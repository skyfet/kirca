import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'attachment_image.dart';
import 'chat_row.dart';

/// One message bubble. Pure rendering — selection / actions are wired by the
/// parent through [onLongPress]. The bubble itself never reads providers.
class MessageBubble extends StatelessWidget {
  final ChatRow row;
  final bool mine;
  final String roomId;
  final bool e2e;
  final String token;
  final VoidCallback? onLongPress;

  const MessageBubble({
    super.key,
    required this.row,
    required this.mine,
    required this.roomId,
    required this.e2e,
    required this.token,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.of(context).size.width * 0.75;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxW),
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: _decoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!mine && row.username.isNotEmpty) _authorLine(),
          if (row.attachment != null) _attachment(),
          if (row.deleted) const _DeletedNotice()
          else if (row.text.isNotEmpty) _body(),
          _footer(),
        ],
      ),
    );

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(onLongPress: onLongPress, child: bubble),
    );
  }

  BoxDecoration _decoration() => BoxDecoration(
        gradient: mine
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xCC6E6BFF), Color(0xCCB46CFF)],
              )
            : null,
        color: mine ? null : const Color(0x1FFFFFFF),
        border: Border.all(color: const Color(0x33FFFFFF), width: 0.5),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(mine ? 16 : 4),
          bottomRight: Radius.circular(mine ? 4 : 16),
        ),
      );

  Widget _authorLine() => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(
          row.username,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.onGlassMuted,
          ),
        ),
      );

  Widget _attachment() => Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: AttachmentImage(
            attachment: row.attachment!,
            e2e: e2e,
            roomId: roomId,
            token: token,
          ),
        ),
      );

  Widget _body() => Text(
        row.text,
        style: const TextStyle(color: AppColors.onGlass, height: 1.3),
      );

  Widget _footer() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (row.edited && !row.deleted)
            const Padding(
              padding: EdgeInsets.only(top: 2, right: 6),
              child: Text(
                'изменено',
                style: TextStyle(fontSize: 10, color: AppColors.onGlassDim),
              ),
            ),
          if (mine)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                row.isPending ? Icons.access_time : Icons.done_all,
                size: 12,
                color: AppColors.onGlassDim,
              ),
            ),
        ],
      );
}

class _DeletedNotice extends StatelessWidget {
  const _DeletedNotice();
  @override
  Widget build(BuildContext context) => const Text(
        'сообщение удалено',
        style: TextStyle(
          fontStyle: FontStyle.italic,
          color: AppColors.onGlassDim,
        ),
      );
}
