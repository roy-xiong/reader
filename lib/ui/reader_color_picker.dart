import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 通用六位 HEX 颜色选择器，照片和纯色设置共享自定义颜色历史。
Future<int?> showReaderColorPicker(
  BuildContext context, {
  int? initial,
  List<int> history = const [],
}) => showDialog<int>(
  context: context,
  builder: (_) => _ColorDialog(initial: initial, history: history),
);

class _ColorDialog extends StatefulWidget {
  const _ColorDialog({this.initial, this.history = const []});
  final int? initial;
  final List<int> history;
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
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              child: Column(
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
                  if (widget.history.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('我的自定义颜色'),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final color in widget.history)
                          InkWell(
                            key: ValueKey('saved-color-$color'),
                            onTap: () => Navigator.pop(context, color),
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
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: field,
            key: const ValueKey('hex-color-input'),
            maxLength: 6,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[a-fA-F0-9]')),
            ],
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
