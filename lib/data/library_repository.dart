import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../domain/models.dart';
import 'book_parser.dart';

/// 原子保存书架、设置和密码校验记录。写入串行执行，失败不会污染后续任务。
class LibraryRepository {
  LibraryRepository(this.root);
  final Directory root;
  Future<void> _tail = Future.value();
  File get _state => File(p.join(root.path, 'library.json'));
  String bookPath(String id) => p.join(root.path, 'books', id, 'document.json');

  Future<Map<String, dynamic>?> load() async {
    await root.create(recursive: true);
    final candidates = [_state, File('${_state.path}.bak')];
    var found = false;
    for (final candidate in candidates) {
      if (!await candidate.exists()) {
        continue;
      }
      found = true;
      try {
        final map = await Isolate.run(
          () async =>
              jsonDecode(await candidate.readAsString())
                  as Map<String, dynamic>,
        );
        // 整体校验后才接受备份，损坏时不静默重置密码或书架。
        for (final b in map['books'] as List) {
          BookRecord.fromJson(Map<String, dynamic>.from(b as Map));
        }
        ReaderSettings.fromJson(
          Map<String, dynamic>.from(map['settings'] as Map),
        );
        if (map['pin'] != null) {
          PinService.validateRecord(
            Map<String, dynamic>.from(map['pin'] as Map),
          );
        }
        return map;
      } catch (_) {
        /* 主文件不可读时仅尝试经过相同校验的备份。 */
      }
    }
    if (found) {
      throw const FormatException('书架数据损坏，已保留原文件。请恢复 library.json 或其备份');
    }
    return null;
  }

  Future<void> save(Map<String, dynamic> snapshot) {
    // 在排队前编码快照，调用方后续变化不会改变当前写入内容。
    final content = jsonEncode(snapshot);
    final operation = _tail.then((_) async {
      await root.create(recursive: true);
      final temp = File('${_state.path}.tmp');
      await temp.writeAsString(content, flush: true);
      final backup = File('${_state.path}.bak.tmp');
      await backup.writeAsString(content, flush: true);
      await backup.rename('${_state.path}.bak');
      // 主文件最后替换；此前任何写入失败都不会让调用方误判保存状态。
      await temp.rename(_state.path);
    });
    _tail = operation.catchError((Object _) {});
    return operation;
  }

  Future<BookRecord> import(String source) async {
    final parser = BookParser();
    final document = await parser.parse(source);
    final digest = await Isolate.run(
      () async => (await sha256.bind(File(source).openRead()).first).toString(),
    );
    final directory = Directory(p.join(root.path, 'books', digest));
    await directory.create(recursive: true);
    final target = bookPath(digest);
    final content = document.toJson();
    await Isolate.run(() async {
      final temporary = File('$target.tmp');
      await temporary.writeAsString(jsonEncode(content), flush: true);
      await temporary.rename(target);
    });
    // 保留原始文件，便于后续升级阅读引擎时重新解析；不保存用户原始绝对路径。
    final extension = p.extension(source).toLowerCase();
    await File(source).copy(p.join(directory.path, 'original$extension'));
    return BookRecord(
      id: digest,
      title: document.title,
      author: document.author,
      format: extension.substring(1).toUpperCase(),
      length: document.text.length,
      importedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<BookDocument> open(BookRecord book) async {
    final path = bookPath(book.id);
    return Isolate.run(
      () async => BookDocument.fromJson(
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>,
      ),
    );
  }

  Future<void> deleteFiles(String id) async {
    final directory = Directory(p.dirname(bookPath(id)));
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<String> importFont(String source) async {
    if (await File(source).length() > 20 * 1024 * 1024) {
      throw const FormatException('字体文件不能超过 20 MB');
    }
    final digest = (await sha256.bind(File(source).openRead()).first)
        .toString();
    final directory = Directory(p.join(root.path, 'fonts'));
    await directory.create(recursive: true);
    await File(source).copy(p.join(directory.path, '$digest.ttf'));
    return digest;
  }

  File fontFile(String id) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
      throw const FormatException('字体标识无效');
    }
    return File(p.join(root.path, 'fonts', '$id.ttf'));
  }
}

/// 四位数字锁保存 PBKDF2-HMAC-SHA256 校验值。耗时推导全部放在 Isolate 中。
class PinService {
  static const iterations = 100000;
  static void validateRecord(Map<String, dynamic> record) {
    final salt = base64Decode(record['salt'] as String);
    final hash = base64Decode(record['hash'] as String);
    if (salt.length != 16 ||
        hash.length != 32 ||
        record['iterations'] != iterations) {
      throw const FormatException('密码校验记录损坏');
    }
  }

  static Future<Map<String, dynamic>> create(String pin) async {
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
      throw const FormatException('密码必须为四位数字');
    }
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final hash = await Isolate.run(() => _derive(pin, salt));
    return {
      'salt': base64Encode(salt),
      'hash': base64Encode(hash),
      'iterations': iterations,
    };
  }

  static Future<bool> verify(String pin, Map<String, dynamic> record) async {
    validateRecord(record);
    final salt = base64Decode(record['salt'] as String);
    final expected = base64Decode(record['hash'] as String);
    final actual = await Isolate.run(() => _derive(pin, salt));
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= actual[i] ^ expected[i];
    }
    return difference == 0;
  }

  static List<int> _derive(String pin, List<int> salt) {
    final hmac = Hmac(sha256, utf8.encode(pin));
    var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final output = List<int>.of(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < output.length; j++) {
        output[j] ^= u[j];
      }
    }
    return output;
  }
}
