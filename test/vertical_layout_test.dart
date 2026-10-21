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
import 'package:reader/ui/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const style = TextStyle(fontSize: 21, height: 1.8, letterSpacing: 1);
  final doc = _document();

  test('横竖排和列序兼容旧设置，并持久化', () {
    expect(ReaderSettings.fromJson({}).readingLayout, 'horizontal');
    final saved = ReaderSettings.fromJson(
      const ReaderSettings(
        readingLayout: 'vertical',
        verticalDirection: 'ltr',
      ).toJson(),
    );
    expect(saved.readingLayout, 'vertical');
    expect(saved.verticalDirection, 'ltr');
    expect(
      ReaderSettings.fromJson({
        'readingLayout': 'bad',
        'verticalDirection': 'bad',
      }).verticalDirection,
      'rtl',
    );
  });

  for (final size in [
    const Size(280, 360),
    const Size(600, 280),
    const Size(58, 80),
  ]) {
    test('竖排分页连续、字素完整、方向镜像且单元在页内 $size', () async {
      final results = <List<ReadingPage>>[];
      for (final direction in ['rtl', 'ltr']) {
        final pages = await Pagination.layout(
          document: doc,
          chapter: doc.chapters.first,
          width: size.width,
          height: size.height,
          style: style,
          paragraphSpacing: 12,
          scaler: TextScaler.noScaling,
          readingLayout: 'vertical',
          verticalDirection: direction,
        );
        results.add(pages);
        expect(pages.first.start, 0);
        expect(pages.last.end, doc.text.length);
        final boundaries = <int>{0};
        var position = 0;
        for (final cluster in doc.text.characters) {
          position += cluster.length;
          boundaries.add(position);
        }
        for (var i = 0; i < pages.length; i++) {
          final page = pages[i];
          expect(boundaries, containsAll([page.start, page.end]));
          if (i > 0) expect(page.start, pages[i - 1].end);
          expect(page.end, greaterThan(page.start));
          final actual = page.columns.map((c) => c.text).join();
          expect(
            actual,
            doc.text.substring(page.start, page.end).replaceAll('\n', ''),
          );
          for (var c = 0; c < page.columns.length; c++) {
            final col = page.columns[c];
            expect(col.x, greaterThanOrEqualTo(0));
            expect(col.x + col.width, lessThanOrEqualTo(size.width + .01));
            if (c > 0) {
              expect(
                col.x.compareTo(page.columns[c - 1].x),
                direction == 'rtl' ? -1 : 1,
              );
            }
            for (final glyph in col.glyphs) {
              expect(
                glyph.y + glyph.advance,
                lessThanOrEqualTo(size.height + .01),
              );
            }
          }
        }
      }
      expect(results[0].map((p) => p.start), results[1].map((p) => p.start));
      for (var i = 0; i < results[0].length; i++) {
        for (var c = 0; c < results[0][i].columns.length; c++) {
          final a = results[0][i].columns[c], b = results[1][i].columns[c];
          expect(a.x + b.x + a.width, closeTo(size.width, .01));
        }
      }
    });
  }

  test('标题竖线、西文侧排、标点方向、全书索引和预览共用同一竖排', () async {
    final pages = await Pagination.layout(
      document: doc,
      chapter: doc.chapters.first,
      width: 280,
      height: 360,
      style: style,
      paragraphSpacing: 12,
      scaler: TextScaler.noScaling,
      readingLayout: 'vertical',
    );
    expect(pages.first.columns.first.heading, isTrue);
    expect(
      pages.expand((p) => p.columns).where((c) => c.separator),
      isNotEmpty,
    );
    final glyphs = pages
        .expand((p) => p.columns)
        .expand((c) => c.glyphs)
        .toList();
    expect(
      glyphs.where((g) => g.sideways && g.text.contains('Kindle')),
      isNotEmpty,
    );
    expect(glyphs.map((g) => g.text), contains('︒'));
    final index = await BookPageIndex.build(
      document: doc,
      width: 280,
      height: 360,
      style: style,
      paragraphSpacing: 12,
      scaler: TextScaler.noScaling,
      readingLayout: 'vertical',
    );
    expect(index!.starts, pages.map((p) => p.start));
    final session = PageFlipSession(
      document: doc,
      originOffset: 0,
      width: 280,
      height: 360,
      style: style,
      scaler: TextScaler.noScaling,
      paragraphSpacing: 12,
      layoutKey: 'vertical',
      readingLayout: 'vertical',
      index: index,
      initialPages: pages,
    );
    session.seekFraction(1);
    session.flush();
    for (var i = 0; session.loading && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(session.page!.start, pages.last.start);
    expect(session.page!.columns, isNotEmpty);
    session.dispose();
    var cancel = false;
    final pending = Pagination.layout(
      document: doc,
      chapter: doc.chapters.first,
      width: 280,
      height: 360,
      style: style,
      paragraphSpacing: 12,
      scaler: TextScaler.noScaling,
      readingLayout: 'vertical',
      cancelled: () => cancel,
    );
    cancel = true;
    expect(await pending, isEmpty);
  });

  testWidgets('正文切横竖排和列序保留当前位置，设置选择后重启恢复', (tester) async {
    final repository = _Repository(doc);
    final model = AppModel(repository, _Platform());
    await model.initialize();
    final book = model.books.single;
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(model: model, book: book, openSettings: () async {}),
      ),
    );
    await tester.pumpAndSettle();
    final original = tester.widget<ReaderPage>(find.byType(ReaderPage)).page;
    final anchor = book.offset;
    expect(original.start <= anchor && original.end > anchor, isTrue);
    for (final direction in ['rtl', 'ltr']) {
      model.updateSettings(
        model.settings.copyWith(
          readingLayout: 'vertical',
          verticalDirection: direction,
        ),
      );
      await tester.pumpAndSettle();
      final page = tester.widget<ReaderPage>(find.byType(ReaderPage)).page;
      expect(page.columns, isNotEmpty);
      expect(page.start <= anchor && page.end > anchor, isTrue);
      expect(model.books.single.offset, anchor);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(model: model)));
    await tester.tap(find.byKey(const ValueKey('settings-typography')));
    await tester.pumpAndSettle();
    final selector = find.byKey(const ValueKey('vertical-direction-selector'));
    await tester.scrollUntilVisible(
      selector,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(selector);
    await tester.pumpAndSettle();
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('从右向左').last);
    await tester.pumpAndSettle();
    expect(model.settings.verticalDirection, 'rtl');
    await model.flush();
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    final restored = AppModel(repository, _Platform());
    await restored.initialize();
    expect(restored.settings.readingLayout, 'vertical');
    expect(restored.settings.verticalDirection, 'rtl');
    restored.dispose();
  });
}

