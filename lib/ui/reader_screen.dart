import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../domain/models.dart';
import '../domain/pagination.dart';
import '../domain/chinese_conversion.dart';
import '../data/chinese_script_service.dart';
import 'contents_dialog.dart';
import 'app_model.dart';
import 'core/reader_icon.dart';
import 'page_flip_preview.dart';
import 'page_flip_session.dart';
import 'reader_page.dart';
import 'reader_pager.dart';
import 'reading_backdrop.dart';
import 'reading_style.dart';
import 'reading_brightness.dart';
import 'reading_quick_slider.dart';

/// 阅读页默认仅显示正文和进度，点击中央时才显示临时操作栏。
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.model,
    required this.book,
    required this.openSettings,
  });
  final AppModel model;
  final BookRecord book;
  final Future<void> Function() openSettings;
  @override
  State<ReaderScreen> createState() => ReaderScreenState();
}

class ReaderScreenState extends State<ReaderScreen> {
  BookDocument? document, sourceDocument;
  final scriptService = ChineseScriptService();
  TextOffsetMap offsets = const TextOffsetMap();
  String requestedScript = '';
  int conversionGeneration = 0;
  int _sourceOffset(int display) => offsets.toSource(display);
  void _recordProgress(int display) {
    final source = sourceDocument;
    final offset = _sourceOffset(display);
    final quote = source == null
        ? ''
        : source.text.substring(
            offset.clamp(0, source.text.length),
            min(source.text.length, offset + 48),
          );
    model.updateProgress(
      book.id,
      offset,
      quote: quote,
      parseVersion: source?.parseVersion ?? 2,
    );
  }

  String? error, layoutKey;
  List<ReadingPage> pages = [];
  int pageIndex = 0, anchor = 0, generation = 0;
  bool loading = true, arranging = false, controls = false;
  PageFlipSession? _preview;
  double _pageWidth = 0, _pageHeight = 0;
  TextStyle _pageStyle = const TextStyle();
  TextScaler _pageScaler = TextScaler.noScaling;
  BookPageIndex? bookPageIndex;
  String? indexKey;
  int indexGeneration = 0;
  Timer? indexDebounce;
  bool indexFailed = false;
  final pager = GlobalKey<ReaderPagerState>();
  final brightnessGesture = GlobalKey<ReadingBrightnessGestureState>();
  bool navigationBusy = false;
  Future<void> requestTurn(bool forward) async {
    if (_preview != null) {
      _preview?.step(forward);
      return;
    }
    if (pager.currentState != null) {
      await pager.currentState?.turn(forward);
    }
  }

  AppModel get model => widget.model;
  ReadingPage? get current =>
      pages.isEmpty ? null : pages[pageIndex.clamp(0, pages.length - 1)];
  BookRecord get book => model.findBook(widget.book.id) ?? widget.book;
  @override
  void initState() {
    super.initState();
    anchor = widget.book.offset;
    model.addListener(_settingsChanged);
    unawaited(_load());
  }

  void _settingsChanged() {
    if (model.locked && _preview != null) {
      _closePreview();
    }
    if (sourceDocument != null &&
        requestedScript != model.settings.scriptMode) {
      unawaited(_applyScript());
    }
  }

  Future<void> _load() async {
    try {
      final content = await model.openBook(widget.book);
      if (!mounted) {
        return;
      }
      sourceDocument = content;
      await _applyScript(sourceOffset: book.offset);
    } catch (_) {
      if (mounted) {
        setState(() {
          error = '无法读取正文，请返回书架重新导入此书';
          loading = false;
        });
      }
    }
  }

