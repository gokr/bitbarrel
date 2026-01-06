import 'dart:convert';

/// Barrel configuration model
class BarrelConfig {
  final String mode;
  final String syncMode;
  final int writeBufferSize;
  final int readBufferSize;
  final bool autoCompact;
  final int compactionThreshold;
  final int maxDataFileSize;

  const BarrelConfig({
    required this.mode,
    required this.syncMode,
    required this.writeBufferSize,
    required this.readBufferSize,
    required this.autoCompact,
    required this.compactionThreshold,
    required this.maxDataFileSize,
  });

  /// Create from JSON string (server response format)
  factory BarrelConfig.fromJsonString(String jsonStr) {
    final json = jsonDecode(jsonStr) as Map<String, dynamic>;
    return BarrelConfig.fromJson(json);
  }

  /// Create from JSON map
  factory BarrelConfig.fromJson(Map<String, dynamic> json) {
    return BarrelConfig(
      mode: json['mode'] ?? 'bmHash',
      syncMode: json['syncMode'] ?? 'none',
      writeBufferSize: json['writeBufferSize'] ?? 65536,
      readBufferSize: json['readBufferSize'] ?? 65536,
      autoCompact: json['autoCompact'] ?? true,
      compactionThreshold: json['compactionThreshold'] ?? 50,
      maxDataFileSize: json['maxDataFileSize'] ?? 536870912,
    );
  }

  /// Convert to JSON string
  String toJsonString() {
    return jsonEncode(toJson());
  }

  /// Convert to JSON map
  Map<String, dynamic> toJson() {
    return {
      'mode': mode,
      'syncMode': syncMode,
      'writeBufferSize': writeBufferSize,
      'readBufferSize': readBufferSize,
      'autoCompact': autoCompact,
      'compactionThreshold': compactionThreshold,
      'maxDataFileSize': maxDataFileSize,
    };
  }

  /// Create a copy with modified values
  BarrelConfig copyWith({
    String? mode,
    String? syncMode,
    int? writeBufferSize,
    int? readBufferSize,
    bool? autoCompact,
    int? compactionThreshold,
    int? maxDataFileSize,
  }) {
    return BarrelConfig(
      mode: mode ?? this.mode,
      syncMode: syncMode ?? this.syncMode,
      writeBufferSize: writeBufferSize ?? this.writeBufferSize,
      readBufferSize: readBufferSize ?? this.readBufferSize,
      autoCompact: autoCompact ?? this.autoCompact,
      compactionThreshold: compactionThreshold ?? this.compactionThreshold,
      maxDataFileSize: maxDataFileSize ?? this.maxDataFileSize,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BarrelConfig &&
        other.mode == mode &&
        other.syncMode == syncMode &&
        other.writeBufferSize == writeBufferSize &&
        other.readBufferSize == readBufferSize &&
        other.autoCompact == autoCompact &&
        other.compactionThreshold == compactionThreshold &&
        other.maxDataFileSize == maxDataFileSize;
  }

  @override
  int get hashCode => Object.hash(
        mode,
        syncMode,
        writeBufferSize,
        readBufferSize,
        autoCompact,
        compactionThreshold,
        maxDataFileSize,
      );

  /// Human-readable mode name
  String get modeDisplayName {
    switch (mode) {
      case 'bmHash':
        return 'Hash (Fast lookup, no range queries)';
      case 'bmCritBit':
        return 'CritBit (Range queries supported)';
      case 'bmHugeCritBit':
        return 'HugeCritBit (Large datasets)';
      default:
        return mode;
    }
  }

  /// Human-readable sync mode name
  String get syncModeDisplayName {
    switch (syncMode) {
      case 'none':
        return 'None (Fastest, risk of data loss)';
      case 'sync':
        return 'Sync (OS flush)';
      case 'fsync':
        return 'Fsync (Disk sync - Safest)';
      default:
        return syncMode;
    }
  }

  /// Format bytes to human-readable string
  static String formatBytes(int bytes) {
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    } else if (bytes >= 1048576) {
      return '${(bytes / 1048576).toStringAsFixed(0)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}

/// Available sync modes
class SyncModes {
  static const List<String> values = ['none', 'sync', 'fsync'];

  static String displayName(String mode) {
    switch (mode) {
      case 'none':
        return 'None (Fastest, risk of data loss)';
      case 'sync':
        return 'Sync (OS flush)';
      case 'fsync':
        return 'Fsync (Disk sync - Safest)';
      default:
        return mode;
    }
  }
}