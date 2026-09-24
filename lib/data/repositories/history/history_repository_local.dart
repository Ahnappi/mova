import 'dart:async';

import 'package:logging/logging.dart';

import '../../../config/app_config.dart';
import '../../../domain/models/history/session_record.dart';
import '../../services/history/history_storage_service.dart';
import 'history_repository.dart';

/// 连接记录仓储的本地实现：以 JSON 文件持久化。
///
/// 两个关键约束：
/// 1. **写盘节流**：每条消息都同步写文件会拖慢收发，因此合并到
///    [AppConfig.historyPersistDelay] 后一次性落盘；退出前强制补写一次。
/// 2. **损坏自愈**：单条记录解析失败只跳过该条，文件整体损坏则当空历史，
///    绝不让历史文件把应用搞崩。
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
  bool _dirty = false;

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
    _dirty = true;
    _emit();
    _schedulePersist();
    return id;
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
    _dirty = true;
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

    _dirty = true;
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

    _dirty = true;
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

    _dirty = true;
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

    _dirty = true;
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
    _dirty = true;
    _emit();
    await _flush();
  }

  @override
  Future<String> historyFilePath() => _storage.filePath();

  @override
  Future<void> dispose() async {
    _persistTimer?.cancel();
    _persistTimer = null;

    // 退出时用同步写：宿主不会 await 这里，异步写在进程退出时会丢掉最后一批记录。
    if (_dirty) {
      _dirty = false;
      try {
        _storage.writeAllSync(_sessions);
      } catch (e) {
        _log.warning('连接记录收尾写盘失败：$e');
      }
    }
    await _controller.close();
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(AppConfig.historyPersistDelay, () {
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      await _storage.writeAll(_sessions);
    } catch (e) {
      _log.warning('连接记录落盘失败：$e');
    }
  }

  void _emit() {
    if (_controller.isClosed) return;
    _controller.add(List<SessionRecord>.unmodifiable(_sessions));
  }
}
