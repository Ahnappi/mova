import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../../data/repositories/chat/chat_repository.dart';
import '../../../domain/models/chat/chat_message.dart';
// 必须显式导入：result.dart 中的 Error 会覆盖 dart:core 的同名类。
import '../../../utils/result.dart';

/// 消息视图模型（ViewModel 层）：维护消息列表并发送文本。
class ChatViewModel extends ChangeNotifier {
  ChatViewModel({required ChatRepository chatRepository})
      : _chatRepository = chatRepository {
    _subscription = _chatRepository.messages.listen(_onMessage);
  }

  final ChatRepository _chatRepository;
  final Logger _log = Logger('ChatViewModel');

  StreamSubscription<ChatMessage>? _subscription;

  List<ChatMessage> _messages = const [];
  String? _errorMessage;

  /// 消息列表（按时间先后）。
  List<ChatMessage> get messages => _messages;

  /// 最近一次发送错误（无错误时为 null）。
  String? get errorMessage => _errorMessage;

  /// 发送文本（空白内容直接忽略）。
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    _errorMessage = null;
    notifyListeners();

    final result = await _chatRepository.send(trimmed);
    if (result is Error<void>) {
      _errorMessage = result.error.toString();
      _log.warning('发送失败：${result.error}');
      notifyListeners();
    }
  }

  void _onMessage(ChatMessage message) {
    _messages = <ChatMessage>[..._messages, message];
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
