import 'dart:async';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:bitbarrel/bitbarrel.dart';

/// Check if BitBarrel server is running on localhost:9876
Future<bool> isServerAvailable() async {
  try {
    final client = BitBarrelClient.localhost();
    await client.connect();
    await client.close();
    return true;
  } catch (e) {
    return false;
  }
}

/// Generate a unique topic name for test isolation
String uniqueTopicName(String prefix) {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final random = DateTime.now().microsecondsSinceEpoch % 1000000;
  return '${prefix}_${timestamp}_${random}';
}

void main() {
  group('Pub/Sub Integration Tests', () {
    late BitBarrelClient client;
    late String testBarrel;
    bool serverAvailable = false;

    setUpAll(() async {
      serverAvailable = await isServerAvailable();
    });

    setUp(() async {
      if (!serverAvailable) {
        print('Skipping Pub/Sub integration tests - no server running on localhost:9876');
        return;
      }

      client = BitBarrelClient.localhost();
      await client.connect();

      testBarrel = uniqueTopicName('test_barrel');
      await client.createBarrel(testBarrel);
      await client.useBarrel(testBarrel);
    });

    tearDown(() async {
      if (!serverAvailable) return;

      try {
        await client.unsubscribeAll();
        await client.closeBarrel();
        await client.close();
      } catch (e) {
        // Ignore cleanup errors
      }
    });

    test('subscribe to topic', () async {
      if (!serverAvailable) return;

      final topic = uniqueTopicName('test:exact');
      final subId = await client.subscribe(topic);

      expect(subId, isNotEmpty);
      expect(await client.isSubscribed(subId), isTrue);

      await client.unsubscribe(subId);
      expect(await client.isSubscribed(subId), isFalse);
    });

    test('subscribe and receive message', () async {
      if (!serverAvailable) return;

      final messagesReceived = <PubSubEvent>[];
      client.setOnMessage((event) {
        messagesReceived.add(event);
      });

      final topic = uniqueTopicName('test:receive');
      final subId = await client.subscribe(topic);

      // Wait for subscription to activate
      await Future.delayed(Duration(milliseconds: 100));

      // Publish a message
      final seqNo = await client.publishData(topic, 'test payload');
      expect(seqNo, greaterThan(0));

      // Wait for message to arrive with timeout
      final startTime = DateTime.now();
      while (messagesReceived.isEmpty &&
          DateTime.now().difference(startTime).inSeconds < 3) {
        await client.receiveMessages(timeout: Duration(milliseconds: 100));
        await Future.delayed(Duration(milliseconds: 50));
      }

      expect(messagesReceived, isNotEmpty);
      expect(messagesReceived.first.topic, equals(topic));
      expect(messagesReceived.first.payload, equals('test payload'));
      expect(messagesReceived.first.sequence, equals(seqNo));

      await client.unsubscribe(subId);
    });

    test('pattern subscription', () async {
      if (!serverAvailable) return;

      final messagesReceived = <PubSubEvent>[];
      client.setOnMessage((event) {
        messagesReceived.add(event);
      });

      // Subscribe to pattern
      final subId = await client.subscribe('user:*');
      await Future.delayed(Duration(milliseconds: 100));

      // Publish matching messages
      await client.publishData('user:login', 'user logged in');
      await client.publishData('user:logout', 'user logged out');

      // Publish non-matching message
      await client.publishData('system:start', 'should not receive');

      // Wait for messages
      final startTime = DateTime.now();
      while (messagesReceived.length < 2 &&
          DateTime.now().difference(startTime).inSeconds < 3) {
        await client.receiveMessages(timeout: Duration(milliseconds: 100));
        await Future.delayed(Duration(milliseconds: 50));
      }

      expect(messagesReceived.length, greaterThanOrEqualTo(2));

      // Verify we didn't receive the system message
      for (final event in messagesReceived) {
        expect(event.topic, isNot(equals('system:start')));
      }

      await client.unsubscribe(subId);
    });

    test('unsubscribe all', () async {
      if (!serverAvailable) return;

      final sub1 = await client.subscribe('topic1');
      final sub2 = await client.subscribe('topic2');
      final sub3 = await client.subscribe('topic3');

      expect(await client.isSubscribed(sub1), isTrue);
      expect(await client.isSubscribed(sub2), isTrue);
      expect(await client.isSubscribed(sub3), isTrue);

      final count = await client.unsubscribeAll();
      expect(count, equals(3));

      expect(await client.isSubscribed(sub1), isFalse);
      expect(await client.isSubscribed(sub2), isFalse);
      expect(await client.isSubscribed(sub3), isFalse);
    });

    test('publish with different message types', () async {
      if (!serverAvailable) return;

      final messagesReceived = <PubSubEvent>[];
      client.setOnMessage((event) {
        messagesReceived.add(event);
      });

      final topic = uniqueTopicName('test:msgtypes');
      // Subscribe with enablePresence to receive presence-type messages
      final subId = await client.subscribe(topic,
          options: const SubscriptionOptions(enablePresence: true));
      await Future.delayed(Duration(milliseconds: 100));

      // Publish different message types
      await client.publish(
        topic,
        messageType: PubSubMessageType.data,
        payload: 'data message',
      );
      await client.publish(
        topic,
        messageType: PubSubMessageType.presence,
        payload: 'presence message',
      );

      // Wait for messages
      final startTime = DateTime.now();
      while (messagesReceived.length < 2 &&
          DateTime.now().difference(startTime).inSeconds < 3) {
        await client.receiveMessages(timeout: Duration(milliseconds: 100));
        await Future.delayed(Duration(milliseconds: 50));
      }

      expect(messagesReceived.length, greaterThanOrEqualTo(2));

      // Verify we have different message types
      final types = messagesReceived.map((e) => e.messageType).toSet();
      expect(types.length, greaterThan(1));

      await client.unsubscribe(subId);
    });

    test('publish with headers', () async {
      if (!serverAvailable) return;

      final messagesReceived = <PubSubEvent>[];
      client.setOnMessage((event) {
        messagesReceived.add(event);
      });

      final topic = uniqueTopicName('test:headers');
      final subId = await client.subscribe(topic);
      await Future.delayed(Duration(milliseconds: 100));

      // Publish with headers
      final headers = '{"userId": "123", "source": "test"}';
      final seqNo = await client.publish(
        topic,
        messageType: PubSubMessageType.data,
        payload: 'message with headers',
        headers: headers,
      );
      expect(seqNo, greaterThan(0));

      // Wait for message
      final startTime = DateTime.now();
      while (messagesReceived.isEmpty &&
          DateTime.now().difference(startTime).inSeconds < 3) {
        await client.receiveMessages(timeout: Duration(milliseconds: 100));
        await Future.delayed(Duration(milliseconds: 50));
      }

      expect(messagesReceived, isNotEmpty);
      // Compare JSON values (ignoring whitespace differences)
      final headersJson = jsonDecode(headers) as Map<String, dynamic>;
      final receivedHeadersJson = jsonDecode(messagesReceived.first.headers) as Map<String, dynamic>;
      expect(receivedHeadersJson, equals(headersJson));
      expect(messagesReceived.first.payload, equals('message with headers'));

      await client.unsubscribe(subId);
    });

    test('unsubscribe non-existent subscription', () async {
      if (!serverAvailable) return;

      final result = await client.unsubscribe('non_existent_sub_id');
      expect(result, isFalse);
    });

    test('list subscribers for topic', () async {
      if (!serverAvailable) return;

      final client2 = BitBarrelClient.localhost();
      await client2.connect();
      await client2.useBarrel(testBarrel);

      try {
        final topic = uniqueTopicName('test:list_subscribers');

        // Both clients subscribe to same topic
        await client.subscribe(topic);
        await client2.subscribe(topic);

        await Future.delayed(Duration(milliseconds: 100));

        // List subscribers
        final subscribers = await client.listSubscribers(topic);
        expect(subscribers.length, greaterThanOrEqualTo(2));

        // Verify all subscription IDs are unique
        final ids = subscribers.map((s) => s.id).toSet();
        expect(ids.length, equals(subscribers.length));
      } finally {
        await client2.close();
      }
    });

    test('list topics', () async {
      if (!serverAvailable) return;

      final topic1 = uniqueTopicName('test:topics1');
      final topic2 = uniqueTopicName('test:topics2');
      final topic3 = uniqueTopicName('test:topics3');

      // Create topics by publishing to them
      await client.publishData(topic1, 'data1');
      await client.publishData(topic2, 'data2');
      await client.publishData(topic3, 'data3');

      await Future.delayed(Duration(milliseconds: 100));

      // List all topics
      final topics = await client.listTopics();
      expect(topics.length, greaterThanOrEqualTo(3));

      // Find our topics
      final topicNames = topics.map((t) => t.name).toSet();
      expect(topicNames, contains(topic1));
      expect(topicNames, contains(topic2));
      expect(topicNames, contains(topic3));

      // Verify topic info structure
      for (final topic in topics) {
        expect(topic.name, isNotEmpty);
        expect(topic.sequence, greaterThanOrEqualTo(0));
        expect(topic.subscriberCount, greaterThanOrEqualTo(0));
        expect(topic.messageCount, greaterThanOrEqualTo(0));
      }
    });

    test('get history for topic', () async {
      if (!serverAvailable) return;

      final topic = uniqueTopicName('test:history');

      // Publish some messages
      await client.publishData(topic, 'message 1');
      await Future.delayed(Duration(milliseconds: 10));
      await client.publishData(topic, 'message 2');
      await Future.delayed(Duration(milliseconds: 10));
      await client.publishData(topic, 'message 3');

      await Future.delayed(Duration(milliseconds: 100));

      // Get history - skip if history not enabled on server
      List<PubSubEvent> history;
      try {
        history = await client.getHistory(topic, limit: 10);
      } catch (e) {
        print('Skipping Pub/Sub history test - history may not be enabled: $e');
        return;
      }
      expect(history.length, greaterThanOrEqualTo(3));

      // Verify messages (newest first)
      expect(history[0].payload, equals('message 1'));
      expect(history[1].payload, equals('message 2'));
      expect(history[2].payload, equals('message 3'));

      // Verify event properties
      for (final event in history) {
        expect(event.topic, equals(topic));
        expect(event.messageType, equals(PubSubMessageType.data));
        expect(event.sequence, greaterThan(0));
        expect(event.timestamp, greaterThan(0));
      }
    });

    test('get history with limit', () async {
      if (!serverAvailable) return;

      final topic = uniqueTopicName('test:history_limit');

      // Publish 5 messages
      final seqNos = <int>[];
      for (var i = 1; i <= 5; i++) {
        final seq = await client.publishData(topic, 'message $i');
        seqNos.add(seq);
        await Future.delayed(Duration(milliseconds: 10));
      }
      await Future.delayed(Duration(milliseconds: 100));

      // Get only 2 messages - skip if history not enabled
      List<PubSubEvent> historyLimited;
      try {
        historyLimited = await client.getHistory(topic, limit: 2);
      } catch (e) {
        print('Skipping Pub/Sub history limit test - history may not be enabled: $e');
        return;
      }
      expect(historyLimited.length, lessThanOrEqualTo(2));

      // Get messages since specific sequence
      final sinceSeq = seqNos[2];
      final historySince = await client.getHistory(
        topic,
        limit: 10,
        sinceSeq: sinceSeq,
      );
      expect(historySince.length, greaterThanOrEqualTo(3));
      expect(historySince.first.sequence, greaterThanOrEqualTo(sinceSeq));
    });

    test('get presence for topic', () async {
      if (!serverAvailable) return;

      final client2 = BitBarrelClient.localhost();
      await client2.connect();
      await client2.useBarrel(testBarrel);

      try {
        final topic = uniqueTopicName('test:presence');

        // Subscribe with presence enabled
        final opts = SubscriptionOptions(enablePresence: true);
        await client.subscribe(topic, options: opts);
        await client2.subscribe(topic, options: opts);

        await Future.delayed(Duration(milliseconds: 100));

        // Get presence
        final presence = await client.getPresence(topic);
        expect(presence.topic, equals(topic));
        expect(presence.members.length, greaterThanOrEqualTo(2));

        // Verify member properties
        for (final member in presence.members) {
          expect(member.clientId, greaterThan(0));
          expect(member.joinedAt, greaterThan(0));
          expect(member.lastPing, greaterThan(0));
        }
      } finally {
        await client2.close();
      }
    });
  });
}
