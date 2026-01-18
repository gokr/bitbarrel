import 'dart:async';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'errors.dart';

/// Wrapper around web_socket_channel for BitBarrel communication
class BitBarrelWebSocket {
  final WebSocketChannel _channel;
  bool _isConnected = false;
  late final Stream<dynamic> _broadcastStream;

  BitBarrelWebSocket._withStream(this._channel, this._broadcastStream) {
    _isConnected = true;
  }

  /// Connect to a BitBarrel server
  static Future<BitBarrelWebSocket> connect(
    String host,
    int port, [
    String path = '/ws',
    Map<String, String>? queryParams,
  ]) async {
    // Build URI with query parameters if provided
    final uri = Uri(
      scheme: 'ws',
      host: host,
      port: port,
      path: path,
      queryParameters: queryParams,
    );

    try {
      // Connect without subprotocol - server doesn't require it
      final channel = WebSocketChannel.connect(uri);

      // Create broadcast stream immediately to not miss welcome message
      final broadcastStream = channel.stream.asBroadcastStream();

      // Wait for connection to be established
      await channel.ready;

      // Read welcome message - server sends text on connection
      final firstMessage = await broadcastStream.first.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw ConnectFailedException('Timeout waiting for welcome message'),
      );
      final welcomeStr = firstMessage is String
          ? firstMessage
          : String.fromCharCodes(firstMessage as List<int>);

      if (!welcomeStr.contains('Connected to BitBarrel')) {
        await channel.sink.close();
        throw ConnectFailedException('Invalid welcome from server: $welcomeStr');
      }

      return BitBarrelWebSocket._withStream(channel, broadcastStream);
    } catch (e) {
      if (e is ConnectFailedException) rethrow;
      throw ConnectFailedException('Failed to connect: $e');
    }
  }

  /// Send binary data
  Future<void> send(Uint8List data) async {
    if (!_isConnected) {
      throw ConnectionClosedException();
    }

    try {
      _channel.sink.add(data);
    } catch (e) {
      _isConnected = false;
      throw ConnectionException('Failed to send data',
          operation: 'send', innerError: e);
    }
  }

  /// Receive binary data
  Future<Uint8List> receive() async {
    if (!_isConnected) {
      throw ConnectionClosedException();
    }

    try {
      final message = await _broadcastStream.first;

      Uint8List data;
      if (message is String) {
        // Silently ignore welcome messages from the server
        if (message.contains('Connected') || message.contains('Welcome')) {
          // Skip this message and wait for the next one (which should be binary)
          return await receive();
        }
        data = Uint8List.fromList(message.codeUnits);
        throw ProtocolException('Unexpected text message: $message');
      } else if (message is List<int>) {
        data = Uint8List.fromList(message);
      } else if (message is Uint8List) {
        data = message;
      } else {
        throw ProtocolException('Unexpected message type: ${message.runtimeType}');
      }

      return data;
    } catch (e) {
      _isConnected = false;
      if (e is BitBarrelException) rethrow;
      throw ConnectionException('Failed to receive data',
          operation: 'receive', innerError: e);
    }
  }

  /// Close the connection
  Future<void> close() async {
    _isConnected = false;
    await _channel.sink.close();
  }

  /// Check if connected
  bool get isConnected => _isConnected;
}
