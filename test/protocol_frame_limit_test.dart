import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mova/data/services/chat/chat_transport_service.dart';
import 'package:mova/data/services/chat/protocol.dart';
import 'package:mova/domain/models/chat/connection_status.dart';

/// 手工拼一个帧头（可以填任意版本 / 类型 / 长度，用来伪造异常对端）。
Uint8List header(MessageType type, int length, {int version = frameVersion}) {
  final head = Uint8List(frameHeaderSize);
  head.setRange(0, 4, <int>[0x4D, 0x4F, 0x56, 0x41]); // MOVA
  head[4] = version;
  head[5] = type.value;
  head[6] = (length >> 24) & 0xFF;
  head[7] = (length >> 16) & 0xFF;
  head[8] = (length >> 8) & 0xFF;
  head[9] = length & 0xFF;
  return head;
}

/// 帧头 + payload（正常帧）。
Uint8List frame(MessageType type, Uint8List payload) {
  final bytes = Uint8List(frameHeaderSize + payload.length);
  bytes.setRange(0, frameHeaderSize, header(type, payload.length));
  bytes.setRange(frameHeaderSize, bytes.length, payload);
  return bytes;
}

/// 帧解析的安全边界：
/// 1. 帧头声明的长度必须在「等数据凑齐」**之前**就校验，
///    否则一个声明数 GB 的帧会让缓冲一路涨到内存耗尽；
/// 2. 版本不符、文件块过小同样是不可恢复的协议错误；
/// 3. 遇到这些错误必须断开连接，而不是继续在可疑数据上跑。
void main() {
  test('正常帧照旧解析', () {
    final reader = FrameReader();
    reader.add(frame(MessageType.text, Uint8List.fromList('{}'.codeUnits)));
    reader.add(
      frame(MessageType.fileChunk, Uint8List.fromList([0, 0, 0, 7, 1, 2, 3])),
    );

    final frames = reader.drain();
    expect(frames.length, 2);
    expect(frames.first.type, MessageType.text);
    expect(reader.hasViolation, isFalse);
  });

  test('声明数 GB 的数据块帧：立刻判违规，不等数据', () {
    final reader = FrameReader();
    // 只给一个帧头：长度校验必须在「还没有数据」时就生效。
    reader.add(header(MessageType.fileChunk, 3 * 1024 * 1024 * 1024));

    expect(reader.drain(), isEmpty);
    expect(reader.hasViolation, isTrue,
        reason: '巨帧声明应当在等数据之前就被拒绝');
    expect(reader.violation, contains('超过上限'));

    // 违规之后再灌 200MB 也不该继续缓冲（否则这个窗口就是漏的）。
    for (var i = 0; i < 200; i++) {
      reader.add(Uint8List(1024 * 1024));
    }
    expect(reader.drain(), isEmpty);
    expect(reader.violation, isNotNull);
  });

  test('控制帧超长同样被拒绝', () {
    final reader = FrameReader();
    reader.add(header(MessageType.text, maxControlPayloadLength + 1));

    expect(reader.drain(), isEmpty);
    expect(reader.hasViolation, isTrue);
  });

  test('帧格式版本不符：拒绝', () {
    final reader = FrameReader();
    reader.add(
      header(MessageType.text, 8, version: frameVersion + 1),
    );

    expect(reader.drain(), isEmpty);
    expect(reader.hasViolation, isTrue);
    expect(reader.violation, contains('版本'));
  });

  test('文件块帧太短（没有数据）：拒绝', () {
    final reader = FrameReader();
    reader.add(header(MessageType.fileChunk, 4));
    reader.add(Uint8List(4));

    expect(reader.drain(), isEmpty);
    expect(reader.hasViolation, isTrue);
  });

  test('违规状态不会连坐下一次连接（reset 后恢复）', () {
    final reader = FrameReader();
    reader.add(header(MessageType.fileChunk, 3 * 1024 * 1024 * 1024));
    // 违规是在解析（drain）时判出来的，不是收到字节的那一刻。
    reader.drain();
    expect(reader.hasViolation, isTrue);

    reader.reset();
    expect(reader.hasViolation, isFalse);
    reader.add(frame(MessageType.text, Uint8List.fromList('{}'.codeUnits)));
    expect(reader.drain().single.type, MessageType.text);
  });

  test('本机也不会编码出超限的帧', () {
    expect(
      () => encodeFrame(
        MessageType.text,
        Uint8List(maxControlPayloadLength + 1),
      ),
      throwsArgumentError,
    );
  });

  test('对端声明一个巨帧：立即断开而不是无限缓冲', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final host = ChatTransportService();
    addTearDown(() => host.dispose());
    await host.startListening(port);

    final disconnected = Completer<void>();
    String? notice;
    host.status.listen((status) {
      if (status == ConnectionStatus.disconnected &&
          !disconnected.isCompleted) {
        disconnected.complete();
      }
    });
    host.notices.listen((text) {
      notice ??= text;
    });

    final peer = await Socket.connect('127.0.0.1', port);
    addTearDown(() => peer.destroy());
    peer.add(header(MessageType.fileChunk, 3 * 1024 * 1024 * 1024));
    await peer.flush();

    await disconnected.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('收到巨帧声明后没有断开'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(notice, isNotNull, reason: '断开了也得让用户知道原因');
    expect(notice, contains('异常'));
    expect(host.isBusy, isFalse);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
