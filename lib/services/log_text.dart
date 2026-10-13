// 日志文本处理（纯 Dart，无 Flutter 依赖，便于 tool/verify.dart 直接跑）

/// 日志文本无害化：**只剔除 NUL 字节，不截断、不改写任何内容**。
///
/// 终端能理解所有 C0 控制字符（\t \n \r \b ESC…），其中 ESC 是 ANSI 颜色
/// 序列的引导字节，绝不能删——删掉只会让 `[31m` 这类残留变成可见乱码。
/// 因此这里只清掉唯一无意义、且会让 C 字符串截断的 NUL。
String sanitizeLogChunk(String raw) {
  if (!raw.contains('\u0000')) return raw; // 绝大多数情况零拷贝返回
  return raw.replaceAll('\u0000', '');
}

/// 统计文本行数（按 \n）
int countLogLines(String text) {
  var count = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) count++;
  }
  return count;
}

/// 把裸 \n 统一成 \r\n。
///
/// 终端里裸 \n 只换行、不回列，行首会停在上行结束的列上（阶梯缩进）；
/// 裸 \r（进度条那种覆盖式输出）按换行展示更易读。
String normalizeLogNewlines(String text) {
  return text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\n', '\r\n');
}

// ---------------------------------------------------------------- 日志着色

const _esc = '\u001b[';

/// 日志级别关键词 → ANSI 颜色（亮色系，配深色终端）。
///
/// 只给**级别词**上色、正文保持默认色：整行染色在满屏日志里会花得没法看，
/// 而级别词染色既能一眼扫出异常，又留住了日志本身的可读性。
const _levelColors = <String, String>{
  'FATAL': '${_esc}1;91m',
  'PANIC': '${_esc}1;91m',
  'CRITICAL': '${_esc}1;91m',
  'ERROR': '${_esc}1;91m',
  'ERR': '${_esc}91m',
  'WARNING': '${_esc}1;93m',
  'WARN': '${_esc}93m',
  'NOTICE': '${_esc}96m',
  'INFO': '${_esc}92m',
  'DEBUG': '${_esc}90m',
  'TRACE': '${_esc}90m',
  'VERBOSE': '${_esc}90m',
};

/// 只认**全大写**的级别词：这是日志库/运行时最可靠的信号
/// （logrus、zap、syslog、nginx… 都输出 ERROR/WARN/INFO）。
/// 若放宽到大小写不敏感，行首的正常句子（如 `error occurred while ...`）
/// 也会被整词染红，反而失去了「颜色＝异常」的意义。
final _levelPattern = RegExp(r'\b(' + _levelColors.keys.join('|') + r')\b');

/// 行首时间戳：`2026-10-13T10:00:01.123Z`、`2026-10-13 10:00:01`、
/// `[2026-10-13 10:00:01]`、`10:00:01` 等常见形态（只认行首）。
final _timestampPattern = RegExp(
  r'^\[?(?:\d{4}[-/]\d{2}[-/]\d{2}[ T])?\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?\]?',
);

/// 只在行首这段范围内找级别词——正文里也偶尔会出现 `ERROR:` 这种引用，
/// 放宽扫描范围会把大段普通文本染色。
const _levelScanLimit = 48;

/// 给一行日志按级别着色（注入 ANSI），返回可直接写进 xterm 的字符串。
///
/// 已经带 ANSI 转义的行**原样返回**：说明输出方自己配了颜色（`docker logs`
/// 加了 `--color`、应用自带 logfmt 着色等），再叠一层只会互相打架。
String colorizeLogLine(String line) {
  if (line.isEmpty) return line;
  if (line.contains(_esc)) return line; // 尊重上游自己的着色
  if (line.length > 4000) return line; // 异常长的行不做正则，避免卡住

  final head = line.length > _levelScanLimit
      ? line.substring(0, _levelScanLimit)
      : line;
  final level = _levelPattern.firstMatch(head);
  final ts = _timestampPattern.firstMatch(line);

  if (level == null && ts == null) return line;

  final buffer = StringBuffer();
  var cursor = 0;

  void emitColored(int start, int end, String color) {
    if (start > cursor) buffer.write(line.substring(cursor, start));
    buffer.write(color);
    buffer.write(line.substring(start, end));
    buffer.write('${_esc}0m');
    cursor = end;
  }

  // 时间戳（灰）与级别词（亮色）按位置先后输出
  final marks = <(int, int, String)>[];
  if (ts != null) marks.add((ts.start, ts.end, '${_esc}90m'));
  if (level != null) {
    final color = _levelColors[level.group(1)!.toUpperCase()]!;
    marks.add((level.start, level.end, color));
  }
  marks.sort((a, b) => a.$1.compareTo(b.$1));

  for (final (start, end, color) in marks) {
    if (start < cursor) continue; // 与前一着色区间重叠（如时间戳与级别相邻）则跳过
    emitColored(start, end, color);
  }
  buffer.write(line.substring(cursor));
  return buffer.toString();
}

/// 对可能含多行的日志块逐行着色，保留原有换行结构。
String colorizeLogChunk(String chunk) {
  if (chunk.isEmpty) return chunk;
  if (!chunk.contains('\n')) return colorizeLogLine(chunk);
  return chunk.split('\n').map(colorizeLogLine).join('\n');
}

// ---------------------------------------------------------------- 日志搜索

/// 一条搜索匹配：缓冲区**绝对行号** + 行内起始列 + 匹配长度（单元格数）。
class LogMatch {
  const LogMatch(this.row, this.column, this.length);

  final int row;
  final int column;
  final int length;

  @override
  String toString() => 'LogMatch(row: $row, column: $column, length: $length)';

  @override
  bool operator ==(Object other) =>
      other is LogMatch &&
      other.row == row &&
      other.column == column &&
      other.length == length;

  @override
  int get hashCode => Object.hash(row, column, length);
}

/// 在一行里找 [query] 的全部匹配，返回每个匹配的起始列（大小写不敏感）。
///
/// 同一位置不重复计数（`aa` 搜 `aa` 只算一次，不重叠）。
List<int> findMatchColumns(String line, String query) {
  if (query.isEmpty || line.isEmpty) return const [];
  final haystack = line.toLowerCase();
  final needle = query.toLowerCase();
  final columns = <int>[];
  var from = 0;
  while (true) {
    final index = haystack.indexOf(needle, from);
    if (index < 0) break;
    columns.add(index);
    from = index + needle.length;
  }
  return columns;
}

/// 在整个日志缓冲区（每行一条纯文本，索引即缓冲区行号）里搜索 [query]。
List<LogMatch> searchLogLines(List<String> lines, String query) {
  if (query.isEmpty) return const [];
  final matches = <LogMatch>[];
  for (var row = 0; row < lines.length; row++) {
    for (final column in findMatchColumns(lines[row], query)) {
      matches.add(LogMatch(row, column, query.length));
    }
  }
  return matches;
}

/// 相对当前匹配位置找到下一个 / 上一个匹配的下标。
///
/// [delta] 为 +1 / -1；到两端时**循环**（和编辑器的搜索一致），
/// 空列表返回 -1。
int stepMatchIndex(int current, int count, int delta) {
  if (count <= 0) return -1;
  if (current < 0 || current >= count) return delta >= 0 ? 0 : count - 1;
  return (current + delta) % count;
}
