import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/remote_entry.dart';
import '../services/local_io.dart';
import '../services/remote_path.dart';
import '../state/app_store.dart';
import 'theme.dart';
import 'widgets/common.dart';

class SftpPanel extends StatefulWidget {
  const SftpPanel({super.key, required this.tab, required this.onClose});

  final TerminalTab tab;
  final VoidCallback onClose;

  @override
  State<SftpPanel> createState() => _SftpPanelState();
}

class _SftpPanelState extends State<SftpPanel> {
  final Set<String> _selected = {};
  bool _dragging = false;
  bool _showTree = true;
  String _lastPath = '';

  TerminalTab get tab => widget.tab;

  void _toggleSelection(String name, {bool additive = false}) {
    setState(() {
      if (additive) {
        if (!_selected.remove(name)) _selected.add(name);
      } else {
        if (_selected.length == 1 && _selected.contains(name)) {
          _selected.clear();
        } else {
          _selected
            ..clear()
            ..add(name);
        }
      }
    });
  }

  List<RemoteEntry> get _selectedEntries =>
      tab.sftp.entries.where((entry) => _selected.contains(entry.name)).toList();

  bool get _modifierPressed =>
      HardwareKeyboard.instance.isMetaPressed ||
      HardwareKeyboard.instance.isShiftPressed;

  // ------------------------------------------------------------- 行为

  Future<void> _openEntry(RemoteEntry entry) async {
    final store = context.read<AppStore>();
    if (entry.isDir) {
      setState(() => _selected.clear());
      await store.sftpOpen(
        tab,
        path: RemotePath.join(tab.sftp.path, entry.name),
      );
    } else {
      await store.openFileViewer(tab, entry);
    }
  }

  Future<void> _uploadFiles({String? remoteDir}) async {
    final store = context.read<AppStore>();
    final files = await FilePicker.pickFiles(
      dialogTitle: remoteDir == null
          ? '选择要上传的文件（可多选）'
          : '选择要上传到「${RemotePath.baseName(remoteDir)}」的文件',
    );
    final paths = files
        .map((file) => file.path)
        .whereType<String>()
        .toList(growable: false);
    if (paths.isEmpty) return;
    await store.uploadPaths(tab, paths, remoteDir: remoteDir);
  }

