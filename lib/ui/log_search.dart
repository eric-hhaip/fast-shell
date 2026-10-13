import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../services/log_text.dart';

/// 日志查看区（深色终端）的配色，与 monitor_panel 的全屏日志视图一致。
class _LogUi {
  const _LogUi._();

  static const bg = Color(0xFF101B2E);
  static const border = Color(0xFF23324A);
  static const text = Color(0xFFDCE5F2);
  static const muted = Color(0xFF6B7686);
  static const accent = Color(0xFF2F6BFF);
  static const danger = Color(0xFFFF6B6B);

  /// 搜索高亮：普通命中偏淡，当前命中更深并描边，避免抢走正文的可读性
  static const hit = Color(0xFFFFD54F);
  static const hitActive = Color(0xFFFFB020);
}

/// 测量终端单元格尺寸——与 xterm 内部 `calcCharSize` 完全同款
/// （量 10 个 `m` 的最大固有宽度，高度取段落高度）。
///
/// 搜索高亮的坐标换算与「滚动到某一行」都以这份尺寸为准；一旦和 xterm
/// 自己用的尺寸不一致，高亮就会逐行偏移，越往下越明显。
Size measureTerminalCell(BuildContext context, TerminalStyle style) {
  const probe = 'mmmmmmmmmm';
  final base = style.toTextStyle();
  final scaler = MediaQuery.textScalerOf(context);
  final builder = ui.ParagraphBuilder(base.getParagraphStyle());
  builder.pushStyle(base.getTextStyle(textScaler: scaler));
  builder.addText(probe);
  final paragraph = builder.build();
  paragraph.layout(const ui.ParagraphConstraints(width: double.infinity));
  return Size(paragraph.maxIntrinsicWidth / probe.length, paragraph.height);
}

/// 日志搜索栏：关键字输入 + 命中计数 + 上一个 / 下一个。
///
/// 键盘：`Enter` 下一个、`Shift+Enter` 上一个、`Esc` 关闭。
class LogSearchBar extends StatelessWidget {
  const LogSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.matchCount,
    required this.currentIndex,
    required this.onChanged,
    required this.onStep,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final int matchCount;

  /// 当前命中下标；-1 表示尚未定位
  final int currentIndex;

