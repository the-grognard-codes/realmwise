import 'dart:convert';
import 'dart:io';

import '../models/catalog_models.dart';
import '../services/app_controller.dart';
import '../services/external_catalog_service.dart';

/// Opt-in loopback HTTP harness for manually exercising remote catalog APIs.
class ApiDebugHarness {
  ApiDebugHarness._(this._server, this.port);
  final HttpServer _server;
  final int port;
  String get boundAddress => (_server.address.address);

  static Future<ApiDebugHarness> start(
    AppController? controller, {
    int? port,
    Future<void>? readiness,
    Future<List<WorkCandidate>> Function(Uri uri)? openLibrary,
    Future<List<WorkCandidate>> Function(String query, String key)? rpgGeekSearch,
    Future<WorkCandidate> Function(String id, String key)? rpgGeekThing,
    @Deprecated('Use rpgGeekSearch/rpgGeekThing') Future<WorkCandidate> Function(WorkCandidate candidate, String key)? enrich,
  }) async {
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port ?? _configuredPort(),
    );
    final harness = ApiDebugHarness._(server, server.port);
    server.listen(
      (request) =>
          harness._handle(request, controller, readiness, openLibrary, rpgGeekSearch, rpgGeekThing, enrich),
    );
    return harness;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(
    HttpRequest request,
    AppController? controller,
    Future<void>? readiness,
    Future<List<WorkCandidate>> Function(Uri uri)? openLibrary,
    Future<List<WorkCandidate>> Function(String query, String key)? rpgGeekSearch,
    Future<WorkCandidate> Function(String id, String key)? rpgGeekThing,
    Future<WorkCandidate> Function(WorkCandidate candidate, String key)? enrich,
  ) async {
    try {
      if (request.method == 'GET' && request.uri.path == '/')
        return _html(request);
      if (request.method == 'GET' && request.uri.path == '/openapi.json')
        return _json(request, _openApi, 200);
      if (request.method == 'GET' &&
          request.uri.path == '/lookup/openlibrary') {
        if (readiness != null) await readiness;
        final q = request.uri.queryParameters;
        final name = q['ownerName'];
        final email = q['ownerEmail'];
        final isbn = q['isbn']?.trim() ?? '';
        final title = q['title']?.trim() ?? '';
        final author = q['author']?.trim() ?? '';
        if (isbn.isEmpty && title.isEmpty && author.isEmpty) {
          return _json(
            request,
            safeDebugError(
              const CatalogLookupException('Provide isbn, title, or author.'),
            ),
            400,
          );
        }
        final result = openLibrary != null
            ? await openLibrary(request.uri)
            : q['isbn']?.trim().isNotEmpty == true
            ? await _requireController(controller).lookup.searchByIsbn(
                q['isbn']!,
                ownerName: name,
                ownerEmail: email,
              )
            : await _requireController(controller).lookup.searchByTitleOrAuthor(
                term: author.isNotEmpty ? author : title,
                author: author.isNotEmpty,
                ownerName: name,
                ownerEmail: email,
              );
        return _json(request, {
          'ok': true,
          'results': result.map(_candidateJson).toList(),
        }, 200);
      }
      if (request.method == 'GET' && request.uri.path == '/lookup/rpggeek/search') {
        if (readiness != null) await readiness;
        final query = request.uri.queryParameters['query']?.trim() ?? '';
        final key = _bearer(request);
        if (query.length < 2 || key.isEmpty) throw const CatalogLookupException('Provide query and Authorization Bearer token.');
        final results = rpgGeekSearch != null ? await rpgGeekSearch(query, key) : await _requireController(controller).lookup.searchRpgGeek(query, key);
        return _json(request, {
          'ok': true,
          'results': results.map(_candidateJson).toList(),
        }, 200);
      }
      if (request.method == 'GET' && request.uri.path.startsWith('/lookup/rpggeek/thing/')) {
        if (readiness != null) await readiness;
        final id = request.uri.path.substring('/lookup/rpggeek/thing/'.length).trim();
        final key = _bearer(request);
        if (id.isEmpty || key.isEmpty) throw const CatalogLookupException('Provide item id and Authorization Bearer token.');
        final result = rpgGeekThing != null ? await rpgGeekThing(id, key) : await _requireController(controller).lookup.fetchRpgGeekItem(id, key);
        return _json(request, {
          'ok': true,
          'result': _candidateJson(result),
        }, 200);
      }
      return _json(request, {'ok': false, 'error': 'Not found'}, 404);
    } on CatalogLookupException catch (error) {
      final invalid =
          error.message == 'Enter a 13-digit ISBN.' ||
          error.message == 'Type at least two characters to search.' ||
          error.message == 'Provide isbn, title, or author.' ||
          error.message.startsWith('Provide query') ||
          error.message.startsWith('Provide item id');
      return _json(request, safeDebugError(error), invalid ? 400 : 503);
    } catch (error) {
      return _json(request, safeDebugError(error), 503);
    }
  }

