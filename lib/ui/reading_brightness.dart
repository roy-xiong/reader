import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 阅读区域的颜色乘数，仅降低本应用绘制像素的亮度，保持 Alpha 不变。
/// 不写系统亮度，不给全透明窗口额外铺黑底；工具栏放在此层之外保持可操作。
class ReadingDimmer extends StatelessWidget {
  const ReadingDimmer({super.key, required this.value, required this.child});
  final double value;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final v = value.clamp(.1, 1.0);
    if (v == 1) return child;
    return ColorFiltered(
      key: const ValueKey('reading-brightness-filter'),
      colorFilter: ColorFilter.matrix([
        v,
        0,
        0,
        0,
        0,
        0,
        v,
        0,
        0,
        0,
        0,
        0,
        v,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ]),
      child: child,
    );
  }
}

/// 双指纵向滑动只处理亮度，整次触摸序列抑制点击与翻页，防止抬起一根手指后误翻页。
/// 手势期间只重绘阅读层，结束后才持久化一次；关闭页面时释放提示计时器。
class ReadingBrightnessGesture extends StatefulWidget {
  const ReadingBrightnessGesture({
    super.key,
    required this.value,
    required this.onChanged,
    required this.builder,
    this.enabled = true,
  });
  final double value;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final Widget Function(BuildContext context, double brightness, bool showHint)
  builder;
  @override
  State<ReadingBrightnessGesture> createState() =>
      ReadingBrightnessGestureState();
}

class ReadingBrightnessGestureState extends State<ReadingBrightnessGesture> {
  final _pointers = <int, Offset>{};
  Offset? _start, _last;
  double? _draft;
  bool _blocked = false, _active = false, _hint = false, _trackpad = false;
  int _sequence = 0;
  Timer? _hintTimer;
  bool get blocksPageTurn => _blocked;
  double get _value => (_draft ?? widget.value).clamp(.1, 1.0);
  Offset get _center =>
      _pointers.values.reduce((a, b) => a + b) / _pointers.length.toDouble();

  void _down(PointerDownEvent event) {
    if (!widget.enabled || event.kind != PointerDeviceKind.touch) return;
    if (_pointers.isEmpty) {
      _sequence++;
      _blocked = false;
    }
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 2) {
      _start = _last = _center;
      _active = false;
      setState(() => _blocked = true);
    } else if (_pointers.length > 2) {
      _start = _last = null;
      _active = false;
    }
  }

  void _move(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    if (widget.enabled && _pointers.length == 2) _adjust(_center);
  }

  void _adjust(Offset point) {
    final start = _start, last = _last;
    if (start == null || last == null) return;
    final total = point - start;
    if (!_active &&
        (total.dy.abs() < 10 || total.dy.abs() <= total.dx.abs() * 1.2)) {
      return;
    }
    final delta = _active ? point.dy - last.dy : total.dy;
    _last = point;
    _active = true;
    final height = math.max(
      200.0,
      context.size?.height ?? MediaQuery.sizeOf(context).height,
    );
    _hintTimer?.cancel();
    setState(() {
      _draft = (_value - delta / height * 1.5).clamp(.1, 1.0);
      _hint = true;
    });
  }

  void _up(PointerEvent event) {
    if (_pointers.remove(event.pointer) == null) return;
    if (_pointers.length != 2) {
      _start = _last = null;
      _active = false;
    }
    if (_pointers.isEmpty) _finish();
  }

  void _finish() {
    final value = _draft;
    _draft = null;
    if (value != null && widget.enabled) widget.onChanged(value);
    final ticket = _sequence;
    // 指针分发结束后才解除翻页屏蔽，保证末次 up 不被子组件解释为点按或拖动翻页。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ticket == _sequence && _pointers.isEmpty && !_trackpad) {
        setState(() => _blocked = false);
      }
    });
    if (_hint) {
      _hintTimer?.cancel();
      _hintTimer = Timer(const Duration(milliseconds: 1100), () {
        if (mounted) setState(() => _hint = false);
      });
    }
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _pointers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: _down,
    onPointerMove: _move,
    onPointerUp: _up,
    onPointerCancel: _up,
    onPointerPanZoomStart: widget.enabled
        ? (_) {
            _sequence++;
            _trackpad = true;
            _start = _last = Offset.zero;
            _active = false;
            setState(() => _blocked = true);
          }
        : null,
    onPointerPanZoomUpdate: widget.enabled
        ? (event) => _adjust(event.pan)
        : null,
    onPointerPanZoomEnd: (_) {
      if (_trackpad) {
        _trackpad = false;
        _start = _last = null;
        _finish();
      }
    },
    child: widget.builder(context, _value, _hint),
  );
}
