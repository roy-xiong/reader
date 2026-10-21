import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/cloud/cloud_crypto.dart';
import 'package:reader/data/cloud/cloud_assets.dart';
import 'package:reader/domain/cloud/cloud_models.dart';
import 'package:reader/domain/cloud/sync_ledger.dart';
import 'package:reader/ui/cloud/cloud_sync_controller.dart';
import 'support/cloud_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('认证加密防篡改、绑定对象路径、恢复码长度校验', () async {
    final code = CloudCrypto.newRecoveryCode();
    final cipher = CloudCrypto(CloudCrypto.parseRecoveryCode(code));
    final bytes = await cipher.encrypt([1, 2, 3], 'lib/object');
    expect(await cipher.decrypt(bytes, 'lib/object'), [1, 2, 3]);
    expect(() => CloudCrypto.parseRecoveryCode('1234'), throwsFormatException);
    await expectLater(
      cipher.decrypt(bytes, 'other/object'),
      throwsFormatException,
    );
    bytes[bytes.length - 1] ^= 1;
    await expectLater(
      cipher.decrypt(bytes, 'lib/object'),
      throwsFormatException,
    );
  });
  test('未知业务字段往返保留，因果覆盖与并发保留', () {
    final a = SyncLedger('a' * 32), b = SyncLedger('b' * 32);
    a.put('future/module', {'schema': 99, 'unknownSetting': 'keep'});
    b.merge(a);
    b.put('item/example', {'x': 1});
    final old = SyncLedger.fromJson(b.toJson());
    old.put('other', 1);
    expect(old.materialize()['future/module'], {
      'schema': 99,
      'unknownSetting': 'keep',
    });
    a.put('item/example', {'x': 2});
    old.merge(a);
    expect(old.hasConflict('item/example'), isTrue);
    old.put('item/example', {'x': 3});
    a.merge(old);
    expect(a.hasConflict('item/example'), isFalse);
    expect(a.materialize()['item/example'], {'x': 3});
  });
  test('大文件分块加密传输、字节进度、断块与完整散列校验', () async {
    final dir = await Directory.systemTemp.createTemp('cloud_asset_test');
    final remote = MemoryDav();
    try {
      final file = File('${dir.path}/large-font');
      await file.writeAsBytes(
        Uint8List.fromList(
          List.generate(CloudAssets.blockSize + 30000, (i) => i % 251),
        ),
      );
      final id = await CloudAssets.hash(file);
      final assets = CloudAssets(
        remote.client(),
        CloudCrypto(
          CloudCrypto.parseRecoveryCode(CloudCrypto.newRecoveryCode()),
        ),
        '阅读',
        'lib',
      );
      final progress = <int>[];
      final item = await assets.upload(
        CloudSource('font', id, '字体', {}, {'font': file}),
        progress: (done, total) {
          progress.add(done);
          expect(done, lessThanOrEqualTo(total));
        },
        cancelled: () => false,
      );
      expect(progress.length, 2);
      expect(progress.last, await file.length());
      expect(remote.files.keys.where((k) => k.endsWith('.bin')).length, 2);
      final downloaded = await assets.download(
        item,
        Directory('${dir.path}/download'),
        progress: (_, _) {},
        cancelled: () => false,
      );
      expect(await CloudAssets.hash(downloaded['font']!), id);
      final chunk = remote.files.keys.first;
      remote.files[chunk]![31] ^= 1;
      await expectLater(
        assets.download(
          item,
          Directory('${dir.path}/bad'),
          progress: (_, _) {},
          cancelled: () => false,
        ),
        throwsFormatException,
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('双设备连接、手动传输、进度按更新时间提示，离线队列重启补传，设置不自动上传', () async {
    final dir = await Directory.systemTemp.createTemp('cloud_two_devices');
    final remote = MemoryDav(),
        secretA = MemorySecrets(),
        secretB = MemorySecrets();
    final received = <String>[];
    CloudSyncController build(String name, MemorySecrets secret) =>
        CloudSyncController(
          directory: Directory('${dir.path}/$name'),
          sources: (_) async => [],
          receive: (item, files) async {
            received.add(item.name);
          },
          isUnavailable: () => false,
          secrets: secret,
          storeFactory: (_, _, _) => remote.client(),
        );
    var a = build('a', secretA);
    final b = build('b', secretB);
    final recovery = CloudCrypto.newRecoveryCode(), book = 'f' * 64;
    try {
      await a.connect(
        server: 'https://example.test/dav/',
        username: 'reader',
        password: 'application-password',
        root: '阅读',
        recoveryCode: recovery,
        create: true,
      );
      await b.connect(
        server: 'https://example.test/dav/',
        username: 'reader',
        password: 'application-password',
        root: '阅读',
        recoveryCode: recovery,
        create: false,
      );
      expect(remote.files.keys, contains('阅读/vault.json'));
      final initialPuts = remote.puts;
      await b.refresh();
      expect(remote.puts, initialPuts, reason: '刷新不能自动上传本机设置或资源');
      // A 重读了前面，较小进度但时间更新，应提示 B 跳回云端。
      a.recordProgress(
        bookId: book,
        offset: 100,
        length: 1000,
        updatedAt: 2000,
      );
      await a.flushProgress();
      final candidate = await b.newerProgress(book, 1000, 800);
      expect(candidate?.offset, 100);
      expect(candidate?.updatedAt, 2000);
      expect(
        await b.newerProgress(book, 3000, 800),
        isNull,
        reason: '较晚的本机阅读不应被旧云进度提示',
      );
      expect(
        await b.newerProgress(book, 1000, 100),
        isNull,
        reason: '同位置不重复提示',
      );
      // 离线不丢最后一次进度，恢复连接不自动上传字体或照片。
      remote.offline = true;
      a.recordProgress(
        bookId: book,
        offset: 230,
        length: 1000,
        updatedAt: 4000,
      );
      a.recordProgress(
        bookId: book,
        offset: 250,
        length: 1000,
        updatedAt: 4100,
      );
      await a.flushProgress();
      expect(a.progressPending, isTrue);
      // 等待原子保存队列落盘，然后销毁，模拟退出后重新启动。
      a.setPaused(true);
      for (
        var i = 0;
        i < 100 && !await File('${dir.path}/a/cloud-state.enc').exists();
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      a.dispose();
      remote.offline = false;
      a = build('a', secretA);
      await a.initialize();
      expect(a.progressPending, isTrue);
      await a.flushProgress();
      expect(a.progressPending, isFalse);
      expect((await b.newerProgress(book, 2000, 100))?.offset, 250);
      expect(
        remote.files.values.every(
          (bytes) =>
              !String.fromCharCodes(bytes).contains('application-password'),
        ),
        isTrue,
      );
      expect(received, isEmpty, reason: '进度同步不能自动下载资源');
      expect(
        remote.files.keys.any(
          (k) => k.contains('settings') || k.contains('pin'),
        ),
        isFalse,
      );
    } finally {
      a.dispose();
      b.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await dir.delete(recursive: true);
    }
  });
  test('本机保存失败时连接必须回到未连接状态，不能留下已关闭的客户端', () async {
    final dir = await Directory.systemTemp.createTemp('cloud_local_failure');
    final blocked = File('${dir.path}/blocked');
    await blocked.writeAsString('occupied');
    final remote = MemoryDav();
    final controller = CloudSyncController(
      directory: Directory(blocked.path),
      sources: (_) async => [],
      receive: (_, _) async {},
      isUnavailable: () => false,
      secrets: MemorySecrets(),
      storeFactory: (_, _, _) => remote.client(),
    );
    try {
      await expectLater(
        controller.connect(
          server: 'https://e.test/',
          username: 'a',
          password: 'p',
          root: '阅读',
          recoveryCode: CloudCrypto.newRecoveryCode(),
          create: true,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(controller.connected, isFalse);
      expect(controller.busy, isFalse);
    } finally {
      controller.dispose();
      await dir.delete(recursive: true);
    }
  });
  test('错误恢复码不会接入已有云库，上传失败不发布半个目录', () async {
    final dir = await Directory.systemTemp.createTemp('cloud_failures');
    final remote = MemoryDav();
    final file = File('${dir.path}/book');
    await file.writeAsString('test book');
    final id = await CloudAssets.hash(file);
    CloudSyncController build(String n) => CloudSyncController(
      directory: Directory('${dir.path}/$n'),
      sources: (_) async => [
        CloudSource('book', id, '书籍', {}, {'original': file}),
      ],
      receive: (_, _) async {},
      isUnavailable: () => false,
      secrets: MemorySecrets(),
      storeFactory: (_, _, _) => remote.client(),
    );
    final a = build('a'), b = build('b');
    final code = CloudCrypto.newRecoveryCode();
    try {
      await a.connect(
        server: 'https://e.test/',
        username: 'a',
        password: 'p',
        root: '阅读',
        recoveryCode: code,
        create: true,
      );
      await expectLater(
        () => b.connect(
          server: 'https://e.test/',
          username: 'a',
          password: 'p',
          root: '阅读',
          recoveryCode: CloudCrypto.newRecoveryCode(),
          create: false,
        ),
        throwsFormatException,
      );
      expect(b.connected, isFalse);
      remote.failPath = '00000000.bin';
      await a.upload('book');
      expect(a.error, isNotNull);
      expect(
        remote.files.keys.where((k) => k.startsWith('阅读/devices/')),
        isEmpty,
      );
      remote.failPath = null;
      await a.upload('book');
      expect(a.error, isNull);
      expect(a.items.single.id, id);
    } finally {
      a.dispose();
      b.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await dir.delete(recursive: true);
    }
  });
}
