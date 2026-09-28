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

  /// 当前会话标识（未连接时为 null）。
  ///
  /// 每次建立连接都会换新，上层据此隔离消息与文件任务。
  String? get sessionId;

  /// 被拒绝的入站连接提示（已占用时有人来连）。
  Stream<String> get notices;

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

  /// 退出专用：停止接收新连接并断开当前会话。
  ///
  /// 与 [disconnect] 的区别在于**监听也要关掉**：退出期间若只是断连，
  /// 另一台设备仍能连进来建新会话，而此刻传输仓储可能已在释放、
  /// 历史仓储可能已经关闭。封存之后的 [connect] / [startListening] /
  /// [send] 一律失败。
  Future<void> stopAcceptingConnections();

  /// 是否已停止接收（退出流程进行中）。
  bool get sealed;

  /// 断开当前会话。
  Future<void> disconnect();

  /// 释放资源。
  Future<void> dispose();
}
