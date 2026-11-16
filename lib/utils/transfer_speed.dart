import 'dart:collection';

/// 最近五秒的累计字节差。由固定周期调用，空闲样本使速度回落到零。
class TransferSpeed {
  TransferSpeed(Duration at, int bytes) { _samples.add((at, bytes)); }
  final Queue<(Duration, int)> _samples = Queue();

  int sample(Duration at, int bytes) {
    final last = _samples.last;
    if (at <= last.$1) return 0;
    if (bytes < last.$2) { _samples.clear(); _samples.add((at, bytes)); return 0; }
    _samples.add((at, bytes));
    final cutoff = at - const Duration(seconds: 5);
    while (_samples.length > 2 && _samples.elementAt(1).$1 <= cutoff) {
      _samples.removeFirst();
    }
    final first = _samples.first;
    return ((bytes - first.$2) * 1000000 / (at - first.$1).inMicroseconds).round();
  }
}
