import 'dart:async';

import 'package:logging/logging.dart';

import '../../../config/app_config.dart';
import '../../../domain/models/history/session_record.dart';
import '../../services/history/history_storage_service.dart';
import 'history_repository.dart';

/// 连接记录仓储的本地实现：以 JSON 文件持久化。
///
/// 四个关键约束：
/// 1. **写盘节流**：每条消息都同步写文件会拖慢收发，因此合并到
///    [AppConfig.historyPersistDelay] 后一次性落盘；退出前强制补写一次。
/// 2. **写盘串行化**：所有写操作排队执行，不会两次写互相穿插
///    （否则后写的旧快照可能覆盖掉更新的内容）。
/// 3. **失败可恢复**：写失败时**保留**待保存标记并退避重试，
///    绝不能把「还没写出去」当成「已经写好了」——那样这条记录就永久丢了。
/// 4. **损坏自愈**：单条记录解析失败只跳过该条，文件整体损坏则当空历史，
///    绝不让历史文件把应用搞崩。
/// 5. **退出是同一条队列上的最后一次写**（见 [dispose]）：收尾写不能绕开
///    [_writeChain] 直接落盘，否则会和正在跑的写入抢同一个临时文件，
///    而且旧快照后落盘会把更新的记录盖掉。
///
/// 注：目前是整份 JSON 覆盖写，记录条数受 [AppConfig.maxHistorySessions]
/// 限制，单文件通常只有几百 KB。若日后记录量明显增长（数万条以上），
/// 应换成追加式日志或 SQLite，而不是继续放大这个文件。
class HistoryRepositoryLocal implements HistoryRepository {
  HistoryRepositoryLocal(this._storage);

  final HistoryStorageService _storage;
  final Logger _log = Logger('HistoryRepositoryLocal');

  final StreamController<List<SessionRecord>> _controller =
      StreamController<List<SessionRecord>>.broadcast();

  List<SessionRecord> _sessions = const <SessionRecord>[];
  String? _activeSessionId;

  Future<void>? _loading;
  Timer? _persistTimer;
  Timer? _retryTimer;
  Duration? _retryDelay;

  /// 有待保存的变更（`true` 只表示「变更还没提交到写队列」）。
  ///
  /// 它不是「已经落盘」的反面：[_flush] 会在**排队时**就把它清掉，
  /// 写入本身此时可能还没开始。判断「到底写没写出去」要看 [_revision]
  /// 与 [_persistedRevision] 是否一致。
  bool _dirty = false;

  /// 写盘任务链：保证两次写入不会交错。
  Future<void> _writeChain = Future<void>.value();

  /// 已提交到写队列、但还没落盘的写入数。
  ///
  /// [dispose] 靠它判断要不要先等一等——有写入在跑就绝不能同时写，
  /// 两条路径共用同一个临时文件。
  int _inFlight = 0;

  /// 内存快照的版本号：每次变更 +1。
  ///
  /// 写盘是有延迟的，「没写完就退出」时如果只盯着 [_dirty]，
  /// 会把「已提交到队列」误当成「已落盘」，从而漏掉最后一次补写。
  int _revision = 0;

  /// 已经成功落盘的快照版本号。
  int _persistedRevision = 0;

  /// 是否已关闭。
  ///
  /// 置位后不再接收新的落盘安排：定时器停掉、失败不再重试、
  /// 后续变更也不会再排进写队列——否则「关闭」之后又冒出来的异步失败
  /// 会把重试计时器重新装上，而那时已经没人会去读结果了。
  bool _closed = false;

  @override
  Stream<List<SessionRecord>> get sessions => _controller.stream;

  @override
  List<SessionRecord> get currentSessions =>
      List<SessionRecord>.unmodifiable(_sessions);

  @override
  String? get activeSessionId => _activeSessionId;

  /// 载入记录。
  ///
  /// 加载完成后**额外推送一次快照**：调用方可能是后挂载的订阅者
  /// （面板重新打开时 ViewModel 会重建），而仓库只在首次读盘时推送一次，
  /// 不补这一次它就永远收不到数据。
  @override
  Future<void> load() async {
    await _ensureLoaded();
    _emit();
  }

  Future<void> _ensureLoaded() {
    final pending = _loading;
    if (pending != null) return pending;

    final future = _readFromDisk();
    _loading = future;
    return future;
  }

  Future<void> _readFromDisk() async {
    _sessions = await _storage.readAll();
    _emit();
  }

  @override
  Future<String> startSession({
    required String peerName,
    required String peerIp,
  }) async {
    await _ensureLoaded();

    final id = '${DateTime.now().microsecondsSinceEpoch}';
    _sessions = <SessionRecord>[
      SessionRecord(
        id: id,
        peerName: peerName,
        peerIp: peerIp,
        startedAt: DateTime.now(),
      ),
      ..._sessions,
    ];
    _activeSessionId = id;
    _trim();
    _markDirty();
    _emit();
    _schedulePersist();
    return id;
  }

