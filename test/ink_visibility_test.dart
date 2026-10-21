import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/domain/pagination.dart';
import 'package:reader/ui/page_ink_snapshot.dart';
import 'package:reader/ui/reader_page.dart';

/// 直接检查实际墨迹帧，防止“能绘制但看不见”的动画再次通过仅检查非空的测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const size = Size(300, 180);
  const page = ReaderPage(
    page: ReadingPage(0, 20, [
      PageFragment('INK TEST', 48, 35),
      PageFragment('VISIBLE', 105, 35),
    ]),
    width: 300,
    style: TextStyle(fontSize: 25, color: Color(0xff999999)),
    scaler: TextScaler.noScaling,
  );

  testWidgets('粒子散开期间保持可见墨迹，不能退化为近乎空白的淡出', (tester) async {
    await tester.runAsync(() async {
      final ink = await PageInkSnapshot.capture(page, size, particles: true);
      try {
        final original = await _render(
          size,
          (canvas) => ink.paint(canvas, size),
        );
        final frame = await _render(
          size,
          (canvas) => ink.paintParticles(
            canvas,
            size,
            .36,
            incoming: false,
            forward: true,
          ),
        );
        final mass = _mass(frame) / _mass(original);
        expect(
          mass,
          greaterThan(.08),
          reason: '中段墨迹强度只有 ${(mass * 100).toStringAsFixed(2)}%，粒子肉眼难辨',
        );
        expect(
          _spread(frame, original),
          greaterThan(60),
          reason: '应有清晰颗粒脱离原文字笔画',
        );
      } finally {
        ink.dispose();
      }
    });
  });

  testWidgets('水墨有可见的笔画浸润与外扩，不能仅用随机遮罩淡出', (tester) async {
    await tester.runAsync(() async {
      final ink = await PageInkSnapshot.capture(page, size, ink: true);
      try {
        final original = await _render(
          size,
          (canvas) => ink.paint(canvas, size),
        );
        final frame = await _render(
          size,
          (canvas) => ink.paintWaterInk(canvas, size, .27, incoming: false),
        );
        final bleed = _spread(frame, original);
        expect(
          bleed,
          greaterThan(500),
          reason: '浸润阶段必须看得见墨迹沿笔画扩散，当前仅 $bleed 像素',
        );
        expect(_mass(frame), greaterThan(_mass(original) * .6));
      } finally {
        ink.dispose();
      }
    });
  });
}

Future<ByteData> _render(Size size, void Function(Canvas) paint) async {
  final recorder = ui.PictureRecorder();
  paint(Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  } finally {
    image.dispose();
    picture.dispose();
  }
}

int _mass(ByteData data) {
  var value = 0;
  for (var i = 3; i < data.lengthInBytes; i += 4) {
    value += data.getUint8(i);
  }
  return value;
}

int _spread(ByteData data, ByteData original) {
  var count = 0;
  for (var i = 3; i < data.lengthInBytes; i += 4) {
    if (data.getUint8(i) > 45 && original.getUint8(i) < 5) count++;
  }
  return count;
}
