import 'package:flutter/material.dart';
import '../domain/pagination.dart';

/// 正文和预览共用的单页绘制组件，缩略显示不会改变分页边界。
class ReaderPage extends StatelessWidget {
  const ReaderPage({
    super.key,
    required this.page,
    required this.width,
    required this.style,
    required this.scaler,
  });
  final ReadingPage page;
  final double width;
  final TextStyle style;
  final TextScaler scaler;

  /// 动画只录制透明的正文墨迹，背景仍由阅读窗口负责，支持完全透明的 macOS 阅读页。
  void paintInk(Canvas canvas, Size size) =>
      _TextPagePainter(page, width, style, scaler).paint(canvas, size);

  @override
  Widget build(BuildContext context) => Semantics(
    label: page.fragments.map((fragment) => fragment.text).join('\n'),
    child: ClipRect(
      child: CustomPaint(
        painter: _TextPagePainter(page, width, style, scaler),
        size: Size.infinite,
      ),
    ),
  );
}

/// 每次绘制后释放 TextPainter，缓存中只保留正文片段和几何数据。
class _TextPagePainter extends CustomPainter {
  _TextPagePainter(this.page, this.width, this.style, this.scaler);
  final ReadingPage page;
  final double width;
  final TextStyle style;
  final TextScaler scaler;

  @override
  void paint(Canvas canvas, Size size) {
    // 透明背景由阅读窗口统一绘制，避免正文背景被重复叠加。
    for (final fragment in page.fragments) {
      final painter = TextPainter(
        text: TextSpan(
          text: fragment.text,
          style: Pagination.fragmentStyle(style, fragment.isHeading),
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: width);
      try {
        painter.paint(canvas, Offset(0, fragment.y));
      } finally {
        painter.dispose();
      }
      if (fragment.separatorAfter) {
        canvas.drawLine(
          Offset(0, fragment.y + fragment.height + 8),
          Offset(width, fragment.y + fragment.height + 8),
          Paint()
            ..color = (style.color ?? Colors.grey).withValues(alpha: .35)
            ..strokeWidth = .7,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TextPagePainter old) =>
      old.page != page ||
      old.width != width ||
      old.style != style ||
      old.scaler != scaler;
}
