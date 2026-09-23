import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'config/dependencies.dart';
import 'ui/chat/widgets/chat_screen.dart';

void main() => runApp(const MainApp());

/// 应用根组件。
///
/// 通过 [MultiProvider] 注入依赖（参照官方架构的 DI 约定）。
class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: providers,
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
