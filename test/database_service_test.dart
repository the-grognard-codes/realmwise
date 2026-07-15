import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rpg_catalog/data/database_service.dart';
import 'package:rpg_catalog/models/catalog_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'SQLite saves, updates, filters suggestions, and deletes a complete record',
    () async {
      final folder = await Directory.systemTemp.createTemp('rpg_catalog_test_');
      final service = DatabaseService();
      await service.open('${folder.path}${Platform.pathSeparator}catalog.db');

      final saved = await service.saveRecord(
        const CatalogRecord(
          work: BookWork(
            title: 'The Grand Grimoire',
            isbn13: '9781234567890',
            gameSystem: 'Arcana',
            gameSetting: 'Old Realm',
            bookType: 'Sourcebook',
          ),
          copies: [
            UserCopy(
              acquiredSource: 'Friendly Local Game Store',
              tags: ['magic', 'reference'],
            ),
          ],
        ),
      );
      expect(saved.work.id, isNotNull);
      expect(
        (await service.listRecords()).single.work.title,
        'The Grand Grimoire',
      );
      expect(await service.suggestions('game_system', 'arc'), ['Arcana']);
      expect(await service.allTags(), ['magic', 'reference']);

      final changed = await service.saveRecord(
        saved.copyWith(
          work: saved.work.copyWith(title: 'The Greater Grimoire'),
        ),
      );
      expect(changed.work.title, 'The Greater Grimoire');
      await service.deleteRecord(changed.work.id!);
      expect(await service.listRecords(), isEmpty);

      await service.close();
      await folder.delete(recursive: true);
    },
  );
}
