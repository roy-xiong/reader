import 'package:flutter/material.dart';

/// 阅读器统一使用矢量图标，避免图标字体子集、字体回退造成的缺字或错误字形。
enum ReaderGlyph {
  lock,
  settings,
  folder,
  add,
  search,
  sort,
  library,
  book,
  back,
  bookmark,
  bookmarkOutline,
  removeBookmark,
  bookmarks,
  list,
  down,
  close,
  restore,
  chevronRight,
  circle,
  circleOutline,
  backspace,
  more,
}

/// 遵循 IconTheme 的尺寸、颜色与透明度；所有路径限制在 24×24 的绘制区域内。
class ReaderIcon extends StatelessWidget {
  const ReaderIcon(this.glyph, {super.key, this.size, this.color});
  final ReaderGlyph glyph;
  final double? size;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final tint =
        color ?? theme.color ?? Theme.of(context).colorScheme.onSurface;
    // Center 放松输入框等父控件的最小约束，防止 18px 图标被强制绘制成 48px。
    return Center(
      widthFactor: 1,
      heightFactor: 1,
      child: SizedBox.square(
        dimension: size ?? theme.size ?? 24,
        child: CustomPaint(
          painter: _ReaderIconPainter(
            glyph,
            tint.withValues(alpha: tint.a * (theme.opacity ?? 1)),
          ),
        ),
      ),
    );
  }
}

class _ReaderIconPainter extends CustomPainter {
  const _ReaderIconPainter(this.glyph, this.color);
  final ReaderGlyph glyph;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;
    void line(double x1, double y1, double x2, double y2) =>
        canvas.drawLine(Offset(x1, y1), Offset(x2, y2), stroke);
    void path(Path path, {bool filled = false}) =>
        canvas.drawPath(path, filled ? fill : stroke);
    final bookmark = Path()
      ..moveTo(7, 3)
      ..lineTo(17, 3)
      ..lineTo(17, 21)
      ..lineTo(12, 17)
      ..lineTo(7, 21)
      ..close();
    switch (glyph) {
      case ReaderGlyph.lock:
        path(
          Path()
            ..moveTo(7.5, 10)
            ..lineTo(7.5, 7)
            ..cubicTo(7.5, 1, 16.5, 1, 16.5, 7)
            ..lineTo(16.5, 10),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTRB(4.5, 10, 19.5, 21),
            const Radius.circular(2.5),
          ),
          stroke,
        );
        canvas.drawCircle(const Offset(12, 15), 1, fill);
        line(12, 16, 12, 18);
      case ReaderGlyph.settings:
        for (final row in [(6.0, 9.0), (12.0, 15.0), (18.0, 9.0)]) {
          line(3, row.$1, row.$2 - 2.5, row.$1);
          line(row.$2 + 2.5, row.$1, 21, row.$1);
          canvas.drawCircle(Offset(row.$2, row.$1), 2.5, stroke);
        }
      case ReaderGlyph.folder:
        path(
          Path()
            ..moveTo(3, 7)
            ..lineTo(3, 5)
            ..lineTo(9, 5)
            ..lineTo(12, 8)
            ..lineTo(21, 8)
            ..lineTo(19, 20)
            ..lineTo(3, 20)
            ..close(),
        );
        line(3, 10, 19.5, 10);
      case ReaderGlyph.add:
        line(12, 4, 12, 20);
        line(4, 12, 20, 12);
      case ReaderGlyph.search:
        canvas.drawCircle(const Offset(10.5, 10.5), 6.5, stroke);
        line(15.3, 15.3, 21, 21);
      case ReaderGlyph.sort:
        line(3, 6, 21, 6);
        line(3, 12, 16, 12);
        line(3, 18, 10, 18);
      case ReaderGlyph.book:
      case ReaderGlyph.library:
        path(
          Path()
            ..moveTo(3, 5)
            ..quadraticBezierTo(7, 3, 12, 6)
            ..quadraticBezierTo(17, 3, 21, 5)
            ..lineTo(21, 20)
            ..quadraticBezierTo(17, 18, 12, 21)
            ..quadraticBezierTo(7, 18, 3, 20)
            ..close(),
        );
        line(12, 6, 12, 21);
        if (glyph == ReaderGlyph.library) {
          line(6, 9, 9, 10);
          line(15, 10, 18, 9);
        }
      case ReaderGlyph.back:
        line(4, 12, 21, 12);
        path(
          Path()
            ..moveTo(11, 5)
            ..lineTo(4, 12)
            ..lineTo(11, 19),
        );
      case ReaderGlyph.bookmark:
        path(bookmark, filled: true);
      case ReaderGlyph.bookmarkOutline:
        path(bookmark);
      case ReaderGlyph.removeBookmark:
        path(bookmark);
        line(9.5, 10, 14.5, 10);
      case ReaderGlyph.bookmarks:
        path(
          Path()
            ..moveTo(9, 3)
            ..lineTo(20, 3)
            ..lineTo(20, 18),
        );
        path(
          Path()
            ..moveTo(4, 6)
            ..lineTo(15, 6)
            ..lineTo(15, 21)
            ..lineTo(9.5, 17)
            ..lineTo(4, 21)
            ..close(),
        );
      case ReaderGlyph.list:
        for (final y in [6.0, 12.0, 18.0]) {
          canvas.drawCircle(Offset(4, y), 1, fill);
          line(9, y, 21, y);
        }
      case ReaderGlyph.down:
        path(
          Path()
            ..moveTo(5, 9)
            ..lineTo(12, 16)
            ..lineTo(19, 9),
        );
      case ReaderGlyph.chevronRight:
        path(
          Path()
            ..moveTo(9, 5)
            ..lineTo(16, 12)
            ..lineTo(9, 19),
        );
      case ReaderGlyph.close:
        line(6, 6, 18, 18);
        line(18, 6, 6, 18);
      case ReaderGlyph.restore:
        path(
          Path()
            ..moveTo(4, 10)
            ..cubicTo(6, 0, 22, 3, 21, 13)
            ..cubicTo(20, 23, 6, 23, 4, 16),
        );
        path(
          Path()
            ..moveTo(3, 4)
            ..lineTo(3, 10)
            ..lineTo(9, 10),
        );
        line(12, 7, 12, 12);
        line(12, 12, 16, 14);
      case ReaderGlyph.circle:
        canvas.drawCircle(const Offset(12, 12), 8, fill);
      case ReaderGlyph.circleOutline:
        canvas.drawCircle(const Offset(12, 12), 8, stroke);
      case ReaderGlyph.backspace:
        path(
          Path()
            ..moveTo(9, 5)
            ..lineTo(21, 5)
            ..lineTo(21, 19)
            ..lineTo(9, 19)
            ..lineTo(3, 12)
            ..close(),
        );
        line(12, 9, 17, 15);
        line(17, 9, 12, 15);
      case ReaderGlyph.more:
        for (final x in [5.0, 12.0, 19.0]) {
          canvas.drawCircle(Offset(x, 12), 1.5, fill);
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ReaderIconPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
