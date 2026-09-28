import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'config/dependencies.dart';
import 'config/navigator_key.dart';
import 'config/window_controller.dart';
import 'data/services/storage/log_service.dart';
import 'data/services/storage/storage_service.dart';
import 'ui/chat/widgets/chat_screen.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 视频预览引擎（libmpv）必须在 runApp 之前初始化。
  MediaKit.ensureInitialized();
  // 窗口管理：关窗口要先走完退出流程（保存连接记录），见 AppShutdown。
  // 这一步必须在 runApp 之前——否则用户可能在拦截生效前就把窗口关了。
  await windowManager.ensureInitialized();

  // 日志在 runApp 之前就接管，启动阶段的问题也能记录下来。
  final storageService = StorageService();
  final logService = LogService(storageService);
  await logService.init();
  _setupLogging(logService);

  runApp(
    MainApp(
      storageService: storageService,
      logService: logService,
    ),
  );
}

/// 把 logging 的输出同时打到控制台与日志文件。
void _setupLogging(LogService logService) {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    final buffer = StringBuffer()
      ..write(record.time.toIso8601String())
      ..write(' [${record.level.name}] ')
      ..write(record.loggerName)
      ..write(': ')
      ..write(record.message);
    if (record.error != null) buffer.write(' | error: ${record.error}');

    final line = buffer.toString();
    debugPrint(line);
    unawaited(logService.append(line));
  });

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    unawaited(logService.append('[FlutterError] ${details.exceptionAsString()}'));
  };
}

/// 应用根组件。
///
/// 通过 [MultiProvider] 注入依赖（参照官方架构的 DI 约定）。
class MainApp extends StatelessWidget {
  const MainApp({
    super.key,
    required this.storageService,
    required this.logService,
    this.window,
  });

  final StorageService storageService;
  final LogService logService;

  /// 窗口操作替身（测试注入）：默认走真实的 window_manager 插件。
  final WindowController? window;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: buildProviders(
        storageService: storageService,
        logService: logService,
        window: window,
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Mova',
        theme: buildAppTheme(),
        // 退出流程要在没有 BuildContext 的窗口回调里弹窗询问用户。
        navigatorKey: appNavigatorKey,
        home: const ChatScreen(),
      ),
    );
  }
}
