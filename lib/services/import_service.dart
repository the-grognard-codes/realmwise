import '../data/database_service.dart';
import '../models/catalog_models.dart';
import 'export_service.dart';
import 'diagnostic_logging.dart';

/// Validates and imports ExportService CSV snapshots.
class ImportService {
  ImportService(this.database);
  final DatabaseService database;

  Future<int> importCsv(String csv) async {
    try {
      return await _importCsv(csv);
    } on Object catch (error) {
      DiagnosticDiagnostics.emit(
        DiagnosticSeverity.warning,
        'catalog.import.error',
        {
          'operation': 'csv_import',
          'outcome': 'failed',
          'errorClass': error.runtimeType.toString(),
        },
      );
      rethrow;
    }
  }

  Future<int> _importCsv(String csv) async {
    final rows = _parse(csv);
    if (rows.isEmpty || !_same(rows.first, ExportService.headers)) {
      throw FormatException('CSV header does not match schema v1.');
    }
    final groups = <String, _Group>{};
    for (var n = 1; n < rows.length; n++) {
      final values = rows[n];
      if (values.length != ExportService.headers.length) {
        throw FormatException(
          'Row ${n + 1} has ${values.length} columns; expected ${ExportService.headers.length}.',
        );
      }
      final map = <String, String>{
        for (var i = 0; i < values.length; i++)
          ExportService.headers[i]: values[i],
      };
      if (map['schema_version'] != '1')
        throw FormatException('Unsupported schema version on row ${n + 1}.');
      final workId = _int(map['work_id'], 'work_id', n);
      if (workId != null && workId <= 0)
        throw FormatException('work_id must be positive on row ${n + 1}.');
      final key = workId == null
          ? 'new:${values.take(32).join('\u0000')}'
          : 'id:$workId';
      final group = groups.putIfAbsent(key, () => _Group(workId));
      final copyWork = _int(map['copy_work_id'], 'copy_work_id', n);
      final imageWork = _int(map['image_work_id'], 'image_work_id', n);
      if (copyWork != null && (workId == null || copyWork != workId))
        throw FormatException(
          'copy_work_id does not match work_id on row ${n + 1}.',
        );
      if (imageWork != null && (workId == null || imageWork != workId))
        throw FormatException(
          'image_work_id does not match work_id on row ${n + 1}.',
        );
      group.add(map, n);
    }
    final records = <CatalogRecord>[];
    final timestamps = <int, Map<String, Object?>>{};
    for (final group in groups.values) {
      final m = group.work;
      if (m['title']!.trim().isEmpty)
        throw FormatException('Title is required.');
      final work = BookWork(
        id: group.id,
        title: m['title']!,
        isbn13: m['isbn13']!,
        authors: _list(m['authors']!),
        publisher: m['publisher']!,
        publicationDate: m['publication_date']!,
        summary: m['summary']!,
        pageCount: _int(m['page_count'], 'page_count', 0),
        gameSystem: m['game_system']!,
        gameSetting: m['game_setting']!,
        bookType: m['book_type']!,
        remoteCoverUrl: m['remote_cover_url']!,
        openLibraryId: m['open_library_id']!,
        rpgGeekId: m['rpggeek_id']!,
        moreInfo: m['more_info']!,
        designers: _list(m['designers']!),
        artists: _list(m['artists']!),
        productionStaff: _list(m['production_staff']!),
        version: m['version']!,
        productCode: m['product_code']!,
        seriesCode: m['series_code']!,
        dimensions: m['dimensions']!,
        series: _list(m['series']!),
        setting: _list(m['setting']!),
        family: _list(m['family']!),
        system: _list(m['system']!),
        category: _list(m['category']!),
        mechanics: _list(m['mechanics']!),
        genre: _list(m['genre']!),
      );
      records.add(
        CatalogRecord(work: work, copies: group.copies, images: group.images),
      );
      if (group.id != null)
        timestamps[group.id!] = {
          'created_at': m['created_at'],
          'updated_at': m['updated_at'],
        };
    }
    await database.importRecords(records, timestampsByWorkId: timestamps);
    return records.length;
  }
}

