import 'dart:io';
import 'package:flutter/services.dart';

/// 字体按需加载到 Flutter；目录扫描只读取名称表，不把每个大字体读入内存。
class FontService {
  Future<void> register(File file, String family) async {
    await validate(file);
    final bytes = await file.readAsBytes();
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }

  /// 校验文件签名，不设置人为的字体大小上限。
  static Future<void> validate(File file) async {
    final handle = await file.open();
    try {
      final bytes = await handle.read(12);
      if (bytes.length < 12 ||
          ![
            0x00010000,
            0x4f54544f,
            0x74746366,
            0x74727565,
          ].contains(ByteData.sublistView(bytes).getUint32(0))) {
        throw const FormatException('请选择有效的 TTF / OTF 字体');
      }
    } finally {
      await handle.close();
    }
  }

  /// 恢复旧版字体记录时从 SFNT 名称表获取全名，读取范围有界且兼容 TTC。
  static Future<String?> readName(File file) async {
    final handle = await file.open();
    try {
      final fileLength = await handle.length();
      var header = await handle.read(12);
      if (header.length != 12) {
        return null;
      }
      var data = ByteData.sublistView(header);
      if (data.getUint32(0) == 0x74746366) {
        final offsetBytes = await handle.read(4);
        if (offsetBytes.length != 4) {
          return null;
        }
        await handle.setPosition(
          ByteData.sublistView(offsetBytes).getUint32(0),
        );
        header = await handle.read(12);
        if (header.length != 12) {
          return null;
        }
        data = ByteData.sublistView(header);
      }
      final tableCount = data.getUint16(4);
      if (tableCount == 0 || tableCount > 512) {
        return null;
      }
      final tables = await handle.read(tableCount * 16);
      if (tables.length != tableCount * 16) {
        return null;
      }
      final tableData = ByteData.sublistView(tables);
      for (var i = 0; i < tableCount; i++) {
        final index = i * 16;
        if (tableData.getUint32(index) != 0x6e616d65) {
          continue;
        }
        final offset = tableData.getUint32(index + 8),
            length = tableData.getUint32(index + 12);
        if (length < 6 || offset + length > fileLength) {
          return null;
        }
        await handle.setPosition(offset);
        final nameHeader = await handle.read(6);
        final metadata = ByteData.sublistView(nameHeader);
        final count = metadata.getUint16(2), storage = metadata.getUint16(4);
        if (count > 4096 || 6 + count * 12 > length) {
          return null;
        }
        final recordBytes = await handle.read(count * 12);
        final records = ByteData.sublistView(recordBytes);
        String? best;
        var bestScore = -1;
        for (var record = 0; record < count; record++) {
          final n = record * 12;
          final platform = records.getUint16(n),
              language = records.getUint16(n + 4),
              nameId = records.getUint16(n + 6);
          final size = records.getUint16(n + 8),
              position = records.getUint16(n + 10);
          if ((platform != 0 && platform != 3) ||
              (nameId != 1 && nameId != 4) ||
              size == 0 ||
              size > 4096 ||
              size.isOdd ||
              storage + position + size > length) {
            continue;
          }
          final score =
              (nameId == 4 ? 10 : 0) +
              (language == 0x0804
                  ? 3
                  : language == 0x0409
                  ? 2
                  : 0);
          if (score <= bestScore) {
            continue;
          }
          await handle.setPosition(offset + storage + position);
          final textBytes = await handle.read(size);
          final text = ByteData.sublistView(textBytes);
          final value = String.fromCharCodes(
            List.generate(size ~/ 2, (i) => text.getUint16(i * 2)),
          ).replaceAll('\u0000', '').trim();
          if (value.isNotEmpty) {
            best = value;
            bestScore = score;
          }
        }
        return best;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      await handle.close();
    }
  }
}
