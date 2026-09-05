import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/catalog_models.dart';
import '../services/app_controller.dart';
import 'book_editor_screen.dart';

enum LookupMode { isbn, title, author }

/// Returns true only for an ISBN-13 represented by exactly 13 ASCII digits.
bool isValidIsbn13(String value) {
  if (!RegExp(r'^[0-9]{13}$').hasMatch(value)) return false;
  var sum = 0;
  for (var i = 0; i < value.length; i++) {
    sum += int.parse(value[i]) * (i.isEven ? 1 : 3);
  }
  return sum % 10 == 0;
}

/// Returns true only for a valid ISBN-10 (nine digits followed by a digit/X).
bool isValidIsbn10(String value) {
  if (!RegExp(r'^[0-9]{9}[0-9Xx]$').hasMatch(value)) return false;
  var sum = 0;
  for (var i = 0; i < 10; i++) {
    final digit = i == 9 && (value[i] == 'X' || value[i] == 'x')
        ? 10
        : int.parse(value[i]);
    sum += digit * (10 - i);
  }
  return sum % 11 == 0;
}

bool isValidIsbn(String value) => isValidIsbn13(value) || isValidIsbn10(value);

class SearchAddScreen extends StatefulWidget {
  const SearchAddScreen({
    super.key,
    required this.controller,
    required this.onSaved,
    this.onBack,
    this.selectionOnly = false,
    this.initialIsbn,
    this.initialTitle,
    this.initialAuthors,
  });
  final AppController controller;
  final VoidCallback onSaved;

  /// Handles leaving the screen when it is embedded in another navigation UI.
  ///
  /// When omitted, the screen retains its pushed-route behavior and pops.
  final VoidCallback? onBack;

  /// When true, selecting a remote result returns the enriched candidate
  /// instead of opening a new editor route.
  final bool selectionOnly;
  final String? initialIsbn;
  final String? initialTitle;
  final String? initialAuthors;

  @override
  State<SearchAddScreen> createState() => _SearchAddScreenState();
}

