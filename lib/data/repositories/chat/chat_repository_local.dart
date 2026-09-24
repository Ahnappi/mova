import 'dart:async';

import '../../../domain/models/chat/chat_message.dart';
import '../../../domain/models/chat/connection_status.dart';
import '../../../utils/result.dart';
import '../../services/chat/chat_transport_service.dart';
import 'chat_repository.dart';

/// 本地（TCP 直连）实现：把收发统一成一条消息流。
class ChatRepositoryLocal implements ChatRepository {
  ChatRepositoryLocal(this._service) {
    _serviceSub = _service.messages.listen(_controller.add);
  }

  final ChatTransportService _service;
  final StreamController<ChatMessage> _controller =
      StreamController<ChatMessage>.broadcast();

  StreamSubscription<ChatMessage>? _serviceSub;

  @override
  Stream<ChatMessage> get messages => _controller.stream;

  @override
  Stream<ConnectionStatus> get status => _service.status;

  @override
  String? get remoteName => _service.remoteName;

  @override
  String? get remoteAddress => _service.remoteAddress;

  @override
  set localName(String value) => _service.localName = value;

  @override
  Future<Result<void>> startListening(int port) => _service.startListening(port);

  @override
  Future<Result<void>> connect(String host, int port) => _service.connect(host, port);

  /// 发送文本；成功后把「本机消息」也并入消息流，便于 UI 统一渲染。
  @override
  Future<Result<void>> send(String text) async {
    final result = await _service.send(text);
    if (result is Error<void>) {
      return result;
    }
    _controller.add(
      ChatMessage(
        text: text,
        sender: _service.localName,
        timestamp: DateTime.now(),
        isSelf: true,
      ),
    );
    return Result.ok(null);
  }

  @override
  Future<void> disconnect() => _service.disconnect();

  @override
  Future<void> dispose() async {
    await _serviceSub?.cancel();
    await _service.dispose();
    await _controller.close();
  }
}
