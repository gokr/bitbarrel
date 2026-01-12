/**
 * BitBarrel TypeScript Client - Main Client Implementation
 *
 * This file contains the BitBarrelClient class which provides a high-level
 * API for interacting with BitBarrel servers via WebSocket connections.
 */

import { WebSocket } from 'ws';
import { EventEmitter } from 'events';
import type {
  ClientConfig, Request, Response, RangeRequest, PrefixRequest,
  TraverseRequest, TraverseResult, TraverseOptions, BarrelStats,
  PubSubEvent, SubscriptionOptions, SubscriptionInfo,
  PresenceMember, PresenceInfo, HistoryRequest,
} from './types';
import { Command as Cmd, ResponseStatus as Resp, defaultConfig, normalizeRangeOptions, defaultSubscriptionOptions } from './types';
import { Protocol } from './protocol';
import { BitBarrelError, ConnectionError, RequestTimeoutError, BarrelError, NotFoundError } from './errors';
import type { PubSubMessageType } from './types';

export interface BitBarrelClientEvents {
  connected: () => void;
  disconnected: () => void;
  error: (error: Error) => void;
  pubsub: (event: PubSubEvent) => void;
}

export declare interface BitBarrelClient {
  on<U extends keyof BitBarrelClientEvents>(
    event: U,
    listener: BitBarrelClientEvents[U]
  ): this;

  emit<U extends keyof BitBarrelClientEvents>(
    event: U,
    ...args: Parameters<BitBarrelClientEvents[U]>
  ): boolean;
}

export class BitBarrelClient extends EventEmitter {
  private config: Required<ClientConfig>;
  private ws: WebSocket | null = null;
  private connected = false;
  private seqCounter = 0;
  private currentBarrel = '';
  private pendingRequests = new Map<number, {
    resolve: (value: Response) => void;
    reject: (error: Error) => void;
    timer: NodeJS.Timeout;
  }>();
  private messageBuffer: Buffer[] = [];
  private isProcessing = false;
  // Pub/Sub support
  private subscriptions = new Map<string, SubscriptionInfo>();
  private onMessage: ((event: PubSubEvent) => void) | null = null;

  constructor(config: ClientConfig | string = 'localhost', port?: number, token?: string) {
    super();

    if (typeof config === 'string') {
      this.config = {
        ...defaultConfig(),
        host: config,
        port: port ?? 9876,
        token: token ?? '',
      };
    } else {
      this.config = {
        ...defaultConfig(),
        ...config,
      };
    }
  }

  // Connection Management

