import 'package:flutter/material.dart';

import '../../theme/app_motion_widgets.dart';
import '../../theme/app_theme.dart';

/// 输入栏：回形针选文件 + 圆角输入框 + 圆形发送按钮。
class InputBar extends StatefulWidget {
  const InputBar({
    super.key,
    required this.messageController,
    required this.enabled,
    required this.onSend,
    required this.onPickFiles,
  });

  final TextEditingController messageController;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onPickFiles;

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.messageController.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final hasText = widget.messageController.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  @override
  void dispose() {
    widget.messageController.removeListener(_onTextChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canSend = widget.enabled && _hasText;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(AppDimens.radiusPill),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: IconButton(
                      tooltip: '发送文件',
                      onPressed: widget.enabled ? widget.onPickFiles : null,
                      icon: const Icon(Icons.attach_file_rounded,
                          size: 20, color: AppColors.textPrimary),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: widget.messageController,
                      enabled: widget.enabled,
                      onSubmitted: (_) => canSend ? widget.onSend() : null,
                      decoration: const InputDecoration(
                        hintText: '输入消息，或把文件拖进来',
                        border: InputBorder.none,
                        filled: false,
                        contentPadding: EdgeInsets.zero,
                      ),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          PressableScale(
            onTap: canSend ? widget.onSend : null,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: canSend ? AppColors.primary : AppColors.surfaceMuted,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.arrow_upward_rounded,
                size: 22,
                color: canSend ? Colors.white : AppColors.idle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
