import '../../../domain/models/storage/storage_entry.dart';

/// 本地存储仓储（Repository 层）：汇总应用占用的磁盘位置及其体积。
abstract class StorageRepository {
  /// 列出应用会写入磁盘的所有位置（尚未统计体积）。
  Future<List<StorageEntry>> loadEntries();

  /// 逐个统计体积并补全存在状态（目录递归统计，可能较慢）。
  Future<List<StorageEntry>> measureEntries(List<StorageEntry> entries);

  /// 清空 / 删除某一项；仅对 [StorageEntry.canDelete] 为 true 的项调用。
  Future<void> deleteEntry(StorageEntry entry);

  /// 在系统文件管理器中显示该位置。
  Future<void> revealEntry(StorageEntry entry);
}
