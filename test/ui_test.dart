import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuji_san/main.dart';

class TestPaths extends PathProviderPlatform {
  TestPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fuji-san-test-');
    PathProviderPlatform.instance = TestPaths(temp.path);
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  for (final size in [const Size(390, 844), const Size(1440, 1000)]) {
    testWidgets('library, editing and slot assignment at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const FujiSanApp());
      // Allow the real temporary-directory IO to finish.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('첫 번째 레시피를 만들어보세요.'), findsOneWidget);
      await tester.tap(find.text('레시피 만들기'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Seoul Walk');
      await tester.tap(find.text('저장'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('Seoul Walk'), findsOneWidget);
      if (size.width < 1000) {
        await tester.tap(find.text('C1–C7'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('레시피 배치').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Seoul Walk · Classic Chrome'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('1개 슬롯 일괄 적용'), findsOneWidget);
    });
  }
}
