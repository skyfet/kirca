import 'dart:typed_data';

import 'package:blurhash_dart/blurhash_dart.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Compute a BlurHash placeholder string from raw image bytes off the UI
/// isolate. Returns null on decode failure so callers can ship the image
/// without a placeholder rather than fail the upload.
Future<String?> encodeBlurhash(Uint8List bytes) async {
  try {
    return await compute(_encode, bytes);
  } catch (_) {
    return null;
  }
}

String? _encode(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  // Visual quality is set by component count, not source resolution. Encode
  // is O(W*H*comp); downscale aggressively so picking a 12 MP photo doesn't
  // stall.
  final small =
      decoded.width > 64 ? img.copyResize(decoded, width: 64) : decoded;
  return BlurHash.encode(small, numCompX: 4, numCompY: 3).hash;
}
