import 'dart:async';
import 'dart:math';
import 'package:flutter/gestures.dart';
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
  void _recordProgress(int display) =>
      model.updateProgress(book.id, _sourceOffset(display));
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
  final pager = GlobalKey<_CoverPagerState>();
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
        '${s.paragraphSpacing}/${s.fontId}/${model.loadedFontId}/${s.fontWeight}/$requestedScript/${scaler.scale(s.fontSize)}';
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
          paragraphSpacing: model.settings.paragraphSpacing,
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
    final spacing = model.settings.paragraphSpacing;
    indexDebounce = Timer(const Duration(milliseconds: 180), () async {
      try {
        final index = await BookPageIndex.build(
          document: doc,
          width: width,
          height: height,
          style: style,
          paragraphSpacing: spacing,
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
        navigationBusy) {
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
      final dark = Theme.of(context).brightness == Brightness.dark;
      final background = s.backgroundColor == null
          ? (dark ? const Color(0xff171c1b) : const Color(0xfff7f5ef))
          : Color(s.backgroundColor!);
      final foreground = s.textColor == null
          ? (dark ? const Color(0xff999999) : const Color(0xff303b35))
          : Color(s.textColor!);
      final style = TextStyle(
        fontFamily: s.fontId != null && s.fontId == model.loadedFontId
            ? 'user_${s.fontId}'
            : null,
        fontSize: s.fontSize,
        fontWeight:
            FontWeight.values[(s.fontWeight / 100).round().clamp(1, 9) - 1],
        height: s.lineHeight,
        letterSpacing: s.letterSpacing,
        color: foreground,
      );
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
              backgroundColor: background.withValues(
                alpha: s.backgroundOpacity,
              ),
              body: SafeArea(
                child: Stack(
                  children: [
                    if (loading)
                      const Center(child: CircularProgressIndicator())
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
                                onPressed: () => Navigator.pop(context),
                                child: const Text('返回书架'),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      Column(
                        children: [
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final padding = constraints.maxWidth > 700
                                    ? 46.0
                                    : 24.0;
                                final width = max(
                                  1.0,
                                  min(
                                    860.0,
                                    constraints.maxWidth - padding * 2,
                                  ),
                                );
                                final height = max(
                                  1.0,
                                  constraints.maxHeight - 32,
                                );
                                final scaler = MediaQuery.textScalerOf(context);
                                _ensureLayout(width, height, style, scaler);
                                final page = current;
                                return Center(
                                  child: SizedBox(
                                    width: width,
                                    height: height,
                                    child: page == null
                                        ? Center(
                                            child: SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 1.5,
                                                color: foreground,
                                              ),
                                            ),
                                          )
                                        : _CoverPager(
                                            key: pager,
                                            effect: s.pageEffect,
                                            onTurn: _turn,
                                            onToggle: () => setState(
                                              () => controls = !controls,
                                            ),
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
                                );
                              },
                            ),
                          ),
                          SizedBox(
                            height: 34,
                            child: Center(
                              child: Text(
                                _progressLabel(),
                                key: const ValueKey('reading-progress'),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: foreground.withValues(alpha: .65),
                                  letterSpacing: .5,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (_preview != null) ...[
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: _closePreview,
                          child: const ColoredBox(color: Color(0xaa000000)),
                        ),
                      ),
                      Positioned(
                        left: 24,
                        right: 24,
                        top: 8,
                        bottom: 186,
                        child: PageFlipPreview(
                          session: _preview!,
                          background: background,
                          onClose: _closePreview,
                          onConfirm: _confirmPreview,
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
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(16),
                            child: Row(
                              children: [
                                IconButton(
                                  tooltip: '返回书架',
                                  onPressed: () => Navigator.pop(context),
                                  icon: const ReaderIcon(ReaderGlyph.back),
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
                                  icon: const ReaderIcon(ReaderGlyph.search),
                                ),
                                IconButton(
                                  tooltip: '添加 / 移除书签',
                                  onPressed: toggleBookmark,
                                  icon: ReaderIcon(
                                    book.bookmarks.any(
                                          (m) =>
                                              m.offset ==
                                              _sourceOffset(
                                                current?.start ?? anchor,
                                              ),
                                        )
                                        ? ReaderGlyph.bookmark
                                        : ReaderGlyph.bookmarkOutline,
                                  ),
                                ),
                                IconButton(
                                  tooltip: '设置',
                                  onPressed: widget.openSettings,
                                  icon: const ReaderIcon(ReaderGlyph.settings),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Positioned(
                        key: const ValueKey('reading-bottom-controls'),
                        left: 12,
                        right: 12,
                        bottom: 40,
                        child: Material(
                          elevation: 3,
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(16),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_preview != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Text(
                                      _preview!.locationLabel,
                                      key: const ValueKey('preview-location'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.labelMedium,
                                    ),
                                  ),
                                Slider(
                                  key: const ValueKey('reading-seek-slider'),
                                  value: _sliderFraction(),
                                  onChangeStart: (_) => _startPreview(),
                                  onChanged: arranging || model.locked
                                      ? null
                                      : _seekPreview,
                                  onChangeEnd: (_) => _preview?.flush(),
                                ),
                                if (_preview != null)
                                  Row(
                                    children: [
                                      IconButton(
                                        key: const ValueKey('preview-previous'),
                                        tooltip: '预览上一页',
                                        onPressed: _preview!.canPrevious
                                            ? () => _preview?.step(false)
                                            : null,
                                        icon: const ReaderIcon(
                                          ReaderGlyph.back,
                                        ),
                                      ),
                                      IconButton(
                                        key: const ValueKey('preview-next'),
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
                                        onPressed: () =>
                                            setState(() => controls = false),
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

/// 横向覆盖：下一页从右侧覆盖当前页，返回时当前页向右移出。
class _CoverPager extends StatefulWidget {
  const _CoverPager({
    super.key,
    required this.child,
    required this.onTurn,
    required this.onToggle,
    required this.effect,
  });
  final Widget child;
  final Future<bool> Function(bool) onTurn;
  final VoidCallback onToggle;
  final String effect;
  @override
  State<_CoverPager> createState() => _CoverPagerState();
}

class _CoverPagerState extends State<_CoverPager>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 230),
  );
  Widget? old;
  bool forward = true, turning = false;
  double drag = 0;
  DateTime lastWheel = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> turn(bool next) async {
    if (turning) {
      return;
    }
    turning = true;
    final previous = widget.child;
    try {
      final moved = await widget.onTurn(next);
      if (!mounted ||
          !moved ||
          widget.effect == 'none' ||
          MediaQuery.disableAnimationsOf(context)) {
        return;
      }
      setState(() {
        old = previous;
        forward = next;
      });
      await animation.forward(from: 0).orCancel;
      if (mounted) {
        setState(() => old = null);
      }
    } on TickerCanceled {
      // 页面退出时终止动画，避免悬挂的 TickerFuture。
    } finally {
      turning = false;
    }
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent &&
            event.scrollDelta.distance > 5 &&
            DateTime.now().difference(lastWheel).inMilliseconds > 280) {
          lastWheel = DateTime.now();
          unawaited(
            turn(
              (event.scrollDelta.dy.abs() > event.scrollDelta.dx.abs()
                      ? event.scrollDelta.dy
                      : event.scrollDelta.dx) >
                  0,
            ),
          );
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          final fraction =
              details.localPosition.dx / max(1, constraints.maxWidth);
          if (fraction < .25) {
            unawaited(turn(false));
          } else if (fraction > .75) {
            unawaited(turn(true));
          } else {
            widget.onToggle();
          }
        },
        onHorizontalDragStart: (_) => drag = 0,
        onHorizontalDragUpdate: (details) => drag += details.delta.dx,
        onHorizontalDragEnd: (details) {
          if (drag.abs() > 35 || (details.primaryVelocity ?? 0).abs() > 200) {
            unawaited(
              turn(
                drag.abs() > 35 ? drag < 0 : (details.primaryVelocity ?? 0) < 0,
              ),
            );
          }
        },
        child: ClipRect(
          child: AnimatedBuilder(
            animation: animation,
            builder: (context, _) {
              final previous = old;
              if (previous == null) {
                return widget.child;
              }
              final progress = Curves.easeOutCubic.transform(animation.value);
              return Stack(
                fit: StackFit.expand,
                children: [
                  ClipRect(
                    clipper: _PageReveal(forward ? 1 - progress : progress),
                    child: forward ? previous : widget.child,
                  ),
                  Transform.translate(
                    offset: Offset(
                      constraints.maxWidth *
                          (forward ? 1 - progress : progress),
                      0,
                    ),
                    child: forward ? widget.child : previous,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

/// 对底页做裁切，透明模式下两页文字也不会重叠。
class _PageReveal extends CustomClipper<Rect> {
  const _PageReveal(this.fraction);
  final double fraction;
  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * fraction, size.height);
  @override
  bool shouldReclip(covariant _PageReveal old) => old.fraction != fraction;
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
