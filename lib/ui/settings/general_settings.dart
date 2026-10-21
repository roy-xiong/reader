import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../app_model.dart';
import '../cloud/cloud_sync_screen.dart';
import '../core/reader_icon.dart';
import '../lock_screen.dart';
import '../wifi_upload_screen.dart';
import 'settings_category.dart';
import 'settings_controls.dart';

/// 非阅读样式的设置各自独立呈现，不重复展示正文预览。
class GeneralSettings extends StatelessWidget {
  const GeneralSettings({
    super.key,
    required this.model,
    required this.category,
  });
  final AppModel model;
  final SettingsCategory category;
  @override
  Widget build(BuildContext context) => switch (category) {
    SettingsCategory.appearance => SettingsChoice(
      title: '主题',
      value: model.settings.theme,
      selectorKey: const ValueKey('theme-selector'),
      options: const {'system': '跟随系统', 'light': '浅色', 'dark': '深色'},
      subtitle: '界面外观独立于阅读背景配色。',
      onChanged: (v) => model.updateSettings(model.settings.copyWith(theme: v)),
    ),
    SettingsCategory.files => Column(
      children: [
        ListTile(
          key: const ValueKey('nutstore-settings-entry'),
          contentPadding: EdgeInsets.zero,
          title: const Text('坚果云同步'),
          subtitle: Text(
            model.cloud.connected
                ? model.cloud.status
                : '书籍、字体与照片手动传输，阅读进度自动上传',
          ),
          trailing: const ReaderIcon(ReaderGlyph.chevronRight),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => CloudSyncScreen(model: model),
            ),
          ),
        ),
        const Divider(height: 24),
        if (defaultTargetPlatform == TargetPlatform.macOS) ...[
          ListTile(
            key: const ValueKey('local-book-import'),
            contentPadding: EdgeInsets.zero,
            title: const Text('导入本地书籍'),
            subtitle: const Text('从 Mac 选择 TXT、EPUB、MOBI 等文件，可多选'),
            trailing: const ReaderIcon(ReaderGlyph.add),
            onTap: model.busy ? null : () => model.importBooks(),
          ),
          ListTile(
            key: const ValueKey('local-folder-import'),
            contentPadding: EdgeInsets.zero,
            title: const Text('导入书籍文件夹'),
            trailing: const ReaderIcon(ReaderGlyph.folder),
            onTap: model.busy ? null : () => model.importBooks(folder: true),
          ),
        ] else if (!Platform.isIOS)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('导入本地书籍'),
            trailing: const ReaderIcon(ReaderGlyph.add),
            onTap: model.busy ? null : () => model.importBooks(),
          ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Wi-Fi 上传书籍和字体'),
          subtitle: const Text('同一 Wi-Fi 下，通过电脑浏览器批量传入'),
          trailing: const ReaderIcon(ReaderGlyph.chevronRight),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => WifiUploadScreen(model: model),
            ),
          ),
        ),
      ],
    ),
    SettingsCategory.privacy => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(model.hasPin ? '已启用四位数字密码' : '保护私人书架'),
          subtitle: Text(
            Platform.isMacOS
                ? '重新启动或手动锁定后解锁；最小化恢复保持当前状态。'
                : '重新启动或从后台返回时解锁。请牢记密码。',
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => showPinSetup(context, model),
          child: Text(model.hasPin ? '修改密码' : '设置密码'),
        ),
        if (model.hasPin)
          TextButton(
            onPressed: () => showPinSetup(context, model, disable: true),
            child: const Text('关闭密码锁'),
          ),
      ],
    ),
    _ => Column(
      children: [
        const ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('阅读 1.6.0'),
          subtitle: Text(
            '本地书架 · 离线阅读\n支持 TXT、EPUB、MOBI、AZW / AZW3、HTML 的可重排文字。\n受 DRM 保护、纯图片和扫描版电子书暂不支持。',
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('开源许可'),
          trailing: const ReaderIcon(ReaderGlyph.chevronRight),
          onTap: () => showLicensePage(
            context: context,
            applicationName: '阅读',
            applicationVersion: '1.6.0',
            applicationLegalese: 'GPL-3.0-or-later',
          ),
        ),
      ],
    ),
  };
}
