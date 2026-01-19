import 'dart:convert';
import 'dart:typed_data';

import 'package:bitbarrel/bitbarrel.dart';
import 'package:bitbarrel/src/protocol/encoder.dart';
import 'package:bitbarrel/src/protocol/decoder.dart';
import 'package:test/test.dart';

void main() {
  group('ProtocolEncoder', () {
    test('encodeRequest produces correct format for SET command', () {
      final data = ProtocolEncoder.encodeRequest(
        command: Command.set,
        seq: 42,
        key: 'test_key',
        value: 'test_value',
      );

      // Format v1.1: [cmd:1][seq:4][flags:1][keyLen:2][key:N][valLen:4][value:M]
      // Expected: [0x02][0x00 0x00 0x00 0x2A][0x00][0x00 0x08][test_key][0x00 0x00 0x00 0x0A][test_value]
      expect(data.length, equals(1 + 4 + 1 + 2 + 8 + 4 + 10));
      expect(data[0], equals(Command.set));
    });

    test('encodeRequest produces correct format for GET command', () {
      final data = ProtocolEncoder.encodeRequest(
        command: Command.get,
        seq: 1,
        key: 'key',
      );

      // GET has no value, v1.1 format includes flags
      expect(data.length, equals(1 + 4 + 1 + 2 + 3 + 4 + 0));
      expect(data[0], equals(Command.get));
    });

    test('encodeRequest throws on invalid command', () {
      expect(
        () => ProtocolEncoder.encodeRequest(
          command: 0xFE,  // 0xFF is now pubsubEvent, use 0xFE which is unused
          seq: 1,
          key: 'key',
        ),
        throwsArgumentError,
      );
    });

    test('encodeRangeRequest produces correct format', () {
      final data = ProtocolEncoder.encodeRangeRequest(
        startKey: 'user:100',
        endKey: 'user:200',
        limit: 100,
        cursor: '',
      );

      // Format: [startKeyLen:2][startKey][endKeyLen:2][endKey][limit:4][cursorLen:2][cursor]
      expect(data.isNotEmpty, true);
    });

    test('encodePrefixRequest produces correct format', () {
      final data = ProtocolEncoder.encodePrefixRequest(
        prefix: 'user:',
        limit: 50,
        cursor: 'user:100',
      );

      // Format: [prefixLen:2][prefix][limit:4][cursorLen:2][cursor]
      expect(data.isNotEmpty, true);
    });

    test('encodeTraverseRequest produces correct format', () {
      final data = ProtocolEncoder.encodeTraverseRequest(
        seq: 5,
        key: 'key1',
        path: '*',
        flags: 0x01,
      );

      // Format: [seq:4][keyLen:2][key][pathLen:2][path][options:1]
      expect(data.isNotEmpty, true);
    });
  });

  group('ProtocolDecoder', () {
    test('decodeResponse decodes valid response', () {
      // Create a response: [status:0x00][seq:0x0000000A][valLen:0x00000005][value:"hello"]
      final buffer = ByteData(1 + 4 + 4 + 5);
      buffer.setUint8(0, Status.ok);
      buffer.setUint32(1, 10, Endian.big);
      buffer.setUint32(5, 5, Endian.big);
      final valueBytes = utf8.encode('hello');
      for (int i = 0; i < 5; i++) {
        buffer.setUint8(9 + i, valueBytes[i]);
      }

      final data = buffer.buffer.asUint8List();
      final response = ProtocolDecoder.decodeResponse(data);

      expect(response.status, equals(Status.ok));
      expect(response.seq, equals(10));
      expect(response.value, equals('hello'));
    });

    test('decodeResponse handles empty value', () {
      final buffer = ByteData(1 + 4 + 4);
      buffer.setUint8(0, Status.ok);
      buffer.setUint32(1, 1, Endian.big);
      buffer.setUint32(5, 0, Endian.big);

      final data = buffer.buffer.asUint8List();
      final response = ProtocolDecoder.decodeResponse(data);

      expect(response.status, equals(Status.ok));
      expect(response.seq, equals(1));
      expect(response.value, equals(''));
    });

    test('decodeResponse throws on invalid status', () {
      final buffer = ByteData(9);
      buffer.setUint8(0, 0xFF);
      buffer.setUint32(1, 1, Endian.big);
      buffer.setUint32(5, 0, Endian.big);

      final data = buffer.buffer.asUint8List();
      expect(
        () => ProtocolDecoder.decodeResponse(data),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('decodeResponse throws on truncated data', () {
      final buffer = ByteData(10);
      buffer.setUint8(0, Status.ok);
      buffer.setUint32(1, 1, Endian.big);
      buffer.setUint32(5, 10, Endian.big); // Claims 10 bytes but only 3 provided

      final data = buffer.buffer.asUint8List();
      expect(
        () => ProtocolDecoder.decodeResponse(data),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('decodeRangeResponse decodes valid response', () {
      // Create a range response with 2 items
      final buffer = StringBuffer();
      // Count: 2
      buffer.write('\x00\x00\x00\x02');
      // Item 1: key 'user:1', value 'Alice'
      buffer.write('\x00\x06user:1');
      buffer.write('\x00\x00\x00\x05Alice');
      // Item 2: key 'user:2', value 'Bob'
      buffer.write('\x00\x06user:2');
      buffer.write('\x00\x00\x00\x03Bob');
      // hasMore: 1, cursorLen: 6, cursor: 'user:2'
      buffer.write('\x01');
      buffer.write('\x00\x06user:2');

      final response = ProtocolDecoder.decodeRangeResponse(buffer.toString());

      expect(response.items.length, equals(2));
      expect(response.items[0].key, equals('user:1'));
      expect(response.items[0].value, equals('Alice'));
      expect(response.items[1].key, equals('user:2'));
      expect(response.items[1].value, equals('Bob'));
      expect(response.hasMore, equals(true));
      expect(response.nextCursor, equals('user:2'));
    });

    test('decodeRangeResponse handles empty response', () {
      final buffer = StringBuffer();
      buffer.write('\x00\x00\x00\x00'); // Count: 0
      buffer.write('\x00'); // hasMore: false
      buffer.write('\x00\x00'); // cursorLen: 0

      final response = ProtocolDecoder.decodeRangeResponse(buffer.toString());

      expect(response.items.length, equals(0));
      expect(response.hasMore, equals(false));
      expect(response.nextCursor, equals(''));
    });
  });

  group('Status', () {
    test('isValid returns true for valid status codes', () {
      expect(Status.isValid(Status.ok), isTrue);
      expect(Status.isValid(Status.notFound), isTrue);
      expect(Status.isValid(Status.error), isTrue);
      expect(Status.isValid(Status.invalid), isTrue);
      expect(Status.isValid(Status.noBarrel), isTrue);
      expect(Status.isValid(Status.barrelExists), isTrue);
      expect(Status.isValid(Status.barrelNotFound), isTrue);
    });

    test('isValid returns false for invalid status codes', () {
      expect(Status.isValid(0xFF), isFalse);
      expect(Status.isValid(0x10), isFalse);
    });

    test('toException returns null for OK status', () {
      final exception = Status.toException(Status.ok, null);
      expect(exception, isNull);
    });

    test('toException returns KeyNotFoundException for notFound', () {
      final exception = Status.toException(Status.notFound, null);
      expect(exception, isA<KeyNotFoundException>());
    });

    test('toException returns ServerErrorException for error status', () {
      final exception = Status.toException(Status.error, 'Server error');
      expect(exception, isA<ServerErrorException>());
      expect(
        (exception as ServerErrorException).serverMessage,
        equals('Server error'),
      );
    });

    test('toException returns NoBarrelSelectedException for noBarrel', () {
      final exception = Status.toException(Status.noBarrel, null);
      expect(exception, isA<NoBarrelSelectedException>());
    });

    test('toException returns BarrelExistsException for barrelExists', () {
      final exception = Status.toBarrelException(Status.barrelExists, 'test', null);
      expect(exception, isA<BarrelExistsException>());
      expect((exception as BarrelExistsException).name, equals('test'));
    });

    test('toException returns BarrelNotFoundException for barrelNotFound', () {
      final exception = Status.toBarrelException(Status.barrelNotFound, 'test', null);
      expect(exception, isA<BarrelNotFoundException>());
      expect((exception as BarrelNotFoundException).name, equals('test'));
    });
  });

  group('Command', () {
    test('isValid returns true for all valid commands', () {
      for (final cmd in Command.allValues) {
        expect(Command.isValid(cmd), isTrue, reason: 'Command 0x${cmd.toRadixString(16)}');
      }
    });

    test('allValues contains all expected commands', () {
      expect(Command.allValues.length, equals(30));  // Including Pub/Sub commands
      expect(Command.allValues.contains(Command.get), isTrue);
      expect(Command.allValues.contains(Command.set), isTrue);
      expect(Command.allValues.contains(Command.delete), isTrue);
      expect(Command.allValues.contains(Command.exists), isTrue);
      expect(Command.allValues.contains(Command.count), isTrue);
      expect(Command.allValues.contains(Command.listKeys), isTrue);
      expect(Command.allValues.contains(Command.ping), isTrue);
      expect(Command.allValues.contains(Command.traverse), isTrue);
      expect(Command.allValues.contains(Command.rangeQuery), isTrue);
      expect(Command.allValues.contains(Command.prefixQuery), isTrue);
      expect(Command.allValues.contains(Command.rangeCount), isTrue);
      expect(Command.allValues.contains(Command.rangeKeys), isTrue);
      expect(Command.allValues.contains(Command.prefixKeys), isTrue);
      expect(Command.allValues.contains(Command.createBarrel), isTrue);
      expect(Command.allValues.contains(Command.openBarrel), isTrue);
      expect(Command.allValues.contains(Command.useBarrel), isTrue);
      expect(Command.allValues.contains(Command.closeBarrel), isTrue);
      expect(Command.allValues.contains(Command.listBarrels), isTrue);
      expect(Command.allValues.contains(Command.dropBarrel), isTrue);
      expect(Command.allValues.contains(Command.getBarrelConfig), isTrue);
      expect(Command.allValues.contains(Command.setBarrelConfig), isTrue);
      expect(Command.allValues.contains(Command.getBarrelStats), isTrue);
      expect(Command.allValues.contains(Command.subscribe), isTrue);
      expect(Command.allValues.contains(Command.unsubscribe), isTrue);
      expect(Command.allValues.contains(Command.publish), isTrue);
      expect(Command.allValues.contains(Command.listSubscribers), isTrue);
      expect(Command.allValues.contains(Command.history), isTrue);
      expect(Command.allValues.contains(Command.listTopics), isTrue);
      expect(Command.allValues.contains(Command.presence), isTrue);
      expect(Command.allValues.contains(Command.pubsubEvent), isTrue);
    });
  });

  group('Types', () {
    test('KeyValue equality works correctly', () {
      final kv1 = const KeyValue(key: 'key1', value: 'value1');
      final kv2 = const KeyValue(key: 'key1', value: 'value1');
      final kv3 = const KeyValue(key: 'key1', value: 'value2');

      expect(kv1, equals(kv2));
      expect(kv1, isNot(equals(kv3)));
      expect(kv1.hashCode, equals(kv2.hashCode));
    });

    test('RangeQueryResponse.empty creates empty response', () {
      final response = RangeQueryResponse.empty();
      expect(response.items, isEmpty);
      expect(response.hasMore, isFalse);
      expect(response.nextCursor, equals(''));
    });

    test('TraverseOptions.defaults has correct flags', () {
      final options = TraverseOptions.defaults;
      expect(options.includeFullData, isTrue);
      expect(options.extractArrays, isFalse);
      expect(options.firstOnly, isFalse);
      expect(options.flags, equals(0x01));
    });

    test('TraverseOptions.flags computes correctly', () {
      final options1 = TraverseOptions(
        includeFullData: true,
        extractArrays: true,
        firstOnly: true,
      );
      expect(options1.flags, equals(0x01 | 0x02 | 0x04));
    });
  });

  group('BitBarrelConfig', () {
    test('localhost factory creates default config', () {
      final config = BitBarrelConfig.localhost();
      expect(config.host, equals('localhost'));
      expect(config.port, equals(9876));
    });

    test('uri creates correct WebSocket URI', () {
      final config = BitBarrelConfig(host: 'example.com', port: 8080);
      final uri = config.uri;
      expect(uri.scheme, equals('ws'));
      expect(uri.host, equals('example.com'));
      expect(uri.port, equals(8080));
      expect(uri.path, equals('/ws'));
    });
  });
}
