/// 应用级常量（端口、超时、传输参数等）。
///
/// 集中放置，便于后续调整为可配置项。
class AppConfig {
  const AppConfig._();

  /// TCP 消息端口：对端主动连接本机时使用。
  static const int tcpPort = 49153;

  /// 当前协议版本（建连时互报，用于兼容老版本对端）。
  ///
  /// v1：只有 offer / accept / chunk / end / cancel，发送端推完就算完成；
  /// v2：end 帧带上字节数与 CRC32，新增 fileDone 回执帧。
  static const int protocolVersion = 2;

  /// 支持「收尾回执」的最低协议版本。
  ///
  /// 对端低于这个版本时不等待回执（它不会发），直接按完成处理，
  /// 免得明明传好了却白等一个超时。
  static const int receiptProtocolVersion = 2;

  /// UDP 发现端口：局域网广播心跳使用。
  static const int discoveryPort = 49154;

  /// 心跳广播间隔。
  static const Duration announceInterval = Duration(seconds: 3);

  /// 对端心跳超时时间：超过此时间未收到心跳即从列表移除。
  static const Duration peerTimeout = Duration(seconds: 10);

  /// 重新枚举本机网卡、刷新广播目标的间隔。
  ///
  /// 网络是会变的（Wi-Fi 切换、插拔网线、连上/断开 VPN），
  /// 广播目标不能只在启动时算一次，否则会往一个已经不存在的网段发。
  static const Duration broadcastTargetsRefresh = Duration(seconds: 15);

  /// 单次心跳最多发往几个广播地址。
  ///
  /// 多网卡（含虚拟机网卡、Docker 网桥）时可能枚举出十几个网段，
  /// 全部发一遍既浪费又容易被系统判定为异常流量，因此按优先级截断。
  static const int maxBroadcastTargets = 4;

  /// 需要跳过的网卡名前缀（小写匹配）。
  ///
  /// 这些几乎都不是「真正的局域网」：VPN 隧道、虚拟机网卡、Docker 网桥、
  /// 热点共享网卡等。把它们排在选择之外，可以避免连上 VPN 后
  /// 把广播发到公司内网、从而搜不到隔壁那台电脑。
  static const List<String> nonLanInterfacePrefixes = [
    'utun', // macOS VPN / 隧道
    'tap',
    'tun',
    'ppp',
    'ipsec',
    'wg', // WireGuard
    'tailscale',
    'zerotier',
    'nebula',
    'hamachi',
    'docker',
    'br-', // Linux 网桥
    'bridge',
    'veth',
    'vmnet', // VMware
    'vboxnet', // VirtualBox
    'awdl', // macOS AirDrop 直连
    'llw',
  ];

  /// 主动连接超时时间。
  static const Duration connectTimeout = Duration(seconds: 5);

  // ---------- 文件传输 ----------

  /// 单个数据块大小（4 MiB）。
  ///
  /// 采用「分块流式」读写，无论多大的文件都不会被整体读进内存，
  /// 因此 10GB 级文件与 10MB 文件的内存占用是一样的。
  ///
  /// 块越大，Dart 层的循环与系统调用次数越少：实测 1MiB 时每块都要
  /// 经历一次「读盘 → 组帧 → 写 socket → 写文件」的完整往返，
  /// 大文件的吞吐被这些固定开销拖住，调到 4MiB 后开销降到约 1/4。
  static const int fileChunkSize = 4 * 1024 * 1024;

  /// 发送端未确认积压上限（32 MiB）。
  ///
  /// 达到上限就等待 socket 把积压数据真正写出去（flush）再继续读盘，
  /// 避免发送快于网络时把内存撑爆——这是能稳定传大文件的关键。
  /// 阈值太小会让 flush 频繁打断读盘、网络出现空档；32MiB 兼顾内存与吞吐。
  static const int maxInFlightBytes = 32 * 1024 * 1024;

  /// 发出文件请求后，**等待对方点「接收 / 拒绝」**的上限。
  ///
  /// 只覆盖「对方还没应答」这一段：对端既不接收也不拒绝时（比如人不在），
  /// 不能让整个发送队列永久卡住。
  ///
  /// 注意：一旦对方点了接收、任务进入传输中，这个计时器就不再起作用，
  /// 改由 [transferStallTimeout] 看护。否则一个传十分钟的大文件会在
  /// 两分钟时被误判成「对方未响应」。
  static const Duration offerResponseTimeout = Duration(seconds: 120);

  /// 传输/接收过程中「长时间没有任何进展」的上限。
  ///
  /// 与 [offerResponseTimeout] 的分工：前者管「对方不理你」，这里管
  /// 「已经在传但卡住了」（网络断了但 socket 没报错、对端进程僵死等）。
  /// 判断依据是字节数有没有变化，因此持续传输的大文件永远不会触发。
  static const Duration transferStallTimeout = Duration(seconds: 90);

