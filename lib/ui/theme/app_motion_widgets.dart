import 'package:flutter/material.dart';

import 'app_theme.dart';

/// 按压反馈：按住缩放到 0.97，抬起回弹到 1（设计稿「按压反馈」）。
class PressableScale extends StatefulWidget {
  const PressableScale({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1,
          duration: AppMotion.press,
          curve: AppMotion.curve,
          child: widget.child,
        ),
      ),
    );
  }
}

/// 入场动效：位移 Y+8px 淡入（设备卡 / 消息卡），[delay] 做逐张错峰。
class Entrance extends StatefulWidget {
  const Entrance({super.key, required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.quick,
  );
  late final Animation<double> _animation = CurvedAnimation(
    parent: _controller,
    curve: AppMotion.curve,
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) => Opacity(
        opacity: _animation.value,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - _animation.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// 状态点呼吸：未连接时明暗循环，透明度 40% → 100%（设计稿「状态点呼吸」）。
class BreathingDot extends StatefulWidget {
  const BreathingDot({super.key, required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  State<BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<BreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.breathe,
    lowerBound: 0.4,
    upperBound: 1.0,
  );

  @override
  void initState() {
    super.initState();
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// 进度条平滑补间：宽度弹性补间（设计稿「传输进度」）。
class SmoothProgress extends StatelessWidget {
  const SmoothProgress({
    super.key,
    required this.value,
    this.height = 5,
    this.color = AppColors.primary,
    this.track = AppColors.border,
  });

  final double value;
  final double height;
  final Color color;
  final Color track;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value.clamp(0.0, 1.0)),
      duration: AppMotion.progress,
      curve: AppMotion.curve,
      builder: (context, animated, _) => ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: SizedBox(
          height: height,
          child: LinearProgressIndicator(
            value: animated,
            minHeight: height,
            color: color,
            backgroundColor: track,
          ),
        ),
      ),
    );
  }
}
