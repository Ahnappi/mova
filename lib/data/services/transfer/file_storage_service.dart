import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../../../config/app_config.dart';
import '../../../domain/models/transfer/picked_file.dart';
import '../../../utils/atomic_link.dart';
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

  /// 临时文件名里的随机成分（不需要密码学强度）。
  final Random _random = Random();

  /// 弹出文件选择器，返回「可发送的文件」与「被忽略的文件名」。
  ///
  /// 这里没有用 `FileType.custom` + `allowedExtensions` 让系统对话框去过滤，
  /// 而是允许选择任意文件后在 Dart 侧校验，原因有两个：
  /// 1. 各平台选择器对扩展名大小写敏感，`.MOV` / `.JPG` 会被直接过滤掉；
  /// 2. 视频格式清单上百项，再乘以大小写变体会让原生过滤器字符串过长。
  /// 自己做校验后，行为在 macOS / Windows 上完全一致，且不受清单长度限制。
  Future<({List<PickedFile> accepted, List<String> ignored})> pickFiles() async {
    // 只取路径，不把文件内容读进内存（大文件关键）。
    final files = await FilePicker.pickFiles(type: FileType.any);
    if (files.isEmpty) {
      return (accepted: const <PickedFile>[], ignored: const <String>[]);
    }

    final accepted = <PickedFile>[];
    final ignored = <String>[];
    for (final file in files) {
      final path = file.path;
      if (path == null) continue;
      if (!isAllowedFile(file.name)) {
        ignored.add(file.name);
        continue;
      }
      // 平台不保证返回大小，取不到就自己 stat 一次（不读内容，开销可忽略）。
      final size = file.lengthSync() ?? await File(path).length();
      accepted.add(PickedFile(path: path, name: file.name, size: size));
    }
    return (accepted: accepted, ignored: ignored);
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

  /// 探测目录是否真的可写。
  ///
  /// 权限被系统拒绝时（macOS 对桌面/文档/下载有 TCC 保护，沙箱下更严格），
  /// 只有在真正写入时才会报错。这里提前用一个临时文件试写一次，
  /// 让「不能写」在传输开始前就被发现，而不是传了一半才失败。
  Future<bool> isWritableDirectory(String directory) async {
    final probe = File(
        p.join(directory, '.mova_write_probe_${DateTime.now().microsecond}'));
    try {
      await probe.writeAsBytes(<int>[0], flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      // 试写失败多半是权限问题；残留的探测文件下次会被 resolveTargetPath 忽略。
      return false;
    }
  }

  /// 确保目录存在（不存在则连同父目录一起创建）。
  ///
  /// 保存目录可能已被移动、删除，或指向一个尚未创建的子目录，
  /// 在真正落盘前补建一次，避免「写到一半才发现目录没了」。
  Future<void> ensureDirectory(String directory) async {
    final dir = Directory(directory);
    if (!await dir.exists()) await dir.create(recursive: true);
  }

  /// 路径上是否已经有东西（文件或目录）。
  bool existsAt(String path) =>
      File(path).existsSync() || Directory(path).existsSync();

  /// 存在就删除；不存在或删除失败都静默返回。
  ///
  /// 清理半成品时用：删不掉不该影响状态流转，让文件留在那里
  /// 也比让整个流程抛异常要好。
  Future<void> deleteIfExists(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删除失败不影响状态流转。
    }
  }

  /// **提交**：把接收完成的临时文件变成正式文件，**目标已存在时拒绝覆盖**。
  ///
  /// 这是接收流程里唯一「文件正式出现在用户面前」的一步，
  /// 因此取消与提交必须围绕它来定边界：
  /// 提交前可以取消（临时文件被删掉，提交自然失败），
  /// 提交中不允许与取消交错（见 Repository 的等待逻辑），
  /// 提交后只能按统一规则回结果。
  ///
  /// 「先检查目标在不在、再改名」保证不了不覆盖：两件事之间隔着 await，
  /// 用户（或另一次接收）完全可能在这个窗口里放一个同名文件进来，
  /// 而 POSIX 的 `rename()` / Windows 的 `MoveFileEx` 都是**静默替换**。
  /// 「先独占占位再改名」同样挡不住：占位只保证创建那一刻没冲突，
  /// 之后那条路径照样可能被别人替换掉，随后的改名还是会覆盖它
  /// （而「目标现在是 0 字节」并不能证明它属于本次接收）。
  ///
  /// 因此不覆盖的保证放在 [atomicCommit]——由操作系统用**一次原子调用**
  /// 完成「检查 + 创建」，中间没有任何窗口；拿不到这个能力就明确失败，
  /// 绝不退回普通改名。
  ///
  /// 目标名确实被占用时返回 [CommitTargetTaken]（没有动过任何已有文件），
  /// 由调用方换一个名字重试。
  Future<CommitOutcome> commitTempFile(String tempPath, String finalPath) async {
    final commit = await atomicCommit(tempPath, finalPath);
    if (!commit.ok) {
      // 失败的原因不止一种：目标名被占用、文件系统不支持硬链接（exFAT/FAT）、
      // 权限不足……只有「路径上确实有东西」才算冲突（换个名字重试即可），
      // 其余一律明确失败——宁可让用户换一个保存位置，也不能悄悄覆盖文件。
      return existsAt(finalPath)
          ? const CommitTargetTaken()
          : CommitFailed(commit.error ?? Exception('无法以不覆盖的方式提交文件'));
    }

    // 提交成功后两个名字指向同一份内容，临时名可以退场。
    await deleteIfExists(tempPath);
    return CommitOk(finalPath);
  }

  /// 提交原语：给已经落盘的临时文件再挂一个正式名字，
  /// **目标已存在时必定失败，且不改动那个已存在的文件**。
  ///
  /// 单独抽成一个方法，一是因为它就是「唯一的提交动作」，
  /// 二来测试需要在它发生的那一刻注入竞争
  /// （见 test/transfer_lifecycle_test.dart 里的 `_RacingCommitStorage`）。
  Future<AtomicCommitResult> atomicCommit(String tempPath, String finalPath) =>
      Future<AtomicCommitResult>.value(AtomicLink.create(tempPath, finalPath));

  /// 这个保存位置能不能做「不覆盖的原子提交」。
  ///
  /// 硬链接不是所有文件系统都支持（exFAT/FAT 就不支持）。等到几个 GB
  /// 都传完了才发现存不下就太晚了，所以开始接收之前先拿一个临时文件试一次。
  Future<bool> supportsAtomicCommit(String directory) async {
    final probe = File(
      p.join(
        directory,
        '.mova_link_probe_${_random.nextInt(0x3FFFFFFF).toRadixString(36)}',
      ),
    );
    final link = '${probe.path}.link';
    try {
      await probe.writeAsBytes(<int>[0], flush: true);
      // 上一次崩溃可能留下过这个探测链，先清掉再试。
      await deleteIfExists(link);
      final result = await atomicCommit(probe.path, link);
      return result.ok;
    } catch (_) {
      return false;
    } finally {
      await deleteIfExists(link);
      await deleteIfExists(probe.path);
    }
  }

  /// 查一个路径的基本事实（是否存在、多大）。
  ///
  /// 界面要显示「文件还在不在 / 有多大」时走这里，而不是自己在 View 里
  /// `File(path).existsSync()`——文件系统访问统一留在 Service 层。
  ({bool exists, int sizeBytes}) inspect(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return (exists: false, sizeBytes: 0);
      return (exists: true, sizeBytes: file.lengthSync());
    } catch (_) {
      // 权限受限等情况下当作「看不到」，由界面给出中性提示。
      return (exists: false, sizeBytes: 0);
    }
  }

  /// 扩展名是否在允许范围内（不区分大小写）。
  bool isAllowedFile(String name) {
    final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
    return AppConfig.allowedFileExtensionSet.contains(ext);
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

  /// 把「对端给的文件名」清洗成一个安全的本地文件名。
  ///
  /// 文件名来自网络，不能当作可信输入直接拼进路径——对端（或中间人）
  /// 完全可以送一个 `../../../../Users/me/.ssh/id_rsa` 或含 `..\\` 的名字，
  /// 让我们把文件写到保存目录之外。这里做四件事：
  /// 1. 只取最后一段路径，丢掉任何目录成分（含 `.` / `..`）；
  /// 2. 去掉控制字符与跨平台非法字符（Windows 的 `<>:"|?*` 等）；
  /// 3. 处理 Windows 保留设备名（CON / NUL / COM1…）与结尾的点/空格；
  /// 4. 兜底：清洗后为空时给一个中性名字，绝不返回空串。
  String sanitizeFileName(String rawName) {
    // 先统一分隔符，再按段切分，只留最后一段。
    var name = rawName.replaceAll(r'\', '/');
    name = name.split('/').where((part) => part.isNotEmpty).lastWhere(
          (part) => part != '.' && part != '..',
          orElse: () => '',
        );

    // 控制字符（含换行、退格）在任何系统上都不可见且有害。
    name = name.replaceAll(_controlChars, '');
    // 跨平台非法字符：Windows 最严格，这里按最严格的来，保证两端一致。
    name = name.replaceAll(_illegalChars, '_');
    name = name.trim();
    // Windows 下文件名不能以点或空格结尾（会被静默截断），
    // 尾部的点还可能让扩展名判断失效。
    name = name.replaceAll(RegExp(r'[. ]+$'), '');

    if (_isReservedWindowsName(name)) name = '_$name';

    // 单段长度上限：多数文件系统的组件上限是 255，留出「(1)」等后缀空间。
    if (name.length > 200) {
      final ext = p.extension(name);
      final keep = 200 - ext.length;
      name = '${name.substring(0, keep < 1 ? 1 : keep)}$ext';
    }

    if (name.isEmpty || name == '.' || name == '..') {
      name = 'mova_${DateTime.now().millisecondsSinceEpoch}';
    }
    return name;
  }

  /// 在 [directory] 下为 [fileName] 规划一个不覆盖已有文件的路径。
  ///
  /// 结果经过 [sanitizeFileName] 清洗，并且**二次确认仍在 [directory] 之内**：
  /// 万一将来有人绕过清洗直接拼路径，这一步也能把写入位置锁回保存目录。
  Future<String> resolveTargetPath(String directory, String fileName) async {
    final safeName = sanitizeFileName(fileName);
    final base = p.normalize(p.absolute(directory));

    Future<String?> pick(String name) async {
      final candidate = p.normalize(p.join(base, name));
      if (!p.isWithin(base, candidate)) return null;
      if (!await File(candidate).exists() &&
          !await Directory(candidate).exists()) {
        return candidate;
      }
      return null;
    }

    final direct = await pick(safeName);
    if (direct != null) return direct;

    final stem = p.basenameWithoutExtension(safeName);
    final ext = p.extension(safeName);
    var index = 1;
    while (index < 10000) {
      final renamed = await pick('$stem ($index)$ext');
      if (renamed != null) return renamed;
      index++;
    }
    // 理论上到不了这里（目录里有上万个同名文件），给个不会覆盖的兜底名。
    return p.join(base, '${stem}_${DateTime.now().millisecondsSinceEpoch}$ext');
  }

  /// 为**一次**接收生成一个独立的临时文件路径。
  ///
  /// 不能用「正式名 + 固定后缀」：目录里完全可能已经存在同名残留
  /// （上次崩溃留下的、或另一个同名接收正在写），而后台是覆盖写打开的，
  /// 那样会直接把已有文件截断成 0。这里带上时间戳与随机数，
  /// 保证每次接收都拿到属于自己的名字。
  ///
  /// 名字本身只负责「大概率不撞」，真正的不覆盖由后台以 `exclusive`
  /// 方式创建来保证（撞了就换一个重试）。
  ///
  /// 结果同样经过清洗与 [p.isWithin] 校验，不会跑出 [directory]。
  String tempPathFor(String directory, String fileName) {
    final safeName = sanitizeFileName(fileName);
    final base = p.normalize(p.absolute(directory));
    final stamp = '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
        '-${_random.nextInt(0x3FFFFFFF).toRadixString(36)}';
    final candidate = p.normalize(
      p.join(base, '$safeName.$stamp${AppConfig.incomingTempSuffix}'),
    );
    if (!p.isWithin(base, candidate)) {
      return p.join(base, 'mova_$stamp${AppConfig.incomingTempSuffix}');
    }
    return candidate;
  }

  static final RegExp _controlChars = RegExp(r'[\x00-\x1f\x7f]');
  static final RegExp _illegalChars = RegExp(r'[<>:"/\\|?*]');

  /// Windows 保留设备名（带不带扩展名都不允许作为文件名）。
  static bool _isReservedWindowsName(String name) {
    final stem = p.basenameWithoutExtension(name).toUpperCase();
    if (const {'CON', 'PRN', 'AUX', 'NUL'}.contains(stem)) return true;
    return RegExp(r'^(COM|LPT)[1-9]$').hasMatch(stem);
  }
}

/// 一次「提交（临时文件 → 正式文件）」的结果。
///
/// 分成三种而不是一个 bool：目标名被占用与其它失败的处理方式完全不同
/// ——前者换个名字重试即可，后者必须让任务失败并告诉用户原因。
sealed class CommitOutcome {
  const CommitOutcome();
}

/// 提交成功：文件已经在 [path]。
final class CommitOk extends CommitOutcome {
  CommitOk(this.path);

  /// 正式文件最终落地的位置（可能已经不是最初想要的那个名字）。
  final String path;
}

/// 目标名在提交那一刻已被占用：没有覆盖任何已有文件，调用方应换名字重试。
final class CommitTargetTaken extends CommitOutcome {
  const CommitTargetTaken();
}

/// 其它失败（权限不足、目录不存在、临时文件已消失等）。
final class CommitFailed extends CommitOutcome {
  CommitFailed(this.error);

  final Object error;
}