  async connect(): Promise<void> {
    if (this.isConnected()) {
      return;
    }

    const wsUrl = this.config.token
      ? `ws://${this.config.host}:${this.config.port}/ws?token=${encodeURIComponent(this.config.token)}`
      : `ws://${this.config.host}:${this.config.port}/ws`;

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new ConnectionError(`Connection timeout after ${this.config.connectTimeout}ms`));
      }, this.config.connectTimeout);

      this.ws = new WebSocket(wsUrl);

      this.ws.on('open', () => {
        clearTimeout(timeout);
        this.connected = true;
        this.setupMessageHandler();
        this.emit('connected');
        resolve();
      });

      this.ws.on('error', (error) => {
        clearTimeout(timeout);
        reject(new ConnectionError(`Failed to connect: ${error.message}`));
      });

      this.ws.on('close', () => {
        this.connected = false;
        this.currentBarrel = '';

        // Reject all pending requests
        for (const [_, pending] of this.pendingRequests) {
          pending.reject(new ConnectionError('Connection closed'));
        }
        this.pendingRequests.clear();

        this.emit('disconnected');
      });
    });
  }

  async close(): Promise<void> {
    if (this.ws && this.connected) {
      this.ws.close();
      this.ws = null;
      this.connected = false;
      this.currentBarrel = '';

      // Reject all pending requests
      for (const [_, pending] of this.pendingRequests) {
        pending.reject(new ConnectionError('Connection closed'));
      }
      this.pendingRequests.clear();

      // Clear message buffer
      this.messageBuffer = [];
      this.isProcessing = false;
    }
  }

  isConnected(): boolean {
    return this.connected && this.ws?.readyState === WebSocket.OPEN;
  }

  // Message Handling

  private setupMessageHandler(): void {
    if (!this.ws) return;

    this.ws.on('message', (data: Buffer) => {
      this.messageBuffer.push(data);
      this.processMessages().catch((error) => {
        this.emit('error', error);
      });
    });
  }

  private async processMessages(): Promise<void> {
    if (this.isProcessing) return;
    this.isProcessing = true;

    try {
      while (this.messageBuffer.length > 0) {
        const data = this.messageBuffer.shift()!;

        // Check if this is a PubSub event (command 0xFF)
        if (Protocol.isPubSubEvent(data)) {
          try {
            const event = Protocol.decodePubSubEvent(data);

            // Call message handler if set
            if (this.onMessage) {
              this.onMessage(event);
            }

            // Also emit event for listeners
            this.emit('pubsub', event);
          } catch (error) {
            this.emit('error', new BitBarrelError(`Failed to decode PubSub event: ${error instanceof Error ? error.message : String(error)}`));
          }
          continue;
        }

        // Skip text messages (e.g., welcome message)
        const firstByte = data[0];
        if (firstByte >= 0x20 && firstByte <= 0x7E) {
          // This is likely a text message, skip it
          continue;
        }

        try {
          const response = Protocol.decodeResponse(data);
          const pending = this.pendingRequests.get(response.seq);

          if (pending) {
            clearTimeout(pending.timer);
            this.pendingRequests.delete(response.seq);
            pending.resolve(response);
          } else {
            // Unsolicited response, ignore or log
            this.emit('error', new BitBarrelError(`Unsolicited response with seq ${response.seq}`));
          }
        } catch (error) {
          this.emit('error', new BitBarrelError(`Failed to decode message: ${error instanceof Error ? error.message : String(error)}`));
        }
      }
    } finally {
      this.isProcessing = false;
    }
  }

  // Request/Response Handling

  private async sendAndWait(request: Request): Promise<Response> {
    if (!this.isConnected()) {
      if (this.config.autoConnect) {
        await this.connect();
      } else {
        throw new ConnectionError('Not connected to server');
      }
    }

    const seq = this.seqCounter++;
    request.seq = seq;

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingRequests.delete(seq);
        reject(new RequestTimeoutError(`Request timeout after ${this.config.requestTimeout}ms`));
      }, this.config.requestTimeout);

      this.pendingRequests.set(seq, { resolve, reject, timer });

      try {
        const encoded = Protocol.encodeRequest(request);
        this.ws!.send(encoded);
      } catch (error) {
        clearTimeout(timer);
        this.pendingRequests.delete(seq);
        reject(new BitBarrelError(`Failed to send request: ${error instanceof Error ? error.message : String(error)}`));
      }
    });
  }

  // Barrel Management

  private checkBarrelSelected(): void {
    if (!this.currentBarrel) {
      throw new BarrelError('No barrel selected. Call useBarrel() first.');
    }
  }

  async createBarrel(name: string, config = ''): Promise<boolean> {
    const req = Protocol.newRequest(Cmd.CreateBarrel, name, config);
    const resp = await this.sendAndWait(req);
    return resp.status === Resp.Ok;
  }

  async openBarrel(name: string): Promise<boolean> {
    const req = Protocol.newRequest(Cmd.OpenBarrel, name);
    const resp = await this.sendAndWait(req);
    return resp.status === Resp.Ok;
  }

  async useBarrel(name: string): Promise<boolean> {
    const req = Protocol.newRequest(Cmd.UseBarrel, name);
    const resp = await this.sendAndWait(req);

    if (resp.status === Resp.Ok) {
      this.currentBarrel = name;
      return true;
    }
    return false;
  }

  async closeBarrel(): Promise<boolean> {
    const req = Protocol.newRequest(Cmd.CloseBarrel);
    const resp = await this.sendAndWait(req);

    if (resp.status === Resp.Ok) {
      this.currentBarrel = '';
      return true;
    }
    return false;
  }

  async listBarrels(): Promise<string[]> {
    const req = Protocol.newRequest(Cmd.ListBarrels);
    const resp = await this.sendAndWait(req);

    if (resp.status === Resp.Ok && resp.value.length > 0) {
      return resp.value.split(',');
    }
    return [];
  }

  async dropBarrel(name: string): Promise<boolean> {
    const req = Protocol.newRequest(Cmd.DropBarrel, name);
    const resp = await this.sendAndWait(req);

    if (resp.status === Resp.Ok) {
      if (name === this.currentBarrel) {
        this.currentBarrel = '';
      }
      return true;
    }
    return false;
  }

  async getBarrelConfig(name: string): Promise<string> {
    const req = Protocol.newRequest(Cmd.GetBarrelConfig, name);
    const resp = await this.sendAndWait(req);

    if (resp.status === Resp.BarrelNotFound) {
      throw new BarrelError(`Barrel not found: ${name}`);
    } else if (resp.status !== Resp.Ok) {
      throw new BarrelError(`Get barrel config failed: ${resp.status}`);
    }

    return resp.value;
  }

  async setBarrelConfig(name: string, config: string): Promise<boolean> {
    const req = Protocol.newRequest(Cmd.SetBarrelConfig, name, config);
    const resp = await this.sendAndWait(req);

    if (resp.status === Resp.BarrelNotFound) {
      throw new BarrelError(`Barrel not found: ${name}`);
    } else if (resp.status !== Resp.Ok) {
      throw new BarrelError(`Set barrel config failed: ${resp.status}`);
    }

    return true;
  }

  async getBarrelStats(name: string): Promise<BarrelStats> {
    const req = Protocol.newRequest(Cmd.GetBarrelStats, name);
    const resp = await this.sendAndWait(req);

    if (resp.status !== Resp.Ok) {
      throw new BarrelError(`Get barrel stats failed: ${resp.status}`);
    }

    return JSON.parse(resp.value) as BarrelStats;
  }

  // Key-Value Operations

  async get(key: string): Promise<string> {
    this.checkBarrelSelected();

    const req = Protocol.newRequest(Cmd.Get, key);
    const resp = await this.sendAndWait(req);

    if (resp.status === Resp.NotFound) {
      throw new NotFoundError(`Key not found: ${key}`);
    } else if (resp.status !== Resp.Ok) {
      throw new BitBarrelError(`GET failed: ${resp.status}`);
    }

    return resp.value;
  }

  async getOrDefault(key: string, defaultValue = ''): Promise<string> {
    try {
      return await this.get(key);
    } catch (error) {
      if (error instanceof NotFoundError) {
        return defaultValue;
      }
      throw error;
    }
  }

  async set(key: string, value: string): Promise<boolean> {
    this.checkBarrelSelected();

    const req = Protocol.newRequest(Cmd.Set, key, value);
    const resp = await this.sendAndWait(req);
    return resp.status === Resp.Ok;
  }

  async delete(key: string): Promise<boolean> {
    this.checkBarrelSelected();

    const req = Protocol.newRequest(Cmd.Delete, key);
    const resp = await this.sendAndWait(req);
    return resp.status === Resp.Ok;
  }

  async exists(key: string): Promise<boolean> {
    this.checkBarrelSelected();

    const req = Protocol.newRequest(Cmd.Exists, key);
    const resp = await this.sendAndWait(req);
    return resp.status === Resp.Ok && resp.value === 'true';
  }

  async count(): Promise<number> {
    this.checkBarrelSelected();

    const req = Protocol.newRequest(Cmd.Count);
    const resp = await this.sendAndWait(req);

    if (resp.status === Resp.Ok) {
      const count = parseInt(resp.value, 10);
      if (isNaN(count)) {
        throw new BitBarrelError('Invalid count response');
      }
      return count;
    }
    return 0;
  }

  async listKeys(): Promise<string[]> {
    this.checkBarrelSelected();

    const req = Protocol.newRequest(Cmd.ListKeys);
    const resp = await this.sendAndWait(req);

    if (resp.status === Resp.Ok && resp.value.length > 0) {
      return resp.value.split(',');
    }
    return [];
  }

  async ping(): Promise<boolean> {
    const req = Protocol.newRequest(Cmd.Ping);
    const resp = await this.sendAndWait(req);
    return resp.status === Resp.Ok;
  }

  // Range Queries (require bmCritBit mode)

  async rangeQuery(
    startKey: string,
    endKey: string,
    options?: { limit?: number; cursor?: string }
  ): Promise<{ items: Array<[string, string]>; nextCursor: string; hasMore: boolean }> {
    this.checkBarrelSelected();

    const opts = normalizeRangeOptions(options);

    const rangePayload: RangeRequest = {
      startKey,
      endKey,
      limit: opts.limit,
      cursor: opts.cursor,
    };

    const rangeData = Protocol.encodeRangeRequest(rangePayload).toString('base64');
    const req = Protocol.newRequest(Cmd.RangeQuery, '', rangeData);
    const resp = await this.sendAndWait(req);

    if (resp.status !== Resp.Ok) {
      throw new BitBarrelError(`Range query failed: ${resp.status}`);
    }

    // Decode the response
    const responseData = Buffer.from(resp.value, 'base64');
    return Protocol.decodeRangeResponse(responseData);
  }

  async prefixQuery(
    prefix: string,
    options?: { limit?: number; cursor?: string }
  ): Promise<{ items: Array<[string, string]>; nextCursor: string; hasMore: boolean }> {
    this.checkBarrelSelected();

    const opts = normalizeRangeOptions(options);

    const prefixPayload: PrefixRequest = {
      prefix,
      limit: opts.limit,
      cursor: opts.cursor,
    };

    const prefixData = Protocol.encodePrefixRequest(prefixPayload).toString('base64');
    const req = Protocol.newRequest(Cmd.PrefixQuery, '', prefixData);
    const resp = await this.sendAndWait(req);

    if (resp.status !== Resp.Ok) {
      throw new BitBarrelError(`Prefix query failed: ${resp.status}`);
    }

    // Decode the response
    const responseData = Buffer.from(resp.value, 'base64');
    return Protocol.decodeRangeResponse(responseData);
  }

  async rangeCount(startKey: string, endKey: string): Promise<number> {
    this.checkBarrelSelected();

    const req = Protocol.newRequest(Cmd.RangeCount, startKey, endKey);
    const resp = await this.sendAndWait(req);

    if (resp.status === Resp.Ok) {
      const count = parseInt(resp.value, 10);
      if (isNaN(count)) {
        throw new BitBarrelError('Invalid range count response');
      }
      return count;
    }
    return 0;
  }

  // Keys-Only Queries (require bmCritBit mode)

  async rangeQueryKeys(
    startKey: string,
    endKey: string,
    options?: { limit?: number; cursor?: string }
  ): Promise<{ keys: string[]; nextCursor: string; hasMore: boolean }> {
    this.checkBarrelSelected();

    const opts = normalizeRangeOptions(options);

    const rangePayload: RangeRequest = {
      startKey,
      endKey,
      limit: opts.limit,
      cursor: opts.cursor,
    };

    const rangeData = Protocol.encodeRangeRequest(rangePayload).toString('base64');
    const req = Protocol.newRequest(Cmd.RangeKeys, '', rangeData);
    const resp = await this.sendAndWait(req);

    if (resp.status !== Resp.Ok) {
      throw new BitBarrelError(`Range keys query failed: ${resp.status}`);
    }

    // Decode the response
    const responseData = Buffer.from(resp.value, 'base64');
    return Protocol.decodeKeysResponse(responseData);
  }

  async prefixQueryKeys(
    prefix: string,
    options?: { limit?: number; cursor?: string }
  ): Promise<{ keys: string[]; nextCursor: string; hasMore: boolean }> {
    this.checkBarrelSelected();

    const opts = normalizeRangeOptions(options);

    const prefixPayload: PrefixRequest = {
      prefix,
      limit: opts.limit,
      cursor: opts.cursor,
    };

    const prefixData = Protocol.encodePrefixRequest(prefixPayload).toString('base64');
    const req = Protocol.newRequest(Cmd.PrefixKeys, '', prefixData);
    const resp = await this.sendAndWait(req);

    if (resp.status !== Resp.Ok) {
      throw new BitBarrelError(`Prefix keys query failed: ${resp.status}`);
    }

    // Decode the response
    const responseData = Buffer.from(resp.value, 'base64');
    return Protocol.decodeKeysResponse(responseData);
  }

  // Reference Traversal

  async traverse(
    key: string,
    pathSpec: string,
    options: TraverseOptions = {}
  ): Promise<TraverseResult[]> {
    this.checkBarrelSelected();

    let optsByte = 0;
    if (options.includeFullData) optsByte |= 0x01;
    if (options.extractArrays) optsByte |= 0x02;
    if (options.firstOnly) optsByte |= 0x04;

    const traversePayload: TraverseRequest = {
      seq: this.seqCounter++,
      key,
      pathSpec,
      options: optsByte,
    };

    const traverseData = Protocol.encodeTraverseRequest(traversePayload).toString('base64');
    const req = Protocol.newRequest(Cmd.Traverse, '', traverseData);
    const resp = await this.sendAndWait(req);

    if (resp.status === Resp.NotFound) {
      throw new NotFoundError(`Key not found: ${key}`);
    } else if (resp.status !== Resp.Ok) {
      throw new BitBarrelError(`Traverse failed: ${resp.status}`);
    }

    // Decode the results
    const responseData = Buffer.from(resp.value, 'base64');
    const [, , results] = Protocol.decodeTraverseResults(responseData);

    return results;
  }

  async traversePath(
    key: string,
    pathSpec: string
  ): Promise<TraverseResult[]> {
    return this.traverse(key, pathSpec, { includeFullData: true });
  }

  // ============================================================================
  // Pub/Sub Methods
  // ============================================================================

  /**
   * Subscribe to topic with options (supports pattern matching with *)
   */
  async subscribe(topic: string, options?: SubscriptionOptions): Promise<string> {
    const opts = options ?? defaultSubscriptionOptions();

    // Determine if this is a pattern subscription
    const isPattern = topic.includes('*');
    const actualTopic = isPattern ? '' : topic;
    const actualPattern = isPattern ? topic : '';

    const subscribeData = Protocol.encodeSubscribeRequest(actualTopic, actualPattern, opts).toString('base64');
    const req = Protocol.newRequest(Cmd.Subscribe, '', subscribeData);
    const resp = await this.sendAndWait(req);

    if (resp.status !== Resp.Ok) {
      throw new BitBarrelError(`Subscribe failed: ${resp.status}`);
    }

    const subId = Protocol.decodeSubscribeResponse(resp.value);

    // Track subscription
    this.subscriptions.set(subId, { id: subId, topic: actualTopic, pattern: actualPattern });

    return subId;
  }

  /**
   * Subscribe to exact topic with default options
   */
  async subscribeSimple(topic: string): Promise<string> {
    return this.subscribe(topic, defaultSubscriptionOptions());
  }

  /**
   * Check if subscription is active
   */
  isSubscribed(subId: string): boolean {
    return this.subscriptions.has(subId);
  }

  /**
   * Unsubscribe from subscription
   */
  async unsubscribe(subId: string): Promise<boolean> {
    if (!this.subscriptions.has(subId)) {
      return false;
    }

    const req = Protocol.newRequest(Cmd.Unsubscribe, subId);
    const resp = await this.sendAndWait(req);

    if (resp.status === Resp.Ok) {
      this.subscriptions.delete(subId);
      return true;
    }
    return false;
  }

  /**
   * Unsubscribe from all active subscriptions
   */
  async unsubscribeAll(): Promise<number> {
    let count = 0;
    const subIds = Array.from(this.subscriptions.keys());
    for (const subId of subIds) {
      if (await this.unsubscribe(subId)) {
        count++;
      }
    }
    return count;
  }

  /**
   * Publish message with type and headers to topic
   */
  async publish(
    topic: string,
    messageType: PubSubMessageType,
    payload: string,
    headers = ''
  ): Promise<number> {
    const publishData = Protocol.encodePublishRequest(topic, messageType, payload, headers).toString('base64');
    const req = Protocol.newRequest(Cmd.Publish, '', publishData);
    const resp = await this.sendAndWait(req);

    if (resp.status !== Resp.Ok) {
      throw new BitBarrelError(`Publish failed: ${resp.status}`);
    }

    return Protocol.decodePublishResponse(resp.value);
  }

  /**
   * Publish message with type to topic (no headers)
   */
  async publishSimple(
    topic: string,
    messageType: PubSubMessageType,
    payload: string
  ): Promise<number> {
    return this.publish(topic, messageType, payload, '');
  }

  /**
   * Publish data message to topic
   */
  async publishData(topic: string, payload: string): Promise<number> {
    return this.publish(topic, 0, payload, ''); // PubSubMessageType.Data
  }

  /**
   * List subscribers for a topic
   * Not yet implemented
   */
  async listSubscribers(_topic: string): Promise<SubscriptionInfo[]> {
    throw new BitBarrelError('listSubscribers() not yet implemented');
  }

  /**
   * List all topics
   * Not yet implemented
   */
  async listTopics(): Promise<string[]> {
    throw new BitBarrelError('listTopics() not yet implemented');
  }

  /**
   * Get message history for topic
   * Not yet implemented
   */
  async getHistory(_topic: string, _request: HistoryRequest): Promise<PubSubEvent[]> {
    throw new BitBarrelError('getHistory() not yet implemented');
  }

  /**
   * Get presence info for topic
   * Not yet implemented
   */
  async getPresence(_topic: string): Promise<PresenceInfo> {
    throw new BitBarrelError('getPresence() not yet implemented');
  }

  /**
   * Set the callback function for PubSub events
   */
  setMessageHandler(handler: ((event: PubSubEvent) => void) | null): void {
    this.onMessage = handler;
  }
}

// Export a convenience function for creating clients
export function createClient(
  config: ClientConfig | string = 'localhost',
  port?: number,
  token?: string
): BitBarrelClient {
  return new BitBarrelClient(config, port, token);
}
