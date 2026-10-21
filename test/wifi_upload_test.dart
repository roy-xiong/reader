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

  test('网页认证、书籍字体批量导入、去重及停止服务', () async {
    final root = await Directory.systemTemp.createTemp('reader_wifi_test_');
    final model = AppModel(
      LibraryRepository(Directory('${root.path}/library')),
      _Platform(),
    );
    await model.initialize();
    final staging = Directory('${root.path}/temp')..createSync();
    final server = WifiUploadServer(
      importFile: model.importTransferredFile,
      temporaryDirectory: staging,
    );
    final client = _RealHttpOverrides().createHttpClient(null);
    final events = <String>[];
    final subscription = server.events.listen(events.add);
    try {
      await server.start(bindAddress: InternetAddress.loopbackIPv4);
      final uri = Uri.parse(server.urls.first);
      final page = await client.getUrl(uri);
      final html = await (await page.close()).transform(utf8.decoder).join();
      expect(html, contains('拖入多个文件'));
      expect(html, isNot(contains(server.code)), reason: '传输码只在阅读器中显示');
      final unauthorized = await _request(
        client,
        uri,
        '/upload',
        utf8.encode('正文'),
        query: {'kind': 'book', 'name': '测试.txt'},
      );
      expect(unauthorized.$1, 401);
      expect(
        (await _request(
          client,
          uri,
          '/auth',
          utf8.encode('{"code":"wrong"}'),
        )).$1,
        401,
      );
      final authorized = await _request(
        client,
        uri,
        '/auth',
        utf8.encode(jsonEncode({'code': server.code})),
      );
      expect(authorized.$1, 200);
      final token = authorized.$2['token'] as String;
      final content = utf8.encode('第一章 春天\n\n你好，世界。\n\n第二章 夏天\n\n新的旅程。');
      final uploaded = await _request(
        client,
        uri,
        '/upload',
        content,
        token: token,
        query: {'kind': 'book', 'name': '测试书籍.txt'},
      );
      expect(uploaded.$1, 200);
      expect(model.books.length, 1);
      await _request(
        client,
        uri,
        '/upload',
        content,
        token: token,
        query: {'kind': 'book', 'name': '重复.txt'},
      );
      expect(model.books.length, 1);
      final font = await _request(
        client,
        uri,
        '/upload',
        [0, 1, 0, 0, ...List.filled(8, 0)],
        token: token,
        query: {'kind': 'font', 'name': '字体甲.ttf'},
      );
      expect(font.$1, 200);
      expect(model.fonts.single.name, '字体甲');
      expect(model.settings.fontId, isNull, reason: '上传字体只记录目录，按需切换');
      expect(events.any((value) => value.startsWith('已导入')), isTrue);
      expect(await staging.list().isEmpty, isTrue);
      await server.stop();
      expect(server.running, isFalse);
      Future<void> afterStop() async {
        final request = await client.getUrl(uri);
        await request.close();
      }

      await expectLater(
        afterStop(),
        throwsA(anyOf(isA<SocketException>(), isA<HttpException>())),
      );
    } finally {
      await subscription.cancel();
      await server.stop();
      client.close(force: true);
      model.dispose();
      await root.delete(recursive: true);
    }
  });

  test('错误类型、伪造来源、空文件与认证限流不写入书架', () async {
    var imported = 0;
    final root = await Directory.systemTemp.createTemp('reader_wifi_invalid_');
    final server = WifiUploadServer(
      importFile: (_, _) async {
        imported++;
        return 'unexpected';
      },
      temporaryDirectory: root,
    );
    final client = _RealHttpOverrides().createHttpClient(null);
    try {
      await server.start(bindAddress: InternetAddress.loopbackIPv4);
      final uri = Uri.parse(server.urls.first);
      final auth = await _request(
        client,
        uri,
        '/auth',
        utf8.encode(jsonEncode({'code': server.code})),
      );
      final token = auth.$2['token'] as String;
      expect(
        (await _request(
          client,
          uri,
          '/upload',
          [1],
          token: token,
          query: {'kind': 'book', 'name': 'attack.exe'},
        )).$1,
        400,
      );
      expect(
        (await _request(
          client,
          uri,
          '/upload',
          [],
          token: token,
          query: {'kind': 'font', 'name': 'empty.ttf'},
        )).$1,
        400,
      );
      expect(
        (await _request(
          client,
          uri,
          '/upload',
          [1],
          token: token,
          origin: 'https://other.example',
          query: {'kind': 'font', 'name': 'font.ttf'},
        )).$1,
        403,
      );
      for (var i = 0; i < 8; i++) {
        expect(
          (await _request(
            client,
            uri,
            '/auth',
            utf8.encode('{"code":"wrong"}'),
          )).$1,
          401,
        );
      }
      expect(
        (await _request(
          client,
          uri,
          '/auth',
          utf8.encode(jsonEncode({'code': server.code})),
        )).$1,
        429,
      );
      expect(imported, 0);
      expect(await root.list().isEmpty, isTrue);
    } finally {
      await server.stop();
      client.close(force: true);
      await root.delete(recursive: true);
    }
  });

  test('超过 64MB 的字体流式上传，书籍大小限制保持一致', () async {
    final root = await Directory.systemTemp.createTemp('reader_wifi_large_');
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
      await handle.writeFrom([0, 1, 0, 0, ...List.filled(8, 0)]);
      await handle.truncate(65 * 1024 * 1024);
      await handle.close();
      await server.start(bindAddress: InternetAddress.loopbackIPv4);
      final uri = Uri.parse(server.urls.first);
      final auth = await _request(
        client,
        uri,
        '/auth',
        utf8.encode(jsonEncode({'code': server.code})),
      );
      final token = auth.$2['token'] as String;
      final request = await client.postUrl(
        uri.replace(
          path: '/upload',
          queryParameters: {'kind': 'font', 'name': 'large.ttf'},
        ),
      );
      request.headers.set('Authorization', 'Bearer $token');
      request.contentLength = await file.length();
      await request.addStream(file.openRead());
      final response = await request.close();
      expect(response.statusCode, 200);
      await response.drain<void>();
      final bookRequest = await client.postUrl(
        uri.replace(
          path: '/upload',
          queryParameters: {'kind': 'book', 'name': 'large.txt'},
        ),
      );
      bookRequest.headers.set('Authorization', 'Bearer $token');
      bookRequest.contentLength = await file.length();
      await bookRequest.addStream(file.openRead());
      final bookResponse = await bookRequest.close();
      expect(bookResponse.statusCode, 400);
      expect(
        await bookResponse.transform(utf8.decoder).join(),
        contains('64 MB'),
      );
    } finally {
      await server.stop();
      client.close(force: true);
      await root.delete(recursive: true);
    }
  });
  test('上传中断会清理临时文件，停止会话后不再接收', () async {
    final root = await Directory.systemTemp.createTemp('reader_wifi_abort_');
    var imported = 0;
    final server = WifiUploadServer(
      importFile: (_, _) async {
        imported++;
        return '已导入';
      },
      temporaryDirectory: root,
    );
    final client = _RealHttpOverrides().createHttpClient(null);
    final receiving = Completer<void>();
    final events = server.events.listen((message) {
      if (message.startsWith('正在接收') && !receiving.isCompleted) {
        receiving.complete();
      }
    });
    Socket? socket;
    try {
      await server.start(bindAddress: InternetAddress.loopbackIPv4);
      final uri = Uri.parse(server.urls.first);
      final auth = await _request(
        client,
        uri,
        '/auth',
        utf8.encode(jsonEncode({'code': server.code})),
      );
      final token = auth.$2['token'] as String;
      socket = await Socket.connect(uri.host, uri.port);
      socket.write(
        'POST /upload?kind=book&name=partial.txt HTTP/1.1\r\nHost: ${uri.host}:${uri.port}\r\nAuthorization: Bearer $token\r\nContent-Length: 524288\r\n\r\npartial',
      );
      await socket.flush();
      await receiving.future.timeout(const Duration(seconds: 3));
      socket.destroy();
      for (var i = 0; i < 100 && !await root.list().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await root.list().isEmpty, isTrue);
      expect(imported, 0);
      await server.stop();
      expect(server.running, isFalse);
    } finally {
      socket?.destroy();
      await events.cancel();
      await server.stop();
      client.close(force: true);
      await root.delete(recursive: true);
    }
  });
}

Future<(int, Map<String, dynamic>)> _request(
  HttpClient client,
  Uri base,
  String path,
  List<int> body, {
  String? token,
  String? origin,
  Map<String, String>? query,
}) async {
  final request = await client.postUrl(
    base.replace(path: path, queryParameters: query),
  );
  request.headers.contentType = ContentType.binary;
  if (token != null) {
    request.headers.set('Authorization', 'Bearer $token');
  }
  if (origin != null) {
    request.headers.set('Origin', origin);
  }
  request.contentLength = body.length;
  request.add(body);
  final response = await request.close();
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

/// 绕过 Widget 测试默认返回 400 的 HTTP 替身，验证真实的本机局域网协议入口。
class _RealHttpOverrides extends HttpOverrides {}
