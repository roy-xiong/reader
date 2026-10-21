import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'reader_page.dart';

/// 单次翻页使用的透明墨迹快照；用于卷页、粒子和水墨效果，动画结束即释放。
///
/// 快照最大约 120 万像素、最长边 2048，避免大窗口和高像素比放大内存。
/// 粒子只从有墨迹的小块生成，使用原图的笔画和颜色，不在整页背景生成随机点。
class PageInkSnapshot {
  PageInkSnapshot._(this.image, this.size);
  final ui.Image image;
  final Size size;
  Float32List? _rects, _transforms, _noise;
  Int32List? _colors;
  final _paint = Paint()..filterQuality = FilterQuality.low;
  bool _disposed = false;
  ui.Image? _inkMask, _wetInk;

  int get particleCount => (_rects?.length ?? 0) ~/ 4;

  static Future<PageInkSnapshot> capture(
    ReaderPage page,
    Size size, {
    bool particles = false,
    bool ink = false,
  }) async {
    if (!size.width.isFinite || !size.height.isFinite || size.isEmpty) {
      throw ArgumentError('正文尺寸无效');
    }
    final ratio = math.min(
      1.5,
      math.min(
        2048 / math.max(size.width, size.height),
        math.sqrt(1200000 / (size.width * size.height)),
      ),
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(ratio);
    canvas.clipRect(Offset.zero & size);
    page.paintInk(canvas, size);
    final picture = recorder.endRecording();
    ui.Image? image;
    PageInkSnapshot? snapshot;
    try {
      image = await picture.toImage(
        math.max(1, (size.width * ratio).ceil()),
        math.max(1, (size.height * ratio).ceil()),
      );
      snapshot = PageInkSnapshot._(image, size);
      if (particles) {
        await snapshot._sampleInk();
      }
      if (ink) {
        await snapshot._prepareInkMask(page.page.start);
        await snapshot._prepareWetInk();
      }
      return snapshot;
    } catch (_) {
      if (snapshot != null) {
        snapshot.dispose();
      } else {
        image?.dispose();
      }
      rethrow;
    } finally {
      picture.dispose();
    }
  }

  /// 每幅图至多约 18000 个候选小块；空白块剔除后通常仅剩几千个粒子。
  /// 坐标、随机量和绘制缓冲区只分配一次，逐帧更新时不创建粒子对象。
  Future<void> _sampleInk() async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw StateError('无法读取正文墨迹');
    }
    final pixels = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final cell = math.max(
      3,
      math.sqrt(image.width * image.height / 18000).ceil(),
    );
    final rects = <double>[];
    final noise = <double>[];
    for (var y = 0; y < image.height; y += cell) {
      for (var x = 0; x < image.width; x += cell) {
        final right = math.min(x + cell, image.width);
        final bottom = math.min(y + cell, image.height);
        var hasInk = false;
        for (var py = y; py < bottom && !hasInk; py++) {
          for (var px = x; px < right; px++) {
            if (pixels[(py * image.width + px) * 4 + 3] > 8) {
              hasInk = true;
              break;
            }
          }
        }
        if (!hasInk) {
          continue;
        }
        // 保留原版完整笔画小块。只在运动过程中缩小精灵，不能把整块墨迹抽成单像素。
        rects.addAll([
          x.toDouble(),
          y.toDouble(),
          right.toDouble(),
          bottom.toDouble(),
        ]);
        // 坐标哈希使同一笔画的运动可重现，重绘时不会抖动。
        final seed = ((x * 73856093) ^ (y * 19349663)) & 0x7fffffff;
        noise.addAll([(seed % 997) / 997, ((seed ~/ 997) % 991) / 991]);
      }
    }
    _rects = Float32List.fromList(rects);
    _noise = Float32List.fromList(noise);
    _transforms = Float32List(rects.length);
    _colors = Int32List(rects.length ~/ 4);
  }

  void paint(Canvas canvas, Size target, {double opacity = 1}) {
    if (_disposed || opacity <= 0) {
      return;
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & target,
      _paint..color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0)),
    );
  }

  /// 小块直接取原图中的笔画像素。散开或聚合只改变墨迹，不绘制页面背景。
  void paintParticles(
    Canvas canvas,
    Size target,
    double progress, {
    required bool incoming,
    required bool forward,
    bool directional = false,
  }) {
    final rects = _rects,
        transforms = _transforms,
        noise = _noise,
        colors = _colors;
    if (_disposed ||
        rects == null ||
        transforms == null ||
        noise == null ||
        colors == null) {
      return;
    }
    final scaleX = target.width / image.width;
    final scaleY = target.height / image.height;
    // 在等比录制的图像坐标内绘制，最后恢复到实际窗口尺寸。
    canvas.save();
    canvas.scale(scaleX, scaleY);
    final direction = forward ? -1.0 : 1.0;
    for (var i = 0; i < colors.length; i++) {
      final r = i * 4;
      final x = rects[r], y = rects[r + 1];
      final n = noise[i * 2], m = noise[i * 2 + 1];
      final sweep = forward ? x / image.width : 1 - x / image.width;
      // 默认不区分前后翻页：去掉左右扫过的时序，使用各笔画自身的随机延迟。
      final delay = directional ? sweep * .12 + n * .10 : n * .22;
      final local = incoming
          ? ((progress - .32 - delay) / (.68 - delay)).clamp(0.0, 1.0)
          : ((progress - delay) / (.68 - delay)).clamp(0.0, 1.0);
      final scatter = incoming ? 1 - local : local;
      final alpha = incoming ? local * local : (1 - local) * (1 - local);
      final angle = (m - .5) * scatter * 1.2;
      // 原版的位移、延迟和透明度保持不变，仅缩小已炸开的颗粒。
      // 静止时仍为 1；完全散开时从原版 0.52 缩至 0.30，避免整段文字同时变淡。
      final scale = 1 - scatter * .70;
      final c = math.cos(angle) * scale, s = math.sin(angle) * scale;
      // 关闭方向感时在原笔画周围均匀散开，不保留水平或向上的整体漂移。
      final radius = 8 + 22 * n;
      final dx =
          (directional
              ? direction * (12 + 45 * n)
              : math.cos(m * math.pi * 2) * radius) *
          scatter /
          scaleX;
      final dy =
          (directional
              ? (m - .5) * 35 - 20 * scatter
              : math.sin(m * math.pi * 2) * radius) *
          scatter /
          scaleY;
      final w = rects[r + 2] - x, h = rects[r + 3] - y;
      // RSTransform 的平移量以精灵局部坐标为基准。
      transforms[r] = c;
      transforms[r + 1] = s;
      transforms[r + 2] = x + dx + w / 2 - c * w / 2 + s * h / 2;
      transforms[r + 3] = y + dy + h / 2 - s * w / 2 - c * h / 2;
      colors[i] = ((alpha * 255).round().clamp(0, 255) << 24) | 0x00ffffff;
    }
    canvas.drawRawAtlas(
      image,
      transforms,
      rects,
      colors,
      BlendMode.modulate,
      null,
      _paint..color = const Color(0xffffffff),
    );
    canvas.restore();
  }

  /// 低分辨率、可复现的柔边墨云遮罩。只录制一次，逐帧以色彩矩阵改变墨迹覆盖。
  Future<void> _prepareInkMask(int seed) async {
    const extent = 192.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(const Color.fromRGBO(255, 255, 255, .1), BlendMode.src);
    final random = math.Random(seed & 0x7fffffff);
    for (var i = 0; i < 80; i++) {
      final point = Offset(
        random.nextDouble() * extent,
        random.nextDouble() * extent,
      );
      final radius = 12 + random.nextDouble() * 30;
      canvas.drawCircle(
        point,
        radius,
        Paint()
          ..shader = ui.Gradient.radial(point, radius, [
            Color.fromRGBO(255, 255, 255, .45 + random.nextDouble() * .4),
            const Color.fromRGBO(255, 255, 255, 0),
          ]),
      );
    }
    final picture = recorder.endRecording();
    try {
      _inkMask = await picture.toImage(extent.toInt(), extent.toInt());
    } finally {
      picture.dispose();
    }
  }

  /// 浸润纹理在开始动画前一次生成，最长边 640px；逐帧只混合位图与遮罩。
  /// 不在每一帧执行大半径形态学滤镜，避免大窗口连续翻页时出现绘制峰值。
  Future<void> _prepareWetInk() async {
    final ratio = math.min(1.0, 640 / math.max(size.width, size.height));
    final width = math.max(1, (size.width * ratio).ceil());
    final height = math.max(1, (size.height * ratio).ceil());
    final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    final dryRecorder = ui.PictureRecorder();
    Canvas(dryRecorder).drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      rect,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final dryPicture = dryRecorder.endRecording();
    ui.Image? reduced;
    try {
      reduced = await dryPicture.toImage(width, height);
      final wetRecorder = ui.PictureRecorder();
      final canvas = Canvas(wetRecorder);
      canvas.drawImage(
        reduced,
        Offset.zero,
        Paint()
          ..color = const Color.fromRGBO(255, 255, 255, .36)
          ..imageFilter = ui.ImageFilter.compose(
            outer: ui.ImageFilter.blur(sigmaX: 5 * ratio, sigmaY: 3.5 * ratio),
            inner: ui.ImageFilter.dilate(
              radiusX: 4.5 * ratio,
              radiusY: 3 * ratio,
            ),
          ),
      );
      canvas.drawImage(
        reduced,
        Offset.zero,
        Paint()
          ..imageFilter = ui.ImageFilter.compose(
            outer: ui.ImageFilter.blur(sigmaX: .9 * ratio, sigmaY: .7 * ratio),
            inner: ui.ImageFilter.dilate(
              radiusX: 2.8 * ratio,
              radiusY: 2 * ratio,
            ),
          ),
      );
      final wetPicture = wetRecorder.endRecording();
      try {
        _wetInk = await wetPicture.toImage(width, height);
      } finally {
        wetPicture.dispose();
      }
    } finally {
      reduced?.dispose();
      dryPicture.dispose();
    }
  }

  /// 水墨分为浸润、墨团扩散和重新凝聚三个可见阶段。
  /// 使用原笔画颜色形成毛边与墨晕，照片和透明背景不参与染色；逐帧不创建位图。
  void paintWaterInk(
    Canvas canvas,
    Size target,
    double progress, {
    required bool incoming,
  }) {
    if (_disposed) return;
    final local = incoming
        ? ((progress - .22) / .78).clamp(0.0, 1.0)
        : (progress / .78).clamp(0.0, 1.0);
    final eased = local * local * (3 - 2 * local);
    final gate = incoming ? eased : 1 - eased;
    if (gate <= 0) return;
    final mask = _inkMask;
    if (gate >= 1 || mask == null) {
      paint(canvas, target, opacity: gate);
      return;
    }
    // 笔画渐渐浸润至预生成的墨团纹理，再反向收拢；背景不参与混合。
    final wet = math.sin(local * math.pi);
    final rect = Offset.zero & target;
    canvas.saveLayer(rect, Paint());
    paint(canvas, target, opacity: 1 - wet);
    final soaked = _wetInk;
    if (soaked != null) {
      canvas.drawImageRect(
        soaked,
        Rect.fromLTWH(0, 0, soaked.width.toDouble(), soaked.height.toDouble()),
        rect,
        Paint()
          ..filterQuality = FilterQuality.medium
          ..color = Color.fromRGBO(255, 255, 255, wet),
      );
    }
    // 墨团按不规则柔边区域侵蚀、聚合，区别于整页透明度交叉淡化。
    canvas.drawImageRect(
      mask,
      Rect.fromLTWH(0, 0, mask.width.toDouble(), mask.height.toDouble()),
      rect,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..blendMode = BlendMode.dstIn
        ..colorFilter = ColorFilter.matrix([
          1,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          0,
          0,
          7,
          (gate * 1.35 - 1.1) * 7 * 255,
        ]),
    );
    canvas.restore();
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    image.dispose();
    _inkMask?.dispose();
    _wetInk?.dispose();
    _inkMask = _wetInk = null;
    _rects = _transforms = _noise = null;
    _colors = null;
  }
}
