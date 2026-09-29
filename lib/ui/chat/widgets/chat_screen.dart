import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/models/transfer/picked_file.dart';
import '../../history/widgets/history_panel.dart';
import '../../settings/view_models/settings_view_model.dart';
import '../../settings/widgets/settings_dialog.dart';
import '../../storage/widgets/storage_paths_dialog.dart';
import '../../theme/app_theme.dart';
import '../../transfer/view_models/transfer_view_model.dart';
import '../../transfer/widgets/send_confirm_dialog.dart';
import '../view_models/chat_view_model.dart';
import '../view_models/connection_view_model.dart';
import 'chat_header.dart';
import 'discovery_section.dart';
import 'drop_overlay.dart';
import 'input_bar.dart';
import 'timeline_area.dart';

/// 首页（View 层）：顶栏 + 附近设备/聊天流 + 输入栏。
///
/// 只负责把各区块拼起来并处理交互，具体区块在
/// `chat_header.dart` / `discovery_section.dart` / `timeline_area.dart` /
/// `input_bar.dart` 里，逻辑全部委托给三个 ViewModel。
///
/// 性能上有一个要点：这里**不**整体监听 [TransferViewModel]。
/// 传输进度每秒刷新十次，整页跟着重建会让滚动和输入发涩；
/// 因此只在列表结构（任务增删）变化时重建时间线，
/// 每张文件卡自己订阅自己那条任务（见 [_TransferSlot]）。
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _ipController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _dragging = false;
  bool _manualOpen = false;

  /// 右侧「连接记录」抽屉是否展开。
  bool _historyOpen = false;

  /// 聊天流上次长度：新条目进来自动滚动到底部并做入场动效。
  int _lastTimelineLength = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final connection = context.read<ConnectionViewModel>();
      connection.initialize();
      // 「有人想连你，但你已连着别人」这类提示用气泡弹出来。
      connection.notices.listen(_showMessage);
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _ipController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connection = context.watch<ConnectionViewModel>();
    final chat = context.watch<ChatViewModel>();
    // 只在任务增删/顺序变化时重建列表，进度刷新交给卡片自己。
    context.select<TransferViewModel, String>((vm) => vm.taskSignature);
    // 设置项（发文件前要不要确认）在发送那一步才读，不必订阅整个 ViewModel。
    final transfer = context.read<TransferViewModel>();

    final timeline = _buildTimeline(chat, transfer);
    final hasNew = timeline.length > _lastTimelineLength;
    _lastTimelineLength = timeline.length;

    return Scaffold(
      // 整个窗口都是拖放区：把文件拖进来即可发送。
      body: LayoutBuilder(
        builder: (context, constraints) {
          final panelWidth = (constraints.maxWidth * 0.62).clamp(360.0, 620.0);

          return DropTarget(
            onDragEntered: (_) => _setDragging(true),
            onDragExited: (_) => _setDragging(false),
            onDragDone: (details) => _handleDrop(details.files),
            child: Stack(
              children: [
                // 条件子项会让后面的 Element 按「索引」错位复用：
                // 打开抽屉或拖入文件时插入新 child，会把面板那个位置
                // 错配给别的 widget，导致面板被卸载重建、状态丢失。
                // 因此每一项都带 key，保证按 key 匹配。
                KeyedSubtree(
                  key: const ValueKey('main'),
                  child: Column(
                    children: [
                      ChatHeader(
                        connection: connection,
                        onOpenHistory: () => setState(() => _historyOpen = true),
                        onOpenStorage: () => showStoragePathsDialog(context),
                        onOpenSettings: () => showSettingsDialog(context),
                      ),
                      ChatSubtitle(connection: connection),
                      if (!connection.isConnected) ...[
                        DiscoverySection(
                          connection: connection,
                          ipController: _ipController,
                          manualOpen: _manualOpen,
                          onToggleManual: () =>
                              setState(() => _manualOpen = !_manualOpen),
                          onConnectManual: () => _connectManual(connection),
                        ),
                        const Divider(height: 1),
                      ],
                      Expanded(
                        child: TimelineArea(
                          entries: timeline,
                          controller: _scrollController,
                          animateLast: hasNew,
                          onAnimateLast: _scrollToBottom,
                        ),
                      ),
                      if (connection.isConnected)
                        SaveDirectoryLine(transfer: transfer),
                      TransferErrorBar(transfer: transfer),
                      InputBar(
                        messageController: _messageController,
                        enabled: connection.isConnected,
                        onSend: _send,
                        onPickFiles: _pickAndSendFiles,
                      ),
                    ],
                  ),
                ),
                if (_dragging)
                  const KeyedSubtree(
                    key: ValueKey('drop'),
                    child: DropOverlay(),
                  ),
                // 抽屉打开时的轻遮罩：点一下就收起。
                if (_historyOpen)
                  KeyedSubtree(
                    key: const ValueKey('scrim'),
                    child: Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _historyOpen = false),
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.06),
                        ),
                      ),
                    ),
                  ),
                // 右侧「连接记录」抽屉：关闭时滑出屏幕外，不挡主界面。
                KeyedSubtree(
                  key: const ValueKey('history'),
                  child: Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    width: panelWidth,
                    child: AnimatedSlide(
                      offset: _historyOpen ? Offset.zero : const Offset(1, 0),
                      duration: AppMotion.quick,
                      curve: AppMotion.curve,
                      child: HistoryPanel(
                        onClose: () => setState(() => _historyOpen = false),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _setDragging(bool value) {
    if (_dragging == value) return;
    setState(() => _dragging = value);
  }

  Future<void> _handleDrop(List<DropItem> items) async {
    _setDragging(false);

    // 在 await 之前取好依赖，避免跨异步间隙使用 context。
    final connection = context.read<ConnectionViewModel>();
    final transfer = context.read<TransferViewModel>();

    if (!connection.isConnected) {
      _showMessage('请先连接一台设备，再拖入文件发送');
      return;
    }

    // macOS 沙箱下，从 Finder 拖入的文件需要先取得安全作用域访问权，
    // 否则读取会失败。整个会话保持即可，无需逐个释放。
    for (final item in items) {
      final bookmark = item.extraAppleBookmark;
      if (bookmark == null || bookmark.isEmpty) continue;
      try {
        await DesktopDrop.instance
            .startAccessingSecurityScopedResource(bookmark: bookmark);
      } catch (_) {
        // 取不到权限也继续尝试，由后续读取给出错误。
      }
    }

    final paths = items.map((item) => item.path).whereType<String>().toList();
    if (paths.isEmpty) return;

    final parsed = await transfer.filesFromPaths(paths);
    if (!mounted) return;

    await _confirmAndSend(
      transfer,
      parsed.accepted,
      ignoredCount: parsed.ignored.length,
      // 拖拽本身就是「松手即发送」，没识别到任何文件时单独提示一次。
      emptyHint: paths.isEmpty ? '没有识别到文件' : null,
    );
  }

  // ---------- 发送文件（回形针 / 拖拽两条入口共用） ----------

  /// 打开文件选择器，确认后发送。
  Future<void> _pickAndSendFiles() async {
    final transfer = context.read<TransferViewModel>();
    final picked = await transfer.pickFiles();
    if (!mounted) return;

    await _confirmAndSend(
      transfer,
      picked.accepted,
      ignoredCount: picked.ignored.length,
    );
  }

  /// 统一的「先看一眼再发」流程。
  ///
  /// 两个入口（回形针、拖拽）都走这里：不小心选错文件、或者把文件拖错
  /// 窗口，都是一次点击就收不回来的操作，而这两个入口原本都是
  /// 「选完就发」。确认框可以在设置里关掉，给追求速度的人留一条捷径。
  Future<void> _confirmAndSend(
    TransferViewModel transfer,
    List<PickedFile> files, {
    required int ignoredCount,
    String? emptyHint,
  }) async {
    if (files.isEmpty) {
      if (emptyHint != null || ignoredCount > 0) {
        _showMessage(
          emptyHint ?? '这些文件暂不支持（仅支持 ${transfer.allowedText}）',
        );
      }
      return;
    }

    final settings = context.read<SettingsViewModel>();
    if (settings.confirmBeforeSend) {
      final connection = context.read<ConnectionViewModel>();
      final confirmed = await showSendConfirmDialog(
        context,
        files: files,
        peerName: connection.remoteName ?? '对方',
      );
      if (!confirmed || !mounted) return;
    }

    await transfer.sendFiles(files);
    if (!mounted) return;

    transfer.reportResult(files.length, ignoredCount);
    final message = transfer.lastMessage;
    if (message != null) {
      transfer.clearMessage();
      _showMessage(message);
    }
  }

  // ---------- 聊天流（消息 + 文件传输归并） ----------

  List<TimelineEntry> _buildTimeline(
    ChatViewModel chat,
    TransferViewModel transfer,
  ) {
    final entries = <TimelineEntry>[
      for (final message in chat.messages)
        TimelineEntry(time: message.timestamp, message: message),
      for (final task in transfer.tasks)
        TimelineEntry(time: task.createdAt, task: task),
    ]..sort((a, b) => a.time.compareTo(b.time));

    return entries;
  }

  // ---------- 交互 ----------

  Future<void> _send() async {
    final text = _messageController.text;
    if (text.trim().isEmpty) return;

    final chat = context.read<ChatViewModel>();
    final sent = await chat.send(text);

    // 只有真的发出去了才清空输入框：内容太长之类发不出去的情况，
    // 清空等于把用户刚粘的一大段话直接弄丢。
    if (!sent) {
      if (!mounted) return;
      _showMessage(chat.errorMessage ?? '发送失败，请重试');
      return;
    }
    if (!mounted) return;

    _messageController.clear();
    _scrollToBottom();
  }

  void _connectManual(ConnectionViewModel vm) {
    final input = _ipController.text.trim();
    if (input.isEmpty) return;

    final parts = input.split(':');
    if (parts.length == 2) {
      final port = int.tryParse(parts[1]);
      vm.connect(parts[0], port: port);
    } else {
      vm.connect(input);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: AppMotion.quick,
        curve: AppMotion.curve,
      );
    });
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
  }
}
