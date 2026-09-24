import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/history/history_repository.dart';
import '../../../data/services/storage/storage_service.dart';
import '../../../domain/models/history/session_record.dart';
import '../../../utils/format.dart';
import '../../theme/app_motion_widgets.dart';
import '../../theme/app_theme.dart';
import '../view_models/history_view_model.dart';

/// 连接记录面板（View 层）：左侧会话列表，右侧该次连接的消息与文件。
class HistoryPanel extends StatelessWidget {
  const HistoryPanel({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => HistoryViewModel(
        historyRepository: context.read<HistoryRepository>(),
        storageService: context.read<StorageService>(),
      ),
      child: _HistoryPanelBody(onClose: onClose),
    );
  }
}

class _HistoryPanelBody extends StatefulWidget {
  const _HistoryPanelBody({required this.onClose});

  final VoidCallback onClose;

  @override
  State<_HistoryPanelBody> createState() => _HistoryPanelBodyState();
}

class _HistoryPanelBodyState extends State<_HistoryPanelBody> {
  bool _confirmClear = false;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<HistoryViewModel>();

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PanelHeader(onClose: widget.onClose),
          const Divider(height: 1),
          Expanded(
            child: vm.sessions.isEmpty
                ? const _PanelEmptyState()
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(width: 216, child: _SessionList()),
                      const VerticalDivider(width: 1),
                      Expanded(child: _SessionDetail(vm: vm)),
                    ],
                  ),
          ),
          const Divider(height: 1),
          _PanelFooter(
            confirmClear: _confirmClear,
            onRequestClear: () => setState(() => _confirmClear = true),
            onCancelClear: () => setState(() => _confirmClear = false),
            onClear: () async {
              setState(() => _confirmClear = false);
              await vm.clearAll();
              if (!mounted) return;
              _showMessage('已清空全部连接记录（进行中的连接保留）');
            },
          ),
        ],
      ),
    );
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
  }
}

/// 面板头部：标题 + 关闭。
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final count = context.watch<HistoryViewModel>().sessions.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 12, 14),
      child: Row(
        children: [
          const Icon(Icons.history_rounded, size: 20),
          const SizedBox(width: 10),
          const Text(
            '连接记录',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 8),
          Text(
            count == 0 ? '' : '$count 次连接',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: '关闭',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

/// 左侧会话列表。
class _SessionList extends StatelessWidget {
  const _SessionList();

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<HistoryViewModel>();
    final sessions = vm.sessions;
    final selectedId = vm.selected?.id;

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sessions.length,
      itemBuilder: (context, index) {
        final session = sessions[index];
        return _SessionTile(
          session: session,
          selected: session.id == selectedId,
          onTap: () => vm.select(session.id),
        );
      },
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.selected,
    required this.onTap,
  });

  final SessionRecord session;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.surfaceMuted : AppColors.background,
          borderRadius: BorderRadius.circular(AppDimens.radiusCard),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.monitor_outlined,
                    size: 16, color: AppColors.textPrimary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    session.peerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (session.isActive)
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: AppColors.success,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              session.peerIp.isEmpty ? '未知地址' : session.peerIp,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 3),
            Text(
              _formatDateTime(session.startedAt),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '${session.messages.length} 条消息 · ${session.files.length} 个文件',
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 右侧详情：一次连接的消息与文件。
class _SessionDetail extends StatelessWidget {
  const _SessionDetail({required this.vm});

  final HistoryViewModel vm;

  @override
  Widget build(BuildContext context) {
    final session = vm.selected;

    if (session == null) {
      return const Center(
        child: Text(
          '选择左侧的一次连接，查看当时的对话与文件',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
      );
    }

    final entries = <_DetailEntry>[
      for (final message in session.messages)
        _DetailEntry(time: message.timestamp, message: message),
      for (final file in session.files)
        _DetailEntry(time: file.createdAt, file: file),
    ]..sort((a, b) => a.time.compareTo(b.time));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DetailHeader(vm: vm, session: session),
        const Divider(height: 1),
        Expanded(
          child: entries.isEmpty
              ? const Center(
                  child: Text(
                    '这次连接没有消息，也没有文件',
                    style:
                        TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    if (entry.message != null) {
                      return _HistoryBubble(message: entry.message!);
                    }
                    return _HistoryFileCard(vm: vm, file: entry.file!);
                  },
                ),
        ),
      ],
    );
  }
}

class _DetailEntry {
  const _DetailEntry({required this.time, this.message, this.file});

  final DateTime time;
  final SessionMessage? message;
  final SessionFile? file;
}

/// 详情头部：对端信息 + 连接时段 + 删除。
class _DetailHeader extends StatelessWidget {
  const _DetailHeader({required this.vm, required this.session});

  final HistoryViewModel vm;
  final SessionRecord session;

  @override
  Widget build(BuildContext context) {
    final ended = session.endedAt;
    final period = ended == null
        ? '${_formatDateTime(session.startedAt)} 连接 · 进行中'
        : '${_formatDateTime(session.startedAt)} — ${_formatClock(ended)}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.peerName,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  session.peerIp.isEmpty ? '未知地址' : session.peerIp,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  period,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '删除这条连接记录',
            onPressed: () => vm.delete(session.id),
            icon: const Icon(Icons.delete_outline_rounded, size: 19),
          ),
        ],
      ),
    );
  }
}

