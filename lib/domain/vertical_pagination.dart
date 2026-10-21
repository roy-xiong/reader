import 'dart:math';
import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'models.dart';
import 'pagination.dart';

/// 竖排列内的一个字形单元。原文偏移仍采用 UTF-16；显示替换不修改书籍内容。
class VerticalGlyph {
  const VerticalGlyph(this.text, this.y, this.advance, {this.sideways = false});
  final String text;
  final double y, advance;
  final bool sideways;
}

/// 一列从上往下的正文。x 已包含左右列序，绘制和预览无需再次镜像文字。
class VerticalColumn {
  const VerticalColumn({
    required this.text,
    required this.x,
    required this.width,
    required this.glyphs,
    this.heading = false,
    this.separator = false,
    this.rightToLeft = true,
  });
  final String text;
  final double x, width;
  final List<VerticalGlyph> glyphs;
  final bool heading, separator, rightToLeft;
}

/// 古书式竖排。汉字保持正立，连续西文顺时针侧排；标题放大并以竖线分隔正文。
///
/// 按字素簇换列，避免拆开代理对、组合音标或 Emoji。每 256 个单元让出事件循环，
/// 拖动窗口、切换字体时能取消旧排版；缓存只含几何数据，不保留 TextPainter。
class VerticalPagination {
  static const _closing = '，。、；：？！）］｝〉》」』】〕〗〙〛…,.!?;:';
  static const _opening = '（［｛〈《「『【〔〖〘〚';
  static final _latin = RegExp(r'^[A-Za-z0-9]$');
  static const _forms = {
    '（': '︵',
    '）': '︶',
    '(': '︵',
    ')': '︶',
    '［': '﹇',
    '］': '﹈',
    '【': '︻',
    '】': '︼',
    '《': '︽',
    '》': '︾',
    '〈': '︿',
    '〉': '﹀',
    '「': '﹁',
    '」': '﹂',
    '『': '﹃',
    '』': '﹄',
    '“': '﹁',
    '”': '﹂',
    '‘': '﹃',
    '’': '﹄',
    '，': '︐',
    '、': '︑',
    '。': '︒',
    '：': '︓',
    '；': '︔',
    '！': '︕',
    '？': '︖',
    '…': '︙',
    '—': '︱',
    '–': '︲',
  };

  static Future<List<ReadingPage>> layout({
    required BookDocument document,
    required Chapter chapter,
    required double width,
    required double height,
    required TextStyle style,
    required double paragraphSpacing,
    required TextScaler scaler,
    required bool rightToLeft,
    bool Function()? cancelled,
  }) async {
    final pages = <ReadingPage>[];
    var columns = <VerticalColumn>[];
    var pageStart = chapter.start, offset = chapter.start, ticks = 0;
    var cursor = 0.0;
    final usableWidth = max(1.0, width), usableHeight = max(1.0, height);
    void finish(int end) {
      if (end <= pageStart) return;
      pages.add(
        ReadingPage(
          pageStart,
          end,
          List.unmodifiable(
            columns.map(
              (c) =>
                  PageFragment(c.text, 0, usableHeight, isHeading: c.heading),
            ),
          ),
          columns: List.unmodifiable(columns),
        ),
      );
      columns = [];
      pageStart = end;
      cursor = 0;
    }

    while (offset < chapter.end) {
      if (cancelled?.call() == true) return [];
      final newline = document.text.indexOf('\n', offset);
      final paragraphEnd = newline < 0 || newline >= chapter.end
          ? chapter.end
          : newline;
      if (paragraphEnd == offset) {
        offset++;
        continue;
      }
      final heading =
          !chapter.isContinuation &&
          chapter.headingEnd != null &&
          offset < chapter.headingEnd!;
      final columnStyle = Pagination.fragmentStyle(
        style,
        heading,
      ).copyWith(height: 1);
      final em = max(1.0, scaler.scale(columnStyle.fontSize ?? 21));
      final pitch = em * (heading ? 1.4 : style.height ?? 1.8).clamp(1.0, 3.0);
      final advance = max(1.0, em + (style.letterSpacing ?? 0));
      // 段落通常有界。西文先按整词组合，过长单词按字素簇拆为不超过列高的片段。
      final clusters = document.text
          .substring(offset, paragraphEnd)
          .characters
          .toList();
      var i = 0;
      while (i < clusters.length) {
        if (cancelled?.call() == true) return [];
        if (columns.isNotEmpty && cursor + em > usableWidth + .01) {
          finish(offset);
        }
        final x = rightToLeft ? max(0.0, usableWidth - cursor - em) : cursor;
        final glyphs = <VerticalGlyph>[];
        final text = StringBuffer();
        var y = 0.0;
        while (i < clusters.length) {
          var end = i + 1;
          final first = clusters[i];
          var sideways = _latin.hasMatch(first);
          var display = first;
          var extent = advance;
          if (sideways) {
            while (end < clusters.length &&
                end - i < 32 &&
                _latin.hasMatch(clusters[end])) {
              end++;
            }
            // 同一词尽可能保持完整；只有超过整列高度才缩短。
            while (true) {
              display = clusters.sublist(i, end).join();
              final painter = TextPainter(
                text: TextSpan(text: display, style: columnStyle),
                textDirection: TextDirection.ltr,
                textScaler: scaler,
              )..layout();
              extent = max(advance, painter.width + (style.letterSpacing ?? 0));
              painter.dispose();
              if (extent <= usableHeight || end == i + 1) break;
              end--;
            }
            // 单个字母保持正立，英文单词、数字串整体侧排。
            sideways = end > i + 1;
            if (!sideways) extent = advance;
          } else {
            display = _forms[first] ?? first;
          }
          var reserve = extent;
          // 起始括号不留在列尾，句末标点尽量随前一个字进入下一列。
          if (end < clusters.length &&
              (_closing.contains(clusters[end]) || _opening.contains(first))) {
            reserve += advance;
          }
          if (glyphs.isNotEmpty && y + reserve > usableHeight + .01) break;
          glyphs.add(
            VerticalGlyph(
              display,
              y,
              min(extent, usableHeight),
              sideways: sideways,
            ),
          );
          final source = clusters.sublist(i, end).join();
          text.write(source);
          offset += source.length;
          i = end;
          y += extent;
          if (++ticks % 256 == 0) {
            await Future<void>.delayed(Duration.zero);
            if (cancelled?.call() == true) return [];
          }
          if (y >= usableHeight) break;
        }
        final atEnd = i == clusters.length;
        columns.add(
          VerticalColumn(
            text: text.toString(),
            x: x,
            width: em,
            glyphs: List.unmodifiable(glyphs),
            heading: heading,
            rightToLeft: rightToLeft,
            separator: heading && atEnd,
          ),
        );
        cursor += pitch;
      }
      if (offset < chapter.end && document.text[offset] == '\n') offset++;
      cursor += paragraphSpacing + (heading ? 18 : 0);
    }
    finish(chapter.end);
    return pages;
  }
}
