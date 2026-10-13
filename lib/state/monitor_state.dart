import 'dart:async';

import 'package:xterm/xterm.dart';

import '../services/log_text.dart';
import '../services/monitor_service.dart';
import '../services/ssh_session.dart';

/// 每个标签页一份的监控状态。
/// 轮询、历史曲线、docker 操作、日志跟踪都集中在这里；
/// UI 通过 AppStore.notifyListeners 感知变化，自身不再发通知。
class MonitorState {
  bool opened = false;
  bool loading = false;
  String? error;

  HostSnapshot? snapshot;

  // 上次采样（算 CPU% 与网络速率的差值基准）
  CpuSample? _prevCpu;
  NetSample? _prevNet;
  DateTime? _prevNetAt;

  // 历史曲线（最多 60 个点）
  final List<double> cpuHistory = [];
  final List<double> memHistory = [];
  final List<double> rxHistory = []; // KB/s
  final List<double> txHistory = []; // KB/s
  static const maxHistoryPoints = 60;

  // docker 资源占用
  bool statsLoading = false;
  Map<String, ContainerStat> dockerStats = {};

  // 容器日志
  //
  // 日志缓冲用 xterm 终端而不是字符串列表：xterm 只在定宽字符网格上绘制
  // 可见行，超长行/海量行都不会产生巨型文本层（滚动的文本列表在 macOS 上
  // 会因排版/图层过大而花屏），同时原生支持 ANSI 颜色。
  // 日志内容不做任何截断，回滚上限只决定内存占用。
  String? logContainer;
  static const logScrollback = 10000;
  late final Terminal logTerminal = Terminal(
    maxLines: logScrollback,
    platform: TerminalTargetPlatform.macos,
  );

  /// 本次会话已写入的行数（界面显示用）
  int logLineCount = 0;

  bool logLoading = false;
  bool logFollowing = false;
  String? logError;
  ExecStreamHandle? _logHandle;

  Timer? _timer;
  Timer? _dockerTimer;
  bool _polling = false;
  bool _dockerPolling = false;

  static const pollInterval = Duration(seconds: 3);

  /// docker 列表轮询频率（docker CLI 启动慢，低频 + 并行，不阻塞主指标）
  static const dockerInterval = Duration(seconds: 12);

  /// docker 列表（独立于主机快照，随 docker 轮询更新）
  List<ContainerInfo> dockerContainers = [];
  bool dockerLoading = false;

  /// 由 AppStore 注入：执行一次性命令
  Future<String> Function(String command)? executor;

  /// 由 AppStore 注入：打开持续输出通道（docker logs -f 用）
  Future<ExecStreamHandle> Function(String command, void Function(String) onLine)?
      streamer;

  void startPolling() {
    stopPolling();
    opened = true;
    _timer = Timer.periodic(pollInterval, (_) => _tick());
    _dockerTimer = Timer.periodic(dockerInterval, (_) => _dockerTick());
    // 两条通道并行首发：主机指标先上屏，docker 稍后填充
    unawaited(_tick());
    unawaited(_dockerTick());
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
    _dockerTimer?.cancel();
    _dockerTimer = null;
    opened = false;
  }

  Future<void> _tick() async {
    final run = executor;
    if (run == null || _polling) return;
    _polling = true;
    loading = snapshot == null;
    try {
      final output = await run(MonitorService.hostScript);
      final next = MonitorService.parseSnapshot(
        output,
        prevCpu: _prevCpu,
        prevNet: _prevNet,
      );
      error = null;

      if (next.cpuPercent != null) {
        _push(cpuHistory, next.cpuPercent!);
      }
      _push(memHistory, next.memPercent);

      final net = next.net;
      final now = DateTime.now();
      if (net != null && _prevNet != null && _prevNetAt != null) {
        final seconds = now.difference(_prevNetAt!).inMilliseconds / 1000.0;
        if (seconds > 0.2) {
          _push(rxHistory, (net.rxBytes - _prevNet!.rxBytes) / seconds / 1024);
          _push(txHistory, (net.txBytes - _prevNet!.txBytes) / seconds / 1024);
        }
      }
      _prevCpu = next.cpuRaw;
      _prevNet = net;
      _prevNetAt = now;

      snapshot = next;
    } catch (e) {
      if (e is TimeoutException) {
        error = '采集超时：服务器响应太慢，正在自动重试…';
      } else {
        error = e.toString().replaceFirst('Exception: ', '');
      }
    } finally {
      loading = false;
      _polling = false;
    }
  }

  /// docker 列表：独立低频通道，失败不影响主指标
  Future<void> _dockerTick() async {
    final run = executor;
    // opened=false 时允许预取阶段的这一次调用
    if (run == null || _dockerPolling || (!opened && !_prefetching)) return;
    _dockerPolling = true;
    dockerLoading = dockerContainers.isEmpty;
    try {
      final output = await run(MonitorService.dockerScript)
          .timeout(const Duration(seconds: 15));
      dockerContainers = MonitorService.parseContainers(output);
      error = null;
    } catch (e) {
      if (e is TimeoutException) return; // 静默，下个周期再试
      // docker 不可用（未安装 / 权限）就清空列表，面板会显示未检测到
      dockerContainers = [];
    } finally {
      dockerLoading = false;
      _dockerPolling = false;
    }
  }

