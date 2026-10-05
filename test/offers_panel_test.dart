// 待接收面板的勾选规则（不依赖 Flutter binding，纯 ViewModel 层）。
//
// 单独拿出来是因为它有两个容易坏的点：
// - 新到的请求要默认勾上（最常见的操作就是「全收」）；
// - 勾选变化必须能被界面感知（[TransferViewModel.offerSelectionSignature]），
//   否则复选框点不动——主界面为了性能只用 Selector 订阅少量字段，
//   订阅的值不变就根本不会重建。

import 'package:flutter_test/flutter_test.dart';

import 'package:mova/data/services/system/system_settings_service.dart';
import 'package:mova/domain/models/transfer/transfer_task.dart';
import 'package:mova/ui/transfer/view_models/transfer_view_model.dart';

import 'support/fake_transfer_repository.dart';

void main() {
  late FakeTransferRepository repo;
  late TransferViewModel vm;

  TransferTask offer(
    int id,
    String name, {
    int size = 1024,
    String sessionId = '',
  }) =>
      TransferTask(
        id: id,
        fileName: name,
        totalBytes: size,
        direction: TransferDirection.receiving,
        status: TransferStatus.waiting,
        sessionId: sessionId,
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
    // 等构造里那次异步的「读取保存目录」落地。
    await Future<void>.delayed(Duration.zero);
  });

  test('新到的请求默认全选，勾选变化能被界面感知', () async {
    repo.emit([offer(1, 'a.bin'), offer(2, 'b.bin'), offer(3, 'c.bin')]);
    await Future<void>.delayed(Duration.zero);

    expect(vm.pendingOfferCount, 3);
    expect(vm.selectedOfferCount, 3, reason: '新到的请求应默认勾上');
    expect(vm.allOffersSelected, isTrue);

    final before = vm.offerSelectionSignature;
    vm.toggleOfferSelection(2);
    expect(vm.isOfferSelected(2), isFalse);
    expect(vm.selectedOfferCount, 2);
    expect(vm.allOffersSelected, isFalse);
    // 界面靠这个指纹决定是否重建：不变的话复选框就点不动。
    expect(vm.offerSelectionSignature, isNot(before),
        reason: '勾选变了而指纹没变，界面不会重建');
  });

  test('全选开关：已经全选时再点一次是全部取消', () async {
    repo.emit([offer(1, 'a.bin'), offer(2, 'b.bin')]);
    await Future<void>.delayed(Duration.zero);

    vm.toggleSelectAllOffers();
    expect(vm.selectedOfferCount, 0);

    vm.toggleSelectAllOffers();
    expect(vm.selectedOfferCount, 2, reason: '再点一次应重新全选');
  });

  test('只接收勾选的那几个，没勾选的被明确拒绝', () async {
    repo.emit([offer(1, 'a.bin'), offer(2, 'b.bin'), offer(3, 'c.bin')]);
    await Future<void>.delayed(Duration.zero);

    vm.toggleOfferSelection(2);
    await vm.acceptSelected(saveDirectory: '/tmp/save');

    expect(repo.acceptedMany, [1, 3], reason: '应只接收勾选的两个');
    expect(repo.rejectedMany, [2],
        reason: '没勾选的必须明确拒绝：放着不管对方要干等 120 秒');
    expect(repo.lastAcceptDirectory, '/tmp/save');
    expect(vm.selectedOfferCount, 0, reason: '处理完之后勾选应清空');
    expect(vm.lastMessage, contains('已接收 2 个'));
  });

  test('全部拒绝时不会误收任何一个', () async {
    repo.emit([offer(1, 'a.bin'), offer(2, 'b.bin')]);
    await Future<void>.delayed(Duration.zero);

    await vm.rejectPending();

    expect(repo.rejectedMany, [1, 2]);
    expect(repo.acceptedMany, isEmpty);
    expect(vm.lastMessage, contains('已拒绝 2 个'));
  });

  test('用户取消勾选后，后续的任务推送不会把它勾回来', () async {
    repo.emit([offer(1, 'a.bin'), offer(2, 'b.bin')]);
    await Future<void>.delayed(Duration.zero);

    vm.toggleOfferSelection(2);
    expect(vm.isOfferSelected(2), isFalse);

    // 其它文件开始传输、以及新请求到达，都会推送一整份新的任务列表；
    // 每次推送都会走一遍「勾选对齐」。这正是被悄悄勾回来的时机。
    repo.emit([
      offer(1, 'a.bin').copyWith(
        status: TransferStatus.transferring,
        transferredBytes: 512,
      ),
      offer(2, 'b.bin'),
      offer(3, 'c.bin'),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(
      vm.isOfferSelected(2),
      isFalse,
      reason: '用户取消的勾选不能被自动加回：否则会收到他明确不想收的文件',
    );
    expect(vm.isOfferSelected(3), isTrue, reason: '新到的请求仍应默认勾上');
    expect(vm.isOfferSelected(1), isFalse, reason: '已在传输中的不算待接收');
    expect(vm.pendingOfferCount, 2);
  });

  test('「存到…」期间新发来的文件不会被一起收下', () async {
    repo.emit([offer(1, 'a.bin'), offer(2, 'b.bin')]);
    await Future<void>.delayed(Duration.zero);
    expect(vm.selectedOfferCount, 2);

    repo.directoryToPick = '/tmp/picked';
    // 用户翻文件夹的这段时间里，对方又发来了一个文件。
    // 新请求默认勾上——若不先冻结决定，它会被顺手一起收下。
    repo.onPickingDirectory = () async {
      repo.emit([offer(1, 'a.bin'), offer(2, 'b.bin'), offer(3, '新来的.bin')]);
    };

    await vm.acceptSelectedWithDirectoryPicker();

    expect(repo.acceptedMany, [1, 2],
        reason: '用户确认的只有前两个，第三个他根本没见过');
    expect(repo.rejectedMany, isEmpty);
    expect(vm.lastMessage, contains('已接收 2 个'));
    // 新来的那个仍然是勾选着的，用户可以再决定一次。
    expect(vm.isOfferSelected(3), isTrue);
  });

  test('「存到…」期间换了设备，不会拿旧请求去骚扰新对端', () async {
    repo.emit([offer(1, 'a.bin'), offer(2, 'b.bin')]);
    await Future<void>.delayed(Duration.zero);

    repo.directoryToPick = '/tmp/picked';
    repo.onPickingDirectory = () async {
      // 断线并连上另一台设备：新会话、新请求。
      // 旧会话那两个请求还没来得及被清掉——这正是「会话换了但列表还是旧的」
      // 那一瞬间，也是这条用例要挡住的情况。
      repo.sessionId = 'session-B';
      repo.emit([
        offer(1, 'a.bin'),
        offer(2, 'b.bin'),
        offer(9, '来自新设备.bin', sessionId: 'session-B'),
      ]);
    };

    await vm.acceptSelectedWithDirectoryPicker();

    expect(repo.acceptedMany, isEmpty,
        reason: '旧请求随上一通会话作废了，不能再收');
    expect(repo.rejectedMany, isEmpty,
        reason: '更不能拿旧 fileId 给新对端发拒绝帧——它没见过这些 id');
    expect(vm.errorMessage, contains('切换'));
  });

  test('只有一部分真的接下时，按实际数量反馈', () async {
    repo.emit([offer(1, 'a.bin'), offer(2, 'b.bin'), offer(3, 'c.bin')]);
    await Future<void>.delayed(Duration.zero);

    // 三个都勾上了，但对面只处理成两个（比如中途断连）。
    repo.acceptManyResult = 2;
    await vm.acceptSelected(saveDirectory: '/tmp/save');

    expect(vm.lastMessage, contains('已接收 2 个'),
        reason: '报请求数会让人以为三个都收到了');
    expect(vm.lastMessage, isNot(contains('3')));
  });

  test('已被处理的请求会从勾选里剔除', () async {
    repo.emit([offer(1, 'a.bin'), offer(2, 'b.bin')]);
    await Future<void>.delayed(Duration.zero);
    expect(vm.selectedOfferCount, 2);

    // 第一个被接收（状态不再是 waiting），第二个仍是待接收。
    repo.emit([
      offer(1, 'a.bin').copyWith(status: TransferStatus.transferring),
      offer(2, 'b.bin'),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(vm.pendingOfferCount, 1);
    expect(vm.selectedOfferCount, 1, reason: '已经不是待接收的应自动取消勾选');
    expect(vm.isOfferSelected(1), isFalse);
  });
}
