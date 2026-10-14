// 纯 Dart 逻辑自检（不依赖 flutter_test，可在无 GUI 环境运行）
// 运行：dart run tool/verify.dart
// ignore_for_file: avoid_print

import 'package:hhaip_shell/models/app_settings.dart';
import 'package:hhaip_shell/models/connection.dart';
import 'package:hhaip_shell/models/transfer_task.dart';
import 'package:hhaip_shell/services/error_text.dart';
import 'package:hhaip_shell/services/log_text.dart';
import 'package:hhaip_shell/services/monitor_service.dart';
import 'package:hhaip_shell/services/remote_path.dart';
import 'package:hhaip_shell/ui/quick_connect.dart';
import 'package:hhaip_shell/ui/terminal_selection.dart';

import 'package:dartssh2/dartssh2.dart';

int _passed = 0;
int _failed = 0;

void check(String label, Object? actual, Object? expected) {
  final ok = '$actual' == '$expected';
  if (ok) {
    _passed++;
    print('  ✓ $label');
  } else {
    _failed++;
    print('  ✗ $label → 期望 $expected，实际 $actual');
  }
}

void main() {
  print('SFTP 错误文案');
  check(
    'code 3 带服务器消息',
    describeError(SftpStatusError(3, 'Permission denied')),
    '远端权限不足：Permission denied。可用 ls -ld <目录> 查归属，或改传到有写权限的目录',
  );
  check(
    'code 4 提示磁盘与配额',
    describeError(SftpStatusError(4, 'Disk quota exceeded')),
    '远端操作失败：Disk quota exceeded。磁盘空间满、配额超限（df -h 查看）也会报这个错',
  );
  check(
    'code 3 无消息时不出冒号',
    describeError(SftpStatusError(3, '')),
    '远端权限不足。可用 ls -ld <目录> 查归属，或改传到有写权限的目录',
  );
  check(
    'code 2 文件不存在',
    describeError(SftpStatusError(2, 'no such file')),
    '远端文件或目录不存在：no such file',
  );
  check(
    '未知 code 保留原始编号',
    describeError(SftpStatusError(7, '')),
    'SFTP 操作失败（code 7）',
  );

  print('RemotePath');
  check(
    'normalize 折叠 . 与 ..',
    RemotePath.normalize('/var/./log/../tmp'),
    '/var/tmp',
  );
  check('normalize 合并斜杠', RemotePath.normalize('a//b///c'), 'a/b/c');
  check('normalize 根目录', RemotePath.normalize('/'), '/');
  check('normalize 越界不回溯', RemotePath.normalize('/../etc'), '/etc');
  check('join', RemotePath.join('/home/deploy', 'app'), '/home/deploy/app');
  check('join 到根', RemotePath.join('/', 'etc'), '/etc');
  check('parent', RemotePath.parent('/home/deploy/app'), '/home/deploy');
  check('parent 根', RemotePath.parent('/'), '/');
  check(
    'breadcrumbs',
    RemotePath.breadcrumbs('/home/deploy').map((c) => c.label).join('|'),
    '/|home|deploy',
  );

  print('快速连接解析');
  check('user@host', parseQuickTarget('root@10.0.0.2')?.username, 'root');
  check('默认端口', parseQuickTarget('root@10.0.0.2')?.port, 22);
  check('自定义端口', parseQuickTarget('deploy@example.com:2222')?.port, 2222);
  check('缺少 @ 返回 null', parseQuickTarget('example.com'), null);
  check('空串返回 null', parseQuickTarget(''), null);
  check('空用户名返回 null', parseQuickTarget('@host'), null);

  print('连接模型');
  final connection = SshConnection(
    name: '生产',
    host: '10.0.0.2',
    port: 2222,
    username: 'deploy',
    authType: SshAuthType.privateKey,
    privateKeyPath: '/Users/me/.ssh/id_ed25519',
    group: '线上',
  );
  final restored = SshConnection.fromJson(connection.toJson());
  check('序列化往返 id', restored.id, connection.id);
  check('序列化往返端口', restored.port, 2222);
  check('序列化往返认证方式', restored.authType, SshAuthType.privateKey);
  check('address', restored.address, 'deploy@10.0.0.2:2222');
  check(
    'displayName 回退',
    SshConnection(host: 'a.com', username: 'ops').displayName,
    'ops@a.com',
  );

  print('传输任务进度');
  final task = TransferTask(
    id: 't1',
    name: 'a.bin',
    direction: TransferDirection.upload,
    localPath: '/tmp/a.bin',
    remotePath: '/root/a.bin',
    totalBytes: 1000,
  );
  task.updateProgress(250);
  check('进度百分比', (task.progress * 100).round(), 25);
  check('进度文案', task.progressText, '250 B / 1000 B');
  task.transferredBytes = 1000;
  check('完成进度', task.progress, 1.0);

  print('监控采集解析');
  const sampleOutput = '''
==FINFO==
my-server
5.10.0
"Tencent OS Server 3.1"
4
86400
==STAT==
cpu  100 0 100 700 100 0 0 0 0 0
==LOAD==
0.10 0.20 0.30 1/100 1234
==MEM==
MemTotal:        4000000 kB
MemAvailable:    2000000 kB
SwapTotal:             0 kB
SwapFree:              0 kB
==DISK==
Filesystem     1024-blocks     Used Available Capacity Mounted on
/dev/vda1        41152812 12345678  26652126  32%      /
tmpfs              996000        0    996000   0%      /dev/shm
/dev/vdb1       103080888 51540444  46316032  53%      /data
==NET==
  lo: 12345 100 0 0 0 0 0 0 678 6 0 0 0 0 0 0
  eth0: 1000000 800 0 0 0 0 0 0 500000 600 0 0 0 0 0 0
==TOP==
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  2.5  1.0  10000 20000 ?       Ss   10:00  1:00 /sbin/init
==DOCKER==
abc123|web|nginx:1.25|running|Up 2 days
def456|cache|redis:7|exited|Exited (0) 3 days ago
==END==
''';
  final snapshot = MonitorService.parseSnapshot(sampleOutput);
  check('主机名', snapshot.hostname, 'my-server');
  check('内核', snapshot.kernel, '5.10.0');
  check('系统', snapshot.os, 'Tencent OS Server 3.1');
  check('核数', snapshot.cores, 4);
  check('负载', snapshot.load1, 0.10);
  check('内存已用', snapshot.memUsedBytes, 2000000 * 1024);
  check('内存百分比', snapshot.memPercent.toStringAsFixed(1), '50.0');
  check('磁盘过滤 tmpfs', snapshot.disks.length, 2);
  check('磁盘挂载', snapshot.disks.first.mount, '/');
  check('网络接口取 eth0', snapshot.net?.interface, 'eth0');
  check('网络收字节', snapshot.net?.rxBytes, 1000000);
  check('进程解析', snapshot.processes.first.command, '/sbin/init');
  check('容器数量', snapshot.containers.length, 2);
  check('容器运行态', snapshot.containers.first.isRunning, true);
  check('容器停止态', snapshot.containers.last.isRunning, false);

  // CPU 使用率：两次采样对比
  final first = MonitorService.parseSnapshot(sampleOutput);
  const busierOutput = '''
==FINFO==
my-server
5.10.0
"Tencent OS Server 3.1"
4
86400
==STAT==
cpu  200 0 200 800 100 0 0 0 0 0
==END==
''';
  final second = MonitorService.parseSnapshot(
    busierOutput,
    prevCpu: first.cpuRaw,
  );
  // total 1000→1300（+300），idle 800→900（+100）→ busy (300-100)/300
  check('CPU 使用率', second.cpuPercent?.toStringAsFixed(1), '66.7');

  final stats = MonitorService.parseDockerStats(
    'web|12.34%|100 MiB / 2 GiB|4.88%|1.2 MB / 3.4 MB',
  );
  check('容器统计名称', stats.keys.first, 'web');
  check('容器统计 CPU', stats['web']?.cpuPercent?.toStringAsFixed(2), '12.34');
  check('容器统计内存', stats['web']?.memUsage, '100 MiB / 2 GiB');

  check(
    '日志脚本',
    MonitorService.containerLogsScript('my web', follow: true),
    "docker logs -f --tail 300 'my web' 2>&1",
  );

  print('设置与分类');
  final defaults = AppSettings();
  check('内置分类只有默认', defaults.categories.join(','), '默认');
  final withCustom = AppSettings(categories: ['默认', '灰度环境']);
  check('自定义分类保留', withCustom.categories.join(','), '默认,灰度环境');
  final restoredSettings = AppSettings.fromJson(withCustom.toJson());
  check('分类序列化往返', restoredSettings.categories.join(','), '默认,灰度环境');
  check(
    '旧数据缺 categories 字段回退',
    AppSettings.fromJson({'fontSize': 15}).categories.join(','),
    '默认',
  );
  check(
    '去重与空值过滤',
    AppSettings.fromJson({
      'categories': ['默认', '  ', '生产', '生产', '', '生产'],
    }).categories.join(','),
    '默认,生产',
  );
  check('默认是内置不可删', defaults.isBuiltinCategory('默认'), true);
  check('自定义可删', withCustom.isBuiltinCategory('灰度环境'), false);

  print('日志行处理（不截断、不改写内容）');
  check(
    '保留 ANSI 颜色码',
    sanitizeLogChunk('\x1B[31mError\x1B[0m'),
    '\x1B[31mError\x1B[0m',
  );
  check('保留制表符', sanitizeLogChunk('a\tb'), 'a\tb');
  check('保留换行', sanitizeLogChunk('a\nb'), 'a\nb');
  check('保留回车', sanitizeLogChunk('a\rb'), 'a\rb');
  check('保留退格', sanitizeLogChunk('a\bb'), 'a\bb');
  check('剔除 NUL', sanitizeLogChunk('a\x00b'), 'ab');
  final huge = 'x' * 300000;
  check('超长行完整保留', sanitizeLogChunk(huge).length, huge.length);
  check('普通行原样', sanitizeLogChunk('hello 世界'), 'hello 世界');
  check('行数统计', countLogLines('a\nb\nc'), 2);

  print('终端选区自动滚动');
  // 几何约定：内容区 8..500，感应区厚度 40（即 8..48 与 460..500 是感应区）
  const top = 8.0, bottom = 500.0, edge = 40.0;
  check(
    '界外上方向上滚',
    selectionScrollDirection(
      pointerY: -100,
      contentTop: top,
      contentBottom: bottom,
      edgePixels: edge,
    ),
    -1,
  );
  check(
    '界内贴上边向上滚',
    selectionScrollDirection(
      pointerY: 40,
      contentTop: top,
      contentBottom: bottom,
      edgePixels: edge,
    ),
    -1,
  );
  check(
    '感应区外不滚',
    selectionScrollDirection(
      pointerY: 50,
      contentTop: top,
      contentBottom: bottom,
      edgePixels: edge,
    ),
    0,
  );
  check(
    '中间不滚',
    selectionScrollDirection(
      pointerY: 250,
      contentTop: top,
      contentBottom: bottom,
      edgePixels: edge,
    ),
    0,
  );
  check(
    '界内贴下边向下滚',
    selectionScrollDirection(
      pointerY: 470,
      contentTop: top,
      contentBottom: bottom,
      edgePixels: edge,
    ),
    1,
  );
  check(
    '界外下方向下滚',
    selectionScrollDirection(
      pointerY: 900,
      contentTop: top,
      contentBottom: bottom,
      edgePixels: edge,
    ),
    1,
  );
  check(
    '感应区厚度为 0 时界内不滚',
    selectionScrollDirection(
      pointerY: 250,
      contentTop: top,
      contentBottom: bottom,
      edgePixels: 0,
    ),
    0,
  );
  check(
    '感应区厚度为 0 时出界仍会滚',
    selectionScrollDirection(
      pointerY: -100,
      contentTop: top,
      contentBottom: bottom,
      edgePixels: 0,
    ),
    -1,
  );

  // 浮点运算带尾差，速度系数统一按三位小数比对
  String speed(double pointerY) => selectionScrollSpeedFactor(
    pointerY: pointerY,
    contentTop: top,
    contentBottom: bottom,
    edgePixels: edge,
  ).toStringAsFixed(3);

  check('贴边最慢（0.35 封顶）', speed(top), '0.350');
  check('感应区内缘速度归零', speed(top + edge), '0.000');
  check('刚出界略加速', speed(top - edge * 0.1), '0.450');
  check('出界一个感应区宽度后到顶速', speed(top - edge), '1.000');
  check('出界很远仍是顶速', speed(top - edge * 50), '1.000');

  // 行换算：行高 20，顶部留白 8，安全区 0
  const cellH = 20.0, padT = 8.0, safeT = 0.0;
  check(
    '未滚动时指向第一行',
    selectionRowFor(
      localY: 8,
      cellHeight: cellH,
      paddingTop: padT,
      safeAreaTop: safeT,
      scrollOffset: 0,
      bufferLines: 24,
    ),
    0,
  );
  check(
    '往下两行是第 1 行',
    selectionRowFor(
      localY: 28,
      cellHeight: cellH,
      paddingTop: padT,
      safeAreaTop: safeT,
      scrollOffset: 0,
      bufferLines: 24,
    ),
    1,
  );
  check(
    '滚动 200px 后同一位置是第 10 行',
    selectionRowFor(
      localY: 8,
      cellHeight: cellH,
      paddingTop: padT,
      safeAreaTop: safeT,
      scrollOffset: 200,
      bufferLines: 24,
    ),
    10,
  );
  check(
    '行号钳制到缓冲区末行',
    selectionRowFor(
      localY: 8,
      cellHeight: cellH,
      paddingTop: padT,
      safeAreaTop: safeT,
      scrollOffset: 1000,
      bufferLines: 24,
    ),
    23,
  );
  check(
    '指针出上界不产生负行号',
    selectionRowFor(
      localY: 0,
      cellHeight: cellH,
      paddingTop: padT,
      safeAreaTop: safeT,
      scrollOffset: 0,
      bufferLines: 24,
    ),
    0,
  );
  // 安全区非零（触屏设备场景）时同样要扣掉
  check(
    '安全区被扣掉',
    selectionRowFor(
      localY: 33,
      cellHeight: cellH,
      paddingTop: padT,
      safeAreaTop: 5,
      scrollOffset: 0,
      bufferLines: 24,
    ),
    1,
  );

  // 列换算：列宽 10，左边留白 10，终端 80 列
  const cellW = 10.0, padL = 10.0;
  check(
    '未滚动时指向第一列',
    selectionColumnFor(
      localX: 10,
      cellWidth: cellW,
      paddingLeft: padL,
      safeAreaLeft: 0,
      viewColumns: 80,
    ),
    0,
  );
  check(
    '中段列号正确',
    selectionColumnFor(
      localX: 105,
      cellWidth: cellW,
      paddingLeft: padL,
      safeAreaLeft: 0,
      viewColumns: 80,
    ),
    9,
  );
  check(
    '列号钳制到最后一列',
    selectionColumnFor(
      localX: 1000,
      cellWidth: cellW,
      paddingLeft: padL,
      safeAreaLeft: 0,
      viewColumns: 80,
    ),
    79,
  );

  check('向右拖时多含一个单元格', selectionExtentColumn(fromColumn: 3, toColumn: 5), 6);
  check('向左拖不多含', selectionExtentColumn(fromColumn: 5, toColumn: 3), 3);
  check(
    '同一列也多含（保证至少选中一格）',
    selectionExtentColumn(fromColumn: 4, toColumn: 4),
    5,
  );

  print('日志着色');
  const esc = '\u001b[';
  check(
    'ERROR 词被染红',
    colorizeLogLine('ERROR failed to connect')
        .contains('${esc}1;91mERROR${esc}0m'),
    true,
  );
  check(
    'WARN 词被染黄',
    colorizeLogLine('WARN disk almost full').contains('${esc}93mWARN${esc}0m'),
    true,
  );
  check(
    'INFO 词被染绿',
    colorizeLogLine('INFO server started').contains('${esc}92mINFO${esc}0m'),
    true,
  );
  check(
    '时间戳染灰且正文保持默认色',
    colorizeLogLine('2026-10-13 10:00:01 INFO boot').startsWith(
      '${esc}90m2026-10-13 10:00:01${esc}0m ${esc}92mINFO${esc}0m boot',
    ),
    true,
  );
  check(
    '时间戳与级别词之间不重复着色',
    colorizeLogLine('2026-10-13T10:00:01Z ERROR boom')
        .contains('${esc}0m ${esc}1;91mERROR${esc}0m'),
    true,
  );
  check(
    '正文小写 error 不染色（只认全大写级别词）',
    colorizeLogLine('error occurred while opening file'),
    'error occurred while opening file',
  );
  check(
    '行尾出现的级别词不染色（只扫行首 48 字符）',
    colorizeLogLine('本次请求返回内容：' * 6 + 'ERROR'),
    '本次请求返回内容：' * 6 + 'ERROR',
  );
  check('无级别无时间戳的行原样返回', colorizeLogLine('listen on :8080'), 'listen on :8080');
  check(
    '已含 ANSI 的行原样返回（尊重上游着色）',
    colorizeLogLine('${esc}32mINFO${esc}0m custom colored'),
    '${esc}32mINFO${esc}0m custom colored',
  );
  check('空行原样返回', colorizeLogLine(''), '');
  check('多行块逐行着色', colorizeLogChunk('INFO a\nERROR b').split('\n').length, 2);
  check(
    '多行块中错误行的级别词被染色',
    colorizeLogChunk('INFO a\nERROR b').contains('${esc}1;91mERROR${esc}0m'),
    true,
  );

  print('日志搜索');
  check('单行多命中', findMatchColumns('aaa', 'a').join(','), '0,1,2');
  check('命中不重叠', findMatchColumns('aaaa', 'aa').join(','), '0,2');
  check('大小写不敏感', findMatchColumns('Error ERROR', 'error').join(','), '0,6');
  check('未命中返回空', findMatchColumns('abc', 'z').length, 0);
  check('空关键字返回空', findMatchColumns('abc', '').length, 0);
  check('空行返回空', findMatchColumns('', 'a').length, 0);

  const searchLines = ['INFO boot', 'ERROR disk full', 'INFO ok ERROR again'];
  final matches = searchLogLines(searchLines, 'ERROR');
  check('全量搜索命中数', matches.length, 2);
  check('首条命中行号', matches[0].row, 1);
  check('首条命中列号', matches[0].column, 0);
  check('次条命中行号', matches[1].row, 2);
  check('次条命中列号', matches[1].column, 8);
  check('匹配长度等于关键字长度', matches[1].length, 5);
  check('空关键字不做全量搜索', searchLogLines(searchLines, '').length, 0);

  check('下一个：中间项前进', stepMatchIndex(0, 3, 1), 1);
  check('下一个：末项回到首项（循环）', stepMatchIndex(2, 3, 1), 0);
  check('上一个：首项回到末项（循环）', stepMatchIndex(0, 3, -1), 2);
  check('上一个：中间项后退', stepMatchIndex(2, 3, -1), 1);
  check('未定位时向下取首项', stepMatchIndex(-1, 3, 1), 0);
  check('未定位时向上取末项', stepMatchIndex(-1, 3, -1), 2);
  check('无命中返回 -1', stepMatchIndex(0, 0, 1), -1);

  print('日志换行归一');
  check('CRLF 归一为单次换行', normalizeLogNewlines('a\r\nb'), 'a\r\nb');
  check('裸 LF 补回车', normalizeLogNewlines('a\nb'), 'a\r\nb');
  check('裸 CR 按换行处理', normalizeLogNewlines('a\rb'), 'a\r\nb');

  print('\n通过 $_passed 项，失败 $_failed 项');
  if (_failed > 0) {
    throw StateError('自检未通过');
  }
}
