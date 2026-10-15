import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/domain/models.dart';
import 'package:reader/main.dart';
import 'package:reader/ui/app_model.dart';
import 'package:reader/ui/lock_screen.dart';

void main() {
  test('应用图标不再越出圆角底板', () async {
    final codec = await ui.instantiateImageCodec(
      await File(
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png',
      ).readAsBytes(),
    );
    final frame = await codec.getNextFrame();
    try {
      final pixels = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (pixels == null) {
        throw StateError('图标无法解码');
      }
      for (var y = 0; y < frame.image.height; y++) {
        for (final x in [0, frame.image.width - 1]) {
          expect(pixels.getUint8((y * frame.image.width + x) * 4 + 3), 0);
        }
      }
    } finally {
      frame.image.dispose();
      codec.dispose();
    }
  });

  test('字体存储接受超过 20 MB 和 64 MB 的文件', () async {
    final directory = await Directory.systemTemp.createTemp(
      'reader_large_font_',
    );
    try {
      final file = File('${directory.path}/large.ttf');
      final handle = await file.open(mode: FileMode.write);
      await handle.writeFrom([0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
      await handle.truncate(75 * 1024 * 1024);
      await handle.close();
      final repository = LibraryRepository(
        Directory('${directory.path}/library'),
      );
      final id = await repository.importFont(file.path);
      expect(await repository.fontFile(id).length(), 75 * 1024 * 1024);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  for (final size in [
    const Size(300, 288),
    const Size(300, 320),
    const Size(420, 600),
  ]) {
    testWidgets('密码键盘最后一行完整可见 ${size.width}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = AppModel(_PinRepository(), PlatformService());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PinPad(
              model: model,
              title: '输入密码',
              subtitle: '解锁你的私人书架',
              onSubmit: (_) async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final viewport = tester.getRect(find.byType(GridView));
      for (final finder in [
        find.widgetWithText(FilledButton, '0'),
        find.byType(FilledButton).last,
      ]) {
        final button = tester.getRect(finder);
        expect(button.bottom, lessThanOrEqualTo(viewport.bottom + .1));
        expect(button.top, greaterThanOrEqualTo(viewport.top - .1));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    });
  }

  testWidgets(
    'macOS 最小化恢复保持解锁，重新启动仍上锁',
    (tester) async {
      final model = AppModel(_PinRepository(), PlatformService());
      await tester.runAsync(model.initialize);
      expect(model.locked, isTrue);
      model.locked = false;
      await tester.pumpWidget(ReaderApp(model: model));
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(model.locked, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      final restarted = AppModel(_PinRepository(), PlatformService());
      await tester.runAsync(restarted.initialize);
      expect(restarted.locked, isTrue);
      restarted.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

class _PinRepository extends LibraryRepository {
  _PinRepository() : super(Directory.systemTemp);
  @override
  Future<Map<String, dynamic>?> load() async => {
    'books': <Map<String, dynamic>>[],
    'settings': const ReaderSettings().toJson(),
    'pin': {
      'salt': base64Encode(List.filled(16, 0)),
      'hash': base64Encode(List.filled(32, 0)),
      'iterations': PinService.iterations,
    },
  };
  @override
  Future<void> save(Map<String, dynamic> snapshot) async {}
}
