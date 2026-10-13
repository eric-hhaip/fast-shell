import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

/// 本地加密仓库。
///
/// - 主密钥保存在 `vault.key`（32 随机字节，权限 0600）
/// - 数据以 AES-256-GCM 加密写入 `vault.enc`
/// - 实际加密密钥由「主密钥 + 本机标识」经 HKDF 派生：
///   只拷贝 vault.enc 到别的机器无法解密。
class Vault {
  Vault._(this.directory, this._key);

  final Directory directory;
  final SecretKey _key;

  static const _vaultFileName = 'vault.enc';
  static const _keyFileName = 'vault.key';

  /// 解密失败时的提示（UI 展示后应清空）
  String? warning;

  File get vaultFile => File('${directory.path}/$_vaultFileName');

  static Future<Vault> open() async {
    final directory = await _resolveDirectory();
    await _migrateLegacyData(directory);

    // 设备 UUID（要 spawn ioreg）与密钥文件读取互不依赖，并行跑省一个来回
    final keyFile = File('${directory.path}/$_keyFileName');
    final deviceIdFuture = _deviceId();
    List<int> master;
    if (keyFile.existsSync() && keyFile.lengthSync() == 32) {
      master = await keyFile.readAsBytes();
    } else {
      final random = Random.secure();
      master = List<int>.generate(32, (_) => random.nextInt(256));
      await keyFile.writeAsBytes(master, flush: true);
      _restrictPermissions(keyFile.path);
    }

    final deviceId = await deviceIdFuture;
    final derive = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await derive.deriveKey(
      secretKey: SecretKey(master),
      nonce: utf8.encode(deviceId),
      info: utf8.encode('hhaip-shell/vault/v1'),
    );

    return Vault._(directory, derived);
  }

