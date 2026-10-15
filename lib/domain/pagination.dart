import 'dart:math';
import 'package:flutter/painting.dart';
import 'models.dart';

/// 分页结果不持有 TextPainter，避免长期保留原生段落对象。
class PageFragment {
  const PageFragment(this.text, this.y, this.height);
  final String text;
  final double y, height;
}

class ReadingPage {
  const ReadingPage(this.start, this.end, this.fragments);
  final int start, end;
  final List<PageFragment> fragments;
}

/// 排版与显示使用完全相同的宽度、样式和缩放，保证翻页不截断正文。
/// 每次只计算一个有界章节，并定期让出事件循环，支持窗口持续缩放时取消旧任务。
class Pagination {
  static Future<List<ReadingPage>> layout({
    required BookDocument document,
    required Chapter chapter,
    required double width,
    required double height,
    required TextStyle style,
    required double paragraphSpacing,
    required TextScaler scaler,
    bool Function()? cancelled,
  }) async {
    final pages = <ReadingPage>[];
    var fragments = <PageFragment>[];
    var y = 0.0, pageStart = chapter.start, offset = chapter.start;
    var ticks = 0;
    final usableHeight = max(height, 1.0);
    void finish(int end) {
      if (end <= pageStart) {
        return;
      }
      pages.add(ReadingPage(pageStart, end, List.unmodifiable(fragments)));
      pageStart = end;
      fragments = [];
      y = 0;
    }

    while (offset < chapter.end) {
      if (cancelled?.call() == true) {
        return [];
      }
      final newline = document.text.indexOf('\n', offset);
      final paragraphEnd = newline < 0 || newline >= chapter.end
          ? chapter.end
          : newline;
      if (paragraphEnd == offset) {
        offset++;
        // 一个或多个空行统一为段间距，避免重复空白占满整页。
        if (y > 0 && (offset < 2 || document.text[offset - 2] != '\n')) {
          y += paragraphSpacing;
        }
        continue;
      }
      final remaining = document.text.substring(offset, paragraphEnd);
      final painter = TextPainter(
        text: TextSpan(text: remaining, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: max(1, width));
      try {
        final metrics = painter.computeLineMetrics();
        var count = 0;
        for (final line in metrics) {
          if (line.baseline + line.descent + y <= usableHeight + 0.01) {
            count++;
          } else {
            break;
          }
        }
        if (count == 0 && fragments.isNotEmpty) {
          finish(offset);
          continue;
        }
        count = max(1, count);
        final last = metrics[min(count, metrics.length) - 1];
        final int length;
        if (count >= metrics.length) {
          length = remaining.length;
        } else {
          final position = painter.getPositionForOffset(
            Offset(0, last.baseline - last.ascent / 2),
          );
          length = painter
              .getLineBoundary(position)
              .end
              .clamp(1, remaining.length);
        }
        final text = remaining.substring(0, length);
        final fragmentHeight = last.baseline + last.descent;
        fragments.add(PageFragment(text, y, fragmentHeight));
        y += fragmentHeight;
        offset += length;
        if (offset < paragraphEnd) {
          finish(offset);
        } else {
          if (offset < chapter.end && document.text[offset] == '\n') {
            offset++;
          }
          y += paragraphSpacing;
          if (y >= usableHeight) {
            finish(offset);
          }
        }
      } finally {
        painter.dispose();
      }
      if (++ticks % 12 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (pageStart < chapter.end) {
      finish(chapter.end);
    }
    return pages;
  }
}
