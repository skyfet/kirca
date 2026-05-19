import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';

class ApiException implements Exception {
  final String message;
  final int status;
  ApiException(this.message, this.status);
  @override
  String toString() => message;
}

/// Колбэк глобальной разлогинки. Устанавливается из state.dart один раз на запуск.
/// Когда сервер отвечает 401 — Api дёрнет его, чтобы стек экранов вернулся на логин.
typedef ForceLogout = Future<void> Function();
ForceLogout? _onUnauthorized;
void registerUnauthorizedHandler(ForceLogout fn) {
  _onUnauthorized = fn;
}

class Api {
  final String? token;
  Api({this.token});

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> register(String username, String password) async {
    final r = await http.post(
      Uri.parse('${Config.apiBase}/register'),
      headers: _headers,
      body: jsonEncode({'username': username, 'password': password}),
    );
    return _decode(r);
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    final r = await http.post(
      Uri.parse('${Config.apiBase}/login'),
      headers: _headers,
      body: jsonEncode({'username': username, 'password': password}),
    );
    return _decode(r);
  }

  Future<void> logout() async {
    final r = await http.post(Uri.parse('${Config.apiBase}/logout'), headers: _headers);
    // 204 — ок; 401 — токен уже мёртв, тоже считаем успехом.
    if (r.statusCode != 204 && r.statusCode != 401) {
      _decode(r);
    }
  }

  Future<void> changePassword(String oldPassword, String newPassword) async {
    final r = await http.post(
      Uri.parse('${Config.apiBase}/change-password'),
      headers: _headers,
      body: jsonEncode({'old_password': oldPassword, 'new_password': newPassword}),
    );
    _decode(r);
  }

  Future<List<dynamic>> rooms() async {
    final r = await http.get(Uri.parse('${Config.apiBase}/rooms'), headers: _headers);
    return (_decode(r))['rooms'] as List<dynamic>;
  }

  Future<Map<String, dynamic>> createRoom(String name, {bool isPublic = true}) async {
    final r = await http.post(
      Uri.parse('${Config.apiBase}/rooms'),
      headers: _headers,
      body: jsonEncode({'name': name, 'is_public': isPublic}),
    );
    return _decode(r);
  }

  Future<List<dynamic>> history(String roomId, {int? after, int? before, int? limit}) async {
    final qp = <String, String>{};
    if (after != null) qp['after'] = after.toString();
    if (before != null) qp['before'] = before.toString();
    if (limit != null) qp['limit'] = limit.toString();
    final uri = Uri.parse('${Config.apiBase}/rooms/$roomId/history')
        .replace(queryParameters: qp.isEmpty ? null : qp);
    final r = await http.get(uri, headers: _headers);
    return (_decode(r))['messages'] as List<dynamic>;
  }

  Future<void> joinRoom(String roomId) async {
    final r = await http.post(
      Uri.parse('${Config.apiBase}/rooms/$roomId/join'),
      headers: _headers,
    );
    _decode(r);
  }

  Future<void> registerDevice(String deviceToken, String platform) async {
    final r = await http.post(
      Uri.parse('${Config.apiBase}/devices'),
      headers: _headers,
      body: jsonEncode({'token': deviceToken, 'platform': platform}),
    );
    _decode(r);
  }

  Future<void> unregisterDevice(String deviceToken) async {
    final r = await http.delete(
      Uri.parse('${Config.apiBase}/devices/$deviceToken'),
      headers: _headers,
    );
    if (r.statusCode != 204) _decode(r);
  }

  Map<String, dynamic> _decode(http.Response r) {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      body = {'error': 'bad response'};
    }
    if (r.statusCode == 401 && _onUnauthorized != null) {
      // не ждём — пусть отработает в фоне; экраны уже получат исключение и выйдут.
      _onUnauthorized!();
    }
    if (r.statusCode >= 400) {
      throw ApiException(body['error']?.toString() ?? 'error', r.statusCode);
    }
    return body;
  }
}
