import 'dart:convert';
import 'dart:typed_data';

import '../../../config/app_config.dart';

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
/// - length 只描述 payload 长度。它**由对端填写**，因此解析时必须按类型
///   校验上限（见 [maxPayloadLength]）：直接信它的后果是为一个数 GB 的
///   巨帧一路扩容，直到内存耗尽；
/// - 控制类帧的 payload 是 UTF-8 JSON；文件块帧的 payload 是
///   `fileId (4B, 大端) + 原始数据`，这样即使将来并发传多个文件也能区分归属。
///
/// 收尾握手（v1 之后补上，两端都做了兼容）：
/// - [MessageType.fileEnd] 带 `size` 与可选 `crc`：发送端声明自己发了多少字节、
///   内容校验值是多少；
/// - [MessageType.fileDone] 是接收端的回执：核对通过才回 `ok=true`。
///   老版本的对端不认识 9 号帧会直接跳过，发送端按超时处理。
enum MessageType {
  hello(1),
  text(2),
  fileOffer(3),
  fileAccept(4),
  fileReject(5),
  fileChunk(6),
  fileEnd(7),
  fileCancel(8),
  fileDone(9),
  /// 存活探测（心跳）。
  ///
  /// 存在的理由：一条 TCP 连接建立之后，如果两端都不说话，谁也不知道
  /// 对方还在不在。对端合盖、Wi-Fi 断了、进程被杀，这些情况既不会发
  /// FIN 也不会发 RST，本端能一直「以为还连着」直到下一次真正写数据
  /// 失败——而那可能是几分钟以后。
  ///
  /// 所以建连后双方定期发这个帧：它只有 10 个字节的空 payload，开销可
  /// 以忽略；收到的一方不需要回包，只要「收到任何字节」就刷新存活时间。
  /// 连续几个周期一个字节都没收到，就判定连接已经死了。
  ///
  /// 不认识这个类型的老对端会按 :277 的规则直接跳过，不会断连。
  ping(10);

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

/// 帧格式版本（帧头第 5 个字节）。
///
/// 与 [AppConfig.protocolVersion] 是两回事：那个是「应用层能力版本」，
/// 在 hello 帧里互报、用于兼容老对端；这个是**分帧格式**的版本，
/// 格式一变就没有任何兼容余地，因此不符即断开。
const int frameVersion = 1;

/// 控制类帧（JSON）的 payload 上限：64 KiB。
///
/// 名字、文件清单这类内容再长也不该超过这个量级。
const int maxControlPayloadLength = 64 * 1024;

/// 文件块帧的 payload 上限：`fileId(4B) + 数据`。
///
/// 以当前块大小为基准留一倍余量（对端将来把块调大一点也不至于连不上），
/// 但绝不接受 GB 级的声明——那不是传输，是把内存往外倒。
final int maxChunkPayloadLength = 4 + 2 * AppConfig.fileChunkSize;

/// 文件块帧的 payload 下限：`fileId(4B)` 之后至少要有一个字节。
///
/// 空块没有任何意义，只可能是异常对端或解析错乱的产物。
const int minChunkPayloadLength = 5;

/// 解析缓冲上限：一帧的极限大小再加一个网络包的余量。
final int maxFrameBufferLength =
    frameHeaderSize + maxChunkPayloadLength + 64 * 1024;

/// 该类帧允许的 payload 上限。
///
/// 未知类型按控制帧处理：本机反正会跳过它，没必要为它预留更大的缓冲。
int maxPayloadLength(MessageType? type) =>
    type == MessageType.fileChunk ? maxChunkPayloadLength : maxControlPayloadLength;

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
///
/// 长度超限直接抛错：我们自己也绝不发出一个对端会拒绝的帧。
Uint8List encodeFrame(MessageType type, Uint8List payload) {
  final limit = maxPayloadLength(type);
  if (payload.length > limit) {
    throw ArgumentError.value(
      payload.length,
      'payload',
      '${type.name} 帧超过 $limit 字节上限',
    );
  }
  final frame = Uint8List(frameHeaderSize + payload.length);
  frame.setRange(0, 4, _magic);
  frame[4] = frameVersion;
  frame[5] = type.value;
  _writeUint32(frame, 6, payload.length);
  frame.setRange(frameHeaderSize, frame.length, payload);
  return frame;
}

/// 编码一个 JSON 控制帧（内容一定很短时用这个，超长会抛异常）。
Uint8List encodeJsonFrame(MessageType type, Map<String, dynamic> json) =>
    encodeFrame(type, utf8.encode(jsonEncode(json)));

/// 编码一个 JSON 控制帧；编码后超限时返回 null（**不抛异常**）。
///
/// 用返回值而不是异常来表达「太长」：消息长度完全由用户粘贴的内容决定，
/// 这是**预期内**的情况，调用方要把它翻译成一句人能看懂的提示，
/// 而不是让异常一路冒到界面上（那样输入还被清空了，内容却没发出去）。
Uint8List? tryEncodeJsonFrame(MessageType type, Map<String, dynamic> json) {
  final bytes = utf8.encode(jsonEncode(json));
  if (bytes.length > maxPayloadLength(type)) return null;
  return encodeFrame(type, bytes);
}

/// 一个 JSON 控制帧编码后的实际字节数（UTF-8，含转义后的膨胀）。
///
/// 判断「这条消息发不发得出去」必须按**编码后**的大小算：
/// 一个中文字符占 3 字节，`"` `\` 换行等还会被 JSON 转义放大，
/// 只看 `text.length`（UTF-16 码元数）会严重低估。
int jsonFrameLength(Map<String, dynamic> json) =>
    utf8.encode(jsonEncode(json)).length;

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
///
/// **帧头的 length 是对方给的，不能直接信**。解析器一旦接受一个
/// 「数 GB 的帧」，就会一边等数据凑齐一边不断扩容，而背压机制
/// （写盘队列积压上限）此刻完全帮不上忙——字节还没解析成帧，
/// 根本进不了写盘队列。所以长度、版本、类型在**等数据之前**就要校验，
/// 超限一律置 [hasViolation]，由调用方断开连接。
class FrameReader {
  Uint8List _buffer = Uint8List(64 * 1024);
  int _start = 0;
  int _end = 0;
  String? _violation;

