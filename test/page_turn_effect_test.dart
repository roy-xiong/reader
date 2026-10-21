import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/domain/models.dart';
import 'package:reader/domain/page_turn_effect.dart';
import 'package:reader/domain/pagination.dart';
import 'package:reader/ui/app_model.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/ui/settings/settings_category.dart';
import 'package:reader/ui/settings/settings_detail_screen.dart';
import 'package:reader/ui/page_ink_snapshot.dart';
import 'package:reader/ui/page_turn_transition.dart';
import 'package:reader/ui/reader_page.dart';
import 'package:reader/ui/reader_pager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('所有效果持久化兼容旧版，未知设置安全回退', () {
    for (final effect in PageTurnEffect.values) {
      final restored = ReaderSettings.fromJson(
        ReaderSettings(pageEffect: effect.id).toJson(),
      );
      expect(restored.pageEffect, effect.id);
    }
    expect(
      ReaderSettings.fromJson({'pageEffect': 'unknown'}).pageEffect,
      'cover',
    );
    expect(ReaderSettings.fromJson({'pageEffect': 'none'}).pageEffect, 'none');
  });

  for (final effect in PageTurnEffect.values) {
    testWidgets('${effect.label}：前后翻页、连续输入不重复跳页、书首不切页', (tester) async {
      final harness = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: harness, effect: effect));
      final pager = harness.currentState!.pager;
      await tester.tapAt(
        tester.getRect(find.byType(ReaderPager)).centerRight -
            const Offset(20, 0),
      );
      await tester.pump();
      // 动画期间追加输入不会多推进一页。
      await pager.currentState?.turn(true);
      await _settle(tester, pager);
      expect(harness.currentState?.index, 1);
      expect(harness.currentState?.moves, 1);
      expect(find.byType(PageTurnTransition), findsNothing);
      await tester.tapAt(
        tester.getRect(find.byType(ReaderPager)).centerLeft +
            const Offset(20, 0),
      );
      await _settle(tester, pager);
      expect(harness.currentState?.index, 0);
      await tester.tapAt(
        tester.getRect(find.byType(ReaderPager)).centerLeft +
            const Offset(20, 0),
      );
      await _settle(tester, pager);
      expect(harness.currentState?.index, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('系统关闭动画时粒子效果直接换页，退出时没有悬挂任务', (tester) async {
    final harness = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      _Harness(
        key: harness,
        effect: PageTurnEffect.particles,
        reducedMotion: true,
      ),
    );
    await tester.tapAt(
      tester.getRect(find.byType(ReaderPager)).centerRight -
          const Offset(20, 0),
    );
    await tester.pumpAndSettle();
    expect(harness.currentState?.index, 1);
    expect(find.byType(PageTurnTransition), findsNothing);
    expect(harness.currentState?.pager.currentState?.isTurning, isFalse);
    await tester.pumpWidget(_Harness(effect: PageTurnEffect.particles));
    await tester.tapAt(
      tester.getRect(find.byType(ReaderPager)).centerRight -
          const Offset(20, 0),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('卷页和粒子录制真实墨迹，透明底与动画中间帧可绘制', (tester) async {
    const size = Size(340, 360);
    final first = _page(0), next = _page(1);
    final snapshots = await tester.runAsync(
      () async => [
        await PageInkSnapshot.capture(first, size, particles: true, ink: true),
        await PageInkSnapshot.capture(next, size, particles: true, ink: true),
      ],
    );
    expect(snapshots, isNotNull);
    final inks = snapshots!;
    expect(inks.first.particleCount, inExclusiveRange(0, 18001));
    final key = GlobalKey();
    final directory = Directory('build/qa/page-turn')
      ..createSync(recursive: true);
    for (final effect in [
      PageTurnEffect.particles,
      PageTurnEffect.curl,
      PageTurnEffect.ink,
    ]) {
      for (var frame = 0; frame <= 8; frame++) {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: PageTurnTransition(
                    effect: effect,
                    previous: first,
                    current: next,
                    progress: frame / 8,
                    forward: true,
                    background: Colors.transparent,
                    previousInk: inks.first,
                    currentInk: inks.last,
                  ),
                ),
              ),
            ),
          ),
        );
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final result = await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final rgba = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '${directory.path}/${effect.id}-$frame.png',
            ).writeAsBytes(png!.buffer.asUint8List());
            return rgba!;
          } finally {
            image.dispose();
          }
        });
        // 背景右下角始终透明，不允许粒子效果把整页背景变为不透明。
        expect(
          result!.getUint8(
            (size.width.toInt() * size.height.toInt() - 1) * 4 + 3,
          ),
          0,
        );
        if (frame == 0 ||
            frame == 8 ||
            ((effect == PageTurnEffect.particles ||
                    effect == PageTurnEffect.ink) &&
                frame == 4)) {
          var inkPixels = 0;
          for (var offset = 3; offset < result.lengthInBytes; offset += 4) {
            if (result.getUint8(offset) > 0) {
              inkPixels++;
            }
          }
          expect(
            inkPixels,
            greaterThan(0),
            reason: '${effect.id} 第 $frame 帧没有墨迹',
          );
        }
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    for (final ink in inks) {
      ink.dispose();
    }
  });

  testWidgets('统一预览试翻支持小窗口，效果切换后不残留旧动画', (tester) async {
    tester.view.physicalSize = const Size(320, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = AppModel(_PreviewRepository(), PlatformService());
    model.updateSettings(model.settings.copyWith(pageEffect: 'card'));
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsDetailScreen(
          model: model,
          category: SettingsCategory.pageTurn,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('play-page-effect')));
    await tester.pump(const Duration(milliseconds: 80));
    model.updateSettings(model.settings.copyWith(pageEffect: 'fade'));
    await tester.pumpAndSettle();
    expect(find.byType(PageTurnTransition), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });
}

