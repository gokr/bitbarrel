import 'package:equatable/equatable.dart';

/// Represents a BitBarrel barrel (database)
class Barrel extends Equatable {
  final String name;
  final String? config;
  final int? keyCount;
  final DateTime? createdAt;

  const Barrel({
    required this.name,
    this.config,
    this.keyCount,
    this.createdAt,
  });

  String? get indexMode {
    if (config == null) return null;
    // Simple parsing to extract mode from config JSON
    final modeMatch = RegExp(r'"mode"\s*:\s*"([^"]+)"').firstMatch(config!);
    final mode = modeMatch?.group(1);
    // Convert server format to display format
    if (mode == 'hash') return 'Hash';
    if (mode == 'critbit') return 'CritBit';
    return mode;
  }

  bool get supportsRangeQueries => indexMode == 'CritBit';

  Barrel copyWith({
    String? name,
    String? config,
    int? keyCount,
    DateTime? createdAt,
  }) {
    return Barrel(
      name: name ?? this.name,
      config: config ?? this.config,
      keyCount: keyCount ?? this.keyCount,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  List<Object?> get props => [name, config, keyCount, createdAt];
}
