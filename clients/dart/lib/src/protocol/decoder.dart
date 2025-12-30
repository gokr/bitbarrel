import 'dart:typed_data';
import 'dart:convert';

import 'commands.dart';
import 'status.dart';
import 'encoder.dart';
import '../types.dart';
import '../errors.dart';

/// Binary decoding utilities for the BitBarrel protocol
class ProtocolDecoder {
  ProtocolDecoder._();

  /// Decode a standard response from binary format
  /// Format: [status:1][seq:4][valLen:4][value:N]
  /// Returns a tuple of (status, seq, value)
  static ({int status, int seq, String value}) decodeResponse(Uint8List data) {
    if (data.length < 9) {
      throw ProtocolException('Response too short: ${data.length} bytes (minimum 9)');
    }

    final buffer = ByteData.sublistView(data);
    var offset = 0;

    // Status (1 byte)
    final status = buffer.getUint8(offset++);

    if (!Status.isValid(status)) {
      throw ProtocolException('Invalid status: 0x${status.toRadixString(16)}');
    }

    // Sequence (4 bytes, big-endian)
    final seq = buffer.getUint32(offset, Endian.big);
    offset += 4;

    // Value length (4 bytes, big-endian)
    final valueLen = buffer.getUint32(offset, Endian.big);
    offset += 4;

    if (valueLen > ProtocolEncoder.maxValueSize) {
      throw ProtocolException('Value length too large: $valueLen');
    }

    // Check we have enough data
    if (offset + valueLen > data.length) {
      throw ProtocolException(
        'Truncated response: expected ${offset + valueLen} bytes, got ${data.length}',
      );
    }

    // Value - use Latin1 to preserve binary data for range responses
    final value = valueLen == 0
        ? ''
        : Latin1Codec().decode(data.sublist(offset, offset + valueLen));

    return (status: status, seq: seq, value: value);
  }

  /// Decode range/prefix query response
  /// Format: [count:4][items...][hasMore:1][nextCursorLen:2][nextCursor]
  /// Each item: [keyLen:2][key][valLen:4][value]
  static RangeQueryResponse decodeRangeResponse(String data) {
    final bytes = Latin1Codec().encode(data);
    final buffer = ByteData.sublistView(bytes);

    if (bytes.length < 5) {
      throw ProtocolException('Range response too short');
    }

    var offset = 0;

    // Count
    final count = buffer.getUint32(offset, Endian.big);
    offset += 4;

    final items = <KeyValue>[];

    // Decode items
    for (int i = 0; i < count; i++) {
      // Key length
      if (offset + 2 > bytes.length) {
        throw ProtocolException('Truncated item key length');
      }
      final keyLen = buffer.getUint16(offset, Endian.big);
      offset += 2;

      // Key
      if (offset + keyLen > bytes.length) {
        throw ProtocolException('Truncated item key');
      }
      final key = utf8.decode(bytes.sublist(offset, offset + keyLen));
      offset += keyLen;

      // Value length
      if (offset + 4 > bytes.length) {
        throw ProtocolException('Truncated item value length');
      }
      final valLen = buffer.getUint32(offset, Endian.big);
      offset += 4;

      // Value
      if (offset + valLen > bytes.length) {
        throw ProtocolException('Truncated item value');
      }
      final value = valLen == 0
          ? ''
          : utf8.decode(bytes.sublist(offset, offset + valLen));
      offset += valLen;

      items.add(KeyValue(key: key, value: value));
    }

    // Has more flag
    if (offset + 1 > bytes.length) {
      throw ProtocolException('Truncated hasMore flag');
    }
    final hasMore = buffer.getUint8(offset++) != 0;

    // Next cursor length
    if (offset + 2 > bytes.length) {
      throw ProtocolException('Truncated cursor length');
    }
    final cursorLen = buffer.getUint16(offset, Endian.big);
    offset += 2;

    // Next cursor
    String nextCursor;
    if (cursorLen == 0) {
      nextCursor = '';
    } else {
      if (offset + cursorLen > bytes.length) {
        throw ProtocolException('Truncated cursor');
      }
      nextCursor = utf8.decode(bytes.sublist(offset, offset + cursorLen));
    }

    return RangeQueryResponse(
      items: items,
      nextCursor: nextCursor,
      hasMore: hasMore,
    );
  }

  /// Decode traverse results
  /// Format: [status:1][seq:4][count:4][results...]
  /// Each result: [pathLen:2][path][valLen:4][value][extFlags:1][extLen:4][extData]
  /// Returns a tuple of (status, seq, results)
  static ({int status, int seq, List<TraverseResult> results}) decodeTraverseResults(
    String data,
  ) {
    final bytes = Latin1Codec().encode(data);
    final buffer = ByteData.sublistView(bytes);

    if (bytes.length < 9) {
      throw ProtocolException('Traverse response too short');
    }

    var offset = 0;

    // Status
    final status = buffer.getUint8(offset++);

    // Sequence
    final seq = buffer.getUint32(offset, Endian.big);
    offset += 4;

    // Count
    final count = buffer.getUint32(offset, Endian.big);
    offset += 4;

    final results = <TraverseResult>[];

    for (int i = 0; i < count; i++) {
      // Path length
      if (offset + 2 > bytes.length) {
        throw ProtocolException('Truncated path length');
      }
      final pathLen = buffer.getUint16(offset, Endian.big);
      offset += 2;

      // Path
      if (offset + pathLen > bytes.length) {
        throw ProtocolException('Truncated path');
      }
      final path = utf8.decode(bytes.sublist(offset, offset + pathLen));
      offset += pathLen;

      // Value length
      if (offset + 4 > bytes.length) {
        throw ProtocolException('Truncated value length');
      }
      final valLen = buffer.getUint32(offset, Endian.big);
      offset += 4;

      // Value
      String value;
      if (valLen == 0) {
        value = '';
      } else {
        if (offset + valLen > bytes.length) {
          throw ProtocolException('Truncated value');
        }
        value = utf8.decode(bytes.sublist(offset, offset + valLen));
        offset += valLen;
      }

      // Extracted data flag
      if (offset + 1 > bytes.length) {
        throw ProtocolException('Truncated ext flags');
      }
      final hasExtracted = buffer.getUint8(offset++) != 0;

      // Extracted data length
      if (offset + 4 > bytes.length) {
        throw ProtocolException('Truncated ext length');
      }
      final extLen = buffer.getUint32(offset, Endian.big);
      offset += 4;

      // Extracted data
      String extractedData;
      if (hasExtracted && extLen > 0) {
        if (offset + extLen > bytes.length) {
          throw ProtocolException('Truncated ext data');
        }
        extractedData = utf8.decode(bytes.sublist(offset, offset + extLen));
        offset += extLen;
      } else {
        extractedData = '';
      }

      // Extract key from path (last element after -> if present)
      final key = path.split('->').last;

      results.add(TraverseResult(
        path: path,
        key: key,
        value: value,
        extractedData: extractedData,
      ));
    }

    return (status: status, seq: seq, results: results);
  }
}
