import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mova/data/repositories/transfer/transfer_repository_local.dart';
import 'package:mova/data/services/chat/chat_transport_service.dart';
import 'package:mova/data/services/storage/settings_service.dart';
import 'package:mova/data/services/storage/storage_service.dart';
import 'package:mova/data/services/transfer/file_storage_service.dart';
import 'package:mova/domain/models/chat/connection_status.dart';
import 'package:mova/domain/models/transfer/picked_file.dart';

/// 一次只连一台设备：
/// - 已连接时，第三方连进来会被拒绝，并给当前用户一条提示；
/// - 换会话（断开再连）后，上一次连接留下的任务要清空，
///   否则界面上会混着两台设备的文件卡。
void main() {
  late Directory temp;
  late ChatTransportService host;
  late ChatTransportService first;
  late ChatTransportService third;

  FileStorageService fileStorage() => FileStorageService(
        settingsService: SettingsService(StorageService()),
        storageService: StorageService(),
      );

  Future<int> freePort() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    return port;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mova_session_test');
    host = ChatTransportService();
    first = ChatTransportService();
    third = ChatTransportService();
  });

  tearDown(() async {
    await host.dispose();
    await first.dispose();
    await third.dispose();
    try {
      await temp.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响测试结果。
    }
  });

  test('已连接时第三方连入会被拒绝，当前会话不受影响', () async {
    final port = await freePort();

    final hostReady = Completer<void>();
    host.status.listen((status) {
      if (status == ConnectionStatus.connected && !hostReady.isCompleted) {
        hostReady.complete();
      }
    });

    await host.startListening(port);
    await first.connect('127.0.0.1', port);
    await hostReady.future.timeout(const Duration(seconds: 10));

    final sessionBefore = host.sessionId;
    expect(sessionBefore, isNotNull);

    final notices = <String>[];
    final subscription = host.notices.listen(notices.add);

    // 第三台设备来连：TCP 会连上，但应用层必须拒绝它。
    await third.connect('127.0.0.1', port);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await subscription.cancel();

    expect(notices, isNotEmpty, reason: '拒绝新连接时应当给出提示');
    expect(notices.first, contains('保持连接'));
    // 当前会话既没被顶掉，也没换 id。
    expect(host.sessionId, sessionBefore);
    expect(host.isBusy, isTrue);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('换会话后，上一次连接留下的任务被清空', () async {
    final port = await freePort();
    final saveDir = Directory('${temp.path}/save')..createSync();

    final hostReady = Completer<void>();
    host.status.listen((status) {
      if (status == ConnectionStatus.connected && !hostReady.isCompleted) {
        hostReady.complete();
      }
    });

    await host.startListening(port);
    await first.connect('127.0.0.1', port);
    await hostReady.future.timeout(const Duration(seconds: 10));

    final hostRepo = TransferRepositoryLocal(host, fileStorage());
    addTearDown(() => hostRepo.dispose());

    // 让第一台设备发一个文件过来，任务进入列表。
    final senderRepo = TransferRepositoryLocal(first, fileStorage());
    addTearDown(() => senderRepo.dispose());

    final file = File('${temp.path}/doc.pdf')
      ..writeAsBytesSync(Uint8List.fromList(List<int>.filled(2048, 7)));
    await senderRepo.sendFiles([
      PickedFile(
        path: file.path,
        name: file.path.split(Platform.pathSeparator).last,
        size: await file.length(),
      ),
    ]);

    for (var i = 0; i < 60 && hostRepo.currentTasks.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(hostRepo.currentTasks, isNotEmpty);

    // 断开后再连一次：这是「换了一台设备」的等价操作。
    await first.disconnect();
    for (var i = 0; i < 60 && host.isBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final second = ChatTransportService();
    addTearDown(() => second.dispose());
    final reconnected = Completer<void>();
    host.status.listen((status) {
      if (status == ConnectionStatus.connected && !reconnected.isCompleted) {
        reconnected.complete();
      }
    });
    await second.connect('127.0.0.1', port);
    await reconnected.future.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      hostRepo.currentTasks,
      isEmpty,
      reason: '新会话开始时，上一次连接的任务必须清空',
    );
    expect(hostRepo.currentTasks, isEmpty);
    expect(saveDir.existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
