import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/book_parser.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/domain/models.dart';
import 'package:reader/domain/pagination.dart';
import 'package:reader/ui/app_model.dart';
import 'package:reader/ui/lock_screen.dart';
import 'package:reader/ui/reader_screen.dart';
import 'package:reader/ui/settings_screen.dart';
import 'package:reader/ui/shelf_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('电子书解析', () {
    test('UTF-8、GBK、UTF-16 与章节切分', () async {
      const text = '第一章 春天\n\n你好，世界。\n\n第二章 夏天\n\n新的旅程。';
      for (final bytes in [
        utf8.encode(text),
        const GbkCodec().encode(text),
        [
          255,
          254,
          ...text.codeUnits.expand((c) => [c & 255, c >> 8]),
        ],
      ]) {
        final book = await BookParser.parseBytes(
          Uint8List.fromList(bytes),
          '测试.txt',
        );
        expect(book.text, contains('你好，世界'));
        expect(book.chapters.length, 2);
        expect(book.chapters.last.title, contains('第二章'));
      }
    });
    test('EPUB 使用 spine 顺序并保留段落和元信息', () async {
      final zip = Archive();
      void add(String name, String text) {
        final bytes = utf8.encode(text);
        zip.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      add(
        'META-INF/container.xml',
        '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
      );
      add(
        'OPS/book.opf',
        '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>测试书籍</dc:title><dc:creator>测试作者</dc:creator></metadata><manifest><item id="b" href="b.xhtml" media-type="application/xhtml+xml"/><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>',
      );
      add(
        'OPS/a.xhtml',
        '<html><body><h1>开篇</h1><p>先读这一段。</p><p>再读这一段。</p><script>隐藏脚本</script></body></html>',
      );
      add('OPS/b.xhtml', '<html><body><h1>尾声</h1><p>最后一段。</p></body></html>');
      final book = await BookParser.parseBytes(
        Uint8List.fromList(ZipEncoder().encode(zip)),
        'sample.epub',
      );
      expect(book.title, '测试书籍');
      expect(book.author, '测试作者');
      expect(book.text.indexOf('先读'), lessThan(book.text.indexOf('最后')));
      expect(book.text, isNot(contains('隐藏脚本')));
      expect(book.text, contains('先读这一段。\n\n再读这一段。'));
    });
    test('MOBI 无压缩与 PalmDOC 字面压缩均能读取', () async {
      for (final compressed in [false, true]) {
        final book = await BookParser.parseBytes(
          _mobi(compressed: compressed),
          'mobi测试.mobi',
        );
        expect(book.text, contains('Hello reader'));
        expect(book.text, contains('第二段文字'));
      }
    });
    test('MOBI 加密标记与损坏文件给出明确失败', () async {
      final bytes = _mobi();
      final header = ByteData.sublistView(bytes);
      header.setUint16(header.getUint32(78) + 12, 2);
      await expectLater(
        BookParser.parseBytes(bytes, 'locked.mobi'),
        throwsFormatException,
      );
      await expectLater(
        BookParser.parseBytes(Uint8List(10), 'broken.mobi'),
        throwsFormatException,
      );
      await expectLater(
        BookParser.parseBytes(Uint8List(0), 'empty.txt'),
        throwsFormatException,
      );
    });
    test('长章节切片不拆断 emoji，序列化后保持连续', () async {
      final text = List.filled(10000, '中文😀').join();
      final doc = await BookParser.parseBytes(
        Uint8List.fromList(utf8.encode(text)),
        '长篇.txt',
      );
      final restored = BookDocument.fromJson(doc.toJson());
      expect(restored.text.replaceAll('\n', ''), text);
      for (var i = 1; i < doc.chapters.length; i++) {
        expect(doc.chapters[i].start, doc.chapters[i - 1].end);
      }
    });
  });
  test('原子保存、损坏主文件时恢复备份与密码校验', () async {
    final dir = await Directory.systemTemp.createTemp('reader_repository_');
    try {
      final repo = LibraryRepository(dir);
      final pin = await PinService.create('0123');
      final state = {
        'version': 1,
        'books': [_book.toJson()],
        'settings': const ReaderSettings(backgroundOpacity: 0).toJson(),
        'pin': pin,
      };
      await repo.save(state);
      await File('${dir.path}/library.json').writeAsString('{broken');
      final recovered = await repo.load();
      expect(recovered?['pin'], pin);
      expect((recovered?['settings'] as Map)['backgroundOpacity'], 0);
      expect(await PinService.verify('0123', pin), isTrue);
      expect(await PinService.verify('0124', pin), isFalse);
      await Future.wait([
        repo.save(state),
        repo.save({...state, 'version': 2}),
      ]);
      expect((await repo.load())?['version'], 2);
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('分页保持所有正文连续，调字号和窗口后定位仍有效', () async {
    final doc = _document;
    for (final size in [
      const Size(220, 210),
      const Size(680, 540),
      const Size(960, 720),
    ]) {
      final pages = await Pagination.layout(
        document: doc,
        chapter: doc.chapters.first,
        width: size.width,
        height: size.height,
        style: const TextStyle(fontSize: 23, height: 1.8, letterSpacing: 1.2),
        paragraphSpacing: 18,
        scaler: TextScaler.noScaling,
      );
      expect(pages.first.start, 0);
      expect(pages.last.end, doc.text.length);
      for (var i = 1; i < pages.length; i++) {
        expect(pages[i].start, pages[i - 1].end);
      }
      final drawn = pages.expand((p) => p.fragments).map((f) => f.text).join();
      expect(drawn, doc.text.replaceAll('\n', ''));
      for (final page in pages) {
        for (final f in page.fragments) {
          expect(f.y + f.height, lessThanOrEqualTo(size.height + .1));
        }
      }
    }
  });
  for (final size in [
    const Size(320, 480),
    const Size(760, 680),
    const Size(1400, 900),
  ]) {
    testWidgets('书架、设置、阅读适配 ${size.width}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = AppModel(_MemoryRepository(), PlatformService());
      await model.initialize();
      final boundary = GlobalKey();
      Future<void> show(Widget screen) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: RepaintBoundary(key: boundary, child: screen),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      await show(
        ShelfScreen(
          model: model,
          openBook: (_) async {},
          openSettings: () async {},
        ),
      );
      if (size.width == 1400) {
        await _capture(boundary, 'shelf-wide');
      }
      await show(SettingsScreen(model: model));
      expect(find.text('阅读背景不透明度'), findsOneWidget);
      if (size.width == 1400) {
        await _capture(boundary, 'settings-wide');
      }
      await show(
        ReaderScreen(model: model, book: _book, openSettings: () async {}),
      );
      expect(find.byType(Slider), findsNothing);
      expect(find.text('阅读背景不透明度'), findsNothing);
      if (size.width == 1400) {
        await _capture(boundary, 'reader-wide');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    });
  }
  testWidgets('数字密码键盘固定显示 0–9，提交前导零', (tester) async {
    final model = AppModel(_MemoryRepository(), PlatformService());
    String? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinPad(
            model: model,
            title: '输入密码',
            subtitle: '测试',
            onSubmit: (value) async {
              submitted = value;
              return null;
            },
          ),
        ),
      ),
    );
    for (var i = 0; i <= 9; i++) {
      expect(find.text('$i'), findsOneWidget);
    }
    for (final value in ['0', '1', '2', '3']) {
      await tester.tap(find.text(value));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(submitted, '0123');
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });
}

