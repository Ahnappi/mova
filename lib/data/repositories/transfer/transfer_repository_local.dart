import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';

import '../../../config/app_config.dart';
import '../../../domain/models/chat/connection_status.dart';
import '../../../domain/models/transfer/picked_file.dart';
import '../../../domain/models/transfer/transfer_event.dart';
import '../../../domain/models/transfer/transfer_task.dart';
import '../../../utils/result.dart';
import '../../services/chat/chat_transport_service.dart';
import '../../services/transfer/file_storage_service.dart';
import 'transfer_repository.dart';

/// 文件传输仓储的本地（TCP 直连）实现。
///
/// 职责：把「协议事件」翻译成「任务与进度」，并负责真正的落盘 / 读盘。
/// 大文件安全性体现在三处：
/// 1. 读写都按块进行（[AppConfig.fileChunkSize]），从不整体载入内存；
/// 2. 发送端有背压（在 Service 层），接收端同步写盘；
/// 3. 帧解析自己维护缓冲，避免随文件增大而线性增长的拷贝。
class TransferRepositoryLocal implements TransferRepository {
  TransferRepositoryLocal(this._transport, this._storage) {
    _eventSub = _transport.transferEvents.listen(
      _onEvent,
      onError: (Object error) => _log.warning('传输事件异常：$error'),
    );
    _statusSub = _transport.status.listen(_onStatus);
  }

  final ChatTransportService _transport;
  final FileStorageService _storage;
  final Logger _log = Logger('TransferRepositoryLocal');

  final Map<int, TransferTask> _tasks = <int, TransferTask>{};
  final Map<int, RandomAccessFile> _incomingFiles = <int, RandomAccessFile>{};
  final Map<int, _SpeedState> _speedStates = <int, _SpeedState>{};
  final Map<int, Completer<void>> _finishWaiters = <int, Completer<void>>{};
  final Set<int> _cancelRequests = <int>{};

  final List<_QueuedSend> _queue = <_QueuedSend>[];
  bool _pumping = false;

  final Random _random = Random();
  final StreamController<List<TransferTask>> _controller =
      StreamController<List<TransferTask>>.broadcast();

  StreamSubscription<TransferEvent>? _eventSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  DateTime? _lastEmit;

  @override
  Stream<List<TransferTask>> get tasks => _controller.stream;

  @override
  List<TransferTask> get currentTasks =>
      List<TransferTask>.unmodifiable(_tasks.values);

  // ---------- 发送 ----------

  @override
  Future<Result<void>> sendFiles(List<PickedFile> files) async {
    if (files.isEmpty) return Result.ok(null);

    for (final file in files) {
      final id = _newId();
      _tasks[id] = TransferTask(
        id: id,
        fileName: file.name,
        totalBytes: file.size,
        direction: TransferDirection.sending,
        status: TransferStatus.waiting,
        localPath: file.path,
      );
      _queue.add(_QueuedSend(id: id, file: file));
    }
    _emit(force: true);
    unawaited(_pumpQueue());
    return Result.ok(null);
  }

  /// 串行处理发送队列：一次只向对端提一个请求，等它终结再提下一个。
  Future<void> _pumpQueue() async {
    if (_pumping) return;
    _pumping = true;

    while (_queue.isNotEmpty) {
      final item = _queue.removeAt(0);
      final task = _tasks[item.id];
      if (task == null || !task.isActive) continue;

      final offer = await _transport.sendFileOffer(
        fileId: item.id,
        name: item.file.name,
        size: item.file.size,
      );
      if (offer is Error<void>) {
        _finish(item.id, TransferStatus.failed, error: offer.error.toString());
        continue;
      }

      await _waitForFinish(item.id);
    }

    _pumping = false;
  }

  Future<void> _waitForFinish(int id) {
    final completer = Completer<void>();
    _finishWaiters[id] = completer;
    return completer.future;
  }

