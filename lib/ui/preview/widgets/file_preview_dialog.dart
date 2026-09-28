import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/services/system/file_opener_service.dart';
import '../../../data/services/transfer/file_storage_service.dart';
import '../../theme/app_motion_widgets.dart';
import '../../theme/app_theme.dart';
import '../../../utils/format.dart';
import '../preview_kind.dart';
import 'image_preview_view.dart';
import 'pdf_preview_view.dart';
import 'video_preview_view.dart';

/// 打开全屏文件预览层。
///
/// 点遮罩、按 ESC、点右上角关闭都能退出。
Future<void> showFilePreview(BuildContext context, String path) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭预览',
    barrierColor: Colors.black.withValues(alpha: 0.6),
    transitionDuration: AppMotion.dialogIn,
    transitionBuilder: (context, animation, secondary, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.curve,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
          child: child,
        ),
      );
    },
    pageBuilder: (context, animation, secondary) =>
        _FilePreviewDialog(path: path),
  );
}

class _FilePreviewDialog extends StatelessWidget {
  const _FilePreviewDialog({required this.path});

  final String path;

  String get _name => path.split(RegExp(r'[\\/]')).last;

  @override
  Widget build(BuildContext context) {
    final opener = context.read<FileOpenerService>();
    // 文件状态由 Service 层回答，View 不直接碰文件系统。
    final facts = context.read<FileStorageService>().inspect(path);
    final kind = previewKindOf(extensionOf(path));
    final size = facts.exists ? formatBytes(facts.sizeBytes) : '';

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // 点空白处关闭（预览内容自己会拦截手势）。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Column(
                children: [
                  _Header(
                    name: _name,
                    path: path,
                    size: size,
                    opener: opener,
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: _Body(
                      kind: kind,
                      path: path,
                      exists: facts.exists,
                      opener: opener,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部信息条：文件名、大小、路径，以及复制路径 / 定位 / 系统打开 / 关闭。
class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.path,
    required this.size,
    required this.opener,
  });

  final String name;
  final String path;
  final String size;
  final FileOpenerService opener;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppDimens.radiusCard),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (size.isNotEmpty) ...[
                      Text(
                        size,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        path,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _HeaderAction(
            icon: Icons.copy_all_rounded,
            tooltip: '复制路径',
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: path));
              if (!context.mounted) return;
              _toast(context, '路径已复制');
            },
          ),
          _HeaderAction(
            icon: Icons.folder_open_outlined,
            tooltip: '在文件管理器中显示',
            onTap: () async {
              if (!await opener.reveal(path)) {
                if (!context.mounted) return;
                _toast(context, '打不开文件管理器，可复制路径手动前往');
              }
            },
          ),
          _HeaderAction(
            icon: Icons.open_in_new_rounded,
            tooltip: '用系统默认应用打开',
            onTap: () async {
              if (!await opener.open(path)) {
                if (!context.mounted) return;
                _toast(context, '没有找到能打开它的应用');
              }
            },
          ),
          _HeaderAction(
            icon: Icons.close,
            tooltip: '关闭（Esc）',
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  void _toast(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 19),
      color: Colors.white,
      splashRadius: 18,
    );
  }
}

/// 预览主体：先确认文件还在，再按类型分派。
class _Body extends StatelessWidget {
  const _Body({
    required this.kind,
    required this.path,
    required this.exists,
    required this.opener,
  });

  final PreviewKind kind;
  final String path;
  final bool exists;
  final FileOpenerService opener;

  @override
  Widget build(BuildContext context) {
    if (!exists) {
      return _Placeholder(
        icon: Icons.file_open_outlined,
        title: '文件已不在原位置',
        message: '它可能已被移动、重命名或删除。',
        actionLabel: '在文件管理器中显示',
        onAction: () => opener.reveal(path),
      );
    }

    return switch (kind) {
      PreviewKind.image => ImagePreviewView(path: path),
      PreviewKind.video => VideoPreviewView(path: path),
      PreviewKind.pdf => PdfPreviewView(path: path),
      PreviewKind.external => _Placeholder(
          icon: Icons.description_outlined,
          title: '这个格式不能在应用内预览',
          message: 'Office 文档 / SVG / HEIC 等格式没有内置解码器，'
              '可以交给系统默认程序打开。',
          actionLabel: '用系统默认应用打开',
          onAction: () => opener.open(path),
        ),
    };
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppDimens.radiusCard),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44, color: Colors.white70),
              const SizedBox(height: 14),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              PressableScale(
                onTap: onAction,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius:
                        BorderRadius.circular(AppDimens.radiusPill),
                  ),
                  child: Text(
                    actionLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
