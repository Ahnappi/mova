import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../config/app_config.dart';

/// 一次迁移的结局。
enum StorageMigrationStatus {
  /// 已经有标记，这次什么都没做。
  alreadyDone,

  /// 没有旧目录可搬（全新安装）；已打标记，以后不用再找。
  notNeeded,

  /// 全部搬完；已打标记。
  done,

  /// 有文件没搬成，或中途抛错。**没有**打标记，下次启动会重试。
  failed,
}

/// 迁移报告：搬了几个、哪几个没搬成。
class StorageMigrationReport {
  const StorageMigrationReport({
    required this.moved,
    this.failed = const <String>[],
  });

  /// 成功搬过去的文件数。
  final int moved;

  /// 没搬成的文件名（搬不动的原因不外乎占用 / 权限 / 磁盘）。
  final List<String> failed;

  /// 是否算「搬完了」：一个失败都没有才算。
  bool get ok => failed.isEmpty;
}

/// 本地存储数据源（Service 层）：只回答「数据在哪、占多大、能不能清」。
///
/// 不涉及任何业务逻辑，也不认识 [StorageEntry] 之外的领域概念。
class StorageService {
  final Logger _log = Logger('StorageService');

  /// 应用数据目录（由系统分配，macOS 下在沙箱容器内）。
  ///
  /// 目录名由**应用标识**决定：macOS 取 Bundle ID、Windows 取 exe 的
  /// CompanyName + ProductName（见 [AppConfig.legacyMacosBundleId] 那几条
  /// 常量的说明）。发布前把标识从 com.example.* 改掉之后，系统会给出
  /// 一个全新的空目录——老用户的传输历史与设置会「消失」，文件其实还
  /// 在旧目录里。因此每次取目录都顺带尝试迁移一次（只跑一次，见
  /// [_migrateLegacyData]）。
  Future<Directory> appSupportDirectory() async {
    final directory = await getApplicationSupportDirectory();
    await _ensureExists(directory);
    await migrateLegacyData(directory);
    return directory;
  }

  /// 把旧标识目录下的历史与设置搬进 [target]，返回迁移状态。
  ///
  /// 四条原则：
  /// - **不覆盖**：新目录里已经有同名文件就跳过。新版本已经在写的数据
  ///   永远比旧数据可信，覆盖只会把用户刚改的设置改回去；
  /// - **不删除**旧目录：它是这次迁移的备份，万一搬错了还能人工取回；
  /// - **成功才打标记**：标记只表示「这件事不用再做了」。有文件没搬成
  ///   （被占用 / 无权限 / 磁盘满）时绝不能写标记——写了就等于宣布
  ///   「迁移完成」，下次启动不再重试，那批历史就永久留在旧目录里了；
  /// - **只跑一次**：标记存在就直接返回。
  ///
  /// [legacy] 默认按平台拼出真实路径（读系统环境变量），
  /// 测试里可以直接给一个临时目录。
  Future<StorageMigrationStatus> migrateLegacyData(
    Directory target, {
    Directory? legacy,
  }) async {
    final marker =
        File(p.join(target.path, AppConfig.storageMigrationMarker));
    if (await marker.exists()) return StorageMigrationStatus.alreadyDone;

    Directory? source;
    try {
      source = legacy ?? _legacyDirectory();
      if (source == null || !await source.exists()) {
        // 没有旧目录可搬（全新安装）。打标记，之后不必每次都去找一遍。
        await _writeMarker(marker);
        return StorageMigrationStatus.notNeeded;
      }

      final report = await copyMissingFiles(source, target, copy: copyFile);
      if (!report.ok) {
        // **不打标记**：下次启动再试一次。
        _log.warning(
          '迁移未完成，${report.failed.length} 个文件没搬成'
          '（${report.failed.join('、')}），下次启动会重试',
        );
        return StorageMigrationStatus.failed;
      }
      if (report.moved > 0) {
        _log.fine('已从旧数据目录迁移 ${report.moved} 个文件：${source.path}');
      }
      await _writeMarker(marker);
      return StorageMigrationStatus.done;
    } catch (e) {
      // 迁移失败不影响正常使用：最坏的情况是历史为空、设置回到默认值。
      // 同样不打标记，下次启动还有机会。
      _log.warning('迁移旧数据目录失败：$e');
      return StorageMigrationStatus.failed;
    }
  }

  /// 写「迁移完成」标记。
  ///
  /// 也是先写临时文件再改名：标记哪怕只写进去半个，下次启动也会看到
  /// 「标记存在」从而跳过迁移——那比多搬一次严重得多。
  Future<void> _writeMarker(File marker) async {
    final staging =
        File(marker.path + AppConfig.storageMigrationTempSuffix);
    try {
      await staging.writeAsString(DateTime.now().toIso8601String());
      await staging.rename(marker.path);
    } catch (e) {
      await _deleteQuietly(staging);
      // 写不下标记只意味着下次会再扫一次旧目录，不影响数据本身。
      _log.warning('写入迁移标记失败：$e');
    }
  }

