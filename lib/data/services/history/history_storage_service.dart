import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../config/app_config.dart';
import '../../../domain/models/history/session_record.dart';
import '../storage/storage_service.dart';

/// 连接记录数据源（Service 层）：一个位于应用数据目录下的 JSON 文件。
///
/// 只负责「读文件 / 写文件」，不认识任何业务逻辑。
/// 单条记录损坏时跳过该条，不影响其余记录加载。
class HistoryStorageService {
  HistoryStorageService(this._storage);

  final StorageService _storage;

  String? _cachedPath;

  /// 连接记录文件路径。
  Future<String> filePath() async =>
      _cachedPath ??= await _computeFilePath();

  Future<String> _computeFilePath() async {
    final support = await _storage.appSupportDirectory();
    return p.join(support.path, AppConfig.historyFileName);
  }

  /// 读取全部连接记录（最新的在前）。
  Future<List<SessionRecord>> readAll() async {
    final file = File(await filePath());
    if (!await file.exists()) return const <SessionRecord>[];

    String content;
    try {
      content = await file.readAsString();
    } catch (_) {
      return const <SessionRecord>[];
    }
    if (content.trim().isEmpty) return const <SessionRecord>[];

    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map) return const <SessionRecord>[];

      final raw = decoded['sessions'];
      if (raw is! List) return const <SessionRecord>[];

      final records = <SessionRecord>[];
      for (final item in raw) {
        if (item is! Map) continue;
        try {
          records.add(SessionRecord.fromJson(Map<String, dynamic>.from(item)));
        } catch (_) {
          // 单条损坏就跳过，不让一条坏数据拖垮整个历史。
        }
      }
      return records;
    } catch (_) {
      // 文件整体损坏时当作空历史，避免应用起不来。
      return const <SessionRecord>[];
    }
  }

  /// 覆盖写入全部连接记录。
  ///
  /// 先写临时文件再原子替换，避免写入中途退出导致历史整体丢失。
  Future<void> writeAll(List<SessionRecord> sessions) async {
    final path = await filePath();
    final file = File(path);
    await file.parent.create(recursive: true);

    final temp = File('$path.tmp');
    await temp.writeAsString(jsonEncode(_encode(sessions)));
    await temp.rename(path);
  }

  /// 同步覆盖写入：退出前用，保证「没有 await 也能写完」。
  ///
  /// 路径未解析过（从未读写）时直接跳过——此时也没有内容可写。
  void writeAllSync(List<SessionRecord> sessions) {
    final path = _cachedPath;
    if (path == null) return;

    final temp = File('$path.tmp');
    temp.writeAsStringSync(jsonEncode(_encode(sessions)));
    temp.renameSync(path);
  }

  Map<String, dynamic> _encode(List<SessionRecord> sessions) =>
      <String, dynamic>{
        'version': AppConfig.historyFileVersion,
        'sessions': <Map<String, dynamic>>[
          for (final session in sessions) session.toJson(),
        ],
      };
}
