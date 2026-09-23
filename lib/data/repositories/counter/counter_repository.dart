import '../../../domain/models/counter/counter.dart';
import '../../../utils/result.dart';

/// 计数器仓储接口（Repository 层）。
///
/// 表现层只依赖这个抽象，不关心数据来自本地内存、SharedPreferences 还是远端。
/// 具体实现见 [CounterRepositoryLocal]（之后可加 [CounterRepositoryRemote]）。
abstract class CounterRepository {
  /// 读取当前计数器。
  Future<Result<Counter>> getCounter();

  /// 保存计数器。
  Future<Result<Counter>> setCounter(Counter counter);
}