class _Group {
  _Group(this.id);
  final int? id;
  final Map<String, String> work = {};
  final copies = <UserCopy>[];
  final images = <BookImage>[];
  final _copyPayloads = <String, String>{};
  final _imagePayloads = <String, String>{};
  void add(Map<String, String> row, int index) {
    if (work.isEmpty) {
      work.addAll({for (final h in ExportService.headers.take(32)) h: row[h]!});
    } else {
      for (final h in ExportService.headers.take(32)) {
        if (work[h] != row[h])
          throw FormatException('Inconsistent work data on row ${index + 1}.');
      }
    }
    final hasCopy =
        row['copy_id']!.isNotEmpty ||
        row['copy_condition']!.isNotEmpty ||
        row['copy_price_paid']!.isNotEmpty ||
        row['copy_currency']!.isNotEmpty ||
        row['copy_acquisition_date']!.isNotEmpty ||
        row['copy_acquired_source']!.isNotEmpty ||
        row['copy_notes']!.isNotEmpty ||
        row['copy_favorite']!.isNotEmpty ||
        row['copy_tags']!.isNotEmpty;
    if (hasCopy) {
      final copyPayload = _payload(row, const [
        'copy_condition',
        'copy_price_paid',
        'copy_currency',
        'copy_acquisition_date',
        'copy_acquired_source',
        'copy_notes',
        'copy_favorite',
        'copy_tags',
      ]);
      final copyKey = row['copy_id']!.isEmpty
          ? 'new:$copyPayload'
          : 'id:${row['copy_id']}';
      final existingCopy = _copyPayloads[copyKey];
      if (existingCopy != null) {
        if (existingCopy != copyPayload) {
          throw FormatException('Inconsistent copy data on row ${index + 1}.');
        }
      } else {
        _copyPayloads[copyKey] = copyPayload;
        final condition = row['copy_condition']!.isEmpty
            ? BookCondition.good.name
            : row['copy_condition']!;
        if (!BookCondition.values.any((v) => v.name == condition))
          throw FormatException('Invalid copy_condition on row ${index + 1}.');
        copies.add(
          UserCopy(
            id: _int(row['copy_id'], 'copy_id', index),
            workId: id,
            condition: BookCondition.parse(condition),
            pricePaid: _double(
              row['copy_price_paid'],
              'copy_price_paid',
              index,
            ),
            currency: row['copy_currency']!,
            acquisitionDate: row['copy_acquisition_date']!,
            acquiredSource: row['copy_acquired_source']!,
            notes: row['copy_notes']!,
            favorite: _bool(row['copy_favorite'], index),
            tags: _list(row['copy_tags']!),
          ),
        );
      }
    }
    if (row['image_id']!.isNotEmpty || row['image_local_path']!.isNotEmpty) {
      if (row['image_local_path']!.isEmpty)
        throw FormatException('Image local_path is required.');
      final imagePayload = _payload(row, const [
        'image_local_path',
        'image_remote_url',
        'image_caption',
        'image_is_cover',
        'image_sort_order',
      ]);
      final imageKey = row['image_id']!.isEmpty
          ? 'new:$imagePayload'
          : 'id:${row['image_id']}';
      final existingImage = _imagePayloads[imageKey];
      if (existingImage != null) {
        if (existingImage != imagePayload) {
          throw FormatException('Inconsistent image data on row ${index + 1}.');
        }
        return;
      }
      _imagePayloads[imageKey] = imagePayload;
      images.add(
        BookImage(
          id: _int(row['image_id'], 'image_id', index),
          workId: id,
          localPath: row['image_local_path']!,
          remoteUrl: row['image_remote_url']!,
          caption: row['image_caption']!,
          isCover: _bool(row['image_is_cover'], index),
          sortOrder:
              _int(row['image_sort_order'], 'image_sort_order', index) ?? 0,
        ),
      );
    }
  }
}

List<List<String>> _parse(String input) {
  final out = <List<String>>[];
  var row = <String>[];
  var value = StringBuffer();
  var quoted = false;
  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (c == '"') {
      if (quoted && i + 1 < input.length && input[i + 1] == '"') {
        value.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (c == ',' && !quoted) {
      row.add(value.toString());
      value = StringBuffer();
    } else if ((c == '\n' || c == '\r') && !quoted) {
      if (c == '\r' && i + 1 < input.length && input[i + 1] == '\n') i++;
      row.add(value.toString());
      value = StringBuffer();
      if (row.any((v) => v.isNotEmpty)) out.add(row);
      row = <String>[];
    } else
      value.write(c);
  }
  if (quoted)
    throw const FormatException('CSV contains an unterminated quoted field.');
  if (value.isNotEmpty || row.isNotEmpty) {
    row.add(value.toString());
    out.add(row);
  }
  return out;
}

String _payload(Map<String, String> row, List<String> headers) =>
    headers.map((header) => row[header]!).join('\u0000');
bool _same(List<String> a, List<String> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => a[i] == b[i]).every((x) => x);
int? _int(String? s, String field, int row) {
  if (s == null || s.isEmpty) return null;
  final v = int.tryParse(s);
  if (v == null) throw FormatException('Invalid $field on row ${row + 1}.');
  return v;
}

double? _double(String? s, String field, int row) {
  if (s == null || s.isEmpty) return null;
  final v = double.tryParse(s);
  if (v == null) throw FormatException('Invalid $field on row ${row + 1}.');
  return v;
}

bool _bool(String? s, int row) {
  if (s == null || s.isEmpty) return false;
  if (s == '1') return true;
  if (s == '0') return false;
  throw FormatException('Invalid boolean on row ${row + 1}.');
}

List<String> _list(String value) {
  if (value.isEmpty) return const [];
  final out = <String>[];
  var part = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    if (value[i] == '\u001f') {
      if (i + 1 < value.length && value[i + 1] == '\u001f') {
        part.write('\u001f');
        i++;
      } else {
        out.add(part.toString());
        part = StringBuffer();
      }
    } else
      part.write(value[i]);
  }
  out.add(part.toString());
  return out;
}
