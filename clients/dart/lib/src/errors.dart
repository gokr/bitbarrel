/// Base exception class for all BitBarrel errors
abstract class BitBarrelException implements Exception {
  final String message;
  final String? operation;
  final Object? innerError;

  const BitBarrelException(this.message, {this.operation, this.innerError});

  @override
  String toString() {
    final buffer = StringBuffer('BitBarrelException');
    if (operation != null) {
      buffer.write('($operation)');
    }
    buffer.write(': $message');
    if (innerError != null) {
      buffer.write(' (caused by: $innerError)');
    }
    return buffer.toString();
  }
}

/// Exception thrown when there's a connection-related error
class ConnectionException extends BitBarrelException {
  ConnectionException(super.message, {super.operation, super.innerError});
}

/// Exception thrown when connection fails to establish
class ConnectFailedException extends ConnectionException {
  ConnectFailedException(String message) : super(message);
}

/// Exception thrown when operation times out
class TimeoutException extends BitBarrelException {
  final Duration duration;

  TimeoutException(this.duration, {String? operation})
      : super('Operation timed out after ${duration.inSeconds}s',
            operation: operation);
}

/// Exception thrown when connection is closed
class ConnectionClosedException extends ConnectionException {
  ConnectionClosedException() : super('Connection closed');
}

/// Exception thrown when a key is not found
class KeyNotFoundException extends BitBarrelException {
  final String key;

  const KeyNotFoundException(this.key)
      : super('Key not found: $key');
}

/// Exception thrown when no barrel is selected
class NoBarrelSelectedException extends BitBarrelException {
  const NoBarrelSelectedException() : super('No barrel selected');
}

/// Exception thrown when barrel already exists
class BarrelExistsException extends BitBarrelException {
  final String name;

  const BarrelExistsException(this.name) : super('Barrel already exists: $name');
}

/// Exception thrown when barrel is not found
class BarrelNotFoundException extends BitBarrelException {
  final String name;

  const BarrelNotFoundException(this.name) : super('Barrel not found: $name');
}

/// Exception thrown for invalid requests
class InvalidRequestException extends BitBarrelException {
  const InvalidRequestException(String message) : super(message);
}

/// Exception thrown for server errors
class ServerErrorException extends BitBarrelException {
  final String? serverMessage;

  const ServerErrorException([this.serverMessage])
      : super(serverMessage ?? 'Server error');
}

/// Exception for protocol violations
class ProtocolException extends BitBarrelException {
  const ProtocolException(String message) : super(message);
}

/// Exception for sequence number mismatches
class SequenceMismatchException extends ProtocolException {
  final int expected;
  final int actual;

  const SequenceMismatchException(this.expected, this.actual)
      : super('Sequence mismatch: expected $expected, got $actual');
}
