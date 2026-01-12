import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:bitbarrel_admin/services/import_export_service.dart';
import 'package:bitbarrel_admin/services/connection_service.dart';
import 'package:bitbarrel_admin/services/barrel_service.dart';
import 'package:bitbarrel_admin/theme/app_theme.dart';
import 'package:watch_it/watch_it.dart';

/// Dialog for importing data into a barrel
class ImportDialog extends StatefulWidget {
  const ImportDialog({super.key});

  /// Show the import dialog
  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (context) => const ImportDialog(),
    ).then((_) {});
  }

  @override
  State<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<ImportDialog> {
  late final ImportExportService _service;

  // File selection
  String? _selectedFilename;
  Uint8List? _fileContent;

  // UI state
  ImportFormat _format = ImportFormat.auto;
  ConflictResolution _conflictResolution = ConflictResolution.skip;
  bool _isPreviewing = false;
  bool _isImporting = false;
  String? _error;
  String? _successMessage;

  // Preview data
  PreviewResult? _previewResult;
  List<(String key, String value)> _previewLines = [];

  // Progress
  int _importedCount = 0;
  int _skippedCount = 0;
  int _errorCount = 0;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    _service = ImportExportService(
      di<ConnectionService>(),
      di<BarrelService>(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 700,
        height: _previewLines.isNotEmpty ? 600 : null,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(Icons.file_upload, color: AppTheme.primaryColor, size: 32),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'Import Data',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: AppTheme.primaryColor,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _isImporting ? null : () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Step 1: File selection
            if (!_isPreviewing && !_isImporting) ...[
              _buildFileSelection(),
            ],

            // Step 2: Options (after file selected)
            if (_selectedFilename != null && !_isPreviewing && !_isImporting) ...[
              const SizedBox(height: 24),
              _buildOptions(),
            ],

            // Step 3: Preview (after validation)
            if (_isPreviewing && !_isImporting) ...[
              const SizedBox(height: 24),
              _buildPreview(),
            ],

            // Step 4: Progress (during import)
            if (_isImporting) ...[
              const SizedBox(height: 24),
              _buildProgressIndicator(),
            ],

            // Success message
            if (_successMessage != null) ...[
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.successColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppTheme.successColor.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, color: AppTheme.successColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _successMessage!,
                        style: const TextStyle(color: AppTheme.successColor),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Error message
            if (_error != null) ...[
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.errorColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppTheme.errorColor.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: AppTheme.errorColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: AppTheme.errorColor),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Actions
            if (!_isImporting || _successMessage != null) ...[
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isImporting ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  if (!_isPreviewing && _selectedFilename != null)
                    ElevatedButton(
                      onPressed: _validateAndPreview,
                      child: const Text('Preview'),
                    )
                  else if (_isPreviewing && _previewResult?.isValid == true)
                    ElevatedButton.icon(
                      onPressed: _startImport,
                      icon: const Icon(Icons.file_upload),
                      label: const Text('Import'),
                      style: AppTheme.primaryButtonStyle,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFileSelection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Select File',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border.all(color: AppTheme.secondaryColor.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: _selectedFilename == null
              ? Column(
                  children: [
                    Icon(
                      Icons.insert_drive_file,
                      size: 48,
                      color: AppTheme.secondaryColor.withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'No file selected',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppTheme.secondaryColor,
                          ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _pickFile,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Choose File'),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Icon(
                      Icons.insert_drive_file,
                      color: AppTheme.primaryColor,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedFilename!,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            'Format: ${_format == ImportFormat.auto ? 'Auto-detect' : _format.name.toUpperCase()}',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: AppTheme.secondaryColor,
                                ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        setState(() {
                          _selectedFilename = null;
                          _fileContent = null;
                          _previewResult = null;
                          _previewLines = [];
                        });
                      },
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildOptions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Options',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 8),

        // Format selection
        Row(
          children: [
            Text(
              'Format:',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: DropdownButtonFormField<ImportFormat>(
                value: _format,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: ImportFormat.auto,
                    child: Text('Auto-detect'),
                  ),
                  DropdownMenuItem(
                    value: ImportFormat.jsonl,
                    child: Text('JSON Lines'),
                  ),
                  DropdownMenuItem(
                    value: ImportFormat.csv,
                    child: Text('CSV'),
                  ),
                ],
                onChanged: (value) {
                  setState(() => _format = value ?? ImportFormat.auto);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Conflict resolution
        Row(
          children: [
            Text(
              'On conflict:',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: DropdownButtonFormField<ConflictResolution>(
                value: _conflictResolution,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: ConflictResolution.skip,
                    child: Text('Skip existing keys'),
                  ),
                  DropdownMenuItem(
                    value: ConflictResolution.overwrite,
                    child: Text('Overwrite existing keys'),
                  ),
                  DropdownMenuItem(
                    value: ConflictResolution.abort,
                    child: Text('Stop on conflict'),
                  ),
                ],
                onChanged: (value) {
                  setState(() => _conflictResolution = value ?? ConflictResolution.skip);
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPreview() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.visibility, color: AppTheme.accentColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Preview (showing ${(_previewLines.length)} of ${_previewResult?.sample.length ?? 0} valid rows)',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppTheme.accentColor,
                    ),
              ),
            ),
            if (_previewResult?.isValid == true)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.successColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Ready to import',
                  style: TextStyle(
                    color: AppTheme.successColor,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),

        // Preview table
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: AppTheme.secondaryColor.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.builder(
              itemCount: _previewLines.length,
              itemBuilder: (context, index) {
                final (key, value) = _previewLines[index];
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: AppTheme.secondaryColor.withValues(alpha: 0.1),
                      ),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Key',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppTheme.secondaryColor,
                                  ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              key,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Value',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppTheme.secondaryColor,
                                  ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              value.length > 100 ? '${value.substring(0, 97)}...' : value,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),

        // Validation errors
        if (_previewResult?.errors.isNotEmpty ?? false) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.errorColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: AppTheme.errorColor.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.warning, color: AppTheme.errorColor, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      'Validation Issues',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: AppTheme.errorColor,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ..._previewResult!.errors.take(3).map((error) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '• $error',
                        style: const TextStyle(
                          color: AppTheme.errorColor,
                          fontSize: 12,
                        ),
                      ),
                    )),
                if (_previewResult!.errors.length > 3)
                  Text(
                    '... and ${_previewResult!.errors.length - 3} more issues',
                    style: const TextStyle(
                      color: AppTheme.errorColor,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildProgressIndicator() {
    final totalImported = _importedCount + _skippedCount + _errorCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Importing...',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              '$totalImported total',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.secondaryColor,
                  ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(),
        const SizedBox(height: 8),
        // Stats
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildStat(Icons.check_circle, AppTheme.successColor,
                'Imported\n$_importedCount'),
            _buildStat(Icons.skip_next, AppTheme.secondaryColor,
                'Skipped\n$_skippedCount'),
            _buildStat(Icons.error_outline, AppTheme.errorColor,
                'Errors\n$_errorCount'),
          ],
        ),
        if (_lastError != null) ...[
          const SizedBox(height: 8),
          Text(
            'Last error: $_lastError',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.errorColor,
                ),
          ),
        ],
      ],
    );
  }

  Widget _buildStat(IconData icon, Color color, String label) {
    return Column(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 4),
        Text(
          label,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.secondaryColor,
              ),
        ),
      ],
    );
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jsonl', 'json', 'csv', 'txt'],
      withData: true,
    );

    if (result != null && result.files.isNotEmpty) {
      final file = result.files.first;
      setState(() {
        _selectedFilename = file.name;
        _fileContent = file.bytes;
        _error = null;
        _successMessage = null;
      });

      // Auto-detect format
      if (file.name.toLowerCase().endsWith('.csv')) {
        setState(() => _format = ImportFormat.csv);
      } else if (file.name.toLowerCase().endsWith('.jsonl') ||
                 file.name.toLowerCase().endsWith('.json')) {
        setState(() => _format = ImportFormat.jsonl);
      }
    }
  }

  Future<void> _validateAndPreview() async {
    if (_fileContent == null) {
      setState(() => _error = 'No file selected');
      return;
    }

    setState(() {
      _isPreviewing = true;
      _error = null;
      _successMessage = null;
    });

    try {
      final content = utf8.decode(_fileContent!);
      final options = ImportOptions(
        format: _format,
        conflictResolution: _conflictResolution,
      );

      final result = await _service.previewImport(content, options);

      setState(() {
        _previewResult = result;
        _previewLines = result.sample;
        _isPreviewing = false;

        if (result.errors.isNotEmpty) {
          _error = 'File has validation issues. Check preview.';
        } else if (!result.isValid || result.sample.isEmpty) {
          _error = 'No valid data found in file';
        }
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to validate file: $e';
        _isPreviewing = false;
      });
    }
  }

  Future<void> _startImport() async {
    if (_fileContent == null || _previewResult == null || !_previewResult!.isValid) {
      setState(() => _error = 'Cannot import: file not ready');
      return;
    }

    setState(() {
      _isImporting = true;
      _error = null;
      _importedCount = 0;
      _skippedCount = 0;
      _errorCount = 0;
      _lastError = null;
      _previewLines = [];
    });

    try {
      final content = utf8.decode(_fileContent!);
      final options = ImportOptions(
        format: _previewResult!.detectedFormat,
        conflictResolution: _conflictResolution,
      );

      final importStream = _service.importData(content, options);

      await for (final progress in importStream) {
        if (mounted) {
          setState(() {
            _importedCount = progress.imported;
            _skippedCount = progress.skipped;
            _errorCount = progress.errors;
            _lastError = progress.lastError;
          });
        }
      }

      if (mounted) {
        setState(() {
          _isImporting = false;
          _successMessage =
              'Import complete: $_importedCount imported, $_skippedCount skipped, $_errorCount errors';
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Import failed: $e';
        _isImporting = false;
      });
    }
  }
}
