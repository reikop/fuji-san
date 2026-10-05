import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuji_san/camera/camera.dart';
import 'package:fuji_san/camera/ptp.dart';
import 'package:fuji_san/domain/recipe.dart';

class FakeCamera implements RecipeCamera {
  final events = <String>[];
  int? failAt;
  bool incomplete = false;
  @override
  Future<List<Snapshot>> backup(Set<int> slots) async {
    events.add('backup');
    return incomplete ? [] : slots.map((s) => Snapshot(s, {})).toList();
  }

  @override
  Future<void> write(int slot, Recipe recipe) async {
    events.add('write$slot');
    if (slot == failAt) throw StateError('unplugged');
  }

  @override
  Future<void> restore(Snapshot snapshot) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'batch persists backup before first write and stops after failure',
    () async {
      final c = FakeCamera()..failAt = 2;
      await expectLater(
        BatchWriter(c).apply(
          {3: Recipe.fresh(), 2: Recipe.fresh(), 1: Recipe.fresh()},
          (_) async {
            c.events.add('persist');
          },
          (_) {},
        ),
        throwsStateError,
      );
      expect(c.events, ['backup', 'persist', 'write1', 'write2']);
    },
  );
  test('failed durable backup prevents all writes', () async {
    final c = FakeCamera();
    await expectLater(
      BatchWriter(c).apply({1: Recipe.fresh()}, (_) async {
        throw StateError('disk full');
      }, (_) {}),
      throwsStateError,
    );
    expect(c.events, ['backup']);
  });
  test('incomplete backup prevents all writes', () async {
    final c = FakeCamera()..incomplete = true;
    await expectLater(
      BatchWriter(c).apply({1: Recipe.fresh()}, (_) async {}, (_) {}),
      throwsStateError,
    );
    expect(c.events, ['backup']);
  });
  test('PTP framing and signed values use little endian', () {
    final p = Packet(2, 0x1016, 7, u16(-40));
    final decoded = Packet.decode(p.encode());
    expect(decoded.code, 0x1016);
    expect(decoded.transaction, 7);
    expect(decoded.payload, [0xd8, 0xff]);
    expect(Reader(ptpString('C1')).string(), 'C1');
    expect(() => Packet.decode(Uint8List(3)), throwsFormatException);
  });
  test('bulk transport handles fragmented and coalesced containers', () async {
    final chunks = <Uint8List>[];
    final binding =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    binding.setMockMethodCallHandler(NativeTransport.channel, (
      MethodCall call,
    ) async {
      if (call.method == 'connect') return {'managedSession': false};
      if (call.method == 'write') {
        final p = Packet.decode(call.arguments as Uint8List);
        if (p.type == 1) {
          final response = Packet(
            3,
            0x2001,
            p.transaction,
            Uint8List(0),
          ).encode();
          if (p.code == 0x1015) {
            final all = Uint8List.fromList([
              ...Packet(2, p.code, p.transaction, u16(123)).encode(),
              ...response,
            ]);
            chunks.add(Uint8List.sublistView(all, 0, 3));
            chunks.add(Uint8List.sublistView(all, 3));
          } else {
            chunks.add(response);
          }
        }
      }
      if (call.method == 'read') return chunks.removeAt(0);
      return null;
    });
    final t = NativeTransport();
    await t.open('camera');
    expect(await t.command(0x1015, params: [0xd190]), u16(123));
    await t.close();
    binding.setMockMethodCallHandler(NativeTransport.channel, null);
  });
}
