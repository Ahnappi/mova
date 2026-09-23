/// 一条聊天消息（Domain 层，纯 Dart 模型）。
class ChatMessage {
  const ChatMessage({
    required this.text,
    required this.sender,
    required this.timestamp,
    required this.isSelf,
  });

  /// 消息正文。
  final String text;

  /// 发送方名称。
  final String sender;

  /// 发送时间。
  final DateTime timestamp;

  /// 是否为本机发出（用于 UI 区分左右气泡）。
  final bool isSelf;
}
