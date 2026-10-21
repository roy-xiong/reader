import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/wifi_upload_server.dart';
import 'app_model.dart';

/// 前台 Wi-Fi 传输页。退出、锁定、进入后台时关闭监听和临时会话。
class WifiUploadScreen extends StatefulWidget {
  const WifiUploadScreen({super.key, required this.model});
  final AppModel model;
  @override
  State<WifiUploadScreen> createState() => _WifiUploadScreenState();
}

class _WifiUploadScreenState extends State<WifiUploadScreen>
    with WidgetsBindingObserver {
  WifiUploadServer? _server;
  StreamSubscription<String>? _events;
  final _messages = <String>[];
  bool _starting = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.model.addListener(_modelChanged);
  }

  void _modelChanged() {
    if (widget.model.locked) {
      unawaited(_stop());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ([
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.detached,
    ].contains(state)) {
      unawaited(_stop());
    }
  }

  Future<void> _start() async {
    if (_starting || _server != null || widget.model.locked) {
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    final server = WifiUploadServer(
      importFile: widget.model.importTransferredFile,
    );
    _server = server;
    _events = server.events.listen((message) {
      if (mounted) {
        setState(() {
          _messages.insert(0, message);
          if (_messages.length > 30) {
            _messages.removeLast();
          }
        });
      }
    });
    try {
      await server.start();
      if (!mounted || !identical(_server, server)) {
        await server.stop();
        return;
      }
      setState(() {});
    } catch (error) {
      await _stop();
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : '无法启动传输，请检查 Wi-Fi 和本地网络权限',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _stop() async {
    final server = _server;
    _server = null;
    await _events?.cancel();
    _events = null;
    await server?.stop();
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.model.removeListener(_modelChanged);
    unawaited(_events?.cancel());
    unawaited(_server?.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final server = _server;
    final running = server?.running == true;
    return Scaffold(
      appBar: AppBar(title: const Text('Wi-Fi 上传')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                '把书籍和字体传到阅读器',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              const Text('电脑和本机连接同一 Wi-Fi，在浏览器打开下方地址即可批量上传，无需传输码。'),
              const SizedBox(height: 12),
              const Text('请保持本页在前台。离开本页、锁屏或切到后台后，传输会停止。'),
              const SizedBox(height: 24),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (running) ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('电脑浏览器访问'),
                        for (final url in server!.urls)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: SelectableText(url),
                            trailing: TextButton(
                              onPressed: () =>
                                  Clipboard.setData(ClipboardData(text: url)),
                              child: const Text('复制'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: _stop, child: const Text('停止传输')),
              ] else
                FilledButton(
                  onPressed: _starting ? null : _start,
                  child: Text(_starting ? '正在启动…' : '启动 Wi-Fi 上传'),
                ),
              const SizedBox(height: 24),
              const Text(
                '书籍：TXT、EPUB、MOBI、AZW / AZW3、HTML\n字体：TTF / OTF，上传后在设置的字体列表中选择。',
              ),
              if (_messages.isNotEmpty) ...[
                const SizedBox(height: 24),
                const Text('传输记录'),
                for (final message in _messages)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Text(message),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
