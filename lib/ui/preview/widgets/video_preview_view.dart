import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../theme/app_theme.dart';

/// 视频预览：media_kit（libmpv 引擎）。
///
/// 选 libmpv 而不是系统播放器组件，是因为它能覆盖 mkv / rmvb / flv / avi
/// 等一众非主流封装——本应用允许传输上百种视频格式，
/// 平台自带的解码器只认其中一小部分。
class VideoPreviewView extends StatefulWidget {
  const VideoPreviewView({super.key, required this.path});

  final String path;

  @override
  State<VideoPreviewView> createState() => _VideoPreviewViewState();
}

class _VideoPreviewViewState extends State<VideoPreviewView> {
  late final Player _player;
  late final VideoController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _open();
  }

  Future<void> _open() async {
    try {
      // play: false —— 预览层打开后先给一帧画面，由用户决定是否播放。
      await _player.open(Media(widget.path), play: false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '无法播放这个文件：$e');
    }
  }

  @override
  void dispose() {
    // Player 必须显式释放，否则 libmpv 实例会一直占着解码资源。
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.movie_creation_outlined,
                  size: 40, color: AppColors.textSecondary),
              const SizedBox(height: 10),
              const Text(
                'libmpv 无法解码这个文件',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppDimens.radiusCard),
      child: Video(
        controller: _controller,
        controls: MaterialDesktopVideoControls,
        // 预览层本身是全屏弹层，这里不再接管窗口全屏。
        fill: Colors.black,
      ),
    );
  }
}
