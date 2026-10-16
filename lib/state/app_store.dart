import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// widgets.dart：需要 WidgetsBinding 把标签释放推迟到界面卸载之后
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import '../models/app_settings.dart';
import '../models/connection.dart';
import '../models/remote_entry.dart';
import '../models/transfer_task.dart';
import '../services/local_io.dart';
import '../services/monitor_service.dart';
import '../services/remote_path.dart';
import '../services/ssh_session.dart';
import '../services/vault.dart';
import 'monitor_state.dart';

/// SFTP 面板状态（每个标签页一份）
class SftpViewState {
  String path = '';
  List<RemoteEntry> entries = const [];
  bool loading = false;
  bool ready = false;
  String? error;

  String? renaming;

  List<RemoteEntry> visibleEntries(bool showHidden) {
    if (showHidden) return entries;
    return entries.where((entry) => !entry.name.startsWith('.')).toList();
  }
}

/// 目录树状态：惰性加载子目录
class DirectoryTreeState {
  final Map<String, List<String>> children = {};
  final Set<String> expanded = {};
  final Set<String> loading = {};

  bool isExpanded(String path) => expanded.contains(path);
  bool isLoading(String path) => loading.contains(path);

  void forget(String path) {
    children.remove(path);
  }
}

/// 文件内容查看 / 编辑状态
class FileViewState {
  String? path;
  String? name;
  int size = 0;

  String content = '';
  String? original;

  bool loading = false;
  bool truncated = false;
  bool binary = false;
  bool editing = false;
  bool saving = false;
  String? error;

  bool get isOpen => path != null;
  bool get dirty => original != null && content != original;

  int get lineCount => content.isEmpty ? 1 : '\n'.allMatches(content).length + 1;

  void reset() {
    path = null;
    name = null;
    size = 0;
    content = '';
    original = null;
    loading = false;
    truncated = false;
    binary = false;
    editing = false;
    saving = false;
    error = null;
  }
}

/// 一个已打开的终端标签
class TerminalTab {
  TerminalTab({required this.connection}) : session = SshSession(connection) {
    terminal = Terminal(
      maxLines: 8000,
      platform: TerminalTargetPlatform.macos,
      onResize: (width, height, pixelWidth, pixelHeight) =>
          session.resize(width, height, pixelWidth, pixelHeight),
      onOutput: (data) =>
          session.write(Uint8List.fromList(utf8.encode(data))),
      // 不监听 onTitleChange：标签固定显示用户自定义的连接名，
      // 远端 OSC 标题（root@主机名）长且无辨识度
    );
  }

  final String id = SshConnection.newId();
  final SshConnection connection;
  final SshSession session;
  late final Terminal terminal;
  final TerminalController terminalController = TerminalController();
  final SftpViewState sftp = SftpViewState();
  final DirectoryTreeState tree = DirectoryTreeState();
  final FileViewState fileView = FileViewState();
  final MonitorState monitor = MonitorState();

  bool showSftp = false;
  bool showMonitor = false;

  SessionStatus get status => session.status;
  bool get isConnected => session.isConnected;

  void dispose() {
    terminalController.dispose();
    monitor.dispose();
    unawaited(session.dispose());
  }
}

class AppStore extends ChangeNotifier {
  Vault? _vault;
  bool ready = false;
  String? storageWarning;

  List<SshConnection> connections = [];
  List<TerminalTab> tabs = [];
  List<TransferTask> transfers = [];
  AppSettings settings = AppSettings();

  String? activeTabId;
  String? selectedConnectionId;
  bool transferBarCollapsed = false;

  /// 由 UI 注入：主机指纹确认弹窗
  Future<bool> Function(
    SshConnection connection,
    String keyType,
    String fingerprint,
    bool changed,
  )?
  hostKeyPrompter;

  TerminalTab? get activeTab {
    for (final tab in tabs) {
      if (tab.id == activeTabId) return tab;
    }
    return tabs.isEmpty ? null : tabs.last;
  }

