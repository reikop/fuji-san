import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuji_san/storage.dart';
import 'package:fuji_san/domain/recipe.dart';
import 'package:fuji_san/camera/camera.dart';

class DiskStore extends LibraryStore {
  DiskStore(this.root);
  final Directory root;
  @override
  Future<Directory> get directory async => root;
}

void main() {
  test('library replacement and backup survive reopening', () async {
    final dir = await Directory.systemTemp.createTemp('fuji-san-storage-');
    try {
      final store = DiskStore(dir), recipe = Recipe.fresh();
      await store.save([recipe], {1: recipe.id});
      await store.save([recipe], {7: recipe.id});
      final reopened = DiskStore(dir);
      expect((await reopened.load())!['slots'], {'7': recipe.id});
      final path = await store.backup(
        CameraIdentity('X100VI', 'test', 'test-serial', {}),
        [Snapshot(7, {})],
      );
      expect((await reopened.backups()).single.uri, File(path).uri);
      expect(await File(path).readAsString(), contains('test-serial'));
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
