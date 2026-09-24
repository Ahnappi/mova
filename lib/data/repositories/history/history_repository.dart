import '../../../domain/models/history/session_record.dart';

/// 连接记录仓储（Repository 抽象）。
///
/// 上层只依赖本接口：以后换成数据库（如 sqlite）时 UI 与 ViewModel 无需改动。
abstract class HistoryRepository {
  /// 连接记录流（增删改时推送全量）。
  Stream<List<SessionRecord>> get sessions;

  /// 当前记录快照。
  List<SessionRecord> get currentSessions;

  /// 当前进行中的会话 id（未连接时为 null）。
  String? get activeSessionId;

  /// 从磁盘载入记录。
  Future<void> load();

  /// 开启一次会话（连接成功时调用），返回会话 id。
  Future<String> startSession({
    required String peerName,
    required String peerIp,
  });

  /// 补全 / 修正对端信息（握手名晚于连接到达时调用）。
  Future<void> updateSessionPeer(
    String sessionId, {
    String? peerName,
    String? peerIp,
  });

  /// 结束一次会话（断开时调用）。
  Future<void> endSession(String sessionId);

  /// 追加一条消息；[sessionId] 为空时落到当前会话。
  Future<void> appendMessage(SessionMessage message, {String? sessionId});

  /// 新增或更新一条文件记录；[sessionId] 为空时落到当前会话。
  Future<void> upsertFile(SessionFile file, {String? sessionId});

  /// 删除一次连接记录。
  Future<void> deleteSession(String sessionId);

  /// 清空全部连接记录。
  Future<void> clearAll();

  /// 记录文件路径（用于在「数据存放位置」里展示）。
  Future<String> historyFilePath();

  /// 释放资源（退出前把未落盘的改动写完）。
  Future<void> dispose();
}