  /// 数据目录：**刻意放在沙盒容器之外**（`~/Library/Application Support/FastShell/`）。
  ///
  /// 沙盒容器（`~/Library/Containers/<bundle-id>/Data/…`）会在应用重装、
  /// 代码签名变化等情况下被系统重置——用户看到的现象是「连接和分类全没了」。
  /// 容器外的目录只受用户自己的操作影响。为此本应用**不启用 App Sandbox**
  /// （见 `macos/Runner/Release.entitlements`），该路径无需额外授权即可读写。
  ///
  /// 万一写入被拒（例如运行环境异常），写探针会失败，此时回退到
  /// `getApplicationSupportDirectory()` 给的目录——宁可回到旧行为，
  /// 也不能让应用存不了配置。
  static Future<Directory> _resolveDirectory() async {
    // 沙盒下 getApplicationSupportDirectory() 返回容器路径，路径里本身就带着
    // 真实家目录——这是最可靠的线索（沙盒里 HOME 环境变量不一定存在或指向容器）
    final container = await getApplicationSupportDirectory();
    final realHome =
        _homeFromPath(container.path) ?? _homeFromEnvironment() ?? '';
    if (realHome.isNotEmpty) {
      final preferred = Directory(
        '$realHome/Library/Application Support/FastShell',
      );
      try {
        if (!preferred.existsSync()) {
          await preferred.create(recursive: true);
        }
        final probe = File('${preferred.path}/.write-probe');
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
        return preferred;
      } catch (_) {
        // 落到下面的容器回退
      }
    }
    final directory = Directory(container.path);
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  /// 从容器路径还原真实家目录：
  /// `/Users/me/Library/Containers/<id>/Data` → `/Users/me`
  static String? _homeFromPath(String path) {
    final match = RegExp(r'^(/Users/[^/]+)/Library/Containers/')
        .firstMatch(path);
    return match?.group(1);
  }

  /// 兜底：`HOME` 指向真实目录时直接用，否则用 `USER` 拼
  static String? _homeFromEnvironment() {
    final home = Platform.environment['HOME'] ?? '';
    if (home.startsWith('/Users/') && !home.contains('/Library/Containers/')) {
      return home;
    }
    final user = Platform.environment['USER'];
    if (user != null && user.isNotEmpty) return '/Users/$user';
    return null;
  }

  /// 一次性搬迁：老版本把数据放在沙盒容器里，升级后自动挪过来，
  /// 不因为换了存放位置就把已有连接丢掉。
  ///
  /// 非沙盒运行时 `getApplicationSupportDirectory()` 返回的已是真实目录，
  /// 所以容器路径要显式拼出来。
  static Future<void> _migrateLegacyData(Directory target) async {
    // 新位置已经有数据了就以它为准，不再覆盖
    if (File('${target.path}/$_vaultFileName').existsSync()) return;
    for (final legacy in await _legacyDirectories()) {
      try {
        if (legacy.path == target.path) continue;
        final oldData = File('${legacy.path}/$_vaultFileName');
        if (!oldData.existsSync()) continue;
        final oldKey = File('${legacy.path}/$_keyFileName');
        if (oldKey.existsSync()) {
          await oldKey.copy('${target.path}/$_keyFileName');
        }
        await oldData.copy('${target.path}/$_vaultFileName');
        return;
      } catch (_) {
        // 某个来源搬不动就试下一个，不阻断启动
      }
    }
  }

  /// 历史数据可能落在的位置，按可信度排序
  static Future<List<Directory>> _legacyDirectories() async {
    final dirs = <Directory>[];
    // 旧沙盒容器：~/Library/Containers/<bundle-id>/Data/Library/Application Support/<bundle-id>/
    final home = Platform.environment['HOME'] ?? '';
    if (home.startsWith('/Users/')) {
      dirs.add(
        Directory(
          '$home/Library/Containers/com.hhaip.hhaipShell/Data'
          '/Library/Application Support/com.hhaip.hhaipShell',
        ),
      );
    }
    // path_provider 给的目录（非沙盒下即 ~/Library/Application Support/<bundle-id>）
    final support = await getApplicationSupportDirectory();
    dirs.add(Directory(support.path));
    return dirs;
  }

  /// 权限收紧不阻塞调用方：它只是安全加固，晚几百微秒完成没关系
  static void _restrictPermissions(String path) {
    try {
      Process.run('chmod', ['600', path]).ignore();
    } catch (_) {
      // 被拒也只是退回默认权限，不影响功能
    }
  }

  static Future<String> _deviceId() async {
    if (Platform.isMacOS) {
      try {
        final result = await Process.run('ioreg', [
          '-rd1',
          '-c',
          'IOPlatformExpertDevice',
        ]);
        final output = result.stdout.toString();
        final match = RegExp(r'"IOPlatformUUID"\s*=\s*"([^"]+)"')
            .firstMatch(output);
        if (match != null) return match.group(1)!;
      } catch (_) {
        // 忽略：退回主机名
      }
    }
    return Platform.localHostname;
  }

  /// 读取整份数据；文件不存在返回空 map
  Future<Map<String, dynamic>> read() async {
    final file = vaultFile;
    if (!file.existsSync()) return <String, dynamic>{};

    try {
      final payload =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final nonce = base64Decode(payload['nonce'] as String);
      final mac = Mac(base64Decode(payload['mac'] as String));
      final cipherText = base64Decode(payload['data'] as String);

      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: _key,
      );
      return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    } catch (error) {
      // 无法解密：备份原文件，从头开始，避免应用直接不可用
      try {
        final backup =
            '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}';
        await file.rename(backup);
      } catch (_) {}
      warning = '本地配置解密失败，已重置（旧文件已备份）。';
      return <String, dynamic>{};
    }
  }

  Future<void> write(Map<String, dynamic> data) async {
    final clear = utf8.encode(jsonEncode(data));
    final box = await AesGcm.with256bits().encrypt(clear, secretKey: _key);
    final payload = jsonEncode({
      'v': 1,
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
      'data': base64Encode(box.cipherText),
    });

    final tmp = File('${vaultFile.path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    await tmp.rename(vaultFile.path);
    _restrictPermissions(vaultFile.path);
  }
}
