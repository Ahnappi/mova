import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mova/config/app_config.dart';
import 'package:mova/data/repositories/history/history_repository_local.dart';
import 'package:mova/data/services/history/history_storage_service.dart';
import 'package:mova/data/services/storage/storage_service.dart';
import 'package:mova/domain/models/history/session_record.dart';

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

/// 可控制的落盘器：第一次异步写会卡在闸门处，
/// 用来安排「旧快照正在写 → 期间又产生新记录 → 退出」这个交错。
///
/// 同时记录并发写入数：退出用的同步写若与正在跑的异步写同时进行，
/// 两者会抢同一个 `history.json.tmp`。
class _GatedHistoryStorage extends HistoryStorageService {
  // 基类构造参数是私有的（_storage），跨库没法写成 super 参数。
  // ignore: use_super_parameters
  _GatedHistoryStorage(StorageService storage, {this.failFirstWrite = false})
      : super(storage);

  final bool failFirstWrite;
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();

  /// 第一次写盘**彻底结束**的信号。
  ///
  /// 必须等它再去读文件：否则可能在旧快照还没落盘时就读了，
  /// 那样「内容对不对」这条断言就成了看运气的。
  final Completer<void> firstWriteDone = Completer<void>();

  int attempts = 0;
  int activeWrites = 0;
  int maxConcurrentWrites = 0;

  void open() {
    if (!release.isCompleted) release.complete();
  }

  @override
  Future<void> writeAll(List<SessionRecord> sessions) async {
    attempts++;
    final isFirst = attempts == 1;
    activeWrites++;
    if (activeWrites > maxConcurrentWrites) {
      maxConcurrentWrites = activeWrites;
    }
    try {
      if (isFirst) {
        if (!entered.isCompleted) entered.complete();
        await release.future;
        if (failFirstWrite) {
          throw const FileSystemException('模拟写盘失败');
        }
      }
      await super.writeAll(sessions);
    } finally {
      activeWrites--;
      if (isFirst && !firstWriteDone.isCompleted) firstWriteDone.complete();
    }
  }
}

/// 前 [failures] 次写盘抛异常，之后恢复正常——用来验证「写失败会重试」。
class _FlakyHistoryStorage extends HistoryStorageService {
  // 基类构造参数是私有的（_storage），跨库没法写成 super 参数。
  // ignore: use_super_parameters
  _FlakyHistoryStorage(StorageService storage, {required this.failures})
      : super(storage);

  int failures;
  int attempts = 0;

  @override
  Future<void> writeAll(List<SessionRecord> sessions) async {
    attempts++;
    if (attempts <= failures) {
      throw const FileSystemException('模拟写盘失败');
    }
    await super.writeAll(sessions);
  }
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mova_history_retry_test');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('写盘失败后保留待保存标记，重试成功后记录不丢', () async {
    final flaky = _FlakyHistoryStorage(_FakeStorage(root), failures: 2);
    final repository = HistoryRepositoryLocal(flaky);
    addTearDown(() => repository.dispose());

    await repository.load();
    await repository.startSession(peerName: 'MacBook', peerIp: '10.0.0.5');
    await repository.appendMessage(
      SessionMessage(
        text: '重要消息',
        sender: '我',
        isSelf: true,
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      ),
    );

