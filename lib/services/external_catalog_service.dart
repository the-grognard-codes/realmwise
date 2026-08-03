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

  Future<List<WorkCandidate>> searchByIsbn(String input, {String? ownerName, String? ownerEmail, String? apiKey}) async {
    final normalized = input.replaceAll(RegExp(r'[^0-9Xx]'), '');
    final isbn = _isbn13FromInput(normalized);
    if (isbn == null)
      throw const CatalogLookupException('Enter a valid 10 or 13 digit ISBN.');
    final url = Uri.https('openlibrary.org', '/api/books', {
      'bibkeys': 'ISBN:$isbn',
      'format': 'json',
      'jscmd': 'data',
    });
    final payload = await _json(url, ownerName: ownerName, ownerEmail: ownerEmail);
    final book = payload['ISBN:$isbn'];
    if (book is! Map<String, dynamic>) return const [];
    final ol = _fromOpenLibraryBook(book, isbn);
    final key = apiKey?.trim() ?? '';
    if (key.isEmpty || ol.title.trim().isEmpty) return [ol];
    final hits = await _searchRpgGeek(ol.title, key);
    for (final hit in hits.take(5)) {
      try {
        final detail = await _fetchRpgGeekDetails(hit.id, key);
        final found = _isbnValues(detail);
        if (found.contains(isbn)) return [_mergeRpgGeek(ol, detail)];
      } on Exception {
        // A single unavailable detail must not prevent other candidates/fallback.
      }
    }
    return hits.isEmpty
        ? [ol]
        : hits
            // Non-exact hits are alternatives, not enrichments of the ISBN
            // record. Keeping them independent prevents every result from
            // inheriting the same OpenLibrary metadata while preserving the
            // hit's own title and RPGGeek identity.
            .map((h) => WorkCandidate(title: h.name, rpgGeekId: h.id, publicationDate: h.publicationDate))
            .toList();
  }

  String? _isbn13FromInput(String value) {
    if (RegExp(r'^[0-9]{13}$').hasMatch(value)) {
      // Preserve the existing service contract: any 13-digit value is sent
      // to OpenLibrary. Checksum validation is applied to ISBN-10 because it
      // must be converted before lookup.
      return value;
    }
    if (!RegExp(r'^[0-9]{9}[0-9Xx]$').hasMatch(value)) return null;
    var sum10 = 0;
    for (var i = 0; i < 10; i++) {
      final digit = i == 9 && (value[i] == 'X' || value[i] == 'x')
          ? 10
          : int.parse(value[i]);
      sum10 += digit * (10 - i);
    }
    if (sum10 % 11 != 0) return null;
    final prefix = '978${value.substring(0, 9)}';
    var sum13 = 0;
    for (var i = 0; i < prefix.length; i++) {
      sum13 += int.parse(prefix[i]) * (i.isEven ? 1 : 3);
    }
    final check = (10 - sum13 % 10) % 10;
    return '$prefix$check';
  }

  Future<List<WorkCandidate>> searchByTitleOrAuthor({
    required String term,
    required bool author,
    String? ownerName,
    String? ownerEmail,
    String? apiKey,
  }) async {
    if (term.trim().length < 2)
      throw const CatalogLookupException(
        'Type at least two characters to search.',
      );
    final key = apiKey?.trim() ?? '';
    if (key.isNotEmpty) {
      final hits = await _searchRpgGeek(term.trim(), key);
      if (hits.isNotEmpty) return hits.map((h) => WorkCandidate(title: h.name, rpgGeekId: h.id, publicationDate: h.publicationDate)).toList();
    }
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
      final candidates = await _searchRpgGeek(original.title, apiKey);
      final selected = _selectRpgGeekCandidate(original.title, candidates);
      if (selected == null) return original;
      final id = selected.id;
      return _mergeRpgGeek(original, await _fetchRpgGeekDetails(id, apiKey));
    } on Exception {
      // RPGGeek is optional; a successful OpenLibrary record remains usable.
      return original;
    }
  }

  /// Performs a direct ranked RPGGeek RPG-item search without Open Library
  /// fallback or enrichment.
  Future<List<WorkCandidate>> searchRpgGeek(String query, String apiKey) async {
    final term = query.trim();
    if (term.length < 2) {
      throw const CatalogLookupException('Type at least two characters to search.');
    }
    final key = apiKey.trim();
    if (key.isEmpty) throw const CatalogLookupException('RPGGeek bearer token is required.');
    final hits = await _searchRpgGeek(term, key, failOnError: true);
    return hits.map((h) => WorkCandidate(title: h.name, rpgGeekId: h.id, publicationDate: h.publicationDate)).toList();
  }

  /// Fetches one raw RPGGeek item. This operation never performs Open Library
  /// gap-fill or other enrichment.
  Future<WorkCandidate> fetchRpgGeekItem(String id, String apiKey) async {
    final itemId = id.trim();
    if (itemId.isEmpty) throw const CatalogLookupException('RPGGeek item id is required.');
    final key = apiKey.trim();
    if (key.isEmpty) throw const CatalogLookupException('RPGGeek bearer token is required.');
    final detail = await _fetchRpgGeekDetails(itemId, key);
    return detail.authors.isEmpty && detail.designers.isNotEmpty
        ? _replaceAuthors(detail, detail.designers)
        : detail;
  }

  Future<WorkCandidate> fetchRpgGeekDetails(WorkCandidate confirmed, String apiKey) async {
    if (apiKey.trim().isEmpty || confirmed.rpgGeekId.trim().isEmpty) return confirmed;
    try {
      final detail = await _fetchRpgGeekDetails(confirmed.rpgGeekId, apiKey);
      var merged = _mergeRpgGeek(confirmed, detail);
      if (merged.isbn13.isEmpty || merged.remoteCoverUrl.isEmpty || merged.authors.isEmpty) {
        try {
          List<WorkCandidate> ol;
          final normalizedIsbn = merged.isbn13.replaceAll(RegExp(r'[^0-9Xx]'), '');
          if (normalizedIsbn.length == 13) {
            ol = await searchByIsbn(normalizedIsbn);
            if (ol.isEmpty) ol = await searchByTitleOrAuthor(term: merged.title, author: false);
          } else {
            ol = await searchByTitleOrAuthor(term: merged.title, author: false);
          }
          if (ol.isNotEmpty) merged = _mergeRpgGeek(ol.first, merged);
        } on Exception {
          // Open Library is best-effort enrichment; retain the RPGGeek data
          // when the fallback lookup is unavailable or malformed.
          return merged;
        }
      }
      return merged;
    } on Exception { return confirmed; }
  }

  Future<List<_RpgGeekSearchCandidate>> _searchRpgGeek(String query, String apiKey, {bool failOnError = false}) async {
    final headers = {'Accept': 'application/xml', 'User-Agent': 'RpgCatalog/1.0', 'Authorization': 'Bearer ${apiKey.trim()}'};
    var hadResponse = false;
    final result = <_RpgGeekSearchCandidate>[];
    for (final q in _rpgGeekQueries(WorkCandidate(title: query))) {
      try {
        final response = await _client.get(Uri.https('boardgamegeek.com', '/xmlapi2/search', {'query': q, 'type': 'rpgitem'}), headers: headers).timeout(const Duration(seconds: 12));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          if (failOnError) throw CatalogLookupException('RPGGeek returned HTTP ${response.statusCode}.');
          continue;
        }
        hadResponse = true;
        for (final item in XmlDocument.parse(response.body).findAllElements('item')) {
          final id = item.getAttribute('id') ?? '';
          final name = item.findAllElements('name').map((e) => e.getAttribute('value') ?? '').firstWhere((v) => v.isNotEmpty, orElse: () => '');
          final year = item.findAllElements('yearpublished').map((element) => element.getAttribute('value') ?? '').firstWhere((value) => RegExp(r'^\d{4}$').hasMatch(value), orElse: () => '');
          if (id.isNotEmpty && name.isNotEmpty) result.add(_RpgGeekSearchCandidate(id, name, year));
        }
      } on CatalogLookupException { rethrow; } on Exception {
        if (failOnError) throw const CatalogLookupException('Could not reach RPGGeek.');
      }
    }
    final seen = <String>{};
    result.retainWhere((e) => seen.add(e.id));
    result.sort((a,b) => _scoreRpg(query,b.name).compareTo(_scoreRpg(query,a.name)));
    if (failOnError && !hadResponse) throw const CatalogLookupException('Could not reach RPGGeek.');
    return result;
  }

  int _scoreRpg(String title, String name) {
    final a = _normalizeRpgGeekTitle(title), b = _normalizeRpgGeekTitle(name);
    if (a == b) return 1000;
    if (a.startsWith(b) || b.startsWith(a)) return 700;
    return a.split(' ').where((t) => b.split(' ').contains(t)).length * 10;
  }

  Future<WorkCandidate> _fetchRpgGeekDetails(String id, String apiKey) async {
    final response = await _client.get(Uri.https('boardgamegeek.com', '/xmlapi2/thing', {'id': id, 'stats': '1', 'versions': '1'}), headers: {'Accept': 'application/xml', 'User-Agent': 'RpgCatalog/1.0', 'Authorization': 'Bearer ${apiKey.trim()}'}).timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) throw CatalogLookupException('RPGGeek returned HTTP ${response.statusCode}.');
    return _fromRpgGeek(XmlDocument.parse(response.body), id);
  }

  Set<String> _isbnValues(WorkCandidate c) => {
        if (c.isbn13.isNotEmpty) c.isbn13.replaceAll(RegExp(r'[^0-9Xx]'), ''),
        if (c.isbn.isNotEmpty) c.isbn.replaceAll(RegExp(r'[^0-9Xx]'), ''),
      };

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
    final authors = linkValues('author');
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
      authors: authors,
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

  WorkCandidate _mergeRpgGeek(WorkCandidate original, WorkCandidate detail) {
    final merged = original.mergeRpgGeek(detail);
    if (merged.authors.isNotEmpty || detail.designers.isEmpty) return merged;
    return _replaceAuthors(merged, detail.designers);
  }

  WorkCandidate _replaceAuthors(WorkCandidate source, List<String> authors) => WorkCandidate(
        title: source.title, isbn13: source.isbn13, authors: authors,
        publisher: source.publisher, publicationDate: source.publicationDate,
        summary: source.summary, pageCount: source.pageCount,
        remoteCoverUrl: source.remoteCoverUrl, openLibraryId: source.openLibraryId,
        rpgGeekId: source.rpgGeekId, gameSystem: source.gameSystem,
        gameSetting: source.gameSetting, bookType: source.bookType,
        moreInfo: source.moreInfo, designers: source.designers,
        artists: source.artists, productionStaff: source.productionStaff,
        version: source.version, isbn: source.isbn, productCode: source.productCode,
        seriesCode: source.seriesCode, dimensions: source.dimensions,
        series: source.series, setting: source.setting, family: source.family,
        system: source.system, category: source.category, mechanics: source.mechanics,
        genre: source.genre,
      );

  String _description(Object? raw) {
    if (raw is Map) return raw['value']?.toString() ?? '';
    return raw?.toString() ?? '';
  }
}

class _RpgGeekSearchCandidate {
  const _RpgGeekSearchCandidate(this.id, this.name, [this.publicationDate = '']);
  final String id;
  final String name;
  final String publicationDate;
}

extension FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
