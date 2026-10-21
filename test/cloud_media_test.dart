import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/data/cloud/cloud_crypto.dart';
import 'package:reader/ui/app_model.dart';
import 'support/cloud_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('照片、重叠图片组和字体手动上传下载，批量传输有可见字节进度，其他外观设置保持本机', () async {
    final root = await Directory.systemTemp.createTemp('reader_cloud_media');
    final remote = MemoryDav();
    final first = File('${root.path}/山林.png'),
        second = File('${root.path}/海边.png');
    await first.writeAsBytes(await png(const Color(0xff408060)));
    await second.writeAsBytes(await png(const Color(0xff406080)));
    final a = AppModel(
      LibraryRepository(Directory('${root.path}/a')),
      _Platform([first.path, second.path]),
      cloudSecrets: MemorySecrets(),
      cloudStoreFactory: (_, _, _) => remote.client(),
    );
    final b = AppModel(
      LibraryRepository(Directory('${root.path}/b')),
      _Platform([]),
      cloudSecrets: MemorySecrets(),
      cloudStoreFactory: (_, _, _) => remote.client(),
    );
    final values = <double>[];
    try {
      await a.initialize();
      await b.initialize();
      await a.importPhotos();
      final ids = a.photos.map((p) => p.id).toList();
      final group = a.savePhotoGroup(name: '风景', photoIds: ids)!;
      a.savePhotoGroup(name: '海边', photoIds: ids.skip(1));
      a.selectPhotoGroup(group);
      a.setPhotoTextColor(0xff123456);
      // 只验证传输和本地字体签名校验，不在测试中将人工 SFNT 加载为可绘制字体。
      final font = File('${root.path}/测试字体.ttf');
      await font.writeAsBytes([0, 1, 0, 0, ...List.filled(24, 0)]);
      await a.importTransferredFile(font.path, 'font');
      final recovery = CloudCrypto.newRecoveryCode();
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
      await b.cloud.refresh();
      expect(b.cloud.items, isEmpty, reason: '连接和刷新不自动上传字体或照片');
      a.cloud.addListener(() {
        final p = a.cloud.fraction;
        if (p != null) values.add(p);
      });
      await a.cloud.upload('photo');
      await a.cloud.upload('font');
      expect(a.cloud.error, isNull);
      expect(values.any((p) => p > 0), isTrue);
      expect(values.every((p) => p >= 0 && p <= 1), isTrue);
      await b.cloud.refresh();
      expect(b.cloud.items.length, 3);
      await b.cloud.downloadAll(b.cloud.items);
      expect(b.cloud.error, isNull);
      expect(b.cloud.completedFiles, 3);
      expect(b.photos.length, 2);
      expect(b.fonts.single.name, '测试字体');
      expect(
        b.photoGroups.firstWhere((g) => g.id == group).photoIds.toSet(),
        ids.toSet(),
      );
      expect(b.settings.backgroundMode, 'color');
      expect(b.settings.photoTextColor, isNull);
      a.savePhotoGroup(id: group, name: '新的风景', photoIds: ids.skip(1));
      await a.cloud.upload('photo');
      await b.cloud.refresh();
      await b.cloud.downloadAll(
        b.cloud.items.where((i) => i.kind == 'photo').toList(),
      );
      expect(b.photoGroups.firstWhere((g) => g.id == group).name, '新的风景');
      expect(b.photoGroups.firstWhere((g) => g.id == group).photoIds, [ids[1]]);
    } finally {
      a.dispose();
      b.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await root.delete(recursive: true);
    }
  });
}

Future<Uint8List> png(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(
    recorder,
  ).drawRect(const Rect.fromLTWH(0, 0, 16, 24), Paint()..color = color);
  final picture = recorder.endRecording();
  final image = await picture.toImage(16, 24);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    picture.dispose();
    image.dispose();
  }
}

class _Platform extends PlatformService {
  _Platform(this.paths);
  final List<String> paths;
  @override
  Future<List<String>> pickImages() async => paths;
  @override
  Future<void> appearance(String theme) async {}
  @override
  Future<void> discard(List<String> paths) async {}
}
