/// 计数器领域模型。
///
/// 纯 Dart，不依赖 Flutter。业务规则（自增 / 自减，最小值 0）放在这里，
/// 表现层与数据层都不应重复这些规则。
class Counter {
  const Counter({required this.value});

  final int value;

  Counter increment() => Counter(value: value + 1);

  Counter decrement() => Counter(value: value - 1 < 0 ? 0 : value - 1);
}
