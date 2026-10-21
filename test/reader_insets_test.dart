import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/domain/models.dart';
import 'package:reader/domain/pagination.dart';
import 'package:reader/ui/app_model.dart';
import 'package:reader/ui/reader_page.dart';
import 'package:reader/ui/reader_screen.dart';

void main() {
  for (final size in [
    const Size(390, 780),
    const Size(1200, 800),
    const Size(740, 360),
  ]) {
    testWidgets('阅读区域四边留白一致 $size', (tester) async {
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
      final rect = tester.getRect(find.byType(ReaderPage));
      final left = rect.left,
          right = size.width - rect.right,
          top = rect.top,
          bottom = size.height - rect.bottom;
      expect(right, closeTo(left, .1));
      expect(top, closeTo(left, .1), reason: '顶留白 $top 应与左留白 $left 相同');
      expect(bottom, closeTo(left, .1), reason: '底部进度应放在留白内，不额外挤占正文');
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    });
  }
  test('续页末行仍两端对齐且排版上下文不计入正文', () async {
    final text = List.filled(
      100,
      'one two three four five six seven eight nine ',
    ).join();
    final doc = BookDocument(
      title: '分页',
      author: '',
      text: text,
      chapters: [Chapter(title: '', start: 0, end: text.length)],
    );
    const width = 221.0, style = TextStyle(fontSize: 18, height: 1.8);
    final pages = await Pagination.layout(
      document: doc,
      chapter: doc.chapters.first,
      width: width,
      height: 150,
      style: style,
      paragraphSpacing: 12,
      scaler: TextScaler.noScaling,
    );
    expect(
      pages.map((p) => p.fragments.map((f) => f.text).join()).join(),
      text,
    );
    final fragment = pages.first.fragments.last;
    expect(fragment.layoutTail, isNotEmpty);
    final painter = Pagination.textPainter(
      text: fragment.text + fragment.layoutTail,
      width: width,
      style: style,
      heading: false,
      scaler: TextScaler.noScaling,
    );
    try {
      final metrics = painter.computeLineMetrics();
      expect(metrics.length, greaterThan(1));
      // 排版保留行尾空格，空格的选择框可以超出行宽；检查最后一个实际字形。
      final end = fragment.text.trimRight().length;
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: end - 1, extentOffset: end),
      );
      expect(
        boxes.map((box) => box.right).reduce((a, b) => a > b ? a : b),
        closeTo(width, .01),
      );
      expect(pages.first.end, fragment.text.length);
    } finally {
      painter.dispose();
    }
  });
}

class _Repository extends LibraryRepository {
  _Repository() : super(Directory.systemTemp);
  final text = List.filled(100, '春风又绿江南岸，明月何时照我还。\n\n').join();
  late final book = BookRecord(
    id: 'a' * 64,
    title: '留白测试',
    author: '',
    format: 'TXT',
    length: text.length,
    importedAt: 1,
  );
  @override
  Future<Map<String, dynamic>?> load() async => {
    'books': [book.toJson()],
    'settings': const ReaderSettings(pageEffect: 'none').toJson(),
    'fonts': [],
  };
  @override
  Future<void> save(Map<String, dynamic> value) async {}
  @override
  Future<BookDocument> open(BookRecord record) async => BookDocument(
    title: book.title,
    author: '',
    text: text,
    chapters: [Chapter(title: book.title, start: 0, end: text.length)],
  );
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
