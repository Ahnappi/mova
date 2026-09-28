/// 人类可读的体积/速度格式化。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(2)} GB';
}

/// 速度格式化（字节/秒）。
String formatSpeed(int bytesPerSecond) {
  if (bytesPerSecond <= 0) return '—';
  return '${formatBytes(bytesPerSecond)}/s';
}

/// 剩余时间格式化（秒）→「剩余约 1 分 20 秒」。
String formatEta(int seconds) {
  if (seconds <= 0) return '即将完成';

  if (seconds < 60) return '剩余约 $seconds 秒';

  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  if (minutes < 60) {
    return rest == 0 ? '剩余约 $minutes 分钟' : '剩余约 $minutes 分 $rest 秒';
  }

  final hours = minutes ~/ 60;
  final leftMinutes = minutes % 60;
  return leftMinutes == 0
      ? '剩余约 $hours 小时'
      : '剩余约 $hours 小时 $leftMinutes 分';
}