  /// 对端同意后，真正开始推流。
  Future<void> _startSending(int id) async {
    final task = _tasks[id];
    final path = task?.localPath;
    if (task == null || path == null) return;

    _update(id, status: TransferStatus.transferring, transferredBytes: 0);

    final result = await _transport.sendFileStream(
      fileId: id,
      path: path,
      onProgress: (sent) => _updateProgress(id, sent),
      isCancelled: () => _cancelRequests.contains(id),
    );

    if (result is Error<void>) {
      final canceled = _cancelRequests.remove(id);
      _finish(
        id,
        canceled ? TransferStatus.canceled : TransferStatus.failed,
        error: canceled ? null : result.error.toString(),
      );
      if (canceled) _transport.sendFileCancel(id, reason: '发送方取消');
      return;
    }

    _transport.sendFileEnd(id);
    _finish(id, TransferStatus.completed);
  }

  // ---------- 接收 ----------

  @override
  Future<Result<void>> accept(int fileId, {String? saveDirectory}) async {
    final task = _tasks[fileId];
    if (task == null ||
        task.direction != TransferDirection.receiving ||
        task.status != TransferStatus.waiting) {
      return Result.error(Exception('该接收请求已失效'));
    }

    final directory = saveDirectory ?? await _storage.currentSaveDirectory();
    final target = await _storage.resolveTargetPath(directory, task.fileName);

    try {
      _incomingFiles[fileId] = await File(target).open(mode: FileMode.write);
    } catch (e) {
      _finish(fileId, TransferStatus.failed, error: '无法写入 $target：$e');
      return Result.error(Exception('无法写入文件：$e'));
    }

    _update(
      fileId,
      status: TransferStatus.transferring,
      localPath: target,
      transferredBytes: 0,
    );
    _transport.sendFileAccept(fileId);
    return Result.ok(null);
  }

  @override
  Future<void> reject(int fileId) async {
    final task = _tasks[fileId];
    if (task == null || task.direction != TransferDirection.receiving) return;
    _transport.sendFileReject(fileId);
    _finish(fileId, TransferStatus.rejected);
  }

  // ---------- 取消 ----------

  @override
  Future<void> cancel(int fileId) async {
    final task = _tasks[fileId];
    if (task == null || !task.isActive) return;

    // 还在排队（尚未发给对端）的发送请求：直接出队并终结。
    if (task.direction == TransferDirection.sending &&
        task.status == TransferStatus.waiting) {
      _queue.removeWhere((item) => item.id == fileId);
      _finish(fileId, TransferStatus.canceled);
      return;
    }

    _cancelRequests.add(fileId);
    if (task.direction == TransferDirection.receiving) {
      await _abortIncoming(fileId, deletePartial: true);
      _transport.sendFileCancel(fileId, reason: '接收方取消');
      _finish(fileId, TransferStatus.canceled);
    }
    // 发送中的任务由推流循环检测到取消标记后自行终结。
  }

