import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/screens/search_add_screen.dart';

void main() {
  test('accepts valid ISBN-13 values', () {
    expect(isValidIsbn13('9780306406157'), isTrue);
  });

  test('rejects malformed or bad-checksum values', () {
    expect(isValidIsbn13('9780306406158'), isFalse);
    expect(isValidIsbn13('978-0306406157'), isFalse);
    expect(isValidIsbn13('978030640615'), isFalse);
    expect(
      isValidIsbn13(
        '\uFF19\uFF17\uFF18\uFF10\uFF13\uFF10\uFF16\uFF14\uFF10\uFF16\uFF11\uFF15\uFF17',
      ),
      isFalse,
    );
  });

  test('accepts valid ISBN-10 values, including X check digits', () {
    expect(isValidIsbn10('0306406152'), isTrue);
    expect(isValidIsbn10('080442957X'), isTrue);
    expect(isValidIsbn10('0306406153'), isFalse);
    expect(isValidIsbn10('030640615'), isFalse);
  });

  test('recognizes either ISBN format', () {
    expect(isValidIsbn('0306406152'), isTrue);
    expect(isValidIsbn('9780306406157'), isTrue);
    expect(isValidIsbn('1234567890'), isFalse);
  });
}
