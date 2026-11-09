import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:window_manager/window_manager.dart';

import '../data/repositories/chat/chat_repository.dart';
import '../data/repositories/history/history_repository.dart';
import '../data/repositories/transfer/transfer_repository.dart';
import 'navigator_key.dart';
import 'window_controller.dart';

/// 退出流程的结果。
sealed class ExitOutcome {}

/// 收尾全部完成，可以退出。
class ExitCompleted extends ExitOutcome {}

/// 收尾**没能**完成（保存超时或写盘失败）。
///
/// 这不等同于「可以退出」：`Future.timeout()` 并不会停掉原来的写入，
/// 慢磁盘上进程很可能先一步结束，最后一批记录就此丢失；写盘失败则更明确——
/// 磁盘已满 / 没有权限 / 文件被占用，这次根本没写出去。
class ExitBlocked extends ExitOutcome {
  ExitBlocked(this.reason);

  /// 可以直接显示给用户的原因。
  final String reason;
}

/// 退出被挡住时，用户（或缺省路径）的选择。
enum ExitDecision {
  /// 放弃保存，强制退出（记录可能丢一部分）。
  force,

  /// 再试一次保存。
  retry,

  /// 没有可询问的界面：保持打开，由用户自己再点一次关闭。
  stay,
}

/// 退出受阻时的询问方式。
///
/// 注入它主要是为了测试：真实弹窗依赖 Navigator，测试里换成替身
/// 就能确定地安排「用户选择重试」或「用户选择强制退出」。
typedef ExitPrompt = Future<ExitDecision> Function(String reason);

/// 正常退出流程：关闭窗口 / 退出应用时走的唯一一条路。
///
/// 为什么必须有它：`HistoryRepositoryLocal.dispose()` 虽然会等写入队列，
/// 但 Provider 的 `dispose:` 回调是同步的，宿主根本不会 await；而退出前的
/// 收尾又偏偏要「先封存连接 → 再结束会话 → 再等历史落盘」。少了这个等待，
/// 进程很可能在最终保存之前就结束——尤其是此刻正好有一次旧写入在跑的时候。
///
/// 两条入口，同一个流程（[prepareExit] 幂等，重复调用共用一次结果）：
/// - [onWindowClose]：拦截窗口关闭。**Windows 必须靠它**——Flutter 的
///   框架层退出请求（`didRequestAppExit`）目前只覆盖 macOS / Linux，
///   Windows 上关窗口是不会通知 Dart 的；
/// - [didRequestAppExit]：macOS / Linux 上 Cmd+Q、退出菜单等系统级请求。
///
/// 每一步都有超时：退出流程自己绝不能把用户卡住。但**超时不等于完成**——
/// 只有保存那一步没完成时才会阻断退出，把选择权交回给用户
/// （见 [ExitBlocked] 与 [ExitDecision]）。保存失败（而不是超时）同样阻断：
/// 异常会从 `HistoryRepository.dispose()` 一路抛上来，绝不能当成成功。
///
/// 两个入口共用**同一个进行中的确认流程**（[_confirmBeforeExit]）：
/// 连点关闭、或关闭按钮与系统退出请求撞在一起时，也只有一条流程在跑，
/// 不会弹出两个对话框，放行之后也不会销毁两次窗口。
class AppShutdown with WidgetsBindingObserver, WindowListener {
  AppShutdown({
    required HistoryRepository history,
    required ChatRepository chat,
    required TransferRepository transfer,
    WindowController window = const WindowManagerController(),
    ExitPrompt? prompt,
    Future<void> Function()? flushLogs,
    Duration stepTimeout = const Duration(seconds: 5),
  })  : _history = history,
        _chat = chat,
        _transfer = transfer,
        _window = window,
        _prompt = prompt,
        _flushLogs = flushLogs,
        _stepTimeout = stepTimeout;

  final HistoryRepository _history;
  final ChatRepository _chat;
  final TransferRepository _transfer;
  final WindowController _window;
  final ExitPrompt? _prompt;
  final Future<void> Function()? _flushLogs;
  final Duration _stepTimeout;
  final Logger _log = Logger('AppShutdown');

  bool _installingUpdate = false;
  bool _started = false;
  bool _exiting = false;
  Future<ExitOutcome>? _exitWork;

  /// 进行中的「确认 → 放行」流程（含保存、询问与重试）。
  ///
  /// 两个入口共用它：没有一个共享的 Future，连点关闭就会跑出多条流程，
  /// 每条都去弹一次对话框、各等各的结果。
  Future<bool>? _confirmWork;

  /// 放行（解除拦截 + 销毁窗口）是否已经做过。
  bool _released = false;

  String? _blockReason;

  /// 退出流程是否已开始：开始之后不再接受新的消息与历史变更。
  bool get isExiting => _exiting;

  /// 上一次被挡住的原因（成功时为 null）。
  String? get blockReason => _blockReason;

