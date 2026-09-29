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

  /// 重新发送一个失败的文件任务，返回新任务的 id。
  ///
  /// 只有「自己发出去、并且失败了」的任务能重发：接收失败是对方那边
  /// 的问题，我们手里没有那份文件，重发无从谈起。
  Future<Result<int>> retry(int fileId);

  // ---------- 文件选取与保存位置 ----------
  //
  // 这几项本质是「要发给谁 / 存到哪」的业务规则的一部分，
  // 统一从这里暴露，ViewModel 就不再需要直接认识 FileStorageService。

  /// 弹出文件选择器，返回可发送的文件与被忽略的文件名。
  Future<({List<PickedFile> accepted, List<String> ignored})> pickFilesToSend();

  /// 把拖拽进来的路径转成可发送的文件。
  Future<({List<PickedFile> accepted, List<String> ignored})> filesFromPaths(
    List<String> paths,
  );

  /// 当前接收文件的保存目录。
  Future<String> currentSaveDirectory();

  /// 弹出目录选择器（用户取消时为 null）。
  Future<String?> pickSaveDirectory({String? dialogTitle});

  /// 记住用户选择的保存目录。
  Future<void> rememberSaveDirectory(String directory);

  /// 同意接收 [fileId]；[saveDirectory] 为空时用默认下载目录。
  Future<Result<void>> accept(int fileId, {String? saveDirectory});

  /// 拒绝接收。
  Future<void> reject(int fileId);

  /// 取消（发送中或接收中都可以调用）。
  Future<void> cancel(int fileId);

  /// 释放资源。
  Future<void> dispose();
}
