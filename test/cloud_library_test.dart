import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/data/cloud/cloud_crypto.dart';
import 'package:reader/ui/app_model.dart';
import 'package:reader/ui/cloud/cloud_progress_prompt.dart';
import 'package:reader/ui/cloud/cloud_sync_screen.dart';
import 'support/cloud_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('真实仓库双设备手动上传下载书籍，阅读进度自动入队，设置与密码不随之上传', () async {
    final dir = await Directory.systemTemp.createTemp('cloud_library');
    final remote = MemoryDav();
    AppModel make(String name) => AppModel(
      LibraryRepository(Directory('${dir.path}/$name')),
      _Platform(),
      cloudSecrets: MemorySecrets(),
      cloudStoreFactory: (_, _, _) => remote.client(),
    );
    final a = make('a'), b = make('b');
    final code = CloudCrypto.newRecoveryCode();
    try {
      await a.initialize();
      await b.initialize();
      final source = File('${dir.path}/书籍.txt');
      await source.writeAsString('第一章 山川\n\n${'阅读正文，记录位置。' * 100}');
      await a.importTransferredFile(source.path, 'book');
      await a.cloud.connect(
        server: 'https://e.test/',
        username: 'a',
        password: 'p',
        root: '阅读',
        recoveryCode: code,
        create: true,
      );
      await b.cloud.connect(
        server: 'https://e.test/',
        username: 'a',
        password: 'p',
        root: '阅读',
        recoveryCode: code,
        create: false,
      );
      final before = remote.puts;
      a.updateSettings(a.settings.copyWith(fontSize: 33, theme: 'dark'));
      await a.setPin('2345');
      await a.flush();
      expect(remote.puts, before);
      await a.cloud.upload('book');
      expect(a.cloud.error, isNull);
      await b.cloud.refresh();
      expect(b.cloud.items.length, 1);
      await b.cloud.download(b.cloud.items.single);
      expect(b.cloud.error, isNull);
      expect(b.books.single.id, a.books.single.id);
      expect(
        (await b.openBook(b.books.single)).text,
        (await a.openBook(a.books.single)).text,
      );
      expect(b.settings.fontSize, 21);
      expect(b.hasPin, isFalse);
      a.updateProgress(a.books.single.id, 80);
      await a.cloud.flushProgress();
      final progress = await b.cloud.newerProgress(b.books.single.id, 0, 0);
      expect(progress?.offset, 80);
      expect(b.books.single.offset, 0, reason: '检查云进度不能静默改本机位置');
      await b.followCloudProgress(progress!);
      expect(b.books.single.offset, 80);
    } finally {
      a.dispose();
      b.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await dir.delete(recursive: true);
    }
  });

  testWidgets('设置入口明确手动资源同步，云进度更新时间更晚时可保持本机或追到云端', (tester) async {
    final pair = await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('cloud_prompt');
      final remote = MemoryDav();
      AppModel make(String name) => AppModel(
        LibraryRepository(Directory('${dir.path}/$name')),
        _Platform(),
        cloudSecrets: MemorySecrets(),
        cloudStoreFactory: (_, _, _) => remote.client(),
      );
      final a = make('a'), b = make('b');
      await a.initialize();
      await b.initialize();
      final file = File('${dir.path}/小说.txt');
      await file.writeAsString('第一章 阅读\n\n${'正文。' * 100}');
      await a.importTransferredFile(file.path, 'book');
      final code = CloudCrypto.newRecoveryCode();
      await a.cloud.connect(
        server: 'https://e.test/',
        username: 'a',
        password: 'p',
        root: '阅读',
        recoveryCode: code,
        create: true,
      );
      await b.cloud.connect(
        server: 'https://e.test/',
        username: 'a',
        password: 'p',
        root: '阅读',
        recoveryCode: code,
        create: false,
      );
      await a.cloud.upload('book');
      await b.cloud.refresh();
      await b.cloud.download(b.cloud.items.single);
      a.updateProgress(a.books.single.id, 40);
      await a.cloud.flushProgress();
      return (dir, a, b);
    });
    final (dir, a, b) = pair!;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => checkCloudProgress(context, b, b.books.single),
              child: const Text('打开书籍'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开书籍'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pumpAndSettle();
    expect(find.text('发现更新的云端进度'), findsOneWidget);
    expect(b.books.single.offset, 0);
    await tester.tap(find.byKey(const ValueKey('keep-local-progress')));
    await tester.pumpAndSettle();
    expect(b.books.single.offset, 0);
    await tester.tap(find.text('打开书籍'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('follow-cloud-progress')));
    await tester.pump();
    for (
      var i = 0;
      i < 50 && find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pumpAndSettle();
    expect(b.books.single.offset, 40);
    await tester.pumpWidget(MaterialApp(home: CloudSyncScreen(model: b)));
    await tester.pumpAndSettle();
    expect(find.text('上传本机书籍'), findsOneWidget);
    await tester.tap(find.text('字体'));
    await tester.pumpAndSettle();
    expect(find.text('上传本机字体'), findsOneWidget);
    await tester.tap(find.text('照片'));
    await tester.pumpAndSettle();
    expect(find.text('上传本机照片及图片组'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    a.dispose();
    b.dispose();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await dir.delete(recursive: true);
    });
  });
}

class _Platform extends PlatformService {
  @override
  Future<void> appearance(String theme) async {}
  @override
  Future<void> discard(List<String> paths) async {}
}
