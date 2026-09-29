import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../../config/app_config.dart';
import '../../../data/repositories/chat/chat_repository.dart';
import '../../../data/repositories/discovery/discovery_repository.dart';
import '../../../data/repositories/history/history_repository.dart';
import '../../../data/repositories/settings/settings_repository.dart';
import '../../../data/services/network/network_info_service.dart';
import '../../../data/services/system/system_settings_service.dart';
import '../../../domain/models/chat/connection_status.dart';
import '../../../domain/models/chat/local_info.dart';
import '../../../domain/models/chat/peer.dart';
// 必须显式导入：result.dart 中的 Error 会覆盖 dart:core 的同名类。
import '../../../utils/result.dart';

/// 连接视图模型（ViewModel 层）：发现设备、建立/断开连接。
///
/// 只暴露状态与动作给 View，具体网络细节全部在 Repository / Service 中。
class ConnectionViewModel extends ChangeNotifier {
  ConnectionViewModel({
    required DiscoveryRepository discoveryRepository,
    required ChatRepository chatRepository,
    required NetworkInfoService networkInfoService,
    required HistoryRepository historyRepository,
    required SystemSettingsService systemSettingsService,
    required SettingsRepository settingsRepository,
  })  : _discoveryRepository = discoveryRepository,
        _chatRepository = chatRepository,
        _networkInfoService = networkInfoService,
        _historyRepository = historyRepository,
        _systemSettings = systemSettingsService,
        _settingsRepository = settingsRepository;

  final DiscoveryRepository _discoveryRepository;
  final ChatRepository _chatRepository;
  final NetworkInfoService _networkInfoService;
  final HistoryRepository _historyRepository;
  final SystemSettingsService _systemSettings;
  final SettingsRepository _settingsRepository;

  final Logger _log = Logger('ConnectionViewModel');

  /// 需要弹出提示的事件（如「有人想连你，但你已连着别人」）。
  Stream<String> get notices => _noticeController.stream;

  final StreamController<String> _noticeController =
      StreamController<String>.broadcast();

  StreamSubscription<ConnectionStatus>? _statusSub;
  StreamSubscription<List<Peer>>? _peersSub;
  StreamSubscription<String>? _noticeSub;

  LocalInfo? _localInfo;
  List<Peer> _peers = const [];
  ConnectionStatus _status = ConnectionStatus.disconnected;
  String? _errorMessage;
  bool _initialized = false;

  /// 本次连接对应的历史记录 id（连接成功后才有）。
  String? _sessionId;

  /// 是否正在搜索局域网设备（由用户在界面上手动开启/关闭）。
  bool _discovering = false;

  /// 用户在设置里改过名、但本机信息还没算出来时先存着。
  String? _pendingDeviceName;

  /// 生成本机信息：用户在设置里填的名字优先，没填就用主机名。
  Future<LocalInfo> _resolveLocalInfo() async {
    final fallback =
        await _networkInfoService.getLocalInfo(tcpPort: AppConfig.tcpPort);

    String? preferred;
    try {
      preferred = (await _settingsRepository.load()).customDeviceName;
    } catch (e) {
      // 读不到设置就退回主机名：名字只是标签，
      // 不该因为它让整套连接流程起不来。
      _log.warning('读取设备名失败，退回主机名：$e');
    }
    preferred ??= _pendingDeviceName;

    if (preferred == null || preferred.isEmpty) return fallback;
    return fallback.copyWith(name: preferred);
  }

  /// 用户在设置里改名的入口（由 SettingsViewModel 回调进来）。
  ///
  /// 改名要马上生效才算数：对方的设备列表靠 UDP 心跳刷新，
  /// 因此正在搜索时先停再开，让下一个心跳（最多 3 秒）就带上新名字；
  /// 已经建立的连接不会改（hello 帧只在建连时发一次），
  /// 下次连接才会看到新名字。
  Future<void> applyDeviceName(String name) async {
    final trimmed = name.trim();
    final info = _localInfo;

    if (info == null) {
      // 本机信息还没算出来（设置页比初始化更早打开）：先记着，初始化时套用。
      _pendingDeviceName = trimmed.isEmpty ? null : trimmed;
      return;
    }

    _pendingDeviceName = trimmed.isEmpty ? null : trimmed;
    final updated = trimmed.isEmpty
        ? info.copyWith(name: _networkInfoService.defaultDeviceName())
        : info.copyWith(name: trimmed);
    _localInfo = updated;
    _chatRepository.localName = updated.name;
    notifyListeners();

    if (!_discovering) return;
    await _discoveryRepository.stop();
    final result = await _discoveryRepository.start(updated);
    if (result is Error<void>) {
      _errorMessage = result.error.toString();
      _log.warning('改名后重启搜索失败：${result.error}');
    }
    notifyListeners();
  }

  /// 本机信息（初始化前为 null）。
  LocalInfo? get localInfo => _localInfo;

  /// 已发现的对端列表。
  List<Peer> get peers => _peers;

  /// 当前连接状态。
  ConnectionStatus get status => _status;

  /// 最近一次错误（无错误时为 null）。
  String? get errorMessage => _errorMessage;

  /// 最近一次错误是否属于「系统/网络权限被拒绝」。
  ///
  /// 局域网互传最容易被两类东西静默拦掉：
  /// - macOS 15 起的「本地网络」隐私授权；
  /// - Windows 防火墙拦截入站/出站连接。
  /// 这两种情况在应用里怎么点都没用，只能去系统设置里放行。
  bool get isPermissionError {
    final message = _errorMessage?.toLowerCase() ?? '';
    return message.contains('operation not permitted') ||
        message.contains('permission denied') ||
        message.contains('errno = 13') ||
        message.contains('errno=13') ||
        message.contains('errno = 1') ||
        message.contains('errno=1') ||
        message.contains('本地网络') ||
        message.contains('access is denied');
  }

