import 'dart:typed_data';
import 'dart:convert';

import 'commands.dart';

/// Binary encoding utilities for the BitBarrel protocol
class ProtocolEncoder {
  // Protocol limits
  static const int maxKeySize = 65535;
  static const int maxValueSize = 33554432;

  ProtocolEncoder._();

  /// Encode a standard request to binary format
  /// Format: [cmd:1][seq:4][keyLen:2][key:N][valLen:4][value:M]
  /// All multi-byte values are big-endian
  ///
  /// For binary protocol data (range query params, etc.), pass [binaryValue].
  /// For text data (SET values, etc.), pass [value] which will be UTF-8 encoded.
  static Uint8List encodeRequest({
    required int command,
    required int seq,
    required String key,
    String value = '',
    Uint8List? binaryValue,
  }) {
    if (!Command.isValid(command)) {
      throw ArgumentError('Invalid command: 0x${command.toRadixString(16)}');
    }

    final keyBytes = utf8.encode(key);
    final valueBytes = binaryValue ?? utf8.encode(value);

    if (keyBytes.length > maxKeySize) {
      throw ArgumentError(
        'Key too large: ${keyBytes.length} bytes (max $maxKeySize)',
      );
    }

    if (valueBytes.length > maxValueSize) {
      throw ArgumentError(
        'Value too large: ${valueBytes.length} bytes (max $maxValueSize)',
      );
    }

    // Calculate total size
    final totalSize = 1 + 4 + 2 + keyBytes.length + 4 + valueBytes.length;
    final buffer = ByteData(totalSize);

    var offset = 0;

    // Command (1 byte)
    buffer.setUint8(offset++, command);

    // Sequence (4 bytes, big-endian)
    buffer.setUint32(offset, seq, Endian.big);
    offset += 4;

    // Key length (2 bytes, big-endian)
    buffer.setUint16(offset, keyBytes.length, Endian.big);
    offset += 2;

    // Key data - copy into buffer
    for (int i = 0; i < keyBytes.length; i++) {
      buffer.setUint8(offset++, keyBytes[i]);
    }

    // Value length (4 bytes, big-endian)
    buffer.setUint32(offset, valueBytes.length, Endian.big);
    offset += 4;

    // Value data
    for (int i = 0; i < valueBytes.length; i++) {
      buffer.setUint8(offset++, valueBytes[i]);
    }

    return buffer.buffer.asUint8List();
  }

  /// Encode range query request parameters
  /// Format: [startKeyLen:2][startKey][endKeyLen:2][endKey][limit:4][cursorLen:2][cursor]
  static Uint8List encodeRangeRequest({
    required String startKey,
    required String endKey,
    required int limit,
    required String cursor,
  }) {
    final startKeyBytes = utf8.encode(startKey);
    final endKeyBytes = utf8.encode(endKey);
    final cursorBytes = utf8.encode(cursor);

    final totalSize =
        2 + startKeyBytes.length + 2 + endKeyBytes.length + 4 + 2 + cursorBytes.length;
    final buffer = ByteData(totalSize);

    var offset = 0;

    // Start key
    buffer.setUint16(offset, startKeyBytes.length, Endian.big);
    offset += 2;
    for (int i = 0; i < startKeyBytes.length; i++) {
      buffer.setUint8(offset++, startKeyBytes[i]);
    }

    // End key
    buffer.setUint16(offset, endKeyBytes.length, Endian.big);
    offset += 2;
    for (int i = 0; i < endKeyBytes.length; i++) {
      buffer.setUint8(offset++, endKeyBytes[i]);
    }

    // Limit
    buffer.setUint32(offset, limit, Endian.big);
    offset += 4;

    // Cursor
    buffer.setUint16(offset, cursorBytes.length, Endian.big);
    offset += 2;
    for (int i = 0; i < cursorBytes.length; i++) {
      buffer.setUint8(offset++, cursorBytes[i]);
    }

    return buffer.buffer.asUint8List();
  }

