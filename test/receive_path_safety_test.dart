import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:mova/data/services/storage/settings_service.dart';
import 'package:mova/data/services/storage/storage_service.dart';
import 'package:mova/data/services/transfer/file_storage_service.dart';

/// 文件名来自对端，不能直接拼进保存目录：
/// `../../etc/passwd`、`..\secret.txt` 这类名字会让文件落到目录之外，
/// 而 Windows 的保留名（CON / NUL / COM1）与控制字符则会直接写失败。
void main() {
  late Directory temp;
  late Directory saveDir;
  late FileStorageService storage;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mova_path_test');
    saveDir = Directory('${temp.path}/save')..createSync();
    storage = FileStorageService(
      settingsService: SettingsService(StorageService()),
      storageService: StorageService(),
    );
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响测试结果。
    }
  });

  group('文件名清洗', () {
    test('目录穿越（..）被去掉', () {
      expect(storage.sanitizeFileName('../../etc/passwd'), 'passwd');
      expect(storage.sanitizeFileName('..\\..\\secret.txt'), 'secret.txt');
      expect(storage.sanitizeFileName('/absolute/path/video.mp4'), 'video.mp4');
    });

    test('Windows 保留设备名被改写', () {
      expect(storage.sanitizeFileName('CON'), isNot('CON'));
      expect(storage.sanitizeFileName('nul.txt'), isNot('nul.txt'));
      expect(storage.sanitizeFileName('COM1'), isNot('COM1'));
    });

    test('控制字符与非法字符被处理', () {
      final cleaned = storage.sanitizeFileName('a\u0001b|c<d>.mp4');
      expect(cleaned, isNot(contains('\u0001')));
      expect(cleaned, isNot(contains('|')));
      expect(cleaned, isNot(contains('<')));
    });

    test('结尾的点与空格被去掉（Windows 会静默截断）', () {
      expect(storage.sanitizeFileName('movie.'), 'movie');
      expect(storage.sanitizeFileName('movie  '), 'movie');
    });

    test('空名与超长名都有兜底', () {
      expect(storage.sanitizeFileName(''), isNotEmpty);
      expect(storage.sanitizeFileName('...'), isNotEmpty);
      final long = storage.sanitizeFileName('${'a' * 500}.mp4');
      expect(long.length, lessThanOrEqualTo(220));
      expect(long, endsWith('.mp4'));
    });
  });

  group('目标路径限制在保存目录内', () {
    test('正常文件名落在目录里', () async {
      final target = await storage.resolveTargetPath(saveDir.path, 'a.mp4');
      expect(p.isWithin(saveDir.path, target), isTrue);
    });

    test('穿越文件名也只会落在目录里', () async {
      final target = await storage.resolveTargetPath(
        saveDir.path,
        '../../../../etc/passwd',
      );
      expect(p.isWithin(saveDir.path, target), isTrue);
      expect(p.basename(target), 'passwd');
    });

    test('反斜杠分隔的 Windows 风格穿越同样被挡住', () async {
      final target = await storage.resolveTargetPath(
        saveDir.path,
        r'..\..\evil.txt',
      );
      expect(p.isWithin(saveDir.path, target), isTrue);
    });

    test('同名文件自动改名，不覆盖已有文件', () async {
      final first = await storage.resolveTargetPath(saveDir.path, 'a.mp4');
      await File(first).writeAsString('x');

      final second = await storage.resolveTargetPath(saveDir.path, 'a.mp4');
      expect(second, isNot(first));
      expect(p.basename(second), contains('(1)'));
      expect(p.isWithin(saveDir.path, second), isTrue);
    });

    test('临时文件每次独立生成，不会覆盖已有文件', () {
      final first = storage.tempPathFor(saveDir.path, 'a.mp4');
      final second = storage.tempPathFor(saveDir.path, 'a.mp4');

      // 关键：两次接收同一个名字也必须有各自的临时文件。
      // 固定名字 + 覆盖写会直接把前一次的半成品截断。
      expect(first, isNot(second));
      expect(first, endsWith('.mova-part'));
      expect(second, endsWith('.mova-part'));
      expect(p.isWithin(saveDir.path, first), isTrue);
      expect(p.isWithin(saveDir.path, second), isTrue);
    });

    test('临时文件名同样被限制在保存目录内', () {
      final evil = storage.tempPathFor(saveDir.path, '../../evil.mp4');
      expect(p.isWithin(saveDir.path, evil), isTrue);
      expect(p.basename(evil), contains('evil.mp4'));
    });
  });
}
