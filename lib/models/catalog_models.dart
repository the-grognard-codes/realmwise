import 'dart:convert';

/// Metadata shared by every physical copy of a published RPG book.
class BookWork {
  const BookWork({
    this.id,
    required this.title,
    this.isbn13 = '',
    this.authors = const [],
    this.publisher = '',
    this.publicationDate = '',
    this.summary = '',
    this.pageCount,
    this.gameSystem = '',
    this.gameSetting = '',
    this.bookType = '',
    this.remoteCoverUrl = '',
    this.openLibraryId = '',
    this.rpgGeekId = '',
  });

  final int? id;
  final String isbn13;
  final String title;
  final List<String> authors;
  final String publisher;
  final String publicationDate;
  final String summary;
  final int? pageCount;
  final String gameSystem;
  final String gameSetting;
  final String bookType;
  final String remoteCoverUrl;
  final String openLibraryId;
  final String rpgGeekId;

  /// The public RPGGeek item page for this work, when an ID is available.
  String? get rpgGeekUrl {
    final id = rpgGeekId.trim();
    if (!RegExp(r'^[0-9]+$').hasMatch(id)) return null;
    return Uri(
      scheme: 'https',
      host: 'rpggeek.com',
      pathSegments: ['rpgitem', id],
    ).toString();
  }

  BookWork copyWith({
    int? id,
    String? isbn13,
    String? title,
    List<String>? authors,
    String? publisher,
    String? publicationDate,
    String? summary,
    int? pageCount,
    bool clearPageCount = false,
    String? gameSystem,
    String? gameSetting,
    String? bookType,
    String? remoteCoverUrl,
    String? openLibraryId,
    String? rpgGeekId,
  }) =>
      BookWork(
        id: id ?? this.id,
        isbn13: isbn13 ?? this.isbn13,
        title: title ?? this.title,
        authors: authors ?? this.authors,
        publisher: publisher ?? this.publisher,
        publicationDate: publicationDate ?? this.publicationDate,
        summary: summary ?? this.summary,
        pageCount: clearPageCount ? null : (pageCount ?? this.pageCount),
        gameSystem: gameSystem ?? this.gameSystem,
        gameSetting: gameSetting ?? this.gameSetting,
        bookType: bookType ?? this.bookType,
        remoteCoverUrl: remoteCoverUrl ?? this.remoteCoverUrl,
        openLibraryId: openLibraryId ?? this.openLibraryId,
        rpgGeekId: rpgGeekId ?? this.rpgGeekId,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'isbn13': isbn13.trim().isEmpty ? null : isbn13.trim(),
        'title': title.trim(),
        'authors': jsonEncode(authors),
        'publisher': publisher.trim(),
        'publication_date': publicationDate.trim(),
        'summary': summary.trim(),
        'page_count': pageCount,
        'game_system': gameSystem.trim(),
        'game_setting': gameSetting.trim(),
        'book_type': bookType.trim(),
        'remote_cover_url': remoteCoverUrl.trim(),
        'open_library_id': openLibraryId.trim(),
        'rpggeek_id': rpgGeekId.trim(),
      };

  factory BookWork.fromRow(Map<String, Object?> row) => BookWork(
        id: row['id'] as int?,
        isbn13: row['isbn13'] as String? ?? '',
        title: row['title'] as String? ?? '',
        authors: _stringList(row['authors']),
        publisher: row['publisher'] as String? ?? '',
        publicationDate: row['publication_date'] as String? ?? '',
        summary: row['summary'] as String? ?? '',
        pageCount: row['page_count'] as int?,
        gameSystem: row['game_system'] as String? ?? '',
        gameSetting: row['game_setting'] as String? ?? '',
        bookType: row['book_type'] as String? ?? '',
        remoteCoverUrl: row['remote_cover_url'] as String? ?? '',
        openLibraryId: row['open_library_id'] as String? ?? '',
        rpgGeekId: row['rpggeek_id'] as String? ?? '',
      );
}

/// Condition and acquisition notes for a particular owned physical copy.
class UserCopy {
  const UserCopy({
    this.id,
    this.workId,
    this.condition = BookCondition.good,
    this.pricePaid,
    this.currency = 'USD',
    this.acquisitionDate = '',
    this.acquiredSource = '',
    this.notes = '',
    this.favorite = false,
    this.tags = const [],
  });

  final int? id;
  final int? workId;
  final BookCondition condition;
  final double? pricePaid;
  final String currency;
  final String acquisitionDate;
  final String acquiredSource;
  final String notes;
  final bool favorite;
  final List<String> tags;

