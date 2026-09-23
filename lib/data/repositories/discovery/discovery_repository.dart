import '../../../domain/models/chat/local_info.dart';
import '../../../domain/models/chat/peer.dart';
import '../../../utils/result.dart';

/// 局域网发现仓储（Repository 抽象）。
///
/// 上层只依赖本接口，替换发现方式（UDP / mDNS）时 UI 与 ViewModel 无需改动。
abstract class DiscoveryRepository {
  /// 当前在线对端列表的变化流。
  Stream<List<Peer>> get peers;

  /// 当前对端快照（供首次渲染使用）。
  List<Peer> get currentPeers;

  /// 开启发现并广播 [self]。
  Future<Result<void>> start(LocalInfo self);

  /// 停止发现。
  Future<void> stop();

  /// 释放资源。
  Future<void> dispose();
}
