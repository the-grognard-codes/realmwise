import 'package:flutter/material.dart';

/// Text field with local database suggestions after the third typed character.
class LocalAutocompleteField extends StatelessWidget {
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
  Widget build(BuildContext context) => Autocomplete<String>(
        initialValue: TextEditingValue(text: controller.text),
        optionsBuilder: (value) async => value.text.trim().length < 3
            ? const Iterable<String>.empty()
            : await suggestions(value.text),
        onSelected: (selection) => controller.text = selection,
        fieldViewBuilder: (context, fieldController, focusNode, onSubmitted) {
          // Keep the external controller authoritative for save/switch-copy operations.
          fieldController.addListener(() {
            if (controller.text != fieldController.text)
              controller.value = fieldController.value;
          });
          return TextFormField(
            controller: fieldController,
            focusNode: focusNode,
            maxLines: maxLines,
            keyboardType: keyboardType,
            validator: validator,
            decoration: InputDecoration(
              labelText: label,
              prefixIcon: prefixIcon == null ? null : Icon(prefixIcon),
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
