import 'package:flutter_test/flutter_test.dart';
import 'package:mova/config/app_config.dart';

void main() {
  group('文件类型白名单', () {
    test('覆盖市面上常见与专业的视频格式', () {
      // 覆盖主流容器、摄像机/手机、专业 RAW、监控录制、裸流几大类。
      const samples = [
        // 主流容器
        'mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', 'flv', 'wmv',
        'mpg', 'mpeg', 'ts', 'm2ts', 'mts', 'vob', 'rmvb', '3gp',
        'ogv', 'asf', 'f4v', 'divx', 'wtv',
        // 摄像机与手机
        'mod', 'tod', 'mqv', 'dv', 'k3g',
        // 专业 / RAW
        'mxf', 'r3d', 'braw', 'ari', 'cin', 'gxf',
        // 监控录制
        'dav', 'vdr',
        // 裸流与新编码
        'h264', 'h265', 'hevc', 'av1', 'ivf', 'y4m',
        // 老格式与过场动画
        'swf', 'bik', 'roq',
      ];

      for (final ext in samples) {
        expect(AppConfig.allowedFileExtensionSet.contains(ext), isTrue,
            reason: '.$ext 应该可以发送');
      }
    });

    test('支持常见压缩包与归档格式', () {
      for (final ext in ['zip', 'zipx', 'rar', '7z', 'tar', 'gz', 'tgz',
        'bz2', 'tbz2', 'xz', 'txz', 'zst', 'lz4', 'cab', 'lzh', 'cpio']) {
        expect(AppConfig.allowedFileExtensionSet.contains(ext), isTrue,
            reason: '.$ext 应该可以发送');
      }
    });

    test('清单内部无重复、无空项', () {
      expect(
        AppConfig.videoExtensions.toSet().length,
        AppConfig.videoExtensions.length,
        reason: 'videoExtensions 里有重复项',
      );
      expect(
        AppConfig.allowedFileExtensions.toSet().length,
        AppConfig.allowedFileExtensions.length,
        reason: '合并后的白名单里有重复项（图片/视频/文档交叉了）',
      );
      for (final ext in AppConfig.allowedFileExtensions) {
        expect(ext.isNotEmpty, isTrue);
        expect(ext, ext.toLowerCase(), reason: '扩展名应统一小写：$ext');
      }
    });

    test('可执行文件与安装包不在白名单内', () {
      const blocked = ['exe', 'dll', 'sh', 'bat', 'app', 'dmg', 'msi'];
      for (final ext in blocked) {
        expect(AppConfig.allowedFileExtensionSet.contains(ext), isFalse,
            reason: '.$ext 不应该被允许发送');
      }
    });
  });
}
