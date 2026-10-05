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

/// 一次「接收 / 拒绝」决定的快照。
///
/// 存在的原因：决定与执行之间可能隔着一个很长的 await（典型是目录选择框，
/// 用户要翻好几层文件夹）。这段时间里任务列表会变——对方又发来新文件、
/// 或者干脆换了另一台设备连过来。执行时若重新读一次「当前勾选了谁」，
/// 就会把用户从没确认过的文件一起收下。
///
/// 因此打开选择框**之前**就把它冻下来，回来只认这份快照。
class OfferDecision {
  const OfferDecision({
    required this.picked,
    required this.dropped,
    required this.session,
  });

  /// 用户勾选、要接收的文件 id。
  final List<int> picked;

  /// 没勾选、要显式拒绝的文件 id。
  final List<int> dropped;

  /// 冻结决定时的会话标识；执行时会话不一致则整批作废。
  final String session;
}

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
      _syncOfferSelection();
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

  /// 待接收面板里被勾选的文件 id。
  ///
  /// 新到的请求默认勾上（最常见的操作就是「全收」），用户取消勾选的
  /// 那几个保持未勾选；已经不在待接收列表里的 id 会被自动清掉，
  /// 免得勾选状态越积越多、最后对不上任何文件。
  final Set<int> _selectedOfferIds = <int>{};

  /// 已经出现过、且已经走过一次「默认勾选」的待接收 id。
  ///
  /// 任务列表每秒会推送十次（其它文件的进度变化、新请求到达都会触发），
  /// [_syncOfferSelection] 也随之被调用十次。若它每次都把「所有待接收
  /// 的 id」加回勾选集合，用户在等待期间取消勾选的那几个会被悄悄勾回来
  /// ——最终收到的文件里就有他明确不想收的那几个。
  ///
  /// 因此默认勾选只作用于**第一次见到**的请求：见过的 id 一律不再自动
  /// 勾选，勾不勾完全由用户说了算。
  final Set<int> _seenOfferIds = <int>{};

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

  /// 待接收的个数。
  int get pendingOfferCount => pendingOffers.length;

  /// 待接收面板的「结构指纹」：只在待接收集合**或勾选状态**变化时改变。
  ///
  /// 不能只监听 [taskSignature]：那个指纹里只有 id，勾选变了它不变，
  /// 界面上的复选框就会点不动。
  String get offerSelectionSignature => pendingOffers
      .map((task) => '${task.id}:${_selectedOfferIds.contains(task.id) ? 1 : 0}')
      .join('|');

  /// 勾选了多少个待接收文件。
  int get selectedOfferCount => _selectedOfferIds.length;

  /// 是否**所有**待接收文件都被勾上了（用于「全选 / 取消全选」的切换）。
  bool get allOffersSelected {
    final offers = pendingOffers;
    return offers.isNotEmpty && _selectedOfferIds.length >= offers.length;
  }

  /// 某个待接收文件是否被勾上。
  bool isOfferSelected(int fileId) => _selectedOfferIds.contains(fileId);

  /// 勾选的文件总大小（界面上「接收 N 个 · 共 xxx」用）。
  int get selectedOfferBytes => pendingOffers
      .where((task) => _selectedOfferIds.contains(task.id))
      .fold<int>(0, (sum, task) => sum + task.totalBytes);

  /// 同时传输的文件数上限（要明明白白告诉用户，见 [concurrencyHint]）。
  int get maxConcurrentTransfers => AppConfig.maxConcurrentTransfers;

  /// 并发上限的界面文案。
  ///
  /// 不写出来的话，用户看到「点了 10 个接收、只动了 3 个」会以为卡住了。
  String get concurrencyHint =>
      '最多同时传输 $maxConcurrentTransfers 个，其余自动排队';

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

  /// 支持的文件类型概览（界面提示用，避免罗列上百个扩展名）。
  String get allowedText => AppConfig.allowedSummary;

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

  /// 选择文件前确认（受 AppConfig.allowedFileExtensions 限制）。
  ///
  /// 注意这里**不发送**：发送前要不要再问一句由上层决定
  /// （见 [sendFiles] 与「发送前确认」设置）。拆开之后，
  /// 「选文件的校验」与「真的把文件交出去」这两件事可以分别验证。
  Future<({List<PickedFile> accepted, List<String> ignored})>
      pickFiles() async {
    _errorMessage = null;
    notifyListeners();
    return _transferRepository.pickFilesToSend();
  }

  /// 把拖拽进来的路径转成可发送的文件；不支持的类型会被忽略。
  Future<({List<PickedFile> accepted, List<String> ignored})> filesFromPaths(
    List<String> paths,
  ) async {
    _errorMessage = null;
    notifyListeners();
    return _transferRepository.filesFromPaths(paths);
  }

  /// 真的把文件交出去。
  Future<void> sendFiles(List<PickedFile> files) async {
    if (files.isEmpty) return;

    final result = await _transferRepository.sendFiles(files);
    if (result is Error<void>) {
      _errorMessage = result.error.toString();
      _log.warning('发起发送失败：${result.error}');
      notifyListeners();
    }
  }

  /// 统一给出「发起了几个、忽略了几个」的一次性提示。
  void reportResult(int acceptedCount, int ignoredCount) {
    final ignoredHint =
        ignoredCount == 0 ? '' : '，已忽略 $ignoredCount 个不支持的项';
    _lastMessage = '已发起 $acceptedCount 个文件$ignoredHint';
    notifyListeners();
  }

  /// 重新发送一个失败的文件。
  ///
  /// 失败原因往往是一行很长的系统错误，先把它从错误条里收掉——
  /// 重发的任务已经有自己的卡片和进度条，不需要再挂一条过期的报错。
  Future<void> retry(int fileId) async {
    final message = _errorMessage;
    if (message != null) _dismissedErrors.add(message);
    _errorMessage = null;
    notifyListeners();

    final task = taskById(fileId);
    final name = task?.fileName;

    final result = await _transferRepository.retry(fileId);
    if (result is Error<int>) {
      _errorMessage = result.error.toString();
      _log.warning('重新发送失败：${result.error}');
      notifyListeners();
      return;
    }

    // 旧任务已经不存在了，别再拿它的状态去重放历史。
    _recordedStatus.remove(fileId);
    _lastMessage = name == null ? '已重新发送' : '已重新发送「$name」';
    notifyListeners();
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

  // ---------- 待接收面板：勾选与批量处理 ----------

  /// 勾选/取消勾选一个待接收文件。
  void toggleOfferSelection(int fileId) {
    if (!_selectedOfferIds.remove(fileId)) {
      _selectedOfferIds.add(fileId);
    }
    notifyListeners();
  }

  /// 全选 / 取消全选（当前已经是全选时就全部取消）。
  void toggleSelectAllOffers() {
    if (allOffersSelected) {
      _selectedOfferIds.clear();
    } else {
      _selectedOfferIds.addAll(pendingOffers.map((task) => task.id));
    }
    notifyListeners();
  }

  /// 接收勾上的文件；[saveDirectory] 为空时落到当前保存目录。
  ///
  /// [decision] 是「这一次要处理谁」的快照，默认现取一份。需要弹目录
  /// 选择框时必须先冻结再传进来（见 [acceptSelectedWithDirectoryPicker]）。
  ///
  /// 没勾上的那些会**同时被显式拒绝**：发送端为每个请求都挂着一个
  /// 两分钟的计时器，放着不管的话对方要干等满 120 秒才知道你不收。
  Future<void> acceptSelected({
    String? saveDirectory,
    OfferDecision? decision,
  }) async {
    final plan = decision ?? freezeOfferDecision();

    // 会话换了就整批作废。旧请求早已随上一通会话一起收尾，
    // 再拿它们的 fileId 去发拒绝帧，等于给**新**对端发了一串它
    // 根本没见过的 id；新到的请求也还没经过用户确认，不能顺手收下。
    if (_transferRepository.sessionId != plan.session) {
      _errorMessage = '设备连接已切换，请重新确认要接收的文件';
      notifyListeners();
      return;
    }

    // 只处理「还待接收、且仍属于这条会话」的那几个。
    final picked = _stillWaiting(plan.picked, plan.session);
    final dropped = _stillWaiting(plan.dropped, plan.session);

    // 只摘掉这次处理掉的那些：期间新到的请求保持用户（或默认勾选）
    // 的状态，等他下一次决定，而不是被一并清空。
    final handled = <int>{...picked, ...dropped};
    _selectedOfferIds.removeWhere(handled.contains);
    notifyListeners();

    if (dropped.isNotEmpty) {
      await _transferRepository.rejectMany(dropped);
    }
    if (picked.isEmpty) {
      if (dropped.isNotEmpty) _lastMessage = '已拒绝 ${dropped.length} 个文件';
      notifyListeners();
      return;
    }

    final result = await _transferRepository.acceptMany(
      picked,
      saveDirectory: saveDirectory,
    );
    switch (result) {
      case Error<int>():
        _errorMessage = result.error.toString();
        _log.warning('批量接收失败：${result.error}');
      case Ok<int>(value: final accepted):
        // 报**实际接下的**数量：目录检查与逐文件准备都是 await，
        // 期间断连或换设备时后面的文件根本没处理，
        // 照着请求数报「已接收 10 个」是骗人。
        final rejected = dropped.isEmpty ? '' : '，拒绝 ${dropped.length} 个';
        _lastMessage = '已接收 $accepted 个文件$rejected';
    }
    notifyListeners();
  }

  /// 把「这次要接收谁、拒绝谁」冻成一份快照。
  ///
  /// 弹目录选择框要等用户翻好几层文件夹，这期间任务列表早就变了：
  /// 对方又发来新文件（新请求默认勾上），甚至换了另一台设备连过来。
  /// 若等选完目录再读一次「当前勾选了谁」，就会把用户从没见过的
  /// 文件一起收下——他以为自己只确认了刚才那几个。
  OfferDecision freezeOfferDecision() {
    final offers = pendingOffers;
    return OfferDecision(
      picked: <int>[
        for (final task in offers)
          if (_selectedOfferIds.contains(task.id)) task.id,
      ],
      dropped: <int>[
        for (final task in offers)
          if (!_selectedOfferIds.contains(task.id)) task.id,
      ],
      session: _transferRepository.sessionId,
    );
  }

  /// 从 [ids] 里筛出「仍待接收、且还属于这条会话」的那些。
  ///
  /// 期间被用户取消、被看护判失败、或者会话已经换人的，都不在结果里。
  List<int> _stillWaiting(Iterable<int> ids, String session) {
    final byId = <int, TransferTask>{
      for (final task in pendingOffers) task.id: task,
    };
    return <int>[
      for (final id in ids)
        if (byId[id]?.sessionId == session) id,
    ];
  }

  /// 弹出目录选择后接收勾选的文件（会顺带记住该目录）。
  Future<void> acceptSelectedWithDirectoryPicker() async {
    // 先冻结、再开选择框：翻文件夹的这几十秒里，任务列表会变。
    // 顺序反过来的话，「存到…」就可能收下用户没有确认过的新文件。
    final plan = freezeOfferDecision();
    final directory = await _transferRepository.pickSaveDirectory(
      dialogTitle: '选择这批文件的保存位置',
    );
    if (directory == null) return; // 用户取消选择
    await _transferRepository.rememberSaveDirectory(directory);
    _saveDirectory = directory;
    notifyListeners();
    await acceptSelected(saveDirectory: directory, decision: plan);
  }

  /// 把待接收列表里剩下的全部拒绝（面板上的「全部拒绝」）。
  Future<void> rejectPending() async {
    final offers = pendingOffers;
    if (offers.isEmpty) return;

    final ids = offers.map((task) => task.id).toList(growable: false);
    _selectedOfferIds.clear();
    notifyListeners();

    await _transferRepository.rejectMany(ids);
    _lastMessage = '已拒绝 ${ids.length} 个文件';
    notifyListeners();
  }

  /// 让勾选状态跟待接收列表对齐：新到的默认勾上，已处理的自动剔除。
  ///
  /// 返回是否有变化（供调用方决定要不要 [notifyListeners]）。
  bool _syncOfferSelection() {
    final pendingIds = <int>{
      for (final task in _tasks)
        if (task.direction == TransferDirection.receiving &&
            task.status == TransferStatus.waiting)
          task.id,
    };

    final before = _selectedOfferIds.length;
    _selectedOfferIds.removeWhere((id) => !pendingIds.contains(id));
    var changed = _selectedOfferIds.length != before;

    // 默认勾选只给**第一次见到**的请求：见过的（无论用户是留着还是
    // 取消了勾选）一律不再自动加回，否则用户在等待期间取消勾选的那几个
    // 会被下一次任务推送勾回来，最后收到他明确不想收的文件。
    for (final id in pendingIds) {
      if (_seenOfferIds.add(id) && _selectedOfferIds.add(id)) changed = true;
    }

    // 已经不待接收的 id 从「见过」里删掉：集合不会无限增长，
    // 同一个 fileId 若将来再次出现，也应当重新默认勾上。
    _seenOfferIds.removeWhere((id) => !pendingIds.contains(id));
    return changed;
  }

  @override
  void dispose() {
    _tasksSub?.cancel();
    super.dispose();
  }
}
