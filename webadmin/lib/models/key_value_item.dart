import 'dart:convert';

/// Model representing a key-value pair from the barrel
class KeyValueItem {
  final String key;
  final String value;

  const KeyValueItem({
    required this.key,
    required this.value,
  });

  /// Check if the value is valid JSON
  bool get isJson {
    if (value.isEmpty) return false;
    try {
      json.decode(value);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Get a preview of the value (truncated for display)
  String get valuePreview {
    if (value.isEmpty) return '(empty)';
    const maxLen = 100;
    if (value.length <= maxLen) return value;
    return '${value.substring(0, maxLen)}...';
  }

  /// Create a copy with modified fields
  KeyValueItem copyWith({
    String? key,
    String? value,
  }) {
    return KeyValueItem(
      key: key ?? this.key,
      value: value ?? this.value,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is KeyValueItem && other.key == key && other.value == value;
  }

  @override
  int get hashCode => key.hashCode ^ value.hashCode;

  @override
  String toString() => 'KeyValueItem(key: $key, value: $valuePreview)';
}