  Future<void> _json(HttpRequest request, Object value, int status) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(value));
    await request.response.close();
  }

  Future<void> _html(HttpRequest request) async {
    request.response.headers.contentType = ContentType.html;
    request.response.headers.set(
      'Content-Security-Policy',
      "default-src 'none'; style-src https://unpkg.com; script-src https://unpkg.com 'unsafe-inline'; img-src data: https://unpkg.com; connect-src 'self'; font-src https://unpkg.com;",
    );
    request.response.write(
      '<!doctype html>\n'
      '<html lang="en"><head>\n'
      '<meta charset="utf-8">\n'
      '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
      '<title>Realmwise API</title>\n'
      '<link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 32 32%22><text y=%2224%22 font-size=%2224%22>R</text></svg>">\n'
      '<link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5.11.10/swagger-ui.css" integrity="sha256-WudGeIrWwvGbuMdjjWO1dE4+/rqss7yrzNySjb7GxN8=" crossorigin="anonymous">\n'
      '</head><body><div id="swagger-ui"></div>\n'
      '<script src="https://unpkg.com/swagger-ui-dist@5.11.10/swagger-ui-bundle.js" integrity="sha256-rrxl4znrA7X2/cHNouSsYygu+oqjdJpEgjJolOBlsVI=" crossorigin="anonymous"></script>\n'
      '<script src="https://unpkg.com/swagger-ui-dist@5.11.10/swagger-ui-standalone-preset.js" integrity="sha256-L2Pxpxznpse9e5MAAJATjBH2qVRIrbDdlm9X4t1fBlU=" crossorigin="anonymous"></script>\n'
      '<script>window.onload = function() { SwaggerUIBundle({ url: "/openapi.json", dom_id: "#swagger-ui", deepLinking: true, presets: [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset], layout: "StandaloneLayout" }); };</script>\n'
      '</body></html>',
    );
    await request.response.close();
  }
}

String _bearer(HttpRequest request) {
  final value = request.headers.value('authorization')?.trim() ?? '';
  if (!value.toLowerCase().startsWith('bearer ')) return '';
  return value.substring(7).trim();
}

int _configuredPort() =>
    int.tryParse(
      const String.fromEnvironment('API_DEBUG_PORT', defaultValue: '8080'),
    ) ??
    8080;
bool apiDebugHarnessEnabled() =>
    const String.fromEnvironment(
      'API_DEBUG_HARNESS',
      defaultValue: 'false',
    ).toLowerCase() ==
    'true';
Map<String, dynamic> safeDebugError(Object error) => {
  'ok': false,
  'error': error is CatalogLookupException
      ? error.message
      : 'Request could not be completed.',
};

Map<String, dynamic> _candidateJson(WorkCandidate c) => {
  'title': c.title,
  'isbn13': c.isbn13,
  'authors': c.authors,
  'publisher': c.publisher,
  'publicationDate': c.publicationDate,
  'summary': c.summary,
  'pageCount': c.pageCount,
  'remoteCoverUrl': c.remoteCoverUrl,
  'openLibraryId': c.openLibraryId,
  'rpgGeekId': c.rpgGeekId,
  'rpgGeekUrl': c.rpgGeekUrl,
  'gameSystem': c.gameSystem,
  'gameSetting': c.gameSetting,
  'bookType': c.bookType,
  'moreInfo': c.moreInfo,
  'designers': c.designers,
  'artists': c.artists,
  'productionStaff': c.productionStaff,
  'version': c.version,
  'isbn': c.isbn,
  'productCode': c.productCode,
  'seriesCode': c.seriesCode,
  'dimensions': c.dimensions,
  'series': c.series,
  'setting': c.setting,
  'family': c.family,
  'system': c.system,
  'category': c.category,
  'mechanics': c.mechanics,
  'genre': c.genre,
};

