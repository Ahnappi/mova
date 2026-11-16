import 'package:flutter_test/flutter_test.dart';
import 'package:mova/utils/transfer_speed.dart';

void main() {
  test('固定窗口包含无数据时段，五秒无新增后归零', () {
    final meter = TransferSpeed(Duration.zero, 0);
    expect(meter.sample(const Duration(seconds: 1), 1000), 1000);
    expect(meter.sample(const Duration(seconds: 2), 1000), 500);
    for (var second = 3; second <= 5; second++) {
      meter.sample(Duration(seconds: second), 1000);
    }
    expect(meter.sample(const Duration(seconds: 6), 1000), 0);
  });

  test('连续传输速度稳定，窗口淘汰早期突发流量', () {
    final meter = TransferSpeed(Duration.zero, 0);
    meter.sample(const Duration(seconds: 1), 10000);
    for (var second = 2; second <= 6; second++) {
      final speed = meter.sample(Duration(seconds: second), 10000 + (second - 1) * 1000);
      if (second == 6) expect(speed, 1000);
    }
  });

  test('不等间隔按实际时间计算，累计值回退时重新开始', () {
    final meter = TransferSpeed(Duration.zero, 0);
    expect(meter.sample(const Duration(milliseconds: 2500), 5000), 2000);
    expect(meter.sample(const Duration(seconds: 3), 0), 0);
    expect(meter.sample(const Duration(seconds: 4), 1000), 1000);
  });
}
