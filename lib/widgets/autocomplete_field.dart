import 'package:flutter/material.dart';

/// Text field with local database suggestions after the third typed character.
class LocalAutocompleteField extends StatefulWidget {
  const LocalAutocompleteField({
    super.key,
    required this.controller,
    required this.label,
    required this.suggestions,
    this.maxLines = 1,
    this.keyboardType,
    this.validator,
    this.prefixIcon,
  });

  final TextEditingController controller;
  final String label;
  final Future<List<String>> Function(String value) suggestions;
  final int maxLines;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final IconData? prefixIcon;

  @override
  State<LocalAutocompleteField> createState() => _LocalAutocompleteFieldState();
}

class _LocalAutocompleteFieldState extends State<LocalAutocompleteField> {
  TextEditingController? _fieldController;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleExternalControllerChanged);
  }

  @override
  void didUpdateWidget(covariant LocalAutocompleteField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleExternalControllerChanged);
      widget.controller.addListener(_handleExternalControllerChanged);
      _handleExternalControllerChanged();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleExternalControllerChanged);
    _setFieldController(null);
    super.dispose();
  }

  void _handleExternalControllerChanged() {
    final fieldController = _fieldController;
    if (fieldController != null &&
        fieldController.value != widget.controller.value) {
      fieldController.value = widget.controller.value;
    }
  }

  void _handleFieldControllerChanged() {
    final fieldController = _fieldController;
    if (fieldController != null &&
        widget.controller.value != fieldController.value) {
      widget.controller.value = fieldController.value;
    }
  }

  void _setFieldController(TextEditingController? controller) {
    if (identical(_fieldController, controller)) return;
    _fieldController?.removeListener(_handleFieldControllerChanged);
    _fieldController = controller;
    _fieldController?.addListener(_handleFieldControllerChanged);
    _handleExternalControllerChanged();
  }

  @override
  Widget build(BuildContext context) => Autocomplete<String>(
    initialValue: TextEditingValue(text: widget.controller.text),
    optionsBuilder: (value) async => value.text.trim().length < 3
        ? const Iterable<String>.empty()
        : await widget.suggestions(value.text),
    onSelected: (selection) => widget.controller.text = selection,
    fieldViewBuilder: (context, fieldController, focusNode, onSubmitted) {
      // Keep both controllers synchronized for save and switch-copy operations.
      _setFieldController(fieldController);
      return TextFormField(
        controller: fieldController,
        focusNode: focusNode,
        maxLines: widget.maxLines,
        keyboardType: widget.keyboardType,
        validator: widget.validator,
        decoration: InputDecoration(
          labelText: widget.label,
          prefixIcon: widget.prefixIcon == null
              ? null
              : Icon(widget.prefixIcon),
        ),
      );
    },
    optionsViewBuilder: (context, onSelected, options) => Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 5,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220, maxWidth: 420),
          child: ListView.builder(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            itemCount: options.length,
            itemBuilder: (context, index) {
              final option = options.elementAt(index);
              return ListTile(
                title: Text(option),
                onTap: () => onSelected(option),
              );
            },
          ),
        ),
      ),
    ),
  );
}
