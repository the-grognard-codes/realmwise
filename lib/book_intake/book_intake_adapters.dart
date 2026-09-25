import 'package:shared_preferences/shared_preferences.dart';

import '../models/catalog_models.dart';
import '../services/app_controller.dart';
import '../services/catalog_service.dart';
import '../services/external_catalog_service.dart';
import 'book_intake_session.dart';

/// App wiring stays outside the visit-scoped intake logic.
BookIntakeSession createBookIntakeSession({
  required AppController controller,
  bool refreshOnly = false,
  String? initialIsbn,
  String? initialTitle,
  String? initialAuthors,
}) => BookIntakeSession(
  lookup: ExternalCatalogIntakeLookup(controller.lookup),
  catalog: CatalogIntakeCatalog(controller.catalog),
  preferences: SharedPreferencesIntakePreferences(),
  keyProvider: ControllerIntakeKeyProvider(controller),
  refreshOnly: refreshOnly,
  initialIsbn: initialIsbn,
  initialTitle: initialTitle,
  initialAuthors: initialAuthors,
);

class ExternalCatalogIntakeLookup implements BookIntakeLookup {
  const ExternalCatalogIntakeLookup(this.service);
  final ExternalCatalogService service;

  @override
  Future<List<WorkCandidate>> searchByIsbn(
    String query, {
    required String apiKey,
  }) => service.searchByIsbn(query, apiKey: apiKey);

  @override
  Future<List<WorkCandidate>> searchByTitleOrAuthor({
    required String term,
    required bool author,
    required String apiKey,
  }) =>
      service.searchByTitleOrAuthor(term: term, author: author, apiKey: apiKey);

  @override
  Future<WorkCandidate> fetchRpgGeekDetails(
    WorkCandidate candidate,
    String apiKey,
  ) => service.fetchRpgGeekDetails(candidate, apiKey);
}

class CatalogIntakeCatalog implements BookIntakeCatalog {
  const CatalogIntakeCatalog(this.service);
  final CatalogService service;

  @override
  Future<CatalogRecord?> findByIsbn(String isbn13) =>
      service.findByIsbn(isbn13);
}

class SharedPreferencesIntakePreferences implements BookIntakePreferences {
  const SharedPreferencesIntakePreferences();
  static const preferenceKey = 'realmwise.lookup_mode';

  @override
  Future<LookupMode?> readMode() async {
    final preferences = await SharedPreferences.getInstance();
    return LookupMode.values.asNameMap()[preferences.getString(preferenceKey)];
  }

  @override
  Future<void> writeMode(LookupMode mode) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(preferenceKey, mode.name);
  }
}

class ControllerIntakeKeyProvider implements BookIntakeKeyProvider {
  const ControllerIntakeKeyProvider(this.controller);
  final AppController controller;

  @override
  Future<String> rpgGeekKey() => controller.rpgGeekKey();
}
