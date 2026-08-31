import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/services/export_service.dart';

void main() {
  test('exports a flat, escaped and future-importable schema', () async {
    final directory = await Directory.systemTemp.createTemp('rpg-export-');
    addTearDown(() => directory.delete(recursive: true));
    final output = '${directory.path}${Platform.pathSeparator}catalog.csv';
    const sep = '\u001f';
    const second = 'Second';
    final record = CatalogRecord(
      work: const BookWork(
        id: 3,
        title: 'A, "quoted" book',
        summary: 'line one\nline two',
        authors: ['A$sep"uthor', second],
        designers: ['D${sep}signer'],
      ),
      copies: const [
        UserCopy(
          condition: BookCondition.mint,
          favorite: true,
          tags: ['one', 'two'],
        ),
        UserCopy(id: 7, condition: BookCondition.poor),
      ],
      images: const [
        BookImage(localPath: 'C:\\cover.png', isCover: true),
        BookImage(id: 8, localPath: 'back.png'),
      ],
    );
    await ExportService().exportRecords(
      records: [record],
      outputPath: output,
      timestampsByWorkId: const {
        3: {'created_at': '2024-01-02T03:04:05Z', 'updated_at': null},
      },
    );
    final rows = _parseCsv(await File(output).readAsString());
    expect(rows, hasLength(5)); // header plus 2 copies x 2 images
    final header = rows.first;
    expect(header, orderedEquals(ExportService.headers));
    expect(header.where((h) => h.contains('json')), isEmpty);
    final row = rows[1];
    expect(row[header.indexOf('title')], record.work.title);
    expect(row[header.indexOf('summary')], record.work.summary);
    expect(row[header.indexOf('authors')], 'A$sep$sep"uthor$sep$second');
    expect(row[header.indexOf('created_at')], '2024-01-02T03:04:05Z');
    expect(row[header.indexOf('updated_at')], isEmpty);
    expect(row[header.indexOf('copy_favorite')], '1');
    expect(row[header.indexOf('copy_tags')], 'one${sep}two');
    expect(row[header.indexOf('image_local_path')], r'C:\cover.png');
  });

  test('emits one blank-related row when relations are absent', () async {
    final directory = await Directory.systemTemp.createTemp(
      'rpg-export-empty-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final output = '${directory.path}${Platform.pathSeparator}catalog.csv';
    await ExportService().exportRecords(
      records: const [CatalogRecord(work: BookWork(title: 'Solo'))],
      outputPath: output,
    );
    final rows = _parseCsv(await File(output).readAsString());
    expect(rows, hasLength(2));
    expect(rows[1][ExportService.headers.indexOf('title')], 'Solo');
    expect(rows[1][ExportService.headers.indexOf('copy_id')], isEmpty);
    expect(rows[1][ExportService.headers.indexOf('image_id')], isEmpty);
  });
}

List<List<String>> _parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  var value = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '"') {
      if (quoted && i + 1 < text.length && text[i + 1] == '"') {
        value.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (c == ',' && !quoted) {
      row.add(value.toString());
      value = StringBuffer();
    } else if (c == '\n' && !quoted) {
      if (value.length > 0 || row.isNotEmpty) {
        row.add(value.toString().replaceAll('\r', ''));
        rows.add(row);
      }
      row = <String>[];
      value = StringBuffer();
    } else {
      value.write(c);
    }
  }
  return rows;
}
