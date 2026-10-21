import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../domain/page_turn_effect.dart';
import 'page_ink_snapshot.dart';
import 'page_turn_transition.dart';
import 'reader_page.dart';

/// 统一的翻页入口。点击、滑动、滚轮和键盘共用同一动画任务，防止连续输入重复翻页。
class ReaderPager extends StatefulWidget {
  const ReaderPager({
    super.key,
    required this.child,
    required this.onTurn,
    required this.onToggle,
    required this.effect,
    required this.background,
  });
  final ReaderPage child;
  final Future<bool> Function(bool) onTurn;
  final VoidCallback onToggle;
  final String effect;
  final Color background;
  @override
  State<ReaderPager> createState() => ReaderPagerState();
}

class ReaderPagerState extends State<ReaderPager>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(vsync: this);
  ReaderPage? _previous;
  PageInkSnapshot? _previousInk, _currentInk;
  PageTurnEffect _effect = PageTurnEffect.cover;
  Size? _size, _transitionSize;
  bool _forward = true, _turning = false, _prepared = false;
  int _operation = 0;
  double _drag = 0;
  DateTime _lastWheel = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isTurning => _turning;

  /// 只有导航成功且新页面已完成布局后才开始动画；跨章节时也保持旧页稳定显示。
  Future<void> turn(bool next) async {
    if (_turning) {
      return;
    }
    _turning = true;
    final ticket = ++_operation;
    final previous = widget.child;
    final effect = PageTurnEffect.parse(widget.effect);
    final size = _size;
    final animate =
        effect != PageTurnEffect.none &&
        !MediaQuery.disableAnimationsOf(context) &&
        size != null &&
        !size.isEmpty;
    PageInkSnapshot? previousInk, currentInk;
    bool cancelled() => !mounted || ticket != _operation;
    if (animate) {
      setState(() {
        _previous = previous;
        _prepared = false;
        _transitionSize = size;
        _forward = next;
        _effect = effect;
      });
    }
    try {
      final moved = await widget.onTurn(next);
      if (cancelled() || !moved || !animate) {
        return;
      }
      // 父组件 setState 先完成，确保录制到目标页，而不是导航前的旧 widget。
      await WidgetsBinding.instance.endOfFrame;
      if (cancelled() || _size != size) {
        return;
      }
      final current = widget.child;
      if (identical(current.page, previous.page)) {
        return;
      }
      if (effect.needsInk) {
        previousInk = await PageInkSnapshot.capture(
          previous,
          size,
          particles: effect == PageTurnEffect.particles,
        );
        if (cancelled()) {
          return;
        }
        currentInk = await PageInkSnapshot.capture(
          current,
          size,
          particles: effect == PageTurnEffect.particles,
        );
        if (cancelled() || _size != size) {
          return;
        }
      }
      _animation.duration = effect.duration;
      _animation.value = 0;
      setState(() {
        _previousInk = previousInk;
        _currentInk = currentInk;
        _prepared = true;
      });
      await _animation.forward().orCancel;
    } on TickerCanceled {
      // 路由退出、排版变化或系统关闭动画时，取消尚未完成的 TickerFuture。
    } catch (_) {
      // 快照录制失败时直接显示已导航的目标页，翻页和进度仍然有效。
    } finally {
      if (!cancelled()) {
        setState(() {
          _previous = null;
          _previousInk = _currentInk = null;
          _prepared = false;
          _turning = false;
        });
      }
      // 等旧 CustomPainter 从渲染树移除，避免本帧仍在使用已释放的图像。
      if (previousInk != null || currentInk != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          previousInk?.dispose();
          currentInk?.dispose();
        });
        WidgetsBinding.instance.scheduleFrame();
      }
    }
  }

  void _cancel() {
    _operation++;
    _animation.stop(canceled: true);
    _previous = null;
    _previousInk = _currentInk = null;
    _turning = _prepared = false;
  }

  @override
  void didUpdateWidget(covariant ReaderPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.effect != widget.effect ||
        oldWidget.child.width != widget.child.width ||
        oldWidget.child.style != widget.child.style ||
        oldWidget.child.scaler != widget.child.scaler) {
      _cancel();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_turning && MediaQuery.disableAnimationsOf(context)) {
      _cancel();
    }
  }

  @override
  void dispose() {
    _operation++;
    _animation.dispose();
    super.dispose();
  }

  void _endDrag(DragEndDetails details) {
    if (_drag.abs() > 35 || (details.primaryVelocity ?? 0).abs() > 200) {
      unawaited(
        turn(_drag.abs() > 35 ? _drag < 0 : (details.primaryVelocity ?? 0) < 0),
      );
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _size = constraints.biggest;
      if (_previous != null && _size != _transitionSize) {
        final ticket = _operation;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && ticket == _operation) {
            setState(_cancel);
          }
        });
      }
      final vertical =
          PageTurnEffect.parse(widget.effect) == PageTurnEffect.vertical;
      return Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent &&
              event.scrollDelta.distance > 5 &&
              DateTime.now().difference(_lastWheel).inMilliseconds > 280) {
            _lastWheel = DateTime.now();
            unawaited(
              turn(
                (event.scrollDelta.dy.abs() > event.scrollDelta.dx.abs()
                        ? event.scrollDelta.dy
                        : event.scrollDelta.dx) >
                    0,
              ),
            );
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final fraction =
                details.localPosition.dx / math.max(1, constraints.maxWidth);
            if (fraction < .25) {
              unawaited(turn(false));
            } else if (fraction > .75) {
              unawaited(turn(true));
            } else {
              widget.onToggle();
            }
          },
          onHorizontalDragStart: (_) => _drag = 0,
          onHorizontalDragUpdate: (details) => _drag += details.delta.dx,
          onHorizontalDragEnd: _endDrag,
          onVerticalDragStart: vertical ? (_) => _drag = 0 : null,
          onVerticalDragUpdate: vertical
              ? (details) => _drag += details.delta.dy
              : null,
          onVerticalDragEnd: vertical ? _endDrag : null,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _animation,
              builder: (context, _) {
                final previous = _previous;
                if (previous == null || _size != _transitionSize) {
                  return widget.child;
                }
                if (!_prepared) {
                  return previous;
                }
                return PageTurnTransition(
                  effect: _effect,
                  previous: previous,
                  current: widget.child,
                  progress: _animation.value,
                  forward: _forward,
                  background: widget.background,
                  previousInk: _previousInk,
                  currentInk: _currentInk,
                );
              },
            ),
          ),
        ),
      );
    },
  );
}