  /// 删除一个可能不存在、也可能删不掉的文件（失败一律忽略）。
  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 清不掉就留着：下次迁移开始时会再清一遍。
    }
  }

  /// 清掉上次（被中断的）迁移留下的临时文件。
  ///
  /// 进程在复制途中被杀掉时，临时文件是没有人来收尾的。
  /// 不清的话它们会一直躺在数据目录里。
  static Future<void> _clearStagingFiles(Directory target) async {
    await for (final entity
        in target.list(recursive: false, followLinks: false)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith(AppConfig.storageMigrationTempSuffix)) continue;
      await _deleteQuietly(entity);
    }
  }

  /// 复制单个文件（迁移用）。
  ///
  /// 单独抽出来是为了让测试能模拟「搬不动」：真实环境里的文件占用、
  /// 权限不足、磁盘写满都发生在这里，而这条路径恰恰是最容易漏测的
  /// ——「迁移失败」如果也被打上完成标记，历史就永久丢了。
  @visibleForTesting
  Future<void> copyFile(File source, String destination) =>
      source.copy(destination);

  /// 旧版数据目录（只认两个桌面平台；其它平台返回 null）。
  Directory? _legacyDirectory() {
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) return null;
      return Directory(
        p.join(
          home,
          'Library',
          'Application Support',
          AppConfig.legacyMacosBundleId,
        ),
      );
    }
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData == null || appData.isEmpty) return null;
      return Directory(
        p.join(
          appData,
          AppConfig.legacyWindowsCompanyName,
          AppConfig.legacyWindowsProductName,
        ),
      );
    }
    return null;
  }

  /// 把 [source] 里**目标还没有**的文件复制进 [target]，返回一份报告。
  ///
  /// 单独抽成静态方法是为了能直接测：真实路径要读系统环境变量，
  /// 测试里给两个临时目录就能验证「只补缺失、不覆盖、重复执行无害」。
  /// 只搬顶层文件（历史与设置都是文件），日志目录不搬——它本来就是
  /// 可再生的。
  ///
  /// 报告里**必须**带上搬失败的那些：调用方靠它决定能不能打「迁移完成」
  /// 标记，只看搬成功的个数会把「部分失败」当成圆满完成。
  ///
  /// 每个文件都**先复制到临时文件、确认完整后改名**过去（见
  /// [AppConfig.storageMigrationTempSuffix]）：复制直接写正式路径的话，
  /// 复制到一半失败（磁盘写满、进程被杀）会在正式路径上留下半个文件，
  /// 而下一次重试看到「已存在」就跳过它——半个文件就这样被当成迁移结果，
  /// 甚至据此打上完成标记。改名在同一分区内是原子的，要么没有、要么完整。
  ///
  /// [copy] 可注入，测试用它模拟搬不动 / 只搬了一半的文件。
  static Future<StorageMigrationReport> copyMissingFiles(
    Directory source,
    Directory target, {
    Future<void> Function(File source, String destination)? copy,
  }) async {
    final perform = copy ?? _defaultCopy;
    var moved = 0;
    final failed = <String>[];
    await _clearStagingFiles(target);

    await for (final entity
        in source.list(recursive: false, followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final destination = File(p.join(target.path, name));
      if (await destination.exists()) continue;

      final staging = File(destination.path + AppConfig.storageMigrationTempSuffix);
      try {
        await perform(entity, staging.path);
        // 复制「没报错」也不等于完整：写完再对一次字节数，
        // 静默截断（磁盘配额、网络盘）只有这一步能发现。
        if (!await _sameLength(entity, staging)) {
          throw const FileSystemException('复制结果与源文件长度不一致');
        }
        await staging.rename(destination.path);
        moved++;
      } catch (_) {
        // 单个文件搬不动就记下来，不影响其它文件。
        failed.add(name);
        // 关键：把残缺的临时文件删掉，别让它变成下一次重试看到的「已存在」。
        await _deleteQuietly(staging);
      }
    }
    return StorageMigrationReport(moved: moved, failed: failed);
  }

  /// [staging] 的字节数是否与 [source] 一致（读不到长度时按一致处理）。
  static Future<bool> _sameLength(File source, File staging) async {
    try {
      return await staging.length() == await source.length();
    } catch (_) {
      // 量不到就放行：这种情况 rename 之后仍然是一个完整复制的尝试，
      // 而不是我们明确知道它是残缺的。
      return true;
    }
  }

  static Future<void> _defaultCopy(File source, String destination) =>
      source.copy(destination);

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
