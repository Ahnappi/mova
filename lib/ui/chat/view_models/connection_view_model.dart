import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../../config/app_config.dart';
import '../../../data/repositories/chat/chat_repository.dart';
import '../../../data/repositories/discovery/discovery_repository.dart';
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
  })  : _discoveryRepository = discoveryRepository,
        _chatRepository = chatRepository,
        _networkInfoService = networkInfoService;

  final DiscoveryRepository _discoveryRepository;
  final ChatRepository _chatRepository;
  final NetworkInfoService _networkInfoService;

  final Logger _log = Logger('ConnectionViewModel');

  StreamSubscription<ConnectionStatus>? _statusSub;
  StreamSubscription<List<Peer>>? _peersSub;

  LocalInfo? _localInfo;
  List<Peer> _peers = const [];
  ConnectionStatus _status = ConnectionStatus.disconnected;
  String? _errorMessage;
  bool _initialized = false;

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

  /// 对端名称。
  String? get remoteName => _chatRepository.remoteName;

  /// 初始化：取本机信息 → 开启 TCP 监听 → 开启局域网发现。
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    _statusSub = _chatRepository.status.listen((status) {
      _status = status;
      notifyListeners();
    });

    _peersSub = _discoveryRepository.peers.listen((peers) {
      _peers = peers;
      notifyListeners();
    });

    _localInfo = await _networkInfoService.getLocalInfo(tcpPort: AppConfig.tcpPort);
    _chatRepository.localName = _localInfo!.name;
    notifyListeners();

    // 开启监听，让对方可以主动连进来。
    final listenResult = await _chatRepository.startListening(AppConfig.tcpPort);
    if (listenResult is Error<void>) {
      _errorMessage = listenResult.error.toString();
      _log.warning('监听失败：${listenResult.error}');
    }
    notifyListeners();

    // 开启局域网发现。
    final discoveryResult = await _discoveryRepository.start(_localInfo!);
    if (discoveryResult is Error<void>) {
      _errorMessage = discoveryResult.error.toString();
      _log.warning('发现失败：${discoveryResult.error}');
    }
    notifyListeners();
  }

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

  /// 重新搜索局域网设备（清空当前列表后重新广播/监听一轮）。
  Future<void> restartDiscovery() async {
    final info = _localInfo;
    if (info == null) return;

    _peers = const [];
    notifyListeners();

    await _discoveryRepository.stop();
    final result = await _discoveryRepository.start(info);
    if (result is Error<void>) {
      _errorMessage = result.error.toString();
      _log.warning('重新搜索失败：${result.error}');
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _peersSub?.cancel();
    super.dispose();
  }
}
