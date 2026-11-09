import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mova/config/app_config.dart';
import 'package:mova/data/repositories/update/update_repository.dart';
import 'package:mova/data/services/update/update_installer_service.dart';
import 'package:mova/data/services/update/update_service.dart';
import 'package:mova/domain/models/transfer/transfer_task.dart';
import 'package:mova/domain/models/update/app_update.dart';
import 'package:mova/ui/settings/view_models/update_view_model.dart';

import 'support/fake_transfer_repository.dart';

class _Transfers extends FakeTransferRepository {
  List<TransferTask> snapshot = [];
  @override
  List<TransferTask> get currentTasks => snapshot;
}

class _Installer extends UpdateInstallerService {
  int downloads = 0;
  int launches = 0;
  bool failDownload = false;
  @override
  String get platformKey => 'windows-x64';
  @override
  Future<File> download(UpdateAsset asset, void Function(double?) progress) async {
    downloads++;
    if (failDownload) throw const FileSystemException('磁盘已满');
    progress(1);
    return File('unused-test-package.exe');
  }
  @override
  Future<Future<void> Function()> prepare(File package) async => () async { launches++; };
}

void main() {
  test('非法或不完整的平台包不可用于安装', () {
    expect(UpdateAsset.tryParse({'url': 'http://example.com/a', 'size': 1}), isNull);
    expect(UpdateAsset.tryParse({'url': 'https://example.com/a', 'size': 0}), isNull);
    expect(UpdateAsset.tryParse({'url': 'https://example.com/a', 'size': 10}), isNotNull);
  });

  for (final status in TransferStatus.values.where((s) => [
    TransferStatus.queued, TransferStatus.waiting, TransferStatus.preparing,
    TransferStatus.transferring, TransferStatus.confirming,
  ].contains(s))) {
    test('任务处于 $status 时不启动安装器', () async {
      final transfers = _Transfers();
      addTearDown(transfers.dispose);
      transfers.snapshot = [TransferTask(id: 1, fileName: 'a.zip', totalBytes: 1,
        direction: TransferDirection.receiving, status: status)];
      final installer = _Installer();
      final repository = UpdateRepository(installer: installer, transfer: transfers,
        installAndExit: (launch) => launch());
      await expectLater(repository.install(), throwsStateError);
      expect(installer.launches, 0);
    });
  }

  testWidgets('下载不结束文件任务，取消等待后不会自动安装，再次确认可安装', (tester) async {
    final transfers = _Transfers();
    addTearDown(transfers.dispose);
    transfers.snapshot = [TransferTask(id: 1, fileName: 'a.zip', totalBytes: 1,
      direction: TransferDirection.sending, status: TransferStatus.transferring)];
    final installer = _Installer();
    final repository = UpdateRepository(installer: installer, transfer: transfers,
      installAndExit: (launch) => launch());
    final vm = UpdateViewModel(updateRepository: repository, updateService: UpdateService(
      fetcher: (_, timeout) async => '{"versionCode":${AppConfig.appBuildNumber + 1},"assets":{"windows-x64":{"url":"https://example.com/setup.exe","size":10}}}',
    ));
    addTearDown(vm.dispose);
    await vm.check();
    await vm.downloadUpdate();
    expect(vm.readyToInstall, isTrue);
    expect(transfers.snapshot.single.status, TransferStatus.transferring);
    await vm.installUpdate();
    expect(vm.waitingForTransfers, isTrue);
    expect(installer.launches, 0);
    vm.cancelUpdate();
    transfers.snapshot = [];
    await tester.pump(const Duration(seconds: 2));
    expect(installer.launches, 0);
    await vm.installUpdate();
    expect(installer.launches, 1);
  });

  test('保存失败时安装器不会启动，错误反馈到界面', () async {
    final transfers = _Transfers();
    addTearDown(transfers.dispose);
    final installer = _Installer();
    final vm = UpdateViewModel(
      updateRepository: UpdateRepository(installer: installer, transfer: transfers,
        installAndExit: (_) async => throw StateError('保存失败')),
      updateService: UpdateService(fetcher: (_, timeout) async =>
        '{"versionCode":${AppConfig.appBuildNumber + 1},"assets":{"windows-x64":{"url":"https://example.com/setup.exe","size":10}}}'),
    );
    addTearDown(vm.dispose);
    await vm.check();
    await vm.downloadUpdate();
    await vm.installUpdate();
    expect(installer.launches, 0);
    expect(vm.downloadHint, contains('保存失败'));
    expect(vm.installing, isFalse);
  });
}