  /// Encode prefix query request parameters
  /// Format: [prefixLen:2][prefix][limit:4][cursorLen:2][cursor]
  static Uint8List encodePrefixRequest({
    required String prefix,
    required int limit,
    required String cursor,
  }) {
    final prefixBytes = utf8.encode(prefix);
    final cursorBytes = utf8.encode(cursor);

    final totalSize = 2 + prefixBytes.length + 4 + 2 + cursorBytes.length;
    final buffer = ByteData(totalSize);

    var offset = 0;

    // Prefix
    buffer.setUint16(offset, prefixBytes.length, Endian.big);
    offset += 2;
    for (int i = 0; i < prefixBytes.length; i++) {
      buffer.setUint8(offset++, prefixBytes[i]);
    }

    // Limit
    buffer.setUint32(offset, limit, Endian.big);
    offset += 4;

    // Cursor
    buffer.setUint16(offset, cursorBytes.length, Endian.big);
    offset += 2;
    for (int i = 0; i < cursorBytes.length; i++) {
      buffer.setUint8(offset++, cursorBytes[i]);
    }

    return buffer.buffer.asUint8List();
  }

  /// Encode traverse request
  /// Format: [seq:4][keyLen:2][key][pathLen:2][path][options:1]
  static Uint8List encodeTraverseRequest({
    required int seq,
    required String key,
    required String path,
    required int flags,
  }) {
    final keyBytes = utf8.encode(key);
    final pathBytes = utf8.encode(path);

    final totalSize = 4 + 2 + keyBytes.length + 2 + pathBytes.length + 1;
    final buffer = ByteData(totalSize);

    var offset = 0;

    // Sequence
    buffer.setUint32(offset, seq, Endian.big);
    offset += 4;

    // Key
    buffer.setUint16(offset, keyBytes.length, Endian.big);
    offset += 2;
    for (int i = 0; i < keyBytes.length; i++) {
      buffer.setUint8(offset++, keyBytes[i]);
    }

    // Path
    buffer.setUint16(offset, pathBytes.length, Endian.big);
    offset += 2;
    for (int i = 0; i < pathBytes.length; i++) {
      buffer.setUint8(offset++, pathBytes[i]);
    }

    // Options
    buffer.setUint8(offset, flags);

    return buffer.buffer.asUint8List();
  }

  // ============================================================================
  // Pub/Sub Encoding
  // ============================================================================

  /// Encode subscribe request
  /// Format: [topicLen:2][topic][patternLen:2][pattern][options:1]
  static Uint8List encodeSubscribeRequest({
    required String topic,
    required String pattern,
    required int options,
  }) {
    final topicBytes = utf8.encode(topic);
    final patternBytes = utf8.encode(pattern);

    final totalSize = 2 + topicBytes.length + 2 + patternBytes.length + 1;
    final buffer = ByteData(totalSize);

    var offset = 0;

    // Topic
    buffer.setUint16(offset, topicBytes.length, Endian.big);
    offset += 2;
    for (int i = 0; i < topicBytes.length; i++) {
      buffer.setUint8(offset++, topicBytes[i]);
    }

    // Pattern
    buffer.setUint16(offset, patternBytes.length, Endian.big);
    offset += 2;
    for (int i = 0; i < patternBytes.length; i++) {
      buffer.setUint8(offset++, patternBytes[i]);
    }

    // Options
    buffer.setUint8(offset, options);

    return buffer.buffer.asUint8List();
  }

  /// Encode publish request
  /// Format: [topicLen:2][topic][msgType:1][headersLen:2][headers][payloadLen:4][payload]
  static Uint8List encodePublishRequest({
    required String topic,
    required int msgType,
    required String payload,
    required String headers,
  }) {
    final topicBytes = utf8.encode(topic);
    final headersBytes = utf8.encode(headers);
    final payloadBytes = utf8.encode(payload);

    final totalSize =
        2 + topicBytes.length + 1 + 2 + headersBytes.length + 4 + payloadBytes.length;
    final buffer = ByteData(totalSize);

    var offset = 0;

    // Topic
    buffer.setUint16(offset, topicBytes.length, Endian.big);
    offset += 2;
    for (int i = 0; i < topicBytes.length; i++) {
      buffer.setUint8(offset++, topicBytes[i]);
    }

    // Message type
    buffer.setUint8(offset++, msgType);

    // Headers
    buffer.setUint16(offset, headersBytes.length, Endian.big);
    offset += 2;
    for (int i = 0; i < headersBytes.length; i++) {
      buffer.setUint8(offset++, headersBytes[i]);
    }

    // Payload
    buffer.setUint32(offset, payloadBytes.length, Endian.big);
    offset += 4;
    for (int i = 0; i < payloadBytes.length; i++) {
      buffer.setUint8(offset++, payloadBytes[i]);
    }

    return buffer.buffer.asUint8List();
  }
}