  /// 显示文本始终由原文派生，进度和书签仍保存为原文坐标。
  Future<void> _applyScript({int? sourceOffset}) async {
    final source = sourceDocument;
    if (source == null || !mounted) {
      return;
    }
    final location = sourceOffset ?? _sourceOffset(current?.start ?? anchor);
    requestedScript = model.settings.scriptMode;
    final ticket = ++conversionGeneration;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final rendered = await scriptService.convert(source, requestedScript);
      if (!mounted || ticket != conversionGeneration) {
        return;
      }
      generation++;
      indexGeneration++;
      indexDebounce?.cancel();
      setState(() {
        _disposePreview();
        document = rendered.document;
        offsets = rendered.offsets;
        anchor = offsets
            .toDisplay(location)
            .clamp(0, rendered.document.text.length - 1);
        pages = [];
        pageIndex = 0;
        loading = false;
        arranging = false;
        layoutKey = null;
        indexKey = null;
        bookPageIndex = null;
      });
      _recordProgress(anchor);
    } on ScriptConversionCancelled {
      /* 后续转换或页面销毁已接管。 */
    } catch (_) {
      if (mounted && ticket == conversionGeneration) {
        setState(() {
          loading = false;
          error = '正文转换失败，请切回原文后重试';
        });
      }
    }
  }

  @override
  void dispose() {
    _disposePreview();
    model.removeListener(_settingsChanged);
    conversionGeneration++;
    scriptService.cancel();
    generation++;
    indexGeneration++;
    indexDebounce?.cancel();
    super.dispose();
  }

  void _previewChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 预览退出时释放缓存并取消排版。临时预览从不修改 anchor 或持久化进度。
  void _disposePreview() {
    final preview = _preview;
    _preview = null;
    preview?.removeListener(_previewChanged);
    preview?.dispose();
  }

  void _closePreview() {
    if (mounted && _preview != null) {
      setState(_disposePreview);
    }
  }

  void _startPreview() {
    final doc = document;
    final key = layoutKey;
    if (_preview != null ||
        doc == null ||
        key == null ||
        current == null ||
        arranging ||
        model.locked ||
        _pageWidth <= 0 ||
        _pageHeight <= 0) {
      return;
    }
    final preview = PageFlipSession(
      document: doc,
      originOffset: current!.start,
      width: _pageWidth,
      height: _pageHeight,
      style: _pageStyle,
      scaler: _pageScaler,
      paragraphSpacing: model.settings.paragraphSpacing,
      readingLayout: model.settings.readingLayout,
      verticalDirection: model.settings.verticalDirection,
      layoutKey: key,
      index: bookPageIndex,
      initialPages: pages,
    );
    preview.addListener(_previewChanged);
    setState(() => _preview = preview);
  }

  void _seekPreview(double value) {
    _startPreview();
    _preview?.seekFraction(value);
  }

  /// 只有明确点击预览正文或“阅读此页”才提交跳转，原文坐标映射由 _jump 统一处理。
  void _confirmPreview() {
    final preview = _preview;
    final page = preview?.page;
    if (preview?.ready != true || page == null || model.locked) {
      return;
    }
    _closePreview();
    unawaited(_jump(page.start));
  }

  double _sliderFraction() {
    if (_preview != null) {
      return _preview!.fraction;
    }
    final index = bookPageIndex;
    final offset = current?.start ?? anchor;
    return index != null && index.totalPages > 1
        ? (index.pageNumberAt(offset) - 1) / (index.totalPages - 1)
        : (offset / max(1, (document?.text.length ?? 1) - 1)).clamp(0.0, 1.0);
  }

  /// 尺寸与排版参数组成布局标识。只接受最后一次任务，避免拖动窗口时旧结果覆盖新结果。
  void _ensureLayout(
    double width,
    double height,
    TextStyle style,
    TextScaler scaler,
  ) {
    final doc = document;
    if (doc == null) {
      return;
    }
    final chapterIndex = doc.chapterAt(anchor);
    final s = model.settings;
    final metricsKey =
        '$width/$height/${s.fontSize}/${s.lineHeight}/${s.letterSpacing}/'
        '${s.readingLayout}/${s.verticalDirection}/${s.paragraphSpacing}/${s.fontId}/${model.loadedFontId}/${s.fontWeight}/$requestedScript/${scaler.scale(s.fontSize)}';
    _ensureBookIndex(metricsKey, width, height, style, scaler);
    final key = '$metricsKey/$chapterIndex';
    _pageWidth = width;
    _pageHeight = height;
    _pageStyle = style;
    _pageScaler = scaler;
    final preview = _preview;
    if (preview != null && preview.layoutKey != key) {
      // 旋转、窗口缩放、字体或简繁变化后关闭旧预览，避免提交过期分页。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_preview, preview)) {
          _closePreview();
        }
      });
    }
    if (key == layoutKey) {
      return;
    }
    layoutKey = key;
    final ticket = ++generation;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || ticket != generation) {
        return;
      }
      setState(() => arranging = true);
      try {
        final computed = await Pagination.layout(
          document: doc,
          chapter: doc.chapters[chapterIndex],
          width: width,
          height: height,
          style: style,
          paragraphSpacing: s.paragraphSpacing,
          readingLayout: s.readingLayout,
          verticalDirection: s.verticalDirection,
          scaler: scaler,
          cancelled: () => !mounted || ticket != generation,
        );
        if (!mounted || ticket != generation) {
          return;
        }
        var index = computed.lastIndexWhere((p) => p.start <= anchor);
        if (index < 0) {
          index = 0;
        }
        setState(() {
          pages = computed;
          pageIndex = index;
          arranging = false;
        });
      } catch (_) {
        if (mounted && ticket == generation) {
          setState(() {
            arranging = false;
            error = '排版失败，请调整字体或重新打开';
          });
        }
      }
    });
  }

  /// 全书计数与当前章节翻页独立；连续缩放时只计算最后一次稳定的布局。
  void _ensureBookIndex(
    String key,
    double width,
    double height,
    TextStyle style,
    TextScaler scaler,
  ) {
    if (indexKey == key) {
      return;
    }
    indexKey = key;
    final ticket = ++indexGeneration;
    indexDebounce?.cancel();
    bookPageIndex = null;
    indexFailed = false;
    final doc = document;
    if (doc == null) {
      return;
    }
    final preferences = model.settings;
    final spacing = preferences.paragraphSpacing;
    indexDebounce = Timer(const Duration(milliseconds: 180), () async {
      try {
        final index = await BookPageIndex.build(
          document: doc,
          width: width,
          height: height,
          style: style,
          paragraphSpacing: spacing,
          readingLayout: preferences.readingLayout,
          verticalDirection: preferences.verticalDirection,
          scaler: scaler,
          cancelled: () => !mounted || ticket != indexGeneration,
        );
        if (mounted && ticket == indexGeneration && index != null) {
          setState(() => bookPageIndex = index);
          _preview?.updateIndex(index);
        }
      } catch (_) {
        if (mounted && ticket == indexGeneration) {
          setState(() => indexFailed = true);
        }
      }
    });
  }

  /// 快捷键和原生菜单均只作用于当前位于最上层的阅读页。
  void adjustFontSize(int delta) {
    if (model.locked || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final s = model.settings;
    final next = (s.fontSize + delta).clamp(12.0, 48.0);
    if (next != s.fontSize) {
      model.updateSettings(s.copyWith(fontSize: next));
    }
  }

  Future<void> escapeReading() async {
    if (model.locked || ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    if (_preview != null) {
      _closePreview();
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      await model.platform.minimize();
    } else if (mounted) {
      setState(() => controls = !controls);
    }
  }

  String _progressLabel() {
    final percent =
        ((current?.end == document?.text.length
                    ? 1.0
                    : anchor / max(1, document?.text.length ?? 1)) *
                100)
            .toStringAsFixed(1);
    final index = bookPageIndex;
    final position = index == null
        ? (indexFailed ? '页码暂不可用' : '页码计算中')
        : '${index.pageNumberAt(current?.start ?? anchor)}/${index.totalPages}';
    return '$percent%   ·   $position';
  }

  Future<bool> _turn(bool forward) async {
    final doc = document;
    final page = current;
    if (doc == null ||
        page == null ||
        arranging ||
        model.locked ||
        navigationBusy ||
        brightnessGesture.currentState?.blocksPageTurn == true) {
      return false;
    }
    navigationBusy = true;
    try {
      if (forward && pageIndex + 1 < pages.length) {
        setState(() {
          pageIndex++;
          anchor = pages[pageIndex].start;
          controls = false;
        });
      } else if (!forward && pageIndex > 0) {
        setState(() {
          pageIndex--;
          anchor = pages[pageIndex].start;
          controls = false;
        });
      } else {
        final index = doc.chapterAt(page.start);
        if (forward && index + 1 < doc.chapters.length) {
          await _jump(doc.chapters[index + 1].start);
        } else if (!forward && index > 0) {
          await _jump(doc.chapters[index - 1].end - 1);
        } else {
          return false;
        }
      }
      _recordProgress(anchor);
      if (current == null || current?.start == page.start) {
        return false;
      }
      model.recordPageTurn();
      return true;
    } finally {
      navigationBusy = false;
    }
  }

  Future<void> _jump(int offset) async {
    final doc = document;
    if (doc == null || model.locked) {
      return;
    }
    final target = offset.clamp(0, doc.text.length - 1);
    if (pages.isNotEmpty &&
        target >= pages.first.start &&
        target < pages.last.end) {
      setState(() {
        anchor = target;
        pageIndex = max(0, pages.lastIndexWhere((p) => p.start <= target));
        controls = false;
      });
    } else {
      setState(() {
        anchor = target;
        layoutKey = null;
        controls = false;
      });
      // 等待有界章节排版完成；菜单、搜索定位也会经过相同路径。
      for (var i = 0; i < 200 && mounted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        if (!arranging &&
            current != null &&
            target >= pages.first.start &&
            target < pages.last.end) {
          break;
        }
      }
    }
    _recordProgress(target);
  }

  Future<void> toggleBookmark() async {
    final doc = document;
    final page = current;
    if (doc == null || page == null || model.locked) {
      return;
    }
    try {
      await model.toggleBookmark(
        book.id,
        _sourceOffset(page.start),
        (sourceDocument ?? doc).text
            .substring(
              _sourceOffset(page.start),
              min(
                (sourceDocument ?? doc).text.length,
                _sourceOffset(page.start) + 80,
              ),
            )
            .trim(),
      );
      if (mounted) {
        setState(() {});
      }
    } catch (_) {
      /* 模型负责显示保存错误。 */
    }
  }

  Future<void> showSearch() async {
    final doc = document;
    if (doc == null || model.locked) {
      return;
    }
    final offset = await showDialog<int>(
      context: context,
      builder: (_) => _SearchDialog(model: model, document: doc),
    );
    if (offset != null && mounted) {
      await _jump(offset);
    }
  }

  Future<void> _contents({bool bookmarks = false}) async {
    final doc = document;
    if (doc == null || model.locked) {
      return;
    }
    final openingOffsets = offsets;
    final int? selected;
    if (!bookmarks) {
      selected = await showDialog<int>(
        context: context,
        builder: (_) => ChapterContentsDialog(
          document: doc,
          offset: current?.start ?? anchor,
        ),
      );
    } else {
      selected = await showDialog<int>(
        context: context,
        builder: (context) => Dialog(
          child: SizedBox(
            width: 620,
            height: min(620, MediaQuery.sizeOf(context).height * .8),
            child: Column(
              children: [
                ListTile(
                  title: const Text('书签'),
                  trailing: IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const ReaderIcon(ReaderGlyph.close),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListenableBuilder(
                    listenable: model,
                    builder: (context, _) {
                      final marks = book.bookmarks;
                      if (marks.isEmpty) {
                        return const Center(child: Text('还没有书签'));
                      }
                      return ListView.builder(
                        itemCount: marks.length,
                        itemBuilder: (context, index) {
                          final mark = marks[index],
                              display = openingOffsets.toDisplay(mark.offset);
                          return ListTile(
                            title: Text(
                              mark.quote,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${(display / doc.text.length * 100).toStringAsFixed(1)}%',
                            ),
                            onTap: () => Navigator.pop(context, display),
                            trailing: IconButton(
                              tooltip: '删除书签',
                              icon: const ReaderIcon(
                                ReaderGlyph.removeBookmark,
                              ),
                              onPressed: () async {
                                try {
                                  await model.toggleBookmark(
                                    book.id,
                                    mark.offset,
                                    '',
                                  );
                                } catch (_) {}
                              },
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (selected != null && mounted) {
      await _jump(offsets.toDisplay(openingOffsets.toSource(selected)));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final s = model.settings;
      final resolved = ReadingStyle.resolve(
        model,
        Theme.of(context).brightness,
      );
      final background = resolved.background, foreground = resolved.foreground;
      final style = resolved.text;
      return PopScope(
        canPop: !model.locked && _preview == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _preview != null) {
            _closePreview();
          }
        },
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                unawaited(requestTurn(true)),
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                unawaited(requestTurn(true)),
            const SingleActivator(LogicalKeyboardKey.space): () =>
                unawaited(requestTurn(true)),
            const SingleActivator(LogicalKeyboardKey.pageDown): () =>
                unawaited(requestTurn(true)),
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                unawaited(requestTurn(false)),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                unawaited(requestTurn(false)),
            const SingleActivator(LogicalKeyboardKey.pageUp): () =>
                unawaited(requestTurn(false)),
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                unawaited(escapeReading()),
            const SingleActivator(LogicalKeyboardKey.equal, meta: true): () =>
                adjustFontSize(1),
            const SingleActivator(
              LogicalKeyboardKey.equal,
              meta: true,
              shift: true,
            ): () =>
                adjustFontSize(1),
            const SingleActivator(
              LogicalKeyboardKey.numpadAdd,
              meta: true,
            ): () =>
                adjustFontSize(1),
            const SingleActivator(LogicalKeyboardKey.minus, meta: true): () =>
                adjustFontSize(-1),
            const SingleActivator(
              LogicalKeyboardKey.numpadSubtract,
              meta: true,
            ): () =>
                adjustFontSize(-1),
            const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
                unawaited(showSearch()),
            const SingleActivator(LogicalKeyboardKey.keyD, control: true): () =>
                unawaited(toggleBookmark()),
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: ReadingBrightnessGesture(
                key: brightnessGesture,
                value: s.readingBrightness,
                enabled: !model.locked && _preview == null,
                onChanged: (v) => model.updateSettings(
                  model.settings.copyWith(readingBrightness: v),
                ),
                builder: (context, brightness, showHint) => Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned.fill(
                      child: ReadingDimmer(
                        value: brightness,
                        child: ColoredBox(
                          color: model.currentPhoto != null
                              ? Colors.transparent
                              : background.withValues(
                                  alpha: s.backgroundOpacity,
                                ),
                          child: ReadingBackdrop(
                            model: model,
                            background: background,
                            child: SafeArea(
                              child: Stack(
                                children: [
                                  if (loading)
                                    const Center(
                                      child: CircularProgressIndicator(),
                                    )
                                  else if (error != null)
                                    Center(
                                      child: Padding(
                                        padding: const EdgeInsets.all(24),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(error!),
                                            const SizedBox(height: 24),
                                            FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(context),
                                              child: const Text('返回书架'),
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                  else
                                    LayoutBuilder(
                                      builder: (context, constraints) {
                                        // 以安全区域为边界，四边使用相同的留白；页码放在底部留白内。
                                        final margin = min(
                                          constraints.maxWidth > 700
                                              ? 46.0
                                              : 24.0,
                                          max(
                                            0.0,
                                            (min(
                                                      constraints.maxWidth,
                                                      constraints.maxHeight,
                                                    ) -
                                                    1) /
                                                2,
                                          ),
                                        );
                                        final width = max(
                                          1.0,
                                          constraints.maxWidth - margin * 2,
                                        );
                                        final height = max(
                                          1.0,
                                          constraints.maxHeight - margin * 2,
                                        );
                                        final scaler = MediaQuery.textScalerOf(
                                          context,
                                        );
                                        _ensureLayout(
                                          width,
                                          height,
                                          style,
                                          scaler,
                                        );
                                        final page = current;
                                        return Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            Positioned(
                                              left: margin,
                                              right: margin,
                                              top: margin,
                                              bottom: margin,
                                              child: page == null
                                                  ? Center(
                                                      child: SizedBox(
                                                        width: 18,
                                                        height: 18,
                                                        child:
                                                            CircularProgressIndicator(
                                                              strokeWidth: 1.5,
                                                              color: foreground,
                                                            ),
                                                      ),
                                                    )
                                                  : ReaderPager(
                                                      key: pager,
                                                      effect: s.pageEffect,
                                                      particleDirectional:
                                                          s.particleDirectional,
                                                      background: background
                                                          .withValues(
                                                            alpha: s
                                                                .backgroundOpacity,
                                                          ),
                                                      onTurn: _turn,
                                                      onToggle: () {
                                                        if (brightnessGesture
                                                                .currentState
                                                                ?.blocksPageTurn !=
                                                            true) {
                                                          setState(
                                                            () => controls =
                                                                !controls,
                                                          );
                                                        }
                                                      },
                                                      child: ReaderPage(
                                                        key: ValueKey(
                                                          '${page.start}/$layoutKey',
                                                        ),
                                                        page: page,
                                                        width: width,
                                                        style: style,
                                                        scaler: scaler,
                                                      ),
                                                    ),
                                            ),
                                            Positioned(
                                              left: margin,
                                              right: margin,
                                              bottom: 0,
                                              height: margin,
                                              child: Center(
                                                child: Text(
                                                  _progressLabel(),
                                                  key: const ValueKey(
                                                    'reading-progress',
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: foreground
                                                        .withValues(alpha: .65),
                                                    letterSpacing: .5,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: SafeArea(
                        child: Stack(
                          children: [
                            if (_preview != null) ...[
                              Positioned.fill(
                                child: GestureDetector(
                                  onTap: _closePreview,
                                  child: const ColoredBox(
                                    color: Color(0xaa000000),
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 24,
                                right: 24,
                                top: 8,
                                bottom: 186,
                                child: ReadingDimmer(
                                  value: brightness,
                                  child: PageFlipPreview(
                                    session: _preview!,
                                    background: background,
                                    onClose: _closePreview,
                                    onConfirm: _confirmPreview,
                                  ),
                                ),
                              ),
                            ],
                            if (controls && !loading && error == null) ...[
                              if (_preview == null)
                                Positioned(
                                  left: 12,
                                  right: 12,
                                  top: 8,
                                  child: Material(
                                    elevation: 3,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surface,
                                    borderRadius: BorderRadius.circular(16),
                                    child: Row(
                                      children: [
                                        IconButton(
                                          tooltip: '返回书架',
                                          onPressed: () =>
                                              Navigator.pop(context),
                                          icon: const ReaderIcon(
                                            ReaderGlyph.back,
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            book.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: '搜索正文',
                                          onPressed: showSearch,
                                          icon: const ReaderIcon(
                                            ReaderGlyph.search,
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: '添加 / 移除书签',
                                          onPressed: toggleBookmark,
                                          icon: ReaderIcon(
                                            book.bookmarks.any(
                                                  (m) =>
                                                      m.offset ==
                                                      _sourceOffset(
                                                        current?.start ??
                                                            anchor,
                                                      ),
                                                )
                                                ? ReaderGlyph.bookmark
                                                : ReaderGlyph.bookmarkOutline,
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: '设置',
                                          onPressed: widget.openSettings,
                                          icon: const ReaderIcon(
                                            ReaderGlyph.settings,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              Positioned(
                                key: const ValueKey('reading-bottom-controls'),
                                left: 12,
                                right: 12,
                                bottom: 12,
                                child: Material(
                                  elevation: 3,
                                  color: Theme.of(context).colorScheme.surface,
                                  borderRadius: BorderRadius.circular(16),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_preview != null)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 12,
                                            ),
                                            child: Text(
                                              _preview!.locationLabel,
                                              key: const ValueKey(
                                                'preview-location',
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.labelMedium,
                                            ),
                                          ),
                                        Slider(
                                          key: const ValueKey(
                                            'reading-seek-slider',
                                          ),
                                          value: _sliderFraction(),
                                          onChangeStart: (_) => _startPreview(),
                                          onChanged: arranging || model.locked
                                              ? null
                                              : _seekPreview,
                                          onChangeEnd: (_) => _preview?.flush(),
                                        ),
                                        if (_preview == null) ...[
                                          ReadingQuickSlider(
                                            title: '字号',
                                            value: s.fontSize,
                                            min: 12,
                                            max: 48,
                                            label: '${s.fontSize.round()}',
                                            divisions: 36,
                                            sliderKey: const ValueKey(
                                              'reading-font-size-slider',
                                            ),
                                            onChanged: model.locked
                                                ? null
                                                : (v) => model.updateSettings(
                                                    model.settings.copyWith(
                                                      fontSize: v
                                                          .roundToDouble(),
                                                    ),
                                                  ),
                                          ),
                                          ReadingQuickSlider(
                                            title: '亮度',
                                            value: brightness,
                                            min: .1,
                                            max: 1,
                                            label:
                                                '${(brightness * 100).round()}%',
                                            sliderKey: const ValueKey(
                                              'reading-brightness-slider',
                                            ),
                                            onChanged: model.locked
                                                ? null
                                                : (v) => model.updateSettings(
                                                    model.settings.copyWith(
                                                      readingBrightness: v,
                                                    ),
                                                  ),
                                          ),
                                        ],
                                        if (_preview != null)
                                          Row(
                                            children: [
                                              IconButton(
                                                key: const ValueKey(
                                                  'preview-previous',
                                                ),
                                                tooltip: '预览上一页',
                                                onPressed: _preview!.canPrevious
                                                    ? () =>
                                                          _preview?.step(false)
                                                    : null,
                                                icon: const ReaderIcon(
                                                  ReaderGlyph.back,
                                                ),
                                              ),
                                              IconButton(
                                                key: const ValueKey(
                                                  'preview-next',
                                                ),
                                                tooltip: '预览下一页',
                                                onPressed: _preview!.canNext
                                                    ? () => _preview?.step(true)
                                                    : null,
                                                icon: const ReaderIcon(
                                                  ReaderGlyph.chevronRight,
                                                ),
                                              ),
                                              Expanded(
                                                child: FilledButton(
                                                  key: const ValueKey(
                                                    'confirm-page-preview',
                                                  ),
                                                  onPressed: _preview!.ready
                                                      ? _confirmPreview
                                                      : null,
                                                  child: const Text('阅读此页'),
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: '预览回到原阅读页',
                                                onPressed: () =>
                                                    _preview?.returnToOrigin(),
                                                icon: const ReaderIcon(
                                                  ReaderGlyph.restore,
                                                ),
                                              ),
                                            ],
                                          )
                                        else
                                          Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceEvenly,
                                            children: [
                                              TextButton.icon(
                                                onPressed: () => _contents(),
                                                icon: const ReaderIcon(
                                                  ReaderGlyph.list,
                                                  size: 18,
                                                ),
                                                label: const Text('目录'),
                                              ),
                                              TextButton.icon(
                                                onPressed: () =>
                                                    _contents(bookmarks: true),
                                                icon: const ReaderIcon(
                                                  ReaderGlyph.bookmarks,
                                                  size: 18,
                                                ),
                                                label: const Text('书签'),
                                              ),
                                              IconButton(
                                                tooltip: '收起工具',
                                                onPressed: () => setState(
                                                  () => controls = false,
                                                ),
                                                icon: const ReaderIcon(
                                                  ReaderGlyph.down,
                                                ),
                                              ),
                                            ],
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            if (showHint)
                              Positioned(
                                top: 72,
                                left: 0,
                                right: 0,
                                child: IgnorePointer(
                                  child: Center(
                                    child: Material(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainerHigh,
                                      borderRadius: BorderRadius.circular(20),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 18,
                                          vertical: 10,
                                        ),
                                        child: Text(
                                          '阅读亮度 ${(brightness * 100).round()}%',
                                          key: const ValueKey(
                                            'reading-brightness-hint',
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.model, required this.document});
  final AppModel model;
  final BookDocument document;
  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final field = TextEditingController();
  Timer? debounce;
  int generation = 0;
  List<SearchHit> hits = [];
  bool searching = false;
  void query(String value) {
    debounce?.cancel();
    final ticket = ++generation;
    if (value.trim().isEmpty) {
      setState(() {
        hits = [];
        searching = false;
      });
      return;
    }
    setState(() => searching = true);
    debounce = Timer(const Duration(milliseconds: 300), () async {
      final result = await widget.model.search(widget.document, value);
      if (mounted && ticket == generation) {
        setState(() {
          hits = result;
          searching = false;
        });
      }
    });
  }

  @override
  void dispose() {
    generation++;
    debounce?.cancel();
    field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 640,
      height: min(650, MediaQuery.sizeOf(context).height * .85),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    autofocus: true,
                    controller: field,
                    onChanged: query,
                    decoration: const InputDecoration(
                      hintText: '搜索全文',
                      prefixIcon: ReaderIcon(ReaderGlyph.search),
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const ReaderIcon(ReaderGlyph.close),
                ),
              ],
            ),
          ),
          if (searching) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                field.text.trim().isEmpty
                    ? '输入文字开始搜索'
                    : '${hits.length}${hits.length == 300 ? '+' : ''} 处匹配',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: hits.length,
              itemBuilder: (context, index) {
                final hit = hits[index];
                return ListTile(
                  title: Text(
                    hit.excerpt,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${(hit.offset / widget.document.text.length * 100).toStringAsFixed(1)}%',
                  ),
                  onTap: () => Navigator.pop(context, hit.offset),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