  /// 本地加密配置文件的路径（设置页展示用）
  String? get storagePath => _vault?.vaultFile.path;

  /// 某个连接名下所有标签的聚合状态（侧栏圆点用）：
  /// 已连接 > 连接中 > 失败 > 已断开
  SessionStatus? connectionStatus(String connectionId) {
    final matched = tabs.where((tab) => tab.connection.id == connectionId);
    if (matched.isEmpty) return null;
    const priority = [
      SessionStatus.connected,
      SessionStatus.connecting,
      SessionStatus.failed,
      SessionStatus.closed,
      SessionStatus.idle,
    ];
    for (final status in priority) {
      if (matched.any((tab) => tab.status == status)) return status;
    }
    return null;
  }

  List<TransferTask> get activeTransfers =>
      transfers.where((task) => task.isActive).toList();

  // ------------------------------------------------------------ lifecycle

  /// 单实例锁：进程存活期间持有，退出自动释放。
  /// 两个实例同时跑会各自读写同一份 vault.enc，后保存的会覆盖先保存的
  /// （真实事故：Dock 里出现两个图标后，配置被空数据覆盖）。
  // ignore: unused_field
  RandomAccessFile? _instanceLock;

  Future<bool> _acquireSingletonLock() async {
    final dir = _vault?.directory;
    if (dir == null) return true;
    try {
      final raf = await File('${dir.path}/app.lock').open(mode: FileMode.write);
      // 默认非阻塞：锁被占时抛 FileException，即已有实例在跑
      await raf.lock(FileLock.exclusive);
      _instanceLock = raf;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> init() async {
    _vault = await Vault.open();

    // 已有实例在跑（常见于误从 build 目录又开了一份）：直接退出，
    // 避免两个实例读写同一份配置互踩。
    if (!await _acquireSingletonLock()) {
      try {
        stderr.writeln('[Fast Shell] 已有实例在运行，本次启动退出。');
      } catch (_) {}
      exit(0);
    }

    final data = await _vault!.read();
    storageWarning = _vault!.warning;

    final rawConnections = data['connections'];
    if (rawConnections is List) {
      connections = rawConnections
          .whereType<Map<dynamic, dynamic>>()
          .map((json) => SshConnection.fromJson(json.cast<String, dynamic>()))
          .toList();
    }
    settings = AppSettings.fromJson(
      (data['settings'] as Map<dynamic, dynamic>?)?.cast<String, dynamic>(),
    );
    ready = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final vault = _vault;

    // 守卫一：数据还没从磁盘加载完时，内存里的连接列表是空的或不完整的，
    // 写出去会用半初始化状态覆盖用户的真实配置（真实事故：2026-10-14，
    // 启动后 5 分钟内一次保存把 1 条连接覆盖成 0 条）。
    if (vault == null || !ready) return;

    // 守卫二：磁盘上的配置明显有内容、内存里却一条连接都没有时，
    // 十有八九是状态没加载好或实例互踩，绝不能用空列表覆盖。
    // 代价：用户真的删光所有连接时这次删除不落盘（重启后连接还在），
    // 属于「宁可少保存，不可错覆盖」的取舍。
    try {
      final existing = vault.vaultFile;
      if (connections.isEmpty &&
          existing.existsSync() &&
          existing.lengthSync() > 512) {
        return;
      }
    } catch (_) {}

    await vault.write({
      'version': 1,
      'connections': connections.map((item) => item.toJson()).toList(),
      'settings': settings.toJson(),
    });
  }

  void consumeStorageWarning() {
    storageWarning = null;
  }

  // ------------------------------------------------------------- 分类

  /// 新增分类（持久化到设置里）
  Future<void> addCategory(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    if (settings.categories.contains(trimmed)) return;
    settings.categories.add(trimmed);
    await _persist();
    notifyListeners();
  }

  /// 删除分类：使用该分类的连接一并归到「默认」，保证界面不留孤立分组
  Future<void> deleteCategory(String name) async {
    if (AppSettings.defaultCategories.contains(name)) return;
    settings.categories.removeWhere((item) => item == name);
    for (var i = 0; i < connections.length; i++) {
      if (connections[i].group == name) {
        connections[i] = connections[i].copyWith(group: AppSettings.defaultCategories.first);
      }
    }
    await _persist();
    notifyListeners();
  }

  // ---------------------------------------------------------- connections

  Future<void> saveConnection(SshConnection connection) async {
    final index = connections.indexWhere((item) => item.id == connection.id);
    if (index >= 0) {
      connections[index] = connection;
    } else {
      connections.add(connection);
    }
    notifyListeners();
    await _persist();
  }

  Future<void> deleteConnection(String id) async {
    connections.removeWhere((item) => item.id == id);
    if (selectedConnectionId == id) selectedConnectionId = null;
    notifyListeners();
    await _persist();
  }

  Future<void> duplicateConnection(SshConnection connection) async {
    final copy = SshConnection.fromJson(connection.toJson())
      ..id = SshConnection.newId()
      ..name = '${connection.displayName} 副本';
    await saveConnection(copy);
  }

  /// 上下移动连接实现排序（持久化到 vault）
  void moveConnection(SshConnection connection, int delta) {
    final index = connections.indexOf(connection);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= connections.length) return;
    final item = connections.removeAt(index);
    connections.insert(target, item);
    unawaited(_persist());
    notifyListeners();
  }

  void selectConnection(String? id) {
    selectedConnectionId = id;
    notifyListeners();
  }

  List<String> get groups {
    final result = <String>[];
    for (final connection in connections) {
      if (!result.contains(connection.group)) result.add(connection.group);
    }
    result.sort();
    return result;
  }

  // -------------------------------------------------------------- sessions

  Future<TerminalTab> openConnection(SshConnection connection) async {
    final tab = TerminalTab(connection: connection)
      ..showSftp = settings.openSftpByDefault;

    tabs.add(tab);
    activeTabId = tab.id;
    selectedConnectionId = tab.connection.id;
    notifyListeners();

    await _connectTab(tab);
    return tab;
  }

  Future<void> reconnectTab(TerminalTab tab) async {
    tab.terminal.write('\r\n\x1b[38;5;245m—— 重新连接中 ——\x1b[0m\r\n');
    await _connectTab(tab);
  }

  Future<void> _connectTab(TerminalTab tab) async {
    final size = tab.terminal.viewWidth > 0 && tab.terminal.viewHeight > 0
        ? (tab.terminal.viewWidth, tab.terminal.viewHeight)
        : (100, 30);

    await tab.session.connect(
      columns: size.$1,
      rows: size.$2,
      onOutput: (data) => tab.terminal.write(data),
      onStatus: (status, error) {
        if (status == SessionStatus.closed && error != null) {
          tab.terminal.write(
            '\r\n\x1b[38;5;245m$error\x1b[0m\r\n',
          );
        }
        if (status == SessionStatus.failed && error != null) {
          tab.terminal.write('\r\n\x1b[31m✗ $error\x1b[0m\r\n');
        }
        notifyListeners();
      },
      onHostKey: (keyType, fingerprint) async {
        final known = tab.connection.hostKeyFingerprint;
        if (known != null && known == fingerprint) return true;

        final prompter = hostKeyPrompter;
        if (prompter == null) return known == null;

        final changed = known != null && known != fingerprint;
        final trusted = await prompter(
          tab.connection,
          keyType,
          fingerprint,
          changed,
        );
        if (trusted) {
          tab.connection.hostKeyFingerprint = fingerprint;
          tab.connection.lastConnectedAt = DateTime.now();
          await _persist();
          notifyListeners();
        }
        return trusted;
      },
    );

    if (tab.session.isConnected) {
      tab.connection.lastConnectedAt = DateTime.now();
      await _persist();
      // 连接已建立、UI 立刻可用；预热 exec 通道放到后台异步跑，
      // 不阻塞打开连接这个动作，也不影响终端交互。
      // 预热完成后顺带预取首份监控数据，点开监控面板时不用再等 exec 冷启动。
      unawaited(
        tab.session.warmUpExec().then((_) {
          tab.monitor.executor = (command) => tab.session.runCommand(command);
          tab.monitor.streamer = tab.session.streamCommand;
          return tab.monitor.prefetch();
        }),
      );
      if (tab.showSftp) {
        unawaited(sftpOpen(tab));
      }
    }
  }

  Future<void> closeTab(String id) async {
    final index = tabs.indexWhere((tab) => tab.id == id);
    if (index < 0) return;
    final tab = tabs.removeAt(index);
    if (activeTabId == id) {
      activeTabId = tabs.isEmpty
          ? null
          : tabs[min(index, tabs.length - 1)].id;
    }
    notifyListeners();
    // 关键顺序：先让界面重建、把该标签的 TerminalView 从树上卸掉，
    // 下一帧再释放 terminal / controller。否则已挂载的终端会用到
    // 已 dispose 的 TerminalController（关闭连接时花屏的元凶之一）。
    WidgetsBinding.instance.addPostFrameCallback((_) => tab.dispose());
  }

  void activateTab(String id) {
    activeTabId = id;
    for (final tab in tabs) {
      if (tab.id == id) selectedConnectionId = tab.connection.id;
    }
    notifyListeners();
  }

  void toggleSftp(TerminalTab tab) {
    tab.showSftp = !tab.showSftp;
    notifyListeners();
    if (tab.showSftp && !tab.sftp.ready) {
      unawaited(sftpOpen(tab));
    }
  }

  // ------------------------------------------------------------ 监控面板

  void toggleMonitor(TerminalTab tab) {
    tab.showMonitor = !tab.showMonitor;
    final monitor = tab.monitor;
    if (tab.showMonitor) {
      monitor.executor = (command) => tab.session.runCommand(command);
      monitor.streamer = tab.session.streamCommand;
      monitor.startPolling();
    } else {
      monitor.stopPolling();
      unawaited(monitor.closeLogs());
    }
    notifyListeners();
  }

  /// 应用前后台切换：退到后台就停掉监控轮询（省 CPU/电量，也少打扰服务端），
  /// 回到前台再恢复。终端会话本身是远端的，断开与否不受影响。
  void setAppActive(bool active) {
    var changed = false;
    for (final tab in tabs) {
      final monitor = tab.monitor;
      if (!tab.showMonitor) continue; // 没开监控面板的本来就没轮询
      if (active) {
        monitor.startPolling();
      } else {
        monitor.stopPolling();
      }
      changed = true;
    }
    if (changed && active) notifyListeners();
  }

  /// 立即刷新（主机指标 + docker 列表并行），完成或失败后通知 UI
  Future<void> refreshMonitor(TerminalTab tab) async {
    final monitor = tab.monitor;
    if (!monitor.opened) return;
    unawaited(
      monitor.refreshNow().then((_) => notifyListeners()),
    );
  }

  Future<void> loadDockerStats(TerminalTab tab) async {
    await tab.monitor.loadDockerStats();
    notifyListeners();
  }

  /// 容器操作：start / stop / restart / rm；完成后立即刷新 docker 列表
  Future<String> containerAction(
    TerminalTab tab,
    ContainerInfo container,
    String action,
  ) async {
    final output = await tab.monitor.containerAction(container.name, action);
    unawaited(
      tab.monitor
          .refreshDocker()
          .then((_) => tab.monitor.loadDockerStats())
          .then((_) => notifyListeners()),
    );
    return output;
  }

  Future<void> openContainerLogs(TerminalTab tab, String name) async {
    await tab.monitor.openLogs(name, onChanged: notifyListeners);
    notifyListeners();
  }

  Future<void> closeContainerLogs(TerminalTab tab) async {
    await tab.monitor.closeLogs();
    notifyListeners();
  }

  Future<void> toggleLogFollow(TerminalTab tab) async {
    final monitor = tab.monitor;
    if (monitor.logFollowing) {
      await monitor.stopFollow();
    } else {
      // 日志增量由 xterm 自己重绘、UI 侧由 _LogTail 监听终端变化局部刷新，
      // 这里不再主动通知整页重建
      unawaited(monitor.startFollow());
    }
    notifyListeners();
  }

  /// 切换容器日志「最新在前 / 顺序显示」。
  /// 切换本身重写终端缓冲（由 xterm 重绘），这里只需通知一次更新按钮态；
  /// 倒序下吸底跟随没有意义，顺手关掉跟踪流。
  void toggleLogOrder(TerminalTab tab) {
    final monitor = tab.monitor;
    monitor.toggleLogOrder();
    if (monitor.logReversed && monitor.logFollowing) {
      unawaited(monitor.stopFollow());
    }
    notifyListeners();
  }

  Future<void> disconnectTab(TerminalTab tab) async {
    await tab.session.disconnect();
    notifyListeners();
  }

  void clearTerminal(TerminalTab tab) {
    // 通过转义序列清屏 + 清回滚缓冲（CSI 2J / 3J），保证触发重绘
    tab.terminal.write('\x1b[H\x1b[2J\x1b[3J');
  }

  void changeFontSize(double delta) {
    final next = (settings.fontSize + delta).clamp(9.0, 26.0);
    settings.fontSize = next;
    notifyListeners();
    unawaited(_persist());
  }

  Future<void> updateSettings({
    bool? showHiddenFiles,
    bool? confirmBeforeClose,
    bool? openSftpByDefault,
    double? fontSize,
  }) async {
    if (showHiddenFiles != null) settings.showHiddenFiles = showHiddenFiles;
    if (confirmBeforeClose != null) {
      settings.confirmBeforeClose = confirmBeforeClose;
    }
    if (openSftpByDefault != null) {
      settings.openSftpByDefault = openSftpByDefault;
    }
    if (fontSize != null) settings.fontSize = fontSize;
    notifyListeners();
    await _persist();
  }

  // ---------------------------------------------------------------- SFTP

  Future<void> sftpOpen(TerminalTab tab, {String? path}) async {
    final state = tab.sftp;
    state.loading = true;
    state.error = null;
    tab.fileView.reset();
    notifyListeners();

    try {
      final target = path ??
          (state.path.isEmpty
              ? await tab.session.resolveInitialDirectory()
              : state.path);
      state.entries = await tab.session.listDir(target);
      state.path = RemotePath.normalize(target);
      state.ready = true;
      _syncTreeFor(tab, state.path);
    } catch (error) {
      state.error = _describe(error);
    } finally {
      state.loading = false;
      notifyListeners();
    }
  }

  /// 目录切换后让树同步展开并高亮
  void _syncTreeFor(TerminalTab tab, String path) {
    final tree = tab.tree;
    tree.expanded.add('/');
    if (path != '/') {
      var current = '';
      for (final segment in RemotePath.normalize(path).split('/')) {
        if (segment.isEmpty) continue;
        current = '$current/$segment';
        tree.expanded.add(current);
      }
    }
  }

  // ------------------------------------------------------------ 目录树

  Future<void> treeToggle(TerminalTab tab, String path) async {
    final tree = tab.tree;
    if (tree.expanded.contains(path)) {
      tree.expanded.remove(path);
      notifyListeners();
      return;
    }
    tree.expanded.add(path);
    notifyListeners();
    if (!tree.children.containsKey(path)) {
      await treeLoad(tab, path);
    }
  }

  Future<void> treeLoad(TerminalTab tab, String path) async {
    final tree = tab.tree;
    if (tree.loading.contains(path)) return;
    tree.loading.add(path);
    notifyListeners();
    try {
      tree.children[path] = await tab.session.listDirectories(path);
    } catch (_) {
      tree.children[path] = const [];
    } finally {
      tree.loading.remove(path);
      notifyListeners();
    }
  }

  /// 目录结构变化后刷新树的指定分支（及其父级）
  void invalidateTree(TerminalTab tab, String path) {
    final tree = tab.tree;
    tree.forget(path);
    tree.forget(RemotePath.parent(path));
    if (tree.expanded.contains(path)) {
      unawaited(treeLoad(tab, path));
    }
    if (tree.expanded.contains(RemotePath.parent(path))) {
      unawaited(treeLoad(tab, RemotePath.parent(path)));
    }
  }

  // -------------------------------------------------- 文件内容查看/编辑

  Future<void> openFileViewer(TerminalTab tab, RemoteEntry entry) async {
    final view = tab.fileView;
    view.reset();
    view.path = RemotePath.join(tab.sftp.path, entry.name);
    view.name = entry.name;
    view.size = entry.size;
    view.loading = true;
    notifyListeners();
    await _loadFileContent(tab);
  }

  Future<void> refreshFileViewer(TerminalTab tab) async {
    if (!tab.fileView.isOpen) return;
    tab.fileView.loading = true;
    tab.fileView.error = null;
    notifyListeners();
    await _loadFileContent(tab);
  }

  Future<void> _loadFileContent(TerminalTab tab) async {
    final view = tab.fileView;
    final path = view.path;
    if (path == null) return;
    try {
      final result = await tab.session.readTextFile(path);
      view
        ..content = result.text
        ..original = result.text
        ..size = result.size
        ..truncated = result.truncated
        ..binary = result.binary
        ..error = null;
    } catch (error) {
      view.error = _describe(error);
    } finally {
      view.loading = false;
      notifyListeners();
    }
  }

  void startEditFile(TerminalTab tab) {
    tab.fileView.editing = true;
    notifyListeners();
  }

  void cancelEditFile(TerminalTab tab) {
    final view = tab.fileView;
    view.content = view.original ?? '';
    view.editing = false;
    notifyListeners();
  }

  Future<bool> saveFileContent(TerminalTab tab, String content) async {
    tab.fileView.content = content;
    return saveFileViewer(tab);
  }

  Future<bool> saveFileViewer(TerminalTab tab) async {
    final view = tab.fileView;
    final path = view.path;
    if (path == null) return false;
    view.saving = true;
    view.error = null;
    notifyListeners();
    try {
      await tab.session.writeTextFile(path, view.content);
      view
        ..original = view.content
        ..size = utf8.encode(view.content).length
        ..truncated = false
        ..binary = false
        ..editing = false;
      invalidateTree(tab, tab.sftp.path);
      return true;
    } catch (error) {
      view.error = _describe(error);
      return false;
    } finally {
      view.saving = false;
      notifyListeners();
    }
  }

  void closeFileViewer(TerminalTab tab) {
    tab.fileView.reset();
    notifyListeners();
  }

  Future<void> sftpOpenParent(TerminalTab tab) async {
    final path = tab.sftp.path;
    if (path.isEmpty || path == '/') return;
    await sftpOpen(tab, path: RemotePath.parent(path));
  }

  Future<void> sftpMkdir(TerminalTab tab, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await tab.session.mkdir(RemotePath.join(tab.sftp.path, trimmed));
    invalidateTree(tab, tab.sftp.path);
    await sftpOpen(tab);
  }

  Future<void> sftpRename(
    TerminalTab tab,
    RemoteEntry entry,
    String newName,
  ) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == entry.name) return;
    await tab.session.rename(
      RemotePath.join(tab.sftp.path, entry.name),
      RemotePath.join(tab.sftp.path, trimmed),
    );
    invalidateTree(tab, tab.sftp.path);
    await sftpOpen(tab);
  }

  Future<void> sftpDelete(TerminalTab tab, List<RemoteEntry> entries) async {
    for (final entry in entries) {
      await tab.session.deleteRecursive(
        RemotePath.join(tab.sftp.path, entry.name),
      );
    }
    invalidateTree(tab, tab.sftp.path);
    await sftpOpen(tab);
  }

  /// 上传本地文件 / 目录到当前远端目录
  Future<void> uploadPaths(
    TerminalTab tab,
    List<String> localPaths, {
    String? remoteDir,
  }) async {
    final targetDir = remoteDir ?? tab.sftp.path;
    if (targetDir.isEmpty) return;

    for (final localPath in localPaths) {
      final type = FileSystemEntity.typeSync(localPath);
      if (type == FileSystemEntityType.directory) {
        final base = localPath.split(Platform.pathSeparator).last;
        final remoteBase = RemotePath.join(targetDir, base);
        await _collectUploadJobs(Directory(localPath), remoteBase, tab);
      } else if (type == FileSystemEntityType.file) {
        final file = File(localPath);
        final name = localPath.split(Platform.pathSeparator).last;
        final size = await file.length();
        await _enqueueTransfer(
          tab,
          TransferTask(
            id: SshConnection.newId(),
            name: name,
            direction: TransferDirection.upload,
            localPath: localPath,
            remotePath: RemotePath.join(targetDir, name),
            totalBytes: size,
          ),
        );
      }
    }
    if (tab.sftp.ready) {
      invalidateTree(tab, targetDir);
      unawaited(sftpOpen(tab));
    }
  }

  Future<void> _collectUploadJobs(
    Directory directory,
    String remoteDir,
    TerminalTab tab,
  ) async {
    final entities = directory.listSync(followLinks: false);
    if (entities.isEmpty) {
      await tab.session.mkdirRecursive(remoteDir);
      return;
    }
    for (final entity in entities) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (entity is Directory) {
        await _collectUploadJobs(entity, RemotePath.join(remoteDir, name), tab);
      } else if (entity is File) {
        final size = await entity.length();
        await _enqueueTransfer(
          tab,
          TransferTask(
            id: SshConnection.newId(),
            name: name,
            direction: TransferDirection.upload,
            localPath: entity.path,
            remotePath: RemotePath.join(remoteDir, name),
            totalBytes: size,
          ),
        );
      }
    }
  }

  /// 默认下载目录（~/Downloads）。首次调用会确保目录存在。
  ///
  /// 之所以默认落到这里而不是每次都弹面板：macOS 沙盒下
  /// ~/Downloads 有明确的读写授权，是唯一「点了就一定写得进去」的位置。
  Future<String> defaultDownloadDirectory() async {
    final dir = await LocalIo.downloadsDirectory();
    return dir.path;
  }

  /// 下载远端条目到本地目录。
  ///
  /// [localDir] 为空时使用 ~/Downloads。返回实际加入队列的条目数。
  /// 目录创建失败等错误会直接抛出，由调用方提示用户。
  Future<int> downloadEntries(
    TerminalTab tab,
    List<RemoteEntry> entries, {
    String? localDir,
  }) async {
    if (entries.isEmpty) return 0;
    final target = (localDir == null || localDir.isEmpty)
        ? await defaultDownloadDirectory()
        : localDir;

    // 提前落盘一次，避免每个任务各自创建时反复报错
    await Directory(target).create(recursive: true);

    var count = 0;
    for (final entry in entries) {
      final remotePath = RemotePath.join(tab.sftp.path, entry.name);
      if (entry.isDir) {
        count += await _collectDownloadJobs(remotePath, target, tab);
      } else {
        await _enqueueTransfer(
          tab,
          TransferTask(
            id: SshConnection.newId(),
            name: entry.name,
            direction: TransferDirection.download,
            localPath: LocalIo.join(target, entry.name),
            remotePath: remotePath,
            totalBytes: entry.size,
          ),
        );
        count++;
      }
    }
    return count;
  }

  Future<int> _collectDownloadJobs(
    String remoteDir,
    String localDir,
    TerminalTab tab,
  ) async {
    final name = RemotePath.baseName(remoteDir);
    final targetDir = LocalIo.join(localDir, name);
    await Directory(targetDir).create(recursive: true);

    var count = 0;
    for (final entry in await tab.session.listDir(remoteDir)) {
      final remotePath = RemotePath.join(remoteDir, entry.name);
      if (entry.isDir) {
        count += await _collectDownloadJobs(remotePath, targetDir, tab);
      } else {
        await _enqueueTransfer(
          tab,
          TransferTask(
            id: SshConnection.newId(),
            name: entry.name,
            direction: TransferDirection.download,
            localPath: LocalIo.join(targetDir, entry.name),
            remotePath: remotePath,
            totalBytes: entry.size,
          ),
        );
        count++;
      }
    }
    return count;
  }

  // ------------------------------------------------------------- transfers

  final List<TransferTask> _queue = [];
  int _running = 0;
  static const _maxParallelTransfers = 2;

  Future<void> _enqueueTransfer(TerminalTab tab, TransferTask task) async {
    _queue.add(task);
    transfers.add(task);
    notifyListeners();
    _pumpTransfers(tab);
  }

  void _pumpTransfers(TerminalTab tab) {
    while (_running < _maxParallelTransfers && _queue.isNotEmpty) {
      final task = _queue.removeAt(0);
      _running++;
      unawaited(
        _runTransfer(tab, task).whenComplete(() {
          _running--;
          _pumpTransfers(tab);
        }),
      );
    }
  }

  Future<void> _runTransfer(TerminalTab tab, TransferTask task) async {
    if (task.cancelRequested) {
      task.status = TransferStatus.cancelled;
      notifyListeners();
      return;
    }
    task.status = TransferStatus.running;
    notifyListeners();

    try {
      if (task.direction == TransferDirection.upload) {
        await tab.session.uploadFile(task);
      } else {
        await tab.session.downloadFile(task);
      }
      if (task.cancelRequested) {
        task.status = TransferStatus.cancelled;
        if (task.direction == TransferDirection.upload) {
          // 清理远端残留的半截文件
          try {
            await tab.session.deleteFile(task.remotePath);
          } catch (_) {}
        } else {
          try {
            await File(task.localPath).delete();
          } catch (_) {}
          try {
            await File('${task.localPath}.fastshell-part').delete();
          } catch (_) {}
        }
      } else {
        task.transferredBytes = task.totalBytes > 0
            ? task.totalBytes
            : task.transferredBytes;
        task.status = TransferStatus.done;
      }
    } catch (error) {
      if (task.cancelRequested) {
        task.status = TransferStatus.cancelled;
      } else {
        task.status = TransferStatus.failed;
        task.error = _describe(error);
      }
    }
    notifyListeners();
  }

  void cancelTransfer(TransferTask task) {
    task.cancelRequested = true;
    if (task.status == TransferStatus.queued) {
      _queue.remove(task);
      task.status = TransferStatus.cancelled;
    }
    notifyListeners();
  }

  /// 从队列中移除单条记录（已结束的任务）
  void removeTransfer(TransferTask task) {
    if (task.isActive) return;
    transfers.remove(task);
    notifyListeners();
  }

  void clearFinishedTransfers() {
    transfers.removeWhere((task) => !task.isActive);
    notifyListeners();
  }

  void toggleTransferBar() {
    transferBarCollapsed = !transferBarCollapsed;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final tab in tabs) {
      tab.dispose();
    }
    super.dispose();
  }

  static String _describe(Object error) => describeError(error);
}