  /// 注册：接管窗口关闭，并接收框架转来的退出请求。
  ///
  /// 必须在 `runApp` 之后、用户有机会关窗口之前调用。
  Future<void> start() async {
    if (_started) return;
    _started = true;

    WidgetsBinding.instance.addObserver(this);
    // 先挂上监听、再拦截：反过来写的话，拦截生效前那一次关闭会被漏掉。
    _window.addListener(this);
    try {
      await _window.setPreventClose(true);
    } catch (e) {
      // 拦不住也要记下来：此时关窗口还是能走到回调，只是可能来不及保存。
      _log.warning('设置关闭拦截失败：$e');
    }
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;

    WidgetsBinding.instance.removeObserver(this);
    _window.removeListener(this);
    await _window.setPreventClose(false).catchError((Object e) {
      _log.warning('解除关闭拦截失败：$e');
    });
  }

  /// 用户点了关闭按钮：跑完退出流程再真正关掉窗口。
  ///
  /// 保存没完成时**不关窗口**：留在应用里，由用户决定重试还是放弃。
  @override
  void onWindowClose() {
    if (!_installingUpdate) unawaited(_closeWindowAfterExit());
  }

  Future<void> _closeWindowAfterExit() async {
    if (!await _confirmBeforeExit()) return;
    await _releaseWindow();
  }

  /// 跑到「允许退出」为止；返回 `false` 表示应当留在应用里。
  ///
  /// 整个流程（保存 → 受阻则询问 → 重试）共用一个进行中的 Future：
  /// 两个入口同时进来也只有一条流程，不会弹出两个对话框。
  Future<bool> _confirmBeforeExit() => _confirmWork ??= _runConfirmBeforeExit();

  Future<bool> _runConfirmBeforeExit() async {
    while (true) {
      final outcome = await prepareExit();
      if (outcome is! ExitBlocked) return true;

      final decision = await _promptExit(outcome.reason);
      switch (decision) {
        case ExitDecision.force:
          _log.warning('用户选择放弃保存并退出');
          return true;
        case ExitDecision.retry:
          // 清掉上一次结果：「重试」必须真的再跑一遍保存，
          // 而不是拿上一次的失败结果直接放行。
          _exitWork = null;
          continue;
        case ExitDecision.stay:
          // 没有可询问的界面（或用户没表态）：保持打开，
          // 用户再点一次关闭就会重新走一遍。
          _exitWork = null;
          // 关键：把这次「没放行」的结果也清掉。留着的话，下次点关闭
          // 会直接复用这个 false 一路返回，重试永远跑不起来。
          _confirmWork = null;
          return false;
      }
    }
  }

  Future<ExitDecision> _promptExit(String reason) async {
    final prompt = _prompt;
    if (prompt != null) return prompt(reason);
    return _defaultPrompt(reason);
  }

