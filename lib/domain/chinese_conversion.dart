import 'models.dart';

/// 仅记录长度发生变化的转换片段，以低内存开销保持阅读进度、书签的原文坐标。
class TextOffsetMap {
  const TextOffsetMap([this.edits = const []]);

  /// 每项依次为原文起止、显示文本起止，均采用 UTF-16 偏移。
  final List<List<int>> edits;
  int toDisplay(int offset) => _map(offset, false);
  int toSource(int offset) => _map(offset, true);
  int _map(int offset, bool reverse) {
    var low = 0, high = edits.length - 1, found = -1;
    final a = reverse ? 2 : 0, b = reverse ? 0 : 2;
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      if (edits[mid][a] <= offset) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    if (found < 0) {
      return offset;
    }
    final edit = edits[found];
    if (offset < edit[a + 1]) {
      return edit[b] +
          ((offset - edit[a]) *
              (edit[b + 1] - edit[b]) ~/
              (edit[a + 1] - edit[a]));
    }
    return offset + edit[b + 1] - edit[a + 1];
  }
}

class ConvertedDocument {
  const ConvertedDocument(this.document, this.offsets);
  final BookDocument document;
  final TextOffsetMap offsets;
}

class _DictionaryNode {
  final children = <int, _DictionaryNode>{};
  String? replacement;
}

/// OpenCC 标准字词表的最长匹配转换器，不依赖原生库或新工具链。
class ChineseTextConverter {
  ChineseTextConverter(String characters, String phrases) {
    for (final dictionary in [characters, phrases]) {
      for (final line in dictionary.split('\n')) {
        if (line.isEmpty || line.startsWith('#')) {
          continue;
        }
        final fields = line.trimRight().split('\t');
        if (fields.length < 2 || fields[0].isEmpty || fields[1].isEmpty) {
          continue;
        }
        var node = root;
        for (final unit in fields[0].codeUnits) {
          node = node.children.putIfAbsent(unit, _DictionaryNode.new);
        }
        node.replacement = fields[1].split(' ').first;
      }
    }
  }
  final root = _DictionaryNode();
  ({String text, TextOffsetMap offsets}) convert(String source) {
    final output = StringBuffer();
    final edits = <List<int>>[];
    var i = 0;
    while (i < source.length) {
      var node = root, scan = i, end = i;
      String? replacement;
      while (scan < source.length) {
        final next = node.children[source.codeUnitAt(scan)];
        if (next == null) {
          break;
        }
        node = next;
        scan++;
        if (node.replacement != null) {
          replacement = node.replacement;
          end = scan;
        }
      }
      if (replacement == null) {
        output.writeCharCode(source.codeUnitAt(i++));
        continue;
      }
      final targetStart = output.length;
      output.write(replacement);
      if (replacement.length != end - i) {
        edits.add([i, end, targetStart, output.length]);
      }
      i = end;
    }
    return (
      text: output.toString(),
      offsets: TextOffsetMap(List.unmodifiable(edits)),
    );
  }

  ConvertedDocument document(BookDocument source) {
    final result = convert(source.text), offsets = result.offsets;
    final chapters = source.chapters
        .map(
          (chapter) => Chapter(
            title: convert(chapter.title).text,
            start: offsets.toDisplay(chapter.start),
            end: offsets.toDisplay(chapter.end),
            isContinuation: chapter.isContinuation,
            headingEnd: chapter.headingEnd == null
                ? null
                : offsets.toDisplay(chapter.headingEnd!),
          ),
        )
        .toList();
    return ConvertedDocument(
      BookDocument(
        title: convert(source.title).text,
        author: source.author,
        text: result.text,
        chapters: chapters,
        parseVersion: source.parseVersion,
      ),
      offsets,
    );
  }
}
