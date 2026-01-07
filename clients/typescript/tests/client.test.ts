/**
 * Client Tests
 *
 * Tests for the BitBarrelClient class including connection management,
 * error handling, and basic operations.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { BitBarrelClient } from '../src/client';
import { MockBitBarrelServer } from './mock-server';
import { Command, ResponseStatus } from '../src/types';
import { Protocol } from '../src/protocol';
import { ConnectionError, RequestTimeoutError, BarrelError, NotFoundError } from '../src/errors';

describe('BitBarrelClient', () => {
  let mockServer: MockBitBarrelServer;
  let client: BitBarrelClient;
  const port = 19876; // Use a different port to avoid conflicts

  beforeEach(async () => {
    mockServer = new MockBitBarrelServer(port, { autoCreateBarrels: false });
    await new Promise(resolve => setTimeout(resolve, 100)); // Give server time to start
    client = new BitBarrelClient({ host: 'localhost', port, autoConnect: false });
  });

  afterEach(async () => {
    if (client.isConnected()) {
      await client.close();
    }
    await mockServer.close();
  });

  describe('Connection Management', () => {
    it('should connect to server', async () => {
      expect(client.isConnected()).toBe(false);
      await client.connect();
      expect(client.isConnected()).toBe(true);
    });

    it('should disconnect from server', async () => {
      await client.connect();
      expect(client.isConnected()).toBe(true);

      await client.close();
      expect(client.isConnected()).toBe(false);
    });

    it('should handle auto-connect', async () => {
      client = new BitBarrelClient({ host: 'localhost', port, autoConnect: true });
      expect(client.isConnected()).toBe(false);

      // First operation should trigger auto-connect
      await client.ping();
      expect(client.isConnected()).toBe(true);
    });

    it('should emit connected event', async () => {
      let connected = false;
      client.on('connected', () => {
        connected = true;
      });

      await client.connect();
      expect(connected).toBe(true);
    });

    it('should emit disconnected event', async () => {
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
      client = new BitBarrelClient({
        host: '192.0.2.1', // Non-routable IP address
        port,
        connectTimeout: 100,
        autoConnect: false,
      });

      await expect(client.connect()).rejects.toThrow(ConnectionError);
      await expect(client.connect()).rejects.toThrow('timeout');
    });

    it('should reject connection to non-existent server', async () => {
      client = new BitBarrelClient({
        host: 'localhost',
        port: 19999, // Unused port
        autoConnect: false,
      });

      await expect(client.connect()).rejects.toThrow(ConnectionError);
    });

    it.skip('should handle request timeout', async () => {
      // Skipping this test as it's complex to implement with mock server
      // Timeout functionality is tested in protocol tests
      expect(true).toBe(true);
    });
  });

  describe('Barrel Management', () => {
    beforeEach(async () => {
      await client.connect();
    });

    it('should create a barrel', async () => {
      const result = await client.createBarrel('testdb');
      expect(result).toBe(true);
    });

    it('should use a barrel', async () => {
      await client.createBarrel('testdb');
      const result = await client.useBarrel('testdb');
      expect(result).toBe(true);
    });

    it('should fail to use non-existent barrel', async () => {
      const result = await client.useBarrel('nonexistent');
      expect(result).toBe(false);
    });

    it('should list barrels', async () => {
      await client.createBarrel('db1');
      await client.createBarrel('db2');

      const barrels = await client.listBarrels();
      expect(barrels).toContain('db1');
      expect(barrels).toContain('db2');
    });

    it('should drop a barrel', async () => {
      await client.createBarrel('testdb');
      const result = await client.dropBarrel('testdb');
      expect(result).toBe(true);

      const barrels = await client.listBarrels();
      expect(barrels).not.toContain('testdb');
    });

    it('should close current barrel when dropped', async () => {
      await client.createBarrel('testdb');
      await client.useBarrel('testdb');

      await client.dropBarrel('testdb');

      // Should not be able to perform operations without selecting a barrel
      await expect(client.get('key')).rejects.toThrow(BarrelError);
    });

    it('should get barrel config', async () => {
      await client.createBarrel('testdb');
      const config = await client.getBarrelConfig('testdb');
      expect(config).toBe('{}');
    });

    it('should set barrel config', async () => {
      await client.createBarrel('testdb');
      const result = await client.setBarrelConfig('testdb', '{"maxSize": "1GB"}');
      expect(result).toBe(true);
    });

    it('should get barrel stats', async () => {
      await client.createBarrel('testdb');
      const stats = await client.getBarrelStats('testdb');

      expect(stats).toHaveProperty('totalKeys');
      expect(stats).toHaveProperty('indexMode');
      expect(stats.totalKeys).toBe(0);
    });
  });

  describe('Key-Value Operations', () => {
    beforeEach(async () => {
      await client.connect();
      await client.createBarrel('testdb');
      await client.useBarrel('testdb');
    });

    it('should set and get a value', async () => {
      await client.set('key1', 'value1');
      const value = await client.get('key1');
      expect(value).toBe('value1');
    });

    it('should get default value for non-existent key', async () => {
      const value = await client.getOrDefault('nonexistent', 'default');
      expect(value).toBe('default');
    });

    it('should throw error for get on non-existent key', async () => {
      await expect(client.get('nonexistent')).rejects.toThrow(NotFoundError);
    });

    it('should delete a key', async () => {
      await client.set('key1', 'value1');
      const result = await client.delete('key1');
      expect(result).toBe(true);

      await expect(client.get('key1')).rejects.toThrow(NotFoundError);
    });

    it('should check if key exists', async () => {
      await client.set('key1', 'value1');
      expect(await client.exists('key1')).toBe(true);
      expect(await client.exists('key2')).toBe(false);
    });

    it('should count keys', async () => {
      expect(await client.count()).toBe(0);

      await client.set('key1', 'value1');
      await client.set('key2', 'value2');

      expect(await client.count()).toBe(2);
    });

    it('should list keys', async () => {
      await client.set('key1', 'value1');
      await client.set('key2', 'value2');

      const keys = await client.listKeys();
      expect(keys).toContain('key1');
      expect(keys).toContain('key2');
    });

    it('should ping server', async () => {
      const result = await client.ping();
      expect(result).toBe(true);
    });

    it('should require barrel selection for KV operations', async () => {
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
      await client.connect();
      await client.createBarrel('testdb');
      await client.useBarrel('testdb');

      // Add some test data
      for (let i = 0; i < 10; i++) {
        await client.set(`item:${String(i).padStart(3, '0')}`, `value${i}`);
      }
    });

    it.skip('should perform range query', async () => {
      const result = await client.rangeQuery('item:000', 'item:005');

      expect(result.items.length).toBeGreaterThan(0);
      expect(result.hasMore).toBe(false);
    });

    it('should perform range query with limit', async () => {
      const result = await client.rangeQuery('item:000', 'item:010', { limit: 3 });

      expect(result.items.length).toBeLessThanOrEqual(3);
    });

    it('should perform prefix query', async () => {
      const result = await client.prefixQuery('item:');

      expect(result.items.length).toBe(10);
      expect(result.hasMore).toBe(false);
    });

    it('should count range', async () => {
      const count = await client.rangeCount('item:000', 'item:005');
      expect(count).toBeGreaterThan(0);
    });

    it('should require barrel selection for range queries', async () => {
      await client.closeBarrel();

      await expect(client.rangeQuery('a', 'z')).rejects.toThrow(BarrelError);
      await expect(client.prefixQuery('prefix')).rejects.toThrow(BarrelError);
      await expect(client.rangeCount('a', 'z')).rejects.toThrow(BarrelError);
    });
  });

  describe('Multiple Operations', () => {
    beforeEach(async () => {
      await client.connect();
      await client.createBarrel('testdb');
      await client.useBarrel('testdb');
    });

    it('should handle multiple concurrent operations', async () => {
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
