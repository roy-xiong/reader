import 'package:flutter/material.dart';
import 'core/reader_icon.dart';
import 'page_flip_session.dart';
import 'reader_page.dart';

/// 中央单页预览。按正文尺寸绘制后整体缩小，横向滑动只改变临时预览位置。
class PageFlipPreview extends StatefulWidget {
  const PageFlipPreview({
    super.key,
    required this.session,
    required this.background,
    required this.onClose,
    required this.onConfirm,
  });
  final PageFlipSession session;
  final Color background;
  final VoidCallback onClose, onConfirm;

  @override
  State<PageFlipPreview> createState() => _PageFlipPreviewState();
}

class _PageFlipPreviewState extends State<PageFlipPreview> {
  double _drag = 0;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final page = session.page;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                session.chapterTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
            IconButton(
              key: const ValueKey('close-page-preview'),
              tooltip: '关闭预览，保留原阅读位置',
              color: Colors.white,
              onPressed: widget.onClose,
              icon: const ReaderIcon(ReaderGlyph.close),
            ),
          ],
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Center(
              child: FittedBox(
                fit: BoxFit.contain,
                child: GestureDetector(
                  key: const ValueKey('page-preview-card'),
                  behavior: HitTestBehavior.opaque,
                  onTap: session.ready ? widget.onConfirm : null,
                  onHorizontalDragStart: (_) => _drag = 0,
                  onHorizontalDragUpdate: (event) => _drag += event.delta.dx,
                  onHorizontalDragEnd: (event) {
                    final velocity = event.primaryVelocity ?? 0;
                    if (_drag.abs() > 28 || velocity.abs() > 180) {
                      session.step(_drag.abs() > 28 ? _drag < 0 : velocity < 0);
                    }
                  },
                  child: Material(
                    elevation: 8,
                    color: widget.background.withValues(alpha: 1),
                    borderRadius: BorderRadius.circular(14),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      width: session.width + 40,
                      height: session.height + 40,
                      child: Stack(
                        children: [
                          if (page != null)
                            Positioned.fill(
                              child: Padding(
                                padding: const EdgeInsets.all(20),
                                child: RepaintBoundary(
                                  child: ReaderPage(
                                    page: page,
                                    width: session.width,
                                    style: session.style,
                                    scaler: session.scaler,
                                  ),
                                ),
                              ),
                            ),
                          if (session.loading || session.error != null)
                            Positioned.fill(
                              child: ColoredBox(
                                color: widget.background.withValues(alpha: .9),
                                child: Center(
                                  child: session.error != null
                                      ? Padding(
                                          padding: const EdgeInsets.all(20),
                                          child: Text(
                                            session.error!,
                                            style: session.style.copyWith(
                                              fontSize: 16,
                                            ),
                                          ),
                                        )
                                      : const CircularProgressIndicator(),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
