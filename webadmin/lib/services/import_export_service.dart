import 'dart:async';
import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import 'package:bitbarrel_admin/services/connection_service.dart';
import 'package:bitbarrel_admin/services/barrel_service.dart';
import 'package:bitbarrel/bitbarrel.dart';

/// Format options for export/import
enum ExportFormat {
  jsonl,
  csv,
}

/// Scope of data to export
enum ExportScope {
  all,        // Entire barrel
  filtered,   // Current filter/query results
  selection,  // Specific selected keys
}

/// Format options for import
enum ImportFormat {
  jsonl,
  csv,
  auto,       // Auto-detect from file extension/content
}

/// Conflict resolution strategy for imports
enum ConflictResolution {
  skip,       // Skip keys that already exist
  overwrite,  // Replace existing values
  abort,      // Stop on first conflict
}

/// Progress during export operation
class ExportProgress {
  final int current;
  final int? total;
  final String data; // Formatted line

  ExportProgress({
    required this.current,
    this.total,
    required this.data,
  });

  double? get percentage => total != null && total! > 0
      ? current / total!
      : null;
}

/// Progress during import operation
class ImportProgress {
  final int imported;
  final int skipped;
  final int errors;
  final String? lastError;

  ImportProgress({
    required this.imported,
    this.skipped = 0,
    this.errors = 0,
    this.lastError,
  });
}

/// Result of previewing an import file
class PreviewResult {
  final ImportFormat detectedFormat;
  final List<(String key, String value)> sample;
  final List<String> errors;
  final bool isValid;

  PreviewResult({
    required this.detectedFormat,
    required this.sample,
    this.errors = const [],
    required this.isValid,
  });
}

/// Options for export operation
class ExportOptions {
  final ExportFormat format;
  final ExportScope scope;
  final String? prefixFilter;
  final List<String>? selectedKeys;
  final bool compress;

  ExportOptions({
    required this.format,
    required this.scope,
    this.prefixFilter,
    this.selectedKeys,
    this.compress = false,
  });
}

/// Options for import operation
class ImportOptions {
  final ImportFormat format;
  final ConflictResolution conflictResolution;
  final int batchSize;

  ImportOptions({
    required this.format,
    this.conflictResolution = ConflictResolution.skip,
    this.batchSize = 1000,
  });
}

/// Service for importing and exporting data
class ImportExportService extends ChangeNotifier {
  final ConnectionService _connectionService;
  final BarrelService _barrelService;

  ImportExportService(
    this._connectionService,
    this._barrelService,
  );

  /// Stream data export in the specified format
  Stream<ExportProgress> exportData(ExportOptions options) async* {
    final client = _connectionService.client;
    if (client == null) {
      throw Exception('Not connected to server');
    }

    // Check if we have a current barrel
    final barrel = _barrelService.currentBarrel.value;
    if (barrel == null) {
      throw Exception('No barrel selected');
    }

    int totalExported = 0;
    String cursor = '';
    bool hasMore = true;
    int? totalCount;

    // Get total count for progress if exporting all
    if (options.scope == ExportScope.all) {
      try {
        totalCount = await client.count();
      } catch (e) {
        // If count fails, we'll just not show progress percentage
        totalCount = null;
      }
    }

    // Stream data in batches
    while (hasMore) {
      try {
        if (options.scope == ExportScope.all || options.scope == ExportScope.filtered) {
          // Use prefix query for CritBit mode
          final barrel = _barrelService.currentBarrel.value;
          if (barrel?.supportsRangeQueries ?? false) {
            final prefix = options.prefixFilter ?? '';
            final result = await client.prefixQuery(prefix,
                limit: 1000, cursor: cursor);
            cursor = result.nextCursor;
            hasMore = result.hasMore;

            // Format and yield each item
            for (final item in result.items) {
              final formatted = _formatExportLine(item.key, item.value, options.format);
              yield ExportProgress(
                current: ++totalExported,
                total: totalCount,
                data: formatted,
              );
            }
          } else {
            // For Hash mode, we need a different approach
            throw Exception(
                'Hash mode export not supported in current implementation');
          }
        } else if (options.scope == ExportScope.selection) {
          // Export specific list of keys
          final keysToExport = options.selectedKeys ?? [];
          for (final key in keysToExport) {
            try {
              final value = await client.get(key);
              final formatted = _formatExportLine(key, value, options.format);
              yield ExportProgress(
                current: ++totalExported,
                total: keysToExport.length,
                data: formatted,
              );
            } catch (e) {
              // Key might not exist, skip it
            }
          }
          hasMore = false; // Single batch for selection
        } else {
          throw Exception('Unknown export scope: ${options.scope}');
        }

        // If we got fewer items than requested and no cursor, we might be done
        if (!hasMore && cursor.isEmpty) {
          hasMore = false;
        }
      } catch (e) {
        throw Exception('Export failed at item $totalExported: $e');
      }
    }
  }

