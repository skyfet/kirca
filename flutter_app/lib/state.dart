import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';
import 'push.dart';
import 'storage/outbox.dart';

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
    try { await Outbox.clear(); } catch (_) {}
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, Auth?>((_) => AuthNotifier());
