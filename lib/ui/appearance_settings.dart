import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../domain/reading_appearance.dart';
import 'app_model.dart';
import 'background_groups.dart';
import 'reader_color_picker.dart';
import 'core/reader_icon.dart';
import 'settings/settings_controls.dart';

/// 官方配色与照片设置集中在设置页，不在正文叠加常驻操作控件。
class AppearanceSettings extends StatelessWidget {
  const AppearanceSettings({super.key, required this.model});
  final AppModel model;
  @override
  Widget build(BuildContext context) {
    final settings = model.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('官方阅读主题', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final palette in ReadingPalette.presets)
              InkWell(
                key: ValueKey('palette-${palette.name}'),
                borderRadius: BorderRadius.circular(14),
                onTap: () => model.applyPalette(palette),
                child: Container(
                  width: 100,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 13,
                  ),
                  decoration: BoxDecoration(
                    color: Color(palette.background),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      width: 2,
                      color:
                          settings.backgroundMode == 'color' &&
                              settings.textColor == palette.text &&
                              settings.backgroundColor == palette.background
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey.withValues(alpha: .25),
                    ),
                  ),
                  child: Text(
                    palette.name,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(palette.text),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        SettingsColor(
          title: '字体颜色',
          value: settings.textColor,
          history: model.textColors,
          onChanged: model.setTextColor,
        ),
        SettingsColor(
          title: '背景颜色',
          value: settings.backgroundColor,
          history: model.backgroundColors,
          onChanged: model.setBackgroundColor,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () =>
                model.updateSettings(settings.copyWith(resetColors: true)),
            child: const Text('恢复主题默认颜色'),
          ),
        ),
        SettingsSlider(
          title: '阅读背景不透明度',
          value: settings.backgroundOpacity,
          min: 0,
          max: 1,
          label: '${(settings.backgroundOpacity * 100).round()}%',
          onChanged: (v) =>
              model.updateSettings(settings.copyWith(backgroundOpacity: v)),
          subtitle: Platform.isMacOS
              ? '0% 阅读背景完全透明，标题栏保留磨砂效果'
              : '桌面穿透效果在 macOS 版本生效',
        ),
        const Divider(height: 32),
        Row(
          children: [
            Expanded(
              child: Text(
                '照片背景（${model.photos.length}）',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            OutlinedButton(
              onPressed: model.busy ? null : model.importPhotos,
              child: Text(Platform.isIOS ? '从相册选择' : '选择照片'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          '可选多张。按正式翻页次数切换，预览、搜索和目录跳转不计数。',
          style: TextStyle(fontSize: 12),
        ),
        if (defaultTargetPlatform == TargetPlatform.iOS)
          ListTile(
            key: const ValueKey('photo-access-management'),
            contentPadding: EdgeInsets.zero,
            title: const Text('相册访问权限'),
            subtitle: Text(switch (model.photoAccess) {
              'authorized' => '已允许完全访问照片',
              'limited' => '当前仅授权部分照片，可管理所选照片或前往系统设置开启完全访问',
              'denied' => '未授权直接访问，可前往设置调整；系统相册选择仍可使用',
              'restricted' => '系统限制了相册访问，可检查屏幕使用时间等系统设置',
              _ => '可申请完整访问，或继续使用系统相册选择照片',
            }),
            trailing: const ReaderIcon(ReaderGlyph.chevronRight),
            onTap: model.managePhotoAccess,
          ),
        if (model.photos.isNotEmpty) ...[
          BackgroundGroups(model: model),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('使用照片背景'),
            value: settings.backgroundMode == 'photos',
            onChanged: (value) => model.updateSettings(
              settings.copyWith(backgroundMode: value ? 'photos' : 'color'),
            ),
          ),
          SizedBox(
            height: 132,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: model.activePhotos.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final photo = model.activePhotos[index];
                return SizedBox(
                  width: 88,
                  child: Column(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => model.selectPhoto(index),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                width: 3,
                                color: model.currentPhoto?.id == photo.id
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.transparent,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(9),
                              child: Image.file(
                                model.repository.backgroundFile(photo.id),
                                width: 82,
                                height: 86,
                                cacheWidth: 164,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    const Center(child: Text('照片不可用')),
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        height: 36,
                        child: IconButton(
                          tooltip: '移除此照片',
                          onPressed: model.busy
                              ? null
                              : () => model.removePhoto(photo.id),
                          icon: const ReaderIcon(ReaderGlyph.close, size: 18),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('每'),
              const SizedBox(width: 10),
              SizedBox(
                width: 76,
                child: TextFormField(
                  key: const ValueKey('photo-turn-interval'),
                  initialValue: '${settings.photoTurnInterval}',
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4),
                  ],
                  decoration: const InputDecoration(isDense: true),
                  onChanged: (value) {
                    final count = int.tryParse(value);
                    if (count != null && count >= 1 && count <= 1000) {
                      model.updateSettings(
                        model.settings.copyWith(
                          photoTurnInterval: count,
                          photoTurns: 0,
                        ),
                      );
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(child: Text('次正式翻页切换一张（1–1000）')),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(child: Text('照片深色遮罩')),
              Text('${(settings.photoDim * 100).round()}%'),
            ],
          ),
          Slider(
            key: const ValueKey('photo-dim-slider'),
            value: settings.photoDim,
            min: 0,
            max: 1,
            onChanged: (value) =>
                model.updateSettings(model.settings.copyWith(photoDim: value)),
          ),
          const Text(
            '0% 不遮罩，100% 完全遮黑；正文颜色保持独立。',
            style: TextStyle(fontSize: 12),
          ),
          ListTile(
            key: const ValueKey('photo-text-color'),
            contentPadding: EdgeInsets.zero,
            title: const Text('照片背景文字颜色'),
            subtitle: Text(
              '#${((settings.photoTextColor ?? settings.textColor ?? 0xffe7e7e7) & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}',
            ),
            trailing: OutlinedButton(
              onPressed: () async {
                final color = await showReaderColorPicker(
                  context,
                  initial:
                      settings.photoTextColor ??
                      settings.textColor ??
                      0xffe7e7e7,
                  history: model.textColors,
                );
                if (color != null) model.setPhotoTextColor(color);
              },
              child: const Text('选择文字颜色'),
            ),
          ),
          if (settings.photoTextColor != null)
            TextButton(
              onPressed: () => model.updateSettings(
                model.settings.copyWith(resetPhotoTextColor: true),
              ),
              child: const Text('照片文字跟随默认颜色'),
            ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}
