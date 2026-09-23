import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../config/app_config.dart';
import '../../../domain/models/chat/chat_message.dart';
import '../../../domain/models/chat/connection_status.dart';
import '../../../domain/models/chat/peer.dart';
import '../../../domain/models/transfer/transfer_task.dart';
import '../../storage/widgets/storage_paths_dialog.dart';
import '../../transfer/view_models/transfer_view_model.dart';
import '../../transfer/widgets/transfer_card.dart';
import '../../theme/app_motion_widgets.dart';
import '../../theme/app_theme.dart';
import '../view_models/chat_view_model.dart';
import '../view_models/connection_view_model.dart';

/// 首页（View 层）：顶栏（状态/本机地址）+ 附近设备/聊天流 + 输入栏。
///
/// 只负责展示与交互，逻辑全部委托给 [ConnectionViewModel]、
/// [ChatViewModel] 与 [TransferViewModel]。
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

  /// 聊天流上次长度：新条目进来自动滚动到底部并做入场动效。
  int _lastTimelineLength = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ConnectionViewModel>().initialize();
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
    final transfer = context.watch<TransferViewModel>();

    final timeline = _buildTimeline(chat, transfer);
    final hasNew = timeline.length > _lastTimelineLength;
    _lastTimelineLength = timeline.length;

    return Scaffold(
      // 整个窗口都是拖放区：把文件拖进来即可发送。
      body: DropTarget(
        onDragEntered: (_) => _setDragging(true),
        onDragExited: (_) => _setDragging(false),
        onDragDone: (details) => _handleDrop(details.files),
        child: Stack(
          children: [
            Column(
              children: [
                _Header(connection: connection),
                _Subtitle(connection: connection),
                if (!connection.isConnected) ...[
                  _DiscoverySection(
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
                  child: _TimelineArea(
                    entries: timeline,
                    controller: _scrollController,
                    animateLast: hasNew,
                    onAnimateLast: _scrollToBottom,
                  ),
                ),
                if (connection.isConnected)
                  _SaveDirectoryLine(transfer: transfer),
                _InputBar(
                  messageController: _messageController,
                  enabled: connection.isConnected,
                  onSend: _send,
                  onPickFiles: transfer.pickAndSendFiles,
                ),
              ],
            ),
            if (_dragging) const _DropOverlay(),
          ],
        ),
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

    await transfer.sendPaths(paths);
    if (!mounted) return;

    final message = transfer.lastMessage;
    if (message != null) {
      transfer.clearMessage();
      _showMessage(message);
    }
  }

  // ---------- 聊天流（消息 + 文件传输归并） ----------

  List<_TimelineEntry> _buildTimeline(
    ChatViewModel chat,
    TransferViewModel transfer,
  ) {
    final entries = <_TimelineEntry>[
      for (final message in chat.messages)
        _TimelineEntry(time: message.timestamp, message: message),
      for (final task in transfer.tasks)
        _TimelineEntry(time: task.createdAt, task: task),
    ]..sort((a, b) => a.time.compareTo(b.time));

    return entries;
  }

  // ---------- 交互 ----------

  Future<void> _send() async {
    final text = _messageController.text;
    if (text.trim().isEmpty) return;

    _messageController.clear();
    await context.read<ChatViewModel>().send(text);
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
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
  }
}

// ---------- 顶栏 ----------

/// 顶栏：左侧状态徽章（+断开），右侧本机地址胶囊与数据存放位置按钮。
class _Header extends StatelessWidget {
  const _Header({required this.connection});

  final ConnectionViewModel connection;

  @override
  Widget build(BuildContext context) {
    final endpoint = connection.localInfo?.endpoint;

    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppDimens.pagePadding,
        14,
        AppDimens.pagePadding,
        14,
      ),
      child: Row(
        children: [
          _StatusChip(status: connection.status),
          if (connection.isConnected) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: connection.disconnect,
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('断开'),
            ),
          ],
          const Spacer(),
          PressableScale(
            onTap: endpoint == null
                ? null
                : () {
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        SnackBar(
                          content: Text('已复制本机地址：$endpoint'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                  },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(AppDimens.radiusPill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    endpoint ?? '获取中…',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textPrimary,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.copy_rounded,
                      size: 15, color: AppColors.textSecondary),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          PressableScale(
            onTap: () => showStoragePathsDialog(context),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.background,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.storage_rounded,
                  size: 18, color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 连接状态徽章（设计稿：未连接灰点呼吸 / 连接中蓝 / 已连接绿 + 脉冲）。
class _StatusChip extends StatefulWidget {
  const _StatusChip({required this.status});

  final ConnectionStatus status;

  @override
  State<_StatusChip> createState() => _StatusChipState();
}

class _StatusChipState extends State<_StatusChip> {
  @override
  Widget build(BuildContext context) {
    final (text, color, breathing) = switch (widget.status) {
      ConnectionStatus.connected => ('已连接', AppColors.success, false),
      ConnectionStatus.connecting => ('连接中', AppColors.connecting, false),
      ConnectionStatus.disconnected => ('未连接', AppColors.idle, true),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppDimens.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusDot(color: color, breathing: breathing),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 状态点：未连接呼吸；连接成功时向外扩散一圈涟漪。
class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.color, required this.breathing});

  final Color color;
  final bool breathing;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: AppMotion.medium,
  );

  @override
  void didUpdateWidget(_StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 连接建立：绿点向外扩散一圈涟漪后消失（设计稿「连接成功脉冲」）。
    if (widget.color == AppColors.success &&
        oldWidget.color != AppColors.success) {
      _pulse.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const size = 8.0;

    final dot = widget.breathing
        ? BreathingDot(color: widget.color, size: size)
        : Container(
            width: size,
            height: size,
            decoration:
                BoxDecoration(color: widget.color, shape: BoxShape.circle),
          );

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          dot,
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              final t = _pulse.value;
              if (t == 0 || t == 1) return const SizedBox.shrink();
              return Positioned(
                left: -size * t,
                top: -size * t,
                child: IgnorePointer(
                  child: Container(
                    width: size * (1 + 2 * t),
                    height: size * (1 + 2 * t),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.success.withValues(alpha: 0.35 * (1 - t)),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 状态栏下的说明行。
class _Subtitle extends StatelessWidget {
  const _Subtitle({required this.connection});

  final ConnectionViewModel connection;

  @override
  Widget build(BuildContext context) {
    final text = connection.isConnected
        ? '已与 ${connection.remoteName ?? '对方'} 建立直连 · 文件只在两台设备之间传输'
        : '在同一局域网打开 Mova，设备会自动出现在这里';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.pagePadding,
        12,
        AppDimens.pagePadding,
        12,
      ),
      child: Text(
        text,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
      ),
    );
  }
}

// ---------- 附近设备 ----------

/// 未连接时展示：设备卡片列表 + 搜索中 + 手动直连折叠区。
class _DiscoverySection extends StatelessWidget {
  const _DiscoverySection({
    required this.connection,
    required this.ipController,
    required this.manualOpen,
    required this.onToggleManual,
    required this.onConnectManual,
  });

  final ConnectionViewModel connection;
  final TextEditingController ipController;
  final bool manualOpen;
  final VoidCallback onToggleManual;
  final VoidCallback onConnectManual;

  @override
  Widget build(BuildContext context) {
    final peers = connection.peers;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.pagePadding,
        8,
        AppDimens.pagePadding,
        16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '附近设备',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              if (connection.isDiscovering)
                PressableScale(
                  onTap: connection.stopDiscovery,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      children: [
                        Icon(Icons.stop_rounded,
                            size: 15, color: AppColors.textSecondary),
                        SizedBox(width: 4),
                        Text(
                          '停止搜索',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (connection.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                connection.errorMessage!,
                style: const TextStyle(
                    color: AppColors.danger, fontSize: 12),
              ),
            ),
          // 未开启搜索：给一个明确入口，默认不在后台持续扫描。
          if (!connection.isDiscovering)
            const _DiscoveryIdleHint()
          else ...[
            for (var i = 0; i < peers.length; i++)
              Entrance(
                delay: AppMotion.stagger * i,
                child: _DeviceCard(
                  peer: peers[i],
                  onConnect: () => connection.connectToPeer(peers[i]),
                ),
              ),
            if (peers.isEmpty)
              const _SearchingRow(text: '正在搜索附近的设备…')
            else
              const _SearchingRow(text: '正在搜索更多设备…'),
          ],
          const SizedBox(height: 6),
          _ManualConnect(
            ipController: ipController,
            open: manualOpen,
            onToggle: onToggleManual,
            onConnect: onConnectManual,
          ),
        ],
      ),
    );
  }
}

/// 单个设备卡片。
class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.peer, required this.onConnect});

  final Peer peer;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(AppDimens.radiusCard),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.monitor_outlined,
                  size: 20, color: AppColors.textPrimary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    peer.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    peer.ip,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            PressableScale(
              onTap: onConnect,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                ),
                child: const Text(
                  '连接',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 未开启搜索时的占位卡片：只给入口，不自动扫描。
class _DiscoveryIdleHint extends StatelessWidget {
  const _DiscoveryIdleHint();

  @override
  Widget build(BuildContext context) {
    final connection = context.read<ConnectionViewModel>();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppDimens.radiusCard),
      ),
      child: Row(
        children: [
          const Icon(Icons.wifi_tethering_off_rounded,
              size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              '未开启设备搜索。你也可以直接在下方手动输入对方 IP 直连。',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 12),
          PressableScale(
            onTap: connection.startDiscovery,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(AppDimens.radiusPill),
              ),
              child: const Text(
                '开始搜索',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「正在搜索…」灰底行。
class _SearchingRow extends StatelessWidget {
  const _SearchingRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppDimens.radiusCard),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            text,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「手动直连 IP:端口」折叠区（展开高度 0→auto，箭头旋转 90°）。
class _ManualConnect extends StatelessWidget {
  const _ManualConnect({
    required this.ipController,
    required this.open,
    required this.onToggle,
    required this.onConnect,
  });

  final TextEditingController ipController;
  final bool open;
  final VoidCallback onToggle;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PressableScale(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedRotation(
                  turns: open ? 0.25 : 0,
                  duration: AppMotion.quick,
                  curve: AppMotion.curve,
                  child: const Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 4),
                const Text(
                  '手动直连 IP:端口',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        // 高度 0 → auto：用 ClipRect + AnimatedAlign 近似设计稿的展开动效。
        ClipRect(
          child: AnimatedAlign(
            alignment: Alignment.topLeft,
            heightFactor: open ? 1 : 0,
            duration: AppMotion.quick,
            curve: AppMotion.curve,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, left: 24),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: ipController,
                      decoration: const InputDecoration(
                        hintText: '输入 IP 或 IP:端口',
                      ),
                      onSubmitted: (_) => onConnect(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PressableScale(
                    onTap: onConnect,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 11),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius:
                            BorderRadius.circular(AppDimens.radiusPill),
                      ),
                      child: const Text(
                        '连接',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------- 聊天流区域 ----------

class _TimelineEntry {
  const _TimelineEntry({required this.time, this.message, this.task});

  final DateTime time;
  final ChatMessage? message;
  final TransferTask? task;
}

/// 消息/文件卡时间线区域；无内容时显示空态。
class _TimelineArea extends StatelessWidget {
  const _TimelineArea({
    required this.entries,
    required this.controller,
    required this.animateLast,
    required this.onAnimateLast,
  });

  final List<_TimelineEntry> entries;
  final ScrollController controller;
  final bool animateLast;
  final VoidCallback onAnimateLast;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const _EmptyState();
    }

    if (animateLast) onAnimateLast();

    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.pagePadding, vertical: 12),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final showTimeDivider = index == 0 ||
            entry.time.difference(entries[index - 1].time).inMinutes >= 3;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showTimeDivider)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Center(
                  child: Text(
                    _formatTime(entry.time),
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            if (entry.message != null)
              _MessageBubble(message: entry.message!)
            else
              _buildTransferCard(context, entry.task!),
          ],
        );
      },
    );
  }

  Widget _buildTransferCard(BuildContext context, TransferTask task) {
    final vm = context.read<TransferViewModel>();

    return TransferCard(
      task: task,
      onAccept: () => vm.acceptToDefaultDirectory(task.id),
      onSaveAs: () => vm.acceptWithDirectoryPicker(task.id),
      onReject: () => vm.reject(task.id),
      onCancel: () => vm.cancel(task.id),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(time.year, time.month, time.day);
    final hhmm =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    if (that == today) return '今天 $hhmm';
    if (that == today.subtract(const Duration(days: 1))) {
      return '昨天 $hhmm';
    }
    return '${time.month}月${time.day}日 $hhmm';
  }
}

/// 空态（设计稿 01 底部）。
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.monitor_outlined,
                  size: 26, color: AppColors.idle),
              SizedBox(width: 6),
              Icon(Icons.arrow_right_alt_rounded,
                  size: 20, color: AppColors.idle),
              SizedBox(width: 6),
              Icon(Icons.smartphone_outlined,
                  size: 26, color: AppColors.idle),
            ],
          ),
          SizedBox(height: 16),
          Text(
            '还没有消息',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 6),
          Text(
            '连接一台设备后，即可互发文字与文件',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// 消息气泡：对方浅灰居左，自己蓝色居右。
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isSelf = message.isSelf;

    return Align(
      alignment: isSelf ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: isSelf ? AppColors.primary : AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(AppDimens.radiusCard),
        ),
        child: Text(
          message.text,
          style: TextStyle(
            fontSize: 14,
            height: 1.45,
            color: isSelf ? Colors.white : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

// ---------- 底部 ----------

/// 接收保存位置（已连接时显示在输入栏上方，可点击修改）。
class _SaveDirectoryLine extends StatelessWidget {
  const _SaveDirectoryLine({required this.transfer});

  final TransferViewModel transfer;

  @override
  Widget build(BuildContext context) {
    final directory = transfer.saveDirectory;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.pagePadding,
        0,
        AppDimens.pagePadding,
        4,
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined,
              size: 13, color: AppColors.textSecondary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '接收到：${directory ?? '获取中…'}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          GestureDetector(
            onTap: transfer.chooseSaveDirectory,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.edit_outlined,
                  size: 13, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 输入栏：回形针选文件 + 圆角输入框 + 圆形发送按钮。
class _InputBar extends StatefulWidget {
  const _InputBar({
    required this.messageController,
    required this.enabled,
    required this.onSend,
    required this.onPickFiles,
  });

  final TextEditingController messageController;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onPickFiles;

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.messageController.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final hasText = widget.messageController.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  @override
  void dispose() {
    widget.messageController.removeListener(_onTextChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canSend = widget.enabled && _hasText;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(AppDimens.radiusPill),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: IconButton(
                      tooltip: '发送文件',
                      onPressed: widget.enabled ? widget.onPickFiles : null,
                      icon: const Icon(Icons.attach_file_rounded,
                          size: 20, color: AppColors.textPrimary),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: widget.messageController,
                      enabled: widget.enabled,
                      onSubmitted: (_) => canSend ? widget.onSend() : null,
                      decoration: const InputDecoration(
                        hintText: '输入消息，或把文件拖进来',
                        border: InputBorder.none,
                        filled: false,
                        contentPadding: EdgeInsets.zero,
                      ),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          PressableScale(
            onTap: canSend ? widget.onSend : null,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: canSend ? AppColors.primary : AppColors.surfaceMuted,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.arrow_upward_rounded,
                size: 22,
                color: canSend ? Colors.white : AppColors.idle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- 拖拽提示层 ----------

/// 拖拽悬停时的提示层。
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: AppColors.background.withValues(alpha: 0.8),
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.primary, width: 1.5),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.download_rounded,
                    size: 30, color: AppColors.primary),
                SizedBox(height: 10),
                Text(
                  '松手即发送给对方',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 4),
                Text(
                  '支持 ${AppConfig.allowedSummary}',
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
