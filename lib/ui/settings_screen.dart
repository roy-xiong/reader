import 'package:flutter/material.dart';
import 'app_model.dart';
import 'core/reader_icon.dart';
import 'settings/settings_category.dart';
import 'settings/settings_detail_screen.dart';

/// 设置首页只保留分类导航，具体操作均在各自子页完成。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.model});
  final AppModel model;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => PopScope(
      canPop: !model.locked,
      child: Scaffold(
        appBar: AppBar(title: const Text('设置')),
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                children: [
                  _heading(context, '阅读样式'),
                  _group(context, SettingsCategory.values.take(3)),
                  const SizedBox(height: 20),
                  _heading(context, '应用'),
                  _group(context, SettingsCategory.values.skip(3)),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _heading(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
    child: Text(title, style: Theme.of(context).textTheme.labelLarge),
  );

  Widget _group(BuildContext context, Iterable<SettingsCategory> categories) {
    final entries = categories.toList(), colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 58, endIndent: 16),
            ListTile(
              key: ValueKey('settings-${entries[i].name}'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 6,
              ),
              leading: ReaderIcon(
                entries[i].glyph,
                size: 22,
                color: colors.onSurfaceVariant,
              ),
              title: Text(entries[i].title),
              subtitle: Text(
                entries[i].subtitle,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: const ReaderIcon(ReaderGlyph.chevronRight, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  settings: RouteSettings(name: '/settings/${entries[i].name}'),
                  builder: (_) =>
                      SettingsDetailScreen(model: model, category: entries[i]),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
