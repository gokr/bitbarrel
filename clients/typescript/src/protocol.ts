/**
 * BitBarrel TypeScript Client - Protocol Implementation
 *
 * This file implements the binary protocol encoding and decoding for communicating
 * with the BitBarrel server. All multi-byte integers use big-endian encoding.
 */

import { Command, ResponseStatus, MaxKeySize, MaxValueSize } from './types';
import { ProtocolError } from './errors';
import type {
  Request, Response, RangeRequest, PrefixRequest, RangeResponse,
  KeysResponse, TraverseRequest, TraverseResult,
  PubSubEvent, SubscriptionOptions, SubscriptionInfo,
  PresenceInfo, TopicInfo,
} from './types';
import type { PubSubMessageType } from './types';

export class Protocol {
  /**
   * Encode a request: [type:1][seq:4][keyLen:2][key:N][valLen:4][value:M]
   * Format: Command (1 byte) | Sequence (4 bytes) | Key Length (2 bytes) | Key (N bytes) | Value Length (4 bytes) | Value (M bytes)
   * All multi-byte integers are big-endian.
   */
  static encodeRequest(req: Request): Buffer {
    if (req.key.length > MaxKeySize) {
      throw new ProtocolError(`Key too large: ${req.key.length} bytes (max ${MaxKeySize})`);
    }
    if (req.value.length > MaxValueSize) {
      throw new ProtocolError(`Value too large: ${req.value.length} bytes (max ${MaxValueSize})`);
    }

    const keyLen = req.key.length;
    const valLen = req.value.length;
    const buffer = Buffer.allocUnsafe(1 + 4 + 2 + keyLen + 4 + valLen);

    let offset = 0;
    buffer.writeUInt8(req.command, offset++);
    buffer.writeUInt32BE(req.seq, offset);
    offset += 4;
    buffer.writeUInt16BE(keyLen, offset);
    offset += 2;
    buffer.write(req.key, offset);
    offset += keyLen;
    buffer.writeUInt32BE(valLen, offset);
    offset += 4;
    buffer.write(req.value, offset);

    return buffer;
  }

  /**
   * Decode a request from binary format
   */
  static decodeRequest(data: Buffer): Request {
    if (data.length < 11) {
      throw new ProtocolError(`Request too short: ${data.length} bytes (min 11)`);
    }

    let offset = 0;

    const cmdByte = data.readUInt8(offset++);
    const command = cmdByte as Command;

    const seq = data.readUInt32BE(offset);
    offset += 4;

    const keyLen = data.readUInt16BE(offset);
    offset += 2;
    if (keyLen > MaxKeySize) {
      throw new ProtocolError(`Key too large: ${keyLen} bytes (max ${MaxKeySize})`);
    }
    if (offset + keyLen > data.length) {
      throw new ProtocolError('Truncated request: key extends beyond buffer');
    }
    const key = data.toString('utf8', offset, offset + keyLen);
    offset += keyLen;

    if (offset + 4 > data.length) {
      throw new ProtocolError('Truncated request: missing value length');
    }
    const valLen = data.readUInt32BE(offset);
    offset += 4;
    if (valLen > MaxValueSize) {
      throw new ProtocolError(`Value too large: ${valLen} bytes (max ${MaxValueSize})`);
    }
    if (offset + valLen > data.length) {
      throw new ProtocolError('Truncated request: value extends beyond buffer');
    }
    const value = data.toString('utf8', offset, offset + valLen);

    return { command, seq, key, value };
  }

