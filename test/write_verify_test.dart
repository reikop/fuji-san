import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuji_san/camera/camera.dart';
import 'package:fuji_san/camera/ptp.dart';
import 'package:fuji_san/domain/recipe.dart';

class CameraFixture implements CameraTransport {
  int selected = 4;
  bool corrupt = false;
  bool descriptorsUnavailable = false;
  final written = <int>[];
  final slots = <int, Map<int, Uint8List>>{
    for (var i = 1; i <= 7; i++)
      i: {
        0xd18d: ptpString('Original $i'),
        for (final s in settings) s.id: u16(s.initial),
        0xd1a5: u16(99),
      },
  };
  @override
  Future<Uint8List> command(
    int code, {
    List<int> params = const [],
    Uint8List? outgoing,
  }) async {
    final prop = params.first;
    if (code == 0x1015) {
      if (prop == 0xd18c) return u16(selected);
      if (corrupt && written.contains(prop) && prop == 0xd190) return u16(400);
      return Uint8List.fromList(slots[selected]![prop]!);
    }
    if (code == 0x1016) {
      if (prop == 0xd18c) {
        selected = Reader(outgoing!).read16();
      } else {
        written.add(prop);
        slots[selected]![prop] = Uint8List.fromList(outgoing!);
      }
      return Uint8List(0);
    }
    if (code == 0x1014) {
      if (descriptorsUnavailable) throw PtpResponseException(0x2002, 0x1014);
      final type = prop == 0xd18d
          ? 0xffff
          : settings.firstWhere((s) => s.id == prop).signed
          ? 3
          : 4;
      return Uint8List.fromList([
        ...u16(prop),
        ...u16(type),
        1,
        ...u16(0),
        ...u16(0),
        0,
      ]);
    }
    throw StateError('Unexpected opcode');
  }
}

void main() {
  test(
    'X100VI 1.32 accepts documented schema when descriptors return 2002',
    () async {
      final transport = CameraFixture()..descriptorsUnavailable = true;
      final camera = FujiCamera(transport)
        ..identity = CameraIdentity('X100VI', '1.32', 'test', {
          0xd18d,
          ...settings.map((s) => s.id),
        });
      final original = (await camera.backup({1})).single;
      await camera.write(1, Recipe.fresh());
      expect(Reader(transport.slots[1]![0xd18d]!).string(), 'My Recipe');
      await camera.restore(original);
      expect(Reader(transport.slots[1]![0xd18d]!).string(), 'Original 1');
      expect(transport.selected, 4);
    },
  );
  test(
    'descriptor fallback does not hide errors on unverified firmware',
    () async {
      final transport = CameraFixture()..descriptorsUnavailable = true;
      final camera = FujiCamera(transport)
        ..identity = CameraIdentity('X100VI', '9.99', 'test', {
          0xd18d,
          ...settings.map((s) => s.id),
        });
      await expectLater(
        camera.write(1, Recipe.fresh()),
        throwsA(isA<PtpResponseException>()),
      );
      expect(transport.written, isEmpty);
      expect(transport.selected, 4);
    },
  );
  FujiCamera create(CameraFixture transport) => FujiCamera(transport)
    ..identity = CameraIdentity(
      'X100VI',
      'test',
      'test',
      settings.map((s) => s.id).toSet(),
    );
  test(
    'writing and restoration preserve other slots and unknown properties',
    () async {
      final transport = CameraFixture(), recipe = Recipe.fresh();
      final camera = create(transport);
      final backup = (await camera.backup({1})).single;
      expect(transport.selected, 4);
      await camera.write(1, recipe);
      expect(Reader(transport.slots[1]![0xd18d]!).string(), 'My Recipe');
      expect(Reader(transport.slots[2]![0xd18d]!).string(), 'Original 2');
      expect(transport.written, isNot(contains(0xd1a5)));
      expect(transport.selected, 4);
      await camera.restore(backup);
      expect(Reader(transport.slots[1]![0xd18d]!).string(), 'Original 1');
      expect(transport.selected, 4);
    },
  );
  test('read-back mismatch fails and restores selected slot', () async {
    final transport = CameraFixture()..corrupt = true;
    await expectLater(
      create(transport).write(1, Recipe.fresh()),
      throwsStateError,
    );
    expect(transport.selected, 4);
  });
}
