/// 应用级常量（端口、超时等）。
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
}