// ignore: unused_element
WorkCandidate _candidate(Map<String, dynamic> m) => WorkCandidate(
  title: m['title']?.toString() ?? '',
  isbn13: m['isbn13']?.toString() ?? '',
  authors: (m['authors'] as List? ?? const [])
      .map((e) => e.toString())
      .toList(),
  publisher: m['publisher']?.toString() ?? '',
  publicationDate: m['publicationDate']?.toString() ?? '',
  summary: m['summary']?.toString() ?? '',
  pageCount: (m['pageCount'] as num?)?.toInt(),
  remoteCoverUrl: m['remoteCoverUrl']?.toString() ?? '',
  openLibraryId: m['openLibraryId']?.toString() ?? '',
  rpgGeekId: m['rpgGeekId']?.toString() ?? '',
  gameSystem: m['gameSystem']?.toString() ?? '',
  gameSetting: m['gameSetting']?.toString() ?? '',
  bookType: m['bookType']?.toString() ?? '',
  moreInfo: m['moreInfo']?.toString() ?? '',
  designers: _list(m['designers']), artists: _list(m['artists']),
  productionStaff: _list(m['productionStaff']), version: m['version']?.toString() ?? '',
  isbn: m['isbn']?.toString() ?? '', productCode: m['productCode']?.toString() ?? '',
  seriesCode: m['seriesCode']?.toString() ?? '', dimensions: m['dimensions']?.toString() ?? '',
  series: _list(m['series']), setting: _list(m['setting']), family: _list(m['family']),
  system: _list(m['system']), category: _list(m['category']), mechanics: _list(m['mechanics']),
  genre: _list(m['genre']),
);

List<String> _list(Object? value) => (value as List? ?? const []).map((e) => e.toString()).toList();

AppController _requireController(AppController? controller) =>
    controller ??
    (throw StateError('A controller is required for this request.'));

