import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:xml/xml.dart';

/// 可替换的远端字节存储接口，核心协议不绑定坚果云的账号和 URL。
abstract class CloudStore {
  Future<Uint8List?> read(String path, {int maxBytes = 16 * 1024 * 1024});
  Future<void> write(String path, List<int> bytes, {bool createOnly = false});
  Future<void> directory(String path);
  Future<List<String>> list(String path);
  void close();
}

/// HTTPS WebDAV 客户端。认证只发往配置源站，禁止跨域跳转和无效证书放行。
/// 每个请求有超时与响应大小界限，错误不包含凭据、远端正文或私人文件名。
class WebDavStore implements CloudStore {
  WebDavStore({
    required String server,
    required String username,
    required String password,
    bool allowLocalHttp = false,
  }) : base = Uri.parse(server.trim()),
       _authorization =
           'Basic ${base64Encode(utf8.encode('$username:$password'))}' {
    if ((!base.isScheme('https') &&
            !(allowLocalHttp &&
                base.isScheme('http') &&
                ['localhost', '127.0.0.1'].contains(base.host))) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw const FormatException('请输入不含账号和参数的 HTTPS WebDAV 地址');
    }
    _client.connectionTimeout = const Duration(seconds: 20);
  }
  final Uri base;
  final String _authorization;
  final HttpClient _client = HttpClient();
  bool _closed = false;
  DateTime? retryAfter;
  Uri _uri(String path) {
    if (path.split('/').any((p) => p == '..' || p == '.') ||
        path.startsWith('/')) {
      throw const FormatException('同步路径不合法');
    }
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((s) => s.isNotEmpty),
        ...path.split('/').where((s) => s.isNotEmpty),
      ],
    );
  }

  Future<Uint8List> _request(
    String method,
    String path, {
    List<int>? bytes,
    Map<String, String> headers = const {},
    Set<int> accepted = const {200},
    int maxBytes = 16 * 1024 * 1024,
  }) async {
    if (_closed) throw const FormatException('同步已取消');
    if (retryAfter != null && DateTime.now().isBefore(retryAfter!)) {
      throw const FormatException('网盘请求过于频繁，稍后自动重试');
    }
    HttpClientRequest? request;
    try {
      request = await _client
          .openUrl(method, _uri(path))
          .timeout(const Duration(seconds: 25));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, _authorization);
      request.headers.set(HttpHeaders.userAgentHeader, 'Reading/1.5 WebDAV');
      for (final header in headers.entries) {
        request.headers.set(header.key, header.value);
      }
      if (bytes != null) {
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      if (!accepted.contains(response.statusCode)) {
        final status = response.statusCode;
        if (status == 429 || status == 503) {
          final seconds =
              int.tryParse(response.headers.value('retry-after') ?? '') ?? 60;
          retryAfter = DateTime.now().add(
            Duration(seconds: seconds.clamp(30, 1800)),
          );
        }
        await response.drain<void>().timeout(const Duration(seconds: 5));
        throw FormatException(switch (status) {
          401 || 403 => '网盘认证失败，请检查账号和第三方应用密码（不是登录密码）',
          404 => '云端文件不存在，请刷新云书架',
          409 => '云端目录不存在，请重新连接',
          412 => '云书架已存在，请使用对应恢复码加入',
          413 || 507 => '网盘空间、流量或文件大小超过当前套餐限制',
          429 || 503 => '网盘限流，稍后自动重试',
          _ => '网盘请求失败（HTTP $status）',
        });
      }
      if (response.statusCode == 404) {
        await response.drain<void>();
        return Uint8List(0);
      }
      final result = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 60))) {
        if (result.length + chunk.length > maxBytes) {
          throw const FormatException('云端文件异常过大，已停止读取');
        }
        result.add(chunk);
      }
      return result.takeBytes();
    } on TimeoutException {
      request?.abort();
      throw const FormatException('连接网盘超时，请检查网络后重试');
    } on HandshakeException {
      request?.abort();
      throw const FormatException('网盘 HTTPS 证书验证失败');
    } on SocketException {
      request?.abort();
      throw const FormatException('无法连接网盘，请检查网络');
    }
  }

  @override
  Future<Uint8List?> read(
    String path, {
    int maxBytes = 16 * 1024 * 1024,
  }) async {
    final data = await _request(
      'GET',
      path,
      accepted: {200, 404},
      maxBytes: maxBytes,
    );
    return data.isEmpty ? null : data;
  }

  @override
  Future<void> write(
    String path,
    List<int> bytes, {
    bool createOnly = false,
  }) async {
    await _request(
      'PUT',
      path,
      bytes: bytes,
      accepted: {200, 201, 204},
      headers: {
        'Content-Type': 'application/octet-stream',
        if (createOnly) 'If-None-Match': '*',
      },
    );
  }

  @override
  Future<void> directory(String path) async {
    await _request('MKCOL', path, accepted: {200, 201, 204, 405});
  }

  @override
  Future<List<String>> list(String path) async {
    final bytes = await _request(
      'PROPFIND',
      path,
      bytes: utf8.encode(
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
      ),
      headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      accepted: {207, 404},
    );
    if (bytes.isEmpty) return [];
    final root = XmlDocument.parse(utf8.decode(bytes));
    final result = <String>[];
    for (final item in root.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'response',
    )) {
      final href = item.childElements
          .where((e) => e.name.local == 'href')
          .firstOrNull
          ?.innerText;
      if (href == null) continue;
      final uri = base.resolve(href);
      if (uri.host != base.host ||
          uri.scheme != base.scheme ||
          uri.port != base.port) {
        continue;
      }
      final prefix = '${_uri(path).path.replaceFirst(RegExp(r'/$'), '')}/';
      final target = uri.path;
      if (!target.startsWith(prefix)) continue;
      final tail = target
          .substring(prefix.length)
          .replaceFirst(RegExp(r'/$'), '');
      if (tail.isNotEmpty && !tail.contains('/')) {
        result.add(Uri.decodeComponent(tail));
      }
    }
    if (result.length >= 750) {
      throw const FormatException('此目录达到网盘单次列举上限，请为本应用使用独立目录');
    }
    return result;
  }

  @override
  void close() {
    _closed = true;
    _client.close(force: true);
  }
}
