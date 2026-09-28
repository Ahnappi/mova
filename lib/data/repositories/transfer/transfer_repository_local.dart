import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../../../config/app_config.dart';
import '../../../domain/models/chat/connection_status.dart';
import '../../../domain/models/transfer/picked_file.dart';
import '../../../domain/models/transfer/transfer_event.dart';
import '../../../domain/models/transfer/transfer_task.dart';
import '../../../utils/result.dart';
import '../../services/chat/chat_transport_service.dart';
import '../../services/transfer/file_storage_service.dart';
import '../../services/transfer/incoming_file_writer.dart';
import 'transfer_repository.dart';

/// 文件传输仓储的本地（TCP 直连）实现。
///
/// 职责：把「协议事件」翻译成「任务与进度」，落盘/读盘交给 Service 层。
///
/// 六条容易踩坑、这里专门处理过的规则：
///
/// 1. **超时分两类**（见 [_checkTimeouts]）。等对方点接收用
///    [AppConfig.offerResponseTimeout]；传输过程中卡住用
///    [AppConfig.transferStallTimeout]，判据是字节数有没有变化。
///    正常传大文件再久也不会被判超时。
/// 2. **「发完」不等于「对方收到了」**。发送端推完流后进入
///    [TransferStatus.confirming]，等接收端核对字节数与 CRC32、
///    临时文件改名成功后回执，才标记完成（见 [_startSending] / [_onEnd]）。
///    发送操作返回后还会**统一复核一次**（会话没换、任务没终结、没有取消
///    请求），否则不发结束帧：最后一次 flush 期间点下的取消不能失效。
/// 3. **接收路径只落在用户选的目录里**。文件名来自对端，必须先清洗再拼接，
///    由 [FileStorageService.resolveTargetPath] 保证写入位置不越界。
/// 4. **任务按会话隔离**。换一台设备连接就清空上一次的残留，
///    连接、解析缓冲、消息与任务都绑定当前会话（见 [_onStatus]）。
///    发送循环还额外绑定「发起时的 socket 与会话」，旧循环不会把数据
///    写进新连接（见 [_startSending]）。
/// 5. **准备接收是可撤销的**。选目录、探测权限、建临时文件都跨 await，
///    期间可能取消/断连/重复点击，因此用 [TransferStatus.preparing]
///    占位防重入，每个 await 回来核对归属，失效就清理本次建的文件
///    （见 [accept]）。
/// 6. **提交（临时文件改名）有明确边界，且不覆盖已有文件**。提交前可取消，
///    提交中与取消串行（取消等它落地），提交后统一按「取消优先」处理——
///    绝不会出现「界面显示已取消、目录里却躺着完整文件」（见 [_onEnd]）。
///    「先挑空名字再改名」挡不住并发占用，「先独占占位再改名」也挡不住
///    （占位之后那条路径照样可能被别人替换）。因此不覆盖的保证放在
///    [FileStorageService.commitTempFile]：它由操作系统用**一次原子调用**
///    完成「检查 + 创建」，目标被占用时换名字重试，拿不到这个能力就
///    明确失败——绝不退回会覆盖已有文件的普通改名。
/// 7. **已经终结的任务不会再被改写**。推流/收尾/回执的异步结果回来时
///    都会重新核对，任务若已被取消、超时或断连终结，后来的结果一律作废
///    （见 [_finish]）。
/// 8. **清理只认调用开始时捕获的状态**。作废一次接收时，删哪些文件一律
///    以 [_IncomingState] 里记下的路径为准，不回头查 [_tasks]——
///    连上新设备会清空任务表，若按任务表判断「还删不删」，
///    旧会话那几个 GB 的临时文件就会被留在用户目录里
///    （见 [_abortIncoming]）。
///
/// 大文件的安全性体现在三处：
/// - 读写都按块进行（[AppConfig.fileChunkSize]），从不整体载入内存；
/// - 发送端 socket 有背压，接收端落盘在后台 isolate 且有有界队列；
/// - 帧解析自己维护缓冲，避免随文件增大而线性增长的拷贝。
class TransferRepositoryLocal implements TransferRepository {
  /// [offerTimeout] / [stallTimeout] / [ackTimeout] 可被测试覆盖，
  /// 默认是 [AppConfig] 里的值（真实场景是分钟级，测试里等不起）。
  TransferRepositoryLocal(
    this._transport,
    this._storage, {
    IncomingFileWriter? writer,
    Duration? offerTimeout,
    Duration? stallTimeout,
    Duration? ackTimeout,
  })  : _writer = writer ?? IncomingFileWriter(),
        _offerTimeout = offerTimeout ?? AppConfig.offerResponseTimeout,
        _stallTimeout = stallTimeout ?? AppConfig.transferStallTimeout,
        _ackTimeout = ackTimeout ?? AppConfig.transferAckTimeout {
    _eventSub = _transport.transferEvents.listen(
      _onEvent,
      onError: (Object error) => _log.warning('传输事件异常：$error'),
    );
    _statusSub = _transport.status.listen(_onStatus);
    _writer.onWriteAck = _onWriteAck;
    _writer.onError = _onWriteError;
    // 会话标识直接取当前连接：仓储完全可能在连接**已经建立之后**才创建
    // （测试里常见），那时不会再收到 connected 事件，若留成空串，
    // 「会话绑定」的校验会把正常发送误判成「连接已切换」。
    _sessionId = _transport.sessionId ?? '';
    unawaited(_writer.start());
    // 看护计时器：统一处理「等对端应答」「传输停滞」「等回执」三类超时。
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) => _checkTimeouts());
  }

  /// 后台写盘失败：立刻终结这个任务，并解除可能的背压暂停
  /// （否则 socket 会一直停读，后续什么也收不到）。
  void _onWriteError(int fileId, Object error) {
    final task = _tasks[fileId];
    if (task == null || task.isFinished) return;

    _log.warning('文件 $fileId 落盘失败：$error');
    _applyBackpressure();
    unawaited(_abortIncoming(fileId, deletePartial: true));
    _transport.sendFileCancel(fileId, reason: '写盘失败');
    _finish(fileId, TransferStatus.failed, error: '写盘失败：$error');
  }

  final ChatTransportService _transport;
  final FileStorageService _storage;
  final IncomingFileWriter _writer;
  final Logger _log = Logger('TransferRepositoryLocal');

  final Duration _offerTimeout;
  final Duration _stallTimeout;
  final Duration _ackTimeout;

  final Map<int, TransferTask> _tasks = <int, TransferTask>{};
  final Map<int, _IncomingState> _incoming = <int, _IncomingState>{};

  /// 正在「准备接收」的任务（[accept] 里那些 await 还没走完的）。
  ///
  /// 准备期间还没有 [_incoming] 登记，但可能已经建好了临时文件，
  /// 因此单独记录：取消/断连时靠它作废这次准备，
  /// 临时文件由 [accept] 自己收尾（谁创建谁清理，避免两边都删或都漏）。
  final Map<int, _PrepareState> _preparing = <int, _PrepareState>{};

  /// 准备令牌：区分「同一次准备」，防止迟到的准备结果覆盖新的流程。
  int _prepareToken = 0;

  final Map<int, _SpeedState> _speedStates = <int, _SpeedState>{};
  final Map<int, Completer<void>> _finishWaiters = <int, Completer<void>>{};
  final Map<int, Completer<void>> _ackWaiters = <int, Completer<void>>{};
  final Map<int, DateTime> _waitingSince = <int, DateTime>{};
  final Map<int, DateTime> _lastProgressAt = <int, DateTime>{};
  final Set<int> _cancelRequests = <int>{};

  final List<_QueuedSend> _queue = <_QueuedSend>[];
  bool _pumping = false;

  /// 是否已暂停读取 socket（接收端背压）。
  bool _paused = false;

  /// 当前会话标识；换设备连接时会整体重置。
  String _sessionId = '';

  final Random _random = Random();
  final StreamController<List<TransferTask>> _controller =
      StreamController<List<TransferTask>>.broadcast();

  StreamSubscription<TransferEvent>? _eventSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  Timer? _watchdog;
  DateTime? _lastEmit;

  @override
  Stream<List<TransferTask>> get tasks => _controller.stream;

  @override
  List<TransferTask> get currentTasks =>
      List<TransferTask>.unmodifiable(_tasks.values);

  // ---------- 发送 ----------

  @override
  Future<Result<void>> sendFiles(List<PickedFile> files) async {
    if (files.isEmpty) return Result.ok(null);

    for (final file in files) {
      final id = _newId();
      _tasks[id] = TransferTask(
        id: id,
        fileName: file.name,
        totalBytes: file.size,
        direction: TransferDirection.sending,
        // 先排队：只有真正把请求发出去的那个才进入 waiting 并开始计时，
        // 否则后面的文件会在还没轮到时就被判成「对方没有响应」。
        status: TransferStatus.queued,
        createdAt: DateTime.now(),
        localPath: file.path,
        sessionId: _sessionId,
      );
      _queue.add(_QueuedSend(id: id, file: file));
    }
    _emit(force: true);
    unawaited(_pumpQueue());
    return Result.ok(null);
  }

  /// 串行处理发送队列：一次只向对端提一个请求，等它终结再提下一个。
  Future<void> _pumpQueue() async {
    if (_pumping) return;
    _pumping = true;

    // 必须有 finally：中途抛异常若把 _pumping 留在 true，
    // 之后的每一次发送都会被当成「队列正在处理」而永远发不出去。
    try {
      while (_queue.isNotEmpty) {
        final item = _queue.removeAt(0);
        final task = _tasks[item.id];
        if (task == null || !task.isActive) continue;

        // 从这里开始，对端才知道有这个文件——「等对端应答」的计时
        // 也只能从这里开始（排队中的任务不计时，见 [_checkTimeouts]）。
        final now = DateTime.now();
        _waitingSince[item.id] = now;
        _lastProgressAt[item.id] = now;
        _update(item.id, status: TransferStatus.waiting);

        final offer = await _transport.sendFileOffer(
          fileId: item.id,
          name: item.file.name,
          size: item.file.size,
        );
        if (offer is Error<void>) {
          _finish(item.id, TransferStatus.failed, error: offer.error.toString());
          continue;
        }

        // 这里不再加超时：超时由 _checkTimeouts 按「等待应答 / 传输停滞」
        // 分别判断。早先在这里统一加 120 秒，导致正常传输大文件超过两分钟
        // 也会被判成「对方未响应」。
        await _waitForFinish(item.id);
      }
    } finally {
      _pumping = false;
    }
  }

  /// 这个任务现在是否可以开始推流。
  ///
  /// 必须同时满足：是我们发出的、属于当前会话、确实已向对端发出过请求
  /// （[TransferStatus.waiting]，而不是还在排队的 [TransferStatus.queued]）、
  /// 并且还没有终结。任一条不满足，这个「同意」就是迟到的或伪造的。
  bool _canStartSending(TransferTask? task) {
    if (task == null) return false;
    if (task.direction != TransferDirection.sending) return false;
    if (task.status != TransferStatus.waiting) return false;
    if (task.sessionId != _sessionId) return false;
    return !task.isFinished;
  }

  /// 等待某个发送任务终结。
  ///
  /// 队列靠它串行；真正让它结束的是任务终结（成功/失败/取消/回执）或看护计时器。
  Future<void> _waitForFinish(int id) {
    final completer = Completer<void>();
    _finishWaiters[id] = completer;
    return completer.future;
  }

  /// 对端同意后，真正开始推流；推完还要等对端回执。
  ///
  /// 入口处必须完整核对一次任务身份：同意帧可能是一次**迟到的**应答
  /// （我们已经取消/超时/切换会话之后才到）。少了这些检查，
  /// 会出现「你已经取消，对方随后点接收，文件照样发出去」。
  Future<void> _startSending(int id) async {
    final task = _tasks[id];
    if (!_canStartSending(task)) return;
    final path = task!.localPath;
    if (path == null) return;

    // 整次发送都绑定「发起时的会话」：传输过程中若断连并连上了另一台
    // 设备，旧循环既不能继续写数据，也不能给新设备补一个结束帧。
    // （[_canStartSending] 已保证 task.sessionId 与当前会话一致。）
    final session = _sessionId;

    _update(id, status: TransferStatus.transferring, transferredBytes: 0);

    final result = await _transport.sendFileStream(
      fileId: id,
      path: path,
      // 拿最初声明的大小对账：源文件在传输期间被截短时，
      // 读循环会提前 EOF，若不比对就会把不完整的文件当成发完了。
      expectedSize: task.totalBytes,
      session: session,
      onProgress: (sent) => _updateProgress(id, sent),
      // 新会话会清空 _cancelRequests，所以停止信号不能只依赖它：
      // 会话一变，旧循环必须立刻停下来。
      isCancelled: () => _cancelRequests.contains(id) || _sessionId != session,
    );

    // 不管成功失败都要清掉取消标记，否则下一次同名任务会被误判为已取消。
    final canceled = _cancelRequests.remove(id);

    // 会话已经换人：任务表早被新会话清空，这里一个字都不能再改，
    // 更不能给新设备补结束帧或取消帧。
    if (_sessionId != session) return;

    // ---- 发送操作返回后的统一复核 ----
    //
    // 从「最后一块写出」到这里的每一步都跨着 await（最后一次 flush、
    // 结果回调），期间用户可能点了取消、对端可能取消、看护计时器也可能
    // 已经判停滞而终结任务。少了这一步会有两个后果：
    // - 取消失效：文件照样发完、结束帧照样发出；
    // - 迟到的成功结果把已经终结的任务重新改成 confirming。
    // 因此这里只认「原会话仍有效 + 任务还没终结 + 没有取消请求」这一种
    // 情况，其余一律按取消/作废处理，绝不发结束帧。
    final current = _tasks[id];
    if (current == null || current.isFinished) return;

    if (canceled || _cancelRequests.contains(id)) {
      _finish(id, TransferStatus.canceled);
      // 数据块已经发给对端一部分了：必须明确告诉它丢弃，
      // 否则它会一直等一个永远不来的结束帧。
      _transport.sendFileCancel(id, reason: '发送方取消', session: session);
      return;
    }

    if (result is Error<SentFileSummary>) {
      _finish(
        id,
        canceled ? TransferStatus.canceled : TransferStatus.failed,
        error: canceled ? null : result.error.toString(),
      );
      // 失败也要通知对端：它正在等结束帧，不知道我们已经放弃了。
      _transport.sendFileCancel(
        id,
        reason: canceled ? '发送方取消' : '发送失败',
        session: session,
      );
      return;
    }

    final summary = (result as Ok<SentFileSummary>).value;
    _lastProgressAt[id] = DateTime.now();

    // 声明「我发完了，一共这么多字节、校验值是这个」，交给对端核对。
    _transport.sendFileEnd(
      id,
      size: summary.bytes,
      checksum: summary.checksum,
      session: session,
    );

    // 老版本对端不认识回执帧，等下去只会白等一个超时。
    if (_transport.remoteProtocolVersion < AppConfig.receiptProtocolVersion) {
      _finish(id, TransferStatus.completed);
      return;
    }

    _update(id, status: TransferStatus.confirming);
    await _waitForAck(id);
  }

  /// 等待接收端回执；等不到就按失败处理，并明确告知原因。
  Future<void> _waitForAck(int id) {
    final completer = Completer<void>();
    _ackWaiters[id] = completer;
    return completer.future.timeout(
      _ackTimeout,
      onTimeout: () {
        _ackWaiters.remove(id);
        final task = _tasks[id];
        if (task != null && task.isActive) {
          _finish(
            id,
            TransferStatus.failed,
            error: '已发送完毕，但没有收到对方的接收确认（超时）。'
                '文件可能未完整保存，建议重新发送。',
          );
        }
      },
    );
  }

  // ---------- 文件选取与保存位置 ----------

  @override
  Future<({List<PickedFile> accepted, List<String> ignored})>
      pickFilesToSend() => _storage.pickFiles();

  @override
  Future<({List<PickedFile> accepted, List<String> ignored})> filesFromPaths(
    List<String> paths,
  ) =>
      _storage.filesFromPaths(paths);

  @override
  Future<String> currentSaveDirectory() => _storage.currentSaveDirectory();

  @override
  Future<String?> pickSaveDirectory({String? dialogTitle}) =>
      _storage.pickDirectory(dialogTitle: dialogTitle);

  @override
  Future<void> rememberSaveDirectory(String directory) =>
      _storage.rememberSaveDirectory(directory);

  // ---------- 接收 ----------

  /// 同意接收一个文件：选目录 → 探测权限 → 建临时文件 → 通知对端开始。
  ///
  /// 中间每一步都是 await，期间对端可能取消、连接可能断开、用户可能
  /// 又点了一次「接收」。因此这里有三道防线：
  /// 1. **第一个 await 之前**就切到 [TransferStatus.preparing]，
  ///    重复点击会看到这个状态而被挡回去，不会两次为同一个 fileId
  ///    打开临时文件、互相覆盖句柄；
  /// 2. 每次 await 回来都用 [_isPrepareAlive] 核对「会话没换、
  ///    令牌还是我、任务还活着」，失效就直接放弃本次准备；
  /// 3. `finally` 统一清理**本次准备创建的**临时文件，
  ///    避免取消后留下一个永远不会有人接手的 `.mova-part`。
  @override
  Future<Result<void>> accept(int fileId, {String? saveDirectory}) async {
    final task = _tasks[fileId];
    if (task == null ||
        task.direction != TransferDirection.receiving ||
        task.status != TransferStatus.waiting ||
        task.sessionId != _sessionId) {
      return Result.error(Exception('该接收请求已失效'));
    }

    final session = _sessionId;
    final token = ++_prepareToken;
    final prepare = _PrepareState(token);
    _preparing[fileId] = prepare;
    // 必须放在第一个 await **之前**：否则重复点击会在准备还在进行时
    // 再次进入，为同一个 fileId 打开第二个临时文件、覆盖掉前一个句柄。
    _update(fileId, status: TransferStatus.preparing);

    try {
      final directory = saveDirectory ?? await _storage.currentSaveDirectory();
      if (!_isPrepareAlive(fileId, token, session)) return _prepareAborted();

      // 目录可能已被移动或删除，先补建一次。
      try {
        await _storage.ensureDirectory(directory);
      } catch (e) {
        final message = '无法创建保存目录 $directory：$e';
        return _failPrepare(fileId, token, session, message);
      }
      if (!_isPrepareAlive(fileId, token, session)) return _prepareAborted();

      // 先确认写得进去：macOS 对桌面/文档/下载有系统权限保护（即使没有沙箱），
      // 被拒绝时只有在真正落盘那一刻才报错。提前探测可以把问题挡在传输之前，
      // 免得几 GB 的文件传完了才说写不进去。
      if (!await _storage.isWritableDirectory(directory)) {
        final hint = '没有写入「$directory」的权限，请在系统'
            '「隐私与安全性 → 文件与文件夹」中允许 mova，或换一个保存位置。';
        return _failPrepare(fileId, token, session, hint);
      }
      if (!_isPrepareAlive(fileId, token, session)) return _prepareAborted();

      // 文件名来自对端：清洗 + 限制在保存目录内都在这里完成。
      final target = await _storage.resolveTargetPath(directory, task.fileName);
      if (!_isPrepareAlive(fileId, token, session)) return _prepareAborted();

      // 先用临时名落盘，核对无误后才改成正式名，
      // 免得半成品被当成完整文件打开。
      //
      // 临时名是每次现生成的，并且以独占方式创建：目录里若已有同名残留
      // （上次崩溃留下的，或另一次同名接收正在写），绝不覆盖它，换名字重试。
      String? temp;
      Object? openError;
      for (var attempt = 0; attempt < 8; attempt++) {
        final candidate = _storage.tempPathFor(directory, p.basename(target));
        try {
          await _writer.open(fileId, candidate, exclusive: true);
          temp = candidate;
          prepare.tempPath = candidate;
          break;
        } catch (e) {
          openError = e;
        }
      }
      if (temp == null) {
        return _failPrepare(
          fileId,
          token,
          session,
          '无法创建临时文件：$openError',
        );
      }

      // 提交方式要**提前**确认：等到几个 GB 都传完了才发现这个目录不支持
      // 「不覆盖的原子提交」（exFAT/FAT 等文件系统不支持硬链接），
      // 那才是真的浪费。早失败、早换目录。
      if (!await _storage.supportsAtomicCommit(directory)) {
        return _failPrepare(
          fileId,
          token,
          session,
          '「$directory」不支持安全的原子保存（该文件系统可能不支持硬链接，'
          '例如 exFAT/FAT），请换一个保存位置后重新接收。',
        );
      }
      if (!_isPrepareAlive(fileId, token, session)) return _prepareAborted();

      // 最后一次核对：准备期间完全可能被取消、断连或切换会话。
      if (!_isPrepareAlive(fileId, token, session)) return _prepareAborted();

      _preparing.remove(fileId);
      _incoming[fileId] = _IncomingState(finalPath: target, tempPath: temp);
      _lastProgressAt[fileId] = DateTime.now();

      _update(
        fileId,
        status: TransferStatus.transferring,
        localPath: target,
        transferredBytes: 0,
      );
      _transport.sendFileAccept(fileId);
      return Result.ok(null);
    } finally {
      // 只有「还是自己这一次准备」时才由这里收尾：
      // 成功路径已经把自己摘掉了，取消路径则等在这里把临时文件删干净。
      final mine = _preparing[fileId];
      if (mine != null && mine.token == token) {
        _preparing.remove(fileId);
        await _writer.abort(fileId).catchError((Object _) {});
        await _storage.deleteIfExists(prepare.tempPath);
        if (!mine.done.isCompleted) mine.done.complete();
      }
    }
  }

  /// 准备期间任务是否仍然「算数」。
  bool _isPrepareAlive(int fileId, int token, String session) {
    if (_sessionId != session) return false;
    final prepare = _preparing[fileId];
    if (prepare == null || prepare.token != token) return false;
    if (prepare.abandoned) return false;
    final task = _tasks[fileId];
    if (task == null || task.isFinished) return false;
    if (task.direction != TransferDirection.receiving) return false;
    return task.status == TransferStatus.preparing;
  }

  /// 准备已经被作废（取消/断连/切换会话）：本次结果一律丢弃。
  Result<void> _prepareAborted() =>
      Result.error(Exception('该接收请求已失效'));

  /// 准备期间出错：只在准备仍然有效时才把任务判失败。
  Result<void> _failPrepare(
    int fileId,
    int token,
    String session,
    String message,
  ) {
    if (_isPrepareAlive(fileId, token, session)) {
      _finish(fileId, TransferStatus.failed, error: message);
    }
    return Result.error(Exception(message));
  }

  /// 作废一次准备并**等它自己收尾**。
  ///
  /// 临时文件由 [accept] 创建，也只有它知道确切路径
  /// （可能刚发出 open 命令、还没拿到结果）。因此这里只打标记，
  /// 再等 prepare 的收尾完成，避免两边同时删、或者谁都不删。
  Future<void> _abortPreparing(int fileId) async {
    final prepare = _preparing[fileId];
    if (prepare == null) return;
    prepare.abandoned = true;
    await prepare.done.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
  }

  /// 只打标记、不等（断连、切会话这类批量场景用）：
  /// [accept] 的 finally 会负责清理它自己创建的文件。
  void _abandonPreparing(int fileId) {
    _preparing[fileId]?.abandoned = true;
  }

  @override
  Future<void> reject(int fileId) async {
    final task = _tasks[fileId];
    if (task == null || task.direction != TransferDirection.receiving) return;
    _transport.sendFileReject(fileId);
    _finish(fileId, TransferStatus.rejected);
  }

  // ---------- 取消 ----------

  @override
  Future<void> cancel(int fileId) async {
    final task = _tasks[fileId];
    if (task == null || !task.isActive) return;

    if (task.direction == TransferDirection.sending &&
        task.status == TransferStatus.queued) {
      // 还在排队（对端根本不知道它存在）：直接出队并终结，不需要通知谁。
      _queue.removeWhere((item) => item.id == fileId);
      _finish(fileId, TransferStatus.canceled);
      return;
    }

    if (task.direction == TransferDirection.sending &&
        task.status == TransferStatus.waiting) {
      // 请求已经发给对端了：除本地终结外，还必须通知对端撤销这个请求。
      // 否则对端稍后点「接收」，我们这边会重新开始推流——
      // 「你已经取消，文件却照样发出去」。
      _queue.removeWhere((item) => item.id == fileId);
      _transport.sendFileCancel(fileId, reason: '发送方取消');
      _finish(fileId, TransferStatus.canceled);
      return;
    }

    if (task.direction == TransferDirection.receiving) {
      // 准备期间（选目录/建临时文件）没有 _incoming 登记，
      // 但可能已经建好了临时文件：先作废旧准备，再走常规清理。
      await _abortPreparing(fileId);
      await _abortIncoming(fileId, deletePartial: true);
      _transport.sendFileCancel(fileId, reason: '接收方取消');
      _finish(fileId, TransferStatus.canceled);
      return;
    }
    // 已推完、正在等回执：数据已经在对端手里，只能请它丢弃。
    if (task.status == TransferStatus.confirming) {
      _transport.sendFileCancel(fileId, reason: '发送方取消');
      _finish(fileId, TransferStatus.canceled);
      return;
    }
    // 发送中的任务：打上停止标记，由推流循环在下一块前自行退出。
    _cancelRequests.add(fileId);
  }

  /// 作废一次接收并清理它落在磁盘上的东西。
  ///
  /// 清理只依赖**调用开始时捕获的那一份 [_IncomingState]**，不再回头查
  /// [_tasks]：后台 `abort` 与删除之间跨着 await，期间若连上了另一台设备，
  /// 新会话会把 [_tasks] 清空，等回来再按任务表判断「还删不删」，
  /// 就会因为「任务不存在」直接退出，把几个 GB 的 `.mova-part` 留在
  /// 用户目录里。路径在 state 里就已经够了，任务表说了什么都不影响清理。
  ///
  /// 没有 state 说明这不是一次接收（发送端任务没有临时文件），
  /// 也就没有任何半成品要清——发送端的 localPath 指向用户源文件，
  /// 删掉它是不可逆的数据丢失。
  Future<void> _abortIncoming(int id, {required bool deletePartial}) async {
    final state = _incoming.remove(id);
    if (state == null) return;

    // 与「提交（临时文件改名）」串行：正在提交时先等它落地。
    // 否则取消删掉临时文件、提交却随后成功，目录里就会留下一个
    // 界面显示为「已取消」的完整文件。
    await state.waitCommit();
    await _writer.abort(id).catchError((Object _) {});
    if (!deletePartial) return;

    // 先删已经落地的正式文件（提交可能在取消到达前后刚好完成），
    // 再删临时文件。
    await _storage.deleteIfExists(state.committedPath);
    await _storage.deleteIfExists(state.tempPath);
  }

  // ---------- 事件处理 ----------

  void _onEvent(TransferEvent event) {
    if (_isStaleEvent()) return;

    switch (event) {
      case OfferReceived():
        _tasks[event.fileId] = TransferTask(
          id: event.fileId,
          // 立刻清洗：对端给的名字可能带路径分隔符或 ..，
          // 界面上展示的也应该是真正会落盘的那个名字。
          fileName: _storage.sanitizeFileName(event.name),
          totalBytes: event.size,
          direction: TransferDirection.receiving,
          status: TransferStatus.waiting,
          createdAt: DateTime.now(),
          sessionId: _sessionId,
        );
        _emit(force: true);
      case AcceptReceived():
        _onAccept(event.fileId);
      case RejectReceived():
        _finish(event.fileId, TransferStatus.rejected, error: event.reason);
      case ChunkReceived():
        _onChunk(event.fileId, event.data);
      case EndReceived():
        unawaited(_onEnd(event.fileId, event.size, event.checksum));
      case CancelReceived():
        unawaited(_onCancel(event.fileId, event.reason));
      case DoneReceived():
        _onDone(event.fileId, event.ok, event.reason);
    }
  }

  /// 对端点了「接收」。
  ///
  /// 这一帧完全可能是**迟到的**：我们取消/超时之后对端才点下去。
  /// 早前的实现只检查「任务和路径还在不在」，于是取消之后对面一点接收，
  /// 文件照样发出去。现在先完整核对任务身份，不通过就回一条取消，
  /// 让对端把这个已经失效的请求撤掉。
  void _onAccept(int fileId) {
    final task = _tasks[fileId];
    if (task != null && !_canStartSending(task)) {
      _log.info('忽略迟到的接收同意：$fileId（当前状态 ${task.status.name}）');
      _transport.sendFileCancel(fileId, reason: '该发送请求已失效');
      return;
    }
    unawaited(_startSending(fileId));
  }

  /// 来自上一次会话的迟到事件：连接已经换人了，不能再改当前的任务。
  bool _isStaleEvent() {
    final current = _transport.sessionId;
    return current != null && _sessionId.isNotEmpty && current != _sessionId;
  }

  void _onChunk(int fileId, List<int> data) {
    final state = _incoming[fileId];
    final task = _tasks[fileId];
    if (state == null || task == null) return;
    // 已终结的任务还可能收到对端在途中发来的残留数据块，直接丢弃。
    if (task.isFinished) return;

    // 交给后台 isolate 写盘：这里只登记字节数，不做阻塞式 I/O。
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    _writer.write(fileId, bytes);
    state.receivedBytes += bytes.length;
    _updateProgress(fileId, state.receivedBytes);
    _applyBackpressure();
  }

  /// 接收端背压：待落盘数据积压到阈值就暂停读 socket，
  /// 让 TCP 的接收窗口去压住对端，而不是把数据都堆在内存里。
  void _applyBackpressure() {
    final pending = _writer.pendingBytes;
    if (!_paused && pending >= AppConfig.maxPendingWriteBytes) {
      _paused = true;
      _transport.pauseInbound();
      return;
    }
    // 留一段滞回区间，避免在阈值附近反复暂停/恢复。
    if (_paused && pending <= AppConfig.maxPendingWriteBytes ~/ 2) {
      _paused = false;
      _transport.resumeInbound();
    }
  }

  void _onWriteAck(int fileId, int bytes) => _applyBackpressure();

  /// 收到「发送完毕」：核对字节数与校验值 → 改名 → 回执。
  ///
  /// 收尾由好几个 await 串起来（等后台刷盘、挑一个空名字、改名），
  /// 这段时间里用户可能取消、连接可能断、会话可能切换。因此：
  /// 1. 收尾期间任务**仍然留在 [_incoming] 里**，让取消流程能找到临时文件；
  /// 2. 每个 await 之后都重新核对任务是否还「活着」，死掉就只清理、不提交。
  ///    少了这一步，取消之后收尾流程照样改名、照样发成功回执，
  ///    界面上却是「已取消」——用户看到的是一个不该存在的文件。
  Future<void> _onEnd(
    int fileId,
    int? declaredSize,
    int? declaredChecksum,
  ) async {
    final task = _tasks[fileId];
    if (task == null) return;
    // 文件已终结（被取消/已失败）后到达的 end 帧不再改状态。
    if (task.isFinished) return;

    final state = _incoming[fileId];
    if (state == null) {
      _finish(fileId, TransferStatus.failed, error: '接收已中断，无法收尾');
      return;
    }

    // 收尾期间不把状态从 _incoming 摘掉，而是记住「这一轮收尾属于哪个
    // 会话、哪个状态对象」，await 回来后逐条核对。
    final session = _sessionId;
    final expectedSize = task.totalBytes;
    // 刷盘这一段没有字节流动，别让停滞看护误判。
    _lastProgressAt[fileId] = DateTime.now();

    WriteSummary summary;
    try {
      // 命令在后台按序执行，这个结果一定包含此前所有数据块。
      summary = await _writer.close(fileId);
    } catch (e) {
      if (_isFinalizeVoid(fileId, state, session)) {
        await _storage.deleteIfExists(state.tempPath);
        return;
      }
      _incoming.remove(fileId);
      await _storage.deleteIfExists(state.tempPath);
      _transport.sendFileDone(
        fileId,
        ok: false,
        reason: '写盘失败：$e',
        session: session,
      );
      _finish(fileId, TransferStatus.failed, error: '收尾失败：$e');
      return;
    }

    final mismatch = _verify(
      summary: summary,
      declaredSize: declaredSize,
      declaredChecksum: declaredChecksum,
      expectedSize: expectedSize,
    );
    if (mismatch != null) {
      if (_isFinalizeVoid(fileId, state, session)) {
        await _storage.deleteIfExists(state.tempPath);
        return;
      }
      _incoming.remove(fileId);
      await _storage.deleteIfExists(state.tempPath);
      _transport.sendFileDone(fileId, ok: false, reason: mismatch, session: session);
      _finish(fileId, TransferStatus.failed, error: mismatch);
      return;
    }

    // ---- 提交边界 ----
    //
    // 改名是文件「正式交到用户手里」的那一步，取消必须围绕它定边界：
    // - 提交**前**可以取消：临时文件被删掉，改名自然失败；
    // - 提交**中**与取消串行：取消先等改名落地（见 _abortIncoming 的
    //   waitCommit），再把正式文件一起删掉；
    // - 提交**后**不再重新判定是否该保存：改完名立刻复核一次，
    //   若期间已被取消/断连/切会话，就按「取消优先」把文件删掉。
    // 只在改名前检查一次是不够的：取消可能正好落在改名那一次 await 上。
    //
    // 另外，「先挑一个空名字、再改名」并不能保证不覆盖：两者之间隔着
    // await，用户（或另一次接收）完全可能在这个窗口里放一个同名文件
    // 进来。因此不覆盖的保证放在 [FileStorageService.commitTempFile]
    // ——它独占占位，冲突时返回 [CommitTargetTaken]，我们换名字重试。
    var candidate = state.finalPath;
    String? renamed;
    Object? commitError;

    state.beginCommit();
    try {
      for (var attempt = 0; attempt < 8; attempt++) {
        // 每次提交前都再核对一次。
        if (_isFinalizeVoid(fileId, state, session)) break;

        final outcome = await _storage.commitTempFile(state.tempPath, candidate);
        switch (outcome) {
          case CommitOk():
            renamed = outcome.path;
            state.committedPath = outcome.path;
          case CommitTargetTaken():
            // 名字在提交那一瞬间被占用了：换一个不冲突的名字再来一次，
            // 已有文件一个字节都不会被动过。
            candidate = await _storage.resolveTargetPath(
              p.dirname(state.finalPath),
              p.basename(state.finalPath),
            );
            continue;
          case CommitFailed():
            commitError = outcome.error;
        }
        break;
      }
    } finally {
      state.endCommit();
    }

    // 改名这一次 await 期间同样可能出事。
    if (_isFinalizeVoid(fileId, state, session)) {
      // 文件可能已经落地：必须删掉，绝不能留下「已取消却有完整文件」。
      await _storage.deleteIfExists(renamed);
      await _storage.deleteIfExists(state.tempPath);
      return;
    }

    if (commitError != null) {
      _incoming.remove(fileId);
      await _storage.deleteIfExists(state.tempPath);
      final reason = '保存失败：$commitError';
      _transport.sendFileDone(fileId, ok: false, reason: reason, session: session);
      _finish(fileId, TransferStatus.failed, error: reason);
      return;
    }

    if (renamed == null) {
      // 连续多次都被占用：目录里同名文件堆积（或有人一直在抢名字），
      // 与其无限重试不如明确失败。
      _incoming.remove(fileId);
      await _storage.deleteIfExists(state.tempPath);
      const reason = '保存位置反复被占用，未能保存该文件';
      _transport.sendFileDone(fileId, ok: false, reason: reason, session: session);
      _finish(fileId, TransferStatus.failed, error: reason);
      return;
    }

    _incoming.remove(fileId);
    _transport.sendFileDone(fileId, ok: true, session: session);
    _finish(fileId, TransferStatus.completed, localPath: renamed);
  }

  /// 收尾期间任务是否已经「作废」。
  ///
  /// 三种情况都意味着这次收尾结果不能再提交：被取消/已失败、
  /// 被 [_abortIncoming] 摘走（断连、切换会话、写盘出错），
  /// 或者会话已经换人了。此时只需清理临时文件，状态由取消流程决定。
  bool _isFinalizeVoid(int fileId, _IncomingState state, String session) {
    if (_sessionId != session) return true;
    if (!identical(_incoming[fileId], state)) return true;
    final task = _tasks[fileId];
    if (task == null || task.isFinished) return true;
    return false;
  }

  /// 核对落盘结果；没问题返回 null，有问题返回给用户看的原因。
  ///
  /// 三个数字都必须对上：
  /// - [expectedSize]：对端在 offer 里**最初声明**的大小；
  /// - [declaredSize]：对端在结束帧里声明的「我实际发了这么多」；
  /// - [summary.bytes]：我们真正落盘的字节数。
  ///
  /// 只比后两个是不够的：源文件若在传输途中被截短，发送端会如实地把
  /// 截短后的大小写进结束帧，两端一核对反而「一致」了。
  /// 老版本对端的结束帧不带大小（[declaredSize] 为 null），
  /// 此时退化为拿最初声明的大小对账，不再跳过检查。
  String? _verify({
    required WriteSummary summary,
    required int? declaredSize,
    required int? declaredChecksum,
    required int? expectedSize,
  }) {
    if (expectedSize != null &&
        declaredSize != null &&
        declaredSize != expectedSize) {
      return '文件大小前后不一致：对方发起时声明 $expectedSize 字节，'
          '完成时却声明 $declaredSize 字节。'
          '文件可能在传输中被改写，半成品已丢弃，请重新传输。';
    }

    // 结束帧没有大小（老协议）时，用最初声明的大小兜底。
    final expected = declaredSize ?? expectedSize;
    if (expected != null && summary.bytes != expected) {
      return '文件不完整：应为 $expected 字节，实际只保存了 '
          '${summary.bytes} 字节。半成品已丢弃，请重新传输。';
    }

    if (declaredChecksum != null &&
        summary.checksum != null &&
        declaredChecksum != summary.checksum) {
      return '内容校验不一致（CRC32 对不上），文件可能在传输中被改写。'
          '半成品已丢弃，请重新传输。';
    }
    return null;
  }

  void _onDone(int fileId, bool ok, String? reason) {
    final waiter = _ackWaiters.remove(fileId);
    if (waiter != null && !waiter.isCompleted) waiter.complete();

    final task = _tasks[fileId];
    if (task == null || task.isFinished) return;

    if (ok) {
      _finish(fileId, TransferStatus.completed);
    } else {
      _finish(
        fileId,
        TransferStatus.failed,
        error: reason ?? '对方未能完整保存该文件',
      );
    }
  }

  Future<void> _onCancel(int fileId, String? reason) async {
    final task = _tasks[fileId];
    if (task == null || task.isFinished) return;

    // 对方取消的是「我正在发送」的文件：立刻标记取消让推流循环停下来。
    // 少了这一步，发送端会把整个文件继续推完，这些残留数据块排在对端
    // socket 里，导致后续文件的请求帧要等它们传完才被解析——表现就是
    // 「取消一次之后，再发文件对端半天没反应」。
    if (task.direction == TransferDirection.sending) {
      // 只有真正在推流时才需要停止标记；还在等对端同意的话没有循环可读它。
      if (task.status == TransferStatus.transferring) {
        _cancelRequests.add(fileId);
      }
      _finish(fileId, TransferStatus.canceled, error: reason ?? '对方取消了传输');
      return;
    }

    // 准备接收期间对方取消：同样要先作废旧准备，再清理可能的临时文件。
    await _abortPreparing(fileId);
    await _abortIncoming(fileId, deletePartial: true);
    _finish(fileId, TransferStatus.canceled, error: reason ?? '对方取消了传输');
  }

  void _onStatus(ConnectionStatus status) {
    if (status == ConnectionStatus.connected) {
      // 新会话：上一次连接的残留全部作废。
      _onSessionStarted();
      return;
    }
    // 连接断了：所有进行中的任务标记失败，并把队列清空。
    for (final id in _tasks.keys.toList()) {
      final task = _tasks[id];
      if (task == null || !task.isActive) continue;
      // 只打标记：还在跑的 accept 会自己发现会话/状态变了并清理临时文件。
      _abandonPreparing(id);
      // 只有发送中的任务需要「停止推流」信号；接收侧没有循环，加了也无人读取。
      if (task.direction == TransferDirection.sending) _cancelRequests.add(id);
      unawaited(_abortIncoming(id, deletePartial: true));
      _finish(id, TransferStatus.failed, error: '连接已断开');
    }
    _queue.clear();
    _paused = false;
  }

  /// 换会话（换设备连接）时重置：任务、收发状态、队列全部清空。
  ///
  /// 不清的话，连上新设备后界面上还挂着上一台设备的消息与文件卡，
  /// 用户会以为是当前这台发来的。
  void _onSessionStarted() {
    _sessionId = _transport.sessionId ?? '';

    // 未完成的等待要叫醒，否则发送队列会永久卡在旧任务上。
    for (final waiter in _finishWaiters.values) {
      if (!waiter.isCompleted) waiter.complete();
    }
    for (final waiter in _ackWaiters.values) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _finishWaiters.clear();
    _ackWaiters.clear();

    // 换会话后，还在跑的 accept 会因为「会话变了」自行放弃并清理临时文件，
    // 这里只打标记，不直接删——此刻它可能还没拿到临时文件的确切路径。
    for (final prepare in _preparing.values) {
      prepare.abandoned = true;
    }

    for (final id in _incoming.keys.toList()) {
      unawaited(_abortIncoming(id, deletePartial: true));
    }

    _tasks.clear();
    _incoming.clear();
    _speedStates.clear();
    _waitingSince.clear();
    _lastProgressAt.clear();
    _cancelRequests.clear();
    _queue.clear();
    _paused = false;
    _emit(force: true);
  }

  // ---------- 超时看护 ----------

  /// 每秒扫一次进行中的任务，按两类超时分别处理。
  ///
  /// - [TransferStatus.waiting]（发送端）：等对端点接收/拒绝，
  ///   超时说明对方没理你；
  /// - [TransferStatus.transferring]：已经有字节在流动，只有
  ///   **长时间没有任何进展**才算卡住。因此正常传大文件永远不会被误判。
  ///
  /// [TransferStatus.queued] 的任务**不计时**：它还在队列里，请求根本
  /// 没发出去，对端无从「响应」。以前拿 `createdAt` 兜底计时，
  /// 于是一次发多个文件时，排在后面的会在轮到之前就被判成「对方没有响应」。
  void _checkTimeouts() {
    final now = DateTime.now();

    for (final task in _tasks.values.toList()) {
      if (!task.isActive) continue;

      // 排队中：请求还没发出去，对端根本不知道它存在，不计时。
      if (task.status == TransferStatus.queued) continue;

      // 准备接收是纯本地操作（选目录、建临时文件），
      // 不涉及对端响应，也不该被看护计时器打断。
      if (task.status == TransferStatus.preparing) continue;

      if (task.status == TransferStatus.waiting) {
        if (task.direction != TransferDirection.sending) continue;
        // 没有 _waitingSince 就说明请求还没发出去，同样不计时。
        final since = _waitingSince[task.id];
        if (since == null) continue;
        if (now.difference(since) < _offerTimeout) continue;
        // 请求已经发给对端了，超时后必须通知它撤掉：
        // 否则对端过了很久点「接收」，我们这边还会真的开始推流。
        _transport.sendFileCancel(task.id, reason: '发送请求已超时');
        _finish(
          task.id,
          TransferStatus.failed,
          error: '对方没有响应接收请求（已等待 ${_offerTimeout.inSeconds} 秒）',
        );
        continue;
      }

      if (task.status != TransferStatus.transferring) continue;

      final last = _lastProgressAt[task.id] ?? task.createdAt;
      if (now.difference(last) < _stallTimeout) continue;

      if (task.direction == TransferDirection.sending) {
        // 让推流循环停下来，并通知对端别再等了。
        _cancelRequests.add(task.id);
        _transport.sendFileCancel(task.id, reason: '传输长时间无进展，已中断');
        _finish(task.id, TransferStatus.failed, error: '传输长时间没有进展，已中断');
      } else {
        unawaited(_abortIncoming(task.id, deletePartial: true));
        _transport.sendFileCancel(task.id, reason: '接收长时间无进展，已中断');
        _finish(task.id, TransferStatus.failed, error: '接收长时间没有进展，已中断');
      }
    }
  }

  // ---------- 状态更新 ----------

  void _updateProgress(int id, int transferredBytes) {
    final task = _tasks[id];
    if (task == null) return;

    // 只要有字节在动就刷新「最后进展时间」，停滞计时器随之归零。
    _lastProgressAt[id] = DateTime.now();

    final now = DateTime.now();
    var speed = task.speedBytesPerSecond;
    var average = task.averageSpeedBytesPerSecond;

    final state = _speedStates[id] ??= _SpeedState(now, task.transferredBytes);
    final elapsedMs = now.difference(state.at).inMilliseconds;
    if (elapsedMs >= 500) {
      final delta = transferredBytes - state.bytes;
      final instant = delta * 1000 / elapsedMs;
      speed = instant.round();
      // 指数滑动平均：单独维护一个平滑值供「剩余时间」使用。
      // 瞬时速度每 500ms 采样一次、波动可达数倍，直接用它算 ETA
      // 会让界面上的倒计时剧烈跳动，观感比「不给时间」还差。
      average = average <= 0
          ? instant
          : average * (1 - AppConfig.speedEmaAlpha) +
              instant * AppConfig.speedEmaAlpha;
      state
        ..at = now
        ..bytes = transferredBytes;
    }

    _tasks[id] = task.copyWith(
      transferredBytes: transferredBytes,
      speedBytesPerSecond: speed,
      averageSpeedBytesPerSecond: average,
    );
    _emit();
  }

  void _update(
    int id, {
    TransferStatus? status,
    int? transferredBytes,
    String? localPath,
  }) {
    final task = _tasks[id];
    if (task == null) return;
    _lastProgressAt[id] = DateTime.now();
    _tasks[id] = task.copyWith(
      status: status,
      transferredBytes: transferredBytes,
      localPath: localPath,
    );
    _emit(force: true);
  }

  void _finish(int id, TransferStatus status, {String? error, String? localPath}) {
    final task = _tasks[id];
    if (task == null) return;

    // **已经终结的任务不再被后续异步结果改写**。
    //
    // 推流、收尾、回执、超时看护都跨着 await，晚到的结果完全可能试图把
    // 「已取消 / 已失败 / 已超时」重新改成成功或 confirming——界面上就是
    // 「用户取消了，任务却显示完成」。第一次终结才是用户看到的结果，
    // 后来的只作废（最多补叫醒还在等它的一方）。
    if (task.isFinished) {
      _releaseWaiters(id);
      return;
    }

    // 注意：这里**不能**清 _cancelRequests。
    // 该标记同时充当「让推流循环停下来」的停止信号，发送循环要等它读到
    // 才会退出；若在终结时就清掉，循环下一块又读到 false，会把整个文件
    // 继续推完（残留数据堵住后续请求帧，表现为「取消一次之后再发文件，
    // 对端半天没反应」）。真正的清理在 _startSending 等循环结束后做。

    _tasks[id] = task.copyWith(
      status: status,
      error: error,
      localPath: localPath,
      speedBytesPerSecond: 0,
      transferredBytes:
          status == TransferStatus.completed ? task.totalBytes : task.transferredBytes,
    );
    _speedStates.remove(id);
    _waitingSince.remove(id);
    _lastProgressAt.remove(id);
    _emit(force: true);
    _releaseWaiters(id);
  }

  /// 叫醒还在等这个任务的一方（发送队列、回执等待），不改变任务状态。
  void _releaseWaiters(int id) {
    final waiter = _finishWaiters.remove(id);
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    final ackWaiter = _ackWaiters.remove(id);
    if (ackWaiter != null && !ackWaiter.isCompleted) ackWaiter.complete();
  }

  /// 节流推送：高频分块时按 [AppConfig.progressThrottle] 合并刷新，
  /// 终结状态则立即推送。
  void _emit({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        _lastEmit != null &&
        now.difference(_lastEmit!) < AppConfig.progressThrottle) {
      return;
    }
    _lastEmit = now;
    if (_controller.isClosed) return;
    _controller.add(List<TransferTask>.unmodifiable(_tasks.values));
  }

  int _newId() {
    while (true) {
      final id = _random.nextInt(0x7FFFFFFF);
      if (!_tasks.containsKey(id)) return id;
    }
  }

  @override
  Future<void> dispose() async {
    _watchdog?.cancel();
    _watchdog = null;
    // 先作废仍在准备的接收：它们的临时文件由 accept 的 finally 清理，
    // 这里等一下，免得进程退出时留下 .mova-part 残留。
    for (final id in _preparing.keys.toList()) {
      await _abortPreparing(id);
    }
    for (final id in _incoming.keys.toList()) {
      await _abortIncoming(id, deletePartial: true);
    }
    await _writer.dispose();
    await _eventSub?.cancel();
    await _statusSub?.cancel();
    // 重复 dispose（测试里常见）不应抛异常。
    if (!_controller.isClosed) await _controller.close();
  }
}

