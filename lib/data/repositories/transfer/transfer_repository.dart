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

  /// 当前会话标识（未连接时为空串）。
  ///
  /// 界面需要它来回答一个问题：「用户刚才确认的那批文件，现在还算数吗」。
  /// 弹目录选择框要等用户翻好几层文件夹，期间完全可能断了又连上另一台
  /// 设备——那时手里的 fileId 全部属于上一通会话，绝不能再拿去发帧。
  String get sessionId;

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

  /// 一次同意多个文件（批量接收），返回**真正接下了几个**。
  ///
  /// 与逐个调用 [accept] 的区别不只是省事：保存目录的**那些检查只做一次**
  /// （建目录、写权限探测、是否支持原子提交），而不是每个文件重复一遍。
  /// 一次接收几十个文件时，这部分是实实在在的 IO。
  ///
  /// 返回值必须是「实际数量」而不是「请求数量」：
  /// 目录检查与逐文件准备都是 await，期间可能断连、换会话、被用户取消，
  /// 请求 10 个最后只处理了 3 个是完全正常的。照着请求数报「已接收 10 个」
  /// 等于骗人，界面上那 7 个其实还在对面等着。
  ///
  /// 失败（Error）只表示**一个都没接成**；部分成功照样走 Ok，
  /// 用返回值区分——已经同意的那些仍然生效，不会为了「要么全成功要么
  /// 全不做」把准备好的临时文件又删掉。
  Future<Result<int>> acceptMany(
    Iterable<int> fileIds, {
    String? saveDirectory,
  });

  /// 拒绝接收。
  Future<void> reject(int fileId);

  /// 一次拒绝多个文件（批量接收里「没勾选的那些」）。
  ///
  /// 必须显式拒绝而不是放着不管：发送端为每个请求都挂着一个计时器，
  /// 不回应的话它要等满 120 秒才自己放弃。
  Future<void> rejectMany(Iterable<int> fileIds);

  /// 取消（发送中或接收中都可以调用）。
  Future<void> cancel(int fileId);

  /// 释放资源。
  Future<void> dispose();
}
