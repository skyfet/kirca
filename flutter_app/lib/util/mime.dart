/// Maps a file path to one of the MIME types the server accepts for image
/// uploads. Returns null for unsupported formats so callers can surface a
/// "wrong format" error instead of silently shipping a bad blob.
String? imageMimeFromPath(String path) {
  final p = path.toLowerCase();
  if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
  if (p.endsWith('.png')) return 'image/png';
  if (p.endsWith('.webp')) return 'image/webp';
  if (p.endsWith('.gif')) return 'image/gif';
  if (p.endsWith('.heic')) return 'image/heic';
  return null;
}
