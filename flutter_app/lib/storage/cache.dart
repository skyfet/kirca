import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'db.dart';

// ---- models ----------------------------------------------------------------

/// Aggregated reaction bucket for a single emoji on a message.
class MessageReaction {
  final String emoji;
  final int count;
  final bool mine;
  const MessageReaction({
    required this.emoji,
    required this.count,
    required this.mine,
  });

  factory MessageReaction.fromJson(Map<String, dynamic> j) => MessageReaction(
        emoji: j['emoji']?.toString() ?? '',
        count: (j['count'] as num?)?.toInt() ?? 0,
        mine: j['mine'] == true,
      );

  Map<String, dynamic> toJson() => {
        'emoji': emoji,
        'count': count,
        'mine': mine,
      };
}

class CachedAttachment {
  final String? id;
  final String? url;
  final String mime;
  final int? width;
  final int? height;
  // E2E wrapping fields. Non-null only on E2E attachments. The bytes at [url]
  // (or behind /attachments/:id) are AES-GCM ciphertext; the client decrypts
  // using the per-blob key unwrapped from [wrappedKey] under the room key.
  final String? wrappedKey;
  final String? wrappedKeyIv;
  final String? iv;
  final int? keyVersion;
  // F10/F11: BlurHash placeholder for images, duration for voice/audio blobs.
  final String? blurhash;
  final int? durationMs;
  const CachedAttachment({
    this.id,
    this.url,
    required this.mime,
    this.width,
    this.height,
    this.wrappedKey,
    this.wrappedKeyIv,
    this.iv,
    this.keyVersion,
    this.blurhash,
    this.durationMs,
  });

  bool get isE2e => wrappedKey != null;
}

class CachedMessage {
  final String id;
  final String roomId;
  final String? clientId;
  final String userId;
  final String username;
  /// Plaintext for the bubble. For E2E rooms this is the decrypted form (set
  /// after the chat screen decodes ciphertext) — empty until decryption runs.
  final String text;
  final int createdAt;
  final int? editedAt;
  final int? deletedAt;
  final CachedAttachment? attachment;
  // E2E fields. Set on E2E rooms; null on plain rooms.
  final String? ciphertext;
  final String? iv;
  final int? keyVersion;
  // F1 reply / F2 forward / F3 mentions / F4 reactions metadata.
  final String? replyToId;
  final List<String>? mentions;
  final String? forwardedFromRoomId;
  final String? forwardedFromMsgId;
  final String? forwardedFromUsername;
  final List<MessageReaction> reactions;

  const CachedMessage({
    required this.id,
    required this.roomId,
    this.clientId,
    required this.userId,
    required this.username,
    required this.text,
    required this.createdAt,
    this.editedAt,
    this.deletedAt,
    this.attachment,
    this.ciphertext,
    this.iv,
    this.keyVersion,
    this.replyToId,
    this.mentions,
    this.forwardedFromRoomId,
    this.forwardedFromMsgId,
    this.forwardedFromUsername,
    this.reactions = const [],
  });

  bool get isE2e => ciphertext != null;
  bool get isForwarded => forwardedFromMsgId != null;

  factory CachedMessage.fromRow(Map<String, dynamic> r) {
    final attId = r['attachment_id'] as String?;
    return CachedMessage(
      id: r['id'] as String,
      roomId: r['room_id'] as String,
      clientId: r['client_id'] as String?,
      userId: r['user_id'] as String,
      username: r['username'] as String,
      text: (r['text'] as String?) ?? '',
      createdAt: r['created_at'] as int,
      editedAt: r['edited_at'] as int?,
      deletedAt: r['deleted_at'] as int?,
      attachment: attId == null
          ? null
          : CachedAttachment(
              id: attId,
              url: r['attachment_url'] as String?,
              mime: (r['attachment_mime'] as String?) ?? 'image/*',
              width: r['attachment_width'] as int?,
              height: r['attachment_height'] as int?,
              wrappedKey: r['attachment_wrapped_key'] as String?,
              wrappedKeyIv: r['attachment_wrapped_key_iv'] as String?,
              iv: r['attachment_iv'] as String?,
              keyVersion: r['attachment_key_version'] as int?,
              blurhash: r['attachment_blurhash'] as String?,
              durationMs: r['attachment_duration_ms'] as int?,
            ),
      ciphertext: r['ciphertext'] as String?,
      iv: r['iv'] as String?,
      keyVersion: r['key_version'] as int?,
      replyToId: r['reply_to_id'] as String?,
      mentions: _decodeStringList(r['mentions'] as String?),
      forwardedFromRoomId: r['forwarded_from_room_id'] as String?,
      forwardedFromMsgId: r['forwarded_from_msg_id'] as String?,
      forwardedFromUsername: r['forwarded_from_username'] as String?,
      reactions: _decodeReactions(r['reactions'] as String?),
    );
  }