  /// 关掉错误提示。
  void dismissError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// 打开系统的网络/本地网络权限设置页。
  Future<void> openNetworkSettings() =>
      _systemSettings.openLocalNetworkSettings();

  /// 打开系统防火墙设置页（Windows 上入站连接常被它拦住）。
  Future<void> openFirewallSettings() =>
      _systemSettings.openFirewallSettings();

  /// 是否已连接。
  bool get isConnected => _status == ConnectionStatus.connected;

  /// 是否正在搜索局域网设备。
  bool get isDiscovering => _discovering;

  /// 对端名称。
  String? get remoteName => _chatRepository.remoteName;

  /// 初始化：取本机信息 → 开启 TCP 监听 → 开启局域网发现。
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    _statusSub = _chatRepository.status.listen((status) {
      final previous = _status;
      _status = status;

      if (status == ConnectionStatus.connected) {
        // 连上之后设备搜索就没意义了，自动停下，避免一直在局域网里广播。
        if (_discovering) unawaited(stopDiscovery());
        unawaited(_openSession());
      } else if (previous == ConnectionStatus.connected) {
        // 从已连接变为非连接：收尾这次会话。
        unawaited(_closeSession());
      }
      notifyListeners();
    });

    _peersSub = _discoveryRepository.peers.listen((peers) {
      _peers = peers;
      notifyListeners();
    });

    // 忙碌时被拒绝的入站连接：转给界面提示，让用户知道有人来连过。
    _noticeSub = _chatRepository.notices.listen(_noticeController.add);

    final info = await _resolveLocalInfo();
    _localInfo = info;
    _chatRepository.localName = info.name;
    notifyListeners();

    // 开启监听，让对方可以主动连进来（手动 IP 直连也依赖它）。
    final listenResult = await _chatRepository.startListening(AppConfig.tcpPort);
    if (listenResult is Error<void>) {
      _errorMessage = listenResult.error.toString();
      _log.warning('监听失败：${listenResult.error}');
    }
    notifyListeners();
  }

  /// 开启局域网搜索（用户手动触发，默认不搜）。
  Future<void> startDiscovery() async {
    final info = _localInfo;
    if (info == null || _discovering) return;

    _errorMessage = null;
    _discovering = true;
    notifyListeners();

    final result = await _discoveryRepository.start(info);
    if (result is Error<void>) {
      _discovering = false;
      _errorMessage = result.error.toString();
      _log.warning('发现失败：${result.error}');
    }
    notifyListeners();
  }

  /// 停止局域网搜索，并清空已发现的设备。
  Future<void> stopDiscovery() async {
    if (!_discovering) return;

    _discovering = false;
    notifyListeners();

    await _discoveryRepository.stop();
    notifyListeners();
  }

  /// 搜索开关。
  Future<void> toggleDiscovery() =>
      _discovering ? stopDiscovery() : startDiscovery();

  /// 连接到发现的某个设备。
  Future<void> connectToPeer(Peer peer) => connect(peer.ip, port: peer.tcpPort);

  /// 按 IP 手动连接，[port] 缺省用 [AppConfig.tcpPort]。
  Future<void> connect(String host, {int? port}) async {
    // 退出流程已经封存连接层：这时候再建会话，收尾中的传输与历史仓储
    // 都接不住它。界面直接给结论，不必等底层报错。
    if (_chatRepository.sealed) {
      _errorMessage = '应用正在退出，无法再建立连接';
      notifyListeners();
      return;
    }

    _errorMessage = null;
    notifyListeners();

    final result = await _chatRepository.connect(host, port ?? AppConfig.tcpPort);
    if (result is Error<void>) {
      _errorMessage = result.error.toString();
      _log.warning('连接失败：${result.error}');
    }
    notifyListeners();
  }

  /// 断开当前会话（监听仍保留，对方可再次连入）。
  Future<void> disconnect() async {
    await _chatRepository.disconnect();
    notifyListeners();
  }

  // ---------- 连接记录 ----------

  /// 连接成功：开一条连接记录，后续消息与文件都挂在它下面。
  Future<void> _openSession() async {
    _sessionId = await _historyRepository.startSession(
      peerName: _chatRepository.remoteName ?? '对方',
      peerIp: _chatRepository.remoteAddress ?? '',
    );

    // 对端名在 hello 帧里，可能比连接状态晚一点点到达，稍后补一次。
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final id = _sessionId;
    if (id == null) return;
    await _historyRepository.updateSessionPeer(
      id,
      peerName: _chatRepository.remoteName,
      peerIp: _chatRepository.remoteAddress,
    );
  }

  /// 断开：补全对端信息并结束这条记录。
  Future<void> _closeSession() async {
    final id = _sessionId;
    if (id == null) return;
    _sessionId = null;

    await _historyRepository.updateSessionPeer(
      id,
      peerName: _chatRepository.remoteName,
      peerIp: _chatRepository.remoteAddress,
    );
    await _historyRepository.endSession(id);
  }

  @override
  void dispose() {
    final id = _sessionId;
    if (id != null) {
      _sessionId = null;
      unawaited(_historyRepository.endSession(id));
    }
    _statusSub?.cancel();
    _peersSub?.cancel();
    _noticeSub?.cancel();
    _noticeController.close();
    super.dispose();
  }
}
