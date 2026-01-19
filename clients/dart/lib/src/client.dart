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
  final Set<String> _subscriptions = {}; // Active subscription IDs
  void Function(PubSubEvent)? _onMessage; // PubSub event callback

  // Server info from handshake
  ServerInfo? _serverInfo;
  bool _handshakeReceived = false;

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

      // Read and parse binary handshake
      try {
        final handshakeData = await _ws!.receive();
        _serverInfo = _parseHandshake(handshakeData);
        _handshakeReceived = true;
      } catch (e) {
        await close();
        rethrow;
      }
    });
  }

  /// Close the connection to the server
  Future<void> close() async {
    await _lock.protect(() async {
      _currentBarrel = null;
      _subscriptions.clear();
      _onMessage = null;
      _serverInfo = null;
      _handshakeReceived = false;
      if (_ws != null) {
        await _ws!.close();
        _ws = null;
      }
    });
  }

  /// Get server information from the handshake
  ///
  /// Throws [ConnectionException] if not connected or handshake not received
  ServerInfo getServerInfo() {
    if (_ws == null || !isConnected) {
      throw ConnectionException('Not connected', operation: 'getServerInfo');
    }
    if (!_handshakeReceived) {
      throw ConnectionException('Handshake not received', operation: 'getServerInfo');
    }
    return _serverInfo!;
  }

  /// Check if connected to the server
  bool get isConnected => _ws != null && _ws!.isConnected;

  /// Get the current barrel name
  String get currentBarrel => _currentBarrel ?? '';

  /// Parse binary handshake from server
  ServerInfo _parseHandshake(Uint8List data) {
    // Format: [versionMajor:1][versionMinor:1][serverIdLen:2][serverId:N][pluginCount:1][pluginNameLen1:2][pluginName1]...
    if (data.length < 2) {
      throw ProtocolException('Handshake too short');
    }

    var offset = 0;

    // Parse version
    final versionMajor = data[offset++];
    final versionMinor = data[offset++];

    // Parse server ID length (2 bytes, big-endian)
    if (data.length < offset + 2) {
      throw ProtocolException('Handshake truncated at server ID length');
    }
    final serverIdLen = (data[offset] << 8) | data[offset + 1];
    offset += 2;

    // Parse server ID
    if (data.length < offset + serverIdLen) {
      throw ProtocolException('Handshake truncated at server ID');
    }
    final serverId = String.fromCharCodes(data, offset, offset + serverIdLen);
    offset += serverIdLen;

    // Parse plugin count
    if (data.length < offset + 1) {
      throw ProtocolException('Handshake truncated at plugin count');
    }
    final pluginCount = data[offset++];

    // Parse plugins
    final plugins = <String>[];
    for (var i = 0; i < pluginCount; i++) {
      // Parse plugin name length (2 bytes, big-endian)
      if (data.length < offset + 2) {
        throw ProtocolException('Handshake truncated at plugin name length');
      }
      final pluginNameLen = (data[offset] << 8) | data[offset + 1];
      offset += 2;

      // Parse plugin name
      if (data.length < offset + pluginNameLen) {
        throw ProtocolException('Handshake truncated at plugin name');
      }
      final pluginName = String.fromCharCodes(data, offset, offset + pluginNameLen);
      plugins.add(pluginName);
      offset += pluginNameLen;
    }

    return ServerInfo(
      versionMajor: versionMajor,
      versionMinor: versionMinor,
      serverId: serverId,
      plugins: plugins,
    );
  }

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
  ///
  /// Note: This method filters out PubSub events (command 0xFF) that may
  /// be interleaved with the expected response. PubSub events are passed
  /// to the message handler callback if set.
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

      // PubSub command is 0xFF - used to filter out PubSub events
      const int pubsubCommand = 0xFF;

      // Loop to receive response, filtering out any interleaved PubSub events
      ({int status, int seq, String value}) response =
          (status: 0, seq: 0, value: '');
      bool receivedExpectedResponse = false;
      final startTime = DateTime.now();

      while (!receivedExpectedResponse) {
        // Check for overall timeout
        if (DateTime.now().difference(startTime) > _config.requestTimeout) {
          _ws = null;
          throw TimeoutException(_config.requestTimeout, operation: 'receive');
        }

        // Receive next message
        final data = await ws.receive().timeout(
          _config.requestTimeout,
          onTimeout: () {
            _ws = null;
            throw TimeoutException(_config.requestTimeout, operation: 'receive');
          },
        );

        // Check if this is a PubSub event (command 0xFF)
        if (data.isNotEmpty && data[0] == pubsubCommand) {
          // This is a PubSub event, pass to message handler and continue waiting
          final handler = _onMessage;
          if (handler != null) {
            try {
              final event = ProtocolDecoder.decodePubSubEvent(data);
              handler(event);
            } catch (e) {
              // Skip malformed events
            }
          }
        } else {
          // This is a response
          response = ProtocolDecoder.decodeResponse(data);
          receivedExpectedResponse = true;
        }
      }

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

  /// Set the PubSub message handler callback
  ///
  /// The callback will be invoked whenever a pub/sub event is received
  /// for any active subscription. Call [receiveMessages] to poll for events.
  ///
  /// Example:
  /// ```dart
  /// client.onMessage = (event) {
  ///   print('Received: ${event.topic} -> ${event.payload}');
  /// };
  /// ```
  void setOnMessage(void Function(PubSubEvent) callback) {
    _onMessage = callback;
  }

  /// Receive and process pending pub/sub messages
  ///
  /// This method should be called periodically (or in a loop) to process
  /// pub/sub events that arrive from the server. Events will be passed to
  /// the callback set via [setOnMessage].
  ///
  /// Returns the number of events processed.
  Future<int> receiveMessages({Duration timeout = const Duration(milliseconds: 100)}) async {
    if (!isConnected || _onMessage == null) {
      return 0;
    }

    final ws = _ws;
    if (ws == null) return 0;

    var processed = 0;

    // Try to receive messages (non-blocking with timeout)
    try {
      final data = await ws.receive().timeout(timeout, onTimeout: () {
        throw TimeoutException(timeout);
      });

      // Check if this is a pub/sub event (command 0xFF)
      if (ProtocolDecoder.isPubSubEvent(data)) {
        try {
          final event = ProtocolDecoder.decodePubSubEvent(data);
          _onMessage!(event);
          processed++;
        } catch (e) {
          // Log error but don't throw
        }
      }
      // If not an event, it's a response (shouldn't happen here)
    } on TimeoutException {
      // Expected when no messages available
    } catch (e) {
      // Ignore other errors
    }

    return processed;
  }

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

    // Track subscription
    _subscriptions.add(subId);

    return subId;
  }

  /// Subscribe to exact topic with default options
  Future<String> subscribeSimple(String topic) async {
    return subscribe(topic);
  }

  /// Check if subscription is active
  bool isSubscribed(String subId) {
    return _subscriptions.contains(subId);
  }

  /// Unsubscribe from subscription
  /// Returns true if subscription existed and was removed
  Future<bool> unsubscribe(String subId) async {
    final existed = _subscriptions.contains(subId);

    if (!existed) {
      return false;
    }

    await _sendRequest(
      command: Command.unsubscribe,
      key: subId,
      value: '',
    );

    _subscriptions.remove(subId);
    return true;
  }

  /// Unsubscribe from all active subscriptions
  /// Returns the number of subscriptions removed
  Future<int> unsubscribeAll() async {
    final subIds = _subscriptions.toList();
    var removed = 0;

    for (final subId in subIds) {
      if (await unsubscribe(subId)) {
        removed++;
      }
    }

    return removed;
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
  ///
  /// Returns a list of subscription information including subscription ID,
  /// client ID, and topic/pattern details.
  Future<List<SubscriptionInfo>> listSubscribers(String topic) async {
    final value = await _sendRequest(
      command: Command.listSubscribers,
      key: '',
      value: topic,
    );

    return ProtocolDecoder.decodeListSubscribersResponse(value);
  }

  /// List all topics
  ///
  /// Returns a list of topic information including name, sequence number,
  /// subscriber count, and message count.
  Future<List<TopicInfo>> listTopics() async {
    final value = await _sendRequest(
      command: Command.listTopics,
      key: '',
      value: '',
    );

    return ProtocolDecoder.decodeListTopicsResponse(value);
  }

  /// Get message history for topic
  ///
  /// Returns a sequence of historical pub/sub events.
  /// [limit]: Maximum number of messages to return (default: 100)
  /// [sinceSeq]: Only return messages with sequence >= this value (default: 0)
  Future<List<PubSubEvent>> getHistory(
    String topic, {
    int limit = 100,
    int sinceSeq = 0,
  }) async {
    final encodedParams = ProtocolEncoder.encodeHistoryRequest(
      topic: topic,
      count: limit,
      sinceSeq: sinceSeq,
    );

    final value = await _sendRequest(
      command: Command.history,
      key: '',
      binaryValue: encodedParams,
    );

    return ProtocolDecoder.decodeHistoryResponse(value);
  }

  /// Get presence info for topic
  ///
  /// Returns presence information for subscribers on a topic.
  /// Requires clients to have subscribed with enablePresence: true.
  Future<PresenceInfo> getPresence(String topic) async {
    // Request: topic as key, presence operation as value
    // Presence request is encoded separately
    final encodedParams = ProtocolEncoder.encodePresenceRequest(
      operation: 0, // Get online presence
    );

    final value = await _sendRequest(
      command: Command.presence,
      key: topic,
      binaryValue: encodedParams,
    );

    return ProtocolDecoder.decodePresenceResponse(topic, value);
  }
}
