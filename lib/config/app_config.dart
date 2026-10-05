/// 应用级常量（端口、超时、传输参数等）。
///
/// 集中放置，便于后续调整为可配置项。
class AppConfig {
  const AppConfig._();

  // ---------- 版本与更新 ----------

  /// 对外展示的版本名（x.y.z）。
  static const String appVersion = '1.0.0';

  /// 版本号（整数，只增不减）。
  ///
  /// **判断新旧一律用它**，不要去解析 [appVersion]：按字典序比较的话
  /// '1.9.0' 会大于 '1.10.0'，正好得出相反的结论。
  static const int appBuildNumber = 100;

  /// 界面上那一行版本文案，如 `1.0.0（100）`。
  static String get versionLabel => '$appVersion（$appBuildNumber）';

  /// 版本清单地址：一个静态 JSON 文件，点「检查更新」时拉一次。
  ///
  /// 清单格式（只有 `versionCode` 是必填）：
  /// ```json
  /// {
  ///   "versionName": "1.1.0",
  ///   "versionCode": 101,
  ///   "notes": "修了什么、加了什么",
  ///   "url": "https://……/下载页",
  ///   "mandatory": false
  /// }
  /// ```
  /// `versionCode` 比 [appBuildNumber] 大才提示更新；`url` 是下载页
  /// （不是安装包直链：macOS 给 DMG、Windows 给安装包，让页面去分派）。
  ///
  /// 发新版时改仓库里这个文件即可，不用重新发布应用。
  static const String updateManifestUrl =
      'https://raw.githubusercontent.com/ahnappi/mova/main/version.json';

  /// 兜底下载页：清单里没给 `url`（或给的不是一个能打开的网页）时用它。
  ///
  /// 没有它的话，「发现新版本」配一个点了没反应的下载按钮，用户只能自己
  /// 去猜去哪儿下。给一个固定的发布页，至少永远有地方可去。
  static const String updateFallbackUrl =
      'https://github.com/ahnappi/mova/releases';

  /// 拉版本清单的超时。
  ///
  /// 检查更新是界面上的一次点击，卡十几秒比直接失败更难受；
  /// 失败也只是「没查到」，不影响用。
  static const Duration updateCheckTimeout = Duration(seconds: 8);

  /// TCP 消息端口：对端主动连接本机时使用。
  static const int tcpPort = 49153;

  /// 当前协议版本（建连时互报，用于兼容老版本对端）。
  ///
  /// v1：只有 offer / accept / chunk / end / cancel，发送端推完就算完成；
  /// v2：end 帧带上字节数与 CRC32，新增 fileDone 回执帧；
  /// v3：新增 ping 心跳帧，并在 hello 里带 `ka` 能力位。
  static const int protocolVersion = 3;

  /// 支持「收尾回执」的最低协议版本。
  ///
  /// 对端低于这个版本时不等待回执（它不会发），直接按完成处理，
  /// 免得明明传好了却白等一个超时。
  static const int receiptProtocolVersion = 2;

  /// 支持「心跳」的最低协议版本。
  ///
  /// 只有确认对端会发心跳之后，才能把「太久没收到任何字节」当成
  /// 连接已断的证据。低版本对端空闲时本来就是零字节，
  /// 拿它判死等于版本一不一致就把正常连接掐断（见 keepAliveTimeout）。
  static const int keepAliveProtocolVersion = 3;

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

  /// 单个数据块大小（8 MiB）。
  ///
  /// 采用「分块流式」读写，无论多大的文件都不会被整体读进内存，
  /// 因此 10GB 级文件与 10MB 文件的内存占用是一样的。
  ///
  /// 块越大，Dart 层的循环与系统调用次数越少：实测 1MiB 时每块都要
  /// 经历一次「读盘 → 组帧 → 写 socket → 写文件」的完整往返，
  /// 大文件的吞吐被这些固定开销拖住，4MiB 时开销降到约 1/4，8MiB 再降一半。
  ///
  /// **8MiB 是当前协议帧格式能容忍的上限，不要随手调大**：
  /// 对端判据是 `maxChunkPayloadLength = 4 + 2 * 本机 fileChunkSize`，
  /// 而这个上限各端按自己的块大小算。8MiB 的 payload 是 `4 + 8MiB`，
  /// 正好等于**旧版（4MiB）**那台机器的上限，再多一个字节它就会在收到
  /// 第一块时判协议违规并直接断开连接（见 [FrameReader]）。
  /// 想用更大的块，必须先在 hello 里协商块大小，让双方都同意才放大
  /// ——步子不能跨过「对端还不知道你变大了」这一步。
  static const int fileChunkSize = 8 * 1024 * 1024;

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

