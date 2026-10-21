import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/domain/models.dart';
import 'package:reader/ui/app_model.dart';
import 'package:reader/ui/core/reader_theme.dart';
import 'package:reader/ui/reader_page.dart';
import 'package:reader/ui/reader_pager.dart';
import 'package:reader/ui/settings/reading_style_preview.dart';
import 'package:reader/ui/settings/settings_category.dart';
import 'package:reader/ui/settings/settings_detail_screen.dart';
import 'package:reader/ui/settings_screen.dart';

void main() {
  test('深色界面的背景与各级容器为中性灰，正文保留柔和灰色', () {
    final colors = ReaderTheme.build(Brightness.dark).colorScheme;
    for (final color in [
      colors.surface,
      colors.surfaceContainerLow,
      colors.surfaceContainer,
      colors.surfaceContainerHigh,
      colors.surfaceContainerHighest,
    ]) {
      expect(color.r, color.g);
      expect(color.g, color.b);
    }
    expect(colors.onSurface, const Color(0xff999999));
    expect(colors.primary.g, lessThanOrEqualTo(colors.primary.r));
  });

  testWidgets('设置首页仅分类，子页使用同一完整样式预览，试翻不修改书籍或轮换计数', (tester) async {
    final model = AppModel(_Repository(), _Platform());
    await model.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: ReaderTheme.build(Brightness.dark),
        home: SettingsScreen(model: model),
      ),
    );
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(ReadingStylePreview), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-typography')));
    await tester.pumpAndSettle();
    expect(find.byType(ReadingStylePreview), findsOneWidget);
    model.loadedFontId = 'a' * 64;
    model.updateSettings(
      model.settings.copyWith(
        fontId: model.loadedFontId,
        fontSize: 29,
        fontWeight: 700,
        lineHeight: 2.1,
        letterSpacing: 2.5,
        paragraphSpacing: 26,
        textColor: 0xffbbaa99,
        backgroundColor: 0xff222222,
        backgroundOpacity: .7,
        pageEffect: 'none',
      ),
    );
    await tester.pumpAndSettle();
    final page = tester.widget<ReaderPage>(find.byType(ReaderPage));
    expect(page.style.fontFamily, 'user_${model.loadedFontId}');
    expect(page.style.fontSize, 29);
    expect(page.style.fontWeight, FontWeight.w700);
    expect(page.style.height, 2.1);
    expect(page.style.letterSpacing, 2.5);
    expect(page.style.color, const Color(0xffbbaa99));
    expect(
      tester
          .widget<ColoredBox>(
            find.byKey(const ValueKey('reading-style-preview-background')),
          )
          .color
          .a,
      closeTo(.7, .001),
    );
    final oldStart = page.page.start, saved = model.snapshot();
    await tester.tap(find.byKey(const ValueKey('play-page-effect')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ReaderPage>(find.byType(ReaderPage)).page.start,
      isNot(oldStart),
    );
    expect(model.snapshot(), saved);
    await tester.pageBack();
    await tester.pumpAndSettle();
    for (final name in ['background', 'pageTurn']) {
      await tester.tap(find.byKey(ValueKey('settings-$name')));
      await tester.pumpAndSettle();
      expect(find.byType(ReadingStylePreview), findsOneWidget);
      expect(find.byType(ReaderPager), findsOneWidget);
      expect(
        tester.widget<ReaderPage>(find.byType(ReaderPage)).style,
        page.style,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });

  for (final size in [
    const Size(320, 480),
    const Size(740, 360),
    const Size(1280, 840),
  ]) {
    testWidgets('样式子页在小屏、横屏与桌面可滚动且预览不越界 $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = AppModel(_Repository(), _Platform());
      await model.initialize();
      for (final category in SettingsCategory.values.where(
        (value) => value.hasPreview,
      )) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ReaderTheme.build(Brightness.dark),
            home: SettingsDetailScreen(model: model, category: category),
          ),
        );
        await tester.pumpAndSettle();
        final preview = find.byType(ReadingStylePreview);
        expect(preview, findsOneWidget);
        final bounds = tester.getRect(preview);
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(size.width));
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(bounds.bottom, lessThanOrEqualTo(size.height));
        final scroll = find.byKey(
          ValueKey('settings-options-${category.name}'),
        );
        await tester.drag(scroll, const Offset(0, -450));
        await tester.pumpAndSettle();
        expect(tester.getRect(preview), bounds, reason: '选项滚动时保留同一个预览位置');
        model.updateSettings(
          model.settings.copyWith(
            fontSize: 48,
            lineHeight: 3,
            letterSpacing: 8,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      // 模拟输入框键盘占据大部分窗口，仍可滚动访问设置。
      tester.view.viewInsets = FakeViewPadding(bottom: size.height - 190);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    });
  }
}

class _Repository extends LibraryRepository {
  _Repository() : super(Directory.systemTemp);
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> value) async {}
  @override
  Future<List<ReaderFont>> recoverFonts(
    List<ReaderFont> catalog, {
    String? selectedId,
    String? selectedName,
  }) async => catalog;
}

class _Platform extends PlatformService {
  @override
  Future<void> appearance(String theme) async {}
}
