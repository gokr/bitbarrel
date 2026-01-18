import 'dart:convert';

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

// ============================================================================
// Pub/Sub Types
// ============================================================================

/// Pub/Sub message type
class PubSubMessageType {
  // Prevent instantiation
  PubSubMessageType._();

  /// Data message
  static const int data = 0;

  /// Presence message
  static const int presence = 1;
}

/// Event received from PubSub subscription
class PubSubEvent {
  /// Topic the event was published to
  final String topic;

  /// Message type (data or presence)
  final int messageType;

  /// Sequence number
  final int sequence;

  /// Timestamp
  final int timestamp;

  /// Headers (optional JSON string)
  final String headers;

  /// Message payload
  final String payload;

  const PubSubEvent({
    required this.topic,
    required this.messageType,
    required this.sequence,
    required this.timestamp,
    required this.headers,
    required this.payload,
  });

  @override
  String toString() {
    final typeName = messageType == PubSubMessageType.data ? 'DATA' : 'PRESENCE';
    return 'PubSubEvent(topic: $topic, type: $typeName, seq: $sequence, '
        'payload: $payload)';
  }
}

/// Options for subscribing to a topic
class SubscriptionOptions {
  /// Enable key-value events
  final bool enableKvEvents;

  /// Enable presence tracking
  final bool enablePresence;

  /// Replay historical messages
  final bool replayHistory;

  const SubscriptionOptions({
    this.enableKvEvents = false,
    this.enablePresence = false,
    this.replayHistory = false,
  });

  /// Default options
  static const defaults = SubscriptionOptions();

  /// Encode options to a single byte
  int encode() {
    var opts = 0;
    if (enableKvEvents) opts |= 0x01;
    if (enablePresence) opts |= 0x02;
    if (replayHistory) opts |= 0x04;
    return opts;
  }
}

/// Information about a subscription
class SubscriptionInfo {
  /// Subscription ID
  final String id;

  /// Client ID
  final int clientId;

  /// Topic name
  final String topic;

  /// Pattern (for wildcard subscriptions)
  final String pattern;

  const SubscriptionInfo({
    required this.id,
    required this.clientId,
    required this.topic,
    required this.pattern,
  });

  @override
  String toString() =>
      'SubscriptionInfo(id: $id, clientId: $clientId, topic: $topic, pattern: $pattern)';

  /// Create SubscriptionInfo from JSON
  factory SubscriptionInfo.fromJson(Map<String, dynamic> json) {
    /// Helper to safely extract int from JSON (handles both int and double)
    int toInt(dynamic value, int fallback) {
      if (value == null) return fallback;
      if (value is int) return value;
      if (value is double) return value.toInt();
      return fallback;
    }

    return SubscriptionInfo(
      id: json['subscriptionId'] as String? ?? '',
      clientId: toInt(json['clientId'], 0),
      topic: json['topic'] as String? ?? '',
      pattern: json['pattern'] as String? ?? '',
    );
  }
}

/// Single member in presence data
class PresenceMember {
  /// Client ID
  final int clientId;

  /// Username
  final String username;

  /// Unix timestamp when client joined
  final int joinedAt;

  /// Unix timestamp of last ping
  final int lastPing;

  /// Metadata (optional JSON string)
  final String metadata;

  const PresenceMember({
    required this.clientId,
    required this.username,
    required this.joinedAt,
    required this.lastPing,
    this.metadata = '',
  });

  @override
  String toString() => 'PresenceMember(clientId: $clientId, username: $username)';

  /// Create PresenceMember from JSON
  factory PresenceMember.fromJson(Map<String, dynamic> json) {
    /// Helper to safely extract int from JSON (handles both int and double)
    int toInt(dynamic value, int fallback) {
      if (value == null) return fallback;
      if (value is int) return value;
      if (value is double) return value.toInt();
      return fallback;
    }

    return PresenceMember(
      clientId: toInt(json['clientId'], 0),
      username: json['username'] as String? ?? '',
      joinedAt: toInt(json['joinedAt'], 0),
      lastPing: toInt(json['lastPing'], 0),
      metadata: json['metadata'] != null
          ? jsonEncode(json['metadata'])
          : '',
    );
  }
}

/// Presence information for a topic
class PresenceInfo {
  /// Topic name
  final String topic;

  /// Active members
  final List<PresenceMember> members;

  /// Last update timestamp
  final int lastUpdate;

  const PresenceInfo({
    required this.topic,
    required this.members,
    required this.lastUpdate,
  });

  @override
  String toString() => 'PresenceInfo(topic: $topic, members: ${members.length})';
}

/// Information about a topic
class TopicInfo {
  /// Topic name
  final String name;

  /// Current sequence number
  final int sequence;

  /// Number of active subscribers
  final int subscriberCount;

  /// Total message count
  final int messageCount;

  const TopicInfo({
    required this.name,
    required this.sequence,
    required this.subscriberCount,
    required this.messageCount,
  });

  @override
  String toString() =>
      'TopicInfo(name: $name, seq: $sequence, subs: $subscriberCount, msgs: $messageCount)';

  /// Create TopicInfo from JSON
  factory TopicInfo.fromJson(Map<String, dynamic> json) {
    /// Helper to safely extract int from JSON (handles both int and double)
    int toInt(dynamic value, int fallback) {
      if (value == null) return fallback;
      if (value is int) return value;
      if (value is double) return value.toInt();
      return fallback;
    }

    return TopicInfo(
      name: json['name'] as String? ?? '',
      sequence: toInt(json['sequence'], 0),
      subscriberCount: toInt(json['subscriberCount'], 0),
      messageCount: toInt(json['messageCount'], 0),
    );
  }
}

/// Parameters for history queries
class HistoryRequest {
  /// Maximum number of messages to return
  final int limit;

  /// Starting sequence number (0 for beginning)
  final int sinceSeq;

  const HistoryRequest({
    this.limit = 100,
    this.sinceSeq = 0,
  });

  /// Default request
  static const defaults = HistoryRequest();
}
