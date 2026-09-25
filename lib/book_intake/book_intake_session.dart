// Named dependency parameters initialize private fields to keep the session
// boundary as the only access point for intake operations.
// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../models/catalog_models.dart';

enum LookupMode { isbn, title, author }

enum BookIntakeMessageKind { noResults, failure }

abstract interface class BookIntakeLookup {
  Future<List<WorkCandidate>> searchByIsbn(
    String query, {
    required String apiKey,
  });
  Future<List<WorkCandidate>> searchByTitleOrAuthor({
    required String term,
    required bool author,
    required String apiKey,
  });
  Future<WorkCandidate> fetchRpgGeekDetails(
    WorkCandidate candidate,
    String apiKey,
  );
}

abstract interface class BookIntakeCatalog {
  Future<CatalogRecord?> findByIsbn(String isbn13);
}

abstract interface class BookIntakePreferences {
  Future<LookupMode?> readMode();
  Future<void> writeMode(LookupMode mode);
}

abstract interface class BookIntakeKeyProvider {
  Future<String> rpgGeekKey();
}

@immutable
class BookIntakeState {
  const BookIntakeState({
    required this.mode,
    required this.query,
    required this.results,
    required this.loading,
    required this.bulkAdd,
    this.message,
    this.messageKind,
  });

  final LookupMode mode;
  final String query;
  final List<WorkCandidate> results;
  final bool loading;
  final bool bulkAdd;
  final String? message;
  final BookIntakeMessageKind? messageKind;
}

sealed class BookIntakeOutcome {
  const BookIntakeOutcome();
}

final class IntakeIgnored extends BookIntakeOutcome {
  const IntakeIgnored();
}

final class IntakeRefreshCandidate extends BookIntakeOutcome {
  const IntakeRefreshCandidate(this.candidate);
  final WorkCandidate candidate;
}

final class IntakeDuplicateRequest extends BookIntakeOutcome {
  const IntakeDuplicateRequest(this.id, this.existing);
  final int id;
  final CatalogRecord existing;
}

enum IntakeDuplicateChoice { edit, addCopy, cancel }

final class IntakeEditorRequest extends BookIntakeOutcome {
  const IntakeEditorRequest(this.id, this.record);
  final int id;
  final CatalogRecord record;
}

final class IntakeSaved extends BookIntakeOutcome {
  const IntakeSaved({required this.startNext});
  final bool startNext;
}

/// One visit to the add or metadata-refresh flow. UI routes and dialogs consume
/// outcomes, then report their choices back with the issued request objects.
class BookIntakeSession extends ChangeNotifier {
  BookIntakeSession({
    required BookIntakeLookup lookup,
    required BookIntakeCatalog catalog,
    required BookIntakePreferences preferences,
    required BookIntakeKeyProvider keyProvider,
    this.refreshOnly = false,
    String? initialIsbn,
    String? initialTitle,
    String? initialAuthors,
  }) : _lookup = lookup,
       _catalog = catalog,
       _preferences = preferences,
       _keyProvider = keyProvider,
       _seeds = {
         LookupMode.isbn: initialIsbn ?? '',
         LookupMode.title: initialTitle ?? '',
         LookupMode.author: initialAuthors ?? '',
       } {
    _mode = initialIsbn?.trim().isNotEmpty == true
        ? LookupMode.isbn
        : initialTitle?.trim().isNotEmpty == true
        ? LookupMode.title
        : initialAuthors?.trim().isNotEmpty == true
        ? LookupMode.author
        : LookupMode.isbn;
    _query = _seeds[_mode]!;
  }

  final BookIntakeLookup _lookup;
  final BookIntakeCatalog _catalog;
  final BookIntakePreferences _preferences;
  final BookIntakeKeyProvider _keyProvider;
  final Map<LookupMode, String> _seeds;
  final bool refreshOnly;
  late LookupMode _mode;
  late String _query;
  List<WorkCandidate> _results = const [];
  bool _loading = false;
  bool _bulkAdd = false;
  String? _message;
  BookIntakeMessageKind? _messageKind;
  bool _modeChanged = false;
  bool _disposed = false;
  int _generation = 0;
  int _requestId = 0;
  IntakeDuplicateRequest? _duplicate;
  IntakeEditorRequest? _editor;

  BookIntakeState get state => BookIntakeState(
    mode: _mode,
    query: _query,
    results: List.unmodifiable(_results),
    loading: _loading,
    bulkAdd: _bulkAdd,
    message: _message,
    messageKind: _messageKind,
  );

  bool _current(int generation) => !_disposed && generation == _generation;

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _invalidate() {
    _generation++;
    _loading = false;
    _duplicate = null;
    _editor = null;
  }

  Future<void> restoreMode() async {
    final mode = await _preferences.readMode();
    if (_disposed || _modeChanged || mode == null || mode == _mode) return;
    _invalidate();
    _mode = mode;
    _query = _seeds[mode]!;
    _results = const [];
    _message = null;
    _messageKind = null;
    _emit();
  }

