/**
 * BitBarrel TypeScript Client - Type Definitions
 *
 * This file contains all TypeScript interfaces, enums, and constants
 * for the BitBarrel client library, matching the Nim client's protocol.
 */

// Connection Configuration
export interface ClientConfig {
  host?: string;
  port?: number;
  connectTimeout?: number;  // milliseconds
  requestTimeout?: number;  // milliseconds
  token?: string;           // JWT authentication token
  autoConnect?: boolean;    // auto-connect on first operation
}

// Default configuration values
export const DefaultHost = 'localhost';
export const DefaultPort = 9876;
export const DefaultConnectTimeout = 5000; // 5 seconds
export const DefaultRequestTimeout = 30000; // 30 seconds

export function defaultConfig(): Required<ClientConfig> {
  return {
    host: DefaultHost,
    port: DefaultPort,
    connectTimeout: DefaultConnectTimeout,
    requestTimeout: DefaultRequestTimeout,
    token: '',
    autoConnect: true,
  };
}

// Protocol command codes (matching Nim client)
export const enum Command {
  // Data operations
  Get = 0x01,
  Set = 0x02,
  Delete = 0x03,
  Exists = 0x04,
  Count = 0x05,
  ListKeys = 0x06,
  Ping = 0x09,

  // Barrel management
  CreateBarrel = 0x10,
  OpenBarrel = 0x11,
  UseBarrel = 0x12,
  CloseBarrel = 0x13,
  ListBarrels = 0x14,
  DropBarrel = 0x15,

  // Configuration
  GetBarrelConfig = 0x16,
  SetBarrelConfig = 0x17,
  GetBarrelStats = 0x18,

  // Reference traversal
  Traverse = 0x20,

  // Range queries
  RangeQuery = 0x21,
  PrefixQuery = 0x22,
  RangeCount = 0x23,
  RangeKeys = 0x24,
  PrefixKeys = 0x25,
}

// Response status codes
export const enum ResponseStatus {
  Ok = 0x00,
  NotFound = 0x01,
  Error = 0x02,
  Invalid = 0x03,
  NoBarrel = 0x04,
  BarrelExists = 0x05,
  BarrelNotFound = 0x06,
  Unauthorized = 0x07,
}

// Protocol limits
export const MaxKeySize = 65535;     // 64KB
export const MaxValueSize = 32 * 1024 * 1024; // 32MB

// Request interface: [type:1][seq:4][keyLen:2][key:N][valLen:4][value:M]
export interface Request {
  command: Command;
  seq: number;
  key: string;
  value: string;
}

// Response interface: [status:1][seq:4][valLen:4][value:M]
export interface Response {
  status: ResponseStatus;
  seq: number;
  value: string;
}

// Range query types
export interface RangeRequest {
  startKey: string;
  endKey: string;
  limit: number;
  cursor: string;
}

export interface PrefixRequest {
  prefix: string;
  limit: number;
  cursor: string;
}

export interface RangeResponse {
  items: Array<[string, string]>;
  nextCursor: string;
  hasMore: boolean;
}

// Keys-only response type
export interface KeysResponse {
  keys: string[];
  nextCursor: string;
  hasMore: boolean;
}

// Traversal types
export interface TraverseRequest {
  seq: number;
  key: string;
  pathSpec: string;
  options: number;  // bitfield
}

export interface TraverseResult {
  path: string;
  key: string;
  value: string;
  extractedData: string;
}

export interface TraverseOptions {
  includeFullData?: boolean;  // Return full values or just paths
  extractArrays?: boolean;    // Extract array elements individually
  firstOnly?: boolean;        // Stop after first result
}

// Barrel statistics
export interface BarrelStats {
  totalKeys: number;
  activeKeys: number;
  deletedKeys: number;
  fileCount: number;
  totalSize: number;
  activeFileSize: number;
  avgKeySize: number;
  avgValueSize: number;
  avgRecordSize: number;
  fragmentationRatio: number;
  isCompacting: boolean;
  lastCompactTime: string;
  recordsScanned: number;
  recordsKept: number;
  recordsDropped: number;
  indexMode: string;
  syncMode: string;
  dataPath: string;
  lastModified: string;
}

// Range query options with defaults
export const DefaultRangeLimit = 1000;

export interface RangeQueryOptions {
  limit?: number;
  cursor?: string;
}

export function normalizeRangeOptions(options?: RangeQueryOptions): Required<RangeQueryOptions> {
  return {
    limit: options?.limit ?? DefaultRangeLimit,
    cursor: options?.cursor ?? '',
  };
}
