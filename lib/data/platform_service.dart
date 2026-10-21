import 'dart:io';
import 'package:flutter/services.dart';

/// 封装原生文件面板和窗口菜单。原生层只返回已复制进缓存的受控路径。
class PlatformService {
  static const channel = MethodChannel('com.xiongjian.reader/platform');
  Future<String> supportPath() async {
    final path = await channel.invokeMethod<String>('supportPath');
    if (path == null || path.isEmpty) {
      throw const FileSystemException('无法获取存储目录');
    }
    return path;
  }

  Future<List<String>> pick({bool folder = false, bool font = false}) async =>
      await channel.invokeListMethod<String>('pick', {
        'folder': folder,
        'font': font,
      }) ??
      [];

  /// 兼容各平台原有列表返回值，以及 iOS 的部分失败提示。
  String? imageImportWarning;
  Future<List<String>> pickImages() async {
    imageImportWarning = null;
    final value = await channel.invokeMethod<Object?>('pickImages');
    if (value is List) return value.whereType<String>().toList();
    if (value is Map) {
      final failed = value['failed'];
      if (failed is num && failed > 0) {
        imageImportWarning = '${failed.toInt()} 张照片读取失败，请确认照片已下载到本机，或联网后重试';
      }
      return (value['paths'] as List? ?? []).whereType<String>().toList();
    }
    return [];
  }

  Future<String> photoAccess() async =>
      await channel.invokeMethod<String>('photoAccess') ?? 'system';
  Future<void> managePhotoAccess() =>
      channel.invokeMethod<void>('managePhotoAccess');

  /// 清理原生选择器产生的缓存副本；原生层再次校验目录边界。
  Future<void> discard(List<String> paths) async {
    if (paths.isEmpty) {
      return;
    }
    try {
      await channel.invokeMethod<void>('discard', paths);
    } catch (_) {
      /* 系统可在后续清理缓存。 */
    }
  }

  Future<void> readingMode(bool reading) async {
    if (Platform.isMacOS) {
      await channel.invokeMethod<void>('readingMode', reading);
    }
  }

  /// 阅读页响应 Escape 时由原生窗口执行最小化。
  Future<void> minimize() async {
    if (Platform.isMacOS) {
      await channel.invokeMethod<void>('minimize');
    }
  }

  /// 原生磨砂标题栏跟随应用主题。其他平台忽略窗口外观通道。
  Future<void> appearance(String theme) async {
    if (!Platform.isMacOS) {
      return;
    }
    try {
      await channel.invokeMethod<void>('appearance', theme);
    } catch (_) {
      /* 兼容旧通道。 */
    }
  }

  void onMenu(Future<void> Function(String) callback) {
    channel.setMethodCallHandler((call) async {
      await callback(call.method);
    });
  }

  void dispose() => channel.setMethodCallHandler(null);
}
