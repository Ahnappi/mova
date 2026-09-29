import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter_test/flutter_test.dart';

import 'package:mova/config/app_shutdown.dart';
import 'package:mova/data/repositories/chat/chat_repository.dart';
import 'package:mova/data/repositories/chat/chat_repository_local.dart';
import 'package:mova/data/repositories/history/history_repository_local.dart';
import 'package:mova/data/repositories/transfer/transfer_repository.dart';
import 'package:mova/data/services/chat/chat_transport_service.dart';
import 'package:mova/data/services/history/history_storage_service.dart';
import 'package:mova/data/services/storage/storage_service.dart';
import 'package:mova/domain/models/chat/chat_message.dart';
import 'package:mova/domain/models/chat/connection_status.dart';
import 'package:mova/domain/models/history/session_record.dart';
import 'package:mova/domain/models/transfer/picked_file.dart';
import 'package:mova/domain/models/transfer/transfer_task.dart';
import 'package:mova/utils/result.dart';

import 'support/fake_window_controller.dart';

/// 只替换「应用数据目录」，其余能力照旧。
class _FakeStorage extends StorageService {
  _FakeStorage(this._directory);

  final Directory _directory;

  @override
  Future<Directory> appSupportDirectory() async {
    if (!await _directory.exists()) {
      await _directory.create(recursive: true);
    }
    return _directory;
  }
}

/// 第一次异步写卡在闸门处：用来证明「退出流程真的在等它」。
class _GatedHistoryStorage extends HistoryStorageService {
  // 基类构造参数是私有的（_storage），跨库没法写成 super 参数。
  // ignore: use_super_parameters
  _GatedHistoryStorage(StorageService storage) : super(storage);

  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();

  /// 同时进行的写入数（峰值）：收尾写若与在途写并行，
  /// 两者会抢同一个 `history.json.tmp`。
  int activeWrites = 0;
  int maxConcurrentWrites = 0;

  @override
  Future<void> writeAll(List<SessionRecord> sessions) async {
    activeWrites++;
    if (activeWrites > maxConcurrentWrites) {
      maxConcurrentWrites = activeWrites;
    }
    try {
      if (!entered.isCompleted) {
        entered.complete();
        await release.future;
      }
      await super.writeAll(sessions);
    } finally {
      activeWrites--;
    }
  }

  void open() {
    if (!release.isCompleted) release.complete();
  }
}

/// 收尾那次写会失败：用来证明「写盘失败」和「写盘超时」一样要拦住退出，
/// 而不是记一行日志就当保存好了。
///
/// 第一次写（节流写盘）照常放行，之后的收尾写才失败——
/// 否则挡住的其实是「上一次写入还没落地」，两种原因会混在一起。
class _FailingFinalWriteStorage extends _GatedHistoryStorage {
  // ignore: use_super_parameters
  _FailingFinalWriteStorage(StorageService storage) : super(storage);

  bool failFinalWrite = true;
  int finalWriteAttempts = 0;
  int writes = 0;

  @override
  Future<void> writeAll(List<SessionRecord> sessions) async {
    writes++;
    if (writes > 1) {
      finalWriteAttempts++;
      if (failFinalWrite) {
        throw const FileSystemException('模拟磁盘已满');
      }
    }
    return super.writeAll(sessions);
  }
}

/// 收尾那次写**卡住**（不是失败）：用来证明退出流程的超时计时器
/// 不会因为写盘而停摆——同步写盘会把主 isolate 占住，计时器根本走不动。
class _StuckFinalWriteStorage extends _GatedHistoryStorage {
  // ignore: use_super_parameters
  _StuckFinalWriteStorage(StorageService storage) : super(storage);

  final Completer<void> releaseFinal = Completer<void>();
  int writes = 0;

  @override
  Future<void> writeAll(List<SessionRecord> sessions) async {
    writes++;
    // 第一次是节流写盘：照常走闸门（证明退出流程确实在等它）。
    if (writes > 1) await releaseFinal.future;
    return super.writeAll(sessions);
  }

  void openFinal() {
    if (!releaseFinal.isCompleted) releaseFinal.complete();
  }
}

/// 什么都不做的聊天仓储：只记录「退出流程有没有叫它停止接收」。
class _FakeChatRepository implements ChatRepository {
  int stopCalls = 0;
  int disconnects = 0;

  @override
  Stream<ChatMessage> get messages => const Stream<ChatMessage>.empty();

  @override
  Stream<ConnectionStatus> get status => const Stream<ConnectionStatus>.empty();

