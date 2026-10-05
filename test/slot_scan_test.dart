import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuji_san/camera/camera.dart';
import 'package:fuji_san/camera/ptp.dart';
import 'package:fuji_san/domain/recipe.dart';
import 'write_verify_test.dart' show CameraFixture;

class FailingScan extends CameraFixture {
  @override
  Future<Uint8List> command(
    int code, {
    List<int> params = const [],
    Uint8List? outgoing,
  }) {
    if (code == 0x1015 && params.first == 0xd192 && selected == 3) {
      throw StateError('Simulated read failure');
    }
    return super.command(code, params: params, outgoing: outgoing);
  }
}

void main() {
  FujiCamera camera(CameraFixture transport) => FujiCamera(transport)
    ..identity = CameraIdentity(
      'X100VI',
      '1.32',
      'test',
      settings.map((s) => s.id).toSet(),
    );

  test(
    'scan reads all seven distinct recipes without recipe writes and restores selected slot',
    () async {
      final fixture = CameraFixture();
      fixture.slots[2]![0xd18d] = ptpString('나의 레시피');
      fixture.slots[2]![0xd195] = u16(6);
      fixture.slots[2]![0xd1a2] = u16(-20);
      final snapshots = await camera(fixture).backup({7, 6, 5, 4, 3, 2, 1});
      expect(snapshots.map((s) => s.slot), [1, 2, 3, 4, 5, 6, 7]);
      expect(snapshots[1].name, '나의 레시피');
      expect(snapshots[1].values[0xd195], 1);
      expect(snapshots[1].values[0xd1a2], -20);
      expect(snapshots[1].film, 'Classic Chrome');
      expect(fixture.selected, 4);
      expect(fixture.written, isEmpty);
    },
  );
  test(
    'read failure restores original slot and returns no partial snapshot list',
    () async {
      final fixture = FailingScan();
      await expectLater(
        camera(fixture).backup({1, 2, 3, 4, 5, 6, 7}),
        throwsStateError,
      );
      expect(fixture.selected, 4);
      expect(fixture.written, isEmpty);
    },
  );
}
