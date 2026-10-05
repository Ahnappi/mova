import 'dart:async';

import 'package:mova/data/repositories/history/history_repository.dart';
import 'package:mova/data/repositories/transfer/transfer_repository.dart';
import 'package:mova/domain/models/history/session_record.dart';
import 'package:mova/domain/models/transfer/picked_file.dart';
import 'package:mova/domain/models/transfer/transfer_task.dart';
import 'package:mova/utils/result.dart';

/// 只记录调用、不碰磁盘与网络的传输仓储。
///
/// 待接收面板那几条用例只关心「点了什么、传下去哪些 id」，
/// 真起 socket 与写文件既慢又会让失败原因变得难读。
class FakeTransferRepository implements TransferRepository {
  final StreamController<List<TransferTask>> _controller =
      StreamController<List<TransferTask>>.broadcast();

  /// 批量接收收到的 id。
  final List<int> acceptedMany = <int>[];

  /// 批量拒绝收到的 id。
  final List<int> rejectedMany = <int>[];

  /// 单个接收收到的 id。
  final List<int> accepted = <int>[];

  /// 单个拒绝收到的 id。
  final List<int> rejected = <int>[];

  /// 最近一次批量接收用的保存目录。
  String? lastAcceptDirectory;

  /// 批量接收要返回几个「实际接下」的数量（模拟部分成功）。
  ///
  /// 为 null 时按请求数返回，用来验证界面报的是请求数还是实际数。
  int? acceptManyResult;

  /// 目录选择器要返回的路径（null 表示用户取消）。
  String? directoryToPick;

  /// 目录选择期间要做的事（模拟「用户翻文件夹的那几十秒」）。
  Future<void> Function()? onPickingDirectory;

  /// 推一组任务快照给订阅者（界面就是这么拿到待接收列表的）。
  void emit(List<TransferTask> tasks) => _controller.add(tasks);

  @override
  Stream<List<TransferTask>> get tasks => _controller.stream;

  @override
  List<TransferTask> get currentTasks => const <TransferTask>[];

  @override
  String get sessionId => _sessionId;

  String _sessionId = '';

  /// 改掉它就等于「中途断了又连上另一台设备」。
  set sessionId(String value) => _sessionId = value;

  @override
  Future<Result<void>> accept(int fileId, {String? saveDirectory}) async {
    accepted.add(fileId);
    return const Result.ok(null);
  }

  @override
  Future<Result<int>> acceptMany(
    Iterable<int> fileIds, {
    String? saveDirectory,
  }) async {
    acceptedMany.addAll(fileIds);
    lastAcceptDirectory = saveDirectory;
    return Result.ok(acceptManyResult ?? fileIds.length);
  }

  @override
  Future<void> reject(int fileId) async {
    rejected.add(fileId);
  }

  @override
  Future<void> rejectMany(Iterable<int> fileIds) async {
    rejectedMany.addAll(fileIds);
  }

  @override
  Future<void> cancel(int fileId) async {}

  @override
  Future<Result<int>> retry(int fileId) async => const Result.ok(0);

  @override
  Future<Result<void>> sendFiles(List<PickedFile> files) async =>
      const Result.ok(null);

  @override
  Future<({List<PickedFile> accepted, List<String> ignored})>
      pickFilesToSend() async =>
          (accepted: const <PickedFile>[], ignored: const <String>[]);

  @override
  Future<({List<PickedFile> accepted, List<String> ignored})> filesFromPaths(
    List<String> paths,
  ) async =>
      (accepted: const <PickedFile>[], ignored: const <String>[]);

  @override
  Future<String> currentSaveDirectory() async => '/tmp/mova-test-save';

  @override
  Future<String?> pickSaveDirectory({String? dialogTitle}) async {
    // 用户翻文件夹的那段时间：这段时间里任务列表完全可以变。
    await onPickingDirectory?.call();
    return directoryToPick;
  }

  @override
  Future<void> rememberSaveDirectory(String directory) async {}

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

/// 什么都不做的连接记录仓储：这几条用例只关心传输面板，不关心历史落盘。
class NoopHistoryRepository implements HistoryRepository {
  @override
  Stream<List<SessionRecord>> get sessions => const Stream.empty();

  @override
  List<SessionRecord> get currentSessions => const <SessionRecord>[];

  @override
  String? get activeSessionId => null;

  @override
  Future<void> load() async {}

  @override
  Future<String> startSession({
    required String peerName,
    required String peerIp,
  }) async =>
      'session';

  @override
  Future<void> updateSessionPeer(
    String sessionId, {
    String? peerName,
    String? peerIp,
  }) async {}

  @override
  Future<void> endSession(String sessionId) async {}

  @override
  Future<void> appendMessage(
    SessionMessage message, {
    String? sessionId,
  }) async {}

  @override
  Future<void> upsertFile(SessionFile file, {String? sessionId}) async {}

  @override
  Future<void> deleteSession(String sessionId) async {}

  @override
  Future<void> clearAll() async {}

  @override
  Future<int> applyRetention() async => 0;

  @override
  Future<String> historyFilePath() async => '/tmp/mova-test-history.json';

  @override
  Future<void> flush() async {}

  @override
  Future<void> dispose() async {}
}
