import 'package:flutter/material.dart';

/// 应用外观使用中性灰阶，阅读纸张与照片颜色由阅读设置独立管理。
/// 显式定义深色容器，避免 Material 种子色给大面积背景染上绿色。
abstract final class ReaderTheme {
  static const darkPaper = Color(0xff161616);
  static const lightPaper = Color(0xfff7f5ef);

  static ThemeData build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colors =
        ColorScheme.fromSeed(
          seedColor: const Color(0xff82705a),
          brightness: brightness,
        ).copyWith(
          primary: dark ? const Color(0xffc6b79e) : const Color(0xff75634d),
          onPrimary: dark ? const Color(0xff25211b) : Colors.white,
          primaryContainer: dark
              ? const Color(0xff36312a)
              : const Color(0xffeee4d6),
          onPrimaryContainer: dark
              ? const Color(0xffd7c9b5)
              : const Color(0xff423729),
          secondary: dark ? const Color(0xffb6b1a9) : const Color(0xff706a61),
          secondaryContainer: dark
              ? const Color(0xff32302d)
              : const Color(0xffe8e3db),
          onSecondaryContainer: dark
              ? const Color(0xffcbc5bc)
              : const Color(0xff474139),
          surface: dark ? darkPaper : lightPaper,
          surfaceDim: dark ? darkPaper : const Color(0xffdedbd4),
          surfaceBright: dark ? const Color(0xff383838) : lightPaper,
          surfaceContainerLowest: dark ? const Color(0xff101010) : Colors.white,
          surfaceContainerLow: dark
              ? const Color(0xff1c1c1c)
              : const Color(0xfff1efe9),
          surfaceContainer: dark
              ? const Color(0xff222222)
              : const Color(0xffece9e2),
          surfaceContainerHigh: dark
              ? const Color(0xff2a2a2a)
              : const Color(0xffe6e3dc),
          surfaceContainerHighest: dark
              ? const Color(0xff333333)
              : const Color(0xffdfdcd5),
          onSurface: dark ? const Color(0xff999999) : const Color(0xff34322f),
          onSurfaceVariant: dark
              ? const Color(0xff999999)
              : const Color(0xff706c65),
          outline: dark ? const Color(0xff737373) : const Color(0xff8b857b),
          outlineVariant: dark
              ? const Color(0xff383838)
              : const Color(0xffd7d2c8),
          surfaceTint: Colors.transparent,
        );
    final popupShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      dividerColor: colors.outlineVariant,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        scrolledUnderElevation: 0,
      ),
      popupMenuTheme: PopupMenuThemeData(
        shape: popupShape,
        color: colors.surfaceContainerHigh,
        elevation: 6,
        menuPadding: const EdgeInsets.symmetric(vertical: 8),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(shape: WidgetStatePropertyAll(popupShape)),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(shape: WidgetStatePropertyAll(popupShape)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerHighest.withValues(alpha: .45),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
