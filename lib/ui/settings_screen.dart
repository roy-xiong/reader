import 'dart:io';
import 'package:flutter/material.dart';
import '../domain/models.dart';
import 'app_model.dart';
import 'lock_screen.dart';

/// 独立设置页。背景透明度和所有排版选项集中于此，阅读页保持简洁。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.model});
  final AppModel model;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final s = model.settings;
      void update(ReaderSettings value) => model.updateSettings(value);
      return PopScope(
        canPop: !model.locked,
        child: Scaffold(
          appBar: AppBar(title: const Text('设置')),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
                children: [
                  _section(context, '外观'),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('主题'),
                    trailing: DropdownButton<String>(
                      value: s.theme,
                      underline: const SizedBox.shrink(),
                      onChanged: (value) {
                        if (value != null) {
                          update(s.copyWith(theme: value));
                        }
                      },
                      items: const [
                        DropdownMenuItem(value: 'system', child: Text('跟随系统')),
                        DropdownMenuItem(value: 'light', child: Text('浅色')),
                        DropdownMenuItem(value: 'dark', child: Text('深色')),
                      ],
                    ),
                  ),
                  _slider(
                    '阅读背景不透明度',
                    s.backgroundOpacity,
                    0,
                    1,
                    '${(s.backgroundOpacity * 100).round()}%',
                    (v) => update(s.copyWith(backgroundOpacity: v)),
                    subtitle: Platform.isMacOS
                        ? '0% 可直接透出桌面，正文保持清晰'
                        : '桌面穿透效果在 macOS 版本生效',
                  ),
                  _color(
                    context,
                    '字体颜色',
                    s.textColor,
                    (color) => update(s.copyWith(textColor: color)),
                  ),
                  _color(
                    context,
                    '背景颜色',
                    s.backgroundColor,
                    (color) => update(s.copyWith(backgroundColor: color)),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => update(s.copyWith(resetColors: true)),
                      child: const Text('恢复主题默认颜色'),
                    ),
                  ),
                  _section(context, '字体与排版'),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('阅读字体'),
                    subtitle: Text(s.fontName ?? '系统字体'),
                    trailing: Wrap(
                      spacing: 4,
                      children: [
                        if (s.fontId != null)
                          IconButton(
                            tooltip: '恢复系统字体',
                            onPressed: () =>
                                update(s.copyWith(resetFont: true)),
                            icon: const Icon(Icons.restore),
                          ),
                        OutlinedButton(
                          onPressed: model.busy ? null : model.importFont,
                          child: const Text('导入 TTF'),
                        ),
                      ],
                    ),
                  ),
                  _slider(
                    '字号',
                    s.fontSize,
                    12,
                    48,
                    '${s.fontSize.round()}',
                    (v) => update(s.copyWith(fontSize: v.roundToDouble())),
                  ),
                  _slider(
                    '行间距',
                    s.lineHeight,
                    1,
                    3,
                    '${s.lineHeight.toStringAsFixed(2)} 倍',
                    (v) => update(s.copyWith(lineHeight: v)),
                  ),
                  _slider(
                    '字间距',
                    s.letterSpacing,
                    -1,
                    8,
                    s.letterSpacing.toStringAsFixed(1),
                    (v) => update(s.copyWith(letterSpacing: v)),
                  ),
                  _slider(
                    '段间距',
                    s.paragraphSpacing,
                    0,
                    48,
                    '${s.paragraphSpacing.round()}',
                    (v) => update(s.copyWith(paragraphSpacing: v)),
                  ),
                  Container(
                    padding: const EdgeInsets.all(20),
                    margin: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: s.backgroundColor == null
                          ? Theme.of(context).colorScheme.surfaceContainer
                          : Color(s.backgroundColor!),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      '在文字之间，找到自己的节奏。\n\n从一页开始，走进另一个世界。',
                      style: TextStyle(
                        fontFamily:
                            s.fontId == model.loadedFontId && s.fontId != null
                            ? 'user_${s.fontId}'
                            : null,
                        color: s.textColor == null ? null : Color(s.textColor!),
                        fontSize: s.fontSize,
                        height: s.lineHeight,
                        letterSpacing: s.letterSpacing,
                      ),
                    ),
                  ),
                  _section(context, '阅读'),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('翻页特效'),
                    trailing: DropdownButton<String>(
                      value: s.pageEffect,
                      underline: const SizedBox.shrink(),
                      onChanged: (v) {
                        if (v != null) {
                          update(s.copyWith(pageEffect: v));
                        }
                      },
                      items: const [
                        DropdownMenuItem(value: 'cover', child: Text('横向覆盖')),
                        DropdownMenuItem(value: 'none', child: Text('无动画')),
                      ],
                    ),
                  ),
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('阅读操作'),
                    subtitle: Text(
                      '左右滑动或点击两侧翻页；点击中间显示工具。\n桌面端支持方向键、空格和 Page Up / Page Down。\n⌘, 设置 · ⌘F 搜索 · ⌘D 书签 · ⌘B 书架',
                    ),
                  ),
                  _section(context, '密码锁'),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(model.hasPin ? '已启用四位数字密码' : '保护私人书架'),
                    subtitle: const Text('重新启动或从后台返回时解锁。请牢记密码。'),
                    trailing: OutlinedButton(
                      onPressed: () => showPinSetup(context, model),
                      child: Text(model.hasPin ? '修改密码' : '设置密码'),
                    ),
                  ),
                  if (model.hasPin)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () =>
                            showPinSetup(context, model, disable: true),
                        child: const Text('关闭密码锁'),
                      ),
                    ),
                  _section(context, '关于 Reader'),
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Reader 1.0.0'),
                    subtitle: Text(
                      '本地书架 · 离线阅读\n支持 TXT、EPUB、MOBI、AZW / AZW3、HTML 的可重排文字。\n受 DRM 保护、纯图片和扫描版电子书暂不支持。',
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('开源许可'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showLicensePage(
                      context: context,
                      applicationName: 'Reader',
                      applicationVersion: '1.0.0',
                      applicationLegalese: 'GPL-3.0-or-later',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.only(top: 26, bottom: 6),
    child: Text(
      title,
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
        fontSize: 14,
      ),
    ),
  );
  Widget _slider(
    String title,
    double value,
    double min,
    double max,
    String label,
    ValueChanged<double> change, {
    String? subtitle,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(title)),
            Text(label),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          label: label,
          onChanged: change,
        ),
        if (subtitle != null)
          Text(subtitle, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );
  Widget _color(
    BuildContext context,
    String title,
    int? value,
    ValueChanged<int> change,
  ) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(
      value == null
          ? '跟随主题'
          : '#${(value & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}',
    ),
    trailing: Wrap(
      spacing: 10,
      children: [
        if (value != null)
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: Color(value),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.grey),
            ),
          ),
        OutlinedButton(
          onPressed: () async {
            final picked = await showDialog<int>(
              context: context,
              builder: (_) => _ColorDialog(initial: value),
            );
            if (picked != null) {
              change(picked);
            }
          },
          child: const Text('选择颜色'),
        ),
      ],
    ),
  );
}

