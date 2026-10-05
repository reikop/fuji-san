import 'dart:convert';

class Setting {
  const Setting(
    this.id,
    this.label,
    this.initial, {
    this.options,
    this.min,
    this.max,
    this.step = 1,
    this.signed = false,
    this.scale = 1,
  });
  final int id;
  final String label;
  final int initial;
  final Map<int, String>? options;
  final int? min, max;
  final int step, scale;
  final bool signed;
  bool accepts(int value) => options != null
      ? options!.containsKey(value)
      : value >= min! && value <= max! && (value - min!) % step == 0;
  String display(int value) =>
      options?[value] ?? (scale == 1 ? '$value' : '${value / scale}');
}

const filmNames = <int, String>{
  1: 'PROVIA',
  2: 'Velvia',
  3: 'ASTIA',
  4: 'PRO Neg. Hi',
  5: 'PRO Neg. Std',
  6: 'Monochrome',
  7: 'Monochrome + Y',
  8: 'Monochrome + R',
  9: 'Monochrome + G',
  10: 'Sepia',
  11: 'Classic Chrome',
  12: 'ACROS',
  13: 'ACROS + Y',
  14: 'ACROS + R',
  15: 'ACROS + G',
  16: 'ETERNA',
  17: 'Classic Neg.',
  18: 'ETERNA Bleach Bypass',
  19: 'Nostalgic Neg.',
  20: 'REALA ACE',
};
const monoFilms = {6, 7, 8, 9, 10, 12, 13, 14, 15};
const effects = {1: 'Off', 2: 'Weak', 3: 'Strong'};
const settings = <Setting>[
  Setting(0xd192, '필름 시뮬레이션', 11, options: filmNames),
  Setting(
    0xd191,
    '다이내믹 레인지 우선',
    0,
    options: {0: 'Off', 1: 'Weak', 2: 'Strong', 32768: 'Auto'},
  ),
  Setting(
    0xd190,
    '다이내믹 레인지',
    100,
    options: {0: 'Auto', 100: 'DR100', 200: 'DR200', 400: 'DR400'},
  ),
  Setting(
    0xd193,
    '모노크롬 W/C',
    0,
    min: -180,
    max: 180,
    step: 10,
    signed: true,
    scale: 10,
  ),
  Setting(
    0xd194,
    '모노크롬 M/G',
    0,
    min: -180,
    max: 180,
    step: 10,
    signed: true,
    scale: 10,
  ),
  Setting(
    0xd195,
    '그레인 효과',
    1,
    options: {
      1: 'Off',
      2: 'Weak / Small',
      3: 'Strong / Small',
      4: 'Weak / Large',
      5: 'Strong / Large',
    },
  ),
  Setting(0xd196, '컬러 크롬', 1, options: effects),
  Setting(0xd197, '컬러 크롬 FX Blue', 1, options: effects),
  Setting(0xd198, '피부 보정', 1, options: effects),
  Setting(
    0xd199,
    '화이트 밸런스',
    2,
    options: {
      2: 'Auto',
      32800: 'White Priority',
      32801: 'Ambience Priority',
      4: 'Daylight',
      6: 'Incandescent',
      8: 'Underwater',
      32769: 'Fluorescent 1',
      32770: 'Fluorescent 2',
      32771: 'Fluorescent 3',
      32774: 'Shade',
      32775: 'Kelvin',
      32776: 'Custom 1',
      32777: 'Custom 2',
      32778: 'Custom 3',
    },
  ),
  Setting(0xd19c, '색온도', 5600, min: 2500, max: 10000, step: 10),
  Setting(0xd19a, 'WB Shift · Red', 0, min: -9, max: 9, signed: true),
  Setting(0xd19b, 'WB Shift · Blue', 0, min: -9, max: 9, signed: true),
  Setting(
    0xd19d,
    '하이라이트',
    0,
    min: -20,
    max: 40,
    step: 5,
    signed: true,
    scale: 10,
  ),
  Setting(0xd19e, '섀도', 0, min: -20, max: 40, step: 5, signed: true, scale: 10),
  Setting(
    0xd19f,
    '색농도',
    0,
    min: -40,
    max: 40,
    step: 10,
    signed: true,
    scale: 10,
  ),
  Setting(
    0xd1a0,
    '샤프니스',
    0,
    min: -40,
    max: 40,
    step: 10,
    signed: true,
    scale: 10,
  ),
  Setting(
    0xd1a1,
    '고감도 노이즈 감소',
    8192,
    options: {
      32768: '-4',
      28672: '-3',
      16384: '-2',
      12288: '-1',
      8192: '0',
      4096: '+1',
      0: '+2',
      24576: '+3',
      20480: '+4',
    },
  ),
  Setting(
    0xd1a2,
    '클래리티',
    0,
    min: -50,
    max: 50,
    step: 10,
    signed: true,
    scale: 10,
  ),
];

