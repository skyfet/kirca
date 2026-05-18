import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Auth {
  final String token;
  final String userId;
  final String username;
  Auth(this.token, this.userId, this.username);
}

class AuthNotifier extends StateNotifier<Auth?> {
  AuthNotifier() : super(null) { _load(); }

  static const _storage = FlutterSecureStorage();

  Future<void> _load() async {
    final t = await _storage.read(key: 'token');
    final uid = await _storage.read(key: 'userId');
    final un = await _storage.read(key: 'username');
    if (t != null && uid != null && un != null) {
      state = Auth(t, uid, un);
    }
  }

  Future<void> set(Auth a) async {
    await _storage.write(key: 'token', value: a.token);
    await _storage.write(key: 'userId', value: a.userId);
    await _storage.write(key: 'username', value: a.username);
    state = a;
  }

  Future<void> clear() async {
    await _storage.deleteAll();
    state = null;
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, Auth?>((_) => AuthNotifier());
