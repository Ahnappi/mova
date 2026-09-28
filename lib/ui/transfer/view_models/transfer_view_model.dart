import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../../config/app_config.dart';
import '../../../data/repositories/history/history_repository.dart';
import '../../../data/repositories/transfer/transfer_repository.dart';
import '../../../data/services/system/system_settings_service.dart';
import '../../../domain/models/history/session_record.dart';
import '../../../domain/models/transfer/picked_file.dart';
import '../../../domain/models/transfer/transfer_task.dart';
// 必须显式导入：result.dart 中的 Error 会覆盖 dart:core 的同名类。
import '../../../utils/result.dart';

/// 文件传输视图模型（ViewModel 层）：选文件、拖拽发送、保存位置、同意/拒绝/取消。
class TransferViewModel extends ChangeNotifier {
  TransferViewModel({
    required TransferRepository transferRepository,
    required HistoryRepository historyRepository,
    required SystemSettingsService systemSettingsService,
  })  : _transferRepository = transferRepository,
        _historyRepository = historyRepository,
        _systemSettings = systemSettingsService {
    _tasksSub = _transferRepository.tasks.listen((tasks) {
      _tasks = tasks;
      _byId = <int, TransferTask>{
        for (final task in tasks) task.id: task,
      };
      _recordFiles(tasks);
      _captureFailure(tasks);
      notifyListeners();
    });
    unawaited(_loadSaveDirectory());
  }

  final TransferRepository _transferRepository;
  final HistoryRepository _historyRepository;
  final SystemSettingsService _systemSettings;
  final Logger _log = Logger('TransferViewModel');

  /// 已写入历史的「任务 id → 状态」，用于避免每 100ms 的进度刷新都写盘。
  final Map<int, TransferStatus> _recordedStatus = <int, TransferStatus>{};

  StreamSubscription<List<TransferTask>>? _tasksSub;

  List<TransferTask> _tasks = const [];
  Map<int, TransferTask> _byId = const <int, TransferTask>{};
  String? _errorMessage;

  /// 用户已手动关掉的错误，避免进度刷新时又把它弹回来。
  final Set<String> _dismissedErrors = <String>{};

  /// 接收文件的保存目录（null 表示尚未加载完）。
  String? _saveDirectory;

  /// 最近一次操作反馈（如「已忽略 2 个不支持的文件」），供界面提示一次。
  String? _lastMessage;

  /// 全部任务（收发混合，按发起/到达顺序）。
  List<TransferTask> get tasks => _tasks;

  /// 任务列表的「结构指纹」：只在任务增删或顺序变化时改变。
  ///
  /// 进度每秒会刷新十次，界面只需要重画那一张卡片，
  /// 而不是重建整条时间线。用 [Selector] 监听这个值，
  /// 就能把「高频进度」和「列表结构变化」分开。
  String get taskSignature => _tasks.map((task) => task.id).join(',');

  /// 按 id 取任务（卡片自己监听，避免被别人的进度带着重画）。
  ///
  /// 只有真正变化的那一条会被重建：其余任务对象保持同一实例，
  /// [Selector] 比较时发现没变就不重画。
  TransferTask? taskById(int id) => _byId[id];

  /// 待确认的接收请求。
  List<TransferTask> get pendingOffers => _tasks
      .where(
        (task) =>
            task.direction == TransferDirection.receiving &&
            task.status == TransferStatus.waiting,
      )
      .toList(growable: false);

  /// 是否正在传输（有任务在收发中）。
  bool get hasActiveTransfer => _tasks.any((task) => task.isActive);

  /// 最近一次错误。
  String? get errorMessage => _errorMessage;

  /// 最近一次错误是否属于「系统权限被拒绝」。
  ///
  /// 这类错误用户自己改不了应用设置，只能去系统里授权，
  /// 界面据此给出打开设置页的入口。
  bool get isPermissionError {
    final message = _errorMessage?.toLowerCase() ?? '';
    return message.contains('operation not permitted') ||
        message.contains('permission denied') ||
        message.contains('errno = 1') ||
        message.contains('errno=1') ||
        message.contains('access is denied') ||
        message.contains('没有写入');
  }

  /// 关掉错误提示条（同一条错误不会被后续的进度刷新重新弹出来）。
  void dismissError() {
    final current = _errorMessage;
    if (current != null) _dismissedErrors.add(current);
    _errorMessage = null;
    notifyListeners();
  }

  /// 打开系统的文件/文件夹权限设置页。
  Future<void> openFileAccessSettings() =>
      _systemSettings.openFileAccessSettings();

  /// 打开系统的网络权限设置页（连不上、搜不到设备时用到）。
  Future<void> openNetworkSettings() =>
      _systemSettings.openLocalNetworkSettings();

  /// 接收文件的保存目录。
  String? get saveDirectory => _saveDirectory;

  /// 最近一次操作反馈；读取后调用 [clearMessage] 避免重复提示。
  String? get lastMessage => _lastMessage;

