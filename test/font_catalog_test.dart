import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/data/font_service.dart';
import 'package:reader/data/library_repository.dart';
import 'package:reader/data/platform_service.dart';
import 'package:reader/domain/models.dart';
import 'package:reader/ui/app_model.dart';

void main() {
  test('批量导入、切换、去重与重启后字体列表保持一致', () async {
    final directory = await Directory.systemTemp.createTemp(
      'reader_font_catalog_',
    );
    AppModel? model;
    try {
      final a = File('${directory.path}/字体甲.ttf');
      final b = File('${directory.path}/字体乙.otf');
      await a.writeAsBytes([0, 1, 0, 0, ...List.filled(8, 0), 1]);
      await b.writeAsBytes([0, 1, 0, 0, ...List.filled(8, 0), 2]);
      final repository = LibraryRepository(
        Directory('${directory.path}/library'),
      );
      final loader = _FontLoader();
      final picker = _FontPicker([a.path, b.path]);
      model = AppModel(repository, picker, fontService: loader);
      await model.initialize();
      await model.importFont();
      expect(model.fonts.map((font) => font.name), ['字体甲', '字体乙']);
      expect(model.settings.fontId, model.fonts[1].id);
      expect(loader.registered.length, 1, reason: '批量导入只加载最后选中的字体');
      final first = model.fonts.first.id, second = model.fonts.last.id;
      await model.selectFont(first);
      await model.selectFont(second);
      await model.selectFont(first);
      expect(loader.registered.length, 2, reason: '切换回已加载字体时不能重复注册');
      await model.importFont();
      expect(model.fonts.length, 2, reason: '重复文件不能生成重复记录');
      await model.selectFont(null);
      expect(model.settings.fontId, isNull);
      expect(model.fonts.length, 2);
      await model.selectFont(second);
      model.dispose();
      model = null;
      final restarted = AppModel(
        repository,
        _FontPicker([]),
        fontService: _FontLoader(),
      );
      model = restarted;
      await restarted.initialize();
      expect(restarted.fonts.map((font) => font.id), [first, second]);
      expect(restarted.settings.fontId, second);
      await restarted.selectFont(first);
      expect(restarted.settings.fontName, '字体甲');
    } finally {
      model?.dispose();
      await directory.delete(recursive: true);
    }
  });

  test('旧版没有字体列表时恢复当前字体及其他已导入字体', () async {
    final directory = await Directory.systemTemp.createTemp(
      'reader_font_migration_',
    );
    AppModel? model;
    try {
      final repository = LibraryRepository(
        Directory('${directory.path}/library'),
      );
      final source = File('${directory.path}/old.ttf');
      await source.writeAsBytes([0, 1, 0, 0, ...List.filled(8, 0), 1]);
      final first = await repository.importFont(source.path);
      await source.writeAsBytes([0, 1, 0, 0, ...List.filled(8, 0), 2]);
      final second = await repository.importFont(source.path);
      await repository.save({
        'version': 1,
        'books': <Map<String, dynamic>>[],
        'settings': ReaderSettings(fontId: first, fontName: '旧版字体').toJson(),
        'pin': null,
      });
      model = AppModel(repository, _FontPicker([]), fontService: _FontLoader());
      await model.initialize();
      expect(model.fonts.map((font) => font.id), containsAll([first, second]));
      expect(model.fonts.firstWhere((font) => font.id == first).name, '旧版字体');
      expect(((await repository.load())?['fonts'] as List).length, 2);
    } finally {
      model?.dispose();
      await directory.delete(recursive: true);
    }
  });
}

class _FontLoader extends FontService {
  final registered = <String>[];
  @override
  Future<void> register(File file, String family) async {
    registered.add(family);
  }
}

class _FontPicker extends PlatformService {
  _FontPicker(this.paths);
  final List<String> paths;
  @override
  Future<List<String>> pick({bool folder = false, bool font = false}) async =>
      paths;
  @override
  Future<void> discard(List<String> paths) async {}
}
