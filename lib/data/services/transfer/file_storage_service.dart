import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../../../config/app_config.dart';
import '../../../domain/models/transfer/picked_file.dart';
import '../storage/settings_service.dart';
import '../storage/storage_service.dart';

/// 本地文件系统数据源（Service 层）：选文件、选保存目录、落盘路径规划。
///
/// 只做「文件在哪、能不能写」这类系统交互，传输协议与进度逻辑不在这里。
class FileStorageService {
  FileStorageService({
    required SettingsService settingsService,
    required StorageService storageService,
  })  : _settings = settingsService,
        _storage = storageService;

  final SettingsService _settings;
  final StorageService _storage;

  /// 弹出文件选择器，只允许 [AppConfig.allowedFileExtensions] 中的类型。
  Future<List<PickedFile>> pickFiles() async {
    // 只取路径，不把文件内容读进内存（大文件关键）。
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      // file_picker 的 allowedExtensions 在某些平台上是大小写敏感的，
      // 这里把大小写变体都带上（如 .JPG / .MOV），避免选择文件时被过滤掉。
      allowedExtensions: AppConfig.allowedExtensionsWithCaseVariants,
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

  /// 当前接收文件的保存目录：优先用户自定义，否则下载目录。
  Future<String> currentSaveDirectory() async {
    final saved = await _settings.readString(SettingsService.saveDirectoryKey);
    if (saved != null && await Directory(saved).exists()) return saved;
    return _storage.fallbackDownloadDirectory();
  }

  /// 记住用户选择的保存目录，之后接收直接落到这里。
  Future<void> rememberSaveDirectory(String directory) =>
      _settings.writeString(SettingsService.saveDirectoryKey, directory);

  /// 扩展名是否在允许范围内（不区分大小写）。
  bool isAllowedFile(String name) {
    final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
    return AppConfig.allowedFileExtensions.contains(ext);
  }

  /// 把拖拽进来的路径转成可发送的文件，跳过目录与类型不支持的项。
  ///
  /// 返回 (可发送的文件, 被忽略的名称)。
  Future<({List<PickedFile> accepted, List<String> ignored})> filesFromPaths(
    List<String> paths,
  ) async {
    final accepted = <PickedFile>[];
    final ignored = <String>[];

    for (final path in paths) {
      final name = p.basename(path);
      if (await FileSystemEntity.isDirectory(path)) {
        ignored.add(name);
        continue;
      }
      final file = File(path);
      if (!await file.exists()) {
        ignored.add(name);
        continue;
      }
      if (!isAllowedFile(name)) {
        ignored.add(name);
        continue;
      }
      accepted.add(
        PickedFile(path: path, name: name, size: await file.length()),
      );
    }

    return (accepted: accepted, ignored: ignored);
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
