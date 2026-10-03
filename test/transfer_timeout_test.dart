import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mova/data/repositories/transfer/transfer_repository_local.dart';
import 'package:mova/data/services/chat/chat_transport_service.dart';
import 'package:mova/data/services/storage/settings_service.dart';
import 'package:mova/data/services/storage/storage_service.dart';
import 'package:mova/data/services/transfer/file_storage_service.dart';
import 'package:mova/domain/models/transfer/picked_file.dart';
import 'package:mova/domain/models/transfer/transfer_task.dart';
import 'package:mova/utils/result.dart';

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
  late int port;

  FileStorageService fileStorage() => FileStorageService(
        settingsService: SettingsService(StorageService()),
        storageService: StorageService(),
      );

  /// 与本机监听端建一条连接，并等到会话真正建立（sessionId 就绪）。
  ///
  /// 不能只 `await connect()`：会话标识是握手之后才有的，而传输仓储在
  /// 构造时就会读它——早了会拿到 null，之后的「会话绑定」校验会出错。
  ///
  /// 每条用例自己建自己的连接：接收端一次只接待一个会话，先建一条再换掉
  /// 会在服务端留下一次「连接被重置」，白白污染结果。
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

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mova_timeout_test');
    saveDir = Directory('${temp.path}/save')..createSync();

    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = probe.port;
    await probe.close();

    receiver = ChatTransportService();
    await receiver.startListening(port);
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
    sender = await connectPeer(ChatTransportService());

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

  test('已经开传的任务不再受「等待响应」计时器管', () async {
    // 这条用例只验证**一件事**：「等对端应答」的计时器不许跨界管到已经
    // 处于 transferring 的任务上。因此除 offerTimeout 之外，其余超时一律
    // 显式放大（默认走 AppConfig：停滞 90 秒、回执 60 秒）——若沿用默认值，
    // 慢机器上真正出手的是停滞/回执看护，红了的原因却不是它要盯的 bug。
    const offerTimeout = Duration(milliseconds: 300);
    const plenty = Duration(minutes: 5);

    // 这条用例的发送走一条可控连接：接收端这时候还没有会话，不存在换新。
    final gated = _PausableTransport();
    sender = await connectPeer(gated);

    final senderRepo = TransferRepositoryLocal(
      gated,
      fileStorage(),
      offerTimeout: offerTimeout,
      stallTimeout: plenty,
      ackTimeout: const Duration(minutes: 2),
    );
    addTearDown(() => senderRepo.dispose());

    // 接收端同样被停滞超时管着：它等在原地收数据的时间不比发送端短。
    final receiverRepo = TransferRepositoryLocal(
      receiver,
      fileStorage(),
      stallTimeout: plenty,
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

    // 数据量无关紧要：任务停在 transferring 多久由闸门说了算，不再靠
    // 「文件够大、机器够慢」去碰运气。
    const size = 512 * 1024;
    final file = await makeFile('gated.bin', size);
    await senderRepo.sendFiles([
      PickedFile(path: file.path, name: 'gated.bin', size: size),
    ]);

    // 闸门没起作用时别干等：把双方任务状态一起抛出来。
    String show(List<TransferTask> tasks) => tasks
        .map((t) => '${t.status.name} ${t.transferredBytes}/${t.totalBytes}'
            ' 错误=${t.error}')
        .join('；');

    // 等推流入口：走到这里时任务已经是 transferring，
    // 「等待响应」的计时若没收住，就该在此之后出手了。
    await gated.entered.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException(
        '推流迟迟没开始，闸门没起作用。'
        '发送端：${show(senderRepo.currentTasks)}'
        '接收端：${show(receiverRepo.currentTasks)}',
      ),
    );
    expect(senderRepo.currentTasks.single.status, TransferStatus.transferring,
        reason: '闸门卡住的那一刻，任务应该正在传输');

    // 停在 transferring 上等足够久：既明显越过「等待响应」的期限，
    // 也保证每秒一次的看护计时器至少跑过两三趟。
    final held = Stopwatch()..start();
    await Future<void>.delayed(const Duration(seconds: 3));
    held.stop();

    expect(held.elapsedMilliseconds, greaterThan(2000),
        reason: '停留时间不够长，看护计时器可能一趟都没跑到');

    final during = senderRepo.currentTasks.single;
    final peer = receiverRepo.currentTasks.isEmpty
        ? null
        : receiverRepo.currentTasks.single;
    expect(during.status, TransferStatus.transferring,
        reason: '正在传输的任务被超时误杀了：状态=${during.status.name}，'
            '任务记录的原因=${during.error}');
    expect(during.error, isNull);
    expect(peer?.status, TransferStatus.transferring,
        reason: '接收端也被看护拦下来了：${peer?.status.name} ${peer?.error}');

    // 放行：剩下的流程照常跑完——这是「任务还有效」最直接的证明。
    gated.release();

    // 按截止时间轮询，不数迭代次数：慢机器上每次 sleep 都会被拉长，
    // 数次循环等于给这次传输定了一个看不见的时间上限。
    final deadline = DateTime.now().add(const Duration(minutes: 1, seconds: 30));
    TransferTask? last;
    while (DateTime.now().isBefore(deadline)) {
      final tasks = senderRepo.currentTasks;
      if (tasks.isNotEmpty) {
        last = tasks.single;
        if (last.isFinished) break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // 失败时把双方状态一次性摊开：只报「期望 completed，实际 failed」
    // 等于要人在黑箱里猜是哪条路径判的。
    String dump(String what) {
      final saved = File('${saveDir.path}/gated.bin');
      final savedLength = saved.existsSync() ? saved.lengthSync() : -1;
      final peerState = receiverRepo.currentTasks
          .map((t) => '${t.status.name} 已收${t.transferredBytes}'
              '/${t.totalBytes} 错误=${t.error}')
          .join('；');
      return '$what\n'
          '  发送端：${last?.status.name} 已发${last?.transferredBytes}'
          '/${last?.totalBytes} 错误=${last?.error}\n'
          '  接收端：${peerState.isEmpty ? '（任务已清空）' : peerState}\n'
          '  落盘：expect $size，实际 $savedLength'
          '（存在=${saved.existsSync()}）';
    }

    expect(last, isNotNull, reason: dump('放行之后任务迟迟没有终结。'));
    expect(last!.status, TransferStatus.completed,
        reason: dump('放行之后任务没能完成。'));
    expect(File('${saveDir.path}/gated.bin').lengthSync(), size,
        reason: dump('收到的文件字节数对不上。'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// 能把「推流」这一步钉在原地的传输通道。
///
/// 这条用例要验证的是「等对端应答」的计时器不许管到已经开传的任务上。
/// 以前的做法是传一个很大的文件，指望传输时间长到能跨过看护计时器的
/// 好几个周期——那是**碰运气**：机器越快，整段传输越可能落在两次 tick
/// 之间（实测 150MB 在快机器上不到一秒就传完，而看护是每秒一次），
/// 用例照绿，却什么也没验到；反过来把文件加到几百兆，CI 上又白白多花
/// 时间和磁盘 IO，仍然保证不了覆盖。
///
/// 现在直接在推流入口加一道闸门：任务稳稳停在 transferring，
/// 想停多久停多久，覆盖是确定的，数据量也无关紧要。
class _PausableTransport extends ChatTransportService {
  final Completer<void> _entered = Completer<void>();
  final Completer<void> _release = Completer<void>();

  /// 已经走到推流这一步（此刻任务状态已经是 transferring）。
  Future<void> get entered => _entered.future;

  /// 放开闸门，让被卡住的传输继续往下跑。
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
