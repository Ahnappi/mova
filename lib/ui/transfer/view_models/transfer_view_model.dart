import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../../data/repositories/transfer/transfer_repository.dart';
import '../../../data/services/transfer/file_storage_service.dart';
import '../../../domain/models/transfer/picked_file.dart';
import '../../../domain/models/transfer/transfer_task.dart';
// 必须显式导入：result.dart 中的 Error 会覆盖 dart:core 的同名类。
import '../../../utils/result.dart';

/// 文件传输视图模型（ViewModel 层）：选文件、同意/拒绝/取消、进度展示。
class TransferViewModel extends ChangeNotifier {
  TransferViewModel({
    required TransferRepository transferRepository,
    required FileStorageService fileStorageService,
  })  : _transferRepository = transferRepository,
        _fileStorageService = fileStorageService {
    _tasksSub = _transferRepository.tasks.listen((tasks) {
      _tasks = tasks;
      notifyListeners();
    });
  }

  final TransferRepository _transferRepository;
  final FileStorageService _fileStorageService;
  final Logger _log = Logger('TransferViewModel');

  StreamSubscription<List<TransferTask>>? _tasksSub;

  List<TransferTask> _tasks = const [];
  String? _errorMessage;

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

  /// 选择文件并发送（受 AppConfig.allowedFileExtensions 限制）。
  Future<void> pickAndSendFiles() async {
    _errorMessage = null;
    notifyListeners();

    final List<PickedFile> picked = await _fileStorageService.pickFiles();
    if (picked.isEmpty) return;

    final result = await _transferRepository.sendFiles(picked);
    if (result is Error<void>) {
      _errorMessage = result.error.toString();
      _log.warning('发起发送失败：${result.error}');
      notifyListeners();
    }
  }

  /// 同意接收；[saveDirectory] 为空时由调用方先选择目录。
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

  /// 弹出目录选择后接收。
  Future<void> acceptWithDirectoryPicker(int fileId) async {
    final directory = await _fileStorageService.pickDirectory();
    if (directory == null) return; // 用户取消选择
    await accept(fileId, saveDirectory: directory);
  }

  /// 直接接收到默认目录（下载目录）。
  Future<void> acceptToDefaultDirectory(int fileId) =>
      accept(fileId);

  Future<void> reject(int fileId) => _transferRepository.reject(fileId);

  Future<void> cancel(int fileId) => _transferRepository.cancel(fileId);

  @override
  void dispose() {
    _tasksSub?.cancel();
    super.dispose();
  }
}
