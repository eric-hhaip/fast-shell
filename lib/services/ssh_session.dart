import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/connection.dart';
import '../models/remote_entry.dart';
import '../models/transfer_task.dart';
import 'remote_path.dart';

enum SessionStatus { idle, connecting, connected, closed, failed }

typedef SessionOutputCallback = void Function(String data);
typedef SessionStatusCallback =
    void Function(SessionStatus status, String? error);

/// 主机指纹确认回调：返回 true 表示信任
typedef HostKeyPrompt = Future<bool> Function(String keyType, String fingerprint);

/// 一条持续输出 exec 通道的取消句柄
class ExecStreamHandle {
  const ExecStreamHandle({required this.close});
  final Future<void> Function() close;
}

/// 远端文本文件内容
class RemoteFileContent {
  const RemoteFileContent({
    required this.text,
    required this.size,
    required this.truncated,
    required this.binary,
  });

  final String text;

  /// 远端文件真实大小
  final int size;

  /// 是否因超出读取上限被截断
  final bool truncated;

  /// 是否疑似二进制文件
  final bool binary;
}

/// 一条 SSH 会话：交互式 Shell + 按需打开的 SFTP 通道
class SshSession {
  SshSession(this.connection);

  final SshConnection connection;

  SSHClient? _client;
  SSHSession? _shell;
  SftpClient? _sftp;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  SessionStatus status = SessionStatus.idle;
  String? error;
  String? homeDirectory;

  SessionOutputCallback? onOutput;
  SessionStatusCallback? onStatus;

  bool get isConnected => status == SessionStatus.connected;

  Future<void> connect({
    required SessionOutputCallback onOutput,
    required SessionStatusCallback onStatus,
    required HostKeyPrompt onHostKey,
    int columns = 100,
    int rows = 30,
  }) async {
    this.onOutput = onOutput;
    this.onStatus = onStatus;

    await _teardown();
    _setStatus(SessionStatus.connecting, null);

    try {
      final socket = await SSHSocket.connect(
        connection.host,
        connection.port,
        timeout: const Duration(seconds: 20),
      );

      final client = SSHClient(
        socket,
        username: connection.username,
        identities: _loadIdentities(),
        onPasswordRequest:
            connection.authType == SshAuthType.password &&
                connection.password.isNotEmpty
            ? () async => connection.password
            : null,
        // 很多服务器（尤其云上镜像）禁用 password 认证方式、
        // 只接受 keyboard-interactive。dartssh2 只有在传了这个回调时
        // 才会尝试该方式 —— 把保存的密码填进非回显的提示里即可。
        onUserInfoRequest: connection.authType == SshAuthType.password &&
                connection.password.isNotEmpty
            ? (request) async {
                return request.prompts
                    .map((prompt) => prompt.echo ? '' : connection.password)
                    .toList();
              }
            : null,
        onVerifyHostKey: (type, fingerprint) async {
          final value = utf8.decode(fingerprint);
          return onHostKey(type, value);
        },
        keepAliveInterval: const Duration(seconds: 15),
        handshakeTimeout: const Duration(seconds: 25),
      );
      _client = client;

      await client.authenticated;

      final pty = SSHPtyConfig(
        type: 'xterm-256color',
        width: columns,
        height: rows,
      );
      SSHSession shell;
      try {
        // 让远端程序知道终端支持真彩色，ls / vim / 主题脚本会输出彩色转义。
        // 部分服务器（sshd 配置了 AcceptEnv 白名单或严格模式）会直接拒绝
        // 设置环境变量并让整个 shell 打开失败 —— 此时退回不带环境变量的 shell。
        shell = await client.shell(
          pty: pty,
          environment: const {'COLORTERM': 'truecolor'},
        );
      } on SSHChannelRequestError {
        shell = await client.shell(pty: pty);
      }
      _shell = shell;
      // 用流式 UTF-8 解码器拼接分块：TCP 分块可能把多字节汉字/符号
      // 从中间切断，逐块 decode 会产生乱码（花屏）
      _subscriptions.add(
        shell.stdout
            .cast<List<int>>()
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(_onRemoteOutput),
      );
      _subscriptions.add(
        shell.stderr
            .cast<List<int>>()
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(_onRemoteOutput),
      );
      unawaited(
        shell.done.then((_) {
          if (status == SessionStatus.connected) {
            _setStatus(SessionStatus.closed, '远端会话已结束');
          }
        }),
      );

      _setStatus(SessionStatus.connected, null);
      // 连上后注入一次「美化管理」：彩色提示符 + ls/grep 自动着色。
      // 不少服务器（尤其 CentOS/OpenCloudOS 的 root）默认 PS1 纯白、ls 无色，
      // 远端不发颜色码，客户端调色板再好也无从渲染。
      // stty -echo 让这段命令不回显，最后的 clear 清掉横幅，只留彩色提示符。
      writeString(_shellInitCommand);
    } catch (error) {
      final message = _describeError(error);
      await _teardown();
      _setStatus(SessionStatus.failed, message);
    }
  }

