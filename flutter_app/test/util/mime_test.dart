import 'package:flutter_test/flutter_test.dart';
import 'package:kirca/util/mime.dart';

void main() {
  group('imageMimeFromPath', () {
    test('maps every supported extension', () {
      expect(imageMimeFromPath('/tmp/a.jpg'), 'image/jpeg');
      expect(imageMimeFromPath('/tmp/a.JPEG'), 'image/jpeg');
      expect(imageMimeFromPath('a.png'), 'image/png');
      expect(imageMimeFromPath('a.webp'), 'image/webp');
      expect(imageMimeFromPath('a.gif'), 'image/gif');
      expect(imageMimeFromPath('a.HEIC'), 'image/heic');
    });

    test('returns null for unsupported and missing extensions', () {
      expect(imageMimeFromPath('a.bmp'), isNull);
      expect(imageMimeFromPath('a.svg'), isNull);
      expect(imageMimeFromPath('no_extension'), isNull);
      expect(imageMimeFromPath(''), isNull);
    });
  });
}
