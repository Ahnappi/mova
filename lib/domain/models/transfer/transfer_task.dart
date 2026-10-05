/// 传输方向。
enum TransferDirection { sending, receiving }

/// 传输状态。
enum TransferStatus {
  /// 已在发送队列里排队，还没有向对端发出请求。
  ///
  /// 与 [waiting] 的区别很重要：排队中的文件对端根本不知道它存在，
  /// 因此不能开始「等对端应答」的计时。一次发三个文件时，若排队也算
  /// 在计时内，后两个会在轮到它们之前就被判成「对方没有响应」。
  queued,

  /// 等待对方确认（已发出请求 / 收到请求待接收）。
  waiting,

  /// 接收方正在准备接收：选目录、探测写权限、创建临时文件。
  ///
  /// 这几个步骤都包含 await，期间对端可能取消、连接可能断开、用户可能
  /// 再点一次「接收」。它既不是「等你点接收」的 waiting，也不是
  /// 「已经在收数据」的 transferring——单独占一个状态，才能让重复点击
  /// 被挡回去、让迟到的取消在准备返回时被认出来。
  preparing,

  /// 正在传输。
  transferring,

  /// 数据已发完，等待对端核对并回执。
  ///
  /// 「推完流」还不算完成：接收端要核对字节数与校验值、把临时文件改名存好，
  /// 再发回执。这段时间任务仍然是活跃的，不能被当成已终结。
  confirming,

  /// 已完成（双方一致确认）。
  completed,

  /// 已拒绝。
  ///
  /// 注意它同时表示两种相反的情形，界面必须按 [TransferTask.direction]
  /// 区分：接收方拒绝是自己拒的，发送方收到 reject 帧才是「对方已拒绝」
  /// （reject 帧只有接收方发得出去）。
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
  TransferTask({
    required this.id,
    required this.fileName,
    required this.totalBytes,
    required this.direction,
    required this.status,
    DateTime? createdAt,
    this.transferredBytes = 0,
    this.localPath,
    this.error,
    this.speedBytesPerSecond = 0,
    this.averageSpeedBytesPerSecond = 0,
    this.sessionId = '',
    this.batchId,
    this.batchIndex,
    this.batchCount,
  }) : createdAt = createdAt ?? DateTime(1970);

  /// 传输 id（发起方分配，随机生成以避免双方撞号）。
  final int id;

  /// 批次标识：同一次「批量发送」的文件共享同一个值。
  ///
  /// 接收端据此把一批文件聚成一组展示，让用户一次决定收哪些；
  /// 单独发来的文件也可以有（这批就只有它一个）。
  final int? batchId;

  /// 在本批中的序号（从 0 开始）。
  final int? batchIndex;

  /// 本批总共有几个文件。
  final int? batchCount;

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

  /// 平滑后的平均速度（字节/秒），仅用于估算剩余时间。
  ///
  /// 瞬时速度抖动很大（每 500ms 采样一次，局域网下能差好几倍），
  /// 直接拿它算「还剩多久」会让倒计时来回乱跳，因此单独维护一个
  /// 指数滑动平均，0 表示还没有可用样本。
  final double averageSpeedBytesPerSecond;

  /// 任务创建时间（用于在聊天流里按时间归并展示）。
  final DateTime createdAt;

  /// 所属会话标识（换设备连接后据此清理旧任务）。
  final String sessionId;

  /// 进度 0.0 ~ 1.0；未知大小时为 0。
  double get progress =>
      totalBytes <= 0 ? 0 : (transferredBytes / totalBytes).clamp(0.0, 1.0);

  /// 预计剩余秒数；无法估算时为 null。
  ///
  /// 只在真正传输中才有意义：等待对方确认时没有速度样本，
  /// 已终结的任务也不需要倒计时。
  int? get etaSeconds {
    if (status != TransferStatus.transferring) return null;
    final remaining = totalBytes - transferredBytes;
    if (remaining <= 0) return 0;
    if (averageSpeedBytesPerSecond <= 0) return null;
    return (remaining / averageSpeedBytesPerSecond).ceil();
  }

  /// 是否仍在进行中（未终结）。
  bool get isActive =>
      status == TransferStatus.queued ||
      status == TransferStatus.waiting ||
      status == TransferStatus.preparing ||
      status == TransferStatus.transferring ||
      status == TransferStatus.confirming;

  /// 是否已终结（成功/失败/取消/拒绝）。
  bool get isFinished => !isActive;

  TransferTask copyWith({
    int? transferredBytes,
    TransferStatus? status,
    String? localPath,
    String? error,
    int? speedBytesPerSecond,
    double? averageSpeedBytesPerSecond,
    String? sessionId,
  }) {
    return TransferTask(
      id: id,
      fileName: fileName,
      totalBytes: totalBytes,
      direction: direction,
      status: status ?? this.status,
      // 必须带上：否则每帧进度更新都会把创建时间重置为纪元，
      // 导致聊天流里的时间线错乱、时间显示为 1970。
      createdAt: createdAt,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      localPath: localPath ?? this.localPath,
      error: error ?? this.error,
      speedBytesPerSecond: speedBytesPerSecond ?? this.speedBytesPerSecond,
      averageSpeedBytesPerSecond:
          averageSpeedBytesPerSecond ?? this.averageSpeedBytesPerSecond,
      sessionId: sessionId ?? this.sessionId,
    );
  }
}
