import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/cloud/cloud_crypto.dart';
import '../../domain/cloud/cloud_models.dart';
import '../app_model.dart';
import 'cloud_progress_prompt.dart';

/// 坚果云连接和主动传输入口。字体、照片不因打开此页而自动上传或下载。
class CloudSyncScreen extends StatefulWidget {
  const CloudSyncScreen({super.key, required this.model});
  final AppModel model;
  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  late final server = TextEditingController(text: widget.model.cloud.server);
  late final username = TextEditingController(
    text: widget.model.cloud.username,
  );
  final password = TextEditingController(),
      root = TextEditingController(text: '阅读');
  final recovery = TextEditingController();
  bool create = false, showPassword = false, showRecovery = false;
  String selected = 'book';
  @override
  void dispose() {
    for (final field in [server, username, password, root, recovery]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    try {
      await widget.model.cloud.connect(
        server: server.text,
        username: username.text,
        password: password.text,
        root: root.text,
        recoveryCode: recovery.text,
        create: create,
      );
      if (widget.model.cloud.connected) {
        password.clear();
        recovery.clear();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e is FormatException ? e.message : '连接失败，请检查填写内容'),
          ),
        );
      }
    }
  }

  Future<void> _revealCode() async {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('云书架恢复码'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('在另一台设备加入同一云书架时填写。请妥善保管，不要将恢复码和应用密码发给他人。'),
              const SizedBox(height: 16),
              SelectableText(widget.model.cloud.recoveryCode),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () => Clipboard.setData(
              ClipboardData(text: widget.model.cloud.recoveryCode),
            ),
            child: const Text('复制恢复码'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model.cloud,
    builder: (context, _) {
      final cloud = widget.model.cloud;
      final items = cloud.items.where((i) => i.kind == selected).toList();
      return PopScope(
        canPop: !widget.model.locked,
        child: Scaffold(
          appBar: AppBar(title: const Text('坚果云同步')),
          bottomNavigationBar: !cloud.busy
              ? null
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LinearProgressIndicator(
                          key: const ValueKey('cloud-transfer-progress'),
                          value: cloud.fraction,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${cloud.currentFile.isEmpty ? cloud.status : cloud.currentFile} '
                          '${cloud.fraction == null ? '' : '${(cloud.fraction! * 100).round()}%'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (cloud.totalFiles > 0)
                          Text(
                            '已完成 ${cloud.completedFiles}/${cloud.totalFiles} 项',
                          ),
                      ],
                    ),
                  ),
                ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
                children: [
                  Text(
                    cloud.status,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '阅读进度自动上传；打开书籍时按更新时间提示追到云端。书籍、字体和照片均由你主动上传或下载，字号、主题、密码等设置不自动同步。',
                  ),
                  if (cloud.error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        cloud.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (!cloud.connected) ...[
                    const SizedBox(height: 24),
                    TextField(
                      controller: server,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'WebDAV 地址'),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      key: const ValueKey('cloud-account'),
                      controller: username,
                      autocorrect: false,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: '坚果云账号（邮箱）'),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      key: const ValueKey('cloud-app-password'),
                      controller: password,
                      autocorrect: false,
                      enableSuggestions: false,
                      obscureText: !showPassword,
                      decoration: InputDecoration(
                        labelText: '第三方应用密码',
                        helperText: '坚果云 → 账户信息 → 安全选项 → 添加应用密码',
                        suffixIcon: TextButton(
                          onPressed: () =>
                              setState(() => showPassword = !showPassword),
                          child: Text(showPassword ? '隐藏' : '显示'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: root,
                      decoration: const InputDecoration(
                        labelText: '专属云书架目录',
                        helperText: '两台设备使用相同目录，默认“阅读”',
                      ),
                    ),
                    const SizedBox(height: 20),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('加入已有云书架')),
                        ButtonSegment(value: true, label: Text('首次创建')),
                      ],
                      selected: {create},
                      onSelectionChanged: cloud.busy
                          ? null
                          : (value) => setState(() {
                              create = value.single;
                              recovery.text = create
                                  ? CloudCrypto.newRecoveryCode()
                                  : '';
                            }),
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      key: const ValueKey('cloud-recovery'),
                      controller: recovery,
                      readOnly: create,
                      autocorrect: false,
                      enableSuggestions: false,
                      obscureText: !showRecovery,
                      decoration: InputDecoration(
                        labelText: '云书架恢复码',
                        suffixIcon: TextButton(
                          onPressed: () =>
                              setState(() => showRecovery = !showRecovery),
                          child: Text(showRecovery ? '隐藏' : '显示'),
                        ),
                      ),
                    ),
                    if (create)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => Clipboard.setData(
                            ClipboardData(text: recovery.text),
                          ),
                          child: const Text('复制恢复码，供另一台设备加入'),
                        ),
                      ),
                    const SizedBox(height: 10),
                    const Text(
                      '恢复码用于解密云端资料。请另行保存；丢失后仅凭网盘账号无法恢复加密资料。',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: cloud.busy ? null : _connect,
                      child: Text(create ? '创建并连接' : '连接云书架'),
                    ),
                  ] else ...[
                    const SizedBox(height: 20),
                    Text('账号：${cloud.username}'),
                    Text('目录：${cloud.root}'),
                    if (cloud.lastSuccess > 0)
                      Text('上次成功：${cloudTime(cloud.lastSuccess)}'),
                    if (cloud.progressPending)
                      Text('${cloud.pendingCount} 本书的最新进度待上传，联网且应用在前台时补传。'),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: cloud.busy ? null : cloud.refresh,
                          child: const Text('刷新云端目录'),
                        ),
                        TextButton(
                          onPressed: cloud.busy ? null : cloud.flushProgress,
                          child: const Text('补传阅读进度'),
                        ),
                        TextButton(
                          onPressed: _revealCode,
                          child: const Text('查看恢复码'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'book', label: Text('书籍')),
                        ButtonSegment(value: 'font', label: Text('字体')),
                        ButtonSegment(value: 'photo', label: Text('照片')),
                      ],
                      selected: {selected},
                      onSelectionChanged: (value) =>
                          setState(() => selected = value.single),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: cloud.busy
                          ? null
                          : () => cloud.upload(selected),
                      child: Text(
                        '上传本机${switch (selected) {
                          'book' => '书籍',
                          'font' => '字体',
                          _ => '照片及图片组',
                        }}',
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: cloud.busy || items.isEmpty
                          ? null
                          : () => cloud.downloadAll(
                              items
                                  .where(
                                    (item) =>
                                        !widget.model.hasCloudItem(item) ||
                                        item.kind == 'photo',
                                  )
                                  .toList(),
                            ),
                      child: const Text('下载本类全部未下载项目（照片含图片组更新）'),
                    ),
                    if (items.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text('云端目录尚无项目。上传后，另一设备连接并点击“刷新云端目录”。'),
                      ),
                    for (final item in items) _item(item),
                    const SizedBox(height: 24),
                    const Divider(),
                    TextButton(
                      onPressed: cloud.busy
                          ? null
                          : () async {
                              final yes = await showDialog<bool>(
                                context: context,
                                builder: (_) => AlertDialog(
                                  title: const Text('断开此设备？'),
                                  content: Text(
                                    cloud.progressPending
                                        ? '还有未上传进度。断开后不会继续补传；本机资料与网盘文件保留。'
                                        : '本机资料与网盘文件保留。重新连接需要应用密码和恢复码。',
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
                                      child: const Text('断开'),
                                    ),
                                  ],
                                ),
                              );
                              if (yes == true) await cloud.disconnect();
                            },
                      child: const Text('断开坚果云连接'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  Widget _item(CloudItem item) {
    final exists = widget.model.hasCloudItem(item);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  Text(
                    '${(item.bytes / 1048576).toStringAsFixed(1)} MB · ${exists ? '已在本机' : '可下载'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed:
                  widget.model.cloud.busy || (exists && item.kind != 'photo')
                  ? null
                  : () => widget.model.cloud.download(item),
              child: Text(
                exists ? (item.kind == 'photo' ? '更新图片组' : '已下载') : '下载',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