  bool _warming = false;

  /// 预热 exec 通道：sshd 首次为 exec 拉起用户 shell 时，PAM/NSS 冷缓存
  /// 可能要几十秒（之后命中缓存就快）。
  ///
  /// 由上层在「连接已建立」后异步调用（不 await），把这份一次性开销
  /// 吸收在用户还没去点监控面板的空档里；失败静默忽略，不影响连接。
  Future<void> warmUpExec() async {
    if (_warming || !isConnected) return;
    _warming = true;
    try {
      await runCommand('true', timeout: const Duration(seconds: 40));
    } catch (_) {
      // 预热失败无所谓，正式采集时会自己重试
    } finally {
      _warming = false;
    }
  }

  void write(Uint8List data) {
    final shell = _shell;
    if (shell == null) return;
    shell.write(data);
  }

  void writeString(String data) {
    final shell = _shell;
    if (shell == null) return;
    shell.write(Uint8List.fromList(utf8.encode(data)));
  }

  /// 执行一次性命令（exec 通道，不影响交互 shell），返回合并 stdout+stderr。
  /// 监控采集、docker 操作都走这里。
  Future<String> runCommand(
    String command, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final client = _client;
    if (client == null || !isConnected) {
      throw StateError('连接尚未建立');
    }
    final exec = await client.execute(command);
    final buffer = BytesBuilder(copy: false);
    final done = Completer<void>();
    final subs = <StreamSubscription<dynamic>>[];
    subs.add(exec.stdout.cast<List<int>>().listen(buffer.add, onDone: () {
      if (!done.isCompleted) done.complete();
    }));
    // docker logs 这类输出走 stderr，必须合并进来
    subs.add(exec.stderr.cast<List<int>>().listen(buffer.add));
    try {
      await done.future.timeout(timeout);
    } on TimeoutException {
      try {
        exec.close();
      } catch (_) {}
      rethrow;
    } finally {
      for (final sub in subs) {
        await sub.cancel();
      }
    }
    try {
      exec.close();
    } catch (_) {}
    return utf8.decode(buffer.takeBytes(), allowMalformed: true);
  }

  /// 打开一条持续输出的 exec 通道（如 docker logs -f），
  /// 通过 [onLine] 逐行回调，返回用于取消的订阅句柄。
  Future<ExecStreamHandle> streamCommand(
    String command,
    void Function(String line) onLine,
  ) async {
    final client = _client;
    if (client == null || !isConnected) {
      throw StateError('连接尚未建立');
    }
    final exec = await client.execute(command);
    final decoder = const Utf8Decoder(allowMalformed: true);
    var pending = '';
    // 超过 256KB 还没有换行（如无换行的大 JSON / 二进制）就强制吐出一行，
    // 避免缓冲无上限增长把内存与后续排版撑爆
    const pendingLimit = 256 * 1024;
    final sub = exec.stdout.cast<List<int>>().listen((chunk) {
      pending += decoder.convert(chunk);
      while (true) {
        final index = pending.indexOf('\n');
        if (index < 0) break;
        onLine(pending.substring(0, index));
        pending = pending.substring(index + 1);
      }
      if (pending.length > pendingLimit) {
        onLine(pending);
        pending = '';
      }
    });
    final errSub = exec.stderr.cast<List<int>>().listen((chunk) {
      onLine(decoder.convert(chunk).trim());
    });
    return ExecStreamHandle(
      close: () async {
        await sub.cancel();
        await errSub.cancel();
        try {
          exec.close();
        } catch (_) {}
      },
    );
  }

  void resize(int columns, int rows, [int pixelWidth = 0, int pixelHeight = 0]) {
    final shell = _shell;
    if (shell == null || !isConnected) return;
    if (columns <= 0 || rows <= 0) return;
    try {
      shell.resizeTerminal(columns, rows, pixelWidth, pixelHeight);
    } catch (_) {
      // 忽略尺寸发送失败
    }
  }

  Future<void> disconnect() async {
    await _teardown();
    if (status != SessionStatus.failed) {
      _setStatus(SessionStatus.closed, '已断开连接');
    }
  }

  Future<void> dispose() => _teardown();

  // ---------------------------------------------------------------- SFTP

