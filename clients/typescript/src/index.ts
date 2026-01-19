/**
 * BitBarrel TypeScript Client
 *
 * Main entry point for the BitBarrel TypeScript client library.
 * Provides a typesafe, async API for interacting with BitBarrel servers.
 */

// Core client
export { BitBarrelClient, createClient } from './client';

// Types and interfaces
export type {
  ClientConfig,
  ServerInfo,
  BarrelStats,
  RangeRequest,
  PrefixRequest,
  RangeResponse,
  TraverseRequest,
  TraverseResult,
  TraverseOptions,
} from './types';

// Enums
export { Command, ResponseStatus } from './types';

// Errors
export {
  BitBarrelError,
  ConnectionError,
  ProtocolError,
  RequestTimeoutError,
  BarrelError,
  AuthenticationError,
  NotFoundError,
} from './errors';

// Utility functions
export { Protocol } from './protocol';

// Default export
import { BitBarrelClient, createClient } from './client';
export default {
  BitBarrelClient,
  createClient,
};
