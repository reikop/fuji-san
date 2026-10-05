import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuji_san/main.dart';
import 'package:fuji_san/camera/camera.dart';
import 'package:fuji_san/camera/ptp.dart';
import 'package:fuji_san/domain/recipe.dart';
import 'ui_test.dart' show MemoryStore;
import 'write_verify_test.dart' show CameraFixture;

class BackupStore extends MemoryStore {
  int backupsSaved = 0;
  @override
  Future<String> backup(
    CameraIdentity identity,
    List<Snapshot> snapshots,
  ) async {
    backupsSaved++;
    return 'memory-backup';
  }
}

List<int> u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();
List<int> array(List<int> values) => [
  ...u32(values.length),
  for (final value in values) ...u16(value),
];
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'slot tap edits current recipe and save returns to refreshed card; replacement is separate',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = CameraFixture();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NativeTransport.channel, (call) async {
        if (call.method == 'discover')
          return [
            {'id': 'wpd:test', 'name': 'X100VI'},
          ];
        if (call.method == 'connect') return {'managedSession': true};
        if (call.method == 'disconnect') return null;
        final args = call.arguments as Map;
        final packet = Packet.decode(args['command'] as Uint8List);
        Uint8List data;
        if (packet.code == 0x1001) {
          data = Uint8List.fromList([
            ...u16(100),
            ...u32(0),
            ...u16(100),
            ...ptpString(''),
            ...u16(0),
            ...array([0x1014, 0x1015, 0x1016]),
            ...array([]),
            ...array([0xd18c, 0xd18d, ...settings.map((s) => s.id)]),
            ...array([]),
            ...array([]),
            ...ptpString('FUJIFILM'),
            ...ptpString('X100VI'),
            ...ptpString('1.32'),
            ...ptpString('test'),
          ]);
        } else {
          data = await fixture.command(
            packet.code,
            params: [
              ByteData.sublistView(packet.payload).getUint32(0, Endian.little),
            ],
            outgoing: args['outgoing'] as Uint8List?,
          );
        }
        return {
          'data': data,
          'response': Packet(
            3,
            0x2001,
            packet.transaction,
            Uint8List(0),
          ).encode(),
        };
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(NativeTransport.channel, null),
      );
      final store = BackupStore();
      await tester.pumpWidget(FujiSanApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('카메라 연결'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('X100VI'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Original 1'));
      await tester.pumpAndSettle();
      expect(find.text('C1 레시피 편집'), findsOneWidget);
      expect(find.text('Original 1'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'New Name');
      await tester.tap(find.text('카메라에 저장'));
      await tester.pumpAndSettle();
      expect(find.text('C1 레시피 편집'), findsNothing);
      expect(find.text('New Name'), findsOneWidget);
      expect(store.backupsSaved, 1);
      expect(fixture.written, [0xd18d]);
      expect(fixture.selected, 4);
      await tester.tap(find.byTooltip('다른 레시피로 교체').first);
      await tester.pumpAndSettle();
      expect(find.text('C1에 배치'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
