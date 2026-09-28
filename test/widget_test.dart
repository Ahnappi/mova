// 应用冒烟测试：验证根组件可正常构建，并渲染出首页的连接状态。
//
// 窗口操作用替身：[AppShutdown] 一启动就会调 `setPreventClose`，
// 而普通 Widget 测试没有原生插件实现，那条路径会抛
// MissingPluginException——它又发生在未等待的 Future 里，测试根本看不到。
// 换成替身之后，这条「启动即接管关闭按钮」的入口才真正被验证到。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mova/data/services/storage/log_service.dart';
import 'package:mova/data/services/storage/storage_service.dart';
import 'package:mova/main.dart';

import 'support/fake_window_controller.dart';

void main() {
  testWidgets('app renders home screen', (WidgetTester tester) async {
    final storage = StorageService();
    final window = FakeWindowController();
    await tester.pumpWidget(
      MainApp(
        storageService: storage,
        logService: LogService(storage),
        window: window,
      ),
    );
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
    // 未连接时的主界面：状态徽章 + 设备发现区。
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('附近设备'), findsOneWidget);
  });

  testWidgets('启动即接管窗口关闭：拦截已打开且回调已注册',
      (WidgetTester tester) async {
    final storage = StorageService();
    final window = FakeWindowController();
    await tester.pumpWidget(
      MainApp(
        storageService: storage,
        logService: LogService(storage),
        window: window,
      ),
    );

    // AppShutdown 是在 Provider 里 `lazy: false` 建的，且 start() 未被等待，
    // 因此多泵几帧让它把拦截与监听挂上。
    for (var i = 0; i < 20 && !window.preventClose; i++) {
      await tester.pump();
    }

    expect(window.preventClose, isTrue,
        reason: '启动后没有拦截关闭按钮——保存流程会在关窗口时被跳过');
    expect(window.listener, isNotNull,
        reason: '没有注册关闭回调，用户点关闭时没人跑退出流程');
  });
}
