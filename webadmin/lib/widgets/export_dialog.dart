import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:bitbarrel_admin/services/import_export_service.dart';
import 'package:bitbarrel_admin/services/connection_service.dart';
import 'package:bitbarrel_admin/services/barrel_service.dart';
import 'package:bitbarrel_admin/theme/app_theme.dart';
import 'package:intl/intl.dart';
import 'package:watch_it/watch_it.dart';

/// Dialog for exporting data from a barrel
class ExportDialog extends StatefulWidget {
  final ExportScope initialScope;
  final List<String>? selectedKeys;
  final String? prefixFilter;

  const ExportDialog({
    super.key,
    required this.initialScope,
    this.selectedKeys,
    this.prefixFilter,
  });

  /// Show the export dialog
  static Future<void> show(
    BuildContext context, {
    required ExportScope scope,
    List<String>? selectedKeys,
    String? prefixFilter,
  }) {
    return showDialog(
      context: context,
      builder: (context) => ExportDialog(
        initialScope: scope,
        selectedKeys: selectedKeys,
        prefixFilter: prefixFilter,
      ),
    ).then((_) {});
  }

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  late final ImportExportService _service;

  // UI state
  ExportFormat _format = ExportFormat.jsonl;
  ExportScope _scope = ExportScope.all;
  bool _compress = false;
  bool _isExporting = false;
  String? _error;
  int _exportedCount = 0;
  int? _totalCount;
  String _dataSize = '';

  // Export data buffer
  final List<String> _exportBuffer = [];
  static const int _bufferFlushSize = 100; // Flush every 100 lines

