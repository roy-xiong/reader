import 'package:flutter/material.dart';
import 'app_model.dart';
import 'core/reader_theme.dart';

/// 正文和设置预览的唯一样式解析入口，避免照片文字色、字体和主题默认值不一致。
@immutable
class ReadingStyle {
  const ReadingStyle(this.background, this.foreground, this.text);
  final Color background, foreground;
  final TextStyle text;

  factory ReadingStyle.resolve(AppModel model, Brightness brightness) {
    final s = model.settings;
    final dark = brightness == Brightness.dark;
    final background = s.backgroundColor == null
        ? (dark ? ReaderTheme.darkPaper : ReaderTheme.lightPaper)
        : Color(s.backgroundColor!);
    final photo = model.currentPhoto != null;
    final custom = photo ? s.photoTextColor ?? s.textColor : s.textColor;
    final foreground = custom != null
        ? Color(custom)
        : photo
        ? const Color(0xffe7e7e7)
        : dark
        ? const Color(0xff999999)
        : const Color(0xff34322f);
    return ReadingStyle(
      background,
      foreground,
      TextStyle(
        fontFamily: s.fontId != null && s.fontId == model.loadedFontId
            ? 'user_${s.fontId}'
            : null,
        fontSize: s.fontSize,
        fontWeight:
            FontWeight.values[(s.fontWeight / 100).round().clamp(1, 9) - 1],
        height: s.lineHeight,
        letterSpacing: s.letterSpacing,
        color: foreground,
      ),
    );
  }
}
