import 'dart:io';

/// 系统设置入口（Service 层）：权限被系统拒绝时，直接把用户带到对应设置页。
///
/// 桌面端最常卡住的两类权限：
/// - **文件夹访问**：macOS 对桌面 / 文档 / 下载目录有 TCC 保护，
///   用户一旦拒绝过就不会再弹窗，只能自己去设置里打开；
/// - **本地网络 / 防火墙**：局域网发现与直连会被它们静默拦掉。
class SystemSettingsService {
  /// 打开「文件与文件夹」权限设置页。
  Future<bool> openFileAccessSettings() async {
    if (Platform.isMacOS) {
      return _run('open', [
        'x-apple.systempreferences:com.apple.preference.security?Privacy',
      ]);
    }
    if (Platform.isWindows) {
      return _run('cmd', ['/c', 'start', '', 'ms-settings:privacy']);
    }
    return false;
  }

  /// 打开「本地网络」权限设置页（macOS 15 起局域网访问需要单独授权）。
  Future<bool> openLocalNetworkSettings() async {
    if (Platform.isMacOS) {
      return _run('open', [
        'x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork',
      ]);
    }
    if (Platform.isWindows) {
      return _run('cmd', ['/c', 'start', '', 'ms-settings:network']);
    }
    return false;
  }

  /// 打开防火墙设置（Windows 上入站连接常被它拦住）。
  Future<bool> openFirewallSettings() async {
    if (Platform.isWindows) {
      return _run('cmd', [
        '/c',
        'start',
        '',
        'control',
        '/name',
        'Microsoft.WindowsFirewall',
      ]);
    }
    if (Platform.isMacOS) {
      return _run('open', [
        'x-apple.systempreferences:com.apple.preference.security?Firewall',
      ]);
    }
    return false;
  }

  Future<bool> _run(String executable, List<String> args) async {
    try {
      final result = await Process.run(executable, args);
      return result.exitCode == 0;
    } catch (_) {
      // 打不开也不影响主流程，界面上还有文字说明告诉用户怎么走。
      return false;
    }
  }
}
