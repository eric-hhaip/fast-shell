// 本地配置诊断工具：解密 vault.enc 并打印内容摘要。
//
// 用途：用户反馈「连接不见了」时，先确认磁盘上的数据到底有没有、有几条，
// 避免在 UI 层瞎猜。默认对密码与私钥脱敏。
//
// 用法：
//   dart run tool/inspect_vault.dart            # 摘要（脱敏）
//   dart run tool/inspect_vault.dart --reveal   # 显示密码明文（谨慎）
//   dart run tool/inspect_vault.dart --path <目录>  # 指定数据目录
//
// 注意：密钥由「vault.key + 本机 IOPlatformUUID」经 HKDF 派生，
// 换机或删除 vault.key 后无法解密，这是设计使然。
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

const _defaultDir = 'Library/Application Support/FastShell';

Future<void> main(List<String> args) async {
  final reveal = args.contains('--reveal');
  final pathIndex = args.indexOf('--path');
  final home = Platform.environment['HOME'] ?? '';
  final dir = pathIndex >= 0 && pathIndex + 1 < args.length
      ? args[pathIndex + 1]
      : '$home/$_defaultDir';

  print('数据目录：$dir');
  final keyFile = File('$dir/vault.key');
  final encFile = File('$dir/vault.enc');

  if (!keyFile.existsSync()) {
    print('✗ 没有 vault.key —— 该目录从未被使用过，或密钥已被删除');
    return;
  }
  if (!encFile.existsSync()) {
    print('✗ 没有 vault.enc —— 密钥在但配置为空（从未保存过连接）');
    return;
  }

  print('vault.key：${keyFile.lengthSync()} 字节，'
      '最后修改 ${keyFile.statSync().modified}');
  print('vault.enc：${encFile.lengthSync()} 字节，'
      '最后修改 ${encFile.statSync().modified}');

  // 与 Vault._deviceId 完全一致：先 ioreg，失败退回主机名
  String deviceId = Platform.localHostname;
  if (Platform.isMacOS) {
    try {
      final result = await Process.run('ioreg', [
        '-rd1',
        '-c',
        'IOPlatformExpertDevice',
      ]);
      final match = RegExp(r'"IOPlatformUUID"\s*=\s*"([^"]+)"')
          .firstMatch(result.stdout.toString());
      if (match != null) deviceId = match.group(1)!;
    } catch (_) {}
  }
  print('本机标识：$deviceId');

  final master = await keyFile.readAsBytes();
  if (master.length != 32) {
    print('✗ vault.key 长度不是 32 字节，无法作为主密钥');
    return;
  }

  final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: SecretKey(master),
    nonce: utf8.encode(deviceId),
    info: utf8.encode('hhaip-shell/vault/v1'),
  );

  final payload =
      jsonDecode(await encFile.readAsString()) as Map<String, dynamic>;

  String clearText;
  try {
    final clear = await AesGcm.with256bits().decrypt(
      SecretBox(
        base64Decode(payload['data'] as String),
        nonce: base64Decode(payload['nonce'] as String),
        mac: Mac(base64Decode(payload['mac'] as String)),
      ),
      secretKey: derived,
    );
    clearText = utf8.decode(clear);
  } catch (e) {
    print('✗ 解密失败：$e');
    print('  常见原因：vault.key 与 vault.enc 不配套（比如换过 key），'
        '或本机标识变了。');
    return;
  }

  final data = jsonDecode(clearText) as Map<String, dynamic>;
  final connections = (data['connections'] as List?) ?? const [];
  final settings = (data['settings'] as Map?) ?? const {};
  final categories = (settings['categories'] as List?) ?? const [];

  print('');
  print('=== 解密成功 ===');
  print('连接数：${connections.length}');
  print('分类（${categories.length}）：${categories.join('、')}');
  print('');
  for (var i = 0; i < connections.length; i++) {
    final c = connections[i] as Map;
    final auth = c['authType'] == 'key' ? '密钥' : '密码';
    final secret = c['authType'] == 'key'
        ? '私钥=${(c['privateKeyPath'] as String?)?.isNotEmpty == true ? c['privateKeyPath'] : '（内联 ${(c['privateKeyPem'] as String?)?.length ?? 0} 字符）'}'
        : '密码=${reveal ? c['password'] : '******'}';
    print('${i + 1}. ${c['name']}  '
        '${c['username']}@${c['host']}:${c['port']}  [$auth]  '
        '分组=${c['group'] ?? '(无)'}');
    print('   $secret');
    if (c['lastConnectedAt'] != null) {
      print('   最后连接：${c['lastConnectedAt']}');
    }
  }
  print('');
  print('提示：--reveal 可显示密码明文。');
}
