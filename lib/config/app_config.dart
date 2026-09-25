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
  ///
  /// 视频封装极其零散——手机、相机、非编软件、监控系统各有各的格式，
  /// 只列十几个「常见格式」必然会有用户发不出去的文件，
  /// 因此这里按「主流容器 / 摄像机与专业格式 / 裸流 / 老格式 / 监控录制」
  /// 尽量覆盖市面上的格式。
  static const List<String> videoExtensions = [
    // 主流容器与流媒体封装
    'mp4',
    'm4v',
    'mp4v',
    'mpg4',
    'mov',
    'qt',
    'mkv',
    'mk3d',
    'webm',
    'avi',
    'divx',
    'xvid',
    'flv',
    'f4v',
    'f4p',
    'wmv',
    'wm',
    'wmx',
    'asf',
    'wtv',
    'dvr',
    'dvr-ms',
    'mpg',
    'mpeg',
    'mpe',
    'm1v',
    'm2v',
    'mpv',
    'm2p',
    'ps',
    'pss',
    'pva',
    'ts',
    'm2ts',
    'mts',
    'm2t',
    'tp',
    'trp',
    'vob',
    'vro',
    'dat',
    'evo',
    'ogv',
    'ogx',
    'ogg',
    'rm',
    'rmvb',
    'rv',
    '3gp',
    '3g2',
    '3gpp',
    '3gpp2',
    'amv',
    'dpg',
    'smv',
    'mtv',
    'svi',
    'nsv',
    'nut',
    'gxf',
    'mxf',
    'ismv',
    'ismt',
    'hdmov',
    'dmb',
    'k3g',
    'str',
    // 摄像机、手机与专业 RAW 视频
    'mod',
    'tod',
    'mqv',
    'dv',
    'dif',
    'r3d',
    'braw',
    'ari',
    'cin',
    'drc',
    'tivo',
    // 裸流与编解码测试容器
    'h264',
    'h265',
    'hevc',
    '264',
    '265',
    'avc',
    'av1',
    'obu',
    'ivf',
    'vp8',
    'vp9',
    'y4m',
    'mjp',
    'mj2',
    // 老格式与游戏过场动画
    'fli',
    'flc',
    'mve',
    'vmd',
    'bik',
    'bk2',
    'roq',
    'smk',
    'swf',
    // 监控设备录制
    'dav',
    'vdr',
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

  /// 允许传输的扩展名集合（全小写）：拖拽批量校验时的 O(1) 查表。
  static final Set<String> allowedFileExtensionSet =
      allowedFileExtensions.toSet();

  /// 用于界面提示的类型概览（避免把上百个扩展名罗列出来）。
  static const String allowedSummary = '图片 / 视频 / PDF / Office 文档';

  /// 进度刷新间隔：高频分块时按此节流，避免每块都触发整页重建。
  static const Duration progressThrottle = Duration(milliseconds: 100);

  // ---------- 本地存储 ----------

  /// 应用配置文件名（位于应用数据目录下）。
  static const String settingsFileName = 'settings.json';

  /// 日志目录名（位于应用数据目录下）。
  static const String logsDirectoryName = 'logs';

  /// 日志文件名。
  static const String logFileName = 'mova.log';

  /// 连接记录文件名（位于应用数据目录下）。
  static const String historyFileName = 'history.json';

  /// 连接记录文件格式版本：后续字段变更时用于兼容升级。
  static const int historyFileVersion = 1;

  /// 连接记录落盘合并延迟：期间的多条变更合并成一次写文件。
  static const Duration historyPersistDelay = Duration(milliseconds: 400);

  /// 单个日志文件的大小上限，超过后轮转为 `mova.log.1`，避免日志无限增长。
  static const int maxLogFileBytes = 2 * 1024 * 1024;
}
