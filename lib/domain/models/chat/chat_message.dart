/// 一条聊天消息（Domain 层，纯 Dart 模型）。
class ChatMessage {
  const ChatMessage({
    required this.text,
    required this.sender,
    required this.timestamp,
    required this.isSelf,
    this.sessionId = '',
  });

  /// 消息正文。
  final String text;

  /// 发送方名称。
  final String sender;

  /// 发送时间。
  final DateTime timestamp;

  /// 是否为本机发出（用于 UI 区分左右气泡）。
  final bool isSelf;

  /// 所属会话标识。
  ///
  /// 换设备连接后，旧会话的迟到消息会被丢弃，
  /// 不会混进新会话的聊天记录里。
  final String sessionId;
}