  /**
   * Encode a response: [status:1][seq:4][valLen:4][value:M]
   * Format: Status (1 byte) | Sequence (4 bytes) | Value Length (4 bytes) | Value (M bytes)
   * All multi-byte integers are big-endian.
   */
  static encodeResponse(resp: Response): Buffer {
    if (resp.value.length > MaxValueSize) {
      throw new ProtocolError(`Value too large: ${resp.value.length} bytes (max ${MaxValueSize})`);
    }

    const valLen = resp.value.length;
    const buffer = Buffer.allocUnsafe(1 + 4 + 4 + valLen);

    let offset = 0;
    buffer.writeUInt8(resp.status, offset++);
    buffer.writeUInt32BE(resp.seq, offset);
    offset += 4;
    buffer.writeUInt32BE(valLen, offset);
    offset += 4;
    if (valLen > 0) {
      buffer.write(resp.value, offset);
    }

    return buffer;
  }

  /**
   * Decode a response from binary format
   */
  static decodeResponse(data: Buffer): Response {
    if (data.length < 9) {
      throw new ProtocolError(`Response too short: ${data.length} bytes (min 9)`);
    }

    let offset = 0;

    const statusByte = data.readUInt8(offset++);
    const status = statusByte as ResponseStatus;

    const seq = data.readUInt32BE(offset);
    offset += 4;

    const valLen = data.readUInt32BE(offset);
    offset += 4;
    if (valLen > MaxValueSize) {
      throw new ProtocolError(`Value too large: ${valLen} bytes (max ${MaxValueSize})`);
    }
    if (offset + valLen > data.length) {
      throw new ProtocolError('Truncated response: value extends beyond buffer');
    }
    const value = valLen > 0 ? data.toString('utf8', offset, offset + valLen) : '';

    return { status, seq, value };
  }

  /**
   * Encode a range query request: [startKeyLen:2][startKey:N][endKeyLen:2][endKey:N][limit:4][cursorLen:2][cursor:M]
   */
  static encodeRangeRequest(req: RangeRequest): Buffer {
    const startKeyLen = req.startKey.length;
    const endKeyLen = req.endKey.length;
    const cursorLen = req.cursor.length;

    if (startKeyLen > MaxKeySize) {
      throw new ProtocolError(`Start key too large: ${startKeyLen} bytes`);
    }
    if (endKeyLen > MaxKeySize) {
      throw new ProtocolError(`End key too large: ${endKeyLen} bytes`);
    }
    if (cursorLen > MaxKeySize) {
      throw new ProtocolError(`Cursor too large: ${cursorLen} bytes`);
    }

    const buffer = Buffer.allocUnsafe(2 + startKeyLen + 2 + endKeyLen + 4 + 2 + cursorLen);

    let offset = 0;
    buffer.writeUInt16BE(startKeyLen, offset);
    offset += 2;
    buffer.write(req.startKey, offset);
    offset += startKeyLen;

    buffer.writeUInt16BE(endKeyLen, offset);
    offset += 2;
    buffer.write(req.endKey, offset);
    offset += endKeyLen;

    buffer.writeUInt32BE(req.limit, offset);
    offset += 4;

    buffer.writeUInt16BE(cursorLen, offset);
    offset += 2;
    buffer.write(req.cursor, offset);

    return buffer;
  }

  /**
   * Decode a range query request
   */
  static decodeRangeRequest(data: Buffer): RangeRequest {
    if (data.length < 10) {
      throw new ProtocolError(`Range request too short: ${data.length} bytes (min 10)`);
    }

    let offset = 0;

    const startKeyLen = data.readUInt16BE(offset);
    offset += 2;
    if (startKeyLen > MaxKeySize) {
      throw new ProtocolError(`Start key too large: ${startKeyLen} bytes`);
    }
    if (offset + startKeyLen > data.length) {
      throw new ProtocolError('Truncated range request: start key extends beyond buffer');
    }
    const startKey = data.toString('utf8', offset, offset + startKeyLen);
    offset += startKeyLen;

    if (offset + 2 > data.length) {
      throw new ProtocolError('Truncated range request: missing end key length');
    }
    const endKeyLen = data.readUInt16BE(offset);
    offset += 2;
    if (endKeyLen > MaxKeySize) {
      throw new ProtocolError(`End key too large: ${endKeyLen} bytes`);
    }
    if (offset + endKeyLen > data.length) {
      throw new ProtocolError('Truncated range request: end key extends beyond buffer');
    }
    const endKey = data.toString('utf8', offset, offset + endKeyLen);
    offset += endKeyLen;

    if (offset + 4 > data.length) {
      throw new ProtocolError('Truncated range request: missing limit');
    }
    const limit = data.readUInt32BE(offset);
    offset += 4;

    if (offset + 2 > data.length) {
      throw new ProtocolError('Truncated range request: missing cursor length');
    }
    const cursorLen = data.readUInt16BE(offset);
    offset += 2;
    if (cursorLen > MaxKeySize) {
      throw new ProtocolError(`Cursor too large: ${cursorLen} bytes`);
    }
    if (offset + cursorLen > data.length) {
      throw new ProtocolError('Truncated range request: cursor extends beyond buffer');
    }
    const cursor = cursorLen > 0 ? data.toString('utf8', offset, offset + cursorLen) : '';

    return { startKey, endKey, limit, cursor };
  }

