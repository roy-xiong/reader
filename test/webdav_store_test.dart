import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/cloud/webdav_store.dart';

void main() {
  test('真实 HTTP WebDAV 往返：中文目录、认证、PROPFIND、原子创建及无跨站重定向', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final files = <String, List<int>>{};
    final directories = <String>{'/dav'};
    var authenticated = 0, unauthorized = 0;
    server.listen((request) async {
      final path = request.uri.path.replaceFirst(RegExp(r'/$'), '');
      if (request.headers.value('authorization') !=
          'Basic ${base64Encode(utf8.encode('reader:application-password'))}') {
        unauthorized++;
        request.response.statusCode = 401;
        await request.response.close();
        return;
      }
      authenticated++;
      switch (request.method) {
        case 'MKCOL':
          request.response.statusCode = directories.add(path) ? 201 : 405;
        case 'PUT':
          if (request.headers.value('if-none-match') == '*' &&
              files.containsKey(path)) {
            request.response.statusCode = 412;
          } else {
            files[path] = await request.fold<List<int>>(
              [],
              (all, c) => all..addAll(c),
            );
            request.response.statusCode = 201;
          }
        case 'GET':
          if (path.endsWith('/redirect')) {
            request.response.statusCode = 302;
            request.response.headers.set(
              'location',
              'http://127.0.0.1:9/steal',
            );
          } else if (files.containsKey(path)) {
            request.response.add(files[path]!);
          } else {
            request.response.statusCode = 404;
          }
        case 'PROPFIND':
          expect(request.headers.value('depth'), '1');
          request.response.statusCode = 207;
          request.response.headers.contentType = ContentType(
            'application',
            'xml',
            charset: 'utf-8',
          );
          final rows = {...files.keys, ...directories}
              .where((k) => k == path || k.startsWith('$path/'))
              .where(
                (k) => k == path || !k.substring(path.length + 1).contains('/'),
              )
              .map(
                (k) =>
                    '<d:response><d:href>${Uri(path: k).toString()}</d:href><d:propstat><d:prop/></d:propstat></d:response>',
              )
              .join();
          request.response.write(
            '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">$rows</d:multistatus>',
          );
        default:
          request.response.statusCode = 405;
      }
      await request.response.close();
    });
    final store = WebDavStore(
      server: 'http://127.0.0.1:${server.port}/dav/',
      username: 'reader',
      password: 'application-password',
      allowLocalHttp: true,
    );
    final bad = WebDavStore(
      server: 'http://127.0.0.1:${server.port}/dav/',
      username: 'reader',
      password: 'bad',
      allowLocalHttp: true,
    );
    try {
      await store.directory('阅读');
      await store.directory('阅读');
      expect(await store.read('阅读/missing'), isNull);
      await store.write('阅读/文件.bin', [1, 2, 3], createOnly: true);
      expect(await store.read('阅读/文件.bin'), [1, 2, 3]);
      expect(await store.list('阅读'), ['文件.bin']);
      await expectLater(
        store.write('阅读/文件.bin', [4], createOnly: true),
        throwsFormatException,
      );
      await expectLater(bad.read('阅读/文件.bin'), throwsFormatException);
      await expectLater(store.read('阅读/redirect'), throwsFormatException);
      expect(unauthorized, 1);
      expect(authenticated, greaterThan(6));
      expect(
        () => WebDavStore(
          server: 'http://untrusted.test/',
          username: 'x',
          password: 'y',
        ),
        throwsFormatException,
      );
      await expectLater(store.read('../escape'), throwsFormatException);
    } finally {
      store.close();
      bad.close();
      await server.close(force: true);
    }
  });
}
