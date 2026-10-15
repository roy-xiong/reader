import 'dart:math';
import 'package:flutter/material.dart';
import '../domain/models.dart';
import 'core/reader_icon.dart';

/// 目录只呈现真实章节，打开时直接定位当前章节，长目录也不一次创建全部条目。
class ChapterContentsDialog extends StatefulWidget {
  const ChapterContentsDialog({
    super.key,
    required this.document,
    required this.offset,
  });
  final BookDocument document;
  final int offset;
  @override
  State<ChapterContentsDialog> createState() => _ChapterContentsDialogState();
}

class _ChapterContentsDialogState extends State<ChapterContentsDialog> {
  late final chapters = widget.document.outline;
  late final selected = max(
    0,
    chapters.lastIndexWhere((chapter) => chapter.start <= widget.offset),
  );
  late final controller = ScrollController(
    initialScrollOffset: max(0, selected * 72.0 - 180),
  );
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      child: SizedBox(
        width: 620,
        height: min(620, MediaQuery.sizeOf(context).height * .8),
        child: Column(
          children: [
            ListTile(
              title: const Text('目录'),
              subtitle: Text('${chapters.length} 个章节'),
              trailing: IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const ReaderIcon(ReaderGlyph.close),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: controller,
                itemExtent: 72,
                itemCount: chapters.length,
                itemBuilder: (context, index) {
                  final chapter = chapters[index], active = index == selected;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    child: Material(
                      color: active
                          ? colors.primaryContainer
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        key: ValueKey('chapter-${chapter.start}'),
                        selected: active,
                        selectedColor: colors.onPrimaryContainer,
                        leading: Container(
                          width: 3,
                          height: 36,
                          color: active ? colors.primary : Colors.transparent,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        title: Text(
                          chapter.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: active
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                        subtitle: Text(
                          active
                              ? '正在阅读'
                              : '${(chapter.start / widget.document.text.length * 100).toStringAsFixed(1)}%',
                          style: const TextStyle(fontSize: 11),
                        ),
                        onTap: () => Navigator.pop(context, chapter.start),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
