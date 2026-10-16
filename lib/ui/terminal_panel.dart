import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../services/ssh_session.dart';
import '../state/app_store.dart';
import 'terminal_selection.dart';
import 'theme.dart';
import 'widgets/common.dart';

class TerminalPanel extends StatefulWidget {
  const TerminalPanel({super.key, required this.tab, required this.onClose});

  final TerminalTab tab;
  final VoidCallback onClose;

  @override
  State<TerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends State<TerminalPanel> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'terminal');

  // 交给 _SelectionAutoScroll，用它在拖拽选中时驱动视口滚动。
  // xterm 只有在拿到外部 scrollController 时才不会自己创建并销毁一个。
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _copySelection() async {
    final tab = widget.tab;
    final range = tab.terminalController.selection;
    if (range == null) return;
    final text = tab.terminal.buffer.getText(range);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    tab.terminalController.clearSelection();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    widget.tab.terminal.paste(text);
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final tab = widget.tab;
    final status = tab.status;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
            _copySelection,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true): _paste,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            store.clearTerminal(tab),
        const SingleActivator(LogicalKeyboardKey.equal, meta: true): () =>
            store.changeFontSize(1),
        const SingleActivator(LogicalKeyboardKey.minus, meta: true): () =>
            store.changeFontSize(-1),
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true):
            widget.onClose,
      },
      child: Column(
        children: [
          _toolbar(store, tab, status),
          Expanded(
            child: Container(
              color: AppColors.terminalBackdrop,
              child: Stack(
                children: [
                  Positioned.fill(
                    // 终端每来一段输出就重绘一次，用 RepaintBoundary 把它
                    // 和窗口其余部分隔开，避免牵连整页重绘
                    child: RepaintBoundary(
                      child: _SelectionAutoScroll(
                        terminal: tab.terminal,
                        controller: tab.terminalController,
                        scrollController: _scrollController,
                        focusNode: _focusNode,
                        theme: appTerminalTheme,
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                        textStyle: TerminalStyle(
                          fontSize: store.settings.fontSize,
                          height: 1.32,
                          fontFamily: 'SF Mono',
                          fontFamilyFallback: [
                            'Menlo',
                            'Monaco',
                            'PingFang SC',
                            'monospace',
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (status == SessionStatus.connecting)
                    const Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: _ProgressLine(),
                    ),
                ],
              ),
            ),
          ),
          _keyBar(tab),
        ],
      ),
    );
  }

  Widget _toolbar(AppStore store, TerminalTab tab, SessionStatus status) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      // 左侧的 状态点 / user@host / 状态文字 已删：与上方标签页完全重复，
      // 连接失败的原因会直接打印在终端里，重连入口保留在右侧。
      child: Row(
        children: [
          const Spacer(),
          if (status == SessionStatus.failed ||
              status == SessionStatus.closed) ...[
            TextButton.icon(
              onPressed: () => store.reconnectTab(tab),
              icon: const Icon(Icons.refresh, size: 15),
              label: const Text('重新连接'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.accent,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
              ),
            ),
            const SizedBox(width: 2),
          ],
          AppIconButton(
            icon: Icons.monitor_heart_outlined,
            tooltip: '服务器监控（⌘⇧M）',
            active: tab.showMonitor,
            iconColor: const Color(0xFF12B5A5),
            onPressed: () => store.toggleMonitor(tab),
          ),
          AppIconButton(
            icon: Icons.article_outlined,
            tooltip: 'SFTP 文件（⌘⇧F）',
            active: tab.showSftp,
            onPressed: () => store.toggleSftp(tab),
          ),
          AppIconButton(
            icon: Icons.keyboard_arrow_down,
            tooltip: '降低字号（⌘-）',
            onPressed: () => store.changeFontSize(-1),
          ),
          AppIconButton(
            icon: Icons.keyboard_arrow_up,
            tooltip: '提高字号（⌘+）',
            onPressed: () => store.changeFontSize(1),
          ),
          AppIconButton(
            icon: Icons.cleaning_services_outlined,
            tooltip: '清屏（⌘K）',
            onPressed: () => store.clearTerminal(tab),
          ),
          AppIconButton(
            icon: Icons.power_settings_new,
            tooltip: tab.isConnected ? '断开连接' : '关闭标签',
            danger: tab.isConnected,
            onPressed: () {
              if (tab.isConnected) {
                store.disconnectTab(tab);
              } else {
                widget.onClose();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _keyBar(TerminalTab tab) {
    Widget key(String label, String sequence, {String? tooltip}) {
      return _VirtualKey(
        label: label,
        tooltip: tooltip ?? label,
        onPressed: tab.isConnected
            ? () {
                tab.session.writeString(sequence);
                _focusNode.requestFocus();
              }
            : null,
      );
    }

    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          key('Esc', '\x1b'),
          key('Tab', '\t'),
          key('Ctrl+C', '\x03', tooltip: '发送中断信号'),
          key('Ctrl+D', '\x04', tooltip: '发送 EOF'),
          key('↑', '\x1b[A'),
          key('↓', '\x1b[B'),
          key('←', '\x1b[D'),
          key('→', '\x1b[C'),
          const Spacer(),
          Text('⌘K 清屏 · ⌘C/⌘V 复制粘贴 · ⌘W 关闭标签', style: AppText.tertiary),
          const SizedBox(width: 4),
          AppIconButton(
            icon: Icons.help_outline,
            tooltip: '快捷键说明',
            size: 24,
            iconSize: 14,
            onPressed: () => _showShortcuts(context),
          ),
        ],
      ),
    );
  }

  void _showShortcuts(BuildContext context) {
    const items = <(String, String)>[
      ('⌘ K', '清空终端显示与回滚缓冲'),
      ('⌘ C', '复制选中的文本'),
      ('⌘ V', '粘贴到终端'),
      ('⌘ +  /  ⌘ -', '调整终端字号'),
      ('⌘ ⇧ F', '打开 / 收起文件面板'),
      ('⌘ W', '关闭当前标签'),
      ('⌘ N', '新建连接'),
      ('⌘ R', '重新连接当前会话'),
      ('Esc / Tab', '发送转义与制表符'),
      ('Ctrl + C', '发送中断信号'),
    ];

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('快捷键', style: AppText.h1),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 104,
                        child: Text(
                          item.$1,
                          style: AppText.mono.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      Expanded(child: Text(item.$2, style: AppText.secondary)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

/// 终端选区自动滚动。
///
/// xterm 只在指针移动时重算选区（`RenderTerminal.selectCharacters`），自己从不
/// 滚动视口 —— 于是拖拽选中时鼠标一旦停在上/下边界外，视口纹丝不动，
/// 边界外的文本既看不见、也选不准。
///
/// 这里补上标准终端的行为：指针进入边界附近的感应区就逐行滚动，滚动后按
/// 「拖拽起点 + 当前指针位置」重算一次选区。xterm 换算行号用的是
/// 「指针位置 + 当前滚动偏移」，所以视口一滚，同一个指针位置自然对应新的一行。
class _SelectionAutoScroll extends StatefulWidget {
  const _SelectionAutoScroll({
    required this.terminal,
    required this.controller,
    required this.scrollController,
    required this.focusNode,
    required this.theme,
    required this.padding,
    required this.textStyle,
  });

  final Terminal terminal;
  final TerminalController controller;
  final ScrollController scrollController;
  final FocusNode focusNode;
  final TerminalTheme theme;
  final EdgeInsets padding;
  final TerminalStyle textStyle;

  @override
  State<_SelectionAutoScroll> createState() => _SelectionAutoScrollState();
}

class _SelectionAutoScrollState extends State<_SelectionAutoScroll> {
  /// 距上/下边界多少行开始滚动
  static const _edgeLines = 2.0;

  /// 滚动节拍：一行一行地滚，滚太快选区会跳
  static const _tick = Duration(milliseconds: 16);

  /// 每帧滚动的行数范围（≈ 7 行/秒 起步，≈ 54 行/秒 封顶）
  static const _minLinesPerTick = 0.12;
  static const _maxLinesPerTick = 0.9;

  final _viewKey = GlobalKey();

  Timer? _timer;
  int _direction = 0;

  /// 拖拽起点与当前指针位置（都是本 widget 的本地坐标）。
  /// 与 xterm 的 `DragStartBehavior.down` 对齐：起点取按下那一刻的位置。
  Offset? _dragStart;
  Offset? _pointer;

  /// 本次拖拽使用的单元格尺寸：按下时测一次、整个过程复用。
  /// 滚动步长和选区换算都用同一个值，天然自洽，也免去每次移动都量一遍排版。
  Size? _dragCellSize;

  /// 拖拽起点的绝对单元格坐标（buffer 行号），按下那一刻定格。
  /// 之后无论自动滚动把视口推到哪里，重算选区都以它为锚——
  /// 否则起点会用「固定视口坐标 + 当下 scrollOffset」重新换算，跟着滚动漂移，
  /// 往下拖时上半段选区就会消失（真实事故：2026-10-16 用户报告）。
  CellOffset? _dragStartOffset;

  /// 亚行精度的滚动累积器，低速时也能保证最终滚够整数行
  double _carry = 0;

  Size _boxSize = Size.zero;

  /// 单击不滚动：指针拖出这个距离才算「正在拖拽选区」
  static const _dragSlop = 6.0;

  bool get _isDragging {
    final start = _dragStart;
    final pointer = _pointer;
    if (start == null || pointer == null) return false;
    return (pointer - start).distance > _dragSlop;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------ 指针

  void _onPointerDown(PointerDownEvent event) {
    // 只认左键：右键是菜单、中键不用于选择
    if (event.buttons != kPrimaryMouseButton) return;
    _dragStart = event.localPosition;
    _pointer = event.localPosition;
    _dragCellSize = null;
    _carry = 0;
    // 起点立刻换算成 buffer 绝对坐标并定格（依赖按下时的 scrollOffset）
    _dragCellSize = _cellSize();
    _dragStartOffset = _absoluteOffset(event.localPosition, _dragCellSize!);
    _update();
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_dragStart == null) return;
    _pointer = event.localPosition;
    _update();
  }

  void _onPointerFinish(PointerEvent event) {
    if (_dragStart == null) return;
    _dragStart = null;
    _pointer = null;
    _dragCellSize = null;
    _dragStartOffset = null;
    _stop();
  }

  // ------------------------------------------------ 自动滚动

  void _update() {
    final start = _dragStart;
    final pointer = _pointer;
    if (start == null || pointer == null) return _stop();
    if (!_isDragging) return _stop(); // 单击不算拖拽，避免贴边点击就滚屏

    final size = _boxSize;
    if (size.isEmpty) return _stop();

    final cell = _dragCellSize ??= _cellSize();
    if (cell.height <= 0) return _stop();

    // 内容区：TerminalView.padding 是外层 Container 的内边距，
    // xterm 的绘制与命中都在这之内
    final top = widget.padding.top;
    final bottom = size.height - widget.padding.bottom;
    final margin = _edgeLines * cell.height;

    final dir = selectionScrollDirection(
      pointerY: pointer.dy,
      contentTop: top,
      contentBottom: bottom,
      edgePixels: margin,
    );

    if (dir == 0) return _stop();
    if (dir == _direction && _timer != null) return;

    _direction = dir;
    _carry = 0;
    _timer?.cancel();
    _step();
    _timer = Timer.periodic(_tick, (_) => _step());
  }

  void _step() {
    final dir = _direction;
    if (dir == 0) return;

    final scroll = widget.scrollController;
    if (!scroll.hasClients) return;
    final position = scroll.position;

    final cell = _dragCellSize;
    if (cell == null || cell.height <= 0) return;

    // 越靠边界（或越往边界外）滚得越快
    final lines =
        _minLinesPerTick +
        (_maxLinesPerTick - _minLinesPerTick) * _speedFactor();
    _carry += lines;

    final whole = _carry.floor();
    if (whole <= 0) return;
    _carry -= whole;

    final target = (position.pixels + dir * whole * cell.height).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < 0.5) return _stop(); // 已滚到头

    position.jumpTo(target);
    _reapplySelection(cell);
  }

  /// 越出边界的程度：0 = 刚进感应区（界内），1 = 出界超过一个感应区宽度
  double _speedFactor() {
    final pointer = _pointer;
    final cell = _dragCellSize;
    if (pointer == null || cell == null || cell.height <= 0) return 0;

    final size = _boxSize;
    if (size.isEmpty) return 0;

    return selectionScrollSpeedFactor(
      pointerY: pointer.dy,
      contentTop: widget.padding.top,
      contentBottom: size.height - widget.padding.bottom,
      edgePixels: _edgeLines * cell.height,
    );
  }

  /// 视口局部坐标 → buffer 绝对单元格坐标。
  /// 换算依赖取点当下的 scrollOffset，所以只在取点那一刻调用、
  /// 结果存住复用，不要在滚动之后再用旧坐标重复换算。
  CellOffset _absoluteOffset(Offset local, Size cell) {
    final safeArea = MediaQuery.of(context).padding;
    return CellOffset(
      selectionColumnFor(
        localX: local.dx,
        cellWidth: cell.width,
        paddingLeft: widget.padding.left,
        safeAreaLeft: safeArea.left,
        viewColumns: widget.terminal.viewWidth,
      ),
      selectionRowFor(
        localY: local.dy,
        cellHeight: cell.height,
        paddingTop: widget.padding.top,
        safeAreaTop: safeArea.top,
        scrollOffset: _scrollOffset(),
        bufferLines: widget.terminal.buffer.height,
      ),
    );
  }

  /// 按当前滚动位置重算选区：起点用按下时定格的绝对坐标（`_dragStartOffset`），
  /// 终点用当前指针位置实时换算——自动滚动只允许影响终点。
  void _reapplySelection(Size cell) {
    final startOffset = _dragStartOffset;
    final pointer = _pointer;
    if (startOffset == null || pointer == null) return;

    final safeArea = MediaQuery.of(context).padding;
    final toColumn = selectionColumnFor(
      localX: pointer.dx,
      cellWidth: cell.width,
      paddingLeft: widget.padding.left,
      safeAreaLeft: safeArea.left,
      viewColumns: widget.terminal.viewWidth,
    );
    final toRow = selectionRowFor(
      localY: pointer.dy,
      cellHeight: cell.height,
      paddingTop: widget.padding.top,
      safeAreaTop: safeArea.top,
      scrollOffset: _scrollOffset(),
      bufferLines: widget.terminal.buffer.height,
    );

    // 与 xterm 一致：向右拖时多含一个单元格
    final to = CellOffset(
      selectionExtentColumn(fromColumn: startOffset.x, toColumn: toColumn),
      toRow,
    );

    widget.controller.setSelection(
      widget.terminal.buffer.createAnchorFromOffset(startOffset),
      widget.terminal.buffer.createAnchorFromOffset(to),
    );
  }

  double _scrollOffset() {
    final scroll = widget.scrollController;
    if (!scroll.hasClients) return 0;
    return scroll.position.pixels;
  }

  /// 与 xterm 内部 `calcCharSize` 完全相同的测量方式，
  /// 否则「滚一行」和「选区移动一行」会对不上
  Size _cellSize() {
    const probe = 'mmmmmmmmmm';
    final base = widget.textStyle.toTextStyle();
    final scaler = MediaQuery.textScalerOf(context);
    final builder = ui.ParagraphBuilder(base.getParagraphStyle());
    builder.pushStyle(base.getTextStyle(textScaler: scaler));
    builder.addText(probe);
    final paragraph = builder.build();
    paragraph.layout(const ui.ParagraphConstraints(width: double.infinity));
    return Size(paragraph.maxIntrinsicWidth / probe.length, paragraph.height);
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _direction = 0;
    _carry = 0;
  }

  // ------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _boxSize = constraints.biggest;
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerFinish,
          onPointerCancel: _onPointerFinish,
          child: TerminalView(
            widget.terminal,
            key: _viewKey,
            controller: widget.controller,
            scrollController: widget.scrollController,
            focusNode: widget.focusNode,
            autofocus: true,
            theme: widget.theme,
            padding: widget.padding,
            textStyle: widget.textStyle,
          ),
        );
      },
    );
  }
}

class _VirtualKey extends StatefulWidget {
  const _VirtualKey({
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final String label;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  State<_VirtualKey> createState() => _VirtualKeyState();
}

class _VirtualKeyState extends State<_VirtualKey> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            margin: const EdgeInsets.only(right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _hover && enabled ? AppColors.canvas : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: AppColors.borderSoft),
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                fontFamily: 'SF Mono',
                fontFamilyFallback: const ['Menlo', 'monospace'],
                color: enabled
                    ? AppColors.textSecondary
                    : AppColors.textTertiary.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine();

  @override
  Widget build(BuildContext context) {
    return const LinearProgressIndicator(
      minHeight: 2,
      backgroundColor: Colors.transparent,
      color: AppColors.accent,
    );
  }
}
