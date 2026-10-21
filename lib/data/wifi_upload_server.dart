import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'book_parser.dart';
import 'wifi_upload_page.dart';

/// 仅在传输页存活的局域网 HTTP 上传入口。流式落盘，不把书籍或大字体整份加载到内存。
/// 网页先通过临时传输码换取本次会话令牌，不提供书架下载或任意路径访问接口。
class WifiUploadServer {
  WifiUploadServer({required this.importFile, Directory? temporaryDirectory})
    : temporaryDirectory = temporaryDirectory ?? Directory.systemTemp;
  final Future<String> Function(String path, String kind) importFile;
  final Directory temporaryDirectory;
  final _events = StreamController<String>.broadcast();
  Stream<String> get events => _events.stream;
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  final _attempts = <String, (DateTime, int)>{};
  Set<String> _hosts = {};
  String code = '', _token = '';
  List<String> urls = [];
  bool _closed = false, _uploading = false;
  bool get running => _server != null && !_closed;

  static bool _private(InternetAddress address) {
    if (address.isLoopback) {
      return true;
    }
    final bytes = address.rawAddress;
    return bytes.length == 4 &&
        (bytes[0] == 10 ||
            (bytes[0] == 192 && bytes[1] == 168) ||
            (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
            (bytes[0] == 169 && bytes[1] == 254));
  }

  Future<void> start({InternetAddress? bindAddress}) async {
    if (_closed) {
      throw StateError('传输会话已关闭');
    }
    if (_server != null) {
      return;
    }
    final List<String> addresses;
    if (bindAddress != null) {
      addresses = [bindAddress.address];
    } else {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      interfaces.sort(
        (a, b) => (a.name == 'en0' || a.name.startsWith('wlan') ? 0 : 1)
            .compareTo(b.name == 'en0' || b.name.startsWith('wlan') ? 0 : 1),
      );
      addresses = interfaces
          .where(
            (item) => !RegExp(r'^(utun|tun|pdp_ip|rmnet)').hasMatch(item.name),
          )
          .expand((item) => item.addresses)
          .where((address) => !address.isLoopback && _private(address))
          .map((address) => address.address)
          .toSet()
          .toList();
    }
    if (addresses.isEmpty) {
      throw const FormatException('请先连接 Wi-Fi，再启动传输');
    }
    final server = await HttpServer.bind(
      bindAddress ?? InternetAddress.anyIPv4,
      0,
    );
    if (_closed) {
      await server.close(force: true);
      return;
    }
    final random = Random.secure();
    code = (100000 + random.nextInt(900000)).toString();
    _token = base64UrlEncode(List.generate(32, (_) => random.nextInt(256)));
    _hosts = addresses.map((address) => '$address:${server.port}').toSet();
    urls = addresses
        .map((address) => 'http://$address:${server.port}')
        .toList();
    _server = server;
    _subscription = server.listen(
      (request) {
        unawaited(_handle(request));
      },
      onError: (Object _) {
        _emit('传输连接异常，请停止后重新启动');
      },
    );
  }

  void _emit(String value) {
    if (!_closed) {
      _events.add(value);
    }
  }

  Future<void> _json(
    HttpResponse response,
    int status,
    Map<String, dynamic> body,
  ) async {
    response.statusCode = status;
    if (status >= 400) {
      response.persistentConnection = false;
    }
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.flush();
    await response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      response.headers.set('Cache-Control', 'no-store');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      response.headers.set('X-Frame-Options', 'DENY');
      response.headers.set(
        'Content-Security-Policy',
        "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'",
      );
      final host = request.headers.value('host');
      final peer = request.connectionInfo?.remoteAddress;
      final origin = request.headers.value('origin');
      if (_closed ||
          host == null ||
          !_hosts.contains(host) ||
          peer == null ||
          !_private(peer) ||
          (origin != null && origin != 'http://$host')) {
        await _json(response, 403, {'error': '请从传输页显示的本地地址连接'});
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/') {
        response.headers.contentType = ContentType.html;
        response.write(wifiUploadPage);
        await response.close();
      } else if (request.method == 'POST' && request.uri.path == '/auth') {
        final key = peer.address, now = DateTime.now();
        final previous = _attempts[key];
        final count =
            previous == null || now.difference(previous.$1).inSeconds >= 60
            ? 0
            : previous.$2;
        if (count >= 8) {
          await _json(response, 429, {'error': '传输码尝试较多，请稍后重试'});
          return;
        }
        _attempts[key] = (
          previous == null || count == 0 ? now : previous.$1,
          count + 1,
        );
        final bytes = <int>[];
        await for (final chunk in request.timeout(
          const Duration(seconds: 15),
        )) {
          if (bytes.length + chunk.length > 512) {
            throw const FormatException('连接请求过大');
          }
          bytes.addAll(chunk);
        }
        final input = jsonDecode(utf8.decode(bytes));
        if (input is! Map || input['code'] != code) {
          await _json(response, 401, {'error': '传输码不正确'});
          return;
        }
        _attempts.remove(key);
        await _json(response, 200, {'token': _token});
      } else if (request.method == 'POST' && request.uri.path == '/upload') {
        if (request.headers.value('authorization') != 'Bearer $_token') {
          await _json(response, 401, {'error': '请先输入传输码连接阅读器'});
          return;
        }
        await _upload(request);
      } else {
        await _json(response, 404, {'error': '页面不存在'});
      }
    } catch (error) {
      if (request.uri.path == '/upload') {
        _emit(
          error is FormatException ? '未导入：${error.message}' : '传输失败，请重试或检查存储空间',
        );
      }
      try {
        await _json(response, error is FormatException ? 400 : 500, {
          'error': error is FormatException ? error.message : '传输失败，请重试或检查存储空间',
        });
      } catch (_) {
        /* 客户端中断或会话停止时连接已关闭。 */
      }
    }
  }

