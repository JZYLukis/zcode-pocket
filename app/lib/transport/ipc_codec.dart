import 'dart:convert';
import 'dart:typed_data';

/// Value codec mirroring `Sm()`/`Cm()` in the web client.
///
/// Type tags: Undefined=0, String=1, Buffer=2, VSBuffer=3, Array=4,
/// Object=5 (JSON), Int=6. Lengths/counts are 7-bit little-endian varints.
class ValueWriter {
  final BytesBuilder _builder = BytesBuilder();

  void writeByte(int v) => _builder.addByte(v & 0xFF);

  void writeVarint(int value) {
    var v = value;
    do {
      var byte = v & 0x7F;
      v >>= 7;
      if (v > 0) byte |= 0x80;
      _builder.addByte(byte);
    } while (v > 0);
  }

  void writeBytes(List<int> bytes) => _builder.add(bytes);

  Uint8List toBytes() => _builder.toBytes();
}

class ValueReader {
  static const maxContainerItems = 100000;

  /// 单值字节上限=64MiB，与 [RpcFrameTransport.maxMessageBytes] 单一真源
  /// 绑定（开源审查批B组2 G2 P2-3/G3 P2-4：旧值 16MiB 与 rpc-frame 重组
  /// 层的 64MiB 跨层不一致——16-64MiB 的逻辑消息在重组成功后被解码层
  /// 静默丢弃，历史回归"大快照静默丢=永久 spinner"在上一层复活；真源
  /// 在本层，rpc_frame_transport 引用此值）。
  static const maxValueBytes = 64 * 1024 * 1024;

  final Uint8List data;
  int pos = 0;

  ValueReader(this.data);

  int get remaining => data.length - pos;

  Uint8List read(int n) {
    if (pos + n > data.length) {
      throw FormatException(
        'ValueReader: cannot read $n bytes, only ${data.length - pos} remaining',
      );
    }
    final end = pos + n;
    final out = Uint8List.sublistView(data, pos, end);
    pos = end;
    return out;
  }

  int readVarint() {
    var value = 0;
    var shift = 0;
    while (pos < data.length) {
      final b = data[pos++];
      if (shift == 28 && (b & 0xF0) != 0) {
        throw FormatException('ValueReader: varint overflow at pos $pos');
      }
      value |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return value;
      shift += 7;
      if (shift >= 35) break;
    }
    throw FormatException('ValueReader: invalid varint at pos $pos');
  }
}

void encodeValue(ValueWriter w, Object? value) {
  if (value == null) {
    w.writeByte(0);
  } else if (value is String) {
    final bytes = utf8.encode(value);
    w.writeByte(1);
    w.writeVarint(bytes.length);
    w.writeBytes(bytes);
  } else if (value is Uint8List) {
    w.writeByte(3);
    w.writeVarint(value.length);
    w.writeBytes(value);
  } else if (value is List) {
    w.writeByte(4);
    w.writeVarint(value.length);
    for (final item in value) {
      encodeValue(w, item);
    }
  } else if (value is int && value >= 0 && value <= 0x7FFFFFFF) {
    w.writeByte(6);
    w.writeVarint(value);
  } else {
    final bytes = utf8.encode(jsonEncode(value));
    w.writeByte(5);
    w.writeVarint(bytes.length);
    w.writeBytes(bytes);
  }
}

/// 解码递归深度上限（开源审查 G1-P3-3/G2-P3-12/G3-P3-8）：16MiB 上限
/// 内可构造百万级嵌套数组 → 栈溢出（handleMessage 的 catch 能兜 Error，
/// 但栈溢出后恢复不可靠）。128 层远超任何合法载荷（快照嵌套 ~10 级）。
const int maxValueDepth = 128;

Object? decodeValue(ValueReader r, {int depth = 0}) {
  if (depth > maxValueDepth) {
    throw FormatException('ValueReader: nesting too deep');
  }
  final tag = r.read(1)[0];
  switch (tag) {
    case 0:
      return null;
    case 1:
      final length = r.readVarint();
      if (length > ValueReader.maxValueBytes) {
        throw FormatException('ValueReader: string too large');
      }
      return utf8.decode(r.read(length));
    case 2:
    case 3:
      final length = r.readVarint();
      if (length > ValueReader.maxValueBytes) {
        throw FormatException('ValueReader: bytes too large');
      }
      return r.read(length);
    case 4:
      final count = r.readVarint();
      if (count > ValueReader.maxContainerItems) {
        throw FormatException('ValueReader: list too large');
      }
      return List<Object?>.generate(
        count,
        (_) => decodeValue(r, depth: depth + 1),
      );
    case 5:
      final length = r.readVarint();
      if (length > ValueReader.maxValueBytes) {
        throw FormatException('ValueReader: object too large');
      }
      return jsonDecode(utf8.decode(r.read(length)));
    case 6:
      return r.readVarint();
    default:
      throw FormatException('unknown value tag $tag');
  }
}
