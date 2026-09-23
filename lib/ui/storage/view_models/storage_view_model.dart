import 'package:flutter/foundation.dart';

import '../../../data/repositories/storage/storage_repository.dart';
import '../../../domain/models/storage/storage_entry.dart';

/// 数据存放位置视图模型（ViewModel 层）：加载 / 统计 / 清理磁盘占用。
class StorageViewModel extends ChangeNotifier {
  StorageViewModel({required StorageRepository storageRepository})
      : _storageRepository = storageRepository;

  final StorageRepository _storageRepository;

  List<StorageEntry> _entries = const <StorageEntry>[];
  bool _loading = false;
  bool _measuring = false;
  String? _errorMessage;

  /// 全部存储位置。
  List<StorageEntry> get entries => _entries;

  bool get isLoading => _loading;

  /// 正在统计体积（目录递归，大目录会稍慢）。
  bool get isMeasuring => _measuring;

  String? get errorMessage => _errorMessage;

  /// 加载位置列表，并异步统计各项体积。
  Future<void> load() async {
    _loading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _entries = await _storageRepository.loadEntries();
    } catch (e) {
      _errorMessage = '读取存储位置失败：$e';
      _loading = false;
      notifyListeners();
      return;
    }

    _loading = false;
    notifyListeners();
    await measure();
  }

  /// 统计体积（可单独调用以刷新）。
  Future<void> measure() async {
    if (_entries.isEmpty) return;

    _measuring = true;
    notifyListeners();

    try {
      _entries = await _storageRepository.measureEntries(_entries);
    } catch (e) {
      _errorMessage = '统计体积失败：$e';
    }

    _measuring = false;
    notifyListeners();
  }

  /// 清空 / 删除某一项，之后重新加载以刷新体积。
  Future<void> delete(StorageEntry entry) async {
    try {
      await _storageRepository.deleteEntry(entry);
    } catch (e) {
      _errorMessage = '清理失败：$e';
      notifyListeners();
      return;
    }
    await load();
  }

  /// 在系统文件管理器中显示。
  Future<void> reveal(StorageEntry entry) =>
      _storageRepository.revealEntry(entry);
}
