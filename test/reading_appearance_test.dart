import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/background_image_service.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/domain/models.dart';
import 'package:reader/domain/reading_appearance.dart';
import 'package:reader/ui/app_model.dart';
import 'package:reader/ui/reading_backdrop.dart';
import 'package:reader/ui/settings_screen.dart';
import 'package:reader/ui/reader_screen.dart';
import 'package:reader/ui/reader_pager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('照片设置兼容旧数据，并校验遮罩和轮换次数', () {
    final old = ReaderSettings.fromJson({});
    expect(old.backgroundMode, 'color');
    final setting = old.copyWith(
      backgroundMode: 'photos',
      photoDim: 1,
      photoTurnInterval: 3,
      photoIndex: 2,
      photoTurns: 1,
    );
    final saved = ReaderSettings.fromJson(setting.toJson());
    expect(saved.photoDim, 1);
    expect(saved.photoTurnInterval, 3);
    expect(saved.photoIndex, 2);
    expect(saved.photoTurns, 1);
    expect(
      ReaderSettings.fromJson({
        'photoDim': -5,
        'photoTurnInterval': 0,
      }).photoTurnInterval,
      1,
    );
    expect(ReaderSettings.fromJson({'photoDim': -5}).photoDim, 0);
  });

  test('照片缩小、导入去重、按翻页轮换、重启恢复及移除', () async {
    final root = await Directory.systemTemp.createTemp('reader_photo_test_');
    AppModel? model;
    try {
      final wide = File('${root.path}/风景.png');
      await wide.writeAsBytes(await _png(4000, 8, const Color(0xff408090)));
      final second = File('${root.path}/山林.png');
      await second.writeAsBytes(await _png(24, 32, const Color(0xff408040)));
      final normalized = await BackgroundImageService().normalize(wide);
      final codec = await ui.instantiateImageCodec(normalized);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 2048);
      expect(frame.image.height, 4);
      frame.image.dispose();
      codec.dispose();
      final repository = LibraryRepository(Directory('${root.path}/library'));
      model = AppModel(repository, _Platform([wide.path, second.path]));
      await model.initialize();
      await model.importPhotos();
      expect(model.photos.length, 2);
      expect(model.currentPhoto?.id, model.photos.first.id);
      await model.importPhotos();
      expect(model.photos.length, 2);
      model.updateSettings(
        model.settings.copyWith(photoTurnInterval: 2, photoDim: .7),
      );
      model.recordPageTurn();
      expect(model.currentPhoto?.id, model.photos.first.id);
      model.recordPageTurn();
      expect(model.currentPhoto?.id, model.photos.last.id);
      model.recordPageTurn();
      await model.flush();
      model.dispose();
      model = AppModel(repository, _Platform([]));
      await model.initialize();
      expect(model.photos.length, 2);
      expect(model.settings.photoTurns, 1);
      expect(model.settings.photoDim, .7);
      expect(model.currentPhoto?.id, model.photos.last.id);
      model.recordPageTurn();
      expect(model.currentPhoto?.id, model.photos.first.id);
      await model.removePhoto(model.photos.first.id);
      expect(model.photos.length, 1);
      await model.removePhoto(model.photos.single.id);
      expect(model.currentPhoto, isNull);
      expect(model.settings.backgroundMode, 'color');
    } finally {
      model?.dispose();
      await root.delete(recursive: true);
    }
  });

  test('八套主题成对应用，手动颜色与旧版颜色历史重启后保留', () async {
    final repository = _MemoryRepository();
    repository.saved = {
      'books': [],
      'fonts': [],
      'settings': const ReaderSettings(
        textColor: 0xff123456,
        backgroundColor: 0xff654321,
      ).toJson(),
    };
    var model = AppModel(repository, _Platform([]));
    await model.initialize();
    expect(model.textColors, contains(0xff123456));
    expect(model.backgroundColors, contains(0xff654321));
    model.setTextColor(0xff998877);
    model.setBackgroundColor(0xffabcdef);
    model.setTextColor(0xff998877);
    expect(model.textColors.where((color) => color == 0xff998877).length, 1);
    expect(ReadingPalette.presets.length, 8);
    for (final palette in ReadingPalette.presets) {
      model.applyPalette(palette);
      expect(model.settings.textColor, palette.text);
      expect(model.settings.backgroundColor, palette.background);
      expect(model.settings.backgroundMode, 'color');
    }
    await model.flush();
    model.dispose();
    model = AppModel(repository, _Platform([]));
    await model.initialize();
    expect(model.textColors, containsAll([0xff123456, 0xff998877]));
    expect(model.backgroundColors, containsAll([0xff654321, 0xffabcdef]));
    model.dispose();
  });

  testWidgets('自定义颜色在原颜色选择器中复用，照片遮罩支持两端值', (tester) async {
    final repository = _MemoryRepository();
    final model = AppModel(repository, _Platform([]));
    await model.initialize();
    model.setTextColor(0xff123456);
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(model: model)));
    await tester.tap(find.byKey(const ValueKey('settings-background')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('选择颜色').first);
    await tester.tap(find.text('选择颜色').first);
    await tester.pumpAndSettle();
    expect(find.text('我的自定义颜色'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('saved-color-4279383126')));
    await tester.pumpAndSettle();
    expect(model.settings.textColor, 0xff123456);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();

    final photoModel = AppModel(_PhotoRepository(), _Platform([]));
    await photoModel.initialize();
    for (final dim in [0.0, 1.0]) {
      photoModel.updateSettings(photoModel.settings.copyWith(photoDim: dim));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReadingBackdrop(
              model: photoModel,
              background: Colors.white,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<ColoredBox>(find.byKey(const ValueKey('photo-dark-mask')))
            .color
            .a,
        dim,
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    photoModel.dispose();
  });
  testWidgets('只有成功的正式翻页轮换照片，预览和书首无效操作不计数', (tester) async {
    final repository = _ReaderRepository();
    final model = AppModel(repository, _Platform([]));
    await model.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(
          model: model,
          book: repository.book,
          openSettings: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byType(ReaderPager));
    await tester.tapAt(rect.centerLeft + const Offset(20, 0));
    await tester.pumpAndSettle();
    expect(model.settings.photoTurns, 0);
    await tester.tapAt(rect.centerRight - const Offset(20, 0));
    await tester.pumpAndSettle();
    expect(model.settings.photoTurns, 1);
    final photo = model.currentPhoto!.id;
    await tester.tapAt(rect.center);
    await tester.pumpAndSettle();
    final slider = tester.getRect(
      find.byKey(const ValueKey('reading-seek-slider')),
    );
    final drag = await tester.startGesture(
      Offset(slider.left + 24, slider.center.dy),
    );
    await tester.pump();
    await drag.moveTo(Offset(slider.right - 32, slider.center.dy));
    await tester.pump(const Duration(milliseconds: 100));
    await drag.up();
    await tester.pumpAndSettle();
    expect(model.currentPhoto!.id, photo);
    expect(model.settings.photoTurns, 1);
    await tester.tap(find.byKey(const ValueKey('close-page-preview')));
    await tester.pumpAndSettle();
    await tester.tapAt(rect.centerRight - const Offset(20, 0));
    await tester.pumpAndSettle();
    expect(model.currentPhoto!.id, isNot(photo));
    expect(model.settings.photoTurns, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
  });
}

Future<Uint8List> _png(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

class _Platform extends PlatformService {
  _Platform(this.paths);
  final List<String> paths;
  @override
  Future<List<String>> pickImages() async => paths;
  @override
  Future<void> discard(List<String> paths) async {}
  @override
  Future<void> appearance(String theme) async {}
}

class _MemoryRepository extends LibraryRepository {
  _MemoryRepository() : super(Directory.systemTemp);
  Map<String, dynamic>? saved;
  @override
  Future<Map<String, dynamic>?> load() async => saved;
  @override
  Future<void> save(Map<String, dynamic> snapshot) async {
    saved = snapshot;
  }

  @override
  Future<List<ReaderFont>> recoverFonts(
    List<ReaderFont> catalog, {
    String? selectedId,
    String? selectedName,
  }) async => catalog;
}

class _PhotoRepository extends _MemoryRepository {
  @override
  Future<Map<String, dynamic>?> load() async => {
    'books': [],
    'fonts': [],
    'photos': [
      BackgroundPhoto(
        id: List.filled(64, 'e').join(),
        name: '背景',
        bytes: 1,
      ).toJson(),
    ],
    'settings': const ReaderSettings(backgroundMode: 'photos').toJson(),
  };
}

class _ReaderRepository extends _MemoryRepository {
  final document = BookDocument(
    title: '照片轮换测试',
    author: '',
    text: List.filled(200, '阅读正文，照片不应在进度预览中轮换。\n\n').join(),
    chapters: [
      Chapter(
        title: '第一章',
        start: 0,
        end: List.filled(200, '阅读正文，照片不应在进度预览中轮换。\n\n').join().length,
      ),
    ],
  );
  late final book = BookRecord(
    id: List.filled(64, 'd').join(),
    title: document.title,
    author: '',
    format: 'TXT',
    length: document.text.length,
    importedAt: 1,
  );
  @override
  Future<Map<String, dynamic>?> load() async => {
    'books': [book.toJson()],
    'fonts': [],
    'photos': [
      for (final letter in ['a', 'b'])
        BackgroundPhoto(
          id: List.filled(64, letter).join(),
          name: letter,
          bytes: 1,
        ).toJson(),
    ],
    'settings': const ReaderSettings(
      backgroundMode: 'photos',
      photoTurnInterval: 2,
      pageEffect: 'none',
    ).toJson(),
  };
  @override
  Future<BookDocument> open(BookRecord book) async => document;
}