  Future<void> _uploadFolder({String? remoteDir}) async {
    final store = context.read<AppStore>();
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择要上传的文件夹',
    );
    if (directory == null || directory.isEmpty) return;
    await store.uploadPaths(tab, [directory], remoteDir: remoteDir);
  }

  /// 直接下载到默认目录（~/Downloads）。
  ///
  /// 不再每次弹目录选择面板：沙盒下 ~/Downloads 一定有写权限，
  /// 少一步交互，下载完还能一键在访达中查看。
  Future<void> _download(List<RemoteEntry> entries) async {
    if (entries.isEmpty) return;
    final store = context.read<AppStore>();
    try {
      final target = await store.defaultDownloadDirectory();
      final count = await store.downloadEntries(tab, entries, localDir: target);
      if (count == 0) return;
      if (!mounted) return;
      _toastWithReveal('开始下载 $count 项 → ${_shortPath(target)}', target);
    } catch (error) {
      if (!mounted) return;
      _toast('下载失败：${describeError(error)}');
    }
  }

  /// 下载到用户自选目录。沙盒下先探测可写性，不可写则回退到 ~/Downloads。
  Future<void> _downloadAs(List<RemoteEntry> entries) async {
    if (entries.isEmpty) return;
    final store = context.read<AppStore>();
    final target = await FilePicker.getDirectoryPath(dialogTitle: '选择保存位置');
    if (target == null || target.isEmpty) return;

    final problem = await LocalIo.probeWritable(target);
    if (problem != null) {
      if (!mounted) return;
      _toast('该位置不可写（$problem），已改为下载到 ~/Downloads');
      await _download(entries);
      return;
    }

    try {
      final count = await store.downloadEntries(tab, entries, localDir: target);
      if (count == 0) return;
      if (!mounted) return;
      _toastWithReveal('开始下载 $count 项 → ${_shortPath(target)}', target);
    } catch (error) {
      if (!mounted) return;
      _toast('下载失败：${describeError(error)}');
    }
  }

  static String _shortPath(String path) {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty && path.startsWith(home)) {
      return '~${path.substring(home.length)}';
    }
    return path;
  }

  Future<void> _createFolder({String? remoteDir}) async {
    final store = context.read<AppStore>();
    final name = await showPromptDialog(
      context,
      title: '新建文件夹',
      description: remoteDir == null ? null : '位置：$remoteDir',
      hintText: '文件夹名称',
      confirmText: '创建',
    );
    if (name == null || name.trim().isEmpty) return;
    if (!mounted) return;
    try {
      if (remoteDir == null) {
        await store.sftpMkdir(tab, name);
      } else {
        await tab.session.mkdir(RemotePath.join(remoteDir, name.trim()));
        store.invalidateTree(tab, remoteDir);
        await store.sftpOpen(tab);
      }
    } catch (error) {
      if (!mounted) return;
      _toast('创建失败：$error');
    }
  }

  Future<void> _rename(RemoteEntry entry) async {
    final store = context.read<AppStore>();
    final name = await showPromptDialog(
      context,
      title: entry.isDir ? '重命名文件夹' : '重命名文件',
      description: RemotePath.join(tab.sftp.path, entry.name),
      initialValue: entry.name,
      confirmText: '重命名',
    );
    if (name == null || name.trim().isEmpty) return;
    if (!mounted) return;
    try {
      await store.sftpRename(tab, entry, name);
    } catch (error) {
      if (!mounted) return;
      _toast('重命名失败：$error');
    }
  }

  Future<void> _delete(List<RemoteEntry> entries) async {
    if (entries.isEmpty) return;
    final store = context.read<AppStore>();
    final label = entries.length == 1
        ? '「${entries.first.name}」'
        : '选中的 ${entries.length} 个项目';
    final confirmed = await showConfirmDialog(
      context,
      title: '删除远端内容',
      message: '将永久删除 $label，文件夹会连同内部所有内容一起删除。该操作不可撤销。',
      confirmText: '删除',
      danger: true,
    );
    if (!confirmed) return;
    if (!mounted) return;
    try {
      if (tab.fileView.isOpen &&
          entries.any(
            (entry) => tab.fileView.path ==
                RemotePath.join(tab.sftp.path, entry.name),
          )) {
        store.closeFileViewer(tab);
      }
      await store.sftpDelete(tab, entries);
      setState(() => _selected.clear());
      _toast('已删除');
    } catch (error) {
      if (!mounted) return;
      _toast('删除失败：$error');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(_snackBar(message));
  }

  /// 带「打开文件夹」动作的提示，下载入队后引导用户去看结果
  void _toastWithReveal(String message, String path) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      _snackBar(
        message,
        actionLabel: '打开文件夹',
        action: () => LocalIo.revealInFinder(path),
      ),
    );
  }

  // -------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final state = tab.sftp;
    final view = tab.fileView;

    if (state.path != _lastPath) {
      _lastPath = state.path;
      _selected.clear();
    }

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (details) async {
          setState(() => _dragging = false);
          final paths = details.files
              .map((file) => file.path)
              .where((path) => path.isNotEmpty)
              .toList();
          if (paths.isEmpty) return;
          await store.uploadPaths(tab, paths);
          if (!mounted) return;
          _toast('已加入上传队列');
        },
        child: Stack(
          children: [
            Column(
              children: [
                _header(store, view),
                if (!view.isOpen) _pathBar(store),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: view.isOpen
                        ? _FileViewer(
                            key: ValueKey('viewer-${view.path}'),
                            tab: tab,
                            view: view,
                            onBack: () => store.closeFileViewer(tab),
                          )
                        : Row(
                            children: [
                              if (_showTree) ...[
                                _DirectoryTree(tab: tab),
                                const VerticalDivider(
                                  width: 1,
                                  thickness: 1,
                                  color: AppColors.border,
                                ),
                              ],
                              Expanded(child: _listColumn(store, state)),
                            ],
                          ),
                  ),
                ),
                if (!view.isOpen) _footer(store),
              ],
            ),
            if (_dragging)
              Container(
                color: AppColors.accent.withValues(alpha: 0.06),
                alignment: Alignment.center,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.accent),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.file_upload_outlined,
                        size: 16,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        view.isOpen
                            ? '松开以上传到 ${RemotePath.baseName(state.path)}'
                            : '松开以上传到当前目录',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.accentDeep,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _header(AppStore store, FileViewState view) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.folder_open_outlined,
            size: 15,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 7),
          const Text(
            '文件',
            style: TextStyle(
              fontSize: 12.8,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(width: 8),
          if (!view.isOpen && tab.sftp.path.isNotEmpty)
            Flexible(
              child: Text(
                tab.sftp.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.tertiary,
              ),
            ),
          const Spacer(),
          if (!view.isOpen) ...[
            AppIconButton(
              icon: Icons.account_tree_outlined,
              tooltip: _showTree ? '隐藏目录树' : '显示目录树',
              active: _showTree,
              iconColor: const Color(0xFF5B8DEF),
              onPressed: () => setState(() => _showTree = !_showTree),
            ),
            AppIconButton(
              icon: Icons.upload_file_outlined,
              tooltip: '上传文件',
              iconColor: const Color(0xFF12A150),
              onPressed: () => _uploadFiles(),
            ),
            AppIconButton(
              icon: Icons.drive_folder_upload_outlined,
              tooltip: '上传文件夹',
              iconColor: const Color(0xFF0E9888),
              onPressed: () => _uploadFolder(),
            ),
            AppIconButton(
              icon: Icons.create_new_folder_outlined,
              tooltip: '新建文件夹',
              iconColor: const Color(0xFFE0A02E),
              onPressed: () => _createFolder(),
            ),
            AppIconButton(
              icon: store.settings.showHiddenFiles
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              tooltip: store.settings.showHiddenFiles ? '隐藏点文件' : '显示点文件',
              active: store.settings.showHiddenFiles,
              iconColor: const Color(0xFF9B6BE0),
              onPressed: () => store.updateSettings(
                showHiddenFiles: !store.settings.showHiddenFiles,
              ),
            ),
            AppIconButton(
              icon: Icons.refresh,
              tooltip: '刷新',
              iconColor: const Color(0xFF2F9BD8),
              onPressed: () => store.sftpOpen(tab),
            ),
          ],
          AppIconButton(
            icon: Icons.close,
            tooltip: '收起面板',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _pathBar(AppStore store) {
    final state = tab.sftp;
    if (state.path.isEmpty) return const SizedBox(height: 6);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
      decoration: const BoxDecoration(
        color: AppColors.canvas,
        border: Border(bottom: BorderSide(color: AppColors.borderSoft)),
      ),
      child: Row(
        children: [
          AppIconButton(
            icon: Icons.arrow_upward,
            tooltip: '上一级',
            size: 24,
            iconSize: 14,
            onPressed: state.path == '/'
                ? null
                : () => store.sftpOpenParent(tab),
          ),
          AppIconButton(
            icon: Icons.home_outlined,
            tooltip: '主目录',
            size: 24,
            iconSize: 14,
            onPressed: tab.session.homeDirectory == null
                ? null
                : () => store.sftpOpen(tab, path: tab.session.homeDirectory),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children: [
                  for (final crumb in RemotePath.breadcrumbs(state.path)) ...[
                    GestureDetector(
                      onTap: () => store.sftpOpen(tab, path: crumb.path),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          color: crumb.path == state.path
                              ? AppColors.accentSoft
                              : Colors.transparent,
                        ),
                        child: Text(
                          crumb.label,
                          style: TextStyle(
                            fontSize: 12,
                            color: crumb.path == state.path
                                ? AppColors.accentDeep
                                : AppColors.textSecondary,
                            fontWeight: crumb.path == state.path
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                    // 根目录的标签本身就是「/」，后面不能再拼分隔符，
                    // 否则会渲染成「/ / var」
                    if (crumb.path != state.path && crumb.path != '/')
                      const Text(
                        '/',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textTertiary,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          AppIconButton(
            icon: Icons.content_copy,
            tooltip: '复制当前路径',
            size: 24,
            iconSize: 13,
            onPressed: () => copyWithToast(context, state.path),
          ),
        ],
      ),
    );
  }

  Widget _listColumn(AppStore store, SftpViewState state) {
    return Column(
      children: [
        _tableHeader(),
        Expanded(child: _body(store, state)),
      ],
    );
  }

  Widget _tableHeader() {
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.borderSoft)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showMode = constraints.maxWidth >= 420;
          final showTime = constraints.maxWidth >= 320;
          return Row(
            children: [
              const Expanded(child: Text('名称', style: _headerStyle)),
              const SizedBox(
                width: 70,
                child: Text(
                  '大小',
                  textAlign: TextAlign.right,
                  style: _headerStyle,
                ),
              ),
              if (showTime)
                const SizedBox(
                  width: 112,
                  child: Text(
                    '修改时间',
                    textAlign: TextAlign.right,
                    style: _headerStyle,
                  ),
                ),
              if (showMode)
                const SizedBox(
                  width: 92,
                  child: Text(
                    '权限',
                    textAlign: TextAlign.right,
                    style: _headerStyle,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _body(AppStore store, SftpViewState state) {
    if (!tab.isConnected) {
      return const EmptyHint(
        icon: Icons.link_off,
        title: '连接不可用',
        description: '重新连接后即可浏览远端文件',
      );
    }
    if (state.loading && !state.ready) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (state.error != null) {
      return EmptyHint(
        icon: Icons.error_outline,
        title: '无法读取目录',
        description: state.error,
        action: OutlinedButton(
          onPressed: () => store.sftpOpen(tab),
          child: const Text('重试'),
        ),
      );
    }

    final entries = state.visibleEntries(store.settings.showHiddenFiles);
    if (entries.isEmpty) {
      return const EmptyHint(
        icon: Icons.folder_off_outlined,
        title: '目录为空',
        description: '可以拖拽文件到此处上传',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final showMode = constraints.maxWidth >= 420;
        final showTime = constraints.maxWidth >= 320;
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 2),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            return _FileRow(
              entry: entry,
              selected: _selected.contains(entry.name),
              opened: tab.fileView.path ==
                  RemotePath.join(tab.sftp.path, entry.name),
              showTime: showTime,
              showMode: showMode,
              onTap: () {
                if (entry.isDir || _modifierPressed) {
                  _toggleSelection(entry.name, additive: _modifierPressed);
                } else {
                  _openEntry(entry);
                }
              },
              onDoubleTap: () {
                if (entry.isDir) {
                  _openEntry(entry);
                } else {
                  _download([entry]);
                }
              },
              onContextMenu: (position) => _showRowMenu(position, entry),
            );
          },
        );
      },
    );
  }

  Widget _footer(AppStore store) {
    final selected = _selectedEntries.length;
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              selected == 0
                  ? '点击文件查看内容 · 双击目录进入 · 右键更多操作'
                  : '已选中 $selected 项',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.tertiary,
            ),
          ),
          if (selected > 0) ...[
            TextButton.icon(
              onPressed: () => _download(_selectedEntries),
              icon: const Icon(Icons.download_outlined, size: 15),
              label: const Text('下载'),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
            TextButton.icon(
              onPressed: () => _delete(_selectedEntries),
              icon: const Icon(Icons.delete_outline, size: 15),
              label: const Text('删除'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.danger,
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showRowMenu(Offset position, RemoteEntry entry) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final entryPath = RemotePath.join(tab.sftp.path, entry.name);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (entry.isDir)
          const PopupMenuItem(value: 'enter', height: 34, child: Text('打开目录'))
        else ...[
          const PopupMenuItem(
            value: 'view',
            height: 34,
            child: Text('查看内容'),
          ),
          const PopupMenuItem(
            value: 'edit',
            height: 34,
            child: Text('编辑文件'),
          ),
        ],
        const PopupMenuItem(
          value: 'download',
          height: 34,
          child: Text('下载到 ~/Downloads'),
        ),
        const PopupMenuItem(
          value: 'downloadAs',
          height: 34,
          child: Text('下载到…（选择位置）'),
        ),
        if (entry.isDir) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'upload',
            height: 34,
            child: Text('上传文件到此处'),
          ),
          const PopupMenuItem(
            value: 'newfolder',
            height: 34,
            child: Text('在此新建文件夹'),
          ),
        ],
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'rename', height: 34, child: Text('重命名')),
        const PopupMenuItem(
          value: 'copy',
          height: 34,
          child: Text('复制远端路径'),
        ),
        const PopupMenuItem(
          value: 'delete',
          height: 34,
          child: Text('删除', style: TextStyle(color: AppColors.danger)),
        ),
      ],
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'enter':
        await _openEntry(entry);
      case 'view':
        await context.read<AppStore>().openFileViewer(tab, entry);
      case 'edit':
        final store = context.read<AppStore>();
        await store.openFileViewer(tab, entry);
        if (!mounted) return;
        store.startEditFile(tab);
      case 'download':
        await _download([entry]);
      case 'downloadAs':
        await _downloadAs([entry]);
      case 'upload':
        await _uploadFiles(remoteDir: entryPath);
      case 'newfolder':
        await _createFolder(remoteDir: entryPath);
      case 'rename':
        await _rename(entry);
      case 'copy':
        await copyWithToast(context, entryPath);
      case 'delete':
        await _delete([entry]);
    }
  }
}

const _headerStyle = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w600,
  color: AppColors.textTertiary,
);

/// 左侧目录树
class _DirectoryTree extends StatelessWidget {
  const _DirectoryTree({required this.tab});

  final TerminalTab tab;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final home = tab.session.homeDirectory;

    final roots = <({String label, String path})>[
      (label: '文件系统', path: '/'),
      if (home != null && home.isNotEmpty && home != '/')
        (label: '主目录', path: home),
    ];

    return Container(
      width: 190,
      color: AppColors.canvas,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: [
          for (final root in roots) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
              child: Text(
                root.label,
                style: const TextStyle(
                  fontSize: 10.5,
                  letterSpacing: 0.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textTertiary,
                ),
              ),
            ),
            _TreeNode(
              tab: tab,
              path: root.path,
              label: root.path,
              depth: 0,
              isRoot: true,
            ),
            ..._children(store, root.path, 1),
          ],
        ],
      ),
    );
  }

  List<Widget> _children(AppStore store, String path, int depth) {
    final tree = tab.tree;
    final children = tree.children[path];
    if (children == null) return const [];

    final widgets = <Widget>[];
    for (final name in children) {
      final childPath = RemotePath.join(path, name);
      widgets.add(
        _TreeNode(
          tab: tab,
          path: childPath,
          label: name,
          depth: depth,
          isRoot: false,
        ),
      );
      if (tree.isExpanded(childPath)) {
        widgets.addAll(_children(store, childPath, depth + 1));
      }
    }
    return widgets;
  }
}

