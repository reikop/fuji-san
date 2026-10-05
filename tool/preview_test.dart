// Local review only: flutter test tool/preview_test.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuji_san/domain/recipe.dart';
import 'package:fuji_san/main.dart';
import '../test/ui_test.dart' show MemoryStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final size in [const Size(390, 844), const Size(1440, 1000)]) {
    testWidgets('review $size', (tester) async {
      final font = File('C:/Windows/Fonts/malgun.ttf');
      if (font.existsSync()) {
        final loader = FontLoader('Roboto')
          ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
        await loader.load();
      }
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryStore();
      final base = Recipe.fresh();
      final recipes = [
        Recipe(
          id: 'a',
          name: '서울의 오후',
          cameraName: 'Seoul Afternoon',
          values: base.values,
        ),
        Recipe(
          id: 'b',
          name: '비 오는 골목',
          cameraName: 'Rainy Alley',
          values: {...base.values, 0xd192: 12},
        ),
        Recipe(
          id: 'c',
          name: '제주에서',
          cameraName: 'Jeju Days',
          values: {...base.values, 0xd192: 17},
        ),
      ];
      await store.save(recipes, {1: 'a', 2: 'b', 3: 'c'});
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: FujiSanApp(store: store),
        ),
      );
      await tester.pumpAndSettle();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await tester.runAsync(() async {
        await Directory('.tools').create(recursive: true);
        await File(
          '.tools/preview-${size.width.toInt()}.png',
        ).writeAsBytes(data!.buffer.asUint8List());
      });
      image.dispose();
    });
  }
}
