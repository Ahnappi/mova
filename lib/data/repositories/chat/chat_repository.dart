import '../../../domain/models/chat/chat_message.dart';
import '../../../domain/models/chat/connection_status.dart';
import '../../../utils/result.dart';

/// 文本传输仓储（Repository 抽象）。
///
/// 上层只依赖本接口，底层换成其它传输方式时 UI 与 ViewModel 无需改动。
abstract class ChatRepository {
  /// 消息流（含本机发出与对端发来的）。
  Stream<ChatMessage> get messages;

  /// 连接状态流。
  Stream<ConnectionStatus> get status;

  /// 对端名称（握手后可用，未连接时为 null）。
  String? get remoteName;

  /// 对端 IP（连接建立后可用，未连接时为 null）。
  String? get remoteAddress;

  /// 本机显示名。
  set localName(String value);

  /// 开启监听，等待对端连入。
  Future<Result<void>> startListening(int port);

  /// 主动连接 [host]:[port]。
  Future<Result<void>> connect(String host, int port);

  /// 发送文本。
  Future<Result<void>> send(String text);

  /// 断开当前会话。
  Future<void> disconnect();

  /// 释放资源。
  Future<void> dispose();
}
