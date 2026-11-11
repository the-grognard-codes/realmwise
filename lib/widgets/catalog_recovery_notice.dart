import 'package:flutter/material.dart';

import '../services/app_controller.dart';

/// Remains visible across navigation until the active catalog is acknowledged.
class CatalogRecoveryNotice extends StatelessWidget {
  const CatalogRecoveryNotice({super.key, required this.controller});
  final AppController controller;

  Future<void> _review(BuildContext context) async {
    final warning = controller.recoveryWarning;
    if (warning == null) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Review the active catalog'),
        content: SingleChildScrollView(
          child: SelectableText(
            '${warning.message}\n\n'
            'You can restore a protected snapshot from Settings → Database. '
            'Acknowledging allows automatic sync to resume if enabled.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep sync paused'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Acknowledge catalog'),
          ),
        ],
      ),
    );
    if (accepted != true || !context.mounted) return;
    // A dialog for an earlier catalog cannot acknowledge a new warning.
    if (!identical(controller.recoveryWarning, warning)) return;
    try {
      await controller.acknowledgeRecoveryWarning();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not acknowledge catalog: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => controller.recoveryWarning == null
        ? const SizedBox.shrink()
        : MaterialBanner(
            content: Text(controller.recoveryWarning!.summary),
            actions: [
              TextButton(
                onPressed: () => _review(context),
                child: const Text('Review catalog'),
              ),
            ],
          ),
  );
}