  /// 发送完毕后等待接收端回执（[MessageType.fileDone]）的上限。
  ///
  /// 「已发送」不等于「对方存好了」：只有当接收端核对大小与校验值、
  /// 并把临时文件改名为正式文件之后，才会发回执。
  /// 超过这个时间仍无回执，按失败处理并给出明确原因。
  static const Duration transferAckTimeout = Duration(seconds: 60);

  /// 是否在文件传输时计算并校验 CRC32。
  ///
  /// 代价：发送端每读一块要额外扫一遍（实测约 300MB/s，只占单核的一小部分），
  /// 接收端的计算放在后台落盘 isolate 里，不占界面线程。
  /// 收益：能发现「写盘被截断 / 磁盘静默损坏」这类只靠字节数发现不了的问题。
  /// 极端追求吞吐时可以关掉，此时仍然会核对字节数。
  static const bool transferChecksumEnabled = true;

  /// 接收中临时文件的后缀。
  ///
  /// 收完并核对无误后才改名为正式文件名，避免半成品看起来像完整文件
  /// （用户双击打开一个只传了一半的视频/压缩包会直接报错）。
  static const String incomingTempSuffix = '.mova-part';

  /// 接收端允许积压的待落盘字节数上限。
  ///
  /// 达到上限就暂停读取 socket，让 TCP 自己的窗口去做背压，
  /// 由对端放慢发送。这样即便磁盘比网络慢，内存占用也是有界的。
  static const int maxPendingWriteBytes = 32 * 1024 * 1024;

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

  /// 能在应用内直接预览的图片扩展名。
  ///
  /// 只列 Flutter 内置解码器确实支持的类型：
  /// svg 是矢量格式、heic / heif 需要平台专有解码器，Flutter 都渲染不了，
  /// 这些走「用系统默认程序打开」而不是点开一个空白页。
  static const List<String> previewableImageExtensions = [
    'jpg',
    'jpeg',
    'png',
    'gif',
    'bmp',
    'webp',
    'tif',
    'tiff',
    'ico',
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

  /// 速度滑动平均系数（0~1）：越大越贴近瞬时值，越小越平滑。
  ///
  /// 只影响「预计剩余时间」的计算，不影响界面上显示的瞬时速度。
  static const double speedEmaAlpha = 0.3;

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

  /// 快照编码搬到后台 isolate 的规模阈值（记录 + 消息 + 文件的条目数）。
  ///
  /// JSON 编码是在主 isolate 上做的：快照一大（几千条消息），一次编码
  /// 就要几十毫秒甚至更久，这段时间**事件循环是被占住的**——
  /// 界面动不了，退出流程的超时计时器也走不动，「重试 / 放弃」对话框
  /// 根本弹不出来，5 秒超时形同虚设。
  ///
  /// 阈值以下就地编码：起一个 isolate 本身也要几毫秒，而节流写盘
  /// 每几百毫秒就来一次，不能每次都付这个代价。
  static const int historyBackgroundEncodeEntries = 2000;

  /// 保留的连接记录条数上限。
  ///
  /// 历史是整份 JSON 覆盖写的，条数不设上限的话，文件会越写越大、
  /// 每次写盘也越来越慢。超过上限时淘汰最旧的记录（进行中的会话不淘汰）。
  /// 若日后确实需要长期保存全部记录，应改用追加式日志或本地数据库。
  static const int maxHistorySessions = 200;

  // ---------- 偏好设置 ----------

  /// 自定义设备名的长度上限。
  ///
  /// 这个名字会随每次 UDP 心跳广播出去（一个包里几十个字节），
  /// 太长既没必要也会让广播包变大。
  static const int maxDeviceNameLength = 32;

  /// 连接记录的默认保留天数。
  static const int defaultHistoryRetentionDays = 30;

  /// 界面上可选的保留期限（天数）。
  ///
  /// `0` 表示**永久保留**——此时不做时间维度的清理，
  /// 只保留「条数上限」这一条约束（见 [maxHistorySessions]）。
  static const List<int> historyRetentionOptions = <int>[1, 7, 30, 90, 365, 0];

  /// 发送文件前是否先弹窗确认（默认开）。
  ///
  /// 拖文件进窗口太容易手滑了：确认这一步是唯一的刹车。
  static const bool defaultConfirmBeforeSend = true;

  /// 单个日志文件的大小上限，超过后轮转为 `mova.log.1`，避免日志无限增长。
  static const int maxLogFileBytes = 2 * 1024 * 1024;
}
