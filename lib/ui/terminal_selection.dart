/// 终端选区自动滚动的纯计算部分。
///
/// 不 import Flutter —— 这样 `tool/verify.dart` 能在无 GUI 环境直接验证这些
/// 换算，界面层（terminal_panel.dart）只负责把指针位置、视口尺寸喂进来。
///
/// 背景见 `_SelectionAutoScroll` 的文档注释：xterm 只在指针移动时重算选区、
/// 自己从不滚动视口，拖拽选中时鼠标停在上下边界外就卡住。
library;

/// 指针在竖直方向上该往哪滚：-1 向上，1 向下，0 不滚。
///
/// [contentTop] / [contentBottom] 是终端绘制区（已扣掉外层 padding）的上下沿，
/// [edgePixels] 是「距边界多少像素开始滚」的感应区厚度。
int selectionScrollDirection({
  required double pointerY,
  required double contentTop,
  required double contentBottom,
  required double edgePixels,
}) {
  if (pointerY < contentTop + edgePixels) return -1;
  if (pointerY > contentBottom - edgePixels) return 1;
  return 0;
}

/// 滚动快慢的系数，取值 0 ~ 1：刚进感应区最慢，出界越远越快。
///
/// 贴边时故意压到 0.35 封顶 —— 用户贴着边界微调选区时，一眼一行才可控；
/// 出界之后才放开速度，长距离滚动不至于太磨人。
double selectionScrollSpeedFactor({
  required double pointerY,
  required double contentTop,
  required double contentBottom,
  required double edgePixels,
}) {
  if (edgePixels <= 0) return 1;

  // 已经出到边界外：越远越快，刚出界时从 0.35 起步
  if (pointerY < contentTop) {
    return ((contentTop - pointerY) / edgePixels + 0.35).clamp(0.0, 1.0);
  }
  if (pointerY > contentBottom) {
    return ((pointerY - contentBottom) / edgePixels + 0.35).clamp(0.0, 1.0);
  }

  // 还在界内、但落在感应区里：越贴近边界越快，最多到 0.35
  final fromTop = pointerY - contentTop;
  final fromBottom = contentBottom - pointerY;
  final near = fromTop < fromBottom ? fromTop : fromBottom;
  return ((1 - near / edgePixels) * 0.35).clamp(0.0, 1.0);
}

/// 指针所在的行号 —— 与 xterm `RenderTerminal.getCellOffset` 的行换算一致：
/// 「本地 y − 顶部留白 − 安全区 + 当前滚动偏移」再除以行高，并钳制到缓冲区范围。
int selectionRowFor({
  required double localY,
  required double cellHeight,
  required double paddingTop,
  required double safeAreaTop,
  required double scrollOffset,
  required int bufferLines,
}) {
  final y = localY - paddingTop - safeAreaTop + scrollOffset;
  return (y ~/ cellHeight).clamp(0, bufferLines - 1);
}

/// 指针所在的列号，与行同理（钳制到终端列数）。
int selectionColumnFor({
  required double localX,
  required double cellWidth,
  required double paddingLeft,
  required double safeAreaLeft,
  required int viewColumns,
}) {
  final x = localX - paddingLeft - safeAreaLeft;
  return (x ~/ cellWidth).clamp(0, viewColumns - 1);
}

/// xterm 的 `selectCharacters` 会把目标列 +1：向右拖时把落点那个单元格也含进去。
/// 返回列号，越界时由调用方自行处理（xterm 直接用越界值构造锚点）。
int selectionExtentColumn({required int fromColumn, required int toColumn}) {
  return toColumn >= fromColumn ? toColumn + 1 : toColumn;
}
