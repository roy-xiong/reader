import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/domain/models.dart';
import 'package:reader/domain/pagination.dart';
import 'package:reader/ui/app_model.dart';
import 'package:reader/ui/page_flip_session.dart';
import 'package:reader/ui/reader_page.dart';
import 'package:reader/ui/reader_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('全书预览跨章、逐页、边界和取消过期任务', () async {
    final document = _document();
    const style = TextStyle(fontSize: 21, height: 1.8);
    final index = await BookPageIndex.build(
      document: document,
      width: 300,
      height: 500,
      style: style,
      paragraphSpacing: 12,
      scaler: TextScaler.noScaling,
    );
    final initial = await Pagination.layout(
      document: document,
      chapter: document.chapters.first,
      width: 300,
      height: 500,
      style: style,
      paragraphSpacing: 12,
      scaler: TextScaler.noScaling,
    );
    final session = PageFlipSession(
      document: document,
      originOffset: 0,
      width: 300,
      height: 500,
      style: style,
      scaler: TextScaler.noScaling,
      paragraphSpacing: 12,
      layoutKey: 'test',
      index: index,
      initialPages: initial,
    );
    expect(session.canPrevious, isFalse);
    for (final value in [.1, .2, .3, .4, .5, .6, .7, .8]) {
      session.seekFraction(value);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(session.page!.start, greaterThan(0), reason: '持续拖动时也应刷新预览');
    session.seekFraction(.2);
    session.seekFraction(.8);
    session.seekFraction(1);
    session.flush();
    await _ready(session);
    expect(session.page?.end, document.text.length);
    expect(session.canNext, isFalse);
    expect(session.locationLabel, contains('100.0%'));
    session.step(false);
    await _ready(session);
    expect(index!.pageNumberAt(session.page!.start), index.totalPages - 1);
    session.returnToOrigin();
    await _ready(session);
    expect(session.page?.start, 0);
    // 在异步分页或防抖等待期间退出，不再通知已销毁的页面。
    session.seekFraction(.75);
    session.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  for (final size in [
    const Size(360, 760),
    const Size(300, 320),
    const Size(740, 360),
  ]) {
    testWidgets('拖动只预览，关闭与返回不改进度，确认后定位同一页 $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository();
      final model = AppModel(repository, _Platform());
      await model.initialize();
      final book = model.books.first;
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            model: model,
            book: book,
            openSettings: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ReaderPage));
      await tester.pumpAndSettle();
      final original = model.findBook(book.id)!.offset;
      final originalPage = tester
          .widget<ReaderPage>(find.byType(ReaderPage))
          .page;
      final slider = find.byKey(const ValueKey('reading-seek-slider'));

      Future<void> preview(double fraction) async {
        final rect = tester.getRect(slider);
        final gesture = await tester.startGesture(
          Offset(rect.left + 24, rect.center.dy),
        );
        await tester.pump();
        await gesture.moveTo(
          Offset(rect.left + 24 + (rect.width - 48) * fraction, rect.center.dy),
        );
        await tester.pump(const Duration(milliseconds: 80));
        await gesture.up();
        await tester.pumpAndSettle();
      }

      await preview(.75);
      expect(find.byKey(const ValueKey('page-preview-card')), findsOneWidget);
      expect(model.findBook(book.id)!.offset, original);
      expect(
        tester.widget<ReaderPage>(find.byType(ReaderPage).first).page.start,
        originalPage.start,
      );
      expect(
        tester.widget<ReaderPage>(find.byType(ReaderPage).last).page.start,
        greaterThan(original),
      );
      expect(tester.takeException(), isNull);
      final beforeSwipe = tester
          .widget<ReaderPage>(find.byType(ReaderPage).last)
          .page
          .start;
      await tester.drag(
        find.byKey(const ValueKey('page-preview-card')),
        const Offset(100, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderPage>(find.byType(ReaderPage).last).page.start,
        lessThan(beforeSwipe),
      );
      expect(model.findBook(book.id)!.offset, original);
      await tester.tap(find.byKey(const ValueKey('close-page-preview')));
      await tester.pumpAndSettle();
      expect(model.findBook(book.id)!.offset, original);
      expect(find.byKey(const ValueKey('page-preview-card')), findsNothing);

      await preview(.4);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('page-preview-card')), findsNothing);
      expect(model.findBook(book.id)!.offset, original);

      await preview(.8);
      final target = tester
          .widget<ReaderPage>(find.byType(ReaderPage).last)
          .page;
      await tester.tap(
        find.byKey(
          ValueKey(
            size.width == 360 ? 'page-preview-card' : 'confirm-page-preview',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(model.findBook(book.id)!.offset, target.start);
      expect(
        tester.widget<ReaderPage>(find.byType(ReaderPage)).page.start,
        target.start,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    });
  }
}

Future<void> _ready(PageFlipSession session) async {
  for (var i = 0; session.loading && i < 100; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(session.ready, isTrue, reason: session.error);
}

BookDocument _document() {
  final chapters = <Chapter>[];
  var text = '';
  for (var i = 1; i <= 4; i++) {
    final title = '第$i章 预览测试';
    final chunk =
        '$title\n\n${List.generate(28, (line) => '第$i章第$line段，预览翻页保持原位置，点击页面后继续阅读。').join('\n\n')}\n\n';
    chapters.add(
      Chapter(
        title: title,
        start: text.length,
        end: text.length + chunk.length,
        headingEnd: text.length + title.length,
      ),
    );
    text += chunk;
  }
  return BookDocument(
    title: '翻页预览测试',
    author: '',
    text: text,
    chapters: chapters,
  );
}

class _Repository extends LibraryRepository {
  _Repository() : super(Directory.systemTemp);
  final document = _document();
  late final book = BookRecord(
    id: List.filled(64, 'd').join(),
    title: document.title,
    author: '',
    format: 'TXT',
    length: document.text.length,
    importedAt: 1,
  );
  @override
  Future<Map<String, dynamic>?> load() async => {
    'books': [book.toJson()],
    'settings': const ReaderSettings().toJson(),
    'fonts': <Map<String, dynamic>>[],
    'pin': null,
  };
  @override
  Future<BookDocument> open(BookRecord book) async => document;
  @override
  Future<List<ReaderFont>> recoverFonts(
    List<ReaderFont> catalog, {
    String? selectedId,
    String? selectedName,
  }) async => catalog;
  @override
  Future<void> save(Map<String, dynamic> snapshot) async {}
}

class _Platform extends PlatformService {
  @override
  Future<void> appearance(String theme) async {}
}
