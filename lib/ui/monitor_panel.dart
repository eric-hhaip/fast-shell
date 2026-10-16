import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../services/log_text.dart';
import '../services/monitor_service.dart';
import '../state/app_store.dart';
import '../state/monitor_state.dart';
import 'log_search.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 服务器监控面板：主机资源 + Docker 容器（操作与日志）
class MonitorPanel extends StatefulWidget {
  const MonitorPanel({super.key, required this.tab, required this.onClose});

  final TerminalTab tab;
  final VoidCallback onClose;

  @override
  State<MonitorPanel> createState() => _MonitorPanelState();
}

class _MonitorPanelState extends State<MonitorPanel> {
  final ScrollController _logScroll = ScrollController();

  /// 内嵌日志视图：标题栏的搜索按钮通过它唤出搜索栏
  final _logViewKey = GlobalKey<_LogViewBodyState>();

  /// 全屏日志窗口是否打开：打开时内嵌视图让位，
  /// 否则两个视口会同时改动同一个 Terminal 的网格尺寸
  bool _fullscreenLog = false;

  TerminalTab get tab => widget.tab;

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  void _toast(String message, {bool error = false}) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontSize: 12.5)),
        behavior: SnackBarBehavior.floating,
        width: 340,
        duration: Duration(seconds: error ? 4 : 2),
        backgroundColor: error
            ? const Color(0xFF5A2430)
            : const Color(0xFF232A35),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final monitor = tab.monitor;
    final showLogs = monitor.logContainer != null;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        children: [
          _header(store, showLogs),
          Expanded(
            child: showLogs
                ? _logView(store, monitor)
                : _dashboard(store, monitor),
          ),
        ],
      ),
    );
  }

  Widget _header(AppStore store, bool showLogs) {
    final monitor = tab.monitor;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.monitor_heart_outlined,
            size: 15,
            color: Color(0xFF12B5A5),
          ),
          const SizedBox(width: 7),
          Text(
            showLogs ? '容器日志 · ${monitor.logContainer}' : '服务器监控',
            style: const TextStyle(
              fontSize: 12.8,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const Spacer(),
          if (showLogs)
            AppIconButton(
              icon: Icons.swap_vert,
              tooltip: monitor.logReversed ? '恢复顺序显示' : '最新在前（倒序快照）',
              active: monitor.logReversed,
              iconColor: const Color(0xFFE0912F),
              onPressed: () => store.toggleLogOrder(tab),
            ),
          if (showLogs)
            AppIconButton(
              icon: Icons.search,
              tooltip: '搜索日志（⌘F）',
              iconColor: const Color(0xFF9B6BE0),
              onPressed: () => _logViewKey.currentState?.openSearch(),
            ),
          if (showLogs)
            AppIconButton(
              icon: monitor.logFollowing
                  ? Icons.pause_circle_outline
                  : Icons.play_circle_outline,
              tooltip: monitor.logFollowing ? '停止跟踪' : '实时跟踪',
              active: monitor.logFollowing,
              iconColor: const Color(0xFF12A150),
              onPressed: () => store.toggleLogFollow(tab),
            ),
          if (showLogs)
            AppIconButton(
              icon: Icons.refresh,
              tooltip: '重新加载',
              iconColor: const Color(0xFF2F9BD8),
              onPressed: () =>
                  store.openContainerLogs(tab, monitor.logContainer!),
            ),
          if (showLogs)
            AppIconButton(
              icon: Icons.open_in_full,
              tooltip: '全屏查看',
              iconColor: const Color(0xFF2F6BFF),
              onPressed: () => _openFullscreenLogs(store),
            ),
          if (!showLogs) ...[
            AppIconButton(
              icon: Icons.speed_outlined,
              tooltip: '刷新容器资源占用',
              iconColor: const Color(0xFF9B6BE0),
              onPressed: monitor.statsLoading
                  ? null
                  : () => store.loadDockerStats(tab),
            ),
            AppIconButton(
              icon: Icons.refresh,
              tooltip: '立即刷新（每 3 秒自动刷新）',
              iconColor: const Color(0xFF2F9BD8),
              onPressed: () => store.refreshMonitor(tab),
            ),
          ],
          AppIconButton(
            icon: Icons.close,
            tooltip: showLogs ? '返回监控' : '收起面板',
            onPressed: () {
              if (showLogs) {
                store.closeContainerLogs(tab);
              } else {
                widget.onClose();
              }
            },
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 主面板

  Widget _dashboard(AppStore store, MonitorState monitor) {
    final snapshot = monitor.snapshot;
    if (snapshot == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            const SizedBox(height: 12),
            _LoadingHint(error: monitor.error),
            if (monitor.error != null) ...[
              const SizedBox(height: 6),
              Text('会持续自动重试，一般几秒内出数据', style: AppText.tertiary),
            ],
          ],
        ),
      );
    }
    if (monitor.error != null && snapshot.hostname.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 22, color: AppColors.danger),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                monitor.error!,
                textAlign: TextAlign.center,
                style: AppText.secondary,
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      children: [
        _hostCard(snapshot),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _metricCard(
                label: 'CPU',
                value: snapshot.cpuPercent == null
                    ? '—'
                    : '${snapshot.cpuPercent!.toStringAsFixed(1)}%',
                subtitle: '${snapshot.cores} 核',
                percent: snapshot.cpuPercent,
                color: const Color(0xFF2F6BFF),
                history: monitor.cpuHistory,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _metricCard(
                label: '内存',
                value: '${snapshot.memPercent.toStringAsFixed(1)}%',
                subtitle:
                    '${_gb(snapshot.memUsedBytes)} / ${_gb(snapshot.memTotalBytes)}',
                percent: snapshot.memPercent,
                color: const Color(0xFF8B5CF6),
                history: monitor.memHistory,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _networkCard(monitor),
        const SizedBox(height: 10),
        _diskCard(snapshot),
        const SizedBox(height: 10),
        _processCard(snapshot),
        const SizedBox(height: 12),
        _dockerSection(store),
      ],
    );
  }

  Widget _hostCard(HostSnapshot snapshot) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.dns_outlined,
                size: 14,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  snapshot.hostname,
                  style: const TextStyle(
                    fontSize: 12.8,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(_uptime(snapshot.uptimeSeconds), style: AppText.tertiary),
            ],
          ),
          if (snapshot.os.isNotEmpty || snapshot.kernel.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              [
                if (snapshot.os.isNotEmpty) snapshot.os,
                if (snapshot.kernel.isNotEmpty) snapshot.kernel,
              ].join(' · '),
              style: AppText.tertiary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _metricCard({
    required String label,
    required String value,
    required String subtitle,
    required double? percent,
    required Color color,
    required List<double> history,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: AppText.tertiary),
              const Spacer(),
              Text(
                value,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(subtitle, style: AppText.tertiary),
          const SizedBox(height: 8),
          SizedBox(
            height: 34,
            width: double.infinity,
            child: CustomPaint(
              painter: _SparklinePainter(data: history, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _networkCard(MonitorState monitor) {
    final rx = monitor.rxHistory.isEmpty ? null : monitor.rxHistory.last;
    final tx = monitor.txHistory.isEmpty ? null : monitor.txHistory.last;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('网络', style: AppText.tertiary),
              const Spacer(),
              Icon(Icons.south_west, size: 12, color: const Color(0xFF12A150)),
              const SizedBox(width: 3),
              Text(rx == null ? '—' : '${_rate(rx)} ↓', style: AppText.body),
              const SizedBox(width: 10),
              Icon(Icons.north_east, size: 12, color: const Color(0xFF2F6BFF)),
              const SizedBox(width: 3),
              Text(tx == null ? '—' : '${_rate(tx)} ↑', style: AppText.body),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 30,
            width: double.infinity,
            child: CustomPaint(
              painter: _SparklinePainter(
                data: monitor.rxHistory,
                color: const Color(0xFF12A150),
                overlay: monitor.txHistory,
                overlayColor: const Color(0xFF2F6BFF),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _diskCard(HostSnapshot snapshot) {
    final disks = snapshot.disks;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('磁盘', style: AppText.tertiary),
          const SizedBox(height: 8),
          if (disks.isEmpty)
            const Text('未读取到挂载点', style: AppText.tertiary)
          else
            for (final disk in disks.take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(
                  children: [
                    SizedBox(
                      width: 86,
                      child: Text(
                        disk.mount,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: (disk.percent / 100).clamp(0, 1),
                          minHeight: 5,
                          backgroundColor: AppColors.border,
                          color: disk.percent > 90
                              ? AppColors.danger
                              : disk.percent > 75
                              ? const Color(0xFFF0A02E)
                              : const Color(0xFF2F9BD8),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 108,
                      child: Text(
                        '${_gb(disk.usedBytes)} / ${_gb(disk.totalBytes)} · ${disk.percent.toStringAsFixed(0)}%',
                        style: AppText.tertiary,
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _processCard(HostSnapshot snapshot) {
    final processes = snapshot.processes;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('CPU 占用 Top', style: AppText.tertiary),
          const SizedBox(height: 6),
          if (processes.isEmpty)
            const Text('未读取到进程', style: AppText.tertiary)
          else
            for (final proc in processes.take(5))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.5),
                child: Row(
                  children: [
                    SizedBox(
                      width: 44,
                      child: Text(
                        '${proc.pid}',
                        style: AppText.mono.copyWith(fontSize: 10.5),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        proc.command,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 66,
                      child: Text(
                        '${proc.cpuPercent.toStringAsFixed(1)}% cpu',
                        style: AppText.tertiary,
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _dockerSection(AppStore store) {
    final monitor = tab.monitor;
    final containers = monitor.dockerContainers;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.view_in_ar_outlined,
                size: 14,
                color: Color(0xFF0E9888),
              ),
              const SizedBox(width: 6),
              const Text('Docker 容器', style: AppText.tertiary),
              const Spacer(),
              if (monitor.dockerLoading || monitor.statsLoading)
                const SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (containers.isEmpty)
            Text(
              monitor.dockerLoading ? '正在检测容器…' : '未检测到容器（未安装 Docker 或没有容器）',
              style: AppText.tertiary,
            )
          else
            for (final container in containers) _containerRow(store, container),
        ],
      ),
    );
  }

  Widget _containerRow(AppStore store, ContainerInfo container) {
    final monitor = tab.monitor;
    final stat = monitor.dockerStats[container.name];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 8, 9, 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: AppColors.borderSoft),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: container.isRunning
                        ? AppColors.success
                        : AppColors.textTertiary,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    container.name,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(container.status, style: AppText.tertiary),
              ],
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                Expanded(
                  child: Text(
                    container.image,
                    style: AppText.tertiary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (stat != null)
                  Text(
                    'cpu ${stat.cpuPercent?.toStringAsFixed(1) ?? '?'}% · '
                    '${stat.memUsage} (${stat.memPercent?.toStringAsFixed(1) ?? '?'}%)',
                    style: AppText.tertiary,
                  ),
              ],
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                if (!container.isRunning)
                  _opButton(
                    store,
                    container,
                    '启动',
                    Icons.play_arrow,
                    const Color(0xFF12A150),
                    'start',
                  )
                else ...[
                  _opButton(
                    store,
                    container,
                    '停止',
                    Icons.stop,
                    const Color(0xFFE0A02E),
                    'stop',
                  ),
                  const SizedBox(width: 6),
                  _opButton(
                    store,
                    container,
                    '重启',
                    Icons.refresh,
                    const Color(0xFF2F6BFF),
                    'restart',
                  ),
                ],
                const SizedBox(width: 6),
                _opButton(
                  store,
                  container,
                  '日志',
                  Icons.article_outlined,
                  const Color(0xFF9B6BE0),
                  null,
                ),
                const SizedBox(width: 6),
                _opButton(
                  store,
                  container,
                  '删除',
                  Icons.delete_outline,
                  AppColors.danger,
                  'rm',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _opButton(
    AppStore store,
    ContainerInfo container,
    String label,
    IconData icon,
    Color color,
    String? action,
  ) {
    return _MiniButton(
      label: label,
      icon: icon,
      color: color,
      onTap: () => _runContainerOp(store, container, action),
    );
  }

  Future<void> _runContainerOp(
    AppStore store,
    ContainerInfo container,
    String? action,
  ) async {
    if (action == null) {
      await store.openContainerLogs(tab, container.name);
      return;
    }
    if (action == 'rm') {
      final confirmed = await showConfirmDialog(
        context,
        title: '删除容器',
        message: '将永久删除容器「${container.name}」及其未保存的数据，该操作不可撤销。确认删除？',
        confirmText: '删除',
        danger: true,
      );
      if (!confirmed || !mounted) return;
    }
    final output = await store.containerAction(tab, container, action);
    if (!mounted) return;
    if (output.isNotEmpty && !output.contains('Error')) {
      final labels = {
        'start': '已启动',
        'stop': '已停止',
        'restart': '已重启',
        'rm': '已删除',
      };
      _toast('容器 ${container.name} ${labels[action] ?? action}');
      if (tab.monitor.logContainer != null && action == 'rm') {
        await store.closeContainerLogs(tab);
      }
    } else if (output.isNotEmpty) {
      _toast('操作失败：$output', error: true);
    }
  }

  // ------------------------------------------------------------ 日志视图

  /// 全屏查看容器日志
  void _openFullscreenLogs(AppStore store) {
    if (_fullscreenLog) return;
    // 先让内嵌视图让出 Terminal，再弹全屏，避免两个视口在同一帧里
    // 用不同尺寸去 resize 同一个终端
    setState(() => _fullscreenLog = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showGeneralDialog(
        context: context,
        barrierDismissible: true,
        barrierLabel: '容器日志',
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 150),
        pageBuilder: (dialogContext, animation, secondaryAnimation) {
          return Dialog.fullscreen(
            backgroundColor: const Color(0xFF0D1626),
            child: _FullscreenLogView(
              store: store,
              tab: tab,
              onClose: () => Navigator.of(dialogContext).pop(),
            ),
          );
        },
      ).whenComplete(() {
        if (mounted) setState(() => _fullscreenLog = false);
      });
    });
  }

  Widget _logView(AppStore store, MonitorState monitor) {
    if (monitor.logLoading && monitor.logLineCount == 0) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }
    if (_fullscreenLog) {
      return const ColoredBox(
        color: Color(0xFF0D1626),
        child: Center(
          child: Text(
            '日志已在全屏窗口打开',
            style: TextStyle(fontSize: 11.5, color: Color(0xFF6B7686)),
          ),
        ),
      );
    }
    // 实时跟踪时始终吸底（由 _LogTail 监听终端变化驱动，不依赖整页重建）
    return _LogViewBody(
      key: _logViewKey,
      terminal: monitor.logTerminal,
      scrollController: _logScroll,
      following: monitor.logFollowing && !monitor.logReversed,
      error: monitor.logError,
      fontSize: 11,
    );
  }

  // ------------------------------------------------------------ helpers

  static String _gb(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';
  }

  static String _rate(double kbPerSecond) {
    if (kbPerSecond >= 1024) {
      return '${(kbPerSecond / 1024).toStringAsFixed(1)} MB/s';
    }
    return '${kbPerSecond.toStringAsFixed(0)} KB/s';
  }

  static String _uptime(int seconds) {
    final days = seconds ~/ 86400;
    final hours = (seconds % 86400) ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (days > 0) return '已运行 $days 天 $hours 小时';
    if (hours > 0) return '已运行 $hours 小时 $minutes 分';
    return '已运行 $minutes 分钟';
  }
}

/// 加载提示：显示已等待秒数，超过 5 秒给出引导文案
class _LoadingHint extends StatefulWidget {
  const _LoadingHint({this.error});

  final String? error;

  @override
  State<_LoadingHint> createState() => _LoadingHintState();
}

class _LoadingHintState extends State<_LoadingHint> {
  Timer? _timer;
  int _elapsed = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.error ?? '正在采集服务器数据…（首次连接需预热，请稍候）';
    return Text(
      _elapsed >= 5 ? '$base 已等待 $_elapsed 秒' : base,
      style: AppText.tertiary,
    );
  }
}

/// 容器操作小按钮
class _MiniButton extends StatefulWidget {
  const _MiniButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  State<_MiniButton> createState() => _MiniButtonState();
}

class _MiniButtonState extends State<_MiniButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _hover
                  ? widget.color.withValues(alpha: 0.1)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(
                color: _hover
                    ? widget.color.withValues(alpha: 0.5)
                    : AppColors.borderSoft,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 11.5, color: widget.color),
                const SizedBox(width: 3),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 11,
                    color: widget.color,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 迷你折线图
class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.data,
    required this.color,
    this.overlay,
    this.overlayColor,
  }) : _len = data.length,
       _last = data.isEmpty ? null : data.last,
       _overlayLen = overlay?.length ?? -1,
       _overlayLast = (overlay == null || overlay.isEmpty)
           ? null
           : overlay.last;

  final List<double> data;
  final Color color;
  final List<double>? overlay;
  final Color? overlayColor;

  // 构造时快照：data 是原地增长的同一个 List 实例，
  // 只比引用的话永远判定「没变化」，曲线就再也不会更新。
  final int _len;
  final double? _last;
  final int _overlayLen;
  final double? _overlayLast;

  @override
  void paint(Canvas canvas, Size size) {
    _paintSeries(canvas, size, data, color);
    final over = overlay;
    if (over != null) {
      _paintSeries(canvas, size, over, overlayColor ?? color);
    }
  }

  void _paintSeries(Canvas canvas, Size size, List<double> data, Color color) {
    if (data.isEmpty) return;
    final maxPoint = data.reduce(math.max);
    final maxV = math.max(maxPoint, 1.0) * 1.25;
    final stepX = data.length > 1 ? size.width / (data.length - 1) : size.width;

    final path = Path()..moveTo(0, size.height);
    for (final (index, value) in data.indexed) {
      final x = index * stepX;
      final y =
          size.height - (value / maxV * size.height).clamp(0.0, size.height);
      path.lineTo(x, y);
    }
    path.lineTo((data.length - 1) * stepX, size.height);
    path.close();

    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.30),
            color.withValues(alpha: 0.02),
          ],
        ).createShader(Offset.zero & size),
    );

    final line = Path();
    for (final (index, value) in data.indexed) {
      final x = index * stepX;
      final y =
          size.height - (value / maxV * size.height).clamp(0.0, size.height);
      if (index == 0) {
        line.moveTo(x, y);
      } else {
        line.lineTo(x, y);
      }
    }
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    if (oldDelegate.color != color) return true;
    if (oldDelegate.overlayColor != overlayColor) return true;
    // 数据是同一个 List 原地追加/裁剪的，比长度与末值即可判断出新点
    if (oldDelegate._len != data.length) return true;
    if (oldDelegate._last != (data.isEmpty ? null : data.last)) return true;
    final over = overlay;
    if (oldDelegate._overlayLen != (over?.length ?? -1)) return true;
    if (oldDelegate._overlayLast !=
        ((over == null || over.isEmpty) ? null : over.last)) {
      return true;
    }
    return false;
  }
}

/// 日志终端与搜索高亮共用的字体设置。
///
/// 搜索高亮的坐标换算要按字格尺寸来算，所以两处必须引用同一份定义——
/// 各自写一套迟早会漂移成「高亮整体偏半行」。
TerminalStyle logTerminalTextStyle(double fontSize) => TerminalStyle(
  fontSize: fontSize,
  height: 1.35,
  fontFamily: 'SF Mono',
  fontFamilyFallback: const ['Menlo', 'monospace'],
);

/// 日志查看主体：吸底 + 搜索栏 + 终端 + 命中高亮。
///
/// 内嵌面板与全屏窗口共用同一个实现，两处的搜索行为（⌘F 打开、Enter 下一个、
/// Shift+Enter 上一个、Esc 关闭）因此天然一致。
class _LogViewBody extends StatefulWidget {
  const _LogViewBody({
    super.key,
    required this.terminal,
    required this.scrollController,
    required this.following,
    this.error,
    this.fontSize = 11.5,
    this.padding = const EdgeInsets.fromLTRB(10, 8, 10, 8),
  });

  final Terminal terminal;
  final ScrollController scrollController;
  final bool following;
  final String? error;
  final double fontSize;
  final EdgeInsets padding;

  @override
  State<_LogViewBody> createState() => _LogViewBodyState();
}

class _LogViewBodyState extends State<_LogViewBody> {
  final _searchCtl = TextEditingController();
  final _searchFocus = FocusNode();

  bool _searchOpen = false;
  String _query = '';
  List<LogMatch> _matches = const [];
  int _current = -1;
  Timer? _refreshThrottle;

  /// 搜索栏打开且有关键字时，暂停自动吸底（见 build 里的说明）
  bool get _searchActive => _searchOpen && _query.isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_onTerminalChanged);
  }

  @override
  void didUpdateWidget(_LogViewBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalChanged);
      widget.terminal.addListener(_onTerminalChanged);
    }
  }

  @override
  void dispose() {
    _refreshThrottle?.cancel();
    widget.terminal.removeListener(_onTerminalChanged);
    _searchCtl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 搜索

  /// 跟踪模式下日志会持续追加，命中位置随之变化；节流后重新扫描一遍。
  void _onTerminalChanged() {
    if (!_searchOpen || _query.isEmpty) return;
    if (_refreshThrottle != null) return;
    _refreshThrottle = Timer(const Duration(milliseconds: 400), () {
      _refreshThrottle = null;
      if (mounted) _refreshMatches(jump: false);
    });
  }

  /// 打开搜索栏并聚焦输入框（供标题栏按钮与 ⌘F 共用）
  void openSearch() {
    if (_searchOpen) {
      _searchFocus.requestFocus();
      return;
    }
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _searchCtl.clear();
    setState(() {
      _searchOpen = false;
      _query = '';
      _matches = const [];
      _current = -1;
    });
  }

  void _onQueryChanged(String value) {
    _query = value.trim();
    _refreshMatches();
  }

  /// 扫描整个缓冲区（含回滚）找命中。
  ///
  /// 直接读 xterm 的行文本而不是自己维护一份副本：终端里显示的才是用户
  /// 看到的，且 ANSI 已被解析掉，关键字不会撞上颜色转义。
  void _refreshMatches({bool jump = true}) {
    final matches = _query.isEmpty
        ? const <LogMatch>[]
        : searchLogLines(_readBufferLines(), _query);
    final current = matches.isEmpty
        ? -1
        : (_current >= 0 && _current < matches.length ? _current : 0);
    setState(() {
      _matches = matches;
      _current = current;
    });
    if (jump) _scrollToCurrent();
  }

  List<String> _readBufferLines() {
    final buffer = widget.terminal.buffer;
    final lines = <String>[];
    for (var i = 0; i < buffer.height; i++) {
      lines.add(buffer.lines[i].getText(0, buffer.viewWidth));
    }
    return lines;
  }

  void _step(int delta) {
    if (_matches.isEmpty) return;
    final next = stepMatchIndex(_current, _matches.length, delta);
    setState(() => _current = next);
    _scrollToCurrent();
  }

  /// 把命中的行滚到视口正中，滚动量与 xterm 的像素滚动模型一致
  /// （1 行 = 一个行高，见 terminal_selection.dart 的换算）。
  void _scrollToCurrent() {
    if (_current < 0 || _current >= _matches.length) return;
    final scroll = widget.scrollController;
    if (!scroll.hasClients) return;
    final cell = measureTerminalCell(
      context,
      logTerminalTextStyle(widget.fontSize),
    );
    if (cell.height <= 0) return;
    final position = scroll.position;
    final row = _matches[_current].row;
    final target =
        widget.padding.top +
        row * cell.height -
        (position.viewportDimension - cell.height) / 2;
    scroll.jumpTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  // ------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final textStyle = logTerminalTextStyle(widget.fontSize);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): openSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            openSearch,
      },
      child: Column(
        children: [
          // 零尺寸的尾部感知器：驱动吸底。
          // 搜索进行中不平滑吸底——否则「下一个」刚滚到命中行就被日志流拉回底部。
          _LogTail(
            terminal: widget.terminal,
            scrollController: widget.scrollController,
            following: widget.following && !_searchActive,
            builder: (context) => const SizedBox.shrink(),
          ),
          if (widget.error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: AppColors.danger.withValues(alpha: 0.08),
              child: Text(
                widget.error!,
                style: const TextStyle(fontSize: 11.5, color: AppColors.danger),
              ),
            ),
          if (_searchOpen)
            LogSearchBar(
              controller: _searchCtl,
              focusNode: _searchFocus,
              matchCount: _matches.length,
              currentIndex: _current,
              onChanged: _onQueryChanged,
              onStep: _step,
              onClose: _closeSearch,
            ),
          Expanded(
            child: Container(
              color: const Color(0xFF0D1626),
              child: Stack(
                children: [
                  _LogTerminal(
                    terminal: widget.terminal,
                    scrollController: widget.scrollController,
                    fontSize: widget.fontSize,
                    padding: widget.padding,
                  ),
                  if (_searchOpen && _matches.isNotEmpty)
                    LogSearchHighlight(
                      terminal: widget.terminal,
                      scrollController: widget.scrollController,
                      matches: _matches,
                      currentIndex: _current,
                      textStyle: textStyle,
                      padding: widget.padding,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 只读日志终端：用 xterm 的定宽字符网格渲染日志。
///
/// 为什么不用滚动文本列表：`Text`/`SelectableText` 会把整行排版成一个文本
/// 层，docker 日志里几十万字符的单行 + 上千行内容会让图层尺寸爆炸，在 macOS
/// 上表现为花屏（斜向拉丝）。xterm 只绘制可见单元格，行数再多也只是定长
/// 网格，且原生渲染 ANSI 颜色，日志内容不做任何截断。
class _LogTerminal extends StatelessWidget {
  const _LogTerminal({
    required this.terminal,
    required this.scrollController,
    this.fontSize = 11.5,
    this.padding = const EdgeInsets.fromLTRB(10, 8, 10, 8),
  });

  final Terminal terminal;
  final ScrollController scrollController;
  final double fontSize;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: TerminalView(
        terminal,
        // 只读：不接 onOutput，键盘输入不会回传远端
        readOnly: true,
        scrollController: scrollController,
        theme: appTerminalTheme,
        padding: padding,
        textStyle: logTerminalTextStyle(fontSize),
        cursorType: TerminalCursorType.block,
        alwaysShowCursor: false,
        mouseCursor: SystemMouseCursors.text,
      ),
    );
  }
}

/// 日志尾部感知：直接监听终端自身的变化，节流地刷新计数并保持吸底。
///
/// 终端（xterm）自己会重绘内容，所以日志滚滚而来时不需要 AppStore
/// 通知整页重建——那样每 300ms 会把侧栏、标签、面板全部重造一遍。
class _LogTail extends StatefulWidget {
  const _LogTail({
    required this.terminal,
    required this.scrollController,
    required this.following,
    required this.builder,
  });

  final Terminal terminal;
  final ScrollController scrollController;
  final bool following;

  /// 由刷新回调驱动重建的小块内容（如「N 行」计数）
  final WidgetBuilder builder;

  @override
  State<_LogTail> createState() => _LogTailState();
}

class _LogTailState extends State<_LogTail> {
  Timer? _throttle;

  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_onTerminalChanged);
  }

  @override
  void didUpdateWidget(_LogTail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalChanged);
      widget.terminal.addListener(_onTerminalChanged);
    }
  }

  @override
  void dispose() {
    _throttle?.cancel();
    widget.terminal.removeListener(_onTerminalChanged);
    super.dispose();
  }

  void _onTerminalChanged() {
    // 窗口内的多次输出合并成一次刷新，避免高频日志把 UI 拖住
    if (_throttle != null) return;
    _throttle = Timer(const Duration(milliseconds: 250), () {
      _throttle = null;
      if (!mounted) return;
      if (widget.following) _scrollToBottom();
      setState(() {});
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = widget.scrollController;
      if (controller.hasClients && controller.position.maxScrollExtent > 0) {
        controller.jumpTo(controller.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// 全屏容器日志视图
class _FullscreenLogView extends StatefulWidget {
  const _FullscreenLogView({
    required this.store,
    required this.tab,
    required this.onClose,
  });

  final AppStore store;
  final TerminalTab tab;
  final VoidCallback onClose;

  @override
  State<_FullscreenLogView> createState() => _FullscreenLogViewState();
}

class _FullscreenLogViewState extends State<_FullscreenLogView> {
  final ScrollController _scroll = ScrollController();

  /// 搜索栏挂在共用的 _LogViewBody 里，这里只负责把「打开搜索」的请求递进去
  final _viewKey = GlobalKey<_LogViewBodyState>();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final monitor = widget.tab.monitor;

    return CallbackShortcuts(
      bindings: {
        // Esc 退出全屏（吸底由 _LogTail 监听终端驱动）
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: Focus(
        autofocus: true,
        child: Container(
          color: const Color(0xFF0D1626),
          child: Column(
            children: [
              Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: const BoxDecoration(
                  color: Color(0xFF101B2E),
                  border: Border(bottom: BorderSide(color: Color(0xFF23324A))),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.article_outlined,
                      size: 15,
                      color: Color(0xFF9B6BE0),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '容器日志 · ${monitor.logContainer ?? ''}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFDCE5F2),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _LogTail(
                      terminal: monitor.logTerminal,
                      scrollController: _scroll,
                      following: monitor.logFollowing && !monitor.logReversed,
                      builder: (context) => Text(
                        '${monitor.logLineCount} 行'
                        '${monitor.logFollowing ? ' · 实时跟踪中' : ''}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF6B7686),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Tooltip(
                      message: '搜索日志（⌘F）',
                      child: IconButton(
                        icon: const Icon(
                          Icons.search,
                          size: 18,
                          color: Color(0xFFDCE5F2),
                        ),
                        onPressed: () => _viewKey.currentState?.openSearch(),
                      ),
                    ),
                    Tooltip(
                      message: monitor.logFollowing ? '停止跟踪' : '实时跟踪',
                      child: IconButton(
                        icon: Icon(
                          monitor.logFollowing
                              ? Icons.pause_circle_outline
                              : Icons.play_circle_outline,
                          size: 18,
                          color: monitor.logFollowing
                              ? const Color(0xFF12A150)
                              : const Color(0xFF6B7686),
                        ),
                        onPressed: () =>
                            widget.store.toggleLogFollow(widget.tab),
                      ),
                    ),
                    Tooltip(
                      message: '重新加载',
                      child: IconButton(
                        icon: const Icon(
                          Icons.refresh,
                          size: 18,
                          color: Color(0xFF2F9BD8),
                        ),
                        onPressed: monitor.logContainer == null
                            ? null
                            : () => widget.store.openContainerLogs(
                                widget.tab,
                                monitor.logContainer!,
                              ),
                      ),
                    ),
                    Tooltip(
                      message: '退出全屏（Esc）',
                      child: IconButton(
                        icon: const Icon(
                          Icons.close,
                          size: 18,
                          color: Color(0xFF6B7686),
                        ),
                        onPressed: widget.onClose,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _LogViewBody(
                  key: _viewKey,
                  terminal: monitor.logTerminal,
                  scrollController: _scroll,
                  following: monitor.logFollowing && !monitor.logReversed,
                  fontSize: 11.5,
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
