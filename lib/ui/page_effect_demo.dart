import 'dart:async';
import 'package:flutter/material.dart';
import '../domain/page_turn_effect.dart';
import '../domain/pagination.dart';
import 'reader_page.dart';
import 'reader_pager.dart';

/// 设置里的独立小样，不关联正在阅读的书籍，试用效果不会修改阅读进度。
class PageEffectDemo extends StatefulWidget {
  const PageEffectDemo({super.key, required this.effect});
  final String effect;
  @override
  State<PageEffectDemo> createState() => _PageEffectDemoState();
}

class _PageEffectDemoState extends State<PageEffectDemo> {
  final _pager = GlobalKey<ReaderPagerState>();
  var _index = 0;
  static final _pages = [
    ReadingPage(0, 100, const [
      PageFragment('文字，也会流动。', 0, 28, isHeading: true, separatorAfter: true),
      PageFragment('一阵风翻过书页，\n故事在此刻继续。', 46, 54),
    ]),
    ReadingPage(100, 200, const [
      PageFragment('下一页，新风景。', 0, 28, isHeading: true, separatorAfter: true),
      PageFragment('光落在字里行间，\n时间也慢了下来。', 46, 54),
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effect = PageTurnEffect.parse(widget.effect);
    return Container(
      key: const ValueKey('page-effect-demo'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(effect.description, style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          SizedBox(
            height: 140,
            child: LayoutBuilder(
              builder: (context, constraints) => ReaderPager(
                key: _pager,
                effect: effect.id,
                background: theme.colorScheme.surfaceContainer,
                onToggle: () => unawaited(_pager.currentState?.turn(true)),
                onTurn: (_) async {
                  setState(() => _index = 1 - _index);
                  return true;
                },
                child: ReaderPage(
                  page: _pages[_index],
                  width: constraints.maxWidth,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.7,
                    color: theme.colorScheme.onSurface,
                  ),
                  scaler: TextScaler.noScaling,
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('play-page-effect'),
              onPressed: () => unawaited(_pager.currentState?.turn(true)),
              child: const Text('点击试翻一页'),
            ),
          ),
        ],
      ),
    );
  }
}
