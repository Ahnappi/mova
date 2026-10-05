// 待接收面板本身必须能画出来、点得动。
//
// 上面那条 ViewModel 用例只证明了「数据层选对了」，证明不了界面：
// 面板用 Selector 订阅一个指纹，订阅错了（比如只订阅 taskSignature）
// 就会出现「勾选状态变了但复选框不动」——数据是对的，界面是死的。
// 因此这里直接泵出面板，点一下看它到底动没动。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:mova/data/services/system/system_settings_service.dart';
import 'package:mova/domain/models/transfer/transfer_task.dart';
import 'package:mova/ui/transfer/view_models/transfer_view_model.dart';
import 'package:mova/ui/transfer/widgets/incoming_offers_dialog.dart';

import 'support/fake_transfer_repository.dart';

void main() {
  late FakeTransferRepository repo;
  late TransferViewModel vm;

  TransferTask offer(int id, String name) => TransferTask(
        id: id,
        fileName: name,
        totalBytes: 2048,
        direction: TransferDirection.receiving,
        status: TransferStatus.waiting,
        batchId: 7,
        batchIndex: id - 1,
        batchCount: 3,
      );

  setUp(() async {
    repo = FakeTransferRepository();
    vm = TransferViewModel(
      transferRepository: repo,
      historyRepository: NoopHistoryRepository(),
      systemSettingsService: SystemSettingsService(),
    );
    addTearDown(() => vm.dispose());
    addTearDown(() => repo.dispose());
    await Future<void>.delayed(Duration.zero);
  });

  Future<void> openPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<TransferViewModel>.value(
        value: vm,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showIncomingOffersDialog(context, peerName: 'MacBook'),
                child: const Text('打开面板'),
              ),
            ),
          ),
        ),
      ),
    );

    repo.emit([offer(1, 'a.bin'), offer(2, 'b.bin'), offer(3, 'c.bin')]);
    await tester.pump();
    await tester.tap(find.text('打开面板'));
    await tester.pumpAndSettle();
  }

  testWidgets('面板列出全部待接收文件，并写明并发上限', (tester) async {
    await openPanel(tester);

    expect(find.text('「MacBook」发来 3 个文件'), findsOneWidget);
    for (final name in ['a.bin', 'b.bin', 'c.bin']) {
      expect(find.text(name), findsOneWidget, reason: '$name 没出现在面板里');
    }
    // 并发上限要说在明处：否则用户看见「点了 10 个只动了 3 个」会以为卡住。
    expect(find.textContaining('最多同时传输 3 个'), findsOneWidget);

    // 3 行各一个复选框 + 底部「全选」那一个。
    expect(find.byType(Checkbox), findsNWidgets(4));
  });

  testWidgets('取消勾选一个，只接收剩下的两个', (tester) async {
    await openPanel(tester);

    // 点文件名那一整行即可切换勾选。
    await tester.tap(find.text('b.bin'));
    await tester.pumpAndSettle();

    expect(find.text('接收 2 个'), findsOneWidget,
        reason: '按钮上的数字应跟着勾选变化');

    await tester.tap(find.text('接收 2 个'));
    await tester.pumpAndSettle();

    expect(repo.acceptedMany, [1, 3], reason: '应只接收勾选的两个');
    expect(repo.rejectedMany, [2],
        reason: '没勾选的必须明确拒绝，不能放着不管');
    // 决定完了面板就该自己收起来。
    expect(find.text('「MacBook」发来 3 个文件'), findsNothing);
  });

  testWidgets('全部处理完之后面板自己关闭', (tester) async {
    await openPanel(tester);

    // 三个文件都在别处被处理掉了（比如用户在聊天流的卡片上逐个点的）。
    repo.emit([
      offer(1, 'a.bin').copyWith(status: TransferStatus.completed),
      offer(2, 'b.bin').copyWith(status: TransferStatus.completed),
      offer(3, 'c.bin').copyWith(status: TransferStatus.completed),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('「MacBook」发来 3 个文件'), findsNothing,
        reason: '没有待接收的文件了，面板不该还挂在屏幕上');
  });
}
