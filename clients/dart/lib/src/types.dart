/// Represents a key-value pair
class KeyValue {
  final String key;
  final String value;

  const KeyValue({required this.key, required this.value});

  @override
  String toString() => 'KeyValue($key: $value)';

  @override
  bool operator ==(Object other) =>
      other is KeyValue && other.key == key && other.value == value;

  @override
  int get hashCode => Object.hash(key, value);
}

/// Result of a keys-only range or prefix query with pagination support
class KeysResponse {
  /// Keys in this page
  final List<String> keys;

  /// Cursor for fetching the next page (empty if no more pages)
  final String nextCursor;

  /// Whether more items are available
  final bool hasMore;

  const KeysResponse({
    required this.keys,
    required this.nextCursor,
    required this.hasMore,
  });

  /// Creates an empty response (no keys)
  const KeysResponse.empty()
      : keys = const [],
        nextCursor = '',
        hasMore = false;
}

/// Result of a range or prefix query with pagination support
class RangeQueryResponse {
  /// Key-value pairs in this page
  final List<KeyValue> items;

  /// Cursor for fetching the next page (empty if no more pages)
  final String nextCursor;

  /// Whether more items are available
  final bool hasMore;

  const RangeQueryResponse({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
  });

  /// Creates an empty response (no items)
  const RangeQueryResponse.empty()
      : items = const [],
        nextCursor = '',
        hasMore = false;
}

/// Options for reference traversal
class TraverseOptions {
  /// Include full data instead of just references
  final bool includeFullData;

  /// Extract arrays as individual items
  final bool extractArrays;

  /// Return only the first matching result
  final bool firstOnly;

  const TraverseOptions({
    this.includeFullData = true,
    this.extractArrays = false,
    this.firstOnly = false,
  });

  /// Default options (full data, no extraction)
  static const defaults = TraverseOptions();

  /// Bit flag for protocol encoding
  int get flags {
    var flags = 0;
    if (includeFullData) flags |= 0x01;
    if (extractArrays) flags |= 0x02;
    if (firstOnly) flags |= 0x04;
    return flags;
  }
}

/// Result of a reference traversal
class TraverseResult {
  /// Path from starting key to this result
  final String path;

  /// The leaf key name
  final String key;

  /// The value at this location
  final String value;

  /// Extracted data (if options.includeFullData)
  final String extractedData;

  const TraverseResult({
    required this.path,
    required this.key,
    required this.value,
    this.extractedData = '',
  });

  @override
  String toString() => 'TraverseResult($key from $path)';
}

/// Comprehensive statistics for a BitBarrel barrel
class BarrelStats {
  /// Total keys including tombstones
  final int totalKeys;

  /// Active keys (excluding tombstones)
  final int activeKeys;

  /// Tombstone/deleted keys
  final int deletedKeys;

  /// Number of data files
  final int fileCount;

  /// Total bytes on disk for all files
  final int totalSize;

  /// Size of active data file
  final int activeFileSize;

  /// Average key size in bytes
  final double avgKeySize;

  /// Average value size in bytes
  final double avgValueSize;

  /// Average record size in bytes
  final double avgRecordSize;

  /// Fragmentation ratio (0.0 to 1.0)
  final double fragmentationRatio;

  /// Is compaction currently in progress
  final bool isCompacting;

  /// ISO timestamp of last compaction
  final String lastCompactTime;

  /// Records scanned in last compaction
  final int recordsScanned;

  /// Records kept in last compaction
  final int recordsKept;

  /// Records dropped in last compaction
  final int recordsDropped;

  /// Index mode (hash, critbit, hugecritbit)
  final String indexMode;

  /// Sync mode (none, sync, fsync)
  final String syncMode;

  /// Path to data files
  final String dataPath;

  /// ISO timestamp of last modification
  final String lastModified;

  const BarrelStats({
    required this.totalKeys,
    required this.activeKeys,
    required this.deletedKeys,
    required this.fileCount,
    required this.totalSize,
    required this.activeFileSize,
    required this.avgKeySize,
    required this.avgValueSize,
    required this.avgRecordSize,
    required this.fragmentationRatio,
    required this.isCompacting,
    required this.lastCompactTime,
    required this.recordsScanned,
    required this.recordsKept,
    required this.recordsDropped,
    required this.indexMode,
    required this.syncMode,
    required this.dataPath,
    required this.lastModified,
  });

  /// Creates an empty stats object (all zeros/defaults)
  const BarrelStats.empty()
      : totalKeys = 0,
        activeKeys = 0,
        deletedKeys = 0,
        fileCount = 0,
        totalSize = 0,
        activeFileSize = 0,
        avgKeySize = 0.0,
        avgValueSize = 0.0,
        avgRecordSize = 0.0,
        fragmentationRatio = 0.0,
        isCompacting = false,
        lastCompactTime = '',
        recordsScanned = 0,
        recordsKept = 0,
        recordsDropped = 0,
        indexMode = '',
        syncMode = '',
        dataPath = '',
        lastModified = '';

  /// Creates a BarrelStats from a JSON map
  factory BarrelStats.fromJson(Map<String, dynamic> json) {
    return BarrelStats(
      totalKeys: json['totalKeys'] ?? 0,
      activeKeys: json['activeKeys'] ?? 0,
      deletedKeys: json['deletedKeys'] ?? 0,
      fileCount: json['fileCount'] ?? 0,
      totalSize: json['totalSize'] ?? 0,
      activeFileSize: json['activeFileSize'] ?? 0,
      avgKeySize: json['avgKeySize']?.toDouble() ?? 0.0,
      avgValueSize: json['avgValueSize']?.toDouble() ?? 0.0,
      avgRecordSize: json['avgRecordSize']?.toDouble() ?? 0.0,
      fragmentationRatio: json['fragmentationRatio']?.toDouble() ?? 0.0,
      isCompacting: json['isCompacting'] ?? false,
      lastCompactTime: json['lastCompactTime'] ?? '',
      recordsScanned: json['recordsScanned'] ?? 0,
      recordsKept: json['recordsKept'] ?? 0,
      recordsDropped: json['recordsDropped'] ?? 0,
      indexMode: json['indexMode'] ?? '',
      syncMode: json['syncMode'] ?? '',
      dataPath: json['dataPath'] ?? '',
      lastModified: json['lastModified'] ?? '',
    );
  }

  @override
  String toString() {
    return 'BarrelStats(totalKeys: $totalKeys, activeKeys: $activeKeys, '
        'deletedKeys: $deletedKeys, totalSize: $totalSize bytes, '
        'fragmentation: ${(fragmentationRatio * 100).toStringAsFixed(1)}%)';
  }
}
