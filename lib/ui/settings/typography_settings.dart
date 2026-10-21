import 'dart:io';
import 'package:flutter/material.dart';
import '../app_model.dart';
import '../core/reader_icon.dart';
import '../wifi_upload_screen.dart';
import 'settings_controls.dart';

/// 排版只更新模型，效果由子页共用的阅读预览实时展示。
class TypographySettings extends StatelessWidget {
  const TypographySettings({super.key, required this.model});
  final AppModel model;
  @override
  Widget build(BuildContext context) {
    final s = model.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('已导入字体（${model.fonts.length}）')),
            OutlinedButton(
              onPressed: model.busy
                  ? null
                  : () {
                      if (Platform.isIOS) {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => WifiUploadScreen(model: model),
                          ),
                        );
                      } else {
                        model.importFont();
                      }
                    },
              child: const Text('导入字体'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('font-${s.fontId}-${model.fonts.length}'),
          borderRadius: BorderRadius.circular(16),
          dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
          initialValue: model.fonts.any((font) => font.id == s.fontId)
              ? s.fontId
              : '',
          isExpanded: true,
          icon: const ReaderIcon(ReaderGlyph.down, size: 18),
          decoration: const InputDecoration(
            labelText: '阅读字体',
            helperText: '支持多个 TTF / OTF，导入记录保存在本机。',
            helperMaxLines: 2,
          ),
          items: [
            const DropdownMenuItem(value: '', child: Text('系统字体')),
            ...model.fonts.map(
              (font) => DropdownMenuItem(
                value: font.id,
                child: Text(
                  font.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
          onChanged: model.busy
              ? null
              : (id) => model.selectFont(id == '' ? null : id),
        ),
        SettingsSlider(
          title: '字号',
          value: s.fontSize,
          min: 12,
          max: 48,
          label: '${s.fontSize.round()}',
          onChanged: (v) =>
              model.updateSettings(s.copyWith(fontSize: v.roundToDouble())),
        ),
        SettingsSlider(
          title: '字体加粗',
          value: s.fontWeight,
          min: 100,
          max: 900,
          divisions: 8,
          label: '${s.fontWeight.round()}',
          onChanged: (v) => model.updateSettings(
            s.copyWith(fontWeight: (v / 100).round() * 100.0),
          ),
        ),
        SettingsSlider(
          title: '行间距',
          value: s.lineHeight,
          min: 1,
          max: 3,
          label: '${s.lineHeight.toStringAsFixed(2)} 倍',
          onChanged: (v) => model.updateSettings(s.copyWith(lineHeight: v)),
        ),
        SettingsSlider(
          title: '字间距',
          value: s.letterSpacing,
          min: -1,
          max: 8,
          label: s.letterSpacing.toStringAsFixed(1),
          onChanged: (v) => model.updateSettings(s.copyWith(letterSpacing: v)),
        ),
        SettingsSlider(
          title: '段间距',
          value: s.paragraphSpacing,
          min: 0,
          max: 48,
          label: '${s.paragraphSpacing.round()}',
          onChanged: (v) =>
              model.updateSettings(s.copyWith(paragraphSpacing: v)),
        ),
        const Divider(height: 32),
        SettingsChoice(
          title: '排版样式',
          value: s.readingLayout,
          selectorKey: const ValueKey('reading-layout-selector'),
          options: const {'horizontal': '横排', 'vertical': '古书竖排'},
          onChanged: (v) => model.updateSettings(s.copyWith(readingLayout: v)),
        ),
        if (s.readingLayout == 'vertical')
          SettingsChoice(
            title: '竖排列顺序',
            value: s.verticalDirection,
            selectorKey: const ValueKey('vertical-direction-selector'),
            subtitle: '每列从上往下阅读；行间距控制列距。',
            options: const {'rtl': '从右向左', 'ltr': '从左向右'},
            onChanged: (v) =>
                model.updateSettings(s.copyWith(verticalDirection: v)),
          ),
        SettingsChoice(
          title: '正文简繁',
          value: s.scriptMode,
          options: const {
            'original': '原文',
            'simplified': '简体',
            'traditional': '繁體',
          },
          onChanged: (v) => model.updateSettings(s.copyWith(scriptMode: v)),
        ),
      ],
    );
  }
}