  /// 是否遇到了**必须断开连接**的协议错误。
  ///
  /// 置位后解析器不再产出任何帧。调用方应当立刻断开，
  /// 否则后续的字节全都是无从判断归属的可疑数据。
  bool get hasViolation => _violation != null;

  /// 协议错误的原因（无错误时为 null）。
  String? get violation => _violation;

  /// 丢弃缓冲区中的残留字节。
  ///
  /// 解析器是**长期复用**的：一条连接断开后，缓冲区里往往还留着半个帧
  /// （对端传到大文件一半就断了）。不清掉的话，下一次连接会把这半个帧
  /// 当成新会话的开头来解析——要么一上来就解析失败，要么更糟：
  /// 半截文件块被当成控制帧，整个会话一开始就乱套。
  void reset() {
    _start = 0;
    _end = 0;
    // 新连接该从干净状态开始：上一次的协议错误不能连坐。
    _violation = null;
  }

  /// 写入新到达的字节。
  void add(Uint8List data) {
    if (_violation != null) return;

    final required = _end - _start + data.length;
    // 缓冲本身也要有上界：这是长度校验之外的第二道闸，
    // 防止任何一条漏网的路径把缓冲撑大。
    if (required > maxFrameBufferLength) {
      _violate('单次数据 $required 字节，超过缓冲上限');
      return;
    }
    _ensureCapacity(required);
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
      if (_violation != null) return null;

      final available = _end - _start;
      if (available < frameHeaderSize) return null;

      if (!_hasMagicAt(_start)) {
        if (!_resync()) return null;
        continue;
      }

      final version = _buffer[_start + 4];
      if (version != frameVersion) {
        _violate('帧格式版本不符（对端 $version，本机 $frameVersion）');
        return null;
      }

      final type = MessageType.tryFromValue(_buffer[_start + 5]);
      final length = _readUint32(_buffer, _start + 6);

      // 关键：在「等数据凑齐」**之前**就判长度，否则解析器会为一个
      // 永远等不到的巨帧一路扩容。
      final limit = maxPayloadLength(type);
      if (length > limit) {
        _violate('${type?.name ?? '未知'}帧声明 $length 字节，超过上限 $limit');
        return null;
      }
      if (type == MessageType.fileChunk && length < minChunkPayloadLength) {
        _violate('文件块帧只有 $length 字节，不足 $minChunkPayloadLength');
        return null;
      }

      final total = frameHeaderSize + length;
      if (available < total) return null;

      final payload = Uint8List.fromList(
        Uint8List.sublistView(_buffer, _start + frameHeaderSize, _start + total),
      );
      _start += total;
      if (type == null) continue; // 未知类型：跳过，保证向后兼容
      return Frame(type, payload);
    }
  }

  /// 记下致命协议错误并丢弃全部缓冲：可疑的字节一个都不留。
  void _violate(String message) {
    _violation = message;
    _start = 0;
    _end = 0;
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