  /// 立即同时刷新两条通道
  Future<void> refreshNow() async {
    await Future.wait([_tick(), _dockerTick()]);
  }

  bool _prefetching = false;
  bool _prefetched = false;

  /// 连接建立后预取首份监控数据：exec 冷启动（PAM/NSS 预热）在后台先付掉，
  /// 用户点开监控面板时数据已经就绪，不用再等十几秒。
  Future<void> prefetch() async {
    if (_prefetched || executor == null) return;
    _prefetched = true;
    _prefetching = true;
    try {
      await _tick();
      await _dockerTick();
    } finally {
      _prefetching = false;
    }
  }

  /// 只刷 docker 列表（容器启停/删除后立刻反映结果，不等 12 秒）
  Future<void> refreshDocker() => _dockerTick();

  void _push(List<double> list, double value) {
    list.add(value);
    if (list.length > maxHistoryPoints) {
      list.removeRange(0, list.length - maxHistoryPoints);
    }
  }

  // ------------------------------------------------------------- docker

  Future<void> loadDockerStats() async {
    final run = executor;
    if (run == null || statsLoading) return;
    statsLoading = true;
    try {
      final output = await run(MonitorService.dockerStatsScript)
          .timeout(const Duration(seconds: 25));
      dockerStats = MonitorService.parseDockerStats(output);
    } catch (_) {
      // stats 拿不到就保留旧值，不打断主轮询
    } finally {
      statsLoading = false;
    }
  }

  /// 启动 / 停止 / 重启 / 删除容器；返回输出（报错信息也在这里）
  Future<String> containerAction(String name, String action) async {
    final run = executor;
    if (run == null) return '连接尚未建立';
    try {
      final output = await run(
        MonitorService.containerActionScript(name, action),
      ).timeout(const Duration(seconds: 20));
      return output.trim();
    } catch (e) {
      return e.toString().replaceFirst('Exception: ', '');
    }
  }

  // ------------------------------------------------------------- 日志

  /// 写入一行日志到终端缓冲（超过 [logScrollback] 行时由 xterm 丢弃最旧的行）。
  /// 写入前按日志级别着色：级别词/时间戳上色，正文保持默认色。
  void appendLogLine(String line) {
    logTerminal.write('${colorizeLogLine(sanitizeLogChunk(line))}\r\n');
    logLineCount++;
  }

  /// 清空终端缓冲
  void resetLogTerminal() {
    // CSI 2J 清屏 / CSI 3J 清回滚缓冲
    logTerminal.write('\x1b[H\x1b[2J\x1b[3J');
    logLineCount = 0;
  }

  Future<void> openLogs(
    String name, {
    required void Function() onChanged,
  }) async {
    await closeLogs();
    logContainer = name;
    logLoading = true;
    logError = null;
    resetLogTerminal();
    onChanged();
    final run = executor;
    if (run == null) {
      logLoading = false;
      logError = '连接尚未建立';
      onChanged();
      return;
    }
    try {
      final output = await run(MonitorService.containerLogsScript(name))
          .timeout(const Duration(seconds: 15));
      // 原样写入，不截断：长行由 xterm 自动折行到回滚缓冲里
      final text = sanitizeLogChunk(output);
      if (text.isNotEmpty) {
        // 裸 \n 只换行不回列（行首会阶梯缩进），统一归一成 \r\n；
        // 再按级别着色——逐行做，正文和颜色都不改内容。
        final normalized = colorizeLogChunk(normalizeLogNewlines(text));
        logTerminal.write(
          normalized.endsWith('\r\n') ? normalized : '$normalized\r\n',
        );
        logLineCount = countLogLines(text);
      }
    } catch (e) {
      logError = '日志读取失败：${e.toString().replaceFirst('Exception: ', '')}';
    } finally {
      logLoading = false;
      onChanged();
    }
  }

  /// 跟踪模式：docker logs -f 持续追加。
  ///
  /// 日志内容直接写进 xterm 缓冲（终端自身重绘），UI 侧由 `_LogTail`
  /// 监听终端变化局部刷新，因此这里不需要逐行通知整页重建；
  /// [onChanged] 只在跟踪开关状态变化时回调一次。
  Future<void> startFollow({void Function()? onChanged}) async {
    final name = logContainer;
    final stream = streamer;
    if (name == null || stream == null || logFollowing) return;

    try {
      _logHandle = await stream(
        MonitorService.containerLogsScript(name, follow: true),
        (raw) {
          if (raw.isEmpty) return;
          appendLogLine(raw);
        },
      );
      logFollowing = true;
      onChanged?.call();
    } catch (e) {
      logError = '跟踪失败：${e.toString().replaceFirst('Exception: ', '')}';
      onChanged?.call();
    }
  }

  Future<void> stopFollow() async {
    final handle = _logHandle;
    _logHandle = null;
    logFollowing = false;
    if (handle != null) {
      try {
        await handle.close();
      } catch (_) {}
    }
  }

  Future<void> closeLogs() async {
    await stopFollow();
    logContainer = null;
    resetLogTerminal();
    logError = null;
    logLoading = false;
    logFollowing = false;
  }

  void dispose() {
    stopPolling();
    stopFollow();
  }
}
