import 'package:meta/meta.dart';
import 'page_turn_effect.dart';

/// 可持久化的阅读偏好。透明度只应用到阅读背景，不改变正文的不透明度。
@immutable
class ReaderSettings {
  const ReaderSettings({
    this.theme = 'system',
    this.fontSize = 21,
    this.lineHeight = 1.8,
    this.letterSpacing = 0,
    this.paragraphSpacing = 12,
    this.backgroundOpacity = 1,
    this.textColor,
    this.backgroundColor,
    this.fontId,
    this.fontName,
    this.pageEffect = 'cover',
    this.scriptMode = 'original',
    this.fontWeight = 400,
  });
  final String theme;
  final double fontSize, lineHeight, letterSpacing, paragraphSpacing;
  final double backgroundOpacity;
  final int? textColor, backgroundColor;
  final String? fontId, fontName;
  final String pageEffect, scriptMode;
  final double fontWeight;

  ReaderSettings copyWith({
    String? theme,
    double? fontSize,
    double? lineHeight,
    double? letterSpacing,
    double? paragraphSpacing,
    double? backgroundOpacity,
    int? textColor,
    int? backgroundColor,
    String? fontId,
    String? fontName,
    String? pageEffect,
    String? scriptMode,
    double? fontWeight,
    bool resetColors = false,
    bool resetFont = false,
  }) => ReaderSettings(
    theme: theme ?? this.theme,
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    letterSpacing: letterSpacing ?? this.letterSpacing,
    paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
    backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
    textColor: resetColors ? null : textColor ?? this.textColor,
    backgroundColor: resetColors
        ? null
        : backgroundColor ?? this.backgroundColor,
    fontId: resetFont ? null : fontId ?? this.fontId,
    fontName: resetFont ? null : fontName ?? this.fontName,
    pageEffect: pageEffect ?? this.pageEffect,
    scriptMode: scriptMode ?? this.scriptMode,
    fontWeight: fontWeight ?? this.fontWeight,
  );

  Map<String, dynamic> toJson() => {
    'theme': theme,
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'letterSpacing': letterSpacing,
    'paragraphSpacing': paragraphSpacing,
    'backgroundOpacity': backgroundOpacity,
    'textColor': textColor,
    'backgroundColor': backgroundColor,
    'fontId': fontId,
    'fontName': fontName,
    'pageEffect': pageEffect,
    'scriptMode': scriptMode,
    'fontWeight': fontWeight,
  };

  factory ReaderSettings.fromJson(Map<String, dynamic> j) => ReaderSettings(
    theme: ['system', 'light', 'dark'].contains(j['theme'])
        ? j['theme'] as String
        : 'system',
    fontSize: _number(j['fontSize'], 21, 12, 48),
    lineHeight: _number(j['lineHeight'], 1.8, 1, 3),
    letterSpacing: _number(j['letterSpacing'], 0, -1, 8),
    paragraphSpacing: _number(j['paragraphSpacing'], 12, 0, 48),
    backgroundOpacity: _number(j['backgroundOpacity'], 1, 0, 1),
    textColor: j['textColor'] as int?,
    backgroundColor: j['backgroundColor'] as int?,
    fontId: j['fontId'] as String?,
    fontName: j['fontName'] as String?,
    pageEffect: PageTurnEffect.parse(j['pageEffect']).id,
    scriptMode:
        ['original', 'simplified', 'traditional'].contains(j['scriptMode'])
        ? j['scriptMode'] as String
        : 'original',
    fontWeight: _number(j['fontWeight'], 400, 100, 900),
  );
}

double _number(dynamic n, double fallback, double min, double max) =>
    n is num && n.isFinite ? n.toDouble().clamp(min, max) : fallback;

/// 已导入字体的持久化记录，保留显示名称、内容标识和原始文件大小。
@immutable
class ReaderFont {
  const ReaderFont({
    required this.id,
    required this.name,
    required this.bytes,
    required this.importedAt,
  });
  final String id, name;
  final int bytes, importedAt;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'bytes': bytes,
    'importedAt': importedAt,
  };
  factory ReaderFont.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
      throw const FormatException('字体标识损坏');
    }
    return ReaderFont(
      id: id,
      name: json['name'] as String,
      bytes: json['bytes'] as int? ?? 0,
      importedAt: json['importedAt'] as int? ?? 0,
    );
  }
}

/// 字符偏移采用 UTF-16，与 Flutter 的 TextPosition 保持一致。
@immutable
class BookMark {
  const BookMark({
    required this.offset,
    required this.quote,
    required this.createdAt,
  });
  final int offset, createdAt;
  final String quote;
  Map<String, dynamic> toJson() => {
    'offset': offset,
    'quote': quote,
    'createdAt': createdAt,
  };
  factory BookMark.fromJson(Map<String, dynamic> j) => BookMark(
    offset: j['offset'] as int,
    quote: j['quote'] as String,
    createdAt: j['createdAt'] as int,
  );
}