final Map<String, dynamic> _openApi = {
  'openapi': '3.0.3',
  'info': {
    'title': 'Realmwise Debug Harness API',
    'version': '1.0.0',
    'description':
        'Opt-in loopback-only debug service. Swagger is available at / and this contract at /openapi.json. API keys are writeOnly, never persisted by requests, returned, or logged.',
  },
  'servers': [
    {'url': 'http://127.0.0.1:8080'},
  ],
  'paths': {
    '/lookup/openlibrary': {
      'get': {
        'summary': 'Search Open Library',
        'description':
            'Search by ISBN, title, or author. Optional owner fields are forwarded for catalog attribution.',
        'responses': {
          '200': {
            'description': 'Results envelope',
            'content': {
              'application/json': {
                'schema': {r'$ref': '#/components/schemas/Results'},
                'example': {
                  'ok': true,
                  'results': [
                    {
                      'title': 'Dungeons & Dragons',
                      'isbn13': '9780132350884',
                      'authors': ['Gary Gygax'],
                    },
                  ],
                },
              },
            },
          },
          '400': {
            'description': 'Invalid request',
            'content': {
              'application/json': {
                'schema': {r'$ref': '#/components/schemas/Error'},
              },
            },
          },
          '503': {
            'description': 'Upstream unavailable',
            'content': {
              'application/json': {
                'schema': {r'$ref': '#/components/schemas/Error'},
              },
            },
          },
        },
        'parameters': [
          for (final name in [
            'isbn',
            'title',
            'author',
            'ownerName',
            'ownerEmail',
          ])
            {
              'name': name,
              'in': 'query',
              'description': switch (name) {
                'isbn' => 'A 13-digit ISBN to look up.',
                'title' => 'Title search term.',
                'author' => 'Author search term.',
                'ownerName' => 'Optional catalog owner name.',
                _ => 'Optional catalog owner email.',
              },
              'schema': {
                'type': 'string',
                if (name == 'ownerEmail') 'format': 'email',
              },
              if (name == 'isbn') 'example': '9780132350884',
              if (name == 'title') 'example': 'Dungeons & Dragons',
              if (name == 'author') 'example': 'Gary Gygax',
            },
        ],
      },
    },
    '/lookup/rpggeek/search': {
      'get': {
        'summary': 'Search RPGGeek RPG items',
        'description':
            'Returns ranked RPGGeek rpgitem candidates. Supply the credential in the Authorization Bearer header.',
        'security': [
          {'bearerAuth': <String, dynamic>{}},
        ],
        'parameters': [
          {
            'name': 'query',
            'in': 'query',
            'required': true,
            'schema': {'type': 'string'},
          },
        ],
        'responses': {
          '200': {
            'description': 'Ranked RPGGeek candidates envelope',
            'content': {
              'application/json': {
                'schema': {r'$ref': '#/components/schemas/Results'},
              },
            },
          },
          '400': {'description': 'Invalid request'},
          '503': {'description': 'Upstream unavailable'},
        },
      },
    },
    '/lookup/rpggeek/thing/{id}': {
      'get': {
        'summary': 'Fetch raw RPGGeek item detail',
        'security': [
          {'bearerAuth': <String, dynamic>{}},
        ],
        'parameters': [
          {
            'name': 'id',
            'in': 'path',
            'required': true,
            'schema': {'type': 'string'},
          },
        ],
        'responses': {
          '200': {
            'description': 'RPGGeek item envelope',
            'content': {
              'application/json': {
                'schema': {r'$ref': '#/components/schemas/Result'},
              },
            },
          },
          '400': {'description': 'Invalid request'},
          '503': {'description': 'Upstream unavailable'},
        },
      },
    },
    '/openapi.json': {
      'get': {
        'summary': 'Get the OpenAPI contract',
        'description': 'Returns this machine-readable API contract.',
        'responses': {
          '200': {
            'description': 'This OpenAPI document',
            'content': {
              'application/json': {
                'schema': {'type': 'object'},
              },
            },
          },
        },
      },
    },
  },
  'components': {
    'securitySchemes': {
      'bearerAuth': {
        'type': 'http',
        'scheme': 'bearer',
        'bearerFormat': 'API key',
      },
    },
    'schemas': {
      'Error': {
        'type': 'object',
        'description': 'Safe error envelope. Secret values are never included.',
        'required': ['ok', 'error'],
        'properties': {
          'ok': {
            'type': 'boolean',
            'enum': [false],
          },
          'error': {'type': 'string'},
        },
      },
      'Candidate': {
        'type': 'object',
        'description': 'A catalog work candidate and optional remote metadata. Nonempty RPGGeek title, publisher, publicationDate, summary, and remoteCoverUrl values override Open Library values; OpenLibrary-only fields such as ISBN and authors, plus any RPGGeek-absent fields, remain.',
        'properties': {
          'title': {'type': 'string'},
          'isbn13': {'type': 'string'},
          'authors': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'publisher': {'type': 'string'},
          'publicationDate': {'type': 'string'},
          'summary': {'type': 'string'},
          'pageCount': {'type': 'integer', 'nullable': true},
          'remoteCoverUrl': {'type': 'string'},
          'openLibraryId': {'type': 'string'},
          'rpgGeekId': {'type': 'string'},
          'rpgGeekUrl': {
            'type': 'string',
            'format': 'uri',
            'nullable': true,
            'readOnly': true,
            'description': 'Public RPGGeek item page derived from rpgGeekId.',
          },
          'gameSystem': {'type': 'string'},
          'gameSetting': {'type': 'string'},
          'bookType': {'type': 'string'},
          'moreInfo': {'type': 'string'},
          for (final name in ['designers','artists','productionStaff','series','setting','family','system','category','mechanics','genre'])
            name: {'type': 'array', 'items': {'type': 'string'}},
          for (final name in ['version','isbn','productCode','seriesCode','dimensions'])
            name: {'type': 'string'},
        },
      },
      'Results': {
        'type': 'object',
        'description': 'Successful Open Library search response.',
        'required': ['ok', 'results'],
        'properties': {
          'ok': {
            'type': 'boolean',
            'enum': [true],
          },
          'results': {
            'type': 'array',
            'items': {r'$ref': '#/components/schemas/Candidate'},
          },
        },
      },
      'Result': {
        'type': 'object',
        'description': 'Successful RPGGeek enrichment response.',
        'required': ['ok', 'result'],
        'properties': {
          'ok': {
            'type': 'boolean',
            'enum': [true],
          },
          'result': {r'$ref': '#/components/schemas/Candidate'},
        },
      },
    },
  },
};
