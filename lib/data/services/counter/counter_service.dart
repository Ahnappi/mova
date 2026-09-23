import '../../../domain/models/counter/counter.dart';
import '../../../utils/result.dart';

/// 计数器数据源（Service 层 / 数据来源）。
///
/// 当前为内存实现。后续可替换为 SharedPreferences / 文件等持久化实现，
/// 只要保持 [load] / [save] 的签名与 [Result] 约定不变，上层（Repository、ViewModel）无需改动。
class CounterService {
  int _value = 0;

  Future<Result<Counter>> load() async {
    return Result.ok(Counter(value: _value));
  }

  Future<Result<Counter>> save(Counter counter) async {
    _value = counter.value;
    return Result.ok(counter);
  }
}
