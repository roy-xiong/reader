import 'package:flutter/material.dart';
import '../../domain/page_turn_effect.dart';
import '../app_model.dart';
import 'settings_controls.dart';

class PageTurnSettings extends StatelessWidget {
  const PageTurnSettings({super.key, required this.model});
  final AppModel model;
  @override
  Widget build(BuildContext context) {
    final s = model.settings,
        effect = PageTurnEffect.parse(model.settings.pageEffect);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsChoice(
          title: '翻页特效',
          value: effect.id,
          selectorKey: const ValueKey('page-effect-selector'),
          options: {
            for (final effect in PageTurnEffect.values) effect.id: effect.label,
          },
          onChanged: (v) => model.updateSettings(s.copyWith(pageEffect: v)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            effect.description,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (s.pageEffect == 'particles')
          SwitchListTile(
            key: const ValueKey('particle-directional-switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('粒子方向感'),
            subtitle: const Text('关闭时在原地消散和聚合；开启后随翻页方向飘散。'),
            value: s.particleDirectional,
            onChanged: (v) =>
                model.updateSettings(s.copyWith(particleDirectional: v)),
          ),
        const Divider(height: 32),
        Text('阅读操作', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),
        const Text('左右滑动或点击两侧翻页，点击中间显示工具。\n拖动进度可快速预览，确认后跳转。'),
        const SizedBox(height: 20),
        Text('桌面快捷键', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),
        const Text(
          '方向键 / 空格 / Page Up / Page Down：翻页\n⌘, 设置 · ⌘F 搜索 · ⌘D 书签 · ⌘B 书架\nmacOS：Esc 最小化 · ⌘+ / ⌘- 调整字号',
        ),
      ],
    );
  }
}
