import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../../data/repositories/storage/storage_repository.dart';
import '../../../../domain/models/storage/storage_entry.dart';
import '../../../../utils/format.dart';
import '../view_models/storage_view_model.dart';

/// 打开「数据存放位置」弹窗。
Future<void> showStoragePathsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const StoragePathsDialog(),
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
        final total = vm.entries.fold<int>(0, (sum, e) => sum + e.sizeBytes);

        return AlertDialog(
          title: const Text('数据存放位置'),
          content: SizedBox(
            width: 620,
            height: 440,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '共 ${vm.entries.length} 处 · 合计 ${formatBytes(total)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (vm.isMeasuring) ...[
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '统计中…',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const Spacer(),
                    IconButton(
                      tooltip: '刷新',
                      iconSize: 18,
                      onPressed: vm.isLoading ? null : vm.load,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                if (vm.errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      vm.errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Expanded(
                  child: vm.entries.isEmpty
                      ? const Center(child: Text('正在读取…'))
                      : ListView.separated(
                          itemCount: vm.entries.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) => _EntryCard(
                            entry: vm.entries[index],
                            onCopy: () => _copy(vm.entries[index].path),
                            onReveal: () => vm.reveal(vm.entries[index]),
                            onDelete: () => _confirmDelete(vm, vm.entries[index]),
                          ),
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _copy(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    _showMessage('已复制路径');
  }

  Future<void> _confirmDelete(StorageViewModel vm, StorageEntry entry) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('确认清理「${entry.title}」？'),
            content: Text('${entry.path}\n\n${entry.deleteNote}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('清理'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed) return;
    await vm.delete(entry);
    if (!mounted) return;
    _showMessage('已清理「${entry.title}」');
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
  }
}

/// 单个存储位置卡片。
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.entry,
    required this.onCopy,
    required this.onReveal,
    required this.onDelete,
  });

  final StorageEntry entry;
  final VoidCallback onCopy;
  final VoidCallback onReveal;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_iconFor(entry.kind), size: 18),
              const SizedBox(width: 8),
              Text(entry.title, style: theme.textTheme.titleSmall),
              const SizedBox(width: 8),
              _DeletableChip(canDelete: entry.canDelete, entry: entry),
              const Spacer(),
              Text(formatBytes(entry.sizeBytes), style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 4),
          Text(entry.description, style: theme.textTheme.bodySmall),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  entry.path,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'Courier',
                    fontSize: 12,
                  ),
                ),
              ),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  tooltip: '复制路径',
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy),
                ),
              ),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  tooltip: '在文件管理器中显示',
                  onPressed: onReveal,
                  icon: const Icon(Icons.folder_open),
                ),
              ),
              if (entry.canDelete)
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    tooltip: '清理',
                    onPressed: onDelete,
                    icon: Icon(
                      Icons.delete_outline,
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _iconFor(StorageEntryKind kind) => switch (kind) {
        StorageEntryKind.appData => Icons.inventory_2_outlined,
        StorageEntryKind.settings => Icons.settings_outlined,
        StorageEntryKind.logs => Icons.article_outlined,
        StorageEntryKind.temp => Icons.cleaning_services_outlined,
        StorageEntryKind.receivedFiles => Icons.download_done_outlined,
      };
}

/// 「可安全删除 / 请勿删除」标记。
class _DeletableChip extends StatelessWidget {
  const _DeletableChip({required this.canDelete, required this.entry});

  final bool canDelete;
  final StorageEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = entry.isDisposable
        ? Colors.green
        : (canDelete ? Colors.orange : theme.colorScheme.outline);

    final text = entry.isDisposable
        ? '可安全删除'
        : (canDelete ? '可删除（会重置偏好）' : '请勿删除');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 11),
      ),
    );
  }
}
