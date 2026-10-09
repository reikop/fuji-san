import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuji_san/camera/camera.dart';
import 'package:fuji_san/camera/ptp.dart';
import 'package:fuji_san/camera_slot_editor.dart';
import 'package:fuji_san/domain/recipe.dart';
import 'write_verify_test.dart' show CameraFixture;

void main() {
  FujiCamera camera(CameraFixture transport) => FujiCamera(transport)
    ..identity = CameraIdentity('X100VI', '1.32', 'test', {
      0xd18d,
      ...settings.map((s) => s.id),
    });

  test(
    'edits only changed fields, preserving unknown values, other slots and selector',
    () async {
      final fixture = CameraFixture()..descriptorsUnavailable = true;
      fixture.slots[1]![0xd190] = u16(300);
      final cam = camera(fixture);
      final original = (await cam.backup({1})).single;
      var backedUp = false;
      await cam.editSlot(
        original,
        SlotEdit('Updated', {...original.values, 0xd19a: 3}),
        (snapshots) async {
          expect(fixture.written, isEmpty);
          expect(snapshots.single.properties[0xd190], u16(300));
          backedUp = true;
        },
      );
      expect(backedUp, true);
      expect(fixture.written, [0xd19a, 0xd18d]);
      expect(fixture.slots[1]![0xd190], u16(300));
      expect(fixture.slots[2]![0xd18d], ptpString('Original 2'));
      expect(fixture.selected, 4);
    },
  );
  test('backup failure prevents every recipe write', () async {
    final fixture = CameraFixture();
    final cam = camera(fixture);
    final original = (await cam.backup({2})).single;
    await expectLater(
      cam.editSlot(original, SlotEdit('Changed', original.values), (_) async {
        throw StateError('Disk full');
      }),
      throwsStateError,
    );
    expect(fixture.written, isEmpty);
  });
  test('camera changes during editing prevent stale writes', () async {
    final fixture = CameraFixture();
    final cam = camera(fixture);
    final original = (await cam.backup({2})).single;
    fixture.slots[2]![0xd192] = u16(20);
    await expectLater(
      cam.editSlot(original, SlotEdit('Changed', original.values), (_) async {
        fail('Must not persist stale edit');
      }),
      throwsStateError,
    );
    expect(fixture.written, isEmpty);
  });
  test(
    'no-op edit preserves blank names and never backs up or writes',
    () async {
      final fixture = CameraFixture();
      final cam = camera(fixture);
      fixture.slots[7]![0xd18d] = ptpString('');
      final original = (await cam.backup({7})).single;
      await cam.editSlot(
        original,
        SlotEdit('', original.values),
        (_) async => fail('No changes'),
      );
      expect(fixture.written, isEmpty);
    },
  );

  for (final size in [const Size(390, 844), const Size(1440, 1000)]) {
    testWidgets(
      'editor displays current values and retains edits after failed save at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = CameraFixture();
        fixture.slots[1]![0xd190] = u16(300);
        final snapshot = Snapshot(1, fixture.slots[1]!);
        SlotEdit? submitted;
        await tester.pumpWidget(
          MaterialApp(
            home: CameraSlotEditor(
              snapshot: snapshot,
              onSave: (edit) async {
                submitted = edit;
                throw StateError('연결 오류');
              },
            ),
          ),
        );
        expect(find.text('Original 1'), findsOneWidget);
        expect(find.text('Classic Chrome'), findsOneWidget);
        expect(find.text('현재 값 300 · 유지'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'New Name');
        await tester.tap(find.text('카메라에 저장'));
        await tester.pumpAndSettle();
        expect(find.text('오류 보고'), findsOneWidget);
        await tester.tap(find.text('닫기'));
        await tester.pumpAndSettle();
        expect(submitted!.name, 'New Name');
        expect(submitted!.values[0xd190], 300);
        expect(find.text('New Name'), findsOneWidget);
        expect(find.textContaining('연결 오류'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
