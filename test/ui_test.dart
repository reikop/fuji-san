import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuji_san/domain/recipe.dart';
import 'package:fuji_san/main.dart';
import 'package:fuji_san/storage.dart';

class MemoryStore extends LibraryStore {
  Map<String, dynamic>? data;
  @override
  Future<Map<String, dynamic>?> load() async => data;
  @override
  Future<void> save(List<Recipe> recipes, Map<int, String> slots) async {
    data = {
      'version': 1,
      'recipes': recipes.map((r) => r.toJson()).toList(),
      'slots': slots.map((k, v) => MapEntry('$k', v)),
    };
  }
}

void main() {
  for (final size in [const Size(390, 844), const Size(1440, 1000)]) {
    testWidgets('create, persist and assign recipe at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryStore();
      await tester.pumpWidget(FujiSanApp(store: store));
      await tester.pumpAndSettle();
      expect(find.text('첫 번째 레시피를 만들어보세요.'), findsOneWidget);
      await tester.tap(find.text('레시피 만들기'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Seoul Walk');
      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();
      expect(find.text('Seoul Walk'), findsOneWidget);
      if (size.width < 1000) {
        await tester.tap(find.text('C1–C7'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('레시피 배치').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Seoul Walk · Classic Chrome'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('1개 슬롯 일괄 적용'),
        200,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('camera-kit')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('1개 슬롯 일괄 적용'), findsOneWidget);
      expect((store.data!['recipes'] as List).single['name'], 'Seoul Walk');
      expect((store.data!['slots'] as Map).length, 1);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '1개 슬롯 일괄 적용'),
      );
      expect(
        button.onPressed,
        isNull,
      ); // No fake connection or successful transfer.
    });
  }
}
