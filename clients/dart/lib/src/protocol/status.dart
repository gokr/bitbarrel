import '../errors.dart';

/// Status byte constants for the BitBarrel protocol
class Status {
  // Prevent instantiation
  Status._();

  static const int ok = 0x00;
  static const int notFound = 0x01;
  static const int error = 0x02;
  static const int invalid = 0x03;
  static const int noBarrel = 0x04;
  static const int barrelExists = 0x05;
  static const int barrelNotFound = 0x06;

  /// All valid status values
  static const Set<int> allValues = {
    ok,
    notFound,
    error,
    invalid,
    noBarrel,
    barrelExists,
    barrelNotFound,
  };

  /// Check if a byte is a valid status
  static bool isValid(int status) => allValues.contains(status);

  /// Convert status byte to corresponding exception (returns null for OK)
  static BitBarrelException? toException(int status, String? message) {
    switch (status) {
      case ok:
        return null;
      case notFound:
        return KeyNotFoundException('key');
      case error:
        return ServerErrorException(message);
      case invalid:
        return InvalidRequestException(message ?? 'Invalid request');
      case noBarrel:
        return const NoBarrelSelectedException();
      case barrelExists:
        return BarrelExistsException(name ?? '');
      case barrelNotFound:
        return BarrelNotFoundException(name ?? '');
      default:
        return ProtocolException('Unknown status: 0x${status.toRadixString(16)}');
    }
  }

  /// Helper for barrel status exceptions
  static BitBarrelException? toBarrelException(
    int status,
    String barrelName,
    String? message,
  ) {
    switch (status) {
      case ok:
        return null;
      case barrelExists:
        return BarrelExistsException(barrelName);
      case barrelNotFound:
        return BarrelNotFoundException(barrelName);
      default:
        return toException(status, message);
    }
  }

  /// Placeholder variables used in toException - these should be
  /// replaced by the actual key/barrel name when calling the methods
  static const String? name = null;
}