  /**
   * Encode a prefix query request: [prefixLen:2][prefix:N][limit:4][cursorLen:2][cursor:M]
   */
  static encodePrefixRequest(req: PrefixRequest): Buffer {
    const prefixLen = req.prefix.length;
    const cursorLen = req.cursor.length;

    if (prefixLen > MaxKeySize) {
      throw new ProtocolError(`Prefix too large: ${prefixLen} bytes`);
    }
    if (cursorLen > MaxKeySize) {
      throw new ProtocolError(`Cursor too large: ${cursorLen} bytes`);
    }

    const buffer = Buffer.allocUnsafe(2 + prefixLen + 4 + 2 + cursorLen);

    let offset = 0;
    buffer.writeUInt16BE(prefixLen, offset);
    offset += 2;
    buffer.write(req.prefix, offset);
    offset += prefixLen;

    buffer.writeUInt32BE(req.limit, offset);
    offset += 4;

    buffer.writeUInt16BE(cursorLen, offset);
    offset += 2;
    buffer.write(req.cursor, offset);

    return buffer;
  }

  /**
   * Decode a prefix query request
   */
  static decodePrefixRequest(data: Buffer): PrefixRequest {
    if (data.length < 8) {
      throw new ProtocolError(`Prefix request too short: ${data.length} bytes (min 8)`);
    }

    let offset = 0;

    const prefixLen = data.readUInt16BE(offset);
    offset += 2;
    if (prefixLen > MaxKeySize) {
      throw new ProtocolError(`Prefix too large: ${prefixLen} bytes`);
    }
    if (offset + prefixLen > data.length) {
      throw new ProtocolError('Truncated prefix request: prefix extends beyond buffer');
    }
    const prefix = data.toString('utf8', offset, offset + prefixLen);
    offset += prefixLen;

    if (offset + 4 > data.length) {
      throw new ProtocolError('Truncated prefix request: missing limit');
    }
    const limit = data.readUInt32BE(offset);
    offset += 4;

    if (offset + 2 > data.length) {
      throw new ProtocolError('Truncated prefix request: missing cursor length');
    }
    const cursorLen = data.readUInt16BE(offset);
    offset += 2;
    if (cursorLen > MaxKeySize) {
      throw new ProtocolError(`Cursor too large: ${cursorLen} bytes`);
    }
    if (offset + cursorLen > data.length) {
      throw new ProtocolError('Truncated prefix request: cursor extends beyond buffer');
    }
    const cursor = cursorLen > 0 ? data.toString('utf8', offset, offset + cursorLen) : '';

    return { prefix, limit, cursor };
  }

