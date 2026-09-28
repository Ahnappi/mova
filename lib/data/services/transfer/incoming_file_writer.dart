import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../../config/app_config.dart';
import '../../../utils/checksum.dart';

/// 接收端后台落盘器（Service 层）。
///
/// 为什么要把写盘搬出主 isolate：
/// 接收端每来一个 4MiB 的数据块就要写一次盘。同步写在主 isolate 上会
/// **整块时间占住事件循环**——界面掉帧、按钮点不动，而磁盘越慢越明显。
/// 放到独立 isolate 后，主 isolate 只负责「收帧 → 转发 → 更新进度」，
/// 写盘与 CRC32 计算都在后台完成。
///
/// 背压：每个已发出但未确认落盘的数据块都计入 [pendingBytes]；
/// 上层在超过 [AppConfig.maxPendingWriteBytes] 时暂停读 socket，
/// 让 TCP 的接收窗口去压住对端的发送速度，内存占用因此始终有界。
///
/// 降级：万一平台不允许起 isolate（或资源不足），会自动退回主 isolate 的
/// 异步写盘（`writeFrom` 走的是 I/O 线程池，不会阻塞事件循环），
/// 功能完全一致，只是少了跨 isolate 的并行度。
class IncomingFileWriter {
  IncomingFileWriter({void Function(int fileId, Object error)? onError})
      : onError = onError;

  /// 某一块写盘失败时的回调（调用方据此让任务失败，而不是干等收尾）。
  void Function(int fileId, Object error)? onError;

  final Logger _log = Logger('IncomingFileWriter');

  Isolate? _isolate;
  SendPort? _toWriter;
  StreamSubscription<Object?>? _replySub;

  /// 降级路径使用的落盘核心（与主 isolate 共用同一份实现）。
  final _WriterCore _local = _WriterCore();
  Future<void> _localChain = Future.value();

  int _pendingBytes = 0;
  int _requestId = 0;
  final Map<int, Completer<Object?>> _waiters = <int, Completer<Object?>>{};

  /// 已交给后台、尚未确认落盘的字节数（背压依据）。
  int get pendingBytes => _pendingBytes;

  /// 一块数据确认落盘后回调（上层据此判断何时恢复读取 socket）。
  void Function(int fileId, int bytes)? onWriteAck;

  /// 是否运行在独立 isolate 中（false 表示已降级）。
  bool get isIsolated => _toWriter != null;

  /// 启动后台 isolate（失败则自动降级，不抛异常）。
  ///
  /// 幂等：重复调用返回同一次启动的结果。
  Future<void> start() {
    final pending = _starting;
    if (pending != null) return pending;
    return _starting = _start();
  }

  Future<void>? _starting;

  Future<void> _start() async {
    if (_isolate != null || _toWriter != null) return;

    final fromWriter = ReceivePort();
    final ready = Completer<SendPort>();

    _replySub = fromWriter.listen((Object? message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message == null) {
        // isolate 退出：把等待中的请求全部叫醒，并切回降级模式。
        _onWriterExit();
        return;
      }
      _onReply(message as List<Object?>);
    });

    try {
      _isolate = await Isolate.spawn(
        _writerEntry,
        fromWriter.sendPort,
        errorsAreFatal: false,
      );
      _toWriter = await ready.future.timeout(const Duration(seconds: 10));
    } catch (e) {
      _log.warning('后台落盘 isolate 启动失败，退回主 isolate 写盘：$e');
      await _replySub?.cancel();
      _replySub = null;
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _toWriter = null;
    }
  }

  /// 打开（创建）一个临时文件准备写入。
  ///
  /// [exclusive] 为 true 时以独占方式创建：目标已存在就报错，
  /// **绝不覆盖**。接收端的临时文件名是每次现生成的，但「生成名字」和
  /// 「创建文件」之间仍有窗口（两个同名接收、或上次崩溃留下的残留），
  /// 覆盖写会直接把已有文件截断成 0，因此必须由文件系统来兜这一下。
  ///
  /// 先等启动结束再发命令：否则可能出现「open 走降级路径、后续 write 发给
  /// isolate」的错位（isolate 里没有这个文件，数据会被静默丢弃）。
  Future<void> open(int fileId, String path, {bool exclusive = true}) async {
    await start();
    await _request(_Cmd.open, fileId, payload: <Object?>[path, exclusive]);
  }

  /// 追加一块数据。
  ///
  /// 同步返回：真正的写入在后台排队执行，失败通过 [onError] 回调。
  void write(int fileId, Uint8List data) {
    if (data.isEmpty) return;
    final length = data.length;
    _pendingBytes += length;
    _request(_Cmd.write, fileId, payload: data).then(
      (_) {
        _pendingBytes -= length;
        onWriteAck?.call(fileId, length);
      },
      onError: (Object error, StackTrace _) {
        _pendingBytes -= length;
        onError?.call(fileId, error);
      },
    );
  }

  /// 收尾：刷盘、关闭，并返回实际写入的字节数与 CRC32。
  ///
  /// 命令是在后台**按序**执行的，所以这条请求的结果一定包含了之前所有
  /// 数据块，可以直接拿来和对端声明的大小/校验值对账。
  Future<WriteSummary> close(int fileId) async {
    final result = await _request(_Cmd.close, fileId);
    return result as WriteSummary;
  }

  /// 放弃：关闭临时文件（**不删除**）。
  ///
  /// 删除由调用方负责，而且要用它自己捕获的路径：后台 abort 与删除之间
  /// 跨着 await，期间完全可能换会话，届时任务表已经被清空，
  /// 按任务表判断「还删不删」就会把临时文件漏在磁盘上。
  Future<void> abort(int fileId) => _request(_Cmd.abort, fileId);

  /// 释放后台 isolate。
  Future<void> dispose() async {
    _toWriter?.send(<Object?>[_Cmd.stop.index, 0, 0, null]);
    await _replySub?.cancel();
    _replySub = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _toWriter = null;
    _failAllWaiters(StateError('落盘器已释放'));
    await _closeLocalFiles();
  }

  // ---------- 内部 ----------

  Future<Object?> _request(_Cmd cmd, int fileId, {Object? payload}) {
    final id = ++_requestId;
    final completer = Completer<Object?>();
    _waiters[id] = completer;
    _send(<Object?>[cmd.index, fileId, id, payload]);
    return completer.future;
  }

  void _send(List<Object?> message) {
    final port = _toWriter;
    if (port != null) {
      port.send(message);
      return;
    }
    // 降级：同一份逻辑在本 isolate 里按序执行。
    final command = message;
    _localChain = _localChain.catchError((Object _) {}).then((_) async {
      final reply = await _WriterCore.handle(_local, command);
      _deliver(reply);
    });
  }

  void _onReply(List<Object?> reply) => _deliver(reply);

  void _deliver(List<Object?> reply) {
    final id = reply[0] as int;
    final error = reply[1] as String?;
    final value = reply[2];

    final waiter = _waiters.remove(id);
    if (waiter == null) return;

    if (error != null) {
      waiter.completeError(StateError(error));
      return;
    }
    waiter.complete(value);
  }

  void _onWriterExit() {
    _log.warning('后台落盘 isolate 意外退出，切换为主 isolate 写盘');
    _toWriter = null;
    _isolate = null;
    _failAllWaiters(StateError('后台落盘中断'));
  }

  void _failAllWaiters(Object error) {
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _waiters.clear();
    _pendingBytes = 0;
  }

  Future<void> _closeLocalFiles() async {
    _localChain = _localChain.catchError((Object _) {}).then((_) async {
      await _local.closeAll();
    });
    return _localChain;
  }

  /// isolate 入口：收命令、按序执行、回执。
  static void _writerEntry(SendPort toHost) {
    final inbox = ReceivePort();
    toHost.send(inbox.sendPort);

    final core = _WriterCore();
    // 命令必须串行执行：open 尚未完成时到达的 write 不能插队。
    Future<void> chain = Future.value();

    inbox.listen((Object? message) {
      chain = chain.catchError((Object _) {}).then((_) async {
        final reply = await _WriterCore.handle(core, message as List<Object?>);
        toHost.send(reply);
      });
    });
  }
}

