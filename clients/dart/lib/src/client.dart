import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:mutex/mutex.dart';

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
///
/// **Thread-safety**: The client has internal locking and is safe for concurrent access.
/// Requests are serialized - only one operation can be in-flight at a time.
class BitBarrelClient {
  final BitBarrelConfig _config;
  BitBarrelWebSocket? _ws;
  int _seq = 0;
  String? _currentBarrel;
  final _lock = Mutex(); // Internal lock for thread-safe operations

  BitBarrelClient(this._config);

  /// Create client with default localhost configuration
  factory BitBarrelClient.localhost() =>
      BitBarrelClient(BitBarrelConfig.localhost());

  /// Connect to the BitBarrel server
  Future<void> connect() async {
    await _lock.protect(() async {
      if (_ws != null) {
        throw ConnectionException('Already connected',
            operation: 'connect');
      }

      // Prepare query parameters with JWT token if provided
      Map<String, String>? queryParams;
      if (_config.token != null && _config.token!.isNotEmpty) {
        queryParams = {
          'token': _config.token!,
        };
      }

      _ws = await BitBarrelWebSocket.connect(
        _config.host,
        _config.port,
        _config.path,
        queryParams,
      );
    });
  }

  /// Close the connection to the server
  Future<void> close() async {
    await _lock.protect(() async {
      _currentBarrel = null;
      if (_ws != null) {
        await _ws!.close();
        _ws = null;
      }
    });
  }

  /// Check if connected to the server
  bool get isConnected => _ws != null && _ws!.isConnected;

  /// Get the current barrel name
  String get currentBarrel => _currentBarrel ?? '';

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
  ///
  /// Thread-safe: holds lock for entire send-receive cycle to prevent
  /// interleaving from concurrent calls and sequence number collisions.
  Future<String> _sendRequest({
    required int command,
    required String key,
    String value = '',
    Uint8List? binaryValue,
  }) async {
    return await _lock.protect(() async {
      await _ensureConnected();

      final ws = _ws;
      if (ws == null) {
        throw ConnectionClosedException();
      }

      // Get next sequence number (atomic within lock)
      final seq = _seq++;

      // Encode request
      final requestData = ProtocolEncoder.encodeRequest(
        command: command,
        seq: seq,
        key: key,
        value: value,
        binaryValue: binaryValue,
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
    });
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

  /// Get comprehensive statistics for a barrel
  ///
  /// Returns a [BarrelStats] object with detailed metrics about keys,
  /// storage usage, performance, compaction status, and configuration.
  ///
  /// Example:
  /// ```dart
  /// final stats = await client.getBarrelStats('mydb');
  /// print('Total keys: ${stats.totalKeys}');
  /// print('Active keys: ${stats.activeKeys}');
  /// print('Disk usage: ${stats.totalSize} bytes');
  /// print('Fragmentation: ${(stats.fragmentationRatio * 100).toStringAsFixed(1)}%');
  /// ```
  Future<BarrelStats> getBarrelStats(String name) async {
    final value = await _sendRequest(
      command: Command.getBarrelStats,
      key: name,
      value: '',
    );

    // Parse JSON response
    final json = jsonDecode(value) as Map<String, dynamic>;
    return BarrelStats.fromJson(json);
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

  /// Retrieve a value by key, returning defaultValue if key doesn't exist
  Future<String> getOrDefault(String key, String defaultValue) async {
    _ensureBarrel();
    try {
      return await _sendRequest(
        command: Command.get,
        key: key,
        value: '',
      );
    } on KeyNotFoundException {
      return defaultValue;
    }
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
    // Empty string means no keys, split would return ['']
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
      binaryValue: encodedParams,
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
      binaryValue: encodedParams,
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
      binaryValue: encodedParams,
    );

    return int.tryParse(value) ?? 0;
  }

  /// Perform a keys-only range query
  /// Returns a [KeysResponse] with keys, cursor, and hasMore flag
  /// Requires barrel opened in bmCritBit mode
  /// Empty startKey/endKey queries entire barrel
  Future<KeysResponse> rangeQueryKeys(
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
      command: Command.rangeKeys,
      key: '',
      binaryValue: encodedParams,
    );

    return ProtocolDecoder.decodeKeysResponse(value);
  }

  /// Perform a keys-only prefix query
  /// Returns a [KeysResponse] with keys, cursor, and hasMore flag
  /// Requires barrel opened in bmCritBit mode
  Future<KeysResponse> prefixQueryKeys(
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
      command: Command.prefixKeys,
      key: '',
      binaryValue: encodedParams,
    );

    return ProtocolDecoder.decodeKeysResponse(value);
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
      binaryValue: encodedParams,
    );

