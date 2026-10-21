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
