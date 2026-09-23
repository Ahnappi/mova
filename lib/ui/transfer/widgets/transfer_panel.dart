import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../config/app_config.dart';
import '../../../../domain/models/transfer/transfer_task.dart';
import '../../../../utils/format.dart';
import '../../chat/view_models/connection_view_model.dart';
import '../view_models/transfer_view_model.dart';

/// 文件传输面板（View 层）：发起发送、处理接收请求、展示双方进度。
///
/// 只做展示与交互，逻辑全部委托给 [TransferViewModel]。
class TransferPanel extends StatelessWidget {
  const TransferPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final transfer = context.watch<TransferViewModel>();
    final connection = context.watch<ConnectionViewModel>();

    final tasks = transfer.tasks.reversed.toList(growable: false);
    final offers = transfer.pendingOffers;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text('文件传输', style: theme.textTheme.titleSmall),
            const SizedBox(width: 8),
            Text(
              '支持 ${AppConfig.allowedFileExtensions.join(' / ')}',
              style: theme.textTheme.bodySmall,
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed:
                  connection.isConnected ? transfer.pickAndSendFiles : null,
              icon: const Icon(Icons.attach_file, size: 18),
              label: const Text('发送文件'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _buildSaveDirectoryRow(context, transfer),
        if (offers.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final offer in offers) _OfferTile(task: offer),
        ],
        const SizedBox(height: 8),
        if (tasks.isEmpty)
          Text(
            connection.isConnected
                ? '还没有文件传输 —— 点「发送文件」选择，或把文件直接拖进窗口'
                : '连接后即可传输文件',
            style: theme.textTheme.bodySmall,
          )
        else
          for (final task in tasks) _TaskTile(task: task),
      ],
    );
  }

  /// 接收文件的保存位置（可更改，会被记住）。
  Widget _buildSaveDirectoryRow(BuildContext context, TransferViewModel vm) {
    final theme = Theme.of(context);
    final directory = vm.saveDirectory;

    // 注意：这里不能设 mainAxisSize.min —— 那样 Flexible 会拿到 0 宽度，
    // 路径文字会被压没。占满整行，超长时省略。
    return Row(
      children: [
        const Icon(Icons.folder_outlined, size: 14),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            '接收到：${directory ?? '获取中…'}',
            style: theme.textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        SizedBox(
          width: 26,
          height: 26,
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 15,
            tooltip: '更改接收文件的保存位置',
            onPressed: vm.chooseSaveDirectory,
            icon: const Icon(Icons.edit_outlined),
          ),
        ),
      ],
    );
  }
}

/// 待确认的接收请求。
class _OfferTile extends StatelessWidget {
  const _OfferTile({required this.task});

  final TransferTask task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vm = context.read<TransferViewModel>();

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.download_rounded, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(task.fileName, overflow: TextOverflow.ellipsis),
                Text(
                  '对方请求发送 · ${formatBytes(task.totalBytes)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => vm.acceptToDefaultDirectory(task.id),
            child: const Text('接收'),
          ),
          TextButton(
            onPressed: () => vm.acceptWithDirectoryPicker(task.id),
            child: const Text('存到…'),
          ),
          TextButton(
            onPressed: () => vm.reject(task.id),
            child: const Text('拒绝'),
          ),
        ],
      ),
    );
  }
}

/// 单个传输任务（发送或接收共用）。
class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task});

  final TransferTask task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vm = context.read<TransferViewModel>();
    final isSending = task.direction == TransferDirection.sending;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            isSending ? Icons.upload_rounded : Icons.download_rounded,
            size: 20,
            color: isSending
                ? theme.colorScheme.primary
                : theme.colorScheme.secondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        task.fileName,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Text(
                      '${(task.progress * 100).toStringAsFixed(0)}%',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: task.status == TransferStatus.waiting ? null : task.progress,
                  minHeight: 4,
                ),
                const SizedBox(height: 2),
                Text(
                  _detailText(task),
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (task.isActive)
            IconButton(
              tooltip: '取消',
              iconSize: 18,
              onPressed: () => vm.cancel(task.id),
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
  }

  String _detailText(TransferTask task) {
    final done = formatBytes(task.transferredBytes);
    final total = formatBytes(task.totalBytes);

    return switch (task.status) {
      TransferStatus.waiting => task.direction == TransferDirection.sending
          ? '等待对方确认 · $total'
          : '待接收 · $total',
      TransferStatus.transferring =>
        '$done / $total · ${formatSpeed(task.speedBytesPerSecond)}',
      TransferStatus.completed => '已完成 · $total${_pathHint(task)}',
      TransferStatus.rejected => '对方已拒绝',
      TransferStatus.canceled => '已取消',
      TransferStatus.failed => '失败：${task.error ?? '未知错误'}',
    };
  }

  String _pathHint(TransferTask task) {
    final path = task.localPath;
    if (path == null || path.isEmpty) return '';
    return ' · 已保存到 $path';
  }
}
