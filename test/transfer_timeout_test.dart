import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mova/data/repositories/transfer/transfer_repository_local.dart';
import 'package:mova/data/services/chat/chat_transport_service.dart';
import 'package:mova/data/services/storage/settings_service.dart';
import 'package:mova/data/services/storage/storage_service.dart';
import 'package:mova/data/services/transfer/file_storage_service.dart';
import 'package:mova/domain/models/chat/connection_status.dart';
import 'package:mova/domain/models/transfer/picked_file.dart';
import 'package:mova/domain/models/transfer/transfer_task.dart';

/// 超时分两类，各管各的：
/// - 等对端点接收：超过 offerResponseTimeout 判「对方没响应」；
/// - 传输中停滞：只有字节数长时间不动才算卡住。
///
/// 第二条尤其重要：早期的实现把 120 秒的「等待响应」计时器用在了整个任务上，
/// 于是正常传一个超过两分钟的大文件会被误判成「对方未响应」。
void main() {
  late Directory temp;
  late ChatTransportService sender;
  late ChatTransportService receiver;
  late Directory saveDir;

  FileStorageService fileStorage() => FileStorageService(
        settingsService: SettingsService(StorageService()),
        storageService: StorageService(),
      );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mova_timeout_test');
    saveDir = Directory('${temp.path}/save')..createSync();

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
    await ready.future.timeout(const Duration(seconds: 10));
  });

  tearDown(() async {
    await sender.dispose();
    await receiver.dispose();
    try {
      await temp.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响测试结果。
    }
  });

  Future<File> makeFile(String name, int bytes) async {
    final file = File('${temp.path}/$name');
    final raf = await file.open(mode: FileMode.write);
    final block = Uint8List(1024 * 1024);
    var written = 0;
    while (written < bytes) {
      final size =
          (bytes - written) < block.length ? bytes - written : block.length;
      await raf.writeFrom(Uint8List.sublistView(block, 0, size));
      written += size;
    }
    await raf.close();
    return file;
  }

  test('对方一直不点接收时，按「未响应」超时失败', () async {
    final senderRepo = TransferRepositoryLocal(
      sender,
      fileStorage(),
      offerTimeout: const Duration(milliseconds: 300),
      stallTimeout: const Duration(minutes: 5),
    );
    addTearDown(() => senderRepo.dispose());
    // 接收端什么都不做（不点接收、不拒绝）。
    final receiverRepo = TransferRepositoryLocal(receiver, fileStorage());
    addTearDown(() => receiverRepo.dispose());

    final file = await makeFile('ignored.bin', 32 * 1024);
    await senderRepo.sendFiles([
      PickedFile(path: file.path, name: 'ignored.bin', size: 32 * 1024),
    ]);

    TransferTask? task;
    for (var i = 0; i < 60; i++) {
      final tasks = senderRepo.currentTasks;
      if (tasks.length == 1 && tasks.single.isFinished) {
        task = tasks.single;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    expect(task, isNotNull, reason: '对方不理人时，发送任务应被超时终结');
    expect(task!.status, TransferStatus.failed);
    expect(task.error, contains('没有响应接收请求'));
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('持续传输的大文件不会被「等待响应」超时误杀', () async {
    // 关键：等待响应的上限远小于传输耗时。
    final senderRepo = TransferRepositoryLocal(
      sender,
      fileStorage(),
      offerTimeout: const Duration(milliseconds: 500),
      stallTimeout: const Duration(minutes: 5),
    );
    addTearDown(() => senderRepo.dispose());

    final receiverRepo = TransferRepositoryLocal(receiver, fileStorage());
    addTearDown(() => receiverRepo.dispose());

    receiverRepo.tasks.listen((tasks) {
      for (final task in tasks) {
        if (task.direction == TransferDirection.receiving &&
            task.status == TransferStatus.waiting) {
          unawaited(receiverRepo.accept(task.id, saveDirectory: saveDir.path));
        }
      }
    });

    const size = 150 * 1024 * 1024;
    final file = await makeFile('big.bin', size);
    await senderRepo.sendFiles([
      PickedFile(path: file.path, name: 'big.bin', size: size),
    ]);

    // 传输过程中持续采样：不能有「未响应」之类的超时失败。
    var transferringSamples = 0;
    TransferTask? last;
    for (var i = 0; i < 600; i++) {
      final tasks = senderRepo.currentTasks;
      if (tasks.isNotEmpty) {
        last = tasks.single;
        if (last.status == TransferStatus.transferring) {
          transferringSamples++;
        } else if (last.isFinished) {
          break;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // 采样到多次 transferring，说明这次传输确实跨过了看护计时器的多个周期。
    expect(
      transferringSamples,
      greaterThanOrEqualTo(5),
      reason: '传输太快结束，这条用例没能真正覆盖「长时间传输」',
    );
    expect(last, isNotNull);
    expect(last!.status, TransferStatus.completed);
    expect(await File('${saveDir.path}/big.bin').length(), size);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
