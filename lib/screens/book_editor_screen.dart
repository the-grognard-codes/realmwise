import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;

import '../models/catalog_models.dart';
import '../services/app_controller.dart';
import '../widgets/autocomplete_field.dart';
import '../widgets/cover_image.dart';
import 'search_add_screen.dart';

const _currencies = <({String code, String name})>[
  (code: 'USD', name: 'United States Dollar'),
  (code: 'EUR', name: 'European Euro'),
  (code: 'JPY', name: 'Japanese Yen'),
  (code: 'GBP', name: 'British Pound Sterling'),
  (code: 'AUD', name: 'Australian Dollar'),
  (code: 'CAD', name: 'Canadian Dollar'),
  (code: 'CHF', name: 'Swiss Franc'),
  (code: 'CNY', name: 'Chinese Yuan Renminbi'),
  (code: 'SEK', name: 'Swedish Krona'),
  (code: 'MXN', name: 'Mexican Peso'),
  (code: 'NZD', name: 'New Zealand Dollar'),
  (code: 'SGD', name: 'Singapore Dollar'),
  (code: 'HKD', name: 'Hong Kong Dollar'),
  (code: 'NOK', name: 'Norwegian Krone'),
  (code: 'KRW', name: 'South Korean Won'),
  (code: 'TRY', name: 'Turkish Lira'),
  (code: 'INR', name: 'Indian Rupee'),
  (code: 'RUB', name: 'Russian Ruble'),
  (code: 'BRL', name: 'Brazilian Real'),
  (code: 'ZAR', name: 'South African Rand'),
];

const _currencyByCountry = <String, String>{
  'AT': 'EUR',
  'AU': 'AUD',
  'BE': 'EUR',
  'BG': 'EUR',
  'BR': 'BRL',
  'CA': 'CAD',
  'CH': 'CHF',
  'CN': 'CNY',
  'CY': 'EUR',
  'DE': 'EUR',
  'EE': 'EUR',
  'ES': 'EUR',
  'FI': 'EUR',
  'FR': 'EUR',
  'GB': 'GBP',
  'GR': 'EUR',
  'HK': 'HKD',
  'HR': 'EUR',
  'IE': 'EUR',
  'IN': 'INR',
  'IT': 'EUR',
  'JP': 'JPY',
  'KR': 'KRW',
  'LI': 'CHF',
  'LT': 'EUR',
  'LU': 'EUR',
  'LV': 'EUR',
  'MC': 'EUR',
  'ME': 'EUR',
  'MT': 'EUR',
  'MX': 'MXN',
  'NL': 'EUR',
  'NO': 'NOK',
  'NZ': 'NZD',
  'PT': 'EUR',
  'RU': 'RUB',
  'SE': 'SEK',
  'SG': 'SGD',
  'SI': 'EUR',
  'SK': 'EUR',
  'SM': 'EUR',
  'TR': 'TRY',
  'US': 'USD',
  'VA': 'EUR',
  'XK': 'EUR',
  'ZA': 'ZAR',
};

String _defaultCurrencyForDeviceLocale() {
  final countryCode =
      WidgetsBinding.instance.platformDispatcher.locale.countryCode;
  return _currencyByCountry[countryCode?.toUpperCase()] ?? 'USD';
}

/// Full work/copy/image editor. It is intentionally one route so every mutation is saveable offline.
class BookEditorScreen extends StatefulWidget {
  const BookEditorScreen({
    super.key,
    required this.controller,
    required this.record,
    this.navigationRecords = const [],
    this.navigationIndex = -1,
  });
  final AppController controller;
  final CatalogRecord record;
  final List<CatalogRecord> navigationRecords;
  final int navigationIndex;

  @override
  State<BookEditorScreen> createState() => _BookEditorScreenState();
}

