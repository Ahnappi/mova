import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../config/app_config.dart';
import '../../../domain/models/chat/peer.dart';
import '../../../utils/result.dart';
import '../network/network_info_service.dart';

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
/// - **广播目标按当前网卡动态计算**。只按「第一个私有 IP + /24」推算是靠不住的：
///   多网卡、VPN、虚拟机网桥、网络切换都会让它算错网段，表现为「搜不到设备」。
///   这里每隔 [AppConfig.broadcastTargetsRefresh] 重新枚举一次网卡，
///   每个候选网段都发一份（同时补发 /16），并用
///   [AppConfig.maxBroadcastTargets] 截断，避免一次心跳发出十几个包。
/// - 受限广播 255.255.255.255 仅作补充；一旦发送失败就停用并重建发送 socket。
class DiscoveryService {
  DiscoveryService({NetworkInfoService? networkInfoService})
      : _networkInfo = networkInfoService ?? NetworkInfoService();

  final NetworkInfoService _networkInfo;

  RawDatagramSocket? _receiveSocket;
  RawDatagramSocket? _sendSocket;
  Timer? _timer;
  Map<String, dynamic>? _self;

  /// 最近一次算出的子网广播地址。
  List<String> _subnetTargets = const <String>[];

  /// [_subnetTargets] 的计算时间（用于定期刷新）。
  DateTime? _targetsAt;

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

      // 先算好广播目标再发第一次心跳，否则首包会落到空目标上。
      await _refreshTargets();
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
    // 下次开启时重新枚举网卡（网络可能已经变了）。
    _targetsAt = null;
    _subnetTargets = const <String>[];
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

    // 子网广播是主力：每个候选网段都发一份。
    for (final target in _subnetTargets) {
      _send(data, target);
    }
    // 受限广播作为补充（部分系统会限制，失败后自动停用）。
    if (_limitedBroadcastEnabled) {
      _send(data, limitedBroadcastAddress);
    }

    // 广播目标要跟着网络变化走：切 Wi-Fi、插拔网线、连上 VPN 之后，
    // 旧的网段就不再有效了。
    unawaited(_refreshTargets());

    if (_recreateSendSocket) {
      _recreateSendSocket = false;
      unawaited(_rebuildSendSocket());
    }
  }

  /// 重新枚举网卡并计算广播目标（有刷新间隔，不会每次心跳都枚举）。
  Future<void> _refreshTargets() async {
    final last = _targetsAt;
    if (last != null &&
        DateTime.now().difference(last) < AppConfig.broadcastTargetsRefresh) {
      return;
    }

    try {
      final ips = await _networkInfo.findLanIps();
      final targets = <String>{};
      for (final ip in ips) {
        // /24 是最常见的小局域网；/16 用于公司/校园这类大网段。
        final narrow = subnetBroadcast(ip, 24);
        if (narrow != null) targets.add(narrow);
        final wide = subnetBroadcast(ip, 16);
        if (wide != null) targets.add(wide);
      }
      _subnetTargets =
          targets.take(AppConfig.maxBroadcastTargets).toList(growable: false);
      _targetsAt = DateTime.now();
    } catch (_) {
      // 枚举失败就沿用上一次的目标，下次心跳再试。
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

  /// 受限广播地址。
  static const String limitedBroadcastAddress = '255.255.255.255';

  /// 由本机 IP 推导子网广播地址（[prefixLen] 为 24 或 16）。
  ///
  /// 掩码位数拿不到（Dart 的 [InternetAddress] 不暴露），所以两种常见掩码都算，
  /// 宁可多发一个包，也不要漏掉整个网段。
  static String? subnetBroadcast(String? ip, int prefixLen) {
    if (ip == null) return null;
    final parts = ip.split('.');
    if (parts.length != 4) return null;

    final octets = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null) return null;
      octets.add(value);
    }

    final mask = prefixLen == 24
        ? const <int>[255, 255, 255, 0]
        : const <int>[255, 255, 0, 0];

    return List<int>.generate(
      4,
      (i) => octets[i] | (mask[i] ^ 255),
    ).join('.');
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
