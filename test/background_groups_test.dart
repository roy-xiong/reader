import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/domain/models.dart';
import 'package:reader/domain/reading_appearance.dart';
import 'package:reader/ui/app_model.dart';
import 'package:reader/ui/appearance_settings.dart';
import 'package:reader/ui/background_groups.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('重叠图片组 123/234 独立循环，颜色、选择组及位置重启保留', () async {
    final repository = _Repository();
    var model = AppModel(repository, _Platform());
    await model.initialize();
    final ids = model.photos.map((p) => p.id).toList();
    final group1 = model.savePhotoGroup(name: '一组', photoIds: ids.take(3));
    final group2 = model.savePhotoGroup(name: '二组', photoIds: ids.skip(1));
    model.selectPhotoGroup(group1);
    final turns = <String?>[];
    for (var i = 0; i < 7; i++) {
      turns.add(model.currentPhoto?.id);
      model.recordPageTurn();
    }
    expect(turns, [ids[0], ids[1], ids[2], ids[0], ids[1], ids[2], ids[0]]);
    model.selectPhotoGroup(group2);
    expect(model.activePhotos.map((p) => p.id), ids.skip(1));
    expect(model.currentPhoto?.id, ids[1]);
    model.recordPageTurn();
    expect(model.currentPhoto?.id, ids[2]);
    model.setTextColor(0xff123456);
    model.setPhotoTextColor(0xffaabbcc);
    expect(model.settings.backgroundMode, 'photos');
    expect(model.settings.textColor, 0xff123456);
    expect(model.textColors, contains(0xffaabbcc));
    await model.flush();
    model.dispose();
    model = AppModel(repository, _Platform());
    await model.initialize();
    expect(model.settings.photoGroupId, group2);
    expect(model.currentPhoto?.id, ids[2]);
    expect(model.settings.photoTextColor, 0xffaabbcc);
    expect(model.textColors, contains(0xffaabbcc));
    // 组中删除成员会同时清理引用；文件只有从照片库移除时才删除。
    await model.removePhoto(ids[1]);
    expect(
      model.photoGroups.every((g) => !g.photoIds.contains(ids[1])),
      isTrue,
    );
    expect(model.currentPhoto?.id, ids[2]);
    model.removePhotoGroup(group2!);
    expect(model.photos.length, 3);
    expect(model.settings.photoGroupId, isNull);
    final empty = model.savePhotoGroup(name: '空组', photoIds: []);
    model.selectPhotoGroup(empty);
    model.recordPageTurn();
    expect(model.currentPhoto, isNull);
    expect(model.activePhotos, isEmpty);
    model.dispose();
  });

  testWidgets('新建、编辑、选择共享成员；照片文字颜色入口不改变普通主题颜色', (tester) async {
    final model = AppModel(_Repository(), _Platform());
    await model.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: model,
            builder: (_, _) =>
                SingleChildScrollView(child: AppearanceSettings(model: model)),
          ),
        ),
      ),
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('create-photo-group')),
    );
    await tester.tap(find.byKey(const ValueKey('create-photo-group')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('photo-group-name')),
      '山水',
    );
    final id = model.photos[1].id;
    await tester.tap(find.byKey(ValueKey('group-photo-$id')));
    await tester.tap(find.byKey(const ValueKey('save-photo-group')));
    await tester.pumpAndSettle();
    expect(model.photoGroups.single.name, '山水');
    expect(model.activePhotos.single.id, id);
    expect(find.byType(BackgroundGroups), findsOneWidget);
    final color = find.byKey(const ValueKey('photo-text-color'));
    await tester.scrollUntilVisible(
      color,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('选择文字颜色'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('hex-color-input')),
      '445566',
    );
    await tester.tap(find.text('使用颜色'));
    await tester.pumpAndSettle();
    expect(model.settings.photoTextColor, 0xff445566);
    expect(model.settings.textColor, isNull);
    expect(model.settings.backgroundMode, 'photos');
    expect(model.textColors, contains(0xff445566));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });
}

class _Repository extends LibraryRepository {
  _Repository()
    : super(
        Directory('${Directory.systemTemp.path}/nonexistent-reader-group-test'),
      );
  Map<String, dynamic>? saved;
  @override
  Future<Map<String, dynamic>?> load() async =>
      saved ??
      {
        'books': [],
        'fonts': [],
        'photos': [
          for (final c in ['a', 'b', 'c', 'd'])
            BackgroundPhoto(id: c * 64, name: c, bytes: 1).toJson(),
        ],
        'settings': const ReaderSettings(
          backgroundMode: 'photos',
          photoTurnInterval: 1,
        ).toJson(),
      };
  @override
  Future<void> save(Map<String, dynamic> value) async {
    saved = value;
  }

  @override
  Future<List<ReaderFont>> recoverFonts(
    List<ReaderFont> catalog, {
    String? selectedId,
    String? selectedName,
  }) async => catalog;
}

class _Platform extends PlatformService {
  @override
  Future<void> appearance(String theme) async {}
}
