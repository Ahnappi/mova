import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/models/transfer/transfer_task.dart';
import '../../theme/app_motion_widgets.dart';
import '../../theme/app_theme.dart';
import '../../../utils/format.dart';
import '../view_models/transfer_view_model.dart';

/// 待接收面板（View 层）：把对方发来的文件一次性全列出来，可勾选后批量处理。
///
/// 在此之前每个文件是聊天流里一张独立卡片：一次发十个就要点十次「接收」，
/// 而「部分同意」根本没法表达——没点的那些既不接收也不拒绝，发送端只能
/// 干等 [AppConfig.offerResponseTimeout] 那 120 秒才自己放弃。
///
/// 返回 `true` 表示用户已经做出决定（接收 / 拒绝），`false` 表示只是关掉
/// 面板（稍后处理，卡片仍在聊天流里，可以逐个点）。
Future<bool> showIncomingOffersDialog(
  BuildContext context, {
  required String peerName,
}) async {
  final result = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '稍后处理',
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
    pageBuilder: (_, _, _) => _IncomingOffersDialog(peerName: peerName),
  );
  return result ?? false;
}

class _IncomingOffersDialog extends StatelessWidget {
  const _IncomingOffersDialog({required this.peerName});

  final String peerName;

  @override
  Widget build(BuildContext context) {
    // 只订阅「待接收集合 + 勾选状态」这个指纹：传输进度每秒刷新十次，
    // 面板不能被别人的进度带着重画。
    final signature = context.select<TransferViewModel, String>(
      (vm) => vm.offerSelectionSignature,
    );

    // 全部处理完了（或者对方撤回了请求），面板自己退场。
    if (signature.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).pop(true);
      });
      return const SizedBox.shrink();
    }

    final vm = context.read<TransferViewModel>();
    final offers = vm.pendingOffers;
    final selected = vm.selectedOfferCount;

    return Dialog(
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _Header(peerName: peerName, count: offers.length),
            _ConcurrencyHint(text: vm.concurrencyHint),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: offers.length,
                itemBuilder: (context, index) =>
                    _OfferRow(vm: vm, task: offers[index]),
              ),
            ),
            const Divider(height: 1),
            _Footer(vm: vm, selected: selected, total: offers.length),
          ],
        ),
      ),
    );
  }
}

/// 标题行：谁发来的、几个、一共多大。
class _Header extends StatelessWidget {
  const _Header({required this.peerName, required this.count});

  final String peerName;
  final int count;

  @override
  Widget build(BuildContext context) {
    final vm = context.read<TransferViewModel>();
    final offers = vm.pendingOffers;
    final total = offers.fold<int>(0, (sum, task) => sum + task.totalBytes);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '「$peerName」发来 $count 个文件',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '共 ${formatBytes(total)} · 勾选后接收，未勾选的会被拒绝',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          // 「稍后处理」：关掉面板，卡片留在聊天流里可以逐个点。
          SizedBox(
            width: 32,
            height: 32,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 18,
              tooltip: '稍后处理',
              onPressed: () => Navigator.of(context).pop(false),
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    );
  }
}

/// 并发上限提示：不写出来的话，用户看到「点了 10 个接收、只动了 3 个」
/// 会以为程序卡住了。
class _ConcurrencyHint extends StatelessWidget {
  const _ConcurrencyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 10),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded,
              size: 14, color: AppColors.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行一个文件：整行可点，右侧是大小。
class _OfferRow extends StatelessWidget {
  const _OfferRow({required this.vm, required this.task});

  final TransferViewModel vm;
  final TransferTask task;

  @override
  Widget build(BuildContext context) {
    final checked = vm.isOfferSelected(task.id);

    return InkWell(
      onTap: () => vm.toggleOfferSelection(task.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Checkbox(
              value: checked,
              onChanged: (_) => vm.toggleOfferSelection(task.id),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 6),
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(_icon(task.fileName),
                  size: 18, color: AppColors.textPrimary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                  // 同一批发来的文件标一下序号，方便对上发送端的顺序。
                  if (task.batchCount != null && task.batchCount! > 1) ...[
                    const SizedBox(height: 2),
                    Text(
                      '第 ${task.batchIndex ?? 0} / ${task.batchCount} 个',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              formatBytes(task.totalBytes),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _icon(String name) {
    final ext =
        name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'pdf' => Icons.picture_as_pdf_outlined,
      'xls' || 'xlsx' => Icons.table_chart_outlined,
      'doc' || 'docx' => Icons.description_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}

/// 底部操作区：全选 / 全部拒绝 / 存到… / 接收 N 个。
class _Footer extends StatelessWidget {
  const _Footer({
    required this.vm,
    required this.selected,
    required this.total,
  });

  final TransferViewModel vm;
  final int selected;
  final int total;

  @override
  Widget build(BuildContext context) {
    final allSelected = selected >= total;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 24, 18),
      child: Row(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 三态：全选 / 部分勾选 / 全不选，点一下在两者之间切换。
              Checkbox(
                tristate: true,
                value: allSelected ? true : (selected == 0 ? false : null),
                onChanged: (_) => vm.toggleSelectAllOffers(),
                visualDensity: VisualDensity.compact,
              ),
              const Text(
                '全选',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const Spacer(),
          PressableScale(
            onTap: () => _rejectAll(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                '全部拒绝',
                style: TextStyle(
                  color: AppColors.danger,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          PressableScale(
            onTap: selected == 0 ? null : () => _accept(context, pickDir: true),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(AppDimens.radiusPill),
              ),
              child: const Text(
                '存到…',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(width: 10),
          PressableScale(
            onTap: selected == 0 ? null : () => _accept(context),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: selected == 0 ? AppColors.border : AppColors.primary,
                borderRadius: BorderRadius.circular(AppDimens.radiusPill),
              ),
              child: Text(
                selected == 0 ? '接收' : '接收 $selected 个',
                style: TextStyle(
                  color: selected == 0 ? AppColors.textSecondary : Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 先关面板再开工：接收动作要弹目录选择框、还要建临时文件，
  /// 面板挡在上面既碍事，也会让「点完没反应」的窗口变长。
  void _accept(BuildContext context, {bool pickDir = false}) {
    final transfer = context.read<TransferViewModel>();
    Navigator.of(context).pop(true);

    if (pickDir) {
      unawaited(transfer.acceptSelectedWithDirectoryPicker());
    } else {
      unawaited(transfer.acceptSelected());
    }
  }

  void _rejectAll(BuildContext context) {
    final transfer = context.read<TransferViewModel>();
    Navigator.of(context).pop(true);
    unawaited(transfer.rejectPending());
  }
}
