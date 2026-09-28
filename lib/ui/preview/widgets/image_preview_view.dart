import 'dart:io';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// 图片预览：支持缩放拖动，双击 / 点击按钮复位。
class ImagePreviewView extends StatefulWidget {
  const ImagePreviewView({super.key, required this.path});

  final String path;

  @override
  State<ImagePreviewView> createState() => _ImagePreviewViewState();
}

class _ImagePreviewViewState extends State<ImagePreviewView> {
  final TransformationController _controller = TransformationController();
  bool _zoomed = false;
  Size _viewport = Size.zero;

  void _reset() {
    _controller.value = Matrix4.identity();
    setState(() => _zoomed = false);
  }

  /// 以视口中心为锚点缩放：直接乘缩放矩阵会让画面往左上角漂。
  void _zoom(double factor) {
    final current = _controller.value;
    final scale = (current.getMaxScaleOnAxis() * factor).clamp(0.2, 8.0);
    final delta = scale / (current.getMaxScaleOnAxis() == 0
        ? 1.0
        : current.getMaxScaleOnAxis());

    final cx = _viewport.width / 2;
    final cy = _viewport.height / 2;
    final toOrigin = Matrix4.translationValues(-cx, -cy, 0);
    final scaling = Matrix4.diagonal3Values(delta, delta, 1);
    final back = Matrix4.translationValues(cx, cy, 0);

    _controller.value = back * (scaling * (toOrigin * current));
    setState(() => _zoomed = scale > 1.01);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        return Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              transformationController: _controller,
              minScale: 0.2,
              maxScale: 8,
              onInteractionUpdate: (_) {
                final zoomed = _controller.value.getMaxScaleOnAxis() > 1.01;
                if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
              },
              child: Center(
                child: Image.file(
                  File(widget.path),
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                  errorBuilder: (context, error, stackTrace) =>
                      const _PreviewError(
                    message: '这个文件不是有效的图片，或已损坏',
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 16,
              child: _PreviewToolbar(
                children: [
                  _ToolbarButton(
                    icon: Icons.zoom_out,
                    tooltip: '缩小',
                    onTap: () => _zoom(1 / 1.3),
                  ),
                  _ToolbarButton(
                    icon: Icons.zoom_in,
                    tooltip: '放大',
                    onTap: () => _zoom(1.3),
                  ),
                  _ToolbarButton(
                    icon: Icons.restart_alt_rounded,
                    tooltip: '复位',
                    enabled: _zoomed,
                    onTap: _reset,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 预览层底部共用的半透明工具条。
class _PreviewToolbar extends StatelessWidget {
  const _PreviewToolbar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppDimens.radiusPill),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 20),
      color: Colors.white,
      disabledColor: Colors.white.withValues(alpha: 0.35),
    );
  }
}

/// 预览层内统一的错误占位（文件损坏 / 解码失败）。
class _PreviewError extends StatelessWidget {
  const _PreviewError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image_outlined,
              size: 40, color: AppColors.textSecondary),
          const SizedBox(height: 10),
          Text(
            message,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
