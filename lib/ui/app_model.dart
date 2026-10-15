import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../data/library_repository.dart';
import '../data/platform_service.dart';
import '../domain/models.dart';

/// 应用状态的唯一写入口。界面仅观察状态，持久化操作始终经过仓库串行队列。
class AppModel extends ChangeNotifier {
  AppModel(this.repository, this.platform);
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
      _pin = data['pin'] == null
          ? null
          : Map<String, dynamic>.from(data['pin'] as Map);
      failedAttempts = data['failedAttempts'] as int? ?? 0;
      blockedUntil = data['blockedUntil'] as int? ?? 0;
      locked = hasPin;
      try {
        await loadFont();
      } catch (_) {
        error = '自定义字体暂不可用，已使用系统字体';
      }
    }
    changed();
  }

  Map<String, dynamic> snapshot() => {
    'version': 1,
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
  void updateProgress(String id, int offset) {
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
    settings = value;
    changed();
    _scheduleSave();
  }

  Future<void> importFont() async {
    if (busy || locked) {
      return;
    }
    busy = true;
    changed();
    var paths = <String>[];
    try {
      paths = await platform.pick(font: true);
      if (paths.isEmpty) {
        return;
      }
      final id = await repository.importFont(paths.first);
      await _loadFontId(id);
      settings = settings.copyWith(
        fontId: id,
        fontName: p
            .basenameWithoutExtension(paths.first)
            .replaceFirst(RegExp(r'^[a-f0-9-]{36}_'), ''),
      );
      await flush();
    } catch (e) {
      error = _message(e);
    } finally {
      busy = false;
      await platform.discard(paths);
      changed();
    }
  }

  Future<void> loadFont() async {
    final id = settings.fontId;
    if (id != null) {
      await _loadFontId(id);
    }
  }

  Future<void> _loadFontId(String id) async {
    if (loadedFontId == id) {
      return;
    }
    final file = repository.fontFile(id);
    final bytes = await file.readAsBytes();
    if (bytes.length < 12) {
      throw const FormatException('字体文件损坏');
    }
    final signature = ByteData.sublistView(bytes).getUint32(0);
    if (![0x00010000, 0x4f54544f, 0x74746366, 0x74727565].contains(signature)) {
      throw const FormatException('请选择有效的 TTF / OTF 字体');
    }
    final loader = FontLoader('user_$id')
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    loadedFontId = id;
  }

  void lock() {
    if (hasPin) {
      locked = true;
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

  String _message(Object e) => e is FormatException
      ? e.message
      : e is PlatformException
      ? e.message ?? '系统文件操作失败'
      : '操作失败，请检查文件和存储空间';
  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    platform.dispose();
    super.dispose();
  }
}