bool applicable(int id, Map<int, int> values) {
  final mono = monoFilms.contains(values[0xd192]);
  if (id == 0xd193 || id == 0xd194) return mono;
  if (id == 0xd19f) return !mono;
  if (id == 0xd19c) return values[0xd199] == 32775;
  if ({0xd190, 0xd19d, 0xd19e}.contains(id)) return values[0xd191] == 0;
  return true;
}

class Recipe {
  Recipe({
    required this.id,
    required this.name,
    required this.cameraName,
    required Map<int, int> values,
  }) : values = Map.unmodifiable(values) {
    if (id.isEmpty ||
        id.length > 100 ||
        name.trim().isEmpty ||
        name.length > 120) {
      throw const FormatException('레시피 이름 또는 ID가 잘못되었습니다.');
    }
    if (!RegExp(r'^[A-Za-z0-9 _.,+()\-]{1,25}$').hasMatch(cameraName)) {
      throw const FormatException('카메라 이름은 영문·숫자·공백·_.,+()- 1~25자입니다.');
    }
    if (values.length != settings.length ||
        settings.any(
          (s) => !values.containsKey(s.id) || !s.accepts(values[s.id]!),
        )) {
      throw const FormatException('레시피 설정값이 유효하지 않습니다.');
    }
  }
  final String id, name, cameraName;
  final Map<int, int> values;
  String get film => filmNames[values[0xd192]]!;
  Map<int, int> get writeValues => Map.fromEntries(
    settings
        .where((s) => applicable(s.id, values))
        .map((s) => MapEntry(s.id, values[s.id]!)),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'cameraName': cameraName,
    'values': values.map((k, v) => MapEntry(k.toRadixString(16), v)),
  };
  factory Recipe.fromJson(Map<String, dynamic> json) => Recipe(
    id: json['id'] as String,
    name: json['name'] as String,
    cameraName: json['cameraName'] as String,
    values: (json['values'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(int.parse(k, radix: 16), v as int),
    ),
  );
  static Recipe fresh() => Recipe(
    id: DateTime.now().microsecondsSinceEpoch.toString(),
    name: '새 레시피',
    cameraName: 'My Recipe',
    values: {for (final s in settings) s.id: s.initial},
  );
}

String exportRecipes(List<Recipe> recipes) =>
    const JsonEncoder.withIndent('  ').convert({
      'format': 'fuji-san',
      'version': 1,
      'recipes': recipes.map((r) => r.toJson()).toList(),
    });
List<Recipe> importRecipes(String source) {
  if (source.length > 2000000) throw const FormatException('파일은 2MB 이하여야 합니다.');
  final json = jsonDecode(source) as Map<String, dynamic>;
  if (json['format'] != 'fuji-san' || json['version'] != 1) {
    throw const FormatException('Fuji San v1 JSON 파일이 아닙니다.');
  }
  final list = json['recipes'] as List;
  if (list.length > 500) throw const FormatException('한 번에 500개까지 가져올 수 있습니다.');
  final result = list
      .map((j) => Recipe.fromJson(j as Map<String, dynamic>))
      .toList();
  if (result.map((r) => r.id).toSet().length != result.length) {
    throw const FormatException('중복 레시피 ID가 있습니다.');
  }
  return result;
}
