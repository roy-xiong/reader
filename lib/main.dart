import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'data/library_repository.dart';
import 'data/platform_service.dart';
import 'domain/models.dart';
import 'ui/app_model.dart';
import 'ui/lock_screen.dart';
import 'ui/reader_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/shelf_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final platform = PlatformService();
  try {
    final path = await platform.supportPath();
    final model = AppModel(LibraryRepository(Directory(path)), platform);
    await model.initialize();
    runApp(ReaderApp(model: model));
  } catch (error) {
    runApp(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: SelectableText(
                '无法打开书架\n\n$error\n\n原有数据已保留。请检查存储目录权限或备份。',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 负责页面导航、生命周期锁定及原生菜单分发；所有阅读状态由 AppModel 持有。
class ReaderApp extends StatefulWidget {
  const ReaderApp({super.key, required this.model});
  final AppModel model;
  @override
  State<ReaderApp> createState() => _ReaderAppState();
}

class _ReaderAppState extends State<ReaderApp> with WidgetsBindingObserver {
  final navigator = GlobalKey<NavigatorState>();
  final messenger = GlobalKey<ScaffoldMessengerState>();
  GlobalKey<ReaderScreenState>? reader;
  bool settingsOpen = false;
  AppModel get model => widget.model;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    model.addListener(_modelChanged);
    model.platform.onMenu(_menu);
  }

  void _modelChanged() {
    final message = model.error;
    if (message != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || model.error != message) {
          return;
        }
        messenger.currentState?.showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 7),
          ),
        );
        model.clearError();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        // macOS 最小化只保存状态；启动锁和用户主动锁定继续生效。
        unawaited(model.flush().catchError((Object _) {}));
      } else {
        model.lock();
      }
    }
  }

  Future<void> _menu(String command) async {
    if (!mounted || model.locked) {
      return;
    }
    switch (command) {
      case 'openSettings':
        await _settings();
      case 'importBooks':
        await model.importBooks();
      case 'importFolder':
        await model.importBooks(folder: true);
      case 'showShelf':
        navigator.currentState?.popUntil((r) => r.isFirst);
      case 'findText':
        reader?.currentState?.showSearch();
      case 'bookmark':
        await reader?.currentState?.toggleBookmark();
      case 'lockApp':
        model.lock();
    }
  }

  Future<void> _settings() async {
    if (settingsOpen || model.locked) {
      return;
    }
    settingsOpen = true;
    try {
      await navigator.currentState?.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/settings'),
          builder: (_) => SettingsScreen(model: model),
        ),
      );
      await model.flush();
    } catch (_) {
      /* 存储错误已由模型向用户显示。 */
    } finally {
      settingsOpen = false;
    }
  }

  Future<void> _open(BookRecord book) async {
    if (model.locked || model.busy) {
      return;
    }
    reader = GlobalKey<ReaderScreenState>();
    await model.platform.readingMode(true);
    try {
      await navigator.currentState?.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/reader'),
          builder: (_) => ReaderScreen(
            key: reader,
            model: model,
            book: book,
            openSettings: _settings,
          ),
        ),
      );
      await model.flush();
    } catch (_) {
      /* 模型负责报告可恢复的读写错误。 */
    } finally {
      reader = null;
      await model.platform.readingMode(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    model.removeListener(_modelChanged);
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => MaterialApp(
      title: 'Reader',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigator,
      scaffoldMessengerKey: messenger,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: switch (model.settings.theme) {
        'dark' => ThemeMode.dark,
        'light' => ThemeMode.light,
        _ => ThemeMode.system,
      },
      builder: (context, child) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
              unawaited(_settings()),
          const SingleActivator(LogicalKeyboardKey.keyO, control: true): () =>
              unawaited(model.importBooks()),
        },
        child: Stack(
          children: [
            ExcludeFocus(
              excluding: model.locked,
              child: ExcludeSemantics(
                excluding: model.locked,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
            if (model.locked)
              Positioned.fill(
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: SafeArea(
                    child: PinPad(
                      model: model,
                      title: '输入密码',
                      subtitle: '解锁你的私人书架',
                      onSubmit: (code) async =>
                          await model.verifyPin(code, unlock: true)
                          ? null
                          : '密码错误，请重试',
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      home: ShelfScreen(model: model, openBook: _open, openSettings: _settings),
    ),
  );
}

ThemeData _theme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors = ColorScheme.fromSeed(
    seedColor: const Color(0xff4f7568),
    brightness: brightness,
    surface: dark ? const Color(0xff171c1b) : const Color(0xfff7f5ef),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    scaffoldBackgroundColor: defaultTargetPlatform == TargetPlatform.macOS
        ? colors.surface.withValues(alpha: .86)
        : colors.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: defaultTargetPlatform == TargetPlatform.macOS
          ? colors.surface.withValues(alpha: .86)
          : colors.surface,
      scrolledUnderElevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerHighest.withValues(alpha: .45),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
  );
}