  Future<SftpClient> _ensureSftp() async {
    final existing = _sftp;
    if (existing != null) return existing;

    final client = _client;
    if (client == null || !isConnected) {
      throw StateError('连接尚未建立');
    }
    final sftp = await client.sftp();
    await sftp.handshake;
    _sftp = sftp;
    if (homeDirectory == null) {
      try {
        homeDirectory = await sftp.absolute('.');
      } catch (_) {
        homeDirectory = '/';
      }
    }
    return sftp;
  }

  Future<String> resolveInitialDirectory() async {
    await _ensureSftp();
    return homeDirectory ?? '/';
  }

  Future<List<RemoteEntry>> listDir(String path) async {
    final sftp = await _ensureSftp();
    final names = await sftp.listdir(RemotePath.normalize(path));
    final entries = <RemoteEntry>[];
    for (final item in names) {
      if (item.filename == '.' || item.filename == '..') continue;
      final attr = item.attr;
      final modified = attr.modifyTime;
      entries.add(
        RemoteEntry(
          name: item.filename,
          isDir: attr.isDirectory,
          isLink: attr.isSymbolicLink,
          size: attr.size ?? 0,
          modified: modified == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(modified * 1000),
          mode: _modeString(attr.mode),
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// 只列出目录（供目录树懒加载）
  Future<List<String>> listDirectories(String path) async {
    final entries = await listDir(path);
    final directories = entries
        .where((entry) => entry.isDir)
        .map((entry) => entry.name)
        .toList();
    directories.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return directories;
  }

  /// 读取文本文件内容（超过 [maxBytes] 时截断）
  Future<RemoteFileContent> readTextFile(
    String path, {
    int maxBytes = 1024 * 1024,
  }) async {
    final sftp = await _ensureSftp();
    final normalized = RemotePath.normalize(path);
    final attrs = await sftp.stat(normalized);
    final size = attrs.size ?? 0;

    final file = await sftp.open(normalized, mode: SftpFileOpenMode.read);
    try {
      final builder = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in file.read()) {
        final remaining = maxBytes - total;
        if (remaining <= 0) break;
        builder.add(
          chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
        );
        total += chunk.length;
      }
      final bytes = builder.takeBytes();
      return RemoteFileContent(
        text: utf8.decode(bytes, allowMalformed: true),
        size: size,
        truncated: size > bytes.length,
        binary: bytes.contains(0),
      );
    } finally {
      await file.close();
    }
  }

  /// 覆盖写回文本文件
  Future<void> writeTextFile(String path, String content) async {
    final sftp = await _ensureSftp();
    final normalized = RemotePath.normalize(path);
    final file = await sftp.open(
      normalized,
      mode:
          SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.writeBytes(Uint8List.fromList(utf8.encode(content)));
    } finally {
      await file.close();
    }
  }

  Future<void> mkdir(String path) async {
    final sftp = await _ensureSftp();
    await sftp.mkdir(RemotePath.normalize(path));
  }

  Future<void> rename(String from, String to) async {
    final sftp = await _ensureSftp();
    await sftp.rename(RemotePath.normalize(from), RemotePath.normalize(to));
  }

  Future<void> deleteFile(String path) async {
    final sftp = await _ensureSftp();
    await sftp.remove(RemotePath.normalize(path));
  }

  /// 递归删除文件或目录
  Future<void> deleteRecursive(String path) async {
    final sftp = await _ensureSftp();
    final normalized = RemotePath.normalize(path);
    final attrs = await sftp.stat(normalized);
    if (!attrs.isDirectory) {
      await sftp.remove(normalized);
      return;
    }
    for (final entry in await listDir(normalized)) {
      await deleteRecursive(RemotePath.join(normalized, entry.name));
    }
    await sftp.rmdir(normalized);
  }

  Future<void> mkdirRecursive(String path) async {
    final sftp = await _ensureSftp();
    final normalized = RemotePath.normalize(path);
    if (normalized == '/' || normalized.isEmpty) return;
    try {
      final attrs = await sftp.stat(normalized);
      if (attrs.isDirectory) return;
    } catch (_) {
      // 不存在，继续创建
    }
    await mkdirRecursive(RemotePath.parent(normalized));
    try {
      await sftp.mkdir(normalized);
    } catch (_) {
      // 并发创建时可能已存在，忽略
    }
  }

  Future<int> remoteFileSize(String path) async {
    final sftp = await _ensureSftp();
    final attrs = await sftp.stat(RemotePath.normalize(path));
    return attrs.size ?? 0;
  }

  /// 下载单个文件到本地。
  ///
  /// 先写入 `<name>.fastshell-part`，全部读完后原子改名成目标文件：
  /// 中途失败/取消不会留下半截文件覆盖掉本地已有的同名文件。
  Future<void> downloadFile(TransferTask task) async {
    final sftp = await _ensureSftp();
    final remote = await sftp.open(
      RemotePath.normalize(task.remotePath),
      mode: SftpFileOpenMode.read,
    );

    final local = File(task.localPath);
    await local.parent.create(recursive: true);
    final partPath = '${task.localPath}.fastshell-part';
    final part = File(partPath);
    try {
      await part.delete();
    } catch (_) {
      // 残留的临时文件不存在也无所谓
    }

    RandomAccessFile? writer;
    var completed = false;
    try {
      writer = await part.open(mode: FileMode.write);
      await for (final chunk in remote.read()) {
        if (task.cancelRequested) break;
        await writer.writeFrom(chunk);
        task.updateProgress(task.transferredBytes + chunk.length);
      }
      completed = !task.cancelRequested;
      await writer.flush();
    } finally {
      try {
        await writer?.close();
      } catch (_) {}
      try {
        await remote.close();
      } catch (_) {}
    }

    if (!completed) {
      try {
        await part.delete();
      } catch (_) {}
      return;
    }

    // 原子替换目标文件
    try {
      if (await local.exists()) await local.delete();
    } catch (_) {}
    await part.rename(task.localPath);
  }

  /// 上传本地文件到远端。
  ///
  /// 先写入 `<name>.fastshell-part`，全部写完后用 rename 原子替换目标文件
  /// （OpenSSH 的 posix-rename 扩展支持覆盖已存在目标）：
  /// 中途失败/取消不会在远端留下半截文件，也不会破坏远端已有的同名文件。
  Future<void> uploadFile(TransferTask task) async {
    final sftp = await _ensureSftp();
    final remotePath = RemotePath.normalize(task.remotePath);
    await mkdirRecursive(RemotePath.parent(remotePath));

    final partPath = '$remotePath.fastshell-part';
    try {
      final remote = await sftp.open(
        partPath,
        mode:
            SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      try {
        final writer = remote.write(
          _fileChunks(File(task.localPath), task),
          onProgress: (bytes) => task.updateProgress(bytes),
        );
        await writer.done;
      } finally {
        await remote.close();
      }

      if (task.cancelRequested) {
        try {
          await sftp.remove(partPath);
        } catch (_) {}
        return;
      }

      await sftp.rename(partPath, remotePath);
    } catch (_) {
      // 失败清理：不在远端留半截临时文件
      try {
        await sftp.remove(partPath);
      } catch (_) {}
      rethrow;
    }
  }

  Stream<Uint8List> _fileChunks(File file, TransferTask task) async* {
    final reader = await file.open();
    try {
      const chunkSize = 256 * 1024;
      while (true) {
        if (task.cancelRequested) break;
        final chunk = await reader.read(chunkSize);
        if (chunk.isEmpty) break;
        yield chunk;
      }
    } finally {
      await reader.close();
    }
  }

  // ------------------------------------------------------------- internals

  /// 是否已就 ZMODEM 提示过一次（每次会话最多提示一次，避免刷屏）
  bool _zmodemNotified = false;

  /// ZMODEM 启动序列的关键特征：rz/sz 一启动就发 `**\x18B00…`
  static const String _zmodemSignature = '\x18B00';

  /// 远端输出统一入口：透传给 UI，并顺路检测 rz/sz。
  ///
  /// xterm 终端不支持 ZMODEM 协议，rz 的握手序列会以乱码形式留在屏幕上
  /// （`waiting to receive.*xB01000000…`）。与其让用户对着一屏乱码，
  /// 不如当场说明并指路 SFTP 面板——那里有拖拽、进度与断点重试。
  void _onRemoteOutput(String data) {
    if (!_zmodemNotified && data.contains(_zmodemSignature)) {
      _zmodemNotified = true;
      onOutput?.call(data);
      onOutput?.call(
        '\r\n\x1b[33m'
        '[Fast Shell] 检测到 rz（ZMODEM）：终端不支持该协议，无法完成传输。\r\n'
        '  按 Ctrl+X 取消 rz，然后用 SFTP 面板上传（支持拖拽、进度与失败重试）。\r\n'
        '\x1b[0m\r\n',
      );
      return;
    }
    onOutput?.call(data);
  }

  /// 连接成功后注入远端 shell 的一次性美化命令（不回显、执行完自动清屏）：
  /// - 彩色 PS1：绿色 user@host + 蓝色路径（仅 bash 生效，sh 下跳过）
  /// - PS1 以 `\n` 开头：cat 无换行结尾的文件时，输出与提示符分两行，
  ///   提示符永远从行首开始（代价是正常输出后多一个空行，P10k 同款观感）
  /// - ls / grep / egrep 自动着色
  /// - stty -echo / echo 包裹，避免命令文本出现在终端里
  static const String _shellInitCommand =
      "stty -echo 2>/dev/null; "
      "alias ls='ls --color=auto' 2>/dev/null; "
      "alias grep='grep --color=auto' 2>/dev/null; "
      "alias egrep='egrep --color=auto' 2>/dev/null; "
      "if [ -n \"\$BASH_VERSION\" ]; then "
      "PS1='\\n\\[\\033[01;32m\\]\\u@\\h\\[\\033[0m\\]:\\[\\033[01;34m\\]\\w\\[\\033[0m\\]\\\$ '; "
      "export PS1; fi; "
      "stty echo 2>/dev/null; clear\n";

  List<SSHKeyPair>? _loadIdentities() {
    if (connection.authType != SshAuthType.privateKey) return null;

    var pem = connection.privateKeyPem.trim();
    if (pem.isEmpty && connection.privateKeyPath.trim().isNotEmpty) {
      final file = File(connection.privateKeyPath.trim());
      if (!file.existsSync()) {
        throw StateError('私钥文件不存在：${connection.privateKeyPath}');
      }
      pem = file.readAsStringSync();
    }
    if (pem.isEmpty) return null;

    // 处理粘贴时把换行转义成字面量 \n 的情况
    if (!pem.contains('\n') && pem.contains(r'\n')) {
      pem = pem.replaceAll(r'\n', '\n');
    }

    final passphrase = connection.passphrase.isEmpty
        ? null
        : connection.passphrase;
    return SSHKeyPair.fromPem(pem, passphrase);
  }

  Future<void> _teardown() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();

    try {
      await _sftp?.close();
    } catch (_) {}
    _sftp = null;

    try {
      _shell?.close();
    } catch (_) {}
    _shell = null;

    try {
      _client?.close();
      await _client?.done.timeout(const Duration(seconds: 3));
    } catch (_) {}
    _client = null;
  }

  void _setStatus(SessionStatus next, String? message) {
    status = next;
    error = message;
    onStatus?.call(next, message);
  }

  static String _describeError(Object error) {
    if (error is SocketException) {
      final code = error.osError?.message ?? error.message;
      if (code.contains('Connection refused')) {
        return '连接被拒绝：端口没开放或 sshd 没在监听（检查端口号）';
      }
      if (code.contains('Connection reset') || code.contains('reset by peer')) {
        return '连接被重置：多为安全组/防火墙拦了本机 IP，或 sshd 限制来源';
      }
      if (code.contains('No route to host') ||
          code.contains('unreachable')) {
        return '网络不可达：检查 IP 是否正确、本机网络是否正常';
      }
      if (code.contains('timed out') || code.contains('Timeout')) {
        return '连接超时：IP 通不了或端口被防火墙丢弃';
      }
      return '无法连接到主机（$code）';
    }
    if (error is TimeoutException) {
      return '连接超时，请检查主机地址与网络';
    }
    if (error is SSHAuthFailError || error is SSHAuthAbortError) {
      return '认证失败：请检查用户名、密码或私钥';
    }
    if (error is SSHHostkeyError) {
      return '主机密钥校验未通过';
    }
    if (error is SSHChannelRequestError) {
      return '远端拒绝了会话请求（${error.message}）';
    }
    if (error is SSHKeyDecryptError) {
      return '私钥解密失败：密码短语不正确';
    }
    if (error is StateError) {
      return error.message;
    }
    return error.toString();
  }

  static String _modeString(SftpFileMode? mode) {    if (mode == null) return '----------';
    final type = switch (mode.type) {
      SftpFileType.directory => 'd',
      SftpFileType.symbolicLink => 'l',
      SftpFileType.blockDevice => 'b',
      SftpFileType.characterDevice => 'c',
      SftpFileType.pipe => 'p',
      SftpFileType.socket => 's',
      _ => '-',
    };
    final buffer = StringBuffer(type);
    void triplet(bool read, bool write, bool execute) {
      buffer
        ..write(read ? 'r' : '-')
        ..write(write ? 'w' : '-')
        ..write(execute ? 'x' : '-');
    }

    triplet(mode.userRead, mode.userWrite, mode.userExecute);
    triplet(mode.groupRead, mode.groupWrite, mode.groupExecute);
    triplet(mode.otherRead, mode.otherWrite, mode.otherExecute);
    return buffer.toString();
  }
}