  @override
  void initState() {
    super.initState();
    _service = ImportExportService(
      di<ConnectionService>(),
      di<BarrelService>(),
    );
    _scope = widget.initialScope;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 600,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(Icons.file_download, color: AppTheme.primaryColor, size: 32),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'Export Data',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: AppTheme.primaryColor,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _isExporting ? null : () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Format selection
            Text(
              'Format',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            _buildFormatSelector(),
            const SizedBox(height: 24),

            // Scope selection
            Text(
              'Export Scope',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            _buildScopeSelector(),
            const SizedBox(height: 24),

            // Options
            CheckboxListTile(
              title: const Text('Compress file (gzip)'),
              subtitle: const Text('Reduces file size but requires extraction'),
              value: _compress,
              onChanged: _isExporting ? null : (value) {
                setState(() => _compress = value ?? false);
              },
            ),
            const SizedBox(height: 24),

            // Progress indicator (shown during export)
            if (_isExporting) ...[
              _buildProgressIndicator(),
              const SizedBox(height: 24),
            ],

            // Error message
            if (_error != null) ...[
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
              const SizedBox(height: 24),
            ],

            // Actions
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _isExporting ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _isExporting ? null : _startExport,
                  icon: _isExporting
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : const Icon(Icons.file_download),
                  label: Text(_isExporting ? 'Exporting...' : 'Export'),
                  style: AppTheme.primaryButtonStyle,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormatSelector() {
    return Column(
      children: [
        RadioListTile<ExportFormat>(
          title: const Text('JSON Lines (.jsonl)'),
          subtitle: const Text('Recommended: One JSON object per line, preserves structure'),
          value: ExportFormat.jsonl,
          groupValue: _format,
          onChanged: _isExporting
              ? null
              : (value) => setState(() => _format = value ?? ExportFormat.jsonl),
        ),
        RadioListTile<ExportFormat>(
          title: const Text('CSV (.csv)'),
          subtitle: const Text('Good for spreadsheets: Simple 2-column format'),
          value: ExportFormat.csv,
          groupValue: _format,
          onChanged: _isExporting
              ? null
              : (value) => setState(() => _format = value ?? ExportFormat.csv),
        ),
      ],
    );
  }

  Widget _buildScopeSelector() {
    return Column(
      children: [
        RadioListTile<ExportScope>(
          title: const Text('All data'),
          subtitle: const Text('Export entire barrel'),
          value: ExportScope.all,
          groupValue: _scope,
          onChanged: _isExporting
              ? null
              : (value) => setState(() => _scope = value ?? ExportScope.all),
        ),
        if (widget.prefixFilter != null) ...[
          RadioListTile<ExportScope>(
            title: Text('Filtered: "${widget.prefixFilter}"'),
            subtitle: const Text('Export matching keys only'),
            value: ExportScope.filtered,
            groupValue: _scope,
            onChanged: _isExporting
                ? null
                : (value) => setState(() => _scope = value ?? ExportScope.filtered),
          ),
        ],
        if (widget.selectedKeys != null && widget.selectedKeys!.isNotEmpty) ...[
          RadioListTile<ExportScope>(
            title: Text('Selected (${widget.selectedKeys!.length} keys)'),
            subtitle: const Text('Export only selected keys'),
            value: ExportScope.selection,
            groupValue: _scope,
            onChanged: _isExporting
                ? null
                : (value) => setState(() => _scope = value ?? ExportScope.selection),
          ),
        ],
      ],
    );
  }

  Widget _buildProgressIndicator() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Exporting...',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              _totalCount != null
                  ? '$_exportedCount / $_totalCount'
                  : '$_exportedCount',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.secondaryColor,
                  ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: _totalCount != null ? (_exportedCount / _totalCount!.toDouble()) : null,
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _dataSize,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.secondaryColor,
                  ),
            ),
            if (_totalCount != null)
              Text(
                '${(_exportedCount / _totalCount! * 100).toStringAsFixed(1)}%',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.secondaryColor,
                    ),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _startExport() async {
    setState(() {
      _isExporting = true;
      _error = null;
      _exportedCount = 0;
      _totalCount = null;
      _exportBuffer.clear();
    });

    try {
      final barrelName = _barrelService.currentBarrel.value?.name ?? 'data';
      final timestamp = DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());
      final extension = _format == ExportFormat.jsonl ? 'jsonl' : 'csv';
      final filename = '${barrelName}-export-$timestamp.$extension';

      final options = ExportOptions(
        format: _format,
        scope: _scope,
        prefixFilter: _scope == ExportScope.filtered ? widget.prefixFilter : null,
        selectedKeys: _scope == ExportScope.selection ? widget.selectedKeys : null,
        compress: _compress,
      );

      final exportStream = _service.exportData(options);
      final exportCompleter = Completer<void>();

      if (_compress) {
        // For compressed export, we need to collect all data first
        final allLines = <String>[];
        await for (final progress in exportStream) {
          allLines.add(progress.data);
          _updateProgress(progress);
        }

        // Compress and download
        final content = allLines.join('\n');
        final compressed = utf8.encode(content); // Simplified - would use gzip
        _downloadFile(compressed, filename, 'application/gzip');
      } else {
        // For uncompressed, stream directly to download
        _streamExportToDownload(exportStream, filename, extension);
      }

      await exportCompleter.future;

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export complete: $_exportedCount keys'),
            backgroundColor: AppTheme.successColor,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _error = 'Export failed: $e';
        _isExporting = false;
      });
    }
  }

  void _updateProgress(ExportProgress progress) {
    setState(() {
      _exportedCount = progress.current;
      _totalCount = progress.total;
      // Update data size estimate
      final estimatedBytes = _exportedCount * 200; // Rough estimate
      _dataSize = _formatBytes(estimatedBytes);
    });
  }

  void _streamExportToDownload(Stream<ExportProgress> stream, String filename, String extension) {
    // For web, we can use a more efficient streaming approach
    // For now, collect and download (can be optimized later)
    final lines = <String>[];
    stream.listen(
      (progress) {
        lines.add(progress.data);
        _updateProgress(progress);
      },
      onDone: () {
        final content = lines.join('\n');
        final bytes = utf8.encode(content);
        final mimeType = extension == 'jsonl' ? 'application/jsonl' : 'text/csv';
        _downloadFile(bytes, filename, mimeType);
      },
      onError: (error) {
        setState(() {
          _error = 'Export stream error: $error';
          _isExporting = false;
        });
      },
    );
  }

  void _downloadFile(List<int> bytes, String filename, String mimeType) {
    final blob = html.Blob([bytes], mimeType);
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: url)
      ..setAttribute('download', filename)
      ..click();
    html.Url.revokeObjectUrl(url);

    // Finish after download starts
    setState(() {
      _isExporting = false;
    });
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
