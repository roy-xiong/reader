import 'dart:convert';
import 'dart:typed_data';
import 'package:reader/data/cloud/cloud_secrets.dart';
import 'package:reader/data/cloud/webdav_store.dart';

class MemorySecrets extends CloudSecrets {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    this.value = value;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}

class MemoryDav {
  final files = <String, Uint8List>{};
  final directories = <String>{};
  bool offline = false;
  String? failPath;
  int puts = 0;
  CloudStore client() => _Client(this);
}

class _Client implements CloudStore {
  _Client(this.remote);
  final MemoryDav remote;
  bool closed = false;
  void check() {
    if (remote.offline || closed) throw const FormatException('离线');
  }

  @override
  Future<Uint8List?> read(
    String path, {
    int maxBytes = 16 * 1024 * 1024,
  }) async {
    check();
    final value = remote.files[path];
    if (value != null && value.length > maxBytes) {
      throw const FormatException('文件过大');
    }
    return value == null ? null : Uint8List.fromList(value);
  }

  @override
  Future<void> write(
    String path,
    List<int> bytes, {
    bool createOnly = false,
  }) async {
    check();
    if (remote.failPath != null && path.contains(remote.failPath!)) {
      throw const FormatException('模拟上传中断');
    }
    if (createOnly && remote.files.containsKey(path)) {
      throw const FormatException('已经存在');
    }
    remote.files[path] = Uint8List.fromList(bytes);
    remote.puts++;
  }

  @override
  Future<void> directory(String path) async {
    check();
    remote.directories.add(path);
  }

  @override
  Future<List<String>> list(String path) async {
    check();
    final prefix = '$path/';
    return {...remote.files.keys, ...remote.directories}
        .where((p) => p.startsWith(prefix))
        .map((p) => p.substring(prefix.length))
        .where((p) => p.isNotEmpty && !p.contains('/'))
        .toSet()
        .toList();
  }

  @override
  void close() {
    closed = true;
  }
}

String canonicalJson(Object? value) => jsonEncode(value);