  Future<void> changeMode(LookupMode mode) async {
    if (_disposed) return;
    _modeChanged = true;
    _invalidate();
    _mode = mode;
    _query = _seeds[mode]!;
    _results = const [];
    _message = null;
    _messageKind = null;
    _emit();
    await _preferences.writeMode(mode);
  }

  void setQuery(String query) {
    if (_disposed || query == _query) return;
    _invalidate();
    _query = query;
    _emit();
  }

  void setBulkAdd(bool enabled) {
    if (_disposed || _bulkAdd == enabled) return;
    _bulkAdd = enabled;
    _emit();
  }

  Future<void> search() async {
    if (_disposed) return;
    _invalidate();
    final generation = _generation;
    final mode = _mode;
    final query = _query;
    _loading = true;
    _results = const [];
    _message = null;
    _messageKind = null;
    _emit();
    try {
      final key = await _keyProvider.rpgGeekKey();
      if (!_current(generation)) return;
      final results = switch (mode) {
        LookupMode.isbn => await _lookup.searchByIsbn(query, apiKey: key),
        LookupMode.title => await _lookup.searchByTitleOrAuthor(
          term: query,
          author: false,
          apiKey: key,
        ),
        LookupMode.author => await _lookup.searchByTitleOrAuthor(
          term: query,
          author: true,
          apiKey: key,
        ),
      };
      if (!_current(generation)) return;
      _results = results;
      _message = results.isEmpty
          ? 'No works were found in OpenLibrary. Check the search, try a title, or add the book manually.'
          : null;
      _messageKind = results.isEmpty ? BookIntakeMessageKind.noResults : null;
    } catch (error) {
      if (_current(generation)) {
        _message = error.toString();
        _messageKind = BookIntakeMessageKind.failure;
      }
    } finally {
      if (_current(generation)) {
        _loading = false;
        _emit();
      }
    }
  }

  Future<BookIntakeOutcome> select(WorkCandidate candidate) async {
    if (_disposed) return const IntakeIgnored();
    _invalidate();
    final generation = _generation;
    _loading = true;
    _message = null;
    _messageKind = null;
    _emit();
    try {
      final key = await _keyProvider.rpgGeekKey();
      if (!_current(generation)) return const IntakeIgnored();
      final enriched = candidate.rpgGeekId.trim().isNotEmpty
          ? await _lookup.fetchRpgGeekDetails(candidate, key)
          : candidate;
      if (!_current(generation)) return const IntakeIgnored();
      if (refreshOnly) return IntakeRefreshCandidate(enriched);
      final existing = enriched.isbn13.isEmpty
          ? null
          : await _catalog.findByIsbn(enriched.isbn13);
      if (!_current(generation)) return const IntakeIgnored();
      if (existing != null) {
        return _duplicate = IntakeDuplicateRequest(++_requestId, existing);
      }
      return _editor = IntakeEditorRequest(++_requestId, enriched.toRecord());
    } catch (error) {
      if (_current(generation)) {
        _message = error.toString();
        _messageKind = BookIntakeMessageKind.failure;
      }
      return const IntakeIgnored();
    } finally {
      if (_current(generation)) {
        _loading = false;
        _emit();
      }
    }
  }

  BookIntakeOutcome chooseDuplicate(
    IntakeDuplicateRequest request,
    IntakeDuplicateChoice choice,
  ) {
    if (_disposed || !identical(_duplicate, request)) {
      return const IntakeIgnored();
    }
    _duplicate = null;
    if (choice == IntakeDuplicateChoice.cancel) return const IntakeIgnored();
    final existing = request.existing;
    final record = choice == IntakeDuplicateChoice.addCopy
        ? existing.copyWith(copies: [...existing.copies, const UserCopy()])
        : existing;
    return _editor = IntakeEditorRequest(++_requestId, record);
  }

  BookIntakeOutcome manual() {
    if (_disposed) return const IntakeIgnored();
    _invalidate();
    _emit();
    return _editor = IntakeEditorRequest(
      ++_requestId,
      const CatalogRecord(
        work: BookWork(title: ''),
        copies: [UserCopy()],
      ),
    );
  }

  BookIntakeOutcome completeEditor(
    IntakeEditorRequest request, {
    required bool saved,
  }) {
    if (_disposed || !identical(_editor, request)) {
      return const IntakeIgnored();
    }
    _editor = null;
    if (!saved) return const IntakeIgnored();
    if (_bulkAdd) {
      _invalidate();
      _query = '';
      _results = const [];
      _message = null;
      _messageKind = null;
      _emit();
    }
    return IntakeSaved(startNext: _bulkAdd);
  }

  @override
  void dispose() {
    _disposed = true;
    _invalidate();
    super.dispose();
  }
}
