import 'dart:typed_data';

/// 传输层事件（Domain 层模型）：把「线路上发生了什么」抽象成类型化的事件，
/// 供 Repository 层消费，避免 UI 直接触碰 socket 细节。
sealed class TransferEvent {}

/// 对端发来文件发送请求。
class OfferReceived extends TransferEvent {
  OfferReceived({required this.fileId, required this.name, required this.size});

  final int fileId;
  final String name;
  final int size;
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
class EndReceived extends TransferEvent {
  EndReceived(this.fileId);

  final int fileId;
}

/// 对端（或我方）取消传输。
class CancelReceived extends TransferEvent {
  CancelReceived({required this.fileId, this.reason});

  final int fileId;
  final String? reason;
}
