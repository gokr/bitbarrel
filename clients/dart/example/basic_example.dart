import 'package:bitbarrel/bitbarrel.dart';

void main() async {
  final client = BitBarrelClient.localhost();

  try {
    print('Connecting to BitBarrel server...');
    await client.connect();
    print('Connected!');

    // Create a barrel
    print('\nCreating barrel: example_db');
    await client.createBarrel('example_db');

    // Use the barrel
    print('Using barrel: example_db');
    await client.useBarrel('example_db');

    // Store some data
    print('\nStoring data...');
    await client.set('user:alice', '{"name":"Alice","age":30}');
    print('Stored: user:alice');
    await client.set('user:bob', '{"name":"Bob","age":25}');
    print('Stored: user:bob');
    await client.set('user:charlie', '{"name":"Charlie","age":35}');
    print('Stored: user:charlie');

    // Retrieve data
    print('\nRetrieving user:alice...');
    final alice = await client.get('user:alice');
    print('Value: $alice');

    // Check if key exists
    print('\nChecking if user:alice exists...');
    final exists = await client.exists('user:alice');
    print('Exists: $exists');

    // Check if non-existent key exists
    print('\nChecking if user:dave exists...');
    final exists2 = await client.exists('user:dave');
    print('Exists: $exists2');

    // Count keys
    print('\nCounting keys...');
    final count = await client.count();
    print('Total keys: $count');

    // List all keys
    print('\nListing all keys...');
    final keys = await client.listKeys();
    print('Keys: $keys');

    // Prefix query
    print('\nPrefix query for "user:"...');
    var cursor = '';
    do {
      final result = await client.prefixQuery('user:', limit: 10, cursor: cursor);
      for (final item in result.items) {
        print('  ${item.key}: ${item.value}');
      }
      if (!result.hasMore) break;
      cursor = result.nextCursor;
    } while (true);

    // Ping the server
    print('\nPinging server...');
    await client.ping();
    print('Pong!');

    // Delete a key
    print('\nDeleting user:charlie...');
    await client.delete('user:charlie');
    print('Deleted!');

    // Verify deletion
    print('\nVerifying deletion...');
    final finalCount = await client.count();
    print('Total keys after deletion: $finalCount');

    // List all barrels
    print('\nListing all barrels...');
    await client.closeBarrel();
    final barrels = await client.listBarrels();
    print('Barrels: $barrels');

    print('\n=== Basic operations completed successfully ===');
  } on BitBarrelException catch (e) {
    print('BitBarrel error: $e');
  } catch (e) {
    print('Unexpected error: $e');
  } finally {
    await client.close();
    print('\nConnection closed.');
  }
}
