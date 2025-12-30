import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:bitbarrel_admin/theme/app_theme.dart';

/// Dialog for creating or editing a key-value pair
class KeyValueEditorDialog extends StatefulWidget {
  final String? initialKey;
  final String? initialValue;
  final bool isEditing;

  const KeyValueEditorDialog({
    super.key,
    this.initialKey,
    this.initialValue,
    this.isEditing = false,
  });

  /// Show the dialog and return the result (key, value) or null if cancelled
  static Future<(String, String)?> show(
    BuildContext context, {
    String? initialKey,
    String? initialValue,
    bool isEditing = false,
  }) {
    return showDialog<(String, String)?>(
      context: context,
      builder: (context) => KeyValueEditorDialog(
        initialKey: initialKey,
        initialValue: initialValue,
        isEditing: isEditing,
      ),
    );
  }

  @override
  State<KeyValueEditorDialog> createState() => _KeyValueEditorDialogState();
}

class _KeyValueEditorDialogState extends State<KeyValueEditorDialog> {
  late final TextEditingController _keyController;
  late final TextEditingController _valueController;
  bool _isValidJson = false;

  @override
  void initState() {
    super.initState();
    _keyController = TextEditingController(text: widget.initialKey ?? '');
    _valueController = TextEditingController(text: widget.initialValue ?? '');
    _validateJson();
  }

  @override
  void dispose() {
    _keyController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  void _validateJson() {
    if (_valueController.text.isEmpty) {
      setState(() => _isValidJson = false);
      return;
    }
    try {
      json.decode(_valueController.text);
      setState(() => _isValidJson = true);
    } catch (_) {
      setState(() => _isValidJson = false);
    }
  }

  void _formatJson() {
    try {
      final parsed = json.decode(_valueController.text);
      final formatted = const JsonEncoder.withIndent('  ').convert(parsed);
      _valueController.text = formatted;
      _validateJson();
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Invalid JSON - cannot format'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  void _minifyJson() {
    try {
      final parsed = json.decode(_valueController.text);
      final minified = json.encode(parsed);
      _valueController.text = minified;
      _validateJson();
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Invalid JSON - cannot minify'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isEditing ? 'Edit Key-Value' : 'Add Key-Value'),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.6,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Key field
            TextField(
              controller: _keyController,
              decoration: const InputDecoration(
                labelText: 'Key',
                hintText: 'Enter key name',
              ),
              readOnly: widget.isEditing,
              autofocus: !widget.isEditing,
            ),
            const SizedBox(height: 16),

            // Value field with JSON indicator
            Row(
              children: [
                const Text('Value'),
                const Spacer(),
                if (_valueController.text.isNotEmpty) ...[
                  Icon(
                    _isValidJson ? Icons.check_circle : Icons.text_snippet,
                    size: 16,
                    color: _isValidJson ? AppTheme.successColor : AppTheme.secondaryColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _isValidJson ? 'Valid JSON' : 'Plain text',
                    style: TextStyle(
                      fontSize: 12,
                      color: _isValidJson ? AppTheme.successColor : AppTheme.secondaryColor,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: TextField(
                controller: _valueController,
                decoration: const InputDecoration(
                  hintText: 'Enter value (plain text or JSON)',
                  alignLabelWithHint: true,
                ),
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
                onChanged: (_) => _validateJson(),
                autofocus: widget.isEditing,
              ),
            ),
            const SizedBox(height: 8),

            // JSON formatting buttons
            if (_isValidJson)
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _formatJson,
                    icon: const Icon(Icons.format_align_left, size: 16),
                    label: const Text('Format'),
                  ),
                  TextButton.icon(
                    onPressed: _minifyJson,
                    icon: const Icon(Icons.compress, size: 16),
                    label: const Text('Minify'),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final key = _keyController.text.trim();
            final value = _valueController.text;

            if (key.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Key cannot be empty'),
                  backgroundColor: AppTheme.errorColor,
                ),
              );
              return;
            }

            Navigator.of(context).pop((key, value));
          },
          style: AppTheme.primaryButtonStyle,
          child: Text(widget.isEditing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}
