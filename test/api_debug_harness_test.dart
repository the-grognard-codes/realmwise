import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:rpg_catalog/debug/api_debug_harness.dart';
import 'package:rpg_catalog/models/catalog_models.dart';
import 'package:rpg_catalog/services/external_catalog_service.dart';

void main() {
  test(
    'HTTP harness binds loopback and serves contract/error envelopes',
    () async {
      final ready = Completer<void>();
      final lookupEntered = Completer<void>();
      final harness = await ApiDebugHarness.start(
        null,
        port: 0,
        readiness: ready.future,
        openLibrary: (_) async {
          if (!lookupEntered.isCompleted) lookupEntered.complete();
          return [const WorkCandidate(title: 'Test')];
        },
        enrich: (_, key) async {
          throw Exception('failed key=$key');
        },
      );
      addTearDown(harness.close);
      expect(harness.port, greaterThan(0));
      expect(harness.boundAddress, '127.0.0.1');
      final client = http.Client();
      addTearDown(client.close);
      final pending = client.get(
        Uri.http('127.0.0.1:${harness.port}', '/lookup/openlibrary', {
          'title': 'test',
        }),
      );
      expect(lookupEntered.isCompleted, isFalse);
      ready.complete();
      await lookupEntered.future;
      final lookup = await pending;
      expect(lookup.statusCode, 200);
      expect(jsonDecode(lookup.body), containsPair('ok', true));
      expect(
        (jsonDecode(lookup.body)['results'] as List).single['title'],
        'Test',
      );
      final contract = await client.get(
        Uri.http('127.0.0.1:${harness.port}', '/openapi.json'),
      );
      expect(contract.statusCode, 200);
      final document = jsonDecode(contract.body) as Map<String, dynamic>;
      expect(document['info']['title'], 'RPG Catalog Debug Harness API');
      expect(
        document['info']['description'],
        contains('Opt-in loopback-only debug service.'),
      );
      expect(document['servers'], [
        {'url': 'http://127.0.0.1:8080'},
      ]);
      expect(
        document['paths']['/lookup/openlibrary']['get']['responses']['503'],
        isNotNull,
      );
      expect(
        document['paths']['/lookup/openlibrary']['get']['parameters'],
        hasLength(5),
      );
      final parameters =
          document['paths']['/lookup/openlibrary']['get']['parameters']
              as List<dynamic>;
      expect(
        parameters.every(
          (parameter) =>
              !(parameter as Map<String, dynamic>).containsKey('required'),
        ),
        isTrue,
      );
      expect(
        document['paths']['/lookup/rpggeek']['post']['responses']['200']['description'],
        'Result envelope',
      );
      final landing = await client.get(
        Uri.http('127.0.0.1:${harness.port}', '/'),
      );
      expect(landing.statusCode, 200);
      expect(landing.headers['content-type'], contains('text/html'));
      expect(landing.body, contains('swagger-ui.css'));
      expect(landing.body, contains('swagger-ui-bundle.js'));
      expect(landing.body, contains('swagger-ui-standalone-preset.js'));
      expect(landing.body, contains('presets: [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset]'));
      expect(landing.body, isNot(contains('SwaggerUIBundle.SwaggerUIStandalonePreset')));
      expect(landing.body, contains('swagger-ui-dist@5.11.10'));
      expect(landing.body, contains('integrity="sha256-'));
      expect(landing.body, contains('crossorigin="anonymous"'));
      expect(landing.body, contains('viewport'));
      expect(landing.body, contains('url: "/openapi.json"'));
      expect(landing.headers['content-security-policy'], contains("default-src 'none'"));
      expect(landing.body, isNot(contains('super-secret-token')));
      final operation =
          document['paths']['/lookup/openlibrary']['get'] as Map<String, dynamic>;
      expect(operation['summary'], 'Search Open Library');
      expect(operation['description'], contains('ISBN'));
      final requestSchema = document['paths']['/lookup/rpggeek']['post']
          ['requestBody']['content']['application/json']['schema'] as Map<String, dynamic>;
      final apiKeySchema = requestSchema['properties']['apiKey'] as Map<String, dynamic>;
      expect(apiKeySchema['writeOnly'], isTrue);
      expect(apiKeySchema['format'], 'password');
      expect(apiKeySchema.containsKey('example'), isFalse);
      final malformed = await client.post(
        Uri.http('127.0.0.1:${harness.port}', '/lookup/rpggeek'),
        body: jsonEncode({
          'apiKey': 'super-secret-token',
          'candidate': {'title': 'Test'},
        }),
      );
      expect(malformed.statusCode, 400);
      expect(malformed.body, isNot(contains('super-secret-token')));
      expect(jsonDecode(malformed.body)['ok'], isFalse);
    },
  );

  test(
    'invalid lookup input is 400 while catalog upstream failures are 503',
    () async {
      final harness = await ApiDebugHarness.start(
        null,
        port: 0,
        openLibrary: (_) async =>
            throw const CatalogLookupException('Could not reach OpenLibrary.'),
      );
      addTearDown(harness.close);
      final client = http.Client();
      addTearDown(client.close);
      final base = '127.0.0.1:${harness.port}';
      final invalid = await client.get(Uri.http(base, '/lookup/openlibrary'));
      expect(invalid.statusCode, 400);
      final upstream = await client.get(
        Uri.http(base, '/lookup/openlibrary', {'title': 'valid'}),
      );
      expect(upstream.statusCode, 503);
    },
  );
  test('safe debug errors never echo secrets', () {
    final response = safeDebugError(Exception('apiKey=super-secret-token'));
    expect(response['ok'], isFalse);
    expect(response['error'], isNot(contains('super-secret-token')));
  });

  test('catalog errors preserve safe message in envelope', () {
    final response = safeDebugError(
      const CatalogLookupException('invalid query'),
    );
    expect(response, {'ok': false, 'error': 'invalid query'});
  });

  test('harness is disabled by default', () {
    expect(apiDebugHarnessEnabled(), isFalse);
  });
}
