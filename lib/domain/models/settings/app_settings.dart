import '../../../config/app_config.dart';

/// 用户偏好设置（Domain 层，纯 Dart 模型）。
///
/// 三项都是**本机**行为，不会随连接同步给对端：
/// - [deviceName]：局域网搜索时展示给对方的名字；
/// - [historyRetentionDays]：连接记录保留多久；
/// - [confirmBeforeSend]：发文件前要不要再问一句。
class AppSettings {
  const AppSettings({
    this.deviceName = '',
    this.historyRetentionDays = AppConfig.defaultHistoryRetentionDays,
    this.confirmBeforeSend = AppConfig.defaultConfirmBeforeSend,
  });

  /// 用户填写的设备名；**空串表示没有自定义**，此时用主机名兜底。
  final String deviceName;

  /// 连接记录保留天数；`0` 或负数表示永久保留。
  final int historyRetentionDays;

  /// 发送文件前是否先弹确认框。
  final bool confirmBeforeSend;

  /// 用户真的填了名字才有效（空串要退回主机名，而不是广播一个空名字）。
  String? get customDeviceName {
    final trimmed = deviceName.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// 保留期限对应的时长；永久保留时为 null。
  ///
  /// 调用方判断 「`null` → 不按时间清理」即可，不必自己记住「0 是永久」。
  Duration? get retentionDuration {
    if (historyRetentionDays <= 0) return null;
    return Duration(days: historyRetentionDays);
  }

  AppSettings copyWith({
    String? deviceName,
    int? historyRetentionDays,
    bool? confirmBeforeSend,
  }) =>
      AppSettings(
        deviceName: deviceName ?? this.deviceName,
        historyRetentionDays: historyRetentionDays ?? this.historyRetentionDays,
        confirmBeforeSend: confirmBeforeSend ?? this.confirmBeforeSend,
      );
}

/// 保留期限的界面文案。
String retentionLabel(int days) {
  if (days <= 0) return '永久保留';
  if (days == 1) return '1 天';
  if (days < 30) return '$days 天';
  if (days == 365) return '1 年';
  return '$days 天';
}
