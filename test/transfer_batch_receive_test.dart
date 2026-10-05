import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:mova/data/repositories/transfer/transfer_repository_local.dart';
import 'package:mova/data/services/chat/chat_transport_service.dart';
import 'package:mova/data/services/storage/settings_service.dart';
import 'package:mova/data/services/storage/storage_service.dart';
import 'package:mova/data/services/transfer/file_storage_service.dart';
import 'package:mova/domain/models/chat/connection_status.dart';
import 'package:mova/domain/models/transfer/picked_file.dart';
import 'package:mova/domain/models/transfer/transfer_task.dart';
// 必须显式导入：Result 的成类（Ok / Error）不会跟着别的导入进来。
import 'package:mova/utils/result.dart';

/// 批量接收与并发相关的三条规则：
/// 1. 一次发多个文件时，接收端要**一次性**看到全部待接收请求（带批次序号），
///    而不是一个一个冒出来、点完一个才出现下一个；
/// 2. 可以「部分同意」：勾选的接收、没勾选的**明确拒绝**（不能放着不管，
///    否则发送端要干等 120 秒）；
/// 3. 对端在传输途中消失（不发 FIN、不发 RST）时，本端要能在几秒内察觉，
///    而不是一直显示「接收中」。反过来也一样：接收端没了，发送端也要停。
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
    temp = await Directory.systemTemp.createTemp('mova_batch_test');
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
      const Duration(seconds: 10),
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

  /// 轮询等到 [condition] 成立；超时就把双方状态一起抛出来。
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

  test('批量发送时，接收端一次性看到全部待接收请求', () async {
    final senderRepo = TransferRepositoryLocal(sender, fileStorage());
    addTearDown(() => senderRepo.dispose());
    final receiverRepo = TransferRepositoryLocal(receiver, fileStorage());
    addTearDown(() => receiverRepo.dispose());

    const size = 64 * 1024;
    const count = 4;
    final files = <PickedFile>[];
    for (var i = 0; i < count; i++) {
      final file = await makeFile('b$i.bin', size);
      files.add(PickedFile(path: file.path, name: 'b$i.bin', size: size));
    }
    await senderRepo.sendFiles(files);

    // 整批请求要**一次性**发出去：若还停留在「发一个、等一个」，
    // 接收端就只能看见第一个，批量面板也就无从谈起。
    //
    // 因此这里给的是很短的时间窗，而不是「等到凑齐为止」——
    // 等下去的话，串行发送迟早也会凑齐，用例就绿得毫无意义。
    final offers = <TransferTask>[];
    await waitFor(
      '接收端应在 3 秒内一次性收到 $count 个待接收请求',
      () {
        offers
          ..clear()
          ..addAll(receiverRepo.currentTasks.where(
            (task) =>
                task.direction == TransferDirection.receiving &&
                task.status == TransferStatus.waiting,
          ));
        return offers.length == count;
      },
      dump: () => '接收端：${show(receiverRepo.currentTasks)}',
      timeout: const Duration(seconds: 3),
    );

    final batchIds = offers.map((task) => task.batchId).toSet();
    expect(batchIds.length, 1, reason: '同一批发来的文件应共享一个批次号');
    expect(batchIds.single, isNotNull);
    for (final task in offers) {
      expect(task.batchCount, count, reason: '${task.fileName} 没记下批次总数');
    }
    expect(
      offers.map((task) => task.batchIndex).toSet(),
      containsAll(<int>[0, 1, 2, 3]),
      reason: '批次序号应覆盖整批，接收端才能按顺序展示',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('部分同意：勾选的被接收，没勾选的被明确拒绝', () async {
    final senderRepo = TransferRepositoryLocal(sender, fileStorage());
    addTearDown(() => senderRepo.dispose());
    final receiverRepo = TransferRepositoryLocal(receiver, fileStorage());
    addTearDown(() => receiverRepo.dispose());

    const size = 64 * 1024;
    const count = 3;
    final files = <PickedFile>[];
    for (var i = 0; i < count; i++) {
      final file = await makeFile('p$i.bin', size);
      files.add(PickedFile(path: file.path, name: 'p$i.bin', size: size));
    }
    await senderRepo.sendFiles(files);

    // 按「批次序号」而不是 id 排序：文件 id 是随机生成的，
    // 谁先谁后没有意义，序号才对应发送端的顺序。
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

    // 只收第一个和第三个，中间那个明确拒绝。
    final kept = [offers[0].id, offers[2].id];
    final droppedName = offers[1].fileName;
    await receiverRepo.acceptMany(kept, saveDirectory: saveDir.path);
    await receiverRepo.rejectMany([offers[1].id]);

    await waitFor(
      '接收端的任务都应终结',
      () => receiverRepo.currentTasks.length == count &&
          receiverRepo.currentTasks.every((task) => task.isFinished),
      dump: () => '接收端：${show(receiverRepo.currentTasks)}',
    );

    final done = receiverRepo.currentTasks;
    expect(
      done.where((task) => task.status == TransferStatus.completed).length,
      2,
      reason: '应只接收 2 个：${show(done)}',
    );
    expect(
      done.where((task) => task.status == TransferStatus.rejected).length,
      1,
      reason: '没勾选的那个应被拒绝：${show(done)}',
    );
    expect(
      File(p.join(saveDir.path, droppedName)).existsSync(),
      isFalse,
      reason: '被拒绝的文件（$droppedName）不该出现在保存目录里',
    );

    // 发送端要**立刻**知道被拒了，而不是等满 120 秒的「对方没响应」。
    await waitFor(
      '发送端的任务都应终结',
      () => senderRepo.currentTasks.length == count &&
          senderRepo.currentTasks.every((task) => task.isFinished),
      dump: () => '发送端：${show(senderRepo.currentTasks)}',
      timeout: const Duration(seconds: 15),
    );
    final sent = senderRepo.currentTasks;
    expect(
      sent.where((task) => task.status == TransferStatus.completed).length,
      2,
      reason: '发送端应确认 2 个已送达：${show(sent)}',
    );
    expect(
      sent.where((task) => task.status == TransferStatus.rejected).length,
      1,
      reason: '发送端应收到明确的拒绝，而不是超时：${show(sent)}',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('对端在传输途中消失时，两端都不再显示「传输中」', () async {
    // 这条用例盯的是那个最难受的现象：对方合盖 / Wi-Fi 断了 / 进程被杀，
    // 这些情况既不发 FIN 也不发 RST，本端的 socket 一直「以为还连着」，
    // 界面上就是进度条不动、状态停在接收中，直到若干分钟后才报错。
    await sender.dispose();
    await receiver.dispose();

    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final silentPort = probe.port;
    await probe.close();

    // 接收端的心跳窗口压到几百毫秒：真实环境是 5 秒 / 20 秒，测试等不起。
    receiver = ChatTransportService(
      keepAliveInterval: const Duration(milliseconds: 100),
      keepAliveTimeout: const Duration(milliseconds: 600),
    );
    // 发送端的心跳间隔设成 10 分钟 = 它「死后」一个字节都不会再发，
    // 这正是真实断链的样子（进程没了，哪来的心跳）。
    final silentSender = _SilentSenderTransport();
    sender = silentSender;

    final connected = Completer<void>();
    receiver.status.listen((status) {
      if (status == ConnectionStatus.connected && !connected.isCompleted) {
        connected.complete();
      }
    });
    final statuses = <ConnectionStatus>[];
    receiver.status.listen(statuses.add);

    await receiver.startListening(silentPort);
    await silentSender.connect('127.0.0.1', silentPort);
    await connected.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('对端未接入'),
    );

    final senderRepo = TransferRepositoryLocal(
      silentSender,
      fileStorage(),
      // 其余超时一律拉长：这条用例只许「心跳判死活」这一条路径出手，
      // 否则停滞超时也会把任务判失败，红了却不是它要盯的那个 bug。
      offerTimeout: const Duration(minutes: 5),
      stallTimeout: const Duration(minutes: 5),
      ackTimeout: const Duration(minutes: 5),
    );
    addTearDown(() => senderRepo.dispose());
    final receiverRepo = TransferRepositoryLocal(
      receiver,
      fileStorage(),
      stallTimeout: const Duration(minutes: 5),
    );
    addTearDown(() => receiverRepo.dispose());

    receiverRepo.tasks.listen((tasks) {
      for (final task in tasks) {
        if (task.direction == TransferDirection.receiving &&
            task.status == TransferStatus.waiting) {
          unawaited(receiverRepo.accept(task.id, saveDirectory: saveDir.path));
        }
      }
    });

    const size = 512 * 1024;
    final file = await makeFile('ghost.bin', size);
    await senderRepo.sendFiles([
      PickedFile(path: file.path, name: 'ghost.bin', size: size),
    ]);

    // 等推流真的开始：此刻两端都在「传输中」，对端随即人间蒸发。
    await silentSender.entered.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw TimeoutException(
        '推流迟迟没开始。发送端：${show(senderRepo.currentTasks)}'
        '接收端：${show(receiverRepo.currentTasks)}',
      ),
    );

    // 接收端：几百毫秒内就该判定连接已死，而不是一直停在接收中。
    await waitFor(
      '接收端应在心跳超时后判定连接已断开',
      () => statuses.contains(ConnectionStatus.disconnected),
      timeout: const Duration(seconds: 15),
      dump: () => '状态=${statuses.map((s) => s.name).join(',')}'
          ' 接收端：${show(receiverRepo.currentTasks)}',
    );

    await waitFor(
      '接收端的任务应被判失败',
      () => receiverRepo.currentTasks.every((task) => task.isFinished),
      dump: () => '接收端：${show(receiverRepo.currentTasks)}',
    );
    expect(
      receiverRepo.currentTasks.single.status,
      TransferStatus.failed,
      reason: '接收端应判失败而不是继续显示接收中',
    );

    // 反过来：接收端主动断开后，发送端也不能还挂着「发送中」。
    await waitFor(
      '发送端的任务应被判失败',
      () => senderRepo.currentTasks.every((task) => task.isFinished),
      timeout: const Duration(seconds: 15),
      dump: () => '发送端：${show(senderRepo.currentTasks)}',
    );
    expect(
      senderRepo.currentTasks.single.status,
      TransferStatus.failed,
      reason: '对端没了，发送端不该还显示发送中',
    );

    silentSender.release();
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// 推流到一半就「人间蒸发」的发送端：既不发数据、也不关 socket。
///
/// 用 `socket.destroy()` 模拟不出真实断链——那会发出 FIN/RST，
/// 本端立刻就能察觉，根本轮不到心跳出手。真实情况是进程没了：
/// 一个字节都不再发，连接却还挂在内核里。
class _SilentSenderTransport extends ChatTransportService {
  // 心跳间隔拉到 10 分钟：保证「死后」不再往连接上写一个字节。
  _SilentSenderTransport()
      : super(keepAliveInterval: const Duration(minutes: 10));

  final Completer<void> _entered = Completer<void>();
  final Completer<void> _release = Completer<void>();

  /// 已经走到推流这一步（此刻两端都处于「传输中」）。
  Future<void> get entered => _entered.future;

  /// 放开闸门（用例结束前调用，避免这个 Future 永远悬着）。
  void release() => _release.complete();

  @override
  Future<Result<SentFileSummary>> sendFileStream({
    required int fileId,
    required String path,
    int? expectedSize,
    String? session,
    void Function(int sentBytes)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!_entered.isCompleted) _entered.complete();
    await _release.future;
    return Result.error(Exception('测试闸门：不发任何一个字节'));
  }
}
