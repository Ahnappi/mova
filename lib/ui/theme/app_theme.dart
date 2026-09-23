import 'package:flutter/material.dart';

/// 设计系统：颜色、圆角、间距、动效（View 层共享）。
///
/// 出自设计稿《动效与交互》：出统一用 cubic-bezier(0.16, 1, 0.3, 1)，
/// 短促、克制，不抢主流程。
abstract final class AppMotion {
  /// 统一缓动曲线（设计稿指定）。
  static const Curve curve = Cubic(0.16, 1, 0.3, 1);

  /// 按压反馈。
  static const Duration press = Duration(milliseconds: 100);

  /// 状态点呼吸 / 设备卡入场 / 消息卡入场。
  static const Duration quick = Duration(milliseconds: 200);

  /// 设备卡入场的逐张错峰间隔。
  static const Duration stagger = Duration(milliseconds: 40);

  /// 连接成功脉冲 / 手动直连展开。
  static const Duration medium = Duration(milliseconds: 600);

  /// 弹窗进 / 出场。
  static const Duration dialogIn = Duration(milliseconds: 260);
  static const Duration dialogOut = Duration(milliseconds: 160);

  /// 进度条补间。
  static const Duration progress = Duration(milliseconds: 300);

  /// 状态点呼吸周期。
  static const Duration breathe = Duration(milliseconds: 2000);
}

/// 设计稿配色（浅色主题）。
abstract final class AppColors {
  /// 主色：按钮、气泡、进度条（设计稿蓝）。
  static const Color primary = Color(0xFF1A6FEB);

  /// 页面背景。
  static const Color background = Colors.white;

  /// 浅灰卡片 / 输入底 / 分隔带（设备卡、搜索行、气泡）。
  static const Color surfaceMuted = Color(0xFFF5F6F7);

  /// 描边（卡片、输入框）。
  static const Color border = Color(0xFFE7E9EC);

  /// 主文本。
  static const Color textPrimary = Color(0xFF1F2329);

  /// 次要文本（说明、路径、时间）。
  static const Color textSecondary = Color(0xFF8A9099);

  /// 已连接状态点。
  static const Color success = Color(0xFF23A757);

  /// 未连接状态点。
  static const Color idle = Color(0xFFB9BEC6);

  /// 连接中状态点。
  static const Color connecting = primary;

  /// 危险操作（删除）。
  static const Color danger = Color(0xFFD93A3A);
}

/// 设计稿圆角与间距。
abstract final class AppDimens {
  static const double radiusCard = 12;
  static const double radiusPill = 999;
  static const double pagePadding = 20;
}

/// 应用浅色主题。
ThemeData buildAppTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
  ).copyWith(
    primary: AppColors.primary,
    surface: AppColors.background,
    error: AppColors.danger,
  );

  final base = ThemeData(
    colorScheme: colorScheme,
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.background,
    visualDensity: VisualDensity.standard,
  );

  return base.copyWith(
    dividerTheme: const DividerThemeData(color: AppColors.border, thickness: 1),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: AppColors.textSecondary),
    ),
    inputDecorationTheme: InputDecorationTheme(
      hintStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
      filled: true,
      fillColor: AppColors.background,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppDimens.radiusCard),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppDimens.radiusCard),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.4),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      titleTextStyle: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
