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
