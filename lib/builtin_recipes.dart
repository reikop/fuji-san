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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('내장 레시피')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: FutureBuilder<List<BuiltinRecipe>>(
          future: items,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(child: Text('내장 레시피를 읽지 못했습니다: ${snapshot.error}'));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final all = snapshot.data!;
            final q = query.toLowerCase();
            final shown = all
                .where(
                  (b) => '${b.recipe.name} ${b.recipe.film} ${b.creator}'
                      .toLowerCase()
                      .contains(q),
                )
                .toList();
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                  child: TextField(
                    onChanged: (v) => setState(() => query = v),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '이름, 필름 시뮬레이션 또는 제작자 검색',
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    '${shown.length} / ${all.length}개 · 제작자가 공개한 레시피입니다. 눌러서 설정과 원문을 확인하고 라이브러리에 추가하세요. '
                    '목록 출처: Fujifilm Film Simulation Recipes Database (Henri-Pierre Chavaz)',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final item = shown[i];
                      final done = added.contains(item.recipe.id);
                      return ListTile(
                        onTap: () => details(item),
                        title: Text(item.recipe.name),
                        subtitle: Text(
                          '${item.recipe.film} · ${item.creator} · ${item.camera}',
                          style: const TextStyle(fontSize: 12),
                        ),
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
            );
          },
        ),
      ),
    ),
  );
}
