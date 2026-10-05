import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'domain/recipe.dart';

// A published recipe bundled with the app (assets/builtin_recipes.json, built by
// tool/build_builtin_recipes.py). It only enters the library when the user adds it.
class BuiltinRecipe {
  BuiltinRecipe(this.recipe, this.creator, this.camera, this.sensor, this.url);
  final Recipe recipe;
  final String creator, camera, sensor;
  final Uri url;
}

List<BuiltinRecipe> parseBuiltinRecipes(String source) {
  final json = jsonDecode(source) as Map<String, dynamic>;
  if (json['format'] != 'fuji-san-builtin' || json['version'] != 1) {
    throw const FormatException('내장 레시피 파일 형식이 아닙니다.');
  }
  final list = (json['recipes'] as List).cast<Map<String, dynamic>>();
  return [
    for (var i = 0; i < list.length; i++)
      BuiltinRecipe(
        Recipe.fromJson({...list[i], 'id': 'builtin-$i'}),
        list[i]['creator'] as String,
        list[i]['camera'] as String,
        list[i]['sensor'] as String,
        Uri.parse(list[i]['url'] as String),
      ),
  ];
}

Future<List<BuiltinRecipe>> loadBuiltinRecipes() async => parseBuiltinRecipes(
  await rootBundle.loadString('assets/builtin_recipes.json'),
);

class BuiltinCatalog extends StatefulWidget {
  const BuiltinCatalog({super.key, required this.onAdd, this.load});
  final Future<void> Function(Recipe recipe) onAdd;
  final Future<List<BuiltinRecipe>> Function()? load;
  @override
  State<BuiltinCatalog> createState() => _BuiltinCatalogState();
}

class _BuiltinCatalogState extends State<BuiltinCatalog> {
  late final Future<List<BuiltinRecipe>> items =
      (widget.load ?? loadBuiltinRecipes)();
  final added = <String>{};
  String query = '';
  int? film;
  final dr = <int>{}, cc = <int>{}, fx = <int>{};
  int sort = 0;
  bool descending = false;

  void notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> add(BuiltinRecipe item) async {
    try {
      await widget.onAdd(item.recipe);
      if (mounted) setState(() => added.add(item.recipe.id));
      notify('${item.recipe.name} 라이브러리에 추가됨');
    } catch (e) {
      notify('추가하지 못했습니다: $e');
    }
  }

