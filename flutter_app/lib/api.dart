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

/// Превращает url, полученный с бэкенда, в абсолютный.
/// Сервер отдаёт `/attachments/<id>` и `/users/<id>/avatar?v=<ts>`
/// (R2 не используется — байты лежат в D1 BLOB).
String resolveMediaUrl(String url) {
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  return '${Config.apiBase}$url';
}

/// Заголовки для запроса картинок через Image.network / NetworkImage.
/// Без них сервер вернёт 401 — все эндпоинты вложений требуют сессию.
Map<String, String> mediaHeaders(String? token) =>
    token == null ? const {} : {'Authorization': 'Bearer $token'};

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

  // ---- profile ----
  Future<Map<String, dynamic>> me() async {
    final r = await http.get(Uri.parse('${Config.apiBase}/me'), headers: _headers);
    return _decode(r);
  }

  Future<Map<String, dynamic>> updateProfile({String? displayName, String? avatarUrl}) async {
    final body = <String, dynamic>{};
    if (displayName != null) body['display_name'] = displayName;
    if (avatarUrl != null) body['avatar_url'] = avatarUrl;
    final r = await http.patch(
      Uri.parse('${Config.apiBase}/me'),
      headers: _headers,
      body: jsonEncode(body),
    );
    return _decode(r);
  }

  Future<Map<String, dynamic>> uploadAvatar(List<int> bytes, String mime) async {
    final r = await http.put(
      Uri.parse('${Config.apiBase}/me/avatar'),
      headers: {
        if (token != null) 'Authorization': 'Bearer $token',
        'Content-Type': mime,
        'Content-Length': bytes.length.toString(),
      },
      body: bytes,
    );
    return _decode(r);
  }

  Future<void> deleteAccount() async {
    final r = await http.delete(Uri.parse('${Config.apiBase}/me'), headers: _headers);
    if (r.statusCode != 204) _decode(r);
  }

  Future<void> logoutAll() async {
    final r = await http.post(
      Uri.parse('${Config.apiBase}/logout?all=1'),
      headers: _headers,
    );
    if (r.statusCode != 204 && r.statusCode != 401) _decode(r);
  }

  // ---- rooms extras ----
  Future<List<dynamic>> members(String roomId) async {
    final r = await http.get(
      Uri.parse('${Config.apiBase}/rooms/$roomId/members'),
      headers: _headers,
    );
    return (_decode(r))['members'] as List<dynamic>;
  }

  Future<void> setMuted(String roomId, bool muted) async {
    final r = await http.patch(
      Uri.parse('${Config.apiBase}/rooms/$roomId/membership'),
      headers: _headers,
      body: jsonEncode({'muted': muted}),
    );
    _decode(r);
  }

  Future<void> leaveRoom(String roomId) async {
    final r = await http.post(
      Uri.parse('${Config.apiBase}/rooms/$roomId/leave'),
      headers: _headers,
    );
    if (r.statusCode != 204) _decode(r);
  }

  // ---- invites ----
  Future<Map<String, dynamic>> invite(String roomId, {String? username, String? userId}) async {
    final r = await http.post(
      Uri.parse('${Config.apiBase}/rooms/$roomId/invites'),
      headers: _headers,
      body: jsonEncode({
        if (username != null) 'username': username,
        if (userId != null) 'user_id': userId,
      }),
    );
    return _decode(r);
  }

  Future<List<dynamic>> invites() async {
    final r = await http.get(Uri.parse('${Config.apiBase}/invites'), headers: _headers);
    return (_decode(r))['invites'] as List<dynamic>;
  }

  Future<Map<String, dynamic>> acceptInvite(String id) async {
    final r = await http.post(
      Uri.parse('${Config.apiBase}/invites/$id/accept'),
      headers: _headers,
    );
    return _decode(r);
  }

  Future<void> declineInvite(String id) async {
    final r = await http.post(
      Uri.parse('${Config.apiBase}/invites/$id/decline'),
      headers: _headers,
    );
    _decode(r);
  }

  // ---- messages: edit / delete / read ----
  Future<void> editMessage(String roomId, String msgId, String text) async {
    final r = await http.patch(
      Uri.parse('${Config.apiBase}/rooms/$roomId/messages/$msgId'),
      headers: _headers,
      body: jsonEncode({'text': text}),
    );
    _decode(r);
  }

  Future<void> deleteMessage(String roomId, String msgId) async {
    final r = await http.delete(
      Uri.parse('${Config.apiBase}/rooms/$roomId/messages/$msgId'),
      headers: _headers,
    );
    if (r.statusCode != 204) _decode(r);
  }

  Future<void> markRead(String roomId, int lastReadAt) async {
    final r = await http.post(
      Uri.parse('${Config.apiBase}/rooms/$roomId/read'),
      headers: _headers,
      body: jsonEncode({'last_read_at': lastReadAt}),
    );
    _decode(r);
  }

  // ---- uploads ----
  Future<Map<String, dynamic>> reserveUpload({
    required String mime,
    required int size,
    int? width,
    int? height,
  }) async {
    final r = await http.post(
      Uri.parse('${Config.apiBase}/uploads'),
      headers: _headers,
      body: jsonEncode({
        'mime': mime,
        'size': size,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
      }),
    );
    return _decode(r);
  }

  Future<void> uploadBytes(String uploadUrl, List<int> bytes, String mime) async {
    final r = await http.put(
      Uri.parse('${Config.apiBase}$uploadUrl'),
      headers: {
        if (token != null) 'Authorization': 'Bearer $token',
        'Content-Type': mime,
        'Content-Length': bytes.length.toString(),
      },
      body: bytes,
    );
    _decode(r);
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