/// 历史消息气泡（与主界面一致的左右分栏）。
class _HistoryBubble extends StatelessWidget {
  const _HistoryBubble({required this.message});

  final SessionMessage message;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment:
          message.isSelf ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: message.isSelf ? AppColors.primary : AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(AppDimens.radiusCard),
        ),
        child: Text(
          message.text,
          style: TextStyle(
            fontSize: 14,
            height: 1.45,
            color: message.isSelf ? Colors.white : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// 历史文件卡：文件名、大小、结果，以及**当时的路径**。
class _HistoryFileCard extends StatelessWidget {
  const _HistoryFileCard({required this.vm, required this.file});

  final HistoryViewModel vm;
  final SessionFile file;

  @override
  Widget build(BuildContext context) {
    final path = file.localPath;
    final exists = vm.fileExists(path);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppDimens.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_iconFor(file.fileName),
                  size: 20, color: AppColors.textPrimary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  file.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatBytes(file.sizeBytes),
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                file.direction == SessionFileDirection.sent
                    ? '已发送'
                    : '已接收',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _statusText(file.status),
                style: TextStyle(
                  color: _statusColor(file.status),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatClock(file.createdAt),
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          if (path != null && path.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.folder_outlined,
                    size: 13, color: AppColors.textSecondary),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    path,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11.5,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _SmallAction(
                  tooltip: '复制路径',
                  icon: Icons.copy_rounded,
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: path));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        const SnackBar(
                          content: Text('已复制路径'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                  },
                ),
                if (exists)
                  _SmallAction(
                    tooltip: '在文件管理器中显示',
                    icon: Icons.visibility_outlined,
                    onTap: () => vm.reveal(path),
                  ),
              ],
            ),
            if (!exists)
              const Padding(
                padding: EdgeInsets.only(top: 5),
                child: Text(
                  '文件已不在原位置',
                  style: TextStyle(color: AppColors.danger, fontSize: 11.5),
                ),
              ),
          ],
          if (file.error != null && file.error!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                file.error!,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11.5,
                ),
              ),
            ),
        ],
      ),
    );
  }

  IconData _iconFor(String name) {
    final ext = name.contains('.')
        ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
        : '';
    const images = {
      'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'tif',
      'tiff', 'svg', 'ico',
    };
    const videos = {
      'mp4', 'mov', 'm4v', 'avi', 'mkv', 'flv', 'wmv', 'webm', '3gp', 'mpg',
      'mpeg', 'ts',
    };
    if (images.contains(ext)) return Icons.image_outlined;
    if (videos.contains(ext)) return Icons.movie_outlined;
    return Icons.description_outlined;
  }

  String _statusText(SessionFileStatus status) => switch (status) {
        SessionFileStatus.completed => '完成',
        SessionFileStatus.rejected => '对方拒绝',
        SessionFileStatus.canceled => '已取消',
        SessionFileStatus.failed => '失败',
        SessionFileStatus.pending => '未完成',
      };

  Color _statusColor(SessionFileStatus status) => switch (status) {
        SessionFileStatus.completed => AppColors.success,
        SessionFileStatus.pending => AppColors.textSecondary,
        SessionFileStatus.canceled => AppColors.textSecondary,
        SessionFileStatus.rejected => AppColors.textSecondary,
        SessionFileStatus.failed => AppColors.danger,
      };
}

/// 文件卡内的小号操作按钮。
class _SmallAction extends StatelessWidget {
  const _SmallAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: PressableScale(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(icon, size: 15, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}

/// 面板底部：清空全部（需二次确认）。
class _PanelFooter extends StatelessWidget {
  const _PanelFooter({
    required this.confirmClear,
    required this.onRequestClear,
    required this.onCancelClear,
    required this.onClear,
  });

  final bool confirmClear;
  final VoidCallback onRequestClear;
  final VoidCallback onCancelClear;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (confirmClear) {
      return Container(
        color: AppColors.surfaceMuted,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '清空后不可恢复，确定继续？',
                style: TextStyle(fontSize: 13),
              ),
            ),
            PressableScale(
              onTap: onCancelClear,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.border),
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                ),
                child: const Text(
                  '取消',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(width: 10),
            PressableScale(
              onTap: onClear,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.danger,
                  borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                ),
                child: const Text(
                  '清空',
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              '记录保存在 history.json，可在「数据存放位置」中查看',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 11.5),
            ),
          ),
          PressableScale(
            onTap: onRequestClear,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.delete_outline_rounded,
                      size: 15, color: AppColors.danger),
                  SizedBox(width: 4),
                  Text(
                    '清空全部',
                    style: TextStyle(
                      color: AppColors.danger,
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
    );
  }
}

/// 空态。
class _PanelEmptyState extends StatelessWidget {
  const _PanelEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history_toggle_off_rounded,
              size: 30, color: AppColors.idle),
          SizedBox(height: 14),
          Text(
            '还没有连接记录',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 6),
          Text(
            '每次成功连接都会留下一条记录，重启后依然保留',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

String _formatClock(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

String _formatDateTime(DateTime time) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(time.year, time.month, time.day);

  if (that == today) return '今天 ${_formatClock(time)}';
  if (that == today.subtract(const Duration(days: 1))) {
    return '昨天 ${_formatClock(time)}';
  }
  return '${time.month}月${time.day}日 ${_formatClock(time)}';
}