  /// 超过 [AppConfig.maxHistorySessions] 时淘汰最旧的记录。
  ///
  /// 只淘汰已结束的：进行中的会话还在用，删掉会让当前聊天无处可写。
  void _trim() {
    if (_sessions.length <= AppConfig.maxHistorySessions) return;

    final kept = <SessionRecord>[];
    for (final session in _sessions) {
      if (kept.length < AppConfig.maxHistorySessions) {
        kept.add(session);
        continue;
      }
      // 超出的部分只保留进行中的。
      if (session.isActive) kept.add(session);
    }
    _sessions = kept;
  }

  @override
  Future<void> updateSessionPeer(
    String sessionId, {
    String? peerName,
    String? peerIp,
  }) async {
    await _ensureLoaded();

    final index = _sessions.indexWhere((item) => item.id == sessionId);
    if (index < 0) return;

    final old = _sessions[index];
    final next = old.copyWith(peerName: peerName, peerIp: peerIp);
    if (next.peerName == old.peerName && next.peerIp == old.peerIp) return;

    _sessions = <SessionRecord>[..._sessions]..[index] = next;
    _markDirty();
    _emit();
    _schedulePersist();
  }

  @override
  Future<void> endSession(String sessionId) async {
    await _ensureLoaded();

    final index = _sessions.indexWhere((item) => item.id == sessionId);
    if (index < 0) return;
    if (_sessions[index].endedAt != null) return;

    _sessions = <SessionRecord>[..._sessions]
      ..[index] = _sessions[index].copyWith(endedAt: DateTime.now());
    if (_activeSessionId == sessionId) _activeSessionId = null;

    _markDirty();
    _emit();
    _schedulePersist();
  }

  @override
  Future<void> appendMessage(
    SessionMessage message, {
    String? sessionId,
  }) async {
    final targetId = await _resolveSessionId(sessionId);

    final index = _sessions.indexWhere((item) => item.id == targetId);
    if (index < 0) return;

    final session = _sessions[index];
    _sessions = <SessionRecord>[..._sessions]
      ..[index] = session.copyWith(
        messages: <SessionMessage>[...session.messages, message],
      );

    _markDirty();
    _emit();
    _schedulePersist();
  }

  @override
  Future<void> upsertFile(
    SessionFile file, {
    String? sessionId,
  }) async {
    final targetId = await _resolveSessionId(sessionId);

    final index = _sessions.indexWhere((item) => item.id == targetId);
    if (index < 0) return;

    final session = _sessions[index];
    final files = <SessionFile>[...session.files];
    final at = files.indexWhere((item) => item.id == file.id);
    if (at >= 0) {
      files[at] = file;
    } else {
      files.add(file);
    }

    _sessions = <SessionRecord>[..._sessions]
      ..[index] = session.copyWith(files: files);

    _markDirty();
    _emit();
    _schedulePersist();
  }

  /// 落点会话：优先用传入的 id，其次当前会话，都没有就临时开一个。
  ///
  /// 临时会话用于兜底——即便某条消息早于连接状态到达，也不会丢记录。
  Future<String> _resolveSessionId(String? sessionId) async {
    await _ensureLoaded();

    if (sessionId != null) return sessionId;

    final active = _activeSessionId;
    if (active != null) return active;

    return startSession(peerName: '未知设备', peerIp: '');
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    await _ensureLoaded();

    final before = _sessions.length;
    _sessions = <SessionRecord>[
      for (final session in _sessions)
        if (session.id != sessionId) session,
    ];
    if (_sessions.length == before) return;
    if (_activeSessionId == sessionId) _activeSessionId = null;

    _markDirty();
    _emit();
    _schedulePersist();
  }

  @override
  Future<void> clearAll() async {
    await _ensureLoaded();

    // 进行中的会话不清除：它还在用，清掉会让当前聊天无处可写。
    _sessions = <SessionRecord>[
      for (final session in _sessions)
        if (session.isActive) session,
    ];

    // 覆盖写（而不是删文件）：history.json 保留在磁盘上，
    // 「数据存放位置」里始终能看到它的路径。
    _persistTimer?.cancel();
    _persistTimer = null;
    _markDirty();
    _emit();
    await _flush();
  }

  /// 记下一次变更：待保存标记 + 快照版本号。
  void _markDirty() {
    _dirty = true;
    _revision++;
  }

  @override
  Future<String> historyFilePath() => _storage.filePath();

  @override
  Future<void> flush() async {
    if (_closed) return;
    await _ensureLoaded();
    await _flush();
  }

