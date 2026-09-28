import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/repositories/history/history_repository.dart';
import '../../../data/services/storage/storage_service.dart';
import '../../../data/services/transfer/file_storage_service.dart';
import '../../../domain/models/history/session_record.dart';

/// 连接记录视图模型（ViewModel 层）：查看 / 选择 / 删除历史会话。
class HistoryViewModel extends ChangeNotifier {
  HistoryViewModel({
    required HistoryRepository historyRepository,
    required StorageService storageService,
    required FileStorageService fileStorageService,
  })  : _historyRepository = historyRepository,
        _storageService = storageService,
        _fileStorageService = fileStorageService {
    // 先用仓库的当前快照打底：本 ViewModel 可能被重建（面板重新挂载），
    // 而仓库只在首次加载时推送一次，重建后就再也收不到那次推送了。
    _sessions = _historyRepository.currentSessions;
    _syncSelection(_sessions);

    _subscription = _historyRepository.sessions.listen((sessions) {
      _sessions = sessions;
      _syncSelection(sessions);
      notifyListeners();
      unawaited(_checkPaths());
    });
    unawaited(refresh());
  }

  /// 打开面板即展示最近一次连接；选中项被删掉时改选最新的那条。
  void _syncSelection(List<SessionRecord> sessions) {
    final selected = _selectedId;
    final stillThere =
        selected != null && sessions.any((session) => session.id == selected);
    if (!stillThere) {
      _selectedId = sessions.isEmpty ? null : sessions.first.id;
    }
  }

  final HistoryRepository _historyRepository;
  final StorageService _storageService;
  final FileStorageService _fileStorageService;

  StreamSubscription<List<SessionRecord>>? _subscription;

  List<SessionRecord> _sessions = const <SessionRecord>[];
  String? _selectedId;

  /// 路径是否仍然存在（用于提示「文件已不在原位置」）。
  final Map<String, bool> _pathExists = <String, bool>{};

  /// 全部连接记录（最新的在前）。
  List<SessionRecord> get sessions => _sessions;

  /// 当前选中的记录。
  SessionRecord? get selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final session in _sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  /// 选中一条记录。
  void select(String id) {
    if (_selectedId == id) return;
    _selectedId = id;
    notifyListeners();
    unawaited(_checkPaths());
  }

  /// 重新载入（切换面板显示时调用）。
  Future<void> refresh() => _historyRepository.load();

  /// [path] 对应的文件现在还在不在（未检查过返回 true，避免误报）。
  bool fileExists(String? path) {
    if (path == null || path.isEmpty) return false;
    return _pathExists[path] ?? true;
  }

  /// 删除一条连接记录。
  Future<void> delete(String id) async {
    await _historyRepository.deleteSession(id);
    if (_selectedId == id) _selectedId = null;
    notifyListeners();
  }

  /// 清空全部连接记录（进行中的会话保留）。
  Future<void> clearAll() async {
    await _historyRepository.clearAll();
    _selectedId = null;
    _pathExists.clear();
    notifyListeners();
  }

  /// 在系统文件管理器中定位到 [path]。
  Future<void> reveal(String path) => _storageService.reveal(path);

  /// 逐条检查当前会话里的文件路径是否还在。
  Future<void> _checkPaths() async {
    final session = selected;
    if (session == null) return;

    for (final file in session.files) {
      final path = file.localPath;
      if (path == null || path.isEmpty) continue;
      final exists = _fileStorageService.inspect(path).exists;
      if (_pathExists[path] == exists) continue;
      _pathExists[path] = exists;
      if (hasListeners) notifyListeners();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