  /**
   * Encode a range query response: [count:4][items...][hasMore:1][nextCursorLen:2][nextCursor:N]
   * Items format: [keyLen:2][key:N][valLen:4][val:M]
   */
  static encodeRangeResponse(resp: RangeResponse): Buffer {
    const itemCount = resp.items.length;
    const nextCursorLen = resp.nextCursor.length;

    // Calculate total size
    let totalSize = 4 + 1 + 2 + nextCursorLen; // count + hasMore + nextCursor
    for (const [key, value] of resp.items) {
      if (key.length > MaxKeySize) {
        throw new ProtocolError(`Key too large in response: ${key.length} bytes`);
      }
      if (value.length > MaxValueSize) {
        throw new ProtocolError(`Value too large in response: ${value.length} bytes`);
      }
      totalSize += 2 + key.length + 4 + value.length;
    }

    const buffer = Buffer.allocUnsafe(totalSize);

    let offset = 0;
    buffer.writeUInt32BE(itemCount, offset);
    offset += 4;

    for (const [key, value] of resp.items) {
      buffer.writeUInt16BE(key.length, offset);
      offset += 2;
      buffer.write(key, offset);
      offset += key.length;

      buffer.writeUInt32BE(value.length, offset);
      offset += 4;
      if (value.length > 0) {
        buffer.write(value, offset);
        offset += value.length;
      }
    }

    buffer.writeUInt8(resp.hasMore ? 1 : 0, offset++);
    buffer.writeUInt16BE(nextCursorLen, offset);
    offset += 2;
    if (nextCursorLen > 0) {
      buffer.write(resp.nextCursor, offset);
    }

    return buffer;
  }

  /**
   * Decode a range query response
   */
  static decodeRangeResponse(data: Buffer): RangeResponse {
    if (data.length < 7) {
      throw new ProtocolError(`Range response too short: ${data.length} bytes (min 7)`);
    }

    let offset = 0;

    const count = data.readUInt32BE(offset);
    offset += 4;

    const items: Array<[string, string]> = [];
    for (let i = 0; i < count; i++) {
      if (offset + 2 > data.length) {
        throw new ProtocolError('Truncated range response: missing key length');
      }
      const keyLen = data.readUInt16BE(offset);
      offset += 2;
      if (keyLen > MaxKeySize) {
        throw new ProtocolError(`Key too large in response: ${keyLen} bytes`);
      }
      if (offset + keyLen > data.length) {
        throw new ProtocolError('Truncated range response: key extends beyond buffer');
      }
      const key = data.toString('utf8', offset, offset + keyLen);
      offset += keyLen;

      if (offset + 4 > data.length) {
        throw new ProtocolError('Truncated range response: missing value length');
      }
      const valLen = data.readUInt32BE(offset);
      offset += 4;
      if (valLen > MaxValueSize) {
        throw new ProtocolError(`Value too large in response: ${valLen} bytes`);
      }
      if (offset + valLen > data.length) {
        throw new ProtocolError('Truncated range response: value extends beyond buffer');
      }
      const value = valLen > 0 ? data.toString('utf8', offset, offset + valLen) : '';
      offset += valLen;

      items.push([key, value]);
    }

    if (offset >= data.length) {
      throw new ProtocolError('Truncated range response: missing hasMore flag');
    }
    const hasMore = data.readUInt8(offset++) !== 0;

    if (offset + 2 > data.length) {
      throw new ProtocolError('Truncated range response: missing next cursor length');
    }
    const nextCursorLen = data.readUInt16BE(offset);
    offset += 2;
    if (nextCursorLen > MaxKeySize) {
      throw new ProtocolError(`Next cursor too large: ${nextCursorLen} bytes`);
    }
    if (offset + nextCursorLen > data.length) {
      throw new ProtocolError('Truncated range response: next cursor extends beyond buffer');
    }
    const nextCursor = nextCursorLen > 0 ? data.toString('utf8', offset, offset + nextCursorLen) : '';

    return { items, nextCursor, hasMore };
  }

