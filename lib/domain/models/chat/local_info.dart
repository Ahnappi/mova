/// 本机信息（Domain 层，纯 Dart 模型）。
///
/// 用于在界面上展示「我是谁、别人该怎么连我」。
class LocalInfo {
  const LocalInfo({
    required this.id,
    required this.name,
    required this.ip,
    required this.tcpPort,
    required this.platform,
  });

  /// 本机在本轮运行中的唯一标识（用于忽略自己发出的广播）。
  final String id;

  /// 设备名（默认取主机名）。
  final String name;

  /// 局域网 IPv4 地址，取不到时为 '未知'。
  final String ip;

  /// 本机 TCP 监听端口。
  final int tcpPort;

  /// 操作系统（macos / windows / ...）。
  final String platform;

  /// 展示用的「地址:端口」，如 `192.168.1.5:49153`。
  String get endpoint => '$ip:$tcpPort';

  /// 换一个设备名（用户在设置里改名时用），其余字段保持不变。
  LocalInfo copyWith({String? name, String? ip, int? tcpPort}) => LocalInfo(
        id: id,
        name: name ?? this.name,
        ip: ip ?? this.ip,
        tcpPort: tcpPort ?? this.tcpPort,
        platform: platform,
      );
}
