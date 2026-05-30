import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../theme/app_theme.dart';

/// F1: data for the dismissable quoted-preview strip shown above the composer.
class ReplyPreview {
  final String sender;
  final String snippet;
  const ReplyPreview({required this.sender, required this.snippet});
}

/// Bottom composer: image button, mic (voice) button, multi-line text field,
/// send button, plus an optional reply-preview strip (F1) and a recording
/// overlay (F11).
class ChatInputBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final VoidCallback onPickImage;

  // F1 reply preview.
  final ReplyPreview? replyPreview;
  final VoidCallback? onCancelReply;

  // F11 voice messages.
  final VoidCallback? onStartRecording;
  final VoidCallback? onStopRecording;
  final VoidCallback? onCancelRecording;
  final bool recording;
  final Duration recordElapsed;

  const ChatInputBar({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onSend,
    required this.onPickImage,
    this.replyPreview,
    this.onCancelReply,
    this.onStartRecording,
    this.onStopRecording,
    this.onCancelRecording,
    this.recording = false,
    this.recordElapsed = Duration.zero,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
        child: GlassPanel(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (replyPreview != null) _replyStrip(),
              recording ? _recordingRow() : _composerRow(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _replyStrip() => Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 4, right: 4),
        child: Row(
          children: [
            const Icon(Icons.reply, size: 16, color: AppColors.onGlassMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    replyPreview!.sender,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.onGlassMuted,
                    ),
                  ),
                  Text(
                    replyPreview!.snippet,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.onGlassDim,
                    ),
                  ),
                ],
              ),
            ),
            GlassIconButton(
              size: 28,
              icon: const Icon(Icons.close,
                  color: AppColors.onGlassMuted, size: 16),
              onPressed: onCancelReply,
            ),
          ],
        ),
      );

  Widget _composerRow() => Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          GlassIconButton(
            size: 38,
            icon: const Icon(Icons.image_outlined, color: AppColors.onGlass),
            onPressed: onPickImage,
          ),
          const SizedBox(width: 4),
          GlassIconButton(
            size: 38,
            icon: const Icon(Icons.mic_none, color: AppColors.onGlass),
            onPressed: onStartRecording,
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
          ),
          const SizedBox(width: 6),
          GlassIconButton(
            size: 42,
            icon: const Icon(Icons.send, color: AppColors.onGlass),
            glowColor: AppColors.accent,
            onPressed: onSend,
          ),
        ],
      );

  Widget _recordingRow() {
    final s = recordElapsed.inSeconds;
    final mm = (s ~/ 60).toString();
    final ss = (s % 60).toString().padLeft(2, '0');
    return Row(
      children: [
        GlassIconButton(
          size: 38,
          icon: const Icon(Icons.delete_outline, color: AppColors.danger),
          onPressed: onCancelRecording,
        ),
        const SizedBox(width: 10),
        const Icon(Icons.fiber_manual_record,
            color: AppColors.danger, size: 14),
        const SizedBox(width: 8),
        Text(
          '$mm:$ss',
          style: const TextStyle(
            color: AppColors.onGlass,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const Spacer(),
        const Text(
          'запись…',
          style: TextStyle(color: AppColors.onGlassDim, fontSize: 12),
        ),
        const SizedBox(width: 10),
        GlassIconButton(
          size: 42,
          icon: const Icon(Icons.send, color: AppColors.onGlass),
          glowColor: AppColors.accent,
          onPressed: onStopRecording,
        ),
      ],
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