  @override
  String? get sessionId => null;

  @override
  Stream<String> get notices => const Stream<String>.empty();

  @override
  String? get remoteName => null;

  @override
  String? get remoteAddress => null;

  @override
  bool get sealed => stopCalls > 0;

  @override
  set localName(String value) {}

  @override
  Future<Result<void>> startListening(int port) async => Result.ok(null);

  @override
  Future<Result<void>> connect(String host, int port) async => Result.ok(null);

  @override
  Future<Result<void>> send(String text) async => Result.ok(null);

  @override
  Future<void> stopAcceptingConnections() async {
    stopCalls++;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
  }

  @override
  Future<void> dispose() async {}
}

/// 什么都不做的传输仓储：只记录有没有被收尾。
class _FakeTransferRepository implements TransferRepository {
  int disposals = 0;

  @override
  Stream<List<TransferTask>> get tasks => const Stream<List<TransferTask>>.empty();

  @override
  List<TransferTask> get currentTasks => const <TransferTask>[];

  @override
  Future<Result<void>> sendFiles(List<PickedFile> files) async => Result.ok(null);

  @override
  Future<Result<int>> retry(int fileId) async =>
      Result.error(Exception('这个替身不做重发'));

  @override
  Future<({List<PickedFile> accepted, List<String> ignored})>
      pickFilesToSend() async => (accepted: <PickedFile>[], ignored: <String>[]);

  @override
  Future<({List<PickedFile> accepted, List<String> ignored})> filesFromPaths(
    List<String> paths,
  ) async =>
      (accepted: <PickedFile>[], ignored: <String>[]);

  @override
  Future<String> currentSaveDirectory() async => '.';

  @override
  Future<String?> pickSaveDirectory({String? dialogTitle}) async => null;

  @override
  Future<void> rememberSaveDirectory(String directory) async {}

  @override
  Future<Result<void>> accept(int fileId, {String? saveDirectory}) async =>
      Result.ok(null);

  @override
  Future<void> reject(int fileId) async {}