  /**
   * Decode a keys-only response: [count:4][keys...][hasMore:1][nextCursorLen:2][nextCursor:N]
   * Each key: [keyLen:2][key:N]
   */
  static decodeKeysResponse(data: Buffer): KeysResponse {
    if (data.length < 7) {
      throw new ProtocolError(`Keys response too short: ${data.length} bytes (min 7)`);
    }

    let offset = 0;

    const count = data.readUInt32BE(offset);
    offset += 4;

    const keys: string[] = [];
    for (let i = 0; i < count; i++) {
      if (offset + 2 > data.length) {
        throw new ProtocolError('Truncated keys response: missing key length');
      }
      const keyLen = data.readUInt16BE(offset);
      offset += 2;
      if (keyLen > MaxKeySize) {
        throw new ProtocolError(`Key too large in response: ${keyLen} bytes`);
      }
      if (offset + keyLen > data.length) {
        throw new ProtocolError('Truncated keys response: key extends beyond buffer');
      }
      const key = data.toString('utf8', offset, offset + keyLen);
      offset += keyLen;
      keys.push(key);
    }

    if (offset >= data.length) {
      throw new ProtocolError('Truncated keys response: missing hasMore flag');
    }
    const hasMore = data.readUInt8(offset++) !== 0;

    if (offset + 2 > data.length) {
      throw new ProtocolError('Truncated keys response: missing next cursor length');
    }
    const nextCursorLen = data.readUInt16BE(offset);
    offset += 2;
    if (nextCursorLen > MaxKeySize) {
      throw new ProtocolError(`Next cursor too large: ${nextCursorLen} bytes`);
    }
    if (offset + nextCursorLen > data.length) {
      throw new ProtocolError('Truncated keys response: next cursor extends beyond buffer');
    }
    const nextCursor = nextCursorLen > 0 ? data.toString('utf8', offset, offset + nextCursorLen) : '';

    return { keys, nextCursor, hasMore };
  }

  /**
   * Encode a traverse request: [seq:4][keyLen:2][key:N][pathLen:2][path:N][options:1]
   */
  static encodeTraverseRequest(req: TraverseRequest): Buffer {
    const keyLen = req.key.length;
    const pathLen = req.pathSpec.length;

    if (keyLen > MaxKeySize) {
      throw new ProtocolError(`Key too large: ${keyLen} bytes`);
    }

    const buffer = Buffer.allocUnsafe(4 + 2 + keyLen + 2 + pathLen + 1);

    let offset = 0;
    buffer.writeUInt32BE(req.seq, offset);
    offset += 4;

    buffer.writeUInt16BE(keyLen, offset);
    offset += 2;
    buffer.write(req.key, offset);
    offset += keyLen;

    buffer.writeUInt16BE(pathLen, offset);
    offset += 2;
    buffer.write(req.pathSpec, offset);
    offset += pathLen;

    buffer.writeUInt8(req.options, offset);

    return buffer;
  }

  /**
   * Decode a traverse request
   */
  static decodeTraverseRequest(data: Buffer): TraverseRequest {
    if (data.length < 9) {
      throw new ProtocolError(`Traverse request too short: ${data.length} bytes (min 9)`);
    }

    let offset = 0;

    const seq = data.readUInt32BE(offset);
    offset += 4;

    const keyLen = data.readUInt16BE(offset);
    offset += 2;
    if (keyLen > MaxKeySize) {
      throw new ProtocolError(`Key too large: ${keyLen} bytes`);
    }
    if (offset + keyLen > data.length) {
      throw new ProtocolError('Truncated traverse request: key extends beyond buffer');
    }
    const key = data.toString('utf8', offset, offset + keyLen);
    offset += keyLen;

    if (offset + 2 > data.length) {
      throw new ProtocolError('Truncated traverse request: missing path length');
    }
    const pathLen = data.readUInt16BE(offset);
    offset += 2;
    if (offset + pathLen > data.length) {
      throw new ProtocolError('Truncated traverse request: path extends beyond buffer');
    }
    const pathSpec = data.toString('utf8', offset, offset + pathLen);
    offset += pathLen;

    if (offset >= data.length) {
      throw new ProtocolError('Truncated traverse request: missing options');
    }
    const options = data.readUInt8(offset);

    return { seq, key, pathSpec, options };
  }

