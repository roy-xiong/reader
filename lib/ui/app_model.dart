import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../data/library_repository.dart';
import '../data/font_service.dart';
import '../data/platform_service.dart';
import '../domain/models.dart';
import '../domain/book_relocation.dart';
import '../domain/reading_appearance.dart';
import '../data/background_image_service.dart';
import '../data/cloud/cloud_assets.dart';
import '../data/cloud/cloud_secrets.dart';
import '../data/cloud/webdav_store.dart';
import '../domain/cloud/cloud_models.dart';
import 'cloud/cloud_sync_controller.dart';
import 'dart:convert';

/// 应用状态的唯一写入口。界面仅观察状态，持久化操作始终经过仓库串行队列。
class AppModel extends ChangeNotifier {
  AppModel(
    this.repository,
    this.platform, {
    FontService? fontService,
    BackgroundImageService? imageService,
    CloudSecrets? cloudSecrets,
    CloudStore Function(String, String, String)? cloudStoreFactory,
  }) : fontService = fontService ?? FontService(),
       imageService = imageService ?? BackgroundImageService() {
    cloud = CloudSyncController(
      directory: Directory('${repository.root.path}/cloud'),
      sources: _cloudSources,
      receive: _receiveCloudItem,
      isUnavailable: () => busy || locked,
      secrets: cloudSecrets,
      storeFactory: cloudStoreFactory,
    );
    cloud.addListener(changed);
  }
  late final CloudSyncController cloud;
  final FontService fontService;
  final BackgroundImageService imageService;
  List<BackgroundPhoto> _photos = [];
  List<BackgroundPhotoGroup> _photoGroups = [];
  List<BackgroundPhotoGroup> get photoGroups => List.unmodifiable(_photoGroups);

  /// 当前组的有序照片；null 表示全部照片，空组不会回退到其他组。
  List<BackgroundPhoto> get activePhotos {
    final group = _photoGroups
        .where((group) => group.id == settings.photoGroupId)
        .firstOrNull;
    if (group == null) return photos;
    final byId = {for (final photo in _photos) photo.id: photo};
    return List.unmodifiable(
      group.photoIds.map((id) => byId[id]).whereType<BackgroundPhoto>(),
    );
  }

  List<int> _textColors = [], _backgroundColors = [];
  List<BackgroundPhoto> get photos => List.unmodifiable(_photos);
  List<int> get textColors => List.unmodifiable(_textColors);
  List<int> get backgroundColors => List.unmodifiable(_backgroundColors);
  BackgroundPhoto? get currentPhoto {
    if (settings.backgroundMode != 'photos') return null;
    final candidates = activePhotos;
    return candidates.isEmpty
        ? null
        : candidates[settings.photoIndex % candidates.length];
  }

