import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:crypto/crypto.dart';
import '../../domain/cloud/cloud_models.dart';
import 'cloud_crypto.dart';
import 'webdav_store.dart';

/// 2MiB 有界块加密和传输，字体不设人为大小上限。单文件失败可以重试，最终做完整散列校验。
class CloudAssets {
  CloudAssets(this.store, this.crypto, this.root, this.libraryId);
  final CloudStore store;
  final CloudCrypto crypto;
  final String root, libraryId;
  static const blockSize = 2 * 1024 * 1024;
  final _directories = <String>{};
  Future<void> ensureDirectory(String path) async {
    final parts = path.split('/');
    for (var i = 1; i <= parts.length; i++) {
      final dir = parts.take(i).join('/');
      if (_directories.add(dir)) {
        try {
          await store.directory(dir);
        } catch (_) {
          _directories.remove(dir);
          rethrow;
        }
      }
    }
  }

  static Future<String> hash(File file) => Isolate.run(
    () async => (await sha256.bind(file.openRead()).first).toString(),
  );
  String _binding(String kind, String id, String digest, int index, int size) =>
      '$libraryId/asset/$kind/$id/$digest/$index/$size';
  String folder(String kind, String id, String digest) =>
      '$root/${switch (kind) {
        'book' => '书籍',
        'font' => '字体',
        _ => '照片',
      }}/$id/$digest';

  Future<CloudItem> upload(
    CloudSource source, {
    required void Function(int, int) progress,
    required bool Function() cancelled,
  }) async {
    final files = <String, Map<String, dynamic>>{};
    final total = await source.files.values.fold<Future<int>>(
      Future.value(0),
      (future, file) async => await future + await file.length(),
    );
    var done = 0;
    for (final slot in source.files.entries) {
      final file = slot.value,
          size = await slot.value.length(),
          digest = await hash(slot.value);
      final dir = folder(source.kind, source.id, digest);
      await ensureDirectory(dir);
      final handle = await file.open();
      final count = max(1, (size / blockSize).ceil());
      try {
        for (var index = 0; index < count; index++) {
          if (cancelled()) throw const FormatException('同步已取消');
          final bytes = await handle.read(blockSize);
          final name = '${index.toString().padLeft(8, '0')}.bin';
          {
            final encrypted = await crypto.encrypt(
              bytes,
              _binding(source.kind, source.id, digest, index, size),
            );
            await store.write('$dir/$name', encrypted);
          }
          done += bytes.length;
          progress(done, total);
        }
      } finally {
        await handle.close();
      }
      if (await file.length() != size || await hash(file) != digest) {
        throw const FormatException('本机文件正在更新，请稍后重新上传');
      }
      files[slot.key] = {
        'sha256': digest,
        'size': size,
        'blocks': count,
        'blockSize': blockSize,
      };
    }
    return CloudItem(
      kind: source.kind,
      id: source.id,
      name: source.name,
      metadata: source.metadata,
      files: files,
    );
  }

  Future<Map<String, File>> download(
    CloudItem item,
    Directory temporary, {
    required void Function(int, int) progress,
    required bool Function() cancelled,
  }) async {
    final files = <String, File>{};
    var completed = 0;
    await temporary.create(recursive: true);
    for (final slot in item.files.entries) {
      if (!['original', 'document', 'font', 'photo'].contains(slot.key)) {
        continue; // 新端扩展的附件由云端原样保留，旧端只下载能识别的资源。
      }
      final manifest = slot.value,
          digest = manifest['sha256'] as String,
          size = manifest['size'] as int,
          count = manifest['blocks'] as int,
          block = manifest['blockSize'] as int;
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
          size < 0 ||
          block != blockSize ||
          count != max(1, (size / blockSize).ceil())) {
        throw const FormatException('云端文件清单无效');
      }
      final target = File('${temporary.path}/${slot.key}.part');
      final output = await target.open(mode: FileMode.write);
      var received = 0;
      try {
        for (var index = 0; index < count; index++) {
          if (cancelled()) throw const FormatException('同步已取消');
          final path =
              '${folder(item.kind, item.id, digest)}/${index.toString().padLeft(8, '0')}.bin';
          final encrypted = await store.read(path, maxBytes: blockSize + 100);
          if (encrypted == null) {
            throw const FormatException('云端文件未上传完整，请在原设备重新上传');
          }
          final data = await crypto.decrypt(
            encrypted,
            _binding(item.kind, item.id, digest, index, size),
          );
          final expected = min(blockSize, size - received);
          if (data.length != expected) throw const FormatException('文件块长度校验失败');
          await output.writeFrom(data);
          received += data.length;
          completed += data.length;
          progress(completed, item.bytes);
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (received != size || await hash(target) != digest) {
        throw const FormatException('下载内容校验失败，已保留原本地文件');
      }
      files[slot.key] = target;
    }
    return files;
  }
}
