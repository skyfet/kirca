import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';
import 'crypto/key_store.dart';
import 'crypto/room_keys.dart';
import 'crypto/shared_secrets.dart';
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
    try {
      final t = await _storage.read(key: 'token');
      final uid = await _storage.read(key: 'userId');
      final un = await _storage.read(key: 'username');
      if (t != null && uid != null && un != null) {
        state = Auth(t, uid, un);
        // Mirror the restored token into the shared keychain for the iOS NSE.
        await SharedSecrets.writeAuth(t);
        _registerPushSilently(t);
      }
    } catch (_) {
      // headless / no keyring — стартуем без сохранённого auth.
    }
  }

  Future<void> set(Auth a) async {
    try {
      await _storage.write(key: 'token', value: a.token);
      await _storage.write(key: 'userId', value: a.userId);
      await _storage.write(key: 'username', value: a.username);
    } catch (_) { /* best-effort */ }
    // Mirror the token + API base into the shared keychain for the iOS NSE.
    await SharedSecrets.writeAuth(a.token);
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
    String? deviceToken;
    try {
      deviceToken = await _storage.read(key: 'deviceToken');
    } catch (_) { /* best-effort */ }
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
    try { await _storage.deleteAll(); } catch (_) { /* best-effort */ }
    try { await wipeAllCaches(); } catch (_) {}
    // Clear E2E key material so the next account on this device starts clean.
    try { await KeyStore.wipeIdentity(); } catch (_) {}
    // Drop the App Group keychain mirror (auth + room keys) the NSE reads.
    try { await SharedSecrets.clearAll(); } catch (_) {}
    RoomKeyCache.clear();
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
      await RoomsCache.replaceAll(
        list.cast<Map<String, dynamic>>(),
        currentUserId: auth.userId,
      );
    } catch (_) { /* offline — рисуем из кэша */ }
  });
  return RoomsCache.watch();
});

/// Rooms shown in the main list: archived rooms filtered out, pinned first,
/// then the base `updated_at DESC` order preserved. UI for F5/F6 consumes this
/// instead of mutating the base [roomsProvider]'s contract.
final sortedRoomsProvider = Provider<AsyncValue<List<CachedRoom>>>((ref) {
  return ref.watch(roomsProvider).whenData((rooms) {
    final visible = rooms.where((r) => !r.archived).toList();
    visible.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      // Preserve base ordering (updated_at DESC) within each pin group.
      final byTime = (b.lastAt ?? 0).compareTo(a.lastAt ?? 0);
      return byTime;
    });
    return visible;
  });
});

/// Archived rooms only (newest activity first), for the F6 "Archive" view.
final archivedRoomsProvider = Provider<AsyncValue<List<CachedRoom>>>((ref) {
  return ref.watch(roomsProvider).whenData((rooms) {
    final archived = rooms.where((r) => r.archived).toList();
    archived.sort((a, b) => (b.lastAt ?? 0).compareTo(a.lastAt ?? 0));
    return archived;
  });
});

/// F12: blocked users. Streams the local [BlocksCache]; kicks off a background
/// refresh from the server on first watch. UI calls `Api.addBlock/removeBlock`
/// then mirrors into [BlocksCache] for instant feedback.
final blockedUsersProvider = StreamProvider<List<CachedBlockedUser>>((ref) {
  final auth = ref.watch(authProvider);
  if (auth == null) {
    return const Stream.empty();
  }
  Future<void>.microtask(() async {
    try {
      final list = await Api(token: auth.token).listBlocks();
      await BlocksCache.replaceAll(list.cast<Map<String, dynamic>>());
    } catch (_) {}
  });
  return BlocksCache.watch();
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

final friendsProvider = StreamProvider<List<CachedFriend>>((ref) {
  final auth = ref.watch(authProvider);
  if (auth == null) {
    return const Stream.empty();
  }
  Future<void>.microtask(() async {
    try {
      final list = await Api(token: auth.token).friends();
      await FriendsCache.replaceAll(list.cast<Map<String, dynamic>>());
    } catch (_) {}
  });
  return FriendsCache.watch();
});

final friendRequestsProvider =
    StreamProvider<List<CachedFriendRequest>>((ref) {
  final auth = ref.watch(authProvider);
  if (auth == null) {
    return const Stream.empty();
  }
  Future<void>.microtask(() async {
    try {
      final list = await Api(token: auth.token).friendRequests();
      await FriendRequestsCache.replaceAll(list.cast<Map<String, dynamic>>());
    } catch (_) {}
  });
  return FriendRequestsCache.watch();
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