/// 书架仅保存元信息和定位信息；正文独立保存，避免每次翻页重写整本书。
@immutable
class BookRecord {
  const BookRecord({
    required this.id,
    required this.title,
    required this.author,
    required this.format,
    required this.length,
    required this.importedAt,
    this.lastOpened = 0,
    this.offset = 0,
    this.bookmarks = const [],
  });
  final String id, title, author, format;
  final int length, importedAt, lastOpened, offset;
  final List<BookMark> bookmarks;
  double get progress => length == 0 ? 0 : (offset / length).clamp(0, 1);
  BookRecord copyWith({
    int? length,
    int? offset,
    int? lastOpened,
    List<BookMark>? bookmarks,
  }) => BookRecord(
    id: id,
    title: title,
    author: author,
    format: format,
    length: length ?? this.length,
    importedAt: importedAt,
    offset: offset ?? this.offset,
    lastOpened: lastOpened ?? this.lastOpened,
    bookmarks: List.unmodifiable(bookmarks ?? this.bookmarks),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'format': format,
    'length': length,
    'importedAt': importedAt,
    'lastOpened': lastOpened,
    'offset': offset,
    'bookmarks': bookmarks.map((b) => b.toJson()).toList(),
  };
  factory BookRecord.fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
      throw const FormatException('书籍标识损坏');
    }
    return BookRecord(
      id: id,
      title: j['title'] as String,
      author: j['author'] as String? ?? '',
      format: j['format'] as String,
      length: j['length'] as int,
      importedAt: j['importedAt'] as int,
      lastOpened: j['lastOpened'] as int? ?? 0,
      offset: j['offset'] as int? ?? 0,
      bookmarks: List.unmodifiable(
        (j['bookmarks'] as List? ?? []).map(
          (b) => BookMark.fromJson(Map<String, dynamic>.from(b as Map)),
        ),
      ),
    );
  }
}

@immutable
class Chapter {
  const Chapter({
    required this.title,
    required this.start,
    required this.end,
    this.isContinuation = false,
    this.headingEnd,
  });
  final String title;
  final int start, end;
  final bool isContinuation;

  /// 标题在正文中的结束位置；续排片段和不存在正文标题的章节为空。
  final int? headingEnd;
  Map<String, dynamic> toJson() => {
    'title': title,
    'start': start,
    'end': end,
    'isContinuation': isContinuation,
    'headingEnd': headingEnd,
  };
  factory Chapter.fromJson(Map<String, dynamic> j) => Chapter(
    title: j['title'] as String,
    start: j['start'] as int,
    end: j['end'] as int,
    isContinuation:
        j['isContinuation'] as bool? ??
        RegExp(r'（续 \d+）$').hasMatch(j['title'] as String),
    headingEnd: j['headingEnd'] as int?,
  );
}

/// 已归一化的可重排正文。章节在导入时切为有界片段，限制单次排版耗时。
@immutable
class BookDocument {
  const BookDocument({
    required this.title,
    required this.author,
    required this.text,
    required this.chapters,
    this.parseVersion = currentParseVersion,
  });
  static const currentParseVersion = 2;
  final int parseVersion;
  final String title, author, text;
  final List<Chapter> chapters;
  List<Chapter> get outline =>
      List.unmodifiable(chapters.where((chapter) => !chapter.isContinuation));
  int chapterAt(int offset) {
    var low = 0, high = chapters.length - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (chapters[middle].start <= offset) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return low;
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'author': author,
    'parseVersion': parseVersion,
    'text': text,
    'chapters': chapters.map((c) => c.toJson()).toList(),
  };
  factory BookDocument.fromJson(Map<String, dynamic> j) {
    final text = j['text'] as String;
    final chapters = (j['chapters'] as List)
        .map((c) => Chapter.fromJson(Map<String, dynamic>.from(c as Map)))
        .toList();
    if (text.isEmpty ||
        chapters.isEmpty ||
        chapters.first.start != 0 ||
        chapters.last.end != text.length) {
      throw const FormatException('正文数据损坏，请重新导入');
    }
    for (var i = 0; i < chapters.length; i++) {
      final c = chapters[i];
      if (c.start < 0 ||
          c.end <= c.start ||
          c.end > text.length ||
          (i > 0 && c.start != chapters[i - 1].end)) {
        throw const FormatException('章节数据损坏');
      }
    }
    return BookDocument(
      title: j['title'] as String,
      author: j['author'] as String? ?? '',
      text: text,
      chapters: List.unmodifiable(chapters),
      parseVersion: j['parseVersion'] as int? ?? 1,
    );
  }
}

@immutable
class SearchHit {
  const SearchHit(this.offset, this.excerpt);
  final int offset;
  final String excerpt;
}