    // 前两次写盘失败：等待退避重试把内容补写出去。
    for (var i = 0; i < 100 && flaky.attempts < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    expect(flaky.attempts, greaterThanOrEqualTo(3), reason: '失败后应当自动重试');

    // 重新读盘：内容必须在。
    final reopened = HistoryRepositoryLocal(
      HistoryStorageService(_FakeStorage(root)),
    );
    addTearDown(() => reopened.dispose());
    await reopened.load();

    expect(reopened.currentSessions.length, 1);
    expect(reopened.currentSessions.single.messages.single.text, '重要消息');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('记录条数超过上限时淘汰最旧的，进行中的会话保留', () async {
    final repository = HistoryRepositoryLocal(
      HistoryStorageService(_FakeStorage(root)),
    );
    addTearDown(() => repository.dispose());
    await repository.load();

    // 上限是 200，这里开 210 条已结束的会话（直接构造后写盘）。
    for (var i = 0; i < 210; i++) {
      final id = await repository.startSession(
        peerName: '设备$i',
        peerIp: '10.0.0.$i',
      );
      await repository.endSession(id);
    }
    await repository.dispose();

    final reopened = HistoryRepositoryLocal(
      HistoryStorageService(_FakeStorage(root)),
    );
    addTearDown(() => reopened.dispose());
    await reopened.load();

    // 上限是 AppConfig.maxHistorySessions，超出的最旧记录被淘汰。
    expect(reopened.currentSessions.length, AppConfig.maxHistorySessions);
    // 最新的那条（设备209）必须在。
    expect(reopened.currentSessions.first.peerName, '设备209');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('退出时最后落盘的一定是最新快照（旧快照不会覆盖新记录）', () async {
    final gated = _GatedHistoryStorage(_FakeStorage(root));
    final repository = HistoryRepositoryLocal(gated);

    await repository.load();
    await repository.startSession(peerName: 'MacBook', peerIp: '10.0.0.5');
    await repository.appendMessage(_message('第一条'));

    // 等节流写盘真的开始：这一次写的是「只有第一条」的旧快照，
    // 并且会一直卡在闸门处。
    await gated.entered.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('节流写盘没有开始'),
    );

    // 旧快照还在写的时候又来了一条记录。
    await repository.appendMessage(_message('第二条'));

    // 此刻退出：收尾写必须排在旧快照之后，否则会被它盖掉。
    final closing = repository.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    gated.open();
    await closing.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('dispose 没有返回'),
    );
    // 必须等那次旧快照写完再读：读早了会读到「被覆盖之前」的内容，
    // 断言就成了看运气。
    await gated.firstWriteDone.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('第一次写盘没有结束'),
    );

    final reopened = HistoryRepositoryLocal(
      HistoryStorageService(_FakeStorage(root)),
    );
    addTearDown(() => reopened.dispose());
    await reopened.load();

    final texts = reopened.currentSessions.single.messages
        .map((item) => item.text)
        .toList();
    expect(texts, <String>['第一条', '第二条'],
        reason: '最后写出去的不是最新快照');
    expect(gated.maxConcurrentWrites, 1,
        reason: '收尾写与正在跑的写入并行了（两者共用同一个临时文件）');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('关闭后写失败不再安排重试', () async {
    final gated = _GatedHistoryStorage(_FakeStorage(root), failFirstWrite: true);
    final repository = HistoryRepositoryLocal(gated);

    await repository.load();
    await repository.startSession(peerName: 'MacBook', peerIp: '10.0.0.5');
    await repository.appendMessage(_message('重要消息'));

    await gated.entered.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('节流写盘没有开始'),
    );

    // 退出，然后让那次写入失败：失败回调不许再装重试计时器。
    final closing = repository.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    gated.open();
    await closing.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('dispose 没有返回'),
    );

    final attemptsAtClose = gated.attempts;
    // 最小重试间隔是 1s，等超过它就一定能看出有没有偷偷重试。
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    expect(gated.attempts, attemptsAtClose,
        reason: '关闭之后仍在安排重试（没人会再等它的结果）');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('大快照的 JSON 编码放到后台 isolate，小快照就地编码', () async {
    final storage = HistoryStorageService(_FakeStorage(root));
    final repository = HistoryRepositoryLocal(storage);
    addTearDown(() => repository.dispose());

    await repository.load();
    await repository.startSession(peerName: 'MacBook', peerIp: '10.0.0.5');

    // 阈值以下：就地编码。节流写盘每几百毫秒就来一次，
    // 为它起 isolate 反而更慢。
    await repository.appendMessage(_message('短历史'));
    await repository.flush();
    expect(storage.backgroundEncodes, 0,
        reason: '小快照不该付「起 isolate」这份固定开销');

    // 超过阈值：编码必须搬到后台，否则一次编码就占住事件循环——
    // 界面动不了，退出流程的超时计时器也走不动。
    for (var i = 0; i < AppConfig.historyBackgroundEncodeEntries; i++) {
      await repository.appendMessage(_message('第 $i 条消息'));
    }
    await repository.flush();
    expect(storage.backgroundEncodes, greaterThanOrEqualTo(1),
        reason: '大快照仍在主 isolate 上编码，会堵住界面与退出流程的计时器');

    // 后台编码的结果必须能原样读回来。
    await repository.dispose();
    final reopened = HistoryRepositoryLocal(
      HistoryStorageService(_FakeStorage(root)),
    );
    addTearDown(() => reopened.dispose());
    await reopened.load();
    expect(
      reopened.currentSessions.single.messages.length,
      AppConfig.historyBackgroundEncodeEntries + 1,
      reason: '后台编码写出去的内容与内存快照不一致',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));
}

SessionMessage _message(String text) => SessionMessage(
      text: text,
      sender: '我',
      isSelf: true,
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    );
