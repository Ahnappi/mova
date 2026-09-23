import '../../services/counter/counter_service.dart';
import '../../../domain/models/counter/counter.dart';
import '../../../utils/result.dart';
import 'counter_repository.dart';

/// 本地实现：把计数器数据交给 [CounterService] 处理。
class CounterRepositoryLocal implements CounterRepository {
  CounterRepositoryLocal(this._service);

  final CounterService _service;

  @override
  Future<Result<Counter>> getCounter() => _service.load();

  @override
  Future<Result<Counter>> setCounter(Counter counter) => _service.save(counter);
}
