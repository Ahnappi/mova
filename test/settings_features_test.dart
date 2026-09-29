// 本轮新增功能的回归用例：
// 1. 用户设置（设备名 / 记录保留期限 / 发送前确认）能落盘并再次读到；
// 2. 连接记录按保留期限清理——过期删除、当前会话保留、永久不清理；
// 3. 失败的文件可以直接«重新发送»，而不是回到文件选择器再来一遍；
// 4. 发送前那句确认：取消就是不发。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:mova/data/repositories/history/history_repository_local.dart';
import 'package:mova/data/repositories/settings/settings_repository_local.dart';
import 'package:mova/data/repositories/transfer/transfer_repository_local.dart';
import 'package:mova/data/services/chat/chat_transport_service.dart';
import 'package:mova/data/services/history/history_storage_service.dart';
import 'package:mova/data/services/network/network_info_service.dart';
import 'package:mova/data/services/storage/settings_service.dart';
import 'package:mova/data/services/storage/storage_service.dart';
import 'package:mova/data/services/transfer/file_storage_service.dart';
import 'package:mova/domain/models/chat/connection_status.dart';
import 'package:mova/domain/models/history/session_record.dart';
import 'package:mova/domain/models/settings/app_settings.dart';
import 'package:mova/domain/models/transfer/picked_file.dart';
import 'package:mova/domain/models/transfer/transfer_task.dart';
import 'package:mova/ui/settings/view_models/settings_view_model.dart';
import 'package:mova/ui/transfer/widgets/send_confirm_dialog.dart';
import 'package:mova/ui/transfer/widgets/transfer_card.dart';
import 'package:mova/utils/result.dart';

/// 把应用数据目录指到一个临时目录，避免测试读写真实的 ~/Library。
class _FakeStorage extends StorageService {
  _FakeStorage(this._directory);

  final Directory _directory;

  @override
  Future<Directory> appSupportDirectory() async {
    if (!await _directory.exists()) {
      await _directory.create(recursive: true);
    }
    return _directory;
  }
}

/// 等某个任务落到指定状态（或超时返回最后一个已知快照）。
Future<TransferTask?> _waitForTask(
  TransferRepositoryLocal repo,
  String fileName,
  TransferStatus status, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final found = repo.currentTasks
        .cast<TransferTask?>()
        .firstWhere((task) => task?.fileName == fileName, orElse: () => null);
    if (found?.status == status) return found;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return null;
}

