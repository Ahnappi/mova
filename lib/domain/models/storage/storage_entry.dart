/// 本应用在磁盘上的一处数据存储位置（Domain 层，纯数据）。
///
/// 用于「数据存放位置」弹窗展示：每一处数据在哪、占多大、能不能删。
enum StorageEntryKind {
  /// 应用数据根目录（配置与日志的父目录）。
  appData,

  /// 偏好设置。
  settings,

  /// 运行日志。
  logs,

  /// 系统临时目录。
  temp,

  /// 接收文件的保存目录。
  receivedFiles,

  /// 连接记录（history.json）。
  history,
}

class StorageEntry {
  const StorageEntry({
    required this.id,
    required this.title,
    required this.path,
    required this.kind,
    required this.description,
    required this.canDelete,
    required this.deleteNote,
    this.sizeBytes = 0,
    this.exists = false,
  });

  final String id;
  final String title;
  final String path;
  final StorageEntryKind kind;
  final String description;

  /// 是否提供「清空 / 删除」按钮。
  final bool canDelete;

  /// 删除后会有什么影响（展示给用户看的说明）。
  final String deleteNote;

  /// 占用体积（字节）；目录为递归统计结果，未统计时为 0。
  final int sizeBytes;

  /// 该路径当前是否存在。
  final bool exists;

  /// 日志 / 缓存类：删除只影响诊断信息，不影响任何功能。
  bool get isDisposable =>
      kind == StorageEntryKind.logs || kind == StorageEntryKind.temp;

  StorageEntry copyWith({int? sizeBytes, bool? exists}) {
    return StorageEntry(
      id: id,
      title: title,
      path: path,
      kind: kind,
      description: description,
      canDelete: canDelete,
      deleteNote: deleteNote,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      exists: exists ?? this.exists,
    );
  }
}
