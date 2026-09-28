import '../../config/app_config.dart';

/// 应用内预览能力（View 层按此分派渲染方式）。
enum PreviewKind {
  /// 图片：Flutter 内置解码器直接渲染。
  image,

  /// 视频：media_kit（libmpv）播放。
  video,

  /// PDF：pdfx（pdfium）渲染。
  pdf,

  /// 应用内渲染不了，只能交给系统默认程序（Office 文档、SVG、HEIC 等）。
  external,
}

/// 按扩展名判断预览方式（扩展名需已小写、不含点）。
PreviewKind previewKindOf(String extension) {
  if (AppConfig.previewableImageExtensions.contains(extension)) {
    return PreviewKind.image;
  }
  if (AppConfig.videoExtensions.contains(extension)) {
    return PreviewKind.video;
  }
  if (extension == 'pdf') return PreviewKind.pdf;
  return PreviewKind.external;
}

/// 取文件扩展名（小写、不含点；无扩展名时返回空串）。
String extensionOf(String pathOrName) {
  final name = pathOrName.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}
