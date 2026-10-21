import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/cloud/cloud_crypto.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/ui/app_model.dart';
import 'support/cloud_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final kind in ['font', 'book', 'photo']) {
    for (final legacy in [false, true]) {
      test('$kind（旧版迁移=$legacy）：云端下载 A 后导入 B，只上传 B，重启后保持', () async {
        final dir = await Directory.systemTemp.createTemp('cloud_origin_$kind');
        final remote = MemoryDav(), secrets = MemorySecrets();
        final aPlatform = _Platform(), bPlatform = _Platform();
        AppModel make(
          String name,
          _Platform platform,
          MemorySecrets credentials,
        ) => AppModel(
          LibraryRepository(Directory('${dir.path}/$name')),
          platform,
          cloudSecrets: credentials,
          cloudStoreFactory: (_, _, _) => remote.client(),
        );
        final a = make('a', aPlatform, MemorySecrets());
        var b = make('b', bPlatform, secrets);
        final recovery = CloudCrypto.newRecoveryCode();
        try {
          await a.initialize();
          await b.initialize();
          await _importLocal(a, aPlatform, dir, kind, 'A', 1);
          await a.cloud.connect(
            server: 'https://e.test/',
            username: 'a',
            password: 'p',
            root: '阅读',
            recoveryCode: recovery,
            create: true,
          );
          await b.cloud.connect(
            server: 'https://e.test/',
            username: 'a',
            password: 'p',
            root: '阅读',
            recoveryCode: recovery,
            create: false,
          );
          await a.cloud.upload(kind);
          await b.cloud.refresh();
          await b.cloud.download(b.cloud.items.single);
          expect(b.cloud.error, isNull);
          if (legacy) {
            final old = b.snapshot()..remove('assetOrigins');
            await b.repository.save(old);
            b.dispose();
            b = make('b', bPlatform, secrets);
            await b.initialize();
            await b.cloud.initialize();
          }
          await _importLocal(b, bPlatform, dir, kind, 'B', 2);
          await b.flush();
          b.dispose();
          b = make('b', bPlatform, secrets);
          await b.initialize();
          await b.cloud.initialize();
          await b.cloud.upload(kind);
          expect(b.cloud.error, isNull);
          expect(b.cloud.completedFiles, 1, reason: '云端下载的 A 不应混入本地 B 的上传批次');
          expect(b.cloud.items.length, 2);
        } finally {
          a.dispose();
          b.dispose();
          await Future<void>.delayed(const Duration(milliseconds: 150));
          await dir.delete(recursive: true);
        }
      });
    }
  }
}

Future<void> _importLocal(
  AppModel model,
  _Platform platform,
  Directory root,
  String kind,
  String name,
  int value,
) async {
  if (kind == 'photo') {
    final file = File('${root.path}/$name.png');
    await file.writeAsBytes(await png(value));
    platform.paths = [file.path];
    await model.importPhotos();
  } else {
    final file = File('${root.path}/$name.${kind == 'font' ? 'ttf' : 'txt'}');
    await file.writeAsBytes(
      kind == 'font'
          ? [0, 1, 0, 0, ...List.filled(24, value)]
          : utf8.encode('第一章 $name\n\n正文$value。'),
    );
    await model.importTransferredFile(file.path, kind);
  }
}

Future<Uint8List> png(int value) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 16, 24),
    Paint()..color = (value == 1 ? Colors.red : Colors.blue),
  );
  final picture = recorder.endRecording(),
      image = await picture.toImage(16, 24);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

class _Platform extends PlatformService {
  List<String> paths = [];
  @override
  Future<List<String>> pickImages() async => paths;
  @override
  Future<void> discard(List<String> paths) async {}
  @override
  Future<void> appearance(String theme) async {}
}
