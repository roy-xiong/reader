import 'package:flutter/material.dart';
import '../../domain/models.dart';
import '../../domain/cloud/cloud_models.dart';
import '../app_model.dart';

String cloudTime(int milliseconds) {
  final t = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// 进入正文前检查远端，不能先把“打开书籍”记录成新进度再覆盖云端。
Future<bool> checkCloudProgress(
  BuildContext context,
  AppModel model,
  BookRecord book,
) async {
  if (!model.cloud.connected) return true;
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ProgressGate(model: model, book: book),
      ) ??
      false;
}

class _ProgressGate extends StatefulWidget {
  const _ProgressGate({required this.model, required this.book});
  final AppModel model;
  final BookRecord book;
  @override
  State<_ProgressGate> createState() => _ProgressGateState();
}

class _ProgressGateState extends State<_ProgressGate> {
  CloudProgress? remote;
  String? error;
  bool loading = true;
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() => loading = true);
    final cloud = widget.model.cloud;
    final progress = await cloud.newerProgress(
      widget.book.id,
      widget.book.lastOpened,
      widget.book.offset,
    );
    if (!mounted) return;
    if (progress == null && cloud.error == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      remote = progress;
      error = cloud.error;
      loading = false;
    });
  }

  Future<void> _follow() async {
    final progress = remote;
    if (progress == null) return;
    setState(() => loading = true);
    try {
      await widget.model.followCloudProgress(progress);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '云端位置暂时无法应用，可继续本机阅读';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      loading
          ? '检查云端进度'
          : remote == null
          ? '云端暂不可用'
          : '发现更新的云端进度',
    ),
    content: SizedBox(
      width: 390,
      child: loading
          ? const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(),
                SizedBox(height: 16),
                Text('正在读取此书的最新阅读记录…'),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (remote != null) ...[
                  Text(
                    widget.book.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '本机：${(widget.book.progress * 100).toStringAsFixed(1)}%',
                  ),
                  Text(
                    widget.book.lastOpened == 0
                        ? '尚未阅读'
                        : cloudTime(widget.book.lastOpened),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '云端：${(remote!.offset / remote!.length * 100).toStringAsFixed(1)}%',
                  ),
                  Text(cloudTime(remote!.updatedAt)),
                  const SizedBox(height: 16),
                  const Text('云端阅读时间更晚，是否跳到该位置？'),
                ],
                if (error != null) Text(error!),
              ],
            ),
    ),
    actions: loading
        ? [
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续本机阅读'),
            ),
          ]
        : [
            TextButton(
              key: const ValueKey('keep-local-progress'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(remote == null ? '继续本机阅读' : '保持本机位置'),
            ),
            if (remote == null)
              TextButton(onPressed: _check, child: const Text('重试')),
            if (remote != null)
              FilledButton(
                key: const ValueKey('follow-cloud-progress'),
                onPressed: _follow,
                child: const Text('追到云端进度'),
              ),
          ],
  );
}
