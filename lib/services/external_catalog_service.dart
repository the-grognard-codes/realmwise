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

  Future<List<WorkCandidate>> searchByIsbn(String input) async {
    final isbn = input.replaceAll(RegExp(r'[^0-9Xx]'), '');
    if (isbn.length != 13)
      throw const CatalogLookupException('Enter a 13-digit ISBN.');
    final url = Uri.https('openlibrary.org', '/api/books', {
      'bibkeys': 'ISBN:$isbn',
      'format': 'json',
      'jscmd': 'data',
    });
    final payload = await _json(url);
    final book = payload['ISBN:$isbn'];
    if (book is! Map<String, dynamic>) return const [];
    return [_fromOpenLibraryBook(book, isbn)];
  }

  Future<List<WorkCandidate>> searchByTitleOrAuthor({
    required String term,
    required bool author,
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
    final payload = await _json(url);
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
        'Authorization': 'Bearer ${apiKey.trim()}',
      };
      final search = Uri.https('api.rpggeek.com', '/xmlapi2/search', {
        'query': original.title,
        'type': 'rpgitem',
      });
      final searchResponse = await _client
          .get(search, headers: headers)
          .timeout(const Duration(seconds: 12));
      if (searchResponse.statusCode < 200 || searchResponse.statusCode >= 300)
        return original;
      final searchXml = XmlDocument.parse(searchResponse.body);
      final item = searchXml.findAllElements('item').firstOrNull;
      final id = item?.getAttribute('id');
      if (id == null || id.isEmpty) return original;
      final details = Uri.https('api.rpggeek.com', '/xmlapi2/thing', {
        'id': id,
        'stats': '1',
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

  Future<Map<String, dynamic>> _json(Uri url) async {
    try {
      final response = await _client.get(
        url,
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'RpgCatalog/1.0',
        },
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
    final publisher = item
        .findAllElements('link')
        .where(
          (element) =>
              element.getAttribute('type')?.contains('publisher') ?? false,
        )
        .map((element) => element.getAttribute('value') ?? '')
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    return WorkCandidate(
      title: named,
      publisher: publisher,
      publicationDate: attrFor('yearpublished', 'value'),
      summary: textFor('description'),
      remoteCoverUrl: textFor('image'),
      rpgGeekId: id,
    );
  }

  String _description(Object? raw) {
    if (raw is Map) return raw['value']?.toString() ?? '';
    return raw?.toString() ?? '';
  }
}

extension FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
