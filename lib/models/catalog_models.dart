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
    this.moreInfo = '',
    this.designers = const [],
    this.artists = const [],
    this.productionStaff = const [],
    this.version = '',
    this.productCode = '',
    this.seriesCode = '',
    this.dimensions = '',
    this.series = const [],
    this.setting = const [],
    this.family = const [],
    this.system = const [],
    this.category = const [],
    this.mechanics = const [],
    this.genre = const [],
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
  final String moreInfo, version, productCode, seriesCode, dimensions;
  final List<String> designers,
      artists,
      productionStaff,
      series,
      setting,
      family,
      system,
      category,
      mechanics,
      genre;

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
    String? moreInfo,
    List<String>? designers,
    List<String>? artists,
    List<String>? productionStaff,
    String? version,
    String? productCode,
    String? seriesCode,
    String? dimensions,
    List<String>? series,
    List<String>? setting,
    List<String>? family,
    List<String>? system,
    List<String>? category,
    List<String>? mechanics,
    List<String>? genre,
  }) => BookWork(
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
    moreInfo: moreInfo ?? this.moreInfo,
    designers: designers ?? this.designers,
    artists: artists ?? this.artists,
    productionStaff: productionStaff ?? this.productionStaff,
    version: version ?? this.version,
    productCode: productCode ?? this.productCode,
    seriesCode: seriesCode ?? this.seriesCode,
    dimensions: dimensions ?? this.dimensions,
    series: series ?? this.series,
    setting: setting ?? this.setting,
    family: family ?? this.family,
    system: system ?? this.system,
    category: category ?? this.category,
    mechanics: mechanics ?? this.mechanics,
    genre: genre ?? this.genre,
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
    'more_info': moreInfo.trim(),
    'designers': jsonEncode(designers),
    'artists': jsonEncode(artists),
    'production_staff': jsonEncode(productionStaff),
    'version': version.trim(),
    'product_code': productCode.trim(),
    'series_code': seriesCode.trim(),
    'dimensions': dimensions.trim(),
    'series': jsonEncode(series),
    'setting': jsonEncode(setting),
    'family': jsonEncode(family),
    'system': jsonEncode(system),
    'category': jsonEncode(category),
    'mechanics': jsonEncode(mechanics),
    'genre': jsonEncode(genre),
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
    moreInfo: row['more_info'] as String? ?? '',
    designers: _stringList(row['designers']),
    artists: _stringList(row['artists']),
    productionStaff: _stringList(row['production_staff']),
    version: row['version'] as String? ?? '',
    productCode: row['product_code'] as String? ?? '',
    seriesCode: row['series_code'] as String? ?? '',
    dimensions: row['dimensions'] as String? ?? '',
    series: _stringList(row['series']),
    setting: _stringList(row['setting']),
    family: _stringList(row['family']),
    system: _stringList(row['system']),
    category: _stringList(row['category']),
    mechanics: _stringList(row['mechanics']),
    genre: _stringList(row['genre']),
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
  }) => UserCopy(
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
  nearMint('Near Mint'),
  veryFine('Very Fine'),
  fine('Fine'),
  veryGood('Very Good'),
  good('Good'),
  fair('Fair'),
  poor('Poor');

  const BookCondition(this.label);
  final String label;

  static BookCondition parse(String? value) {
    switch (value) {
      case 'excellent':
        return BookCondition.veryFine;
      case 'damaged':
        return BookCondition.poor;
      default:
        return BookCondition.values.firstWhere(
          (condition) => condition.name == value,
          orElse: () => BookCondition.good,
        );
    }
  }
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
    this.sourceType = ImageSourceType.userImported,
  });

  final int? id;
  final int? workId;
  final String localPath;
  final String remoteUrl;
  final String caption;
  final bool isCover;
  final int sortOrder;
  final ImageSourceType sourceType;

  BookImage copyWith({
    int? id,
    int? workId,
    String? localPath,
    String? remoteUrl,
    String? caption,
    bool? isCover,
    int? sortOrder,
    ImageSourceType? sourceType,
  }) => BookImage(
    id: id ?? this.id,
    workId: workId ?? this.workId,
    localPath: localPath ?? this.localPath,
    remoteUrl: remoteUrl ?? this.remoteUrl,
    caption: caption ?? this.caption,
    isCover: isCover ?? this.isCover,
    sortOrder: sortOrder ?? this.sortOrder,
    sourceType: sourceType ?? this.sourceType,
  );

  Map<String, Object?> toRow(int assignedWorkId) => {
    'id': id,
    'work_id': assignedWorkId,
    'local_path': localPath,
    'remote_url': remoteUrl,
    'caption': caption,
    'is_cover': isCover ? 1 : 0,
    'sort_order': sortOrder,
    'source_type': sourceType.name,
  };

  factory BookImage.fromRow(Map<String, Object?> row) => BookImage(
    id: row['id'] as int?,
    workId: row['work_id'] as int?,
    localPath: row['local_path'] as String? ?? '',
    remoteUrl: row['remote_url'] as String? ?? '',
    caption: row['caption'] as String? ?? '',
    isCover: (row['is_cover'] as int? ?? 0) == 1,
    sortOrder: row['sort_order'] as int? ?? 0,
    sourceType: ImageSourceType.parse(
      row['source_type'] as String?,
      localPath: row['local_path'] as String?,
      remoteUrl: row['remote_url'] as String?,
    ),
  );
}