  void clearMessage() => _lastMessage = null;

  /// 把文件写入连接记录：只在「首次出现」和「状态变化」时写。
  ///
  /// 进度刷新每秒可达十次，逐次写盘既浪费又会拖慢传输，因此按状态去重。
  void _recordFiles(List<TransferTask> tasks) {
    for (final task in tasks) {
      final previous = _recordedStatus[task.id];
      if (previous == task.status) continue;

      _recordedStatus[task.id] = task.status;
      unawaited(_historyRepository.upsertFile(SessionFile.fromTask(task)));
    }
  }

  /// 把「被动失败」（传输中断连、写盘被拒等）的原因也提到界面上。
  ///
  /// 此前只有主动操作（选文件、点接收）的错误会被记下来，
  /// 传输途中出问题时用户只看到一个失败的卡片，不知道原因。
  void _captureFailure(List<TransferTask> tasks) {
    TransferTask? latest;
    for (final task in tasks) {
      if (task.status != TransferStatus.failed) continue;
      final error = task.error;
      if (error == null || error.isEmpty) continue;
      if (latest == null || task.createdAt.isAfter(latest.createdAt)) {
        latest = task;
      }
    }
    if (latest == null) return;

    final message = '${latest.fileName}：${latest.error}';
    if (_dismissedErrors.contains(message)) return;
    _errorMessage = message;
  }

  Future<void> _loadSaveDirectory() async {
    _saveDirectory = await _transferRepository.currentSaveDirectory();
    notifyListeners();
  }

  /// 让用户选择接收文件的保存目录，并记住它。
  Future<void> chooseSaveDirectory() async {
    final directory = await _transferRepository.pickSaveDirectory(
      dialogTitle: '选择接收文件的保存位置',
    );
    if (directory == null) return; // 用户取消
    await _transferRepository.rememberSaveDirectory(directory);
    _saveDirectory = directory;
    notifyListeners();
  }

  /// 选择文件并发送（受 AppConfig.allowedFileExtensions 限制）。
  Future<void> pickAndSendFiles() async {
    _errorMessage = null;
    notifyListeners();

    final picked = await _transferRepository.pickFilesToSend();
    if (picked.accepted.isEmpty) {
      if (picked.ignored.isNotEmpty) {
        _lastMessage = '这些文件暂不支持（仅支持 $_allowedText）';
        notifyListeners();
      }
      return;
    }

    await _send(picked.accepted);
    _reportResult(picked.accepted.length, picked.ignored.length);
  }

  /// 发送拖拽进来的文件路径；不支持的类型会被忽略并给出提示。
  Future<void> sendPaths(List<String> paths) async {
    _errorMessage = null;
    notifyListeners();

    final parsed = await _transferRepository.filesFromPaths(paths);
    if (parsed.accepted.isEmpty) {
      _lastMessage = paths.isEmpty
          ? '没有识别到文件'
          : '这些文件暂不支持（仅支持 $_allowedText）';
      notifyListeners();
      return;
    }

    await _send(parsed.accepted);
    _reportResult(parsed.accepted.length, parsed.ignored.length);
  }

  /// 统一给出「发起了几个、忽略了几个」的一次性提示。
  void _reportResult(int acceptedCount, int ignoredCount) {
    final ignoredHint =
        ignoredCount == 0 ? '' : '，已忽略 $ignoredCount 个不支持的项';
    _lastMessage = '已发起 $acceptedCount 个文件$ignoredHint';
    notifyListeners();
  }

  String get _allowedText => AppConfig.allowedSummary;

  Future<void> _send(List<PickedFile> files) async {
    final result = await _transferRepository.sendFiles(files);
    if (result is Error<void>) {
      _errorMessage = result.error.toString();
      _log.warning('发起发送失败：${result.error}');
      notifyListeners();
    }
  }

  /// 同意接收；[saveDirectory] 为空时落到当前保存目录。
  Future<void> accept(int fileId, {String? saveDirectory}) async {
    final result = await _transferRepository.accept(
      fileId,
      saveDirectory: saveDirectory,
    );
    if (result is Error<void>) {
      _errorMessage = result.error.toString();
      _log.warning('接收失败：${result.error}');
      notifyListeners();
    }
  }

  /// 弹出目录选择后接收（会顺带记住该目录）。
  Future<void> acceptWithDirectoryPicker(int fileId) async {
    final directory = await _transferRepository.pickSaveDirectory();
    if (directory == null) return; // 用户取消选择
    await _transferRepository.rememberSaveDirectory(directory);
    _saveDirectory = directory;
    notifyListeners();
    await accept(fileId, saveDirectory: directory);
  }

  /// 直接接收到当前保存目录。
  Future<void> acceptToDefaultDirectory(int fileId) => accept(fileId);

  Future<void> reject(int fileId) => _transferRepository.reject(fileId);

  Future<void> cancel(int fileId) => _transferRepository.cancel(fileId);

  @override
  void dispose() {
    _tasksSub?.cancel();
    super.dispose();
  }
}
