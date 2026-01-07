/**
 * Protocol Encoding/Decoding Tests
 *
 * Tests for the binary protocol implementation to ensure correct
 * encoding and decoding of requests and responses.
 */

import { describe, it, expect } from 'vitest';
import { Protocol } from '../src/protocol';
import { Command, ResponseStatus } from '../src/types';
import { ProtocolError } from '../src/errors';

describe('Protocol', () => {
  describe('Request Encoding/Decoding', () => {
    it('should encode and decode a basic request', () => {
      const original = {
        command: Command.Get as Command,
        seq: 42,
        key: 'test_key',
        value: '',
      };

      const encoded = Protocol.encodeRequest(original);
      const decoded = Protocol.decodeRequest(encoded);

      expect(decoded.command).toBe(original.command);
      expect(decoded.seq).toBe(original.seq);
      expect(decoded.key).toBe(original.key);
      expect(decoded.value).toBe(original.value);
    });

    it('should encode and decode a request with value', () => {
      const original = {
        command: Command.Set as Command,
        seq: 123,
        key: 'mykey',
        value: 'myvalue',
      };

      const encoded = Protocol.encodeRequest(original);
      const decoded = Protocol.decodeRequest(encoded);

      expect(decoded.command).toBe(original.command);
      expect(decoded.seq).toBe(original.seq);
      expect(decoded.key).toBe(original.key);
      expect(decoded.value).toBe(original.value);
    });

    it('should handle empty key and value', () => {
      const original = {
        command: Command.Count as Command,
        seq: 0,
        key: '',
        value: '',
      };

      const encoded = Protocol.encodeRequest(original);
      const decoded = Protocol.decodeRequest(encoded);

      expect(decoded.command).toBe(original.command);
      expect(decoded.seq).toBe(original.seq);
      expect(decoded.key).toBe('');
      expect(decoded.value).toBe('');
    });

    it('should handle all command types', () => {
      const commands = [
        Command.Get,
        Command.Set,
        Command.Delete,
        Command.Exists,
        Command.Count,
        Command.ListKeys,
        Command.CreateBarrel,
        Command.RangeQuery,
        Command.PrefixQuery,
      ];

      for (const cmd of commands) {
        const request = {
          command: cmd,
          seq: Math.floor(Math.random() * 1000),
          key: `key_for_${cmd}`,
          value: cmd === Command.Set ? `value_for_${cmd}` : '',
        };

        const encoded = Protocol.encodeRequest(request);
        const decoded = Protocol.decodeRequest(encoded);

        expect(decoded.command).toBe(cmd);
        expect(decoded.seq).toBe(request.seq);
        expect(decoded.key).toBe(request.key);
        expect(decoded.value).toBe(request.value);
      }
    });

    it('should throw error for key exceeding max size', () => {
      const largeKey = 'x'.repeat(65536); // 64KB + 1
      const request = {
        command: Command.Get as Command,
        seq: 1,
        key: largeKey,
        value: '',
      };

      expect(() => Protocol.encodeRequest(request)).toThrow(ProtocolError);
      expect(() => Protocol.encodeRequest(request)).toThrow('Key too large');
    });

    it('should throw error for value exceeding max size', () => {
      const largeValue = 'x'.repeat(32 * 1024 * 1024 + 1); // 32MB + 1
      const request = {
        command: Command.Set as Command,
        seq: 1,
        key: 'test',
        value: largeValue,
      };

      expect(() => Protocol.encodeRequest(request)).toThrow(ProtocolError);
      expect(() => Protocol.encodeRequest(request)).toThrow('Value too large');
    });

    it('should throw error for truncated request', () => {
      const request = {
        command: Command.Get as Command,
        seq: 1,
        key: 'test',
        value: '',
      };

      const encoded = Protocol.encodeRequest(request);
      const truncated = encoded.slice(0, encoded.length - 5); // Remove last 5 bytes

      expect(() => Protocol.decodeRequest(truncated)).toThrow(ProtocolError);
    });
  });

  describe('Response Encoding/Decoding', () => {
    it('should encode and decode a basic response', () => {
      const original = {
        status: ResponseStatus.Ok as ResponseStatus,
        seq: 42,
        value: 'test_value',
      };

      const encoded = Protocol.encodeResponse(original);
      const decoded = Protocol.decodeResponse(encoded);

      expect(decoded.status).toBe(original.status);
      expect(decoded.seq).toBe(original.seq);
      expect(decoded.value).toBe(original.value);
    });

    it('should handle error response', () => {
      const original = {
        status: ResponseStatus.Error as ResponseStatus,
        seq: 123,
        value: 'Something went wrong',
      };

      const encoded = Protocol.encodeResponse(original);
      const decoded = Protocol.decodeResponse(encoded);

      expect(decoded.status).toBe(original.status);
      expect(decoded.seq).toBe(original.seq);
      expect(decoded.value).toBe(original.value);
    });

    it('should handle not found response', () => {
      const original = {
        status: ResponseStatus.NotFound as ResponseStatus,
        seq: 456,
        value: '',
      };

      const encoded = Protocol.encodeResponse(original);
      const decoded = Protocol.decodeResponse(encoded);

      expect(decoded.status).toBe(original.status);
      expect(decoded.seq).toBe(original.seq);
      expect(decoded.value).toBe('');
    });

    it('should handle all status types', () => {
      const statuses = [
        ResponseStatus.Ok,
        ResponseStatus.NotFound,
        ResponseStatus.Error,
        ResponseStatus.Invalid,
        ResponseStatus.NoBarrel,
        ResponseStatus.BarrelExists,
        ResponseStatus.BarrelNotFound,
        ResponseStatus.Unauthorized,
      ];

      for (const status of statuses) {
        const response = {
          status,
          seq: Math.floor(Math.random() * 1000),
          value: status === ResponseStatus.Ok ? 'success' : 'error message',
        };

        const encoded = Protocol.encodeResponse(response);
        const decoded = Protocol.decodeResponse(encoded);

        expect(decoded.status).toBe(status);
        expect(decoded.seq).toBe(response.seq);
        expect(decoded.value).toBe(response.value);
      }
    });

    it('should throw error for truncated response', () => {
      const response = {
        status: ResponseStatus.Ok as ResponseStatus,
        seq: 1,
        value: 'test',
      };

      const encoded = Protocol.encodeResponse(response);
      const truncated = encoded.slice(0, encoded.length - 3); // Remove last 3 bytes

      expect(() => Protocol.decodeResponse(truncated)).toThrow(ProtocolError);
    });
  });

  describe('Range Request Encoding/Decoding', () => {
    it('should encode and decode a range request', () => {
      const original = {
        startKey: 'user:0001',
        endKey: 'user:1000',
        limit: 100,
        cursor: '',
      };

      const encoded = Protocol.encodeRangeRequest(original);
      const decoded = Protocol.decodeRangeRequest(encoded);

      expect(decoded.startKey).toBe(original.startKey);
      expect(decoded.endKey).toBe(original.endKey);
      expect(decoded.limit).toBe(original.limit);
      expect(decoded.cursor).toBe(original.cursor);
    });

    it('should handle range request with cursor', () => {
      const original = {
        startKey: 'item:100',
        endKey: 'item:999',
        limit: 50,
        cursor: 'item:150',
      };

      const encoded = Protocol.encodeRangeRequest(original);
      const decoded = Protocol.decodeRangeRequest(encoded);

      expect(decoded).toEqual(original);
    });

    it('should throw error for oversized keys', () => {
      const largeKey = 'x'.repeat(65536);
      const request = {
        startKey: largeKey,
        endKey: 'test',
        limit: 100,
        cursor: '',
      };

      expect(() => Protocol.encodeRangeRequest(request)).toThrow(ProtocolError);
    });
  });

  describe('Prefix Request Encoding/Decoding', () => {
    it('should encode and decode a prefix request', () => {
      const original = {
        prefix: 'user:',
        limit: 100,
        cursor: '',
      };

      const encoded = Protocol.encodePrefixRequest(original);
      const decoded = Protocol.decodePrefixRequest(encoded);

      expect(decoded.prefix).toBe(original.prefix);
      expect(decoded.limit).toBe(original.limit);
      expect(decoded.cursor).toBe(original.cursor);
    });

    it('should handle prefix request with cursor', () => {
      const original = {
        prefix: 'product:',
        limit: 25,
        cursor: 'product:456',
      };

      const encoded = Protocol.encodePrefixRequest(original);
      const decoded = Protocol.decodePrefixRequest(encoded);

      expect(decoded).toEqual(original);
    });
  });

  describe('Range Response Encoding/Decoding', () => {
    it('should encode and decode an empty range response', () => {
      const original = {
        items: [],
        nextCursor: '',
        hasMore: false,
      };

      const encoded = Protocol.encodeRangeResponse(original);
      const decoded = Protocol.decodeRangeResponse(encoded);

      expect(decoded.items).toEqual([]);
      expect(decoded.nextCursor).toBe('');
      expect(decoded.hasMore).toBe(false);
    });

    it('should encode and decode a range response with items', () => {
      const original = {
        items: [
          ['key1', 'value1'],
          ['key2', 'value2'],
          ['key3', 'value3'],
        ],
        nextCursor: 'key3',
        hasMore: true,
      };

      const encoded = Protocol.encodeRangeResponse(original);
      const decoded = Protocol.decodeRangeResponse(encoded);

      expect(decoded.items).toEqual(original.items);
      expect(decoded.nextCursor).toBe(original.nextCursor);
      expect(decoded.hasMore).toBe(true);
    });

    it('should handle range response with empty values', () => {
      const original = {
        items: [
          ['tombstone1', ''],
          ['tombstone2', ''],
        ],
        nextCursor: '',
        hasMore: false,
      };

      const encoded = Protocol.encodeRangeResponse(original);
      const decoded = Protocol.decodeRangeResponse(encoded);

      expect(decoded.items).toEqual(original.items);
    });
  });

  describe('Utility Methods', () => {
    it('should create a new request with defaults', () => {
      const req = Protocol.newRequest(Command.Get);

      expect(req.command).toBe(Command.Get);
      expect(req.seq).toBe(0);
      expect(req.key).toBe('');
      expect(req.value).toBe('');
    });

    it('should create a new request with parameters', () => {
      const req = Protocol.newRequest(Command.Set, 'key', 'value', 42);

      expect(req.command).toBe(Command.Set);
      expect(req.seq).toBe(42);
      expect(req.key).toBe('key');
      expect(req.value).toBe('value');
    });

    it('should create an OK response', () => {
      const resp = Protocol.okResponse(1, 'success');

      expect(resp.status).toBe(ResponseStatus.Ok);
      expect(resp.seq).toBe(1);
      expect(resp.value).toBe('success');
    });

    it('should create an error response', () => {
      const resp = Protocol.errorResponse(2, 'error message');

      expect(resp.status).toBe(ResponseStatus.Error);
      expect(resp.seq).toBe(2);
      expect(resp.value).toBe('error message');
    });
  });

  describe('Big-Endian Encoding Verification', () => {
    it('should use big-endian for sequence numbers', () => {
      const req = Protocol.newRequest(Command.Get, 'key', '', 0x12345678);
      const encoded = Protocol.encodeRequest(req);

      // Check that the sequence number is big-endian
      expect(encoded[1]).toBe(0x12);
      expect(encoded[2]).toBe(0x34);
      expect(encoded[3]).toBe(0x56);
      expect(encoded[4]).toBe(0x78);
    });

    it('should use big-endian for lengths', () => {
      const req = Protocol.newRequest(Command.Set, 'key', 'value', 1);
      const encoded = Protocol.encodeRequest(req);

      // Key length at offset 5-6 (should be 3)
      expect(encoded[5]).toBe(0x00);
      expect(encoded[6]).toBe(0x03);

      // Value length at offset 9-12
      const valLenOffset = 5 + 2 + 3; // offset + keyLen bytes + key
      expect(encoded[valLenOffset]).toBe(0x00); // 5 = length of 'value'
      expect(encoded[valLenOffset + 1]).toBe(0x00);
      expect(encoded[valLenOffset + 2]).toBe(0x00);
      expect(encoded[valLenOffset + 3]).toBe(0x05);
    });
  });
});
