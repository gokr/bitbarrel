import 'dart:async';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'errors.dart';

/// Wrapper around web_socket_channel for BitBarrel communication
class BitBarrelWebSocket {
  final WebSocketChannel _channel;
  final String _host;
  final int _port;
  bool _isConnected = false;
  late final Stream<dynamic> _broadcastStream;

  BitBarrelWebSocket._(this._channel, this._host, this._port) {
    _isConnected = true;
    // Create broadcast stream early to allow multiple listeners
    _broadcastStream = _channel.stream.asBroadcastStream();
  }

  /// Connect to a BitBarrel server
  static Future<BitBarrelWebSocket> connect(
    String host,
    int port, [
    String path = '/ws',
  ]) async {
    final uri = Uri(
      scheme: 'ws',
      host: host,
      port: port,
      path: path,
    );

    try {
      final channel = WebSocketChannel.connect(uri);

      // Wait for connection to be established
      await channel.ready;

      // Read welcome message - server sends text on connection
      final socket = BitBarrelWebSocket._(channel, host, port);
      final firstMessage = await socket._broadcastStream.first;
      final welcomeStr = firstMessage is String
          ? firstMessage
          : String.fromCharCodes(firstMessage as List<int>);

      if (!welcomeStr.contains('Connected to BitBarrel')) {
        await channel.sink.close();
        throw ConnectFailedException('Invalid welcome from server: $welcomeStr');
      }

      return socket;
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