  static List<String>? _decodeStringList(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return list.map((e) => e.toString()).toList(growable: false);
      }
    } catch (_) {}
    return null;
  }

  static List<MessageReaction> _decodeReactions(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return list
            .whereType<Map>()
            .map((e) => MessageReaction.fromJson(e.cast<String, dynamic>()))
            .where((r) => r.emoji.isNotEmpty && r.count > 0)
            .toList(growable: false);
      }
    } catch (_) {}
    return const [];
  }
}

class CachedRoom {
  final String id;
  final String name;
  final bool isPublic;
  final bool isMember;
  final String role;
  final int unread;
  final String? lastText;
  final int? lastAt;
  final bool e2e;
  final int keyVersion;
  // F5 pin / F6 archive / F7 mute-with-ttl / F8 DM rooms.
  final bool pinned;
  final bool archived;
  /// null = not muted; 0 = muted forever; >0 = muted until this epoch-ms.
  final int? mutedUntil;
  final String kind; // 'group' | 'dm'
  final String? dmPeerId;

  /// [muted] is a backwards-compatible convenience: when true (and no explicit
  /// [mutedUntil] given) it sets `mutedUntil = 0` (muted forever). Prefer
  /// passing [mutedUntil] directly.
  CachedRoom({
    required this.id,
    required this.name,
    required this.isPublic,
    required this.isMember,
    required this.role,
    required this.unread,
    this.lastText,
    this.lastAt,
    this.e2e = false,
    this.keyVersion = 0,
    this.pinned = false,
    this.archived = false,
    int? mutedUntil,
    bool muted = false,
    this.kind = 'group',
    this.dmPeerId,
  }) : mutedUntil = mutedUntil ?? (muted ? 0 : null);

  /// Backwards-compatible muted getter. A room counts as muted whenever a
  /// `muted_until` is set (0 = forever, or any future timestamp). We treat a
  /// past timestamp as still "muted" too so the flag survives until the row is
  /// refreshed — the server is the source of truth for expiry.
  bool get muted => mutedUntil != null;

  bool get isDm => kind == 'dm';

  factory CachedRoom.fromRow(Map<String, dynamic> r) => CachedRoom(
        id: r['id'] as String,
        name: r['name'] as String,
        isPublic: (r['is_public'] as int) == 1,
        isMember: (r['is_member'] as int? ?? 0) == 1,
        role: (r['role'] as String?) ?? '',
        unread: r['unread'] as int? ?? 0,
        lastText: r['last_text'] as String?,
        lastAt: r['last_at'] as int?,
        e2e: (r['e2e'] as int? ?? 0) == 1,
        keyVersion: r['key_version'] as int? ?? 0,
        pinned: (r['pinned'] as int? ?? 0) == 1,
        archived: (r['archived'] as int? ?? 0) == 1,
        mutedUntil: r['muted_until'] as int?,
        kind: (r['kind'] as String?) ?? 'group',
        dmPeerId: r['dm_peer_id'] as String?,
      );
}

class CachedMember {
  final String userId;
  final String username;
  final String? displayName;
  final String? avatarUrl;
  final String role;
  final bool online;

  const CachedMember({
    required this.userId,
    required this.username,
    this.displayName,
    this.avatarUrl,
    required this.role,
    required this.online,
  });

  factory CachedMember.fromRow(Map<String, dynamic> r) => CachedMember(
        userId: r['user_id'] as String,
        username: r['username'] as String,
        displayName: r['display_name'] as String?,
        avatarUrl: r['avatar_url'] as String?,
        role: (r['role'] as String?) ?? '',
        online: (r['online'] as int? ?? 0) == 1,
      );
}

class CachedInvite {
  final String id;
  final String roomId;
  final String roomName;
  final String? inviterId;
  final String? inviterUsername;
  final String? inviterDisplayName;
  final int createdAt;

  const CachedInvite({
    required this.id,
    required this.roomId,
    required this.roomName,
    this.inviterId,
    this.inviterUsername,
    this.inviterDisplayName,
    required this.createdAt,
  });

  factory CachedInvite.fromRow(Map<String, dynamic> r) => CachedInvite(
        id: r['id'] as String,
        roomId: r['room_id'] as String,
        roomName: r['room_name'] as String,
        inviterId: r['inviter_id'] as String?,
        inviterUsername: r['inviter_username'] as String?,
        inviterDisplayName: r['inviter_display_name'] as String?,
        createdAt: r['created_at'] as int,
      );
}

// ---- caches ----------------------------------------------------------------
// SQLite не умеет триггеров на уровне sqflite, поэтому каждый write вызывает
// notify() вручную — стримы получают свежий снимок.

class _Notifier<K> {
  final _ctrls = <K, StreamController<void>>{};

  Stream<void> watch(K key) {
    final c = _ctrls[key] ??= StreamController<void>.broadcast();
    return c.stream;
  }

  void notify(K key) {
    _ctrls[key]?.add(null);
  }

