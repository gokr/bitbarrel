/**
 * Mock WebSocket Server for Testing
 *
 * Provides a mock WebSocket server that simulates BitBarrel server behavior
 * for testing the client implementation.
 */

import { WebSocketServer, WebSocket } from 'ws';
import { Command, ResponseStatus } from '../src/types';
import type { Request, Response } from '../src/types';
import { Protocol } from '../src/protocol';
import type { Server } from 'http';

export interface MockServerOptions {
  barrelData?: Map<string, Map<string, string>>;
  barrels?: Set<string>;
  authToken?: string;
  autoCreateBarrels?: boolean;
}

export class MockBitBarrelServer {
  private server: WebSocketServer;
  private barrelData: Map<string, Map<string, string>>;
  private barrels: Set<string>;
  private clientBarrels: Map<WebSocket, string | null> = new Map();
  public readonly authToken?: string;
  private autoCreateBarrels: boolean;

  constructor(port: number, options: MockServerOptions = {}) {
    this.barrelData = options.barrelData ?? new Map();
    this.barrels = options.barrels ?? new Set();
    this.authToken = options.authToken;
    this.autoCreateBarrels = options.autoCreateBarrels ?? true;

    this.server = new WebSocketServer({ port });
    this.setupHandlers();
  }

  private setupHandlers(): void {
    this.server.on('connection', (ws, request) => {
      // Check authentication if token is configured
      if (this.authToken) {
        const url = new URL(request.url!, `http://${request.headers.host}`);
        const token = url.searchParams.get('token');
        if (token !== this.authToken) {
          ws.close(1008, 'Authentication failed');
          return;
        }
      }

      this.clientBarrels.set(ws, null);

      // Send welcome message
      ws.send('Connected to BitBarrel network server');

      ws.on('message', (data) => {
        try {
          const buffer = Buffer.from(data as ArrayBuffer);
          const request = Protocol.decodeRequest(buffer);
          const response = this.handleRequest(request, ws);
          const encoded = Protocol.encodeResponse(response);
          ws.send(encoded);
        } catch (error) {
          const errorResponse: Response = {
            status: ResponseStatus.Error,
            seq: 0,
            value: error instanceof Error ? error.message : 'Unknown error',
          };
          const encoded = Protocol.encodeResponse(errorResponse);
          ws.send(encoded);
        }
      });

      ws.on('close', () => {
        this.clientBarrels.delete(ws);
      });
    });
  }

  private handleRequest(req: Request, ws: WebSocket): Response {
    const clientCurrentBarrel = this.clientBarrels.get(ws);

    switch (req.command) {
      case Command.CreateBarrel: {
        const name = req.key;
        if (this.barrels.has(name)) {
          return Protocol.newResponse(ResponseStatus.BarrelExists, req.seq, `Barrel ${name} already exists`);
        }
        this.barrels.add(name);
        this.barrelData.set(name, new Map());
        return Protocol.okResponse(req.seq, 'Barrel created');
      }

      case Command.OpenBarrel:
      case Command.UseBarrel: {
        const name = req.key;
        if (!this.barrels.has(name)) {
          if (this.autoCreateBarrels) {
            this.barrels.add(name);
            this.barrelData.set(name, new Map());
          } else {
            return Protocol.newResponse(ResponseStatus.BarrelNotFound, req.seq, `Barrel ${name} not found`);
          }
        }
        this.clientBarrels.set(ws, name);
        return Protocol.okResponse(req.seq, 'Barrel opened');
      }

      case Command.CloseBarrel: {
        this.clientBarrels.set(ws, null);
        return Protocol.okResponse(req.seq, 'Barrel closed');
      }

      case Command.ListBarrels: {
        const barrelList = Array.from(this.barrels).join(',');
        return Protocol.okResponse(req.seq, barrelList);
      }

      case Command.DropBarrel: {
        const name = req.key;
        if (!this.barrels.has(name)) {
          return Protocol.newResponse(ResponseStatus.BarrelNotFound, req.seq, `Barrel ${name} not found`);
        }
        this.barrels.delete(name);
        this.barrelData.delete(name);
        return Protocol.okResponse(req.seq, 'Barrel dropped');
      }

      case Command.GetBarrelConfig:
      case Command.SetBarrelConfig: {
        const name = req.key;
        if (!this.barrels.has(name)) {
          return Protocol.newResponse(ResponseStatus.BarrelNotFound, req.seq, `Barrel ${name} not found`);
        }
        return Protocol.okResponse(req.seq, '{}'); // Empty config
      }

      case Command.GetBarrelStats: {
        const name = req.key;
        if (!this.barrels.has(name)) {
          return Protocol.newResponse(ResponseStatus.BarrelNotFound, req.seq, `Barrel ${name} not found`);
        }
        const data = this.barrelData.get(name) ?? new Map();
        const stats = {
          totalKeys: data.size,
          activeKeys: data.size,
          deletedKeys: 0,
          fileCount: 1,
          totalSize: 1024,
          activeFileSize: 1024,
          avgKeySize: 10,
          avgValueSize: 50,
          avgRecordSize: 60,
          fragmentationRatio: 0,
          isCompacting: false,
          lastCompactTime: 'never',
          recordsScanned: 0,
          recordsKept: data.size,
          recordsDropped: 0,
          indexMode: 'hash',
          syncMode: 'buffer',
          dataPath: `./data/${name}`,
          lastModified: new Date().toISOString(),
        };
        return Protocol.okResponse(req.seq, JSON.stringify(stats));
      }

      // Data operations require a selected barrel
      case Command.Get:
      case Command.Set:
      case Command.Delete:
      case Command.Exists:
      case Command.Count:
      case Command.ListKeys:
      case Command.RangeQuery:
      case Command.PrefixQuery:
      case Command.RangeCount:
      case Command.Traverse: {
        if (!clientCurrentBarrel) {
          return Protocol.newResponse(ResponseStatus.NoBarrel, req.seq, 'No barrel selected');
        }
        return this.handleDataRequest(req, clientCurrentBarrel);
      }

      case Command.Ping: {
        return Protocol.okResponse(req.seq, 'pong');
      }

      default: {
        return Protocol.newResponse(ResponseStatus.Invalid, req.seq, `Unknown command: ${req.command}`);
      }
    }
  }

