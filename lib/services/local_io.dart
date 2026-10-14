import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

// 错误翻译逻辑是纯 Dart（供 tool/verify.dart 自检），抽在 error_text.dart；
// 这里 re-export 保持既有 import 路径可用。
import 'error_text.dart';

export 'error_text.dart';

/// 本地文件系统辅助：下载目录解析、写入权限探测、在访达中定位。
///
/// 去沙盒后（2026-10-13 起）目录写入不再受沙盒限制，但 `file_picker`
/// 返回的目录仍不保证可写，探测逻辑保留。
class LocalIo {
  LocalIo._();

  static Directory? _cachedDownloads;

  /// 默认下载目录。macOS 上为 ~/Downloads，
  /// 对应 entitlements 里的 `com.apple.security.files.downloads.read-write`。
  static Future<Directory> downloadsDirectory() async {
    final cached = _cachedDownloads;
    if (cached != null) return cached;

    Directory? dir;
    try {
      dir = await getDownloadsDirectory();
    } catch (_) {
      dir = null;
    }
    dir ??= _fallbackDownloads();

    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cachedDownloads = dir;
    return dir;
  }

  static Directory _fallbackDownloads() {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory('$home/Downloads');
    }
    return Directory.systemTemp;
  }

  /// 拼接本地路径（统一用 `/`，macOS 下与 `\` 等价）
  static String join(String dir, String name) {
    if (dir.isEmpty) return name;
    return dir.endsWith('/') ? '$dir$name' : '$dir/$name';
  }

  /// 探测目录是否真的可写：写一个探针文件再删掉。
  ///
  /// 沙盒下 `Directory.exists()` 即使为 true 也可能不可写，
  /// 所以必须做一次真实写入。返回 null 表示可写，否则返回错误原因。
  static Future<String?> probeWritable(String dir) async {
    if (dir.isEmpty) return '目录为空';
    try {
      final probe = File(join(dir, '.fastshell-write-probe'));
      await probe.writeAsString('fastshell', flush: true);
      await probe.delete();
      return null;
    } on FileSystemException catch (error) {
      return error.osError?.message ?? error.message;
    } catch (error) {
      return describeError(error);
    }
  }

  /// 在访达中显示某个文件或目录
  static Future<void> revealInFinder(String path) async {
    if (path.isEmpty) return;
    final type = FileSystemEntity.typeSync(path);
    try {
      if (type == FileSystemEntityType.notFound) {
        final parent = _parentOf(path);
        await Process.run('open', [parent]);
      } else {
        await Process.run('open', ['-R', path]);
      }
    } catch (_) {
      // 打不开就算了，不影响主流程
    }
  }

  static String _parentOf(String path) {
    final index = path.lastIndexOf('/');
    if (index <= 0) return '/';
    return path.substring(0, index);
  }
}