class _ColorDialog extends StatefulWidget {
  const _ColorDialog({this.initial});
  final int? initial;
  @override
  State<_ColorDialog> createState() => _ColorDialogState();
}

class _ColorDialogState extends State<_ColorDialog> {
  late final field = TextEditingController(
    text: ((widget.initial ?? 0xfff5efdf) & 0xffffff)
        .toRadixString(16)
        .padLeft(6, '0'),
  );
  String? error;
  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  void submit() {
    final text = field.text.trim().replaceFirst('#', '');
    if (!RegExp(r'^[a-fA-F0-9]{6}$').hasMatch(text)) {
      setState(() => error = '请输入六位十六进制颜色');
      return;
    }
    Navigator.pop(context, 0xff000000 | int.parse(text, radix: 16));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('自定义颜色'),
    content: SizedBox(
      width: 300,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children:
                [
                      0xfff7f5ef,
                      0xfff0e6cf,
                      0xffcee1d1,
                      0xffd4e1ed,
                      0xff171c1b,
                      0xff252525,
                      0xff111111,
                      0xffffffff,
                      0xffe1d8c6,
                      0xffbad6cb,
                    ]
                    .map(
                      (color) => InkWell(
                        onTap: () => Navigator.pop(context, color),
                        borderRadius: BorderRadius.circular(24),
                        child: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: Color(color),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.grey.withValues(alpha: .5),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: field,
            maxLength: 7,
            decoration: InputDecoration(
              labelText: '十六进制颜色',
              prefixText: '#',
              errorText: error,
            ),
            onSubmitted: (_) => submit(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: submit, child: const Text('使用颜色')),
    ],
  );
}
