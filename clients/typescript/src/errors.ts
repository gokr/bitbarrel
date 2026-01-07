/**
 * BitBarrel TypeScript Client - Error Classes
 *
 * Custom error classes for different types of errors that can occur
 * when using the BitBarrel client library.
 */

export class BitBarrelError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'BitBarrelError';

    // Maintains proper stack trace for where our error was thrown
    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, BitBarrelError);
    }
  }
}

export class ConnectionError extends BitBarrelError {
  constructor(message: string) {
    super(message);
    this.name = 'ConnectionError';

    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, ConnectionError);
    }
  }
}

export class ProtocolError extends BitBarrelError {
  constructor(message: string) {
    super(message);
    this.name = 'ProtocolError';

    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, ProtocolError);
    }
  }
}

export class RequestTimeoutError extends BitBarrelError {
  constructor(message: string) {
    super(message);
    this.name = 'RequestTimeoutError';

    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, RequestTimeoutError);
    }
  }
}

export class BarrelError extends BitBarrelError {
  constructor(message: string) {
    super(message);
    this.name = 'BarrelError';

    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, BarrelError);
    }
  }
}

export class AuthenticationError extends BitBarrelError {
  constructor(message: string) {
    super(message);
    this.name = 'AuthenticationError';

    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, AuthenticationError);
    }
  }
}

export class NotFoundError extends BitBarrelError {
  constructor(message: string) {
    super(message);
    this.name = 'NotFoundError';

    if (Error.captureStackTrace) {
      Error.captureStackTrace(this, NotFoundError);
    }
  }
}