  final ValueChanged<String> onChanged;
  final void Function(int delta) onStep;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final query = controller.text;
    final counter = query.isEmpty
        ? ''
        : matchCount == 0
        ? '无匹配'
        : '${currentIndex + 1}/$matchCount';

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, shift: true): () =>
            onStep(-1),
        const SingleActivator(LogicalKeyboardKey.escape): onClose,
      },
      child: Container(
        height: 38,
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: const BoxDecoration(
          color: _LogUi.bg,
          border: Border(bottom: BorderSide(color: _LogUi.border)),
        ),
        child: Row(
          children: [
            const Icon(Icons.search, size: 14, color: _LogUi.muted),
            const SizedBox(width: 7),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: _LogUi.text,
                  fontFamily: 'SF Mono',
                  fontFamilyFallback: ['Menlo', 'monospace'],
                ),
                cursorColor: _LogUi.accent,
                cursorHeight: 14,
                decoration: const InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 9),
                  hintText: '搜索日志关键字',
                  hintStyle: TextStyle(fontSize: 12.5, color: _LogUi.muted),
                ),
                onChanged: onChanged,
                onSubmitted: (_) => onStep(1),
              ),
            ),
            if (counter.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                counter,
                style: TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'SF Mono',
                  fontFamilyFallback: const ['Menlo', 'monospace'],
                  color: matchCount == 0 ? _LogUi.danger : _LogUi.muted,
                ),
              ),
            ],
            const SizedBox(width: 4),
            _SearchIconButton(
              icon: Icons.keyboard_arrow_up,
              tooltip: '上一个（Shift+Enter）',
              onPressed: matchCount > 0 ? () => onStep(-1) : null,
            ),
            _SearchIconButton(
              icon: Icons.keyboard_arrow_down,
              tooltip: '下一个（Enter）',
              onPressed: matchCount > 0 ? () => onStep(1) : null,
            ),
            _SearchIconButton(
              icon: Icons.close,
              tooltip: '关闭搜索（Esc）',
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchIconButton extends StatelessWidget {
  const _SearchIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkResponse(
        onTap: onPressed,
        radius: 14,
        child: SizedBox(
          width: 26,
          height: 26,
          child: Icon(
            icon,
            size: 16,
            color: enabled ? _LogUi.text : _LogUi.muted.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

/// 搜索结果高亮层：叠在终端之上，把缓冲区里**所有命中**都标出来。
///
/// xterm 4.0 没有内置搜索高亮（只有单个选区），所以这里自绘一层矩形：
/// 行号 × 行高 − 滚动偏移 得到屏幕坐标，绘制全部落在可视区内的命中。
/// 用 [IgnorePointer] 包裹，不影响终端自身的选区与滚动交互。
class LogSearchHighlight extends StatefulWidget {
  const LogSearchHighlight({
    super.key,
    required this.terminal,
    required this.scrollController,
    required this.matches,
    required this.currentIndex,
    required this.textStyle,
    required this.padding,
  });

  final Terminal terminal;
  final ScrollController scrollController;
  final List<LogMatch> matches;
  final int currentIndex;
  final TerminalStyle textStyle;

  /// 与 TerminalView 使用的内边距一致（坐标换算要扣掉它）
  final EdgeInsets padding;

  @override
  State<LogSearchHighlight> createState() => _LogSearchHighlightState();
}

class _LogSearchHighlightState extends State<LogSearchHighlight> {
  Timer? _throttle;

  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_onTerminalChanged);
    widget.scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(LogSearchHighlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalChanged);
      widget.terminal.addListener(_onTerminalChanged);
    }
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _throttle?.cancel();
    widget.terminal.removeListener(_onTerminalChanged);
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (mounted) setState(() {});
  }

  /// 日志在追加（跟踪模式）时会滚动整个缓冲区，高亮位置随之变化；
  /// 与 _LogTail 同样做节流，避免高频日志把每帧都拿去重绘。
  void _onTerminalChanged() {
    if (_throttle != null) return;
    _throttle = Timer(const Duration(milliseconds: 250), () {
      _throttle = null;
      if (mounted) setState(() {});
    });
  }

  /// 与 xterm 内部 `calcCharSize` 完全相同的测量方式，否则高亮会和字格错位
  Size _measureCell() => measureTerminalCell(context, widget.textStyle);

  @override
  Widget build(BuildContext context) {
    final scroll = widget.scrollController;
    final offset = scroll.hasClients ? scroll.position.pixels : 0.0;
    return IgnorePointer(
      child: CustomPaint(
        painter: _HighlightPainter(
          matches: widget.matches,
          currentIndex: widget.currentIndex,
          cell: _measureCell(),
          scrollOffset: offset,
          padding: widget.padding,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// 绘制全部命中：只画可视区内的行，滚动再快也不会遍历全部匹配。
class _HighlightPainter extends CustomPainter {
  _HighlightPainter({
    required this.matches,
    required this.currentIndex,
    required this.cell,
    required this.scrollOffset,
    required this.padding,
  });

  final List<LogMatch> matches;
  final int currentIndex;
  final Size cell;
  final double scrollOffset;
  final EdgeInsets padding;

  @override
  void paint(Canvas canvas, Size size) {
    if (matches.isEmpty || cell.height <= 0 || cell.width <= 0) return;

    final lineHeight = cell.height;
    // 可视行范围（上下各多留一行，避免边缘漏画）
    final firstRow = ((scrollOffset - padding.top) / lineHeight).floor() - 1;
    final lastRow = firstRow + (size.height / lineHeight).ceil() + 2;

    final normalPaint = Paint()..color = _LogUi.hit.withValues(alpha: 0.16);
    final activePaint = Paint()
      ..color = _LogUi.hitActive.withValues(alpha: 0.38);
    final activeStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _LogUi.hitActive.withValues(alpha: 0.85);

    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      if (match.row < firstRow || match.row > lastRow) continue;

      final y = padding.top + match.row * lineHeight - scrollOffset;
      final x = padding.left + match.column * cell.width;
      final width = (match.length * cell.width).clamp(2.0, size.width);
      final rect = Rect.fromLTWH(x, y, width, lineHeight);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(2.5));

      final isActive = i == currentIndex;
      canvas.drawRRect(rrect, isActive ? activePaint : normalPaint);
      if (isActive) canvas.drawRRect(rrect, activeStroke);
    }
  }

  @override
  bool shouldRepaint(covariant _HighlightPainter old) {
    return old.scrollOffset != scrollOffset ||
        old.currentIndex != currentIndex ||
        !identical(old.matches, matches) ||
        old.cell != cell ||
        old.padding != padding;
  }
}
