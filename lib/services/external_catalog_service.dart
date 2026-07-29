import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/catalog_models.dart';

class CatalogLookupException implements Exception {
  const CatalogLookupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Remote lookup boundary. All callers handle failure so the catalog remains usable offline.
class ExternalCatalogService {
  ExternalCatalogService(this._client);
  final http.Client _client;

  Future<List<WorkCandidate>> searchByIsbn(String input, {String? ownerName, String? ownerEmail}) async {
    final isbn = input.replaceAll(RegExp(r'[^0-9Xx]'), '');
    if (isbn.length != 13)
      throw const CatalogLookupException('Enter a 13-digit ISBN.');
    final url = Uri.https('openlibrary.org', '/api/books', {
      'bibkeys': 'ISBN:$isbn',
      'format': 'json',
      'jscmd': 'data',
    });
    final payload = await _json(url, ownerName: ownerName, ownerEmail: ownerEmail);
    final book = payload['ISBN:$isbn'];
    if (book is! Map<String, dynamic>) return const [];
    return [_fromOpenLibraryBook(book, isbn)];
  }

  Future<List<WorkCandidate>> searchByTitleOrAuthor({
    required String term,
    required bool author,
    String? ownerName,
    String? ownerEmail,
  }) async {
    if (term.trim().length < 2)
      throw const CatalogLookupException(
        'Type at least two characters to search.',
      );
    final url = Uri.https('openlibrary.org', '/search.json', {
      author ? 'author' : 'title': term.trim(),
      'limit': '5',
      'fields':
          'key,title,author_name,isbn,publisher,publish_date,first_publish_year,cover_i,number_of_pages_median',
    });
    final payload = await _json(url, ownerName: ownerName, ownerEmail: ownerEmail);
    final docs = payload['docs'];
    if (docs is! List) return const [];
    return docs
        .whereType<Map>()
        .take(5)
        .map((item) => _fromOpenLibrarySearch(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<WorkCandidate> enrichWithRpgGeek(
    WorkCandidate original,
    String apiKey,
  ) async {
    if (apiKey.trim().isEmpty) return original;
    try {
      final headers = <String, String>{
        'Accept': 'application/xml',
        'User-Agent': 'RpgCatalog/1.0',
        'X-API-Key': apiKey.trim(),
      };
      final candidates = <_RpgGeekSearchCandidate>[];
      for (final query in _rpgGeekQueries(original)) {
        final search = Uri.https('boardgamegeek.com', '/xmlapi2/search', {
          'query': query,
          'type': 'rpgitem',
        });
        try {
          final searchResponse = await _client
              .get(search, headers: headers)
              .timeout(const Duration(seconds: 12));
          if (searchResponse.statusCode < 200 ||
              searchResponse.statusCode >= 300) continue;
          final searchXml = XmlDocument.parse(searchResponse.body);
          for (final item in searchXml.findAllElements('item')) {
            final id = item.getAttribute('id');
            if (id == null || id.isEmpty) continue;
            final name = item
                .findAllElements('name')
                .map((element) => element.getAttribute('value') ?? '')
                .firstWhere((value) => value.isNotEmpty, orElse: () => '');
            candidates.add(_RpgGeekSearchCandidate(id, name));
          }
        } on Exception {
          // A failed query should not prevent a useful fallback query.
        }
      }
      final selected = _selectRpgGeekCandidate(original.title, candidates);
      if (selected == null) return original;
      final id = selected.id;
      final details = Uri.https('boardgamegeek.com', '/xmlapi2/thing', {
        'id': id,
        'stats': '1',
        'versions': '1',
      });
      final detailsResponse = await _client
          .get(details, headers: headers)
          .timeout(const Duration(seconds: 12));
      if (detailsResponse.statusCode < 200 || detailsResponse.statusCode >= 300)
        return original;
      final document = XmlDocument.parse(detailsResponse.body);
      return original.mergeRpgGeek(_fromRpgGeek(document, id));
    } on Exception {
      // RPGGeek is optional; a successful OpenLibrary record remains usable.
      return original;
    }
  }

  List<String> _rpgGeekQueries(WorkCandidate original) {
    final title = original.title.trim();
    if (title.isEmpty) return const [];
    final queries = <String>[title];
    // RPGGeek's search often treats subtitles as distinct records. Retry the
    // base title when the first query contains a common subtitle separator.
    final base = title.split(RegExp(r'\s*(?::|–|—|-)\s*')).first.trim();
    if (base.length >= 2 && base.toLowerCase() != title.toLowerCase()) {
      queries.add(base);
    }
    return queries;
  }

  _RpgGeekSearchCandidate? _selectRpgGeekCandidate(
    String title,
    List<_RpgGeekSearchCandidate> candidates,
  ) {
    if (candidates.isEmpty) return null;
    final normalizedTitle = _normalizeRpgGeekTitle(title);
    final titleTokens = normalizedTitle.split(' ').where((token) => token.isNotEmpty).toSet();
    _RpgGeekSearchCandidate? best;
    var bestScore = -1;
    final seen = <String>{};
    for (final candidate in candidates) {
      if (!seen.add(candidate.id)) continue;
      final normalizedName = _normalizeRpgGeekTitle(candidate.name);
      final nameTokens = normalizedName.split(' ').where((token) => token.isNotEmpty).toSet();
      if (normalizedName.isEmpty) continue;
      var score = 0;
      if (normalizedName == normalizedTitle && normalizedName.isNotEmpty) {
        score = 1000;
      } else if (normalizedName.startsWith(normalizedTitle) ||
          normalizedTitle.startsWith(normalizedName)) {
        score = 700;
      }
      score += titleTokens.intersection(nameTokens).length * 10;
      score -= (nameTokens.length - titleTokens.length).abs();
      // Ignore unrelated/weak hits rather than replacing a good OpenLibrary
      // record with an arbitrary RPGGeek result.
      if (score < 10) continue;
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return best;
  }

  String _normalizeRpgGeekTitle(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');

  Future<Map<String, dynamic>> _json(Uri url, {String? ownerName, String? ownerEmail}) async {
    final headers = <String, String>{
      'Accept': 'application/json',
      'User-Agent': _userAgent(ownerName, ownerEmail),
    };
    if (ownerEmail?.trim().isNotEmpty == true) headers['From'] = ownerEmail!.trim();
    try {
      final response = await _client.get(
        url,
        headers: headers,
      ).timeout(const Duration(seconds: 12));
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw CatalogLookupException(
          'OpenLibrary returned HTTP ${response.statusCode}.',
        );
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>)
        throw const CatalogLookupException(
          'OpenLibrary returned an unexpected response.',
        );
      return decoded;
    } on CatalogLookupException {
      rethrow;
    } on Exception {
      throw const CatalogLookupException(
        'Could not reach OpenLibrary. You can still add the book manually while offline.',
      );
    }
  }

  String _userAgent(String? ownerName, String? ownerEmail) {
    final name = ownerName?.trim() ?? '';
    final email = ownerEmail?.trim() ?? '';
    if (name.isEmpty && email.isEmpty) return 'RpgCatalog/1.0';
    final identity = [if (name.isNotEmpty) name, if (email.isNotEmpty) email].join(' ');
    return 'RpgCatalog/1.0 ($identity)';
  }

  WorkCandidate _fromOpenLibraryBook(
    Map<String, dynamic> book,
    String fallbackIsbn,
  ) {
    final identifiers = book['identifiers'] as Map?;
    final isbn13s = identifiers?['isbn_13'] as List?;
    final cover = book['cover'] as Map?;
    final authors = (book['authors'] as List? ?? const [])
        .whereType<Map>()
        .map((entry) => entry['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .toList();
    return WorkCandidate(
      title: book['title']?.toString() ?? 'Untitled work',
      isbn13: isbn13s?.firstOrNull?.toString() ?? fallbackIsbn,
      authors: authors,
      publisher: (book['publishers'] as List? ?? const [])
          .whereType<Map>()
          .map((entry) => entry['name']?.toString() ?? '')
          .firstWhere((value) => value.isNotEmpty, orElse: () => ''),
      publicationDate: book['publish_date']?.toString() ?? '',
      summary: _description(book['notes']),
      pageCount: (book['number_of_pages'] as num?)?.toInt(),
      remoteCoverUrl:
          cover?['large']?.toString() ?? cover?['medium']?.toString() ?? '',
      openLibraryId: book['key']?.toString() ?? '',
    );
  }

  WorkCandidate _fromOpenLibrarySearch(Map<String, dynamic> doc) {
    final isbnList = doc['isbn'] as List? ?? const [];
    final isbn = isbnList.map((value) => value.toString()).firstWhere(
          (value) => value.replaceAll(RegExp(r'[^0-9]'), '').length == 13,
          orElse: () => '',
        );
    final coverId = doc['cover_i'];
    return WorkCandidate(
      title: doc['title']?.toString() ?? 'Untitled work',
      isbn13: isbn,
      authors: (doc['author_name'] as List? ?? const [])
          .map((value) => value.toString())
          .toList(),
      publisher: (doc['publisher'] as List? ?? const [])
          .map((value) => value.toString())
          .firstWhere((value) => value.isNotEmpty, orElse: () => ''),
      publicationDate: doc['first_publish_year']?.toString() ??
          (doc['publish_date'] as List?)?.firstOrNull?.toString() ??
          '',
      pageCount: (doc['number_of_pages_median'] as num?)?.toInt(),
      remoteCoverUrl: coverId == null
          ? ''
          : 'https://covers.openlibrary.org/b/id/$coverId-L.jpg',
      openLibraryId: doc['key']?.toString() ?? '',
    );
  }

  WorkCandidate _fromRpgGeek(XmlDocument document, String id) {
    final item = document.findAllElements('item').firstOrNull;
    if (item == null) return WorkCandidate(title: '', rpgGeekId: id);
    String textFor(String localName) => item
        .findAllElements(localName)
        .map((element) => element.innerText.trim())
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    String attrFor(String localName, String attribute) => item
        .findAllElements(localName)
        .map((element) => element.getAttribute(attribute) ?? '')
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    final named = item
        .findAllElements('name')
        .map((element) => element.getAttribute('value') ?? '')
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    final links = <String, List<String>>{};
    for (final link in item.findAllElements('link')) {
      final type = (link.getAttribute('type') ?? '').toLowerCase();
      final value = (link.getAttribute('value') ?? link.innerText).trim();
      if (type.isNotEmpty && value.isNotEmpty) {
        (links[type] ??= <String>[]).add(value);
      }
    }
    List<String> linkValues(String key) => links.entries
        .where((entry) => entry.key == key || entry.key.endsWith(key) || entry.key.contains(key))
        .expand((entry) => entry.value)
        .toSet()
        .toList();
    String firstValue(String tag, String linkKey) =>
        textFor(tag).trim().isNotEmpty ? textFor(tag) : (linkValues(linkKey).firstOrNull ?? '');
    final publisherLinks = linkValues('publisher');
    final designers = linkValues('designer');
    final artists = linkValues('artist');
    final production = linkValues('production');
    final versionLinks = linkValues('version');
    final versionNames = item
        .findAllElements('versions')
        .expand((element) => element.findAllElements('name'))
        .map((element) => element.getAttribute('value') ?? element.innerText.trim())
        .where((value) => value.trim().isNotEmpty)
        .toList();
    final isbn = firstValue('isbn', 'isbn');
    return WorkCandidate(
      title: named,
      isbn13: isbn,
      publisher: publisherLinks.firstOrNull ?? '',
      publicationDate: attrFor('yearpublished', 'value'),
      summary: textFor('description'),
      moreInfo: textFor('moreinfo'),
      designers: designers,
      artists: artists,
      productionStaff: production,
      version: versionLinks.firstOrNull ?? versionNames.firstOrNull ?? textFor('version'),
      isbn: isbn,
      productCode: firstValue('productcode', 'productcode'),
      seriesCode: firstValue('seriescode', 'seriescode'),
      dimensions: firstValue('dimensions', 'dimensions'),
      series: linkValues('series'),
      setting: linkValues('setting'),
      family: linkValues('family'),
      system: linkValues('system'),
      category: linkValues('category'),
      mechanics: linkValues('mechanic'),
      genre: linkValues('genre'),
      gameSystem: (linkValues('system').firstOrNull ?? ''),
      gameSetting: (linkValues('setting').firstOrNull ?? ''),
      remoteCoverUrl: textFor('image'),
      rpgGeekId: id,
    );
  }

  String _description(Object? raw) {
    if (raw is Map) return raw['value']?.toString() ?? '';
    return raw?.toString() ?? '';
  }
}

class _RpgGeekSearchCandidate {
  const _RpgGeekSearchCandidate(this.id, this.name);
  final String id;
  final String name;
}

extension FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
