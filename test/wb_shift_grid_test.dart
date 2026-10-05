import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuji_san/wb_shift_grid.dart';

void main() {
  testWidgets('grid maps right to red, up to blue, and steps one at a time', (
    tester,
  ) async {
    var red = 0, blue = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => WbShiftGrid(
              red: red,
              blue: blue,
              onChanged: (r, b) => setState(() {
                red = r;
                blue = b;
              }),
            ),
          ),
        ),
      ),
    );
    final grid = tester.getRect(find.byKey(const ValueKey('wb-shift-grid')));
    final cell = grid.width / 19;
    await tester.tapAt(grid.topRight + Offset(-cell / 2, cell / 2));
    await tester.pump();
    expect((red, blue), (9, 9));
    await tester.tapAt(grid.bottomLeft + Offset(cell * 3.5, -cell * 1.5));
    await tester.pump();
    expect((red, blue), (-6, -8));
    await tester.dragFrom(grid.center, Offset(cell * 2, -cell * 4));
    await tester.pump();
    expect((red, blue), (2, 4));
    await tester.tap(find.byTooltip('R 늘리기'));
    await tester.pump();
    await tester.tap(find.byTooltip('B 줄이기'));
    await tester.pump();
    expect((red, blue), (3, 3));
    await tester.tap(find.text('중앙으로'));
    await tester.pump();
    expect((red, blue), (0, 0));
    expect(find.text('R: 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
