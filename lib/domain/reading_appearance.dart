import 'package:meta/meta.dart';

/// 阅读器内置配色。参考成熟阅读器的纸白、棕褐、柔和灰和夜间模式，独立定义本应用色值。
@immutable
class ReadingPalette {
  const ReadingPalette(this.name, this.text, this.background);
  final String name;
  final int text, background;
  static const presets = [
    ReadingPalette('纸白', 0xff303b35, 0xfff7f5ef),
    ReadingPalette('羊皮纸', 0xff594833, 0xfff0e6cf),
    ReadingPalette('柔和灰', 0xff4b4b48, 0xffe8e6e1),
    ReadingPalette('竹青', 0xff304b3b, 0xffd4e4d5),
    ReadingPalette('雾蓝', 0xff354653, 0xffdce6ed),
    ReadingPalette('深海', 0xffaab5c4, 0xff202a37),
    ReadingPalette('墨色', 0xff999999, 0xff171c1b),
    ReadingPalette('午夜', 0xff999999, 0xff000000),
  ];
}

/// 应用内照片记录。正文只引用内容标识，不保存相册或外部文件的临时路径。
@immutable
class BackgroundPhoto {
  const BackgroundPhoto({
    required this.id,
    required this.name,
    required this.bytes,
  });
  final String id, name;
  final int bytes;
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'bytes': bytes};
  factory BackgroundPhoto.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
      throw const FormatException('背景照片标识损坏');
    }
    return BackgroundPhoto(
      id: id,
      name: json['name'] as String,
      bytes: json['bytes'] as int? ?? 0,
    );
  }
}
