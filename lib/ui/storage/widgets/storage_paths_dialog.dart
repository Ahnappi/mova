import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/storage/storage_repository.dart';
import '../../../domain/models/storage/storage_entry.dart';
import '../../theme/app_motion_widgets.dart';
import '../../theme/app_theme.dart';
import '../../../utils/format.dart';
import '../view_models/storage_view_model.dart';

/// 打开「数据存放位置」弹窗（缩放 0.96→1 进场 / 反向出场）。
///
/// 点击弹窗外的遮罩即可关闭：modal 的 barrier 必须显式声明可点，
/// 否则用户只能用底部的「完成」按钮退出。
Future<void> showStoragePathsDialog(BuildContext context) {
  return showGeneralDialog(
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
    pageBuilder: (_, _, _) => const StoragePathsDialog(),
  );
}

/// 数据存放位置弹窗（View 层）：列出本应用写入磁盘的所有位置、
/// 标注哪些可以安全删除（日志 / 缓存），并提供复制路径、打开、清理。
class StoragePathsDialog extends StatefulWidget {
  const StoragePathsDialog({super.key});

  @override
  State<StoragePathsDialog> createState() => _StoragePathsDialogState();
}

class _StoragePathsDialogState extends State<StoragePathsDialog> {
  late final StorageViewModel _viewModel;
  StorageEntry? _pendingDelete;