  UserCopy copyWith({
    int? id,
    int? workId,
    BookCondition? condition,
    double? pricePaid,
    bool clearPrice = false,
    String? currency,
    String? acquisitionDate,
    String? acquiredSource,
    String? notes,
    bool? favorite,
    List<String>? tags,
  }) =>
      UserCopy(
        id: id ?? this.id,
        workId: workId ?? this.workId,
        condition: condition ?? this.condition,
        pricePaid: clearPrice ? null : (pricePaid ?? this.pricePaid),
        currency: currency ?? this.currency,
        acquisitionDate: acquisitionDate ?? this.acquisitionDate,
        acquiredSource: acquiredSource ?? this.acquiredSource,
        notes: notes ?? this.notes,
        favorite: favorite ?? this.favorite,
        tags: tags ?? this.tags,
      );

  Map<String, Object?> toRow(int assignedWorkId) => {
        'id': id,
        'work_id': assignedWorkId,
        'condition_name': condition.name,
        'price_paid': pricePaid,
        'currency': currency.trim(),
        'acquisition_date': acquisitionDate.trim(),
        'acquired_source': acquiredSource.trim(),
        'notes': notes.trim(),
        'favorite': favorite ? 1 : 0,
        'tags': jsonEncode(tags),
      };

  factory UserCopy.fromRow(Map<String, Object?> row) => UserCopy(
        id: row['id'] as int?,
        workId: row['work_id'] as int?,
        condition: BookCondition.parse(row['condition_name'] as String?),
        pricePaid: (row['price_paid'] as num?)?.toDouble(),
        currency: row['currency'] as String? ?? 'USD',
        acquisitionDate: row['acquisition_date'] as String? ?? '',
        acquiredSource: row['acquired_source'] as String? ?? '',
        notes: row['notes'] as String? ?? '',
        favorite: (row['favorite'] as int? ?? 0) == 1,
        tags: _stringList(row['tags']),
      );
}

enum BookCondition {
  mint('Mint'),
  nearMint('Near mint'),
  excellent('Excellent'),
  good('Good'),
  poor('Poor'),
  damaged('Damaged');

  const BookCondition(this.label);
  final String label;

  static BookCondition parse(String? value) => BookCondition.values.firstWhere(
        (condition) => condition.name == value,
        orElse: () => BookCondition.good,
      );
}

/// A locally-owned image; remoteUrl preserves source provenance.
class BookImage {
  const BookImage({
    this.id,
    this.workId,
    required this.localPath,
    this.remoteUrl = '',
    this.caption = '',
    this.isCover = false,
    this.sortOrder = 0,
  });

  final int? id;
  final int? workId;
  final String localPath;
  final String remoteUrl;
  final String caption;
  final bool isCover;
  final int sortOrder;

  BookImage copyWith({
    int? id,
    int? workId,
    String? localPath,
    String? remoteUrl,
    String? caption,
    bool? isCover,
    int? sortOrder,
  }) =>
      BookImage(
        id: id ?? this.id,
        workId: workId ?? this.workId,
        localPath: localPath ?? this.localPath,
        remoteUrl: remoteUrl ?? this.remoteUrl,
        caption: caption ?? this.caption,
        isCover: isCover ?? this.isCover,
        sortOrder: sortOrder ?? this.sortOrder,
      );

  Map<String, Object?> toRow(int assignedWorkId) => {
        'id': id,
        'work_id': assignedWorkId,
        'local_path': localPath,
        'remote_url': remoteUrl,
        'caption': caption,
        'is_cover': isCover ? 1 : 0,
        'sort_order': sortOrder,
      };

  factory BookImage.fromRow(Map<String, Object?> row) => BookImage(
        id: row['id'] as int?,
        workId: row['work_id'] as int?,
        localPath: row['local_path'] as String? ?? '',
        remoteUrl: row['remote_url'] as String? ?? '',
        caption: row['caption'] as String? ?? '',
        isCover: (row['is_cover'] as int? ?? 0) == 1,
        sortOrder: row['sort_order'] as int? ?? 0,
      );
}

/// Complete, editable catalog record shown in the UI.
class CatalogRecord {
  const CatalogRecord({
    required this.work,
    this.copies = const [],
    this.images = const [],
  });

  final BookWork work;
  final List<UserCopy> copies;
  final List<BookImage> images;

  BookImage? get cover {
    for (final image in images) {
      if (image.isCover) return image;
    }
    return images.isEmpty ? null : images.first;
  }

