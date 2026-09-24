import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../../config/app_config.dart';
import '../../../data/repositories/history/history_repository.dart';
import '../../../data/repositories/transfer/transfer_repository.dart';
import '../../../data/services/transfer/file_storage_service.dart';
import '../../../domain/models/history/session_record.dart';
import '../../../domain/models/transfer/picked_file.dart';
import '../../../domain/models/transfer/transfer_task.dart';
// 必须显式导入：result.dart 中的 Error 会覆盖 dart:core 的同名类。
import '../../../utils/result.dart';

/// 文件传输视图模型（ViewModel 层）：选文件、拖拽发送、保存位置、同意/拒绝/取消。
class TransferViewModel extends ChangeNotifier {
  TransferViewModel({
    required TransferRepository transferRepository,
    required FileStorageService fileStorageService,
    required HistoryRepository historyRepository,
  })  : _transferRepository = transferRepository,
        _fileStorageService = fileStorageService,
        _historyRepository = historyRepository {
    _tasksSub = _transferRepository.tasks.listen((tasks) {
      _tasks = tasks;
      _recordFiles(tasks);
      notifyListeners();
    });
    unawaited(_loadSaveDirectory());
  }

  final TransferRepository _transferRepository;
  final FileStorageService _fileStorageService;
  final HistoryRepository _historyRepository;
  final Logger _log = Logger('TransferViewModel');

  /// 已写入历史的「任务 id → 状态」，用于避免每 100ms 的进度刷新都写盘。
  final Map<int, TransferStatus> _recordedStatus = <int, TransferStatus>{};

  StreamSubscription<List<TransferTask>>? _tasksSub;

  List<TransferTask> _tasks = const [];
  String? _errorMessage;

  /// 接收文件的保存目录（null 表示尚未加载完）。
  String? _saveDirectory;

  /// 最近一次操作反馈（如「已忽略 2 个不支持的文件」），供界面提示一次。
  String? _lastMessage;

  /// 全部任务（收发混合，按发起/到达顺序）。
  List<TransferTask> get tasks => _tasks;

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

  Future<void> _loadSaveDirectory() async {
    _saveDirectory = await _fileStorageService.currentSaveDirectory();
    notifyListeners();
  }

  /// 让用户选择接收文件的保存目录，并记住它。
  Future<void> chooseSaveDirectory() async {
    final directory = await _fileStorageService.pickDirectory(
      dialogTitle: '选择接收文件的保存位置',
    );
    if (directory == null) return; // 用户取消
    await _fileStorageService.rememberSaveDirectory(directory);
    _saveDirectory = directory;
    notifyListeners();
  }

  /// 选择文件并发送（受 AppConfig.allowedFileExtensions 限制）。
  Future<void> pickAndSendFiles() async {
    _errorMessage = null;
    notifyListeners();

    final List<PickedFile> picked = await _fileStorageService.pickFiles();
    if (picked.isEmpty) return;

    await _send(picked);
  }

  /// 发送拖拽进来的文件路径；不支持的类型会被忽略并给出提示。
  Future<void> sendPaths(List<String> paths) async {
    _errorMessage = null;
    notifyListeners();

    final parsed = await _fileStorageService.filesFromPaths(paths);
    if (parsed.accepted.isEmpty) {
      _lastMessage = paths.isEmpty
          ? '没有识别到文件'
          : '这些文件暂不支持（仅支持 $_allowedText）';
      notifyListeners();
      return;
    }

    await _send(parsed.accepted);

    final ignoredHint = parsed.ignored.isEmpty
        ? ''
        : '，已忽略 ${parsed.ignored.length} 个不支持的项';
    _lastMessage =
        '已发起 ${parsed.accepted.length} 个文件$ignoredHint';
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
    final directory = await _fileStorageService.pickDirectory();
    if (directory == null) return; // 用户取消选择
    await _fileStorageService.rememberSaveDirectory(directory);
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