void main() {
  group('用户设置的持久化', () {
    late Directory temp;
    late _FakeStorage storage;
    late SettingsRepositoryLocal settings;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('mova_settings_test');
      storage = _FakeStorage(temp);
      settings = SettingsRepositoryLocal(SettingsService(storage));
    });

    tearDown(() async {
      try {
        await temp.delete(recursive: true);
      } catch (_) {
        // 清理失败不影响测试结果。
      }
    });

    test('没改过的设置是文档里承诺的默认值', () async {
      final loaded = await settings.load();

      expect(loaded.deviceName, '');
      expect(loaded.customDeviceName, isNull, reason: '空名字必须退回主机名');
      expect(loaded.historyRetentionDays, 30);
      expect(loaded.confirmBeforeSend, isTrue);
    });

    test('设备名与开关写进去之后，重开还读得回来', () async {
      await settings.save(
        const AppSettings(
          deviceName: '客厅的 Mac',
          historyRetentionDays: 7,
          confirmBeforeSend: false,
        ),
      );

      // 换一个实例读：证明写进了文件，而不只是内存缓存。
      final reopened = SettingsRepositoryLocal(SettingsService(storage));
      final loaded = await reopened.load();

      expect(loaded.deviceName, '客厅的 Mac');
      expect(loaded.historyRetentionDays, 7);
      expect(loaded.confirmBeforeSend, isFalse);
      expect(loaded.retentionDuration, const Duration(days: 7));
    });

    test('超出长度的设备名会被截断，而不是原样广播出去', () async {
      await settings.save(
        AppSettings(deviceName: 'x' * 80),
      );

      final loaded = await SettingsRepositoryLocal(
        SettingsService(storage),
      ).load();

      expect(loaded.deviceName.length, 32);
    });

    test('设置文件损坏时退回默认值，而不是让设置页打不开', () async {
      final file = File(p.join(temp.path, 'settings.json'));
      await file.writeAsString('{ 这不是 json');

      final loaded = await settings.load();

      expect(loaded.deviceName, '');
      expect(loaded.historyRetentionDays, 30);
      expect(loaded.confirmBeforeSend, isTrue);
    });
  });

  group('连接记录的保留期限', () {
    late Directory temp;
    late _FakeStorage storage;
    late SettingsRepositoryLocal settings;
    late HistoryStorageService historyStorage;

    final now = DateTime.now();

    /// 一条已经结束的会话记录。
    SessionRecord ended(String id, int daysAgo) => SessionRecord(
          id: id,
          peerName: '设备 $id',
          peerIp: '192.168.1.9',
          startedAt: now.subtract(Duration(days: daysAgo + 1)),
          endedAt: now.subtract(Duration(days: daysAgo)),
        );

    /// 一条「还在线」的记录（崩溃时会留下这种没有结束时间的）。
    SessionRecord live(String id, int daysAgo) => SessionRecord(
          id: id,
          peerName: '设备 $id',
          peerIp: '192.168.1.9',
          startedAt: now.subtract(Duration(days: daysAgo)),
        );

    HistoryRepositoryLocal repository() => HistoryRepositoryLocal(
          historyStorage,
          settingsRepository: settings,
        );

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('mova_retention_test');
      storage = _FakeStorage(temp);
      settings = SettingsRepositoryLocal(SettingsService(storage));
      historyStorage = HistoryStorageService(storage);
    });

    tearDown(() async {
      try {
        await temp.delete(recursive: true);
      } catch (_) {
        // 清理失败不影响测试结果。
      }
    });

    test('保留 7 天：过期记录载入时就被清掉，当前会话不受影响', () async {
      await historyStorage.writeAll(<SessionRecord>[
        ended('old', 40),
        ended('recent', 3),
      ]);
      await settings.save(const AppSettings(historyRetentionDays: 7));

      final repo = repository();
      addTearDown(repo.dispose);
      await repo.load();

      final ids = repo.currentSessions.map((item) => item.id).toList();
      expect(ids, contains('recent'));
      expect(ids, isNot(contains('old')), reason: '超过 7 天的记录没有被清理');
    });

    test('期限改为「永久」后不再按时间清理', () async {
      await historyStorage.writeAll(<SessionRecord>[ended('old', 400)]);
      await settings.save(const AppSettings(historyRetentionDays: 0));

      final repo = repository();
      addTearDown(repo.dispose);
      await repo.load();

      expect(
        repo.currentSessions.map((item) => item.id).toList(),
        contains('old'),
        reason: '选了永久保留，历史却被删了——这是不可逆的数据丢失',
      );
    });

    test('没结束的会话不会被当作过期记录清理', () async {
      // 崩溃退出会留下「没有结束时间」的记录：它的时间基准是开始时间，
      // 因此同样会被到期清理，但**当前正在进行的会话**必须留着。
      await historyStorage.writeAll(<SessionRecord>[live('unfinished', 400)]);
      await settings.save(const AppSettings(historyRetentionDays: 7));

      final repo = repository();
      addTearDown(repo.dispose);
      await repo.load();
      await repo.startSession(peerName: '当前设备', peerIp: '192.168.1.2');
      final activeId = repo.activeSessionId!;

      await repo.applyRetention();

      final ids = repo.currentSessions.map((item) => item.id).toList();
      expect(ids, contains(activeId),
          reason: '正在进行的会话被期限清理掉了，消息与文件会无处可写');
      expect(ids, isNot(contains('unfinished')));
    });

    test('把期限改短：立刻清理并落盘，而不只是内存里少一条', () async {
      await historyStorage.writeAll(<SessionRecord>[ended('old', 40)]);
      await settings.save(const AppSettings(historyRetentionDays: 0));

      final repo = repository();
      addTearDown(repo.dispose);
      await repo.load();
      expect(repo.currentSessions.length, 1);

      await settings.save(const AppSettings(historyRetentionDays: 7));
      final removed = await repo.applyRetention();
      expect(removed, 1);
      expect(repo.currentSessions, isEmpty);

      // 真的写回了文件：换一个实例读，不是只在内存里少了一条。
      await repo.flush();
      final reopened = repository();
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.currentSessions, isEmpty);
    });

    test('设置里的期限变动由 ViewModel 触发清理，并告诉用户清了几条', () async {
      await historyStorage.writeAll(<SessionRecord>[
        ended('old', 40),
        live('unfinished', 1),
      ]);
      await settings.save(const AppSettings(historyRetentionDays: 0));

      final repo = repository();
      addTearDown(repo.dispose);
      await repo.load();

      final vm = SettingsViewModel(
        settingsRepository: settings,
        historyRepository: repo,
        networkInfoService: NetworkInfoService(),
      );
      addTearDown(vm.dispose);
      await vm.load();

      await vm.setRetentionDays(7);

      expect(vm.retentionDays, 7);
      expect(vm.lastMessage, contains('清理了 1 条过期记录'));
      expect(repo.currentSessions.map((item) => item.id).toList(),
          contains('unfinished'));
      expect(repo.currentSessions.map((item) => item.id).toList(),
          isNot(contains('old')));
    });

    test('改设备名会立刻通知到连接侧，并写进设置文件', () async {
      String? notified;
      final vm = SettingsViewModel(
        settingsRepository: settings,
        historyRepository: repository(),
        networkInfoService: NetworkInfoService(),
        onDeviceNameChanged: (name) => notified = name,
      );
      addTearDown(vm.dispose);
      await vm.load();

      // 没自定义时输入框显示主机名，广播出去的也是它。
      expect(vm.deviceName, '');
      expect(vm.deviceNameForInput, vm.defaultDeviceName);

      await vm.setDeviceName('客厅的 Mac');

      expect(vm.deviceName, '客厅的 Mac');
      expect(notified, '客厅的 Mac',
          reason: '改名没有同步给连接层：对方要等下次心跳才知道');
      expect(
        (await SettingsRepositoryLocal(SettingsService(storage)).load())
            .deviceName,
        '客厅的 Mac',
      );

      // 清空 = 恢复主机名，而不是广播一个空名字。
      await vm.setDeviceName('');
      expect(vm.deviceName, '');
      expect(notified, vm.defaultDeviceName);
    });
  });

  group('失败任务重新发送', () {
    late Directory temp;
    late Directory saveDir;
    late ChatTransportService sender;
    late ChatTransportService receiver;

    FileStorageService fileStorage() => FileStorageService(
          settingsService: SettingsService(_FakeStorage(temp)),
          storageService: _FakeStorage(temp),
        );

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('mova_retry_test');
      saveDir = Directory(p.join(temp.path, 'save'))..createSync();

      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      receiver = ChatTransportService();
      sender = ChatTransportService();

      final ready = Completer<void>();
      receiver.status.listen((status) {
        if (status == ConnectionStatus.connected && !ready.isCompleted) {
          ready.complete();
        }
      });
      await receiver.startListening(port);
      await sender.connect('127.0.0.1', port);
      await ready.future
          .timeout(const Duration(seconds: 10), onTimeout: () => throw StateError('对端未接入'));
    });

    tearDown(() async {
      await sender.dispose();
      await receiver.dispose();
      try {
        await temp.delete(recursive: true);
      } catch (_) {
        // 清理失败不影响测试结果。
      }
    });

    File makeFile(String name) {
      final file = File(p.join(temp.path, name));
      file.writeAsBytesSync(List<int>.filled(4096, 7));
      return file;
    }

    /// 让接收端自动接收，用来把一次发送真正跑完（取「已完成」状态）。
    void autoAccept(TransferRepositoryLocal repo) {
      repo.tasks.listen((tasks) {
        for (final task in tasks) {
          if (task.direction == TransferDirection.receiving &&
              task.status == TransferStatus.waiting) {
            unawaited(repo.accept(task.id, saveDirectory: saveDir.path));
          }
        }
      });
    }

    test('发送失败的任务再次发送：新任务入队，旧的失败卡片被替换', () async {
      final senderRepo = TransferRepositoryLocal(
        sender,
        fileStorage(),
        // 对方永远不点接收 → 这个请求必然超时失败。
        offerTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(senderRepo.dispose);
      final receiverRepo = TransferRepositoryLocal(receiver, fileStorage());
      addTearDown(receiverRepo.dispose);

      final file = makeFile('retry-me.bin');
      await senderRepo.sendFiles([
        PickedFile(path: file.path, name: 'retry-me.bin', size: 4096),
      ]);

      final failed = await _waitForTask(
        senderRepo,
        'retry-me.bin',
        TransferStatus.failed,
      );
      expect(failed, isNotNull, reason: '对方不接收，任务应在offer超时后失败');

      final result = await senderRepo.retry(failed!.id);
      expect(result, isA<Ok<int>>(), reason: '失败的任务应该可以重新发送');

      final tasks = senderRepo.currentTasks;
      expect(
        tasks.any((task) => task.id == failed.id),
        isFalse,
        reason: '旧的失败卡片还在列表里，用户会以为文件发了一半',
      );
      final fresh = tasks
          .cast<TransferTask?>()
          .firstWhere((task) => task?.fileName == 'retry-me.bin',
              orElse: () => null);
      expect(fresh, isNotNull);
      expect(fresh!.id, isNot(failed.id),
          reason: '重发必须换任务 id：对端正是用它认这一条传输的');
      expect(fresh.isActive, isTrue);
      expect(fresh.totalBytes, 4096);
    });

    test('已经传完的文件不能重发', () async {
      final senderRepo = TransferRepositoryLocal(sender, fileStorage());
      addTearDown(senderRepo.dispose);
      final receiverRepo = TransferRepositoryLocal(receiver, fileStorage());
      addTearDown(receiverRepo.dispose);
      autoAccept(receiverRepo);

      final file = makeFile('once.bin');
      await senderRepo.sendFiles([
        PickedFile(path: file.path, name: 'once.bin', size: 4096),
      ]);

      final done = await _waitForTask(
        senderRepo,
        'once.bin',
        TransferStatus.completed,
      );
      expect(done, isNotNull, reason: '文件没能传完，这条用例的前提不成立');

      final result = await senderRepo.retry(done!.id);
      expect(result, isA<Error<int>>(), reason: '已经传完的文件不该被重复发送');
    });

    test('原文件不在了会明确报错，而不是卡着一个永远成功不了的任务', () async {
      final senderRepo = TransferRepositoryLocal(
        sender,
        fileStorage(),
        offerTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(senderRepo.dispose);
      final receiverRepo = TransferRepositoryLocal(receiver, fileStorage());
      addTearDown(receiverRepo.dispose);

      final file = makeFile('gone.bin');
      await senderRepo.sendFiles([
        PickedFile(path: file.path, name: 'gone.bin', size: 4096),
      ]);
      final failed = await _waitForTask(
        senderRepo,
        'gone.bin',
        TransferStatus.failed,
      );
      expect(failed, isNotNull);

      await file.delete();

      final result = await senderRepo.retry(failed!.id);
      expect(result, isA<Error<int>>());
      final message = (result as Error<int>).error.toString();
      expect(message, contains('不在原来的位置'),
          reason: '文件都没了还去排队，用户只能干等着一个必然的失败');
    });
  });

  group('发送前的那句确认', () {
    final files = <PickedFile>[
      const PickedFile(path: '/tmp/合同.pdf', name: '合同.pdf', size: 3 * 1024),
      const PickedFile(path: '/tmp/旅行.mp4', name: '旅行.mp4', size: 5 * 1024 * 1024),
    ];

    Future<void> open(
      WidgetTester tester,
      List<PickedFile> items, {
      required void Function(bool) onResult,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  final confirmed = await showSendConfirmDialog(
                    context,
                    files: items,
                    peerName: '客厅的 Mac',
                  );
                  onResult(confirmed);
                },
                child: const Text('发起'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('发起'));
      await tester.pumpAndSettle();
    }

    testWidgets('弹窗列出要发的文件与大小', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSendConfirmDialog(
                  context,
                  files: files,
                  peerName: '客厅的 Mac',
                ),
                child: const Text('发起'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('发起'));
      await tester.pumpAndSettle();

      expect(find.text('发送给「客厅的 Mac」？'), findsOneWidget);
      expect(find.text('合同.pdf'), findsOneWidget);
      expect(find.text('旅行.mp4'), findsOneWidget);
      // 标题里必须出现总数：不然用户不知道自己一次点了几个文件出去。
      expect(find.textContaining('2 个文件'), findsOneWidget);
    });

    testWidgets('取消就是不发送', (tester) async {
      bool? confirmed;
      await open(tester, files, onResult: (value) => confirmed = value);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(confirmed, isFalse, reason: '点了取消，文件还是被发出去了');
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('点「发送」才真的发出', (tester) async {
      bool? confirmed;
      await open(tester, files, onResult: (value) => confirmed = value);

      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();

      expect(confirmed, isTrue);
    });

    testWidgets('遮罩点击等于取消', (tester) async {
      bool? confirmed;
      await open(tester, files, onResult: (value) => confirmed = value);

      // 点弹窗外：不能因为没有按到「取消」就被当成确认。
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      expect(confirmed, isFalse, reason: '点遮罩关闭被当成了确认发送');
      expect(find.byType(Dialog), findsNothing);
    });
  });

  group('卡片上的「重新发送」', () {
    TransferTask buildTask(TransferDirection direction, TransferStatus status) =>
        TransferTask(
          id: 42,
          fileName: '设计稿.png',
          totalBytes: 4096,
          direction: direction,
          status: status,
          createdAt: DateTime(2026),
          localPath: '/tmp/设计稿.png',
          error: '对方没有响应接收请求',
        );

    Future<void> pump(
      WidgetTester tester,
      TransferTask task,
      VoidCallback onRetry,
    ) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: TransferCard(
                  task: task,
                  onAccept: () {},
                  onSaveAs: () {},
                  onReject: () {},
                  onCancel: () {},
                  onRetry: onRetry,
                ),
              ),
            ),
          ),
        );

    testWidgets('自己发出去失败：有按钮，点了真的会重发', (tester) async {
      var called = 0;
      await pump(
        tester,
        buildTask(TransferDirection.sending, TransferStatus.failed),
        () => called++,
      );

      expect(find.text('重新发送'), findsOneWidget);
      await tester.tap(find.text('重新发送'));
      await tester.pumpAndSettle();
      expect(called, 1);
    });

    testWidgets('对方发来失败：不给按钮，说明要对方重发', (tester) async {
      var called = 0;
      await pump(
        tester,
        buildTask(TransferDirection.receiving, TransferStatus.failed),
        () => called++,
      );

      expect(find.text('重新发送'), findsNothing,
          reason: '接收失败时文件在对方手里，这个按钮点了也没有');
      expect(find.text('这是对方发来的文件，需要对方重新发送'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(called, 0);
    });

    testWidgets('传完的文件不显示重发按钮', (tester) async {
      await pump(
        tester,
        buildTask(TransferDirection.sending, TransferStatus.completed),
        () {},
      );
      expect(find.text('重新发送'), findsNothing);
    });
  });
}
