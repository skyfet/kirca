import '../../storage/cache.dart';

/// Source of a row rendered in the chat list.
enum ChatRowKind { server, pending }

/// A pending (locally-optimistic) message awaiting its server echo.
class PendingMessage {
  final String clientId;
  final String text;
  final int createdAt;
  CachedAttachment? attachment;
  PendingMessage({
    required this.clientId,
    required this.text,
    required this.createdAt,
    this.attachment,
  });
}

/// View model for one bubble in the chat ListView. Folds the two sources of
/// messages (cached server rows + locally-pending sends) into a single shape
/// so the renderer doesn't branch on origin for every field it touches.
class ChatRow {
  final ChatRowKind kind;
  final String userId;
  final String username;
  final String text;
  final int createdAt;
  final bool edited;
  final bool deleted;
  final CachedAttachment? attachment;
  final CachedMessage? serverMsg;

  const ChatRow._({
    required this.kind,
    required this.userId,
    required this.username,
    required this.text,
    required this.createdAt,
    required this.edited,
    required this.deleted,
    required this.attachment,
    required this.serverMsg,
  });

  factory ChatRow.server(CachedMessage m) => ChatRow._(
        kind: ChatRowKind.server,
        userId: m.userId,
        username: m.username,
        text: m.text,
        createdAt: m.createdAt,
        edited: m.editedAt != null,
        deleted: m.deletedAt != null,
        attachment: m.attachment,
        serverMsg: m,
      );

  factory ChatRow.pending(PendingMessage p, String userId, String username) =>
      ChatRow._(
        kind: ChatRowKind.pending,
        userId: userId,
        username: username,
        text: p.text,
        createdAt: p.createdAt,
        edited: false,
        deleted: false,
        attachment: p.attachment,
        serverMsg: null,
      );

  bool get isPending => kind == ChatRowKind.pending;
}
