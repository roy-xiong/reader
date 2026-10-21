import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/main.dart';
import 'package:reader/ui/app_model.dart';
import 'package:reader/ui/lock_screen.dart';
import 'package:reader/ui/settings_screen.dart';
import 'package:reader/ui/wifi_upload_screen.dart';

void main() {
  testWidgets(
    'macOS 书架、设置、颜色弹窗、上传页和密码页 Esc 均最小化并保留页面',
    (tester) async {
      final platform = _Platform();
      final model = AppModel(_Repository(), platform);
      await model.initialize();
      await tester.pumpWidget(ReaderApp(model: model));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(platform.minimized, 1);
      unawaited(platform.menu!.call('openSettings'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(platform.minimized, 2);
      expect(find.byType(SettingsScreen), findsOneWidget);
      await tester.tap(find.text('选择颜色').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hex-color-input')));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(platform.minimized, 3);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      final upload = find.text('Wi-Fi 上传书籍和字体');
      await tester.scrollUntilVisible(upload, 350);
      await tester.ensureVisible(upload);
      await tester.pumpAndSettle();
      await tester.tap(upload);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(platform.minimized, 4);
      expect(find.byType(WifiUploadScreen), findsOneWidget);
      model.locked = true;
      model.changed();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(platform.minimized, 5);
      expect(model.locked, isTrue);
      expect(find.byType(PinPad), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(platform.minimized, 5, reason: '页面退出后注销全局按键处理器');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('密码支持没有 character 的数字键、小键盘、退格与回车，等待期间不会重复提交', (tester) async {
    final model = AppModel(_Repository(), _Platform());
    final submitted = <String>[];
    var pending = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinPad(
            model: model,
            title: '输入密码',
            subtitle: '键盘输入测试',
            onSubmit: (pin) {
              submitted.add(pin);
              return pending.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final key in [
      LogicalKeyboardKey.numpad0,
      LogicalKeyboardKey.numpad1,
      LogicalKeyboardKey.backspace,
      LogicalKeyboardKey.numpad2,
      LogicalKeyboardKey.numpad3,
      LogicalKeyboardKey.enter,
    ]) {
      await tester.sendKeyEvent(key);
    }
    expect(submitted, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad4);
    await tester.pump();
    expect(submitted, ['0234']);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
    expect(submitted, ['0234']);
    pending.complete('密码错误，请重试');
    await tester.pumpAndSettle();
    pending = Completer<String?>();
    await tester.tap(find.widgetWithText(FilledButton, '1'));
    for (final key in [
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
    ]) {
      await tester.sendKeyEvent(key);
    }
    await tester.pump();
    expect(submitted, ['0234', '1234']);
    pending.complete(null);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });

  testWidgets(
    'macOS 设置中直接导入本地书籍，调用文件面板而不是 Wi-Fi 入口',
    (tester) async {
      final platform = _Platform();
      final model = AppModel(_Repository(), platform);
      await model.initialize();
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(model: model)));
      final local = find.byKey(const ValueKey('local-book-import'));
      await tester.scrollUntilVisible(local, 250);
      await tester.ensureVisible(local);
      await tester.pumpAndSettle();
      await tester.tap(local);
      await tester.pumpAndSettle();
      expect(platform.bookPicks, 1);
      expect(platform.fontPicks, 0);
      expect(find.byType(WifiUploadScreen), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

class _Platform extends PlatformService {
  int minimized = 0, bookPicks = 0, fontPicks = 0;
  Future<void> Function(String)? menu;
  @override
  void onMenu(Future<void> Function(String) callback) {
    menu = callback;
  }

  @override
  Future<void> minimize() async {
    minimized++;
  }

  @override
  Future<void> appearance(String theme) async {}
  @override
  Future<List<String>> pick({bool folder = false, bool font = false}) async {
    if (font) {
      fontPicks++;
    } else {
      bookPicks++;
    }
    return [];
  }

  @override
  Future<void> discard(List<String> paths) async {}
}

class _Repository extends LibraryRepository {
  _Repository() : super(Directory.systemTemp);
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> snapshot) async {}
}
