import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuji_san/builtin_recipes.dart';
import 'package:fuji_san/domain/recipe.dart';

void main() {
  final bundled = parseBuiltinRecipes(
    File('assets/builtin_recipes.json').readAsStringSync(),
  );
  test('every bundled recipe is valid and attributed', () {
    // Recipe's constructor already rejected any out-of-schema value.
    expect(bundled.length, greaterThan(400));
    for (final b in bundled) {
      expect(b.creator, isNotEmpty, reason: b.recipe.name);
      expect(b.url.scheme, startsWith('http'), reason: b.recipe.name);
      expect(b.url.host, isNotEmpty, reason: b.recipe.name);
    }
    expect(bundled.map((b) => b.recipe.id).toSet().length, bundled.length);
  });
  testWidgets('catalog searches, shows settings and adds to the library', (
    tester,
  ) async {
    final added = <Recipe>[];
    final target = bundled[7];
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltinCatalog(
          onAdd: (r) async => added.add(r),
          load: () async => bundled.take(40).toList(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), target.recipe.name);
    await tester.pumpAndSettle();
    await tester.tap(find.text(target.recipe.name).last);
    await tester.pumpAndSettle();
    expect(find.text('원문 보기'), findsOneWidget);
    expect(find.text('필름 시뮬레이션'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '라이브러리에 추가'));
    await tester.pumpAndSettle();
    expect(added.single.name, target.recipe.name);
    expect(added.single.values, target.recipe.values);
    expect(tester.takeException(), isNull);
  });
}