  @override
  void initState() {
    super.initState();
    _viewModel =
        StorageViewModel(storageRepository: context.read<StorageRepository>())
          ..load();
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _viewModel,
      builder: (context, _) {
        final vm = _viewModel;
        final receivedEntry = _findReceivedEntry(vm);

        return Dialog(
          backgroundColor: AppColors.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 620),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 头部：标题 + 刷新圆钮。
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 22, 16, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 这里不能用 const：副标题要读运行时的 vm.entries。
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '数据存放位置',
                              style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            _TotalSubtitle(entries: vm.entries),
                          ],
                        ),
                      ),
                      PressableScale(
                        onTap: vm.isLoading ? null : vm.load,
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: const BoxDecoration(
                            color: AppColors.surfaceMuted,
                            shape: BoxShape.circle,
                          ),
                          child: vm.isMeasuring
                              ? const Padding(
                                  padding: EdgeInsets.all(10),
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.refresh_rounded, size: 18),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 右上角关闭：与「点击外部关闭」并存，鼠标用户更习惯点这个。
                      PressableScale(
                        onTap: () => Navigator.of(context).pop(),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: const BoxDecoration(
                            color: AppColors.surfaceMuted,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close_rounded, size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
                if (vm.errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Text(
                      vm.errorMessage!,
                      style: const TextStyle(
                          color: AppColors.danger, fontSize: 12),
                    ),
                  ),
                const Divider(height: 1),
                // 条目列表：行式布局，分隔线隔开。
                Expanded(
                  child: vm.entries.isEmpty
                      ? const Center(
                          child: Text(
                            '正在读取…',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: vm.entries.length,
                          itemBuilder: (context, index) {
                            final entry = vm.entries[index];
                            return Column(
                              children: [
                                _EntryRow(
                                  entry: entry,
                                  onCopy: () => _copy(entry.path),
                                  onReveal: () => vm.reveal(entry),
                                  onDelete: entry.canDelete
                                      ? () => setState(
                                          () => _pendingDelete = entry)
                                      : null,
                                ),
                                if (_pendingDelete == entry)
                                  _ConfirmDeleteBand(
                                    onCancel: () =>
                                        setState(() => _pendingDelete = null),
                                    onDelete: () async {
                                      setState(() => _pendingDelete = null);
                                      await vm.delete(entry);
                                      if (!mounted) return;
                                      _showMessage('已清理「${entry.title}」');
                                    },
                                  ),
                                const Divider(height: 1),
                              ],
                            );
                          },
                        ),
                ),
                // 底部：打开接收文件夹 + 完成。
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 18),
                  child: Row(
                    children: [
                      if (receivedEntry != null)
                        PressableScale(
                          onTap: () => vm.reveal(receivedEntry),
                          child: const Text(
                            '在访达中打开接收文件夹',
                            style: TextStyle(
                              color: AppColors.primary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      const Spacer(),
                      PressableScale(
                        onTap: () => Navigator.of(context).pop(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 28, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius:
                                BorderRadius.circular(AppDimens.radiusPill),
                          ),
                          child: const Text(
                            '完成',
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
      },
    );
  }

  StorageEntry? _findReceivedEntry(StorageViewModel vm) {
    for (final entry in vm.entries) {
      if (entry.kind == StorageEntryKind.receivedFiles) return entry;
    }
    return null;
  }

  Future<void> _copy(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    _showMessage('已复制路径');
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
  }
}

/// 「共 N 处 · 占用 X」副标题。
///
/// 条目由外部传入：本弹窗的 ViewModel 是 State 的私有字段，并没有挂在
/// Provider 树上，这里若用 `context.read<StorageViewModel>()` 会直接抛
/// ProviderNotFoundException（弹窗一打开就红屏）。
class _TotalSubtitle extends StatelessWidget {
  const _TotalSubtitle({required this.entries});

  final List<StorageEntry> entries;

  @override
  Widget build(BuildContext context) {
    final total = entries.fold<int>(0, (sum, e) => sum + e.sizeBytes);

    return Text(
      entries.isEmpty ? '正在统计占用…' : '共 ${entries.length} 处 · 占用 ${formatBytes(total)}',
      style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
    );
  }
}

/// 单个存储位置行（设计稿 03：图标方块 + 标题/描述/路径 + 尺寸 + 操作图标）。
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.onCopy,
    required this.onReveal,
    required this.onDelete,
  });

  final StorageEntry entry;
  final VoidCallback onCopy;
  final VoidCallback onReveal;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.surfaceMuted,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_iconFor(entry.kind),
                size: 20, color: AppColors.textPrimary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  entry.description,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  entry.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 72,
            child: Text(
              formatBytes(entry.sizeBytes),
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 8),
          _RoundIconAction(
            tooltip: '在文件管理器中显示',
            icon: Icons.visibility_outlined,
            onPressed: onReveal,
          ),
          _RoundIconAction(
            tooltip: '复制路径',
            icon: Icons.copy_rounded,
            onPressed: onCopy,
          ),
          if (entry.canDelete)
            _RoundIconAction(
              tooltip: '清理',
              icon: Icons.delete_outline_rounded,
              color: entry.isDisposable ? AppColors.danger : null,
              onPressed: onDelete!,
            ),
        ],
      ),
    );
  }

  IconData _iconFor(StorageEntryKind kind) => switch (kind) {
        StorageEntryKind.appData => Icons.storage_rounded,
        StorageEntryKind.settings => Icons.tune_rounded,
        StorageEntryKind.logs => Icons.article_outlined,
        StorageEntryKind.temp => Icons.folder_outlined,
        StorageEntryKind.receivedFiles => Icons.folder_outlined,
        StorageEntryKind.history => Icons.history_rounded,
      };
}

/// 行内删除确认条（设计稿：灰底 + 取消 / 红色删除）。
class _ConfirmDeleteBand extends StatelessWidget {
  const _ConfirmDeleteBand({required this.onCancel, required this.onDelete});

  final VoidCallback onCancel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceMuted,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              '删除后不可恢复，确定继续？',
              style: TextStyle(fontSize: 13),
            ),
          ),
          PressableScale(
            onTap: onCancel,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                color: AppColors.background,
              ),
              child: const Text(
                '取消',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(width: 10),
          PressableScale(
            onTap: onDelete,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.danger,
                borderRadius: BorderRadius.circular(AppDimens.radiusPill),
              ),
              child: const Text(
                '删除',
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

/// 圆形小操作按钮。
class _RoundIconAction extends StatelessWidget {
  const _RoundIconAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: PressableScale(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 17, color: color ?? AppColors.textSecondary),
        ),
      ),
    );
  }
}
