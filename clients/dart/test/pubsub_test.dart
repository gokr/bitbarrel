import 'dart:convert';
import 'dart:typed_data';

import 'package:bitbarrel/bitbarrel.dart';
import 'package:bitbarrel/src/protocol/encoder.dart';
import 'package:bitbarrel/src/protocol/decoder.dart';
import 'package:test/test.dart';

void main() {
  group('PubSub Protocol Encoders', () {
    test('encodeSubscribeRequest produces correct format', () {
      final data = ProtocolEncoder.encodeSubscribeRequest(
        topic: 'chat/room1',
        pattern: '',
        options: 0x00,
      );

      // Format: [topicLen:2][topic:topic][patternLen:2][pattern][options:1]
      // Expected: [0x00 0x0A][chat/room1][0x00 0x00][][0x00]
      expect(data.isNotEmpty, true);
      expect(data.length, equals(2 + 10 + 2 + 0 + 1));
    });

    test('encodeSubscribeRequest handles pattern subscription', () {
      final data = ProtocolEncoder.encodeSubscribeRequest(
        topic: '',
        pattern: 'user:*',
        options: 0x01,
      );

      // Format: [topicLen:2][topic][patternLen:2][pattern:pattern][options:1]
      expect(data.isNotEmpty, true);
    });

    test('encodeSubscribeRequest encodes options correctly', () {
      // Test all option flags
      final opts1 = SubscriptionOptions(
        enableKvEvents: true,
        enablePresence: false,
        replayHistory: false,
      );
      final data1 = ProtocolEncoder.encodeSubscribeRequest(
        topic: 'topic',
        pattern: '',
        options: opts1.encode(),
      );
      // Only high bit set
      expect(data1.last, equals(0x01));

      final opts2 = SubscriptionOptions(
        enableKvEvents: true,
        enablePresence: true,
        replayHistory: true,
      );
      final data2 = ProtocolEncoder.encodeSubscribeRequest(
        topic: 'topic',
        pattern: '',
        options: opts2.encode(),
      );
      // All bits set
      expect(data2.last, equals(0x07));
    });

    test('encodePublishRequest produces correct format', () {
      final data = ProtocolEncoder.encodePublishRequest(
        topic: 'events/user',
        msgType: PubSubMessageType.data,
        payload: 'user logged in',
        headers: '',
      );

      // Format: [topicLen:2][topic][msgType:1][headersLen:2][headers][payloadLen:4][payload]
      expect(data.isNotEmpty, true);
    });

    test('encodePublishRequest encodes sequence correctly in server response', () {
      // Test 64-bit sequence number decoding
      final buffer = ByteData(8);
      final seq = 0x123456789ABCDEF0; // 64-bit value
      final high = (seq >> 32) & 0xFFFFFFFF;
      final low = seq & 0xFFFFFFFF;
      buffer.setUint32(0, high, Endian.big);
      buffer.setUint32(4, low, Endian.big);

      final seqStr = Latin1Codec().decode(buffer.buffer.asUint8List());
      final decoded = ProtocolDecoder.decodePublishResponse(seqStr);
      expect(decoded, equals(seq));
    });

    test('encodeHistoryRequest produces correct format', () {
      final data = ProtocolEncoder.encodeHistoryRequest(
        topic: 'chat/room1',
        count: 50,
        sinceSeq: 12345,
      );

      // Format: [topicLen:2][topic][count:4][sinceSeq:8]
      expect(data.isNotEmpty, true);
    });

    test('encodePresenceRequest produces correct format', () {
      final data = ProtocolEncoder.encodePresenceRequest(
        operation: 0, // get_online
      );

      // Format: [operation:1]
      expect(data.length, equals(1));
      expect(data[0], equals(0));
    });

    test('encodePresenceRequest with broadcast operation', () {
      final data = ProtocolEncoder.encodePresenceRequest(
        operation: 1, // broadcast_update
      );

      expect(data.length, equals(1));
      expect(data[0], equals(1));
    });
  });

  group('PubSub Protocol Decoders', () {
    test('decodePubSubEvent decodes valid event', () {
      // Create a pub/sub event: [cmd:0xFF][topicLen:2][topic][msgType:1][seq:8][ts:8][headersLen:2][headers][payloadLen:4][payload]
      final buffer = ByteData(1 + 2 + 5 + 1 + 8 + 8 + 2 + 0 + 4 + 12);
      var offset = 0;

      // Command
      buffer.setUint8(offset++, Command.pubsubEvent);


      // Topic 'topic'
      final topic = 'topic';
      buffer.setUint16(offset, topic.length, Endian.big);
      offset += 2;
      for (int i = 0; i < topic.length; i++) {
        buffer.setUint8(offset++, topic.codeUnitAt(i));
      }

      // Message type
      buffer.setUint8(offset++, PubSubMessageType.data);

      // Event sequence (64-bit)
      final eventSeq = 123456789;
      final seqHigh = (eventSeq >> 32) & 0xFFFFFFFF;
      final seqLow = eventSeq & 0xFFFFFFFF;
      buffer.setUint32(offset, seqHigh, Endian.big);
      offset += 4;
      buffer.setUint32(offset, seqLow, Endian.big);
      offset += 4;

      // Timestamp (64-bit)
      final timestamp = 1672531200000; // 2023-01-01 UTC
      final tsHigh = (timestamp >> 32) & 0xFFFFFFFF;
      final tsLow = timestamp & 0xFFFFFFFF;
      buffer.setUint32(offset, tsHigh, Endian.big);
      offset += 4;
      buffer.setUint32(offset, tsLow, Endian.big);
      offset += 4;

      // Headers
      buffer.setUint16(offset, 0, Endian.big);
      offset += 2;

      // Payload
      final payload = 'test payload';
      buffer.setUint32(offset, payload.length, Endian.big);
      offset += 4;
      for (int i = 0; i < payload.length; i++) {
        buffer.setUint8(offset++, payload.codeUnitAt(i));
      }

      final data = buffer.buffer.asUint8List();
      final event = ProtocolDecoder.decodePubSubEvent(data);

      expect(event.topic, equals('topic'));
      expect(event.messageType, equals(PubSubMessageType.data));
      expect(event.sequence, equals(eventSeq));
      expect(event.timestamp, equals(timestamp));
      expect(event.headers, equals(''));
      expect(event.payload, equals('test payload'));
    });

    test('isPubSubEvent identifies pub/sub events correctly', () {
      // Pub/sub event has command 0xFF
      final buffer1 = ByteData(1);
      buffer1.setUint8(0, Command.pubsubEvent);
      final data1 = buffer1.buffer.asUint8List();

      expect(ProtocolDecoder.isPubSubEvent(data1), isTrue);

      // Regular response has status byte (always < 0x10)
      final buffer2 = ByteData(1);
      buffer2.setUint8(0, Status.ok);
      final data2 = buffer2.buffer.asUint8List();

      expect(ProtocolDecoder.isPubSubEvent(data2), isFalse);

      // Empty data
      expect(ProtocolDecoder.isPubSubEvent(Uint8List(0)), isFalse);
    });

    test('decodeSubscribeResponse returns subscription ID', () {
      final subId = ProtocolDecoder.decodeSubscribeResponse('sub-12345-abc');
      expect(subId, equals('sub-12345-abc'));
    });

    test('decodePublishResponse decodes 64-bit sequence', () {
      final buffer = ByteData(8);
      final seq = 0xFEDCBA9876543210;
      buffer.setUint32(0, (seq >> 32) & 0xFFFFFFFF, Endian.big);
      buffer.setUint32(4, seq & 0xFFFFFFFF, Endian.big);

      final seqStr = Latin1Codec().decode(buffer.buffer.asUint8List());
      final decoded = ProtocolDecoder.decodePublishResponse(seqStr);
      expect(decoded, equals(seq));
    });

    test('decodeListSubscribersResponse parses JSON correctly', () {
      final json = jsonEncode([
        {
          'subscriptionId': 'sub-1',
          'clientId': 1001,
          'topic': 'chat/room1',
        },
        {
          'subscriptionId': 'sub-2',
          'clientId': 1002,
          'pattern': 'user:*',
        },
      ]);

      final subscribers = ProtocolDecoder.decodeListSubscribersResponse(json);

      expect(subscribers.length, equals(2));
      expect(subscribers[0].id, equals('sub-1'));
      expect(subscribers[0].clientId, equals(1001));
      expect(subscribers[0].topic, equals('chat/room1'));
      expect(subscribers[0].pattern, isEmpty);
      expect(subscribers[1].id, equals('sub-2'));
      expect(subscribers[1].pattern, equals('user:*'));
    });

    test('decodeListTopicsResponse parses JSON correctly', () {
      final json = jsonEncode([
        {'name': 'chat/room1', 'sequence': 100, 'subscriberCount': 5, 'messageCount': 500},
        {'name': 'chat/room2', 'sequence': 50, 'subscriberCount': 2, 'messageCount': 100},
      ]);

      final topics = ProtocolDecoder.decodeListTopicsResponse(json);

      expect(topics.length, equals(2));
      expect(topics[0].name, equals('chat/room1'));
      expect(topics[0].sequence, equals(100));
      expect(topics[0].subscriberCount, equals(5));
      expect(topics[0].messageCount, equals(500));
      expect(topics[1].name, equals('chat/room2'));
      expect(topics[1].subscriberCount, equals(2));
    });

    test('decodeHistoryResponse parses JSON correctly', () {
      final json = jsonEncode([
        {
          'topic': 'chat/room1',
          'messageType': PubSubMessageType.data,
          'sequence': 100,
          'timestamp': 1672531200000,
          'payload': 'message 1',
        },
        {
          'topic': 'chat/room1',
          'messageType': PubSubMessageType.data,
          'sequence': 101,
          'timestamp': 1672531201000,
          'payload': 'message 2',
        },
      ]);

      final history = ProtocolDecoder.decodeHistoryResponse(json);

      expect(history.length, equals(2));
      expect(history[0].topic, equals('chat/room1'));
      expect(history[0].messageType, equals(PubSubMessageType.data));
      expect(history[0].sequence, equals(100));
      expect(history[0].timestamp, equals(1672531200000));
      expect(history[0].payload, equals('message 1'));
      expect(history[1].payload, equals('message 2'));
    });

    test('decodeHistoryResponse handles presence events', () {
      final json = jsonEncode([
        {
          'topic': 'presence/chat',
          'messageType': PubSubMessageType.presence,
          'sequence': 200,
          'timestamp': 1672531200000,
          'payload': jsonEncode({'user': 'alice', 'online': true}),
        },
      ]);

      final history = ProtocolDecoder.decodeHistoryResponse(json);

      expect(history.length, equals(1));
      expect(history[0].messageType, equals(PubSubMessageType.presence));
      expect(history[0].headers, isEmpty);
    });

    test('decodePresenceResponse parses JSON correctly', () {
      final topic = 'chat/room1';
      final json = jsonEncode([
        {
          'topic': topic,
          'members': [
            {
              'clientId': 1001,
              'username': 'alice',
              'joinedAt': 1672531200000,
              'lastPing': 1672531205000,
            },
            {
              'clientId': 1002,
              'username': 'bob',
              'joinedAt': 1672531201000,
              'lastPing': 1672531206000,
            },
          ],
          'lastUpdate': 1672531206000,
        },
      ]);

      final presence = ProtocolDecoder.decodePresenceResponse(topic, json);

      expect(presence.topic, equals(topic));
      expect(presence.members.length, equals(2));
      expect(presence.members[0].clientId, equals(1001));
      expect(presence.members[0].username, equals('alice'));
      expect(presence.members[0].joinedAt, equals(1672531200000));
      expect(presence.members[0].lastPing, equals(1672531205000));
      expect(presence.members[1].username, equals('bob'));
      expect(presence.lastUpdate, equals(1672531206000));
    });
  });

  group('PubSub Types', () {
    test('PubSubMessageType has correct values', () {
      expect(PubSubMessageType.data, equals(0));
      expect(PubSubMessageType.presence, equals(1));
    });

    test('SubscriptionOptions.defaults has correct values', () {
      final opts = SubscriptionOptions.defaults;
      expect(opts.enableKvEvents, isFalse);
      expect(opts.enablePresence, isFalse);
      expect(opts.replayHistory, isFalse);
      expect(opts.encode(), equals(0));
    });

    test('SubscriptionOptions.encode computes correct flags', () {
      final opts1 = SubscriptionOptions(
        enableKvEvents: true,
        enablePresence: true,
        replayHistory: true,
      );
      expect(opts1.encode(), equals(0x01 | 0x02 | 0x04));
    });

    test('SubscriptionInfo.fromJson creates correct object', () {
      final json = {
        'subscriptionId': 'sub-123',
        'clientId': 1001,
        'topic': 'chat/room1',
        'pattern': '',
      };

      final info = SubscriptionInfo.fromJson(json);

      expect(info.id, equals('sub-123'));
      expect(info.clientId, equals(1001));
      expect(info.topic, equals('chat/room1'));
      expect(info.pattern, isEmpty);
    });

    test('PresenceMember.fromJson creates correct object', () {
      final json = {
        'clientId': 1001,
        'username': 'alice',
        'joinedAt': 1672531200000,
        'lastPing': 1672531205000,
        'metadata': {'role': 'admin'},
      };

      final member = PresenceMember.fromJson(json);

      expect(member.clientId, equals(1001));
      expect(member.username, equals('alice'));
      expect(member.joinedAt, equals(1672531200000));
      expect(member.lastPing, equals(1672531205000));
      expect(member.metadata, isNotEmpty);
    });

    test('TopicInfo.fromJson creates correct object', () {
      final json = {
        'name': 'chat/room1',
        'sequence': 100,
        'subscriberCount': 5,
        'messageCount': 500,
      };

      final info = TopicInfo.fromJson(json);

      expect(info.name, equals('chat/room1'));
      expect(info.sequence, equals(100));
      expect(info.subscriberCount, equals(5));
      expect(info.messageCount, equals(500));
    });

    test('HistoryRequest.defaults has correct values', () {
      final req = HistoryRequest.defaults;
      expect(req.limit, equals(100));
      expect(req.sinceSeq, equals(0));
    });
  });

  group('PubSubEvent', () {
    test('toString formats event correctly for data message', () {
      final event = PubSubEvent(
        topic: 'chat/room1',
        messageType: PubSubMessageType.data,
        sequence: 100,
        timestamp: 1672531200000,
        headers: '',
        payload: 'hello',
      );

      final str = event.toString();
      expect(str, contains('chat/room1'));
      expect(str, contains('DATA'));
      expect(str, contains('100'));
      expect(str, contains('hello'));
    });

    test('toString formats event correctly for presence message', () {
      final event = PubSubEvent(
        topic: 'presence/chat',
        messageType: PubSubMessageType.presence,
        sequence: 200,
        timestamp: 1672531200000,
        headers: '',
        payload: '{"online": true}',
      );

      final str = event.toString();
      expect(str, contains('presence/chat'));
      expect(str, contains('PRESENCE'));
    });
  });
}
