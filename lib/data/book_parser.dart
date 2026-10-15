import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:dart_mobi/dart_mobi.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import '../domain/models.dart';

/// 本地电子书解析。独立 Isolate 可在超时后终止，防止损坏文件阻塞界面。
class BookParser {
  static const extensions = [
    'txt',
    'epub',
    'mobi',
    'azw',
    'azw3',
    'html',
    'htm',
  ];
  static const maxFileBytes = 64 * 1024 * 1024;
  Future<BookDocument> parse(String path) async {
    final port = ReceivePort();
    Isolate? worker;
    try {
      worker = await Isolate.spawn(
        _worker,
        [port.sendPort, path],
        onError: port.sendPort,
        onExit: port.sendPort,
      );
      final message = await port.first.timeout(const Duration(seconds: 45));
      if (message is Map && message['ok'] is Map) {
        return BookDocument.fromJson(
          Map<String, dynamic>.from(message['ok'] as Map),
        );
      }
      throw FormatException(
        message is Map ? message['error'] as String? ?? '解析失败' : '文件无法解析',
      );
    } finally {
      worker?.kill(priority: Isolate.immediate);
      port.close();
    }
  }

  static Future<void> _worker(List<Object> args) async {
    final send = args[0] as SendPort;
    try {
      send.send({'ok': (await parseFile(args[1] as String)).toJson()});
    } catch (e) {
      send.send({'error': e is FormatException ? e.message : '文件损坏或暂不支持其内部编码'});
    }
  }

  /// 供隔离线程和格式回归测试使用，不依赖 Flutter 插件。
  static Future<BookDocument> parseFile(String path) async {
    final file = File(path);
    final size = await file.length();
    if (size == 0 || size > maxFileBytes) {
      throw const FormatException('请选择非空且不超过 64 MB 的电子书');
    }
    return parseBytes(await file.readAsBytes(), p.basename(path));
  }

  static Future<BookDocument> parseBytes(
    Uint8List bytes,
    String filename,
  ) async {
    final ext = p.extension(filename).toLowerCase().replaceFirst('.', '');
    final fallback = p
        .basenameWithoutExtension(filename)
        .replaceFirst(RegExp(r'^[a-f0-9-]{36}_'), '');
    if (ext == 'epub') {
      return _epub(bytes, fallback);
    }
    if (['mobi', 'azw', 'azw3'].contains(ext)) {
      return _mobi(bytes, fallback);
    }
    if (['html', 'htm'].contains(ext)) {
      final doc = html.parse(decodeText(bytes));
      return _assemble(doc.querySelector('title')?.text ?? fallback, '', [
        (fallback, _htmlText(doc.body)),
      ]);
    }
    if (ext != 'txt') {
      throw const FormatException('不支持此文件格式');
    }
    final text = _normalize(decodeText(bytes));
    final sections = <(String, String)>[];
    final heading = RegExp(
      r'^(第[零〇一二三四五六七八九十百千万两\d]+[章节卷部回][^\n]{0,60}|(?:chapter|part)\s+[\divxlc]+[^\n]{0,60})$',
      multiLine: true,
      caseSensitive: false,
    );
    final matches = heading.allMatches(text).toList();
    var start = 0;
    var title = '正文';
    for (final m in matches) {
      if (m.start > start) {
        sections.add((title, text.substring(start, m.start)));
      }
      start = m.start;
      title = m.group(0) ?? title;
    }
    sections.add((title, text.substring(start)));
    return _assemble(fallback, '', sections);
  }

