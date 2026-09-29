import '../../../config/app_config.dart';
import '../../../domain/models/settings/app_settings.dart';
import '../../services/storage/settings_service.dart';
import 'settings_repository.dart';

/// 用户偏好设置的本地实现：写在应用数据目录的 `settings.json` 里。
///
/// 两处容错是刻意的：
/// - **缺字段 / 类型不对就退回默认值**。这个文件可能来自旧版本，
///   也可能被手改过，任何一个字段读不出来都不该让设置页打不开。
/// - **保存失败必须抛出**。吞掉异常之后界面会显示「已保存」，
///   下次启动却是旧值——用户以为改过但其实没改。
class SettingsRepositoryLocal implements SettingsRepository {
  SettingsRepositoryLocal(this._settings);

  final SettingsService _settings;

  static const String _deviceNameKey = 'deviceName';
  static const String _historyRetentionDaysKey = 'historyRetentionDays';
  static const String _confirmBeforeSendKey = 'confirmBeforeSend';

  AppSettings? _cache;

  @override
  Future<AppSettings> load() async {
    final cached = _cache;
    if (cached != null) return cached;

    final loaded = AppSettings(
      deviceName: (await _settings.readString(_deviceNameKey) ?? '')
          .trim(),
      historyRetentionDays: (await _settings.readInt(
                _historyRetentionDaysKey,
              ) ??
              AppConfig.defaultHistoryRetentionDays),
      confirmBeforeSend: (await _settings.readBool(_confirmBeforeSendKey) ??
          AppConfig.defaultConfirmBeforeSend),
    );

    final sanitized = loaded.copyWith(
      // 负值没有意义，统一按「永久保留」处理。
      historyRetentionDays:
          loaded.historyRetentionDays < 0 ? 0 : loaded.historyRetentionDays,
      deviceName: loaded.deviceName.length > AppConfig.maxDeviceNameLength
          ? loaded.deviceName.substring(0, AppConfig.maxDeviceNameLength)
          : loaded.deviceName,
    );

    _cache = sanitized;
    return sanitized;
  }

  @override
  Future<void> save(AppSettings settings) async {
    final sanitized = settings.copyWith(
      deviceName: settings.deviceName.trim().length >
              AppConfig.maxDeviceNameLength
          ? settings.deviceName.trim().substring(0, AppConfig.maxDeviceNameLength)
          : settings.deviceName.trim(),
      historyRetentionDays:
          settings.historyRetentionDays < 0 ? 0 : settings.historyRetentionDays,
    );

    _cache = sanitized;
    await _settings.writeString(_deviceNameKey, sanitized.deviceName);
    await _settings.writeInt(
      _historyRetentionDaysKey,
      sanitized.historyRetentionDays,
    );
    await _settings.writeBool(
      _confirmBeforeSendKey,
      sanitized.confirmBeforeSend,
    );
  }
}