Future<void> _settle(
  WidgetTester tester,
  GlobalKey<ReaderPagerState> pager,
) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 3)),
    );
    if (pager.currentState?.isTurning != true) {
      break;
    }
  }
  expect(pager.currentState?.isTurning, isFalse);
  await tester.pumpAndSettle();
}

ReaderPage _page(int index) => ReaderPage(
  page: ReadingPage(index * 100, (index + 1) * 100, [
    PageFragment(
      index == 0 ? 'READING' : 'NEXT PAGE',
      index == 0 ? 10 : 38,
      30,
      isHeading: true,
    ),
    PageFragment(
      index == 0 ? '文字化作微尘\n轻轻散开，故事仍在继续。' : '光落在字里行间\n另一页，另一种风景。',
      index == 0 ? 80 : 120,
      100,
    ),
  ]),
  width: 340,
  style: const TextStyle(fontSize: 22, height: 1.7, color: Color(0xff999999)),
  scaler: TextScaler.noScaling,
);

class _Harness extends StatefulWidget {
  const _Harness({super.key, required this.effect, this.reducedMotion = false});
  final PageTurnEffect effect;
  final bool reducedMotion;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final pager = GlobalKey<ReaderPagerState>();
  int index = 0, moves = 0;
  @override
  Widget build(BuildContext context) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: widget.reducedMotion),
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: 340,
            height: 360,
            child: ReaderPager(
              key: pager,
              effect: widget.effect.id,
              background: Colors.transparent,
              onToggle: () {},
              onTurn: (forward) async {
                final target = index + (forward ? 1 : -1);
                if (target < 0 || target > 1) {
                  return false;
                }
                setState(() {
                  index = target;
                  moves++;
                });
                return true;
              },
              child: _page(index),
            ),
          ),
        ),
      ),
    ),
  );
}

class _PreviewRepository extends LibraryRepository {
  _PreviewRepository() : super(Directory.systemTemp);
  @override
  Future<void> save(Map<String, dynamic> snapshot) async {}
}