/// 落盘核心：isolate 内与降级路径共用。
class _WriterCore {
  final Map<int, RandomAccessFile> _files = <int, RandomAccessFile>{};
  final Map<int, Crc32> _crcs = <int, Crc32>{};
  final Map<int, int> _bytes = <int, int>{};

  /// 处理一条命令，返回 `[requestId, error, value]`。
  static Future<List<Object?>> handle(_WriterCore core, List<Object?> command) {
    final cmd = _Cmd.values[command[0] as int];
    final fileId = command[1] as int;
    final id = command[2] as int;
    final payload = command[3];

    Future<Object?> run() async {
      switch (cmd) {
        case _Cmd.open:
          final spec = payload as List<Object?>;
          final path = spec[0] as String;
          final exclusive = spec[1] as bool? ?? false;
          final file = File(path);
          if (exclusive) {
            // 已存在则抛错：让调用方换一个名字重试，而不是截断已有文件。
            await file.create(exclusive: true);
          }
          core._files[fileId] = await file.open(mode: FileMode.write);
          core._crcs[fileId] = Crc32();
          core._bytes[fileId] = 0;
          return null;
        case _Cmd.write:
          final data = payload as Uint8List;
          final raf = core._files[fileId];
          if (raf == null) return null;
          final crc = core._crcs[fileId];
          if (AppConfig.transferChecksumEnabled) crc?.add(data);
          await raf.writeFrom(data);
          core._bytes[fileId] = (core._bytes[fileId] ?? 0) + data.length;
          return null;
        case _Cmd.close:
          final raf = core._files.remove(fileId);
          if (raf == null) {
            return WriteSummary(
              bytes: core._bytes[fileId] ?? 0,
              checksum: core._crcs[fileId]?.value,
            );
          }
          await raf.flush();
          await raf.close();
          final summary = WriteSummary(
            bytes: core._bytes[fileId] ?? 0,
            checksum: core._crcs[fileId]?.value,
          );
          core._crcs.remove(fileId);
          core._bytes.remove(fileId);
          return summary;
        case _Cmd.abort:
          final raf = core._files.remove(fileId);
          core._crcs.remove(fileId);
          core._bytes.remove(fileId);
          if (raf == null) return null;
          try {
            await raf.flush();
            await raf.close();
          } catch (_) {
            // 关闭失败也要继续清理。
          }
          return null;
        case _Cmd.stop:
          await core.closeAll();
          return null;
      }
    }

    return run().then(
      (Object? value) => <Object?>[id, null, value],
      onError: (Object error) => <Object?>[id, error.toString(), null],
    );
  }

  Future<void> closeAll() async {
    for (final fileId in _files.keys.toList()) {
      final raf = _files.remove(fileId);
      _crcs.remove(fileId);
      _bytes.remove(fileId);
      if (raf == null) continue;
      try {
        await raf.flush();
        await raf.close();
      } catch (_) {
        // 收尾失败不影响其它文件。
      }
    }
  }
}

/// 一次接收的落盘结果。
class WriteSummary {
  const WriteSummary({required this.bytes, this.checksum});

  /// 实际写入的字节数。
  final int bytes;

  /// 内容的 CRC32（未开启校验时为 null）。
  final int? checksum;
}

enum _Cmd { open, write, close, abort, stop }
