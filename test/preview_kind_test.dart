import 'package:flutter_test/flutter_test.dart';
import 'package:mova/config/app_config.dart';
import 'package:mova/ui/preview/preview_kind.dart';

void main() {
  group('扩展名提取', () {
    test('从完整路径取小写扩展名', () {
      expect(extensionOf('/Users/me/Desktop/a.MOV'), 'mov');
      expect(extensionOf(r'C:\Users\me\clip.MP4'), 'mp4');
    });

    test('无扩展名或点开头时返回空串', () {
      expect(extensionOf('/Users/me/README'), '');
      expect(extensionOf('/Users/me/.bashrc'), '');
    });
  });

  group('预览方式分派', () {
    test('常见图片走内置解码', () {
      for (final ext in AppConfig.previewableImageExtensions) {
        expect(previewKindOf(ext), PreviewKind.image, reason: '.$ext');
      }
    });

    test('视频走 media_kit', () {
      for (final ext in ['mp4', 'mov', 'mkv', 'rmvb', 'flv', 'avi', 'ts']) {
        expect(previewKindOf(ext), PreviewKind.video, reason: '.$ext');
      }
    });

    test('PDF 走 pdfium', () {
      expect(previewKindOf('pdf'), PreviewKind.pdf);
    });

    test('应用内渲染不了的格式交给系统', () {
      // Office 需要宿主程序；svg 是矢量、heic 需要平台解码器，
      // Flutter 都渲染不了，不能给出一个空白预览页。
      for (final ext in ['doc', 'docx', 'xls', 'xlsx', 'svg', 'heic']) {
        expect(previewKindOf(ext), PreviewKind.external, reason: '.$ext');
      }
    });
  });

  test('可预览的图片格式都在可传输白名单内', () {
    // 否则会出现「能收到但预览不了」或反过来「能预览却发不出去」的割裂。
    for (final ext in AppConfig.previewableImageExtensions) {
      expect(AppConfig.allowedFileExtensionSet.contains(ext), isTrue,
          reason: '.$ext');
    }
  });
}
