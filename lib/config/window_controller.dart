import 'package:window_manager/window_manager.dart';

/// 窗口操作的收窄封装：只暴露退出流程用得到的那几个动作。
///
/// 抽成接口有两个直接原因：
/// - **可测**：普通 Widget 测试没有原生插件实现，直接调
///   `windowManager.setPreventClose()` 会抛 `MissingPluginException`，
///   而这个调用又发生在 `unawaited(start())` 里，测试既看不到、
///   也证明不了「关窗口真的走了退出流程」这条入口；
/// - **可换**：日后换成别的窗口方案（或去掉窗口插件）时，
///   退出流程一行都不用改。
abstract class WindowController {
  const WindowController();

  /// 拦住（或放开）关闭按钮：拦截期间关窗口不会真的关，
  /// 而是先在 [WindowListener.onWindowClose] 里跑完退出流程。
  Future<void> setPreventClose(bool value);

  /// 真正关掉窗口（退出流程跑完之后才调）。
  Future<void> destroy();

  /// 注册窗口事件监听（退出流程靠它接住关闭按钮）。
  void addListener(WindowListener listener);

  void removeListener(WindowListener listener);
}

/// 真实实现：转调 window_manager 插件。
class WindowManagerController extends WindowController {
  const WindowManagerController();

  @override
  Future<void> setPreventClose(bool value) =>
      windowManager.setPreventClose(value);

  @override
  Future<void> destroy() => windowManager.destroy();

  @override
  void addListener(WindowListener listener) =>
      windowManager.addListener(listener);

  @override
  void removeListener(WindowListener listener) =>
      windowManager.removeListener(listener);
}
