import 'dart:math';
import 'package:flutter/painting.dart';
import 'models.dart';

/// 分页结果不持有 TextPainter，避免长期保留原生段落对象。
class PageFragment {
  const PageFragment(
    this.text,
    this.y,
    this.height, {
    this.isHeading = false,
    this.separatorAfter = false,
  });
  final String text;
  final double y, height;
  final bool isHeading, separatorAfter;
}

class ReadingPage {
  const ReadingPage(this.start, this.end, this.fragments);
  final int start, end;
  final List<PageFragment> fragments;
}

/// 排版与显示使用完全相同的宽度、样式和缩放，保证翻页不截断正文。
/// 每次只计算一个有界章节，并定期让出事件循环，支持窗口持续缩放时取消旧任务。
class Pagination {
  /// 标题的排版和绘制共用同一字号、字重，分隔线空间也计入分页高度。
  static TextStyle fragmentStyle(TextStyle body, bool heading) => !heading
      ? body
      : body.copyWith(
          fontSize: (body.fontSize ?? 21) * 1.35,
          height: 1.4,
          fontWeight: (body.fontWeight?.value ?? 400) > FontWeight.w700.value
              ? body.fontWeight
              : FontWeight.w700,
        );

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
      final heading =
          !chapter.isContinuation &&
          chapter.headingEnd != null &&
          offset < chapter.headingEnd!;
      final reserve = heading ? 18.0 : 0.0;
      final remaining = document.text.substring(offset, paragraphEnd);
      final painter = TextPainter(
        text: TextSpan(text: remaining, style: fragmentStyle(style, heading)),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: max(1, width));
      try {
        final metrics = painter.computeLineMetrics();
        var count = 0;
        for (final line in metrics) {
          if (line.baseline + line.descent + y + reserve <=
              usableHeight + 0.01) {
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
        final separator = heading && offset + length >= chapter.headingEnd!;
        fragments.add(
          PageFragment(
            text,
            y,
            fragmentHeight,
            isHeading: heading,
            separatorAfter: separator,
          ),
        );
        y += fragmentHeight + (separator ? 18 : 0);
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

/// 全书分页索引仅保存各页起点，避免长期持有整本书的段落和原生排版对象。
class BookPageIndex {
  BookPageIndex._(List<int> starts) : starts = List.unmodifiable(starts);
  final List<int> starts;
  int get totalPages => starts.length;

  /// 返回字符位置所在的全书页码，从 1 开始计数。
  int pageNumberAt(int offset) {
    if (starts.isEmpty) {
      return 0;
    }
    var low = 0, high = starts.length - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (starts[middle] <= offset) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low + 1;
  }

  /// 使用与阅读页一致的参数逐章计数；每章让出事件循环，并支持尺寸变化时取消。
  static Future<BookPageIndex?> build({
    required BookDocument document,
    required double width,
    required double height,
    required TextStyle style,
    required double paragraphSpacing,
    required TextScaler scaler,
    bool Function()? cancelled,
  }) async {
    final starts = <int>[];
    for (final chapter in document.chapters) {
      if (cancelled?.call() == true) {
        return null;
      }
      final pages = await Pagination.layout(
        document: document,
        chapter: chapter,
        width: width,
        height: height,
        style: style,
        paragraphSpacing: paragraphSpacing,
        scaler: scaler,
        cancelled: cancelled,
      );
      if (cancelled?.call() == true) {
        return null;
      }
      starts.addAll(pages.map((page) => page.start));
      await Future<void>.delayed(Duration.zero);
    }
    return cancelled?.call() == true ? null : BookPageIndex._(starts);
  }
}
