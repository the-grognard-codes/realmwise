import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/catalog_models.dart';
import '../book_intake/book_intake_adapters.dart';
import '../book_intake/book_intake_session.dart';
import '../services/app_controller.dart';
import 'book_editor_screen.dart';

export '../book_intake/book_intake_session.dart' show LookupMode;

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
    this.intakeSession,
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

  /// Optional visit session, useful when embedding the screen with controlled
  /// intake dependencies. The screen owns its lifetime.
  final BookIntakeSession? intakeSession;

  @override
  State<SearchAddScreen> createState() => _SearchAddScreenState();
}

class _SearchAddScreenState extends State<SearchAddScreen> {
  final _query = TextEditingController();
  final _queryFocus = FocusNode();
  late final BookIntakeSession _intake;
  bool _cameraPermissionDenied = false;

  BookIntakeState get _state => _intake.state;

  @override
  void initState() {
    super.initState();
    _intake =
        widget.intakeSession ??
        createBookIntakeSession(
          controller: widget.controller,
          refreshOnly: widget.selectionOnly,
          initialIsbn: widget.initialIsbn,
          initialTitle: widget.initialTitle,
          initialAuthors: widget.initialAuthors,
        );
    _query.text = _state.query;
    _intake.addListener(_syncIntakeState);
    _intake.restoreMode();
    if (_isAndroid) _loadCameraPermission();
    _focusQuery();
  }

  void _focusQuery() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _queryFocus.requestFocus();
    });
  }

  void _focusQueryAfterEditorCloses() {
    final animation = ModalRoute.of(context)?.secondaryAnimation;
    if (animation == null || animation.status == AnimationStatus.dismissed) {
      _focusQuery();
      return;
    }
    late final AnimationStatusListener listener;
    listener = (status) {
      if (status != AnimationStatus.dismissed) return;
      animation.removeStatusListener(listener);
      if (mounted) _focusQuery();
    };
    animation.addStatusListener(listener);
  }

  void _syncIntakeState() {
    if (!mounted) return;
    final query = _state.query;
    if (_query.text != query) {
      _query.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
      _focusQuery();
    }
    setState(() {});
  }

  Future<void> _changeLookupMode(
    LookupMode mode, {
    bool focusQuery = true,
  }) async {
    final change = _intake.changeMode(mode);
    if (focusQuery) _focusQuery();
    await change;
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
    _intake.removeListener(_syncIntakeState);
    _intake.dispose();
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    FocusScope.of(context).unfocus();
    await _intake.search();
  }

  Future<void> _select(WorkCandidate candidate) async {
    final outcome = await _intake.select(candidate);
    if (mounted) await _handleOutcome(outcome);
  }

  Future<void> _handleOutcome(BookIntakeOutcome outcome) async {
    if (!mounted || outcome is IntakeIgnored) return;
    if (outcome is IntakeRefreshCandidate) {
      Navigator.pop(context, outcome.candidate);
    } else if (outcome is IntakeDuplicateRequest) {
      final existing = outcome.existing;
      final choice = await showDialog<IntakeDuplicateChoice>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('This work is already cataloged'),
          content: Text(
            '“${existing.work.title}” already has ${existing.copies.length} owned ${existing.copies.length == 1 ? 'copy' : 'copies'}. What would you like to do?',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, IntakeDuplicateChoice.cancel),
              child: const Text('Cancel'),
            ),
            OutlinedButton(
              onPressed: () =>
                  Navigator.pop(context, IntakeDuplicateChoice.edit),
              child: const Text('Edit existing'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, IntakeDuplicateChoice.addCopy),
              child: const Text('Add copy'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      await _handleOutcome(
        _intake.chooseDuplicate(
          outcome,
          choice ?? IntakeDuplicateChoice.cancel,
        ),
      );
    } else if (outcome is IntakeEditorRequest) {
      final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (context) => BookEditorScreen(
            controller: widget.controller,
            record: outcome.record,
          ),
        ),
      );
      if (!mounted) return;
      await _handleOutcome(
        _intake.completeEditor(outcome, saved: saved == true),
      );
    } else if (outcome is IntakeSaved) {
      if (outcome.startNext) {
        _focusQueryAfterEditorCloses();
      } else {
        widget.onSaved();
      }
    }
  }

  Future<void> _manual() async {
    await _handleOutcome(_intake.manual());
  }

  Future<void> _scanWithCamera() async {
    if (!_isAndroid || _cameraPermissionDenied || _state.loading) return;
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
    if (_state.mode != LookupMode.isbn) {
      await _changeLookupMode(LookupMode.isbn, focusQuery: false);
    }
    if (!mounted) return;
    _query.text = isbn;
    _intake.setQuery(isbn);
    await _search();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final mode = state.mode;
    return Scaffold(
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
                selected: {mode},
                onSelectionChanged: (selection) =>
                    _changeLookupMode(selection.first),
              ),
              const SizedBox(height: 14),
              TextField(
                key: ValueKey(mode),
                controller: _query,
                focusNode: _queryFocus,
                autofocus: true,
                keyboardType: mode == LookupMode.isbn
                    ? TextInputType.number
                    : TextInputType.text,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                onChanged: _intake.setQuery,
                decoration: InputDecoration(
                  labelText: mode == LookupMode.isbn
                      ? '10 or 13 digit ISBN'
                      : (mode == LookupMode.title
                            ? 'Book title'
                            : 'Author name'),
                  suffixIcon: IconButton(
                    onPressed: state.loading ? null : _search,
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
                    onPressed: state.loading ? null : _search,
                    icon: const Icon(Icons.travel_explore),
                    label: const Text('Search OpenLibrary'),
                  ),
                  OutlinedButton.icon(
                    onPressed: state.loading ? null : _manual,
                    icon: const Icon(Icons.edit_note),
                    label: const Text('Add manually'),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Bulk Add'),
                      Switch(
                        value: state.bulkAdd,
                        onChanged: state.loading ? null : _intake.setBulkAdd,
                      ),
                    ],
                  ),
                  if (_isAndroid && !_cameraPermissionDenied)
                    OutlinedButton.icon(
                      onPressed: state.loading ? null : _scanWithCamera,
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('Scan with Camera'),
                    ),
                ],
              ),
              if (state.loading)
                const Padding(
                  padding: EdgeInsets.all(28),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (state.message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(state.message!),
                    ),
                  ),
                ),
              if (state.results.isNotEmpty) ...[
                const SizedBox(height: 28),
                Text(
                  'Top ${state.results.length} match${state.results.length == 1 ? '' : 'es'}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                ...state.results.map(
                  (candidate) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.menu_book_outlined),
                      title: Text(_title(candidate)),
                      subtitle: Text(_subtitle(candidate)),
                      trailing: FilledButton(
                        onPressed: state.loading
                            ? null
                            : () => _select(candidate),
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
  }

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
