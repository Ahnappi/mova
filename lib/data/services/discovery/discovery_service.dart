import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../config/app_config.dart';
import '../../../domain/models/chat/peer.dart';
import '../../../utils/result.dart';

/// 局域网发现数据源（Service 层）：UDP 广播心跳。
///
/// - 定时向广播地址发送本机信息 JSON；
/// - 监听同端口的 UDP 包，解析出邻居并对外抛出。
/// 无中心服务器，仅在局域网内工作。
///
/// 实现要点（踩坑记录）：
/// - **收发必须用两个 socket**。在 macOS 上，一次失败的 UDP 发送会让该 socket
///   进入错误状态，之后连正常包都收不到（表现为发现功能整体失效）。
///   分离后，发送失败只影响发送 socket，不影响接收。
/// - UDP 的发送失败是**异步错误事件**，必须在 listen 上提供 onError，
///   否则会变成未处理异常导致进程崩溃。
/// - 优先发「子网广播」（如 192.168.1.255），受限广播 255.255.255.255 仅作补充；
///   一旦发送失败就停用受限广播并重建发送 socket。
class DiscoveryService {
  RawDatagramSocket? _receiveSocket;
  RawDatagramSocket? _sendSocket;
  Timer? _timer;
  Map<String, dynamic>? _self;

  /// 受限广播（255.255.255.255）是否仍可尝试。
  bool _limitedBroadcastEnabled = true;

  /// 发送 socket 是否需要重建（发送失败后置位）。
  bool _recreateSendSocket = false;

  final StreamController<Peer> _peerController =
      StreamController<Peer>.broadcast();

  /// 发现到的对端流。
  Stream<Peer> get onPeer => _peerController.stream;

  /// 开启发现：[self] 为广播出去的本机信息。
  Future<Result<void>> start({required Map<String, dynamic> self}) async {
    try {
      await stop();
      _self = self;

      // ---- 接收 socket：固定绑定发现端口 ----
      final receive = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        AppConfig.discoveryPort,
      );
      receive.broadcastEnabled = true;
      _receiveSocket = receive;
      receive.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          final datagram = receive.receive();
          if (datagram == null) return;
          _handlePacket(datagram);
        },
        onError: (Object _) {
          // 接收侧错误忽略，避免因偶发网络错误中断发现。
        },
        cancelOnError: false,
      );

      // ---- 发送 socket：独立端口 ----
      _sendSocket = await _createSendSocket();

      _announce();
      _timer = Timer.periodic(AppConfig.announceInterval, (_) => _announce());

      return Result.ok(null);
    } catch (e) {
      return Result.error(Exception('开启局域网发现失败：$e'));
    }
  }

  /// 停止发现。
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _receiveSocket?.close();
    _receiveSocket = null;
    _sendSocket?.close();
    _sendSocket = null;
  }

  /// 释放资源。
  Future<void> dispose() async {
    await stop();
    await _peerController.close();
  }

  Future<RawDatagramSocket?> _createSendSocket() async {
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.listen(
        (_) {},
        onError: (Object _) {
          // 发送失败（常见于无网络 / 广播受限）：停用受限广播，下次重建 socket。
          _limitedBroadcastEnabled = false;
          _recreateSendSocket = true;
        },
        cancelOnError: false,
      );
      return socket;
    } catch (_) {
      return null;
    }
  }

  void _announce() {
    final self = _self;
    if (self == null) return;

    final data = utf8.encode(jsonEncode(self));

    // 优先子网广播（真实局域网中最可靠）。
    final subnet = _subnetBroadcast(self['ip'] as String?);
    if (subnet != null) {
      _send(data, subnet);
    }
    // 受限广播作为补充（部分系统会限制，失败后自动停用）。
    if (_limitedBroadcastEnabled) {
      _send(data, '255.255.255.255');
    }

    if (_recreateSendSocket) {
      _recreateSendSocket = false;
      unawaited(_rebuildSendSocket());
    }
  }

  Future<void> _rebuildSendSocket() async {
    _sendSocket?.close();
    _sendSocket = await _createSendSocket();
  }

  void _send(List<int> data, String address) {
    final socket = _sendSocket;
    if (socket == null) return;
    try {
      socket.send(data, InternetAddress(address), AppConfig.discoveryPort);
    } catch (_) {
      // 同步发送失败：同样按降级处理。
      if (address == '255.255.255.255') {
        _limitedBroadcastEnabled = false;
      }
      _recreateSendSocket = true;
    }
  }

  /// 由本机 IP 推导子网广播地址（按最常见的 /24 掩码）。
  String? _subnetBroadcast(String? ip) {
    if (ip == null) return null;
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}.255';
  }

  void _handlePacket(Datagram datagram) {
    final self = _self;
    try {
      final json = jsonDecode(
        utf8.decode(datagram.data, allowMalformed: true),
      ) as Map<String, dynamic>;

      // 只处理本应用的广播。
      if (json['app'] != 'mova') return;
      // 忽略自己发出的包。
      if (self != null && json['id'] == self['id']) return;

      _peerController.add(
        Peer(
          id: json['id'] as String? ?? '',
          name: json['name'] as String? ?? '未知设备',
          ip: datagram.address.address,
          tcpPort: (json['tcpPort'] as num?)?.toInt() ?? AppConfig.tcpPort,
          platform: json['platform'] as String? ?? '',
        ),
      );
    } catch (_) {
      // 忽略非法包。
    }
  }
}
