import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rpg_catalog/models/catalog_models.dart';
import 'package:rpg_catalog/services/image_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('imports catalog icons with icon filename prefix', () async {
    final folder = await Directory.systemTemp.createTemp('rpg_icon_storage_');
    final source = File('${folder.path}${Platform.pathSeparator}source.png')..writeAsBytesSync([1, 2, 3]);
    final storage = ImageStorageService(http.Client());
    await storage.initialize('${folder.path}${Platform.pathSeparator}images');
    final imported = await storage.importCatalogIcon(sourcePath: source.path, tier: 'gameSystem', sectionName: 'Arcana');
    expect(File(imported).existsSync(), isTrue);
    expect(imported.split(Platform.pathSeparator).last, startsWith('icon_gameSystem_Arcana'));
    await folder.delete(recursive: true);
  });

  test('rejects non-http remote cover URLs without making a request', () async {
    var requested = false;
    final client = MockClient((request) async {
      requested = true;
      return http.Response.bytes([1, 2, 3], 200);
    });
    final storage = ImageStorageService(client);

    await expectLater(
      storage.downloadRemoteCover(
        work: const BookWork(title: 'Test'),
        remoteUrl: 'See also under Forgotten Realms',
      ),
      throwsArgumentError,
    );
    expect(requested, isFalse);
  });
}
