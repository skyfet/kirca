import 'package:flutter_test/flutter_test.dart';
import 'package:kirca/util/uuid.dart';

void main() {
  group('uuidV4', () {
    test('matches the canonical 8-4-4-4-12 hex format', () {
      final id = uuidV4();
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
            .hasMatch(id),
        isTrue,
        reason: 'got: $id',
      );
    });

    test('encodes version 4 in the high nibble of byte 6', () {
      final id = uuidV4();
      expect(id.substring(14, 15), '4');
    });

    test('encodes RFC 4122 variant in the high bits of byte 8', () {
      final id = uuidV4();
      final variantNibble = int.parse(id.substring(19, 20), radix: 16);
      // High bits must be 10xx — i.e. nibble ∈ {8, 9, a, b}.
      expect([8, 9, 10, 11].contains(variantNibble), isTrue);
    });

    test('produces distinct values across many calls (random)', () {
      final ids = {for (var i = 0; i < 1000; i++) uuidV4()};
      expect(ids.length, 1000);
    });
  });
}
