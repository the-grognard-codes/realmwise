import 'dart:convert';
import 'dart:io';

import '../models/catalog_models.dart';
import 'diagnostic_logging.dart';

/// Writes a lossless, deterministic CSV snapshot of catalog records.
class ExportService {
  static const _unitSeparator = '\u001f';

  static const headers = <String>[
    'schema_version',
    'work_id',
    'isbn13',
    'title',
    'authors',
    'publisher',
    'publication_date',
    'summary',
    'page_count',
    'game_system',
    'game_setting',
    'book_type',
    'remote_cover_url',
    'open_library_id',
    'rpggeek_id',
    'more_info',
    'designers',
    'artists',
    'production_staff',
    'version',
    'product_code',
    'series_code',
    'dimensions',
    'series',
    'setting',
    'family',
    'system',
    'category',
    'mechanics',
    'genre',
    'created_at',
    'updated_at',
    'copy_id',
    'copy_work_id',
    'copy_condition',
    'copy_price_paid',
    'copy_currency',
    'copy_acquisition_date',
    'copy_acquired_source',
    'copy_notes',
    'copy_favorite',
    'copy_tags',
    'image_id',
    'image_work_id',
    'image_local_path',
    'image_remote_url',
    'image_caption',
    'image_is_cover',
    'image_sort_order',
  ];

  Future<void> exportRecords({
    required Iterable<CatalogRecord> records,
    required String outputPath,
    Map<int, Map<String, Object?>> timestampsByWorkId = const {},
  }) async {
    try {
      await _exportRecords(
        records: records,
        outputPath: outputPath,
        timestampsByWorkId: timestampsByWorkId,
      );
    } on Object catch (error) {
      DiagnosticDiagnostics.emit(
        DiagnosticSeverity.warning,
        'catalog.export.error',
        {
          'operation': 'csv_export',
          'outcome': 'failed',
          'errorClass': error.runtimeType.toString(),
        },
      );
      rethrow;
    }
  }

  Future<void> _exportRecords({
    required Iterable<CatalogRecord> records,
    required String outputPath,
    Map<int, Map<String, Object?>> timestampsByWorkId = const {},
  }) async {
    await File(outputPath).parent.create(recursive: true);
    final ordered = records.toList()
      ..sort((a, b) {
        final aid = a.work.id ?? -1;
        final bid = b.work.id ?? -1;
        final byId = aid.compareTo(bid);
        return byId != 0 ? byId : a.work.title.compareTo(b.work.title);
      });
    final lines = <String>[headers.map(_escape).join(',')];
    for (final record in ordered) {
      final List<UserCopy?> copies = record.copies.isEmpty
          ? <UserCopy?>[null]
          : record.copies;
      final List<BookImage?> images = record.images.isEmpty
          ? <BookImage?>[null]
          : record.images;
      for (final copy in copies) {
        for (final image in images) {
          lines.add(
            _row(
              record,
              copy,
              image,
              timestampsByWorkId[record.work.id] ?? const {},
            ),
          );
        }
      }
    }
    await File(
      outputPath,
    ).writeAsString('${lines.join('\r\n')}\r\n', encoding: utf8);
  }

  static String _row(
    CatalogRecord record,
    UserCopy? copy,
    BookImage? image,
    Map<String, Object?> timestamps,
  ) {
    final w = record.work;
    final values = <Object?>[
      '1',
      w.id,
      w.isbn13,
      w.title,
      _list(w.authors),
      w.publisher,
      w.publicationDate,
      w.summary,
      w.pageCount,
      w.gameSystem,
      w.gameSetting,
      w.bookType,
      w.remoteCoverUrl,
      w.openLibraryId,
      w.rpgGeekId,
      w.moreInfo,
      _list(w.designers),
      _list(w.artists),
      _list(w.productionStaff),
      w.version,
      w.productCode,
      w.seriesCode,
      w.dimensions,
      _list(w.series),
      _list(w.setting),
      _list(w.family),
      _list(w.system),
      _list(w.category),
      _list(w.mechanics),
      _list(w.genre),
      timestamps['created_at'],
      timestamps['updated_at'],
      copy?.id,
      copy?.workId,
      copy?.condition.name,
      copy?.pricePaid,
      copy?.currency,
      copy?.acquisitionDate,
      copy?.acquiredSource,
      copy?.notes,
      copy == null ? null : (copy.favorite ? 1 : 0),
      copy == null ? null : _list(copy.tags),
      image?.id,
      image?.workId,
      image?.localPath,
      image?.remoteUrl,
      image?.caption,
      image == null ? null : (image.isCover ? 1 : 0),
      image?.sortOrder,
    ];
    return values.map((value) => _escape(value?.toString() ?? '')).join(',');
  }

  static String _list(Iterable<String> values) => values
      .map(
        (value) =>
            value.replaceAll(_unitSeparator, '$_unitSeparator$_unitSeparator'),
      )
      .join(_unitSeparator);

  static String _escape(String value) {
    if (value.contains(',') ||
        value.contains('"') ||
        value.contains('\r') ||
        value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
