import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

/// 把任意异常翻译成适合直接展示给用户的一句话。
///
/// 纯 Dart、无 Flutter 依赖（可在 tool/verify.dart 里自检）。
/// 原 local_io.dart 中的实现迁移至此，local_io.dart 通过 export 保持兼容。
String describeError(Object error) {
  if (error is StateError) return error.message;

  if (error is FileSystemException) {
    final reason = error.osError?.message ?? error.message;
    if (reason.contains('Operation not permitted') ||
        reason.contains('Permission denied')) {
      return '本地写入被系统拒绝（$reason），请换一个位置或检查权限';
    }
    if (reason.contains('No such file or directory')) {
      return '本地路径不存在（$reason）';
    }
    if (reason.contains('No space left')) {
      return '本地磁盘空间不足';
    }
    return '本地文件操作失败（$reason）';
  }

  if (error is SocketException) {
    return error.osError?.message ?? error.message;
  }

  if (error is SftpStatusError) {
    // 服务器返回的 message 是最接近真相的信息（如 Disk quota exceeded），
    // 必须原样带给用户，别只丢一个 code。
    final detail = error.message.trim();
    final suffix = detail.isEmpty ? '' : '：$detail';
    switch (error.code) {
      case 1:
        return '远端提前结束传输（EOF）$suffix';
      case 2:
        return '远端文件或目录不存在$suffix';
      case 3:
        return '远端权限不足$suffix。可用 ls -ld <目录> 查归属，或改传到有写权限的目录';
      case 4:
        return '远端操作失败$suffix。磁盘空间满、配额超限（df -h 查看）也会报这个错';
      case 8:
        return '远端服务器不支持该操作$suffix';
      case 11:
        return '远端已有同名文件$suffix';
      case 12:
        return '远端文件只读$suffix';
      default:
        return 'SFTP 操作失败（code ${error.code}）$suffix';
    }
  }

  if (error is SSHAuthFailError || error is SSHAuthAbortError) {
    return '认证失败：请检查用户名、密码或私钥';
  }

  if (error is SSHChannelRequestError) {
    return '远端拒绝了会话请求（${error.message}）';
  }

  if (error is SSHKeyDecryptError) {
    return '私钥解密失败：密码短语不正确';
  }

  if (error is TimeoutException) {
    return '操作超时，请检查网络';
  }

  return error.toString().replaceFirst('Exception: ', '');
}
