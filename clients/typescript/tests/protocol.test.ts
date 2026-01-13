/**
 * Protocol Encoding/Decoding Tests
 *
 * Tests for the binary protocol implementation to ensure correct
 * encoding and decoding of requests and responses.
 */

import { describe, it, expect } from 'vitest';
import { Protocol } from '../src/protocol';
import { Command, ResponseStatus, PubSubMessageType } from '../src/types';
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

  // ============================================================================
  // Pub/Sub Tests
  // ============================================================================

  describe('Pub/Sub Command Constants', () => {
    it('should have correct command values', () => {
      expect(Command.Subscribe).toBe(0x40);
      expect(Command.Unsubscribe).toBe(0x41);
      expect(Command.Publish).toBe(0x42);
      expect(Command.ListSubscribers).toBe(0x43);
      expect(Command.History).toBe(0x44);
      expect(Command.ListTopics).toBe(0x45);
      expect(Command.Presence).toBe(0x46);
      expect(Command.PubSubEvent).toBe(0xFF);
    });
  });

  describe('Pub/Sub Message Type Constants', () => {
    it('should have correct message type values', () => {
      expect(PubSubMessageType.Data).toBe(0);
      expect(PubSubMessageType.Presence).toBe(1);
    });
  });

  describe('Subscribe Request Encoding', () => {
    it('should encode simple subscription', () => {
      const encoded = Protocol['encodeSubscribeRequest'](
        'updates',
        '',
        { enableKvEvents: false, enablePresence: false, replayHistory: false }
      );

      expect(encoded.length).toBe(1 + 2 + 7 + 2 + 0); // options + topicLen + topic(7) + patternLen + pattern
      expect(encoded.readUInt8(0)).toBe(0); // options byte at start
    });

    it('should encode subscription with all options', () => {
      const encoded = Protocol['encodeSubscribeRequest'](
        'chat',
        '',
        { enableKvEvents: true, enablePresence: true, replayHistory: true }
      );

      const optsByte = encoded.readUInt8(0);
      expect(optsByte).toBe(0x01 | 0x02 | 0x04); // All flags set
    });

    it('should encode pattern subscription', () => {
      const encoded = Protocol['encodeSubscribeRequest'](
        '',
        'news:*',
        { enableKvEvents: false, enablePresence: false, replayHistory: false }
      );

      expect(encoded.length).toBe(1 + 2 + 0 + 2 + 6);
    });

    it('should decode subscribe response', () => {
      const subId = 'sub-abc-123';
      const result = Protocol.decodeSubscribeResponse(subId);
      expect(result).toBe(subId);
    });

    it('should decode empty subscribe response', () => {
      const result = Protocol.decodeSubscribeResponse('');
      expect(result).toBe('');
    });
  });

  describe('Publish Request Encoding', () => {
    it('should encode simple data message', () => {
      const encoded = Protocol.encodePublishRequest('updates', PubSubMessageType.Data, 'hello', '');

      let offset = 0;
      const topicLen = encoded.readUInt16BE(offset);
      offset += 2;
      expect(topicLen).toBe(7);
      expect(encoded.toString('utf8', offset, offset + topicLen)).toBe('updates');
      offset += topicLen;

      const msgType = encoded.readUInt8(offset++);
      expect(msgType).toBe(PubSubMessageType.Data);

      const headersLen = encoded.readUInt32BE(offset);
      offset += 4;
      expect(headersLen).toBe(0);

      const payloadLen = encoded.readUInt32BE(offset);
      offset += 4;
      expect(payloadLen).toBe(5);
    });

    it('should encode message with headers', () => {
      const encoded = Protocol.encodePublishRequest(
        'events',
        PubSubMessageType.Data,
        'data',
        '{"type":"msg"}'
      );

      let offset = 0;
      // Skip topic
      const topicLen = encoded.readUInt16BE(offset);
      offset += 2 + topicLen;
      // Skip msgType
      offset++;
      // Check headersLen (should be 4 bytes and value 14)
      const headersLen = encoded.readUInt32BE(offset);
      offset += 4;
      expect(headersLen).toBe(14); // length of '{"type":"msg"}'
    });

    it('should decode publish response', () => {
      // The publish response contains an 8-byte big-endian sequence number
      // For testing, we create a buffer with the raw bytes and convert to string
      // In real scenario, WebSocket delivers these bytes into the response string
      const buf = new Uint8Array([0, 0, 0, 0, 0, 0, 0, 123]); // big-endian 123
      // Create string from the binary data (how WebSocket would deliver it)
      const dataString = Buffer.from(buf).toString('binary');
      const result = Protocol.decodePublishResponse(dataString);
      expect(result).toBe(123);
    });
  });

  describe('PubSub Event Decoding', () => {
    it('should decode simple data event', () => {
      const buf = Buffer.allocUnsafe(1 + 4 + 2 + 7 + 1 + 8 + 8 + 4 + 0 + 4 + 5);
      let offset = 0;
      buf.writeUInt8(Command.PubSubEvent, offset++);
      buf.writeUInt32BE(0, offset); // msg_seq for response matching
      offset += 4;
      buf.writeUInt16BE(7, offset);
      offset += 2;
      buf.write('updates', offset);
      offset += 7;
      buf.writeUInt8(PubSubMessageType.Data, offset++);
      buf.writeBigUInt64BE(BigInt(100), offset);
      offset += 8;
      buf.writeBigUInt64BE(BigInt(1234567890), offset);
      offset += 8;
      buf.writeUInt32BE(0, offset);
      offset += 4;
      buf.writeUInt32BE(5, offset);
      offset += 4;
      buf.write('hello', offset);

      const result = Protocol.decodePubSubEvent(buf);

      expect(result.topic).toBe('updates');
      expect(result.messageType).toBe(PubSubMessageType.Data);
      expect(result.sequence).toBe(100);
      expect(result.timestamp).toBe(1234567890);
      expect(result.headers).toBe('');
      expect(result.payload).toBe('hello');
    });

    it('should decode event with headers', () => {
      const headers = '{"type":"msg"}';
      const payload = 'data';
      const buf = Buffer.allocUnsafe(1 + 4 + 2 + 6 + 1 + 8 + 8 + 4 + headers.length + 4 + payload.length);
      let offset = 0;
      buf.writeUInt8(Command.PubSubEvent, offset++);
      buf.writeUInt32BE(0, offset);
      offset += 4;
      buf.writeUInt16BE(6, offset);
      offset += 2;
      buf.write('events', offset);
      offset += 6;
      buf.writeUInt8(PubSubMessageType.Data, offset++);
      buf.writeBigUInt64BE(BigInt(200), offset);
      offset += 8;
      buf.writeBigUInt64BE(BigInt(1234567900), offset);
      offset += 8;
      buf.writeUInt32BE(headers.length, offset);
      offset += 4;
      buf.write(headers, offset);
      offset += headers.length;
      buf.writeUInt32BE(payload.length, offset);
      offset += 4;
      buf.write(payload, offset);

      const result = Protocol.decodePubSubEvent(buf);

      expect(result.topic).toBe('events');
      expect(result.headers).toBe(headers);
      expect(result.payload).toBe(payload);
    });

    it('should decode presence event', () => {
      const buf = Buffer.allocUnsafe(1 + 4 + 2 + 8 + 1 + 8 + 8 + 4 + 0 + 4 + 2);
      let offset = 0;
      buf.writeUInt8(Command.PubSubEvent, offset++);
      buf.writeUInt32BE(0, offset);
      offset += 4;
      buf.writeUInt16BE(8, offset);
      offset += 2;
      buf.write('presence', offset);
      offset += 8;
      buf.writeUInt8(PubSubMessageType.Presence, offset++);
      buf.writeBigUInt64BE(BigInt(789), offset);
      offset += 8;
      buf.writeBigUInt64BE(BigInt(1234567910), offset);
      offset += 8;
      buf.writeUInt32BE(0, offset);
      offset += 4;
      buf.writeUInt32BE(2, offset);
      offset += 4;
      buf.write('{}', offset);

      const result = Protocol.decodePubSubEvent(buf);

      expect(result.topic).toBe('presence');
      expect(result.messageType).toBe(PubSubMessageType.Presence);
      expect(result.sequence).toBe(789);
      expect(result.payload).toBe('{}');
    });

    it('should throw error for truncated event', () => {
      const shortBuf = Buffer.from([Command.PubSubEvent]);
      expect(() => Protocol.decodePubSubEvent(shortBuf)).toThrow(ProtocolError);
    });

    it('should throw error for non-event data', () => {
      const buf = Buffer.from([0x01, 0x00]); // Not a PubSub event
      expect(() => Protocol.decodePubSubEvent(buf)).toThrow(ProtocolError);
    });
  });

  describe('IsPubSubEvent Check', () => {
    it('should identify PubSub events', () => {
      const eventBuf = Buffer.from([Command.PubSubEvent, 0x01, 0x02]);
      expect(Protocol.isPubSubEvent(eventBuf)).toBe(true);
    });

    it('should reject non-PubSub data', () => {
      const buf = Buffer.from([Command.Get, 0x00]);
      expect(Protocol.isPubSubEvent(buf)).toBe(false);
    });

    it('should handle empty buffer', () => {
      expect(Protocol.isPubSubEvent(Buffer.alloc(0))).toBe(false);
    });
  });

  describe('History Request Encoding', () => {
    it('should encode default history request', () => {
      const encoded = Protocol.encodeHistoryRequest('updates', 100, 0);

      let offset = 0;
      const topicLen = encoded.readUInt16BE(offset);
      offset += 2;
      expect(topicLen).toBe(7);
      expect(encoded.toString('utf8', offset, offset + topicLen)).toBe('updates');
      offset += topicLen;

      const count = encoded.readUInt32BE(offset);
      offset += 4;
      expect(count).toBe(100);

      const sinceSeq = encoded.readBigUInt64BE(offset);
      expect(Number(sinceSeq)).toBe(0);
    });

    it('should encode history request with since sequence', () => {
      const encoded = Protocol.encodeHistoryRequest('chat', 50, 1000);

      let offset = 0;
      offset += 2 + 4; // skip topic
      offset += 4; // skip count
      const sinceSeq = encoded.readBigUInt64BE(offset);
      expect(Number(sinceSeq)).toBe(1000);
    });

    it('should encode empty topic', () => {
      const encoded = Protocol.encodeHistoryRequest('', 10, 0);

      const topicLen = encoded.readUInt16BE(0);
      expect(topicLen).toBe(0);
    });
  });

  describe('Presence Request Encoding', () => {
    it('should encode get online operation', () => {
      const encoded = Protocol.encodePresenceRequest(0);
      expect(encoded.length).toBe(1);
      expect(encoded.readUInt8(0)).toBe(0);
    });

    it('should encode broadcast update operation', () => {
      const encoded = Protocol.encodePresenceRequest(1);
      expect(encoded.length).toBe(1);
      expect(encoded.readUInt8(0)).toBe(1);
    });
  });

  describe('Decoders - List Subscribers', () => {
    it('should decode empty response', () => {
      const result = Protocol.decodeListSubscribersResponse('');
      expect(result).toEqual([]);
    });

    it('should decode single subscriber', () => {
      const json = '[{"subscriptionId":"sub-1","clientId":123,"topic":"updates","pattern":""}]';
      const result = Protocol.decodeListSubscribersResponse(json);

      expect(result).toHaveLength(1);
      expect(result[0].id).toBe('sub-1');
      expect(result[0].topic).toBe('updates');
      expect(result[0].pattern).toBe('');
      expect(result[0].clientId).toBe(123);
    });

    it('should decode multiple subscribers', () => {
      const json = '[{"subscriptionId":"sub-1","clientId":100,"topic":"chat","pattern":""},{"subscriptionId":"sub-2","clientId":200,"topic":"notifications","pattern":""}]';
      const result = Protocol.decodeListSubscribersResponse(json);

      expect(result).toHaveLength(2);
      expect(result[0].clientId).toBe(100);
      expect(result[1].clientId).toBe(200);
    });

    it('should decode pattern subscriptions', () => {
      const json = '[{"subscriptionId":"sub-1","clientId":50,"topic":"","pattern":"events:*"}]';
      const result = Protocol.decodeListSubscribersResponse(json);

      expect(result).toHaveLength(1);
      expect(result[0].pattern).toBe('events:*');
    });

    it('should handle legacy id field', () => {
      const json = '[{"id":"sub-legacy","topic":"test","pattern":"","clientId":1}]';
      const result = Protocol.decodeListSubscribersResponse(json);

      expect(result[0].id).toBe('sub-legacy');
    });
  });

  describe('Decoders - List Topics', () => {
    it('should decode empty response', () => {
      const result = Protocol.decodeListTopicsResponse('');
      expect(result).toEqual([]);
    });

    it('should decode single topic', () => {
      const json = '[{"name":"updates","sequence":100,"subscriberCount":5,"messageCount":20}]';
      const result = Protocol.decodeListTopicsResponse(json);

      expect(result).toHaveLength(1);
      expect(result[0].name).toBe('updates');
      expect(result[0].sequence).toBe(100);
      expect(result[0].subscriberCount).toBe(5);
      expect(result[0].messageCount).toBe(20);
    });

    it('should decode multiple topics', () => {
      const json = '[{"name":"chat","sequence":200,"subscriberCount":10,"messageCount":100},{"name":"notifications","sequence":50,"subscriberCount":3,"messageCount":15}]';
      const result = Protocol.decodeListTopicsResponse(json);

      expect(result).toHaveLength(2);
      expect(result[0].name).toBe('chat');
      expect(result[1].name).toBe('notifications');
    });

    it('should decode topic with zero counts', () => {
      const json = '[{"name":"empty","sequence":0,"subscriberCount":0,"messageCount":0}]';
      const result = Protocol.decodeListTopicsResponse(json);

      expect(result[0].sequence).toBe(0);
      expect(result[0].subscriberCount).toBe(0);
      expect(result[0].messageCount).toBe(0);
    });
  });

  describe('Decoders - History Response', () => {
    it('should decode empty response', () => {
      const result = Protocol.decodeHistoryResponse('');
      expect(result).toEqual([]);
    });

    it('should decode single data message', () => {
      const json = '[{"topic":"updates","messageType":0,"sequence":100,"timestamp":1234567890,"headers":"","payload":"hello"}]';
      const result = Protocol.decodeHistoryResponse(json);

      expect(result).toHaveLength(1);
      expect(result[0].topic).toBe('updates');
      expect(result[0].messageType).toBe(PubSubMessageType.Data);
      expect(result[0].sequence).toBe(100);
      expect(result[0].payload).toBe('hello');
    });

    it('should decode multiple messages', () => {
      const json = '[{"topic":"chat","messageType":0,"sequence":1,"timestamp":1234567800,"headers":"","payload":"msg1"},{"topic":"chat","messageType":0,"sequence":2,"timestamp":1234567900,"headers":"","payload":"msg2"}]';
      const result = Protocol.decodeHistoryResponse(json);

      expect(result).toHaveLength(2);
      expect(result[0].payload).toBe('msg1');
      expect(result[1].payload).toBe('msg2');
    });

    it('should serialize object payload to JSON string', () => {
      const json = '[{"topic":"events","messageType":0,"sequence":10,"timestamp":1234567890,"headers":"","payload":{"type":"action"}}]';
      const result = Protocol.decodeHistoryResponse(json);

      expect(result[0].payload).toBe('{"type":"action"}');
    });

    it('should decode presence message', () => {
      const json = '[{"topic":"presence","messageType":1,"sequence":5,"timestamp":1234567890,"headers":"","payload":"user_joined"}]';
      const result = Protocol.decodeHistoryResponse(json);

      expect(result[0].messageType).toBe(PubSubMessageType.Presence);
      expect(result[0].payload).toBe('user_joined');
    });
  });

  describe('Decoders - Presence Response', () => {
    it('should decode empty response', () => {
      const result = Protocol.decodePresenceResponse('chat', '');
      expect(result.topic).toBe('chat');
      expect(result.members).toEqual([]);
      expect(result.lastUpdate).toBe(0);
    });

    it('should decode single member', () => {
      const json = '[{"topic":"chat","members":[{"clientId":100,"username":"alice","joinedAt":1234567890,"lastPing":1234567900}],"lastUpdate":1234567910}]';
      const result = Protocol.decodePresenceResponse('chat', json);

      expect(result.topic).toBe('chat');
      expect(result.members).toHaveLength(1);
      expect(result.members[0].clientId).toBe(100);
      expect(result.members[0].username).toBe('alice');
      expect(result.members[0].joinedAt).toBe(1234567890);
      expect(result.members[0].lastPing).toBe(1234567900);
      expect(result.lastUpdate).toBe(1234567910);
    });

    it('should decode multiple members', () => {
      const json = '[{"topic":"chat","members":[{"clientId":100,"username":"alice","joinedAt":100,"lastPing":200},{"clientId":200,"username":"bob","joinedAt":150,"lastPing":250}],"lastUpdate":300}]';
      const result = Protocol.decodePresenceResponse('chat', json);

      expect(result.members).toHaveLength(2);
      expect(result.members[0].username).toBe('alice');
      expect(result.members[1].username).toBe('bob');
    });

    it('should decode member with metadata', () => {
      const memberStr = 'eyJuYW1lIjoiYWxpY2UifQ=='; // base64 of {"name":"alice"}
      const json = `[{"topic":"chat","members":[{"clientId":100,"username":"alice","joinedAt":100,"lastPing":200,"metadata":"${memberStr}"}],"lastUpdate":300}]`;
      const result = Protocol.decodePresenceResponse('chat', json);

      // Base64 decoding is handled in the decoder
      expect(result.members[0].clientId).toBe(100);
      expect(result.members[0].username).toBe('alice');
    });

    it('should use topic from data when available', () => {
      const json = '[{"topic":"different","members":[],"lastUpdate":0}]';
      const result = Protocol.decodePresenceResponse('chat', json);

      expect(result.topic).toBe('different');
    });
  });
});
