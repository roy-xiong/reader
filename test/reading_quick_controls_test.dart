import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/domain/models.dart';
import 'package:reader/ui/app_model.dart';
import 'package:reader/ui/reader_pager.dart';
import 'package:reader/ui/reader_screen.dart';
import 'package:reader/ui/reading_brightness.dart';

void main() {
  test('阅读亮度兼容旧设置，并校验边界和重启恢复', () {
    expect(ReaderSettings.fromJson({}).readingBrightness, 1);
    expect(
      ReaderSettings.fromJson({'readingBrightness': -10}).readingBrightness,
      .1,
    );
    expect(
      ReaderSettings.fromJson({
        'readingBrightness': double.nan,
      }).readingBrightness,
      1,
    );
    expect(
      ReaderSettings.fromJson(
        const ReaderSettings(readingBrightness: .45).toJson(),
      ).readingBrightness,
      .45,
    );
  });
  testWidgets('阅读亮度降低像素颜色，保留原始透明度', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: key,
            child: const SizedBox.square(
              dimension: 20,
              child: ReadingDimmer(
                value: .5,
                child: ColoredBox(color: Color(0x80c08040)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        ))!;
        final offset = (10 * 20 + 10) * 4;
        expect(bytes.getUint8(offset), closeTo(96, 2));
        expect(bytes.getUint8(offset + 1), closeTo(64, 2));
        expect(bytes.getUint8(offset + 2), closeTo(32, 2));
        expect(bytes.getUint8(offset + 3), closeTo(128, 1));
      } finally {
        image.dispose();
      }
    });
  });
  for (final size in [
    const Size(320, 480),
    const Size(390, 844),
    const Size(740, 360),
    const Size(1280, 800),
  ]) {
    testWidgets('字号、亮度快捷滑块只在工具栏显示，布局不溢出 $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = _Repository(), model = AppModel(_Repository(), _Platform());
      await model.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            model: model,
            book: repo.book,
            openSettings: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reading-font-size-slider')),
        findsNothing,
      );
      final pager = tester.getRect(find.byType(ReaderPager));
      await tester.tapAt(pager.center);
      await tester.pumpAndSettle();
      final font = find.byKey(const ValueKey('reading-font-size-slider'));
      final brightness = find.byKey(
        const ValueKey('reading-brightness-slider'),
      );
      expect(font, findsOneWidget);
      expect(brightness, findsOneWidget);
      final toolbar = tester.getRect(
        find.byKey(const ValueKey('reading-bottom-controls')),
      );
      expect(toolbar.top, greaterThanOrEqualTo(0));
      expect(toolbar.bottom, lessThanOrEqualTo(size.height));
      final before = model.books.single.offset;
      tester.widget<Slider>(font).onChanged!(32);
      await tester.pumpAndSettle();
      expect(model.settings.fontSize, 32);
      expect(model.books.single.offset, before);
      tester.widget<Slider>(brightness).onChanged!(.4);
      await tester.pumpAndSettle();
      expect(model.settings.readingBrightness, .4);
      expect(
        tester.widget<ReadingDimmer>(find.byType(ReadingDimmer)).value,
        .4,
      );
      expect(model.books.single.offset, before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    });
  }
  testWidgets('双指上下滑调整亮度，垂直翻页模式也不会误翻页或打开工具', (tester) async {
    final repo = _Repository(), model = AppModel(_Repository(), _Platform());
    await model.initialize();
    model.updateSettings(
      model.settings.copyWith(readingBrightness: .6, pageEffect: 'vertical'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(
          model: model,
          book: repo.book,
          openSettings: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byType(ReaderPager));
    final before = model.books.single.offset;
    Future<void> slide(double delta) async {
      final a = await tester.startGesture(
        rect.center - const Offset(50, 0),
        pointer: 1,
      );
      final b = await tester.startGesture(
        rect.center + const Offset(50, 0),
        pointer: 2,
      );
      await tester.pump();
      await a.moveBy(Offset(0, delta));
      await b.moveBy(Offset(0, delta));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reading-brightness-hint')),
        findsOneWidget,
      );
      await a.up();
      await tester.pump();
      // 剩余手指继续移动，也属于本次双指序列，不得触发翻页。
      await b.moveBy(const Offset(0, -60));
      await b.up();
      await tester.pumpAndSettle();
      expect(model.books.single.offset, before);
      expect(
        find.byKey(const ValueKey('reading-bottom-controls')),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pumpAndSettle();
    }

    await slide(100);
    final dark = model.settings.readingBrightness;
    expect(dark, lessThan(.6));
    await slide(-120);
    expect(model.settings.readingBrightness, greaterThan(dark));
    final single = await tester.startGesture(rect.center, pointer: 1);
    await single.moveBy(const Offset(0, 5));
    await single.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });
  testWidgets('触控板纵向平移调整阅读亮度', (tester) async {
    final repo = _Repository(), model = AppModel(_Repository(), _Platform());
    await model.initialize();
    model.updateSettings(model.settings.copyWith(readingBrightness: .7));
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(
          model: model,
          book: repo.book,
          openSettings: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byType(ReaderPager));
    await tester.sendEventToBinding(
      PointerPanZoomStartEvent(pointer: 11, position: rect.center),
    );
    await tester.sendEventToBinding(
      PointerPanZoomUpdateEvent(
        pointer: 11,
        position: rect.center,
        pan: const Offset(0, 90),
        panDelta: const Offset(0, 90),
      ),
    );
    await tester.sendEventToBinding(
      PointerPanZoomEndEvent(pointer: 11, position: rect.center),
    );
    await tester.pumpAndSettle();
    expect(model.settings.readingBrightness, lessThan(.7));
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });
}

class _Repository extends LibraryRepository {
  _Repository() : super(Directory.systemTemp);
  final text = List.filled(200, '春风又绿江南岸，明月何时照我还。\n\n').join();
  late final book = BookRecord(
    id: 'b' * 64,
    title: '快捷调节测试',
    author: '',
    format: 'TXT',
    length: text.length,
    importedAt: 1,
  );
  @override
  Future<Map<String, dynamic>?> load() async => {
    'settings': const ReaderSettings(pageEffect: 'none').toJson(),
    'books': [book.toJson()],
    'fonts': [],
  };
  @override
  Future<void> save(Map<String, dynamic> snapshot) async {}
  @override
  Future<List<ReaderFont>> recoverFonts(
    List<ReaderFont> catalog, {
    String? selectedId,
    String? selectedName,
  }) async => catalog;
  @override
  Future<BookDocument> open(BookRecord record) async => BookDocument(
    title: record.title,
    author: '',
    text: text,
    chapters: [Chapter(title: '', start: 0, end: text.length)],
  );
}

class _Platform extends PlatformService {
  @override
  Future<void> appearance(String theme) async {}
}
