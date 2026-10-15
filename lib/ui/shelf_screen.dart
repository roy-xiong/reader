import 'dart:io';
import 'package:flutter/material.dart';
import '../domain/models.dart';
import 'app_model.dart';

class ShelfScreen extends StatefulWidget {
  const ShelfScreen({
    super.key,
    required this.model,
    required this.openBook,
    required this.openSettings,
  });
  final AppModel model;
  final Future<void> Function(BookRecord) openBook;
  final Future<void> Function() openSettings;
  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen> {
  String query = '', sort = 'recent';
  final search = TextEditingController();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final books =
          widget.model.books
              .where(
                (b) => '${b.title} ${b.author}'.toLowerCase().contains(
                  query.toLowerCase(),
                ),
              )
              .toList()
            ..sort(
              (a, b) => sort == 'title'
                  ? a.title.compareTo(b.title)
                  : sort == 'added'
                  ? b.importedAt.compareTo(a.importedAt)
                  : b.lastOpened.compareTo(a.lastOpened),
            );
      return PopScope(
        canPop: !widget.model.locked,
        child: Scaffold(
          appBar: AppBar(
            title: const Text(
              'Reader',
              style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 1),
            ),
            actions: [
              if (widget.model.hasPin)
                IconButton(
                  tooltip: '锁定',
                  onPressed: widget.model.lock,
                  icon: const Icon(Icons.lock_outline),
                ),
              IconButton(
                tooltip: '设置',
                onPressed: widget.openSettings,
                icon: const Icon(Icons.tune_rounded),
              ),
              const SizedBox(width: 12),
            ],
          ),
          body: Column(
            children: [
              if (widget.model.busy)
                LinearProgressIndicator(semanticsLabel: widget.model.busyLabel),
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                      sliver: SliverToBoxAdapter(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final title = Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '我的书架',
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  widget.model.busy
                                      ? widget.model.busyLabel ?? '处理中'
                                      : '${widget.model.books.length} 本藏书 · 给阅读留一点时间',
                                  style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            );
                            final buttons = Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (Platform.isMacOS)
                                  OutlinedButton.icon(
                                    onPressed: widget.model.busy
                                        ? null
                                        : () => widget.model.importBooks(
                                            folder: true,
                                          ),
                                    icon: const Icon(
                                      Icons.folder_open,
                                      size: 18,
                                    ),
                                    label: const Text('导入文件夹'),
                                  ),
                                FilledButton.icon(
                                  onPressed: widget.model.busy
                                      ? null
                                      : () => widget.model.importBooks(),
                                  icon: const Icon(Icons.add, size: 18),
                                  label: const Text('导入书籍'),
                                ),
                              ],
                            );
                            return constraints.maxWidth >= 650
                                ? Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Flexible(child: title),
                                      buttons,
                                    ],
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      title,
                                      const SizedBox(height: 20),
                                      buttons,
                                    ],
                                  );
                          },
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                      sliver: SliverToBoxAdapter(
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: search,
                                decoration: const InputDecoration(
                                  prefixIcon: Icon(Icons.search),
                                  hintText: '搜索书名、作者',
                                  isDense: true,
                                ),
                                onChanged: (value) =>
                                    setState(() => query = value),
                              ),
                            ),
                            const SizedBox(width: 12),
                            PopupMenuButton<String>(
                              tooltip: '排序',
                              initialValue: sort,
                              onSelected: (v) => setState(() => sort = v),
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'recent',
                                  child: Text('最近阅读'),
                                ),
                                PopupMenuItem(
                                  value: 'added',
                                  child: Text('最近导入'),
                                ),
                                PopupMenuItem(
                                  value: 'title',
                                  child: Text('书名排序'),
                                ),
                              ],
                              icon: const Icon(Icons.sort_rounded),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (books.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.auto_stories_outlined,
                                  size: 64,
                                  color: colors.primary.withValues(alpha: .6),
                                ),
                                const SizedBox(height: 24),
                                Text(
                                  query.isEmpty ? '从一本书开始' : '没有找到这本书',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 12),
                                const Text(
                                  'TXT · EPUB · MOBI\n本地保存，离线阅读',
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                      sliver: SliverGrid.builder(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 240,
                              mainAxisExtent: 300,
                              crossAxisSpacing: 22,
                              mainAxisSpacing: 24,
                            ),
                        itemCount: books.length,
                        itemBuilder: (context, index) {
                          final book = books[index];
                          return _BookCard(
                            book: book,
                            open: () => widget.openBook(book),
                            delete: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: const Text('移除书籍'),
                                  content: Text(
                                    '移除《${book.title}》及其阅读记录？原始文件不受影响。',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('取消'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('移除'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed == true) {
                                try {
                                  await widget.model.deleteBook(book.id);
                                } catch (_) {
                                  /* 模型显示保存错误。 */
                                }
                              }
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.open,
    required this.delete,
  });
  final BookRecord book;
  final VoidCallback open, delete;
  @override
  Widget build(BuildContext context) {
    const palettes = [
      Color(0xff355c55),
      Color(0xff86694d),
      Color(0xff495974),
      Color(0xff715971),
      Color(0xff7c584b),
    ];
    final color =
        palettes[int.parse(book.id.substring(0, 2), radix: 16) %
            palettes.length];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Material(
            color: color,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: open,
              child: Stack(
                children: [
                  Positioned(
                    left: 9,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 1,
                      color: Colors.white.withValues(alpha: .2),
                    ),
                  ),
                  Positioned(
                    right: -45,
                    bottom: -50,
                    child: Icon(
                      Icons.menu_book_rounded,
                      size: 185,
                      color: Colors.white.withValues(alpha: .055),
                    ),
                  ),
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(23, 23, 18, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            book.format,
                            style: const TextStyle(
                              fontSize: 10,
                              letterSpacing: 2,
                              color: Colors.white60,
                            ),
                          ),
                          const SizedBox(height: 24),
                          Expanded(
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: Text(
                                book.title,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 20,
                                  height: 1.5,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                          Text(
                            book.author.isEmpty ? '本地藏书' : book.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white70,
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
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
            SizedBox(
              width: 28,
              height: 28,
              child: PopupMenuButton<String>(
                tooltip: '书籍操作',
                padding: EdgeInsets.zero,
                iconSize: 18,
                onSelected: (_) => delete(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'delete', child: Text('移除书籍')),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          book.lastOpened == 0
              ? '尚未阅读'
              : '已读 ${(book.progress * 100).toStringAsFixed(1)}%',
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: book.progress,
            minHeight: 2,
            backgroundColor: color.withValues(alpha: .15),
          ),
        ),
      ],
    );
  }
}
