import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/services/image_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reuses legacy default image directory when present', () async {
    final folder = await Directory.systemTemp.createTemp('realmwise_images_');
    final legacy = Directory(
      '${folder.path}${Platform.pathSeparator}rpg_catalog_images',
    )..createSync();
    PathProviderPlatform.instance = _FakePathProvider(folder.path);
    final storage = ImageStorageService(http.Client());
    expect(await storage.initialize(null), legacy.path);
    await folder.delete(recursive: true);
  });

  test('imports catalog icons with icon filename prefix', () async {
    final folder = await Directory.systemTemp.createTemp('rpg_icon_storage_');
    final source = File('${folder.path}${Platform.pathSeparator}source.png')
      ..writeAsBytesSync([1, 2, 3]);
    final storage = ImageStorageService(http.Client());
    await storage.initialize('${folder.path}${Platform.pathSeparator}images');
    final imported = await storage.importCatalogIcon(
      sourcePath: source.path,
      tier: 'gameSystem',
      sectionName: 'Arcana',
    );
    expect(File(imported).existsSync(), isTrue);
    expect(
      imported.split(Platform.pathSeparator).last,
      startsWith('icon_gameSystem_Arcana'),
    );
    await folder.delete(recursive: true);
  });

  test('rejects non-http remote cover URLs without making a request', () async {
    var requested = false;
    final storage = ImageStorageService(
      http.Client(),
      transport: (uri, peer) async {
        requested = true;
        return _response([1, 2, 3], 200);
      },
    );

    await expectLater(
      storage.downloadRemoteCover(
        work: const BookWork(title: 'Test'),
        remoteUrl: 'See also under Forgotten Realms',
      ),
      throwsArgumentError,
    );
    expect(requested, isFalse);
  });

  test(
    'requires HTTPS and blocks restricted DNS targets before requesting',
    () async {
      var requested = false;
      final storage = ImageStorageService(
        http.Client(),
        resolver: (_) async => [InternetAddress('127.0.0.1')],
        transport: (uri, peer) async {
          requested = true;
          return _response(_png, 200, {'content-type': 'image/png'});
        },
      );
      await expectLater(
        storage.downloadRemoteCover(
          work: const BookWork(title: 'Test'),
          remoteUrl: 'https://example.com/cover.png',
        ),
        throwsA(isA<HttpException>()),
      );
      expect(requested, isFalse);
    },
  );

  test('validates content type and image signature before saving', () async {
    final folder = await Directory.systemTemp.createTemp('rpg_remote_');
    final storage = ImageStorageService(
      http.Client(),
      resolver: (_) async => [InternetAddress('93.184.216.34')],
      transport: (uri, peer) async =>
          _response([1, 2, 3], 200, {'content-type': 'image/png'}),
    );
    await storage.initialize(folder.path);
    await expectLater(
      storage.downloadRemoteCover(
        work: const BookWork(title: 'Test'),
        remoteUrl: 'https://example.com/cover.png',
      ),
      throwsA(isA<HttpException>()),
    );
    expect(folder.listSync(recursive: true).whereType<File>(), isEmpty);
    await folder.delete(recursive: true);
  });

  test(
    'accepts a valid image when content type labels another image format',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'rpg_remote_mismatch_',
      );
      final storage = ImageStorageService(
        http.Client(),
        resolver: (_) async => [InternetAddress('93.184.216.34')],
        transport: (uri, peer) async =>
            _response(_png, 200, {'content-type': 'image/jpeg'}),
      );
      await storage.initialize(folder.path);
      final image = await storage.downloadRemoteCover(
        work: const BookWork(title: 'Test'),
        remoteUrl: 'https://example.com/cover.jpg',
      );
      expect(image.localPath, endsWith('.png'));
      await folder.delete(recursive: true);
    },
  );

  test(
    'accepts valid image bytes with absent or generic content type',
    () async {
      for (final headers in <Map<String, String>>[
        const {},
        {'content-type': 'application/octet-stream'},
      ]) {
        final folder = await Directory.systemTemp.createTemp(
          'rpg_remote_type_',
        );
        final storage = ImageStorageService(
          http.Client(),
          resolver: (_) async => [InternetAddress('93.184.216.34')],
          transport: (uri, peer) async => _response(_png, 200, headers),
        );
        await storage.initialize(folder.path);
        final image = await storage.downloadRemoteCover(
          work: const BookWork(title: 'Test'),
          remoteUrl: 'https://example.com/cover',
        );
        expect(image.localPath, endsWith('.png'));
        await folder.delete(recursive: true);
      }
    },
  );

  test(
    'rejects explicit non-image content type despite image signature',
    () async {
      final folder = await Directory.systemTemp.createTemp('rpg_remote_html_');
      final storage = ImageStorageService(
        http.Client(),
        resolver: (_) async => [InternetAddress('93.184.216.34')],
        transport: (uri, peer) async =>
            _response(_png, 200, {'content-type': 'text/html; charset=utf-8'}),
      );
      await storage.initialize(folder.path);
      await expectLater(
        storage.downloadRemoteCover(
          work: const BookWork(title: 'Test'),
          remoteUrl: 'https://example.com/cover.png',
        ),
        throwsA(isA<HttpException>()),
      );
      expect(folder.listSync(recursive: true).whereType<File>(), isEmpty);
      await folder.delete(recursive: true);
    },
  );

  test('pins a freshly resolved peer on each redirect hop', () async {
    final peers = <String>[];
    var resolveCount = 0;
    final storage = ImageStorageService(
      http.Client(),
      resolver: (_) async {
        resolveCount++;
        return [
          InternetAddress(resolveCount == 1 ? '93.184.216.34' : '1.1.1.1'),
        ];
      },
      transport: (uri, peer) async {
        peers.add('${uri.host}:${peer.address}');
        if (uri.host == 'example.com') {
          return _response(const [], 302, {
            'location': 'https://cdn.example/cover.png',
          });
        }
        return _response(_png, 200, {'content-type': 'image/png'});
      },
    );
    final folder = await Directory.systemTemp.createTemp('rpg_redirect_');
    await storage.initialize(folder.path);
    await storage.downloadRemoteCover(
      work: const BookWork(title: 'Test'),
      remoteUrl: 'https://example.com/cover.png',
    );
    expect(peers, ['example.com:93.184.216.34', 'cdn.example:1.1.1.1']);
    await folder.delete(recursive: true);
  });

  test('TLS factory pins peer while preserving request hostname', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final expectedPort = server.port;
    final accepted = server.first;
    InternetAddress? seenPeer;
    int? seenPort;
    String? seenHost;
    final task = await imagePinnedTlsConnection(
      Uri.parse('https://cdn.example/cover.png'),
      InternetAddress('127.0.0.1'),
      port: server.port,
      connector: (peer, port) {
        seenPeer = peer;
        seenPort = port;
        return Socket.startConnect(peer, port);
      },
      upgrader: (socket, {required host}) async {
        seenHost = host;
        return socket;
      },
    );
    final socket = await task.socket;
    socket.destroy();
    (await accepted).destroy();
    await server.close();

    expect(seenPeer?.address, '127.0.0.1');
    expect(seenPort, expectedPort);
    expect(seenHost, 'cdn.example');
  });

  test(
    'tries each allowed Geekdo CDN peer after a transport failure',
    () async {
      final folder = await Directory.systemTemp.createTemp('rpg_geekdo_');
      final attemptedPeers = <String>[];
      final storage = ImageStorageService(
        http.Client(),
        resolver: (host) async => [
          InternetAddress('93.184.216.34'),
          InternetAddress('1.1.1.1'),
        ],
        transport: (uri, peer) async {
          attemptedPeers.add(peer.address);
          if (attemptedPeers.length == 1) {
            throw const SocketException('simulated unreachable peer');
          }
          return _response(_png, 200, {'content-type': 'image/png'});
        },
      );
      await storage.initialize(folder.path);

      final image = await storage.downloadRemoteCover(
        work: const BookWork(title: 'Test'),
        remoteUrl: 'https://cf.geekdo-images.com/example/cover.png',
      );

      expect(attemptedPeers, ['93.184.216.34', '1.1.1.1']);
      expect(File(image.localPath).existsSync(), isTrue);
      await folder.delete(recursive: true);
    },
  );
}

http.StreamedResponse _response(
  List<int> bytes,
  int status, [
  Map<String, String>? headers,
]) => http.StreamedResponse(
  Stream<List<int>>.value(bytes),
  status,
  headers: headers ?? const {},
);

const _png = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0];

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