enum ImageSourceType {
  userImported,
  remoteCache,
  packagedAsset;

  static ImageSourceType parse(
    String? value, {
    String? localPath,
    String? remoteUrl,
  }) {
    switch (value) {
      case 'remoteCache':
        return remoteCache;
      case 'packagedAsset':
        return packagedAsset;
      case 'userImported':
        return userImported;
    }
    // Legacy compatibility: infer only when explicit provenance is absent.
    if ((remoteUrl ?? '').trim().isNotEmpty && (localPath ?? '').trim().isEmpty)
      return remoteCache;
    if ((localPath ?? '').replaceAll('\\', '/').startsWith('assets/'))
      return packagedAsset;
    return userImported;
  }
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

  List<String> get tags =>
      copies
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
  }) => CatalogRecord(
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
    this.moreInfo = '',
    this.designers = const [],
    this.artists = const [],
    this.productionStaff = const [],
    this.version = '',
    this.isbn = '',
    this.productCode = '',
    this.seriesCode = '',
    this.dimensions = '',
    this.series = const [],
    this.setting = const [],
    this.family = const [],
    this.system = const [],
    this.category = const [],
    this.mechanics = const [],
    this.genre = const [],
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
  final String moreInfo, version, isbn, productCode, seriesCode, dimensions;
  final List<String> designers,
      artists,
      productionStaff,
      series,
      setting,
      family,
      system,
      category,
      mechanics,
      genre;

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
    publisher: rpgGeek.publisher.trim().isNotEmpty
        ? rpgGeek.publisher
        : publisher,
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
    bookType: rpgGeek.bookType.trim().isNotEmpty ? rpgGeek.bookType : bookType,
    moreInfo: _prefer(rpgGeek.moreInfo, moreInfo),
    designers: _preferList(rpgGeek.designers, designers),
    artists: _preferList(rpgGeek.artists, artists),
    productionStaff: _preferList(rpgGeek.productionStaff, productionStaff),
    version: _prefer(rpgGeek.version, version),
    isbn: _prefer(rpgGeek.isbn, isbn),
    productCode: _prefer(rpgGeek.productCode, productCode),
    seriesCode: _prefer(rpgGeek.seriesCode, seriesCode),
    dimensions: _prefer(rpgGeek.dimensions, dimensions),
    series: _preferList(rpgGeek.series, series),
    setting: _preferList(rpgGeek.setting, setting),
    family: _preferList(rpgGeek.family, family),
    system: _preferList(rpgGeek.system, system),
    category: _preferList(rpgGeek.category, category),
    mechanics: _preferList(rpgGeek.mechanics, mechanics),
    genre: _preferList(rpgGeek.genre, genre),
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
      moreInfo: moreInfo,
      designers: designers,
      artists: artists,
      productionStaff: productionStaff,
      version: version,
      productCode: productCode,
      seriesCode: seriesCode,
      dimensions: dimensions,
      series: series,
      setting: setting,
      family: family,
      system: system,
      category: category,
      mechanics: mechanics,
      genre: genre,
    ),
    copies: const [UserCopy()],
  );
}

String _prefer(String a, String b) => a.trim().isNotEmpty ? a : b;
List<String> _preferList(List<String> a, List<String> b) =>
    a.isNotEmpty ? a : b;

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
