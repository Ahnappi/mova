import 'package:flutter_test/flutter_test.dart';
import 'package:mova/config/window_controller.dart';

void main() {
  test('Windows 收尾后的释放使用进程退出，不依赖原生窗口销毁调用', () async {
    final codes = <int>[];
    final window = WindowManagerController(
      windows: true,
      terminateProcess: codes.add,
    );
    // 无插件通道的测试环境中仍应成功，不应调用 windowManager.destroy。
    await window.destroy();
    expect(codes, [0]);
  });
}
