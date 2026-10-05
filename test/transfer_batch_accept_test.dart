// 批量接收的两条边界规则：
// 1. 目录检查（好几轮真实 IO）期间被取消的文件，不能又被拉回接收流程；
// 2. 一次收的文件数超过并发上限时，排队等待的那些只是「还没轮到」，
//    不能按「传输停滞」判失败。

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
import 'package:mova/domain/models/chat/connection_status.dart';
import 'package:mova/domain/models/transfer/picked_file.dart';
import 'package:mova/domain/models/transfer/transfer_task.dart';
// 必须显式导入：Result 的成类（Ok / Error）不会跟着别的导入进来。
// 注意 result.dart 的 Error 会覆盖 dart:core 的同名类，本文件里所有
// Error 都指「失败结果」。
import 'package:mova/utils/result.dart';

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

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mova_batch_accept');
    saveDir = Directory(p.join(temp.path, 'save'))..createSync();

    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = probe.port;
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
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException('对端未接入'),
    );
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
    await file.writeAsBytes(Uint8List(bytes));
    return file;
  }

  Future<void> waitFor(
    String what,
    bool Function() condition, {
    String Function()? dump,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('等待超时：$what${dump == null ? '' : '\n${dump()}'}');
  }

  String show(List<TransferTask> tasks) => tasks
      .map((task) => '${task.fileName}=${task.status.name}'
          '(${task.transferredBytes}/${task.totalBytes}) 错误=${task.error}')
      .join('；');

  test('目录检查期间被取消的文件，不会被重新拉回接收流程', () async {
    final senderRepo = TransferRepositoryLocal(sender, fileStorage());
    addTearDown(() => senderRepo.dispose());
    final storage = _SlowWritableCheckStorage(
      settingsService: SettingsService(StorageService()),
      storageService: StorageService(),
    );
    final receiverRepo = TransferRepositoryLocal(receiver, storage);
    addTearDown(() => receiverRepo.dispose());

    const size = 64 * 1024;
    const count = 3;
    final files = <PickedFile>[];
    for (var i = 0; i < count; i++) {
      final file = await makeFile('c$i.bin', size);
      files.add(PickedFile(path: file.path, name: 'c$i.bin', size: size));
    }
    await senderRepo.sendFiles(files);

    final offers = <TransferTask>[];
    await waitFor(
      '应收到 $count 个待接收请求',
      () {
        offers
          ..clear()
          ..addAll(receiverRepo.currentTasks
              .where((task) => task.status == TransferStatus.waiting));
        return offers.length == count;
      },
      dump: () => '接收端：${show(receiverRepo.currentTasks)}',
    );
    offers.sort((a, b) => (a.batchIndex ?? 0).compareTo(b.batchIndex ?? 0));
    final ids = offers.map((task) => task.id).toList(growable: false);

    // 批量同意：目录检查是好几轮 IO，这里让它停在半路。
    final accepting = receiverRepo.acceptMany(ids, saveDirectory: saveDir.path);
    await storage.reachedWritableCheck.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException(
        '目录检查迟迟没开始。接收端：${show(receiverRepo.currentTasks)}',
      ),
    );

    // 等待期间用户把最后一个取消了（面板上取消了勾选、或连接断了）。
    await receiverRepo.reject(ids[2]);
    expect(
      receiverRepo.currentTasks
          .firstWhere((task) => task.id == ids[2])
          .status,
      TransferStatus.rejected,
    );

    storage.release();
    final result = await accepting.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException(
        'acceptMany 迟迟没返回。接收端：${show(receiverRepo.currentTasks)}',
      ),
    );

    // 报的是**实际接下**的数量：三个请求里第三个被取消了，
    // 说「已接收 3 个」会让界面替一个根本没收的文件邀功。
    expect(result, isA<Ok<int>>(), reason: '部分成功仍算成功，但要报真实数量');
    expect((result as Ok<int>).value, 2,
        reason: '只接下了前两个，返回值不能按请求数报 3');

    // 关键断言：被取消的那个不能被「曾经拍过快照」这件事复活。
    final third = receiverRepo.currentTasks.firstWhere(
      (task) => task.id == ids[2],
      orElse: () => throw StateError('任务不见了：${show(receiverRepo.currentTasks)}'),
    );
    expect(
      third.status,
      TransferStatus.rejected,
      reason: '目录检查期间被取消的文件不应再进入接收流程：${show(receiverRepo.currentTasks)}',
    );
    expect(
      File(p.join(saveDir.path, 'c2.bin')).existsSync(),
      isFalse,
      reason: '被取消的文件不该落到保存目录里',
    );

    // 没被取消的那两个照常收完。
    await waitFor(
      '前两个应正常接收完成',
      () => receiverRepo.currentTasks
          .where((task) => task.id != ids[2])
          .every((task) => task.status == TransferStatus.completed),
      dump: () => '接收端：${show(receiverRepo.currentTasks)}',
      timeout: const Duration(seconds: 30),
    );
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('目录检查期间断了连接，一个都没接成时不能报成功', () async {
    final senderRepo = TransferRepositoryLocal(sender, fileStorage());
    addTearDown(() => senderRepo.dispose());
    final storage = _SlowWritableCheckStorage(
      settingsService: SettingsService(StorageService()),
      storageService: StorageService(),
    );
    final receiverRepo = TransferRepositoryLocal(receiver, storage);
    addTearDown(() => receiverRepo.dispose());

    const size = 64 * 1024;
    const count = 3;
    final files = <PickedFile>[];
    for (var i = 0; i < count; i++) {
      final file = await makeFile('d$i.bin', size);
      files.add(PickedFile(path: file.path, name: 'd$i.bin', size: size));
    }
    await senderRepo.sendFiles(files);

    final offers = <TransferTask>[];
    await waitFor(
      '应收到 $count 个待接收请求',
      () {
        offers
          ..clear()
          ..addAll(receiverRepo.currentTasks
              .where((task) => task.status == TransferStatus.waiting));
        return offers.length == count;
      },
      dump: () => '接收端：${show(receiverRepo.currentTasks)}',
    );
    final ids = offers.map((task) => task.id).toList(growable: false);

    final accepting = receiverRepo.acceptMany(ids, saveDirectory: saveDir.path);
    await storage.reachedWritableCheck.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException('目录检查迟迟没开始'),
    );

    // 目录检查还没回来，连接先断了。
    await sender.disconnect();
    storage.release();

    final result = await accepting.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException('acceptMany 迟迟没返回'),
    );

    expect(
      result,
      isA<Error<int>>(),
      reason: '一个都没接成却报成功，界面会提示「已接收 $count 个文件」',
    );
    expect(
      receiverRepo.currentTasks.every((task) =>
          task.status == TransferStatus.failed ||
          task.status == TransferStatus.rejected),
      isTrue,
      reason: '断了就是断了，不该有文件被拉进接收流程：${show(receiverRepo.currentTasks)}',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('超过并发上限的接收任务只是排队，不会被判成传输停滞', () async {
    // 一次收 4 个，上限是 3：第 4 个必然要等前面让出名额。
    // 停滞阈值压到 400 毫秒（真实值是 90 秒，测试等不起），
    // 于是「排队等待」和「真的卡住」在测试里立刻分出高下。
    final senderRepo = TransferRepositoryLocal(sender, fileStorage());
    addTearDown(() => senderRepo.dispose());
    final receiverRepo = TransferRepositoryLocal(
      receiver,
      fileStorage(),
      stallTimeout: const Duration(milliseconds: 400),
      // 其余超时拉长：这条用例只许「停滞」这一条路径出手。
      offerTimeout: const Duration(minutes: 5),
      ackTimeout: const Duration(minutes: 5),
    );
    addTearDown(() => receiverRepo.dispose());

    const size = 64 * 1024 * 1024;
    const count = AppConfig.maxConcurrentTransfers + 1;
    final files = <PickedFile>[];
    for (var i = 0; i < count; i++) {
      final file = await makeFile('q$i.bin', size);
      files.add(PickedFile(path: file.path, name: 'q$i.bin', size: size));
    }
    await senderRepo.sendFiles(files);

    final offers = <TransferTask>[];
    await waitFor(
      '应收到 $count 个待接收请求',
      () {
        offers
          ..clear()
          ..addAll(receiverRepo.currentTasks
              .where((task) => task.status == TransferStatus.waiting));
        return offers.length == count;
      },
      dump: () => '接收端：${show(receiverRepo.currentTasks)}',
      timeout: const Duration(seconds: 10),
    );
    final ids = offers.map((task) => task.id).toList(growable: false);
    await receiverRepo.acceptMany(ids, saveDirectory: saveDir.path);

    // 盯住「已同意、但一个字节都还没收到」的那些任务：
    // 它们只是在等对端轮到自己，任何时候被判失败都说明规则错了。
    var sawQueued = false;
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      final tasks = receiverRepo.currentTasks;
      final streaming = tasks
          .where((task) =>
              task.status == TransferStatus.transferring &&
              task.transferredBytes > 0)
          .length;
      final queued = tasks
          .where((task) =>
              task.status == TransferStatus.transferring &&
              task.transferredBytes == 0)
          .toList(growable: false);

      if (streaming >= AppConfig.maxConcurrentTransfers && queued.isNotEmpty) {
        sawQueued = true;
        for (final task in queued) {
          expect(
            task.isFinished,
            isFalse,
            reason: '排队等名额的文件被判停滞了：${show(tasks)}',
          );
        }
      }
      if (tasks.length == count && tasks.every((task) => task.isFinished)) break;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }

    expect(
      sawQueued,
      isTrue,
      reason: '没观察到「已同意但排队」的时刻，这条用例就没验证到目标场景',
    );

    await waitFor(
      '四个文件都应正常收完',
      () => receiverRepo.currentTasks.length == count &&
          receiverRepo.currentTasks.every((task) => task.isFinished),
      dump: () => '接收端：${show(receiverRepo.currentTasks)}',
      timeout: const Duration(seconds: 60),
    );
    expect(
      receiverRepo.currentTasks
          .where((task) => task.status == TransferStatus.completed)
          .length,
      count,
      reason: '排队的文件最终也要收完：${show(receiverRepo.currentTasks)}',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// 把「这个目录能不能写」的探测停在半路的存储服务。
///
/// 批量接收时这一探是好几轮真实 IO，也是 acceptMany 里最长的一段 await
/// ——用户完全可能在这期间取消勾选。测试要确定的就是这个窗口，
/// 所以自己控制它什么时候返回。
class _SlowWritableCheckStorage extends FileStorageService {
  _SlowWritableCheckStorage({
    required super.settingsService,
    required super.storageService,
  });

  /// 已经进入「目录可写性探测」这一步。
  final Completer<void> reachedWritableCheck = Completer<void>();

  final Completer<void> _gate = Completer<void>();

  /// 放开探测，让批量接收继续往下走。
  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<bool> isWritableDirectory(String directory) async {
    if (!reachedWritableCheck.isCompleted) reachedWritableCheck.complete();
    await _gate.future;
    return super.isWritableDirectory(directory);
  }
}
