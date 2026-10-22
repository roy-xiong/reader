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
    this.particleDirectional = false,
    this.onPreview,
    this.pagePadding = EdgeInsets.zero,
    this.backgroundLayer,
    this.previewBackgroundLayer,
    this.enabled = true,
  });
  final ReaderPage child;
  final Future<bool> Function(bool) onTurn;
  final VoidCallback onToggle;
  final String effect;
  final Color background;
  final bool particleDirectional;

  /// 只排版相邻页，不导航、不保存进度。返回 null 表示已到书首或书尾。
  final Future<ReaderPage?> Function(bool forward)? onPreview;
  final EdgeInsets pagePadding;

  /// 背景必须是创建时已确定的颜色/照片，不能在 build 时重新读取可变的设置。
  /// 这样正式翻页触发照片轮换时，旧页仍然使用轮换前的照片。
  final Widget? backgroundLayer, previewBackgroundLayer;
  final bool enabled;
  @override
  State<ReaderPager> createState() => ReaderPagerState();
}

class ReaderPagerState extends State<ReaderPager>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(vsync: this);
  ReaderPage? _previous;
  ReaderPage? _previewPage;
  Widget? _previousBackground, _previewBackground;
  PageInkSnapshot? _previousInk, _currentInk;
  PageTurnEffect _effect = PageTurnEffect.cover;
  Size? _size, _transitionSize;
  bool _forward = true, _turning = false, _prepared = false;
  int _operation = 0;
  double _drag = 0;
  bool _dragging = false, _interactive = false, _ignoreDrag = false;
  bool _committing = false, _linearProgress = false;
  int _previewOperation = 0;
  Future<void>? _previewTask;
  Axis? _dragAxis;
  DateTime _lastWheel = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isTurning => _turning;

  /// 只有导航成功且新页面已完成布局后才开始动画；跨章节时也保持旧页稳定显示。
  Future<void> turn(bool next) async {
    if (_turning || !widget.enabled) {
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
        _previousBackground = widget.backgroundLayer;
        _linearProgress = false;
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
          widget.pagePadding.deflateSize(size),
          particles: effect == PageTurnEffect.particles,
          ink: effect == PageTurnEffect.ink,
        );
        if (cancelled()) {
          return;
        }
        currentInk = await PageInkSnapshot.capture(
          current,
          widget.pagePadding.deflateSize(size),
          particles: effect == PageTurnEffect.particles,
          ink: effect == PageTurnEffect.ink,
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
          _clearTransition();
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
    _previewOperation++;
    _animation.stop(canceled: true);
    _ignoreDrag = true;
    _clearTransition();
  }

  /// 所有中止入口复用相同清理逻辑，异步预览通过 operation 标识丢弃过期结果。
  void _clearTransition() {
    _previous = null;
    _previewPage = null;
    _previousBackground = null;
    _previewBackground = null;
    _previousInk = _currentInk = null;
    _turning = _prepared = false;
    _dragging = _interactive = _committing = _linearProgress = false;
    _previewTask = null;
    _dragAxis = null;
  }

  @override
  void didUpdateWidget(covariant ReaderPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.effect != widget.effect ||
        oldWidget.particleDirectional != widget.particleDirectional ||
        oldWidget.child.width != widget.child.width ||
        oldWidget.child.style != widget.child.style ||
        oldWidget.child.scaler != widget.child.scaler ||
        oldWidget.pagePadding != widget.pagePadding ||
        !widget.enabled ||
        (_interactive &&
            !_committing &&
            (oldWidget.child.page != widget.child.page ||
                oldWidget.background != widget.background ||
                oldWidget.backgroundLayer?.key !=
                    widget.backgroundLayer?.key))) {
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
    _previewOperation++;
    _animation.dispose();
    super.dispose();
  }

  /// 位移型效果直接消费手指的线性进度；墨迹类效果继续使用完整播放的效果。
  /// 预览加载不会修改真实页码，因此手势取消无需执行一次反向导航。
  void _startDrag(Axis axis) {
    _drag = 0;
    _dragAxis = axis;
    _ignoreDrag = _turning || !widget.enabled;
    if (_ignoreDrag) return;
    final effect = PageTurnEffect.parse(widget.effect);
    _interactive =
        widget.onPreview != null &&
        !MediaQuery.disableAnimationsOf(context) &&
        (effect == PageTurnEffect.cover ||
            effect == PageTurnEffect.slide ||
            effect == PageTurnEffect.vertical ||
            effect == PageTurnEffect.stack);
    if (!_interactive || _size == null || _size!.isEmpty) return;
    _operation++;
    _animation.value = 0;
    setState(() {
      _turning = _dragging = true;
      _linearProgress = true;
      _previous = widget.child;
      _previousBackground = widget.backgroundLayer;
      _previewBackground =
          widget.previewBackgroundLayer ?? widget.backgroundLayer;
      _transitionSize = _size;
      _effect = effect;
      _prepared = false;
    });
  }

  double get _extent {
    final viewport = _transitionSize ?? _size ?? Size.zero;
    final size = _effect == PageTurnEffect.cover
        ? viewport
        : widget.pagePadding.deflateSize(viewport);
    return math.max(
      1.0,
      _effect == PageTurnEffect.vertical ? size.height : size.width,
    );
  }

  void _updateDrag(double delta) {
    if (_ignoreDrag || !widget.enabled) return;
    _drag += delta;
    if (!_dragging) return;
    final forward = _drag < 0;
    if (_drag.abs() > .5 && (_previewTask == null || forward != _forward)) {
      final ticket = ++_previewOperation;
      setState(() {
        _forward = forward;
        _prepared = false;
        _previewPage = null;
      });
      _previewTask = _prepareDrag(forward, _operation, ticket);
    }
    // 拖动不应用缓动曲线，页面移动距离与手指移动距离一一对应。
    _animation.value = (_drag.abs() / _extent).clamp(0.0, 1.0);
  }

  Future<void> _prepareDrag(bool forward, int operation, int preview) async {
    try {
      final page = await widget.onPreview?.call(forward);
      if (!mounted ||
          operation != _operation ||
          preview != _previewOperation ||
          page == null ||
          page.page == _previous?.page) {
        return;
      }
      setState(() {
        _previewPage = page;
        _prepared = true;
      });
    } catch (_) {
      // 预排版失败时停留原页，不把加载失败解释成正式翻页。
    }
  }

  void _endDrag(DragEndDetails details) {
    if (_ignoreDrag || !widget.enabled) return;
    if (_interactive) {
      unawaited(_settleDrag(details.primaryVelocity ?? 0));
    } else if (_drag.abs() > 35 || (details.primaryVelocity ?? 0).abs() > 200) {
      unawaited(
        turn(_drag.abs() > 35 ? _drag < 0 : (details.primaryVelocity ?? 0) < 0),
      );
    }
  }

  void _cancelDrag(Axis axis) {
    if (_interactive && _dragging && _dragAxis == axis) {
      unawaited(_settleDrag(0, cancelled: true));
    }
  }

  /// 松手只接受当前方向的速度。快速反向收手可以撤销已超过距离阈值的拖动。
  /// 动画到达终点后才调用 onTurn，回弹、系统取消及边界拖动均不写阅读进度。
  Future<void> _settleDrag(double velocity, {bool cancelled = false}) async {
    if (!_dragging) return;
    _dragging = false;
    if (cancelled) _previewOperation++;
    final operation = _operation;
    bool stale() => !mounted || operation != _operation;
    try {
      if (!cancelled) await _previewTask;
      if (stale()) return;
      final directedVelocity = velocity * (_forward ? -1 : 1);
      final distanceEnough = _drag.abs() >= math.min(_extent * .24, 180);
      final fling = directedVelocity >= 650 && _drag.abs() >= 12;
      final commit =
          !cancelled &&
          _prepared &&
          directedVelocity > -650 &&
          (distanceEnough || fling);
      final destination = commit ? 1.0 : 0.0;
      final remaining = (destination - _animation.value).abs();
      final milliseconds = velocity.abs() > 650
          ? (remaining * _extent / velocity.abs() * 1000).clamp(100, 280)
          : 150 + 130 * remaining;
      await _animation
          .animateTo(
            destination,
            duration: Duration(milliseconds: milliseconds.round()),
            curve: Curves.easeOutCubic,
          )
          .orCancel;
      if (stale() || !commit) return;
      _committing = true;
      final moved = await widget.onTurn(_forward);
      if (stale()) return;
      // 正式提交被锁屏等状态拒绝时，仍然回到原页，不留下一张“假翻页”。
      if (!moved) {
        await _animation
            .animateBack(
              0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
            )
            .orCancel;
      } else {
        await WidgetsBinding.instance.endOfFrame;
      }
    } on TickerCanceled {
      // 窗口缩放、设置变化或退出阅读会取消当前手势。
    } catch (_) {
      // 异步导航失败时清理预览，真实阅读页仍由父组件负责。
    } finally {
      if (!stale()) {
        _previewOperation++;
        setState(_clearTransition);
      }
    }
  }

  Widget _pageSurface(ReaderPage page, Widget? background) => Stack(
    fit: StackFit.expand,
    children: [
      background ?? ColoredBox(color: widget.background),
      Padding(padding: widget.pagePadding, child: page),
    ],
  );

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
        onPointerCancel: (_) {
          // Flutter 已接受的拖动在 PointerCancel 时也可能走 onEnd，不能当成正常松手。
          // 在手势路由分发前标记取消，确保超过距离阈值时仍回弹且不提交阅读进度。
          _ignoreDrag = true;
          if (_interactive && _dragging) {
            unawaited(_settleDrag(0, cancelled: true));
          }
        },
        onPointerSignal: (event) {
          if (widget.enabled &&
              event is PointerScrollEvent &&
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
          dragStartBehavior: DragStartBehavior.down,
          onTapUp: (details) {
            if (!widget.enabled || _turning) return;
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
          onHorizontalDragStart: (_) => _startDrag(Axis.horizontal),
          onHorizontalDragUpdate: (details) => _updateDrag(details.delta.dx),
          onHorizontalDragEnd: _endDrag,
          onHorizontalDragCancel: () => _cancelDrag(Axis.horizontal),
          onVerticalDragStart: vertical
              ? (_) => _startDrag(Axis.vertical)
              : null,
          onVerticalDragUpdate: vertical
              ? (details) => _updateDrag(details.delta.dy)
              : null,
          onVerticalDragEnd: vertical ? _endDrag : null,
          onVerticalDragCancel: vertical
              ? () => _cancelDrag(Axis.vertical)
              : null,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _animation,
              builder: (context, _) {
                final previous = _previous;
                if (previous == null || _size != _transitionSize) {
                  return _pageSurface(widget.child, widget.backgroundLayer);
                }
                if (!_prepared) {
                  return _pageSurface(previous, _previousBackground);
                }
                return PageTurnTransition(
                  effect: _effect,
                  previous: previous,
                  current: _previewPage ?? widget.child,
                  progress: _animation.value,
                  forward: _forward,
                  background: widget.background,
                  particleDirectional: widget.particleDirectional,
                  previousInk: _previousInk,
                  currentInk: _currentInk,
                  padding: widget.pagePadding,
                  previousBackground: _previousBackground,
                  currentBackground: _interactive
                      ? _previewBackground
                      : widget.backgroundLayer,
                  linearProgress: _linearProgress,
                );
              },
            ),
          ),
        ),
      );
    },
  );
}
