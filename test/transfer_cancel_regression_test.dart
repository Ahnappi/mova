import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mova/config/app_config.dart';
import 'package:mova/data/repositories/transfer/transfer_repository_local.dart';
import 'package:mova/data/services/chat/chat_transport_service.dart';
import 'package:mova/data/services/storage/settings_service.dart';
import 'package:mova/data/services/storage/storage_service.dart';
import 'package:mova/data/services/transfer/file_storage_service.dart';
import 'package:mova/domain/models/chat/connection_status.dart';
import 'package:mova/domain/models/transfer/picked_file.dart';
import 'package:mova/domain/models/transfer/transfer_event.dart';
import 'package:mova/domain/models/transfer/transfer_task.dart';

/// 取消后必须真的停止推流，否则残留数据块会堵住后续请求帧——
/// 用户的表现就是「取消一次之后，再发文件对端半天/完全没反应」。
///
/// 这里用真实的 loopback TCP 跑一遍完整收发链路来锁住这个行为。
void main() {
  late Directory temp;
  late ChatTransportService sender;
  late ChatTransportService receiver;
  late TransferRepositoryLocal senderRepo;
  late TransferRepositoryLocal receiverRepo;

  FileStorageService fileStorage() => FileStorageService(
        settingsService: SettingsService(StorageService()),
        storageService: StorageService(),
      );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mova_cancel_test');

    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    receiver = ChatTransportService();
    sender = ChatTransportService();

    final ready = Completer<void>();
    receiver.status.listen((status) {
      if (status == ConnectionStatus.connected && !ready.isCompleted) {
        ready.complete();
      }
    });

    await receiver.startListening(port);
    await sender.connect('127.0.0.1', port);

    await ready.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('对端未在 10 秒内接入'),
    );

    senderRepo = TransferRepositoryLocal(sender, fileStorage());
    receiverRepo = TransferRepositoryLocal(receiver, fileStorage());
  });

  tearDown(() async {
    await senderRepo.dispose();
    await receiverRepo.dispose();
    await sender.dispose();
    await receiver.dispose();
    try {
      await temp.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响测试结果。
    }
  });

  /// 造一个指定大小的临时文件（内容全 0，只关心体积）。
  Future<File> makeFile(String name, int bytes) async {
    final file = File('${temp.path}/$name');
    final raf = await file.open(mode: FileMode.write);
    final block = Uint8List(1024 * 1024);
    var written = 0;
    while (written < bytes) {
      final size = (bytes - written) < block.length ? bytes - written : block.length;
      await raf.writeFrom(Uint8List.sublistView(block, 0, size));
      written += size;
    }
    await raf.close();
    return file;
  }

  test('接收方取消后，发送方停止推流，后续文件仍能送达', () async {
    const totalBytes = 120 * 1024 * 1024; // 120 MiB
    final big = await makeFile('big.bin', totalBytes);
    final small = await makeFile('small.bin', 64 * 1024);
    final saveDir = Directory('${temp.path}/save')..createSync();

    // 统计接收方实际收到的数据块数量（大文件的 id 要等收到请求才知道）。
    var bigChunks = 0;
    int? bigFileId;
    receiver.transferEvents.listen((event) {
      if (event is ChunkReceived && event.fileId == bigFileId) bigChunks++;
    });

    var cancelRequested = false;

    final secondOffer = Completer<int>();
    receiverRepo.tasks.listen((tasks) {
      for (final task in tasks) {
        // 第一次传输：到了一块以上就取消。
        if (task.fileName == 'big.bin' && task.status == TransferStatus.waiting) {
          bigFileId ??= task.id;
          unawaited(receiverRepo.accept(task.id, saveDirectory: saveDir.path));
        }
        if (task.fileName == 'big.bin' &&
            !cancelRequested &&
            task.transferredBytes >= AppConfig.fileChunkSize) {
          cancelRequested = true;
          unawaited(receiverRepo.cancel(task.id));
        }
        // 第二次传输的请求必须照样弹出来，否则用户没法点「接收」。
        if (task.fileName == 'small.bin' &&
            task.status == TransferStatus.waiting &&
            !secondOffer.isCompleted) {
          secondOffer.complete(task.id);
        }
      }
    });

    await senderRepo.sendFiles([
      PickedFile(path: big.path, name: 'big.bin', size: totalBytes),
    ]);
    // 立刻排队第二个文件：它必须等第一个终结后才能发出。
    await senderRepo.sendFiles([
      PickedFile(path: small.path, name: 'small.bin', size: 64 * 1024),
    ]);

    final secondId = await secondOffer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw TimeoutException(
        '取消之后第二个文件请求始终没到——说明第一次的推流没有停下来',
      ),
    );

    // 让残留数据再飞一会儿，确认发送方真的不再继续推。
    await Future<void>.delayed(const Duration(seconds: 2));

    final totalChunks = (totalBytes / AppConfig.fileChunkSize).ceil();
    expect(
      bigChunks,
      lessThan(totalChunks),
      reason: '取消后发送方应立刻停止推流，实际却把整个文件都推完了',
    );

    // 第二个文件要能正常接收完成。
    await receiverRepo.accept(secondId, saveDirectory: saveDir.path);
    final saved = File('${saveDir.path}/small.bin');
    var length = 0;
    for (var i = 0; i < 100 && length < 64 * 1024; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (await saved.exists()) length = await saved.length();
    }
    expect(length, 64 * 1024, reason: '第二个文件没有完整落盘');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
