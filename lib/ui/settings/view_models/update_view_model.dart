import 'dart:async';

import 'package:flutter/foundation.dart';
import '../../../data/repositories/update/update_repository.dart';
import 'package:logging/logging.dart';

import '../../../config/app_config.dart';
import '../../../data/services/system/file_opener_service.dart';
import '../../../data/services/update/update_service.dart';
import '../../../domain/models/update/app_update.dart';
import '../../../utils/result.dart';

/// 一次检查更新的结局。
enum UpdateCheckStatus {
  /// 还没查过。
  idle,

  /// 正在查。
  checking,

  /// 已经是最新版。
  upToDate,

  /// 有新版本。
  available,

  /// 这次没查成。
  failed,
}

/// 版本与升级的视图模型（ViewModel 层）：当前版本、检查更新、打开下载页。
///
  /// 四个容易做错的点：
  /// 1. **查不到不等于没有新版本**。断网时点「检查更新」得到的是失败，
  ///    不是「已是最新」——说成后者，用户就再也不会去升级了；
  /// 2. **重复点击要挡住**：一次检查还在飞的时候再点一次，
  ///    两条响应谁先回来谁说了算，界面上的结论会来回跳；
  /// 3. **清单没给下载地址时不能静默返回**：那样界面上就是一个
  ///    「发现新版本」配一个点了没反应的下载按钮。应当退回固定的
  ///    发布页，并把这件事说清楚；
  /// 4. **打开下载页失败要给退路**：把地址原样显示出来，
  ///    用户可以自己复制到浏览器。
class UpdateViewModel extends ChangeNotifier {
  UpdateViewModel({
    required UpdateService updateService,
    FileOpenerService? opener,
    UpdateRepository? updateRepository,
  })  : _repository = updateRepository,
        _updateService = updateService,
        _opener = opener ?? FileOpenerService();

  final UpdateRepository? _repository;
  bool downloading = false;
  bool installing = false;
  bool readyToInstall = false;
  bool waitingForTransfers = false;
  double? downloadProgress;
  Timer? _waitTimer;
  bool _disposed = false;
  bool get updateBusy => downloading || installing || waitingForTransfers;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _waitTimer?.cancel();
    _repository?.cancelDownload();
    super.dispose();
  }

  Future<void> downloadUpdate() async {
    if (updateBusy || _update == null) return;
    final repository = _repository;
    if (repository == null) { await openDownloadPage(); return; }
    downloading = true;
    readyToInstall = false;
    downloadProgress = null;
    _downloadHint = '正在下载更新，文件传输可以继续。';
    notifyListeners();
    try {
      await repository.download(_update!, (value) {
        downloadProgress = value;
        notifyListeners();
      });
      readyToInstall = true;
      _downloadHint = '下载完成。点击安装并重启；有文件任务时将等待它们结束。';
    } catch (e) {
      _downloadHint = '下载未完成：$e';
    } finally {
      downloading = false;
      notifyListeners();
    }
  }

  void cancelUpdate() {
    if (installing) return;
    _repository?.cancelDownload();
    waitingForTransfers = false;
    _waitTimer?.cancel();
    _waitTimer = null;
    _downloadHint = '已取消自动安装，可以稍后重试。';
    notifyListeners();
  }

  Future<void> installUpdate() async {
    _log.info('用户确认安装：ready=$readyToInstall, installing=$installing, disposed=$_disposed');
    final repository = _repository;
    if (repository == null || !readyToInstall || installing || _disposed) return;
    if (repository.hasActiveTransfers) {
      if (!waitingForTransfers) _log.info('更新：等待活动文件任务结束');
      waitingForTransfers = true;
      _downloadHint = '等待文件任务结束后安装并重启（包含排队和等待确认的任务）。';
      _waitTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!repository.hasActiveTransfers) unawaited(installUpdate());
      });
      notifyListeners();
      return;
    }
    _waitTimer?.cancel();
    _waitTimer = null;
    waitingForTransfers = false;
    installing = true;
    _downloadHint = '正在准备安装并保存记录，请稍候…';
    notifyListeners();
    try {
      await repository.install();
    } catch (e) {
      _log.warning('自动安装失败', e);
      _downloadHint = '安装未完成：$e';
    } finally {
      installing = false;
      notifyListeners();
    }
  }

  final UpdateService _updateService;
  final FileOpenerService _opener;
  final Logger _log = Logger('UpdateViewModel');

  UpdateCheckStatus _status = UpdateCheckStatus.idle;
  AppUpdate? _update;
  String? _detail;
  String? _downloadHint;

  /// 当前版本文案，如 `1.0.0（100）`。
  String get versionLabel => AppConfig.versionLabel;

  UpdateCheckStatus get status => _status;

  /// 查到的新版本（仅 [UpdateCheckStatus.available] 时非空）。
  AppUpdate? get update => _update;

  /// 补充文案：更新说明，或失败原因。
  String? get detail => _detail;

  /// 下载入口的提示：地址缺失 / 浏览器没打开时，界面上要有这句话。
  ///
  /// 与 [detail] 分开，是因为两者会同时出现：更新说明要一直显示，
  /// 而下载提示只在点过下载之后才有。
  String? get downloadHint => _downloadHint;

  bool get isChecking => _status == UpdateCheckStatus.checking;

  /// 有没有可用更新（界面据此决定要不要显示红点）。
  bool get hasUpdate => _status == UpdateCheckStatus.available && _update != null;

  /// 检查一次更新。正在检查时重复调用会被忽略。
  Future<void> check() async {
    if (_status == UpdateCheckStatus.checking || updateBusy || readyToInstall) return;

    _status = UpdateCheckStatus.checking;
    _detail = null;
    _update = null;
    _downloadHint = null;
    notifyListeners();

    final result = await _updateService.check();
    switch (result) {
      case Error<AppUpdate?>():
        _status = UpdateCheckStatus.failed;
        _detail = result.error.toString();
        _log.info('检查更新失败：${result.error}');
      case Ok<AppUpdate?>(value: final update):
        _update = update;
        _status = update == null
            ? UpdateCheckStatus.upToDate
            : UpdateCheckStatus.available;
        _detail = update?.notes ?? '';
    }
    notifyListeners();
  }

  /// 打开新版本的下载页。
  ///
  /// 清单没给可用地址时，退回 [AppConfig.updateFallbackUrl] 这个固定发布页，
  /// 并在 [downloadHint] 里说明「清单没给地址」：静默 return 的话，
  /// 用户看到的是一个亮着的「打开下载页」按钮，点了却什么都没发生。
  ///
  /// 浏览器也打不开时把地址留在 [downloadHint] 里：用户至少还能手动复制。
  Future<void> openDownloadPage() async {
    final update = _update;
    if (update == null) return;

    final fallback = !update.hasDownloadUrl;
    final url = fallback ? AppConfig.updateFallbackUrl : update.downloadUrl;

    if (!AppUpdate.isUsableDownloadUrl(url)) {
      // 连兜底页都不可用：明确说出来，别留一个点不动的按钮。
      _downloadHint = '这个版本没有提供下载地址，请稍后再试。';
      notifyListeners();
      return;
    }

    _downloadHint = null;
    final opened = await _opener.openUrl(url);
    if (!opened) {
      _downloadHint = '没能打开浏览器，请手动访问：$url';
    } else if (fallback) {
      _downloadHint = '清单没有给下载地址，已打开项目发布页：$url';
    }
    notifyListeners();
  }
}
