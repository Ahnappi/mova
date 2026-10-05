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

  /// 与本机监听端建一条连接，并等到会话真正建立（sessionId 就绪）。
  ///
  /// 不能只 `await connect()`：会话标识是握手之后才有的，而传输仓储在
  /// 构造时就会读它——早了会拿到 null，之后的「会话绑定」校验会出错。
  Future<T> connectPeer<T extends ChatTransportService>(T transport) async {
    final result = await transport.connect('127.0.0.1', port);
    if (result case Error<void> failure) {
      fail('测试环境里连本机失败：${failure.error}');
    }
    for (var i = 0; i < 200 && transport.sessionId == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(transport.sessionId, isNotNull, reason: '会话没建立，用例前提不成立');
    return transport;
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
    //
    // **排队这件事由闸门制造，不靠文件大小去碰运气**：以前用 4 个 64MiB
    // 文件轮询「3 个在传、1 个排队」，机器快时那一瞬间可能根本采不到样
    // （用例会报「没观察到排队」），而采到样的时候大文件本身又可能被
    // 正常的停滞判定误伤——同样是红，却分不清是规则错了还是机器慢。
    // 现在前 3 个文件卡在推流入口不动，第 4 个确定在排队，想停多久停多久。
    await sender.disconnect();
    // 等接收端把上一个会话彻底清掉再连：连早了会被当成「已连接另一台
    // 设备」拒掉，症状是「一个请求都收不到」——和规则写错长得一模一样，
    // 排查起来非常费劲，所以这里把前提钉死。
    for (var i = 0; i < 200 && receiver.sessionId != null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      receiver.sessionId,
      isNull,
      reason: '上一个会话没断开，这条用例的前提不成立',
    );
    final gated = await connectPeer(_GatedTransport());

    final senderRepo = TransferRepositoryLocal(
      gated,
      fileStorage(),
      // 发送端被闸门按住，它自己也在 transferring 上待着：
      // 这条用例只考接收端的排队豁免，别让发送端的停滞看护抢答。
      stallTimeout: const Duration(minutes: 5),
    );
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

    // 数据量无关紧要：任务停多久由闸门说了算。
    const size = 64 * 1024;
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

    // 并发名额占满之后，剩下的那个就确定在排队了。
    await waitFor(
      '应有 ${AppConfig.maxConcurrentTransfers} 个文件占住推流名额',
      () => gated.enteredIds.length == AppConfig.maxConcurrentTransfers,
      dump: () => '已进入闸门：${gated.enteredIds}；'
          '发送端：${show(senderRepo.currentTasks)}',
      timeout: const Duration(seconds: 30),
    );
    final gatedIds = gated.enteredIds.toSet();
    final queuedId = ids.firstWhere(
      (id) => !gatedIds.contains(id),
      orElse: () => throw StateError(
        '没找到排队的那一个。已进入闸门：$gatedIds，全部请求：$ids',
      ),
    );

    try {
      // 闸门关着的时候没有任何文件真正开始发数据：这段时间若被判停滞，
      // 就是「已同意、还没收到首块」被当成了「传输卡住」。
      await Future<void>.delayed(const Duration(seconds: 3));

      expect(
        gated.enteredIds.length,
        AppConfig.maxConcurrentTransfers,
        reason: '并发名额没占稳，排队场景就不成立：已进入 ${gated.enteredIds}',
      );

      final queued = receiverRepo.currentTasks.firstWhere(
        (task) => task.id == queuedId,
        orElse: () => throw StateError(
          '排队任务不见了：${show(receiverRepo.currentTasks)}',
        ),
      );
      expect(
        queued.status,
        TransferStatus.transferring,
        reason: '排队等名额的文件被判死了：${show(receiverRepo.currentTasks)}',
      );
      expect(
        queued.transferredBytes,
        0,
        reason: '它一个字节都还没收到：${show(receiverRepo.currentTasks)}',
      );
      expect(
        receiverRepo.currentTasks.any((task) =>
            task.status == TransferStatus.failed ||
            task.status == TransferStatus.canceled),
        isFalse,
        reason: '等待期间不该有任何任务失败或取消：'
            '${show(receiverRepo.currentTasks)}',
      );

      // 放行：排队的那个也该照常收完——这是「任务还有效」最直接的证明。
      gated.release();

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
      await waitFor(
        '发送端也应全部发完',
        () => senderRepo.currentTasks.length == count &&
            senderRepo.currentTasks
                .every((task) => task.status == TransferStatus.completed),
        dump: () => '发送端：${show(senderRepo.currentTasks)}',
        timeout: const Duration(seconds: 60),
      );
    } finally {
      // 断言失败也要放行：否则 tearDown 里有任务卡在闸门上。
      gated.release();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// 能把「推流」这一步钉在原地的传输通道。
///
/// 排队场景以前是靠「传一个很大的文件、趁它没传完去采样」碰出来的：
/// 机器越快，越可能采不到那一瞬间；而大文件本身又会被正常的停滞判定
/// 误伤，红了也分不清是规则错还是机器慢。
///
/// 现在每个文件的推流入口都过一道闸门：前 N 个（并发上限）进去就不出来，
/// 第 N+1 个因此**确定**在排队，想停多久停多久。
class _GatedTransport extends ChatTransportService {
  final Completer<void> _release = Completer<void>();

  /// 已经进入推流、正卡在闸门上的 fileId（顺序即进入顺序）。
  final List<int> enteredIds = <int>[];

  /// 放开闸门，让被卡住的传输继续往下跑（可重复调用）。
  void release() {
    if (!_release.isCompleted) _release.complete();
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
    enteredIds.add(fileId);
    await _release.future;
    return super.sendFileStream(
      fileId: fileId,
      path: path,
      expectedSize: expectedSize,
      session: session,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }
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
