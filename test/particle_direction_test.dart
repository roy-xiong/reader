import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/domain/models.dart';
import 'package:reader/domain/page_turn_effect.dart';
import 'package:reader/domain/pagination.dart';
import 'package:reader/ui/app_model.dart';
import 'package:reader/ui/page_ink_snapshot.dart';
import 'package:reader/ui/page_turn_transition.dart';
import 'package:reader/ui/reader_page.dart';
import 'package:reader/ui/reader_pager.dart';
import 'package:reader/ui/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('新旧设置默认关闭方向感，开关状态可以保存和恢复', () {
    expect(const ReaderSettings().particleDirectional, isFalse);
    expect(
      ReaderSettings.fromJson({'pageEffect': 'particles'}).particleDirectional,
      isFalse,
    );
    final enabled = const ReaderSettings().copyWith(particleDirectional: true);
    expect(
      ReaderSettings.fromJson(enabled.toJson()).particleDirectional,
      isTrue,
    );
    expect(enabled.copyWith(fontSize: 25).particleDirectional, isTrue);
    expect(
      enabled.copyWith(particleDirectional: false).particleDirectional,
      isFalse,
    );
  });

  testWidgets('关闭方向感时前后翻页画面一致，开启后可恢复左右飘散', (tester) async {
    const size = Size(300, 320);
    ReaderPage page(String text, int offset) => ReaderPage(
      page: ReadingPage(offset, offset + 100, [PageFragment(text, 40, 100)]),
      width: size.width,
      style: const TextStyle(
        fontSize: 22,
        color: Color(0xff999999),
        height: 1.7,
      ),
      scaler: TextScaler.noScaling,
    );
    final previous = page('上一页文字\n散开后保留原阅读位置。', 0);
    final current = page('下一页故事\n在原地聚成新的文字。', 100);
    final snapshots = (await tester.runAsync(
      () async => [
        await PageInkSnapshot.capture(previous, size, particles: true),
        await PageInkSnapshot.capture(current, size, particles: true),
      ],
    ))!;
    final key = GlobalKey();
    Future<String> frame(
      double progress,
      bool forward,
      bool directional,
    ) async {
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
                  effect: PageTurnEffect.particles,
                  previous: previous,
                  current: current,
                  progress: progress,
                  forward: forward,
                  background: Colors.transparent,
                  particleDirectional: directional,
                  previousInk: snapshots.first,
                  currentInk: snapshots.last,
                ),
              ),
            ),
          ),
        ),
      );
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      return (await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final pixels = await image.toByteData();
          return sha256.convert(pixels!.buffer.asUint8List()).toString();
        } finally {
          image.dispose();
        }
      }))!;
    }

    for (final progress in [.25, .5, .75]) {
      expect(
        await frame(progress, true, false),
        await frame(progress, false, false),
        reason: '取消方向感后同一对正文的中间帧不应因前后翻页改变',
      );
      expect(
        await frame(progress, true, true),
        isNot(await frame(progress, false, true)),
        reason: '开启方向感后仍可使用原来的定向飘散效果',
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    for (final snapshot in snapshots) {
      snapshot.dispose();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置开关同步试翻，重新打开后保留选择', (tester) async {
    final repository = _Repository();
    final model = AppModel(repository, _Platform());
    await model.initialize();
    model.updateSettings(model.settings.copyWith(pageEffect: 'particles'));
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(model: model)));
    await tester.tap(find.byKey(const ValueKey('settings-pageTurn')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('particle-directional-switch'));
    await tester.scrollUntilVisible(toggle, 350);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(model.settings.particleDirectional, isTrue);
    final demo = find.byKey(const ValueKey('reading-style-preview'));
    await tester.ensureVisible(demo);
    await tester.pumpAndSettle();
    expect(
      tester.widget<ReaderPager>(find.byType(ReaderPager)).particleDirectional,
      isTrue,
    );
    await model.flush();
    final restored = AppModel(repository, _Platform());
    await restored.initialize();
    expect(restored.settings.particleDirectional, isTrue);
    model.updateSettings(model.settings.copyWith(pageEffect: 'fade'));
    await tester.pumpAndSettle();
    expect(toggle, findsNothing);
    expect(model.settings.particleDirectional, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    restored.dispose();
    model.dispose();
  });
}

class _Repository extends LibraryRepository {
  _Repository() : super(Directory.systemTemp);
  Map<String, dynamic>? saved;
  @override
  Future<Map<String, dynamic>?> load() async => saved;
  @override
  Future<void> save(Map<String, dynamic> snapshot) async {
    saved = snapshot;
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
}
