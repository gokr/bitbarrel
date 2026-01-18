"""BitBarrel WebSocket client implementation."""

import threading
import time
from typing import List, Tuple, Optional, Union, Callable
from .protocol import (
    Command, Status, TopicInfo,
    encode_request, decode_response, decode_response_raw,
    encode_range_request, decode_range_response, decode_keys_response,
    encode_prefix_request,
    encode_traverse_request, decode_traverse_response,
    status_to_error,
    PubSubMessageType, PubSubEvent,
    encode_subscribe_request, decode_subscribe_response,
    encode_publish_request, decode_publish_response,
    decode_pubsub_event, is_pubsub_event,
    encode_history_request, encode_presence_request,
    decode_list_subscribers_response, decode_list_topics_response,
    decode_history_response, decode_presence_response,
    SubscriptionOptions, default_subscription_options,
    PresenceMember, PresenceInfo, SubscriptionInfo, HistoryRequest,
)
from .websocket import WebSocket
from .errors import (
    ConnectionError, NotFoundError, NoBarrelError, ServerError, TimeoutError,
)


class RangeResult:
    """Result from range or prefix query."""

    def __init__(self, items: List[Tuple[str, str]], next_cursor: str, has_more: bool):
        self.items = items
        self.next_cursor = next_cursor
        self.has_more = has_more


class KeysResult:
    """Result from keys-only range or prefix query."""

    def __init__(self, keys: List[str], next_cursor: str, has_more: bool):
        self.keys = keys
        self.next_cursor = next_cursor
        self.has_more = has_more


class TraverseResult:
    """Result from reference traversal."""

    def __init__(self, path: str, key: str, value: str = "", extracted_data: str = ""):
        self.path = path
        self.key = key
        self.value = value
        self.extracted_data = extracted_data


