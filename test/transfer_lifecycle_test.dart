import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:mova/config/app_config.dart';
import 'package:mova/data/repositories/transfer/transfer_repository_local.dart';
import 'package:mova/data/services/chat/chat_transport_service.dart';
import 'package:mova/data/services/storage/settings_service.dart';
import 'package:mova/data/services/storage/storage_service.dart';
import 'package:mova/data/services/transfer/file_storage_service.dart';
import 'package:mova/data/services/transfer/incoming_file_writer.dart';
import 'package:mova/domain/models/chat/connection_status.dart';
import 'package:mova/domain/models/transfer/picked_file.dart';
import 'package:mova/domain/models/transfer/transfer_event.dart';
import 'package:mova/domain/models/transfer/transfer_task.dart';
import 'package:mova/utils/atomic_link.dart';
// 必须显式导入：Result 的成类（Ok / Error）不会跟着别的导入进来。
import 'package:mova/utils/result.dart';

/// 任务生命周期相关的规则：
/// 1. 排队中的文件不能开始「等对端应答」的计时；
/// 2. 取消已发出的请求要通知对端，且迟到的「同意」不能让任务复活；
/// 3. 收尾期间的取消/断连要能让文件真正作废；
/// 4. 临时文件与正式文件都绝不覆盖已有文件（含「提交那一刻」才被占用）；
/// 5. 取消不能因为「最后一块已发出」而失效；
/// 6. 过期的连接尝试不能污染已经建立的会话（时序由注入的连接函数确定）；
/// 7. 换会话时旧接收的临时文件照样要清掉。
void main() {
  late Directory temp;
  late Directory saveDir;
  late ChatTransportService sender;
  late ChatTransportService receiver;
  late int port;

  FileStorageService fileStorage() => FileStorageService(
        settingsService: SettingsService(StorageService()),
        storageService: StorageService(),
      );

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

  /// 取一个当前空闲的端口（用于本文件里临时搭建的第二组连接）。
  Future<int> freePort() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    return port;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mova_lifecycle_test');
    saveDir = Directory('${temp.path}/save')..createSync();
    port = await connectPair();
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
    final file = File(p.join(temp.path, name));
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

  test('排队中的文件不会因为「等待响应」超时而失败', () async {
    // 对端一次都不点接收：第一个文件必然在 offerTimeout 后被判「未响应」，
    // 而第二个文件在这段时间里一直排在队列里、请求根本没发出去。
    // 若排队也算在计时内（拿 createdAt 兜底），它会在轮到之前就一起失败。
    final senderRepo = TransferRepositoryLocal(
      sender,
      fileStorage(),
      offerTimeout: const Duration(seconds: 2),
      stallTimeout: const Duration(minutes: 5),
    );
    addTearDown(() => senderRepo.dispose());

    // 接收端什么都不做。
    final receiverRepo = TransferRepositoryLocal(receiver, fileStorage());
    addTearDown(() => receiverRepo.dispose());

    TransferTask? byName(List<TransferTask> tasks, String name) => tasks
        .cast<TransferTask?>()
        .firstWhere((task) => task?.fileName == name, orElse: () => null);

    final first = await makeFile('first.bin', 32 * 1024);
    final second = await makeFile('second.bin', 32 * 1024);
    await senderRepo.sendFiles([
      PickedFile(path: first.path, name: 'first.bin', size: 32 * 1024),
      PickedFile(path: second.path, name: 'second.bin', size: 32 * 1024),
    ]);

    var queuedEverFailed = false;
    var queuedSamples = 0;
    for (var i = 0; i < 100; i++) {
      final tasks = senderRepo.currentTasks;
      final one = byName(tasks, 'first.bin');
      final two = byName(tasks, 'second.bin');
      if (two?.status == TransferStatus.failed) queuedEverFailed = true;
      if (two?.status == TransferStatus.queued) queuedSamples++;
      if (one == null || one.isFinished) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // 第二个文件确实排过队（否则这条用例没覆盖到排队状态）。
    expect(queuedSamples, greaterThan(0), reason: '第二个文件没有进入排队状态');
    expect(queuedEverFailed, isFalse,
        reason: '还没轮到的文件被判成了「对方没有响应」');

    // 轮到它之后才进入等待应答，而不是直接带着失败原因出现。
    final nowQueued = byName(senderRepo.currentTasks, 'second.bin');
    expect(nowQueued, isNotNull);
    expect(nowQueued!.isFinished, isFalse);
    expect(nowQueued.error, isNull);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('取消已发出的请求后，迟到的「接收」不会让文件重新发出', () async {
    final senderRepo = TransferRepositoryLocal(sender, fileStorage());
    addTearDown(() => senderRepo.dispose());

    // 对端用裸 transport：故意不装仓库，这样它不会处理我们发的取消，
    // 模拟「取消帧还在路上，对方正好点了接收」这一最坏时序。
    final offer = Completer<int>();
    var chunks = 0;
    receiver.transferEvents.listen((event) {
      if (event is OfferReceived && !offer.isCompleted) {
        offer.complete(event.fileId);
      }
      if (event is ChunkReceived) chunks++;
    });

    final file = await makeFile('late.bin', 64 * 1024);
    await senderRepo.sendFiles([
      PickedFile(path: file.path, name: 'late.bin', size: 64 * 1024),
    ]);

    final fileId = await offer.future.timeout(const Duration(seconds: 10));

    TransferTask? taskOf(int id) => senderRepo.currentTasks
        .cast<TransferTask?>()
        .firstWhere((task) => task?.id == id, orElse: () => null);

    // 等发送端确实进入「等待对方应答」后再取消。
    for (var i = 0; i < 50; i++) {
      if (taskOf(fileId)?.status == TransferStatus.waiting) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    await senderRepo.cancel(fileId);
    expect(taskOf(fileId)?.status, TransferStatus.canceled);

    // 迟到的同意：发送端必须忽略，并且不再推任何一个数据块。
    receiver.sendFileAccept(fileId);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    expect(chunks, 0, reason: '取消之后又被迟到的同意重新启动了发送');
    expect(taskOf(fileId)?.status, TransferStatus.canceled);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('源文件在发送期间被截短时，发送端直接判失败', () async {
    final file = await makeFile('shrink.bin', 64 * 1024);

    // 声明的大小远大于真实大小：读循环会提前 EOF。
    // 若不比对「实际读出量 vs 声明量」，对端会收到一个自洽但不完整的文件。
    final result = await sender.sendFileStream(
      fileId: 4242,
      path: file.path,
      expectedSize: 200 * 1024,
    );

    switch (result) {
      case Ok<SentFileSummary>():
        fail('声明大小与实际读出量不一致，却报告发送成功');
      case Error<SentFileSummary>():
        expect(result.error.toString(), contains('发生了变化'));
    }
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('收尾阶段取消：文件不会在取消之后被保存下来', () async {
    // 让「后台刷盘」这一步停在半路，好模拟「收尾还没完成时用户取消」。
    final writer = _GatedWriter();
    addTearDown(writer.release);

    final receiverRepo =
        TransferRepositoryLocal(receiver, fileStorage(), writer: writer);
    addTearDown(() => receiverRepo.dispose());

    final senderRepo = TransferRepositoryLocal(sender, fileStorage());
    addTearDown(() => senderRepo.dispose());

    receiverRepo.tasks.listen((tasks) {
      for (final task in tasks) {
        if (task.direction == TransferDirection.receiving &&
            task.status == TransferStatus.waiting) {
          unawaited(receiverRepo.accept(task.id, saveDirectory: saveDir.path));
        }
      }
    });

    const size = 64 * 1024;
    final file = await makeFile('canceled.bin', size);
    await senderRepo.sendFiles([
      PickedFile(path: file.path, name: 'canceled.bin', size: size),
    ]);

    final fileId = senderRepo.currentTasks.single.id;
    await writer.entered.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('接收端一直没有进入收尾'),
    );

    // 收尾仍在进行时取消。
    unawaited(receiverRepo.cancel(fileId));
    writer.release();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // 关键：取消之后绝不能冒出一个「已保存」的文件。
    expect(fileId, isNonZero);
    expect(
      await File(p.join(saveDir.path, 'canceled.bin')).exists(),
      isFalse,
      reason: '取消之后文件仍然被改名保存了',
    );
    expect(
      saveDir.listSync().where((e) => e.path.endsWith('.mova-part')).toList(),
      isEmpty,
      reason: '临时文件没有清理干净',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('准备接收期间取消：临时文件不残留，任务也不会进入传输', () async {
    // 把「取保存目录」这一步卡住，好让取消必定落在准备阶段。
    final storage = _GatedSaveDirectoryStorage(directory: saveDir);
    final receiverRepo = TransferRepositoryLocal(receiver, storage);
    addTearDown(() => receiverRepo.dispose());

    final senderRepo = TransferRepositoryLocal(sender, fileStorage());
    addTearDown(() => senderRepo.dispose());

    final offered = Completer<int>();
    receiverRepo.tasks.listen((tasks) {
      for (final task in tasks) {
        if (task.direction == TransferDirection.receiving &&
            task.status == TransferStatus.waiting &&
            !offered.isCompleted) {
          offered.complete(task.id);
        }
      }
    });

    const size = 32 * 1024;
    final file = await makeFile('prepare.bin', size);
    await senderRepo.sendFiles([
      PickedFile(path: file.path, name: 'prepare.bin', size: size),
    ]);

    final fileId = await offered.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('一直没有收到发送请求'),
    );

    unawaited(receiverRepo.accept(fileId));
    await storage.entered.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('准备流程没有开始'),
    );

    // 此刻任务应当处于「准备中」，而不是已经进入传输。
    final preparing = receiverRepo.currentTasks
        .firstWhere((task) => task.id == fileId, orElse: () => throw StateError('任务不见了'));
    expect(preparing.status, TransferStatus.preparing);

    unawaited(receiverRepo.cancel(fileId));
    storage.release();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final done = receiverRepo.currentTasks
        .firstWhere((task) => task.id == fileId, orElse: () => throw StateError('任务不见了'));
    expect(done.status, TransferStatus.canceled);
    expect(
      saveDir.listSync().where((e) => e.path.endsWith('.mova-part')).toList(),
      isEmpty,
      reason: '准备期间取消后留下了临时文件',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('重复点击接收：第二次被挡回，不会两次占用同一个任务', () async {
    final storage = _GatedSaveDirectoryStorage(directory: saveDir);
    final receiverRepo = TransferRepositoryLocal(receiver, storage);
    addTearDown(() => receiverRepo.dispose());

    final senderRepo = TransferRepositoryLocal(sender, fileStorage());
    addTearDown(() => senderRepo.dispose());

    final offered = Completer<int>();
    receiverRepo.tasks.listen((tasks) {
      for (final task in tasks) {
        if (task.direction == TransferDirection.receiving &&
            task.status == TransferStatus.waiting &&
            !offered.isCompleted) {
          offered.complete(task.id);
        }
      }
    });

    const size = 32 * 1024;
    final file = await makeFile('twice.bin', size);
    await senderRepo.sendFiles([
      PickedFile(path: file.path, name: 'twice.bin', size: size),
    ]);

    final fileId = await offered.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('一直没有收到发送请求'),
    );

    // 第一次还没走完（卡在取目录），立刻再点一次。
    final first = receiverRepo.accept(fileId);
    await storage.entered.future.timeout(const Duration(seconds: 10));
    // 加上超时：万一防重入失效，第二次会一直卡在取目录这一步，
    // 那样只会得到一个“测试超时”，看不出到底哪里坏了。
    final second = await receiverRepo.accept(fileId).timeout(
          const Duration(seconds: 5),
          onTimeout: () =>
              Result<void>.error(Exception('第二次接收没有及时返回')),
        );

    switch (second) {
      case Ok<void>():
        fail('快速重复点击竟然成功启动了第二次准备');
      case Error<void>():
        expect(second.error.toString(), contains('已失效'));
    }

    storage.release();
    await first.timeout(const Duration(seconds: 10));

    // 只应有一个临时文件被创建，且接着正常进入传输。
    final task = receiverRepo.currentTasks
        .firstWhere((task) => task.id == fileId, orElse: () => throw StateError('任务不见了'));
    expect(task.status, isNot(TransferStatus.preparing));
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('改名期间取消：文件不会在取消之后出现在保存目录', () async {
    // 把「提交」这一步卡住，专门覆盖「取消落在改名那一次 await 上」。
    final storage = _GatedCommitStorage();
    final receiverRepo = TransferRepositoryLocal(receiver, storage);
    addTearDown(() => receiverRepo.dispose());

    final senderRepo = TransferRepositoryLocal(sender, fileStorage());
    addTearDown(() => senderRepo.dispose());

    final accepted = Completer<int>();
    receiverRepo.tasks.listen((tasks) {
      for (final task in tasks) {
        if (task.direction == TransferDirection.receiving &&
            task.status == TransferStatus.waiting &&
            !accepted.isCompleted) {
          unawaited(receiverRepo.accept(task.id, saveDirectory: saveDir.path));
          accepted.complete(task.id);
        }
      }
    });

    // 接收端若在这一步之后仍然报告「保存成功」，发送端就会显示已完成，
    // 而接收端这边是已取消——两边说法不一致，是这条例要抓住的核心问题。
    var successReceipts = 0;
    sender.transferEvents.listen((event) {
      if (event is DoneReceived && event.ok) successReceipts++;
    });

    const size = 64 * 1024;
    final file = await makeFile('rename.bin', size);
    await senderRepo.sendFiles([
      PickedFile(path: file.path, name: 'rename.bin', size: size),
    ]);

    final fileId = await accepted.future.timeout(const Duration(seconds: 10));
    await storage.entered.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('一直没有走到改名这一步'),
    );

    // 改名正在进行时取消。
    unawaited(receiverRepo.cancel(fileId));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    storage.release();
    await Future<void>.delayed(const Duration(milliseconds: 800));

    expect(
      await File(p.join(saveDir.path, 'rename.bin')).exists(),
      isFalse,
      reason: '取消之后文件仍然被改名保存了',
    );
    expect(
      saveDir.listSync().where((e) => e.path.endsWith('.mova-part')).toList(),
      isEmpty,
      reason: '临时文件没有清理干净',
    );
    final task = receiverRepo.currentTasks
        .firstWhere((task) => task.id == fileId, orElse: () => throw StateError('任务不见了'));
    expect(task.status, TransferStatus.canceled);
    expect(successReceipts, 0,
        reason: '已经取消，接收端却仍然向发送端报告保存成功');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('发送途中切换连接：旧文件的数据块不会写进新设备', () async {
    // 第二台设备：用于「正发着文件时断连、再连上别人」。
    final second = ChatTransportService();
    addTearDown(() => second.dispose());

    final probe2 = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port2 = probe2.port;
    await probe2.close();

    final ready2 = Completer<void>();
    second.status.listen((status) {
      if (status == ConnectionStatus.connected && !ready2.isCompleted) {
        ready2.complete();
      }
    });
    await second.startListening(port2);

    const fileId = 8899;
    var chunksToSecond = 0;
    var endsToSecond = 0;
    second.transferEvents.listen((event) {
      if (event is ChunkReceived && event.fileId == fileId) chunksToSecond++;
      if (event is EndReceived && event.fileId == fileId) endsToSecond++;
    });

    // 48MB：超过发送端 32MiB 的背压阈值，配合对端停读，
    // 发送循环一定会停在 flush 上——切换连接的时机因此是确定的。
    const size = 48 * 1024 * 1024;
    final file = await makeFile('handover.bin', size);

    // 让第一台设备停止读取，发送端随即被 TCP 窗口压住。
    receiver.pauseInbound();

    var written = 0;
    final sending = sender.sendFileStream(
      fileId: fileId,
      path: file.path,
      session: sender.sessionId,
      onProgress: (sent) => written = sent,
    );

    // 确实已经往第一条连接写了数据（否则这条用例是空跑）。
    for (var i = 0; i < 300 && written < AppConfig.maxInFlightBytes; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(written, greaterThanOrEqualTo(AppConfig.maxInFlightBytes),
        reason: '发送端没有真正开始推流，用例覆盖不到切换');

    await sender.disconnect();
    await sender.connect('127.0.0.1', port2);
    await ready2.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('没有连上第二台设备'),
    );

    // 旧会话的收尾帧同样不能落到新设备上。
    sender.sendFileEnd(fileId, size: size, session: 'stale-session');
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(chunksToSecond, 0, reason: '旧文件的数据块被写进了新连接');
    expect(endsToSecond, 0, reason: '旧会话的结束帧被发给了新设备');

    // 旧发送要么已中止，要么仍卡在被销毁的 socket 上；都不能报成功。
    final result = await sending.timeout(
      const Duration(seconds: 10),
      onTimeout: () => Result<SentFileSummary>.ok(const SentFileSummary(bytes: 0)),
    );
    switch (result) {
      case Ok<SentFileSummary>():
        fail('会话已经切换，发送却报告成功');
      case Error<SentFileSummary>():
        expect(result.error.toString(), isNotEmpty);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('临时文件已存在时绝不覆盖', () async {
    final writer = IncomingFileWriter();
    // 注意是 dispose()：写成 dispose 只是取了个方法引用，
    // 后台 isolate 不会被释放，测试进程可能因此退不出去。
    addTearDown(() => writer.dispose());
    await writer.start();

    final existing = File(p.join(saveDir.path, 'x.bin.mova-part'));
    await existing.writeAsString('original');

    var threw = false;
    try {
      await writer.open(1, existing.path, exclusive: true);
    } catch (_) {
      threw = true;
    }

    expect(threw, isTrue, reason: '独占打开竟然成功了');
    expect(await existing.readAsString(), 'original',
        reason: '已有文件被截断/覆盖了');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('最后一次 flush 期间取消：发送不会报告成功', () async {
    // 64KB 的小文件：一次就读完，循环里不会触发背压 flush，
    // 唯一一次「等网络排空」就是收尾那次 flush。取消信号在最后一块
    // 写出之后（onProgress 回调之后）才翻转，正好落在那一次 await 上。
    const size = 64 * 1024;
    final file = await makeFile('flushcancel.bin', size);

    var sent = 0;
    final result = await sender.sendFileStream(
      fileId: 3131,
      path: file.path,
      session: sender.sessionId,
      onProgress: (s) => sent = s,
      isCancelled: () => sent >= size,
    );

    switch (result) {
      case Ok<SentFileSummary>():
        fail('最后一块发出之后的取消没有生效，发送仍报告成功');
      case Error<SentFileSummary>():
        expect(result.error.toString(), contains('已取消'));
    }
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('发送结果交回仓储时已取消：不会补发结束帧', () async {
    // 单独搭一组连接：setUp 里那台的会话已经被占用了，连不进第二个。
    final hostPort = await freePort();
    final peer = ChatTransportService();
    addTearDown(() => peer.dispose());
    await peer.startListening(hostPort);

    // 把「发送已经跑完、结果还没交回仓储」这一瞬卡住，
    // 让取消必定落在发送循环之外、结果处理之内。
    final gated = _GatedSendTransport();
    addTearDown(() => gated.dispose());
    await gated.connect('127.0.0.1', hostPort);

    var endFrames = 0;
    peer.transferEvents.listen((event) {
      if (event is OfferReceived) peer.sendFileAccept(event.fileId);
      if (event is EndReceived) endFrames++;
    });

    final senderRepo = TransferRepositoryLocal(gated, fileStorage());
    addTearDown(() => senderRepo.dispose());

    const size = 64 * 1024;
    final file = await makeFile('resultcancel.bin', size);
    await senderRepo.sendFiles([
      PickedFile(path: file.path, name: 'resultcancel.bin', size: size),
    ]);

    await gated.entered.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('发送一直没有跑完'),
    );

    final fileId = senderRepo.currentTasks.single.id;
    await senderRepo.cancel(fileId);
    gated.release();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final task = senderRepo.currentTasks
        .firstWhere((task) => task.id == fileId, orElse: () => throw StateError('任务不见了'));
    expect(task.status, TransferStatus.canceled);
    expect(endFrames, 0, reason: '已经取消，却仍然给对端发出了结束帧');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('提交时目标名已被占用：不覆盖已有文件，另存一个新名字', () async {
    // 「挑好一个空名字」和「改名」之间隔着 await，这期间用户（或另一次
    // 接收）完全可能放一个同名文件进来。这条用例就让这件事真的发生。
    final conflict = File(p.join(saveDir.path, 'conflict.bin'));
    final storage = _ConflictingCommitStorage(conflictPath: conflict.path);
    final receiverRepo = TransferRepositoryLocal(receiver, storage);
    addTearDown(() => receiverRepo.dispose());

    final senderRepo = TransferRepositoryLocal(sender, fileStorage());
    addTearDown(() => senderRepo.dispose());

    receiverRepo.tasks.listen((tasks) {
      for (final task in tasks) {
        if (task.direction == TransferDirection.receiving &&
            task.status == TransferStatus.waiting) {
          unawaited(receiverRepo.accept(task.id, saveDirectory: saveDir.path));
        }
      }
    });

    const size = 64 * 1024;
    final file = await makeFile('conflict.bin', size);
    await senderRepo.sendFiles([
      PickedFile(path: file.path, name: 'conflict.bin', size: size),
    ]);

    // 等接收端收尾完成（它对端会回执，发送端随即完成）。
    for (var i = 0; i < 200; i++) {
      final tasks = receiverRepo.currentTasks;
      if (tasks.isNotEmpty && tasks.single.isFinished) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final task = receiverRepo.currentTasks.single;
    expect(task.status, TransferStatus.completed);

    // 关键：被占用的那个文件一个字节都没被动过。
    expect(await conflict.exists(), isTrue);
    expect(await conflict.readAsString(), 'original',
        reason: '提交时覆盖了已经存在的同名文件');

    // 收到的内容另存到了不冲突的名字上。
    final saved = File(p.join(saveDir.path, 'conflict (1).bin'));
    expect(await saved.exists(), isTrue, reason: '冲突之后没有另存一个新名字');
    expect(await saved.length(), size);
    expect(task.localPath, saved.path);
    expect(
      saveDir.listSync().where((e) => e.path.endsWith('.mova-part')).toList(),
      isEmpty,
      reason: '临时文件没有清理干净',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('旧连接尝试晚于新会话失败：不会把新会话打成断连', () async {
    final hostPort = await freePort();

    // 时序由注入的连接函数**确定**地安排：第一次尝试停在 Completer 上，
    // 直到测试明确让它失败。早先靠「连不可达地址等它超时」来构造交错，
    // 但那样既不能证明旧请求一直挂到新会话建立之后，也没断言它的结果——
    // 它提前失败，测试照样是绿的。
    final staleSocket = Completer<Socket>();
    var outbound = 0;
    Future<Socket> connector(String host, int port, Duration timeout) {
      outbound++;
      // 第一次（旧尝试）永远挂起；其余照常真的连。
      if (outbound == 1) return staleSocket.future;
      return Socket.connect(host, port, timeout: timeout);
    }

    final host = ChatTransportService(connector: connector);
    addTearDown(() => host.dispose());
    final peer = ChatTransportService();
    addTearDown(() => peer.dispose());

    final statuses = <ConnectionStatus>[];
    host.status.listen(statuses.add);
    await host.startListening(hostPort);

    final stale = host.connect('203.0.113.1', 9);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(host.isConnecting, isTrue,
        reason: '连接尝试没有挂起，这条用例覆盖不到「过期尝试」');
    expect(staleSocket.isCompleted, isFalse);

    // 用户不想等了：断开。这一步让还在跑的那次尝试作废。
    await host.disconnect();

    // 新设备连进来，会话建立成功。
    final connected = Completer<void>();
    host.status.listen((status) {
      if (status == ConnectionStatus.connected && !connected.isCompleted) {
        connected.complete();
      }
    });
    await peer.connect('127.0.0.1', hostPort);
    await connected.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('新设备没有连上'),
    );

    final sessionAfter = host.sessionId;
    expect(sessionAfter, isNotNull);

    // 直到这一刻，旧尝试才失败：**晚于**新会话建立。
    staleSocket.completeError(Exception('连接超时'));

    // 必须断言旧尝试自己的结果：它得真的结束了，而且是个错误。
    final staleResult = await stale.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('过期的连接尝试一直没有结束'),
    );
    switch (staleResult) {
      case Ok<void>():
        fail('过期的连接尝试竟然报告成功');
      case Error<void>():
        break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(statuses.last, ConnectionStatus.connected,
        reason: '过期尝试的失败把新会话打成了断连');
    expect(host.isBusy, isTrue, reason: '过期尝试把新会话标记成了未连接');
    expect(host.sessionId, sessionAfter);
    // 对端视角也必须还是连着的（否则它的界面与传输任务会按断连处理）。
    expect(peer.isBusy, isTrue);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('旧尝试失败时新尝试仍在进行：不会广播断连', () async {
    // 上一条覆盖的是「新会话已经建好」，此时「当前没有 socket」这一条
    // 就足以挡住误报。令牌真正兜住的是这里：旧尝试失败时**另一次尝试
    // 正在半路**（还没有 socket），少了令牌判断，它那句 disconnected
    // 会让界面与上层以为新尝试也失败了。
    final hostPort = await freePort();
    final staleSocket = Completer<Socket>();
    final freshSocket = Completer<Socket>();
    var outbound = 0;
    Future<Socket> connector(String host, int port, Duration timeout) {
      outbound++;
      if (outbound == 1) return staleSocket.future;
      if (outbound == 2) return freshSocket.future;
      return Socket.connect(host, port, timeout: timeout);
    }

    final host = ChatTransportService(connector: connector);
    addTearDown(() => host.dispose());
    await host.startListening(hostPort);

    final statuses = <ConnectionStatus>[];
    host.status.listen(statuses.add);

    final stale = host.connect('203.0.113.1', 9);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(host.isConnecting, isTrue, reason: '旧尝试没有挂起');

    // 用户等不下去了：断开，立刻改连另一台（这一次也停在半路）。
    await host.disconnect();
    final fresh = host.connect('127.0.0.1', hostPort);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(host.isConnecting, isTrue, reason: '新尝试没有开始');
    expect(statuses.last, ConnectionStatus.connecting);

    // 旧尝试此刻才失败：新尝试还没有结果，绝不能把状态打成断连。
    staleSocket.completeError(Exception('连接超时'));
    final staleResult = await stale.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('过期的连接尝试一直没有结束'),
    );
    expect(staleResult, isA<Error<void>>());
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(statuses.last, ConnectionStatus.connecting,
        reason: '过期尝试的失败把正在进行的连接尝试打成了断连');
    expect(host.isConnecting, isTrue, reason: '过期尝试把新尝试标记成了未连接');

    // 收尾：让新尝试也结束，免得留下一个永不完成的 Future。
    freshSocket.completeError(Exception('用例结束'));
    await fresh.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('新尝试没有结束'),
    );
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('提交瞬间目标被占用：不覆盖已有文件，另存一个新名字', () async {
    // 与「提交前目标被占用」的区别：这次占用发生在**提交动作内部**——
    // 也就是此前所有准备工作都已完成的最后一刻。旧实现在这一刻之后还要
    // 「占位 → 改名」两步，占位之后别人照样可以换掉那个名字，
    // 接下来的普通改名会把它覆盖掉。
    final conflict = File(p.join(saveDir.path, 'race.bin'));
    final storage = _RacingCommitStorage(conflictPath: conflict.path);
    final receiverRepo = TransferRepositoryLocal(receiver, storage);
    addTearDown(() => receiverRepo.dispose());

    final senderRepo = TransferRepositoryLocal(sender, fileStorage());
    addTearDown(() => senderRepo.dispose());

    receiverRepo.tasks.listen((tasks) {
      for (final task in tasks) {
        if (task.direction == TransferDirection.receiving &&
            task.status == TransferStatus.waiting) {
          unawaited(receiverRepo.accept(task.id, saveDirectory: saveDir.path));
        }
      }
    });

    const size = 64 * 1024;
    final file = await makeFile('race.bin', size);
    await senderRepo.sendFiles([
      PickedFile(path: file.path, name: 'race.bin', size: size),
    ]);

    // 确实走到了提交那一步（否则这条用例是空跑）。
    await storage.entered.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('一直没有走到提交这一步'),
    );

    for (var i = 0; i < 200; i++) {
      final tasks = receiverRepo.currentTasks;
      if (tasks.isNotEmpty && tasks.single.isFinished) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final task = receiverRepo.currentTasks.single;
    expect(task.status, TransferStatus.completed);

    // 关键：提交那一刻被别人占用的那个文件，一个字节都没被动过。
    expect(await conflict.exists(), isTrue);
    expect(await conflict.readAsString(), 'original',
        reason: '提交时覆盖了已经存在的同名文件');

    // 收到的内容另存到了不冲突的名字上。
    final saved = File(p.join(saveDir.path, 'race (1).bin'));
    expect(await saved.exists(), isTrue, reason: '冲突之后没有另存一个新名字');
    expect(await saved.length(), size);
    expect(task.localPath, saved.path);
    expect(
      saveDir.listSync().where((e) => e.path.endsWith('.mova-part')).toList(),
      isEmpty,
      reason: '临时文件没有清理干净',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('提交原语不可用时明确失败，绝不退回覆盖改名', () async {
    // 拿不到「不替换目标的原子提交」时（文件系统不支持硬链接、
    // 权限不足……）必须明确失败。这里故意让原语失败，
    // 看实现会不会悄悄退回普通改名——那会覆盖掉目标上已有的文件。
    final storage = _FailingCommitStorage();
    final dir = Directory(p.join(temp.path, 'commit'))..createSync();
    final tempFile = File(p.join(dir.path, 'a.bin${AppConfig.incomingTempSuffix}'));
    await tempFile.writeAsString('content');
    final target = p.join(dir.path, 'a.bin');

    final outcome = await storage.commitTempFile(tempFile.path, target);
    expect(outcome, isA<CommitFailed>(),
        reason: '提交原语失败，却报告了提交成功');
    expect(await File(target).exists(), isFalse,
        reason: '提交原语失败后仍然把文件改到了目标名（退回了覆盖改名）');
    expect(await tempFile.exists(), isTrue,
        reason: '提交失败后临时文件被提前删掉了');

    // 目标名已被占用时，无论原语报什么错，都只能算「冲突」。
    final occupied = File(target);
    await occupied.writeAsString('original');
    final taken = await storage.commitTempFile(tempFile.path, target);
    expect(taken, isA<CommitTargetTaken>());
    expect(await occupied.readAsString(), 'original',
        reason: '冲突分支覆盖了已有文件');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('切换会话时旧接收的临时文件仍会被清理', () async {
    // 交错顺序：接收已进入收尾（磁盘上有完整的临时文件）→ 断连触发清理，
    // 清理卡在「放弃后台写盘」这一步 → 另一台设备连进来，新会话清空任务表
    // → 旧清理这才继续。清理若回头按任务表判断「还删不删」，
    // 就会因为任务已被清空而跳过删除，把临时文件留在用户目录里。
    final writer = _GatedAbortWriter();
    addTearDown(() => writer.dispose());

    final receiverRepo =
        TransferRepositoryLocal(receiver, fileStorage(), writer: writer);
    addTearDown(() => receiverRepo.dispose());

    final senderRepo = TransferRepositoryLocal(sender, fileStorage());
    addTearDown(() => senderRepo.dispose());

    receiverRepo.tasks.listen((tasks) {
      for (final task in tasks) {
        if (task.direction == TransferDirection.receiving &&
            task.status == TransferStatus.waiting) {
          unawaited(receiverRepo.accept(task.id, saveDirectory: saveDir.path));
        }
      }
    });

    const size = 256 * 1024;
    final file = await makeFile('handover_part.bin', size);
    await senderRepo.sendFiles([
      PickedFile(path: file.path, name: 'handover_part.bin', size: size),
    ]);

    // 整份内容都已落盘、正卡在收尾：此刻磁盘上有一个真实的临时文件。
    await writer.closeEntered.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('接收端一直没有进入收尾'),
    );
    expect(
      saveDir.listSync().where((e) => e.path.endsWith('.mova-part')).toList(),
      hasLength(1),
      reason: '接收过程中没有生成临时文件，用例覆盖不到清理',
    );

    await receiver.disconnect();
    await writer.abortEntered.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('清理没有开始'),
    );

    // 另一台设备在旧清理还没结束时连进来：新会话会清空任务表。
    final second = ChatTransportService();
    addTearDown(() => second.dispose());
    final connected = Completer<void>();
    receiver.status.listen((status) {
      if (status == ConnectionStatus.connected && !connected.isCompleted) {
        connected.complete();
      }
    });
    await second.connect('127.0.0.1', port);
    await connected.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('第二台设备没有连上'),
    );
    expect(receiverRepo.currentTasks.where((t) => t.direction ==
        TransferDirection.receiving), isEmpty);

    // 旧清理这才继续：它必须按自己捕获的路径把临时文件删掉。
    // 收尾那一步仍然卡着，因此删文件的只可能是这次清理本身。
    writer.release();
    await Future<void>.delayed(const Duration(milliseconds: 800));

    expect(
      saveDir.listSync().where((e) => e.path.endsWith('.mova-part')).toList(),
      isEmpty,
      reason: '换会话后旧接收的临时文件被留在了保存目录里',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));
}

/// 把「取保存目录」这一步卡住的存储器：用于让取消必定落在准备阶段。
class _GatedSaveDirectoryStorage extends FileStorageService {
  _GatedSaveDirectoryStorage({required Directory directory})
      : _directory = directory,
        super(
          settingsService: SettingsService(StorageService()),
          storageService: StorageService(),
        );

  final Directory _directory;

  /// 已进入 currentSaveDirectory。
  final Completer<void> entered = Completer<void>();

  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<String> currentSaveDirectory() async {
    if (!entered.isCompleted) entered.complete();
    await _gate.future;
    return _directory.path;
  }
}

/// 把「提交（临时文件改名）」这一步卡住的存储器：
/// 专门用于覆盖「取消落在改名那一次 await 上」。
class _GatedCommitStorage extends FileStorageService {
  _GatedCommitStorage()
      : super(
          settingsService: SettingsService(StorageService()),
          storageService: StorageService(),
        );

  /// 已进入改名。
  final Completer<void> entered = Completer<void>();

  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<CommitOutcome> commitTempFile(String tempPath, String finalPath) async {
    if (!entered.isCompleted) entered.complete();
    await _gate.future;
    return super.commitTempFile(tempPath, finalPath);
  }
}

/// 在「提交（改名）」真正执行前，先让目标名被占用的存储器：
/// 精确覆盖「挑好名字之后、改名之前」这个窗口。
class _ConflictingCommitStorage extends FileStorageService {
  _ConflictingCommitStorage({required this.conflictPath})
      : super(
          settingsService: SettingsService(StorageService()),
          storageService: StorageService(),
        );

  /// 会在提交前被别人占用的那个路径。
  final String conflictPath;

  /// 已进入提交。
  final Completer<void> entered = Completer<void>();

  var _conflicted = false;

  @override
  Future<CommitOutcome> commitTempFile(String tempPath, String finalPath) async {
    if (!_conflicted) {
      _conflicted = true;
      if (!entered.isCompleted) entered.complete();
      // 模拟：名字挑好之后、改名之前，用户正好放了一个同名文件进来。
      await File(conflictPath).writeAsString('original');
    }
    return super.commitTempFile(tempPath, finalPath);
  }
}

/// 把「发送已经跑完、结果还没交回仓储」这一瞬卡住的传输源：
/// 用于让取消必定落在发送循环之外、结果处理之内。
class _GatedSendTransport extends ChatTransportService {
  /// 发送已完成、结果正要交回仓储。
  final Completer<void> entered = Completer<void>();

  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<Result<SentFileSummary>> sendFileStream({
    required int fileId,
    required String path,
    int? expectedSize,
    String? session,
    void Function(int sentBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final result = await super.sendFileStream(
      fileId: fileId,
      path: path,
      expectedSize: expectedSize,
      session: session,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    if (!entered.isCompleted) entered.complete();
    await _gate.future;
    return result;
  }
}

/// 在「提交」真正发生的那一刻让目标名被占用的存储器。
///
/// 与 [_ConflictingCommitStorage] 的区别：那一个是「提交被调用之前」就占好，
/// 这一个是在提交原语内部——此前所有准备工作全部完成之后的最后一刻——
/// 才被别人占用，覆盖的是旧实现「占位 → 改名」两步之间的窗口。
class _RacingCommitStorage extends FileStorageService {
  _RacingCommitStorage({required this.conflictPath})
      : super(
          settingsService: SettingsService(StorageService()),
          storageService: StorageService(),
        );

  /// 会在提交那一刻被别人占用的那个路径。
  final String conflictPath;

  /// 已进入提交。
  final Completer<void> entered = Completer<void>();

  var _raced = false;

  @override
  Future<AtomicCommitResult> atomicCommit(String tempPath, String finalPath) async {
    if (!_raced && p.basename(finalPath) == p.basename(conflictPath)) {
      _raced = true;
      if (!entered.isCompleted) entered.complete();
      await File(finalPath).writeAsString('original');
    }
    return super.atomicCommit(tempPath, finalPath);
  }
}

/// 提交原语永远失败的存储器：模拟「拿不到不覆盖的原子提交」
/// （文件系统不支持硬链接、权限不足等）。
class _FailingCommitStorage extends FileStorageService {
  _FailingCommitStorage()
      : super(
          settingsService: SettingsService(StorageService()),
          storageService: StorageService(),
        );

  @override
  Future<AtomicCommitResult> atomicCommit(String tempPath, String finalPath) async =>
      (ok: false, error: Exception('模拟：该文件系统不支持硬链接'));
}

/// 同时卡住「收尾」与「放弃写盘」的落盘器：
/// 用于构造「接收收尾还没结束、就换了会话」这一交错。
class _GatedAbortWriter extends IncomingFileWriter {
  /// 已进入收尾（close 被调用）。
  final Completer<void> closeEntered = Completer<void>();

  /// 已进入放弃（abort 被调用）。
  final Completer<void> abortEntered = Completer<void>();

  final Completer<void> _closeGate = Completer<void>();
  final Completer<void> _abortGate = Completer<void>();

  /// 只放开「放弃写盘」这一步：收尾继续卡着，
  /// 这样 [_onEnd] 就不会抢在前面把临时文件删掉——
  /// 那会让「清理被跳过」这件事看起来像是没发生。
  void release() {
    if (!_abortGate.isCompleted) _abortGate.complete();
  }

  @override
  Future<WriteSummary> close(int fileId) async {
    if (!closeEntered.isCompleted) closeEntered.complete();
    await _closeGate.future;
    return super.close(fileId);
  }

  @override
  Future<void> abort(int fileId) async {
    if (!abortEntered.isCompleted) abortEntered.complete();
    await _abortGate.future;
    return super.abort(fileId);
  }
}

/// 把「后台刷盘」这一步卡住的落盘器：用于在收尾进行中插一次取消。
class _GatedWriter extends IncomingFileWriter {
  /// 已进入收尾（close 被调用）。
  final Completer<void> entered = Completer<void>();

  final Completer<void> _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<WriteSummary> close(int fileId) async {
    if (!entered.isCompleted) entered.complete();
    await _gate.future;
    return super.close(fileId);
  }
}
