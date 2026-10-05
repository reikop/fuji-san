import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuji_san/domain/recipe.dart';
import 'package:fuji_san/main.dart';
import 'ui_test.dart' show MemoryStore;

void main() {
  testWidgets('dragging a recipe card onto another reorders and persists', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryStore();
    final base = Recipe.fresh();
    await store.save([
      for (final name in ['Alpha', 'Beta', 'Gamma'])
        Recipe(
          id: name,
          name: name,
          cameraName: 'My Recipe',
          values: base.values,
        ),
    ], {});
    List<String> order() => [
      for (final r in store.data!['recipes'] as List) r['id'] as String,
    ];
    await tester.pumpWidget(FujiSanApp(store: store));
    await tester.pumpAndSettle();
    final target = tester.getCenter(find.text('Gamma'));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Alpha')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(target - const Offset(0, 20));
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(order(), ['Beta', 'Gamma', 'Alpha']);
    expect(tester.takeException(), isNull);

    // Editing keeps the recipe where the user placed it.
    await tester.tap(find.text('Gamma'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(order(), ['Beta', 'Gamma', 'Alpha']);
  });
}