  /// 同时传输的文件数上限。
  ///
  /// 注意这**不会提升总吞吐**：只有一条 TCP 连接，带宽是固定的，
  /// N 路并发只是把带宽分给 N 个文件。真正的收益是另外两条：
  ///   - 小文件不用排在大文件后面干等（消除队头阻塞）；
  ///   - 「等对方点接收」那两分钟可以重叠，而不是逐个累加。
  ///
  /// 每路并发各自持有 [fileChunkSize] 的读缓冲，加上最多 [maxInFlightBytes]
  /// 的未 flush 积压，因此这个值直接决定内存峰值：3 路大约 120MiB。
  /// 再往上加收益递减，内存却是线性增长。
  static const int maxConcurrentTransfers = 3;

  /// 心跳间隔：连接空闲时每多久发一个存活探测帧。
  ///
  /// 只在「这一段时间确实没往外发过任何字节」时才发——正在传文件时，
  /// 数据本身就是最好的存活证明，不需要额外心跳。
  ///
  /// 存在的理由：TCP 建立之后如果两端都不说话，谁也不知道对方还在不在。
  /// 对端合盖、Wi-Fi 断了、进程被杀，这些情况既不发 FIN 也不发 RST，
  /// 本端会一直「以为还连着」，直到下一次真正写数据失败——那可能是
  /// 几分钟以后，界面上表现为「一直在接收但进度不动」。
  static const Duration keepAliveInterval = Duration(seconds: 5);

  /// 多久没收到对端任何字节就算连接已死。
  ///
  /// 必须显著大于 [keepAliveInterval]，否则一次网络抖动就会误判断链。
  /// 取 4 倍（20 秒），可以容忍连续丢三个心跳。
  ///
  /// **只对确认具备心跳能力的对端生效**（见 [keepAliveProtocolVersion]）：
  /// 老版本既不发 ping 也不回 ping，空闲二十秒是它的常态，
  /// 拿这条判据去套它，等于一端升级就把所有老连接掐断。
  static const Duration keepAliveTimeout = Duration(seconds: 20);

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

  /// 背压暂停期间，多久「松开一次」读 socket（见 [maxPendingWriteBytes]）。
  ///
  /// 这是为了修一个很隐蔽的问题：暂停读 socket 期间，Dart **按设计**
  /// 不会投递「连接已关闭」事件（dart sdk 的 socket_patch.dart 里明写了）。
  /// 而传大文件时几乎必然处于暂停态，于是对端断线我们根本收不到通知，
  /// 只能干等 [transferStallTimeout] 那 90 秒——界面上就是「一直在接收、
  /// 进度不动」。
  ///
  /// 所以暂停期间定期放开一次：让 socket 把积压数据和 EOF / 错误交上来，
  /// 收到数据后会被再次压住。取值远小于停滞超时，断链就能在几秒内被发现。
  static const Duration backpressureProbeDelay = Duration(seconds: 3);

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

  /// 发布前改掉的旧应用标识（macOS Bundle ID）。
  ///
  /// 应用标识直接决定数据目录名，改名之后老用户会拿到一个全新的空目录，
  /// 历史与设置看起来「丢了」——其实文件还躺在旧目录里，首次启动时
  /// 搬一次即可（迁移逻辑在 StorageService 里）。
  static const String legacyMacosBundleId = 'com.example.mova';

  /// 旧版 Windows 的 CompanyName / ProductName（合起来决定数据目录）。
  static const String legacyWindowsCompanyName = 'com.example';

  /// 旧版 Windows 的产品名（与 [legacyWindowsCompanyName] 拼成目录）。
  static const String legacyWindowsProductName = 'mova';

  /// 迁移完成标记文件名（写在新数据目录里，避免每次启动都去翻旧目录）。
  static const String storageMigrationMarker = '.migration-done';

  /// 迁移过程中临时文件的后缀（写完再改名为正式文件名）。
  ///
  /// 直接往正式路径复制的话，复制到一半失败（磁盘满、进程被杀）会在正式
  /// 路径上留下半个文件；下次重试看到「文件已存在」就跳过它，
  /// 于是这个残缺文件会被当成已迁移的数据，甚至据此打上完成标记。
  static const String storageMigrationTempSuffix = '.mova-migrate-tmp';

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
