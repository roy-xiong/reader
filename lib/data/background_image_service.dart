import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';

/// 照片异步解码并缩到最长边 2048，仅保留静态首帧，限制阅读时的解码内存。
class BackgroundImageService {
  Future<Uint8List> normalize(File file) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final largest = descriptor.width > descriptor.height
          ? descriptor.width
          : descriptor.height;
      final ratio = largest > 2048 ? 2048 / largest : 1.0;
      codec = await descriptor.instantiateCodec(
        targetWidth: (descriptor.width * ratio).round().clamp(1, 2048),
        targetHeight: (descriptor.height * ratio).round().clamp(1, 2048),
      );
      image = (await codec.getNextFrame()).image;
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) {
        throw const FormatException('照片无法读取');
      }
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
