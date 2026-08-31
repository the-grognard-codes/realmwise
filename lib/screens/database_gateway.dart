import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/app_controller.dart';

/// Shown only after a collector intentionally closes the current database.
class DatabaseGateway extends StatefulWidget {
  const DatabaseGateway({super.key, required this.controller, this.error});
  final AppController controller;
  final String? error;

  @override
  State<DatabaseGateway> createState() => _DatabaseGatewayState();
}

class _DatabaseGatewayState extends State<DatabaseGateway> {
  bool _busy = false;
  String? _message;

  Future<void> _run(Future<void> Function() action) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    var succeeded = false;
    try {
      await action();
      succeeded = true;
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      // A successful open replaces this route via the controller listener;
      // avoid touching state while that replacement is underway.
      if (mounted && (!succeeded || !widget.controller.isOpen)) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _create() async {
    final name = TextEditingController(text: 'my_realmwise');
    final route = DialogRoute<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create database'),
        content: TextField(
          controller: name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Database name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    try {
      final accepted = await Navigator.of(context).push(route);
      await route.completed;
      if (accepted == true && mounted && !widget.controller.isOpen) {
        await _run(() => widget.controller.createDatabase(name.text));
      }
    } finally {
      name.dispose();
    }
  }

  Future<void> _open() async {
    final result = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['db', 'sqlite', 'sqlite3'],
      dialogTitle: 'Open Realmwise database',
    );
    final selected = result?.path;
    if (selected != null)
      await _run(() => widget.controller.openDatabase(selected));
  }

  Future<void> _restoreBundle() async {
    final result = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['realmwise', 'zip'],
      dialogTitle: 'Choose portable device bundle',
    );
    final selected = result?.path;
    if (selected != null) {
      await _run(() => widget.controller.restoreDeviceBundle(selected));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.menu_book,
                      size: 48,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Open your Realmwise',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Choose an existing SQLite catalog or create a fresh local database. No account or connection is needed.',
                    ),
                    if (widget.error != null || _message != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        widget.error ?? _message!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    if (_busy)
                      const Center(child: CircularProgressIndicator())
                    else
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          FilledButton.icon(
                            onPressed: _create,
                            icon: const Icon(Icons.create_new_folder_outlined),
                            label: const Text('New database'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _open,
                            icon: const Icon(Icons.folder_open),
                            label: const Text('Open database'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _restoreBundle,
                            icon: const Icon(Icons.restore),
                            label: const Text('Restore sync bundle'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
