import 'dart:io';
import 'dart:math';

import '../../../config/app_config.dart';
import '../../../domain/models/chat/local_info.dart';

/// 本机网络信息数据源（Service 层）。
///
/// 负责获取主机名、局域网 IPv4 地址，并生成本机标识。
class NetworkInfoService {
  /// 生成本机信息。
  ///
  /// [tcpPort] 为本机 TCP 监听端口（用于展示「别人怎么连我」）。
  Future<LocalInfo> getLocalInfo({required int tcpPort}) async {
    final ip = await findLanIp();
    return LocalInfo(
      id: _generateId(),
      name: defaultDeviceName(),
      ip: ip ?? '未知',
      tcpPort: tcpPort,
      platform: Platform.operatingSystem,
    );
  }

  /// 查找局域网 IPv4 地址（优先的那一个）。
  ///
  /// 只是 [findLanIps] 的首选项：真正的排序规则（跳过 VPN / 虚拟机网卡、
  /// 优先私有网段）都在那边。
  Future<String?> findLanIp() async {
    final candidates = await findLanIps();
    if (candidates.isNotEmpty) return candidates.first;

    // 都没评上分（比如只有公网地址）：退化为第一个非回环 IPv4。
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        return address.address;
      }
    }
    return null;
  }

  /// 所有可用的局域网 IPv4 地址，按「更像真局域网」排序。
  ///
  /// 为什么不能只取第一个：
  /// - 一台机器常常同时有 Wi-Fi、有线、虚拟机网卡、Docker 网桥，
  ///   枚举顺序在各系统上并不稳定；
  /// - 连上 VPN 后，隧道网卡的地址往往排在前面，把广播发到公司内网
  ///   就永远搜不到隔壁那台电脑。
  ///
  /// 因此这里先按网卡名排除明显的隧道/虚拟网卡，再按「是否私有网段 +
  /// 是否常见物理网卡」打分排序。广播目标也不止一个：多网卡时每个网段
  /// 都要发一份（见 DiscoveryService）。
  Future<List<String>> findLanIps() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );

    final scored = <({String address, int score})>[];
    for (final interface in interfaces) {
      if (_isVirtualOrTunnel(interface.name)) continue;

      for (final address in interface.addresses) {
        final ip = address.address;
        if (address.isLoopback) continue;
        // 169.254.x.x 是「没拿到 DHCP 地址」时的自动配置地址，不是局域网。
        if (ip.startsWith('169.254.')) continue;
        // 100.64/10 是运营商级 NAT 段，常被 Tailscale 一类工具占用。
        if (_isCgnat(ip)) continue;

        scored.add((address: ip, score: _score(ip, interface.name)));
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.map((item) => item.address).toList(growable: false);
  }

  /// 网卡名是否属于隧道 / 虚拟网卡（VPN、虚拟机、容器网桥、热点直连等）。
  bool _isVirtualOrTunnel(String name) {
    final lower = name.toLowerCase();
    for (final prefix in AppConfig.nonLanInterfacePrefixes) {
      if (lower.startsWith(prefix)) return true;
    }
    return false;
  }

  /// 打分：私有网段 2 分，其它 1 分；常见的物理网卡名再加 1 分。
  int _score(String ip, String interfaceName) {
    var score = _isPrivateLan(ip) ? 2 : 1;
    final lower = interfaceName.toLowerCase();
    if (lower.startsWith('en') ||
        lower.startsWith('eth') ||
        lower.startsWith('wl') ||
        lower.contains('wi-fi') ||
        lower.contains('ethernet')) {
      score += 1;
    }
    return score;
  }

  bool _isCgnat(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    return a == 100 && b >= 64 && b <= 127;
  }

  /// 默认设备名：主机名去掉 `.local` 后缀。
  ///
  /// 用户在设置里改过名之后就用自定义名；这里提供「没改过」时的兜底值，
  /// 设置界面也靠它显示输入框的提示文字。
  String defaultDeviceName() {
    final host = Platform.localHostname;
    final name = host.replaceAll(RegExp(r'\.local$'), '');
    return name.isEmpty ? 'Mova 设备' : name;
  }

  bool _isPrivateLan(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;

    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;

    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    return false;
  }

  String _generateId() {
    final random = Random();
    return '${DateTime.now().millisecondsSinceEpoch}-${random.nextInt(1 << 30)}';
  }
}
