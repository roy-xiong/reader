import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import '../domain/models.dart';
import '../domain/pagination.dart';

/// 临时翻页预览会话。只持有预览位置，不读写书架进度或书签。
///
/// 使用正文相同的排版尺寸；最多缓存三个章节的分页，不保留原生排版对象。
/// 快速拖动合并为最后一次请求，关闭时取消定时器及尚未完成的任务。
class PageFlipSession extends ChangeNotifier {
  PageFlipSession({
    required this.document,
    required this.originOffset,
    required this.width,
    required this.height,
    required this.style,
    required this.scaler,
    required this.paragraphSpacing,
    required this.layoutKey,
    this.index,
    List<ReadingPage> initialPages = const [],
  }) {
    _target = originOffset.clamp(0, document.text.length - 1);
    if (initialPages.isNotEmpty) {
      _cache[document.chapterAt(initialPages.first.start)] = initialPages;
      _page = initialPages.lastWhere((page) => page.start <= _target);
    }
    _fraction = fractionAt(_target);
  }

  final BookDocument document;
  final int originOffset;
  final double width, height, paragraphSpacing;
  final TextStyle style;
  final TextScaler scaler;
  final String layoutKey;
  final _cache = <int, List<ReadingPage>>{};
  BookPageIndex? index;
  ReadingPage? _page;
  Timer? _debounce;
  int _target = 0, _generation = 0;
  double _fraction = 0;
  bool _disposed = false, _loading = false;
  String? _error;

  ReadingPage? get page => _page;
  bool get loading => _loading;
  String? get error => _error;
  double get fraction => _fraction;
  bool get ready => !_loading && _error == null && _page != null;
  bool get canPrevious => ready && _page!.start > 0;
  bool get canNext => ready && _page!.end < document.text.length;
  String get chapterTitle {
    var chapter = document.chapterAt(_target);
    // 长章节的续排块仍展示实际章节名。
    while (chapter > 0 && document.chapters[chapter].isContinuation) {
      chapter--;
    }
    return document.chapters[chapter].title;
  }

  String get locationLabel {
    final offset = ready ? _page!.start : _target;
    final percent = ready && _page!.end == document.text.length
        ? 100.0
        : offset / max(1, document.text.length - 1) * 100;
    final index = this.index;
    final position = index == null
        ? '页码计算中'
        : '${index.pageNumberAt(offset)} / ${index.totalPages} 页';
    return '$position · ${percent.toStringAsFixed(1)}%';
  }

  /// 索引可晚于预览就绪。切换为按实际页码定位，不重新排版整本书。
  void updateIndex(BookPageIndex index) {
    if (_disposed || identical(index, this.index)) {
      return;
    }
    this.index = index;
    _fraction = fractionAt(_target);
    notifyListeners();
  }

  double fractionAt(int offset) {
    final index = this.index;
    return index != null && index.totalPages > 1
        ? (index.pageNumberAt(offset) - 1) / (index.totalPages - 1)
        : (offset / max(1, document.text.length - 1)).clamp(0.0, 1.0);
  }

  /// 拖动最多每 50ms 加载一次最新目标，持续滑动时也更新预览；松手立即加载最终位置。
  void seekFraction(double value) {
    if (_disposed || !value.isFinite) {
      return;
    }
    final fraction = value.clamp(0.0, 1.0);
    final index = this.index;
    final target = index != null && index.totalPages > 0
        ? index.starts[(fraction * (index.totalPages - 1)).round()]
        : (fraction * (document.text.length - 1)).round();
    _seek(target, fraction: fraction, defer: true);
  }

  void returnToOrigin() => _seek(originOffset);

  /// 同章直接切页，跨章只排版相邻章节；书首和书尾不产生额外跳转。
  void step(bool forward) {
    if (_disposed || (forward ? !canNext : !canPrevious)) {
      return;
    }
    _seek(forward ? _page!.end : _page!.start - 1);
  }

  void _seek(int offset, {double? fraction, bool defer = false}) {
    if (_disposed) {
      return;
    }
    _target = offset.clamp(0, document.text.length - 1);
    _fraction = fraction ?? fractionAt(_target);
    _error = null;
    final ticket = ++_generation;
    if (_page != null && _target >= _page!.start && _target < _page!.end) {
      _debounce?.cancel();
      _loading = false;
      notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();
    if (defer) {
      // 合并节流，不断滑动时也会刷新预览，避免只有停手后才显示新页。
      if (_debounce?.isActive != true) {
        _debounce = Timer(const Duration(milliseconds: 50), () {
          unawaited(_load(_generation));
        });
      }
    } else {
      _debounce?.cancel();
      unawaited(_load(ticket));
    }
  }

  void flush() {
    if (_disposed || !_loading || _debounce?.isActive != true) {
      return;
    }
    _debounce?.cancel();
    unawaited(_load(_generation));
  }

  Future<void> _load(int ticket) async {
    bool cancelled() => _disposed || ticket != _generation;
    if (cancelled()) {
      return;
    }
    final chapter = document.chapterAt(_target);
    try {
      var pages = _cache.remove(chapter);
      pages ??= await Pagination.layout(
        document: document,
        chapter: document.chapters[chapter],
        width: width,
        height: height,
        style: style,
        paragraphSpacing: paragraphSpacing,
        scaler: scaler,
        cancelled: cancelled,
      );
      if (cancelled()) {
        return;
      }
      if (pages.isEmpty) {
        throw const FormatException('章节没有可预览的正文');
      }
      _cache[chapter] = pages;
      while (_cache.length > 3) {
        _cache.remove(_cache.keys.first);
      }
      _page =
          pages[max(0, pages.lastIndexWhere((page) => page.start <= _target))];
      _loading = false;
      notifyListeners();
    } catch (_) {
      if (!cancelled()) {
        _loading = false;
        _error = '预览暂不可用，请拖动进度条重试';
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _debounce?.cancel();
    _cache.clear();
    super.dispose();
  }
}