/// 待发送队列项。
class _QueuedSend {
  _QueuedSend({required this.id, required this.file});

  final int id;
  final PickedFile file;
}

/// 速度测算状态。
class _SpeedState {
  _SpeedState(this.at, this.bytes);

  DateTime at;
  int bytes;
}

/// 一个正在接收的文件的落盘位置与已收字节数。
class _IncomingState {
  _IncomingState({required this.finalPath, required this.tempPath});

  /// 核对无误后要改成的正式路径。
  final String finalPath;

  /// 接收过程中的临时路径。
  final String tempPath;

  int receivedBytes = 0;

  /// 是否正在提交（把临时文件改名为正式文件）。
  bool _committing = false;

  /// 已经落地的正式路径（改名成功后才有值）。
  ///
  /// 取消流程需要它：取消可能正好撞在改名那一次 await 上，
  /// 此时临时文件已经不存在了，要删的是这个正式文件。
  String? committedPath;

  final Completer<void> _commitDone = Completer<void>();

  void beginCommit() {
    _committing = true;
  }

  void endCommit() {
    if (!_commitDone.isCompleted) _commitDone.complete();
  }

  /// 若在提交中，等这一步落地后再继续（让取消与提交串行）。
  Future<void> waitCommit() {
    if (!_committing) return Future<void>.value();
    return _commitDone.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {},
    );
  }
}

/// 一次「准备接收」的进度与归属。
///
/// 准备过程跨多次 await，期间可能已经被取消/断连；用 [token] 区分
/// 「是不是同一次准备」，用 [abandoned] 通知还在跑的那次准备放弃结果，
/// 用 [done] 让取消方等到清理结束。
class _PrepareState {
  _PrepareState(this.token);

  final int token;

  /// 本次准备已经创建的临时文件（可能还没有）。
  String? tempPath;

  /// 已被取消/断连作废。
  bool abandoned = false;

  /// 准备流程结束（无论成败）后被叫醒。
  final Completer<void> done = Completer<void>();
}
