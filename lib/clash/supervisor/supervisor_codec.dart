import 'dart:convert';
import 'dart:typed_data';

const controlFrameLimit = 4096;
const businessFrameLimit = 10 * 1024 * 1024;

class SupervisorFailure implements Exception {
  const SupervisorFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

const protocolFailure = SupervisorFailure('控制会话协议校验失败');

Uint8List encodeSupervisorFrame(Map<String, dynamic> value, int limit) {
  final bytes = utf8.encode(jsonEncode(value));
  if (bytes.isEmpty || bytes.length > limit) throw protocolFailure;
  final frame = Uint8List(4 + bytes.length);
  ByteData.sublistView(frame).setUint32(0, bytes.length, Endian.little);
  frame.setRange(4, frame.length, bytes);
  return frame;
}

// 只分配当前帧，按剩余字节消费chunk；不收集完整chunk列表或帧列表。
class SupervisorFrameReader {
  SupervisorFrameReader(this.limit, this.onFrame);
  final int Function() limit;
  final void Function(String) onFrame;
  final Uint8List _header = Uint8List(4);
  int _headerUsed = 0;
  Uint8List? _body;
  int _bodyUsed = 0;
  bool _failed = false;

  void add(List<int> chunk) {
    if (_failed) throw protocolFailure;
    try {
      int offset = 0;
      while (offset < chunk.length) {
        if (_body == null) {
          final remaining = chunk.length - offset;
          final count = 4 - _headerUsed < remaining
              ? 4 - _headerUsed
              : remaining;
          _header.setRange(_headerUsed, _headerUsed + count, chunk, offset);
          _headerUsed += count;
          offset += count;
          if (_headerUsed != 4) continue;
          final size = ByteData.sublistView(
            _header,
          ).getUint32(0, Endian.little);
          if (size == 0 || size > limit()) throw protocolFailure;
          _body = Uint8List(size);
          _bodyUsed = 0;
        }
        final body = _body!;
        final remaining = chunk.length - offset;
        final count = body.length - _bodyUsed < remaining
            ? body.length - _bodyUsed
            : remaining;
        body.setRange(_bodyUsed, _bodyUsed + count, chunk, offset);
        _bodyUsed += count;
        offset += count;
        if (_bodyUsed == body.length) {
          final value = utf8.decode(body, allowMalformed: false);
          _headerUsed = 0;
          _body = null;
          _bodyUsed = 0;
          onFrame(value);
        }
      }
    } catch (_) {
      _failed = true;
      throw protocolFailure;
    }
  }

  void finish() {
    if (_failed || _headerUsed != 0 || _body != null) throw protocolFailure;
  }
}

// jsonDecode会覆盖重复键；先扫描每层对象并拒绝重复键，再使用SDK解析值。
Map<String, dynamic> strictSupervisorObject(String source) {
  try {
    _UniqueJson(source).check();
    final value = jsonDecode(source);
    if (value is! Map<String, dynamic>) throw protocolFailure;
    return value;
  } catch (_) {
    throw protocolFailure;
  }
}

class _UniqueJson {
  _UniqueJson(this.source);
  final String source;
  int offset = 0;
  int depth = 0;
  void whitespace() {
    while (offset < source.length && ' \r\n\t'.contains(source[offset])) {
      offset++;
    }
  }

  void check() {
    value();
    whitespace();
    if (offset != source.length) throw protocolFailure;
  }

  String string() {
    final start = offset++;
    while (offset < source.length) {
      final c = source[offset++];
      if (c == '\\') {
        if (offset >= source.length) throw protocolFailure;
        offset++;
      } else if (c == '"') {
        return jsonDecode(source.substring(start, offset)) as String;
      }
    }
    throw protocolFailure;
  }

  void value() {
    whitespace();
    if (offset >= source.length || ++depth > 128) throw protocolFailure;
    final c = source[offset];
    if (c == '{') {
      offset++;
      whitespace();
      final keys = <String>{};
      if (offset < source.length && source[offset] == '}') {
        offset++;
      } else {
        while (true) {
          whitespace();
          if (offset >= source.length || source[offset] != '"') {
            throw protocolFailure;
          }
          if (!keys.add(string())) throw protocolFailure;
          whitespace();
          if (offset >= source.length || source[offset++] != ':') {
            throw protocolFailure;
          }
          value();
          whitespace();
          if (offset >= source.length) throw protocolFailure;
          final end = source[offset++];
          if (end == '}') break;
          if (end != ',') throw protocolFailure;
        }
      }
    } else if (c == '[') {
      offset++;
      whitespace();
      if (offset < source.length && source[offset] == ']') {
        offset++;
      } else {
        while (true) {
          value();
          whitespace();
          if (offset >= source.length) throw protocolFailure;
          final end = source[offset++];
          if (end == ']') break;
          if (end != ',') throw protocolFailure;
        }
      }
    } else if (c == '"') {
      string();
    } else {
      final start = offset;
      while (offset < source.length && !' \r\n\t,]}'.contains(source[offset])) {
        offset++;
      }
      if (offset == start) throw protocolFailure;
      jsonDecode(source.substring(start, offset));
    }
    depth--;
  }
}

void exactKeys(Map<String, dynamic> value, List<String> keys) {
  if (value.length != keys.length ||
      keys.any((key) => !value.containsKey(key))) {
    throw protocolFailure;
  }
}