  private handleDataRequest(req: Request, barrel: string): Response {
    const data = this.barrelData.get(barrel);
    if (!data) {
      return Protocol.newResponse(ResponseStatus.Error, req.seq, 'Barrel data not found');
    }

    switch (req.command) {
      case Command.Get: {
        const value = data.get(req.key);
        if (value === undefined) {
          return Protocol.notFoundResponse(req.seq, `Key not found: ${req.key}`);
        }
        return Protocol.okResponse(req.seq, value);
      }

      case Command.Set: {
        data.set(req.key, req.value);
        return Protocol.okResponse(req.seq, 'OK');
      }

      case Command.Delete: {
        const existed = data.delete(req.key);
        return existed ? Protocol.okResponse(req.seq, 'OK') : Protocol.notFoundResponse(req.seq);
      }

      case Command.Exists: {
        const exists = data.has(req.key);
        return Protocol.okResponse(req.seq, exists ? 'true' : 'false');
      }

      case Command.Count: {
        return Protocol.okResponse(req.seq, data.size.toString());
      }

      case Command.ListKeys: {
        const keys = Array.from(data.keys()).join(',');
        return Protocol.okResponse(req.seq, keys);
      }

      case Command.RangeQuery: {
        // For now, just return all keys in range
        const keys: Array<[string, string]> = [];
        // Parse the keys which are in format: ["item:000", "value0"]
        const startKey = req.key;
        const endKey = req.value;
        for (const [k, v] of data.entries()) {
          // Simple string comparison for range
          if (k >= startKey && k <= endKey) {
            keys.push([k, v]);
          }
        }
        // Sort by key to ensure consistent ordering
        keys.sort((a, b) => a[0].localeCompare(b[0]));
        const response = {
          items: keys,
          nextCursor: '',
          hasMore: false,
        };
        const encodedRangeResponse = Protocol.encodeRangeResponse(response);
        const base64Encoded = encodedRangeResponse.toString('base64');
        return Protocol.okResponse(req.seq, base64Encoded);
      }

      case Command.PrefixQuery: {
        const prefix = req.key;
        const keys: Array<[string, string]> = [];
        for (const [k, v] of data.entries()) {
          if (k.startsWith(prefix)) {
            keys.push([k, v]);
          }
        }
        const response = {
          items: keys,
          nextCursor: '',
          hasMore: false,
        };
        const encodedRangeResponse = Protocol.encodeRangeResponse(response);
        const base64Encoded = encodedRangeResponse.toString('base64');
        return Protocol.okResponse(req.seq, base64Encoded);
      }

      case Command.RangeCount: {
        let count = 0;
        for (const k of data.keys()) {
          if (k >= req.key && k <= req.value) {
            count++;
          }
        }
        return Protocol.okResponse(req.seq, count.toString());
      }

      case Command.Traverse: {
        // Simple traversal simulation
        const results = [
          `Path: ${req.key} -> ${req.value}`,
        ];
        return Protocol.okResponse(req.seq, Buffer.from(JSON.stringify({ results })).toString('base64'));
      }
    }
  }

  async close(): Promise<void> {
    this.server.close();
  }

  get port(): number {
    const address = this.server.address();
    if (address && typeof address !== 'string') {
      return address.port;
    }
    throw new Error('Server not listening');
  }
}