  /// 缺省询问：弹一个对话框让用户选「重试保存」还是「放弃并退出」。
  ///
  /// 拿不到可展示的界面时返回 [ExitDecision.stay]：窗口保持打开，
  /// 用户再点一次关闭即可重试——绝不能默默把「超时」当成「保存好了」。
  Future<ExitDecision> _defaultPrompt(String reason) async {
    final context = appNavigatorKey.currentContext;
    if (context == null || !context.mounted) return ExitDecision.stay;

    final choice = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('连接记录还没保存完'),
        content: Text('$reason\n\n现在退出会丢失这部分记录。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('重试保存'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('放弃并退出'),
          ),
        ],
      ),
    );

    return switch (choice) {
      true => ExitDecision.force,
      false => ExitDecision.retry,
      null => ExitDecision.stay,
    };
  }

  /// 框架转来的退出请求（macOS / Linux 的系统级退出）。
  ///
  /// 保存没完成时返回 [AppExitResponse.cancel]：退出请求被驳回，
  /// 应用继续运行，用户稍后可以再试。
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (_installingUpdate) return AppExitResponse.cancel;
    final allowed = await _confirmBeforeExit();
    return allowed ? AppExitResponse.exit : AppExitResponse.cancel;
  }

  /// 切到后台 / 被隐藏：不结束会话，只把改动尽快落盘。
  ///
  /// 用户可能只是切走了，此时结束会话会留下一条「半截」的记录。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      unawaited(_history.flush().catchError((Object e) {
        _log.warning('切到后台时的落盘失败：$e');
      }));
    }
  }

  /// 更新专用出口：同一个同步调用内检查任务并封存连接。
  /// 保存失败不启动安装器，也不允许强制丢弃记录。
  Future<void> installUpdate(Future<void> Function() launchInstaller) async {
    if (_confirmWork != null || _released || _installingUpdate) throw StateError('应用正在退出');
    if (_transfer.currentTasks.any((task) => task.isActive)) {
      throw StateError('还有未结束的文件任务，请等待完成或取消任务');
    }
    _installingUpdate = true;
    try {
      final outcome = await prepareExit();
      if (outcome is ExitBlocked) {
        _exitWork = null;
        throw StateError('${outcome.reason} 请重试安装；连接已关闭。');
      }
      _log.info('更新：退出收尾完成，开始启动安装辅助进程');
      await launchInstaller();
      _log.info('更新：辅助进程就绪，开始释放窗口');
      await _releaseWindow();
    } finally {
      _installingUpdate = false;
    }
  }

  /// 退出流程本体（幂等）。
  Future<ExitOutcome> prepareExit() => _exitWork ??= _runExit();

  Future<ExitOutcome> _runExit() async {
    _exiting = true;
    _log.info('开始退出流程');

    // 1) 停止接收新连接：监听要一起关掉。
    //    用 disconnect() 是不够的——它**保留监听**（对方可以再次连入），
    //    退出期间这正是漏洞：保存还没完成的那几秒里，另一台设备仍能
    //    连进来建一个新会话，而此刻传输仓储可能已在释放、
    //    历史仓储可能已经关闭，状态就此错乱。
    await _step('停止接收新连接', _chat.stopAcceptingConnections);

    // 2) 完成会话收尾：把进行中的会话标记为已结束，
    //    之后的历史变更不再入队（见 HistoryRepositoryLocal 的 _closed）。
    final active = _history.activeSessionId;
    if (active != null) {
      await _step('结束会话', () => _history.endSession(active));
    }

    // 3) 停止传输：后台落盘 isolate 与临时文件都要收干净。
    await _step('停止传输', _transfer.dispose);

    // 4) 等历史落盘：内部会等在跑的写入，再写最终快照。
    //    这一步没完成就必须阻断退出——超时只是「等不下去了」，
    //    写入本身还会继续跑，但进程一旦结束就再也没人等它；
    //    写盘失败则更明确（磁盘满 / 没权限 / 被占用），必须原样传给用户。
    final saved = await _step('保存连接记录', _history.dispose);
    if (!saved.done) {
      final reason = saved.timedOut
          ? '连接记录还没写完（磁盘较慢或正在被其它程序占用）。'
          : '连接记录保存失败（磁盘已满、没有写入权限或文件被占用）。';
      _blockReason = reason;
      _log.warning('退出流程被阻断：$reason');
      return ExitBlocked(reason);
    }

    _blockReason = null;
    _log.info('退出流程完成');
    return ExitCompleted();
  }

  /// 单步执行：返回这一步**是否真的完成了**，以及没完成是不是因为超时。
  ///
  /// 超时与报错都算没完成——`Future.timeout()` 只是不等了，
  /// 并不会取消原来的操作，绝不能把它当成功。
  /// 区分两者是为了给用户一个说得通的提示：「还在写」和「写坏了」不是一回事。
  Future<({bool done, bool timedOut})> _step(
    String name,
    Future<void> Function() work,
  ) async {
    final clock = Stopwatch()..start();
    _log.info('退出步骤开始：$name');
    try {
      final pending = work();
      _log.info('退出步骤已返回 Future：$name，同步耗时 ${clock.elapsedMilliseconds}ms');
      await pending.timeout(_stepTimeout);
      _log.info('退出步骤完成：$name，总耗时 ${clock.elapsedMilliseconds}ms');
      return (done: true, timedOut: false);
    } on TimeoutException catch (e) {
      _log.warning('退出流程「$name」超时，耗时 ${clock.elapsedMilliseconds}ms：$e');
      return (done: false, timedOut: true);
    } catch (e) {
      _log.warning('退出流程「$name」失败，耗时 ${clock.elapsedMilliseconds}ms：$e');
      return (done: false, timedOut: false);
    }
  }

  /// 收尾已放行：解除拦截并真正关掉窗口。
  ///
  /// 只做一次：两个入口可能同时拿到「放行」（关闭按钮 + 系统退出请求），
  /// 销毁两次窗口既没必要，也会让「到底关了几次」说不清楚。
  Future<void> _releaseWindow() async {
    if (_released) return;
    _released = true;

    final clock = Stopwatch()..start();
    _log.info('窗口释放：开始解除关闭拦截');
    await _window.setPreventClose(false).catchError((Object e) {
      _log.warning('解除关闭拦截失败：$e');
    });
    _log.info('窗口释放：开始 destroy，已耗时 ${clock.elapsedMilliseconds}ms');
    // 窗口销毁可能立即结束进程，先让之前的诊断记录落盘。
    try {
      await _flushLogs?.call().timeout(const Duration(seconds: 1));
    } catch (_) {
      // 日志不是业务数据，不能因为日志慢而阻止退出。
    }
    await _window.destroy().catchError((Object e) {
      _log.warning('关闭窗口失败：$e');
    });
    _log.info('窗口释放：destroy 已返回，总耗时 ${clock.elapsedMilliseconds}ms');
  }
}
