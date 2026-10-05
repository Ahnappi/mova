import 'dart:typed_data';

/// 传输层事件（Domain 层模型）：把「线路上发生了什么」抽象成类型化的事件，
/// 供 Repository 层消费，避免 UI 直接触碰 socket 细节。
sealed class TransferEvent {}

/// 对端发来文件发送请求。
class OfferReceived extends TransferEvent {
  OfferReceived({
    required this.fileId,
    required this.name,
    required this.size,
    this.batchId,
    this.batchIndex,
    this.batchCount,
  });

  final int fileId;
  final String name;
  final int size;

  /// 批次标识：同一次「批量发送」的文件共享同一个值。
  ///
  /// 接收端据此把它们聚成一组一起展示（一次决定收哪些），而不是逐个
  /// 弹卡片。单独发来的文件（不是批量发送）为 null，退回逐个处理。
  final int? batchId;

  /// 在本批中的序号（从 0 开始），用于按发送端的顺序展示。
  final int? batchIndex;

  /// 本批总共有几个文件。
  final int? batchCount;
}

/// 对端同意接收（我方可以开始推流了）。
class AcceptReceived extends TransferEvent {
  AcceptReceived(this.fileId);

  final int fileId;
}

/// 对端拒绝接收。
class RejectReceived extends TransferEvent {
  RejectReceived({required this.fileId, this.reason});

  final int fileId;
  final String? reason;
}

/// 收到一个文件数据块。
class ChunkReceived extends TransferEvent {
  ChunkReceived({required this.fileId, required this.data});

  final int fileId;
  final Uint8List data;
}

/// 对端声明文件发送完毕。
///
/// [size] 为发送端实际写出的字节数（可能缺失：老版本对端不带这个字段），
/// [checksum] 为内容的 CRC32（同样可缺失）。接收端据此核对落盘结果，
/// 只有对上了才算「真的收到了」。
class EndReceived extends TransferEvent {
  EndReceived(this.fileId, {this.size, this.checksum});

  final int fileId;
  final int? size;
  final int? checksum;
}

/// 接收端的收尾回执（对应协议里的 fileDone 帧）。
///
/// [ok] 为 true 表示对方已核对大小与校验值、并把文件改名存好；
/// false 时 [reason] 说明原因（大小不符 / 校验失败 / 写盘出错）。
/// 发送端必须收到 ok=true 才能把任务标记为「已完成」。
class DoneReceived extends TransferEvent {
  DoneReceived(this.fileId, {required this.ok, this.reason});

  final int fileId;
  final bool ok;
  final String? reason;
}

/// 对端（或我方）取消传输。
class CancelReceived extends TransferEvent {
  CancelReceived({required this.fileId, this.reason});

  final int fileId;
  final String? reason;
}
