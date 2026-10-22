import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../domain/models.dart';
import '../../domain/pagination.dart';
import '../app_model.dart';
import '../reader_page.dart';
import '../reader_pager.dart';
import '../reading_backdrop.dart';
import '../reading_style.dart';
import '../reading_brightness.dart';

/// 设置中唯一的阅读预览：复用正文分页、字形绘制、照片遮罩和翻页组件。
/// 样本文字及页码仅保存在此组件，试翻不修改书籍进度，也不累计照片轮换次数。
class ReadingStylePreview extends StatefulWidget {
  const ReadingStylePreview({super.key, required this.model});
  final AppModel model;
  @override
  State<ReadingStylePreview> createState() => _ReadingStylePreviewState();
}

class _ReadingStylePreviewState extends State<ReadingStylePreview> {
  final _pager = GlobalKey<ReaderPagerState>();
  List<ReadingPage> _pages = const [];
  Object? _layoutKey;
  int _generation = 0, _index = 0;
  bool _layingOut = false;
  static const _title = '字里行间';
  static const _paragraphs = [
    '窗外的风轻轻吹过，书页上落下一束温柔的光。放慢脚步，在文字之间，找到自己的节奏。',
    '读到喜欢的句子，不妨稍作停留。山川与远方，日常与梦想，都在下一页等你。',
    '每一次翻页，都是一次新的相遇。愿这些安静的时刻，陪你走过漫长的旅途。',
  ];

  BookDocument _document(String script) {
    final traditional = script == 'traditional';
    final title = traditional ? '字裡行間' : _title;
    final paragraphs = traditional
        ? const [
            '窗外的風輕輕吹過，書頁上落下一束溫柔的光。放慢腳步，在文字之間，找到自己的節奏。',
            '讀到喜歡的句子，不妨稍作停留。山川與遠方，日常與夢想，都在下一頁等你。',
            '每一次翻頁，都是一次新的相遇。願這些安靜的時刻，陪你走過漫長的旅途。',
          ]
        : _paragraphs;
    final text =
        '$title\n\n${List.generate(9, (i) => paragraphs[i % paragraphs.length]).join('\n\n')}';
    return BookDocument(
      title: _title,
      author: '',
      text: text,
      chapters: [
        Chapter(
          title: _title,
          start: 0,
          end: text.length,
          headingEnd: title.length,
        ),
      ],
    );
  }

  /// 拖动滑块会取消旧排版；只有最后一次排版可以提交，路由退出后丢弃结果。
  void _layout(
    double width,
    double height,
    TextStyle style,
    TextScaler scaler,
  ) {
    final s = widget.model.settings;
    final key = (
      width,
      height,
      style,
      scaler.scale(s.fontSize),
      s.paragraphSpacing,
      s.readingLayout,
      s.verticalDirection,
      s.scriptMode,
    );
    if (key == _layoutKey) return;
    _layoutKey = key;
    _layingOut = true;
    final ticket = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || ticket != _generation) return;
      try {
        final document = _document(s.scriptMode);
        final pages = await Pagination.layout(
          document: document,
          chapter: document.chapters.first,
          width: width,
          height: height,
          style: style,
          paragraphSpacing: s.paragraphSpacing,
          scaler: scaler,
          readingLayout: s.readingLayout,
          verticalDirection: s.verticalDirection,
          cancelled: () => !mounted || ticket != _generation,
        );
        if (!mounted || ticket != _generation) return;
        setState(() {
          _pages = pages;
          _index = 0;
          _layingOut = false;
        });
      } catch (_) {
        if (mounted && ticket == _generation) {
          setState(() {
            _pages = const [];
            _layingOut = false;
          });
        }
      }
    });
  }

  Future<bool> _turn(bool forward) async {
    if (_layingOut || _pages.length < 2) return false;
    setState(() => _index = (_index + (forward ? 1 : -1)) % _pages.length);
    return true;
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model, s = model.settings;
    final resolved = ReadingStyle.resolve(model, Theme.of(context).brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '阅读预览',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              TextButton(
                key: const ValueKey('play-page-effect'),
                onPressed: () => unawaited(_pager.currentState?.turn(true)),
                child: const Text('试翻一页'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ReadingDimmer(
            value: s.readingBrightness,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = math.max(1.0, constraints.maxWidth - 40);
                    final height = math.max(1.0, constraints.maxHeight - 40);
                    final scaler = MediaQuery.textScalerOf(context);
                    final layer = ReadingBackdrop.pageLayer(
                      model,
                      resolved.background,
                      colorKey: const ValueKey(
                        'reading-style-preview-background',
                      ),
                    );
                    _layout(width, height, resolved.text, scaler);
                    if (_layingOut || _pages.isEmpty) {
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          layer,
                          Center(
                            child: _layingOut
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                    ),
                                  )
                                : const Text('暂无可预览内容'),
                          ),
                        ],
                      );
                    }
                    ReaderPage pageAt(int index) => ReaderPage(
                      page: _pages[index],
                      width: width,
                      style: resolved.text,
                      scaler: scaler,
                    );
                    return ReaderPager(
                      key: _pager,
                      effect: s.pageEffect,
                      particleDirectional: s.particleDirectional,
                      background: resolved.background.withValues(
                        alpha: s.backgroundOpacity,
                      ),
                      backgroundLayer: layer,
                      previewBackgroundLayer: layer,
                      pagePadding: const EdgeInsets.all(20),
                      onPreview: (forward) async => _pages.length < 2
                          ? null
                          : pageAt(
                              (_index + (forward ? 1 : -1)) % _pages.length,
                            ),
                      onTurn: _turn,
                      onToggle: () =>
                          unawaited(_pager.currentState?.turn(true)),
                      child: pageAt(_index),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
