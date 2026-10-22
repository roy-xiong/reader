import 'dart:io';
import 'package:flutter/material.dart';
import 'app_model.dart';

/// 背景只绘制一层统一透明度。照片、黑色遮罩与正文分离，翻页预览不会推动照片轮换。
class ReadingBackdrop extends StatelessWidget {
  const ReadingBackdrop({
    super.key,
    required this.model,
    required this.background,
    required this.child,
  });
  final AppModel model;
  final Color background;
  final Widget child;

  /// 创建不可变的整页背景快照。afterTurn 只预测下一次照片轮换，不修改设置。
  /// 预览取消时没有任何副作用，正式翻页后由 AppModel.recordPageTurn 统一累计。
  static Widget pageLayer(
    AppModel model,
    Color background, {
    bool afterTurn = false,
    Key? colorKey,
  }) {
    final s = model.settings;
    final photos = model.activePhotos;
    final photo = model.currentPhoto;
    final advance = afterTurn && s.photoTurns + 1 >= s.photoTurnInterval;
    final nextPhoto = photo == null || photos.isEmpty
        ? null
        : photos[(s.photoIndex + (advance ? 1 : 0)) % photos.length];
    return _ReadingBackgroundLayer(
      key: ValueKey((
        background,
        s.backgroundOpacity,
        s.photoDim,
        nextPhoto?.id,
      )),
      background: background,
      opacity: s.backgroundOpacity,
      photoDim: s.photoDim,
      photo: nextPhoto == null
          ? null
          : model.repository.backgroundFile(nextPhoto.id),
      colorKey: colorKey,
    );
  }

  @override
  Widget build(BuildContext context) {
    final photo = model.currentPhoto;
    if (photo == null || model.settings.backgroundOpacity == 0) {
      return child;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: Opacity(
                opacity: model.settings.backgroundOpacity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: background),
                    Image.file(
                      model.repository.backgroundFile(photo.id),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.low,
                      errorBuilder: (_, _, _) => ColoredBox(color: background),
                    ),
                    ColoredBox(
                      key: const ValueKey('photo-dark-mask'),
                      color: Colors.black.withValues(
                        alpha: model.settings.photoDim,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// 动画持有的是确定的文件及颜色，不持有 AppModel，也不重复叠加背景透明度。
class _ReadingBackgroundLayer extends StatelessWidget {
  const _ReadingBackgroundLayer({
    super.key,
    required this.background,
    required this.opacity,
    required this.photoDim,
    required this.photo,
    this.colorKey,
  });
  final Color background;
  final double opacity, photoDim;
  final File? photo;
  final Key? colorKey;

  @override
  Widget build(BuildContext context) {
    final file = photo;
    if (file == null || opacity == 0) {
      return ColoredBox(
        key: colorKey,
        color: background.withValues(alpha: opacity),
      );
    }
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Opacity(
          opacity: opacity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(key: colorKey, color: background),
              Image.file(
                file,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.low,
                errorBuilder: (_, _, _) => ColoredBox(color: background),
              ),
              ColoredBox(
                key: const ValueKey('photo-dark-mask'),
                color: Colors.black.withValues(alpha: photoDim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
