/**
 * BitBarrel PubSub Chat Room Example
 *
 * Demonstrates real-time chat with history replay, pattern subscriptions,
 * presence tracking, and query operations following the 12-step pattern.
 */

import { BitBarrelClient } from '../src/index';
import type { PubSubEvent, SubscriptionOptions, SubscriptionInfo } from '../src/types';

async function pubsubChatExample() {
  console.log('=== BitBarrel PubSub Chat Room Example (12-step pattern) ===\n');

  // Step 1: Connect to BitBarrel server (localhost:9876)
  console.log('1. Connecting to BitBarrel server...');
  const client = new BitBarrelClient({
    host: 'localhost',
    port: 9876,
    autoConnect: true,
  });

  try {
    await client.connect();
    console.log('✓ Connected to BitBarrel server\n');

    // Step 2: Setup chat storage barrel
    console.log('2. Setting up chat storage barrel...');
    try {
      await client.createBarrel('chat_storage', 'bmCritBit');
      console.log('✓ Created chat_storage barrel (bmCritBit mode)');
    } catch (err) {
      // Barrel might already exist
      console.log('✓ Using existing chat_storage barrel');
    }
    await client.useBarrel('chat_storage');
    console.log('✓ Using chat_storage barrel\n');

    // Step 3: Subscribe to "room:general" with options (history replay, presence)
    console.log('3. Subscribing to "room:general"...');
    const subscriptionOptions: SubscriptionOptions = {
      replayHistory: true,
      enablePresence: true,
    };
    const subIdGeneral = await client.subscribe('room:general', subscriptionOptions);
    console.log('✓ Subscribed to "room:general" with history replay and presence tracking (subscription ID: ' + subIdGeneral + ')\n');

    // Step 4: Publish 5 chat messages from 5 users
    console.log('4. Publishing 5 chat messages from 5 users...');
    const users = ['Alice', 'Bob', 'Charlie', 'Diana', 'Eve'];
    const messages = [
      'Hello everyone!',
      'How are you all doing?',
      'This chat system is great!',
      'Anyone working on interesting projects?',
      'Let\'s schedule a meetup next week.',
    ];

    for (let i = 0; i < 5; i++) {
      const user = users[i];
      const message = messages[i];
      const data = JSON.stringify({
        user,
        message,
        timestamp: Date.now(),
      });
      await client.publishData('room:general', data);
      console.log(`  ${user}: ${message}`);
      // Small delay between messages
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    console.log('✓ Published 5 messages\n');

    // Step 5: Retrieve and display message history
    console.log('5. Retrieving message history...');
    const history = await client.getHistory('room:general', { limit: 10 });
    console.log(`✓ Retrieved ${history.length} messages from history:`);
    history.forEach((msg: PubSubEvent, idx: number) => {
      try {
        const data = JSON.parse(msg.payload);
        console.log(`  [${idx + 1}] ${data.user}: ${data.message}`);
      } catch {
        console.log(`  [${idx + 1}] ${msg.payload}`);
      }
    });
    console.log();

    // Step 6: Subscribe to "room:*" pattern
    console.log('6. Subscribing to "room:*" pattern...');
    const subIdPattern = await client.subscribe('room:*');
    console.log('✓ Subscribed to "room:*" pattern (subscription ID: ' + subIdPattern + ')\n');

    // Step 7: Publish to different rooms (tech, random)
    console.log('7. Publishing to different rooms...');
    const roomMessages = [
      { room: 'room:tech', user: 'Alice', message: 'New TypeScript features are awesome!' },
      { room: 'room:random', user: 'Bob', message: 'Random thought: pineapples on pizza?' },
    ];
    for (const rm of roomMessages) {
      const data = JSON.stringify({
        user: rm.user,
        message: rm.message,
        timestamp: Date.now(),
      });
      await client.publishData(rm.room, data);
      console.log(`  Published to ${rm.room}: ${rm.user}: ${rm.message}`);
    }
    console.log();

    // Step 8: Query subscribers in "room:general"
    console.log('8. Querying subscribers in "room:general"...');
    const subscribers = await client.listSubscribers('room:general');
    console.log(`✓ Subscribers in "room:general": ${subscribers.length} subscribers`);
    subscribers.forEach((sub: SubscriptionInfo, idx: number) => {
      console.log(`  ${idx + 1}. ${sub.id} (topic: ${sub.topic}, pattern: ${sub.pattern})`);
    });
    console.log();

    // Step 9: Check presence information
    console.log('9. Checking presence information...');
    const presence = await client.getPresence('room:general');
    console.log('✓ Presence information:');
    console.log(`  Topic: ${presence.topic}`);
    console.log(`  Members: ${presence.members.length}`);
    console.log(`  Last update: ${new Date(presence.lastUpdate).toLocaleString()}`);
    console.log();

    // Step 10: Get history with sequence filtering (sinceSeq=3)
    console.log('10. Getting history since sequence 3...');
    const historySince3 = await client.getHistory('room:general', { limit: 10, sinceSeq: 3 });
    console.log(`✓ Retrieved ${historySince3.length} messages since sequence 3:`);
    historySince3.forEach((msg: PubSubEvent) => {
      try {
        const data = JSON.parse(msg.payload);
        console.log(`  [seq ${msg.sequence}] ${data.user}: ${data.message}`);
      } catch {
        console.log(`  [seq ${msg.sequence}] ${msg.payload}`);
      }
    });
    console.log();

    // Step 11: Show history per room
    console.log('11. Showing history per room...');
    const rooms = ['room:general', 'room:tech', 'room:random'];
    for (const room of rooms) {
      try {
        const roomHistory = await client.getHistory(room, { limit: 3 });
        console.log(`  ${room}: ${roomHistory.length} messages`);
        if (roomHistory.length > 0) {
          const lastMsg = roomHistory[roomHistory.length - 1];
          try {
            const data = JSON.parse(lastMsg.payload);
            console.log(`    Last: ${data.user}: ${data.message}`);
          } catch {
            console.log(`    Last: ${lastMsg.payload}`);
          }
        }
      } catch (err) {
        console.log(`  ${room}: No history available`);
      }
    }
    console.log();

    // Step 12: Cleanup (unsubscribe, close)
    console.log('12. Cleaning up...');
    await client.unsubscribe(subIdGeneral);
    await client.unsubscribe(subIdPattern);
    console.log('✓ Unsubscribed from all topics');
    await client.close();
    console.log('✓ Closed connection\n');

    console.log('=== Example completed successfully! ===\n');
  } catch (error) {
    console.error('Error during example:', error);
    // Try to close connection on error
    try {
      await client.close();
    } catch {}
    process.exit(1);
  }
}

// Run example if this file is executed directly
if (require.main === module) {
  pubsubChatExample().catch(console.error);
}

export { pubsubChatExample };