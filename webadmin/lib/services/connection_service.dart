import 'package:bitbarrel/bitbarrel.dart';
import 'package:observable/observable.dart';

/// Service for managing BitBarrel server connections
class ConnectionService {
  BitBarrelClient? _client;

  // Observable states
  final Observable<bool> isConnected = Observable(false);
  final Observable<String?> error = Observable(null);
  final Observable<bool> isConnecting = Observable(false);

  BitBarrelClient? get client => _client;

  /// Connect to a BitBarrel server
  Future<void> connect(String host, int port) async {
    isConnecting.value = true;
    error.value = null;

    try {
      // Create client
      _client = BitBarrelClient(BitBarrelConfig(
        host: host,
        port: port,
        connectTimeout: Duration(seconds: 10),
        requestTimeout: Duration(seconds: 30),
      ));

      // Connect to server
      await _client!.connect();

      isConnected.value = true;
      error.value = null;
    } catch (e) {
      error.value = e.toString();
      isConnected.value = false;
      _client = null;
      rethrow;
    } finally {
      isConnecting.value = false;
    }
  }

  /// Disconnect from the server
  Future<void> disconnect() async {
    if (_client != null) {
      try {
        await _client!.close();
      } catch (e) {
        // Ignore errors during disconnect
      }
      _client = null;
    }

    isConnected.value = false;
    isConnecting.value = false;
    error.value = null;
  }

  /// Check if currently connected
  bool get connected => isConnected.value;

  /// Dispose resources
  void dispose() {
    disconnect();
  }
}
