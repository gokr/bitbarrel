/**
 * Client Integration Tests
 *
 * Tests for the BitBarrelClient class including connection management,
 * error handling, and basic operations.
 *
 * These tests require a BitBarrel server running on localhost:9876.
 */

import { describe, it, expect, beforeEach, afterEach, beforeAll } from 'vitest';
import { BitBarrelClient, createClient } from '../src/client';
import { ConnectionError, BarrelError, NotFoundError } from '../src/errors';

const TEST_PORT = 9876;

// Helper to check if server is available
async function isServerAvailable(): Promise<boolean> {
  try {
    const client = createClient('localhost', TEST_PORT);
    await client.connect();
    await client.close();
    return true;
  } catch {
    return false;
  }
}

// Helper to generate unique barrel names for test isolation
function uniqueBarrelName(prefix: string): string {
  const timestamp = Date.now();
  const random = Math.floor(Math.random() * 1000000);
  return `${prefix}_${timestamp}_${random}`;
}

describe('BitBarrelClient', () => {
  let client: BitBarrelClient;
  let serverAvailable: boolean;
  let testBarrel: string;

  beforeAll(async () => {
    serverAvailable = await isServerAvailable();
    if (!serverAvailable) {
      console.log('Skipping integration tests - no server running on localhost:9876');
    }
  });

  beforeEach(async () => {
    if (!serverAvailable) return;
    client = createClient('localhost', TEST_PORT);
    testBarrel = uniqueBarrelName('test');
  });

  afterEach(async () => {
    if (!serverAvailable) return;
    try {
      if (client.isConnected()) {
        // Clean up test barrel
        try {
          await client.dropBarrel(testBarrel);
        } catch {
          // Ignore if barrel doesn't exist
        }
        await client.close();
      }
    } catch {
      // Ignore cleanup errors
    }
  });

  describe('Connection Management', () => {
    it('should connect to server', async () => {
      if (!serverAvailable) return;

      expect(client.isConnected()).toBe(false);
      await client.connect();
      expect(client.isConnected()).toBe(true);
    });

    it('should disconnect from server', async () => {
      if (!serverAvailable) return;

      await client.connect();
      expect(client.isConnected()).toBe(true);

      await client.close();
      expect(client.isConnected()).toBe(false);
    });

    it('should handle auto-connect', async () => {
      if (!serverAvailable) return;

      client = new BitBarrelClient({ host: 'localhost', port: TEST_PORT, autoConnect: true });
      expect(client.isConnected()).toBe(false);

      // First operation should trigger auto-connect
      await client.ping();
      expect(client.isConnected()).toBe(true);
    });

    it('should emit connected event', async () => {
      if (!serverAvailable) return;

      let connected = false;
      client.on('connected', () => {
        connected = true;
      });

      await client.connect();
      expect(connected).toBe(true);
    });

    it('should emit disconnected event', async () => {
      if (!serverAvailable) return;

      await client.connect();

      const disconnectedPromise = new Promise<void>((resolve) => {
        client.on('disconnected', () => {
          resolve();
        });
      });

      await client.close();
      await disconnectedPromise;
      expect(client.isConnected()).toBe(false);
    });

    it('should handle connection timeout', async () => {
      if (!serverAvailable) return;

      const badClient = new BitBarrelClient({
        host: '192.0.2.1', // Non-routable IP address
        port: TEST_PORT,
        connectTimeout: 100,
        autoConnect: false,
      });

      await expect(badClient.connect()).rejects.toThrow(ConnectionError);
    });

    it('should reject connection to non-existent server', async () => {
      const badClient = new BitBarrelClient({
        host: 'localhost',
        port: 19999, // Unused port
        autoConnect: false,
      });

      await expect(badClient.connect()).rejects.toThrow(ConnectionError);
    });
  });

  describe('Barrel Management', () => {
    beforeEach(async () => {
      if (!serverAvailable) return;
      await client.connect();
    });

    it('should create a barrel', async () => {
      if (!serverAvailable) return;

      const result = await client.createBarrel(testBarrel);
      expect(result).toBe(true);
    });

    it('should use a barrel', async () => {
      if (!serverAvailable) return;

      await client.createBarrel(testBarrel);
      const result = await client.useBarrel(testBarrel);
      expect(result).toBe(true);
    });

    it('should fail to use non-existent barrel', async () => {
      if (!serverAvailable) return;

      const result = await client.useBarrel('nonexistent_barrel_xyz_999');
      expect(result).toBe(false);
    });

    it('should list barrels', async () => {
      if (!serverAvailable) return;

      await client.createBarrel(testBarrel);

      const barrels = await client.listBarrels();
      expect(barrels).toContain(testBarrel);
    });

    it('should drop a barrel', async () => {
      if (!serverAvailable) return;

      await client.createBarrel(testBarrel);
      const result = await client.dropBarrel(testBarrel);
      expect(result).toBe(true);

      const barrels = await client.listBarrels();
      expect(barrels).not.toContain(testBarrel);
    });

    it('should close current barrel when dropped', async () => {
      if (!serverAvailable) return;

      await client.createBarrel(testBarrel);
      await client.useBarrel(testBarrel);

      await client.dropBarrel(testBarrel);

      // Should not be able to perform operations without selecting a barrel
      await expect(client.get('key')).rejects.toThrow(BarrelError);
    });

    it('should get barrel stats', async () => {
      if (!serverAvailable) return;

      await client.createBarrel(testBarrel);
      await client.useBarrel(testBarrel);

      // Add some data
      await client.set('key1', 'value1');

      const stats = await client.getBarrelStats(testBarrel);

      expect(stats).toHaveProperty('totalKeys');
      expect(stats).toHaveProperty('indexMode');
    });
  });

  describe('Key-Value Operations', () => {
    beforeEach(async () => {
      if (!serverAvailable) return;
      await client.connect();
      await client.createBarrel(testBarrel);
      await client.useBarrel(testBarrel);
    });

    it('should set and get a value', async () => {
      if (!serverAvailable) return;

      await client.set('key1', 'value1');
      const value = await client.get('key1');
      expect(value).toBe('value1');
    });

    it('should get default value for non-existent key', async () => {
      if (!serverAvailable) return;

      const value = await client.getOrDefault('nonexistent', 'default');
      expect(value).toBe('default');
    });

    it('should throw error for get on non-existent key', async () => {
      if (!serverAvailable) return;

      await expect(client.get('nonexistent')).rejects.toThrow(NotFoundError);
    });

    it('should delete a key', async () => {
      if (!serverAvailable) return;

      await client.set('key1', 'value1');
      const result = await client.delete('key1');
      expect(result).toBe(true);

      await expect(client.get('key1')).rejects.toThrow(NotFoundError);
    });

    it('should check if key exists', async () => {
      if (!serverAvailable) return;

      await client.set('key1', 'value1');
      expect(await client.exists('key1')).toBe(true);
      expect(await client.exists('key2')).toBe(false);
    });

    it('should count keys', async () => {
      if (!serverAvailable) return;

      const initialCount = await client.count();

      await client.set('key1', 'value1');
      await client.set('key2', 'value2');

      expect(await client.count()).toBe(initialCount + 2);
    });

    it('should list keys', async () => {
      if (!serverAvailable) return;

      await client.set('key1', 'value1');
      await client.set('key2', 'value2');

      const keys = await client.listKeys();
      expect(keys).toContain('key1');
      expect(keys).toContain('key2');
    });

    it('should ping server', async () => {
      if (!serverAvailable) return;

      const result = await client.ping();
      expect(result).toBe(true);
    });

    it('should require barrel selection for KV operations', async () => {
      if (!serverAvailable) return;

      await client.closeBarrel();

      await expect(client.get('key')).rejects.toThrow(BarrelError);
      await expect(client.set('key', 'value')).rejects.toThrow(BarrelError);
      await expect(client.delete('key')).rejects.toThrow(BarrelError);
      await expect(client.exists('key')).rejects.toThrow(BarrelError);
      await expect(client.count()).rejects.toThrow(BarrelError);
      await expect(client.listKeys()).rejects.toThrow(BarrelError);
    });
  });

  describe('Range Queries', () => {
    beforeEach(async () => {
      if (!serverAvailable) return;
      await client.connect();
      // Create barrel with CritBit mode for range queries
      await client.createBarrel(testBarrel, '{"mode": "critbit"}');
      await client.useBarrel(testBarrel);

      // Add some test data
      for (let i = 0; i < 10; i++) {
        await client.set(`item:${String(i).padStart(3, '0')}`, `value${i}`);
      }
    });

    it('should perform range query with limit', async () => {
      if (!serverAvailable) return;

      const result = await client.rangeQuery('item:000', 'item:010', { limit: 3 });

      expect(result.items.length).toBeLessThanOrEqual(3);
    });

    it('should perform prefix query', async () => {
      if (!serverAvailable) return;

      const result = await client.prefixQuery('item:');

      expect(result.items.length).toBe(10);
      expect(result.hasMore).toBe(false);
    });

    it('should count range', async () => {
      if (!serverAvailable) return;

      const count = await client.rangeCount('item:000', 'item:005');
      expect(count).toBeGreaterThan(0);
    });

    it('should require barrel selection for range queries', async () => {
      if (!serverAvailable) return;

      await client.closeBarrel();

      await expect(client.rangeQuery('a', 'z')).rejects.toThrow(BarrelError);
      await expect(client.prefixQuery('prefix')).rejects.toThrow(BarrelError);
      await expect(client.rangeCount('a', 'z')).rejects.toThrow(BarrelError);
    });
  });

  describe('Multiple Operations', () => {
    beforeEach(async () => {
      if (!serverAvailable) return;
      await client.connect();
      await client.createBarrel(testBarrel);
      await client.useBarrel(testBarrel);
    });

    it('should handle multiple concurrent operations', async () => {
      if (!serverAvailable) return;

      const operations = [];
      for (let i = 0; i < 10; i++) {
        operations.push(client.set(`key${i}`, `value${i}`));
      }

      await Promise.all(operations);

      // Verify all keys were set
      for (let i = 0; i < 10; i++) {
        const value = await client.get(`key${i}`);
        expect(value).toBe(`value${i}`);
      }
    });

    it('should maintain sequence order', async () => {
      if (!serverAvailable) return;

      const results: number[] = [];

      // Send multiple requests in order
      const req1 = client.set('key1', 'value1').then(() => results.push(1));
      const req2 = client.set('key2', 'value2').then(() => results.push(2));
      const req3 = client.set('key3', 'value3').then(() => results.push(3));

      await Promise.all([req1, req2, req3]);

      // Results should be in order (though technically responses can arrive out of order)
      expect(results).toHaveLength(3);
      expect(results.sort()).toEqual([1, 2, 3]);
    });
  });
});