  Future<void> details(BuiltinRecipe item) async {
    final values = item.recipe.values;
    final wanted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item.recipe.name),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${item.creator} · ${item.camera} (${item.sensor})',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                for (final s in settings)
                  if (applicable(s.id, values))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Expanded(child: Text(s.label)),
                          Text(
                            s.display(values[s.id]!),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                const SizedBox(height: 12),
                Text(
                  item.sensor.startsWith('X-Trans V')
                      ? '공개된 설정값을 그대로 옮겼습니다. 노출 보정·ISO 권장값과 작례는 원문에서 확인하세요.'
                      : '${item.sensor} 카메라용으로 공개된 설정값을 그대로 옮겼습니다. X100VI에서는 결과가 다를 수 있습니다. 노출 보정·ISO 권장값과 작례는 원문에서 확인하세요.',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              if (!await launchUrl(
                item.url,
                mode: LaunchMode.externalApplication,
              )) {
                notify('원문을 열 수 없습니다: ${item.url}');
              }
            },
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('원문 보기'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('라이브러리에 추가'),
          ),
        ],
      ),
    );
    if (wanted == true) await add(item);
  }

  // Filter variants (ACROS + Y, Monochrome + R…) share their base film's tab.
  static int group(int film) => film >= 12 && film <= 15
      ? 12
      : film >= 6 && film <= 9
      ? 6
      : film;
  static const sorts = <int, String>{
    0: '이름',
    0xd19d: '하이라이트',
    0xd19e: '섀도',
    0xd19f: '색농도',
    0xd1a0: '샤프니스',
    0xd1a2: '클래리티',
    0xd19a: 'WB Shift Red',
    0xd19b: 'WB Shift Blue',
  };
  // -1 stands for "D-Range priority on", where the DR value does not apply.
  static int drKey(Map<int, int> v) => v[0xd191] != 0 ? -1 : v[0xd190]!;
  static String drLabel(int key) => key < 0
      ? 'DR 우선'
      : key == 0
      ? 'DR Auto'
      : 'DR$key';

  static String signed(int id, Map<int, int> v) {
    final setting = settings.firstWhere((s) => s.id == id);
    final n = v[id]! / setting.scale;
    final text = n == n.roundToDouble() ? '${n.toInt()}' : '$n';
    return n > 0 ? '+$text' : text;
  }

  static String summary(Map<int, int> v) {
    final wb = settings.firstWhere((s) => s.id == 0xd199);
    return [
      drLabel(drKey(v)),
      if (applicable(0xd19d, v)) 'H ${signed(0xd19d, v)}',
      if (applicable(0xd19e, v)) 'S ${signed(0xd19e, v)}',
      if (applicable(0xd19f, v)) 'Color ${signed(0xd19f, v)}',
      'Sharp ${signed(0xd1a0, v)}',
      'Clarity ${signed(0xd1a2, v)}',
      'CC ${effects[v[0xd196]]}',
      'FX Blue ${effects[v[0xd197]]}',
      'WB ${v[0xd199] == 32775 ? '${v[0xd19c]}K' : wb.display(v[0xd199]!)} '
          'R${signed(0xd19a, v)} B${signed(0xd19b, v)}',
    ].join(' · ');
  }

  bool matches(BuiltinRecipe b, {bool tab = true}) {
    final v = b.recipe.values;
    return (!tab || film == null || group(v[0xd192]!) == film) &&
        (dr.isEmpty || dr.contains(drKey(v))) &&
        (cc.isEmpty || cc.contains(v[0xd196])) &&
        (fx.isEmpty || fx.contains(v[0xd197])) &&
        '${b.recipe.name} ${b.recipe.film} ${b.creator}'.toLowerCase().contains(
          query.toLowerCase(),
        );
  }

  int compare(BuiltinRecipe a, BuiltinRecipe b) {
    final byName = a.recipe.name.toLowerCase().compareTo(
      b.recipe.name.toLowerCase(),
    );
    if (sort == 0) return descending ? -byName : byName;
    // Recipes where the setting does not apply stay at the end either way.
    final x = applicable(sort, a.recipe.values) ? a.recipe.values[sort] : null;
    final y = applicable(sort, b.recipe.values) ? b.recipe.values[sort] : null;
    if (x == null || y == null) {
      return x == y
          ? byName
          : x == null
          ? 1
          : -1;
    }
    final byValue = descending ? y.compareTo(x) : x.compareTo(y);
    return byValue != 0 ? byValue : byName;
  }

  Widget tags(
    String title,
    Set<int> selected,
    List<int> options,
    String Function(int) label,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            title,
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ),
        for (final option in options)
          FilterChip(
            label: Text(label(option)),
            labelStyle: const TextStyle(fontSize: 12),
            visualDensity: VisualDensity.compact,
            selected: selected.contains(option),
            onSelected: (on) => setState(
              () => on ? selected.add(option) : selected.remove(option),
            ),
          ),
      ],
    ),
  );

  Widget controls(List<BuiltinRecipe> all, int shown) {
    List<int> present(int Function(Map<int, int>) key) =>
        (all.map((b) => key(b.recipe.values)).toSet().toList()..sort());
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          tags('DR', dr, present(drKey), drLabel),
          tags(
            '컬러 크롬',
            cc,
            present((v) => v[0xd196]!),
            (o) => 'CC ${effects[o]}',
          ),
          tags(
            'FX Blue',
            fx,
            present((v) => v[0xd197]!),
            (o) => 'FX Blue ${effects[o]}',
          ),
          Row(
            children: [
              const SizedBox(
                width: 70,
                child: Text(
                  '정렬',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
              DropdownButton<int>(
                key: const ValueKey('builtin-sort'),
                value: sort,
                isDense: true,
                items: [
                  for (final e in sorts.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => sort = v!),
              ),
              IconButton(
                tooltip: descending ? '내림차순' : '오름차순',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  descending ? Icons.arrow_downward : Icons.arrow_upward,
                  size: 18,
                ),
                onPressed: () => setState(() => descending = !descending),
              ),
              const Spacer(),
              if (dr.isNotEmpty || cc.isNotEmpty || fx.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() {
                    dr.clear();
                    cc.clear();
                    fx.clear();
                  }),
                  child: const Text('필터 지우기'),
                ),
            ],
          ),
          Text(
            '$shown개 · 제작자가 공개한 레시피입니다. 눌러서 설정과 원문을 확인하고 라이브러리에 추가하세요. '
            '목록 출처: Fujifilm Film Simulation Recipes Database (Henri-Pierre Chavaz)',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<BuiltinRecipe>>(
    future: items,
    builder: (context, snapshot) {
      if (!snapshot.hasData) {
        return Scaffold(
          appBar: AppBar(title: const Text('내장 레시피')),
          body: Center(
            child: snapshot.hasError
                ? Text('내장 레시피를 읽지 못했습니다: ${snapshot.error}')
                : const CircularProgressIndicator(),
          ),
        );
      }
      final all = snapshot.data!;
      // Tab counts follow the search and tag filters, not the selected tab.
      final counts = <int, int>{};
      for (final b in all.where((b) => matches(b, tab: false))) {
        final g = group(b.recipe.values[0xd192]!);
        counts[g] = (counts[g] ?? 0) + 1;
      }
      final films = [
        for (final id in filmNames.keys)
          if (all.any((b) => group(b.recipe.values[0xd192]!) == id)) id,
      ];
      final shown = all.where(matches).toList()..sort(compare);
      return DefaultTabController(
        length: films.length + 1,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('내장 레시피'),
            bottom: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              onTap: (i) => setState(() => film = i == 0 ? null : films[i - 1]),
              tabs: [
                Tab(text: '전체 ${counts.values.fold(0, (a, b) => a + b)}'),
                for (final id in films)
                  Tab(text: '${filmNames[id]} ${counts[id] ?? 0}'),
              ],
            ),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                    child: TextField(
                      onChanged: (v) => setState(() => query = v),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: '이름, 필름 시뮬레이션 또는 제작자 검색',
                        isDense: true,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                      itemCount: shown.length + 1,
                      itemBuilder: (context, i) {
                        if (i == 0) return controls(all, shown.length);
                        final item = shown[i - 1];
                        final done = added.contains(item.recipe.id);
                        return ListTile(
                          onTap: () => details(item),
                          title: Text(item.recipe.name),
                          subtitle: Text(
                            '${item.recipe.film} · ${item.creator} · ${item.camera}\n'
                            '${summary(item.recipe.values)}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          isThreeLine: true,
                          trailing: IconButton(
                            tooltip: done ? '한 번 더 추가' : '라이브러리에 추가',
                            icon: Icon(done ? Icons.check : Icons.add),
                            onPressed: () => add(item),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
