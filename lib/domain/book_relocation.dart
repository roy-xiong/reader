import 'dart:math';
import 'dart:isolate';
import 'models.dart';

/// 解析器升级后使用文字上下文迁移原坐标，移除目录或空白变化不会重置阅读位置。
class BookRelocation {
  static Future<BookRecord> inBackground(
    BookRecord book,
    BookDocument previous,
    BookDocument current,
  ) => Isolate.run(() => relocate(book, previous, current));

  static BookRecord relocate(
    BookRecord book,
    BookDocument previous,
    BookDocument current,
  ) {
    final normalized = StringBuffer(), positions = <int>[];
    bool blank(int unit) =>
        unit == 32 ||
        (unit >= 9 && unit <= 13) ||
        unit == 0xa0 ||
        unit == 0x3000;
    for (var i = 0; i < current.text.length; i++) {
      final unit = current.text.codeUnitAt(i);
      if (!blank(unit)) {
        normalized.writeCharCode(unit);
        positions.add(i);
      }
    }
    final haystack = normalized.toString();
    int locate(int oldOffset) {
      if (positions.isEmpty) {
        return 0;
      }
      final offset = oldOffset
          .clamp(0, max(0, previous.text.length - 1))
          .toInt();
      final start = max(0, offset - 24),
          end = min(previous.text.length, offset + 100);
      final prefix = previous.text
          .substring(start, offset)
          .codeUnits
          .where((u) => !blank(u))
          .length;
      final needle = String.fromCharCodes(
        previous.text.substring(start, end).codeUnits.where((u) => !blank(u)),
      );
      final expected =
          (offset / max(1, previous.text.length) * positions.length).round();
      var match = haystack.indexOf(needle),
          best = -1,
          distance = 1 << 60,
          attempts = 0;
      while (needle.isNotEmpty && match >= 0 && attempts++ < 200) {
        final d = (match + prefix - expected).abs();
        if (d < distance) {
          best = match + prefix;
          distance = d;
        }
        match = haystack.indexOf(needle, match + 1);
      }
      // 定位靠近被移除的旧目录时，前向上下文仍可精确锚定正文。
      if (best < 0) {
        final forward = String.fromCharCodes(
          previous.text
              .substring(offset, end)
              .codeUnits
              .where((u) => !blank(u)),
        );
        if (forward.isNotEmpty) {
          best = haystack.indexOf(forward);
        }
      }
      return best >= 0
          ? positions[best.clamp(0, positions.length - 1)]
          : (offset / max(1, previous.text.length) * current.text.length)
                .round()
                .clamp(0, current.text.length - 1);
    }

    return book.copyWith(
      length: current.text.length,
      offset: locate(book.offset),
      bookmarks: book.bookmarks
          .map(
            (mark) => BookMark(
              offset: locate(mark.offset),
              quote: mark.quote,
              createdAt: mark.createdAt,
            ),
          )
          .toList(),
    );
  }
}
