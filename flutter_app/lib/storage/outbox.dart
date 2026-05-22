import 'package:sqflite/sqflite.dart';

import 'db.dart';

/// Локальная очередь отправленных, но ещё не подтверждённых сообщений.
/// Сохраняется на диск — переживает крэш приложения.
class Outbox {
  static Future<void> add({
    required String clientId,
    required String roomId,
    required String text,
    required int createdAt,
  }) async {
    final db = await AppDb.open();
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
    final db = await AppDb.open();
    await db.delete('outbox', where: 'client_id = ?', whereArgs: [clientId]);
  }

  static Future<List<OutboxEntry>> byRoom(String roomId) async {
    final db = await AppDb.open();
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
    final db = await AppDb.open();
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
