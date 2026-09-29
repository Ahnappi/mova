import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../config/app_config.dart';
import '../../../domain/models/settings/app_settings.dart';
import '../../theme/app_motion_widgets.dart';
import '../../theme/app_theme.dart';
import '../view_models/settings_view_model.dart';

/// 打开「设置」弹窗（缩放 0.96→1 进场，与「数据存放位置」一致）。
Future<void> showSettingsDialog(BuildContext context) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: Colors.black.withValues(alpha: 0.28),
    transitionDuration: AppMotion.dialogIn,
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppMotion.curve,
        reverseCurve: AppMotion.curve,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          child: child,
        ),
      );
    },
    pageBuilder: (_, _, _) => const SettingsDialog(),
  );
}

/// 设置弹窗（View 层）：设备名 / 连接记录保留期限 / 发送前确认。
class SettingsDialog extends StatelessWidget {
  const SettingsDialog({super.key});

  @override
  Widget build(BuildContext context) {
    // 这里直接读 Provider 树上的 ViewModel：它在依赖装配时就
    // 已经 `load()` 过，弹窗不需要再各自读一次盘。
    final vm = context.watch<SettingsViewModel>();

    return Dialog(
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 16, 14),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '设置',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          '只影响本机，不会同步给对方',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  PressableScale(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: const BoxDecoration(
                        color: AppColors.surfaceMuted,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close_rounded, size: 18),
                    ),
                  ),
                ],
              ),
            ),
            if (vm.errorMessage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                child: Text(
                  vm.errorMessage!,
                  style: const TextStyle(
                    color: AppColors.danger,
                    fontSize: 12,
                  ),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: vm.isLoading
                  ? const Center(
                      child: Text(
                        '正在读取…',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(24, 6, 24, 8),
                      children: [
                        _DeviceNameSection(vm: vm),
                        const Divider(height: 32),
                        _RetentionSection(vm: vm),
                        const Divider(height: 32),
                        _ConfirmSendSection(vm: vm),
                        const SizedBox(height: 8),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 设备名：局域网里别人看到的那个名字。
class _DeviceNameSection extends StatefulWidget {
  const _DeviceNameSection({required this.vm});

  final SettingsViewModel vm;

  @override
  State<_DeviceNameSection> createState() => _DeviceNameSectionState();
}

class _DeviceNameSectionState extends State<_DeviceNameSection> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.vm.deviceNameForInput);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _controller.text;
    FocusScope.of(context).unfocus();
    final vm = widget.vm;
    await vm.setDeviceName(value);
    if (!mounted) return;
    // 存的是「用户填了什么」，界面把它再显示一遍（空则退回主机名）。
    _controller.text = vm.deviceNameForInput;
    _showSnack(vm.lastMessage ?? '设备名已保存');
    vm.clearMessage();
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(title: '设备名称'),
        const SizedBox(height: 6),
        const Text(
          '其它设备搜索时会看到这个名字；留空则使用主机名。',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                maxLength: AppConfig.maxDeviceNameLength,
                buildCounter: (_,
                        {required currentLength, required isFocused, maxLength}) =>
                    null,
                decoration: InputDecoration(
                  hintText: vm.defaultDeviceName,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
                style: const TextStyle(fontSize: 14),
                onSubmitted: (_) => _save(),
              ),
            ),
            const SizedBox(width: 10),
            PressableScale(
              onTap: _save,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                ),
                child: const Text(
                  '保存',
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
        const SizedBox(height: 10),
        Text(
          '当前广播给对方的名字：${_effectiveName(vm)}',
          style: const TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  String _effectiveName(SettingsViewModel vm) =>
      vm.deviceName.isEmpty ? vm.defaultDeviceName : vm.deviceName;
}

/// 连接记录保留期限。
class _RetentionSection extends StatelessWidget {
  const _RetentionSection({required this.vm});

  final SettingsViewModel vm;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(title: '连接记录保留期限'),
        const SizedBox(height: 6),
        const Text(
          '到期的记录在下次启动或修改设置时清理；当前正在进行的会话不会被清理。'
          '已接收到的文件不会因此被删除。',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final days in AppConfig.historyRetentionOptions)
              _RetentionChip(
                label: retentionLabel(days),
                selected: vm.retentionDays == days,
                onTap: () async {
                  await vm.setRetentionDays(days);
                  if (!context.mounted) return;
                  final message = vm.lastMessage;
                  if (message == null) return;
                  vm.clearMessage();
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      SnackBar(
                        content: Text(message),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _RetentionChip extends StatelessWidget {
  const _RetentionChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.background,
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
          borderRadius: BorderRadius.circular(AppDimens.radiusPill),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : AppColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// 发送前确认开关。
class _ConfirmSendSection extends StatelessWidget {
  const _ConfirmSendSection({required this.vm});

  final SettingsViewModel vm;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: const _SectionTitle(title: '发送文件前先确认'),
      subtitle: const Text(
        '打开后，选择文件或把文件拖进窗口都会先弹一次确认；'
        '关闭则直接发送。',
        style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
      ),
      value: vm.confirmBeforeSend,
      activeThumbColor: AppColors.primary,
      onChanged: (value) => vm.setConfirmBeforeSend(value),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    );
  }
}
