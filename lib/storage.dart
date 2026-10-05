import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'domain/recipe.dart';
import 'camera/camera.dart';

class LibraryStore {
  Future<Directory> get directory async {
    final dir = Directory(
      '${(await getApplicationSupportDirectory()).path}/fuji-san',
    );
    await dir.create(recursive: true);
    return dir;
  }

  Future<Map<String, dynamic>?> load() async {
    final file = File('${(await directory).path}/library.json');
    return await file.exists()
        ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
        : null;
  }

  Future<void> save(List<Recipe> recipes, Map<int, String> slots) async {
    final dir = await directory;
    final file = File('${dir.path}/library.json.tmp');
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'recipes': recipes.map((r) => r.toJson()).toList(),
        'slots': slots.map((k, v) => MapEntry('$k', v)),
      }),
      flush: true,
    );
    await file.rename('${dir.path}/library.json');
  }

  Future<String> backup(
    CameraIdentity identity,
    List<Snapshot> snapshots,
  ) async {
    final path =
        '${(await directory).path}/backup-${DateTime.now().microsecondsSinceEpoch}.json';
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'format': 'fuji-san-backup',
        'version': 1,
        'created': DateTime.now().toUtc().toIso8601String(),
        'model': identity.model,
        'firmware': identity.firmware,
        'serial': identity.serial,
        'slots': snapshots.map((s) => s.toJson()).toList(),
      }),
      flush: true,
    );
    return path;
  }

  Future<List<File>> backups() async =>
      (await (await directory)
            .list()
            .where(
              (f) =>
                  f is File &&
                  f.path
                      .split(Platform.pathSeparator)
                      .last
                      .startsWith('backup-') &&
                  f.path.endsWith('.json'),
            )
            .cast<File>()
            .toList())
        ..sort((a, b) => b.path.compareTo(a.path));
}
