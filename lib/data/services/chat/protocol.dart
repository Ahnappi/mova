import 'dart:convert';
import 'dart:typed_data';

/// 应用层帧协议（Service 层的协议细节）。
///
/// 之所以从「一行 JSON」升级为「二进制分帧」：文件传输需要与控制消息共用一条
/// TCP 连接，而文件内容里可能本身就含有 `\n`，行式协议无法安全区分。
///
/// 帧格式（小头开销固定 10 字节）：
/// ```
/// | magic 'MOVA' (4B) | version (1B) | type (1B) | length (4B, 大端) | payload (length B) |
/// ```
/// - magic 用于校验与重新同步；
/// - length 只描述 payload 长度，块大小 1MiB 远小于 uint32 上限；
/// - 控制类帧的 payload 是 UTF-8 JSON；文件块帧的 payload 是
///   `fileId (4B, 大端) + 原始数据`，这样即使将来并发传多个文件也能区分归属。
enum MessageType {
  hello(1),
  text(2),
  fileOffer(3),
  fileAccept(4),
  fileReject(5),
  fileChunk(6),
  fileEnd(7),
  fileCancel(8);

  const MessageType(this.value);

  final int value;

  static MessageType? tryFromValue(int value) {
    for (final type in MessageType.values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

/// 一帧：类型 + 原始负载。
class Frame {
  const Frame(this.type, this.payload);

  final MessageType type;
  final Uint8List payload;

  /// 把负载按 UTF-8 JSON 解析。
  Map<String, dynamic> get json =>
      jsonDecode(utf8.decode(payload, allowMalformed: true)) as Map<String, dynamic>;
}

/// 帧头固定长度。
const int frameHeaderSize = 10;

final Uint8List _magic = Uint8List.fromList([0x4D, 0x4F, 0x56, 0x41]); // MOVA
const int _version = 1;

void _writeUint32(Uint8List target, int offset, int value) {
  target[offset] = (value >> 24) & 0xFF;
  target[offset + 1] = (value >> 16) & 0xFF;
  target[offset + 2] = (value >> 8) & 0xFF;
  target[offset + 3] = value & 0xFF;
}

int _readUint32(Uint8List source, int offset) =>
    (source[offset] << 24) |
    (source[offset + 1] << 16) |
    (source[offset + 2] << 8) |
    source[offset + 3];

/// 编码一帧。
Uint8List encodeFrame(MessageType type, Uint8List payload) {
  final frame = Uint8List(frameHeaderSize + payload.length);
  frame.setRange(0, 4, _magic);
  frame[4] = _version;
  frame[5] = type.value;
  _writeUint32(frame, 6, payload.length);
  frame.setRange(frameHeaderSize, frame.length, payload);
  return frame;
}

/// 编码一个 JSON 控制帧。
Uint8List encodeJsonFrame(MessageType type, Map<String, dynamic> json) =>
    encodeFrame(type, utf8.encode(jsonEncode(json)));

/// 编码一个文件块帧（payload = fileId + 数据）。
Uint8List encodeChunkFrame(int fileId, Uint8List data) {
  final payload = Uint8List(4 + data.length);
  _writeUint32(payload, 0, fileId);
  payload.setRange(4, payload.length, data);
  return encodeFrame(MessageType.fileChunk, payload);
}

/// 从文件块帧的 payload 中取出 fileId。
int chunkFileId(Uint8List payload) => _readUint32(payload, 0);

/// 从文件块帧的 payload 中取出有效数据（跳过 4 字节 fileId）。
Uint8List chunkData(Uint8List payload) => Uint8List.sublistView(payload, 4);

/// 增量式帧解析器：持续喂字节流，随时取出已完整的帧。
///
/// 自己维护缓冲区与读写指针，避免每次收到数据都重建/拷贝整个缓冲
/// （传 10GB 文件时这个差异会被放大成几十 GB 的额外拷贝）。
class FrameReader {
  Uint8List _buffer = Uint8List(64 * 1024);
  int _start = 0;
  int _end = 0;

  /// 写入新到达的字节。
  void add(Uint8List data) {
    _ensureCapacity(_end - _start + data.length);
    _buffer.setRange(_end, _end + data.length, data);
    _end += data.length;
  }

  /// 取出当前缓冲中所有完整帧（可能为空）。
  List<Frame> drain() {
    final frames = <Frame>[];
    while (true) {
      final frame = _next();
      if (frame == null) break;
      frames.add(frame);
    }
    _compact();
    return frames;
  }

  Frame? _next() {
    while (true) {
      final available = _end - _start;
      if (available < frameHeaderSize) return null;

      if (!_hasMagicAt(_start)) {
        if (!_resync()) return null;
        continue;
      }

      final length = _readUint32(_buffer, _start + 6);
      final total = frameHeaderSize + length;
      if (available < total) return null;

      final type = MessageType.tryFromValue(_buffer[_start + 5]);
      final payload = Uint8List.fromList(
        Uint8List.sublistView(_buffer, _start + frameHeaderSize, _start + total),
      );
      _start += total;
      if (type == null) continue; // 未知类型：跳过，保证向后兼容
      return Frame(type, payload);
    }
  }

  bool _hasMagicAt(int offset) {
    for (var i = 0; i < 4; i++) {
      if (_buffer[offset + i] != _magic[i]) return false;
    }
    return true;
  }

  /// 流被污染时向后寻找下一个 magic，找不到就丢弃全部缓冲。
  bool _resync() {
    for (var i = _start + 1; i + 4 <= _end; i++) {
      if (_hasMagicAt(i)) {
        _start = i;
        return true;
      }
    }
    _start = _end = 0;
    return false;
  }

  /// 把剩余未消费的字节挪到缓冲区头部，避免缓冲区无限增长。
  void _compact() {
    if (_start == 0) return;
    final remaining = _end - _start;
    if (remaining == 0) {
      _start = _end = 0;
      return;
    }
    _buffer.setRange(0, remaining, Uint8List.sublistView(_buffer, _start, _end));
    _start = 0;
    _end = remaining;
  }

  void _ensureCapacity(int required) {
    if (required <= _buffer.length) return;
    var capacity = _buffer.length;
    while (capacity < required) {
      capacity *= 2;
    }
    final grown = Uint8List(capacity);
    grown.setRange(0, _end - _start, Uint8List.sublistView(_buffer, _start, _end));
    _end -= _start;
    _start = 0;
    _buffer = grown;
  }
}
