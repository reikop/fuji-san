import 'package:flutter/material.dart';

const _steps = 19; // -9…+9 on both axes.

// Mirrors the camera's WB shift screen: red grows to the right, blue grows upward.
class WbShiftGrid extends StatelessWidget {
  const WbShiftGrid({
    super.key,
    required this.red,
    required this.blue,
    required this.onChanged,
  });
  final int red, blue;
  final void Function(int red, int blue) onChanged;

  void _pick(Offset position, double size) {
    final cell = size / _steps;
    final r = ((position.dx / cell).floor() - 9).clamp(-9, 9);
    final b = (9 - (position.dy / cell).floor()).clamp(-9, 9);
    if (r != red || b != blue) onChanged(r, b);
  }

  Widget _stepper(
    String label,
    Color color,
    int value,
    void Function(int) set,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '$label 줄이기',
          visualDensity: VisualDensity.compact,
          color: Colors.white,
          disabledColor: Colors.white24,
          onPressed: value > -9 ? () => set(value - 1) : null,
          icon: const Icon(Icons.remove, size: 18),
        ),
        Icon(Icons.circle, size: 10, color: color),
        const SizedBox(width: 6),
        SizedBox(
          width: 44,
          child: Text(
            '$label: ${value > 0 ? '+' : ''}$value',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ),
        IconButton(
          tooltip: '$label 늘리기',
          visualDensity: VisualDensity.compact,
          color: Colors.white,
          disabledColor: Colors.white24,
          onPressed: value < 9 ? () => set(value + 1) : null,
          icon: const Icon(Icons.add, size: 18),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Icon(Icons.wb_sunny_outlined, size: 18),
          const SizedBox(width: 8),
          const Expanded(child: Text('WB Shift')),
          TextButton.icon(
            onPressed: red == 0 && blue == 0 ? null : () => onChanged(0, 0),
            icon: const Icon(Icons.filter_center_focus, size: 16),
            label: const Text('중앙으로'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 340),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
          decoration: BoxDecoration(
            color: const Color(0xff2b2b2b),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: LayoutBuilder(
                  builder: (context, c) => Semantics(
                    label: 'WB Shift R $red B $blue',
                    // Both drag axes are claimed so the surrounding list does
                    // not scroll while a point is being dragged on the grid.
                    child: GestureDetector(
                      key: const ValueKey('wb-shift-grid'),
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) => _pick(d.localPosition, c.maxWidth),
                      onHorizontalDragStart: (d) =>
                          _pick(d.localPosition, c.maxWidth),
                      onHorizontalDragUpdate: (d) =>
                          _pick(d.localPosition, c.maxWidth),
                      onVerticalDragStart: (d) =>
                          _pick(d.localPosition, c.maxWidth),
                      onVerticalDragUpdate: (d) =>
                          _pick(d.localPosition, c.maxWidth),
                      child: CustomPaint(painter: _GridPainter(red, blue)),
                    ),
                  ),
                ),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _stepper(
                      'R',
                      const Color(0xffff6b5e),
                      red,
                      (v) => onChanged(v, blue),
                    ),
                    const SizedBox(width: 8),
                    _stepper(
                      'B',
                      const Color(0xff5e9bff),
                      blue,
                      (v) => onChanged(red, v),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.red, this.blue);
  final int red, blue;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / _steps;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff4d4d4d),
    );
    final dot = Paint();
    for (var r = -9; r <= 9; r++) {
      for (var b = -9; b <= 9; b++) {
        dot.color = Color.fromARGB(
          255,
          (175 + r * 9).clamp(0, 255),
          (175 - (r + b) * 5).clamp(0, 255),
          (175 + b * 9).clamp(0, 255),
        );
        canvas.drawCircle(
          Offset((r + 9.5) * cell, (9.5 - b) * cell),
          cell * (r == 0 || b == 0 ? 0.2 : 0.15),
          dot,
        );
      }
    }
    final white = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final mid = size.width / 2, tick = cell * 0.45;
    canvas.drawLine(Offset(mid, 0), Offset(mid, tick), white);
    canvas.drawLine(
      Offset(mid, size.height),
      Offset(mid, size.height - tick),
      white,
    );
    canvas.drawLine(Offset(0, mid), Offset(tick, mid), white);
    canvas.drawLine(
      Offset(size.width, mid),
      Offset(size.width - tick, mid),
      white,
    );
    final selected = Offset((red + 9.5) * cell, (9.5 - blue) * cell);
    canvas.drawCircle(selected, cell * 0.22, Paint()..color = Colors.white);
    canvas.drawRect(
      Rect.fromCenter(
        center: selected,
        width: cell * 0.95,
        height: cell * 0.95,
      ),
      white,
    );
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.red != red || old.blue != blue;
}
