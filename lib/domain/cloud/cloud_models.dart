import 'dart:io';

/// 书籍、字体和背景共用的云端目录项；具体资源由可校验的分块清单引用。
class CloudItem {
  const CloudItem({
    required this.kind,
    required this.id,
    required this.name,
    required this.metadata,
    required this.files,
  });
  final String kind, id, name;
  final Map<String, dynamic> metadata;
  final Map<String, Map<String, dynamic>> files;
  String get key => '$kind/$id';
  int get bytes =>
      files.values.fold(0, (sum, file) => sum + (file['size'] as int? ?? 0));
  Map<String, dynamic> toJson() => {
    'kind': kind,
    'id': id,
    'name': name,
    'metadata': metadata,
    'files': files,
  };
  factory CloudItem.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String, id = json['id'] as String;
    if (!['book', 'font', 'photo'].contains(kind) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
      throw const FormatException('云端资源标识无效');
    }
    return CloudItem(
      kind: kind,
      id: id,
      name: json['name'] as String,
      metadata: Map<String, dynamic>.from(json['metadata'] as Map),
      files: Map<String, dynamic>.from(json['files'] as Map).map(
        (key, value) => MapEntry(key, Map<String, dynamic>.from(value as Map)),
      ),
    );
  }
}

/// 导出时仅提供应用内文件，不把外部文件授权路径上传到网盘。
class CloudSource {
  const CloudSource(this.kind, this.id, this.name, this.metadata, this.files);
  final String kind, id, name;
  final Map<String, dynamic> metadata;
  final Map<String, File> files;
}

/// 阅读进度按实际阅读更新时间排序；百分比只用于给用户说明位置，不参与“更新”判断。
class CloudProgress {
  const CloudProgress({
    required this.bookId,
    required this.deviceId,
    required this.offset,
    required this.length,
    required this.updatedAt,
    required this.sequence,
    this.quote = '',
    this.parseVersion = 2,
    this.extensions = const {},
  });
  final String bookId, deviceId, quote;
  final int offset, length, updatedAt, sequence, parseVersion;
  final Map<String, dynamic> extensions;
  Map<String, dynamic> toJson() => {
    ...extensions,
    'bookId': bookId,
    'deviceId': deviceId,
    'offset': offset,
    'length': length,
    'updatedAt': updatedAt,
    'sequence': sequence,
    'quote': quote,
    'parseVersion': parseVersion,
  };
  factory CloudProgress.fromJson(Map<String, dynamic> json) {
    final book = json['bookId'] as String, device = json['deviceId'] as String;
    final offset = json['offset'] as int,
        length = json['length'] as int,
        time = json['updatedAt'] as int;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(book) ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(device) ||
        length <= 0 ||
        offset < 0 ||
        offset >= length ||
        time <= 0) {
      throw const FormatException('云端阅读进度无效');
    }
    return CloudProgress(
      bookId: book,
      deviceId: device,
      offset: offset,
      length: length,
      updatedAt: time,
      sequence: json['sequence'] as int? ?? 0,
      quote: json['quote'] as String? ?? '',
      parseVersion: json['parseVersion'] as int? ?? 2,
      extensions: Map.unmodifiable(json),
    );
  }
}
