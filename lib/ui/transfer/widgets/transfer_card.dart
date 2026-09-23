import 'package:flutter/material.dart';

import '../../../config/app_config.dart';
import '../../../domain/models/transfer/transfer_task.dart';
import '../../theme/app_motion_widgets.dart';
import '../../theme/app_theme.dart';
import '../../../utils/format.dart';

/// 聊天流里的文件传输卡片（设计稿 02）。
///
/// 三种形态：
/// - 待确认：文件信息 + 接收 / 存到… / 拒绝
/// - 进行中：文件名 + 进度条 + 百分比 + 已传/总量
/// - 已终结：状态图标 + 文件名 + 结果说明
class TransferCard extends StatelessWidget {
  const TransferCard({
    super.key,
    required this.task,
    required this.onAccept,
    required this.onSaveAs,
    required this.onReject,
    required this.onCancel,
  });

  final TransferTask task;
  final VoidCallback onAccept;
  final VoidCallback onSaveAs;
  final VoidCallback onReject;
  final VoidCallback onCancel;

  /// 发送方靠右、接收方靠左（与消息气泡同向，方便区分）。
  bool get _isSending => task.direction == TransferDirection.sending;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: _isSending ? Alignment.centerRight : Alignment.centerLeft,
      child: task.status == TransferStatus.waiting && _isOffer
          ? _OfferCard(task: task, onAccept: onAccept, onSaveAs: onSaveAs, onReject: onReject)
          : _buildStateCard(context),
    );
  }

  /// 「待确认」仅对发起方表示等待对方确认，不需要操作按钮；
  /// 接收方的待确认才是真正的「接收请求」。
  bool get _isOffer => task.direction == TransferDirection.receiving;

  Widget _buildStateCard(BuildContext context) {
    final inProgress =
        task.status == TransferStatus.transferring || task.status == TransferStatus.waiting;

    return Container(
      width: 460,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _isSending ? AppColors.surfaceMuted : AppColors.background,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppDimens.radiusCard),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FileBadge(fileName: task.fileName, done: !inProgress),
          const SizedBox(width: 12),
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
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (inProgress)
                      _CancelButton(onCancel: onCancel),
                  ],
                ),
                const SizedBox(height: 8),
                if (inProgress) ...[
                  SmoothProgress(value: task.progress),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        '${(task.progress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const Spacer(),
                      Text(
                        inProgress && task.status == TransferStatus.transferring
                            ? '${formatBytes(task.transferredBytes)} / ${formatBytes(task.totalBytes)} · ${formatSpeed(task.speedBytesPerSecond)}'
                            : formatBytes(task.totalBytes),
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ] else
                  Text(
                    _finishedText(task),
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _finishedText(TransferTask task) {
    final size = formatBytes(task.totalBytes);
    final path = task.localPath;

    return switch (task.status) {
      TransferStatus.completed =>
        '$size · ${_isSending ? '已送达' : '已保存'}${path == null || path.isEmpty ? '' : '至 $path'}',
      TransferStatus.rejected => '$size · 对方已拒绝',
      TransferStatus.canceled => '$size · 已取消',
      TransferStatus.failed => '$size · 失败：${task.error ?? '未知错误'}',
      _ => size,
    };
  }
}

/// 待确认的接收请求卡片（带操作按钮，稍突出）。
class _OfferCard extends StatelessWidget {
  const _OfferCard({
    required this.task,
    required this.onAccept,
    required this.onSaveAs,
    required this.onReject,
  });

  final TransferTask task;
  final VoidCallback onAccept;
  final VoidCallback onSaveAs;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 460,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(AppDimens.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _FileBadge(fileName: task.fileName, done: false),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.fileName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '对方请求发送 · ${formatBytes(task.totalBytes)}',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              PressableScale(
                onTap: onReject,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text(
                    '拒绝',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              PressableScale(
                onTap: onSaveAs,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border),
                    borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                  ),
                  child: const Text(
                    '存到…',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              PressableScale(
                onTap: onAccept,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                  ),
                  child: const Text(
                    '接收',
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
        ],
      ),
    );
  }
}

/// 文件大类（用于图标与提示）。
enum TransferFileKind { image, video, document, other }

/// 按扩展名判断文件大类。
TransferFileKind _kindOf(String extension) {
  if (AppConfig.imageExtensions.contains(extension)) {
    return TransferFileKind.image;
  }
  if (AppConfig.videoExtensions.contains(extension)) {
    return TransferFileKind.video;
  }
  if (AppConfig.documentExtensions.contains(extension)) {
    return TransferFileKind.document;
  }
  return TransferFileKind.other;
}

/// 已完成传输的文件类型图标（按扩展名区分），完成后显示对勾。
class _FileBadge extends StatelessWidget {
  const _FileBadge({required this.fileName, required this.done});

  final String fileName;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';

    final icon = switch (ext) {
      'pdf' => Icons.picture_as_pdf_outlined,
      'xls' || 'xlsx' => Icons.table_chart_outlined,
      'doc' || 'docx' => Icons.description_outlined,
      _ => switch (_kindOf(ext)) {
          TransferFileKind.image => Icons.image_outlined,
          TransferFileKind.video => Icons.movie_outlined,
          _ => Icons.insert_drive_file_outlined,
        },
    };

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: done ? Colors.white : AppColors.surfaceMuted,
        shape: BoxShape.circle,
        border: done ? Border.all(color: AppColors.border) : null,
      ),
      child: done
          ? const Icon(Icons.check, size: 20, color: AppColors.primary)
          : Icon(icon, size: 20, color: AppColors.textPrimary),
    );
  }
}

class _CancelButton extends StatelessWidget {
  const _CancelButton({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 24,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 16,
        tooltip: '取消传输',
        onPressed: onCancel,
        icon: const Icon(Icons.close),
      ),
    );
  }
}
