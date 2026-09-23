/// 局域网内发现的对端设备（Domain 层，纯 Dart 模型）。
class Peer {
  const Peer({
    required this.id,
    required this.name,
    required this.ip,
    required this.tcpPort,
    required this.platform,
  });

  /// 对端标识。
  final String id;

  /// 对端设备名。
  final String name;

  /// 对端 IP（取自 UDP 包的来源地址，比广播里自报的更可靠）。
  final String ip;

  /// 对端 TCP 端口。
  final int tcpPort;

  /// 对端系统。
  final String platform;
}
