import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../domain/models/chat/peer.dart';
import '../../theme/app_motion_widgets.dart';
import '../../theme/app_theme.dart';
import '../view_models/connection_view_model.dart';
import 'error_notice_bar.dart';

/// 未连接时展示：设备卡片列表 + 搜索中 + 手动直连折叠区。
class DiscoverySection extends StatelessWidget {
  const DiscoverySection({
    super.key,
    required this.connection,
    required this.ipController,
    required this.manualOpen,
    required this.onToggleManual,
    required this.onConnectManual,
  });

  final ConnectionViewModel connection;
  final TextEditingController ipController;
  final bool manualOpen;
  final VoidCallback onToggleManual;
  final VoidCallback onConnectManual;

  @override
  Widget build(BuildContext context) {
    final peers = connection.peers;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.pagePadding,
        8,
        AppDimens.pagePadding,
        16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '附近设备',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              if (connection.isDiscovering)
                PressableScale(
                  onTap: connection.stopDiscovery,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      children: [
                        Icon(Icons.stop_rounded,
                            size: 15, color: AppColors.textSecondary),
                        SizedBox(width: 4),
                        Text(
                          '停止搜索',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (connection.errorMessage != null)
            ConnectionErrorBar(connection: connection),
          // 未开启搜索：给一个明确入口，默认不在后台持续扫描。
          if (!connection.isDiscovering)
            const _DiscoveryIdleHint()
          else ...[
            for (var i = 0; i < peers.length; i++)
              Entrance(
                delay: AppMotion.stagger * i,
                child: DeviceCard(
                  peer: peers[i],
                  onConnect: () => connection.connectToPeer(peers[i]),
                ),
              ),
            if (peers.isEmpty)
              const SearchingRow(text: '正在搜索附近的设备…')
            else
              const SearchingRow(text: '正在搜索更多设备…'),
          ],
          const SizedBox(height: 6),
          ManualConnect(
            ipController: ipController,
            open: manualOpen,
            onToggle: onToggleManual,
            onConnect: onConnectManual,
          ),
        ],
      ),
    );
  }
}

/// 连接/搜索阶段的错误：可复制，且权限类问题直接给系统设置入口。
///
/// 局域网互传最常见的拦路虎是「本地网络」授权与防火墙，这类问题用户
/// 在应用里点什么都没用，必须去系统设置里放行，所以这里把入口给出来。
class ConnectionErrorBar extends StatelessWidget {
  const ConnectionErrorBar({super.key, required this.connection});

  final ConnectionViewModel connection;

  @override
  Widget build(BuildContext context) {
    final message = connection.errorMessage;
    if (message == null) return const SizedBox.shrink();

    return ErrorNoticeBar(
      message: message,
      onDismiss: connection.dismissError,
      hint: connection.isPermissionError ? _permissionHint : null,
      actions: connection.isPermissionError
          ? <ErrorAction>[
              ErrorAction(
                label: '打开网络设置',
                onTap: connection.openNetworkSettings,
              ),
              ErrorAction(
                label: '打开防火墙设置',
                onTap: connection.openFirewallSettings,
              ),
            ]
          : const <ErrorAction>[],
    );
  }
}

const String _permissionHint = '这通常是系统拦住了局域网访问：'
    'macOS 请到「系统设置 → 隐私与安全性 → 本地网络」允许 mova；'
    'Windows 请允许 mova 通过防火墙（专用网络也要放行）。';

/// 单个设备卡片。
class DeviceCard extends StatelessWidget {
  const DeviceCard({super.key, required this.peer, required this.onConnect});

  final Peer peer;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(AppDimens.radiusCard),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.monitor_outlined,
                  size: 20, color: AppColors.textPrimary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    peer.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    peer.ip,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            PressableScale(
              onTap: onConnect,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                ),
                child: const Text(
                  '连接',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 未开启搜索时的占位卡片：只给入口，不自动扫描。
class _DiscoveryIdleHint extends StatelessWidget {
  const _DiscoveryIdleHint();

  @override
  Widget build(BuildContext context) {
    final connection = context.read<ConnectionViewModel>();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppDimens.radiusCard),
      ),
      child: Row(
        children: [
          const Icon(Icons.wifi_tethering_off_rounded,
              size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              '未开启设备搜索。你也可以直接在下方手动输入对方 IP 直连。',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 12),
          PressableScale(
            onTap: connection.startDiscovery,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(AppDimens.radiusPill),
              ),
              child: const Text(
                '开始搜索',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「正在搜索…」灰底行。
class SearchingRow extends StatelessWidget {
  const SearchingRow({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppDimens.radiusCard),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            text,
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

/// 「手动直连 IP:端口」折叠区（展开高度 0→auto，箭头旋转 90°）。
class ManualConnect extends StatelessWidget {
  const ManualConnect({
    super.key,
    required this.ipController,
    required this.open,
    required this.onToggle,
    required this.onConnect,
  });

  final TextEditingController ipController;
  final bool open;
  final VoidCallback onToggle;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PressableScale(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedRotation(
                  turns: open ? 0.25 : 0,
                  duration: AppMotion.quick,
                  curve: AppMotion.curve,
                  child: const Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 4),
                const Text(
                  '手动直连 IP:端口',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        // 高度 0 → auto：用 ClipRect + AnimatedAlign 近似设计稿的展开动效。
        ClipRect(
          child: AnimatedAlign(
            alignment: Alignment.topLeft,
            heightFactor: open ? 1 : 0,
            duration: AppMotion.quick,
            curve: AppMotion.curve,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, left: 24),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: ipController,
                      decoration: const InputDecoration(
                        hintText: '输入 IP 或 IP:端口',
                      ),
                      onSubmitted: (_) => onConnect(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PressableScale(
                    onTap: onConnect,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 11),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius:
                            BorderRadius.circular(AppDimens.radiusPill),
                      ),
                      child: const Text(
                        '连接',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
