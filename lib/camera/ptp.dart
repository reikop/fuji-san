import 'dart:typed_data';
import 'package:flutter/services.dart';

Uint8List u16(int n) =>
    (ByteData(2)..setUint16(0, n & 0xffff, Endian.little)).buffer.asUint8List();
Uint8List ptpString(String value) {
  final b = ByteData(1 + (value.length + 1) * 2)..setUint8(0, value.length + 1);
  for (var i = 0; i < value.length; i++) {
    b.setUint16(1 + i * 2, value.codeUnitAt(i), Endian.little);
  }
  return b.buffer.asUint8List();
}

class Reader {
  Reader(Uint8List bytes) : data = ByteData.sublistView(bytes);
  final ByteData data;
  int offset = 0;
  int read8() {
    final n = data.getUint8(offset);
    offset++;
    return n;
  }

  int read16() {
    final n = data.getUint16(offset, Endian.little);
    offset += 2;
    return n;
  }

  int read32() {
    final n = data.getUint32(offset, Endian.little);
    offset += 4;
    return n;
  }

  String string() {
    final count = read8();
    final chars = <int>[];
    for (var i = 0; i < count; i++) {
      final c = read16();
      if (c != 0) chars.add(c);
    }
    return String.fromCharCodes(chars);
  }

  List<int> array16() {
    final count = read32();
    if (count > 65536) throw const FormatException('Invalid PTP array');
    return List.generate(count, (_) => read16());
  }
}

class Packet {
  Packet(this.type, this.code, this.transaction, this.payload);
  final int type, code, transaction;
  final Uint8List payload;
  Uint8List encode() {
    final b = ByteData(12 + payload.length)
      ..setUint32(0, 12 + payload.length, Endian.little)
      ..setUint16(4, type, Endian.little)
      ..setUint16(6, code, Endian.little)
      ..setUint32(8, transaction, Endian.little);
    b.buffer.asUint8List().setRange(12, 12 + payload.length, payload);
    return b.buffer.asUint8List();
  }

  factory Packet.decode(Uint8List bytes) {
    if (bytes.length < 12) throw const FormatException('Short PTP packet');
    final b = ByteData.sublistView(bytes);
    if (b.getUint32(0, Endian.little) != bytes.length) {
      throw const FormatException('PTP length mismatch');
    }
    return Packet(
      b.getUint16(4, Endian.little),
      b.getUint16(6, Endian.little),
      b.getUint32(8, Endian.little),
      Uint8List.sublistView(bytes, 12),
    );
  }
}

abstract interface class CameraTransport {
  Future<Uint8List> command(
    int code, {
    List<int> params = const [],
    Uint8List? outgoing,
  });
}

class NativeTransport implements CameraTransport {
  static const channel = MethodChannel('dev.reikop.fuji_san/usb');
  bool managed = false, opened = false, _busy = false;
  int transaction = 0;
  Uint8List _buffer = Uint8List(0);
  Future<List<Map<String, dynamic>>> discover() async =>
      (await channel.invokeListMethod<dynamic>('discover') ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
  Future<void> open(String id) async {
    final result = await channel.invokeMapMethod<String, dynamic>('connect', {
      'id': id,
    });
    managed = result?['managedSession'] == true;
    opened = true;
    transaction = 0;
    _buffer = Uint8List(0);
    try {
      if (!managed) await command(0x1002, params: [1]);
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> close() async {
    try {
      if (opened && !managed && !_busy) await command(0x1003);
    } catch (_) {
      /* Device may already be unplugged. */
    }
    try {
      await channel.invokeMethod<void>('disconnect');
    } finally {
      opened = false;
      _buffer = Uint8List(0);
    }
  }

  Future<Packet> _receive() async {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (true) {
      if (_buffer.length >= 4) {
        final n = ByteData.sublistView(_buffer).getUint32(0, Endian.little);
        if (n < 12 || n > 1024 * 1024) {
          throw const FormatException('Invalid PTP length');
        }
        if (_buffer.length >= n) {
          final p = Packet.decode(Uint8List.sublistView(_buffer, 0, n));
          _buffer = Uint8List.fromList(_buffer.sublist(n));
          return p;
        }
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('USB 응답 시간이 초과되었습니다.');
      }
      final next = await channel.invokeMethod<Uint8List>('read');
      if (next == null || next.isEmpty) throw StateError('USB 연결이 끊겼습니다.');
      _buffer = Uint8List.fromList([..._buffer, ...next]);
    }
  }

  @override
  Future<Uint8List> command(
    int code, {
    List<int> params = const [],
    Uint8List? outgoing,
  }) async {
    if (!opened || _busy) throw StateError('USB 세션이 없거나 사용 중입니다.');
    _busy = true;
    try {
      final id = transaction++;
      final p = ByteData(params.length * 4);
      for (var i = 0; i < params.length; i++) {
        p.setUint32(i * 4, params[i], Endian.little);
      }
      final cmd = Packet(1, code, id, p.buffer.asUint8List()).encode();
      Uint8List data = Uint8List(0);
      late Packet response;
      if (managed) {
        final result = await channel.invokeMapMethod<String, dynamic>(
          'transaction',
          {'command': cmd, 'outgoing': outgoing},
        );
        response = Packet.decode(result!['response'] as Uint8List);
        data = result['data'] as Uint8List;
      } else {
        await channel.invokeMethod<void>('write', cmd);
        if (outgoing != null) {
          await channel.invokeMethod<void>(
            'write',
            Packet(2, code, id, outgoing).encode(),
          );
        }
        response = await _receive();
        if (response.type == 2) {
          if (response.transaction != id || response.code != code) {
            throw const FormatException('PTP data transaction mismatch');
          }
          data = response.payload;
          response = await _receive();
        }
      }
      if (response.type != 3 || response.transaction != id) {
        throw const FormatException('PTP response mismatch');
      }
      if (response.code != 0x2001) {
        throw StateError(
          '카메라 응답 0x${response.code.toRadixString(16)} (명령 0x${code.toRadixString(16)})',
        );
      }
      return data;
    } on PlatformException {
      await _invalidate();
      rethrow;
    } on FormatException {
      await _invalidate();
      rethrow;
    } finally {
      _busy = false;
    }
  }

  Future<void> _invalidate() async {
    opened = false;
    _buffer = Uint8List(0);
    try {
      await channel.invokeMethod<void>('disconnect');
    } catch (_) {
      /* Already removed. */
    }
  }
}
