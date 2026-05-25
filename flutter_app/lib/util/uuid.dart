import 'dart:math';

/// RFC 4122 v4 (random) UUID, formatted with hyphens.
///
/// Uses [Random.secure] so the value is suitable as a server-side identity
/// (message client_id, request nonces, etc.) rather than just a local handle.
String uuidV4() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
  String hex(int x) => x.toRadixString(16).padLeft(2, '0');
  final s = b.map(hex).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-'
      '${s.substring(16, 20)}-${s.substring(20)}';
}
