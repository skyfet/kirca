import 'dart:io' show Directory;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Глобальный SQLite-кэш приложения.
///
/// v1 — только outbox исходящих (легаси).
/// v2 — кэш для rooms / messages / members / invites, чтобы холодный старт
/// без сети рисовал последний снимок состояния.
class AppDb {
  static Database? _db;
  static Future<Database>? _opening;

  static Future<Database> open() async {
    if (_db != null) return _db!;
    return _opening ??= _doOpen();
  }

  static Future<void> close() async {
    final d = _db;
    _db = null;
    _opening = null;
    if (d != null) {
      await d.close();
    }
  }

  static Future<Database> _doOpen() async {
    Directory dir;
    try {
      dir = await getApplicationDocumentsDirectory();
    } catch (_) {
      dir = Directory.systemTemp.createTempSync('kirca-');
    }
    final path = p.join(dir.path, 'kirca.db');
    final db = await openDatabase(
      path,
      version: 2,
      onCreate: (db, _) async {
        await _createV1(db);
        await _createV2(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) await _createV2(db);
      },
    );
    _db = db;
    return db;
  }

  static Future<void> _createV1(Database db) async {
    await db.execute('''
      CREATE TABLE outbox(
        client_id  TEXT PRIMARY KEY,
        room_id    TEXT NOT NULL,
        text       TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_outbox_room ON outbox(room_id)');
  }

  static Future<void> _createV2(Database db) async {
    await db.execute('''
      CREATE TABLE rooms(
        id         TEXT PRIMARY KEY,
        name       TEXT NOT NULL,
        is_public  INTEGER NOT NULL DEFAULT 1,
        is_member  INTEGER NOT NULL DEFAULT 0,
        role       TEXT,
        muted      INTEGER NOT NULL DEFAULT 0,
        unread     INTEGER NOT NULL DEFAULT 0,
        last_text  TEXT,
        last_at    INTEGER,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_rooms_updated ON rooms(updated_at DESC)');

    // Server-confirmed messages. Pending исходящие живут в outbox.
    await db.execute('''
      CREATE TABLE messages(
        id                TEXT PRIMARY KEY,
        room_id           TEXT NOT NULL,
        client_id         TEXT,
        user_id           TEXT NOT NULL,
        username          TEXT NOT NULL,
        text              TEXT NOT NULL DEFAULT '',
        created_at        INTEGER NOT NULL,
        edited_at         INTEGER,
        deleted_at        INTEGER,
        attachment_id     TEXT,
        attachment_url    TEXT,
        attachment_mime   TEXT,
        attachment_width  INTEGER,
        attachment_height INTEGER
      )
    ''');
    await db.execute('CREATE INDEX idx_messages_room_time ON messages(room_id, created_at)');

    await db.execute('''
      CREATE TABLE members(
        room_id      TEXT NOT NULL,
        user_id      TEXT NOT NULL,
        username     TEXT NOT NULL,
        display_name TEXT,
        avatar_url   TEXT,
        role         TEXT,
        online       INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(room_id, user_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE invites(
        id                   TEXT PRIMARY KEY,
        room_id              TEXT NOT NULL,
        room_name            TEXT NOT NULL,
        inviter_id           TEXT,
        inviter_username     TEXT,
        inviter_display_name TEXT,
        created_at           INTEGER NOT NULL
      )
    ''');
  }
}