  /// 收尾：停掉定时器 → 等已在跑的写入落地 → 写最终快照 → 关闭。
  ///
  /// 三步必须按这个顺序，原因各不一样：
  /// 1. 先停定时器与重试：关闭之后不该再有新的落盘安排，
  ///    尤其是失败回调里的重试——它装的计时器再也没人会等；
  /// 2. 再等已在队列里的写入：收尾写与它们共用同一个临时文件，
  ///    同时写会互相踩踏；更要命的是旧快照**后**落盘会把更新的记录盖掉
  ///    （旧实现里这两条路径正是并行的）；
  /// 3. 最后才写最终快照：此时内存里的 [_sessions] 一定是最新的，
  ///    且此刻队列已空，不会再有人来抢。
  ///
  /// 判断「还需不需要补写」看的是版本号而不是 [_dirty]：后者在提交到
  /// 队列的那一刻就被清掉了，只表示「变更已排队」，不代表「已落盘」。
  ///
  /// 最终快照同样排进**那条异步队列**，不再同步直写。
  ///
  /// 同步写原先的理由是「宿主不 await dispose，同步写才能保证退出前落盘」。
  /// 但它会把主 isolate 整块占住：编码、写文件、改名期间界面动不了，
  /// 退出流程的**超时计时器也走不动**——真遇到慢磁盘，5 秒超时形同虚设，
  /// 「重试 / 放弃」对话框根本弹不出来。退出流程（AppShutdown）现在会
  /// await 这里，同步写就不再是必需的；回到队列之后反而更稳：
  /// 不会与在途写抢同一个临时文件，也不会堵住事件循环。
  ///
  /// 可以**重复调用**：收尾超时时上层会把结果判成「没保存完」并让用户
  /// 重试（见 AppShutdown），那时 `Future.timeout()` 已经放弃了等待，
  /// 但写入本身还在跑。第二次进来会重新等它落地、再补一次快照——
  /// 「已经关了就直接返回」会把重试变成空操作。
  ///
  /// 最终写盘失败时会**抛出**（而不是记一行日志就当没事）。调用方必须
  /// 自己 catch：把它当成「已保存」就会丢记录。
  @override
  Future<void> dispose() async {
    _closed = true;

    _persistTimer?.cancel();
    _persistTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;

    // 队列里还有写入就先等它落地（队列是串行的，一次 await 就够，
    // while 是为了兜住「等待期间又排进来一个」的极端情况）。
    while (_inFlight > 0) {
      await _writeChain.catchError((Object _) {});
    }

    // 重试时这一段是「接着等」而不是「再排一次」：上一次收尾写可能只是
    // 超过了上层给的时间（Future.timeout 并不取消它），此刻还在队列里跑。
    if (_persistedRevision != _revision) {
      await _enqueueWrite();
    }
    // 重复调用（收尾重试）时别把已关的流再关一次：那会抛 StateError。
    if (!_controller.isClosed) await _controller.close();
  }

  void _schedulePersist() {
    // 关闭后不再安排落盘：最终快照已经由 [dispose] 负责。
    if (_closed) return;

    _persistTimer?.cancel();
    _persistTimer = Timer(AppConfig.historyPersistDelay, () {
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    // 关闭后不再接受新的落盘安排（见 [dispose]）。
    if (_closed) return;
    if (!_dirty) return;

    // 先清标记，成功后才真的算写完；失败会在下面恢复。
    _dirty = false;

    try {
      await _enqueueWrite();
      // 写成功了：清掉退避计时，下次从最小延迟重新开始。
      _retryTimer?.cancel();
      _retryTimer = null;
      _retryDelay = null;
    } catch (e) {
      // 关键：把待保存标记补回来。不补的话，这次变更就被当成「已落盘」，
      // 后续没有任何机制会再想起它——记录就此丢失。
      _dirty = true;
      _log.warning('连接记录落盘失败，将重试：$e');
      _scheduleRetry();
    }
  }

  /// 把当前快照排进写队列，并等它真的落盘。
  ///
  /// 节流写与收尾写共用这一条路径（也就是同一条 [_writeChain]）：
  /// 收尾写绕开队列直写会和正在跑的写入抢同一个临时文件，
  /// 而且旧快照**后**落盘会把更新的记录盖掉。
  ///
  /// 只有成功落盘才推进 [_persistedRevision]：失败时上层据此判断
  /// 「还要再补一次」，重试不会变成空操作。
  Future<void> _enqueueWrite() {
    final snapshot = List<SessionRecord>.unmodifiable(_sessions);
    final revision = _revision;
    _inFlight++;

    _writeChain = _writeChain.catchError((Object _) {}).then((_) async {
      try {
        await _storage.writeAll(snapshot);
        _persistedRevision = revision;
      } finally {
        _inFlight--;
      }
    });
    return _writeChain;
  }

  /// 写失败后的退避重试：1s → 2s → 4s … 上限 30s，直到成功为止。
  void _scheduleRetry() {
    // 已经关闭就别再装计时器了：没有任何人会在退出后等它的结果，
    // 而它又会在后台反复写文件（写的是一份马上就要被丢弃的快照）。
    if (_closed || _retryTimer != null) return;

    final next = _retryDelay == null
        ? const Duration(seconds: 1)
        : _retryDelay! * 2;
    _retryDelay = next > const Duration(seconds: 30)
        ? const Duration(seconds: 30)
        : next;

    _retryTimer = Timer(_retryDelay!, () {
      _retryTimer = null;
      unawaited(_flush());
    });
  }

  void _emit() {
    if (_controller.isClosed) return;
    _controller.add(List<SessionRecord>.unmodifiable(_sessions));
  }
}