final _text =
    '${List.generate(100, (i) => '第 $i 行。阅读让时间慢下来，窗外是风，纸上是远方。😀').join('\n\n')}\n\n';
final _document = BookDocument(
  title: '阅读的时光',
  author: 'Reader',
  text: _text,
  chapters: [Chapter(title: '第一章', start: 0, end: _text.length)],
);
final _book = BookRecord(
  id: List.filled(64, 'a').join(),
  title: '阅读的时光',
  author: 'Reader',
  format: 'TXT',
  length: _text.length,
  importedAt: 1,
);

class _MemoryRepository extends LibraryRepository {
  _MemoryRepository() : super(Directory.systemTemp);
  @override
  Future<Map<String, dynamic>?> load() async => {
    'books': [_book.toJson()],
    'settings': const ReaderSettings().toJson(),
    'pin': null,
  };
  @override
  Future<void> save(Map<String, dynamic> snapshot) async {}
  @override
  Future<BookDocument> open(BookRecord book) async => _document;
}

Future<void> _capture(GlobalKey key, String name) async {
  final boundary =
      key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
  final image = await boundary?.toImage();
  if (image == null) {
    return;
  }
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  if (bytes != null) {
    Directory('build/qa').createSync(recursive: true);
    File('build/qa/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
  }
  image.dispose();
}

/// 最小 MOBI6 样本由测试自行生成，避免引入任何第三方书籍内容。
Uint8List _mobi({bool compressed = false}) {
  final text = utf8.encode(
    '<html><body><h1>Hello reader</h1><p>第二段文字。</p></body></html>',
  );
  final encoded = <int>[];
  if (compressed) {
    for (var i = 0; i < text.length; i += 8) {
      final end = (i + 8).clamp(0, text.length);
      encoded.add(end - i);
      encoded.addAll(text.sublist(i, end));
    }
  } else {
    encoded.addAll(text);
  }
  const first = 96, record0 = 248;
  final result = Uint8List(first + record0 + encoded.length);
  final data = ByteData.sublistView(result);
  result.setRange(0, 4, ascii.encode('Test'));
  result.setRange(60, 68, ascii.encode('BOOKMOBI'));
  data.setUint16(76, 2);
  data.setUint32(78, first);
  data.setUint32(86, first + record0);
  data.setUint16(first, compressed ? 2 : 1);
  data.setUint32(first + 4, text.length);
  data.setUint16(first + 8, 1);
  data.setUint16(first + 10, 4096);
  result.fillRange(first + 16, first + record0, 255);
  result.setRange(first + 16, first + 20, ascii.encode('MOBI'));
  data.setUint32(first + 20, 232);
  data.setUint32(first + 24, 2);
  data.setUint32(first + 28, 65001);
  data.setUint32(first + 32, 123);
  data.setUint32(first + 36, 6);
  for (final offset in [
    84,
    88,
    92,
    96,
    100,
    104,
    108,
    112,
    128,
    144,
    148,
    164,
    168,
    172,
    176,
    180,
    184,
    188,
    192,
    196,
    200,
    204,
    208,
    212,
    216,
    220,
    224,
    228,
    232,
    236,
    240,
    244,
  ]) {
    data.setUint32(first + offset, 0);
  }
  data.setUint32(first + 108, 0xffffffff);
  result.setRange(first + record0, result.length, encoded);
  return result;
}
