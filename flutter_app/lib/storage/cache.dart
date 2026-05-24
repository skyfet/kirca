import 'dart:async';

import 'package:sqflite/sqflite.dart';

import 'db.dart';

// ---- models ----------------------------------------------------------------

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
  });

  bool get isE2e => ciphertext != null;

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
            ),
      ciphertext: r['ciphertext'] as String?,
      iv: r['iv'] as String?,
      keyVersion: r['key_version'] as int?,
    );
  }
}

class CachedRoom {
  final String id;
  final String name;
  final bool isPublic;
  final bool isMember;
  final String role;
  final bool muted;
  final int unread;
  final String? lastText;
  final int? lastAt;
  final bool e2e;
  final int keyVersion;

  const CachedRoom({
    required this.id,
    required this.name,
    required this.isPublic,
    required this.isMember,
    required this.role,
    required this.muted,
    required this.unread,
    this.lastText,
    this.lastAt,
    this.e2e = false,
    this.keyVersion = 0,
  });

  factory CachedRoom.fromRow(Map<String, dynamic> r) => CachedRoom(
        id: r['id'] as String,
        name: r['name'] as String,
        isPublic: (r['is_public'] as int) == 1,
        isMember: (r['is_member'] as int? ?? 0) == 1,
        role: (r['role'] as String?) ?? '',
        muted: (r['muted'] as int? ?? 0) == 1,
        unread: r['unread'] as int? ?? 0,
        lastText: r['last_text'] as String?,
        lastAt: r['last_at'] as int?,
        e2e: (r['e2e'] as int? ?? 0) == 1,
        keyVersion: r['key_version'] as int? ?? 0,
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
  static Future<void> replaceAll(List<Map<String, dynamic>> serverRooms) async {
    final db = await AppDb.open();
    await db.transaction((txn) async {
      await txn.delete('rooms');
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final r in serverRooms) {
        await _insertRoomRaw(txn, r, now);
      }
    });
    _notifier.notify(_key);
  }

  /// Идемпотентный upsert одной комнаты (например, после createRoom / room_added).
  static Future<void> upsert(Map<String, dynamic> r) async {
    final db = await AppDb.open();
    await _insertRoomRaw(db, r, DateTime.now().millisecondsSinceEpoch);
    _notifier.notify(_key);
  }

  static Future<void> remove(String roomId) async {
    final db = await AppDb.open();
    await db.delete('rooms', where: 'id = ?', whereArgs: [roomId]);
    _notifier.notify(_key);
  }

  static Future<void> setMuted(String roomId, bool muted) async {
    final db = await AppDb.open();
    await db.update(
      'rooms',
      {'muted': muted ? 1 : 0},
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
    int updatedAt,
  ) async {
    final isPub = (r['is_public'] is num)
        ? (r['is_public'] as num).toInt() == 1
        : r['is_public'] == true;
    final muted = (r['muted'] is num)
        ? (r['muted'] as num).toInt() == 1
        : r['muted'] == true;
    final isMember = (r['is_member'] is num)
        ? (r['is_member'] as num).toInt() == 1
        : r['is_member'] == true;
    final e2e = (r['e2e'] is num)
        ? (r['e2e'] as num).toInt() == 1
        : r['e2e'] == true;
    await x.insert(
      'rooms',
      {
        'id': r['id'].toString(),
        'name': r['name']?.toString() ?? '',
        'is_public': isPub ? 1 : 0,
        'is_member': isMember ? 1 : 0,
        'role': r['role']?.toString(),
        'muted': muted ? 1 : 0,
        'unread': (r['unread'] as num?)?.toInt() ?? 0,
        'last_text': r['last_text']?.toString(),
        'last_at': (r['last_at'] as num?)?.toInt(),
        'updated_at': updatedAt,
        'e2e': e2e ? 1 : 0,
        'key_version': (r['key_version'] as num?)?.toInt() ?? 0,
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

  static Future<void> applyDelete(
    String roomId,
    String id,
    int? deletedAt,
  ) async {
    final db = await AppDb.open();
    await db.update(
      'messages',
      {
        'text': '',
        'deleted_at': deletedAt ?? DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifier.notify(roomId);
  }

  /// Set the decrypted plaintext of an E2E message after the chat screen
  /// has unwrapped it. Leaves the ciphertext columns intact so re-decryption
  /// remains possible if needed.
  static Future<void> setDecryptedText(
    String roomId,
    String id,
    String text,
  ) async {
    final db = await AppDb.open();
    await db.update(
      'messages',
      {'text': text},
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
    final att = m['attachment'] as Map<String, dynamic>?;
    // Preserve any locally-decrypted plaintext we already cached for this id —
    // server replays its empty `text` field for E2E rows, so blind overwrite
    // would wipe the visible message bubble.
    String text = m['text']?.toString() ?? '';
    final ciphertext = m['ciphertext']?.toString();
    if (ciphertext != null && text.isEmpty) {
      final existing = await x.query(
        'messages',
        columns: ['text'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final prev = existing.first['text'] as String?;
        if (prev != null && prev.isNotEmpty) text = prev;
      }
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
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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

// ---- wipe (на logout) ------------------------------------------------------

Future<void> wipeAllCaches() async {
  final db = await AppDb.open();
  await db.transaction((txn) async {
    await txn.delete('rooms');
    await txn.delete('messages');
    await txn.delete('members');
    await txn.delete('invites');
    await txn.delete('outbox');
  });
  RoomsCache._notifier.notify(RoomsCache._key);
  InvitesCache._notifier.notify(InvitesCache._key);
}