  Future<void> _abortIncoming(int id, {required bool deletePartial}) async {
    final raf = _incomingFiles.remove(id);
    if (raf != null) {
      try {
        await raf.close();
      } catch (_) {
        // 关闭失败不影响后续清理。
      }
    }
    if (!deletePartial) return;
    final path = _tasks[id]?.localPath;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删除失败不影响状态流转。
    }
  }

  // ---------- 事件处理 ----------

  void _onEvent(TransferEvent event) {
    switch (event) {
      case OfferReceived():
        _tasks[event.fileId] = TransferTask(
          id: event.fileId,
          fileName: event.name,
          totalBytes: event.size,
          direction: TransferDirection.receiving,
          status: TransferStatus.waiting,
        );
        _emit(force: true);
      case AcceptReceived():
        unawaited(_startSending(event.fileId));
      case RejectReceived():
        _finish(event.fileId, TransferStatus.rejected, error: event.reason);
      case ChunkReceived():
        _onChunk(event.fileId, event.data);
      case EndReceived():
        unawaited(_onEnd(event.fileId));
      case CancelReceived():
        unawaited(_onCancel(event.fileId, event.reason));
    }
  }

  void _onChunk(int fileId, List<int> data) {
    final raf = _incomingFiles[fileId];
    final task = _tasks[fileId];
    if (raf == null || task == null) return;

    try {
      raf.writeFromSync(data);
    } catch (e) {
      _finish(fileId, TransferStatus.failed, error: '写入失败：$e');
      return;
    }
    _updateProgress(fileId, task.transferredBytes + data.length);
  }

  Future<void> _onEnd(int fileId) async {
    final raf = _incomingFiles.remove(fileId);
    if (raf != null) {
      try {
        await raf.flush();
        await raf.close();
      } catch (e) {
        _finish(fileId, TransferStatus.failed, error: '收尾失败：$e');
        return;
      }
    }
    _finish(fileId, TransferStatus.completed);
  }

  Future<void> _onCancel(int fileId, String? reason) async {
    await _abortIncoming(fileId, deletePartial: true);
    _finish(fileId, TransferStatus.canceled, error: reason ?? '对方取消了传输');
  }

  void _onStatus(ConnectionStatus status) {
    if (status == ConnectionStatus.connected) return;
    // 连接断了：所有进行中的任务标记失败，并把队列清空。
    for (final id in _tasks.keys.toList()) {
      final task = _tasks[id];
      if (task == null || !task.isActive) continue;
      _cancelRequests.add(id);
      unawaited(_abortIncoming(id, deletePartial: true));
      _finish(id, TransferStatus.failed, error: '连接已断开');
    }
    _queue.clear();
  }

  // ---------- 状态更新 ----------

  void _updateProgress(int id, int transferredBytes) {
    final task = _tasks[id];
    if (task == null) return;

    final now = DateTime.now();
    var speed = task.speedBytesPerSecond;
    final state = _speedStates[id] ??= _SpeedState(now, task.transferredBytes);
    final elapsedMs = now.difference(state.at).inMilliseconds;
    if (elapsedMs >= 500) {
      final delta = transferredBytes - state.bytes;
      speed = (delta * 1000 / elapsedMs).round();
      state
        ..at = now
        ..bytes = transferredBytes;
    }

    _tasks[id] = task.copyWith(
      transferredBytes: transferredBytes,
      speedBytesPerSecond: speed,
    );
    _emit();
  }

  void _update(
    int id, {
    TransferStatus? status,
    int? transferredBytes,
    String? localPath,
  }) {
    final task = _tasks[id];
    if (task == null) return;
    _tasks[id] = task.copyWith(
      status: status,
      transferredBytes: transferredBytes,
      localPath: localPath,
    );
    _emit(force: true);
  }

  void _finish(int id, TransferStatus status, {String? error}) {
    final task = _tasks[id];
    if (task == null) return;

    _tasks[id] = task.copyWith(
      status: status,
      error: error,
      speedBytesPerSecond: 0,
      transferredBytes:
          status == TransferStatus.completed ? task.totalBytes : task.transferredBytes,
    );
    _speedStates.remove(id);
    _emit(force: true);

    final waiter = _finishWaiters.remove(id);
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  /// 节流推送：高频分块时按 [AppConfig.progressThrottle] 合并刷新，
  /// 终结状态则立即推送。
  void _emit({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        _lastEmit != null &&
        now.difference(_lastEmit!) < AppConfig.progressThrottle) {
      return;
    }
    _lastEmit = now;
    if (_controller.isClosed) return;
    _controller.add(List<TransferTask>.unmodifiable(_tasks.values));
  }

  int _newId() {
    while (true) {
      final id = _random.nextInt(0x7FFFFFFF);
      if (!_tasks.containsKey(id)) return id;
    }
  }

  @override
  Future<void> dispose() async {
    for (final id in _incomingFiles.keys.toList()) {
      await _abortIncoming(id, deletePartial: true);
    }
    await _eventSub?.cancel();
    await _statusSub?.cancel();
    await _controller.close();
  }
}

/// 待发送队列项。
class _QueuedSend {
  _QueuedSend({required this.id, required this.file});

  final int id;
  final PickedFile file;
}

/// 速度测算状态。
class _SpeedState {
  _SpeedState(this.at, this.bytes);

  DateTime at;
  int bytes;
}
