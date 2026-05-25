import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../theme/app_theme.dart';

/// Bottom composer: image button, multi-line text field, send button.
class ChatInputBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final VoidCallback onPickImage;

  const ChatInputBar({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onSend,
    required this.onPickImage,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
        child: GlassPanel(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              GlassIconButton(
                size: 38,
                icon: const Icon(Icons.image_outlined, color: AppColors.onGlass),
                onPressed: onPickImage,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: GlassTextField(
                  controller: controller,
                  placeholder: 'Сообщение…',
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onChanged: onChanged,
                  onSubmitted: (_) => onSend(),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                ),
              ),
              const SizedBox(width: 6),
              GlassIconButton(
                size: 42,
                icon: const Icon(Icons.send_rounded, color: AppColors.onGlass),
                onPressed: onSend,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Floating "@someone is typing" chip shown above the composer.
class TypingChip extends StatelessWidget {
  final int peerCount;
  const TypingChip({super.key, required this.peerCount});

  @override
  Widget build(BuildContext context) {
    if (peerCount == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: GlassChip(
          label: peerCount == 1 ? 'печатает…' : '$peerCount печатают…',
          icon: const Icon(Icons.more_horiz,
              size: 14, color: AppColors.onGlassMuted),
        ),
      ),
    );
  }
}
