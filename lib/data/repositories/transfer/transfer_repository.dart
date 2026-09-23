import '../../../domain/models/transfer/picked_file.dart';
import '../../../domain/models/transfer/transfer_task.dart';
import '../../../utils/result.dart';

/// 文件传输仓储（Repository 抽象）。
///
/// 上层只依赖本接口：换传输方式（如加密、压缩）时 UI 与 ViewModel 无需改动。
abstract class TransferRepository {
  /// 任务列表流（含进度变化）。
  Stream<List<TransferTask>> get tasks;

  /// 当前任务快照。
  List<TransferTask> get currentTasks;

  /// 发送一组文件（内部串行发送，一次只向对端提一个请求）。
  Future<Result<void>> sendFiles(List<PickedFile> files);

  /// 同意接收 [fileId]；[saveDirectory] 为空时用默认下载目录。
  Future<Result<void>> accept(int fileId, {String? saveDirectory});

  /// 拒绝接收。
  Future<void> reject(int fileId);

  /// 取消（发送中或接收中都可以调用）。
  Future<void> cancel(int fileId);

  /// 释放资源。
  Future<void> dispose();
}
