import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../app_model.dart';
import '../appearance_settings.dart';
import 'general_settings.dart';
import 'page_turn_settings.dart';
import 'reading_style_preview.dart';
import 'settings_category.dart';
import 'typography_settings.dart';

/// 手机固定预览、下方滚动选项；宽窗口左右分栏，所有样式子页共用一套预览。
class SettingsDetailScreen extends StatelessWidget {
  const SettingsDetailScreen({
    super.key,
    required this.model,
    required this.category,
  });
  final AppModel model;
  final SettingsCategory category;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final content = switch (category) {
        SettingsCategory.typography => TypographySettings(model: model),
        SettingsCategory.background => AppearanceSettings(model: model),
        SettingsCategory.pageTurn => PageTurnSettings(model: model),
        _ => GeneralSettings(model: model, category: category),
      };
      final options = ListView(
        key: ValueKey('settings-options-${category.name}'),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [content],
      );
      return PopScope(
        canPop: !model.locked,
        child: Scaffold(
          appBar: AppBar(title: Text(category.title)),
          body: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: category.hasPreview ? 1100 : 720,
                ),
                child: !category.hasPreview
                    ? options
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          // 键盘弹出或窗口过矮时优先保留可滚动选项，恢复空间后显示同一个预览。
                          if (constraints.maxHeight < 280) return options;
                          final preview = ReadingStylePreview(
                            key: const ValueKey('reading-style-preview'),
                            model: model,
                          );
                          if (constraints.maxWidth >= 760) {
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 4,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      24,
                                      8,
                                      0,
                                      24,
                                    ),
                                    child: SizedBox(
                                      height: math.min(
                                        constraints.maxHeight - 32,
                                        580,
                                      ),
                                      child: preview,
                                    ),
                                  ),
                                ),
                                Expanded(flex: 6, child: options),
                              ],
                            );
                          }
                          final previewHeight = (constraints.maxHeight * .38)
                              .clamp(148.0, 300.0);
                          return Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  24,
                                  0,
                                  24,
                                  8,
                                ),
                                child: SizedBox(
                                  height: previewHeight,
                                  child: preview,
                                ),
                              ),
                              Expanded(child: options),
                            ],
                          );
                        },
                      ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