  /**
   * Decode traverse results: [status:1][seq:4][count:4][results...]
   * Each result: [pathLen:2][path][valLen:4][value][extFlags:1][extLen:4][extData]
   */
  static decodeTraverseResults(data: Buffer): [number, number, TraverseResult[]] {
    if (data.length < 9) {
      throw new ProtocolError(`Traverse response too short: ${data.length} bytes (min 9)`);
    }

    let offset = 0;

    const status = data.readUInt8(offset++);
    const seq = data.readUInt32BE(offset);
    offset += 4;

    const count = data.readUInt32BE(offset);
    offset += 4;

    const results: TraverseResult[] = [];

    for (let i = 0; i < count; i++) {
      // Path length
      if (offset + 2 > data.length) {
        throw new ProtocolError('Truncated traverse response: missing path length');
      }
      const pathLen = data.readUInt16BE(offset);
      offset += 2;
      if (offset + pathLen > data.length) {
        throw new ProtocolError('Truncated traverse response: path extends beyond buffer');
      }
      const path = data.toString('utf8', offset, offset + pathLen);
      offset += pathLen;

      // Value length
      if (offset + 4 > data.length) {
        throw new ProtocolError('Truncated traverse response: missing value length');
      }
      const valLen = data.readUInt32BE(offset);
      offset += 4;
      let value = '';
      if (valLen > 0 && offset + valLen <= data.length) {
        value = data.toString('utf8', offset, offset + valLen);
        offset += valLen;
      }

      // Extracted data flag
      if (offset >= data.length) {
        throw new ProtocolError('Truncated traverse response: missing extracted flag');
      }
      const hasExtracted = data.readUInt8(offset++) !== 0;

      // Extracted data length
      if (offset + 4 > data.length) {
        throw new ProtocolError('Truncated traverse response: missing extracted length');
      }
      const extLen = data.readUInt32BE(offset);
      offset += 4;
      let extractedData = '';
      if (hasExtracted && extLen > 0 && offset + extLen <= data.length) {
        extractedData = data.toString('utf8', offset, offset + extLen);
        offset += extLen;
      }

      // Extract key from path (last element after -> if present)
      const key = path.includes('->') ? path.split('->').pop() || path : path;

      results.push({
        path,
        key,
        value,
        extractedData,
      });
    }

    return [status, seq, results];
  }

  /**
   * Utility methods for creating common request/response objects
   */
  static newRequest(command: Command, key = '', value = '', seq = 0): Request {
    return { command, seq, key, value };
  }

  static newResponse(status: ResponseStatus, seq: number, value = ''): Response {
    return { status, seq, value };
  }

  static okResponse(seq: number, value = ''): Response {
    return this.newResponse(ResponseStatus.Ok, seq, value);
  }

  static errorResponse(seq: number, message = ''): Response {
    return this.newResponse(ResponseStatus.Error, seq, message);
  }

  static notFoundResponse(seq: number, message = 'Not found'): Response {
    return this.newResponse(ResponseStatus.NotFound, seq, message);
  }

  // ============================================================================
  // Pub/Sub Encoding/Decoding
  // ============================================================================

  /**
   * Encode a subscribe request: [options:1][topicLen:2][topic][patternLen:2][pattern]
   */
  static encodeSubscribeRequest(
    topic: string,
    pattern: string,
    options: SubscriptionOptions
  ): Buffer {
    const topicLen = topic.length;
    const patternLen = pattern.length;
    const optsByte = this.encodeSubscriptionOptions(options);

    const buffer = Buffer.allocUnsafe(1 + 2 + topicLen + 2 + patternLen);

    let offset = 0;
    buffer.writeUInt8(optsByte, offset);
    offset += 1;

    buffer.writeUInt16BE(topicLen, offset);
    offset += 2;
    buffer.write(topic, offset);
    offset += topicLen;

    buffer.writeUInt16BE(patternLen, offset);
    offset += 2;
    buffer.write(pattern, offset);

    return buffer;
  }

