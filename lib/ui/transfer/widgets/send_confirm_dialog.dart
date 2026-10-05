import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../config/app_config.dart';
import '../../../domain/models/transfer/picked_file.dart';
import '../../theme/app_motion_widgets.dart';
import '../../theme/app_theme.dart';
import '../../../utils/format.dart';

/// 发送前的最后一道确认（View 层）。
///
/// 拖文件进窗口、或点了回形针之后都会走到这里：
/// 「选错一个文件发出去」没有撤回键，这一句询问就是唯一的刹车。
///
/// 返回 `true` 表示用户确认发送；取消 / 点击遮罩都是 `false`。
Future<bool> showSendConfirmDialog(
  BuildContext context, {
  required List<PickedFile> files,
  required String peerName,
}) async {
  final result = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: Colors.black.withValues(alpha: 0.28),
    transitionDuration: AppMotion.dialogIn,
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.curve,
        reverseCurve: AppMotion.curve,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          child: child,
        ),
      );
    },
    pageBuilder: (_, _, _) => _SendConfirmDialog(files: files, peerName: peerName),
  );
  return result ?? false;
}

class _SendConfirmDialog extends StatelessWidget {
  const _SendConfirmDialog({required this.files, required this.peerName});

  final List<PickedFile> files;
  final String peerName;

  int get _totalBytes =>
      files.fold<int>(0, (sum, file) => sum + file.size);

  @override
  Widget build(BuildContext context) {
    final count = files.length;

    return Dialog(
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 520),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '发送给「$peerName」？',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '$count 个文件 · 共 ${formatBytes(_totalBytes)}',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  // 超过并发上限时说明一句：否则对面看到「点了 10 个、
                  // 只动了 3 个」会以为卡住了。
                  if (count > AppConfig.maxConcurrentTransfers) ...[
                    const SizedBox(height: 4),
                    Text(
                      '最多同时传输 ${AppConfig.maxConcurrentTransfers} 个，其余自动排队',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: count,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) => _FileRow(file: files[index]),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 18),
              child: Row(
                children: [
                  const Text(
                    '别着急，看一眼再发',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const Spacer(),
                  PressableScale(
                    onTap: () => Navigator.of(context).pop(false),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 10),
                      decoration: BoxDecoration(
                        border: Border.all(color: AppColors.border),
                        borderRadius:
                            BorderRadius.circular(AppDimens.radiusPill),
                      ),
                      child: const Text(
                        '取消',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  PressableScale(
                    onTap: () => Navigator.of(context).pop(true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius:
                            BorderRadius.circular(AppDimens.radiusPill),
                      ),
                      child: const Text(
                        '发送',
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
          ],
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.file});

  final PickedFile file;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.surfaceMuted,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              _icon(p.extension(file.name).replaceFirst('.', '').toLowerCase()),
              size: 18,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            formatBytes(file.size),
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  IconData _icon(String ext) => switch (ext) {
        'pdf' => Icons.picture_as_pdf_outlined,
        'xls' || 'xlsx' => Icons.table_chart_outlined,
        'doc' || 'docx' => Icons.description_outlined,
        _ => Icons.insert_drive_file_outlined,
      };
}
