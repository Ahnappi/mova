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

  /// 允许传输的文件扩展名（v1 仅办公文档）。
  static const List<String> allowedFileExtensions = [
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
  ];

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
