import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../domain/page_turn_effect.dart';
import 'page_ink_snapshot.dart';
import 'reader_page.dart';

/// 两个已排版页面之间的视觉过渡，不参与正文定位、分页或进度持久化。
/// 移动型效果使用互补裁切，透明背景下不会叠加两整页文字。
class PageTurnTransition extends StatelessWidget {
  const PageTurnTransition({
    super.key,
    required this.effect,
    required this.previous,
    required this.current,
    required this.progress,
    required this.forward,
    required this.background,
    this.particleDirectional = false,
    this.previousInk,
    this.currentInk,
  });
  final PageTurnEffect effect;
  final ReaderPage previous, current;
  final double progress;
  final bool forward;
  final bool particleDirectional;
  final Color background;
  final PageInkSnapshot? previousInk, currentInk;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final raw = progress.clamp(0.0, 1.0);
      final p = Curves.easeInOutCubic.transform(raw);
      final direction = forward ? 1.0 : -1.0;
      Widget region(
        Widget child,
        double start,
        double end, {
        bool vertical = false,
      }) => ClipRect(clipper: _PageRegion(start, end, vertical), child: child);
      Widget move(Widget child, Offset offset) =>
          Transform.translate(offset: offset, child: child);
      final old = RepaintBoundary(child: previous);
      final next = RepaintBoundary(child: current);
      Widget stack(List<Widget> children) =>
          Stack(fit: StackFit.expand, children: children);
      switch (effect) {
        case PageTurnEffect.none:
          return current;
        case PageTurnEffect.cover:
          return stack([
            region(forward ? old : next, 0, forward ? 1 - p : p),
            move(
              forward ? next : old,
              Offset(size.width * (forward ? 1 - p : p), 0),
            ),
          ]);
        case PageTurnEffect.slide:
          return stack([
            move(old, Offset(-direction * size.width * p, 0)),
            move(next, Offset(direction * size.width * (1 - p), 0)),
          ]);
        case PageTurnEffect.vertical:
          return stack([
            move(old, Offset(0, -direction * size.height * p)),
            move(next, Offset(0, direction * size.height * (1 - p))),
          ]);
        case PageTurnEffect.fade:
          // 先消隐再显现，避免中文密集正文在半透明阶段重叠难辨。
          return stack([
            Opacity(opacity: (1 - raw * 2).clamp(0.0, 1.0), child: old),
            Opacity(opacity: (raw * 2 - 1).clamp(0.0, 1.0), child: next),
          ]);
        case PageTurnEffect.hardcover:
        case PageTurnEffect.card:
          final outgoing = p < .5;
          final angle = outgoing
              ? -direction * math.pi * p
              : direction * math.pi * (1 - p);
          final hinge = effect == PageTurnEffect.card
              ? Alignment.center
              : (forward == outgoing
                    ? Alignment.centerLeft
                    : Alignment.centerRight);
          return Transform(
            alignment: hinge,
            transform: Matrix4.identity()
              ..setEntry(3, 2, .0007)
              ..rotateY(angle),
            child: ShaderMask(
              blendMode: BlendMode.modulate,
              shaderCallback: (rect) => LinearGradient(
                colors: [
                  Colors.white,
                  Color.lerp(
                    Colors.white,
                    Colors.grey,
                    math.sin(p * math.pi) * .35,
                  )!,
                ],
              ).createShader(rect),
              child: outgoing ? old : next,
            ),
          );
        case PageTurnEffect.stack:
          final split = forward ? 1 - p : p;
          final exposed = Transform.scale(
            scale: .94 + .06 * (forward ? p : 1 - p),
            child: forward ? next : old,
          );
          final moving = Transform.translate(
            offset: Offset(size.width * (forward ? -p : p - 1), 0),
            child: Transform.rotate(
              alignment: Alignment.bottomLeft,
              angle: -.035 * math.sin(math.pi * p),
              child: forward ? old : next,
            ),
          );
          return stack([region(exposed, split, 1), region(moving, 0, split)]);
        case PageTurnEffect.curl:
        case PageTurnEffect.particles:
        case PageTurnEffect.ink:
          if (previousInk == null || currentInk == null) {
            return raw < .5 ? previous : current;
          }
          return CustomPaint(
            painter: _InkTransitionPainter(
              previousInk!,
              currentInk!,
              effect,
              raw,
              forward,
              background,
              particleDirectional,
            ),
            size: Size.infinite,
          );
      }
    },
  );
}

