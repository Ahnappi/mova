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
import 'package:mova/domain/models/transfer/transfer_event.dart';
import 'package:mova/domain/models/transfer/transfer_task.dart';

/// 「发完」不等于「对方收到了」：
/// 发送端必须等接收端核对字节数、把临时文件改名成功后回执，才能算完成。
///
/// 这里用真实的 loopback TCP 跑完整链路，另外用「只收不回执」「谎报大小」
/// 两种坏情况验证失败路径。
void main() {
  late Directory temp;
  late ChatTransportService sender;
  late ChatTransportService receiver;
  late TransferRepositoryLocal senderRepo;
  late TransferRepositoryLocal receiverRepo;
  late Directory saveDir;

  FileStorageService fileStorage() => FileStorageService(
        settingsService: SettingsService(StorageService()),
        storageService: StorageService(),
      );

  /// 建一对已连上的 transport（port 随机）。
  Future<int> connectPair() async {
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
      onTimeout: () => throw TimeoutException('对端未接入'),
    );
    return port;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mova_complete_test');
    saveDir = Directory('${temp.path}/save')..createSync();
    await connectPair();
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

  Future<File> makeFile(String name, int bytes) async {
    final file = File('${temp.path}/$name');
    final raf = await file.open(mode: FileMode.write);
    final block = Uint8List(64 * 1024);
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

  test('完整传输：双方都完成，落盘字节数一致，临时文件不残留', () async {
    const size = 512 * 1024;
    final file = await makeFile('photo.jpg', size);

    // 收到请求就自动接收，模拟用户点了「接收」。
    receiverRepo.tasks.listen((tasks) {
      for (final task in tasks) {
        if (task.direction == TransferDirection.receiving &&
            task.status == TransferStatus.waiting) {
          unawaited(receiverRepo.accept(task.id, saveDirectory: saveDir.path));
        }
      }
    });

    await senderRepo.sendFiles([
      PickedFile(path: file.path, name: 'photo.jpg', size: size),
    ]);

    Future<TransferTask?> taskOf(TransferRepositoryLocal repo) async {
      for (var i = 0; i < 100; i++) {
        final tasks = repo.currentTasks;
        if (tasks.length == 1 && tasks.single.isFinished) return tasks.single;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return null;
    }

    final sent = await taskOf(senderRepo);
    final got = await taskOf(receiverRepo);

    expect(sent, isNotNull, reason: '发送端任务一直没终结');
    expect(got, isNotNull, reason: '接收端任务一直没终结');
    expect(sent!.status, TransferStatus.completed);
    expect(got!.status, TransferStatus.completed);

    // 落盘结果必须和源文件一致。
    final saved = File('${saveDir.path}/photo.jpg');
    expect(await saved.exists(), isTrue);
    expect(await saved.length(), size);

    // 临时文件不能留在目录里吓人。
    final leftovers = saveDir
        .listSync()
        .where((entity) => entity.path.endsWith('.mova-part'))
        .toList();
    expect(leftovers, isEmpty, reason: '半成品文件没有被清理');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('接收端不回执时，发送端不会假装完成', () async {
    // 换成短回执超时的发送端仓库，否则要等默认的 60 秒。
    await senderRepo.dispose();
    final strictSender = TransferRepositoryLocal(
      sender,
      fileStorage(),
      ackTimeout: const Duration(seconds: 1),
    );
    addTearDown(() => strictSender.dispose());

    // 接收端退化成「只点头」：同意接收，但不写盘、也不回执。
    await receiverRepo.dispose();
    receiver.transferEvents.listen((event) {
      if (event is OfferReceived) receiver.sendFileAccept(event.fileId);
    });

    const size = 64 * 1024;
    final file = await makeFile('silent.bin', size);

    await strictSender.sendFiles([
      PickedFile(path: file.path, name: 'silent.bin', size: size),
    ]);

    TransferTask? task;
    for (var i = 0; i < 100; i++) {
      final tasks = strictSender.currentTasks;
      if (tasks.length == 1 && tasks.single.isFinished) {
        task = tasks.single;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    expect(task, isNotNull);
    expect(task!.status, TransferStatus.failed);
    expect(task.error, contains('没有收到对方的接收确认'));
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('字节数对不上时：接收端丢弃半成品并回失败回执', () async {
    // 用裸 transport 扮演「谎报大小」的发送端：声明 1000 字节，实际只发 100。
    final fakeSender = ChatTransportService();
    final bare = ChatTransportService();

    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final ready = Completer<void>();
    bare.status.listen((status) {
      if (status == ConnectionStatus.connected && !ready.isCompleted) {
        ready.complete();
      }
    });
    await bare.startListening(port);
    await fakeSender.connect('127.0.0.1', port);
    await ready.future.timeout(const Duration(seconds: 10));

    final bareRepo = TransferRepositoryLocal(bare, fileStorage());
    addTearDown(() async {
      await bareRepo.dispose();
      await fakeSender.dispose();
      await bare.dispose();
    });

    const fileId = 77;
    final done = Completer<DoneReceived>();
    final accepted = Completer<void>();
    fakeSender.transferEvents.listen((event) {
      if (event is AcceptReceived && event.fileId == fileId) {
        if (!accepted.isCompleted) accepted.complete();
      }
      if (event is DoneReceived && event.fileId == fileId) {
        if (!done.isCompleted) done.complete(event);
      }
    });

    // 收到请求就接收。
    bareRepo.tasks.listen((tasks) {
      for (final task in tasks) {
        if (task.id == fileId && task.status == TransferStatus.waiting) {
          unawaited(bareRepo.accept(fileId, saveDirectory: saveDir.path));
        }
      }
    });

    final small = await makeFile('liar.bin', 100);
    await fakeSender.sendFileOffer(fileId: fileId, name: 'liar.bin', size: 1000);
    await accepted.future.timeout(const Duration(seconds: 10));
    await fakeSender.sendFileStream(fileId: fileId, path: small.path);
    // 谎报：实际只发了 100 字节。
    fakeSender.sendFileEnd(fileId, size: 1000);

    final receipt = await done.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw TimeoutException('没有收到回执'),
    );

    expect(receipt.ok, isFalse, reason: '大小对不上却回了一个成功回执');
    expect(receipt.reason, isNotNull);

    // 半成品必须丢弃：目录里既不能有正式文件，也不能留临时文件。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await File('${saveDir.path}/liar.bin').exists(), isFalse);
    final leftovers = saveDir
        .listSync()
        .where((entity) => entity.path.endsWith('.mova-part'))
        .toList();
    expect(leftovers, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('结束帧按截短后的大小「如实」声明，同样要判失败', () async {
    // 比「谎报大小」更隐蔽的情况：源文件在传输期间被截短，
    // 发送端老老实实把截短后的大小写进结束帧。
    // 只比「结束帧声明 vs 实际落盘」会认为一切正常，
    // 必须再和 offer 里最初声明的大小对一次账。
    final fakeSender = ChatTransportService();
    final bare = ChatTransportService();

    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final ready = Completer<void>();
    bare.status.listen((status) {
      if (status == ConnectionStatus.connected && !ready.isCompleted) {
        ready.complete();
      }
    });
    await bare.startListening(port);
    await fakeSender.connect('127.0.0.1', port);
    await ready.future.timeout(const Duration(seconds: 10));

    final bareRepo = TransferRepositoryLocal(bare, fileStorage());
    addTearDown(() async {
      await bareRepo.dispose();
      await fakeSender.dispose();
      await bare.dispose();
    });

    const fileId = 78;
    final done = Completer<DoneReceived>();
    final accepted = Completer<void>();
    fakeSender.transferEvents.listen((event) {
      if (event is AcceptReceived && event.fileId == fileId) {
        if (!accepted.isCompleted) accepted.complete();
      }
      if (event is DoneReceived && event.fileId == fileId) {
        if (!done.isCompleted) done.complete(event);
      }
    });

    bareRepo.tasks.listen((tasks) {
      for (final task in tasks) {
        if (task.id == fileId && task.status == TransferStatus.waiting) {
          unawaited(bareRepo.accept(fileId, saveDirectory: saveDir.path));
        }
      }
    });

    // 请求时声明 1000 字节……
    final small = await makeFile('shrunk.bin', 100);
    await fakeSender.sendFileOffer(fileId: fileId, name: 'shrunk.bin', size: 1000);
    await accepted.future.timeout(const Duration(seconds: 10));
    await fakeSender.sendFileStream(fileId: fileId, path: small.path);
    // ……结束时如实声明 100 字节（自洽，但不是用户要的那个文件）。
    fakeSender.sendFileEnd(fileId, size: 100);

    final receipt = await done.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw TimeoutException('没有收到回执'),
    );

    expect(receipt.ok, isFalse, reason: '与最初声明的大小不符却回了一个成功回执');
    expect(receipt.reason, isNotNull);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await File('${saveDir.path}/shrunk.bin').exists(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