  void disposeAll() {
    for (final c in _ctrls.values) {
      c.close();
    }
    _ctrls.clear();
  }
}

// ---- rooms ----------------------------------------------------------------

class RoomsCache {
  static final _notifier = _Notifier<int>();
  static const _key = 0;

  static Stream<List<CachedRoom>> watch() async* {
    yield await snapshot();
    await for (final _ in _notifier.watch(_key)) {
      yield await snapshot();
    }
  }

  static Future<List<CachedRoom>> snapshot() async {
    final db = await AppDb.open();
    final rows = await db.query('rooms', orderBy: 'updated_at DESC');
    return rows.map(CachedRoom.fromRow).toList(growable: false);
  }

  /// Полностью переписать список (после успешного GET /rooms).
  ///
  /// [currentUserId] is used to resolve a DM room's `dm_key` ("minId:maxId")
  /// to the *other* user; pass it whenever available so DM rows carry a usable
  /// `dm_peer_id`.
  static Future<void> replaceAll(
    List<Map<String, dynamic>> serverRooms, {
    String? currentUserId,
  }) async {
    final db = await AppDb.open();
    await db.transaction((txn) async {
      await txn.delete('rooms');
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final r in serverRooms) {
        await _insertRoomRaw(txn, r, now, currentUserId: currentUserId);
      }
    });
    _notifier.notify(_key);
  }

  /// Resolve a DM room's peer id from a "minId:maxId" dm_key and the current
  /// user id. Returns null when the key is malformed or the current user isn't
  /// part of it.
  static String? peerFromDmKey(String? dmKey, String? currentUserId) {
    if (dmKey == null || currentUserId == null) return null;
    final parts = dmKey.split(':');
    if (parts.length != 2) return null;
    if (parts[0] == currentUserId) return parts[1];
    if (parts[1] == currentUserId) return parts[0];
    return null;
  }

  /// Идемпотентный upsert одной комнаты (например, после createRoom / room_added).
  ///
  /// [dmPeerId] lets the `room_added` handler stash the peer id from the WS
  /// payload directly, since the server-side `dm_key` ("minId:maxId") can't be
  /// resolved to "the other user" without knowing the current user id.
  static Future<void> upsert(Map<String, dynamic> r, {String? dmPeerId}) async {
    final db = await AppDb.open();
    await _insertRoomRaw(db, r, DateTime.now().millisecondsSinceEpoch,
        dmPeerId: dmPeerId);
    _notifier.notify(_key);
  }

  static Future<void> remove(String roomId) async {
    final db = await AppDb.open();
    await db.delete('rooms', where: 'id = ?', whereArgs: [roomId]);
    _notifier.notify(_key);
  }

  static Future<void> setMuted(String roomId, bool muted) async {
    // Legacy entry point: map to the muted_until model (0 = forever, null = off)
    // and keep the legacy `muted` column in sync for any old reader.
    await setMutedUntil(roomId, muted ? 0 : null);
  }

  /// F7: set the mute-until timestamp. null = unmute, 0 = forever, >0 = epoch-ms.
  static Future<void> setMutedUntil(String roomId, int? mutedUntil) async {
    final db = await AppDb.open();
    await db.update(
      'rooms',
      {
        'muted_until': mutedUntil,
        'muted': mutedUntil != null ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [roomId],
    );
    _notifier.notify(_key);
  }

  /// F5: pin / unpin a room.
  static Future<void> setPinned(String roomId, bool pinned) async {
    final db = await AppDb.open();
    await db.update(
      'rooms',
      {'pinned': pinned ? 1 : 0},
      where: 'id = ?',
      whereArgs: [roomId],
    );
    _notifier.notify(_key);
  }

  /// F6: archive / unarchive a room.
  static Future<void> setArchived(String roomId, bool archived) async {
    final db = await AppDb.open();
    await db.update(
      'rooms',
      {'archived': archived ? 1 : 0},
      where: 'id = ?',
      whereArgs: [roomId],
    );
    _notifier.notify(_key);
  }

  static Future<void> setUnread(String roomId, int unread) async {
    final db = await AppDb.open();
    await db.update(
      'rooms',
      {'unread': unread},
      where: 'id = ?',
      whereArgs: [roomId],
    );
    _notifier.notify(_key);
  }

  /// Атомарно увеличить unread на 1 (для нового входящего сообщения).
  static Future<void> bumpUnread(String roomId) async {
    final db = await AppDb.open();
    await db.rawUpdate(
      'UPDATE rooms SET unread = unread + 1 WHERE id = ?',
      [roomId],
    );
    _notifier.notify(_key);
  }

  static Future<void> setLast(String roomId, String text, int at) async {
    final db = await AppDb.open();
    await db.update(
      'rooms',
      {'last_text': text, 'last_at': at, 'updated_at': at},
      where: 'id = ?',
      whereArgs: [roomId],
    );
    _notifier.notify(_key);
  }

  static Future<void> _insertRoomRaw(
    DatabaseExecutor x,
    Map<String, dynamic> r,
    int updatedAt, {
    String? currentUserId,
    String? dmPeerId,
  }) async {
    bool asBool(dynamic v) => (v is num) ? v.toInt() == 1 : v == true;
    final isPub = asBool(r['is_public']);
    final isMember = asBool(r['is_member']);
    final e2e = asBool(r['e2e']);
    final pinned = asBool(r['pinned']);
    final archived = asBool(r['archived']);
    // muted_until is the v5 source of truth. Fall back to a legacy `muted`
    // boolean (=> 0 forever) when only that is present.
    int? mutedUntil;
    if (r.containsKey('muted_until')) {
      mutedUntil = (r['muted_until'] as num?)?.toInt();
    } else if (asBool(r['muted'])) {
      mutedUntil = 0;
    }
    final kind = (r['kind']?.toString().isNotEmpty ?? false)
        ? r['kind'].toString()
        : 'group';
    // Prefer an explicitly-passed peer id (room_added payload); else resolve
    // from dm_key against the current user; else any server-provided field.
    final peerId = dmPeerId ??
        peerFromDmKey(r['dm_key']?.toString(), currentUserId) ??
        r['dm_peer_id']?.toString();
    await x.insert(
      'rooms',
      {
        'id': r['id'].toString(),
        'name': r['name']?.toString() ?? '',
        'is_public': isPub ? 1 : 0,
        'is_member': isMember ? 1 : 0,
        'role': r['role']?.toString(),
        'muted': mutedUntil != null ? 1 : 0,
        'unread': (r['unread'] as num?)?.toInt() ?? 0,
        'last_text': r['last_text']?.toString(),
        'last_at': (r['last_at'] as num?)?.toInt(),
        'updated_at': updatedAt,
        'e2e': e2e ? 1 : 0,
        'key_version': (r['key_version'] as num?)?.toInt() ?? 0,
        'pinned': pinned ? 1 : 0,
        'archived': archived ? 1 : 0,
        'muted_until': mutedUntil,
        'kind': kind,
        'dm_peer_id': peerId,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

// ---- messages -------------------------------------------------------------

class MessagesCache {
  static final _notifier = _Notifier<String>();

  static Stream<List<CachedMessage>> watch(String roomId) async* {
    yield await snapshot(roomId);
    await for (final _ in _notifier.watch(roomId)) {
      yield await snapshot(roomId);
    }
  }

  static Future<List<CachedMessage>> snapshot(String roomId) async {
    final db = await AppDb.open();
    final rows = await db.query(
      'messages',
      where: 'room_id = ?',
      whereArgs: [roomId],
      orderBy: 'created_at ASC',
    );
    return rows.map(CachedMessage.fromRow).toList(growable: false);
  }

  /// Server-confirmed message. Идемпотентно по `id` (PK).
  static Future<void> upsert(String roomId, Map<String, dynamic> m) async {
    final db = await AppDb.open();
    await _insertMsgRaw(db, roomId, m);
    _notifier.notify(roomId);
  }

  static Future<void> upsertAll(
    String roomId,
    List<Map<String, dynamic>> list,
  ) async {
    if (list.isEmpty) return;
    final db = await AppDb.open();
    await db.transaction((txn) async {
      for (final m in list) {
        await _insertMsgRaw(txn, roomId, m);
      }
    });
    _notifier.notify(roomId);
  }

  static Future<void> applyEdit(
    String roomId,
    String id,
    String text,
    int? editedAt,
  ) async {
    final db = await AppDb.open();
    await db.update(
      'messages',
      {'text': text, 'edited_at': editedAt},
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifier.notify(roomId);
  }

  /// Removes the message row entirely. Deleted messages are gone from the
  /// local cache — re-fetching history filters them too (see _insertMsgRaw).
  static Future<void> applyDelete(
    String roomId,
    String id,
    int? deletedAt,
  ) async {
    final db = await AppDb.open();
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
    _notifier.notify(roomId);
  }

  /// Set the decrypted plaintext of an E2E message after the chat screen
  /// has unwrapped it. Leaves the ciphertext columns intact so re-decryption
  /// remains possible if needed.
  static Future<void> setDecryptedText(
    String roomId,
    String id,
    String text,
  ) =>
      setDecryptedMessage(roomId, id, text);

  /// Like [setDecryptedText] but also propagates attachment metadata pulled
  /// from the E2E envelope (blurhash, audio duration). Server never sees
  /// these for E2E rooms — they only land here after a local decrypt.
  static Future<void> setDecryptedMessage(
    String roomId,
    String id,
    String text, {
    String? blurhash,
    int? durationMs,
  }) async {
    final db = await AppDb.open();
    await db.update(
      'messages',
      {
        'text': text,
        if (blurhash != null) 'attachment_blurhash': blurhash,
        if (durationMs != null) 'attachment_duration_ms': durationMs,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifier.notify(roomId);
  }

  static Future<void> _insertMsgRaw(
    DatabaseExecutor x,
    String roomId,
    Map<String, dynamic> m,
  ) async {
    final id = m['id']?.toString();
    if (id == null) return;
    // Server still tombstones deleted messages (`deleted_at` set, text wiped).
    // We treat them as gone client-side — drop any existing row, skip insert.
    final deletedAt = (m['deleted_at'] as num?)?.toInt();
    if (deletedAt != null) {
      await x.delete('messages', where: 'id = ?', whereArgs: [id]);
      return;
    }
    final att = m['attachment'] as Map<String, dynamic>?;
    // Preserve any locally-decrypted plaintext we already cached for this id —
    // server replays its empty `text` field for E2E rows, so blind overwrite
    // would wipe the visible message bubble.
    String text = m['text']?.toString() ?? '';
    final ciphertext = m['ciphertext']?.toString();
    // Preservation pulls locally-decrypted fields forward across server
    // re-syncs (which carry empty text + null attachment metadata for E2E).
    String? preservedBlurhash;
    int? preservedDurationMs;
    if (ciphertext != null) {
      final existing = await x.query(
        'messages',
        columns: ['text', 'attachment_blurhash', 'attachment_duration_ms'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        if (text.isEmpty) {
          final prev = existing.first['text'] as String?;
          if (prev != null && prev.isNotEmpty) text = prev;
        }
        preservedBlurhash = existing.first['attachment_blurhash'] as String?;
        preservedDurationMs =
            (existing.first['attachment_duration_ms'] as num?)?.toInt();
      }
    }
    // mentions: server sends a JSON array (or list); persist as JSON text.
    String? mentionsJson;
    final rawMentions = m['mentions'];
    if (rawMentions is List) {
      mentionsJson = jsonEncode(rawMentions.map((e) => e.toString()).toList());
    } else if (rawMentions is String && rawMentions.isNotEmpty) {
      mentionsJson = rawMentions; // already JSON-encoded
    }
    // reactions: server sends [{emoji,count,mine,user_ids}]; we keep
    // {emoji,count,mine} for rendering.
    String? reactionsJson;
    final rawReactions = m['reactions'];
    if (rawReactions is List) {
      final shaped = rawReactions
          .whereType<Map>()
          .map((e) {
            final r = e.cast<String, dynamic>();
            return {
              'emoji': r['emoji']?.toString() ?? '',
              'count': (r['count'] as num?)?.toInt() ?? 0,
              'mine': r['mine'] == true,
            };
          })
          .where((r) => (r['emoji'] as String).isNotEmpty)
          .toList();
      reactionsJson = shaped.isEmpty ? null : jsonEncode(shaped);
    } else if (rawReactions is String && rawReactions.isNotEmpty) {
      reactionsJson = rawReactions;
    }
    await x.insert(
      'messages',
      {
        'id': id,
        'room_id': roomId,
        'client_id': m['client_id']?.toString(),
        'user_id': m['user_id']?.toString() ?? '',
        'username': m['username']?.toString() ?? '',
        'text': text,
        'created_at': (m['created_at'] as num?)?.toInt() ?? 0,
        'edited_at': (m['edited_at'] as num?)?.toInt(),
        'deleted_at': (m['deleted_at'] as num?)?.toInt(),
        'attachment_id': att?['id']?.toString(),
        'attachment_url': att?['url']?.toString(),
        'attachment_mime': att?['mime']?.toString(),
        'attachment_width': (att?['width'] as num?)?.toInt(),
        'attachment_height': (att?['height'] as num?)?.toInt(),
        'ciphertext': ciphertext,
        'iv': m['iv']?.toString(),
        'key_version': (m['key_version'] as num?)?.toInt(),
        'attachment_wrapped_key': att?['wrapped_key']?.toString(),
        'attachment_wrapped_key_iv': att?['wrapped_key_iv']?.toString(),
        'attachment_iv': att?['iv']?.toString(),
        'attachment_key_version': (att?['key_version'] as num?)?.toInt(),
        'reply_to_id': m['reply_to_id']?.toString(),
        'mentions': mentionsJson,
        'forwarded_from_room_id': m['forwarded_from_room_id']?.toString(),
        'forwarded_from_msg_id': m['forwarded_from_msg_id']?.toString(),
        'forwarded_from_username': m['forwarded_from_username']?.toString(),
        'reactions': reactionsJson,
        'attachment_blurhash':
            att?['blurhash']?.toString() ?? preservedBlurhash,
        'attachment_duration_ms':
            (att?['duration_ms'] as num?)?.toInt() ?? preservedDurationMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// F4: apply a `reaction_add` event (or optimistic local add). Aggregates
  /// the count for [emoji] on message [msgId] and flips `mine` when the actor
  /// is the current user (pass [mine] = true in that case).
  static Future<void> applyReactionAdd(
    String roomId,
    String msgId,
    String userId,
    String emoji, {
    bool mine = false,
  }) async {
    await _mutateReactions(roomId, msgId, (buckets) {
      final i = buckets.indexWhere((b) => b['emoji'] == emoji);
      if (i == -1) {
        buckets.add({'emoji': emoji, 'count': 1, 'mine': mine});
      } else {
        final cur = buckets[i];
        cur['count'] = ((cur['count'] as num?)?.toInt() ?? 0) + 1;
        if (mine) cur['mine'] = true;
      }
    });
  }

  /// F4: apply a `reaction_remove` event (or optimistic local remove).
  static Future<void> applyReactionRemove(
    String roomId,
    String msgId,
    String userId,
    String emoji, {
    bool mine = false,
  }) async {
    await _mutateReactions(roomId, msgId, (buckets) {
      final i = buckets.indexWhere((b) => b['emoji'] == emoji);
      if (i == -1) return;
      final cur = buckets[i];
      final n = ((cur['count'] as num?)?.toInt() ?? 0) - 1;
      if (n <= 0) {
        buckets.removeAt(i);
      } else {
        cur['count'] = n;
        if (mine) cur['mine'] = false;
      }
    });
  }

  static Future<void> _mutateReactions(
    String roomId,
    String msgId,
    void Function(List<Map<String, dynamic>> buckets) mutate,
  ) async {
    final db = await AppDb.open();
    final rows = await db.query(
      'messages',
      columns: ['reactions'],
      where: 'id = ?',
      whereArgs: [msgId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final raw = rows.first['reactions'] as String?;
    final buckets = <Map<String, dynamic>>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map) buckets.add(e.cast<String, dynamic>());
          }
        }
      } catch (_) {}
    }
    mutate(buckets);
    await db.update(
      'messages',
      {'reactions': buckets.isEmpty ? null : jsonEncode(buckets)},
      where: 'id = ?',
      whereArgs: [msgId],
    );
    _notifier.notify(roomId);
  }
}

// ---- members --------------------------------------------------------------

class MembersCache {
  static final _notifier = _Notifier<String>();

  static Stream<List<CachedMember>> watch(String roomId) async* {
    yield await snapshot(roomId);
    await for (final _ in _notifier.watch(roomId)) {
      yield await snapshot(roomId);
    }
  }

  static Future<List<CachedMember>> snapshot(String roomId) async {
    final db = await AppDb.open();
    final rows = await db.query(
      'members',
      where: 'room_id = ?',
      whereArgs: [roomId],
      orderBy: 'username ASC',
    );
    return rows.map(CachedMember.fromRow).toList(growable: false);
  }

  static Future<void> replaceAll(
    String roomId,
    List<Map<String, dynamic>> list,
  ) async {
    final db = await AppDb.open();
    await db.transaction((txn) async {
      await txn.delete('members', where: 'room_id = ?', whereArgs: [roomId]);
      for (final m in list) {
        await _insertRaw(txn, roomId, m);
      }
    });
    _notifier.notify(roomId);
  }

  static Future<void> _insertRaw(
    DatabaseExecutor x,
    String roomId,
    Map<String, dynamic> m,
  ) async {
    await x.insert(
      'members',
      {
        'room_id': roomId,
        'user_id': m['id']?.toString() ?? m['user_id']?.toString() ?? '',
        'username': m['username']?.toString() ?? '',
        'display_name': m['display_name']?.toString(),
        'avatar_url': m['avatar_url']?.toString(),
        'role': m['role']?.toString(),
        'online': m['online'] == true ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

// ---- invites --------------------------------------------------------------

class InvitesCache {
  static final _notifier = _Notifier<int>();
  static const _key = 0;

  static Stream<List<CachedInvite>> watch() async* {
    yield await snapshot();
    await for (final _ in _notifier.watch(_key)) {
      yield await snapshot();
    }
  }

  static Future<List<CachedInvite>> snapshot() async {
    final db = await AppDb.open();
    final rows = await db.query('invites', orderBy: 'created_at DESC');
    return rows.map(CachedInvite.fromRow).toList(growable: false);
  }

  static Future<void> replaceAll(List<Map<String, dynamic>> list) async {
    final db = await AppDb.open();
    await db.transaction((txn) async {
      await txn.delete('invites');
      for (final inv in list) {
        await txn.insert(
          'invites',
          {
            'id': inv['id'].toString(),
            'room_id': inv['room_id']?.toString() ?? '',
            'room_name': inv['room_name']?.toString() ?? '',
            'inviter_id': inv['inviter_id']?.toString(),
            'inviter_username': inv['inviter_username']?.toString(),
            'inviter_display_name': inv['inviter_display_name']?.toString(),
            'created_at':
                (inv['created_at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    _notifier.notify(_key);
  }

  static Future<void> remove(String id) async {
    final db = await AppDb.open();
    await db.delete('invites', where: 'id = ?', whereArgs: [id]);
    _notifier.notify(_key);
  }

  static Future<void> upsert(Map<String, dynamic> inv) async {
    final db = await AppDb.open();
    await db.insert(
      'invites',
      {
        'id': inv['id'].toString(),
        'room_id': inv['room_id']?.toString() ?? '',
        'room_name': inv['room_name']?.toString() ?? '',
        'inviter_id': inv['inviter_id']?.toString(),
        'inviter_username': inv['inviter_username']?.toString(),
        'inviter_display_name': inv['inviter_display_name']?.toString(),
        'created_at': (inv['created_at'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notifier.notify(_key);
  }
}

// ---- friends + friend requests --------------------------------------------

class CachedFriend {
  final String userId;
  final String username;
  final String? displayName;
  final String? avatarUrl;
  final int since;

  const CachedFriend({
    required this.userId,
    required this.username,
    this.displayName,
    this.avatarUrl,
    required this.since,
  });

  factory CachedFriend.fromRow(Map<String, dynamic> r) => CachedFriend(
        userId: r['user_id'] as String,
        username: r['username'] as String,
        displayName: r['display_name'] as String?,
        avatarUrl: r['avatar_url'] as String?,
        since: r['since'] as int? ?? 0,
      );
}

class CachedFriendRequest {
  final String id;
  final String fromUserId;
  final String fromUsername;
  final String? fromDisplayName;
  final String? fromAvatarUrl;
  final int createdAt;

  const CachedFriendRequest({
    required this.id,
    required this.fromUserId,
    required this.fromUsername,
    this.fromDisplayName,
    this.fromAvatarUrl,
    required this.createdAt,
  });

  factory CachedFriendRequest.fromRow(Map<String, dynamic> r) =>
      CachedFriendRequest(
        id: r['id'] as String,
        fromUserId: r['from_user_id'] as String,
        fromUsername: r['from_username'] as String,
        fromDisplayName: r['from_display_name'] as String?,
        fromAvatarUrl: r['from_avatar_url'] as String?,
        createdAt: r['created_at'] as int,
      );
}

class FriendsCache {
  static final _notifier = _Notifier<int>();
  static const _key = 0;

  static Stream<List<CachedFriend>> watch() async* {
    yield await snapshot();
    await for (final _ in _notifier.watch(_key)) {
      yield await snapshot();
    }
  }

  static Future<List<CachedFriend>> snapshot() async {
    final db = await AppDb.open();
    final rows = await db.query('friends', orderBy: 'username ASC');
    return rows.map(CachedFriend.fromRow).toList(growable: false);
  }

  static Future<void> replaceAll(List<Map<String, dynamic>> list) async {
    final db = await AppDb.open();
    await db.transaction((txn) async {
      await txn.delete('friends');
      for (final f in list) {
        await txn.insert(
          'friends',
          {
            'user_id': f['user_id']?.toString() ?? '',
            'username': f['username']?.toString() ?? '',
            'display_name': f['display_name']?.toString(),
            'avatar_url': f['avatar_url']?.toString(),
            'since': (f['since'] as num?)?.toInt() ?? 0,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    _notifier.notify(_key);
  }

  static Future<void> upsert({
    required String userId,
    required String username,
    String? displayName,
    String? avatarUrl,
    int? since,
  }) async {
    final db = await AppDb.open();
    await db.insert(
      'friends',
      {
        'user_id': userId,
        'username': username,
        'display_name': displayName,
        'avatar_url': avatarUrl,
        'since': since ?? DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notifier.notify(_key);
  }

  static Future<void> remove(String userId) async {
    final db = await AppDb.open();
    await db.delete('friends', where: 'user_id = ?', whereArgs: [userId]);
    _notifier.notify(_key);
  }
}

class FriendRequestsCache {
  static final _notifier = _Notifier<int>();
  static const _key = 0;

  static Stream<List<CachedFriendRequest>> watch() async* {
    yield await snapshot();
    await for (final _ in _notifier.watch(_key)) {
      yield await snapshot();
    }
  }

  static Future<List<CachedFriendRequest>> snapshot() async {
    final db = await AppDb.open();
    final rows = await db.query('friend_requests', orderBy: 'created_at DESC');
    return rows.map(CachedFriendRequest.fromRow).toList(growable: false);
  }

  static Future<void> replaceAll(List<Map<String, dynamic>> list) async {
    final db = await AppDb.open();
    await db.transaction((txn) async {
      await txn.delete('friend_requests');
      for (final r in list) {
        await txn.insert(
          'friend_requests',
          _shapeRow(r),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    _notifier.notify(_key);
  }

  static Future<void> upsert(Map<String, dynamic> r) async {
    final db = await AppDb.open();
    await db.insert(
      'friend_requests',
      _shapeRow(r),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notifier.notify(_key);
  }

  static Future<void> remove(String id) async {
    final db = await AppDb.open();
    await db.delete('friend_requests', where: 'id = ?', whereArgs: [id]);
    _notifier.notify(_key);
  }

  static Map<String, Object?> _shapeRow(Map<String, dynamic> r) => {
        'id': r['id']?.toString() ?? '',
        'from_user_id': r['from_user_id']?.toString() ?? '',
        'from_username': r['from_username']?.toString() ?? '',
        'from_display_name': r['from_display_name']?.toString(),
        'from_avatar_url': r['from_avatar_url']?.toString(),
        'created_at': (r['created_at'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      };
}

// ---- drafts (local-only) --------------------------------------------------

class Draft {
  final String roomId;
  final String text;
  final String? replyToId;
  const Draft({required this.roomId, required this.text, this.replyToId});
}

/// F9: per-room composer draft. Local-only (never synced to the server).
class DraftsCache {
  static Future<Draft?> get(String roomId) async {
    final db = await AppDb.open();
    final rows = await db.query(
      'drafts',
      where: 'room_id = ?',
      whereArgs: [roomId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Draft(
      roomId: roomId,
      text: (r['text'] as String?) ?? '',
      replyToId: r['reply_to_id'] as String?,
    );
  }

  static Future<void> set(String roomId, String text, {String? replyToId}) async {
    final db = await AppDb.open();
    if (text.isEmpty && replyToId == null) {
      await clear(roomId);
      return;
    }
    await db.insert(
      'drafts',
      {
        'room_id': roomId,
        'text': text,
        'reply_to_id': replyToId,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> clear(String roomId) async {
    final db = await AppDb.open();
    await db.delete('drafts', where: 'room_id = ?', whereArgs: [roomId]);
  }
}

// ---- blocked users ---------------------------------------------------------

class CachedBlockedUser {
  final String userId;
  final String? username;
  final String? displayName;
  final String? avatarUrl;
  final int createdAt;

  const CachedBlockedUser({
    required this.userId,
    this.username,
    this.displayName,
    this.avatarUrl,
    required this.createdAt,
  });

  factory CachedBlockedUser.fromRow(Map<String, dynamic> r) => CachedBlockedUser(
        userId: r['user_id'] as String,
        username: r['username'] as String?,
        displayName: r['display_name'] as String?,
        avatarUrl: r['avatar_url'] as String?,
        createdAt: r['created_at'] as int? ?? 0,
      );
}

/// F12: locally-cached block list, mirroring the server's `/blocks`.
class BlocksCache {
  static final _notifier = _Notifier<int>();
  static const _key = 0;

  static Stream<List<CachedBlockedUser>> watch() async* {
    yield await list();
    await for (final _ in _notifier.watch(_key)) {
      yield await list();
    }
  }

  static Future<List<CachedBlockedUser>> list() async {
    final db = await AppDb.open();
    final rows = await db.query('blocked_users', orderBy: 'created_at DESC');
    return rows.map(CachedBlockedUser.fromRow).toList(growable: false);
  }

  static Future<bool> isBlocked(String userId) async {
    final db = await AppDb.open();
    final rows = await db.query(
      'blocked_users',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<void> add(
    String userId, {
    String? username,
    String? displayName,
    String? avatarUrl,
    int? createdAt,
  }) async {
    final db = await AppDb.open();
    await db.insert(
      'blocked_users',
      {
        'user_id': userId,
        'username': username,
        'display_name': displayName,
        'avatar_url': avatarUrl,
        'created_at': createdAt ?? DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notifier.notify(_key);
  }

  static Future<void> remove(String userId) async {
    final db = await AppDb.open();
    await db.delete('blocked_users', where: 'user_id = ?', whereArgs: [userId]);
    _notifier.notify(_key);
  }

  static Future<void> replaceAll(List<Map<String, dynamic>> list) async {
    final db = await AppDb.open();
    await db.transaction((txn) async {
      await txn.delete('blocked_users');
      for (final b in list) {
        await txn.insert(
          'blocked_users',
          {
            'user_id': b['user_id']?.toString() ?? '',
            'username': b['username']?.toString(),
            'display_name': b['display_name']?.toString(),
            'avatar_url': b['avatar_url']?.toString(),
            'created_at': (b['created_at'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    _notifier.notify(_key);
  }
}

// ---- wipe (на logout) ------------------------------------------------------

Future<void> wipeAllCaches() async {
  final db = await AppDb.open();
  await db.transaction((txn) async {
    await txn.delete('rooms');
    await txn.delete('messages');
    await txn.delete('members');
    await txn.delete('invites');
    await txn.delete('outbox');
    await txn.delete('friends');
    await txn.delete('friend_requests');
    await txn.delete('drafts');
    await txn.delete('blocked_users');
  });
  RoomsCache._notifier.notify(RoomsCache._key);
  InvitesCache._notifier.notify(InvitesCache._key);
  FriendsCache._notifier.notify(FriendsCache._key);
  FriendRequestsCache._notifier.notify(FriendRequestsCache._key);
  BlocksCache._notifier.notify(BlocksCache._key);
}
