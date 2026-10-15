import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_model.dart';

/// 固定的 0–9 数字键盘，兼容触屏和物理键盘；不会唤起系统软键盘。
class PinPad extends StatefulWidget {
  const PinPad({
    super.key,
    required this.model,
    required this.title,
    required this.subtitle,
    required this.onSubmit,
  });
  final AppModel model;
  final String title, subtitle;
  final Future<String?> Function(String) onSubmit;
  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String digits = '';
  String? message;
  bool waiting = false;
  Timer? ticker;
  int previousRemaining = 0;
  final focus = FocusNode();
  int get remaining => max(
    0,
    ((widget.model.blockedUntil - DateTime.now().millisecondsSinceEpoch) / 1000)
        .ceil(),
  );
  @override
  void initState() {
    super.initState();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final current = remaining;
      if (mounted && current != previousRemaining) {
        previousRemaining = current;
        setState(() {});
      }
    });
  }

  Future<void> enter(String digit) async {
    if (waiting || widget.model.pinBusy || remaining > 0) {
      return;
    }
    if (digit == 'delete') {
      if (digits.isNotEmpty) {
        setState(() => digits = digits.substring(0, digits.length - 1));
      }
      return;
    }
    if (digits.length >= 4) {
      return;
    }
    setState(() {
      digits += digit;
      message = null;
    });
    if (digits.length == 4) {
      setState(() => waiting = true);
      String? error;
      try {
        error = await widget.onSubmit(digits);
      } catch (_) {
        error = '无法保存密码，请重试';
      }
      if (mounted) {
        setState(() {
          waiting = false;
          digits = '';
          message = error;
        });
        focus.requestFocus();
      }
    }
  }

  @override
  void dispose() {
    ticker?.cancel();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    focusNode: focus,
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) {
        return KeyEventResult.ignored;
      }
      if (event.logicalKey == LogicalKeyboardKey.backspace) {
        unawaited(enter('delete'));
        return KeyEventResult.handled;
      }
      final character = event.character;
      if (character != null && RegExp(r'^\d$').hasMatch(character)) {
        unawaited(enter(character));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: LayoutBuilder(
      builder: (context, constraints) => Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: 290,
              height: 440,
              child: Column(
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 28,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    widget.title,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.subtitle,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      4,
                      (i) => Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Icon(
                          i < digits.length
                              ? Icons.circle
                              : Icons.circle_outlined,
                          size: 13,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 42,
                    child: Center(
                      child: waiting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              remaining > 0 ? '$remaining 秒后重试' : message ?? '',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontSize: 12,
                              ),
                            ),
                    ),
                  ),
                  Expanded(
                    child: GridView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: 12,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 1.45,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 8,
                          ),
                      itemBuilder: (context, index) {
                        if (index == 9) {
                          return const SizedBox.shrink();
                        }
                        final value = index == 10
                            ? '0'
                            : index == 11
                            ? 'delete'
                            : '${index + 1}';
                        return Semantics(
                          label: value == 'delete' ? '删除一位' : value,
                          button: true,
                          child: FilledButton.tonal(
                            onPressed: waiting || remaining > 0
                                ? null
                                : () => enter(value),
                            style: FilledButton.styleFrom(
                              padding: EdgeInsets.zero,
                              shape: const StadiumBorder(),
                            ),
                            child: value == 'delete'
                                ? const Icon(Icons.backspace_outlined, size: 21)
                                : Text(
                                    value,
                                    style: const TextStyle(
                                      fontSize: 27,
                                      fontWeight: FontWeight.w300,
                                    ),
                                  ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 密码修改必须先验证旧密码，并要求两次输入新密码。
Future<void> showPinSetup(
  BuildContext context,
  AppModel model, {
  bool disable = false,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PinSetup(model: model, disable: disable),
  );
}

class _PinSetup extends StatefulWidget {
  const _PinSetup({required this.model, required this.disable});
  final AppModel model;
  final bool disable;
  @override
  State<_PinSetup> createState() => _PinSetupState();
}

class _PinSetupState extends State<_PinSetup> {
  late int stage = widget.model.hasPin ? 0 : 1;
  String? first;
  bool saving = false;
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving && !widget.model.locked,
    child: Dialog(
      child: SizedBox(
        width: 360,
        height: 540,
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: '取消',
                onPressed: saving ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            Expanded(
              child: PinPad(
                model: widget.model,
                title: stage == 0
                    ? '验证当前密码'
                    : stage == 1
                    ? '设置四位密码'
                    : '再次输入密码',
                subtitle: stage == 0 ? '确认是你本人操作' : '使用固定数字键盘输入',
                onSubmit: (code) async {
                  if (stage == 0) {
                    if (!await widget.model.verifyPin(code)) {
                      return '密码错误，请重试';
                    }
                    if (!mounted) {
                      return null;
                    }
                    if (widget.disable) {
                      setState(() => saving = true);
                      try {
                        await widget.model.setPin(null);
                        if (context.mounted) {
                          Navigator.pop(context);
                        }
                      } finally {
                        if (mounted) {
                          setState(() => saving = false);
                        }
                      }
                    } else {
                      setState(() => stage = 1);
                    }
                  } else if (stage == 1) {
                    setState(() {
                      first = code;
                      stage = 2;
                    });
                  } else {
                    if (code != first) {
                      setState(() {
                        first = null;
                        stage = 1;
                      });
                      return '两次输入不一致，请重新设置';
                    }
                    setState(() => saving = true);
                    try {
                      await widget.model.setPin(code);
                      if (context.mounted) {
                        Navigator.pop(context);
                      }
                    } finally {
                      if (mounted) {
                        setState(() => saving = false);
                      }
                    }
                  }
                  return null;
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