class _TreeNode extends StatelessWidget {
  const _TreeNode({
    required this.tab,
    required this.path,
    required this.label,
    required this.depth,
    required this.isRoot,
  });

  final TerminalTab tab;
  final String path;
  final String label;
  final int depth;
  final bool isRoot;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final tree = tab.tree;
    final expanded = tree.isExpanded(path);
    final loading = tree.isLoading(path);
    final current = tab.sftp.path == path;

    // 已展开但尚未加载 → 下一帧拉取子目录
    if (expanded && !loading && !tree.children.containsKey(path)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) store.treeLoad(tab, path);
      });
    }

    return _TreeRow(
      depth: depth,
      label: label,
      expanded: expanded,
      loading: loading,
      current: current,
      onToggle: () => store.treeToggle(tab, path),
      onTap: () => store.sftpOpen(tab, path: path),
    );
  }
}

class _TreeRow extends StatefulWidget {
  const _TreeRow({
    required this.depth,
    required this.label,
    required this.expanded,
    required this.loading,
    required this.current,
    required this.onToggle,
    required this.onTap,
  });

  final int depth;
  final String label;
  final bool expanded;
  final bool loading;
  final bool current;
  final VoidCallback onToggle;
  final VoidCallback onTap;

  @override
  State<_TreeRow> createState() => _TreeRowState();
}

