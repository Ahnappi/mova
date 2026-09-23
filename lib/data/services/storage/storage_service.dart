import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../config/app_config.dart';

/// 本地存储数据源（Service 层）：只回答「数据在哪、占多大、能不能清」。
///
/// 不涉及任何业务逻辑，也不认识 [StorageEntry] 之外的领域概念。
class StorageService {
  /// 应用数据目录（由系统分配，macOS 下在沙箱容器内）。
  Future<Directory> appSupportDirectory() async {
    final directory = await getApplicationSupportDirectory();
    await _ensureExists(directory);
    return directory;
  }

  /// 日志目录。
  Future<Directory> logDirectory() async {
    final support = await appSupportDirectory();
    final directory = Directory(
      p.join(support.path, AppConfig.logsDirectoryName),
    );
    await _ensureExists(directory);
    return directory;
  }

  /// 配置文件路径。
  Future<String> settingsFilePath() async {
    final support = await appSupportDirectory();
    return p.join(support.path, AppConfig.settingsFileName);
  }

  /// 系统临时目录。
  Future<Directory> tempDirectory() => getTemporaryDirectory();

  /// 兜底的接收目录：下载目录，取不到时退化为当前目录。
  Future<String> fallbackDownloadDirectory() async {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads.path;
    } catch (_) {
      // 取不到就用当前目录兜底。
    }
    return Directory.current.path;
  }

  /// 判断 [path] 是否为目录（不存在时返回 false）。
  Future<bool> isDirectory(String path) => FileSystemEntity.isDirectory(path);

  Future<bool> exists(String path) =>
      FileSystemEntity.type(path).then((type) => type != FileSystemEntityType.notFound);

  /// 统计 [path] 的体积：文件直接取长度，目录递归累加。
  ///
  /// 遇到无权限或已损坏的项时跳过（不会因为一项失败而中断统计）。
  Future<int> sizeOf(String path) async {
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.notFound) return 0;
    if (type != FileSystemEntityType.directory) {
      try {
        return await File(path).length();
      } catch (_) {
        return 0;
      }
    }
    return _sizeOfDirectory(Directory(path));
  }

  Future<int> _sizeOfDirectory(Directory directory) async {
    var total = 0;
    try {
      await for (final entity
          in directory.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          total += await entity.length();
        } catch (_) {
          // 单个文件读不到大小就跳过。
        }
      }
    } catch (_) {
      // 目录不可读时按已统计到的结果返回。
    }
    return total;
  }

  /// 清空目录内容（保留目录本身）。
  Future<void> clearDirectory(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) return;
    await for (final entity
        in directory.list(recursive: false, followLinks: false)) {
      try {
        await entity.delete(recursive: true);
      } catch (_) {
        // 删除失败（被占用 / 无权限）就跳过，不中断。
      }
    }
  }

  /// 删除单个文件。
  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  /// 在系统文件管理器中显示 [path]。
  Future<void> reveal(String path) async {
    if (!await exists(path)) return;
    final isDir = await isDirectory(path);

    if (Platform.isMacOS) {
      // open -R：在 Finder 中定位到该文件（目录则直接打开）。
      await Process.run('open', isDir ? [path] : ['-R', path]);
      return;
    }
    if (Platform.isWindows) {
      // explorer 的 /select, 必须和路径连成一个参数。
      await Process.run('explorer', [isDir ? path : '/select,$path']);
      return;
    }
    await Process.run('xdg-open', [path]);
  }

  Future<Directory> _ensureExists(Directory directory) async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }
}
