# Reader

面向 Android 与 macOS 的本地电子书阅读器。阅读页只保留正文和进度；独立设置页集中管理外观、排版和密码。

## 功能

- TXT（UTF-8、UTF-16 BOM、GBK）、EPUB、MOBI / AZW / AZW3、HTML 可重排文字阅读。
- 本地书架、书名/作者搜索、排序、导入去重、阅读进度、目录、书签和全文搜索。
- 横向覆盖翻页，可关闭动画；支持触屏、方向键、空格、Page Up / Down、滚轮。
- 深色、浅色、跟随系统；批量导入 TTF / OTF，持久化字体列表并随时切换；调整字号、行间距、字间距、段间距、颜色。
- macOS 原生磨砂玻璃、统一圆角、任意缩放；在应用菜单“设置…”（⌘,）调整背景不透明度，0% 时显示原生磨砂底层。
- 四位数字密码与固定数字键盘；PBKDF2 校验、错误次数限制；macOS 最小化保持解锁，重新启动或手动锁定时验证密码，Android 后台返回重新锁定。
- 文件面板使用 Android SAF 和 macOS NSOpenPanel，文件复制入应用存储后可持续离线读取。

## 格式边界

当前阅读引擎按原书的文字与段落顺序统一重排，不保留 EPUB/MOBI 的插图、原书 CSS 和复杂版式。纯图片/扫描版、DRM 加密文件暂不支持。TXT 无 BOM 时优先 UTF-8，失败后使用 GBK。全文搜索最多显示前 300 处匹配。

电子书单文件限制 64 MB（字体不设固定大小上限）；EPUB 解压总量 128 MB；正文上限 1200 万 UTF-16 单元。长章节自动切成有界片段，避免整个长篇在窗口缩放时一次性排版。格式解析在可终止的隔离线程中执行。

密码锁控制应用访问；书籍和书架文件保存在系统应用目录，未对正文做文件加密。请牢记密码，界面没有跳过验证的重置入口。

## 固定工具链

与同级 BBK 工程一致：Flutter **3.44.4**、Dart **3.12.2**、AGP **9.0.1**、Kotlin **2.3.20**、Gradle **9.1.0**、JDK **17**、Android SDK **36**、NDK **27.2.12479018**、minSdk **24**。本机不需要下载或升级这些工具。

## 构建与下载

GitHub Actions 的 `Build Reader` 在 main 推送和手动触发时运行：静态检查 → 格式/存储/分页/响应式测试 → Android Release APK 与 macOS 通用 DMG/ZIP → `preview` 预发布。

[测试版下载](https://github.com/roy-xiong/reader/releases/tag/preview)

Android 当前使用测试签名，CI 缓存测试密钥以便连续覆盖安装。缓存被清理后签名可能变化。macOS 使用 ad-hoc 签名，未做 Apple 公证。

## 本地开发

```sh
flutter pub get
flutter analyze --no-pub
# 在需要时自行编译：
flutter run -d macos
flutter build apk --release
```

仓库不包含本机 SDK 路径、签名密钥、书籍文件或用户数据。平台包由 GitHub Actions 构建，测试截图也会作为流水线附件保存。

## 代码结构

- `lib/domain`：不可变模型和分页。
- `lib/data`：格式解析、文件/窗口通道、串行原子持久化与密码推导。
- `lib/ui`：应用模型、书架、阅读、设置与锁屏。
- `android`：Kotlin 系统选择器与后台文件复制。
- `macos`：Swift 透明窗口、原生菜单与沙盒文件面板。

## 开源许可

Reader 使用 GPL-3.0-or-later，第三方许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和应用的开源许可页。项目公开源代码与构建脚本，可重新构建和替换依赖。

界面按钮采用自包含矢量绘制，不依赖图标字体字形。旧版本保存的字体文件会自动扫描并恢复到字体列表。
