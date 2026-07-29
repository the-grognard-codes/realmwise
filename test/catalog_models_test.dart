import 'package:flutter_test/flutter_test.dart';
import 'package:rpg_catalog/models/catalog_models.dart';

void main() {
  test('RPGGeek URL is derived only for a nonempty ID', () {
    const withId = BookWork(title: 'Book', rpgGeekId: ' 42 ');
    const withoutId = BookWork(title: 'Book');

    expect(withId.rpgGeekUrl, 'https://rpggeek.com/rpgitem/42');
    expect(withoutId.rpgGeekUrl, isNull);
    expect(
      const BookWork(title: 'Book', rpgGeekId: '42/evil').rpgGeekUrl,
      isNull,
    );
    expect(
      const BookWork(title: 'Book', rpgGeekId: 'abc').rpgGeekUrl,
      isNull,
    );
    expect(
      const BookWork(title: 'Book', rpgGeekId: '４２').rpgGeekUrl,
      isNull,
    );
    expect(
      const WorkCandidate(title: 'Book', rpgGeekId: '99').rpgGeekUrl,
      'https://rpggeek.com/rpgitem/99',
    );
  });

  test('RPGGeek enrichment prefers nonempty RPGGeek metadata', () {
    const openLibrary = WorkCandidate(
      title: 'Open title',
      publisher: 'Open publisher',
      pageCount: 100,
      isbn13: '9780000000001',
    );
    const rpgGeek = WorkCandidate(
      title: 'RPG title',
      publisher: '',
      summary: 'Authoritative RPG summary',
      rpgGeekId: '42',
    );

    final merged = openLibrary.mergeRpgGeek(rpgGeek);

    expect(merged.title, 'RPG title');
    expect(merged.publisher, 'Open publisher');
    expect(merged.summary, 'Authoritative RPG summary');
    expect(merged.isbn13, '9780000000001');
    expect(merged.rpgGeekId, '42');
  });

  test('catalog filtering searches tags and work metadata', () {
    const record = CatalogRecord(
      work: BookWork(
        title: 'Dragonlance Adventures',
        gameSystem: 'Dungeons & Dragons',
      ),
      copies: [
        UserCopy(tags: ['signed', 'classic']),
      ],
    );
    expect(record.matches('dungeons', null), isTrue);
    expect(record.matches('', 'signed'), isTrue);
    expect(record.matches('dragon', 'classic'), isTrue);
    expect(record.matches('rifts', null), isFalse);
  });
}
