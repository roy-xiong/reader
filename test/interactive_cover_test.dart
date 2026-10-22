import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/domain/models.dart';
import 'package:reader/domain/page_turn_effect.dart';
import 'package:reader/domain/pagination.dart';
import 'package:reader/ui/app_model.dart';
import 'package:reader/ui/page_turn_transition.dart';
import 'package:reader/ui/reader_page.dart';
import 'package:reader/ui/reader_pager.dart';
import 'package:reader/ui/reader_screen.dart';

void main() {
  for (final forward in [true, false]) {
    testWidgets('慢拖跟手，未松手不提交，越过阈值后提交一次：$forward', (tester) async {
      final key = GlobalKey<_PagerHarnessState>();
      await tester.pumpWidget(_PagerHarness(key: key));
      final rect = tester.getRect(find.byType(ReaderPager));
      final gesture = await tester.startGesture(rect.center);
      for (var i = 0; i < 5; i++) {
        await gesture.moveBy(Offset(forward ? -24 : 24, 0));
        await tester.pump(const Duration(milliseconds: 180));
      }
      final transition = tester.widget<PageTurnTransition>(
        find.byType(PageTurnTransition),
      );
      expect(transition.forward, forward);
      expect(transition.progress, closeTo(120 / rect.width, .01));
      expect(transition.linearProgress, isTrue);
      expect(key.currentState!.index, 1);
      expect(key.currentState!.commits, 0);
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(key.currentState!.index, forward ? 2 : 0);
      expect(key.currentState!.commits, 1);
      expect(find.byType(PageTurnTransition), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('小距离慢拖与系统取消均回弹，下一次拖动仍可翻页', (tester) async {
    final key = GlobalKey<_PagerHarnessState>();
    await tester.pumpWidget(_PagerHarness(key: key));
    final rect = tester.getRect(find.byType(ReaderPager));
    for (final cancel in [false, true]) {
      final gesture = await tester.startGesture(rect.center);
      await gesture.moveBy(Offset(cancel ? -150 : -45, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PageTurnTransition), findsOneWidget);
      if (cancel) {
        await gesture.cancel();
      } else {
        await gesture.up();
      }
      await tester.pumpAndSettle();
      expect(key.currentState!.index, 1);
      expect(key.currentState!.commits, 0);
      expect(key.currentState!.pager.currentState!.isTurning, isFalse);
    }
    await tester.drag(find.byType(ReaderPager), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(key.currentState!.index, 2);
    expect(key.currentState!.commits, 1);
  });

  testWidgets('拖动中跨过原点反向，按最终方向翻页', (tester) async {
    final key = GlobalKey<_PagerHarnessState>();
    await tester.pumpWidget(_PagerHarness(key: key));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ReaderPager)),
    );
    await gesture.moveBy(const Offset(-65, 0));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveBy(const Offset(200, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester
          .widget<PageTurnTransition>(find.byType(PageTurnTransition))
          .forward,
      isFalse,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(key.currentState!.index, 0);
    expect(key.currentState!.commits, 1);
  });

  testWidgets('异步预排版未完成就退出，不更新已销毁组件', (tester) async {
    final pending = Completer<ReaderPage?>();
    await tester.pumpWidget(_PagerHarness(preview: (_) => pending.future));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ReaderPager)),
    );
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(_page(2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('书首边界及禁用状态均不会误提交', (tester) async {
    final key = GlobalKey<_PagerHarnessState>();
    await tester.pumpWidget(_PagerHarness(key: key, initial: 0));
    await tester.drag(find.byType(ReaderPager), const Offset(180, 0));
    await tester.pumpAndSettle();
    expect(key.currentState!.index, 0);
    expect(key.currentState!.commits, 0);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ReaderPager)),
    );
    await gesture.moveBy(const Offset(-140, 0));
    await tester.pump();
    key.currentState!.disable();
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(key.currentState!.index, 0);
    expect(key.currentState!.commits, 0);
    expect(find.byType(PageTurnTransition), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('纵向跟手不被横向识别器的取消回调中断', (tester) async {
    final key = GlobalKey<_PagerHarnessState>();
    await tester.pumpWidget(_PagerHarness(key: key, effect: 'vertical'));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ReaderPager)),
    );
    await gesture.moveBy(const Offset(0, -110));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PageTurnTransition), findsOneWidget);
    expect(key.currentState!.commits, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(key.currentState!.index, 2);
    expect(key.currentState!.commits, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('提交时保留手势开始时预测的背景，不提前显示下一张照片', (tester) async {
    final pause = Completer<void>();
    final key = GlobalKey<_PagerHarnessState>();
    await tester.pumpWidget(_PagerHarness(key: key, commitPause: pause));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ReaderPager)),
    );
    await gesture.moveBy(const Offset(-160, 0));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(key.currentState!.commits, 1);
    final scene = tester.widget<PageTurnTransition>(
      find.byType(PageTurnTransition),
    );
    expect(scene.previousBackground!.key, const ValueKey('paper-0'));
    expect(scene.currentBackground!.key, const ValueKey('paper-1'));
    pause.complete();
    await tester.pumpAndSettle();
    expect(find.byType(PageTurnTransition), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final opacity in [1.0, .5, 0.0]) {
    testWidgets('纸面覆盖包含底色及留白，旧页下沉，透明度不叠加：$opacity', (tester) async {
      final key = GlobalKey();
      final oldColor = const Color(0xffff0000).withValues(alpha: opacity);
      final newColor = const Color(0xff0000ff).withValues(alpha: opacity);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 400,
                height: 300,
                child: PageTurnTransition(
                  effect: PageTurnEffect.cover,
                  previous: _page(0),
                  current: _page(1),
                  progress: .5,
                  linearProgress: true,
                  forward: true,
                  background: newColor,
                  padding: const EdgeInsets.all(24),
                  previousBackground: ColoredBox(color: oldColor),
                  currentBackground: ColoredBox(color: newColor),
                ),
              ),
            ),
          ),
        ),
      );
      final scale = tester.widget<Transform>(
        find.byKey(const ValueKey('cover-underlay-scale')),
      );
      final offset = tester.widget<Transform>(
        find.byKey(const ValueKey('cover-underlay-offset')),
      );
      expect(scale.transform.entry(0, 0), closeTo(.9825, .0001));
      expect(offset.transform.entry(1, 3), 5);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final rgba = (await image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          ))!;
          // 新页左边的 24px 留白也带纸色，不能只移动字形。
          for (final x in [210, 300]) {
            final pixel = (100 * 400 + x) * 4;
            expect(
              rgba.getUint8(pixel + 3),
              closeTo((opacity * 255).round(), 1),
            );
            if (opacity > 0) {
              expect(rgba.getUint8(pixel), lessThan(3));
              expect(rgba.getUint8(pixel + 2), greaterThan(252));
            }
          }
        } finally {
          image.dispose();
        }
      });
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('实际阅读跨章：预览和回弹不改进度，确认后定位相邻章节', (tester) async {
    final repo = _Repository();
    final model = AppModel(repo, _Platform());
    final key = GlobalKey<ReaderScreenState>();
    await model.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(
          key: key,
          model: model,
          book: model.books.single,
          openSettings: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(key.currentState!.pages.length, 1);
    final original = model.books.single.offset;
    final rect = tester.getRect(find.byType(ReaderPager));
    final small = await tester.startGesture(rect.center);
    await small.moveBy(const Offset(-50, 0));
    await tester.pumpAndSettle();
    expect(find.byType(PageTurnTransition), findsOneWidget);
    expect(model.books.single.offset, original);
    await small.up();
    await tester.pumpAndSettle();
    expect(model.books.single.offset, original);
    final large = await tester.startGesture(rect.center);
    await large.moveBy(Offset(-rect.width * .35, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(model.books.single.offset, original);
    await large.up();
    await tester.pumpAndSettle();
    expect(model.books.single.offset, repo.document.chapters[1].start);
    expect(key.currentState!.current!.start, repo.document.chapters[1].start);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });
}

ReaderPage _page(int index) => ReaderPage(
  page: _samplePages[index],
  width: 352,
  style: const TextStyle(fontSize: 20, color: Colors.black),
  scaler: TextScaler.noScaling,
);
final _samplePages = List.generate(
  3,
  (i) => ReadingPage(i * 100, (i + 1) * 100, [PageFragment('PAGE $i', 20, 30)]),
);

class _PagerHarness extends StatefulWidget {
  const _PagerHarness({
    super.key,
    this.initial = 1,
    this.preview,
    this.effect = 'cover',
    this.commitPause,
  });
  final int initial;
  final Future<ReaderPage?> Function(bool)? preview;
  final String effect;
  final Completer<void>? commitPause;
  @override
  State<_PagerHarness> createState() => _PagerHarnessState();
}

class _PagerHarnessState extends State<_PagerHarness> {
  final pager = GlobalKey<ReaderPagerState>();
  late int index = widget.initial;
  int commits = 0;
  int paper = 0;
  bool enabled = true;
  void disable() => setState(() => enabled = false);
  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 400,
          height: 300,
          child: ReaderPager(
            key: pager,
            effect: widget.effect,
            background: Colors.white,
            backgroundLayer: ColoredBox(
              key: ValueKey('paper-$paper'),
              color: Colors.white,
            ),
            previewBackgroundLayer: ColoredBox(
              key: ValueKey('paper-${paper + 1}'),
              color: Colors.white,
            ),
            enabled: enabled,
            pagePadding: const EdgeInsets.all(24),
            onPreview:
                widget.preview ??
                (forward) async {
                  final target = index + (forward ? 1 : -1);
                  return target < 0 || target >= _samplePages.length
                      ? null
                      : _page(target);
                },
            onTurn: (forward) async {
              final target = index + (forward ? 1 : -1);
              if (target < 0 || target >= _samplePages.length) return false;
              setState(() {
                index = target;
                commits++;
                paper++;
              });
              await widget.commitPause?.future;
              return true;
            },
            onToggle: () {},
            child: _page(index),
          ),
        ),
      ),
    ),
  );
}

class _Repository extends LibraryRepository {
  _Repository() : super(Directory.systemTemp);
  static const first = '第一章 春风\n\n春风拂过窗前。\n\n';
  static const second = '第二章 月色\n\n月色洒落书页。\n\n';
  final document = BookDocument(
    title: '跨章手势测试',
    author: '',
    text: first + second,
    chapters: [
      Chapter(title: '第一章 春风', start: 0, end: first.length, headingEnd: 6),
      Chapter(
        title: '第二章 月色',
        start: first.length,
        end: first.length + second.length,
        headingEnd: first.length + 6,
      ),
    ],
  );
  late final book = BookRecord(
    id: 'c' * 64,
    title: document.title,
    author: '',
    format: 'TXT',
    length: document.text.length,
    importedAt: 1,
  );
  @override
  Future<Map<String, dynamic>?> load() async => {
    'settings': const ReaderSettings(pageEffect: 'cover').toJson(),
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
  Future<BookDocument> open(BookRecord book) async => document;
}

class _Platform extends PlatformService {
  @override
  Future<void> appearance(String theme) async {}
}