BookDocument _document() {
  final text =
      '第一章 古书排版\n\n${List.filled(120, '明月松间照，清泉石上流。「古书」Kindle2026，表情👨‍👩‍👧‍👦与组合字e\u0301完整保存。\n\n').join()}';
  return BookDocument(
    title: '竖排测试',
    author: '',
    text: text,
    chapters: [
      Chapter(title: '第一章 古书排版', start: 0, end: text.length, headingEnd: 9),
    ],
  );
}

class _Repository extends LibraryRepository {
  _Repository(this.doc) : super(Directory.systemTemp);
  final BookDocument doc;
  Map<String, dynamic>? saved;
  @override
  Future<Map<String, dynamic>?> load() async =>
      saved ??
      {
        'books': [
          BookRecord(
            id: 'a' * 64,
            title: doc.title,
            author: '',
            format: 'TXT',
            length: doc.text.length,
            offset: 830,
            importedAt: 1,
          ).toJson(),
        ],
        'fonts': [],
        'settings': const ReaderSettings(pageEffect: 'none').toJson(),
      };
  @override
  Future<BookDocument> open(BookRecord book) async => doc;
  @override
  Future<void> save(Map<String, dynamic> value) async {
    saved = value;
  }

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
  @override
  Future<void> readingMode(bool reading) async {}
}