  final Set<String> _registeredFonts = {};
  List<ReaderFont> _fonts = [];
  List<ReaderFont> get fonts => List.unmodifiable(_fonts);
  final LibraryRepository repository;
  final PlatformService platform;
  ReaderSettings settings = const ReaderSettings();
  List<BookRecord> _books = [];
  List<BookRecord> get books => List.unmodifiable(_books);
  Map<String, dynamic>? _pin;
  bool get hasPin => _pin != null;
  bool locked = false, busy = false, pinBusy = false;
  int failedAttempts = 0, blockedUntil = 0;
  String? error, busyLabel;
  String? loadedFontId;
  String photoAccess = 'system';
  Timer? _saveTimer;
  bool _disposed = false;
  void changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> initialize() async {
    final data = await repository.load();
    if (data != null) {
      settings = ReaderSettings.fromJson(
        Map<String, dynamic>.from(data['settings'] as Map),
      );
      _books = (data['books'] as List)
          .map((b) => BookRecord.fromJson(Map<String, dynamic>.from(b as Map)))
          .toList();
      _photos = (data['photos'] as List? ?? [])
          .map(
            (value) => BackgroundPhoto.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .toList();
      final photoIds = _photos.map((photo) => photo.id).toSet();
      _photoGroups = (data['photoGroups'] as List? ?? []).whereType<Map>().map((
        value,
      ) {
        final group = BackgroundPhotoGroup.fromJson(
          Map<String, dynamic>.from(value),
        );
        return BackgroundPhotoGroup(
          id: group.id,
          name: group.name,
          photoIds: List.unmodifiable(group.photoIds.where(photoIds.contains)),
        );
      }).toList();
      if (!_photoGroups.any((group) => group.id == settings.photoGroupId)) {
        settings = settings.copyWith(resetPhotoGroup: true);
      }
      _textColors = _readColors(data['textColors']);
      _backgroundColors = _readColors(data['backgroundColors']);
      // 旧版单独设置过的颜色也迁入可选历史，不因升级或切换主题丢失。
      _rememberColor(_textColors, settings.textColor);
      _rememberColor(_textColors, settings.photoTextColor);
      _rememberColor(_backgroundColors, settings.backgroundColor);
      _pin = data['pin'] == null
          ? null
          : Map<String, dynamic>.from(data['pin'] as Map);
      failedAttempts = data['failedAttempts'] as int? ?? 0;
      blockedUntil = data['blockedUntil'] as int? ?? 0;
      locked = hasPin;
      final catalog = (data['fonts'] as List? ?? [])
          .map((f) => ReaderFont.fromJson(Map<String, dynamic>.from(f as Map)))
          .toList();
      _fonts = await repository.recoverFonts(
        catalog,
        selectedId: settings.fontId,
        selectedName: settings.fontName,
      );
      if (data['fonts'] == null || _fonts.length != catalog.length) {
        await flush();
      }
      try {
        await loadFont();
      } catch (_) {
        error = '自定义字体暂不可用，已使用系统字体';
      }
    }
    await platform.appearance(settings.theme);
    if (Platform.isIOS) await refreshPhotoAccess();
    changed();
  }

  Map<String, dynamic> snapshot() => {
    'version': 4,
    'photoGroups': _photoGroups.map((group) => group.toJson()).toList(),
    'photos': _photos.map((photo) => photo.toJson()).toList(),
    'textColors': _textColors,
    'backgroundColors': _backgroundColors,
    'fonts': _fonts.map((f) => f.toJson()).toList(),
    'settings': settings.toJson(),
    'books': _books.map((b) => b.toJson()).toList(),
    'pin': _pin,
    'failedAttempts': failedAttempts,
    'blockedUntil': blockedUntil,
  };
  Future<void> flush() async {
    _saveTimer?.cancel();
    try {
      await repository.save(snapshot());
    } catch (_) {
      error = '保存失败，请检查可用存储空间';
      changed();
      rethrow;
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), () {
      unawaited(flush().catchError((Object _) {}));
    });
  }

  void clearError() {
    error = null;
    changed();
  }

  Future<void> importBooks({bool folder = false}) async {
    if (busy || locked) {
      return;
    }
    busy = true;
    busyLabel = '选择电子书';
    changed();
    final failures = <String>[];
    var imported = 0;
    var paths = <String>[];
    try {
      paths = await platform.pick(folder: folder);
      for (var i = 0; i < paths.length; i++) {
        busyLabel = '导入 ${i + 1}/${paths.length}';
        changed();
        try {
          final book = await repository.import(paths[i]);
          if (!_books.any((b) => b.id == book.id)) {
            _books = [..._books, book];
            imported++;
          }
          await flush();
        } catch (e) {
          failures.add(
            '${p.basename(paths[i]).replaceFirst(RegExp(r"^[a-f0-9-]{36}_"), "")}: ${_message(e)}',
          );
        }
      }
      if (failures.isNotEmpty) {
        error =
            '已导入 $imported 本；${failures.take(3).join('；')}${failures.length > 3 ? '…' : ''}';
      }
    } catch (e) {
      error = _message(e);
    } finally {
      busy = false;
      busyLabel = null;
      await platform.discard(paths);
      changed();
    }
  }

