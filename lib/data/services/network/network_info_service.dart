import 'dart:io';
import 'dart:math';

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
      name: _deviceName(),
      ip: ip ?? '未知',
      tcpPort: tcpPort,
      platform: Platform.operatingSystem,
    );
  }

  /// 查找局域网 IPv4 地址。
  ///
  /// 优先返回私有网段（10.x / 192.168.x / 172.16-31.x）地址，
  /// 取不到时退化为第一个非回环 IPv4，都没有则返回 null。
  Future<String?> findLanIp() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );

    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (_isPrivateLan(address.address)) {
          return address.address;
        }
      }
    }

    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        return address.address;
      }
    }
    return null;
  }

  /// 设备名：取主机名并去掉 `.local` 后缀。
  String _deviceName() {
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
