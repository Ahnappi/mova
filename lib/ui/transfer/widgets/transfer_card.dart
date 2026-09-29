import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../config/app_config.dart';
import '../../../domain/models/transfer/transfer_task.dart';
import '../../preview/preview_kind.dart';
import '../../preview/widgets/file_preview_dialog.dart';
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
    required this.onRetry,
  });

  final TransferTask task;
  final VoidCallback onAccept;
  final VoidCallback onSaveAs;
  final VoidCallback onReject;
  final VoidCallback onCancel;

  /// 重新发送（只有发送失败时才在卡片上出现）。
  final VoidCallback onRetry;

  /// 发送方靠右、接收方靠左（与消息气泡同向，方便区分）。
  bool get _isSending => task.direction == TransferDirection.sending;

  /// 能否重新发送：只有「自己发出去、并且失败了」的文件才可能重发。
  ///
  /// 接收失败时文件在对方手里，我们重发无从谈起——
  /// 给它一个按钮只会让人白点一次。
  bool get _canRetry =>
      task.status == TransferStatus.failed && _isSending;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: _isSending ? Alignment.centerRight : Alignment.centerLeft,
      child: task.status == TransferStatus.waiting && _isOffer
          ? _OfferCard(
              task: task,
              onAccept: onAccept,
              onSaveAs: onSaveAs,
              onReject: onReject,
            )
          : _buildStateCard(context),
    );
  }

  /// 「待确认」仅对发起方表示等待对方确认，不需要操作按钮；
  /// 接收方的待确认才是真正的「接收请求」。
  bool get _isOffer => task.direction == TransferDirection.receiving;

  Widget _buildStateCard(BuildContext context) {
    // 「等回执」也算进行中：数据发完了，但还没确认对方存好。
    // 「排队中」同样算：它随时会轮到自己。
    final inProgress =
        task.status == TransferStatus.transferring ||
        task.status == TransferStatus.waiting ||
        task.status == TransferStatus.queued ||
        task.status == TransferStatus.preparing ||
        task.status == TransferStatus.confirming;

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
                        task.status == TransferStatus.transferring
                            ? formatSpeed(task.speedBytesPerSecond)
                            : task.status == TransferStatus.confirming
                                ? '等待对方核对…'
                                : task.status == TransferStatus.queued
                                    ? '排队中，前面的文件传完就开始…'
                                    : task.status == TransferStatus.preparing
                                        ? '正在准备接收…'
                                        : '等待对方确认…',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // 第二行：已传/总量 + 预计剩余时间。
                  // 剩余时间用平滑速度估算，刚开始传时还没有样本，显示「正在估算」。
                  Row(
                    children: [
                      Text(
                        '${formatBytes(task.transferredBytes)} / ${formatBytes(task.totalBytes)}',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _etaText(task),
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ] else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _finishedText(task),
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      // 接收失败时文件在对方手里，这里没有可重发的东西，
                      // 明确说出来比给一个点不动的按钮强。
                      if (_canRetry) ...[
                        const SizedBox(height: 8),
                        _RetryButton(onRetry: onRetry),
                      ] else if (task.status == TransferStatus.failed) ...[
                        const SizedBox(height: 6),
                        const Text(
                          '这是对方发来的文件，需要对方重新发送',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      // 失败原因常常是一长串系统错误，界面上放不下，
                      // 给一个复制入口方便直接拿去查。
                      if (task.status == TransferStatus.failed &&
                          task.error != null) ...[
                        const SizedBox(height: 6),
                        _CopyErrorButton(message: task.error!),
                      ],
                      // 传完就能直接看：接收方看收到的文件，发送方看源文件。
                      if (_canPreview) ...[
                        const SizedBox(height: 6),
                        _PreviewButton(path: task.localPath!),
                      ],
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 只有传完且手里有实际路径时才提供预览。
  bool get _canPreview {
    if (task.status != TransferStatus.completed) return false;
    final path = task.localPath;
    return path != null && path.isNotEmpty;
  }

  /// 剩余时间文案；传输刚开始还没采到速度样本时给出中性提示。
  String _etaText(TransferTask task) {
    if (task.status != TransferStatus.transferring) return '';
    final eta = task.etaSeconds;
    if (eta == null) return '正在估算剩余时间…';
    return formatEta(eta);
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

/// 「复制错误信息」：把完整的系统报错放到剪贴板，便于检索或反馈。
class _CopyErrorButton extends StatelessWidget {
  const _CopyErrorButton({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: message));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('错误信息已复制'),
              duration: Duration(seconds: 2),
            ),
          );
      },
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.copy_all_rounded,
              size: 14, color: AppColors.textSecondary),
          SizedBox(width: 4),
          Text(
            '复制错误信息',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「预览」：打开全屏预览层直接看刚传完的文件。
class _PreviewButton extends StatelessWidget {
  const _PreviewButton({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final kind = previewKindOf(extensionOf(path));
    // Office / SVG 这类渲染不了的格式也提供入口，
    // 预览层内会给出「用系统默认应用打开」。
    final label = kind == PreviewKind.external ? '打开' : '预览';

    return PressableScale(
      onTap: () => showFilePreview(context, path),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            kind == PreviewKind.external
                ? Icons.open_in_new_rounded
                : Icons.visibility_outlined,
            size: 14,
            color: AppColors.primary,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.primary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「重新发送」：失败的任务不用回到文件选择器再来一遍。
class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onRetry,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(AppDimens.radiusPill),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.refresh_rounded, size: 14, color: AppColors.primary),
            SizedBox(width: 6),
            Text(
              '重新发送',
              style: TextStyle(
                color: AppColors.primary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
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
