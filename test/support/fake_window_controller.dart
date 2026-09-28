import 'package:window_manager/window_manager.dart' show WindowListener;

import 'package:mova/config/window_controller.dart';

/// 窗口操作的测试替身：不碰原生插件，还能手动触发「用户点了关闭」。
///
/// 普通 Widget 测试没有原生插件实现，直接 `windowManager.setPreventClose()`
/// 会抛 MissingPluginException——而那个调用在 `unawaited(start())` 里，
/// 测试连失败都看不到。换成替身之后，退出流程这条入口才真正可验证。
class FakeWindowController implements WindowController {
  bool preventClose = false;
  int destroyCalls = 0;
  WindowListener? listener;

  /// 模拟用户点击关闭按钮（走的是真实的 [WindowListener.onWindowClose]）。
  void tapClose() => listener?.onWindowClose();

  @override
  Future<void> setPreventClose(bool value) async {
    preventClose = value;
  }

  @override
  Future<void> destroy() async {
    destroyCalls++;
  }

  @override
  void addListener(WindowListener listener) {
    this.listener = listener;
  }

  @override
  void removeListener(WindowListener listener) {
    if (identical(this.listener, listener)) this.listener = null;
  }
}