  /// Stream data import from file content
  Stream<ImportProgress> importData(String content, ImportOptions options) async* {
    final client = _connectionService.client;
    if (client == null) {
      throw Exception('Not connected to server');
    }

    final lines = const LineSplitter().convert(content);
    final batch = <(String key, String value)>[];
    int imported = 0;
    int skipped = 0;
    int errors = 0;
    String? lastError;

    // Determine the actual format if set to auto
    ImportFormat format = options.format;
    if (format == ImportFormat.auto) {
      format = _detectFormatFromContent(content);
      if (format == ImportFormat.auto) {
        throw Exception('Could not auto-detect file format');
      }
    }

    for (int lineNum = 0; lineNum < lines.length; lineNum++) {
      final line = lines[lineNum].trim();
      if (line.isEmpty) continue;

      try {
        final (key, value) = _parseImportLine(line, format);

        // Check for conflicts if needed
        if (options.conflictResolution == ConflictResolution.skip ||
            options.conflictResolution == ConflictResolution.abort) {
          try {
            await client.get(key);
            // Key exists
            if (options.conflictResolution == ConflictResolution.skip) {
              skipped++;
              continue;
            } else if (options.conflictResolution == ConflictResolution.abort) {
              throw Exception('Key already exists: $key');
            }
          } catch (e) {
            // Key doesn't exist or other error, proceed with import
            // For abort resolution, we only abort on "key exists"
          }
        }

        batch.add((key, value));

        // Process batch when full
        if (batch.length >= options.batchSize) {
          await _processBatch(client, batch);
          imported += batch.length;
          batch.clear();

          yield ImportProgress(
            imported: imported,
            skipped: skipped,
            errors: errors,
            lastError: lastError,
          );
        }
      } catch (e) {
        errors++;
        lastError = 'Line ${lineNum + 1}: $e';

        if (options.conflictResolution == ConflictResolution.abort) {
          throw Exception('Import failed at line ${lineNum + 1}: $e');
        }
      }
    }

    // Process remaining batch
    if (batch.isNotEmpty) {
      try {
        await _processBatch(client, batch);
        imported += batch.length;
      } catch (e) {
        errors++;
        lastError = 'Final batch: $e';
      }
    }

    yield ImportProgress(
      imported: imported,
      skipped: skipped,
      errors: errors,
      lastError: lastError,
    );
  }

  /// Preview an import file and return sample data
  Future<PreviewResult> previewImport(String content, ImportOptions options) async {
    final lines = const LineSplitter().convert(content);
    final sample = <(String, String)>[];
    final errors = <String>[];

    // Determine format
    ImportFormat format = options.format;
    if (format == ImportFormat.auto) {
      format = _detectFormatFromContent(content);
    }

    // Parse up to 10 lines for preview
    for (int i = 0; i < lines.length && i < 10; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      try {
        final (key, value) = _parseImportLine(line, format);
        sample.add((key, value));
      } catch (e) {
        errors.add('Line ${i + 1}: $e');
      }
    }

    return PreviewResult(
      detectedFormat: format,
      sample: sample,
      errors: errors,
      isValid: errors.isEmpty && sample.isNotEmpty,
    );
  }

