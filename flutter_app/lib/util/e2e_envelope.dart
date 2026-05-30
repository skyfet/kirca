import 'dart:convert';

/// E2E plaintext envelope for messages that carry attachment metadata the
/// server must not see (blurhash, audio duration). Wire format:
/// `{"$k":1,"t":"text","a":{"bh":"...","d":1234}}`.
/// Text-only messages stay as raw strings so legacy receivers (and the bulk
/// of traffic) keep their existing path; the `$k:1` sentinel disambiguates
/// on decode so a user typing literal JSON doesn't trigger the envelope
/// branch.
const String _magic = r'$k';
const int _version = 1;

class E2eEnvelope {
  final String text;
  final String? blurhash;
  final int? durationMs;
  const E2eEnvelope({required this.text, this.blurhash, this.durationMs});
}

String encodeE2eEnvelope({
  required String text,
  String? blurhash,
  int? durationMs,
}) {
  if (blurhash == null && durationMs == null) return text;
  final attach = <String, Object?>{
    if (blurhash != null) 'bh': blurhash,
    if (durationMs != null) 'd': durationMs,
  };
  return jsonEncode(<String, Object?>{
    _magic: _version,
    't': text,
    if (attach.isNotEmpty) 'a': attach,
  });
}

E2eEnvelope decodeE2eEnvelope(String plaintext) {
  if (plaintext.isEmpty || !plaintext.startsWith('{')) {
    return E2eEnvelope(text: plaintext);
  }
  try {
    final v = jsonDecode(plaintext);
    if (v is! Map || v[_magic] != _version) {
      return E2eEnvelope(text: plaintext);
    }
    final text = v['t']?.toString() ?? '';
    final a = v['a'];
    if (a is Map) {
      return E2eEnvelope(
        text: text,
        blurhash: a['bh']?.toString(),
        durationMs: (a['d'] as num?)?.toInt(),
      );
    }
    return E2eEnvelope(text: text);
  } catch (_) {
    return E2eEnvelope(text: plaintext);
  }
}