class _SearchAddScreenState extends State<SearchAddScreen> {
  static const _lookupModePreferenceKey = 'realmwise.lookup_mode';
  final _query = TextEditingController();
  LookupMode _mode = LookupMode.isbn;
  List<WorkCandidate> _results = const [];
  bool _searching = false;
  String? _message;
  bool _cameraPermissionDenied = false;
  bool _modeChanged = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialIsbn?.trim().isNotEmpty == true
        ? LookupMode.isbn
        : widget.initialTitle?.trim().isNotEmpty == true
        ? LookupMode.title
        : LookupMode.author;
    _query.text = _queryForMode(_mode);
    _restoreLookupMode();
    if (_isAndroid) _loadCameraPermission();
  }

  Future<void> _restoreLookupMode() async {
    final prefs = await SharedPreferences.getInstance();
    final savedMode = LookupMode.values
        .asNameMap()[prefs.getString(_lookupModePreferenceKey)];
    if (!mounted || _modeChanged || savedMode == null || savedMode == _mode) {
      return;
    }
    setState(() {
      _mode = savedMode;
      _query.text = _queryForMode(savedMode);
    });
  }

  Future<void> _changeLookupMode(LookupMode mode) async {
    setState(() {
      _modeChanged = true;
      _mode = mode;
      _query.text = _queryForMode(mode);
      _results = const [];
      _message = null;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lookupModePreferenceKey, mode.name);
  }

  String _queryForMode(LookupMode mode) {
    switch (mode) {
      case LookupMode.isbn:
        return widget.initialIsbn ?? '';
      case LookupMode.title:
        return widget.initialTitle ?? '';
      case LookupMode.author:
        return widget.initialAuthors ?? '';
    }
  }

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  Future<void> _loadCameraPermission() async {
    PermissionStatus status;
    try {
      status = await Permission.camera.status;
    } catch (_) {
      // Keep the control visible if the platform permission bridge is absent.
      return;
    }
    if (!mounted) return;
    setState(
      () => _cameraPermissionDenied =
          status.isPermanentlyDenied || status.isRestricted,
    );
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _message = null;
      _results = const [];
    });
    try {
      final key = await widget.controller.rpgGeekKey();
      final results = switch (_mode) {
        LookupMode.isbn => await widget.controller.lookup.searchByIsbn(
          _query.text,
          apiKey: key,
        ),
        LookupMode.title =>
          await widget.controller.lookup.searchByTitleOrAuthor(
            term: _query.text,
            author: false,
            apiKey: key,
          ),
        LookupMode.author =>
          await widget.controller.lookup.searchByTitleOrAuthor(
            term: _query.text,
            author: true,
            apiKey: key,
          ),
      };
      if (mounted)
        setState(() {
          _results = results;
          _message = results.isEmpty
              ? 'No works were found in OpenLibrary. Check the search, try a title, or add the book manually.'
              : null;
        });
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _select(WorkCandidate initial) async {
    setState(() => _searching = true);
    try {
      final key = await widget.controller.rpgGeekKey();
      final enriched = initial.rpgGeekId.trim().isNotEmpty
          ? await widget.controller.lookup.fetchRpgGeekDetails(initial, key)
          : initial;
      if (!mounted) return;
      if (widget.selectionOnly) {
        Navigator.pop(context, enriched);
        return;
      }
      final existing = enriched.isbn13.isEmpty
          ? null
          : await widget.controller.catalog.findByIsbn(enriched.isbn13);
      if (!mounted) return;
      CatalogRecord record;
      if (existing != null) {
        final choice = await showDialog<_ExistingChoice>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('This work is already cataloged'),
            content: Text(
              '“${existing.work.title}” already has ${existing.copies.length} owned ${existing.copies.length == 1 ? 'copy' : 'copies'}. What would you like to do?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, _ExistingChoice.cancel),
                child: const Text('Cancel'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.pop(context, _ExistingChoice.edit),
                child: const Text('Edit existing'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(context, _ExistingChoice.addCopy),
                child: const Text('Add copy'),
              ),
            ],
          ),
        );
        if (choice == null || choice == _ExistingChoice.cancel) return;
        record = choice == _ExistingChoice.addCopy
            ? existing.copyWith(copies: [...existing.copies, const UserCopy()])
            : existing;
      } else {
        record = enriched.toRecord();
      }
      if (!mounted) return;
      final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (context) =>
              BookEditorScreen(controller: widget.controller, record: record),
        ),
      );
      if (saved == true) {
        widget.onSaved();
        if (mounted) setState(() => _results = const []);
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _manual() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => BookEditorScreen(
          controller: widget.controller,
          record: const CatalogRecord(
            work: BookWork(title: ''),
            copies: [UserCopy()],
          ),
        ),
      ),
    );
    if (saved == true) widget.onSaved();
  }

  Future<void> _scanWithCamera() async {
    if (!_isAndroid || _cameraPermissionDenied || _searching) return;
    final status = await Permission.camera.request();
    if (!mounted) return;
    if (!status.isGranted) {
      setState(() => _cameraPermissionDenied = true);
      return;
    }
    final controller = MobileScannerController();
    var found = false;
    final isbn = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .72,
        child: MobileScanner(
          controller: controller,
          onDetect: (capture) {
            if (found) return;
            for (final barcode in capture.barcodes) {
              final value = barcode.rawValue;
              if (value != null && isValidIsbn(value)) {
                found = true;
                controller.stop();
                Navigator.of(context).pop(value);
                return;
              }
            }
          },
        ),
      ),
    );
    controller.dispose();
    if (!mounted || isbn == null) return;
    if (_mode != LookupMode.isbn) await _changeLookupMode(LookupMode.isbn);
    _query.text = isbn;
    await _search();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: widget.onBack == null
        ? AppBar(
            leading: BackButton(onPressed: () => Navigator.pop(context)),
            title: const Text('Find a work'),
          )
        : null,
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 40),
          children: [
            Text(
              'Find a work',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            const Text(
              'OpenLibrary is searched first. If an RPGGeek key is saved in Settings, its returned details are used preferentially. Manual entry always works offline.',
            ),
            const SizedBox(height: 18),
            SegmentedButton<LookupMode>(
              segments: const [
                ButtonSegment(
                  value: LookupMode.isbn,
                  label: Text('ISBN'),
                  icon: Icon(Icons.numbers),
                ),
                ButtonSegment(
                  value: LookupMode.title,
                  label: Text('Title'),
                  icon: Icon(Icons.title),
                ),
                ButtonSegment(
                  value: LookupMode.author,
                  label: Text('Author'),
                  icon: Icon(Icons.person),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (selection) =>
                  _changeLookupMode(selection.first),
            ),
            const SizedBox(height: 14),
            TextField(
              key: ValueKey(_mode),
              controller: _query,
              keyboardType: _mode == LookupMode.isbn
                  ? TextInputType.number
                  : TextInputType.text,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                labelText: _mode == LookupMode.isbn
                    ? '10 or 13 digit ISBN'
                    : (_mode == LookupMode.title
                          ? 'Book title'
                          : 'Author name'),
                suffixIcon: IconButton(
                  onPressed: _searching ? null : _search,
                  tooltip: 'Search OpenLibrary',
                  icon: const Icon(Icons.search),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _searching ? null : _search,
                  icon: const Icon(Icons.travel_explore),
                  label: const Text('Search OpenLibrary'),
                ),
                OutlinedButton.icon(
                  onPressed: _searching ? null : _manual,
                  icon: const Icon(Icons.edit_note),
                  label: const Text('Add manually'),
                ),
                if (_isAndroid && !_cameraPermissionDenied)
                  OutlinedButton.icon(
                    onPressed: _searching ? null : _scanWithCamera,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Scan with Camera'),
                  ),
              ],
            ),
            if (_searching)
              const Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_message!),
                  ),
                ),
              ),
            if (_results.isNotEmpty) ...[
              const SizedBox(height: 28),
              Text(
                'Top ${_results.length} match${_results.length == 1 ? '' : 'es'}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              ..._results.map(
                (candidate) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.menu_book_outlined),
                    title: Text(_title(candidate)),
                    subtitle: Text(_subtitle(candidate)),
                    trailing: FilledButton(
                      onPressed: _searching ? null : () => _select(candidate),
                      child: const Text('Select'),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  String _subtitle(WorkCandidate candidate) {
    final pieces = <String>[
      if (candidate.rpgGeekId.isNotEmpty)
        'RPGGeek candidate — confirm to load details',
      if (candidate.authors.isNotEmpty) candidate.authors.join(', '),
      if (candidate.isbn13.isNotEmpty) 'ISBN ${candidate.isbn13}',
      if (candidate.publicationDate.isNotEmpty) candidate.publicationDate,
    ];
    return pieces.isEmpty
        ? 'No additional OpenLibrary details'
        : pieces.join(' • ');
  }

  String _title(WorkCandidate candidate) {
    final year = RegExp(
      r'\b(\d{4})\b',
    ).firstMatch(candidate.publicationDate)?.group(1);
    return year == null ? candidate.title : '${candidate.title} ($year)';
  }
}

enum _ExistingChoice { edit, addCopy, cancel }
