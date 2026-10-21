import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/book_parser.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/domain/book_relocation.dart';
import 'package:reader/domain/chinese_conversion.dart';
import 'package:reader/domain/models.dart';
import 'package:reader/domain/pagination.dart';
import 'package:reader/main.dart';
import 'package:reader/ui/app_model.dart';
import 'package:reader/ui/contents_dialog.dart';
import 'package:reader/ui/core/reader_icon.dart';
import 'package:reader/ui/reader_screen.dart';
import 'package:reader/ui/settings_screen.dart';
import 'package:reader/ui/shelf_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('全书页码跨章累计，标题加大和分隔线参与分页', () async {
    final doc = fixtureDocument();
    const style = TextStyle(fontSize: 21, height: 1.8);
    final index = await BookPageIndex.build(
      document: doc,
      width: 260,
      height: 300,
      style: style,
      paragraphSpacing: 12,
      scaler: TextScaler.noScaling,
    );
    var total = 0;
    for (final chapter in doc.chapters) {
      final pages = await Pagination.layout(
        document: doc,
        chapter: chapter,
        width: 260,
        height: 300,
        style: style,
        paragraphSpacing: 12,
        scaler: TextScaler.noScaling,
      );
      expect(index?.pageNumberAt(chapter.start), total + 1);
      expect(pages.first.fragments.first.isHeading, isTrue);
      expect(pages.first.fragments.any((f) => f.separatorAfter), isTrue);
      expect(
        Pagination.fragmentStyle(style, true).fontSize,
        greaterThan(style.fontSize!),
      );
      total += pages.length;
    }
    expect(index?.totalPages, total);
    expect(index?.pageNumberAt(doc.text.length - 1), total);
    expect(
      await BookPageIndex.build(
        document: doc,
        width: 260,
        height: 300,
        style: style,
        paragraphSpacing: 12,
        scaler: TextScaler.noScaling,
        cancelled: () => true,
      ),
      isNull,
    );
  });

  test('MOBI 实际标题和目录导航分离，长内容续排不生成伪章节', () async {
    final book = await BookParser.parseBytes(
      mobiFixture('''<html><body><h1>测试书名</h1>
      <h2>目录</h2><ul><li><a href="#one">第一章 风起</a></li><li><a href="#two">第二章 山行</a></li></ul>
      <h2 id="one">第一章 风起</h2><p>第一段真实正文。</p>
      <h2 id="two">第二章 山行</h2><p>第二段真实正文。</p></body></html>'''),
      'test.mobi',
    );
    expect(book.outline.map((c) => c.title), ['测试书名', '第一章 风起', '第二章 山行']);
    expect(book.text.indexOf('第一章 风起'), book.text.lastIndexOf('第一章 风起'));
    expect(book.outline[1].headingEnd, isNotNull);
    final text = '第一章 长篇\n\n${List.filled(16000, '文').join()}';
    final long = await BookParser.parseBytes(
      Uint8List.fromList(utf8.encode(text)),
      'long.txt',
    );
    expect(long.chapters.length, greaterThan(1));
    expect(long.outline.length, 1);
    expect(long.chapters[1].headingEnd, isNull);
  });

  test('正文简繁转换使用词组消歧，长度变化可映射到原文定位', () async {
    final converter = ChineseTextConverter(
      await File('assets/opencc/STCharacters.txt').readAsString(),
      await File('assets/opencc/STPhrases.txt').readAsString(),
    );
    expect(converter.convert('皇后头发干燥，发展阅读习惯。').text, '皇后頭髮乾燥，發展閱讀習慣。');
    final mapped = ChineseTextConverter('甲\t甲乙\n𠀀\t中', '').convert('前甲后𠀀末');
    expect(mapped.text, '前甲乙后中末');
    expect(mapped.offsets.toDisplay(2), 3);
    expect(mapped.offsets.toSource(3), 2);
    expect(mapped.offsets.toDisplay(5), 5);
    final settings = ReaderSettings.fromJson(
      const ReaderSettings(scriptMode: 'traditional', fontWeight: 700).toJson(),
    );
    expect(settings.scriptMode, 'traditional');
    expect(settings.fontWeight, 700);
  });

  test('缓存升级移除目录后仍定位相同正文和书签', () async {
    const body = '第一章 风起\n\n同一段正文，位置需要保持。\n\n';
    final oldText = '旧目录列表\n\n$body';
    final previous = BookDocument(
      title: '测试',
      author: '',
      text: oldText,
      chapters: [Chapter(title: '测试', start: 0, end: oldText.length)],
      parseVersion: 1,
    );
    final next = BookDocument(
      title: '测试',
      author: '',
      text: body,
      chapters: [
        Chapter(title: '第一章 风起', start: 0, end: body.length, headingEnd: 6),
      ],
    );
    final record = BookRecord(
      id: List.filled(64, 'c').join(),
      title: '测试',
      author: '',
      format: 'MOBI',
      length: oldText.length,
      importedAt: 1,
      offset: oldText.indexOf('同一段'),
      bookmarks: [
        BookMark(offset: oldText.indexOf('位置'), quote: '位置需要保持', createdAt: 2),
      ],
    );
    final migrated = BookRelocation.relocate(record, previous, next);
    expect(next.text.substring(migrated.offset), startsWith('同一段'));
    expect(
      next.text.substring(migrated.bookmarks.first.offset),
      startsWith('位置'),
    );
    final repo = _UpgradeRepository(record, previous, next);
    final model = AppModel(repo, _TestPlatform());
    await model.initialize();
    final opened = await model.openBook(record);
    expect(opened.parseVersion, 2);
    expect(model.findBook(record.id)?.offset, migrated.offset);
    expect(repo.replaced?.parseVersion, 2);
    expect(repo.saved, isNotNull);
    model.dispose();
  });

  testWidgets('目录打开后当前章节可见且颜色区分', (tester) async {
    final text = List.filled(100, '章节内容\n\n').join();
    final chapters = List.generate(
      100,
      (i) => Chapter(title: '第 $i 章', start: i * 6, end: (i + 1) * 6),
    );
    final doc = BookDocument(
      title: '测试',
      author: '',
      text: text,
      chapters: chapters,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('目录'),
              onPressed: () => showDialog<int>(
                context: context,
                builder: (_) => ChapterContentsDialog(
                  document: doc,
                  offset: chapters[85].start,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    final selected = find.byKey(ValueKey('chapter-${chapters[85].start}'));
    expect(selected, findsOneWidget);
    expect(tester.widget<ListTile>(selected).selected, isTrue);
    expect(find.text('正在阅读'), findsOneWidget);
    expect(
      tester.getRect(selected).overlaps(Offset.zero & tester.view.physicalSize),
      isTrue,
    );
  });

  testWidgets('搜索图标保持 18px，菜单圆角且十六进制只输入六位', (tester) async {
    final model = AppModel(_Repository(), _TestPlatform());
    await model.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: ShelfScreen(
          model: model,
          openBook: (_) async {},
          openSettings: () async {},
        ),
      ),
    );
    final icon = find.descendant(
      of: find.byKey(const ValueKey('shelf-search')),
      matching: find.byType(ReaderIcon),
    );
    expect(
      tester.getSize(
        find.descendant(of: icon, matching: find.byType(CustomPaint)),
      ),
      const Size(18, 18),
    );
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(model: model)));
    await tester.tap(find.byKey(const ValueKey('settings-appearance')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme-selector')));
    await tester.pumpAndSettle();
    final option = find.text('深色').last;
    final clips = find.ancestor(of: option, matching: find.byType(ClipRRect));
    expect(
      tester
          .widgetList<ClipRRect>(clips)
          .any(
            (clip) =>
                clip.borderRadius.resolve(TextDirection.ltr).topLeft.x >= 12,
          ),
      isTrue,
    );
    await tester.tap(option);
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-background')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('选择颜色').first);
    await tester.tap(find.text('选择颜色').first);
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('hex-color-input'));
    await tester.enterText(input, '#999999');
    await tester.pump();
    expect(tester.widget<TextField>(input).controller?.text, '999999');
    expect(tester.widget<TextField>(input).maxLength, 6);
    await tester.tap(find.text('使用颜色'));
    await tester.pumpAndSettle();
    expect(model.settings.textColor, 0xff999999);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });

  testWidgets(
    'macOS 阅读页 Esc 最小化，Command 加减字号并保留透明背景',
    (tester) async {
      final platform = _TestPlatform();
      final model = AppModel(_Repository(), platform);
      await model.initialize();
      model.updateSettings(
        model.settings.copyWith(backgroundOpacity: 0, fontWeight: 700),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            model: model,
            book: fixtureBook(),
            openSettings: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor?.a,
        0,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(model.settings.fontSize, 22);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.minus);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(model.settings.fontSize, 21);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(platform.minimized, 1);
      final progress = tester
          .widget<Text>(find.byKey(const ValueKey('reading-progress')))
          .data!;
      expect(progress, contains('%'));
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('应用显示名称和深色默认文字', (tester) async {
    final model = AppModel(_Repository(), _TestPlatform());
    await model.initialize();
    model.updateSettings(model.settings.copyWith(theme: 'dark'));
    await tester.pumpWidget(ReaderApp(model: model));
    await tester.pumpAndSettle();
    expect(find.text('阅读'), findsOneWidget);
    final context = tester.element(find.byType(ShelfScreen));
    expect(Theme.of(context).colorScheme.onSurface, const Color(0xff999999));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

BookDocument fixtureDocument() {
  final chunks = List.generate(
    3,
    (i) => '第${i + 1}章 测试\n\n${List.filled(40, '正文内容，翻页需要保持连续。').join()}\n\n',
  );
  var offset = 0;
  final chapters = <Chapter>[];
  for (var i = 0; i < chunks.length; i++) {
    final title = '第${i + 1}章 测试';
    chapters.add(
      Chapter(
        title: title,
        start: offset,
        end: offset + chunks[i].length,
        headingEnd: offset + title.length,
      ),
    );
    offset += chunks[i].length;
  }
  return BookDocument(
    title: '测试',
    author: '',
    text: chunks.join(),
    chapters: chapters,
  );
}

BookRecord fixtureBook() => BookRecord(
  id: List.filled(64, 'b').join(),
  title: '测试',
  author: '',
  format: 'TXT',
  length: fixtureDocument().text.length,
  importedAt: 1,
);

class _TestPlatform extends PlatformService {
  int minimized = 0;
  @override
  Future<void> appearance(String theme) async {}
  @override
  Future<void> minimize() async {
    minimized++;
  }
}

class _Repository extends LibraryRepository {
  _Repository() : super(Directory.systemTemp);
  @override
  Future<Map<String, dynamic>?> load() async => {
    'books': [fixtureBook().toJson()],
    'settings': const ReaderSettings().toJson(),
    'fonts': <Map<String, dynamic>>[],
    'pin': null,
  };
  @override
  Future<List<ReaderFont>> recoverFonts(
    List<ReaderFont> catalog, {
    String? selectedId,
    String? selectedName,
  }) async => catalog;
  @override
  Future<void> save(Map<String, dynamic> snapshot) async {}
  @override
  Future<BookDocument> open(BookRecord book) async => fixtureDocument();
}

class _UpgradeRepository extends _Repository {
  _UpgradeRepository(this.record, this.previous, this.next);
  final BookRecord record;
  final BookDocument previous, next;
  BookDocument? replaced;
  Map<String, dynamic>? saved;
  @override
  Future<Map<String, dynamic>?> load() async => {
    'books': [record.toJson()],
    'settings': const ReaderSettings().toJson(),
    'fonts': <Map<String, dynamic>>[],
    'pin': null,
  };
  @override
  Future<BookDocument> open(BookRecord book) async => previous;
  @override
  Future<BookDocument?> parseOriginal(BookRecord book) async => next;
  @override
  Future<void> replaceDocument(String id, BookDocument doc) async {
    replaced = doc;
  }

  @override
  Future<void> save(Map<String, dynamic> snapshot) async {
    saved = snapshot;
  }
}

Uint8List mobiFixture(String html) {
  final text = utf8.encode(html);
  const first = 96, header = 248;
  final bytes = Uint8List(first + header + text.length),
      data = ByteData(first + header + text.length);
  bytes.setRange(60, 68, ascii.encode('BOOKMOBI'));
  data.setUint16(76, 2);
  data.setUint32(78, first);
  data.setUint32(86, first + header);
  data.setUint16(first, 1);
  data.setUint32(first + 4, text.length);
  data.setUint16(first + 8, 1);
  data.setUint16(first + 10, 4096);
  data.setUint32(first + 20, 232);
  data.setUint32(first + 24, 2);
  data.setUint32(first + 28, 65001);
  data.setUint32(first + 36, 6);
  bytes.setRange(
    68,
    first + header,
    data.buffer.asUint8List().sublist(68, first + header),
  );
  bytes.setRange(first + 16, first + 20, ascii.encode('MOBI'));
  bytes.setRange(first + header, bytes.length, text);
  return bytes;
}
