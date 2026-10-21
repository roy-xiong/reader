import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/data/wifi_upload_server.dart';
import 'package:reader/ui/app_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('固定 9900 地址没有参数，不用传输码；端口占用不悄悄换号，停止后可重用', () async {
    final root = await Directory.systemTemp.createTemp('wifi_port');
    final first = WifiUploadServer(
      importFile: (_, _) async => 'ok',
      temporaryDirectory: root,
    );
    final second = WifiUploadServer(
      importFile: (_, _) async => 'ok',
      temporaryDirectory: root,
    );
    try {
      await first.start(bindAddress: InternetAddress.loopbackIPv4);
      expect(first.urls.single, 'http://127.0.0.1:9900');
      await expectLater(
        second.start(bindAddress: InternetAddress.loopbackIPv4),
        throwsA(isA<FormatException>()),
      );
      await first.stop();
      await second.start(bindAddress: InternetAddress.loopbackIPv4);
      expect(second.urls, first.urls);
    } finally {
      await first.stop();
      await second.stop();
      await root.delete(recursive: true);
    }
  });
  test('打开首页即可上传书籍和字体，无认证步骤，批量去重并清理临时文件', () async {
    final root = await Directory.systemTemp.createTemp('wifi_files');
    final model = AppModel(
      LibraryRepository(Directory('${root.path}/library')),
      _Platform(),
    );
    await model.initialize();
    final staging = await Directory('${root.path}/temp').create();
    final server = WifiUploadServer(
      importFile: model.importTransferredFile,
      temporaryDirectory: staging,
    );
    final client = _RealHttpOverrides().createHttpClient(null);
    try {
      await server.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      final uri = Uri.parse(server.urls.single);
      expect(uri.hasQuery, isFalse);
      final page = await client.getUrl(uri);
      final html = await (await page.close()).transform(utf8.decoder).join();
      expect(html, contains('拖入多个文件'));
      expect(html, isNot(contains('id="auth"')));
      expect(html, isNot(contains('id="code"')));
      expect((await request(client, uri, '/auth', [])).$1, 404);
      final text = utf8.encode('第一章 春天\n\n你好，世界。');
      for (var i = 0; i < 2; i++) {
        expect(
          (await request(
            client,
            uri,
            '/upload',
            text,
            query: {'kind': 'book', 'name': '书籍$i.txt'},
          )).$1,
          200,
        );
      }
      expect(model.books.length, 1);
      final font = await request(
        client,
        uri,
        '/upload',
        [0, 1, 0, 0, ...List.filled(24, 0)],
        query: {'kind': 'font', 'name': '字体甲.ttf'},
      );
      expect(font.$1, 200);
      expect(model.fonts.single.name, '字体甲');
      expect(model.settings.fontId, isNull);
      expect(await staging.list().isEmpty, isTrue);
      await server.stop();
      await expectLater(() async {
        final r = await client.getUrl(uri);
        await r.close();
      }, throwsA(anyOf(isA<SocketException>(), isA<HttpException>())));
    } finally {
      await server.stop();
      client.close(force: true);
      model.dispose();
      await root.delete(recursive: true);
    }
  });
  test('无传输码仍拒绝伪造来源、错误类型与空文件', () async {
    final root = await Directory.systemTemp.createTemp('wifi_invalid');
    var imported = 0;
    final server = WifiUploadServer(
      importFile: (_, _) async {
        imported++;
        return 'unexpected';
      },
      temporaryDirectory: root,
    );
    final client = _RealHttpOverrides().createHttpClient(null);
    try {
      await server.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      final uri = Uri.parse(server.urls.single);
      expect(
        (await request(
          client,
          uri,
          '/upload',
          [1],
          query: {'kind': 'book', 'name': 'attack.exe'},
        )).$1,
        400,
      );
      expect(
        (await request(
          client,
          uri,
          '/upload',
          [],
          query: {'kind': 'font', 'name': 'empty.ttf'},
        )).$1,
        400,
      );
      expect(
        (await request(
          client,
          uri,
          '/upload',
          [1],
          origin: 'https://other.example',
          query: {'kind': 'font', 'name': 'font.ttf'},
        )).$1,
        403,
      );
      expect(imported, 0);
      expect(await root.list().isEmpty, isTrue);
    } finally {
      await server.stop();
      client.close(force: true);
      await root.delete(recursive: true);
    }
  });
  test('超过 64MB 的字体仍流式上传，书籍大小限制不变', () async {
    final root = await Directory.systemTemp.createTemp('wifi_large');
    final server = WifiUploadServer(
      importFile: (path, kind) async {
        expect(await File(path).length(), 65 * 1024 * 1024);
        return '大字体';
      },
      temporaryDirectory: root,
    );
    final client = _RealHttpOverrides().createHttpClient(null);
    try {
      final file = File('${root.path}/large.ttf');
      final handle = await file.open(mode: FileMode.write);
      await handle.writeFrom([0, 1, 0, 0, ...List.filled(24, 0)]);
      await handle.truncate(65 * 1024 * 1024);
      await handle.close();
      await server.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      final uri = Uri.parse(server.urls.single);
      for (final kind in ['font', 'book']) {
        final r = await client.postUrl(
          uri.replace(
            path: '/upload',
            queryParameters: {
              'kind': kind,
              'name': kind == 'font' ? 'large.ttf' : 'large.txt',
            },
          ),
        );
        r.contentLength = await file.length();
        await r.addStream(file.openRead());
        final response = await r.close();
        expect(response.statusCode, kind == 'font' ? 200 : 400);
        await response.drain<void>();
      }
    } finally {
      await server.stop();
      client.close(force: true);
      await root.delete(recursive: true);
    }
  });
  test('上传中断清理临时文件，停止后不接收', () async {
    final root = await Directory.systemTemp.createTemp('wifi_abort');
    var imported = 0;
    final server = WifiUploadServer(
      importFile: (_, _) async {
        imported++;
        return 'ok';
      },
      temporaryDirectory: root,
    );
    final receiving = Completer<void>();
    final events = server.events.listen((m) {
      if (m.startsWith('正在接收') && !receiving.isCompleted) receiving.complete();
    });
    Socket? socket;
    try {
      await server.start(bindAddress: InternetAddress.loopbackIPv4, port: 0);
      final uri = Uri.parse(server.urls.single);
      socket = await Socket.connect(uri.host, uri.port);
      socket.write(
        'POST /upload?kind=book&name=partial.txt HTTP/1.1\r\nHost: ${uri.host}:${uri.port}\r\nContent-Length: 524288\r\n\r\npartial',
      );
      await socket.flush();
      await receiving.future.timeout(const Duration(seconds: 3));
      socket.destroy();
      for (var i = 0; i < 100 && !await root.list().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await root.list().isEmpty, isTrue);
      expect(imported, 0);
    } finally {
      socket?.destroy();
      await events.cancel();
      await server.stop();
      await root.delete(recursive: true);
    }
  });
}

Future<(int, Map<String, dynamic>)> request(
  HttpClient client,
  Uri base,
  String path,
  List<int> body, {
  String? origin,
  Map<String, String>? query,
}) async {
  final r = await client.postUrl(
    base.replace(path: path, queryParameters: query),
  );
  r.headers.contentType = ContentType.binary;
  if (origin != null) r.headers.set('Origin', origin);
  r.contentLength = body.length;
  r.add(body);
  final response = await r.close();
  return (
    response.statusCode,
    Map<String, dynamic>.from(
      jsonDecode(await response.transform(utf8.decoder).join()) as Map,
    ),
  );
}

class _Platform extends PlatformService {
  @override
  Future<void> appearance(String theme) async {}
}

class _RealHttpOverrides extends HttpOverrides {}
