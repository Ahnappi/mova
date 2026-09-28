import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../../../config/app_config.dart';
import '../../../domain/models/history/session_record.dart';
import '../storage/storage_service.dart';

/// 连接记录数据源（Service 层）：一个位于应用数据目录下的 JSON 文件。
///
/// 只负责「读文件 / 写文件」，不认识任何业务逻辑。
/// 单条记录损坏时跳过该条，不影响其余记录加载。
///
/// 写盘全程是**异步**的（含退出前的收尾写）：同步写会把主 isolate 整块
/// 占住，期间界面与退出流程的超时计时器都走不动。需要「退出前一定落盘」
/// 的调用方请 await 写入（见 `AppShutdown`）。
class HistoryStorageService {
  HistoryStorageService(this._storage);

  final StorageService _storage;
  final Logger _log = Logger('HistoryStorageService');

  String? _cachedPath;

  /// 放到后台 isolate 编码的次数。
  ///
  /// 主要是给测试用：确认大快照真的没在主 isolate 上编码
  /// （只有编码**成功返回**才计数，起不了 isolate 时不会假装走过后台）。
  int backgroundEncodes = 0;

  /// 连接记录文件路径。
  Future<String> filePath() async => _cachedPath ??= await _computeFilePath();

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
    await File(path).parent.create(recursive: true);

    final json = await _encodeAsync(sessions);
    final temp = File('$path.tmp');
    await temp.writeAsString(json);
    await temp.rename(path);
  }

  /// 编码整份快照：规模超过 [AppConfig.historyBackgroundEncodeEntries]
  /// 时搬到后台 isolate。
  ///
  /// 写盘本身早已是异步的（[File.writeAsString] 走 I/O 线程池），
  /// 但 JSON 编码是纯 CPU，留在主 isolate 上就等于把事件循环占住。
  Future<String> _encodeAsync(List<SessionRecord> sessions) async {
    if (_entryCount(sessions) < AppConfig.historyBackgroundEncodeEntries) {
      return _encodeJson(sessions);
    }

    try {
      // 计数放在**成功之后**：起不了 isolate 时也不该假装走过后台。
      final json = await Isolate.run(() => _encodeJson(sessions));
      backgroundEncodes++;
      return json;
    } catch (e) {
      // 起不了 isolate（资源不足 / 平台限制）就退回主 isolate：
      // 慢一点，但绝不能因此写不出去——写不出去是要丢记录的。
      _log.warning('连接记录后台编码不可用，退回主 isolate：$e');
      return _encodeJson(sessions);
    }
  }

  /// 快照规模的粗略估计：记录 + 消息 + 文件的条目数。
  ///
  /// 只用条目数当尺子：真正的字节数得编码完才知道，而编码正是想搬走的
  /// 那份开销。条目数与体积是单调相关的，用来挑「值不值得起 isolate」足够。
  int _entryCount(List<SessionRecord> sessions) {
    var count = sessions.length;
    for (final session in sessions) {
      count += session.messages.length + session.files.length;
    }
    return count;
  }
}

/// 快照编码。
///
/// 必须是**顶层函数**：isolate 之间只能发送顶层 / 静态函数的引用。
/// 前后两条路径（主 isolate 与后台 isolate）共用它，编码结果才不会分叉。
String _encodeJson(List<SessionRecord> sessions) => jsonEncode(
      <String, dynamic>{
        'version': AppConfig.historyFileVersion,
        'sessions': <Map<String, dynamic>>[
          for (final session in sessions) session.toJson(),
        ],
      },
    );