  /**
   * Decode subscribe response (subscription ID)
   */
  static decodeSubscribeResponse(data: string): string {
    return data;
  }

  /**
   * Encode a publish request: [topicLen:2][topic][msgType:1][headersLen:4][headers][payloadLen:4][payload]
   */
  static encodePublishRequest(
    topic: string,
    msgType: PubSubMessageType,
    payload: string,
    headers: string
  ): Buffer {
    const topicLen = topic.length;
    const headersLen = headers.length;
    const payloadLen = payload.length;

    const buffer = Buffer.allocUnsafe(2 + topicLen + 1 + 4 + headersLen + 4 + payloadLen);

    let offset = 0;
    buffer.writeUInt16BE(topicLen, offset);
    offset += 2;
    buffer.write(topic, offset);
    offset += topicLen;

    buffer.writeUInt8(msgType, offset++);

    buffer.writeUInt32BE(headersLen, offset);
    offset += 4;
    buffer.write(headers, offset);
    offset += headersLen;

    buffer.writeUInt32BE(payloadLen, offset);
    offset += 4;
    buffer.write(payload, offset);

    return buffer;
  }

  /**
   * Decode publish response (sequence number)
   */
  static decodePublishResponse(data: string): number {
    const buffer = Buffer.from(data);
    if (buffer.length >= 8) {
      return Number(buffer.readBigUInt64BE(0));
    }
    return 0;
  }

  /**
   * Decode a PubSub event from server
   * Format: [cmd:1][msg_seq:4][topicLen:2][topic][msgType:1][seq:8][ts:8][headersLen:4][headers][payloadLen:4][payload]
   */
  static decodePubSubEvent(data: Buffer): PubSubEvent {
    if (data.length < 36) {
      throw new ProtocolError(`PubSub event too short: ${data.length} bytes (min 36)`);
    }

    let offset = 0;

    // Command (should be 0xFF)
    const cmd = data.readUInt8(offset++);
    if (cmd !== Command.PubSubEvent) {
      throw new ProtocolError(`Not a PubSub event: cmd=0x${cmd.toString(16)}`);
    }

    // Message sequence (4 bytes, for matching responses)
    offset += 4;

    // Topic
    const topicLen = data.readUInt16BE(offset);
    offset += 2;
    if (offset + topicLen > data.length) {
      throw new ProtocolError('Truncated PubSub event: topic extends beyond buffer');
    }
    const topic = data.toString('utf8', offset, offset + topicLen);
    offset += topicLen;

    // Message type
    const messageType = data.readUInt8(offset++) as PubSubMessageType;

    // Event sequence (8 bytes)
    const sequence = data.readBigUInt64BE(offset);
    offset += 8;

    // Timestamp (8 bytes)
    const timestamp = Number(data.readBigUInt64BE(offset));
    offset += 8;

    // Headers length (4 bytes)
    const headersLen = data.readUInt32BE(offset);
    offset += 4;
    let headers = '';
    if (headersLen > 0) {
      if (offset + headersLen > data.length) {
        throw new ProtocolError('Truncated PubSub event: headers extend beyond buffer');
      }
      headers = data.toString('utf8', offset, offset + headersLen);
      offset += headersLen;
    }

    // Payload length (4 bytes)
    const payloadLen = data.readUInt32BE(offset);
    offset += 4;
    let payload = '';
    if (payloadLen > 0) {
      if (offset + payloadLen > data.length) {
        throw new ProtocolError('Truncated PubSub event: payload extends beyond buffer');
      }
      payload = data.toString('utf8', offset, offset + payloadLen);
    }

    return { topic, messageType, sequence: Number(sequence), timestamp, headers, payload };
  }

  /**
   * Check if data is a PubSub event (command 0xFF)
   */
  static isPubSubEvent(data: Buffer): boolean {
    return data.length > 0 && data.readUInt8(0) === Command.PubSubEvent;
  }

