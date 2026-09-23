import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../../config/app_config.dart';
import '../../../domain/models/chat/chat_message.dart';
import '../../../domain/models/chat/connection_status.dart';
import '../../../domain/models/transfer/transfer_event.dart';
import '../../../utils/result.dart';
import 'protocol.dart';

/// 传输数据源（Service 层）：TCP 监听 + 连接 + 二进制分帧收发。
///
/// 同一时刻只维护一个会话（无论是自己连出去还是对方连进来）。
///
/// 大文件相关要点：
/// - 发送端按 1MiB 分块读盘并逐块写出，**不把整个文件读进内存**；
/// - 每积累 [AppConfig.maxInFlightBytes] 就 `flush()` 一次做背压，
///   防止「读盘快于网络」时把内存撑爆；
/// - 接收端按帧解析后立即同步写盘，同样只持有单个块。
class ChatTransportService {
  ServerSocket? _server;
  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSub;

  final FrameReader _reader = FrameReader();

  final StreamController<ChatMessage> _messageController =
      StreamController<ChatMessage>.broadcast();
  final StreamController<ConnectionStatus> _statusController =
      StreamController<ConnectionStatus>.broadcast();
  final StreamController<TransferEvent> _transferController =
      StreamController<TransferEvent>.broadcast();

  /// 收到的文本消息流。
  Stream<ChatMessage> get messages => _messageController.stream;

  /// 连接状态流。
  Stream<ConnectionStatus> get status => _statusController.stream;