  BookRecord? findBook(String id) =>
      _books.where((b) => b.id == id).firstOrNull;
  void updateProgress(
    String id,
    int offset, {
    String quote = '',
    int parseVersion = 2,
  }) {
    _books = _books
        .map(
          (b) => b.id == id
              ? b.copyWith(
                  offset: offset.clamp(0, max(0, b.length - 1)),
                  lastOpened: DateTime.now().millisecondsSinceEpoch,
                )
              : b,
        )
        .toList();
    final record = findBook(id);
    if (record != null) {
      cloud.recordProgress(
        bookId: id,
        offset: record.offset,
        length: record.length,
        updatedAt: record.lastOpened,
        quote: quote,
        parseVersion: parseVersion,
      );
    }
    _scheduleSave();
    changed();
  }

  Future<void> toggleBookmark(String id, int offset, String quote) async {
    _books = _books.map((b) {
      if (b.id != id) {
        return b;
      }
      final marks = List<BookMark>.of(b.bookmarks);
      final index = marks.indexWhere((m) => m.offset == offset);
      if (index >= 0) {
        marks.removeAt(index);
      } else {
        marks.add(
          BookMark(
            offset: offset,
            quote: quote,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      marks.sort((a, b) => a.offset.compareTo(b.offset));
      return b.copyWith(bookmarks: marks);
    }).toList();
    changed();
    await flush();
  }

  final Map<String, Future<BookDocument>> _opening = {};

  Future<BookDocument> openBook(BookRecord requested) => _opening.putIfAbsent(
    requested.id,
    () => _openBook(requested).whenComplete(() {
      _opening.remove(requested.id);
    }),
  );

  /// 升级目录缓存并迁移书架定位，升级失败时继续保留原缓存供阅读。
  Future<BookDocument> _openBook(BookRecord requested) async {
    final stored = await repository.open(requested);
    if (stored.parseVersion >= BookDocument.currentParseVersion) {
      return stored;
    }
    final previousBook = findBook(requested.id) ?? requested;
    try {
      final updated = await repository.parseOriginal(previousBook);
      if (updated == null) {
        return stored;
      }
      final relocated = await BookRelocation.inBackground(
        previousBook,
        stored,
        updated,
      );
      await repository.replaceDocument(previousBook.id, updated);
      _books = _books
          .map((book) => book.id == relocated.id ? relocated : book)
          .toList();
      try {
        await flush();
      } catch (_) {
        _books = _books
            .map((book) => book.id == previousBook.id ? previousBook : book)
            .toList();
        await repository.replaceDocument(previousBook.id, stored);
        rethrow;
      }
      changed();
      return updated;
    } catch (_) {
      error = '目录更新未完成，已保留原缓存';
      changed();
      return stored;
    }
  }

  Future<void> deleteBook(String id) async {
    if (busy) {
      return;
    }
    final previous = _books;
    _books = _books.where((b) => b.id != id).toList();
    changed();
    try {
      await flush();
    } catch (_) {
      _books = previous;
      changed();
      rethrow;
    }
    await repository.deleteFiles(id);
  }

  void updateSettings(ReaderSettings value) {
    final themeChanged = settings.theme != value.theme;
    settings = value;
    if (themeChanged) {
      unawaited(platform.appearance(value.theme));
    }
    changed();
    _scheduleSave();
  }

  static List<int> _readColors(dynamic value) => value is List
      ? value
            .whereType<int>()
            .map((color) => 0xff000000 | (color & 0xffffff))
            .toSet()
            .toList()
      : [];

  static void _rememberColor(List<int> colors, int? value) {
    if (value == null) {
      return;
    }
    final color = 0xff000000 | (value & 0xffffff);
    colors.remove(color);
    colors.insert(0, color);
  }

  void setTextColor(int color) {
    _rememberColor(_textColors, settings.textColor);
    _rememberColor(_textColors, color);
    updateSettings(settings.copyWith(textColor: color));
  }

  /// 照片文字色独立保存，并复用字体颜色历史；不会退出照片背景。
  void setPhotoTextColor(int color) {
    _rememberColor(_textColors, settings.photoTextColor);
    _rememberColor(_textColors, color);
    updateSettings(settings.copyWith(photoTextColor: color));
  }

  void setBackgroundColor(int color) {
    _rememberColor(_backgroundColors, settings.backgroundColor);
    _rememberColor(_backgroundColors, color);
    updateSettings(
      settings.copyWith(backgroundColor: color, backgroundMode: 'color'),
    );
  }

  void applyPalette(ReadingPalette palette) {
    _rememberColor(_textColors, settings.textColor);
    _rememberColor(_backgroundColors, settings.backgroundColor);
    updateSettings(
      settings.copyWith(
        textColor: palette.text,
        backgroundColor: palette.background,
        backgroundMode: 'color',
      ),
    );
  }

  /// 仅正式前后翻页调用。目录、搜索、进度预览和书首书尾的无效操作不累计。
  void recordPageTurn() {
    if (currentPhoto == null) {
      return;
    }
    final turns = settings.photoTurns + 1;
    final switchPhoto = turns >= settings.photoTurnInterval;
    updateSettings(
      settings.copyWith(
        photoTurns: switchPhoto ? 0 : turns,
        photoIndex: switchPhoto
            ? (settings.photoIndex + 1) % activePhotos.length
            : settings.photoIndex,
      ),
    );
  }

  void selectPhoto(int index) {
    if (index < 0 || index >= activePhotos.length) {
      return;
    }
    updateSettings(
      settings.copyWith(
        backgroundMode: 'photos',
        photoIndex: index,
        photoTurns: 0,
      ),
    );
  }

  /// 只改变活动组和轮换游标，不复制照片。恢复上次设置时仍停留在同一组。
  void selectPhotoGroup(String? id) {
    if (busy ||
        locked ||
        (id != null && !_photoGroups.any((group) => group.id == id))) {
      return;
    }
    updateSettings(
      settings.copyWith(
        photoGroupId: id,
        resetPhotoGroup: id == null,
        backgroundMode: 'photos',
        photoIndex: 0,
        photoTurns: 0,
      ),
    );
  }

  /// 新建或编辑组；成员使用内容标识，可在多组中共享。返回稳定 ID 供界面选择。
  String? savePhotoGroup({
    String? id,
    required String name,
    required Iterable<String> photoIds,
  }) {
    if (busy || locked || name.trim().isEmpty) return null;
    final available = _photos.map((photo) => photo.id).toSet();
    final identifier =
        id ??
        'group_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1000000)}';
    final group = BackgroundPhotoGroup(
      id: identifier,
      name: name.trim(),
      photoIds: List.unmodifiable(photoIds.where(available.contains).toSet()),
    );
    _photoGroups = [
      ..._photoGroups.where((item) => item.id != identifier),
      group,
    ];
    updateSettings(settings.copyWith(photoIndex: 0, photoTurns: 0));
    return identifier;
  }

  void removePhotoGroup(String id) {
    if (busy || locked) return;
    _photoGroups = _photoGroups.where((group) => group.id != id).toList();
    updateSettings(
      settings.copyWith(
        resetPhotoGroup: settings.photoGroupId == id,
        photoIndex: 0,
        photoTurns: 0,
      ),
    );
  }

  /// 只有用户点击“相册访问权限”才发起授权管理；普通系统选图不强制要求完整授权。
  Future<void> managePhotoAccess() async {
    try {
      await platform.managePhotoAccess();
      await refreshPhotoAccess();
    } catch (e) {
      error = _message(e);
      changed();
    }
  }

  Future<void> refreshPhotoAccess() async {
    try {
      photoAccess = await platform.photoAccess();
    } catch (_) {
      photoAccess = 'system';
    }
    changed();
  }

  Future<void> importPhotos() async {
    if (busy || locked) {
      return;
    }
    busy = true;
    busyLabel = '选择背景照片';
    changed();
    var paths = <String>[];
    var imported = 0;
    final addedIds = <String>[];
    final failures = <String>[];
    try {
      paths = await platform.pickImages();
      for (var i = 0; i < paths.length; i++) {
        busyLabel = '导入照片 ${i + 1}/${paths.length}';
        changed();
        try {
          final bytes = await imageService.normalize(File(paths[i]));
          final photo = await repository.storeBackground(
            bytes,
            p.basename(paths[i]).replaceFirst(RegExp(r'^[a-f0-9-]{36}_'), ''),
          );
          imported++;
          addedIds.add(photo.id);
          if (!_photos.any((item) => item.id == photo.id)) {
            if (!_photos.any((p) => p.id == photo.id)) {
              _photos = [..._photos, photo];
            }
          }
        } catch (_) {
          failures.add(p.basename(paths[i]));
        }
      }
      if (_photos.isNotEmpty && imported > 0) {
        _photoGroups = _photoGroups
            .map(
              (group) => group.id != settings.photoGroupId
                  ? group
                  : BackgroundPhotoGroup(
                      id: group.id,
                      name: group.name,
                      photoIds: List.unmodifiable({
                        ...group.photoIds,
                        ...addedIds,
                      }),
                    ),
            )
            .toList();
        settings = settings.copyWith(
          backgroundMode: 'photos',
          photoIndex: settings.photoIndex % max(1, activePhotos.length),
          photoTurns: 0,
        );
        await flush();
      }
      if (failures.isNotEmpty) {
        error = '部分照片无法读取：${failures.take(3).join('、')}';
      }
      if (platform.imageImportWarning != null) {
        error = platform.imageImportWarning;
      }
    } catch (e) {
      error = _message(e);
    } finally {
      busy = false;
      busyLabel = null;
      await platform.discard(paths);
      changed();
    }
  }

  Future<void> removePhoto(String id) async {
    if (busy || locked) {
      return;
    }
    final previous = _photos, previousSettings = settings;
    final previousGroups = _photoGroups;
    busy = true;
    var saved = false;
    final active = currentPhoto?.id;
    _photos = _photos.where((photo) => photo.id != id).toList();
    _photoGroups = _photoGroups
        .map(
          (group) => BackgroundPhotoGroup(
            id: group.id,
            name: group.name,
            photoIds: List.unmodifiable(
              group.photoIds.where((photoId) => photoId != id),
            ),
          ),
        )
        .toList();
    final selected = activePhotos.indexWhere((photo) => photo.id == active);
    settings = settings.copyWith(
      backgroundMode: _photos.isEmpty ? 'color' : settings.backgroundMode,
      photoIndex: selected < 0 ? 0 : selected,
      photoTurns: 0,
    );
    changed();
    try {
      await flush();
      saved = true;
      final file = repository.backgroundFile(id);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      if (!saved) {
        _photos = previous;
        _photoGroups = previousGroups;
        settings = previousSettings;
      }
      error = _message(e);
    } finally {
      busy = false;
      changed();
    }
  }

  /// Wi-Fi 传输完成后走相同仓库入口。字体先保存到目录，用户按需切换，不批量加载到内存。
  Future<String> importTransferredFile(String path, String kind) async {
    if (busy || locked || _disposed) {
      throw const FormatException('请保持阅读器解锁，并等待当前导入完成');
    }
    if (!['book', 'font'].contains(kind)) {
      throw const FormatException('上传类型无效');
    }
    busy = true;
    busyLabel = '正在导入 ${p.basename(path)}';
    changed();
    try {
      final String name;
      if (kind == 'font') {
        final id = await repository.importFont(path);
        name = p.basenameWithoutExtension(path);
        if (!_fonts.any((font) => font.id == id)) {
          _fonts = [
            ..._fonts,
            ReaderFont(
              id: id,
              name: name,
              bytes: await repository.fontFile(id).length(),
              importedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          ];
        }
      } else {
        final book = await repository.import(path);
        name = book.title;
        if (!_books.any((item) => item.id == book.id)) {
          _books = [..._books, book];
        }
      }
      await flush();
      return name;
    } finally {
      busy = false;
      busyLabel = null;
      changed();
    }
  }

  /// 多文件导入先记录字体目录，只加载最后一个选中的字体，避免批量占用内存。
  Future<void> importFont() async {
    if (busy || locked) {
      return;
    }
    busy = true;
    changed();
    var paths = <String>[];
    final failures = <String>[];
    ReaderFont? last;
    try {
      paths = await platform.pick(font: true);
      for (final path in paths) {
        try {
          final id = await repository.importFont(path);
          final record = ReaderFont(
            id: id,
            name: p
                .basenameWithoutExtension(path)
                .replaceFirst(RegExp(r'^[a-f0-9-]{36}_'), ''),
            bytes: await repository.fontFile(id).length(),
            importedAt: DateTime.now().millisecondsSinceEpoch,
          );
          final existing = _fonts.where((font) => font.id == id).firstOrNull;
          last = existing ?? record;
          if (existing == null) {
            _fonts = [..._fonts, record];
          }
        } catch (e) {
          failures.add('${p.basename(path)}: ${_message(e)}');
        }
      }
      if (last != null) {
        try {
          await _loadFontId(last.id);
          settings = settings.copyWith(fontId: last.id, fontName: last.name);
        } catch (e) {
          failures.add(_message(e));
        }
      }
      if (paths.isNotEmpty) {
        await flush();
      }
      if (failures.isNotEmpty) {
        error = failures.take(3).join('；');
      }
    } catch (e) {
      error = _message(e);
    } finally {
      busy = false;
      await platform.discard(paths);
      changed();
    }
  }

  /// 从已导入字体中切换；传入 null 时恢复系统字体，导入记录继续保留。
  Future<void> selectFont(String? id) async {
    if (busy || locked) {
      return;
    }
    busy = true;
    changed();
    try {
      if (id == null) {
        settings = settings.copyWith(resetFont: true);
      } else {
        final font = _fonts.where((font) => font.id == id).firstOrNull;
        if (font == null) {
          throw const FormatException('字体记录不存在');
        }
        await _loadFontId(id);
        settings = settings.copyWith(fontId: id, fontName: font.name);
      }
      await flush();
    } catch (e) {
      error = _message(e);
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> loadFont() async {
    final id = settings.fontId;
    if (id != null) {
      await _loadFontId(id);
    }
  }

  /// 已注册字体复用同一字体族，往返切换时不重复读取和注册大文件。
  Future<void> _loadFontId(String id) async {
    if (!_registeredFonts.contains(id)) {
      await fontService.register(repository.fontFile(id), 'user_$id');
      _registeredFonts.add(id);
    }
    loadedFontId = id;
  }

  void lock() {
    if (hasPin) {
      locked = true;
      cloud.setPaused(true);
      changed();
    }
    unawaited(flush().catchError((Object _) {}));
  }

  Future<bool> verifyPin(String input, {bool unlock = false}) async {
    if (pinBusy || DateTime.now().millisecondsSinceEpoch < blockedUntil) {
      return false;
    }
    final record = _pin;
    if (record == null) {
      return false;
    }
    pinBusy = true;
    changed();
    try {
      final matches = await PinService.verify(input, record);
      if (matches) {
        failedAttempts = 0;
        blockedUntil = 0;
        await flush();
        if (unlock) {
          locked = false;
          cloud.setPaused(false);
        }
      } else {
        failedAttempts++;
        if (failedAttempts >= 5) {
          blockedUntil =
              DateTime.now().millisecondsSinceEpoch +
              min(300, 30 * pow(2, min(failedAttempts - 5, 4)).toInt()) * 1000;
        }
        await flush();
      }
      return matches;
    } catch (e) {
      error = _message(e);
      return false;
    } finally {
      pinBusy = false;
      changed();
    }
  }

  Future<void> setPin(String? pin) async {
    final previous = _pin;
    _pin = pin == null ? null : await PinService.create(pin);
    try {
      await flush();
    } catch (_) {
      _pin = previous;
      rethrow;
    }
    failedAttempts = 0;
    blockedUntil = 0;
    changed();
  }

  Future<List<SearchHit>> search(BookDocument document, String query) async {
    if (query.trim().isEmpty) {
      return [];
    }
    final text = document.text;
    return Isolate.run(() {
      final hits = <SearchHit>[];
      final regex = RegExp(RegExp.escape(query.trim()), caseSensitive: false);
      for (final match in regex.allMatches(text)) {
        hits.add(
          SearchHit(
            match.start,
            text
                .substring(
                  max(0, match.start - 24),
                  min(text.length, match.end + 64),
                )
                .replaceAll('\n', ' '),
          ),
        );
        if (hits.length == 300) {
          break;
        }
      }
      return hits;
    });
  }

  /// 资源只通过设置页主动上传；书目不夹带本地密码或自动应用的阅读位置；书签随手动书籍备份。
  Future<List<CloudSource>> _cloudSources(String kind) async {
    if (kind == 'book') {
      for (final book in _books) {
        if (book.lastOpened > 0) {
          cloud.recordProgress(
            bookId: book.id,
            offset: book.offset,
            length: book.length,
            updatedAt: book.lastOpened,
          );
        }
      }
      return [
        for (final book in _books)
          CloudSource(
            'book',
            book.id,
            book.title,
            {
              'record': {
                ...book.toJson(),
                'offset': 0,
                'lastOpened': 0,
                'bookmarks': book.bookmarks.map((b) => b.toJson()).toList(),
              },
            },
            {
              'original': File(
                p.join(
                  p.dirname(repository.bookPath(book.id)),
                  'original.${book.format.toLowerCase()}',
                ),
              ),
              'document': File(repository.bookPath(book.id)),
            },
          ),
      ];
    }
    if (kind == 'font') {
      return [
        for (final font in _fonts)
          CloudSource(
            'font',
            font.id,
            font.name,
            {'record': font.toJson()},
            {'font': repository.fontFile(font.id)},
          ),
      ];
    }
    if (kind == 'photo') {
      return [
        for (final photo in _photos)
          CloudSource(
            'photo',
            photo.id,
            photo.name,
            {
              'record': photo.toJson(),
              'groups': _photoGroups.map((g) => g.toJson()).toList(),
            },
            {'photo': repository.backgroundFile(photo.id)},
          ),
      ];
    }
    throw const FormatException('不支持的上传类型');
  }

  bool hasCloudItem(CloudItem item) => switch (item.kind) {
    'book' => _books.any((b) => b.id == item.id),
    'font' => _fonts.any((f) => f.id == item.id),
    'photo' => _photos.any((p) => p.id == item.id),
    _ => false,
  };

  /// 先验证全部下载内容，再写入应用存储；失败不覆盖已有书架项目。
  Future<void> _receiveCloudItem(
    CloudItem item,
    Map<String, File> files,
  ) async {
    if (hasCloudItem(item) && item.kind != 'photo') return;
    busy = true;
    busyLabel = '保存云端${item.name}';
    changed();
    final previousBooks = _books,
        previousFonts = _fonts,
        previousPhotos = _photos,
        previousGroups = _photoGroups;
    try {
      final record = Map<String, dynamic>.from(item.metadata['record'] as Map);
      if (record['id'] != item.id) throw const FormatException('资源归属校验失败');
      if (item.kind == 'book') {
        final book = BookRecord.fromJson(record);
        final original = files['original'], cache = files['document'];
        if (original == null ||
            cache == null ||
            !RegExp(
              r'^(TXT|EPUB|MOBI|AZW|AZW3|HTML|HTM)$',
            ).hasMatch(book.format)) {
          throw const FormatException('云端书籍格式不受支持');
        }
        if (await CloudAssets.hash(original) != item.id) {
          throw const FormatException('原始书籍校验失败');
        }
        final document = await Isolate.run(
          () async => BookDocument.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(await cache.readAsString()) as Map,
            ),
          ),
        );
        if (document.text.length != book.length) {
          throw const FormatException('书籍定位版本不一致');
        }
        final folder = Directory(p.dirname(repository.bookPath(book.id)));
        await folder.create(recursive: true);
        await original.copy(
          p.join(folder.path, 'original.${book.format.toLowerCase()}'),
        );
        await cache.copy(repository.bookPath(book.id));
        _books = [..._books, book];
      } else if (item.kind == 'font') {
        final font = ReaderFont.fromJson(record), file = files['font'];
        if (file == null) throw const FormatException('字体文件缺失');
        final id = await repository.importFont(file.path);
        if (id != item.id) throw const FormatException('字体校验失败');
        _fonts = [..._fonts, font];
      } else if (item.kind == 'photo') {
        final photo = BackgroundPhoto.fromJson(record), file = files['photo'];
        if (file == null || await CloudAssets.hash(file) != item.id) {
          throw const FormatException('照片校验失败');
        }
        // 用解码器验证格式，但保留原阅读用副本的字节，确保多端内容标识一致。
        await imageService.normalize(file);
        final target = repository.backgroundFile(photo.id);
        await target.parent.create(recursive: true);
        await file.copy(target.path);
        if (!_photos.any((p) => p.id == photo.id)) {
          _photos = [..._photos, photo];
        }
        final available = _photos.map((p) => p.id).toSet();
        for (final json in item.metadata['groups'] as List? ?? []) {
          final group = BackgroundPhotoGroup.fromJson(
            Map<String, dynamic>.from(json as Map),
          );
          final members = group.photoIds.where(available.contains).toSet();
          _photoGroups = [
            ..._photoGroups.where((g) => g.id != group.id),
            BackgroundPhotoGroup(
              id: group.id,
              name: group.name,
              photoIds: List.unmodifiable(members),
            ),
          ];
        }
      }
      await flush();
    } catch (_) {
      _books = previousBooks;
      _fonts = previousFonts;
      _photos = previousPhotos;
      _photoGroups = previousGroups;
      rethrow;
    } finally {
      busy = false;
      busyLabel = null;
      changed();
    }
  }

  /// 用户同意追到云端后才更改位置。若解析器版本不同，用上下文或比例作可解释的定位回退。
  Future<void> followCloudProgress(CloudProgress progress) async {
    final book = findBook(progress.bookId);
    if (book == null) return;
    var offset = progress.offset;
    if (book.length != progress.length) {
      final doc = await openBook(book);
      final quote = progress.quote.isEmpty
          ? -1
          : doc.text.indexOf(progress.quote);
      offset = quote >= 0
          ? quote
          : (progress.offset / progress.length * doc.text.length).round();
    }
    _books = _books
        .map(
          (b) => b.id == book.id
              ? b.copyWith(
                  offset: offset.clamp(0, max(0, b.length - 1)),
                  lastOpened: progress.updatedAt,
                )
              : b,
        )
        .toList();
    await flush();
    changed();
  }

  String _message(Object e) => e is FormatException
      ? e.message
      : e is PlatformException
      ? e.message ?? '系统文件操作失败'
      : '操作失败，请检查文件和存储空间';
  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    cloud.removeListener(changed);
    cloud.dispose();
    platform.dispose();
    super.dispose();
  }
}
