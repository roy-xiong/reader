import 'package:flutter/material.dart';

/// 阅读工具栏中的紧凑调节行；大字号和窄屏下保留滑动区域及当前数值。
class ReadingQuickSlider extends StatelessWidget {
  const ReadingQuickSlider({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.onChanged,
    required this.sliderKey,
    this.divisions,
  });
  final String title, label;
  final double value, min, max;
  final Key sliderKey;
  final int? divisions;
  final ValueChanged<double>? onChanged;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: Row(
      children: [
        const SizedBox(width: 8),
        SizedBox(
          width: 36,
          child: Text(title, style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(
          child: Slider(
            key: sliderKey,
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            label,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
        const SizedBox(width: 12),
      ],
    ),
  );
}
