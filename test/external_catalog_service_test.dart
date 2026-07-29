import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:rpg_catalog/models/catalog_models.dart';
import 'package:rpg_catalog/services/external_catalog_service.dart';

void main() {
  test('tries subtitle fallback and selects its matching result', () async {
    final client = _RecordingClient((request) {
      if (request.url.path.endsWith('/search')) {
        if (request.url.queryParameters['query'] == 'Dragon Quest: Deluxe') {
          return _response('<items/>');
        }
        return _response(
          '<items><item id="42"><name value="Dragon Quest"/></item></items>',
        );
      }
      return _response(_detailXml('Dragon Quest', '42'));
    });
    final result = await ExternalCatalogService(client).enrichWithRpgGeek(
      const WorkCandidate(
        title: 'Dragon Quest: Deluxe',
        publisher: 'OL',
        isbn13: '9781234567890',
        authors: ['Open Library Author'],
      ),
      'key',
    );
    expect(result.rpgGeekId, '42');
    expect(result.title, 'Dragon Quest');
    expect(result.publisher, 'RPG Publisher');
    expect(result.isbn13, '9781234567890');
    expect(result.authors, ['Open Library Author']);
    expect(client.requests.map((request) => request.url.path), [
      '/xmlapi2/search',
      '/xmlapi2/search',
      '/xmlapi2/thing',
    ]);
  });

  test('scores exact title above the first search result', () async {
    final client = _RecordingClient((request) {
      if (request.url.path.endsWith('/search')) {
        return _response(
          '<items><item id="1"><name value="Dragon"/></item>'
          '<item id="2"><name value="The Dragon Quest"/></item>'
          '<item id="3"><name value="Dragon Quest"/></item></items>',
        );
      }
      return _response(_detailXml('Dragon Quest', '3'));
    });
    final result = await ExternalCatalogService(client).enrichWithRpgGeek(
      const WorkCandidate(title: 'Dragon Quest'),
      'key',
    );
    expect(result.rpgGeekId, '3');
    expect(client.requests.where((request) => request.url.path.endsWith('/thing')), hasLength(1));
  });

  test('detail failure leaves OpenLibrary candidate unchanged', () async {
    final original = const WorkCandidate(title: 'Missing', publisher: 'OL');
    final client = _RecordingClient((request) => request.url.path.endsWith('/search')
        ? _response('<items><item id="9"><name value="Missing"/></item></items>')
        : _response('', status: 503));
    final result = await ExternalCatalogService(client).enrichWithRpgGeek(original, 'key');
    expect(result, original);
  });

  test('ignores empty or weakly related search hits', () async {
    final original = const WorkCandidate(title: 'Dragon Quest', publisher: 'OL');
    final client = _RecordingClient((request) {
      if (request.url.path.endsWith('/search')) {
        return _response(
          '<items><item id="0"><name value=""/></item>'
          '<item id="1"><name value="Dungeon"/></item></items>',
        );
      }
      fail('weak hits must not trigger a detail request');
    });
    final result = await ExternalCatalogService(client).enrichWithRpgGeek(original, 'key');
    expect(result, same(original));
    expect(client.requests.where((request) => request.url.path.endsWith('/thing')), isEmpty);
  });

  test('captures RPGGeek extended metadata and link values', () async {
    final client = _RecordingClient((request) => request.url.path.endsWith('/search')
        ? _response('<items><item id="7"><name value="Dragon Quest"/></item></items>')
        : _response('<items><item id="7"><name value="Dragon Quest"/>'
            '<description>RPG description</description><moreinfo>https://info</moreinfo>'
            '<isbn>9780000000000</isbn><productcode>PX</productcode><seriescode>SX</seriescode>'
            '<dimensions>8x5</dimensions><link type="rpgproductcode" value="LPX"/>'
            '<link type="rpgseriescode" value="LSX"/><link type="rpgdimensions" value="L8x5"/>'
            '<link type="rpgdesigner" value="Designer"/>'
            '<link type="rpgartist" value="Artist"/><link type="rpgpublisher" value="Pub"/>'
            '<link type="rpgseries" value="Series"/><link type="rpgsetting" value="Setting"/>'
            '<link type="rpgsystem" value="System"/><link type="rpgmechanic" value="Dice"/>'
            '<link type="rpggenre" value="Fantasy"/></item></items>'));
    final result = await ExternalCatalogService(client).enrichWithRpgGeek(
      const WorkCandidate(title: 'Dragon Quest'), 'key');
    expect(result.moreInfo, 'https://info');
    expect(result.designers, ['Designer']);
    expect(result.artists, ['Artist']);
    expect(result.publisher, 'Pub');
    expect(result.series, ['Series']);
    expect(result.system, ['System']);
    expect(result.mechanics, ['Dice']);
    expect(result.genre, ['Fantasy']);
    expect(result.productCode, 'PX');
    expect(result.seriesCode, 'SX');
    expect(result.dimensions, '8x5');
  });
}

String _detailXml(String title, String id) =>
    '<items><item id="$id"><name value="$title"/><yearpublished value="2024"/>'
    '<description>Summary</description><image>https://img.test/$id.jpg</image>'
    '<link type="boardgamepublisher" value="RPG Publisher"/></item></items>';

http.Response _response(String body, {int status = 200}) =>
    http.Response(body, status, headers: {'content-type': 'application/xml'});

class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.handler);
  final http.Response Function(http.BaseRequest request) handler;
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final response = handler(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}