class _BookEditorScreenState extends State<BookEditorScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  late CatalogRecord _record;
  late CatalogRecord _savedRecord;
  late TabController _tabs;
  var _copyIndex = 0;
  var _saving = false;
  late int _navigationIndex;
  late final List<CatalogRecord> _navigationRecords;

  late final TextEditingController _isbn;
  late final TextEditingController _productCode;
  late final TextEditingController _title;
  late final TextEditingController _authors;
  late final TextEditingController _publisher;
  late final TextEditingController _published;
  late final TextEditingController _pages;
  late final TextEditingController _system;
  late final TextEditingController _setting;
  late final TextEditingController _bookType;
  late final TextEditingController _summary;
  late final TextEditingController _price;
  late final TextEditingController _currency;
  late final TextEditingController _acquiredDate;
  late final TextEditingController _acquiredSource;
  late final TextEditingController _notes;
  late final TextEditingController _tags;
  BookCondition _condition = BookCondition.good;
  bool _favorite = false;

  @override
  void initState() {
    super.initState();
    _navigationIndex = widget.navigationIndex;
    _navigationRecords = List<CatalogRecord>.of(widget.navigationRecords);
    final defaultCurrency = _defaultCurrencyForDeviceLocale();
    _record = widget.record.copyWith(
      copies: widget.record.copies.isEmpty
          ? [UserCopy(currency: defaultCurrency)]
          : widget.record.copies
                .map(
                  (copy) => copy.id == null && copy.currency == 'USD'
                      ? copy.copyWith(currency: defaultCurrency)
                      : copy,
                )
                .toList(),
      images: List.of(widget.record.images),
    );
    _savedRecord = _record;
    _tabs = TabController(length: 3, vsync: this);
    _isbn = TextEditingController(text: _record.work.isbn13);
    _productCode = TextEditingController(text: _record.work.productCode);
    _title = TextEditingController(text: _record.work.title);
    _authors = TextEditingController(text: _record.work.authors.join(', '));
    _publisher = TextEditingController(text: _record.work.publisher);
    _published = TextEditingController(text: _record.work.publicationDate);
    _pages = TextEditingController(
      text: _record.work.pageCount?.toString() ?? '',
    );
    _system = TextEditingController(text: _record.work.gameSystem);
    _setting = TextEditingController(text: _record.work.gameSetting);
    _bookType = TextEditingController(text: _record.work.bookType);
    _summary = TextEditingController(text: _record.work.summary);
    _price = TextEditingController();
    _currency = TextEditingController();
    _acquiredDate = TextEditingController();
    _acquiredSource = TextEditingController();
    _notes = TextEditingController();
    _tags = TextEditingController();
    _loadCopy(0);
    if (_record.images.isEmpty &&
        _record.work.remoteCoverUrl.trim().isNotEmpty) {
      _loadRemoteCover();
    }
  }

  /// Pre-fetch a searched work's cover so it is visible in the Images tab
  /// before the user saves the record. A failed fetch is intentionally
  /// non-fatal: the URL remains available for the save-time retry.
  Future<void> _loadRemoteCover() async {
    final work = _record.work;
    final remoteUrl = work.remoteCoverUrl.trim();
    if (remoteUrl.isEmpty || _record.images.isNotEmpty) return;

    try {
      final downloaded = await widget.controller.imageStorage
          .downloadRemoteCover(work: work, remoteUrl: remoteUrl);
      if (!mounted) {
        await widget.controller.imageStorage.deleteImage(downloaded);
        return;
      }
      if (_record.images.isNotEmpty) {
        await widget.controller.imageStorage.deleteImage(downloaded);
        return;
      }
      setState(() => _record = _record.copyWith(images: [downloaded]));
    } catch (_) {
      // Network images are optional; retain the URL for the save-time retry.
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    for (final controller in [
      _isbn,
      _productCode,
      _title,
      _authors,
      _publisher,
      _published,
      _pages,
      _system,
      _setting,
      _bookType,
      _summary,
      _price,
      _currency,
      _acquiredDate,
      _acquiredSource,
      _notes,
      _tags,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  List<String> _splitTags(String value) => value
      .split(',')
      .map((tag) => tag.trim())
      .where((tag) => tag.isNotEmpty)
      .toSet()
      .toList();
  int? _intOrNull(String value) => int.tryParse(value.trim());
  double? _doubleOrNull(String value) =>
      double.tryParse(value.trim().replaceAll(',', ''));

  void _loadCopy(int index) {
    final copy = _record.copies[index];
    _copyIndex = index;
    _condition = copy.condition;
    _price.text = copy.pricePaid?.toString() ?? '';
    final currency = copy.currency.toUpperCase();
    _currency.text = _currencies.any((option) => option.code == currency)
        ? currency
        : 'USD';
    _acquiredDate.text = copy.acquisitionDate;
    _acquiredSource.text = copy.acquiredSource;
    _notes.text = copy.notes;
    _tags.text = copy.tags.join(', ');
    _favorite = copy.favorite;
  }

  void _commitCopy() {
    final updated = _record.copies[_copyIndex].copyWith(
      condition: _condition,
      pricePaid: _doubleOrNull(_price.text),
      clearPrice: _price.text.trim().isEmpty,
      currency: _currency.text.trim().isEmpty
          ? 'USD'
          : _currency.text.trim().toUpperCase(),
      acquisitionDate: _acquiredDate.text,
      acquiredSource: _acquiredSource.text,
      notes: _notes.text,
      favorite: _favorite,
      tags: _splitTags(_tags.text),
    );
    final copies = List<UserCopy>.of(_record.copies)..[_copyIndex] = updated;
    _record = _record.copyWith(copies: copies);
  }

  BookWork _committedWork() => _record.work.copyWith(
    isbn13: _isbn.text.replaceAll(RegExp(r'[^0-9Xx]'), ''),
    productCode: _productCode.text,
    title: _title.text,
    authors: _authors.text
        .split(',')
        .map((author) => author.trim())
        .where((author) => author.isNotEmpty)
        .toList(),
    publisher: _publisher.text,
    publicationDate: _published.text,
    pageCount: _intOrNull(_pages.text),
    clearPageCount: _pages.text.trim().isEmpty,
    gameSystem: _system.text,
    gameSetting: _setting.text,
    bookType: _bookType.text,
    summary: _summary.text,
  );

  String _recordFingerprint(CatalogRecord record) => jsonEncode({
    'work': record.work.toRow(),
    'copies': record.copies
        .map((copy) => copy.toRow(record.work.id ?? 0))
        .toList(),
    'images': record.images
        .map((image) => image.toRow(record.work.id ?? 0))
        .toList(),
  });

  Future<bool> _save({bool close = true, bool showFeedback = true}) async {
    if (!(_formKey.currentState?.validate() ?? false)) return false;
    _commitCopy();
    setState(() => _saving = true);
    try {
      _record = await widget.controller.catalog.save(
        _record.copyWith(work: _committedWork()),
      );
      _savedRecord = _record;
      if (_navigationIndex >= 0 &&
          _navigationIndex < _navigationRecords.length) {
        _navigationRecords[_navigationIndex] = _record;
      }
      if (mounted) {
        if (showFeedback) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Catalog record saved locally.')),
          );
        }
        if (close) Navigator.pop(context, true);
      }
      return true;
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not save: $error')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    return false;
  }

  Future<void> _navigate(int delta) async {
    if (_saving || _navigationRecords.isEmpty) return;
    final next = _navigationIndex + delta;
    if (next < 0 || next >= _navigationRecords.length) return;
    // Save before changing records so edits (including copy fields) are not lost,
    // but leave untouched records alone and keep arrow navigation quiet.
    _commitCopy();
    final current = _record.copyWith(work: _committedWork());
    if (_recordFingerprint(current) != _recordFingerprint(_savedRecord) &&
        (!await _save(close: false, showFeedback: false) || !mounted)) {
      return;
    }
    if (!mounted) return;
    _navigationIndex = next;
    _loadRecord(_navigationRecords[next]);
  }

  void _loadRecord(CatalogRecord record) {
    final defaultCurrency = _defaultCurrencyForDeviceLocale();
    final loaded = record.copyWith(
      copies: record.copies.isEmpty
          ? [UserCopy(currency: defaultCurrency)]
          : record.copies
                .map(
                  (copy) => copy.id == null && copy.currency == 'USD'
                      ? copy.copyWith(currency: defaultCurrency)
                      : copy,
                )
                .toList(),
      images: List.of(record.images),
    );
    setState(() {
      _record = loaded;
      _savedRecord = loaded;
      _isbn.text = loaded.work.isbn13;
      _productCode.text = loaded.work.productCode;
      _title.text = loaded.work.title;
      _authors.text = loaded.work.authors.join(', ');
      _publisher.text = loaded.work.publisher;
      _published.text = loaded.work.publicationDate;
      _pages.text = loaded.work.pageCount?.toString() ?? '';
      _system.text = loaded.work.gameSystem;
      _setting.text = loaded.work.gameSetting;
      _bookType.text = loaded.work.bookType;
      _summary.text = loaded.work.summary;
      _loadCopy(0);
    });
    if (loaded.images.isEmpty && loaded.work.remoteCoverUrl.trim().isNotEmpty) {
      _loadRemoteCover();
    }
  }

  Future<void> _refreshFromRemote() async {
    if (_saving) return;
    _commitCopy();
    final candidate = await Navigator.push<WorkCandidate>(
      context,
      MaterialPageRoute(
        builder: (context) => SearchAddScreen(
          controller: widget.controller,
          selectionOnly: true,
          initialIsbn: _record.work.isbn13,
          initialTitle: _record.work.title,
          initialAuthors: _record.work.authors.join(', '),
          onSaved: () {},
        ),
      ),
    );
    if (candidate == null || !mounted) return;

    final refreshed = candidate.toRecord().work;
    final existingImages = _record.images;
    final merged = _record.work.copyWith(
      isbn13: refreshed.isbn13,
      title: refreshed.title,
      authors: refreshed.authors,
      publisher: refreshed.publisher,
      publicationDate: refreshed.publicationDate,
      summary: refreshed.summary,
      pageCount: refreshed.pageCount,
      clearPageCount: refreshed.pageCount == null,
      gameSystem: refreshed.gameSystem.trim().isEmpty
          ? _record.work.gameSystem
          : refreshed.gameSystem,
      gameSetting: refreshed.gameSetting.trim().isEmpty
          ? _record.work.gameSetting
          : refreshed.gameSetting,
      bookType: refreshed.bookType.trim().isEmpty
          ? _record.work.bookType
          : refreshed.bookType,
      remoteCoverUrl: refreshed.remoteCoverUrl,
      openLibraryId: refreshed.openLibraryId,
      rpgGeekId: refreshed.rpgGeekId,
      moreInfo: refreshed.moreInfo,
      designers: refreshed.designers,
      artists: refreshed.artists,
      productionStaff: refreshed.productionStaff,
      version: refreshed.version,
      productCode: refreshed.productCode,
      seriesCode: refreshed.seriesCode,
      dimensions: refreshed.dimensions,
      series: refreshed.series,
      setting: refreshed.setting,
      family: refreshed.family,
      system: refreshed.system,
      category: refreshed.category,
      mechanics: refreshed.mechanics,
      genre: refreshed.genre,
    );
    setState(() {
      _record = _record.copyWith(work: merged, images: existingImages);
      _isbn.text = merged.isbn13;
      _productCode.text = merged.productCode;
      _title.text = merged.title;
      _authors.text = merged.authors.join(', ');
      _publisher.text = merged.publisher;
      _published.text = merged.publicationDate;
      _pages.text = merged.pageCount?.toString() ?? '';
      _system.text = merged.gameSystem;
      _setting.text = merged.gameSetting;
      _bookType.text = merged.bookType;
      _summary.text = merged.summary;
    });
    if (existingImages.isEmpty && merged.remoteCoverUrl.trim().isNotEmpty) {
      await _loadRemoteCover();
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Work details refreshed.')));
    }
  }

  Future<void> _delete() async {
    if (_record.work.id == null) {
      if (mounted) Navigator.pop(context);
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this book?'),
        content: Text(
          'This removes “${_record.work.title}”, every saved copy, and its local image files.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    setState(() => _saving = true);
    try {
      await widget.controller.catalog.delete(_record);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not remove book: $error')),
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addCopy() async {
    _commitCopy();
    setState(() {
      _record = _record.copyWith(
        copies: [
          ..._record.copies,
          UserCopy(currency: _defaultCurrencyForDeviceLocale()),
        ],
      );
      _loadCopy(_record.copies.length - 1);
    });
  }

  Future<void> _removeCopy() async {
    if (_record.copies.length == 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'A catalog book needs at least one owned copy. Remove the book instead.',
          ),
        ),
      );
      return;
    }
    _commitCopy();
    setState(() {
      final copies = List<UserCopy>.of(_record.copies)..removeAt(_copyIndex);
      _record = _record.copyWith(copies: copies);
      _loadCopy(_copyIndex.clamp(0, copies.length - 1).toInt());
    });
  }

  Future<void> _pickAcquiredDate() async {
    final initial = DateTime.tryParse(_acquiredDate.text) ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
      initialDate: initial,
    );
    if (date != null)
      setState(
        () => _acquiredDate.text = DateFormat('yyyy-MM-dd').format(date),
      );
  }

  Future<void> _importImages() async {
    final label = await _imageLabelDialog();
    if (label == null) return;
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      dialogTitle: 'Add local book images',
    );
    if (result == null) return;
    _commitCopy();
    final imported = <BookImage>[];
    for (final selected in result.files) {
      final selectedPath = selected.path;
      if (selectedPath == null) continue;
      try {
        imported.add(
          await widget.controller.imageStorage.importFile(
            work: _committedWork(),
            sourcePath: selectedPath,
            label: result.files.length == 1
                ? label
                : '${label}_${path.basenameWithoutExtension(selected.name)}',
            cover: _record.images.isEmpty && imported.isEmpty,
          ),
        );
      } on Exception catch (error) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not add ${selected.name}: $error')),
          );
      }
    }
    if (imported.isNotEmpty && mounted)
      setState(
        () => _record = _record.copyWith(
          images: [..._record.images, ...imported],
        ),
      );
  }

  Future<String?> _imageLabelDialog() async {
    final label = TextEditingController(text: 'image');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Image filename label'),
        content: TextField(
          controller: label,
          maxLength: 32,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Up to 32 characters'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, label.text),
            child: const Text('Choose images'),
          ),
        ],
      ),
    );
    label.dispose();
    return result;
  }

  Future<void> _setCover(int index) async {
    final revised = List<BookImage>.of(_record.images);
    final old = revised.indexWhere((image) => image.isCover);
    if (old >= 0 && old != index)
      revised[old] = await widget.controller.imageStorage.setCover(
        revised[old],
        false,
      );
    revised[index] = await widget.controller.imageStorage.setCover(
      revised[index],
      true,
    );
    if (mounted) setState(() => _record = _record.copyWith(images: revised));
  }

  Future<void> _removeImage(int index) async {
    final image = _record.images[index];
    await widget.controller.imageStorage.deleteImage(image);
    final revised = List<BookImage>.of(_record.images)..removeAt(index);
    if (revised.isNotEmpty && !revised.any((item) => item.isCover))
      await _setCoverAfterRemoval(revised, 0);
    if (mounted) setState(() => _record = _record.copyWith(images: revised));
  }

  Future<void> _setCoverAfterRemoval(List<BookImage> images, int index) async {
    images[index] = await widget.controller.imageStorage.setCover(
      images[index],
      true,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        _record.work.id == null ? 'Add book details' : 'Book details',
      ),
      actions: [
        if (_navigationRecords.isNotEmpty) ...[
          IconButton(
            tooltip: 'Previous book',
            onPressed: _saving || _navigationIndex <= 0
                ? null
                : () => _navigate(-1),
            icon: const Icon(Icons.arrow_back),
          ),
          IconButton(
            tooltip: 'Next book',
            onPressed:
                _saving || _navigationIndex >= _navigationRecords.length - 1
                ? null
                : () => _navigate(1),
            icon: const Icon(Icons.arrow_forward),
          ),
        ],
        if (_record.work.id != null)
          IconButton(
            tooltip: 'Remove book',
            onPressed: _saving ? null : _delete,
            icon: const Icon(Icons.delete_outline),
          ),
        IconButton(
          tooltip: 'Refresh work details',
          onPressed: _saving ? null : _refreshFromRemote,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: 'Save',
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.save_outlined),
        ),
      ],
      bottom: TabBar(
        controller: _tabs,
        tabs: const [
          Tab(text: 'Work'),
          Tab(text: 'My copy'),
          Tab(text: 'Images'),
        ],
      ),
    ),
    body: Form(
      key: _formKey,
      child: _saving
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [_workTab(), _copyTab(), _imagesTab()],
            ),
    ),
    floatingActionButton: _saving
        ? null
        : FloatingActionButton.extended(
            heroTag: null,
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('Save'),
          ),
  );

  Widget _workTab() => _ScrollForm(
    children: [
      _section('Work metadata'),
      TextFormField(
        controller: _isbn,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: 'ISBN-13'),
        validator: (value) {
          final cleaned = (value ?? '').replaceAll(RegExp(r'[^0-9Xx]'), '');
          return cleaned.isNotEmpty && cleaned.length != 13
              ? 'ISBN-13 must contain 13 digits.'
              : null;
        },
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _productCode,
        decoration: const InputDecoration(labelText: 'Product code'),
      ),
      const SizedBox(height: 12),
      LocalAutocompleteField(
        controller: _title,
        label: 'Book title *',
        suggestions: (text) =>
            widget.controller.catalog.suggestions('title', text),
        validator: (value) =>
            value?.trim().isEmpty ?? true ? 'A book title is required.' : null,
      ),
      const SizedBox(height: 12),
      TextFormField(
        controller: _authors,
        decoration: const InputDecoration(
          labelText: 'Authors (comma separated)',
        ),
      ),
      const SizedBox(height: 12),
      LocalAutocompleteField(
        controller: _publisher,
        label: 'Publisher',
        suggestions: (text) =>
            widget.controller.catalog.suggestions('publisher', text),
      ),
      const SizedBox(height: 12),
      _ResponsiveFields(
        children: [
          TextFormField(
            controller: _published,
            decoration: const InputDecoration(labelText: 'Publication date'),
          ),
          TextFormField(
            controller: _pages,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Page count'),
            validator: (value) =>
                value?.trim().isNotEmpty == true && _intOrNull(value!) == null
                ? 'Use a whole number.'
                : null,
          ),
        ],
      ),
      const SizedBox(height: 20),
      _section('Catalog hierarchy'),
      LocalAutocompleteField(
        controller: _system,
        label: 'Game system',
        suggestions: (text) =>
            widget.controller.catalog.suggestions('game_system', text),
      ),
      const SizedBox(height: 12),
      LocalAutocompleteField(
        controller: _setting,
        label: 'Game setting',
        suggestions: (text) =>
            widget.controller.catalog.suggestions('game_setting', text),
      ),
      const SizedBox(height: 12),
      LocalAutocompleteField(
        controller: _bookType,
        label: 'Book type',
        suggestions: (text) =>
            widget.controller.catalog.suggestions('book_type', text),
      ),
      const SizedBox(height: 20),
      TextFormField(
        controller: _summary,
        minLines: 5,
        maxLines: 10,
        decoration: const InputDecoration(
          labelText: 'Summary',
          alignLabelWithHint: true,
        ),
      ),
    ],
  );

  Widget _copyTab() {
    final selection = DropdownButton<int>(
      value: _copyIndex,
      isExpanded: true,
      items: List.generate(
        _record.copies.length,
        (index) => DropdownMenuItem(
          value: index,
          child: Text(
            'Copy ${index + 1}${_record.copies[index].favorite ? ' • Favorite' : ''}',
          ),
        ),
      ),
      onChanged: (index) {
        if (index == null) return;
        _commitCopy();
        setState(() => _loadCopy(index));
      },
    );
    return _ScrollForm(
      children: [
        _section('Owned copy'),
        Row(
          children: [
            Expanded(child: selection),
            IconButton(
              onPressed: _addCopy,
              tooltip: 'Add another owned copy',
              icon: const Icon(Icons.add_circle_outline),
            ),
            IconButton(
              onPressed: _removeCopy,
              tooltip: 'Remove this copy',
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ],
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<BookCondition>(
          key: ValueKey('condition-$_copyIndex'),
          initialValue: _condition,
          decoration: const InputDecoration(labelText: 'Condition'),
          items: BookCondition.values
              .map(
                (condition) => DropdownMenuItem(
                  value: condition,
                  child: Text(condition.label),
                ),
              )
              .toList(),
          onChanged: (value) =>
              setState(() => _condition = value ?? BookCondition.good),
        ),
        const SizedBox(height: 12),
        _ResponsiveFields(
          children: [
            TextFormField(
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Price paid'),
              validator: (value) =>
                  value?.trim().isNotEmpty == true &&
                      _doubleOrNull(value!) == null
                  ? 'Use a number.'
                  : null,
            ),
            DropdownButtonFormField<String>(
              key: ValueKey('currency-$_copyIndex'),
              initialValue: _currency.text,
              decoration: const InputDecoration(labelText: 'Currency'),
              items: _currencies
                  .map(
                    (currency) => DropdownMenuItem(
                      value: currency.code,
                      child: Text('${currency.code}: ${currency.name}'),
                    ),
                  )
                  .toList(),
              onChanged: (value) => _currency.text = value ?? 'USD',
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _acquiredDate,
          readOnly: true,
          onTap: _pickAcquiredDate,
          decoration: const InputDecoration(
            labelText: 'Acquisition date',
            suffixIcon: Icon(Icons.calendar_today),
          ),
        ),
        const SizedBox(height: 12),
        LocalAutocompleteField(
          key: ValueKey('acquired-source-$_copyIndex'),
          controller: _acquiredSource,
          label: 'Acquired source',
          suggestions: (text) =>
              widget.controller.catalog.suggestions('acquired_source', text),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _tags,
          decoration: const InputDecoration(
            labelText: 'Tags (comma separated)',
            helperText: 'Tags become available as catalog filters.',
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _favorite,
          onChanged: (value) => setState(() => _favorite = value),
          title: const Text('Favorite'),
          secondary: const Icon(Icons.favorite_outline),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _notes,
          minLines: 5,
          maxLines: 10,
          decoration: const InputDecoration(
            labelText: 'Copy notes',
            alignLabelWithHint: true,
          ),
        ),
      ],
    );
  }

  Widget _imagesTab() => _ScrollForm(
    children: [
      _section('Local work images'),
      const Text(
        'Images are copied to the configured local image folder. The selected cover is named with “_cover” immediately before its extension.',
      ),
      const SizedBox(height: 14),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: List.generate(_record.images.length, (index) {
          final image = _record.images[index];
          return SizedBox(
            width: 166,
            child: Card(
              child: Column(
                children: [
                  CoverImage(image: image, width: 166, height: 185),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      image.isCover
                          ? 'Current cover'
                          : (image.caption.isEmpty ? 'Image' : image.caption),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  OverflowBar(
                    alignment: MainAxisAlignment.center,
                    children: [
                      TextButton(
                        onPressed: image.isCover
                            ? null
                            : () => _setCover(index),
                        child: const Text('Set cover'),
                      ),
                      IconButton(
                        onPressed: () => _removeImage(index),
                        tooltip: 'Remove local image',
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),
      ),
      if (_record.images.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 28),
          child: Center(
            child: Text('No images have been saved locally for this book.'),
          ),
        ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _importImages,
        icon: const Icon(Icons.add_photo_alternate_outlined),
        label: const Text('Add local images'),
      ),
      if (_record.work.remoteCoverUrl.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(
            'Original cover URL: ${_record.work.remoteCoverUrl}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
    ],
  );

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Text(text, style: Theme.of(context).textTheme.titleLarge),
  );
}

class _ScrollForm extends StatelessWidget {
  const _ScrollForm({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 22, 18, 100),
        children: children,
      ),
    ),
  );
}

class _ResponsiveFields extends StatelessWidget {
  const _ResponsiveFields({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth < 480
        ? Column(
            children: children
                .expand((child) => [child, const SizedBox(height: 12)])
                .toList(),
          )
        : Row(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                Expanded(child: children[i]),
                if (i < children.length - 1) const SizedBox(width: 12),
              ],
            ],
          ),
  );
}
