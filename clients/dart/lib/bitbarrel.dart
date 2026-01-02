/// BitBarrel client library for Dart/Flutter
///
/// This library provides a WebSocket-based client for the BitBarrel
/// key-value store that works on Android, iOS, and Flutter Web.
library bitbarrel;

// Core client
export 'src/client.dart' show BitBarrelClient;

// Configuration
export 'src/config.dart' show BitBarrelConfig;

// Public types
export 'src/types.dart'
    show
        KeyValue,
        RangeQueryResponse,
        TraverseOptions,
        TraverseResult,
        BarrelStats;

// Exceptions
export 'src/errors.dart';

// Protocol constants (for advanced users)
export 'src/protocol/commands.dart' show Command;
export 'src/protocol/status.dart' show Status;