class _PageRegion extends CustomClipper<Rect> {
  const _PageRegion(this.start, this.end, this.vertical);
  final double start, end;
  final bool vertical;
  @override
  Rect getClip(Size size) => vertical
      ? Rect.fromLTRB(0, size.height * start, size.width, size.height * end)
      : Rect.fromLTRB(size.width * start, 0, size.width * end, size.height);
  @override
  bool shouldReclip(covariant _PageRegion old) =>
      old.start != start || old.end != end || old.vertical != vertical;
}

/// 粒子与卷页都使用有限尺寸的透明墨迹快照，动画帧不再排版正文。
class _InkTransitionPainter extends CustomPainter {
  _InkTransitionPainter(
    this.previous,
    this.current,
    this.effect,
    this.progress,
    this.forward,
    this.background,
    this.particleDirectional,
  );
  final PageInkSnapshot previous, current;
  final PageTurnEffect effect;
  final double progress;
  final bool forward;
  final bool particleDirectional;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (progress <= 0) {
      previous.paint(canvas, size);
    } else if (progress >= 1) {
      current.paint(canvas, size);
    } else if (effect == PageTurnEffect.particles) {
      previous.paintParticles(
        canvas,
        size,
        progress,
        incoming: false,
        forward: forward,
        directional: particleDirectional,
      );
      current.paintParticles(
        canvas,
        size,
        progress,
        incoming: true,
        forward: forward,
        directional: particleDirectional,
      );
    } else if (effect == PageTurnEffect.ink) {
      previous.paintWaterInk(canvas, size, progress, incoming: false);
      current.paintWaterInk(canvas, size, progress, incoming: true);
    } else {
      _curl(canvas, size);
    }
    canvas.restore();
  }

  /// 卷边沿着纸面推进；背面按圆柱弧度分成 48 个窄片，带反向墨迹和柔和折面。
  /// 透明模式不补不透明纸色，保留用户选择的背景透明度。
  void _curl(Canvas canvas, Size size) {
    final p = Curves.easeInOutCubic.transform(
      forward ? progress : 1 - progress,
    );
    final top = forward ? previous : current;
    final base = forward ? current : previous;
    final seam = size.width * (1 - p);
    final bend = size.width * .18 * math.sin(math.pi * p);
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(seam + bend, 0, size.width, size.height));
    base.paint(canvas, size);
    canvas.restore();
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, seam, size.height));
    top.paint(canvas, size);
    canvas.restore();
    if (bend < .01) {
      return;
    }
    final image = top.image;
    final paint = Paint()..filterQuality = FilterQuality.low;
    const strips = 48;
    for (var i = 0; i < strips; i++) {
      final u = i / strips, v = (i + 1) / strips;
      final left = seam + math.sin(u * math.pi / 2) * bend;
      final right = seam + math.sin(v * math.pi / 2) * bend;
      final inset =
          math.sin(u * math.pi) * size.height * .035 * math.sin(math.pi * p);
      final target = Rect.fromLTRB(
        left,
        inset,
        right + .4,
        size.height - inset,
      );
      canvas.drawRect(target, Paint()..color = background);
      final sourceStart =
          (seam + (size.width - seam) * (1 - v)) / size.width * image.width;
      final sourceEnd =
          (seam + (size.width - seam) * (1 - u)) / size.width * image.width;
      // 逐窄片反向取样自然形成纸张背面的镜像笔画。
      canvas.drawImageRect(
        image,
        Rect.fromLTRB(sourceStart, 0, sourceEnd, image.height.toDouble()),
        target,
        paint..color = Color.fromRGBO(255, 255, 255, .48 + .3 * u),
      );
    }
    final fold = Rect.fromLTWH(seam, 0, bend, size.height);
    canvas.drawRect(
      fold,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(seam, 0),
          Offset(seam + bend, 0),
          [
            Colors.black.withValues(alpha: .15 * background.a),
            Colors.white.withValues(alpha: .12 * background.a),
            Colors.transparent,
          ],
          [0, .45, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(covariant _InkTransitionPainter old) =>
      old.previous != previous ||
      old.current != current ||
      old.effect != effect ||
      old.progress != progress ||
      old.forward != forward ||
      old.background != background ||
      old.particleDirectional != particleDirectional;
}