  Future<void> _upload(HttpRequest request) async {
    if (_uploading) {
      await _json(request.response, 409, {'error': '上一个文件正在导入，请稍后重试'});
      return;
    }
    final kind = request.uri.queryParameters['kind'];
    final rawName = request.uri.queryParameters['name'] ?? '';
    final name = p
        .basename(rawName.replaceAll('\\', '/'))
        .replaceAll(RegExp(r'[\x00-\x1f]'), '')
        .trim();
    final extension = p.extension(name).toLowerCase().replaceFirst('.', '');
    if (name.isEmpty ||
        name.length > 180 ||
        !['book', 'font'].contains(kind) ||
        !(kind == 'font' ? ['ttf', 'otf'] : BookParser.extensions).contains(
          extension,
        )) {
      throw const FormatException('文件类型不支持，请选择电子书或 TTF / OTF 字体');
    }
    const maxBook = 64 * 1024 * 1024;
    if (kind == 'book' && request.contentLength > maxBook) {
      throw const FormatException('电子书不能超过 64 MB');
    }
    _uploading = true;
    Directory? staging;
    IOSink? sink;
    var released = false;
    try {
      staging = await temporaryDirectory.createTemp('reader_wifi_');
      final file = File(p.join(staging.path, name));
      sink = file.openWrite();
      var received = 0;
      _emit('正在接收 $name');
      final stream = request
          .timeout(const Duration(seconds: 60))
          .map<List<int>>((chunk) {
            if (_closed) {
              throw const FormatException('传输已停止');
            }
            received += chunk.length;
            if (kind == 'book' && received > maxBook) {
              throw const FormatException('电子书不能超过 64 MB');
            }
            return chunk;
          });
      await stream.pipe(sink);
      sink = null;
      if (_closed) {
        throw const FormatException('传输已停止');
      }
      if (received == 0) {
        throw const FormatException('请选择非空文件');
      }
      _emit('正在导入 $name');
      final title = await importFile(file.path, kind!);
      _emit('已导入 $title');
      // 浏览器收到成功结果就会发送下一个文件；先完成清理并释放本次导入锁。
      await staging.delete(recursive: true);
      staging = null;
      _uploading = false;
      released = true;
      await _json(request.response, 200, {'name': title});
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        /* 写入失败仍继续清理临时文件。 */
      }
      try {
        if (staging != null && await staging.exists()) {
          await staging.delete(recursive: true);
        }
      } finally {
        if (!released) {
          _uploading = false;
        }
      }
    }
  }

  Future<void> stop() async {
    if (_closed) {
      return;
    }
    _closed = true;
    final server = _server;
    _server = null;
    await server?.close(force: true);
    await _subscription?.cancel();
    _attempts.clear();
    await _events.close();
  }
}
