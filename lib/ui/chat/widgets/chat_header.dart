import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../domain/models/chat/connection_status.dart';
import '../../theme/app_motion_widgets.dart';
import '../../theme/app_theme.dart';
import '../../transfer/view_models/transfer_view_model.dart';
import '../view_models/connection_view_model.dart';
import 'error_notice_bar.dart';

/// 顶栏：左侧状态徽章（+断开），右侧本机地址胶囊、连接记录、数据存放位置与设置按钮。
class ChatHeader extends StatelessWidget {
  const ChatHeader({
    super.key,
    required this.connection,
    required this.onOpenHistory,
    required this.onOpenStorage,
    required this.onOpenSettings,
  });

  final ConnectionViewModel connection;
  final VoidCallback onOpenHistory;
  final VoidCallback onOpenStorage;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final endpoint = connection.localInfo?.endpoint;

    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppDimens.pagePadding,
        14,
        AppDimens.pagePadding,
        14,
      ),
      child: Row(
        children: [
          StatusChip(status: connection.status),
          if (connection.isConnected) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: connection.disconnect,
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('断开'),
            ),
          ],
          const Spacer(),
          PressableScale(
            onTap: endpoint == null ? null : () => _copyEndpoint(context, endpoint),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(AppDimens.radiusPill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    endpoint ?? '获取中…',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textPrimary,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.copy_rounded,
                      size: 15, color: AppColors.textSecondary),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          PressableScale(
            onTap: onOpenHistory,
            child: _HeaderButton(icon: Icons.history_rounded),
          ),
          const SizedBox(width: 10),
          PressableScale(
            onTap: onOpenStorage,
            child: _HeaderButton(icon: Icons.storage_rounded),
          ),
          const SizedBox(width: 10),
          PressableScale(
            onTap: onOpenSettings,
            child: _HeaderButton(icon: Icons.settings_outlined),
          ),
        ],
      ),
    );
  }

  Future<void> _copyEndpoint(BuildContext context, String endpoint) async {
    await Clipboard.setData(ClipboardData(text: endpoint));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已复制本机地址：$endpoint'),
          duration: const Duration(seconds: 2),
        ),
      );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, size: 18, color: AppColors.textPrimary),
    );
  }
}

/// 状态栏下的说明行。
class ChatSubtitle extends StatelessWidget {
  const ChatSubtitle({super.key, required this.connection});

  final ConnectionViewModel connection;

  @override
  Widget build(BuildContext context) {
    final text = connection.isConnected
        ? '已与 ${connection.remoteName ?? '对方'} 建立直连 · 一次只连接一台设备'
        : '在同一局域网打开 Mova，设备会自动出现在这里';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.pagePadding,
        12,
        AppDimens.pagePadding,
        12,
      ),
      child: Text(
        text,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
      ),
    );
  }
}

/// 连接状态徽章（设计稿：未连接灰点呼吸 / 连接中蓝 / 已连接绿 + 脉冲）。
class StatusChip extends StatefulWidget {
  const StatusChip({super.key, required this.status});

  final ConnectionStatus status;

  @override
  State<StatusChip> createState() => _StatusChipState();
}

class _StatusChipState extends State<StatusChip> {
  @override
  Widget build(BuildContext context) {
    final (text, color, breathing) = switch (widget.status) {
      ConnectionStatus.connected => ('已连接', AppColors.success, false),
      ConnectionStatus.connecting => ('连接中', AppColors.connecting, false),
      ConnectionStatus.disconnected => ('未连接', AppColors.idle, true),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppDimens.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(color: color, breathing: breathing),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 状态点：未连接呼吸；连接成功时向外扩散一圈涟漪。
class StatusDot extends StatefulWidget {
  const StatusDot({super.key, required this.color, required this.breathing});

  final Color color;
  final bool breathing;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: AppMotion.medium,
  );

  @override
  void didUpdateWidget(StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 连接建立：绿点向外扩散一圈涟漪后消失（设计稿「连接成功脉冲」）。
    if (widget.color == AppColors.success &&
        oldWidget.color != AppColors.success) {
      _pulse.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const size = 8.0;

    final dot = widget.breathing
        ? BreathingDot(color: widget.color, size: size)
        : Container(
            width: size,
            height: size,
            decoration:
                BoxDecoration(color: widget.color, shape: BoxShape.circle),
          );

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          dot,
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              final t = _pulse.value;
              if (t == 0 || t == 1) return const SizedBox.shrink();
              return Positioned(
                left: -size * t,
                top: -size * t,
                child: IgnorePointer(
                  child: Container(
                    width: size * (1 + 2 * t),
                    height: size * (1 + 2 * t),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.success.withValues(alpha: 0.35 * (1 - t)),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 接收保存位置（已连接时显示在输入栏上方，可点击修改）。
class SaveDirectoryLine extends StatelessWidget {
  const SaveDirectoryLine({super.key, required this.transfer});

  final TransferViewModel transfer;

  @override
  Widget build(BuildContext context) {
    final directory = transfer.saveDirectory;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.pagePadding,
        0,
        AppDimens.pagePadding,
        4,
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined,
              size: 13, color: AppColors.textSecondary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '接收到：${directory ?? '获取中…'}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          GestureDetector(
            onTap: transfer.chooseSaveDirectory,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.edit_outlined,
                  size: 13, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 传输失败时的提示条（权限类问题额外给出系统设置入口）。
class TransferErrorBar extends StatelessWidget {
  const TransferErrorBar({super.key, required this.transfer});

  final TransferViewModel transfer;

  @override
  Widget build(BuildContext context) {
    final message = transfer.errorMessage;
    if (message == null) return const SizedBox.shrink();

    return ErrorNoticeBar(
      message: message,
      onDismiss: transfer.dismissError,
      hint: transfer.isPermissionError ? _permissionHint : null,
      actions: transfer.isPermissionError
          ? <ErrorAction>[
              ErrorAction(
                label: '打开系统设置',
                onTap: transfer.openFileAccessSettings,
              ),
              ErrorAction(
                label: '换个保存位置',
                onTap: transfer.chooseSaveDirectory,
              ),
            ]
          : const <ErrorAction>[],
    );
  }
}

const String _permissionHint = '这是系统权限拦截，不是应用设置能解决的：'
    'macOS 请到「系统设置 → 隐私与安全性 → 文件与文件夹」允许 mova；'
    'Windows 请检查杀毒/安全软件是否拦截了写入。也可以直接换一个保存位置。';