  List<String> get tags => copies
      .expand((copy) => copy.tags)
      .map((tag) => tag.trim())
      .where((tag) => tag.isNotEmpty)
      .toSet()
      .toList()
    ..sort();

  bool matches(String query, String? tag) {
    final needle = query.trim().toLowerCase();
    final text = <String>[
      work.isbn13,
      work.title,
      ...work.authors,
      work.publisher,
      work.gameSystem,
      work.gameSetting,
      work.bookType,
      ...tags,
    ].join(' ').toLowerCase();
    return (needle.isEmpty || text.contains(needle)) &&
        (tag == null || tags.contains(tag));
  }

  CatalogRecord copyWith({
    BookWork? work,
    List<UserCopy>? copies,
    List<BookImage>? images,
  }) =>
      CatalogRecord(
        work: work ?? this.work,
        copies: copies ?? this.copies,
        images: images ?? this.images,
      );
}

/// A normalized result from OpenLibrary/RPGGeek before the collector owns it.
class WorkCandidate {
  const WorkCandidate({
    required this.title,
    this.isbn13 = '',
    this.authors = const [],
    this.publisher = '',
    this.publicationDate = '',
    this.summary = '',
    this.pageCount,
    this.remoteCoverUrl = '',
    this.openLibraryId = '',
    this.rpgGeekId = '',
    this.gameSystem = '',
    this.gameSetting = '',
    this.bookType = '',
  });

  final String title;
  final String isbn13;
  final List<String> authors;
  final String publisher;
  final String publicationDate;
  final String summary;
  final int? pageCount;
  final String remoteCoverUrl;
  final String openLibraryId;
  final String rpgGeekId;
  final String gameSystem;
  final String gameSetting;
  final String bookType;

  /// The public RPGGeek item page for this candidate, when an ID is available.
  String? get rpgGeekUrl {
    final id = rpgGeekId.trim();
    if (!RegExp(r'^[0-9]+$').hasMatch(id)) return null;
    return Uri(
      scheme: 'https',
      host: 'rpggeek.com',
      pathSegments: ['rpgitem', id],
    ).toString();
  }

  WorkCandidate mergeRpgGeek(WorkCandidate rpgGeek) => WorkCandidate(
        title: rpgGeek.title.trim().isNotEmpty ? rpgGeek.title : title,
        isbn13: rpgGeek.isbn13.trim().isNotEmpty ? rpgGeek.isbn13 : isbn13,
        authors: rpgGeek.authors.isNotEmpty ? rpgGeek.authors : authors,
        publisher:
            rpgGeek.publisher.trim().isNotEmpty ? rpgGeek.publisher : publisher,
        publicationDate: rpgGeek.publicationDate.trim().isNotEmpty
            ? rpgGeek.publicationDate
            : publicationDate,
        summary: rpgGeek.summary.trim().isNotEmpty ? rpgGeek.summary : summary,
        pageCount: rpgGeek.pageCount ?? pageCount,
        remoteCoverUrl: rpgGeek.remoteCoverUrl.trim().isNotEmpty
            ? rpgGeek.remoteCoverUrl
            : remoteCoverUrl,
        openLibraryId: openLibraryId,
        rpgGeekId: rpgGeek.rpgGeekId,
        gameSystem: rpgGeek.gameSystem.trim().isNotEmpty
            ? rpgGeek.gameSystem
            : gameSystem,
        gameSetting: rpgGeek.gameSetting.trim().isNotEmpty
            ? rpgGeek.gameSetting
            : gameSetting,
        bookType:
            rpgGeek.bookType.trim().isNotEmpty ? rpgGeek.bookType : bookType,
      );

  CatalogRecord toRecord() => CatalogRecord(
        work: BookWork(
          title: title,
          isbn13: isbn13,
          authors: authors,
          publisher: publisher,
          publicationDate: publicationDate,
          summary: summary,
          pageCount: pageCount,
          remoteCoverUrl: remoteCoverUrl,
          openLibraryId: openLibraryId,
          rpgGeekId: rpgGeekId,
          gameSystem: gameSystem,
          gameSetting: gameSetting,
          bookType: bookType,
        ),
        copies: const [UserCopy()],
      );
}

List<String> _stringList(Object? stored) {
  if (stored == null || stored.toString().isEmpty) return const [];
  try {
    final decoded = jsonDecode(stored.toString());
    if (decoded is List)
      return decoded.map((value) => value.toString()).toList();
  } on FormatException {
    // Compatibility with manually edited/older databases that used commas.
  }
  return stored
      .toString()
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();
}