  /**
   * Encode subscription options to a single byte
   */
  private static encodeSubscriptionOptions(options: SubscriptionOptions): number {
    let encoded = 0;
    if (options.enableKvEvents) encoded |= 0x01;
    if (options.enablePresence) encoded |= 0x02;
    if (options.replayHistory) encoded |= 0x04;
    return encoded;
  }

  // ============================================================================
  // Pub/Sub Phase 3-4 Query Methods
  // ============================================================================

  /**
   * Encode a history request: [topicLen:2][topic][count:4][sinceSeq:8]
   */
  static encodeHistoryRequest(topic: string, count: number, sinceSeq: number): Buffer {
    const topicLen = topic.length;
    const buffer = Buffer.allocUnsafe(2 + topicLen + 4 + 8);

    let offset = 0;
    buffer.writeUInt16BE(topicLen, offset);
    offset += 2;
    buffer.write(topic, offset);
    offset += topicLen;

    buffer.writeUInt32BE(count, offset);
    offset += 4;

    buffer.writeBigUInt64BE(BigInt(sinceSeq), offset);

    return buffer;
  }

  /**
   * Encode a presence request: [operation:1]
   * operation: 0 = get online, 1 = broadcast update
   */
  static encodePresenceRequest(operation: number): Buffer {
    const buffer = Buffer.allocUnsafe(1);
    buffer.writeUInt8(operation, 0);
    return buffer;
  }

  /**
   * Decode list subscribers response (JSON array)
   */
  static decodeListSubscribersResponse(data: string): SubscriptionInfo[] {
    if (!data || data.length === 0) {
      return [];
    }
    const parsed = JSON.parse(data);
    return parsed.map((item: any) => ({
      id: item.subscriptionId || item.id || '',
      topic: item.topic || '',
      pattern: item.pattern || '',
      clientId: item.clientId || 0,
    }));
  }

  /**
   * Decode list topics response (JSON array)
   */
  static decodeListTopicsResponse(data: string): TopicInfo[] {
    if (!data || data.length === 0) {
      return [];
    }
    const parsed = JSON.parse(data);
    return parsed.map((item: any) => ({
      name: item.name || '',
      sequence: item.sequence || 0,
      subscriberCount: item.subscriberCount || 0,
      messageCount: item.messageCount || 0,
    }));
  }

  /**
   * Decode history response (JSON array of PubSubEvent)
   */
  static decodeHistoryResponse(data: string): PubSubEvent[] {
    if (!data || data.length === 0) {
      return [];
    }
    const parsed = JSON.parse(data);
    return parsed.map((item: any) => {
      let payload = item.payload;
      if (payload && typeof payload === 'object') {
        payload = JSON.stringify(payload);
      }
      return {
        topic: item.topic || '',
        messageType: item.messageType ?? 0,
        sequence: item.sequence ?? 0,
        timestamp: item.timestamp ?? 0,
        headers: item.headers || '',
        payload: payload ?? '',
      };
    });
  }

  /**
   * Decode presence response (JSON array with topic and members)
   */
  static decodePresenceResponse(topic: string, data: string): PresenceInfo {
    if (!data || data.length === 0) {
      return { topic, members: [], lastUpdate: 0 };
    }
    const parsed = JSON.parse(data);
    const result = Array.isArray(parsed) ? parsed[0] : parsed;
    return {
      topic: result.topic || topic,
      lastUpdate: result.lastUpdate ?? 0,
      members: (result.members || []).map((member: any) => {
        let metadata = member.metadata || '';
        if (metadata && member.metadataBase64) {
          try {
            metadata = Buffer.from(member.metadata, 'base64').toString('utf8');
          } catch (e) {
            // Keep original if base64 decode fails
          }
        }
        return {
          clientId: member.clientId || 0,
          username: member.username || '',
          joinedAt: member.joinedAt ?? 0,
          lastPing: member.lastPing ?? 0,
          metadata,
        };
      }),
    };
  }
}
