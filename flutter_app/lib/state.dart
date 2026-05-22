import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';
import 'push.dart';
import 'storage/cache.dart';

class Auth {
  final String token;
  final String userId;
  final String username;
  Auth(this.token, this.userId, this.username);
}

class AuthNotifier extends StateNotifier<Auth?> {
  AuthNotifier() : super(null) {
    // Регистрируем глобальный 401-хук один раз. forceLogout сам разгребёт всё.
    registerUnauthorizedHandler(forceLogout);
    _load();
  }

  static const _storage = FlutterSecureStorage();

  Future<void> _load() async {
    final t = await _storage.read(key: 'token');
    final uid = await _storage.read(key: 'userId');
    final un = await _storage.read(key: 'username');
    if (t != null && uid != null && un != null) {
      state = Auth(t, uid, un);
      // На фоне пробуем зарегистрировать device-token (на iOS).
      // Ошибки игнорируем — push best-effort.
      _registerPushSilently(t);
    }
  }

  Future<void> set(Auth a) async {
    await _storage.write(key: 'token', value: a.token);
    await _storage.write(key: 'userId', value: a.userId);
    await _storage.write(key: 'username', value: a.username);
    state = a;
    _registerPushSilently(a.token);
  }

  Future<void> _registerPushSilently(String token) async {
    if (!Platform.isIOS) return;
    try {
      final deviceToken = await Push.requestToken();
      if (deviceToken != null && deviceToken.isNotEmpty) {
        await _storage.write(key: 'deviceToken', value: deviceToken);
        await Api(token: token).registerDevice(deviceToken, 'ios');
      }
    } catch (_) {
      /* пуш — best-effort */
    }
  }

  /// Выход по инициативе пользователя: бросает запрос на сервер, чистит локалку.
  Future<void> logout() async {
    final t = state?.token;
    final deviceToken = await _storage.read(key: 'deviceToken');
    if (t != null) {
      try {
        if (deviceToken != null && deviceToken.isNotEmpty) {
          // Сначала снимаем регистрацию устройства, чтобы новые пуши не приходили.
          await Api(token: t).unregisterDevice(deviceToken);
        }
        await Api(token: t).logout();
      } catch (_) { /* не блокируем выход на сетевых ошибках */ }
    }
    await _wipeLocal();
    state = null;
  }

  /// Принудительная разлогинка: токен сервером уже невалиден (401/1008).
  /// Запросов на сервер не делаем, просто чистим локалку.
  Future<void> forceLogout() async {
    if (state == null) return;
    await _wipeLocal();
    state = null;
  }

  Future<void> _wipeLocal() async {
    await _storage.deleteAll();
    try { await wipeAllCaches(); } catch (_) {}
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, Auth?>((_) => AuthNotifier());

/// id комнаты, на чьём экране сейчас находится пользователь.
/// UserWs смотрит сюда, чтобы НЕ бампить unread для активного чата.
final currentRoomProvider = StateProvider<String?>((_) => null);

// ---- data providers ------------------------------------------------------
// Источник правды для UI — SQLite-кэш. REST-запросы лишь обновляют его.

/// Список комнат — стрим над кэшем. UI рисует мгновенно из кэша на холодный
/// старт; одновременно стартует фоновый refresh.
final roomsProvider = StreamProvider<List<CachedRoom>>((ref) {
  final auth = ref.watch(authProvider);
  if (auth == null) {
    return const Stream.empty();
  }
  // Фоновый refresh — не блокирует стрим.
  Future<void>.microtask(() async {
    try {
      final list = await Api(token: auth.token).rooms();
      await RoomsCache.replaceAll(list.cast<Map<String, dynamic>>());
    } catch (_) { /* offline — рисуем из кэша */ }
  });
  return RoomsCache.watch();
});

final invitesProvider = StreamProvider<List<CachedInvite>>((ref) {
  final auth = ref.watch(authProvider);
  if (auth == null) {
    return const Stream.empty();
  }
  Future<void>.microtask(() async {
    try {
      final list = await Api(token: auth.token).invites();
      await InvitesCache.replaceAll(list.cast<Map<String, dynamic>>());
    } catch (_) {}
  });
  return InvitesCache.watch();
});

final membersProvider = StreamProvider.autoDispose
    .family<List<CachedMember>, String>((ref, roomId) {
  final auth = ref.watch(authProvider);
  if (auth == null) {
    return const Stream.empty();
  }
  Future<void>.microtask(() async {
    try {
      final list = await Api(token: auth.token).members(roomId);
      await MembersCache.replaceAll(roomId, list.cast<Map<String, dynamic>>());
    } catch (_) {}
  });
  return MembersCache.watch(roomId);
});

final messagesProvider = StreamProvider.autoDispose
    .family<List<CachedMessage>, String>((ref, roomId) {
  final auth = ref.watch(authProvider);
  if (auth == null) {
    return const Stream.empty();
  }
  // Подгрузка истории фоном — стрим уже рисует из кэша.
  Future<void>.microtask(() async {
    try {
      final h = await Api(token: auth.token).history(roomId);
      await MessagesCache.upsertAll(roomId, h.cast<Map<String, dynamic>>());
    } catch (_) {}
  });
  return MessagesCache.watch(roomId);
});
