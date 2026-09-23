/// 应用级常量（端口、超时、传输参数等）。
///
/// 集中放置，便于后续调整为可配置项。
class AppConfig {
  const AppConfig._();

  /// TCP 消息端口：对端主动连接本机时使用。
  static const int tcpPort = 49153;

  /// UDP 发现端口：局域网广播心跳使用。
  static const int discoveryPort = 49154;

  /// 心跳广播间隔。
  static const Duration announceInterval = Duration(seconds: 3);

  /// 对端心跳超时时间：超过此时间未收到心跳即从列表移除。
  static const Duration peerTimeout = Duration(seconds: 10);

  /// 主动连接超时时间。
  static const Duration connectTimeout = Duration(seconds: 5);

  // ---------- 文件传输 ----------

  /// 单个数据块大小（1 MiB）。
  ///
  /// 采用「分块流式」读写，无论多大的文件都不会被整体读进内存，
  /// 因此 10GB 级文件与 10MB 文件的内存占用是一样的。
  static const int fileChunkSize = 1024 * 1024;

  /// 发送端未确认积压上限（8 MiB）。
  ///
  /// 达到上限就等待 socket 把积压数据真正写出去（flush）再继续读盘，
  /// 避免发送快于网络时把内存撑爆——这是能稳定传大文件的关键。
  static const int maxInFlightBytes = 8 * 1024 * 1024;

  /// 允许传输的图片扩展名。
  static const List<String> imageExtensions = [
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
    'tif',
    'tiff',
    'svg',
    'ico',
  ];

  /// 允许传输的视频扩展名。
  static const List<String> videoExtensions = [
    'mp4',
    'mov',
    'm4v',
    'avi',
    'mkv',
    'flv',
    'wmv',
    'webm',
    '3gp',
    'mpg',
    'mpeg',
    'ts',
  ];

  /// 允许传输的文档扩展名。
  static const List<String> documentExtensions = [
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
  ];

  /// 允许传输的文件扩展名（图片 / 视频 / 常见文档）。
  static const List<String> allowedFileExtensions = [
    ...documentExtensions,
    ...imageExtensions,
    ...videoExtensions,
  ];

  /// 用于界面提示的类型概览（避免把几十个扩展名罗列出来）。
  static const String allowedSummary = '图片 / 视频 / PDF / Office 文档';

  /// 供 file_picker 使用的扩展名清单。
  ///
  /// 部分平台（尤其 Windows）的选择器对扩展名大小写敏感，
  /// 因此额外带上纯大写与首字母大写两种变体，避免 .JPG / .MOV 选不到。
  static List<String> get allowedExtensionsWithCaseVariants {
    final result = <String>{};
    for (final ext in allowedFileExtensions) {
      result.add(ext);
      result.add(ext.toUpperCase());
      result.add(ext[0].toUpperCase() + ext.substring(1));
    }
    return result.toList(growable: false);
  }

  /// 进度刷新间隔：高频分块时按此节流，避免每块都触发整页重建。
  static const Duration progressThrottle = Duration(milliseconds: 100);

  // ---------- 本地存储 ----------

  /// 应用配置文件名（位于应用数据目录下）。
  static const String settingsFileName = 'settings.json';

  /// 日志目录名（位于应用数据目录下）。
  static const String logsDirectoryName = 'logs';

  /// 日志文件名。
  static const String logFileName = 'mova.log';

  /// 单个日志文件的大小上限，超过后轮转为 `mova.log.1`，避免日志无限增长。
  static const int maxLogFileBytes = 2 * 1024 * 1024;
}
