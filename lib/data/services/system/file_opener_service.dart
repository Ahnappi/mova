import 'dart:io';

/// 用系统能力打开文件（Service 层）。
///
/// 应用内预览覆盖不到的格式（Office 文档、SVG、HEIC 等）统一走这里：
/// 交给系统默认程序打开，或在文件管理器里定位。
class FileOpenerService {
  /// 用系统默认程序打开。
  Future<bool> open(String path) async {
    if (Platform.isMacOS) return _run('open', [path]);
    if (Platform.isWindows) return _run('cmd', ['/c', 'start', '', path]);
    if (Platform.isLinux) return _run('xdg-open', [path]);
    return false;
  }

  /// 在文件管理器中选中并定位（macOS 访达 / Windows 资源管理器）。
  Future<bool> reveal(String path) async {
    if (Platform.isMacOS) return _run('open', ['-R', path]);
    if (Platform.isWindows) {
      // explorer 的 /select 参数要求路径用反斜杠，否则只打开默认位置。
      return _run('explorer', ['/select,', path.replaceAll('/', r'\')]);
    }
    if (Platform.isLinux) {
      final dir = File(path).parent.path;
      return _run('xdg-open', [dir]);
    }
    return false;
  }

  /// 在默认浏览器里打开一个网址（更新下载页用）。
  ///
  /// 没有引入 url_launcher：三个桌面平台各自的命令都能直接开 URL，
  /// 为了一次跳转多引一个插件不划算。
  Future<bool> openUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;

    if (Platform.isMacOS) return _run('open', [trimmed]);
    if (Platform.isWindows) return _run('cmd', ['/c', 'start', '', trimmed]);
    if (Platform.isLinux) return _run('xdg-open', [trimmed]);
    return false;
  }

  Future<bool> _run(String executable, List<String> args) async {
    try {
      final result = await Process.run(executable, args);
      return result.exitCode == 0;
    } catch (_) {
      // 打不开不影响主流程，界面上还有路径可手动复制。
      return false;
    }
  }
}
