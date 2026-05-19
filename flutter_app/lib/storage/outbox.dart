import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Локальная очередь отправленных, но ещё не подтверждённых сообщений.
/// Сохраняется на диск — переживает крэш приложения.
class Outbox {
  static Database? _db;

  static Future<Database> _open() async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'kirca.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE outbox(
            client_id TEXT PRIMARY KEY,
            room_id   TEXT NOT NULL,
            text      TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_outbox_room ON outbox(room_id)');
      },
    );
    return _db!;
  }

  static Future<void> add({
    required String clientId,
    required String roomId,
    required String text,
    required int createdAt,
  }) async {
    final db = await _open();
    await db.insert(
      'outbox',
      {
        'client_id': clientId,
        'room_id': roomId,
        'text': text,
        'created_at': createdAt,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<void> remove(String clientId) async {
    final db = await _open();
    await db.delete('outbox', where: 'client_id = ?', whereArgs: [clientId]);
  }

  static Future<List<OutboxEntry>> byRoom(String roomId) async {
    final db = await _open();
    final rows = await db.query(
      'outbox',
      where: 'room_id = ?',
      whereArgs: [roomId],
      orderBy: 'created_at ASC',
    );
    return rows
        .map((r) => OutboxEntry(
              clientId: r['client_id'] as String,
              roomId: r['room_id'] as String,
              text: r['text'] as String,
              createdAt: r['created_at'] as int,
            ))
        .toList();
  }

  static Future<void> clear() async {
    final db = await _open();
    await db.delete('outbox');
  }
}

class OutboxEntry {
  final String clientId;
  final String roomId;
  final String text;
  final int createdAt;
  const OutboxEntry({
    required this.clientId,
    required this.roomId,
    required this.text,
    required this.createdAt,
  });
}