  /// 文件传输相关事件流。
  Stream<TransferEvent> get transferEvents => _transferController.stream;

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
          await Socket.connect(host, port, timeout: AppConfig.connectTimeout);
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
    _write(encodeJsonFrame(MessageType.text, {
      'name': localName,
      'text': text,
      'ts': DateTime.now().toIso8601String(),
    }));
    return Result.ok(null);
  }

  // ---------- 文件传输 ----------

  /// 向对端发起文件发送请求（此时还不传数据，等对端同意）。
  Future<Result<void>> sendFileOffer({
    required int fileId,
    required String name,
    required int size,
  }) async {
    if (_socket == null) {
      return Result.error(Exception('尚未连接，无法发送文件'));
    }
    _write(encodeJsonFrame(MessageType.fileOffer, {
      'id': fileId,
      'name': name,
      'size': size,
    }));
    return Result.ok(null);
  }

  /// 同意接收对端发来的文件。
  void sendFileAccept(int fileId) =>
      _write(encodeJsonFrame(MessageType.fileAccept, {'id': fileId}));

  /// 拒绝接收对端发来的文件。
  void sendFileReject(int fileId, {String? reason}) =>
      _write(encodeJsonFrame(MessageType.fileReject, {'id': fileId, 'reason': reason}));

  /// 通知对端：该文件已取消（不要再发 / 可以丢弃了）。
  void sendFileCancel(int fileId, {String? reason}) =>
      _write(encodeJsonFrame(MessageType.fileCancel, {'id': fileId, 'reason': reason}));

  /// 声明该文件的数据已全部发完。
  void sendFileEnd(int fileId) =>
      _write(encodeJsonFrame(MessageType.fileEnd, {'id': fileId}));

  /// 流式发送文件内容（不含 offer / end，只负责数据块）。
  ///
  /// - [onProgress] 每写完一块回调一次已发送字节数；
  /// - [isCancelled] 每块前检查一次，true 则立即停止（用于中途取消）；
  /// - 返回 `Error` 表示失败或被取消。
  Future<Result<void>> sendFileStream({
    required int fileId,
    required String path,
    void Function(int sentBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final socket = _socket;
    if (socket == null) {
      return Result.error(Exception('尚未连接，无法发送文件'));
    }

    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!await file.exists()) {
        return Result.error(Exception('文件不存在：$path'));
      }
      raf = await file.open(mode: FileMode.read);
      final total = await raf.length();

      final chunk = Uint8List(AppConfig.fileChunkSize);
      var sent = 0;
      var inFlight = 0;

      while (sent < total) {
        if (isCancelled?.call() ?? false) {
          return Result.error(Exception('已取消发送'));
        }

        final read = await raf.readInto(chunk);
        if (read <= 0) break;

        final data = Uint8List.sublistView(chunk, 0, read);
        _write(encodeChunkFrame(fileId, data));

        sent += read;
        inFlight += read;
        onProgress?.call(sent);

        // 背压：积压到阈值就等 socket 真正写出去，避免内存被读盘速度拖爆。
        if (inFlight >= AppConfig.maxInFlightBytes) {
          await socket.flush();
          inFlight = 0;
        }
      }

      await socket.flush();
      return Result.ok(null);
    } catch (e) {
      return Result.error(Exception('发送文件失败：$e'));
    } finally {
      await raf?.close();
    }
  }

  /// 断开当前会话（监听仍保留，对方可再次连入）。
  Future<void> disconnect() async {
    await _socketSub?.cancel();
    _socketSub = null;
    _socket?.destroy();
    _socket = null;
    remoteName = null;
    _statusController.add(ConnectionStatus.disconnected);
  }

  /// 释放全部资源（含监听与流控制器）。
  Future<void> dispose() async {
    await disconnect();
    await _closeServer();
    await _messageController.close();
    await _statusController.close();
    await _transferController.close();
  }

  Future<void> _closeServer() async {
    await _server?.close();
    _server = null;
  }

  void _write(Uint8List frame) {
    _socket?.add(frame);
  }

  /// 接管一个已建立的 socket（入站或出站）。
  void _attach(Socket socket) {
    _socketSub?.cancel();
    _socket?.destroy();

    _socket = socket;
    remoteName = null;
    _statusController.add(ConnectionStatus.connected);

    // 建连后互报名字。
    _write(encodeJsonFrame(MessageType.hello, {'name': localName}));

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

  /// 收到字节：交给帧解析器，逐帧分发。
  void _feed(Uint8List chunk) {
    _reader.add(chunk);
    for (final frame in _reader.drain()) {
      _handleFrame(frame);
    }
  }

  void _handleFrame(Frame frame) {
    try {
      switch (frame.type) {
        case MessageType.hello:
          remoteName = frame.json['name'] as String? ?? '对端';
        case MessageType.text:
          final json = frame.json;
          _messageController.add(
            ChatMessage(
              text: json['text'] as String? ?? '',
              sender: json['name'] as String? ?? '对端',
              timestamp: DateTime.tryParse(json['ts'] as String? ?? '') ?? DateTime.now(),
              isSelf: false,
            ),
          );
        case MessageType.fileOffer:
          final json = frame.json;
          _transferController.add(
            OfferReceived(
              fileId: json['id'] as int? ?? 0,
              name: json['name'] as String? ?? '未知文件',
              size: json['size'] as int? ?? 0,
            ),
          );
        case MessageType.fileAccept:
          _transferController.add(AcceptReceived(frame.json['id'] as int? ?? 0));
        case MessageType.fileReject:
          final json = frame.json;
          _transferController.add(
            RejectReceived(
              fileId: json['id'] as int? ?? 0,
              reason: json['reason'] as String?,
            ),
          );
        case MessageType.fileChunk:
          _transferController.add(
            ChunkReceived(
              fileId: chunkFileId(frame.payload),
              data: chunkData(frame.payload),
            ),
          );
        case MessageType.fileEnd:
          _transferController.add(EndReceived(frame.json['id'] as int? ?? 0));
        case MessageType.fileCancel:
          final json = frame.json;
          _transferController.add(
            CancelReceived(
              fileId: json['id'] as int? ?? 0,
              reason: json['reason'] as String?,
            ),
          );
      }
    } catch (e) {
      // 单帧解析失败不应影响整条连接。
      _transferController.addError(Exception('帧解析失败：$e'));
    }
  }
}
