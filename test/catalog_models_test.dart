import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/models/catalog_models.dart';

void main() {
  test('book conditions expose the persisted names and labels in order', () {
    expect(BookCondition.values.map((condition) => condition.name).toList(), [
      'mint',
      'nearMint',
      'veryFine',
      'fine',
      'veryGood',
      'good',
      'fair',
      'poor',
    ]);
    expect(BookCondition.values.map((condition) => condition.label).toList(), [
      'Mint',
      'Near Mint',
      'Very Fine',
      'Fine',
      'Very Good',
      'Good',
      'Fair',
      'Poor',
    ]);
  });

  test('book condition parsing preserves legacy values', () {
    expect(BookCondition.parse('excellent'), BookCondition.veryFine);
    expect(BookCondition.parse('damaged'), BookCondition.poor);
    expect(BookCondition.parse('fair'), BookCondition.fair);
    expect(BookCondition.parse('unknown'), BookCondition.good);
  });

  test('RPGGeek URL is derived only for a nonempty ID', () {
    const withId = BookWork(title: 'Book', rpgGeekId: ' 42 ');
    const withoutId = BookWork(title: 'Book');

    expect(withId.rpgGeekUrl, 'https://rpggeek.com/rpgitem/42');
    expect(withoutId.rpgGeekUrl, isNull);
    expect(
      const BookWork(title: 'Book', rpgGeekId: '42/evil').rpgGeekUrl,
      isNull,
    );
    expect(const BookWork(title: 'Book', rpgGeekId: 'abc').rpgGeekUrl, isNull);
    expect(const BookWork(title: 'Book', rpgGeekId: '４２').rpgGeekUrl, isNull);
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

  test('extended RPGGeek metadata round trips through work rows', () {
    const original = BookWork(
      title: 'Metadata Manual',
      moreInfo: 'Expanded details',
      designers: ['A Designer'],
      artists: ['An Artist'],
      productionStaff: ['Editor'],
      version: '2nd edition',
      productCode: 'PR-42',
      seriesCode: 'SER-7',
      dimensions: '8 x 11 in',
      series: ['Core line'],
      setting: ['The Realm'],
      family: ['Fantasy'],
      system: ['d20'],
      category: ['Sourcebook'],
      mechanics: ['Dice rolling'],
      genre: ['High fantasy'],
    );
    final row = original.toRow();
    final restored = BookWork.fromRow(row);
    expect(restored.moreInfo, original.moreInfo);
    expect(restored.designers, original.designers);
    expect(restored.artists, original.artists);
    expect(restored.productionStaff, original.productionStaff);
    expect(restored.version, original.version);
    expect(restored.productCode, original.productCode);
    expect(restored.seriesCode, original.seriesCode);
    expect(restored.dimensions, original.dimensions);
    expect(restored.series, original.series);
    expect(restored.setting, original.setting);
    expect(restored.family, original.family);
    expect(restored.system, original.system);
    expect(restored.category, original.category);
    expect(restored.mechanics, original.mechanics);
    expect(restored.genre, original.genre);
  });
}