class _TreeRowState extends State<_TreeRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final background = widget.current
        ? AppColors.accentSoft
        : (_hover ? Colors.black.withValues(alpha: 0.04) : Colors.transparent);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 24,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: EdgeInsets.only(left: 2 + widget.depth * 12, right: 6),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              GestureDetector(
                onTap: widget.onToggle,
                child: SizedBox(
                  width: 16,
                  height: 24,
                  child: widget.loading
                      ? const Center(
                          child: SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(strokeWidth: 1.4),
                          ),
                        )
                      : Icon(
                          widget.expanded
                              ? Icons.keyboard_arrow_down
                              : Icons.keyboard_arrow_right,
                          size: 15,
                          color: AppColors.textTertiary,
                        ),
                ),
              ),
              Icon(
                widget.expanded ? Icons.folder_open : Icons.folder,
                size: 14,
                color: widget.current
                    ? AppColors.accent
                    : const Color(0xFFE0A02E),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.2,
                    fontWeight: widget.current
                        ? FontWeight.w600
                        : FontWeight.w400,
                    color: widget.current
                        ? AppColors.accentDeep
                        : AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 文件内容查看 / 编辑
class _FileViewer extends StatefulWidget {
  const _FileViewer({
    super.key,
    required this.tab,
    required this.view,
    required this.onBack,
  });

  final TerminalTab tab;
  final FileViewState view;
  final VoidCallback onBack;

  @override
  State<_FileViewer> createState() => _FileViewerState();
}

class _FileViewerState extends State<_FileViewer> {
  final TextEditingController _controller = TextEditingController();

  FileViewState get view => widget.view;

  @override
  void initState() {
    super.initState();
    _controller.text = view.content;
  }

  @override
  void didUpdateWidget(_FileViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (view.path != oldWidget.view.path ||
        (!view.editing && _controller.text != view.content)) {
      _controller.text = view.content;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final store = context.read<AppStore>();
    await store.saveFileContent(widget.tab, _controller.text);
  }

  Future<void> _back() async {
    final store = context.read<AppStore>();
    if (view.editing && view.dirty) {
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
            backgroundColor: AppColors.surface,
            surfaceTintColor: Colors.transparent,
          title: const Text('尚未保存', style: AppText.h1),
          content: Text(
            '「${view.name}」有未保存的修改，如何处理？',
            style: AppText.secondary,
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop('cancel'),
              child: const Text('继续编辑'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('discard'),
              child: const Text('放弃修改'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop('save'),
              child: const Text('保存并返回'),
            ),
          ],
        ),
      );
      if (!mounted || choice == null || choice == 'cancel') return;
      if (choice == 'save') {
        await store.saveFileContent(widget.tab, _controller.text);
        if (!mounted) return;
      }
    }
    widget.onBack();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Column(
      children: [
        _toolbar(store),
        if (view.error != null) _banner(view.error!, AppColors.danger),
        if (view.binary) _banner('疑似二进制文件，下方为原始文本，编辑可能导致内容损坏', AppColors.warning),
        if (view.truncated) _banner('文件较大，仅显示前 1 MB 内容', AppColors.warning),
        Expanded(child: _content(store)),
      ],
    );
  }

  Widget _toolbar(AppStore store) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: AppColors.canvas,
        border: Border(bottom: BorderSide(color: AppColors.borderSoft)),
      ),
      child: Row(
        children: [
          AppIconButton(
            icon: Icons.arrow_back,
            tooltip: '返回文件列表',
            size: 26,
            iconSize: 15,
            onPressed: _back,
          ),
          const SizedBox(width: 6),
          const Icon(
            Icons.description_outlined,
            size: 14,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              view.name ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${RemoteEntry.formatSize(view.size)} · ${view.lineCount} 行',
            style: AppText.tertiary,
          ),
          if (view.dirty) ...[
            const SizedBox(width: 8),
            const Pill(
              text: '未保存',
              foreground: AppColors.warning,
              background: Color(0xFFFDF4E3),
            ),
          ],
          const Spacer(),
          if (view.editing) ...[
            TextButton(
              onPressed: () => store.cancelEditFile(widget.tab),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('取消编辑'),
            ),
            FilledButton(
              onPressed: view.saving ? null : _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Text(view.saving ? '保存中…' : '保存'),
            ),
            const SizedBox(width: 4),
          ] else
            AppIconButton(
              icon: Icons.edit_outlined,
              tooltip: '编辑内容',
              onPressed: view.loading
                  ? null
                  : () => store.startEditFile(widget.tab),
            ),
          AppIconButton(
            icon: Icons.refresh,
            tooltip: '重新读取',
            onPressed: view.loading
                ? null
                : () => store.refreshFileViewer(widget.tab),
          ),
          AppIconButton(
            icon: Icons.download_outlined,
            tooltip: '下载到 ~/Downloads',
            onPressed: () async {
              final entries = widget.tab.sftp.entries
                  .where((entry) => entry.name == view.name)
                  .toList();
              if (entries.isEmpty) return;
              final messenger = ScaffoldMessenger.maybeOf(context);
              try {
                final dir = await store.defaultDownloadDirectory();
                final count = await store.downloadEntries(
                  widget.tab,
                  entries,
                  localDir: dir,
                );
                if (count == 0) return;
                messenger?.showSnackBar(
                  _snackBar('已开始下载 ${view.name}', actionLabel: '打开文件夹', action: () => LocalIo.revealInFinder(dir)),
                );
              } catch (error) {
                messenger?.showSnackBar(
                  _snackBar('下载失败：${describeError(error)}'),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _banner(String message, Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: color.withValues(alpha: 0.08),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 13, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 11.5, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(AppStore store) {
    if (view.loading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (view.error != null && view.content.isEmpty) {
      return EmptyHint(
        icon: Icons.error_outline,
        title: '无法读取文件',
        description: view.error,
        action: OutlinedButton(
          onPressed: () => store.refreshFileViewer(widget.tab),
          child: const Text('重试'),
        ),
      );
    }

    if (view.editing) {
      return Container(
        color: AppColors.surface,
        padding: const EdgeInsets.all(10),
        child: TextField(
          controller: _controller,
          maxLines: null,
          expands: true,
          autofocus: true,
          style: AppText.mono.copyWith(
            fontSize: 12.3,
            color: AppColors.textPrimary,
          ),
          decoration: const InputDecoration(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            hintText: '文件内容为空',
          ),
        ),
      );
    }

    if (view.content.isEmpty) {
      return const EmptyHint(
        icon: Icons.insert_drive_file_outlined,
        title: '空文件',
        description: '这个文件没有任何内容',
      );
    }

    return Container(
      color: AppColors.surface,
      width: double.infinity,
      child: _FileTextBody(content: view.content),
    );
  }
}

/// 文件正文：按行虚拟化渲染。
///
/// 之前是 SingleChildScrollView + 一个 SelectableText 装整份文件，
/// 1MB 文本会被排版成单个巨型段落（与容器日志花屏同源的隐患：
/// 图层过大 + 每次滚动都要重排整段）。改成按行 ListView.builder，
/// 只排版可见的几十行，滚动、选中照常；行内容不做任何截断。
class _FileTextBody extends StatefulWidget {
  const _FileTextBody({required this.content});

  final String content;

  @override
  State<_FileTextBody> createState() => _FileTextBodyState();
}

class _FileTextBodyState extends State<_FileTextBody> {
  List<String> _lines = const [];

  /// 拿到 SelectionArea 的状态，供「全选复制」一键操作。
  final GlobalKey<SelectableRegionState> _selectionKey =
      GlobalKey<SelectableRegionState>();

  /// 选区内容随 onSelectionChanged 实时更新；全选后从这里取全文。
  SelectedContent? _selectedContent;

  @override
  void initState() {
    super.initState();
    _lines = _splitLines(widget.content);
  }

  @override
  void didUpdateWidget(_FileTextBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.content, widget.content)) {
      _lines = _splitLines(widget.content);
    }
  }

  /// 全选 + 复制，一键完成。
  ///
  /// 不让用户拖着选的原因：正文按行虚拟化渲染，滚出视口的行会被销毁，
  /// SelectionArea 对已回收行的选区不保留——长文件拖选必然「选着选着
  /// 上面就没了」。一键全选绕开这条路径。
  void _selectAllAndCopy() {
    final region = _selectionKey.currentState;
    if (region == null) return;
    // selectAll 会在同步链路里回调 onSelectionChanged，随后即可取全文
    region.selectAll(SelectionChangedCause.keyboard);
    final text = _selectedContent?.plainText ?? '';
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制全部内容（${_lines.length} 行）'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  static List<String> _splitLines(String content) {
    final lines = content.split('\n');
    // 末尾换行会多出一个空串，去掉它避免行尾空一行
    if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      key: _selectionKey,
      onSelectionChanged: (content) => _selectedContent = content,
      child: Column(
        children: [
          // 工具行：一键全选复制。拖选在可视范围内可用，但跨屏选择受
          // 虚拟化限制（行被回收后选区丢失），所以这里提供一键操作。
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton.icon(
                  onPressed: _selectAllAndCopy,
                  icon: const Icon(Icons.copy_all_outlined, size: 15),
                  label: const Text('全选复制', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF2F6BFF),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_lines.length} 行 · 跨屏拖选会丢失已滚出视口的部分，长文件建议用此按钮',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF8A93A6)),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
              itemCount: _lines.length,
              itemBuilder: (context, index) {
                return Text(
                  _lines[index],
                  style: AppText.mono.copyWith(
                    fontSize: 12.3,
                    height: 1.5,
                    color: AppColors.textPrimary,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FileRow extends StatefulWidget {
  const _FileRow({
    required this.entry,
    required this.selected,
    required this.opened,
    required this.showTime,
    required this.showMode,
    required this.onTap,
    required this.onDoubleTap,
    required this.onContextMenu,
  });

  final RemoteEntry entry;
  final bool selected;
  final bool opened;
  final bool showTime;
  final bool showMode;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final void Function(Offset position) onContextMenu;

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final background = widget.opened
        ? AppColors.accentSoft
        : widget.selected
        ? AppColors.accentSoft
        : (_hover ? AppColors.canvas : Colors.transparent);

    final icon = entry.isDir ? Icons.folder : _fileIcon(entry.name);
    final iconColor = entry.isDir
        ? const Color(0xFFE0A02E)
        : AppColors.textTertiary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        onSecondaryTapDown: (details) =>
            widget.onContextMenu(details.globalPosition),
        child: Container(
          height: 27,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: background,
          child: Row(
            children: [
              Icon(icon, size: 14, color: iconColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.3,
                    color: AppColors.textPrimary,
                    fontWeight: widget.opened || widget.selected
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
              if (entry.isLink)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: Icon(
                    Icons.link,
                    size: 12,
                    color: AppColors.textTertiary,
                  ),
                ),
              SizedBox(
                width: 70,
                child: Text(
                  entry.readableSize,
                  textAlign: TextAlign.right,
                  style: AppText.tertiary,
                ),
              ),
              if (widget.showTime)
                SizedBox(
                  width: 112,
                  child: Text(
                    entry.readableModified,
                    textAlign: TextAlign.right,
                    style: AppText.tertiary,
                  ),
                ),
              if (widget.showMode)
                SizedBox(
                  width: 92,
                  child: Text(
                    entry.mode,
                    textAlign: TextAlign.right,
                    style: AppText.mono.copyWith(fontSize: 11),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

IconData _fileIcon(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.svg') ||
      lower.endsWith('.webp')) {
    return Icons.image_outlined;
  }
  if (lower.endsWith('.zip') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.gz') ||
      lower.endsWith('.tgz') ||
      lower.endsWith('.rar') ||
      lower.endsWith('.7z')) {
    return Icons.archive_outlined;
  }
  if (lower.endsWith('.sh') ||
      lower.endsWith('.yml') ||
      lower.endsWith('.yaml') ||
      lower.endsWith('.json') ||
      lower.endsWith('.conf') ||
      lower.endsWith('.log') ||
      lower.endsWith('.md')) {
    return Icons.description_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

/// 统一的轻量提示条：深色悬浮，带可选动作按钮
SnackBar _snackBar(
  String message, {
  VoidCallback? action,
  String? actionLabel,
}) {
  return SnackBar(
    content: Text(message, style: const TextStyle(fontSize: 12.5)),
    behavior: SnackBarBehavior.floating,
    width: action == null ? 320 : 380,
    duration: Duration(seconds: action == null ? 2 : 4),
    backgroundColor: const Color(0xFF232A35),
    action: action == null
        ? null
        : SnackBarAction(
            label: actionLabel ?? '确定',
            textColor: AppColors.accent,
            onPressed: action,
          ),
  );
}
