import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/book_intake/book_intake_adapters.dart';
import 'package:realmwise/book_intake/book_intake_session.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/services/external_catalog_service.dart';

void main() {
  late _Lookup lookup;
  late _Catalog catalog;
  late _Preferences preferences;
  late _KeyProvider keyProvider;

  BookIntakeSession session({bool refreshOnly = false}) => BookIntakeSession(
    lookup: lookup,
    catalog: catalog,
    preferences: preferences,
    keyProvider: keyProvider,
    initialTitle: 'Seed title',
    initialAuthors: 'Seed author',
    refreshOnly: refreshOnly,
  );

  setUp(() {
    lookup = _Lookup();
    catalog = _Catalog();
    preferences = _Preferences();
    keyProvider = _KeyProvider();
  });

  test('production lookup adapter converts curated catalog failures', () async {
    final client = http.Client();
    addTearDown(client.close);
    final adapter = ExternalCatalogIntakeLookup(ExternalCatalogService(client));
    await expectLater(
      adapter.searchByIsbn('invalid', apiKey: ''),
      throwsA(
        isA<BookIntakeFailure>().having(
          (failure) => failure.userMessage,
          'userMessage',
          'Enter a valid 10 or 13 digit ISBN.',
        ),
      ),
    );
  });

  test('restores a saved mode unless the visitor has changed it', () async {
    final firstRestore = Completer<LookupMode?>();
    preferences.nextRead = firstRestore.future;
    final intake = session();
    addTearDown(intake.dispose);
    expect(intake.state.mode, LookupMode.title);
    final restoring = intake.restoreMode();
    firstRestore.complete(LookupMode.author);
    await restoring;
    expect(intake.state.mode, LookupMode.author);
    expect(intake.state.query, 'Seed author');

    final secondRestore = Completer<LookupMode?>();
    preferences.nextRead = secondRestore.future;
    final lateRestore = intake.restoreMode();
    await intake.changeMode(LookupMode.isbn);
    secondRestore.complete(LookupMode.title);
    await lateRestore;
    expect(intake.state.mode, LookupMode.isbn);
    expect(intake.state.query, '');
    expect(preferences.writes, [LookupMode.isbn]);
  });

  test('routes each search and exposes no-results and failures', () async {
    final intake = session();
    addTearDown(intake.dispose);
    lookup.results = [const WorkCandidate(title: 'Found')];
    await intake.search();
    expect(lookup.calls, ['title:Seed title:key']);
    expect(intake.state.results.single.title, 'Found');
    intake.setQuery('changed title');
    expect(intake.state.results.single.title, 'Found');

    await intake.changeMode(LookupMode.author);
    expect(intake.state.results, isEmpty);
    lookup.results = const [];
    await intake.search();
    expect(lookup.calls.last, 'author:Seed author:key');
    expect(intake.state.feedback, isA<BookIntakeNoResults>());
    intake.setQuery('changed author');
    expect(intake.state.feedback, isA<BookIntakeNoResults>());

    await intake.changeMode(LookupMode.isbn);
    intake.setQuery('9781234567897');
    lookup.failure = StateError('offline');
    await intake.search();
    expect(lookup.calls.last, 'isbn:9781234567897:key');
    expect(intake.state.feedback, isA<BookIntakeFailure>());
    expect((intake.state.feedback as BookIntakeFailure).userMessage, isNull);
    expect(intake.state.loading, isFalse);
  });

  test('passes through only typed, curated lookup failures', () async {
    final intake = session();
    addTearDown(intake.dispose);
    lookup.failure = const BookIntakeFailure('Could not reach OpenLibrary.');
    await intake.search();
    expect(
      (intake.state.feedback as BookIntakeFailure).userMessage,
      'Could not reach OpenLibrary.',
    );

    lookup.failure = StateError('provider token=secret');
    await intake.search();
    expect((intake.state.feedback as BookIntakeFailure).userMessage, isNull);

    lookup.failure = null;
    catalog.failure = StateError('database path=secret');
    final outcome = await intake.select(
      const WorkCandidate(title: 'Hit', isbn13: '9781234567897'),
    );
    expect(outcome, isA<IntakeIgnored>());
    expect((intake.state.feedback as BookIntakeFailure).userMessage, isNull);
  });

  test('ISBN-13 with no catalog match requests a new editor', () async {
    final intake = session();
    addTearDown(intake.dispose);
    final editor = await intake.select(
      const WorkCandidate(title: 'Unowned', isbn13: '9781234567897'),
    );
    expect(catalog.lookups, ['9781234567897']);
    expect(editor, isA<IntakeEditorRequest>());
    expect((editor as IntakeEditorRequest).record.work.title, 'Unowned');
  });

  test('canceling a duplicate leaves no editor request', () async {
    final intake = session();
    addTearDown(intake.dispose);
    catalog.result = const CatalogRecord(work: BookWork(title: 'Owned'));
    final duplicate =
        await intake.select(
              const WorkCandidate(title: 'Hit', isbn13: '9781234567897'),
            )
            as IntakeDuplicateRequest;
    expect(
      intake.chooseDuplicate(duplicate, IntakeDuplicateChoice.cancel),
      isA<IntakeIgnored>(),
    );
    expect(
      intake.chooseDuplicate(duplicate, IntakeDuplicateChoice.edit),
      isA<IntakeIgnored>(),
    );
  });

  test('enriches then requests duplicate choice and editor handoff', () async {
    final intake = session();
    addTearDown(intake.dispose);
    final existing = CatalogRecord(
      work: const BookWork(title: 'Owned'),
      copies: const [UserCopy()],
    );
    catalog.result = existing;
    lookup.enriched = const WorkCandidate(
      title: 'Enriched',
      isbn13: '9781234567897',
    );
    final duplicate =
        await intake.select(const WorkCandidate(title: 'Hit', rpgGeekId: '42'))
            as IntakeDuplicateRequest;
    expect(lookup.enrichmentCalls, 1);
    expect(catalog.lookups, ['9781234567897']);
    expect(duplicate.existing, same(existing));

    final editor =
        intake.chooseDuplicate(duplicate, IntakeDuplicateChoice.addCopy)
            as IntakeEditorRequest;
    expect(editor.record.copies, hasLength(2));
    expect(intake.completeEditor(editor, saved: false), isA<IntakeIgnored>());
    expect(intake.completeEditor(editor, saved: true), isA<IntakeIgnored>());

    final nextDuplicate =
        await intake.select(const WorkCandidate(title: 'Hit', rpgGeekId: '42'))
            as IntakeDuplicateRequest;
    final edit =
        intake.chooseDuplicate(nextDuplicate, IntakeDuplicateChoice.edit)
            as IntakeEditorRequest;
    expect(edit.record, same(existing));
    expect(
      intake.completeEditor(edit, saved: true),
      isA<IntakeSaved>().having(
        (outcome) => outcome.startNext,
        'startNext',
        false,
      ),
    );
  });

  test(
    'manual and bulk save start a fresh form; refresh returns a candidate',
    () async {
      final intake = session();
      addTearDown(intake.dispose);
      intake.setBulkAdd(true);
      final editor = intake.manual() as IntakeEditorRequest;
      expect(editor.record.work.title, '');
      expect(editor.record.copies, hasLength(1));
      expect(
        intake.completeEditor(editor, saved: true),
        isA<IntakeSaved>().having(
          (outcome) => outcome.startNext,
          'startNext',
          true,
        ),
      );
      expect(intake.state.query, '');
      expect(intake.state.bulkAdd, isTrue);

      final refresh = session(refreshOnly: true);
      addTearDown(refresh.dispose);
      catalog.result = CatalogRecord(work: const BookWork(title: 'Owned'));
      lookup.enriched = const WorkCandidate(
        title: 'Updated',
        isbn13: '9781234567897',
      );
      final result = await refresh.select(
        const WorkCandidate(title: 'Hit', rpgGeekId: '42'),
      );
      expect(result, isA<IntakeRefreshCandidate>());
      expect((result as IntakeRefreshCandidate).candidate.title, 'Updated');
      expect(catalog.lookups, isEmpty);
      final refreshManual = refresh.manual() as IntakeEditorRequest;
      expect(refreshManual.record.work.title, '');
      expect(refreshManual.record.copies, hasLength(1));
      expect(
        refresh.completeEditor(refreshManual, saved: true),
        isA<IntakeSaved>(),
      );
    },
  );

  test(
    'superseded search, selection, and disposed visit ignore late work',
    () async {
      final intake = session();
      final pendingSearch = Completer<List<WorkCandidate>>();
      lookup.nextSearch = pendingSearch.future;
      final searching = intake.search();
      await Future<void>.delayed(Duration.zero);
      expect(intake.state.loading, isTrue);
      intake.setQuery('new query');
      pendingSearch.complete([const WorkCandidate(title: 'Old result')]);
      await searching;
      expect(intake.state.results, isEmpty);
      expect(intake.state.loading, isFalse);

      final pendingEnrichment = Completer<WorkCandidate>();
      lookup.nextEnrichment = pendingEnrichment.future;
      final selecting = intake.select(
        const WorkCandidate(title: 'Old selection', rpgGeekId: '42'),
      );
      await Future<void>.delayed(Duration.zero);
      await intake.changeMode(LookupMode.author);
      pendingEnrichment.complete(const WorkCandidate(title: 'Late'));
      expect(await selecting, isA<IntakeIgnored>());
      expect(catalog.lookups, isEmpty);

      final lateSearch = Completer<List<WorkCandidate>>();
      lookup.nextSearch = lateSearch.future;
      final disposedSearch = intake.search();
      await Future<void>.delayed(Duration.zero);
      intake.dispose();
      lateSearch.complete([const WorkCandidate(title: 'After dispose')]);
      await disposedSearch;
    },
  );
}

