import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../domain/models/chat/chat_message.dart';
import '../../../domain/models/chat/connection_status.dart';
import '../../../utils/result.dart';

/// 文本传输数据源（Service 层）：TCP 监听 + 连接 + 收发行式 JSON。
///
/// 协议：每条报文是一行 JSON，以 `\n` 结尾。
/// - `{"type":"hello","name":"xxx"}` —— 建连后互报名字；
/// - `{"type":"text","name":"xxx","text":"...","ts":"..."}` —— 文本消息。
///
/// 同一时刻只维护一个会话（无论是自己连出去还是对方连进来）。
class ChatTransportService {
  ServerSocket? _server;
  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSub;

  /// 粘包/半包缓冲：按字节累积，只在遇到完整一行时才解码，避免中文被截断。
  final BytesBuilder _buffer = BytesBuilder();

  final StreamController<ChatMessage> _messageController =
      StreamController<ChatMessage>.broadcast();
  final StreamController<ConnectionStatus> _statusController =
      StreamController<ConnectionStatus>.broadcast();

  /// 收到的消息流。
  Stream<ChatMessage> get messages => _messageController.stream;

  /// 连接状态流。
  Stream<ConnectionStatus> get status => _statusController.stream;

  /// 对端名称（收到对端 hello 后可用）。
  String? remoteName;

  /// 本机显示名，发送时作为 sender 带上。
  String localName = '本机';

  /// 开启 TCP 监听，等待其它设备连入。
  Future<Result<void>> startListening(int port) async {
    try {
      await _closeServer();
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      server.listen(
        _attach,
        onError: (Object _) => _statusController.add(ConnectionStatus.disconnected),
      );
      _server = server;
      return Result.ok(null);
    } catch (e) {
      return Result.error(Exception('监听端口 $port 失败：$e'));
    }
  }

  /// 主动连接 [host]:[port]。
  Future<Result<void>> connect(String host, int port) async {
    try {
      _statusController.add(ConnectionStatus.connecting);
      final socket =
          await Socket.connect(host, port, timeout: const Duration(seconds: 5));
      _attach(socket);
      return Result.ok(null);
    } catch (e) {
      _statusController.add(ConnectionStatus.disconnected);
      return Result.error(Exception('连接 $host:$port 失败：$e'));
    }
  }

  /// 发送一行文本消息。
  Future<Result<void>> send(String text) async {
    if (_socket == null) {
      return Result.error(Exception('尚未连接，无法发送'));
    }
    try {
      _sendRaw({
        'type': 'text',
        'name': localName,
        'text': text,
        'ts': DateTime.now().toIso8601String(),
      });
      return Result.ok(null);
    } catch (e) {
      return Result.error(Exception('发送失败：$e'));
    }
  }

  /// 断开当前会话（监听仍保留，对方可再次连入）。
  Future<void> disconnect() async {
    await _socketSub?.cancel();
    _socketSub = null;
    _socket?.destroy();
    _socket = null;
    remoteName = null;
    _buffer.clear();
    _statusController.add(ConnectionStatus.disconnected);
  }

  /// 释放全部资源（含监听与流控制器）。
  Future<void> dispose() async {
    await disconnect();
    await _closeServer();
    await _messageController.close();
    await _statusController.close();
  }

  Future<void> _closeServer() async {
    await _server?.close();
    _server = null;
  }

  void _sendRaw(Map<String, dynamic> json) {
    final socket = _socket;
    if (socket == null) return;
    socket.add(utf8.encode('${jsonEncode(json)}\n'));
  }

  /// 接管一个已建立的 socket（入站或出站）。
  void _attach(Socket socket) {
    _socketSub?.cancel();
    _socket?.destroy();
    _buffer.clear();

    _socket = socket;
    remoteName = null;
    _statusController.add(ConnectionStatus.connected);

    // 建连后互报名字。
    _sendRaw({'type': 'hello', 'name': localName});

    _socketSub = socket.listen(
      _feed,
      onDone: () {
        _socket = null;
        _statusController.add(ConnectionStatus.disconnected);
      },
      onError: (Object _) {
        _socket = null;
        _statusController.add(ConnectionStatus.disconnected);
      },
      cancelOnError: true,
    );
  }

  /// 收到字节流：按 `\n` 切分出完整的行，剩余部分留在缓冲里等下一包。
  void _feed(Uint8List chunk) {
    _buffer.add(chunk);
    final bytes = _buffer.takeBytes();

    var start = 0;
    while (true) {
      final lf = bytes.indexOf(10, start); // 10 == '\n'
      if (lf == -1) break;
      final line = bytes.sublist(start, lf);
      start = lf + 1;
      if (line.isNotEmpty) {
        _handleLine(utf8.decode(line, allowMalformed: true));
      }
    }
    if (start < bytes.length) {
      _buffer.add(bytes.sublist(start));
    }
  }

  void _handleLine(String line) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    switch (json['type'] as String?) {
      case 'hello':
        remoteName = json['name'] as String? ?? '对端';
      case 'text':
        _messageController.add(
          ChatMessage(
            text: json['text'] as String? ?? '',
            sender: json['name'] as String? ?? '对端',
            timestamp: DateTime.tryParse(json['ts'] as String? ?? '') ?? DateTime.now(),
            isSelf: false,
          ),
        );
      default:
        break;
    }
  }
}
