import 'dart:convert';
import 'dart:io';

import 'storage_service.dart';

/// 偏好设置数据源（Service 层）：一个位于应用数据目录下的 JSON 文件。
///
/// 只用文件，不引入额外依赖，便于在「数据存放位置」里一并展示它的路径。
class SettingsService {
  SettingsService(this._storage);

  final StorageService _storage;

  /// 接收文件的保存目录。
  static const String saveDirectoryKey = 'saveDirectory';

  Map<String, dynamic>? _cache;

  Future<String?> readString(String key) async {
    final map = await _load();
    final value = map[key];
    return value is String ? value : null;
  }

  Future<void> writeString(String key, String value) async {
    final map = await _load();
    map[key] = value;
    await _persist(map);
  }

  /// 读整数；不存在或不是数字时返回 null（由调用方给默认值）。
  Future<int?> readInt(String key) async {
    final map = await _load();
    final value = map[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  Future<void> writeInt(String key, int value) async {
    final map = await _load();
    map[key] = value;
    await _persist(map);
  }

  /// 读布尔；不存在或不是布尔时返回 null（由调用方给默认值）。
  Future<bool?> readBool(String key) async {
    final map = await _load();
    final value = map[key];
    return value is bool ? value : null;
  }

  Future<void> writeBool(String key, bool value) async {
    final map = await _load();
    map[key] = value;
    await _persist(map);
  }

  Future<void> remove(String key) async {
    final map = await _load();
    map.remove(key);
    await _persist(map);
  }

  Future<Map<String, dynamic>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;

    final file = File(await _storage.settingsFilePath());
    var map = <String, dynamic>{};
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) map = Map<String, dynamic>.from(decoded);
      } catch (_) {
        // 配置损坏就当空配置，避免应用起不来。
      }
    }
    _cache = map;
    return map;
  }

  Future<void> _persist(Map<String, dynamic> map) async {
    final file = File(await _storage.settingsFilePath());
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(map));
  }
}
