import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../config/app_config.dart';
import 'storage_service.dart';

/// 日志落盘（Service 层）：把运行日志写进应用数据目录下的日志文件。
///
/// 日志是纯诊断信息，可在「数据存放位置」里安全删除，删除后会自动重建。
class LogService {
  LogService(this._storage);

  final StorageService _storage;

  Future<String>? _pathFuture;

  /// 日志文件路径（首次调用时解析一次并缓存）。
  Future<String> logFilePath() {
    return _pathFuture ??= _storage
        .logDirectory()
        .then((directory) => p.join(directory.path, AppConfig.logFileName));
  }

  /// 提前创建目录与文件，让路径在界面上立即可见。
  Future<void> init() async {
    final path = await logFilePath();
    final file = File(path);
    await file.parent.create(recursive: true);
    if (!await file.exists()) await file.create();
  }

  /// 追加一行日志；超过 [AppConfig.maxLogFileBytes] 时先轮转。
  Future<void> _appendQueue = Future<void>.value();

  Future<void> append(String line) {
    _appendQueue = _appendQueue.then((_) => _appendLine(line));
    return _appendQueue;
  }

  /// 等待此前已入队的记录；调用方决定最长等待时间。
  Future<void> flush() => _appendQueue;

  Future<void> _appendLine(String line) async {
    try {
      final file = File(await logFilePath());
      await file.parent.create(recursive: true);
      await _rotateIfNeeded(file);
      await file.writeAsString(
        '$line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (error) {
      // 不再经 Logger 记录，以免写入失败递归产生更多日志。
      try {
        await File(p.join(Directory.systemTemp.path, 'mova-diagnostics.log'))
            .writeAsString('${DateTime.now().toIso8601String()} 日志写入失败：$error\n$line\n',
                mode: FileMode.append, flush: true);
      } catch (_) {
        // 两处都不可写时仍不能让日志错误终止应用。
      }
    }
  }

  /// 清空日志（当前文件与轮转备份）。
  Future<void> clear() async {
    final path = await logFilePath();
    for (final target in <String>{path, '$path.1'}) {
      final file = File(target);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {
          // 删除失败忽略。
        }
      }
    }
  }

  Future<int> sizeBytes() async {
    var total = 0;
    final path = await logFilePath();
    for (final target in <String>{path, '$path.1'}) {
      final file = File(target);
      if (await file.exists()) {
        try {
          total += await file.length();
        } catch (_) {
          // 读不到就按 0 计。
        }
      }
    }
    return total;
  }

  Future<void> _rotateIfNeeded(File file) async {
    if (!await file.exists()) return;
    if (await file.length() < AppConfig.maxLogFileBytes) return;

    final backup = File('${file.path}.1');
    if (await backup.exists()) {
      try {
        await backup.delete();
      } catch (_) {
        return;
      }
    }
    try {
      await file.rename(backup.path);
    } catch (_) {
      // 轮转失败就继续往原文件写，最多文件大一些。
    }
  }
}
