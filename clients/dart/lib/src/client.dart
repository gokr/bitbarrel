import 'dart:async';
import 'dart:convert';

import 'config.dart';
import 'web_socket.dart';
import 'protocol/commands.dart';
import 'protocol/status.dart';
import 'protocol/encoder.dart';
import 'protocol/decoder.dart';
import 'types.dart';
import 'errors.dart';

/// Main BitBarrel client class
///
/// Usage example:
/// ```dart
/// final client = BitBarrelClient.localhost();
/// await client.connect();
/// await client.createBarrel('mydb');
/// await client.useBarrel('mydb');
/// await client.set('key', 'value');
/// final value = await client.get('key');
/// await client.close();
/// ```
class BitBarrelClient {
  final BitBarrelConfig _config;
  BitBarrelWebSocket? _ws;
  int _seq = 0;
  String? _currentBarrel;

  BitBarrelClient(this._config);

  /// Create client with default localhost configuration
  factory BitBarrelClient.localhost() =>
      BitBarrelClient(BitBarrelConfig.localhost());

  /// Connect to the BitBarrel server
  Future<void> connect() async {
    if (_ws != null) {
      throw ConnectionException('Already connected', operation: 'connect');
    }

    _ws = await BitBarrelWebSocket.connect(
      _config.host,
      _config.port,
      _config.path,
    );
  }

  /// Close the connection to the server
  Future<void> close() async {
    _currentBarrel = null;
    if (_ws != null) {
      await _ws!.close();
      _ws = null;
    }
  }

  /// Check if connected to the server
  bool get isConnected => _ws != null && _ws!.isConnected;

  /// Get the current barrel name
  String? get currentBarrel => _currentBarrel;

  /// Ensure connected (auto-connect if not connected)
  Future<void> _ensureConnected() async {
    if (!isConnected) {
      await connect();
    }
  }

  /// Ensure a barrel is selected
  void _ensureBarrel() {
    if (_currentBarrel == null || _currentBarrel!.isEmpty) {
      throw NoBarrelSelectedException();
    }
  }

  /// Send a request and receive a response
  Future<String> _sendRequest({
    required int command,
    required String key,
    String value = '',
  }) async {
    await _ensureConnected();

    final ws = _ws;
    if (ws == null) {
      throw ConnectionClosedException();
    }

    // Get next sequence number
    final seq = _seq++;

    // Encode request
    final requestData = ProtocolEncoder.encodeRequest(
      command: command,
      seq: seq,
      key: key,
      value: value,
    );

    // Apply timeout to send
    await ws.send(requestData).timeout(
      _config.requestTimeout,
      onTimeout: () {
        _ws = null;
        throw TimeoutException(_config.requestTimeout, operation: 'send');
      },
    );

    // Receive response with timeout
    final responseData = await ws.receive().timeout(
      _config.requestTimeout,
      onTimeout: () {
        _ws = null;
        throw TimeoutException(_config.requestTimeout, operation: 'receive');
      },
    );

    final response = ProtocolDecoder.decodeResponse(responseData);

    // Verify sequence
    if (response.seq != seq) {
      throw SequenceMismatchException(seq, response.seq);
    }

    // Handle errors
    final exception = Status.toException(response.status, response.value);
    if (exception != null) {
      throw exception;
    }

    return response.value;
  }

  // ============ Barrel Operations ============

  /// Create a new barrel
  /// [config] is optional JSON string for barrel configuration
  Future<void> createBarrel(String name, [String config = '']) async {
    await _sendRequest(
      command: Command.createBarrel,
      key: name,
      value: config,
    );
  }

  /// Open an existing barrel (doesn't set as active)
  Future<void> openBarrel(String name) async {
    await _sendRequest(
      command: Command.openBarrel,
      key: name,
      value: '',
    );
  }

  /// Use a barrel as the active barrel for this session
  Future<void> useBarrel(String name) async {
    await _sendRequest(
      command: Command.useBarrel,
      key: name,
      value: '',
    );
    _currentBarrel = name;
  }

  /// Close the current barrel
  Future<void> closeBarrel() async {
    await _sendRequest(
      command: Command.closeBarrel,
      key: '',
      value: '',
    );
    _currentBarrel = null;
  }

  /// List all barrels
  Future<List<String>> listBarrels() async {
    final result = await _sendRequest(
      command: Command.listBarrels,
      key: '',
      value: '',
    );
    if (result.isEmpty) return [];
    return result.split(',');
  }

  /// Drop a barrel (delete it and all its data)
  Future<void> dropBarrel(String name) async {
    await _sendRequest(
      command: Command.dropBarrel,
      key: name,
      value: '',
    );
    if (_currentBarrel == name) {
      _currentBarrel = null;
    }
  }

