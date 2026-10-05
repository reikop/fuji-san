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
  testWidgets('film tabs, tag filters and sorting narrow and order the list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltinCatalog(onAdd: (_) async {}, load: () async => bundled),
      ),
    );
    await tester.pumpAndSettle();
    bool wanted(BuiltinRecipe b) =>
        b.recipe.values[0xd192] == 11 &&
        b.recipe.values[0xd191] == 0 &&
        b.recipe.values[0xd190] == 200 &&
        b.recipe.values[0xd196] == 3;
    final expected = bundled.where(wanted).toList()
      ..sort((a, b) {
        final c = b.recipe.values[0xd19d]!.compareTo(a.recipe.values[0xd19d]!);
        return c != 0
            ? c
            : a.recipe.name.toLowerCase().compareTo(
                b.recipe.name.toLowerCase(),
              );
      });
    expect(expected.length, greaterThan(3));
    final tab = find.textContaining(RegExp(r'^Classic Chrome \d+$'));
    await tester.ensureVisible(tab);
    await tester.pumpAndSettle();
    await tester.tap(tab);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'DR200'));
    await tester.tap(find.widgetWithText(FilterChip, 'CC Strong'));
    await tester.pumpAndSettle();
    expect(find.textContaining('${expected.length}개 ·'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('builtin-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('하이라이트').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('오름차순'));
    await tester.pumpAndSettle();
    final titles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => (t.title! as Text).data)
        .toList();
    expect(titles.take(4), expected.take(4).map((b) => b.recipe.name));
    expect(tester.takeException(), isNull);
  });
}
