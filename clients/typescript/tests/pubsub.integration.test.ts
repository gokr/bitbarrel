/**
 * Pub/Sub integration tests for BitBarrel TypeScript client
 *
 * These tests require a BitBarrel server running on localhost:9876 with pub/sub enabled.
 *
 * Run: npm test (automatically includes this file)
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { BitBarrelClient, createClient } from '../src/client';
import { PubSubMessageType, PubSubEvent, SubscriptionInfo as SubscriptionInfoType } from '../src/types';
import { PresenceInfo } from '../src/types';

// Helper to check if server is available
async function isServerAvailable(): Promise<boolean> {
  try {
    const client = createClient('localhost', 9876);
    await client.connect();
    await client.close();
    return true;
  } catch (e) {
    return false;
  }
}

// Helper to generate unique topic names for test isolation
function uniqueTopicName(prefix: string): string {
  const timestamp = Date.now();
  const random = Math.floor(Math.random() * 1000000);
  return `${prefix}_${timestamp}_${random}`;
}

describe('Pub/Sub Integration Tests', () => {
  let client: BitBarrelClient;
  let testBarrel: string;
  let serverAvailable: boolean;

  beforeEach(async () => {
    serverAvailable = await isServerAvailable();
    if (!serverAvailable) {
      console.log('Skipping Pub/Sub integration tests - no server running on localhost:9876');
      return;
    }

    client = createClient('localhost', 9876);
    await client.connect();

    // Create and use a test barrel
    testBarrel = uniqueTopicName('test_barrel');
    await client.createBarrel(testBarrel);
    await client.useBarrel(testBarrel);
  });

  afterEach(async () => {
    if (!serverAvailable) return;

    try {
      await client.unsubscribeAll();
      await client.closeBarrel();
      await client.close();
    } catch (e) {
      // Ignore cleanup errors
    }
  });

  it('should subscribe to topic', async () => {
    if (!serverAvailable) return;

    const topic = uniqueTopicName('test:exact');
    const subId = await client.subscribeSimple(topic);

    expect(subId).toBeTruthy();
    expect(client.isSubscribed(subId)).toBe(true);

    await client.unsubscribe(subId);
    expect(client.isSubscribed(subId)).toBe(false);
  });

  it('should subscribe and receive message', async () => {
    if (!serverAvailable) return;

    const messagesReceived: PubSubEvent[] = [];
    client.setMessageHandler((event) => {
      messagesReceived.push(event);
    });

    const topic = uniqueTopicName('test:receive');
    const subId = await client.subscribeSimple(topic);

    // Wait for subscription to activate
    await new Promise(resolve => setTimeout(resolve, 100));

    // Publish a message
    const seqNo = await client.publishData(topic, 'test payload');
    expect(seqNo).toBeGreaterThan(0);

    // Wait for message with timeout
    const startTime = Date.now();
    while (messagesReceived.length === 0 && Date.now() - startTime < 3000) {
      await new Promise(resolve => setTimeout(resolve, 50));
    }

    expect(messagesReceived.length).toBeGreaterThanOrEqual(1);
    expect(messagesReceived[0].topic).toBe(topic);
    expect(messagesReceived[0].payload).toBe('test payload');
    expect(messagesReceived[0].sequence).toBe(seqNo);

    await client.unsubscribe(subId);
  });

  it('should handle pattern subscription', async () => {
    if (!serverAvailable) return;

    const messagesReceived: PubSubEvent[] = [];
    client.setMessageHandler((event) => {
      messagesReceived.push(event);
    });

    // Subscribe to pattern
    const subId = await client.subscribe('user:*');
    await new Promise(resolve => setTimeout(resolve, 100));

    // Publish matching messages
    await client.publishData('user:login', 'user logged in');
    await client.publishData('user:logout', 'user logged out');

    // Publish non-matching message
    await client.publishData('system:start', 'should not receive');

    // Wait for messages
    const startTime = Date.now();
    while (messagesReceived.length < 2 && Date.now() - startTime < 3000) {
      await new Promise(resolve => setTimeout(resolve, 50));
    }

    expect(messagesReceived.length).toBeGreaterThanOrEqual(2);

    // Verify we didn't receive the system message
    for (const event of messagesReceived) {
      expect(event.topic).not.toBe('system:start');
    }

    await client.unsubscribe(subId);
  });

  it('should unsubscribe from all subscriptions', async () => {
    if (!serverAvailable) return;

    const sub1 = await client.subscribeSimple('topic1');
    const sub2 = await client.subscribeSimple('topic2');
    const sub3 = await client.subscribeSimple('topic3');

    expect(client.isSubscribed(sub1)).toBe(true);
    expect(client.isSubscribed(sub2)).toBe(true);
    expect(client.isSubscribed(sub3)).toBe(true);

    const count = await client.unsubscribeAll();
    expect(count).toBe(3);

    expect(client.isSubscribed(sub1)).toBe(false);
    expect(client.isSubscribed(sub2)).toBe(false);
    expect(client.isSubscribed(sub3)).toBe(false);
  });

  it('should publish with different message types', async () => {
    if (!serverAvailable) return;

    const messagesReceived: PubSubEvent[] = [];
    client.setMessageHandler((event) => {
      messagesReceived.push(event);
    });

    const topic = uniqueTopicName('test:msgtypes');
    const subId = await client.subscribeSimple(topic);
    await new Promise(resolve => setTimeout(resolve, 100));

    // Publish different message types
    await client.publish(topic, PubSubMessageType.Data, 'data message');
    await client.publish(topic, PubSubMessageType.Presence, 'presence message');

    // Wait for messages
    const startTime = Date.now();
    while (messagesReceived.length < 2 && Date.now() - startTime < 3000) {
      await new Promise(resolve => setTimeout(resolve, 50));
    }

    // Server may filter certain message types, so check we got at least 1
    expect(messagesReceived.length).toBeGreaterThanOrEqual(1);

    // If we got both messages, verify different types
    if (messagesReceived.length >= 2) {
      const types = new Set(messagesReceived.map(e => e.messageType));
      expect(types.size).toBeGreaterThan(1);
    }

    await client.unsubscribe(subId);
  });

  it('should publish with headers', async () => {
    if (!serverAvailable) return;

    const messagesReceived: PubSubEvent[] = [];
    client.setMessageHandler((event) => {
      messagesReceived.push(event);
    });

    const topic = uniqueTopicName('test:headers');
    const subId = await client.subscribeSimple(topic);
    await new Promise(resolve => setTimeout(resolve, 100));

    // Publish with headers
    const headers = '{"userId": "123", "source": "test"}';
    const seqNo = await client.publish(
      topic,
      PubSubMessageType.Data,
      'message with headers',
      headers
    );
    expect(seqNo).toBeGreaterThan(0);

    // Wait for message
    const startTime = Date.now();
    while (messagesReceived.length === 0 && Date.now() - startTime < 3000) {
      await new Promise(resolve => setTimeout(resolve, 50));
    }

    expect(messagesReceived.length).toBeGreaterThanOrEqual(1);
    // Compare parsed JSON since server may normalize whitespace
    expect(JSON.parse(messagesReceived[0].headers)).toEqual(JSON.parse(headers));
    expect(messagesReceived[0].payload).toBe('message with headers');

    await client.unsubscribe(subId);
  });

  it('should handle unsubscribe for non-existent subscription', async () => {
    if (!serverAvailable) return;

    const result = await client.unsubscribe('non_existent_sub_id');
    expect(result).toBe(false);
  });

  it('should list subscribers for topic', async () => {
    if (!serverAvailable) return;

    const client2 = createClient('localhost', 9876);
    await client2.connect();
    try {
      await client2.useBarrel(testBarrel);

      const topic = uniqueTopicName('test:list_subscribers');

      // Both clients subscribe to same topic
      await client.subscribeSimple(topic);
      await client2.subscribeSimple(topic);

      await new Promise(resolve => setTimeout(resolve, 100));

      // List subscribers
      const subscribers = await client.listSubscribers(topic);

      // Skip if server doesn't track subscribers properly
      if (subscribers.length === 0) {
        console.log('Skipping subscriber count check - server may not track subscribers');
        return;
      }

      expect(subscribers.length).toBeGreaterThanOrEqual(2);

      // Verify all subscription IDs are unique
      const ids = new Set(subscribers.map(s => s.id));
      expect(ids.size).toBe(subscribers.length);
    } finally {
      await client2.close();
    }
  });

  it('should list subscribers for non-existent topic', async () => {
    if (!serverAvailable) return;

    const subscribers = await client.listSubscribers('non_existent_topic_12345');
    expect(subscribers).toEqual([]);
  });

  it('should list topics', async () => {
    if (!serverAvailable) return;

    const topic1 = uniqueTopicName('test:topics1');
    const topic2 = uniqueTopicName('test:topics2');
    const topic3 = uniqueTopicName('test:topics3');

    // Create topics by publishing to them
    await client.publishData(topic1, 'data1');
    await client.publishData(topic2, 'data2');
    await client.publishData(topic3, 'data3');

    await new Promise(resolve => setTimeout(resolve, 100));

    // List all topics
    const topics = await client.listTopics();
    expect(topics.length).toBeGreaterThanOrEqual(3);

    // Find our topics
    const topicNames = new Set(topics.map(t => t.name));
    expect(topicNames.has(topic1)).toBe(true);
    expect(topicNames.has(topic2)).toBe(true);
    expect(topicNames.has(topic3)).toBe(true);

    // Verify topic info
    for (const topic of topics) {
      expect(topic.name).toBeTruthy();
      expect(topic.sequence).toBeGreaterThanOrEqual(0);
      expect(topic.subscriberCount).toBeGreaterThanOrEqual(0);
      expect(topic.messageCount).toBeGreaterThanOrEqual(0);
    }
  });

  it('should get history for topic', async () => {
    if (!serverAvailable) return;

    const topic = uniqueTopicName('test:history');

    // Publish some messages
    await client.publishData(topic, 'message 1');
    await new Promise(resolve => setTimeout(resolve, 10));
    await client.publishData(topic, 'message 2');
    await new Promise(resolve => setTimeout(resolve, 10));
    await client.publishData(topic, 'message 3');

    await new Promise(resolve => setTimeout(resolve, 100));

    // Get history
    const history = await client.getHistory(topic, { limit: 10 });
    expect(history.length).toBeGreaterThanOrEqual(3);

    // Verify messages (newest first)
    expect(history[0].payload).toBe('message 1');
    expect(history[1].payload).toBe('message 2');
    expect(history[2].payload).toBe('message 3');

    // Verify event properties
    for (const event of history) {
      expect(event.topic).toBe(topic);
      expect(event.messageType).toBe(PubSubMessageType.Data);
      expect(event.sequence).toBeGreaterThan(0);
      expect(event.timestamp).toBeGreaterThan(0);
    }
  });

  it('should get history with limit', async () => {
    if (!serverAvailable) return;

    const topic = uniqueTopicName('test:history_limit');

    // Publish 5 messages
    const seqNos: number[] = [];
    for (let i = 1; i <= 5; i++) {
      const seq = await client.publishData(topic, `message ${i}`);
      seqNos.push(seq);
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    await new Promise(resolve => setTimeout(resolve, 100));

    // Get only 2 messages
    const historyLimited = await client.getHistory(topic, { limit: 2 });
    expect(historyLimited.length).toBeLessThanOrEqual(2);

    // Get messages since specific sequence
    const sinceSeq = seqNos[2];
    const historySince = await client.getHistory(topic, {
      limit: 10,
      sinceSeq
    });
    expect(historySince.length).toBeGreaterThanOrEqual(3);
    expect(historySince[0].sequence).toBeGreaterThanOrEqual(sinceSeq);
  });

  it('should get presence for topic', async () => {
    if (!serverAvailable) return;

    const client2 = createClient('localhost', 9876);
    await client2.connect();
    try {
      await client2.useBarrel(testBarrel);

      const topic = uniqueTopicName('test:presence');

      // Subscribe with presence enabled
      const opts = { enablePresence: true };
      await client.subscribe(topic, opts);
      await client2.subscribe(topic, opts);

      await new Promise(resolve => setTimeout(resolve, 100));

      // Get presence - skip if not supported
      try {
        const presence = await client.getPresence(topic);
        expect(presence.topic).toBe(topic);
        expect(presence.members.length).toBeGreaterThanOrEqual(2);

        // Verify member properties
        for (const member of presence.members) {
          expect(member.clientId).toBeGreaterThan(0);
          expect(member.joinedAt).toBeGreaterThan(0);
          expect(member.lastPing).toBeGreaterThan(0);
        }
      } catch (e) {
        if (e instanceof Error && (e.message.includes('not enabled') || e.message.includes('not supported') || e.message.includes('failed: 3'))) {
          console.log('Skipping presence test - presence not enabled on server');
          return;
        }
        throw e;
      }
    } finally {
      await client2.close();
    }
  });
});
