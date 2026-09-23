import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';

import 'config/dependencies.dart';
import 'data/services/storage/log_service.dart';
import 'data/services/storage/storage_service.dart';
import 'ui/chat/widgets/chat_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
  });

  final StorageService storageService;
  final LogService logService;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: buildProviders(
        storageService: storageService,
        logService: logService,
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Mova',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: const ChatScreen(),
      ),
    );
  }
}
