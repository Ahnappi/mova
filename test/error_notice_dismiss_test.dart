// 错误提示条必须真的能被关掉。
//
// 根因不在按钮上：主界面为了避免被「每 100ms 一次的传输进度」带着重建，
// 用 `context.read` 拿 TransferViewModel。于是点关闭时 ViewModel 里的
// errorMessage 确实清空了、notifyListeners 也调了，**界面却没有重建**——
// 横幅留在原地，看起来就是关闭按钮失灵。
//
// 因此这条用例只盯着可见结果：点了关闭，提示条必须消失。断言用 byType
// 而不是断言某个字段为 null，正是为了覆盖到「状态变了但没重画」这一类。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:mova/data/services/storage/log_service.dart';
import 'package:mova/data/services/storage/storage_service.dart';
import 'package:mova/main.dart';
import 'package:mova/ui/chat/widgets/error_notice_bar.dart';
import 'package:mova/ui/transfer/view_models/transfer_view_model.dart';

import 'support/fake_window_controller.dart';

void main() {
  testWidgets('传输错误条点关闭后真的消失', (tester) async {
    final storage = StorageService();
    await tester.pumpWidget(
      MainApp(
        storageService: storage,
        logService: LogService(storage),
        window: FakeWindowController(),
      ),
    );
    await tester.pump();

    final context = tester.element(find.byType(MaterialApp));
    final transfer = context.read<TransferViewModel>();

    // 重发一个并不存在的任务：仓储会明确报错，错误条应当随之出现。
    // 这条路纯内存、不碰磁盘与网络，用例不依赖外部环境。
    await transfer.retry(404404);
    await tester.pump();

    final bar = find.byType(ErrorNoticeBar);
    expect(bar, findsOneWidget,
        reason: '出了错却没把原因显示给用户，这条用例的前提不成立');

    await tester.tap(find.descendant(of: bar, matching: find.byTooltip('关闭')));
    await tester.pump();

    expect(bar, findsNothing,
        reason: '点了关闭提示条还在——状态清了而界面没重建，是最容易复发的那种');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