  @override
  Future<void> cancel(int fileId) async {}

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

/// 退出流程的规则：
/// 1. 必须**等**保存真正完成才返回（否则关窗口时进程会先走）；
/// 2. 保存**没完成**（超时或写盘失败）时阻断退出：保留窗口，
///    由用户决定重试还是放弃——写盘失败不能只记一行日志就当成功；
/// 3. 退出第一步要封存连接层（关监听），不能只断开会话；
/// 4. 关闭之后不再接收新的历史变更；
/// 5. 两个入口（关闭按钮 / 系统退出请求）共用一条确认流程：
///    连点关闭不会弹出多个对话框，放行之后也不会销毁多次窗口。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mova_shutdown_test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  SessionMessage message(String text) => SessionMessage(
        text: text,
        sender: '我',
        isSelf: true,
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      );

  Future<int> freePort() async {
    final probe = await ServerSocket.bind('127.0.0.1', 0);
    final port = probe.port;
    await probe.close();
    return port;
  }

  /// 建一套「有旧写入在跑」的场景：会话进行中、已发过消息、
  /// 并且有一次写盘正卡在闸门处。
  Future<({
    HistoryRepositoryLocal history,
    _GatedHistoryStorage storage,
    _FakeChatRepository chat,
    _FakeTransferRepository transfer,
    AppShutdown shutdown,
    FakeWindowController window,
    List<String> prompts,
  })> scenario({
    Duration stepTimeout = const Duration(seconds: 5),
    Future<ExitDecision> Function(String reason, int attempt)? onPrompt,
    _GatedHistoryStorage? storageOverride,
  }) async {
    final storage = storageOverride ?? _GatedHistoryStorage(_FakeStorage(root));
    final history = HistoryRepositoryLocal(storage);
    final chat = _FakeChatRepository();
    final transfer = _FakeTransferRepository();

    await history.load();
    await history.startSession(peerName: 'MacBook', peerIp: '10.0.0.5');
    await history.appendMessage(message('第一条'));

    await storage.entered.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('节流写盘没有开始'),
    );
    // 旧快照还在写，又来了一条新记录。
    await history.appendMessage(message('第二条'));

    final window = FakeWindowController();
    final prompts = <String>[];
    var attempts = 0;
    final shutdown = AppShutdown(
      history: history,
      chat: chat,
      transfer: transfer,
      window: window,
      stepTimeout: stepTimeout,
      prompt: (reason) async {
        prompts.add(reason);
        attempts++;
        if (onPrompt != null) return onPrompt(reason, attempts);
        return ExitDecision.stay;
      },
    );
    // 接上窗口关闭回调（不调 start()：那需要 WidgetsBinding）。
    window.addListener(shutdown);
    return (
      history: history,
      storage: storage,
      chat: chat,
      transfer: transfer,
      shutdown: shutdown,
      window: window,
      prompts: prompts,
    );
  }

  Future<List<String>> textsOnDisk() async {
    final reopened = HistoryRepositoryLocal(
      HistoryStorageService(_FakeStorage(root)),
    );
    addTearDown(() => reopened.dispose());
    await reopened.load();
    return <String>[
      for (final session in reopened.currentSessions)
        for (final item in session.messages) item.text,
    ];
  }

  test('退出流程会等在跑的写入：没写完就不返回', () async {
    final scene = await scenario();

    var returned = false;
    unawaited(scene.shutdown.prepareExit().then((_) {
      returned = true;
    }));

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(returned, isFalse,
        reason: '还有一次写入没落地，退出流程却已经返回了');

    scene.storage.open();
    for (var i = 0; i < 100 && !returned; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(returned, isTrue, reason: '写入落地后退出流程应当返回');

    // 重启验证：两条消息都在，且会话已经收尾（有结束时间）。
    expect(await textsOnDisk(), <String>['第一条', '第二条']);

    final reopened = HistoryRepositoryLocal(
      HistoryStorageService(_FakeStorage(root)),
    );
    addTearDown(() => reopened.dispose());
    await reopened.load();
    expect(reopened.currentSessions.single.endedAt, isNotNull,
        reason: '退出时没有结束会话');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('关闭窗口（退出请求）走完流程后才放行，且记录已保存', () async {
    final scene = await scenario();

    var returned = false;
    unawaited(
      scene.shutdown.didRequestAppExit().then((response) {
        returned = true;
        expect(response, AppExitResponse.exit);
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(returned, isFalse, reason: '保存还没完成就放行了退出');

    scene.storage.open();
    for (var i = 0; i < 100 && !returned; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(returned, isTrue);

    expect(await textsOnDisk(), <String>['第一条', '第二条']);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('退出流程会封存连接层并收尾传输，且只跑一次', () async {
    final scene = await scenario();

    final first = scene.shutdown.prepareExit();
    final second = scene.shutdown.prepareExit();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    scene.storage.open();
    await first.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('退出流程没有返回'),
    );
    await second.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('退出流程没有返回'),
    );

    expect(scene.chat.stopCalls, 1, reason: '退出时必须停止接收新连接');
    expect(scene.chat.disconnects, 0,
        reason: '只断开会话不够——监听还开着，新设备仍能连进来');
    expect(scene.transfer.disposals, 1, reason: '退出时应当收尾传输');
    expect(scene.shutdown.isExiting, isTrue);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('退出后不再接收新的历史变更', () async {
    final scene = await scenario();

    final exit = scene.shutdown.prepareExit();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    scene.storage.open();
    await exit.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('退出流程没有返回'),
    );

    // 关闭之后才来的记录：不该再落到磁盘上。
    await scene.history.appendMessage(message('退出之后'));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(await textsOnDisk(), <String>['第一条', '第二条']);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('保存超时不等于保存完成：窗口保持打开、不销毁', () async {
    // 这一次闸门永远不放开，保存必然超时。
    final scene = await scenario(
      stepTimeout: const Duration(milliseconds: 300),
    );

    final outcome = await scene.shutdown.prepareExit().timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('退出流程被保存卡住了'),
    );
    expect(outcome, isA<ExitBlocked>(),
        reason: '保存超时却被当成「保存完成」——进程会带着未落盘的记录退出');
    expect(scene.shutdown.blockReason, isNotNull);

    // 用户点了关闭：保存没完成就不能真的关窗口。
    scene.window.tapClose();
    for (var i = 0; i < 150 && scene.window.destroyCalls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(scene.window.destroyCalls, 0,
        reason: '保存还没完成，窗口却被关掉了');
    expect(scene.prompts.length, 1, reason: '没有询问用户就擅自留下/退出');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('用户选择强制退出时才销毁窗口', () async {
    final scene = await scenario(
      stepTimeout: const Duration(milliseconds: 300),
      onPrompt: (reason, attempt) async => ExitDecision.force,
    );

    scene.window.tapClose();
    for (var i = 0; i < 150 && scene.window.destroyCalls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(scene.window.destroyCalls, 1,
        reason: '用户明确放弃保存之后，窗口应当关掉');
    expect(scene.window.preventClose, isFalse,
        reason: '放行前要先解除关闭拦截');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('用户选择重试：再跑一遍保存，成功后才关窗口', () async {
    // 第一次被挡住时通知外面放开闸门，之后每次都选「重试」。
    final asked = Completer<void>();
    final scene = await scenario(
      stepTimeout: const Duration(milliseconds: 300),
      onPrompt: (reason, attempt) async {
        if (!asked.isCompleted) asked.complete();
        return ExitDecision.retry;
      },
    );

    scene.window.tapClose();
    await asked.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('保存超时后没有询问用户'),
    );
    // 磁盘缓过来了：重试这一次能成功。
    scene.storage.open();

    for (var i = 0; i < 250 && scene.window.destroyCalls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(scene.window.destroyCalls, 1,
        reason: '重试成功之后应当关掉窗口（重试空转说明 dispose 不可重入）');
    expect(await textsOnDisk(), <String>['第一条', '第二条'],
        reason: '重试之后落盘的必须是最新快照');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('退出期间不再接受新连接：保存卡住时也没有设备能连进来', () async {
    final port = await freePort();
    final transport = ChatTransportService();
    final chat = ChatRepositoryLocal(transport);
    addTearDown(() => chat.dispose());

    expect(
      await transport.startListening(port),
      isA<Ok<void>>(),
      reason: '监听没有开起来，这条用例覆盖不到「退出期间连入」',
    );

    final storage = _GatedHistoryStorage(_FakeStorage(root));
    final history = HistoryRepositoryLocal(storage);
    final transfer = _FakeTransferRepository();
    await history.load();
    await history.startSession(peerName: 'MacBook', peerIp: '10.0.0.5');
    await history.appendMessage(message('第一条'));
    await storage.entered.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('节流写盘没有开始'),
    );

    final window = FakeWindowController();
    final shutdown = AppShutdown(
      history: history,
      chat: chat,
      transfer: transfer,
      window: window,
    );
    unawaited(shutdown.prepareExit());

    // 等「停止接收新连接」这一步生效（此后退出流程卡在保存上）。
    for (var i = 0; i < 200 && !transport.isSealed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(transport.isSealed, isTrue,
        reason: '退出流程没有停止接收新连接');

    // 此刻另一台设备试图连进来：必须被拒，绝不能建出新会话。
    final peer = ChatTransportService();
    addTearDown(() => peer.dispose());
    final inbound = await peer.connect('127.0.0.1', port).timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('连入尝试没有返回'),
    );
    expect(inbound, isA<Error<void>>(), reason: '退出期间竟然还能连进来');
    expect(chat.sessionId, isNull, reason: '退出期间建立了新会话');
    expect(await transport.send('退出中'), isA<Error<void>>(),
        reason: '退出期间还能往外发消息');

    storage.open();
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('最终写盘失败也要拦住退出：窗口保持打开、不销毁', () async {
    // 只有收尾那次同步写会失败：这样被挡住的原因一定是「写坏了」，
    // 而不是「上一次写入还没落地」——两种情况必须分别能挡住退出。
    final storage = _FailingFinalWriteStorage(_FakeStorage(root));
    final scene = await scenario(storageOverride: storage);
    storage.open();

    final outcome = await scene.shutdown.prepareExit().timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('退出流程没有返回'),
    );
    expect(outcome, isA<ExitBlocked>(),
        reason: '收尾写盘失败却被当成「保存完成」，进程会带着未落盘的记录退出');
    expect(scene.shutdown.blockReason, contains('失败'),
        reason: '写失败与写超时要给不同的提示，否则用户不知道该腾空间还是该等');

    // 用户点了关闭：没保存成功就不能真的关窗口。
    scene.window.tapClose();
    for (var i = 0; i < 150 && scene.window.destroyCalls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(scene.window.destroyCalls, 0, reason: '保存失败，窗口却被关掉了');
    expect(scene.prompts.length, 1, reason: '没有询问用户就擅自留下/退出');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('写盘失败后选择重试：磁盘恢复之后才落盘并关窗口', () async {
    final storage = _FailingFinalWriteStorage(_FakeStorage(root));
    final asked = Completer<void>();
    final scene = await scenario(
      storageOverride: storage,
      stepTimeout: const Duration(milliseconds: 500),
      onPrompt: (reason, attempt) async {
        if (!asked.isCompleted) asked.complete();
        return ExitDecision.retry;
      },
    );
    storage.open();

    scene.window.tapClose();
    await asked.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('写盘失败后没有询问用户'),
    );
    // 用户腾出了空间：收尾写不再失败。
    storage.failFinalWrite = false;

    for (var i = 0; i < 250 && scene.window.destroyCalls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(scene.window.destroyCalls, 1,
        reason: '重试成功之后应当关掉窗口（重试空转说明收尾写不可重入）');
    expect(await textsOnDisk(), <String>['第一条', '第二条'],
        reason: '重试之后落盘的必须是最新快照');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('收尾写卡住时超时仍然生效：退出流程能返回并询问用户', () async {
    // 收尾写一直不返回（磁盘极慢）：退出流程必须**按时**放弃等待并询问，
    // 而不是跟着一起卡死——这正是「同步写盘」会造成的后果：
    // 它占住主 isolate，超时计时器与对话框都别想跑。
    final storage = _StuckFinalWriteStorage(_FakeStorage(root));
    final asked = Completer<void>();
    final scene = await scenario(
      storageOverride: storage,
      stepTimeout: const Duration(milliseconds: 300),
      onPrompt: (reason, attempt) async {
        if (!asked.isCompleted) asked.complete();
        return ExitDecision.retry;
      },
    );
    // 节流那次写盘放行，让退出流程走到收尾写。
    storage.open();

    final watch = Stopwatch()..start();
    scene.window.tapClose();
    await asked.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw TimeoutException(
        '收尾写卡住时退出流程没能按时返回：超时机制被写盘拖死了',
      ),
    );
    watch.stop();

    expect(watch.elapsed, lessThan(const Duration(seconds: 3)),
        reason: '保存卡了这么久才询问，说明计时器没有真正并发运行');
    expect(scene.window.destroyCalls, 0, reason: '保存没完成就关掉了窗口');

    // 磁盘缓过来：重试时必须**接着等**那次还没结束的收尾写，
    // 而不是再排一次——两条写同时跑会抢同一个临时文件。
    storage.openFinal();
    for (var i = 0; i < 250 && scene.window.destroyCalls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(scene.window.destroyCalls, 1, reason: '收尾写落地后应当关掉窗口');
    expect(storage.maxConcurrentWrites, 1,
        reason: '收尾写与重试的写入并行了（两者共用同一个临时文件）');
    expect(await textsOnDisk(), <String>['第一条', '第二条']);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('连点关闭只跑一条确认流程：只询问一次、只销毁一次', () async {
    final scene = await scenario(
      stepTimeout: const Duration(milliseconds: 300),
      onPrompt: (reason, attempt) async => ExitDecision.force,
    );

    // 用户不耐烦地连点：三次关闭请求几乎同时到达。
    scene.window.tapClose();
    scene.window.tapClose();
    scene.window.tapClose();

    for (var i = 0; i < 250 && scene.window.destroyCalls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(scene.prompts.length, 1,
        reason: '连点关闭弹出了多个对话框，用户会被互相冲突的选择搞懵');
    expect(scene.window.destroyCalls, 1, reason: '窗口被销毁了多次');
    expect(scene.chat.stopCalls, 1, reason: '连点关闭跑出了多条退出流程');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('关闭按钮与系统退出请求同时到来：只询问一次', () async {
    final scene = await scenario(
      stepTimeout: const Duration(milliseconds: 300),
    );

    scene.window.tapClose();
    final response = await scene.shutdown.didRequestAppExit().timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('系统退出请求没有返回'),
    );

    expect(response, AppExitResponse.cancel,
        reason: '保存没完成却放行了系统退出请求');
    expect(scene.prompts.length, 1, reason: '两个入口各弹了一次对话框');
    expect(scene.window.destroyCalls, 0, reason: '没放行就关掉了窗口');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('两个入口都被放行：窗口只销毁一次', () async {
    final scene = await scenario(
      stepTimeout: const Duration(milliseconds: 300),
      onPrompt: (reason, attempt) async => ExitDecision.force,
    );

    scene.window.tapClose();
    final response = await scene.shutdown.didRequestAppExit().timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('系统退出请求没有返回'),
    );
    expect(response, AppExitResponse.exit);

    for (var i = 0; i < 250 && scene.window.destroyCalls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(scene.prompts.length, 1, reason: '两个入口各弹了一次对话框');
    expect(scene.window.destroyCalls, 1, reason: '两个入口各销毁了一次窗口');
  }, timeout: const Timeout(Duration(minutes: 1)));
}
