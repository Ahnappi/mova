import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../config/app_config.dart';
import '../../../domain/models/transfer/picked_file.dart';

/// 本地文件系统数据源（Service 层）：选文件、选保存目录、落盘路径规划。
///
/// 只做「文件在哪、能不能写」这类系统交互，传输协议与进度逻辑不在这里。
class FileStorageService {
  /// 弹出文件选择器，只允许 [AppConfig.allowedFileExtensions] 中的类型。
  Future<List<PickedFile>> pickFiles() async {
    // 只取路径，不把文件内容读进内存（大文件关键）。
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: AppConfig.allowedFileExtensions,
    );
    if (files.isEmpty) return const <PickedFile>[];

    final picked = <PickedFile>[];
    for (final file in files) {
      final path = file.path;
      if (path == null) continue;
      // 平台不保证返回大小，取不到就自己 stat 一次（不读内容，开销可忽略）。
      final size = file.lengthSync() ?? await File(path).length();
      picked.add(PickedFile(path: path, name: file.name, size: size));
    }
    return picked;
  }

  /// 弹出目录选择器，返回目录路径（用户取消时为 null）。
  Future<String?> pickDirectory({String? dialogTitle}) {
    return FilePicker.getDirectoryPath(
      dialogTitle: dialogTitle ?? '选择保存位置',
    );
  }

  /// 默认保存目录（下载目录，取不到时退化为当前目录）。
  Future<String> defaultSaveDirectory() async {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads.path;
    } catch (_) {
      // 取不到就用当前目录兜底。
    }
    return Directory.current.path;
  }

  /// 在 [directory] 下为 [fileName] 规划一个不覆盖已有文件的路径。
  Future<String> resolveTargetPath(String directory, String fileName) async {
    final candidate = p.join(directory, fileName);
    if (!await File(candidate).exists()) return candidate;

    final base = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    var index = 1;
    while (true) {
      final renamed = p.join(directory, '$base ($index)$ext');
      if (!await File(renamed).exists()) return renamed;
      index++;
    }
  }
}