  /// 优先识别 BOM 和严格 UTF-8，旧中文 TXT 回退为 GBK。
  static String decodeText(List<int> bytes, {String? encoding}) {
    if (encoding?.toLowerCase().contains('1252') == true) {
      return const Windows1252Codec().decode(bytes);
    }
    if (bytes.length >= 2 &&
        ((bytes[0] == 255 && bytes[1] == 254) ||
            (bytes[0] == 254 && bytes[1] == 255))) {
      final little = bytes[0] == 255;
      final units = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        units.add(
          little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
        );
      }
      return String.fromCharCodes(units);
    }
    try {
      return utf8.decode(bytes).replaceFirst('\ufeff', '');
    } on FormatException {
      return const GbkCodec(allowInvalid: true).decode(bytes);
    }
  }

  static BookDocument _epub(Uint8List bytes, String fallback) {
    final zip = ZipDecoder().decodeBytes(bytes);
    var total = 0;
    for (final f in zip) {
      total += f.size;
      if (f.size > 32 * 1024 * 1024 ||
          total > 128 * 1024 * 1024 ||
          zip.length > 12000) {
        throw const FormatException('电子书解压后过大');
      }
    }
    String read(String path) {
      final entry = zip.findFile(p.posix.normalize(path));
      if (entry == null || !entry.isFile) {
        throw const FormatException('EPUB 缺少必要内容');
      }
      return decodeText(entry.content as List<int>);
    }

    final encryption = zip.findFile('META-INF/encryption.xml');
    if (encryption != null) {
      final encrypted = XmlDocument.parse(
        decodeText(encryption.content as List<int>),
      );
      // 允许标准字体混淆；加密正文无法在无授权信息时读取。
      final algorithms = encrypted.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'EncryptionMethod')
          .map((e) => e.getAttribute('Algorithm') ?? '');
      if (algorithms.any(
        (a) => !a.contains('embedding') && !a.contains('obfuscation'),
      )) {
        throw const FormatException('此 EPUB 的正文受 DRM 保护');
      }
    }
    final container = XmlDocument.parse(read('META-INF/container.xml'));
    final roots = container.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'rootfile',
    );
    final opfPath = roots.firstOrNull?.getAttribute('full-path');
    if (opfPath == null) {
      throw const FormatException('EPUB 缺少书籍清单');
    }
    final opf = XmlDocument.parse(read(opfPath));
    Iterable<XmlElement> elements(String name) => opf.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == name);
    final title = elements('title').firstOrNull?.innerText.trim();
    final author = elements(
      'creator',
    ).map((e) => e.innerText.trim()).join(' / ');
    final manifest = {
      for (final item in elements('item')) item.getAttribute('id'): item,
    };
    final sections = <(String, String)>[];
    for (final ref in elements('itemref')) {
      if (ref.getAttribute('linear') == 'no') {
        continue;
      }
      final item = manifest[ref.getAttribute('idref')];
      final href = item?.getAttribute('href');
      if (href == null) {
        continue;
      }
      final type = item?.getAttribute('media-type') ?? '';
      if (!type.contains('html')) {
        continue;
      }
      final resolved = p.posix.normalize(
        p.posix.join(
          p.posix.dirname(opfPath),
          Uri.decodeComponent(href.split('#').first),
        ),
      );
      if (resolved.startsWith('../') || p.posix.isAbsolute(resolved)) {
        throw const FormatException('EPUB 内部路径无效');
      }
      final doc = html.parse(read(resolved));
      final text = _htmlText(doc.body);
      final heading = doc.querySelector('h1,h2,h3')?.text.trim();
      if (text.trim().isNotEmpty) {
        sections.add((
          heading?.isNotEmpty == true ? heading! : '第 ${sections.length + 1} 节',
          text,
        ));
      }
    }
    return _assemble(
      title?.isNotEmpty == true ? title! : fallback,
      author,
      sections,
    );
  }

  static Future<BookDocument> _mobi(Uint8List bytes, String fallback) async {
    if (bytes.length < 86) {
      throw const FormatException('MOBI 文件头损坏');
    }
    final header = ByteData.sublistView(bytes);
    final records = header.getUint16(76);
    if (records == 0 || 78 + records * 8 > bytes.length) {
      throw const FormatException('MOBI 记录表损坏');
    }
    final first = header.getUint32(78);
    if (first + 16 > bytes.length) {
      throw const FormatException('MOBI 正文头损坏');
    }
    if (header.getUint16(first + 12) != 0) {
      throw const FormatException('此 MOBI 的正文受 DRM 保护');
    }
    if (header.getUint32(first + 4) > 48 * 1024 * 1024) {
      throw const FormatException('MOBI 正文过大');
    }
    final data = await DartMobiReader.read(bytes);
    final raw = data.parseOpt(true, true, false);
    final sections = <(String, String)>[];
    var part = raw.markup;
    var count = 0;
    while (part != null && count++ < 6000) {
      final content = part.data;
      if (content != null) {
        final doc = html.parse(
          decodeText(
            content,
            encoding: data.mobiHeader?.encoding?.value == 1252 ? '1252' : null,
          ),
        );
        final text = _htmlText(doc.body);
        if (text.trim().isNotEmpty) {
          sections.add((
            doc.querySelector('h1,h2,h3')?.text.trim() ??
                '第 ${sections.length + 1} 节',
            text,
          ));
        }
      }
      part = part.next;
    }
    return _assemble(fallback, '', sections);
  }

  /// 保留块级顺序和段落边界，跳过脚本样式；重排正文由用户统一控制样式。
  static String _htmlText(dom.Element? body) {
    if (body == null) {
      return '';
    }
    final out = StringBuffer();
    const blocks = {
      'p',
      'div',
      'section',
      'article',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'li',
      'blockquote',
      'tr',
      'pre',
    };
    void walk(dom.Node node) {
      if (node is dom.Text) {
        out.write(node.text.replaceAll(RegExp(r'\s+'), ' '));
        return;
      }
      if (node is! dom.Element) {
        return;
      }
      final tag = node.localName;
      if (['script', 'style', 'nav', 'noscript'].contains(tag)) {
        return;
      }
      if (tag == 'br') {
        out.write('\n\n');
        return;
      }
      if (tag == 'img') {
        final alt = node.attributes['alt'];
        if (alt?.trim().isNotEmpty == true) {
          out.write('\n\n[${alt!.trim()}]\n\n');
        }
        return;
      }
      if (blocks.contains(tag)) {
        out.write('\n\n');
      }
      for (final child in node.nodes) {
        walk(child);
      }
      if (blocks.contains(tag)) {
        out.write('\n\n');
      }
    }

    walk(body);
    return _normalize(out.toString());
  }

  static String _normalize(String input) => input
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\u0000', '')
      .replaceAll('\u00a0', ' ')
      .split('\n')
      .map((s) => s.trimRight())
      .join('\n')
      .replaceAll(RegExp(r'\n[ \t]*\n(?:[ \t]*\n)+'), '\n\n')
      .trim();

  static BookDocument _assemble(
    String title,
    String author,
    List<(String, String)> sections,
  ) {
    final out = StringBuffer();
    final chapters = <Chapter>[];
    for (final section in sections) {
      final normalized = _normalize(section.$2);
      if (normalized.isEmpty) {
        continue;
      }
      var position = 0, number = 0;
      while (position < normalized.length) {
        var end = (position + 12000).clamp(0, normalized.length);
        if (end < normalized.length) {
          final boundary = normalized.lastIndexOf('\n', end);
          if (boundary > position + 6000) {
            end = boundary + 1;
          }
          final unit = normalized.codeUnitAt(end - 1);
          if (unit >= 0xd800 && unit <= 0xdbff) {
            end--;
          }
        }
        final start = out.length;
        out.write(normalized.substring(position, end));
        out.write('\n\n');
        chapters.add(
          Chapter(
            title: number++ == 0 ? section.$1 : '${section.$1}（续 $number）',
            start: start,
            end: out.length,
          ),
        );
        position = end;
        if (out.length > 12000000) {
          throw const FormatException('正文超过 1200 万字，暂无法导入');
        }
      }
    }
    if (chapters.isEmpty) {
      throw const FormatException('未发现可重排文字。暂不支持纯图片或扫描版电子书');
    }
    return BookDocument(
      title: title,
      author: author,
      text: out.toString(),
      chapters: List.unmodifiable(chapters),
    );
  }
}
