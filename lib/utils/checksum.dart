import 'dart:typed_data';

/// CRC32（IEEE 802.3，与 zip / Ethernet 同款多项式）增量计算器。
///
/// 用在文件传输的完整性校验上：发送端边读边算，接收端边写边算，
/// 收尾时比对「声明大小 + 校验值」，确认落盘结果和源文件一致。
///
/// 只做增量更新（[add]），不需要把整个文件读进内存，
/// 因此 10GB 文件和 10MB 文件的内存占用一样。
class Crc32 {
  /// 起始值：CRC32 的惯例初值（全 1）。
  static const int seed = 0xFFFFFFFF;

  static final Uint32List _table = _buildTable();

  int _value = seed;

  /// 当前校验值（已做最终异或，可直接与对端比对）。
  int get value => _value ^ seed;

  /// 追加一段数据。可多次调用，顺序即字节顺序。
  void add(Uint8List data) {
    var crc = _value;
    final table = _table;
    final length = data.length;
    for (var i = 0; i < length; i++) {
      crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
    }
    _value = crc;
  }

  /// 一次性算出整段数据的校验值。
  static int of(Uint8List data) {
    final crc = Crc32()..add(data);
    return crc.value;
  }

  static Uint32List _buildTable() {
    final table = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var value = i;
      for (var bit = 0; bit < 8; bit++) {
        value = (value & 1) != 0 ? 0xEDB88320 ^ (value >>> 1) : value >>> 1;
      }
      table[i] = value;
    }
    return table;
  }
}
