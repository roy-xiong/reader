import 'package:flutter/material.dart';
import '../core/reader_icon.dart';
import '../reader_color_picker.dart';

/// 子设置页通用控件只负责展示及回调，不持有设置副本。
class SettingsSlider extends StatelessWidget {
  const SettingsSlider({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.onChanged,
    this.subtitle,
    this.divisions,
  });
  final String title, label;
  final String? subtitle;
  final double value, min, max;
  final int? divisions;
  final ValueChanged<double> onChanged;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(title)),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          label: label,
          divisions: divisions,
          onChanged: onChanged,
        ),
        if (subtitle != null)
          Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

class SettingsChoice extends StatelessWidget {
  const SettingsChoice({
    super.key,
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
    this.subtitle,
    this.selectorKey,
  });
  final String title, value;
  final String? subtitle;
  final Key? selectorKey;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: DropdownButtonFormField<String>(
      key: selectorKey ?? ValueKey('$title-$value'),
      initialValue: options.containsKey(value) ? value : options.keys.first,
      isExpanded: true,
      borderRadius: BorderRadius.circular(16),
      dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      icon: const ReaderIcon(ReaderGlyph.down, size: 18),
      decoration: InputDecoration(
        labelText: title,
        helperText: subtitle,
        helperMaxLines: 3,
      ),
      items: [
        for (final option in options.entries)
          DropdownMenuItem(
            value: option.key,
            child: Text(
              option.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    ),
  );
}

class SettingsColor extends StatelessWidget {
  const SettingsColor({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.history = const [],
  });
  final String title;
  final int? value;
  final ValueChanged<int> onChanged;
  final List<int> history;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(
      value == null
          ? '跟随主题'
          : '#${(value! & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}',
    ),
    trailing: OutlinedButton(
      onPressed: () async {
        final picked = await showReaderColorPicker(
          context,
          initial: value,
          history: history,
        );
        if (picked != null) onChanged(picked);
      },
      child: const Text('选择颜色'),
    ),
  );
}
