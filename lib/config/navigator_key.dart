import 'package:flutter/widgets.dart';

/// 全局导航键。
///
/// 退出流程（[AppShutdown]）是在窗口回调里跑的，手上没有 BuildContext，
/// 但保存没完成时又必须弹窗让用户决定「重试 / 放弃」。
/// 交给 MaterialApp 持有这个 key，退出流程就能拿到当前 Navigator。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
