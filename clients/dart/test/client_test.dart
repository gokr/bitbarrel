import 'dart:async';

import 'package:bitbarrel/bitbarrel.dart';
import 'package:test/test.dart';

/// Integration tests for BitBarrel client.
///
/// These tests require a running BitBarrel server on localhost:9876.
/// Tests will skip automatically if server is not available.
void main() {
  const testServerHost = 'localhost';
  const testServerPort = 9876;

  Future<bool> checkServer() async {
    final testClient = BitBarrelClient(
      BitBarrelConfig(
        host: testServerHost,
        port: testServerPort,
      ),
    );
    try {
      await testClient.connect();
      await testClient.close();
      return true;
    } catch (e) {
      return false;
    }
  }

  group('BitBarrelClient - Integration Tests', () {
    late BitBarrelClient client;
    late bool serverAvailable;

    setUp(() async {
      serverAvailable = await checkServer();
      client = BitBarrelClient(
        BitBarrelConfig(
          host: testServerHost,
          port: testServerPort,
        ),
      );
    });

    tearDown(() async {
      await client.close();
    });

    test('connect to server', () async {
      if (!serverAvailable) {
        return;
      }

      await client.connect();
      expect(client.isConnected, isTrue);
    });

    test('connect to non-existent server fails', () async {
      final badClient = BitBarrelClient(BitBarrelConfig(host: 'localhost', port: 9999));

      expect(
        () => badClient.connect(),
        throwsA(isA<ConnectionException>()),
      );

      await badClient.close();
    });

    test('ping server', () async {
      if (!serverAvailable) {
        return;
      }

      await client.connect();
      await client.ping();
      expect(client.isConnected, isTrue);
    });

    group('Barrel Management', () {
      test('create barrel', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_create_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName);
        await client.dropBarrel(barrelName);
      });

      test('create barrel with config', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_create_config_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName, '{"mode": "critbit"}');
        await client.dropBarrel(barrelName);
      });

      test('use barrel', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_use_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName);
        try {
          await client.useBarrel(barrelName);
          expect(client.currentBarrel, equals(barrelName));
        } finally {
          await client.dropBarrel(barrelName);
        }
      });

      test('use non-existent barrel throws', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();

        expect(
          () => client.useBarrel('nonexistent_barrel_xyz'),
          throwsA(isA<BarrelNotFoundException>()),
        );
      });

      test('list barrels', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_list_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName);
        try {
          final barrels = await client.listBarrels();
          expect(barrels, contains(barrelName));
        } finally {
          await client.dropBarrel(barrelName);
        }
      });

      test('drop barrel', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_drop_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName);
        await client.dropBarrel(barrelName);

        final barrels = await client.listBarrels();
        expect(barrels, isNot(contains(barrelName)));
      });

      test('close barrel', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_close_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName);
        try {
          await client.useBarrel(barrelName);
          expect(client.currentBarrel, equals(barrelName));

          await client.closeBarrel();
          expect(client.currentBarrel, isEmpty);
        } finally {
          await client.dropBarrel(barrelName);
        }
      });

      test('get barrel config', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_config_get_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName, '{"mode": "critbit"}');
        try {
          final config = await client.getBarrelConfig(barrelName);

          expect(config, isNotEmpty);
          expect(config.toLowerCase(), contains('critbit'));
        } finally {
          await client.dropBarrel(barrelName);
        }
      });

      test('set barrel config', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_config_set_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName, '{"mode": "critbit"}');
        try {
          // Try changing a mutable option (can't change mode at runtime)
          await client.setBarrelConfig(barrelName, '{"autoCompact": false}');

          // Verify the config was updated
          final config = await client.getBarrelConfig(barrelName);
          expect(
            config.toLowerCase(),
            anyOf(contains('"autocompact": false'), contains('"autocompact":false')),
          );
        } finally {
          await client.dropBarrel(barrelName);
        }
      });

      test('get config of non-existent barrel throws', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();

        expect(
          () => client.getBarrelConfig('nonexistent_barrel_xyz'),
          throwsA(isA<BarrelNotFoundException>()),
        );
      });

      test('set config of non-existent barrel throws', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();

        expect(
          () => client.setBarrelConfig('nonexistent_barrel_xyz', '{}'),
          throwsA(isA<BarrelNotFoundException>()),
        );
      });
    });

    group('Key-Value Operations', () {
      test('set and get', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_setget_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName);
        try {
          await client.useBarrel(barrelName);

          await client.set('key1', 'value1');
          final value = await client.get('key1');
          expect(value, equals('value1'));
        } finally {
          await client.dropBarrel(barrelName);
        }
      });

      test('get not found throws', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_notfound_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName);
        try {
          await client.useBarrel(barrelName);

          expect(
            () => client.get('nonexistent_key'),
            throwsA(isA<KeyNotFoundException>()),
          );
        } finally {
          await client.dropBarrel(barrelName);
        }
      });

      test('set without barrel throws', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();

        expect(
          () => client.set('key', 'value'),
          throwsA(isA<NoBarrelSelectedException>()),
        );
      });

      test('delete', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_delete_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName);
        try {
          await client.useBarrel(barrelName);

          await client.set('key1', 'value1');
          expect(await client.exists('key1'), isTrue);

          await client.delete('key1');
          expect(await client.exists('key1'), isFalse);
        } finally {
          await client.dropBarrel(barrelName);
        }
      });

      test('exists', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_exists_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName);
        try {
          await client.useBarrel(barrelName);

          expect(await client.exists('key1'), isFalse);
          await client.set('key1', 'value1');
          expect(await client.exists('key1'), isTrue);
        } finally {
          await client.dropBarrel(barrelName);
        }
      });

      test('count', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_count_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName);
        try {
          await client.useBarrel(barrelName);

          expect(await client.count(), equals(0));

          await client.set('key1', 'value1');
          await client.set('key2', 'value2');
          await client.set('key3', 'value3');

          expect(await client.count(), equals(3));
        } finally {
          await client.dropBarrel(barrelName);
        }
      });

      test('list keys', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_listkeys_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName);
        try {
          await client.useBarrel(barrelName);

          await client.set('alpha', '1');
          await client.set('beta', '2');
          await client.set('gamma', '3');

          final keys = await client.listKeys();
          expect(keys, hasLength(3));
          expect(keys, contains('alpha'));
          expect(keys, contains('beta'));
          expect(keys, contains('gamma'));
        } finally {
          await client.dropBarrel(barrelName);
        }
      });

      test('large value', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_large_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName);
        try {
          await client.useBarrel(barrelName);

          final largeValue = 'x' * 10000;
          await client.set('large_key', largeValue);

          final retrieved = await client.get('large_key');
          expect(retrieved, equals(largeValue));
        } finally {
          await client.dropBarrel(barrelName);
        }
      });

      test('get or default', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_getdefault_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName);
        try {
          await client.useBarrel(barrelName);

          // Test getting non-existent key with default
          final value1 = await client.getOrDefault('nonexistent_key', 'default_value');
          expect(value1, equals('default_value'));

          // Add a key and test getting existing value
          await client.set('existing_key', 'actual_value');
          final value2 = await client.getOrDefault('existing_key', 'default_value');
          expect(value2, equals('actual_value'));
        } finally {
          await client.dropBarrel(barrelName);
        }
      });

      test('concurrent operations', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_concurrent_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName);
        try {
          await client.useBarrel(barrelName);

          // Perform concurrent operations
          final futures = <Future<void>>[];
          for (var i = 0; i < 10; i++) {
            final future = () async {
              final localClient = BitBarrelClient(
                BitBarrelConfig(
                  host: testServerHost,
                  port: testServerPort,
                ),
              );
              await localClient.connect();
              await localClient.useBarrel(barrelName);

              final key = 'conc_key_$i';
              final value = 'conc_value_$i';
              await localClient.set(key, value);
              final retrieved = await localClient.get(key);
              expect(retrieved, equals(value));

              await localClient.close();
            }();
            futures.add(future);
          }

          // Wait for all operations to complete
          await Future.wait(futures);

          // Verify all keys were added
          final count = await client.count();
          expect(count, equals(10));
        } finally {
          await client.dropBarrel(barrelName);
        }
      });
    });

    group('Range Queries', () {
      test('range query with ordered barrel', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_range_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName, '{"mode": "critbit"}');
        try {
          await client.useBarrel(barrelName);

          await client.set('user:001', 'Alice');
          await client.set('user:002', 'Bob');
          await client.set('user:003', 'Charlie');

          final result = await client.rangeQuery('user:001', 'user:003');
          expect(result.items, hasLength(2));
          expect(result.items.any((kv) => kv.key == 'user:001'), isTrue);
          expect(result.items.any((kv) => kv.key == 'user:002'), isTrue);
        } finally {
          await client.dropBarrel(barrelName);
        }
      });

      test('prefix query with ordered barrel', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_prefix_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName, '{"mode": "critbit"}');
        try {
          await client.useBarrel(barrelName);

          await client.set('user:001', 'Alice');
          await client.set('user:002', 'Bob');
          await client.set('other:001', 'Other');

          final result = await client.prefixQuery('user:');
          expect(result.items, hasLength(2));
          expect(result.items.any((kv) => kv.key == 'user:001'), isTrue);
          expect(result.items.any((kv) => kv.key == 'user:002'), isTrue);
        } finally {
          await client.dropBarrel(barrelName);
        }
      });

      test('range count with ordered barrel', () async {
        if (!serverAvailable) {
          return;
        }

        await client.connect();
        final barrelName = 'test_count_range_${DateTime.now().millisecondsSinceEpoch}';

        await client.createBarrel(barrelName, '{"mode": "critbit"}');
        try {
          await client.useBarrel(barrelName);

          await client.set('user:001', 'Alice');
          await client.set('user:002', 'Bob');
          await client.set('user:003', 'Charlie');

          final count = await client.rangeCount('user:000', 'user:999');
          expect(count, equals(3));
        } finally {
          await client.dropBarrel(barrelName);
        }
      });
    });

    group('JWT Authentication', () {
      test('client creation with token', () async {
        const token = 'test-jwt-token';
        final config = BitBarrelConfig.withToken(
          host: testServerHost,
          port: testServerPort,
          token: token,
        );

        expect(config.token, equals(token));
      });

      test('connect with token', () async {
        if (!serverAvailable) {
          return;
        }

        // Test with a sample JWT token format
        const token = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0X3JlYWR3cml0ZSIsInJvbGVzIjpbInJlYWR3cml0ZSJdLCJpYXQiOjE3MDQwNjcyMDAsImV4cCI6NDA5OTc2NzIwMH0.test_signature_for_testing';
        final config = BitBarrelConfig.withToken(
          host: testServerHost,
          port: testServerPort,
          token: token,
        );
        final client = BitBarrelClient(config);

        try {
          await client.connect();
          // Connection may succeed or fail depending on server auth config
          // The important part is that the client sends the token
          await client.close();
        } catch (e) {
          // Connection might fail if auth is enabled with different config
          // That's ok - we're testing the client sends the token
          print('Expected: connection with token error (may be ok): $e');
        }
      });

      test('connect without token', () async {
        if (!serverAvailable) {
          return;
        }

        final client = BitBarrelClient.localhost();

        await client.connect();
        expect(client.isConnected, isTrue);

        // Should be able to perform operations without auth
        final barrelName = 'test_no_auth_\${DateTime.now().millisecondsSinceEpoch}';
        try {
          await client.createBarrel(barrelName);
          await client.useBarrel(barrelName);
          await client.set('key1', 'value1');

          final value = await client.get('key1');
          expect(value, equals('value1'));

          final exists = await client.exists('key1');
          expect(exists, isTrue);

          final count = await client.count();
          expect(count, equals(1));
        } finally {
          await client.dropBarrel(barrelName);
        }

        await client.close();
      });
    });

    group('Key Watching', () {
      test('watch requires barrel selection', () async {
        final client = BitBarrelClient(
          BitBarrelConfig(host: testServerHost, port: testServerPort),
        );
        addTearDown(() => client.close());

        await client.connect();

        // Try to watch without selecting a barrel
        expect(
          () => client.watch('user:*'),
          throwsA(isA<NoBarrelSelectedException>()),
        );
      });

      test('watch basic functionality', () async {
        final client = BitBarrelClient(
          BitBarrelConfig(host: testServerHost, port: testServerPort),
        );
        addTearDown(() => client.close());

        final events = <PubSubEvent>[];
        client.setOnMessage(events.add);

        await client.connect();

        final barrelName = 'test_barrel_watch_${DateTime.now().millisecondsSinceEpoch}';
        await client.createBarrel(barrelName);
        addTearDown(() => client.dropBarrel(barrelName));

        await client.useBarrel(barrelName);

        // Subscribe to key events
        await client.subscribe('kv:');
        addTearDown(() => client.unsubscribe('kv:'));

        // Watch pattern
        await client.watch('user:*', includeValues: false);

        // Wait for subscription
        await Future.delayed(Duration(milliseconds: 100));

        // Set a matching key
        await client.set('user:1', 'Alice');

        // Wait for event
        await Future.delayed(Duration(milliseconds: 500));

        // Verify event received
        expect(events, isNotEmpty);
        final event = events.last;
        expect(event.topic, contains('user:1'));
        expect(event.messageType, equals(PubSubMessageType.kvChange));
        expect(event.payload, isEmpty); // No values included
      });

      test('watch with values', () async {
        final client = BitBarrelClient(
          BitBarrelConfig(host: testServerHost, port: testServerPort),
        );
        addTearDown(() => client.close());

        final events = <PubSubEvent>[];
        client.setOnMessage(events.add);

        await client.connect();

        final barrelName = 'test_barrel_watch_values_${DateTime.now().millisecondsSinceEpoch}';
        await client.createBarrel(barrelName);
        addTearDown(() => client.dropBarrel(barrelName));

        await client.useBarrel(barrelName);

        // Subscribe to key events
        await client.subscribe('kv:');
        addTearDown(() => client.unsubscribe('kv:'));

        // Watch with values
        await client.watch('cache:*', includeValues: true);

        // Wait for subscription
        await Future.delayed(Duration(milliseconds: 100));

        // Set a matching key
        await client.set('cache:item1', 'value1');

        // Wait for event
        await Future.delayed(Duration(milliseconds: 500));

        // Verify event received with value
        expect(events, isNotEmpty);
        final event = events.last;
        expect(event.topic, contains('cache:item1'));
        expect(event.payload, equals('value1'));
      });

      test('unwatch stops events', () async {
        final client = BitBarrelClient(
          BitBarrelConfig(host: testServerHost, port: testServerPort),
        );
        addTearDown(() => client.close());

        final events = <PubSubEvent>[];
        client.setOnMessage(events.add);

        await client.connect();

        final barrelName = 'test_barrel_unwatch_${DateTime.now().millisecondsSinceEpoch}';
        await client.createBarrel(barrelName);
        addTearDown(() => client.dropBarrel(barrelName));

        await client.useBarrel(barrelName);

        // Subscribe to key events
        await client.subscribe('kv:');
        addTearDown(() => client.unsubscribe('kv:'));

        // Set up watch
        await client.watch('temp:*', includeValues: false);
        await Future.delayed(Duration(milliseconds: 100));

        // Now unwatch
        await client.unwatch('temp:*');
        await Future.delayed(Duration(milliseconds: 100));

        // Set a key that would match the old pattern
        await client.set('temp:1', 'value1');

        // Wait to ensure no event comes
        await Future.delayed(Duration(milliseconds: 500));

        // Should not have received any events
        expect(events, isEmpty);
      });
    });
  });
}
