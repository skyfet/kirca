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

  Future<List<dynamic>> rooms() async {
    final r = await http.get(Uri.parse('${Config.apiBase}/rooms'), headers: _headers);
    return (_decode(r))['rooms'] as List<dynamic>;
  }

  Future<Map<String, dynamic>> createRoom(String name) async {
    final r = await http.post(
      Uri.parse('${Config.apiBase}/rooms'),
      headers: _headers,
      body: jsonEncode({'name': name}),
    );
    return _decode(r);
  }

  Future<List<dynamic>> history(String roomId) async {
    final r = await http.get(
      Uri.parse('${Config.apiBase}/rooms/$roomId/history'),
      headers: _headers,
    );
    return (_decode(r))['messages'] as List<dynamic>;
  }

  Map<String, dynamic> _decode(http.Response r) {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      body = {'error': 'bad response'};
    }
    if (r.statusCode >= 400) {
      throw ApiException(body['error']?.toString() ?? 'error', r.statusCode);
    }
    return body;
  }
}
