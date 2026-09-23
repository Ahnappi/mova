/// 待发送的文件（Domain 层模型）：由文件选择器得到。
class PickedFile {
  const PickedFile({
    required this.path,
    required this.name,
    required this.size,
  });

  /// 本地绝对路径。
  final String path;

  /// 文件名（含扩展名）。
  final String name;

  /// 字节大小。
  final int size;
}
