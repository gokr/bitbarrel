import 'dart:convert';
import 'package:bitbarrel/bitbarrel.dart';

Future<void> main() async {
  print('=== BitBarrel PubSub Chat Room Example (12-step pattern) ===\n');

  // Step 1: Connect to BitBarrel server (localhost:1337)
  print('1. Connecting to BitBarrel server...');
  final client = BitBarrelClient(host: 'localhost', port: 1337);
  await client.connect();
  print('✓ Connected to BitBarrel server\n');

  try {
    // Step 2: Setup chat storage barrel
    print('2. Setting up chat storage barrel...');
    try {
      await client.createBarrel('chat_storage', mode: BBMode.critbit);
      print('✓ Created chat_storage barrel (bmCritBit mode)');
    } on BitBarrelException {
      // Barrel might already exist
      print('✓ Using existing chat_storage barrel');
    }
    await client.useBarrel('chat_storage');
    print('✓ Using chat_storage barrel\n');

    // Step 3: Subscribe to "room:general" with options (history replay, presence)
    print('3. Subscribing to "room:general"...');
    final subscriptionOptions = SubscriptionOptions(
      replayHistory: true,
      trackPresence: true,
      pattern: false, // exact match
    );
    await client.subscribe('room:general', options: subscriptionOptions);
    print('✓ Subscribed to "room:general" with history replay and presence tracking\n');

    // Step 4: Publish 5 chat messages from 5 users
    print('4. Publishing 5 chat messages from 5 users...');
    final users = ['Alice', 'Bob', 'Charlie', 'Diana', 'Eve'];
    final messages = [
      'Hello everyone!',
      'How are you all doing?',
      'This chat system is great!',
      'Anyone working on interesting projects?',
      'Let\'s schedule a meetup next week.',
    ];

    for (int i = 0; i < 5; i++) {
      final user = users[i];
      final message = messages[i];
      final data = jsonEncode({
        'user': user,
        'message': message,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      await client.publish('room:general', data);
      print('  $user: $message');
      await Future.delayed(Duration(milliseconds: 100)); // Small delay
    }
    print('✓ Published 5 messages\n');

    // Step 5: Retrieve and display message history
    print('5. Retrieving message history...');
    final history = await client.getHistory('room:general', limit: 10);
    print('✓ Retrieved ${history.length} messages from history:');
    for (var i = 0; i < history.length; i++) {
      final msg = history[i];
      try {
        final data = jsonDecode(msg.data) as Map<String, dynamic>;
        print('  [${i + 1}] ${data['user']}: ${data['message']}');
      } catch (e) {
        print('  [${i + 1}] ${msg.data}');
      }
    }
    print();

    // Step 6: Subscribe to "room:*" pattern
    print('6. Subscribing to "room:*" pattern...');
    await client.subscribe('room:*', options: SubscriptionOptions(pattern: true));
    print('✓ Subscribed to "room:*" pattern\n');

    // Step 7: Publish to different rooms (tech, random)
    print('7. Publishing to different rooms...');
    final roomMessages = [
      {'room': 'room:tech', 'user': 'Alice', 'message': 'New TypeScript features are awesome!'},
      {'room': 'room:random', 'user': 'Bob', 'message': 'Random thought: pineapples on pizza?'},
    ];
    for (final rm in roomMessages) {
      final data = jsonEncode({
        'user': rm['user'],
        'message': rm['message'],
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      await client.publish(rm['room'] as String, data);
      print('  Published to ${rm['room']}: ${rm['user']}: ${rm['message']}');
    }
    print();

    // Step 8: Query subscribers in "room:general"
    print('8. Querying subscribers in "room:general"...');
    final subscribers = await client.listSubscribers('room:general');
    print('✓ Subscribers in "room:general": ${subscribers.length} subscribers');
    for (var i = 0; i < subscribers.length; i++) {
      print('  ${i + 1}. ${subscribers[i]}');
    }
    print();

    // Step 9: Check presence information
    print('9. Checking presence information...');
    final presence = await client.getPresence('room:general');
    print('✓ Presence information:');
    print('  Active subscribers: ${presence.activeSubscribers}');
    print('  Total messages: ${presence.totalMessages}');
    print('  Last activity: ${DateTime.fromMillisecondsSinceEpoch(presence.lastActivity).toLocal()}');
    print();

    // Step 10: Get history with sequence filtering (sinceSeq=3)
    print('10. Getting history since sequence 3...');
    final historySince3 = await client.getHistory('room:general', limit: 10, sinceSeq: 3);
    print('✓ Retrieved ${historySince3.length} messages since sequence 3:');
    for (final msg in historySince3) {
      try {
        final data = jsonDecode(msg.data) as Map<String, dynamic>;
        print('  [seq ${msg.sequence}] ${data['user']}: ${data['message']}');
      } catch (e) {
        print('  [seq ${msg.sequence}] ${msg.data}');
      }
    }
    print();

    // Step 11: Show history per room
    print('11. Showing history per room...');
    final rooms = ['room:general', 'room:tech', 'room:random'];
    for (final room in rooms) {
      try {
        final roomHistory = await client.getHistory(room, limit: 3);
        print('  $room: ${roomHistory.length} messages');
        if (roomHistory.isNotEmpty) {
          final lastMsg = roomHistory.last;
          try {
            final data = jsonDecode(lastMsg.data) as Map<String, dynamic>;
            print('    Last: ${data['user']}: ${data['message']}');
          } catch (e) {
            print('    Last: ${lastMsg.data}');
          }
        }
      } on BitBarrelException {
        print('  $room: No history available');
      }
    }
    print();

    // Step 12: Cleanup (unsubscribe, close)
    print('12. Cleaning up...');
    await client.unsubscribe('room:general');
    await client.unsubscribe('room:*');
    print('✓ Unsubscribed from all topics');
    await client.close();
    print('✓ Closed connection\n');

    print('=== Example completed successfully! ===\n');
  } on BitBarrelException catch (error) {
    print('BitBarrel error during example: $error');
    rethrow;
  } catch (error) {
    print('Unexpected error during example: $error');
    rethrow;
  } finally {
    await client.close();
  }
}