class _Lookup implements BookIntakeLookup {
  List<WorkCandidate> results = const [];
  WorkCandidate? enriched;
  Object? failure;
  Future<List<WorkCandidate>>? nextSearch;
  Future<WorkCandidate>? nextEnrichment;
  final calls = <String>[];
  int enrichmentCalls = 0;

  Future<List<WorkCandidate>> _search(String call) {
    calls.add(call);
    final pending = nextSearch;
    nextSearch = null;
    if (pending != null) return pending;
    if (failure != null) return Future.error(failure!);
    return Future.value(results);
  }

  @override
  Future<List<WorkCandidate>> searchByIsbn(
    String query, {
    required String apiKey,
  }) => _search('isbn:$query:$apiKey');

  @override
  Future<List<WorkCandidate>> searchByTitleOrAuthor({
    required String term,
    required bool author,
    required String apiKey,
  }) => _search('${author ? 'author' : 'title'}:$term:$apiKey');

  @override
  Future<WorkCandidate> fetchRpgGeekDetails(
    WorkCandidate candidate,
    String apiKey,
  ) {
    enrichmentCalls++;
    final pending = nextEnrichment;
    nextEnrichment = null;
    return pending ?? Future.value(enriched ?? candidate);
  }
}

class _Catalog implements BookIntakeCatalog {
  CatalogRecord? result;
  Object? failure;
  final lookups = <String>[];

  @override
  Future<CatalogRecord?> findByIsbn(String isbn13) async {
    lookups.add(isbn13);
    if (failure != null) throw failure!;
    return result;
  }
}

class _Preferences implements BookIntakePreferences {
  Future<LookupMode?>? nextRead;
  final writes = <LookupMode>[];

  @override
  Future<LookupMode?> readMode() => nextRead ?? Future.value(null);

  @override
  Future<void> writeMode(LookupMode mode) async => writes.add(mode);
}

class _KeyProvider implements BookIntakeKeyProvider {
  @override
  Future<String> rpgGeekKey() async => 'key';
}
