import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../domain/models.dart';
import '../domain/pagination.dart';
import 'app_model.dart';
import 'core/reader_icon.dart';

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
  BookDocument? document;
  String? error, layoutKey;
  List<ReadingPage> pages = [];
  int pageIndex = 0, anchor = 0, generation = 0;
  bool loading = true, arranging = false, controls = false;
  double? seeking;
  final pager = GlobalKey<_CoverPagerState>();
  bool navigationBusy = false;
  Future<void> requestTurn(bool forward) async {
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
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final content = await model.repository.open(widget.book);
      if (!mounted) {
        return;
      }
      setState(() {
        document = content;
        anchor = anchor.clamp(0, content.text.length - 1);
        loading = false;
      });
      model.updateProgress(book.id, anchor);
    } catch (_) {
      if (mounted) {
        setState(() {
          error = '无法读取正文，请返回书架重新导入此书';
          loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    generation++;
    super.dispose();
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
    final key =
        '$width/$height/$chapterIndex/${jsonEncode(model.settings.toJson())}/${model.loadedFontId}/${scaler.scale(20)}';
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
      model.updateProgress(book.id, anchor);
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
    model.updateProgress(book.id, target);
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
        page.start,
        doc.text.substring(page.start, min(page.end, page.start + 80)).trim(),
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
    final offset = await showDialog<int>(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(
          width: 620,
          height: min(620, MediaQuery.sizeOf(context).height * .8),
          child: Column(
            children: [
              ListTile(
                title: Text(bookmarks ? '书签' : '目录'),
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
                    if (bookmarks && marks.isEmpty) {
                      return const Center(
                        child: Text(
                          '还没有书签\n可用 ⌘D 或阅读工具栏添加',
                          textAlign: TextAlign.center,
                        ),
                      );
                    }
                    return ListView.builder(
                      itemCount: bookmarks ? marks.length : doc.chapters.length,
                      itemBuilder: (context, index) {
                        final offset = bookmarks
                            ? marks[index].offset
                            : doc.chapters[index].start;
                        return ListTile(
                          title: Text(
                            bookmarks
                                ? marks[index].quote
                                : doc.chapters[index].title,
                            maxLines: bookmarks ? 3 : 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${(offset / doc.text.length * 100).toStringAsFixed(1)}%',
                          ),
                          selected:
                              !bookmarks && index == doc.chapterAt(anchor),
                          onTap: () => Navigator.pop(context, offset),
                          trailing: bookmarks
                              ? IconButton(
                                  tooltip: '删除书签',
                                  icon: const ReaderIcon(
                                    ReaderGlyph.removeBookmark,
                                  ),
                                  onPressed: () async {
                                    try {
                                      await model.toggleBookmark(
                                        book.id,
                                        offset,
                                        '',
                                      );
                                    } catch (_) {}
                                  },
                                )
                              : null,
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
    if (offset != null && mounted) {
      await _jump(offset);
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
          ? (dark ? const Color(0xffd4d9d5) : const Color(0xff303b35))
          : Color(s.textColor!);
      final style = TextStyle(
        fontFamily: s.fontId != null && s.fontId == model.loadedFontId
            ? 'user_${s.fontId}'
            : null,
        fontSize: s.fontSize,
        height: s.lineHeight,
        letterSpacing: s.letterSpacing,
        color: foreground,
      );
      return PopScope(
        canPop: !model.locked,
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
                setState(() => controls = !controls),
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
                                            child: _PageCanvas(
                                              key: ValueKey(
                                                '${page.start}/$layoutKey',
                                              ),
                                              page: page,
                                              width: width,
                                              style: style,
                                              scaler: scaler,
                                              background: background.withValues(
                                                alpha: s.backgroundOpacity,
                                              ),
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
                                '${((current?.end == document?.text.length ? 1.0 : anchor / max(1, document?.text.length ?? 1)) * 100).toStringAsFixed(1)}%'
                                '${pages.isEmpty ? '' : '   ·   ${pageIndex + 1}/${pages.length}'}',
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
                    if (controls && !loading && error == null) ...[
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
                                        (m) => m.offset == current?.start,
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
                                Slider(
                                  value:
                                      seeking ??
                                      (anchor /
                                              max(
                                                1,
                                                document?.text.length ?? 1,
                                              ))
                                          .clamp(0.0, 1.0),
                                  onChanged: (value) =>
                                      setState(() => seeking = value),
                                  onChangeEnd: (value) {
                                    setState(() => seeking = null);
                                    unawaited(
                                      _jump(
                                        (value *
                                                max(
                                                  1,
                                                  (document?.text.length ?? 1) -
                                                      1,
                                                ))
                                            .round(),
                                      ),
                                    );
                                  },
                                ),
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
                                      icon: const ReaderIcon(ReaderGlyph.down),
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

/// 页面自身绘制精确分页的段落，释放每次绘制创建的原生 TextPainter。
class _PageCanvas extends StatelessWidget {
  const _PageCanvas({
    super.key,
    required this.page,
    required this.width,
    required this.style,
    required this.scaler,
    required this.background,
  });
  final ReadingPage page;
  final double width;
  final TextStyle style;
  final TextScaler scaler;
  final Color background;
  @override
  Widget build(BuildContext context) => Semantics(
    label: page.fragments.map((f) => f.text).join('\n'),
    child: ClipRect(
      child: CustomPaint(
        painter: _TextPagePainter(page, width, style, scaler, background),
        size: Size.infinite,
      ),
    ),
  );
}

class _TextPagePainter extends CustomPainter {
  _TextPagePainter(
    this.page,
    this.width,
    this.style,
    this.scaler,
    this.background,
  );
  final ReadingPage page;
  final double width;
  final TextStyle style;
  final TextScaler scaler;
  final Color background;
  @override
  void paint(Canvas canvas, Size size) {
    // 透明背景不在单页上重复叠加，交由整个阅读窗口统一绘制。
    for (final fragment in page.fragments) {
      final painter = TextPainter(
        text: TextSpan(text: fragment.text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: width);
      painter.paint(canvas, Offset(0, fragment.y));
      painter.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _TextPagePainter old) =>
      old.page != page ||
      old.width != width ||
      old.style != style ||
      old.scaler != scaler;
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