class Client:
    """BitBarrel WebSocket client for remote key-value storage.

    The client communicates with a BitBarrel server using WebSocket protocol.
    """

    def __init__(self, host: str = "localhost", port: int = 9876,
                 connect_timeout: float = 5.0, request_timeout: float = 3.0,
                 token: Optional[str] = None):
        """Create a new BitBarrel client.

        Args:
            host: Server hostname or IP address
            port: Server port
            connect_timeout: Timeout for initial connection in seconds
            request_timeout: Timeout for operations in seconds
            token: Optional JWT token for authentication
        """
        self.host = host
        self.port = port
        self._connect_timeout = connect_timeout
        self._request_timeout = request_timeout
        self._token = token
        self._ws: Optional[WebSocket] = None
        self._seq_counter = 0
        self._current_barrel = ""
        self._lock = threading.Lock()
        self._connected = False
        # Pub/Sub support
        self._subscriptions: dict[str, SubscriptionInfo] = {}
        self._on_message: Optional[Callable[[PubSubEvent], None]] = None
        self._event_receiver_thread: Optional[threading.Thread] = None
        self._event_receiver_stop = threading.Event()

    def connect(self) -> None:
        """Connect to the BitBarrel server.

        Raises:
            ConnectionError: If connection fails
            TimeoutError: If connection times out
        """
        address = f"{self.host}:{self.port}"

        # Prepare headers including JWT token if provided
        headers = {}
        if self._token:
            headers["Authorization"] = f"Bearer {self._token}"

        self._ws = WebSocket(address, self._connect_timeout, self._request_timeout, headers)
        self._ws.connect()
        self._connected = True

    def close(self) -> None:
        """Close the connection to the server."""
        if self._ws:
            self._ws.close()
            self._ws = None
        self._connected = False

    def __enter__(self):
        """Context manager entry: connect to the server."""
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit: close the connection."""
        self.close()
        return False

    @property
    def connected(self) -> bool:
        """Check if connected to the server."""
        return self._connected

    @property
    def current_barrel(self) -> str:
        """Get the current barrel name."""
        return self._current_barrel

    # Barrel management operations

    def create_barrel(self, name: str, config: str = "") -> bool:
        """Create a new barrel on the server.

        Args:
            name: Barrel name
            config: Optional configuration JSON string

        Returns:
            True on success

        Raises:
            BarrelExistsError: If barrel already exists
            ServerError: If server reports an error
        """
        self._send_request(Command.CREATE_BARREL, name, config)
        return True

    def open_barrel(self, name: str) -> bool:
        """Open an existing barrel on the server.

        Args:
            name: Barrel name

        Returns:
            True on success

        Raises:
            BarrelNotFoundError: If barrel doesn't exist
            ServerError: If server reports an error
        """
        self._send_request(Command.OPEN_BARREL, name, "")
        return True

    def use_barrel(self, name: str) -> bool:
        """Set the current barrel for this session.

        Args:
            name: Barrel name

        Returns:
            True on success

        Raises:
            BarrelNotFoundError: If barrel doesn't exist
            ServerError: If server reports an error
        """
        self._send_request(Command.USE_BARREL, name, "")
        self._current_barrel = name
        return True

    def list_barrels(self) -> List[str]:
        """List all available barrels on the server.

        Returns:
            List of barrel names

        Raises:
            ServerError: If server reports an error
        """
        value = self._send_request(Command.LIST_BARRELS, "", "")
        if not value:
            return []
        return value.split(",") if value else []

    def close_barrel(self, name: Optional[str] = None) -> bool:
        """Close a barrel.

        Args:
            name: Barrel name, or None to close current barrel

        Returns:
            True on success

        Raises:
            ServerError: If server reports an error
        """
        barrel_name = name or self._current_barrel
        if not barrel_name:
            return True
        self._send_request(Command.CLOSE_BARREL, barrel_name, "")
        if barrel_name == self._current_barrel:
            self._current_barrel = ""
        return True

    def drop_barrel(self, name: str) -> bool:
        """Delete a barrel and all its data.

        Args:
            name: Barrel name

        Returns:
            True on success

        Raises:
            BarrelNotFoundError: If barrel doesn't exist
            ServerError: If server reports an error
        """
        self._send_request(Command.DROP_BARREL, name, "")
        if name == self._current_barrel:
            self._current_barrel = ""
        return True

    def get_barrel_config(self, name: str) -> str:
        """Get the configuration for a barrel.

        Args:
            name: Barrel name

        Returns:
            Barrel configuration as JSON string

        Raises:
            BarrelNotFoundError: If barrel doesn't exist
            ServerError: If server reports an error
        """
        return self._send_request(Command.GET_BARREL_CONFIG, name, "")

    def set_barrel_config(self, name: str, config: str) -> bool:
        """Set the configuration for a barrel.

        Args:
            name: Barrel name
            config: Configuration as JSON string

        Returns:
            True on success

        Raises:
            BarrelNotFoundError: If barrel doesn't exist
            ServerError: If server reports an error
        """
        self._send_request(Command.SET_BARREL_CONFIG, name, config)
        return True

    def get_barrel_stats(self, name: str) -> str:
        """Get comprehensive statistics for a barrel.

        Args:
            name: Barrel name

        Returns:
            Barrel statistics as JSON string containing metrics like:
            - totalKeys: Total keys including tombstones
            - activeKeys: Active keys (excluding tombstones)
            - deletedKeys: Tombstone/deleted keys
            - fileCount: Number of data files
            - totalSize: Total bytes on disk for all files
            - activeFileSize: Size of active data file
            - avgKeySize: Average key size in bytes
            - avgValueSize: Average value size in bytes
            - avgRecordSize: Average record size in bytes
            - fragmentationRatio: Fragmentation ratio (0.0 to 1.0)
            - isCompacting: Is compaction currently in progress
            - lastCompactTime: ISO timestamp of last compaction
            - recordsScanned: Records scanned in last compaction
            - recordsKept: Records kept in last compaction
            - recordsDropped: Records dropped in last compaction
            - indexMode: Index mode (hash, critbit, hugecritbit)
            - syncMode: Sync mode (none, sync, fsync)
            - dataPath: Path to data files
            - lastModified: ISO timestamp of last modification

        Raises:
            BarrelNotFoundError: If barrel doesn't exist
            ServerError: If server reports an error
            UnauthorizedError: If read access is required but not available

        Example:
            stats_json = client.get_barrel_stats("mydb")
            import json
            stats = json.loads(stats_json)
            print(f"Total keys: {stats['totalKeys']}")
            print(f"Disk usage: {stats['totalSize']} bytes")
            print(f"Fragmentation: {stats['fragmentationRatio'] * 100:.1f}%")
        """
        return self._send_request(Command.GET_BARREL_STATS, name, "")

    # Basic key-value operations

    def get(self, key: str) -> str:
        """Get value by key.

        Args:
            key: Key to retrieve

        Returns:
            Value associated with key

        Raises:
            NoBarrelError: If no barrel selected
            NotFoundError: If key not found
            ServerError: If server reports an error
        """
        self._ensure_barrel()
        value = self._send_request(Command.GET, key, "")
        # _send_request raises NotFoundError for NOT_FOUND status
        # But if it returns empty string without error, that's a valid empty value
        return value

    def get_or_default(self, key: str, default: str = "") -> str:
        """Get value by key, returning default if key doesn't exist.

        Args:
            key: Key to retrieve
            default: Default value to return if key not found (default: "")

        Returns:
            Value associated with key, or default if key not found

        Raises:
            NoBarrelError: If no barrel selected
            ServerError: If server reports an error (other than not found)
        """
        self._ensure_barrel()
        try:
            return self._send_request(Command.GET, key, "")
        except NotFoundError:
            return default

    def set(self, key: str, value: str) -> bool:
        """Set key-value pair.

        Args:
            key: Key to set
            value: Value to associate with key

        Returns:
            True on success

        Raises:
            NoBarrelError: If no barrel selected
            ServerError: If server reports an error
        """
        self._ensure_barrel()
        self._send_request(Command.SET, key, value)
        return True

    def delete(self, key: str) -> bool:
        """Delete a key from the current barrel.

        Args:
            key: Key to delete

        Returns:
            True on success

        Raises:
            NoBarrelError: If no barrel selected
            ServerError: If server reports an error
        """
        self._ensure_barrel()
        self._send_request(Command.DELETE, key, "")
        return True

    def exists(self, key: str) -> bool:
        """Check if key exists in the current barrel.

        Args:
            key: Key to check

        Returns:
            True if key exists, False otherwise

        Raises:
            NoBarrelError: If no barrel selected
            ServerError: If server reports an error
        """
        self._ensure_barrel()
        value = self._send_request(Command.EXISTS, key, "")
        return value == "true"

    def count(self) -> int:
        """Count all keys in the current barrel.

        Returns:
            Number of keys

        Raises:
            NoBarrelError: If no barrel selected
            ServerError: If server reports an error
        """
        self._ensure_barrel()
        value = self._send_request(Command.COUNT, "", "")
        try:
            return int(value)
        except ValueError:
            raise ServerError(f"Invalid count response: {value}")

    def list_keys(self) -> List[str]:
        """List all keys in the current barrel.

        Returns:
            List of keys

        Raises:
            NoBarrelError: If no barrel selected
            ServerError: If server reports an error
        """
        self._ensure_barrel()
        value = self._send_request(Command.LIST_KEYS, "", "")
        if not value:
            return []
        return value.split(",") if value else []

    def _send_request_raw(self, cmd: int, key: str = "", value: Union[str, bytes] = "") -> Tuple[int, bytes]:
        """Internal: send request and get raw WebSocket response bytes.

        Returns the sequence number used and the raw WebSocket response data.
        Used for cases where we need to handle potentially binary response data.

        Returns:
            Tuple of (sequence_number, raw_response_data)
        """
        self._ensure_connected()

        with self._lock:
            # Get next sequence number (inline to avoid deadlock)
            seq = self._seq_counter
            self._seq_counter += 1

            # Encode request
            data = encode_request(cmd, seq, key, value if isinstance(value, str) else "")

            # Send request
            self._ws.send_binary(data)

            # Receive response
            try:
                response_data = self._ws.recv_binary()
                return seq, response_data
            except ConnectionError:
                self._connected = False
                raise

    def ping(self) -> bool:
        """Ping the server to verify connectivity.

        Returns:
            True if server responds with pong

        Raises:
            ConnectionError: If not connected or ping fails
            TimeoutError: If ping times out
        """
        response = self._send_request(Command.PING, "", "")
        if response != "pong":
            raise ConnectionError("Ping failed - expected 'pong', got: " + response)
        return True

    # Range query operations (require bmCritBit mode barrel)

    def range_query(self, start_key: str, end_key: str,
                  limit: int = 1000, cursor: str = "") -> RangeResult:
        """Query key-value pairs in range [startKey, endKey) with cursor pagination.

        Requires barrel opened in bmCritBit mode.

        Args:
            start_key: Start key (inclusive)
            end_key: End key (exclusive)
            limit: Maximum number of items to return
            cursor: Last key from previous page (empty for first page)

        Returns:
            RangeResult with items, next cursor, and hasMore flag

        Raises:
            NoBarrelError: If no barrel selected
            ServerError: If server reports an error
        """
        self._ensure_barrel()
        params = encode_range_request(start_key, end_key, limit, cursor)
        value = self._send_request_binary(Command.RANGE_QUERY, "", params)
        items, next_cursor, has_more = decode_range_response(value)
        return RangeResult(items, next_cursor, has_more)

    def prefix_query(self, prefix: str, limit: int = 1000,
                    cursor: str = "") -> RangeResult:
        """Query key-value pairs with prefix and cursor pagination.

        Requires barrel opened in bmCritBit mode.

        Args:
            prefix: Key prefix to match
            limit: Maximum number of items to return
            cursor: Last key from previous page (empty for first page)

        Returns:
            RangeResult with items, next cursor, and hasMore flag

        Raises:
            NoBarrelError: If no barrel selected
            ServerError: If server reports an error
        """
        self._ensure_barrel()
        params = encode_prefix_request(prefix, limit, cursor)
        value = self._send_request_binary(Command.PREFIX_QUERY, "", params)
        items, next_cursor, has_more = decode_range_response(value)
        return RangeResult(items, next_cursor, has_more)

    def range_count(self, start_key: str, end_key: str) -> int:
        """Count keys in range [startKey, endKey).

        Requires barrel opened in bmCritBit mode.

        Args:
            start_key: Start key (inclusive)
            end_key: End key (exclusive)

        Returns:
            Number of keys in range

        Raises:
            NoBarrelError: If no barrel selected
            ServerError: If server reports an error
        """
        self._ensure_barrel()
        params = encode_range_request(start_key, end_key, 0, "")
        value = self._send_request(Command.RANGE_COUNT, "", params)
        try:
            return int(value)
        except ValueError:
            raise ServerError(f"Invalid count response: {value}")

    def range_query_keys(self, start_key: str, end_key: str,
                        limit: int = 1000, cursor: str = "") -> KeysResult:
        """Query only keys in range [startKey, endKey) with cursor pagination.

        Requires barrel opened in bmCritBit mode.
        Empty start_key/end_key queries entire barrel.

        Args:
            start_key: Start key (inclusive), or "" for first key
            end_key: End key (exclusive), or "" for end of barrel
            limit: Maximum number of keys to return
            cursor: Last key from previous page (empty for first page)

        Returns:
            KeysResult with keys, next cursor, and hasMore flag

        Raises:
            NoBarrelError: If no barrel selected
            ServerError: If server reports an error
        """
        self._ensure_barrel()
        params = encode_range_request(start_key, end_key, limit, cursor)
        value = self._send_request_binary(Command.RANGE_KEYS, "", params)
        keys, next_cursor, has_more = decode_keys_response(value)
        return KeysResult(keys, next_cursor, has_more)

    def prefix_query_keys(self, prefix: str, limit: int = 1000,
                         cursor: str = "") -> KeysResult:
        """Query only keys with prefix and cursor pagination.

        Requires barrel opened in bmCritBit mode.

        Args:
            prefix: Key prefix to match
            limit: Maximum number of keys to return
            cursor: Last key from previous page (empty for first page)

        Returns:
            KeysResult with keys, next cursor, and hasMore flag

        Raises:
            NoBarrelError: If no barrel selected
            ServerError: If server reports an error
        """
        self._ensure_barrel()
        params = encode_prefix_request(prefix, limit, cursor)
        value = self._send_request_binary(Command.PREFIX_KEYS, "", params)
        keys, next_cursor, has_more = decode_keys_response(value)
        return KeysResult(keys, next_cursor, has_more)

    # Reference traversal

    def traverse(self, key: str, path_spec: str,
               include_full_data: bool = False, extract_arrays: bool = False,
               first_only: bool = False) -> List[TraverseResult]:
        """Traverse references from a key using path specification.

        PathSpec syntax:
        - Specify "*" for single reference
        - Specify "->" to chain references

        Args:
            key: Starting key for traversal
            pathSpec: Path specification string
            include_full_data: Include full values in results
            extract_arrays: Extract array elements individually
            first_only: Stop after first result

        Returns:
            List of TraverseResult with path, key, value, extractedData

        Raises:
            NoBarrelError: If no barrel selected
            ServerError: If server reports an error
        """
        self._ensure_barrel()

        # Build options byte
        options_byte = 0
        if include_full_data:
            options_byte |= 0x01
        if extract_arrays:
            options_byte |= 0x02
        if first_only:
            options_byte |= 0x04

        with self._lock:
            seq = self._next_seq_unlocked()
            params = encode_traverse_request(seq, key, path_spec, options_byte)

            # Send traverse request
            header = encode_request(Command.TRAVERSE, "", params)
            self._ws.send_binary(header)

            # Receive special traversed response
            response_data = self._ws.recv_binary()
            status, seq_resp, results = decode_traverse_response(response_data)

            if status != Status.OK:
                raise ServerError(f"Traversal failed: status=0x{status:02x}")

            return [
                TraverseResult(
                    path=r["path"],
                    key=r["key"],
                    value=r["value"],
                    extracted_data=r.get("extractedData", ""),
                )
                for r in results
            ]

    def traverse_path(self, key: str, path_spec: str) -> List[TraverseResult]:
        """Traverse with default options (include full data, no extraction).

        Args:
            key: Starting key for traversal
            pathSpec: Path specification string

        Returns:
            List of TraverseResult

        Raises:
            NoBarrelError: If no barrel selected
            ServerError: If server reports an error
        """
        return self.traverse(key, path_spec, include_full_data=True)

    # ============================================================================
    # Pub/Sub Methods
    # ============================================================================

    def subscribe(self, topic: str, options: Optional[SubscriptionOptions] = None) -> str:
        """Subscribe to topic with options (supports pattern matching with *).

        Args:
            topic: Topic name (may contain * pattern for wildcard matching)
            options: Subscription options (defaults if None)

        Returns:
            Subscription ID

        Raises:
            ConnectionError: If not connected
            ServerError: If subscription fails
        """
        if options is None:
            options = default_subscription_options()

        # Determine if this is a pattern subscription
        is_pattern = "*" in topic
        actual_topic = ""
        actual_pattern = ""
        if is_pattern:
            actual_pattern = topic
        else:
            actual_topic = topic

        # Encode subscribe request
        subscribe_data = encode_subscribe_request(actual_topic, actual_pattern, options)

        # Send request (value contains the encoded subscribe data)
        value = self._send_request(Command.SUBSCRIBE, "", subscribe_data)

        # The response value is the subscription ID
        sub_id = value
        if not sub_id:
            raise ServerError("Empty subscription ID received from server")

        # Track subscription
        self._subscriptions[sub_id] = SubscriptionInfo(sub_id, actual_topic, actual_pattern)

        return sub_id

    def subscribe_simple(self, topic: str) -> str:
        """Subscribe to exact topic with default options.

        Args:
            topic: Exact topic name (no patterns)

        Returns:
            Subscription ID

        Raises:
            ConnectionError: If not connected
            ServerError: If subscription fails
        """
        return self.subscribe(topic, default_subscription_options())

    def is_subscribed(self, sub_id: str) -> bool:
        """Check if subscription is active.

        Args:
            sub_id: Subscription ID

        Returns:
            True if subscription is active
        """
        return sub_id in self._subscriptions

    def unsubscribe(self, sub_id: str) -> bool:
        """Unsubscribe from subscription.

        Args:
            sub_id: Subscription ID

        Returns:
            True if subscription existed and was removed

        Raises:
            ConnectionError: If not connected
            ServerError: If unsubscribe fails
        """
        if sub_id not in self._subscriptions:
            return False

        self._send_request(Command.UNSUBSCRIBE, sub_id, "")
        self._subscriptions.pop(sub_id, None)
        return True

    def unsubscribe_all(self) -> int:
        """Unsubscribe from all active subscriptions.

        Returns:
            Number of subscriptions removed
        """
        count = 0
        sub_ids = list(self._subscriptions.keys())
        for sub_id in sub_ids:
            if self.unsubscribe(sub_id):
                count += 1
        return count

    def publish(self, topic: str, msg_type: int, payload: str, headers: str = "") -> int:
        """Publish message with type and headers to topic.

        Args:
            topic: Topic name
            msg_type: Message type (PubSubMessageType.DATA or PRESENCE)
            payload: Message payload
            headers: Optional headers as JSON string

        Returns:
            Sequence number

        Raises:
            ConnectionError: If not connected
            ServerError: If publish fails
        """
        publish_data = encode_publish_request(topic, msg_type, payload, headers)
        value = self._send_request(Command.PUBLISH, "", publish_data)
        return decode_publish_response(value.encode("utf-8"))

    def publish_simple(self, topic: str, msg_type: int, payload: str) -> int:
        """Publish message with type to topic (no headers).

        Args:
            topic: Topic name
            msg_type: Message type
            payload: Message payload

        Returns:
            Sequence number
        """
        return self.publish(topic, msg_type, payload, "")

    def publish_data(self, topic: str, payload: str) -> int:
        """Publish data message to topic.

        Args:
            topic: Topic name
            payload: Message payload

        Returns:
            Sequence number
        """
        return self.publish(topic, PubSubMessageType.DATA, payload, "")

    def list_subscribers(self, topic: str) -> List[SubscriptionInfo]:
        """List subscribers for a topic.

        Args:
            topic: Topic name

        Returns:
            List of subscription information

        Raises:
            ConnectionError: If not connected
            ServerError: If request fails
        """
        # List subscribers request uses empty key, topic is in response
        value = self._send_request(Command.LIST_SUBSCRIBERS, topic, "")
        return decode_list_subscribers_response(value)

    def list_topics(self) -> List[TopicInfo]:
        """List all topics.

        Returns:
            List of topic information

        Raises:
            ConnectionError: If not connected
            ServerError: If request fails
        """
        value = self._send_request(Command.LIST_TOPICS, "", "")
        return decode_list_topics_response(value)

    def get_history(self, topic: str, limit: int = 100, since_seq: int = 0) -> List[PubSubEvent]:
        """Get message history for topic.

        Args:
            topic: Topic name
            limit: Maximum number of messages to retrieve (default: 100)
            since_seq: Retrieve messages with sequence > since_seq (default: 0)

        Returns:
            List of historical PubSubEvents

        Raises:
            ConnectionError: If not connected
            ServerError: If request fails
        """
        # Encode history request
        history_data = encode_history_request(topic, limit, since_seq)
        value = self._send_request(Command.HISTORY, "", history_data)
        return decode_history_response(value)

    def get_presence(self, topic: str) -> PresenceInfo:
        """Get presence info for topic.

        Args:
            topic: Topic name

        Returns:
            Presence information with member list

        Raises:
            ConnectionError: If not connected
            ServerError: If request fails
        """
        # Presence request: operation 0 = get_online
        presence_data = encode_presence_request(0)
        value = self._send_request(Command.PRESENCE, topic, presence_data)
        return decode_presence_response(topic, value)

    def set_message_handler(self, handler: Callable[[PubSubEvent], None]) -> None:
        """Set the callback function for PubSub events.

        Args:
            handler: Callback function that receives PubSubEvent
        """
        self._on_message = handler

    def start_event_receiver(self) -> None:
        """Start a background thread to receive PubSub events."""
        if self._event_receiver_thread and self._event_receiver_thread.is_alive():
            return  # Already running

        self._event_receiver_stop.clear()
        self._event_receiver_thread = threading.Thread(
            target=self._receive_pubsub_events, daemon=True)
        self._event_receiver_thread.start()

    def stop_event_receiver(self) -> None:
        """Stop the event receiver thread."""
        if self._event_receiver_thread and self._event_receiver_thread.is_alive():
            self._event_receiver_stop.set()
            self._event_receiver_thread.join(timeout=2.0)

    def _receive_pubsub_events(self) -> None:
        """Background thread function to receive PubSub events."""
        while not self._event_receiver_stop.is_set():
            with self._lock:
                if not self._ws:
                    break

                # Try to read a message without blocking
                self._ws.set_timeout(0.1)  # 100ms timeout
                try:
                    data = self._ws.recv_binary()
                    # Reset timeout back to original after receiving
                    self._ws.reset_timeout()
                except TimeoutError:
                    continue
                except ConnectionError:
                    # Connection closed
                    self._connected = False
                    break

            # Check if this is a PubSub event (command 0xFF)
            if is_pubsub_event(data):
                try:
                    event = decode_pubsub_event(data)

                    # Call message handler if set
                    handler = self._on_message
                    if handler:
                        handler(event)
                except Exception:
                    # Skip malformed events
                    pass

    # Connection lifecycle

    def _ensure_connected(self) -> None:
        """Internal: ensure client is connected."""
        if not self._connected:
            self.connect()

    def _ensure_barrel(self) -> None:
        """Internal: ensure a barrel is selected.

        Raises:
            NoBarrelError: If no barrel selected
        """
        if not self._current_barrel:
            raise NoBarrelError("No barrel selected. Call use_barrel() first.")

    def _next_seq_unlocked(self) -> int:
        """Internal: get next sequence number.

        IMPORTANT: Caller must hold self._lock before calling this method.
        """
        seq = self._seq_counter
        self._seq_counter += 1
        return seq

    def _send_request(self, cmd: int, key: str = "", value: Union[str, bytes] = "") -> Optional[str]:
        """Internal: send request and get response.

        Returns:
            Response value, or None if status not OK

        Raises:
            ConnectionError: If connection issues
            TimeoutError: If request timeout
            NotFoundError: If key not found
            NoBarrelError: If no barrel selected
            BarrelExistsError: If barrel already exists
            BarrelNotFoundError: If barrel not found
            InvalidRequestError: If invalid request parameters
            ServerError: If server error
        """
        self._ensure_connected()

        with self._lock:
            # Get next sequence number (inline to avoid deadlock)
            seq = self._seq_counter
            self._seq_counter += 1

            # Encode request
            data = encode_request(cmd, seq, key, value)

            # Send request
            self._ws.send_binary(data)

            # Receive response, handling any interleaved pubsub events
            max_attempts = 10  # Prevent infinite loop
            for _ in range(max_attempts):
                try:
                    response_data = self._ws.recv_binary()
                except ConnectionError:
                    self._connected = False
                    raise

                # Check if this is a pubsub event instead of a response
                if is_pubsub_event(response_data):
                    # Queue the event for the handler and continue waiting for response
                    try:
                        event = decode_pubsub_event(response_data)
                        handler = self._on_message
                        if handler:
                            handler(event)
                    except Exception:
                        pass  # Skip malformed events
                    continue

                # This is a response, decode it
                status, resp_seq, resp_value = decode_response(response_data)

                # Verify sequence
                if resp_seq != seq:
                    raise ServerError(f"Sequence mismatch: expected {seq}, got {resp_seq}")

                # Handle status
                if status != Status.OK:
                    err = status_to_error(status, resp_value)
                    if err:
                        raise err
                    # Special case for EXISTS with NOT_FOUND
                    if cmd == Command.EXISTS and status == Status.NOT_FOUND:
                        return "false"
                    elif status == Status.NOT_FOUND:
                        raise NotFoundError(f"Key not found: {key}")

                return resp_value

            raise ServerError("Too many interleaved events while waiting for response")

    def _send_request_binary(self, cmd: int, key: str = "", value: Union[str, bytes] = "") -> bytes:
        """Internal: send request and get raw bytes response.

        Same as _send_request but returns raw bytes for the value instead of string.
        Used for range queries and other binary responses.

        Returns:
            Raw response value as bytes

        Raises:
            ConnectionError: If connection issues
            TimeoutError: If request timeout
            NoBarrelError: If no barrel selected
            ServerError: If server error
        """
        self._ensure_connected()

        with self._lock:
            # Get next sequence number (inline to avoid deadlock)
            seq = self._seq_counter
            self._seq_counter += 1

            # Encode request
            data = encode_request(cmd, seq, key, value)

            # Send request
            self._ws.send_binary(data)

            # Receive response, handling any interleaved pubsub events
            max_attempts = 10  # Prevent infinite loop
            for _ in range(max_attempts):
                try:
                    response_data = self._ws.recv_binary()
                except ConnectionError:
                    self._connected = False
                    raise

                # Check if this is a pubsub event instead of a response
                if is_pubsub_event(response_data):
                    # Queue the event for the handler and continue waiting for response
                    try:
                        event = decode_pubsub_event(response_data)
                        handler = self._on_message
                        if handler:
                            handler(event)
                    except Exception:
                        pass  # Skip malformed events
                    continue

                # Decode response (raw bytes)
                status, resp_seq, resp_value = decode_response_raw(response_data)

                # Verify sequence
                if resp_seq != seq:
                    raise ServerError(f"Sequence mismatch: expected {seq}, got {resp_seq}")

                # Handle status
                if status != Status.OK:
                    err = status_to_error(status, resp_value.decode("utf-8", errors="replace"))
                    if err:
                        raise err

                return resp_value

            raise ServerError("Too many interleaved events while waiting for response")
