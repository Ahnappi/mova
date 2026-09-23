import 'dart:async';

import '../../../config/app_config.dart';
import '../../../domain/models/chat/local_info.dart';
import '../../../domain/models/chat/peer.dart';
import '../../../utils/result.dart';
import '../../services/discovery/discovery_service.dart';
import 'discovery_repository.dart';

/// 本地（局域网 UDP）实现：维护对端表并按心跳超时剔除离线设备。
class DiscoveryRepositoryLocal implements DiscoveryRepository {
  DiscoveryRepositoryLocal(this._service) {
    _serviceSub = _service.onPeer.listen(_onPeer);
  }

  final DiscoveryService _service;

  final Map<String, Peer> _peers = {};
  final Map<String, DateTime> _lastSeen = {};
  final StreamController<List<Peer>> _controller =
      StreamController<List<Peer>>.broadcast();

  StreamSubscription<Peer>? _serviceSub;
  Timer? _pruneTimer;

  @override
  Stream<List<Peer>> get peers => _controller.stream;

  @override
  List<Peer> get currentPeers => _peers.values.toList();

  @override
  Future<Result<void>> start(LocalInfo self) {
    // 仅在真正开启发现后才开始清理离线设备。
    _pruneTimer ??= Timer.periodic(const Duration(seconds: 3), (_) => _prune());

    return _service.start(
      self: <String, dynamic>{
        'app': 'mova',
        'id': self.id,
        'name': self.name,
        'ip': self.ip,
        'tcpPort': self.tcpPort,
        'platform': self.platform,
      },
    );
  }

  /// 停止发现：关闭 socket、停止清理定时器，并清空已发现的设备。
  ///
  /// 由用户手动控制搜索与否，因此停止后不应残留旧设备。
  @override
  Future<void> stop() async {
    _pruneTimer?.cancel();
    _pruneTimer = null;
    await _service.stop();

    if (_peers.isNotEmpty) {
      _peers.clear();
      _lastSeen.clear();
      _emit();
    }
  }

  @override
  Future<void> dispose() async {
    _pruneTimer?.cancel();
    await _serviceSub?.cancel();
    await stop();
    await _controller.close();
  }

  void _onPeer(Peer peer) {
    _peers[peer.id] = peer;
    _lastSeen[peer.id] = DateTime.now();
    _emit();
  }

  /// 剔除超过 [AppConfig.peerTimeout] 未再收到心跳的设备。
  void _prune() {
    final now = DateTime.now();
    final stale = _lastSeen.entries
        .where((entry) => now.difference(entry.value) > AppConfig.peerTimeout)
        .map((entry) => entry.key)
        .toList();

    if (stale.isEmpty) return;

    for (final id in stale) {
      _peers.remove(id);
      _lastSeen.remove(id);
    }
    _emit();
  }

  void _emit() {
    final list = _peers.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    _controller.add(list);
  }
}