    final response = ProtocolDecoder.decodeTraverseResults(value);

    final exception = Status.toException(response.status, null);
    if (exception != null) {
      throw exception;
    }

    return response.results;
  }

  // ============ Pub/Sub Operations ============

  /// Subscribe to topic with options (supports pattern matching with *)
  /// Returns the subscription ID
  Future<String> subscribe(
    String topic, {
    SubscriptionOptions? options,
  }) async {
    final opts = options ?? SubscriptionOptions.defaults;

    // Determine if this is a pattern subscription
    final isPattern = topic.contains('*');
    final actualTopic = isPattern ? '' : topic;
    final actualPattern = isPattern ? topic : '';

    // Encode subscribe request
    final subscribeData = ProtocolEncoder.encodeSubscribeRequest(
      topic: actualTopic,
      pattern: actualPattern,
      options: opts.encode(),
    );

    final value = await _sendRequest(
      command: Command.subscribe,
      key: '',
      binaryValue: subscribeData,
    );

    // Response value is the subscription ID
    final subId = ProtocolDecoder.decodeSubscribeResponse(value);

    // Track subscription (need to add subscription tracking to the client)
    // For now, just return the subId

    return subId;
  }

  /// Subscribe to exact topic with default options
  Future<String> subscribeSimple(String topic) async {
    return subscribe(topic);
  }

  /// Check if subscription is active
  /// Note: This requires maintaining subscription tracking
  /// Currently returns false as subscription tracking is not implemented
  bool isSubscribed(String subId) {
    // TODO: Implement subscription tracking
    return false;
  }

  /// Unsubscribe from subscription
  /// Returns true if subscription existed and was removed
  Future<bool> unsubscribe(String subId) async {
    // TODO: Implement subscription tracking
    await _sendRequest(
      command: Command.unsubscribe,
      key: subId,
      value: '',
    );
    return false;
  }

  /// Unsubscribe from all active subscriptions
  /// Returns the number of subscriptions removed
  Future<int> unsubscribeAll() async {
    // TODO: Implement subscription tracking
    return 0;
  }

  /// Publish message with type and headers to topic
  /// Returns the sequence number
  Future<int> publish(
    String topic, {
    required int messageType,
    required String payload,
    String headers = '',
  }) async {
    // Encode publish request
    final publishData = ProtocolEncoder.encodePublishRequest(
      topic: topic,
      msgType: messageType,
      payload: payload,
      headers: headers,
    );

    final value = await _sendRequest(
      command: Command.publish,
      key: '',
      binaryValue: publishData,
    );

    return ProtocolDecoder.decodePublishResponse(value);
  }

  /// Publish data message to topic
  Future<int> publishData(String topic, String payload) async {
    return publish(
      topic,
      messageType: PubSubMessageType.data,
      payload: payload,
      headers: '',
    );
  }

  /// Publish presence message to topic
  Future<int> publishPresence(String topic, String payload) async {
    return publish(
      topic,
      messageType: PubSubMessageType.presence,
      payload: payload,
      headers: '',
    );
  }

  /// List subscribers for a topic
  /// Not yet implemented
  Future<List<SubscriptionInfo>> listSubscribers(String topic) async {
    throw UnimplementedError('listSubscribers() not yet implemented');
  }

  /// List all topics
  /// Not yet implemented
  Future<List<String>> listTopics() async {
    throw UnimplementedError('listTopics() not yet implemented');
  }

  /// Get message history for topic
  /// Not yet implemented
  Future<List<PubSubEvent>> getHistory(
    String topic, {
    HistoryRequest? request,
  }) async {
    throw UnimplementedError('getHistory() not yet implemented');
  }

  /// Get presence info for topic
  /// Not yet implemented
  Future<PresenceInfo> getPresence(String topic) async {
    throw UnimplementedError('getPresence() not yet implemented');
  }
}
