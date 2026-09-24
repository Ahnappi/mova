import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../../config/app_config.dart';
import '../../../data/repositories/chat/chat_repository.dart';
import '../../../data/repositories/discovery/discovery_repository.dart';
import '../../../data/repositories/history/history_repository.dart';
import '../../../data/services/network/network_info_service.dart';
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
  })  : _discoveryRepository = discoveryRepository,
        _chatRepository = chatRepository,
        _networkInfoService = networkInfoService,
        _historyRepository = historyRepository;

  final DiscoveryRepository _discoveryRepository;
  final ChatRepository _chatRepository;
  final NetworkInfoService _networkInfoService;
  final HistoryRepository _historyRepository;

  final Logger _log = Logger('ConnectionViewModel');

  StreamSubscription<ConnectionStatus>? _statusSub;
  StreamSubscription<List<Peer>>? _peersSub;

  LocalInfo? _localInfo;
  List<Peer> _peers = const [];
  ConnectionStatus _status = ConnectionStatus.disconnected;
  String? _errorMessage;
  bool _initialized = false;

  /// 本次连接对应的历史记录 id（连接成功后才有）。
  String? _sessionId;

  /// 是否正在搜索局域网设备（由用户在界面上手动开启/关闭）。
  bool _discovering = false;

  /// 本机信息（初始化前为 null）。
  LocalInfo? get localInfo => _localInfo;

  /// 已发现的对端列表。
  List<Peer> get peers => _peers;

  /// 当前连接状态。
  ConnectionStatus get status => _status;

  /// 最近一次错误（无错误时为 null）。
  String? get errorMessage => _errorMessage;

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

    _localInfo = await _networkInfoService.getLocalInfo(tcpPort: AppConfig.tcpPort);
    _chatRepository.localName = _localInfo!.name;
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
    super.dispose();
  }
}
