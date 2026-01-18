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

  /// Decode keys-only range/prefix query response
  /// Format: [count:4][keys...][hasMore:1][nextCursorLen:2][nextCursor]
  /// Each key: [keyLen:2][key]
  static KeysResponse decodeKeysResponse(String data) {
    final bytes = Latin1Codec().encode(data);
    final buffer = ByteData.sublistView(bytes);

    if (bytes.length < 5) {
      throw ProtocolException('Keys response too short');
    }

    var offset = 0;

    // Count
    final count = buffer.getUint32(offset, Endian.big);
    offset += 4;

    final keys = <String>[];

    // Decode keys
    for (int i = 0; i < count; i++) {
      // Key length
      if (offset + 2 > bytes.length) {
        throw ProtocolException('Truncated key length');
      }
      final keyLen = buffer.getUint16(offset, Endian.big);
      offset += 2;

      // Key
      if (offset + keyLen > bytes.length) {
        throw ProtocolException('Truncated key');
      }
      final key = utf8.decode(bytes.sublist(offset, offset + keyLen));
      offset += keyLen;

      keys.add(key);
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

    return KeysResponse(
      keys: keys,
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

  // ============================================================================
  // Pub/Sub Decoding
  // ============================================================================

  /// Decode a PubSub event from server
  /// Format: [cmd:1][seq:4][topicLen:2][topic:N][msgType:1][seq:8][ts:8][headersLen:4][headers:M][payloadLen:4][payload:P]
  /// Note: The first 4-byte seq is a placeholder (always 0), the actual sequence is 8 bytes later
  static PubSubEvent decodePubSubEvent(Uint8List data) {
    if (data.length < 36) {
      throw ProtocolException('PubSub event too short: ${data.length} bytes (minimum 36)');
    }

    // Check command (should be 0xFF)
    if (data[0] != Command.pubsubEvent) {
      throw ProtocolException('Not a PubSub event: cmd=0x${data[0].toRadixString(16)}');
    }

    final buffer = ByteData.sublistView(data);
    var offset = 1; // Skip command byte

    // Skip 4-byte sequence placeholder
    offset += 4;

    // Topic
    if (offset + 2 > data.length) {
      throw ProtocolException('Truncated PubSub event: missing topic length');
    }
    final topicLen = buffer.getUint16(offset, Endian.big);
    offset += 2;

    if (offset + topicLen > data.length) {
      throw ProtocolException('Truncated PubSub event: topic data');
    }
    final topic = utf8.decode(data.sublist(offset, offset + topicLen));
    offset += topicLen;

    // Message type
    if (offset >= data.length) {
      throw ProtocolException('Truncated PubSub event: missing message type');
    }
    final messageType = data[offset++];

    // Sequence (8 bytes) - actual message sequence
    if (offset + 8 > data.length) {
      throw ProtocolException('Truncated PubSub event: missing sequence');
    }
    // Read 64-bit sequence as two 32-bit values
    final seqHigh = buffer.getUint32(offset, Endian.big);
    offset += 4;
    final seqLow = buffer.getUint32(offset, Endian.big);
    offset += 4;
    final sequence = (seqHigh << 32) + seqLow;

    // Timestamp (8 bytes)
    if (offset + 8 > data.length) {
      throw ProtocolException('Truncated PubSub event: missing timestamp');
    }
    final tsHigh = buffer.getUint32(offset, Endian.big);
    offset += 4;
    final tsLow = buffer.getUint32(offset, Endian.big);
    offset += 4;
    final timestamp = (tsHigh << 32) + tsLow;

    // Headers
    if (offset + 4 > data.length) {
      throw ProtocolException('Truncated PubSub event: missing headers length');
    }
    final headersLen = buffer.getUint32(offset, Endian.big);
    offset += 4;

    String headers;
    if (headersLen == 0) {
      headers = '';
    } else {
      if (offset + headersLen > data.length) {
        throw ProtocolException('Truncated PubSub event: headers data');
      }
      headers = utf8.decode(data.sublist(offset, offset + headersLen));
      offset += headersLen;
    }

    // Payload
    if (offset + 4 > data.length) {
      throw ProtocolException('Truncated PubSub event: missing payload length');
    }
    final payloadLen = buffer.getUint32(offset, Endian.big);
    offset += 4;

    String payload;
    if (payloadLen == 0) {
      payload = '';
    } else {
      if (offset + payloadLen > data.length) {
        throw ProtocolException('Truncated PubSub event: payload data');
      }
      payload = utf8.decode(data.sublist(offset, offset + payloadLen));
    }

    return PubSubEvent(
      topic: topic,
      messageType: messageType,
      sequence: sequence,
      timestamp: timestamp,
      headers: headers,
      payload: payload,
    );
  }

  /// Check if data is a PubSub event (command 0xFF)
  static bool isPubSubEvent(Uint8List data) {
    return data.isNotEmpty && data[0] == Command.pubsubEvent;
  }

  /// Decode subscribe response (subscription ID)
  static String decodeSubscribeResponse(String data) {
    return data;
  }

  /// Decode publish response (sequence number)
  static int decodePublishResponse(String data) {
    final bytes = Latin1Codec().encode(data);
    if (bytes.length >= 8) {
      final buffer = ByteData.sublistView(bytes);
      final high = buffer.getUint32(0, Endian.big);
      final low = buffer.getUint32(4, Endian.big);
      return (high << 32) + low;
    }
    return 0;
  }

  /// Decode listSubscribers response
  /// Returns a list of SubscriptionInfo from JSON array
  static List<SubscriptionInfo> decodeListSubscribersResponse(String data) {
    try {
      final json = jsonDecode(data) as List<dynamic>;
      return json
          .map((item) => SubscriptionInfo.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw ProtocolException('Failed to parse subscribers response: $e');
    }
  }

  /// Decode listTopics response
  /// Returns a list of TopicInfo from JSON array
  static List<TopicInfo> decodeListTopicsResponse(String data) {
    try {
      final json = jsonDecode(data) as List<dynamic>;
      return json
          .map((item) => TopicInfo.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      throw ProtocolException('Failed to parse topics response: $e');
    }
  }

  /// Decode getHistory response
  /// Returns a list of PubSubEvent from JSON array
  static List<PubSubEvent> decodeHistoryResponse(String data) {
    /// Helper to safely extract int from JSON (handles both int and double)
    int toInt(dynamic value, int fallback) {
      if (value == null) return fallback;
      if (value is int) return value;
      if (value is double) return value.toInt();
      return fallback;
    }

    try {
      final json = jsonDecode(data) as List<dynamic>;
      return json.map((item) {
        final obj = item as Map<String, dynamic>;
        return PubSubEvent(
          topic: obj['topic'] as String? ?? '',
          messageType: toInt(obj['messageType'], 0),
          sequence: toInt(obj['sequence'], 0),
          timestamp: toInt(obj['timestamp'], 0),
          headers: obj['headers'] != null ? jsonEncode(obj['headers']) : '',
          payload: obj['payload'] as String? ?? '',
        );
      }).toList();
    } catch (e) {
      throw ProtocolException('Failed to parse history response: $e');
    }
  }

  /// Decode getPresence response
  /// Returns a PresenceInfo object from JSON
  static PresenceInfo decodePresenceResponse(String topic, String data) {
    /// Helper to safely extract int from JSON (handles both int and double)
    int toInt(dynamic value, int? fallback) {
      if (value == null) return fallback ?? 0;
      if (value is int) return value;
      if (value is double) return value.toInt();
      return fallback ?? 0;
    }

    try {
      // Response can be either:
      // 1. Single topic response: [{"topic": "...", "members": [...], "lastUpdate": ...}]
      // 2. Multiple topics response (but we only requested one topic)
      final json = jsonDecode(data) as List<dynamic>;

      List<PresenceMember> members = [];
      int lastUpdate = DateTime.now().millisecondsSinceEpoch;

      for (final item in json) {
        final obj = item as Map<String, dynamic>;
        if (obj['topic'] == topic) {
          // Found our topic
          lastUpdate = toInt(obj['lastUpdate'], lastUpdate);

          final membersArray = obj['members'] as List<dynamic>?;
          if (membersArray != null) {
            members = membersArray
                .map((m) =>
                    PresenceMember.fromJson(m as Map<String, dynamic>))
                .toList();
          }
          break;
        }
      }

      return PresenceInfo(
        topic: topic,
        members: members,
        lastUpdate: lastUpdate,
      );
    } catch (e) {
      throw ProtocolException('Failed to parse presence response: $e');
    }
  }
}
