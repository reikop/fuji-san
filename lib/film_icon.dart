import 'package:flutter/material.dart';

// Main letters on the canister and an optional small letter on the film tail,
// following the labels the camera uses for each film simulation.
const _labels = <int, (String, String)>{
  1: ('STD', ''),
  2: ('V', ''),
  3: ('S', ''),
  4: ('N', 'H'),
  5: ('N', 'S'),
  6: ('B', ''),
  7: ('B', 'Y'),
  8: ('B', 'R'),
  9: ('B', 'G'),
  10: ('SEPIA', ''),
  11: ('C', 'C'),
  12: ('A', ''),
  13: ('A', 'Y'),
  14: ('A', 'R'),
  15: ('A', 'G'),
  16: ('E', ''),
  17: ('N', 'C'),
  18: ('E', 'B'),
  19: ('N', 'N'),
  20: ('R', 'A'),
};
const _filters = {
  'Y': Color(0xffffd84d),
  'R': Color(0xffff7a6b),
  'G': Color(0xff7fd98a),
};

// A film canister with a strip of film, drawn in the style of the camera's film
// simulation menu icons. Drawn in code so every simulation has a crisp icon.
class FilmIcon extends StatelessWidget {
  const FilmIcon(
    this.film, {
    super.key,
    this.size = 20,
    this.color = const Color(0xff222b27),
  });
  final int film;
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: size * 1.3,
    height: size,
    child: CustomPaint(
      painter: _FilmPainter(
        _labels[film],
        film,
        color,
        DefaultTextStyle.of(context).style.fontFamily,
      ),
    ),
  );
}

class _FilmPainter extends CustomPainter {
  _FilmPainter(this.label, this.film, this.color, this.fontFamily);
  final (String, String)? label;
  final int film;
  final Color color;
  final String? fontFamily;

  void _text(Canvas canvas, String text, Rect box, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontFamily: fontFamily,
          fontSize: box.height,
          height: 1,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final scale = painter.width > box.width ? box.width / painter.width : 1.0;
    canvas.save();
    canvas.translate(
      box.center.dx - painter.width * scale / 2,
      box.center.dy - painter.height * scale / 2,
    );
    canvas.scale(scale);
    painter.paint(canvas, Offset.zero);
    canvas.restore();
    painter.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final (main, sub) = label ?? ('?', '');
    final wide = main.length > 2;
    final bodyWidth = w * (wide ? 0.86 : 0.58);
    final ink = Paint()..color = color;
    // The sprocket holes are cut out so the icon works on any background.
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(w * 0.16, 0, w * 0.4, h * 0.3),
        Radius.circular(h * 0.06),
      ),
      ink,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(0, h * 0.18, bodyWidth, h),
        Radius.circular(h * 0.1),
      ),
      ink,
    );
    final tail = Rect.fromLTRB(
      bodyWidth - 1,
      h * 0.34,
      w,
      sub.isEmpty ? h * 0.82 : h,
    );
    canvas.drawRect(tail, ink);
    final hole = Paint()..blendMode = BlendMode.clear;
    final holes = wide ? 1 : 3;
    final gap = (w - bodyWidth) / (holes + 0.5);
    for (var i = 0; i < holes; i++) {
      final x = bodyWidth + gap * (i + 0.45);
      for (final y in [h * 0.4, if (sub.isEmpty) h * 0.68]) {
        canvas.drawRect(Rect.fromLTWH(x, y, gap * 0.5, h * 0.08), hole);
      }
    }
    canvas.restore();
    _text(
      canvas,
      main,
      Rect.fromLTRB(w * 0.05, h * 0.3, bodyWidth - w * 0.05, h * 0.9),
      Colors.white,
    );
    if (sub.isNotEmpty) {
      // Black-and-white filter variants show the filter colour.
      final filter = (film >= 7 && film <= 9) || (film >= 13 && film <= 15);
      _text(
        canvas,
        sub,
        Rect.fromLTRB(bodyWidth + w * 0.03, h * 0.54, w - w * 0.03, h * 0.96),
        filter ? _filters[sub]! : Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(_FilmPainter old) =>
      old.film != film || old.color != color;
}
