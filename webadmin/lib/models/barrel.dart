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
    return modeMatch?.group(1);
  }

  bool get supportsRangeQueries => indexMode == 'bmCritBit';

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
