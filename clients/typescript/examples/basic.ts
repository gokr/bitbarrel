/**
 * BitBarrel TypeScript Client - Basic Usage Examples
 *
 * This file demonstrates how to use the BitBarrel TypeScript client library
 * to perform common operations.
 */

import { BitBarrelClient, createClient } from '../src/index';

async function basicExamples() {
  console.log('=== BitBarrel TypeScript Client Examples ===\n');

  // Example 1: Create a client and connect
  console.log('1. Creating client and connecting...');
  const client = new BitBarrelClient({
    host: 'localhost',
    port: 9876,
    autoConnect: true, // Automatically connect on first operation
  });

  // Or use the convenience function
  // const client = createClient('localhost', 9876);

  try {
    // Explicitly connect (optional if autoConnect is true)
    await client.connect();
    console.log('✓ Connected to BitBarrel server\n');

    // Example 2: Create and use a barrel
    console.log('2. Creating and using a barrel...');
    await client.createBarrel('myapp');
    console.log('✓ Created barrel "myapp"');

    await client.useBarrel('myapp');
    console.log('✓ Using barrel "myapp"\n');

    // Example 3: Basic CRUD operations
    console.log('3. Performing CRUD operations...');

    // Create (Set)
    await client.set('user:001', JSON.stringify({
      name: 'Alice',
      email: 'alice@example.com',
      age: 30,
    }));
    console.log('✓ Created user:001');

    await client.set('user:002', JSON.stringify({
      name: 'Bob',
      email: 'bob@example.com',
      age: 25,
    }));
    console.log('✓ Created user:002');

    // Read (Get)
    const user1 = await client.get('user:001');
    console.log('✓ Retrieved user:001:', user1);

    // Check existence
    const exists = await client.exists('user:001');
    console.log('✓ User:001 exists:', exists);

    // Update
    await client.set('user:001', JSON.stringify({
      name: 'Alice Smith',
      email: 'alice@example.com',
      age: 31,
    }));
    console.log('✓ Updated user:001');

    // Get with default value
    const user3 = await client.getOrDefault('user:003', 'default-user-data');
    console.log('✓ Retrieved user:003 (default):', user3);

    // Delete
    await client.delete('user:002');
    console.log('✓ Deleted user:002');

    // Count keys
    const count = await client.count();
    console.log(`✓ Total keys in barrel: ${count}\n`);

    // Example 4: List keys
    console.log('4. Listing keys...');
    const keys = await client.listKeys();
    console.log('✓ Keys in barrel:', keys.join(', '), '\n');

    // Example 5: Range queries (requires bmCritBit mode)
    console.log('5. Range queries...');

    // Note: These operations require the barrel to be in bmCritBit mode
    // which supports ordered traversal. For standard hash mode, these
    // will return errors or empty results.

    try {
      // Add some test data for range queries
      await client.set('product:001', 'Laptop');
      await client.set('product:002', 'Mouse');
      await client.set('product:003', 'Keyboard');
      await client.set('product:004', 'Monitor');

      // Range query
      const rangeResult = await client.rangeQuery('product:001', 'product:003');
      console.log(`✓ Range query returned ${rangeResult.items.length} items`);
      for (const [key, value] of rangeResult.items) {
        console.log(`  - ${key}: ${value}`);
      }

      // Prefix query
      const prefixResult = await client.prefixQuery('product:');
      console.log(`✓ Prefix query returned ${prefixResult.items.length} items\n`);

      // Count range
      const rangeCount = await client.rangeCount('product:001', 'product:003');
      console.log(`✓ Count in range: ${rangeCount}\n`);
    } catch (error) {
      console.log('✗ Range queries not supported (requires bmCritBit mode)\n');
    }

    // Example 6: Barrel management
    console.log('6. Barrel management...');

    // Create another barrel
    await client.createBarrel('logs');
    console.log('✓ Created barrel "logs"');

    // List all barrels
    const barrels = await client.listBarrels();
    console.log('✓ Available barrels:', barrels.join(', '));

    // Use different barrel
    await client.useBarrel('logs');
    console.log('✓ Switched to barrel "logs"');

    // Add data to logs barrel
    await client.set('error:001', 'Application error at 2024-01-01');
    await client.set('info:001', 'Server started at 2024-01-01');
    console.log('✓ Added log entries\n');

    // Example 7: Error handling
    console.log('7. Error handling...');
    try {
      // Try to get non-existent key
      await client.get('nonexistent');
    } catch (error) {
      console.log('✓ Caught expected error for non-existent key');
    }

    try {
      // Try operation without selecting a barrel
      await client.createBarrel('temp');
      await client.closeBarrel(); // Close current barrel
      await client.get('key'); // This should fail
    } catch (error) {
      console.log('✓ Caught expected error for no barrel selected');
    }

    // Example 8: Cleanup
    console.log('\n8. Cleanup...');
    await client.useBarrel('myapp'); // Switch back

    // Drop barrels
    await client.dropBarrel('logs');
    console.log('✓ Dropped barrel "logs"');

    // Close connection
    await client.close();
    console.log('✓ Closed connection\n');

  } catch (error) {
    console.error('Error:', error);
  }
}

// Run examples
basicExamples().catch(console.error);
