import '../core/reader_icon.dart';

/// 稳定的分类标识；新增设置归入子页，不再扩展首页长表单。
enum SettingsCategory {
  typography('字体与排版', '字体、字号、间距与横竖排', ReaderGlyph.book),
  background('背景与颜色', '主题配色、照片、遮罩与透明度', ReaderGlyph.circleOutline),
  pageTurn('翻页与操作', '翻页特效、粒子方向与快捷键', ReaderGlyph.library),
  appearance('界面外观', '浅色、深色或跟随系统', ReaderGlyph.settings),
  files('文件与同步', '本地导入、Wi-Fi 上传与坚果云', ReaderGlyph.folder),
  privacy('密码锁', '设置、修改或关闭访问密码', ReaderGlyph.lock),
  about('关于阅读', '版本信息与开源许可', ReaderGlyph.more);

  const SettingsCategory(this.title, this.subtitle, this.glyph);
  final String title, subtitle;
  final ReaderGlyph glyph;
  bool get hasPreview =>
      this == typography || this == background || this == pageTurn;
}
