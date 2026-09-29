import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../../config/app_config.dart';
import '../../../data/repositories/history/history_repository.dart';
import '../../../data/repositories/settings/settings_repository.dart';
import '../../../data/services/network/network_info_service.dart';
import '../../../domain/models/settings/app_settings.dart';

/// 把新设备名交给连接层，返回「是否已经推给局域网（正在广播）」。
typedef DeviceNameApplier = Future<bool> Function(String name);

/// 设置页视图模型（ViewModel 层）：设备名、连接记录保留期限、发送前确认。
///
/// 三个值得说明的决定：
///
/// 1. **设备名保存的是「用户填了什么」，而不是「最终用哪个」。**
///    空串表示「没自定义」，界面与广播退回主机名。直接把主机名写进
///    存储的话，用户改了系统的电脑名之后，这里永远也回不到新名字。
/// 2. **改期限会立刻触发一次清理**，并告诉用户清掉了几条。
///    否则用户以为「改成 7 天」已经生效，历史里却还堆着三个月前的记录。
/// 3. **每一次改动都要有看得见的反馈**。保存静默成功是最糟的一类界面：
///    用户不知道到底存没存下，只能重启去猜。提示还会区分「对方马上能
///    看到」与「要再点一次搜索」——本机没在广播时，另一台设备根本搜不到
///    这台机器，光说「已保存」会让人以为改名没生效。
class SettingsViewModel extends ChangeNotifier {
  SettingsViewModel({
    required SettingsRepository settingsRepository,
    required HistoryRepository historyRepository,
    required NetworkInfoService networkInfoService,
    DeviceNameApplier? onDeviceNameChanged,
  })  : _repository = settingsRepository,
        _history = historyRepository,
        _networkInfo = networkInfoService,
        _onDeviceNameChanged = onDeviceNameChanged;

  final SettingsRepository _repository;
  final HistoryRepository _history;
  final NetworkInfoService _networkInfo;
  final DeviceNameApplier? _onDeviceNameChanged;

  final Logger _log = Logger('SettingsViewModel');

  Timer? _messageTimer;

  bool _loading = true;
  String _deviceName = '';
  String _defaultDeviceName = '';
  int _retentionDays = AppConfig.defaultHistoryRetentionDays;
  bool _confirmBeforeSend = AppConfig.defaultConfirmBeforeSend;
  String? _errorMessage;
  String? _lastMessage;

  /// 是否还在读取设置（读完后界面才能显示真实值）。
  bool get isLoading => _loading;

  /// 用户填的设备名（空串表示未自定义）。
  String get deviceName => _deviceName;

  /// 主机名（未自定义时实际广播出去的名字）。
  String get defaultDeviceName => _defaultDeviceName;

  /// 未自定义时用于输入框回填的名字。
  String get deviceNameForInput =>
      _deviceName.isEmpty ? _defaultDeviceName : _deviceName;

  /// 保留期限（天）；0 表示永久。
  int get retentionDays => _retentionDays;

  /// 发送文件前是否需要确认。
  bool get confirmBeforeSend => _confirmBeforeSend;

  String? get errorMessage => _errorMessage;

  /// 最近一次操作反馈，读取后用 [clearMessage] 清掉。
  String? get lastMessage => _lastMessage;

  void clearMessage() {
    if (_lastMessage == null) return;
    _lastMessage = null;
    _messageTimer?.cancel();
    _messageTimer = null;
    notifyListeners();
  }

  /// 写一条会自己消失的提示。
  ///
  /// 提示留在界面上不走，下一次操作就会分不清是哪一条的反馈；
  /// 但也不能指望调用方记得清——所以由这里定时清掉。
  void _setMessage(String text) {
    _lastMessage = text;
    _messageTimer?.cancel();
    _messageTimer = Timer(const Duration(seconds: 5), () {
      _lastMessage = null;
      _messageTimer = null;
      notifyListeners();
    });
    notifyListeners();
  }

