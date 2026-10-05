import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuji_san/domain/recipe.dart';

void main() {
  test('recipe JSON round trip retains all settings', () {
    final recipe = Recipe.fresh();
    expect(
      importRecipes(exportRecipes([recipe])).single.toJson(),
      recipe.toJson(),
    );
  });
  test('unknown properties and out-of-range settings are rejected', () {
    final json = Recipe.fresh().toJson();
    (json['values'] as Map)['d1a5'] = 1;
    expect(() => Recipe.fromJson(json), throwsFormatException);
    (json['values'] as Map).remove('d1a5');
    (json['values'] as Map)['d19a'] = 10;
    expect(() => Recipe.fromJson(json), throwsFormatException);
  });
  test(
    'dependent properties are excluded without touching unknown camera settings',
    () {
      final base = Recipe.fresh();
      final r = Recipe(
        id: 'mono',
        name: 'mono',
        cameraName: 'Mono',
        values: {...base.values, 0xd192: 12, 0xd191: 1},
      );
      expect(r.writeValues.keys, containsAll([0xd193, 0xd194]));
      for (final id in [
        0xd190,
        0xd19d,
        0xd19e,
        0xd19f,
        0xd19c,
        0xd18e,
        0xd1a5,
      ]) {
        expect(r.writeValues.containsKey(id), false);
      }
      expect(r.values[0xd1a1], 8192); // NR zero is not wire zero.
    },
  );
  test('Kelvin follows WB mode and precedes WB shifts', () {
    final r = Recipe(
      id: 'k',
      name: 'k',
      cameraName: 'K',
      values: {...Recipe.fresh().values, 0xd199: 32775},
    );
    final keys = r.writeValues.keys.toList();
    expect(keys.indexOf(0xd199), lessThan(keys.indexOf(0xd19c)));
    expect(keys.indexOf(0xd19c), lessThan(keys.indexOf(0xd19a)));
  });
  test('invalid names and duplicate IDs are rejected', () {
    final r = Recipe.fresh();
    expect(
      () => Recipe(id: 'x', name: 'name', cameraName: '한글', values: r.values),
      throwsFormatException,
    );
    expect(() => importRecipes(exportRecipes([r, r])), throwsFormatException);
    expect(
      () => importRecipes(jsonEncode({'format': 'other', 'version': 1})),
      throwsFormatException,
    );
  });
  test(
    'Dynamic Range Auto uses the camera encoding and migrates old files',
    () {
      final dr = settings.firstWhere((s) => s.id == 0xd190);
      expect(dr.accepts(65535), true);
      expect(dr.accepts(0), false);
      final json = Recipe.fresh().toJson();
      (json['values'] as Map)['d190'] = 0;
      expect(Recipe.fromJson(json).values[0xd190], 65535);
    },
  );
}
