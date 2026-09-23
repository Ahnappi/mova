/// 传输方向。
enum TransferDirection { sending, receiving }

/// 传输状态。
enum TransferStatus {
  /// 等待对方确认（已发出请求 / 收到请求待接收）。
  waiting,

  /// 正在传输。
  transferring,

  /// 已完成。
  completed,

  /// 对方拒绝。
  rejected,

  /// 已取消。
  canceled,

  /// 失败。
  failed,
}

/// 一个文件传输任务（Domain 层，纯 Dart 模型）。
///
/// 收发两端共用同一个模型：发送端与接收端各自维护自己的任务对象，
/// 因此**两边都能看到自己的进度条**。
class TransferTask {
  const TransferTask({
    required this.id,
    required this.fileName,
    required this.totalBytes,
    required this.direction,
    required this.status,
    this.transferredBytes = 0,
    this.localPath,
    this.error,
    this.speedBytesPerSecond = 0,
  });

  /// 传输 id（发起方分配，随机生成以避免双方撞号）。
  final int id;

  final String fileName;
  final int totalBytes;
  final TransferDirection direction;
  final TransferStatus status;

  /// 已传输字节数。
  final int transferredBytes;

  /// 发送端为源文件路径，接收端为保存路径。
  final String? localPath;

  /// 失败/取消原因。
  final String? error;

  /// 瞬时速度（字节/秒），用于界面展示。
  final int speedBytesPerSecond;

  /// 进度 0.0 ~ 1.0；未知大小时为 0。
  double get progress =>
      totalBytes <= 0 ? 0 : (transferredBytes / totalBytes).clamp(0.0, 1.0);

  /// 是否仍在进行中（未终结）。
  bool get isActive =>
      status == TransferStatus.waiting || status == TransferStatus.transferring;

  /// 是否已终结（成功/失败/取消/拒绝）。
  bool get isFinished => !isActive;

  TransferTask copyWith({
    int? transferredBytes,
    TransferStatus? status,
    String? localPath,
    String? error,
    int? speedBytesPerSecond,
  }) {
    return TransferTask(
      id: id,
      fileName: fileName,
      totalBytes: totalBytes,
      direction: direction,
      status: status ?? this.status,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      localPath: localPath ?? this.localPath,
      error: error ?? this.error,
      speedBytesPerSecond: speedBytesPerSecond ?? this.speedBytesPerSecond,
    );
  }
}
