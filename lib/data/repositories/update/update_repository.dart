import 'dart:io';
import 'package:logging/logging.dart';

import '../../../domain/models/update/app_update.dart';
import '../../services/update/update_installer_service.dart';
import '../transfer/transfer_repository.dart';

/// 更新业务：平台选择、下载、任务检查与退出安装之间的协调。
class UpdateRepository {
  UpdateRepository({required UpdateInstallerService installer,
    required TransferRepository transfer,
    required Future<void> Function(Future<void> Function()) installAndExit})
      : _installer = installer, _transfer = transfer, _installAndExit = installAndExit;

  final Logger _log = Logger('UpdateRepository');
  final UpdateInstallerService _installer;
  final TransferRepository _transfer;
  final Future<void> Function(Future<void> Function()) _installAndExit;
  File? _package;
  Future<void> Function()? _launch;
  bool get hasActiveTransfers => _transfer.currentTasks.any((task) => task.isActive);

  Future<void> download(AppUpdate update, void Function(double?) progress) async {
    final asset = update.assets[_installer.platformKey];
    if (asset == null) throw StateError('这个版本没有当前平台的自动更新包，请打开下载页');
    _launch = null;
    _package = await _installer.download(asset, progress);
  }

  void cancelDownload() => _installer.cancel();

  Future<void> install() async {
    if (hasActiveTransfers) throw StateError('还有未结束的文件任务，请等待完成或取消任务');
    final package = _package;
    if (package == null) throw StateError('请先下载更新');
    _log.info('更新：开始准备安装脚本');
    _launch ??= await _installer.prepare(package);
    _log.info('更新：安装脚本已准备，进入退出收尾');
    // prepare 包含磁盘操作；退出入口必须再次同步检查任务，避免检查后新任务进入。
    await _installAndExit(_launch!);
  }
}
