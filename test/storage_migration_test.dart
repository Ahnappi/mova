// 应用标识改名之后的数据迁移。
//
// macOS 的 Bundle ID、Windows 的 CompanyName 直接决定 path_provider 返回的
// 数据目录（见 AppConfig 里那几条 legacy* 常量）。标识一改，老用户会拿到
// 一个全新的空目录：历史为空、设置回到默认——其实文件还躺在旧目录里。
//
// 除了「只补缺失、绝不覆盖、可以重复执行」这三条，这里还钉住一条更容易
// 漏的规则：**没搬成就不能打「已完成」标记**。升级那次正好遇上文件被占用
// 或磁盘写满的话，打了标记就再也不会重试，那批历史等于永久丢失。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:mova/config/app_config.dart';
import 'package:mova/data/services/storage/storage_service.dart';

void main() {
  late Directory root;
  late Directory legacy;
  late Directory target;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mova_migration');
    legacy = Directory(p.join(root.path, 'legacy'))..createSync();
    target = Directory(p.join(root.path, 'new'))..createSync();
  });

  tearDown(() async {
    await root.delete(recursive: true).catchError((Object _) => root);
  });

  File writeIn(Directory dir, String name, String content) {
    final file = File(p.join(dir.path, name));
    file.writeAsStringSync(content);
    return file;
  }

  String readIn(Directory dir, String name) =>
      File(p.join(dir.path, name)).readAsStringSync();

  test('只搬新目录里没有的文件，已有的一个字节都不动', () async {
    writeIn(legacy, AppConfig.settingsFileName, '旧设置');
    writeIn(legacy, AppConfig.historyFileName, '旧历史');
    writeIn(target, AppConfig.settingsFileName, '新设置');

    final report = await StorageService.copyMissingFiles(legacy, target);

    expect(report.moved, 1, reason: '只有历史是新目录里没有的，设置不该被搬过来');
    expect(report.ok, isTrue);
    expect(
      readIn(target, AppConfig.settingsFileName),
      '新设置',
      reason: '新版本已经在写的数据比旧数据可信，绝不能被旧文件覆盖',
    );
    expect(
      readIn(target, AppConfig.historyFileName),
      '旧历史',
      reason: '旧目录里的历史应当被搬过来',
    );
    // 旧目录保留着当备份，不删。
    expect(File(p.join(legacy.path, AppConfig.historyFileName)).existsSync(), isTrue);
  });

  test('重复执行不会覆盖已经搬过去的内容', () async {
    writeIn(legacy, AppConfig.historyFileName, '旧历史');

    expect((await StorageService.copyMissingFiles(legacy, target)).moved, 1);
    writeIn(target, AppConfig.historyFileName, '用户刚产生的新历史');

    expect((await StorageService.copyMissingFiles(legacy, target)).moved, 0);
    expect(
      readIn(target, AppConfig.historyFileName),
      '用户刚产生的新历史',
      reason: '再跑一次迁移也不能把用户的新数据冲掉',
    );
  });

  test('旧目录不存在时什么都不做', () async {
    expect((await StorageService.copyMissingFiles(legacy, target)).moved, 0);
    expect(target.listSync(), isEmpty);
  });

  test('迁移失败不会打上完成标记，下次启动还会再试', () async {
    writeIn(legacy, AppConfig.settingsFileName, '旧设置');
    writeIn(legacy, AppConfig.historyFileName, '旧历史');

    final service = _FlakyStorageService(AppConfig.historyFileName);

    // 第一次升级：历史那个文件正好被占用，没搬成。
    final first = await service.migrateLegacyData(target, legacy: legacy);
    expect(first, StorageMigrationStatus.failed);
    expect(
      File(p.join(target.path, AppConfig.historyFileName)).existsSync(),
      isFalse,
      reason: '没搬成就是没搬成',
    );
    expect(readIn(target, AppConfig.settingsFileName), '旧设置');

    final marker = File(p.join(target.path, AppConfig.storageMigrationMarker));
    expect(
      await marker.exists(),
      isFalse,
      reason: '打了标记就等于宣布迁移完成，下次启动不再重试，历史永久留在旧目录',
    );

    // 第二次启动：占用解除了，应当把剩下的搬完并打上标记。
    service.failFor = null;
    final second = await service.migrateLegacyData(target, legacy: legacy);
    expect(second, StorageMigrationStatus.done);
    expect(readIn(target, AppConfig.historyFileName), '旧历史');
    expect(await marker.exists(), isTrue);

    // 第三次：已经有标记，直接跳过。
    expect(
      await service.migrateLegacyData(target, legacy: legacy),
      StorageMigrationStatus.alreadyDone,
    );
  });

  test('没有旧目录时打标记，之后不再反复去找', () async {
    final empty = Directory(p.join(root.path, '不存在的旧目录'));
    final service = StorageService();

    expect(
      await service.migrateLegacyData(target, legacy: empty),
      StorageMigrationStatus.notNeeded,
    );
    expect(
      await File(p.join(target.path, AppConfig.storageMigrationMarker)).exists(),
      isTrue,
      reason: '全新安装也该打标记：否则每次启动都要白找一遍旧目录',
    );
  });

  test('复制到一半失败不会在正式路径上留下半个文件', () async {
    writeIn(legacy, AppConfig.historyFileName, '完整的历史内容');

    // 模拟磁盘写满：内容写进去一部分之后才报错。
    Future<void> halfCopy(File source, String destination) async {
      await File(destination).writeAsString('半截');
      throw const FileSystemException('模拟：磁盘上没有空间了');
    }

    final report = await StorageService.copyMissingFiles(
      legacy,
      target,
      copy: halfCopy,
    );

    expect(report.failed, [AppConfig.historyFileName]);
    expect(report.ok, isFalse);
    expect(
      File(p.join(target.path, AppConfig.historyFileName)).existsSync(),
      isFalse,
      reason: '只复制了一半就不能出现在正式路径上：'
          '下次重试看到「已存在」就会跳过它，半个文件从此被当成迁移结果',
    );
    expect(
      target
          .listSync()
          .where((e) => e.path.endsWith(AppConfig.storageMigrationTempSuffix)),
      isEmpty,
      reason: '残缺的临时文件也要清掉，不能一直躺在数据目录里',
    );

    // 第二次启动（磁盘腾出空间了）：正式路径上没有那个文件，
    // 所以这次会真的再搬一次，而不是被「已存在」跳过。
    final retry = await StorageService.copyMissingFiles(legacy, target);
    expect(retry.moved, 1);
    expect(readIn(target, AppConfig.historyFileName), '完整的历史内容');
  });

  test('复制没报错但内容被截断时，同样不算成功', () async {
    writeIn(legacy, AppConfig.historyFileName, '完整的历史内容');

    final report = await StorageService.copyMissingFiles(
      legacy,
      target,
      // 静默截断：不抛异常，但只写进去一部分（网络盘 / 配额限制会发生）。
      copy: (source, destination) async =>
          File(destination).writeAsString('半截'),
    );

    expect(report.failed, [AppConfig.historyFileName],
        reason: '字节数对不上就是没搬成，只能靠比对长度发现');
    expect(
      File(p.join(target.path, AppConfig.historyFileName)).existsSync(),
      isFalse,
    );
  });

  test('搬失败的文件会被报出来，而不是当作成功', () async {
    writeIn(legacy, AppConfig.settingsFileName, '旧设置');
    writeIn(legacy, AppConfig.historyFileName, '旧历史');

    final report = await StorageService.copyMissingFiles(
      legacy,
      target,
      copy: (source, destination) async {
        if (p.basename(source.path) == AppConfig.historyFileName) {
          throw const FileSystemException('模拟：文件被占用');
        }
        await source.copy(destination);
      },
    );

    expect(report.moved, 1, reason: '设置搬过去了');
    expect(report.failed, [AppConfig.historyFileName]);
    expect(report.ok, isFalse, reason: '有文件没搬成就不能算完成');
  });
}

/// 会搬失败指定文件的存储服务：用来验证「失败后还有重试机会」。
class _FlakyStorageService extends StorageService {
  _FlakyStorageService(this.failFor);

  /// 搬不动的文件名；置为 null 表示全都搬得动
  /// （模拟「下次启动时占用已经解除」）。
  String? failFor;

  @override
  Future<void> copyFile(File source, String destination) async {
    if (failFor != null && p.basename(source.path) == failFor) {
      throw const FileSystemException('模拟：文件被占用');
    }
    await source.copy(destination);
  }
}
