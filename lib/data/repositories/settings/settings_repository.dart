import '../../../domain/models/settings/app_settings.dart';

/// 用户偏好设置仓储（Repository 抽象）。
///
/// 上层只依赖本接口：换成数据库或云同步时 UI 与 ViewModel 无需改动。
abstract class SettingsRepository {
  /// 读取当前设置（读不到 / 损坏时返回默认值）。
  Future<AppSettings> load();

  /// 保存设置。
  Future<void> save(AppSettings settings);
}