  @override
  void dispose() {
    _messageTimer?.cancel();
    _messageTimer = null;
    super.dispose();
  }

  Future<void> load() async {
    final AppSettings settings;
    try {
      settings = await _repository.load();
    } catch (e) {
      _loading = false;
      _errorMessage = '读取设置失败：$e';
      notifyListeners();
      return;
    }

    _defaultDeviceName = _networkInfo.defaultDeviceName();
    _deviceName = settings.deviceName;
    _retentionDays = settings.historyRetentionDays;
    _confirmBeforeSend = settings.confirmBeforeSend;
    _loading = false;
    notifyListeners();
  }

  Future<void> setDeviceName(String value) async {
    // 超长就截断，而不是拒绝：名字是给用户看的设备标签，
    // 没必要因为多打两个字就让人返工。
    final trimmed = value.trim();
    final name = trimmed.length > AppConfig.maxDeviceNameLength
        ? trimmed.substring(0, AppConfig.maxDeviceNameLength)
        : trimmed;

    await _save((settings) => settings.copyWith(deviceName: name));
    if (_errorMessage != null) return;

    // 立刻生效：下一次 UDP 心跳就带上新名字，
    // 对方不用等到重启应用才看到改动。
    final effective = name.isEmpty ? _defaultDeviceName : name;

    // 这一步失败**不能**推翻「已经存好了」：名字已经落盘，
    // 广播重启不了只是本次没推给局域网，下次搜索仍然会用新名字。
    // 早先把它放在 await 上不管，一旦连接层取不到，
    // 保存早已成功、界面却一点反馈都没有。
    var broadcasting = false;
    try {
      broadcasting = await _onDeviceNameChanged?.call(effective) ?? false;
    } catch (e) {
      _log.warning('设备名已保存，但没能立刻广播出去：$e');
    }

    final hint = broadcasting
        ? '对方几秒内就能看到'
        : '开启「搜索设备」后对方就能看到';
    _setMessage(
      name.isEmpty
          ? '已恢复为设备名（$_defaultDeviceName），$hint'
          : '设备名已更新为「$name」，$hint',
    );
  }

  Future<void> setRetentionDays(int days) async {
    await _save((settings) => settings.copyWith(historyRetentionDays: days));
    if (_errorMessage != null) return;

    // 期限变短要立刻生效：改完历史里还留着过期记录，
    // 用户会以为设置没起作用。
    final removed = await _history.applyRetention();
    _setMessage(
      removed == 0
          ? '已设置为${retentionLabel(days)}'
          : '已设置为${retentionLabel(days)}，并清理了 $removed 条过期记录',
    );
  }

  Future<void> setConfirmBeforeSend(bool value) async {
    await _save((settings) => settings.copyWith(confirmBeforeSend: value));
    if (_errorMessage != null) return;
    _setMessage(
      value ? '发送文件前会先确认' : '发送文件前不再确认，拖拽即发送',
    );
  }

  Future<void> _save(AppSettings Function(AppSettings current) update) async {
    _errorMessage = null;
    // 上一次的提示先撤掉：留着会和新结果叠在一起，分不清哪个是这次的。
    _messageTimer?.cancel();
    _messageTimer = null;
    _lastMessage = null;
    try {
      final current = await _repository.load();
      await _repository.save(update(current));
    } catch (e) {
      // 保存失败必须让用户知道：界面上显示「已保存」、重启却是旧值，
      // 是最难排查的一类反馈。
      _errorMessage = '保存设置失败：$e';
      notifyListeners();
      return;
    }

    try {
      final latest = await _repository.load();
      _deviceName = latest.deviceName;
      _retentionDays = latest.historyRetentionDays;
      _confirmBeforeSend = latest.confirmBeforeSend;
    } catch (_) {
      // 回读失败不影响「保存已经成功」这件事。
    }
    notifyListeners();
  }
}
