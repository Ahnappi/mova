import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_motion_widgets.dart';
import '../../theme/app_theme.dart';

/// 统一的操作提示条（连接类 / 传输类共用）。
///
/// 完整的系统报错往往是一长串（如 `PathAccessException ... errno = 1`），
/// 界面上放不下，用户也没法照着敲，因此必须能一键复制。
/// 权限被系统拒绝时另外给出「打开系统设置」之类的出口。
class ErrorNoticeBar extends StatelessWidget {
  const ErrorNoticeBar({
    super.key,
    required this.message,
    required this.onDismiss,
    this.hint,
    this.actions = const <ErrorAction>[],
  });

  final String message;
  final VoidCallback onDismiss;

  /// 补充说明（通常告诉用户该去系统哪里放行）。
  final String? hint;

  /// 额外的行动入口（打开设置、换个保存位置等）。
  final List<ErrorAction> actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppDimens.pagePadding,
        0,
        AppDimens.pagePadding,
        8,
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.07),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(AppDimens.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.error_outline_rounded,
                    size: 16, color: AppColors.danger),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: AppColors.danger,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
              IconButton(
                tooltip: '复制错误信息',
                onPressed: () => _copy(context, message),
                icon: const Icon(Icons.copy_all_rounded,
                    size: 16, color: AppColors.danger),
                constraints:
                    const BoxConstraints.tightFor(width: 30, height: 30),
                padding: EdgeInsets.zero,
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: onDismiss,
                icon: const Icon(Icons.close_rounded,
                    size: 16, color: AppColors.textSecondary),
                constraints:
                    const BoxConstraints.tightFor(width: 30, height: 30),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(
              hint!,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  _SmallAction(
                    label: actions[i].label,
                    onTap: actions[i].onTap,
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('错误信息已复制'),
          duration: Duration(seconds: 2),
        ),
      );
  }
}

/// 提示条里的一个行动入口。
class ErrorAction {
  const ErrorAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;
}

/// 错误条里的文字按钮（保持与界面其它文字按钮一致的观感）。
class _SmallAction extends StatelessWidget {
  const _SmallAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          label,
          style: const TextStyle(
            color: AppColors.primary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
