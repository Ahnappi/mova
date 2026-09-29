import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/models/chat/chat_message.dart';
import '../../../domain/models/transfer/transfer_task.dart';
import '../../theme/app_theme.dart';
import '../../transfer/view_models/transfer_view_model.dart';
import '../../transfer/widgets/transfer_card.dart';

/// 时间线上的一条：要么是消息，要么是文件传输。
class TimelineEntry {
  const TimelineEntry({required this.time, this.message, this.task});

  final DateTime time;
  final ChatMessage? message;
  final TransferTask? task;
}

/// 消息/文件卡时间线区域；无内容时显示空态。
///
/// 文件卡用 [Selector] 只订阅自己的那条任务：传输进度每秒刷新十次，
/// 如果整条时间线跟着重建，滚动和输入都会明显发涩。
class TimelineArea extends StatelessWidget {
  const TimelineArea({
    super.key,
    required this.entries,
    required this.controller,
    required this.animateLast,
    required this.onAnimateLast,
  });

  final List<TimelineEntry> entries;
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
              MessageBubble(message: entry.message!)
            else
              _TransferSlot(task: entry.task!),
          ],
        );
      },
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

/// 单张文件卡：只跟随自己那条任务刷新。
class _TransferSlot extends StatelessWidget {
  const _TransferSlot({required this.task});

  final TransferTask task;

  @override
  Widget build(BuildContext context) {
    return Selector<TransferViewModel, TransferTask?>(
      selector: (context, vm) => vm.taskById(task.id),
      builder: (context, live, _) {
        final current = live ?? task;
        final vm = context.read<TransferViewModel>();

        return TransferCard(
          task: current,
          onAccept: () => vm.acceptToDefaultDirectory(current.id),
          onSaveAs: () => vm.acceptWithDirectoryPicker(current.id),
          onReject: () => vm.reject(current.id),
          onCancel: () => vm.cancel(current.id),
          onRetry: () => vm.retry(current.id),
        );
      },
    );
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
              Icon(Icons.monitor_outlined, size: 26, color: AppColors.idle),
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
class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});

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