  /// Get barrel configuration as a JSON string
  Future<String> getBarrelConfig(String name) async {
    final value = await _sendRequest(
      command: Command.getBarrelConfig,
      key: name,
      value: '',
    );
    return value;
  }

  /// Set barrel configuration
  /// [config] is a JSON string with barrel configuration
  Future<void> setBarrelConfig(String name, String config) async {
    await _sendRequest(
      command: Command.setBarrelConfig,
      key: name,
      value: config,
    );
  }

  // ============ Data Operations ============

  /// Store a key-value pair
  Future<void> set(String key, String value) async {
    _ensureBarrel();
    await _sendRequest(
      command: Command.set,
      key: key,
      value: value,
    );
  }

  /// Retrieve a value by key
  /// Throws [KeyNotFoundException] if key doesn't exist
  Future<String> get(String key) async {
    _ensureBarrel();
    return await _sendRequest(
      command: Command.get,
      key: key,
      value: '',
    );
  }

  /// Delete a key
  Future<void> delete(String key) async {
    _ensureBarrel();
    await _sendRequest(
      command: Command.delete,
      key: key,
      value: '',
    );
  }

  /// Check if a key exists
  Future<bool> exists(String key) async {
    _ensureBarrel();
    try {
      final result = await _sendRequest(
        command: Command.exists,
        key: key,
        value: '',
      );
      return result.toLowerCase() == 'true';
    } on KeyNotFoundException {
      return false;
    }
  }

  /// Get the number of keys in the current barrel
  Future<int> count() async {
    _ensureBarrel();
    final result = await _sendRequest(
      command: Command.count,
      key: '',
      value: '',
    );
    return int.tryParse(result) ?? 0;
  }

  /// List all keys in the current barrel
  Future<List<String>> listKeys() async {
    _ensureBarrel();
    final result = await _sendRequest(
      command: Command.listKeys,
      key: '',
      value: '',
    );
    if (result.isEmpty) return [];
    return result.split(',');
  }

  /// Send a ping to the server (health check)
  Future<void> ping() async {
    await _sendRequest(
      command: Command.ping,
      key: '',
      value: '',
    );
  }

  // ============ Query Operations ============

  /// Perform a range query
  /// Returns a [RangeQueryResponse] with items, cursor, and hasMore flag
  Future<RangeQueryResponse> rangeQuery(
    String startKey,
    String endKey, {
    int limit = 1000,
    String cursor = '',
  }) async {
    _ensureBarrel();

    final encodedParams = ProtocolEncoder.encodeRangeRequest(
      startKey: startKey,
      endKey: endKey,
      limit: limit,
      cursor: cursor,
    );

    final value = await _sendRequest(
      command: Command.rangeQuery,
      key: '',
      value: Latin1Codec().decode(encodedParams),
    );

    return ProtocolDecoder.decodeRangeResponse(value);
  }

  /// Perform a prefix query
  /// Returns a [RangeQueryResponse] with items, cursor, and hasMore flag
  Future<RangeQueryResponse> prefixQuery(
    String prefix, {
    int limit = 1000,
    String cursor = '',
  }) async {
    _ensureBarrel();

    final encodedParams = ProtocolEncoder.encodePrefixRequest(
      prefix: prefix,
      limit: limit,
      cursor: cursor,
    );

    final value = await _sendRequest(
      command: Command.prefixQuery,
      key: '',
      value: Latin1Codec().decode(encodedParams),
    );

    return ProtocolDecoder.decodeRangeResponse(value);
  }

  /// Count items in a range
  Future<int> rangeCount(String startKey, String endKey) async {
    _ensureBarrel();

    final encodedParams = ProtocolEncoder.encodeRangeRequest(
      startKey: startKey,
      endKey: endKey,
      limit: 0,
      cursor: '',
    );

    final value = await _sendRequest(
      command: Command.rangeCount,
      key: '',
      value: Latin1Codec().decode(encodedParams),
    );

    final response = ProtocolDecoder.decodeRangeResponse(value);
    return response.items.length;
  }

  /// Perform a reference traversal
  /// Returns a list of [TraverseResult] items
  Future<List<TraverseResult>> traverse(
    String key,
    String path, {
    TraverseOptions options = TraverseOptions.defaults,
  }) async {
    _ensureBarrel();

    final seq = _seq;
    final encodedParams = ProtocolEncoder.encodeTraverseRequest(
      seq: seq,
      key: key,
      path: path,
      flags: options.flags,
    );

    final value = await _sendRequest(
      command: Command.traverse,
      key: '',
      value: Latin1Codec().decode(encodedParams),
    );

    final response = ProtocolDecoder.decodeTraverseResults(value);

    final exception = Status.toException(response.status, null);
    if (exception != null) {
      throw exception;
    }

    return response.results;
  }
}
