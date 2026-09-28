import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../../data/repositories/chat/chat_repository.dart';
import '../../../data/repositories/history/history_repository.dart';
import '../../../domain/models/chat/chat_message.dart';
import '../../../domain/models/chat/connection_status.dart';
import '../../../domain/models/history/session_record.dart';
// 必须显式导入：result.dart 中的 Error 会覆盖 dart:core 的同名类。
import '../../../utils/result.dart';

/// 消息视图模型（ViewModel 层）：维护消息列表并发送文本。
///
/// 消息按**会话**隔离：换一台设备连接就清空上一次的聊天记录，
/// 并且丢弃迟到（属于旧会话）的消息，避免两台设备的内容混在一起。
class ChatViewModel extends ChangeNotifier {
  ChatViewModel({
    required ChatRepository chatRepository,
    required HistoryRepository historyRepository,
  })  : _chatRepository = chatRepository,
        _historyRepository = historyRepository {
    _subscription = _chatRepository.messages.listen(_onMessage);
    _statusSub = _chatRepository.status.listen(_onStatus);
  }

  final ChatRepository _chatRepository;
  final HistoryRepository _historyRepository;
  final Logger _log = Logger('ChatViewModel');

  StreamSubscription<ChatMessage>? _subscription;
  StreamSubscription<ConnectionStatus>? _statusSub;

  List<ChatMessage> _messages = const [];
  String? _errorMessage;

  /// 当前会话标识（未连接时为 null）。
  String? _sessionId;

  /// 消息列表（按时间先后）。
  List<ChatMessage> get messages => _messages;

  /// 最近一次发送错误（无错误时为 null）。
  String? get errorMessage => _errorMessage;

  /// 发送文本；返回**是否真的发出去了**。
  ///
  /// 界面必须据此决定要不要清空输入框：发不出去（比如内容太长）时
  /// 清空，等于把用户刚写的一大段话直接弄丢。
  Future<bool> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;

    _errorMessage = null;
    notifyListeners();

    final result = await _chatRepository.send(trimmed);
    if (result is Error<void>) {
      _errorMessage = result.error.toString();
      _log.warning('发送失败：${result.error}');
      notifyListeners();
      return false;
    }
    return true;
  }

  void _onStatus(ConnectionStatus status) {
    if (status != ConnectionStatus.connected) return;
    // 新会话：清掉上一台设备留下来的消息。
    _sessionId = _chatRepository.sessionId;
    if (_messages.isEmpty) return;
    _messages = const [];
    notifyListeners();
  }

  void _onMessage(ChatMessage message) {
    // 上一条连接迟到的消息：会话已经换了人，不能再显示。
    final current = _sessionId;
    if (current != null &&
        message.sessionId.isNotEmpty &&
        message.sessionId != current) {
      return;
    }

    _messages = <ChatMessage>[..._messages, message];
    notifyListeners();

    unawaited(
      _historyRepository.appendMessage(
        SessionMessage(
          text: message.text,
          sender: message.sender,
          isSelf: message.isSelf,
          timestamp: message.timestamp,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }
}