  /// Format a single line for export
  String _formatExportLine(String key, String value, ExportFormat format) {
    switch (format) {
      case ExportFormat.jsonl:
        final jsonKey = json.encode(key);
        final jsonValue = json.encode(value);
        return '{"key":$jsonKey,"value":$jsonValue}';

      case ExportFormat.csv:
        // Escape CSV values
        final escapedKey = _escapeCsvValue(key);
        final escapedValue = _escapeCsvValue(value);
        return '$escapedKey,$escapedValue';
    }
  }

  /// Parse a single import line
  (String key, String value) _parseImportLine(String line, ImportFormat format) {
    switch (format) {
      case ImportFormat.jsonl:
        return _parseJsonlLine(line);

      case ImportFormat.csv:
        return _parseCsvLine(line);

      case ImportFormat.auto:
        throw Exception('Auto format should be resolved before parsing');
    }
  }

  /// Parse a JSONL line
  (String key, String value) _parseJsonlLine(String line) {
    try {
      final jsonMap = json.decode(line);
      if (jsonMap is! Map<String, dynamic>) {
        throw Exception('Invalid JSONL format: expected object');
      }

      final key = jsonMap['key'];
      final value = jsonMap['value'];

      if (key == null) {
        throw Exception('Missing "key" field');
      }
      if (value == null) {
        throw Exception('Missing "value" field');
      }

      return (key.toString(), value.toString());
    } catch (e) {
      throw Exception('Invalid JSONL format: $e');
    }
  }

  /// Parse a CSV line
  (String key, String value) _parseCsvLine(String line) {
    try {
      final csvList = const CsvToListConverter().convert(line);
      if (csvList.isEmpty || csvList.first.length < 2) {
        throw Exception('Invalid CSV format: expected 2 columns');
      }

      final key = csvList.first[0]?.toString() ?? '';
      final value = csvList.first[1]?.toString() ?? '';

      if (key.isEmpty) {
        throw Exception('Empty key in CSV');
      }

      return (key, value);
    } catch (e) {
      throw Exception('Invalid CSV format: $e');
    }
  }

  /// Escape a value for CSV
  String _escapeCsvValue(String value) {
    // If value contains comma, quote, or newline, wrap in quotes and escape quotes
    if (value.contains(',') || value.contains('"') || value.contains('\n') || value.contains('\r')) {
      final escaped = value.replaceAll('"', '""');
      return '"$escaped"';
    }
    return value;
  }

  /// Detect format from file content
  ImportFormat _detectFormatFromContent(String content) {
    final lines = const LineSplitter().convert(content);

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // Check if it looks like JSONL
      if (trimmed.startsWith('{') && trimmed.contains('"key"') && trimmed.contains('"value"')) {
        return ImportFormat.jsonl;
      }

      // Check if it looks like CSV
      final commaCount = ','.allMatches(trimmed).length;
      if (commaCount >= 1 && !trimmed.startsWith('{')) {
        return ImportFormat.csv;
      }
    }

    return ImportFormat.auto; // Could not detect
  }

  /// Process a batch of key-value pairs
  Future<void> _processBatch(dynamic client, List<(String, String)> batch) async {
    // Process batch in parallel for better performance
    final futures = <Future<void>>[];

    for (final (key, value) in batch) {
      futures.add(client.set(key, value));
    }

    await Future.wait(futures);
  }

  /// Auto-detect format from filename and content
  ImportFormat detectFormat(String filename, String content) {
    // Check file extension first
    final lowerName = filename.toLowerCase();
    if (lowerName.endsWith('.jsonl') || lowerName.endsWith('.json')) {
      return ImportFormat.jsonl;
    } else if (lowerName.endsWith('.csv')) {
      return ImportFormat.csv;
    }

    // Fall back to content detection
    return _detectFormatFromContent(content);
  }
}
