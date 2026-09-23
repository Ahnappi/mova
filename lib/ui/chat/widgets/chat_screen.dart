import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../config/app_config.dart';
import '../../../domain/models/chat/chat_message.dart';
import '../../../domain/models/chat/connection_status.dart';
import '../../storage/widgets/storage_paths_dialog.dart';
import '../../transfer/widgets/transfer_panel.dart';
import '../../transfer/view_models/transfer_view_model.dart';
import '../view_models/chat_view_model.dart';
import '../view_models/connection_view_model.dart';

/// 首页（View 层）：连接区 + 消息区 + 输入区。
///
/// 只负责展示与交互，逻辑全部委托给 [ConnectionViewModel] 与 [ChatViewModel]。
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _ipController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  /// 是否有文件正被拖到窗口上方（用于显示拖拽提示层）。
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    // 首帧后再初始化，避免在 build 过程中触发 notifyListeners。
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mova'),
        actions: [
          IconButton(
            tooltip: '数据存放位置',
            icon: const Icon(Icons.storage_rounded),
            onPressed: () => showStoragePathsDialog(context),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                connection.localInfo?.name ?? '获取中…',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      ),
      // 整个窗口都是拖放区：把文件拖进来即可发送。
      body: DropTarget(
        onDragEntered: (_) => _setDragging(true),
        onDragExited: (_) => _setDragging(false),
        onDragDone: (details) => _handleDrop(details.files),
        child: Stack(
          children: [
            Column(
              children: [
                _buildConnectionPanel(connection),
                const Divider(height: 1),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: const TransferPanel(),
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: _buildMessageList(chat)),
                _buildInputBar(connection),
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

  // ---------- 连接区 ----------

  Widget _buildConnectionPanel(ConnectionViewModel vm) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _StatusChip(status: vm.status, remoteName: vm.remoteName),
              const Spacer(),
              if (vm.isConnected)
                TextButton.icon(
                  onPressed: vm.disconnect,
                  icon: const Icon(Icons.link_off, size: 18),
                  label: const Text('断开'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _buildLocalAddressRow(vm),
          const SizedBox(height: 8),
          if (vm.peers.isEmpty)
            const Text('正在搜索局域网内的设备…', style: TextStyle(fontSize: 13))
          else
            Wrap(
              spacing: 8,
              children: [
                for (final peer in vm.peers)
                  ActionChip(
                    avatar: const Icon(Icons.computer, size: 18),
                    label: Text('${peer.name} (${peer.ip})'),
                    onPressed: () => vm.connectToPeer(peer),
                  ),
              ],
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ipController,
                  decoration: const InputDecoration(
                    hintText: '手动连接：输入 IP 或 IP:端口',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _connectManual(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _connectManual,
                child: const Text('连接'),
              ),
            ],
          ),
          if (vm.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                vm.errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  /// 本机地址行：点击文字或按钮即复制，方便发给对方手动连接。
  Widget _buildLocalAddressRow(ConnectionViewModel vm) {
    final endpoint = vm.localInfo?.endpoint;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: endpoint == null ? null : () => _copyToClipboard(endpoint, '本机地址'),
          child: Text(
            '本机地址：${endpoint ?? '获取中…'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        SizedBox(
          width: 28,
          height: 28,
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 16,
            tooltip: '复制本机地址（IP:端口）',
            onPressed:
                endpoint == null ? null : () => _copyToClipboard(endpoint, '本机地址'),
            icon: const Icon(Icons.copy),
          ),
        ),
        SizedBox(
          width: 28,
          height: 28,
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 16,
            tooltip: '仅复制 IP',
            onPressed: vm.localInfo == null
                ? null
                : () => _copyToClipboard(vm.localInfo!.ip, 'IP'),
            icon: const Icon(Icons.copy_all),
          ),
        ),
      ],
    );
  }

  Future<void> _copyToClipboard(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _showMessage('已复制$label：$text');
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
  }

  // ---------- 消息区 ----------

  Widget _buildMessageList(ChatViewModel vm) {
    if (vm.messages.isEmpty) {
      return const Center(
        child: Text('还没有消息 —— 先连接一台设备，然后发送一条试试'),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(12),
      itemCount: vm.messages.length,
      itemBuilder: (context, index) => _MessageBubble(message: vm.messages[index]),
    );
  }

  // ---------- 输入区 ----------

  Widget _buildInputBar(ConnectionViewModel connection) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _messageController,
              decoration: const InputDecoration(
                hintText: '输入消息…',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: connection.isConnected ? _send : null,
            icon: const Icon(Icons.send),
            tooltip: '发送',
          ),
        ],
      ),
    );
  }

  // ---------- 交互 ----------

  Future<void> _send() async {
    final text = _messageController.text;
    if (text.trim().isEmpty) return;

    _messageController.clear();
    await context.read<ChatViewModel>().send(text);
    _scrollToBottom();
  }

  void _connectManual() {
    final input = _ipController.text.trim();
    if (input.isEmpty) return;

    final parts = input.split(':');
    if (parts.length == 2) {
      final port = int.tryParse(parts[1]);
      context.read<ConnectionViewModel>().connect(
            parts[0],
            port: port,
          );
    } else {
      context.read<ConnectionViewModel>().connect(input);
    }
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }
}

/// 拖拽悬停时的提示层。
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: theme.colorScheme.surface.withValues(alpha: 0.75),
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            decoration: BoxDecoration(
              border: Border.all(
                color: theme.colorScheme.primary,
                width: 2,
                strokeAlign: BorderSide.strokeAlignInside,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.download_for_offline_outlined,
                  size: 32,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 8),
                Text(
                  '松手即发送给对方',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '支持 ${AppConfig.allowedFileExtensions.join(' / ')}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 连接状态标签。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status, required this.remoteName});

  final ConnectionStatus status;
  final String? remoteName;

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (status) {
      ConnectionStatus.connected => (
          '已连接${remoteName != null ? '：$remoteName' : ''}',
          Colors.green,
        ),
      ConnectionStatus.connecting => ('连接中…', Colors.orange),
      ConnectionStatus.disconnected => ('未连接', Colors.grey),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: color),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// 单条消息气泡。
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSelf = message.isSelf;

    return Align(
      alignment: isSelf ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: isSelf
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment:
              isSelf ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              isSelf ? '我' : message.sender,
              style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(message.text),
          ],
        ),
      ),
    );
  }
}
