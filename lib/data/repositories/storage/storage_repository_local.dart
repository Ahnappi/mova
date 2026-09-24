import '../../../config/app_config.dart';
import '../../../domain/models/storage/storage_entry.dart';
import '../../repositories/history/history_repository.dart';
import '../../services/storage/log_service.dart';
import '../../services/storage/settings_service.dart';
import '../../services/storage/storage_service.dart';
import 'storage_repository.dart';

/// 本地存储仓储实现：把 Service 提供的零散路径拼成可展示的条目。
class StorageRepositoryLocal implements StorageRepository {
  StorageRepositoryLocal({
    required StorageService storageService,
    required SettingsService settingsService,
    required LogService logService,
    required HistoryRepository historyRepository,
  })  : _storage = storageService,
        _settings = settingsService,
        _log = logService,
        _history = historyRepository;

  final StorageService _storage;
  final SettingsService _settings;
  final LogService _log;
  final HistoryRepository _history;

  @override
  Future<List<StorageEntry>> loadEntries() async {
    final support = await _storage.appSupportDirectory();
    final settingsPath = await _storage.settingsFilePath();
    final logs = await _storage.logDirectory();
    final temp = await _storage.tempDirectory();

    final customSave = await _settings.readString(
      SettingsService.saveDirectoryKey,
    );
    final saveDirectory = customSave ?? await _storage.fallbackDownloadDirectory();

    return <StorageEntry>[
      StorageEntry(
        id: 'appData',
        title: '应用数据目录',
        path: support.path,
        kind: StorageEntryKind.appData,
        description: '配置与日志的存放根目录，由系统分配',
        canDelete: false,
        deleteNote: '删除会连同设置与日志一起丢失',
      ),
      StorageEntry(
        id: 'settings',
        title: '应用配置',
        path: settingsPath,
        kind: StorageEntryKind.settings,
        description: '接收文件的保存位置等偏好（settings.json）',
        canDelete: true,
        deleteNote: '删除后偏好恢复默认，下次启动会自动重建',
      ),
      StorageEntry(
        id: 'logs',
        title: '运行日志',
        path: logs.path,
        kind: StorageEntryKind.logs,
        description: 'mova.log —— 仅用于排查问题，可安全删除',
        canDelete: true,
        deleteNote: '只是诊断信息，删除不影响任何功能，会自动重建',
      ),
      StorageEntry(
        id: 'history',
        title: '连接记录',
        path: await _history.historyFilePath(),
        kind: StorageEntryKind.history,
        description:
            '${AppConfig.historyFileName} —— 每次连接的对话与文件清单（含当时的路径）',
        canDelete: true,
        deleteNote: '删除会清空全部连接记录，不可恢复；下次启动会重新建一个空文件',
      ),
      StorageEntry(
        id: 'temp',
        title: '临时文件',
        path: temp.path,
        kind: StorageEntryKind.temp,
        description: '系统临时目录，可安全清理',
        canDelete: true,
        deleteNote: '删除不影响任何功能',
      ),
      StorageEntry(
        id: 'received',
        title: '接收文件保存位置',
        path: saveDirectory,
        kind: StorageEntryKind.receivedFiles,
        description: customSave == null
            ? '默认下载目录（尚未自定义）'
            : '你自定义的接收目录',
        canDelete: false,
        deleteNote: '这里存放你接收的文件，删除后无法恢复',
      ),
    ];
  }

  @override
  Future<List<StorageEntry>> measureEntries(List<StorageEntry> entries) async {
    final measured = <StorageEntry>[];
    for (final entry in entries) {
      final exists = await _storage.exists(entry.path);
      final size = exists ? await _storage.sizeOf(entry.path) : 0;
      measured.add(entry.copyWith(sizeBytes: size, exists: exists));
    }
    return measured;
  }

  @override
  Future<void> deleteEntry(StorageEntry entry) async {
    switch (entry.kind) {
      case StorageEntryKind.logs:
        await _log.clear();
      case StorageEntryKind.temp:
        await _storage.clearDirectory(entry.path);
      case StorageEntryKind.settings:
        await _storage.deleteFile(entry.path);
      case StorageEntryKind.history:
        // 清空记录；进行中的连接会保留，避免当前会话无处可写。
        await _history.clearAll();
      case StorageEntryKind.appData:
      case StorageEntryKind.receivedFiles:
        // 这两类不提供删除入口，避免误删用户文件。
        return;
    }
  }

  @override
  Future<void> revealEntry(StorageEntry entry) => _storage.reveal(entry.path);
}
