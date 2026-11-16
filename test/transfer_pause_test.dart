import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mova/data/services/chat/chat_transport_service.dart';
import 'package:mova/domain/models/transfer/transfer_event.dart';
import 'package:mova/domain/models/transfer/transfer_task.dart';
import 'package:mova/utils/result.dart';

void main() {
  test('双方暂停各自独立，单方继续不能解除对方暂停', () {
    final task = TransferTask(id: 1, fileName: 'a', totalBytes: 100,
        direction: TransferDirection.sending, status: TransferStatus.transferring,
        pausedLocally: true, pausedRemotely: true);
    final localResumed = task.copyWith(pausedLocally: false);
    expect(localResumed.isPaused, isTrue);
    expect(localResumed.isActive, isTrue);
    expect(localResumed.copyWith(pausedRemotely: false).isPaused, isFalse);
    expect(task.copyWith(status: TransferStatus.completed).isPaused, isFalse);
  });

  test('暂停不发送文件块，文字仍可送达；继续成功，暂停时取消也能返回', () async {
    final sender = ChatTransportService();
    final receiver = ChatTransportService();
    final directory = await Directory.systemTemp.createTemp('mova_pause_test');
    final source = File('${directory.path}/sample.bin');
    await source.writeAsBytes(List<int>.filled(65536, 7));
    addTearDown(() async {
      await sender.dispose();
      await receiver.dispose();
      await directory.delete(recursive: true);
    });
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    await receiver.startListening(port);
    await sender.connect('127.0.0.1', port);
    final chunks = <ChunkReceived>[];
    final subscription = receiver.transferEvents.listen((event) {
      if (event is ChunkReceived) chunks.add(event);
    });
    addTearDown(subscription.cancel);
    sender.setFilePaused(1, true);
    final sending = sender.sendFileStream(fileId: 1, path: source.path);
    var completed = false;
    unawaited(sending.then((_) { completed = true; }));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(completed, isFalse);
    expect(chunks, isEmpty);
    final message = receiver.messages.first;
    await sender.send('暂停期间仍能聊天');
    await message.timeout(const Duration(seconds: 5));
    sender.setFilePaused(1, false);
    expect(await sending.timeout(const Duration(seconds: 5)), isA<Ok<SentFileSummary>>());

    sender.setFilePaused(2, true);
    var cancelled = false;
    final second = sender.sendFileStream(fileId: 2, path: source.path,
        isCancelled: () => cancelled);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    cancelled = true;
    expect(await second.timeout(const Duration(seconds: 5)), isA<Error<SentFileSummary>>());
  });
}
