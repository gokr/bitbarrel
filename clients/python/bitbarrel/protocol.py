"""Binary protocol codec for BitBarrel WebSocket communication.

Request Format: [type:1][seq:4][keyLen:2][key:N][valLen:4][value:M]
Response Format: [status:1][seq:4][valLen:4][value:M]

All multi-byte integers use big-endian encoding.
"""

import struct
from enum import IntEnum
from typing import List, Tuple, Optional, Union


class ProtocolError(Exception):
    """Protocol encoding/decoding error."""
    pass


class Command(IntEnum):
    """Command types (must match BitBarrel server)."""
    GET = 0x01
    SET = 0x02
    DELETE = 0x03
    EXISTS = 0x04
    COUNT = 0x05
    LIST_KEYS = 0x06
    PING = 0x09
    TRAVERSE = 0x20
    RANGE_QUERY = 0x21
    PREFIX_QUERY = 0x22
    RANGE_COUNT = 0x23
    RANGE_KEYS = 0x24
    PREFIX_KEYS = 0x25
    CREATE_BARREL = 0x10
    OPEN_BARREL = 0x11
    USE_BARREL = 0x12
    CLOSE_BARREL = 0x13
    LIST_BARRELS = 0x14
    DROP_BARREL = 0x15
    GET_BARREL_CONFIG = 0x16
    SET_BARREL_CONFIG = 0x17
    GET_BARREL_STATS = 0x18
    # Pub/Sub commands
    SUBSCRIBE = 0x40
    UNSUBSCRIBE = 0x41
    PUBLISH = 0x42
    LIST_SUBSCRIBERS = 0x43
    HISTORY = 0x44
    LIST_TOPICS = 0x45
    PRESENCE = 0x46
    # PubSubEvent is sent as push notification
    PUBSUB_EVENT = 0xFF
    # Batch operations
    BATCH_GET = 0x26
    BATCH_SET = 0x27
    BATCH_DELETE = 0x28


class Status(IntEnum):
    """Response status codes."""
    OK = 0x00
    NOT_FOUND = 0x01
    ERROR = 0x02
    INVALID = 0x03
    NO_BARREL = 0x04
    BARREL_EXISTS = 0x05
    BARREL_NOT_FOUND = 0x06


# Constants
MAX_KEY_SIZE = 65535      # 64KB
MAX_VALUE_SIZE = 33554432  # 32MB (from updated protocol.go)


def encode_request(cmd: int, seq: int, key: str = "", value: Union[str, bytes] = "", ttl: Optional[int] = None) -> bytes:
    """Encode a request to binary format (v1.1).

    Format: [cmd:1][seq:4][flags:1][keyLen:2][key:N][valLen:4][value:M][ttl:4|0]

    Args:
        cmd: Command byte
        seq: Sequence number
        key: Key string
        value: Value as string or bytes (for binary payloads like range queries)
        ttl: Optional TTL in seconds (protocol v1.1+)
    """
    if len(key) > MAX_KEY_SIZE:
        raise ProtocolError(f"Key too large: {len(key)} bytes")
    if len(value) > MAX_VALUE_SIZE:
        raise ProtocolError(f"Value too large: {len(value)} bytes")

    # Encode value to bytes if it's a string
    value_bytes = value if isinstance(value, bytes) else value.encode("utf-8")
    key_bytes = key.encode("utf-8")

    # Check if we should include TTL
    has_ttl = ttl is not None and ttl > 0
    flags = 1 if has_ttl else 0

    # Calculate total size
    total_size = 1 + 4 + 1 + 2 + len(key_bytes) + 4 + len(value_bytes)
    if has_ttl:
        total_size += 4  # Add TTL field (4 bytes)

    buf = bytearray(total_size)

    offset = 0

    # Command (1 byte)
    buf[offset] = cmd
    offset += 1

    # Sequence (4 bytes, big-endian)
    buf[offset:offset+4] = struct.pack(">I", seq)
    offset += 4

    # Flags (1 byte) - 1 if TTL present, 0 otherwise
    buf[offset] = flags
    offset += 1

    # Key length (2 bytes, big-endian)
    buf[offset:offset+2] = struct.pack(">H", len(key_bytes))
    offset += 2

    # Key
    buf[offset:offset+len(key_bytes)] = key_bytes
    offset += len(key_bytes)

    # Value length (4 bytes, big-endian)
    buf[offset:offset+4] = struct.pack(">I", len(value_bytes))
    offset += 4

    # Value
    buf[offset:offset+len(value_bytes)] = value_bytes
    offset += len(value_bytes)

    # TTL (4 bytes, big-endian) if present
    if has_ttl:
        buf[offset:offset+4] = struct.pack(">I", ttl)

    return bytes(buf)


def decode_request(data: bytes) -> Tuple[int, int, str, str]:
    """Decode a request from binary format (v1.1)."""
    if len(data) < 12:  # Minimum: 1+4+1+2+0+4+0
        raise ProtocolError("Request too short")

    offset = 0

    # Command
    cmd = data[offset]
    offset += 1

    # Validate command
    valid_commands = [
        Command.GET, Command.SET, Command.DELETE, Command.EXISTS, Command.COUNT,
        Command.LIST_KEYS, Command.PING, Command.TRAVERSE,
        Command.RANGE_QUERY, Command.PREFIX_QUERY, Command.RANGE_COUNT,
        Command.RANGE_KEYS, Command.PREFIX_KEYS,
        Command.CREATE_BARREL, Command.OPEN_BARREL, Command.USE_BARREL,
        Command.CLOSE_BARREL, Command.LIST_BARRELS, Command.DROP_BARREL,
        Command.GET_BARREL_CONFIG, Command.SET_BARREL_CONFIG, Command.GET_BARREL_STATS
    ]
    if cmd not in valid_commands:
        raise ProtocolError(f"Invalid command: 0x{cmd:02x}")

    # Sequence (4 bytes, big-endian)
    seq = struct.unpack(">I", data[offset:offset+4])[0]
    offset += 4

    # Flags (1 byte) - skip
    offset += 1

    # Key length (2 bytes, big-endian)
    key_len = struct.unpack(">H", data[offset:offset+2])[0]
    offset += 2

    if key_len > MAX_KEY_SIZE:
        raise ProtocolError(f"Key too large: {key_len}")

    if len(data) < offset + key_len + 4:
        raise ProtocolError("Truncated request")

    # Key
    key = data[offset:offset+key_len].decode("utf-8")
    offset += key_len

    # Value length (4 bytes, big-endian)
    value_len = struct.unpack(">I", data[offset:offset+4])[0]
    offset += 4

    if value_len > MAX_VALUE_SIZE:
        raise ProtocolError(f"Value too large: {value_len}")

    if len(data) < offset + value_len:
        raise ProtocolError("Truncated request")

    # Value
    value = data[offset:offset+value_len].decode("utf-8")

    return cmd, seq, key, value


def encode_response(status: int, seq: int, value: str = "") -> bytes:
    """Encode a response to binary format."""
    if len(value) > MAX_VALUE_SIZE:
        raise ProtocolError(f"Value too large: {len(value)} bytes")

    # Calculate total size: 1 + 4 + 4 + value
    total_size = 1 + 4 + 4 + len(value)
    buf = bytearray(total_size)

    offset = 0

    # Status (1 byte)
    buf[offset] = status
    offset += 1

    # Sequence (4 bytes, big-endian)
    buf[offset:offset+4] = struct.pack(">I", seq)
    offset += 4

    # Value length (4 bytes, big-endian)
    buf[offset:offset+4] = struct.pack(">I", len(value))
    offset += 4

    # Value
    buf[offset:offset+len(value)] = value.encode("utf-8")

    return bytes(buf)


def decode_response(data: bytes) -> Tuple[int, int, str]:
    """Decode a response from binary format."""
    if len(data) < 9:  # Minimum: 1+4+4+0
        raise ProtocolError("Response too short")

    offset = 0

    # Status (1 byte)
    status = data[offset]
    offset += 1

    # Validate status
    if status > Status.BARREL_NOT_FOUND:
        raise ProtocolError(f"Invalid status: 0x{status:02x}")

    # Sequence (4 bytes, big-endian)
    seq = struct.unpack(">I", data[offset:offset+4])[0]
    offset += 4

    # Value length (4 bytes, big-endian)
    value_len = struct.unpack(">I", data[offset:offset+4])[0]
    offset += 4

    if value_len > MAX_VALUE_SIZE:
        raise ProtocolError(f"Value too large: {value_len}")

    if len(data) < offset + value_len:
        raise ProtocolError("Truncated response")

    # Value
    value = data[offset:offset+value_len].decode("utf-8")

    return status, seq, value


def decode_response_raw(data: bytes) -> Tuple[int, int, bytes]:
    """Decode a response from binary format, returning raw bytes for value.

    Used for range queries and other binary responses.
    """
    if len(data) < 9:  # Minimum: 1+4+4+0
        raise ProtocolError("Response too short")

    offset = 0

    # Status (1 byte)
    status = data[offset]
    offset += 1

    # Validate status
    if status > Status.BARREL_NOT_FOUND:
        raise ProtocolError(f"Invalid status: 0x{status:02x}")

    # Sequence (4 bytes, big-endian)
    seq = struct.unpack(">I", data[offset:offset+4])[0]
    offset += 4

    # Value length (4 bytes, big-endian)
    value_len = struct.unpack(">I", data[offset:offset+4])[0]
    offset += 4

    if value_len > MAX_VALUE_SIZE:
        raise ProtocolError(f"Value too large: {value_len}")

    if len(data) < offset + value_len:
        raise ProtocolError("Truncated response")

    # Value (raw bytes)
    value = data[offset:offset+value_len]

    return status, seq, value


# Range query encoding

def encode_range_request(start_key: str, end_key: str, limit: int, cursor: str) -> bytes:
    """Encode a range query request."""
    buf = bytearray()

    # Start key
    buf.extend(struct.pack(">H", len(start_key)))
    buf.extend(start_key.encode("utf-8"))

    # End key
    buf.extend(struct.pack(">H", len(end_key)))
    buf.extend(end_key.encode("utf-8"))

    # Limit
    buf.extend(struct.pack(">I", limit))

    # Cursor
    buf.extend(struct.pack(">H", len(cursor)))
    buf.extend(cursor.encode("utf-8"))

    return bytes(buf)


def encode_prefix_request(prefix: str, limit: int, cursor: str) -> bytes:
    """Encode a prefix query request."""
    buf = bytearray()

    # Prefix
    buf.extend(struct.pack(">H", len(prefix)))
    buf.extend(prefix.encode("utf-8"))

    # Limit
    buf.extend(struct.pack(">I", limit))

    # Cursor
    buf.extend(struct.pack(">H", len(cursor)))
    buf.extend(cursor.encode("utf-8"))

    return bytes(buf)


def decode_range_response(data: bytes) -> Tuple[list, str, bool]:
    """Decode a range query response.

    Returns: (items: list of (key, value), nextCursor: str, hasMore: bool)
    """
    buf = data
    offset = 0

    # Count
    count = struct.unpack(">I", buf[offset:offset+4])[0]
    offset += 4

    items = []

    # Items
    for _ in range(count):
        # Key length
        key_len = struct.unpack(">H", buf[offset:offset+2])[0]
        offset += 2

        # Key
        key = buf[offset:offset+key_len].decode("utf-8")
        offset += key_len

        # Value length
        val_len = struct.unpack(">I", buf[offset:offset+4])[0]
        offset += 4

        # Value
        value = buf[offset:offset+val_len].decode("utf-8")
        offset += val_len

        items.append((key, value))

    # Has more
    has_more = buf[offset] != 0
    offset += 1

    # Next cursor length
    cursor_len = struct.unpack(">H", buf[offset:offset+2])[0]
    offset += 2

    # Next cursor
    next_cursor = buf[offset:offset+cursor_len].decode("utf-8")

    return items, next_cursor, has_more


def decode_keys_response(data: bytes) -> Tuple[List[str], str, bool]:
    """Decode a keys-only response.

    Returns: (keys: list of str, nextCursor: str, hasMore: bool)
    """
    buf = data
    offset = 0

    # Count
    count = struct.unpack(">I", buf[offset:offset+4])[0]
    offset += 4

    keys = []

    # Keys
    for _ in range(count):
        # Key length
        key_len = struct.unpack(">H", buf[offset:offset+2])[0]
        offset += 2

        # Key
        key = buf[offset:offset+key_len].decode("utf-8")
        offset += key_len

        keys.append(key)

    # Has more
    has_more = buf[offset] != 0
    offset += 1

    # Next cursor length
    cursor_len = struct.unpack(">H", buf[offset:offset+2])[0]
    offset += 2

    # Next cursor
    next_cursor = buf[offset:offset+cursor_len].decode("utf-8")

    return keys, next_cursor, has_more


# Traversal encoding

def encode_traverse_request(seq: int, key: str, path_spec: str, options_byte: int) -> bytes:
    """Encode a traversal request."""
    buf = bytearray()

    # Sequence
    buf.extend(struct.pack(">I", seq))

    # Key
    buf.extend(struct.pack(">H", len(key)))
    buf.extend(key.encode("utf-8"))

    # Path spec
    buf.extend(struct.pack(">H", len(path_spec)))
    buf.extend(path_spec.encode("utf-8"))

    # Options
    buf.append(options_byte)

    return bytes(buf)


def decode_traverse_response(data: bytes) -> Tuple[int, int, list]:
    """Decode traversal results.

    Returns: (status, seq, results list where each result is dict with path, key, value, extractedData)
    """
    buf = data
    offset = 0

    # Status
    status = buf[offset]
    offset += 1

    # Sequence
    seq = struct.unpack(">I", buf[offset:offset+4])[0]
    offset += 4

    # Count
    count = struct.unpack(">I", buf[offset:offset+4])[0]
    offset += 4

    results = []

    for _ in range(count):
        # Path length
        path_len = struct.unpack(">H", buf[offset:offset+2])[0]
        offset += 2

        # Path
        path = buf[offset:offset+path_len].decode("utf-8")
        offset += path_len

        # Value length
        val_len = struct.unpack(">I", buf[offset:offset+4])[0]
        offset += 4

        # Value
        value = buf[offset:offset+val_len].decode("utf-8") if val_len > 0 else ""
        offset += val_len

        # Extracted data flag
        has_extracted = buf[offset]
        offset += 1

        # Extracted data length
        ext_len = struct.unpack(">I", buf[offset:offset+4])[0]
        offset += 4

        # Extracted data
        extracted_data = ""
        if has_extracted != 0 and ext_len > 0:
            extracted_data = buf[offset:offset+ext_len].decode("utf-8")
            offset += ext_len

        # Extract key from path (last element after -> if present)
        key = path.split("->")[-1] if "->" in path else path

        results.append({
            "path": path,
            "key": key,
            "value": value,
            "extractedData": extracted_data,
        })

    return status, seq, results


def status_to_error(status: int, message: str = "") -> Optional[Exception]:
    """Convert status code to appropriate error."""
    from .errors import (
        NotFoundError, NoBarrelError, BarrelExistsError,
        BarrelNotFoundError, InvalidRequestError, ServerError,
    )

    if status == Status.OK:
        return None
    elif status == Status.NOT_FOUND:
        return NotFoundError(message or "Key not found")
    elif status == Status.NO_BARREL:
        return NoBarrelError("No barrel selected")
    elif status == Status.BARREL_EXISTS:
        return BarrelExistsError("Barrel already exists")
    elif status == Status.BARREL_NOT_FOUND:
        return BarrelNotFoundError("Barrel not found")
    elif status == Status.INVALID:
        return InvalidRequestError(message or "Invalid request")
    elif status == Status.ERROR:
        return ServerError(message or "Server error")
    else:
        return ServerError(f"Unknown status: 0x{status:02x}")


# ============================================================================
# Pub/Sub Support
# ============================================================================

class PubSubMessageType(IntEnum):
    """PubSub message type."""
    DATA = 0
    PRESENCE = 1


class PubSubEvent:
    """Event received from PubSub subscription."""

    def __init__(self, topic: str, message_type: int, sequence: int,
                 timestamp: int, headers: str, payload: str):
        self.topic = topic
        self.message_type = message_type
        self.sequence = sequence
        self.timestamp = timestamp
        self.headers = headers
        self.payload = payload

    def __repr__(self) -> str:
        type_name = "DATA" if self.message_type == PubSubMessageType.DATA else "PRESENCE"
        return (f"PubSubEvent(topic={self.topic!r}, type={type_name}, "
                f"seq={self.sequence}, payload={self.payload!r})")


class SubscriptionOptions:
    """Options for subscribing to a topic."""

    def __init__(self, enable_kv_events: bool = False,
                 enable_presence: bool = False, replay_history: bool = False):
        self.enable_kv_events = enable_kv_events
        self.enable_presence = enable_presence
        self.replay_history = replay_history

    def encode(self) -> int:
        """Encode options to a single byte."""
        opts = 0
        if self.enable_kv_events:
            opts |= 0x01
        if self.enable_presence:
            opts |= 0x02
        if self.replay_history:
            opts |= 0x04
        return opts


def default_subscription_options() -> SubscriptionOptions:
    """Get default subscription options."""
    return SubscriptionOptions()


class PresenceMember:
    """Single member in presence data."""

    def __init__(self, client_id: int, username: str = "",
                 joined_at: int = 0, last_ping: int = 0, metadata: str = ""):
        self.client_id = client_id
        self.username = username
        self.joined_at = joined_at
        self.last_ping = last_ping
        self.metadata = metadata


class PresenceInfo:
    """Presence information for a topic."""

    def __init__(self, topic: str, members: List[PresenceMember], last_update: int):
        self.topic = topic
        self.members = members
        self.last_update = last_update


class SubscriptionInfo:
    """Information about a subscription."""

    def __init__(self, sub_id: str, topic: str, pattern: str = "", client_id: int = 0):
        self.sub_id = sub_id
        self.topic = topic
        self.pattern = pattern
        self.client_id = client_id


class TopicInfo:
    """Information about a topic."""

    def __init__(self, name: str, sequence: int, subscriber_count: int, message_count: int):
        self.name = name
        self.sequence = sequence
        self.subscriber_count = subscriber_count
        self.message_count = message_count


class HistoryRequest:
    """Parameters for history queries."""

    def __init__(self, limit: int = 100, since_seq: int = 0):
        self.limit = limit
        self.since_seq = since_seq


# Pub/Sub encoding/decoding

def encode_subscribe_request(topic: str, pattern: str,
                            options: SubscriptionOptions) -> bytes:
    """Encode a subscribe request.

    Format: [options:1][topicLen:2][topic][patternLen:2][pattern]
    """
    buf = bytearray()

    # Options byte (first, per server protocol)
    buf.append(options.encode())

    # Topic
    buf.extend(struct.pack(">H", len(topic)))
    buf.extend(topic.encode("utf-8"))

    # Pattern
    buf.extend(struct.pack(">H", len(pattern)))
    buf.extend(pattern.encode("utf-8"))

    return bytes(buf)


def decode_subscribe_response(data: bytes) -> str:
    """Decode subscribe response.

    Response value is the subscription ID.
    """
    return data.decode("utf-8") if data else ""


def encode_publish_request(topic: str, msg_type: int,
                          payload: str, headers: str) -> bytes:
    """Encode a publish request.

    Format: [topicLen:2][topic][msgType:1][headersLen:4][headers][payloadLen:4][payload]
    """
    buf = bytearray()

    # Topic
    buf.extend(struct.pack(">H", len(topic)))
    buf.extend(topic.encode("utf-8"))

    # Message type
    buf.append(msg_type)

    # Headers length and headers (4 bytes, not 2!)
    buf.extend(struct.pack(">I", len(headers)))
    buf.extend(headers.encode("utf-8"))

    # Payload length and payload
    buf.extend(struct.pack(">I", len(payload)))
    buf.extend(payload.encode("utf-8"))

    return bytes(buf)


def decode_publish_response(data: bytes) -> int:
    """Decode publish response.

    Response value is the sequence number.
    """
    return struct.unpack(">Q", data)[0] if len(data) >= 8 else 0


def decode_pubsub_event(data: bytes) -> PubSubEvent:
    """Decode a PubSub event from server.

    Format: [cmd:1][seq:4][topicLen:2][topic][msgType:1][seq:8][ts:8][headersLen:4][headers][payloadLen:4][payload]

    The first seq (4 bytes) is the message sequence number for matching responses.
    The second seq (8 bytes) is the event sequence number.
    """
    if len(data) < 32:  # Minimum size
        raise ProtocolError("PubSub event too short")

    offset = 0

    # Command (should be 0xFF)
    cmd = data[offset]
    if cmd != Command.PUBSUB_EVENT:
        raise ProtocolError(f"Not a PubSub event: cmd=0x{cmd:02x}")
    offset += 1

    # Message sequence (4 bytes, not used for events but must be read)
    msg_seq = struct.unpack(">I", data[offset:offset+4])[0]
    offset += 4

    # Topic length and topic
    topic_len = struct.unpack(">H", data[offset:offset+2])[0]
    offset += 2
    topic = data[offset:offset+topic_len].decode("utf-8")
    offset += topic_len

    # Message type
    msg_type = data[offset]
    offset += 1

    # Event sequence number (64-bit)
    sequence = struct.unpack(">Q", data[offset:offset+8])[0]
    offset += 8

    # Timestamp (64-bit)
    timestamp = struct.unpack(">Q", data[offset:offset+8])[0]
    offset += 8

    # Headers length and headers (4 bytes, not 2!)
    headers_len = struct.unpack(">I", data[offset:offset+4])[0]
    offset += 4
    headers = data[offset:offset+headers_len].decode("utf-8") if headers_len > 0 else ""
    offset += headers_len

    # Payload length and payload
    payload_len = struct.unpack(">I", data[offset:offset+4])[0]
    offset += 4
    payload = data[offset:offset+payload_len].decode("utf-8") if payload_len > 0 else ""

    return PubSubEvent(topic, msg_type, sequence, timestamp, headers, payload)


def is_pubsub_event(data: bytes) -> bool:
    """Check if data is a PubSub event (command 0xFF)."""
    return len(data) > 0 and data[0] == Command.PUBSUB_EVENT


# Phase 3-4: Query method encoders/decoders

def encode_history_request(topic: str, count: int, since_seq: int) -> bytes:
    """Encode a history request.

    Format: [topicLen:2][topic][count:4][sinceSeq:8]
    """
    buf = bytearray()

    # Topic
    buf.extend(struct.pack(">H", len(topic)))
    buf.extend(topic.encode("utf-8"))

    # Count
    buf.extend(struct.pack(">I", count))

    # Since sequence (64-bit)
    buf.extend(struct.pack(">Q", since_seq))

    return bytes(buf)


def encode_presence_request(operation: int) -> bytes:
    """Encode a presence request.

    Format: [operation:1]

    Operations:
        0 = get_online
        1 = broadcast_update
    """
    return bytes([operation])


def decode_list_subscribers_response(data: str) -> List[SubscriptionInfo]:
    """Decode list subscribers response.

    The response is JSON: [{"subscriptionId": "...", "clientId": 123, "topic": "...", "pattern": "..."}]
    """
    import json
    try:
        items = json.loads(data) if data else []
        result = []
        for item in items:
            result.append(SubscriptionInfo(
                sub_id=item.get("subscriptionId", ""),
                topic=item.get("topic", ""),
                pattern=item.get("pattern", ""),
                client_id=item.get("clientId", 0)
            ))
        return result
    except json.JSONDecodeError as e:
        raise ProtocolError(f"Failed to decode subscribers response: {e}")


def decode_list_topics_response(data: str) -> List[TopicInfo]:
    """Decode list topics response.

    The response is JSON: [{"name": "...", "sequence": 123, "subscriberCount": 5, "messageCount": 100}]
    """
    import json
    try:
        items = json.loads(data) if data else []
        result = []
        for item in items:
            result.append(TopicInfo(
                name=item.get("name", ""),
                sequence=item.get("sequence", 0),
                subscriber_count=item.get("subscriberCount", 0),
                message_count=item.get("messageCount", 0)
            ))
        return result
    except json.JSONDecodeError as e:
        raise ProtocolError(f"Failed to decode topics response: {e}")


def decode_history_response(data: str) -> List[PubSubEvent]:
    """Decode history response.

    The response is JSON: [{"topic": "...", "messageType": 0, "sequence": 123, "timestamp": 1234567890, "headers": "...", "payload": "..."}]
    """
    import json
    try:
        items = json.loads(data) if data else []
        result = []
        for item in items:
            result.append(PubSubEvent(
                topic=item.get("topic", ""),
                message_type=item.get("messageType", PubSubMessageType.DATA),
                sequence=item.get("sequence", 0),
                timestamp=item.get("timestamp", 0),
                headers=item.get("headers", ""),
                payload=_serialize_history_payload(item.get("payload"))
            ))
        return result
    except json.JSONDecodeError as e:
        raise ProtocolError(f"Failed to decode history response: {e}")


def _serialize_history_payload(payload) -> str:
    """Serialize history payload to string."""
    import json
    if isinstance(payload, str):
        return payload
    elif isinstance(payload, dict):
        return json.dumps(payload)
    return str(payload)


def decode_presence_response(topic: str, data: str) -> PresenceInfo:
    """Decode presence response.

    The response is JSON: [{"topic": "...", "members": [...], "lastUpdate": 1234567890}]
    """
    import json
    try:
        items = json.loads(data) if data else []
        if not items:
            return PresenceInfo(topic=topic, members=[], last_update=0)

        item = items[0]  # Take first (and typically only) topic

        members = []
        for member_data in item.get("members", []):
            metadata = member_data.get("metadata")
            if metadata is not None:
                metadata_str = json.dumps(metadata)
            else:
                metadata_str = ""
            members.append(PresenceMember(
                client_id=member_data.get("clientId", 0),
                username=member_data.get("username", ""),
                joined_at=member_data.get("joinedAt", 0),
                last_ping=member_data.get("lastPing", 0),
                metadata=metadata_str
            ))

        return PresenceInfo(
            topic=item.get("topic", topic),
            members=members,
            last_update=item.get("lastUpdate", 0)
        )
    except json.JSONDecodeError as e:
        raise ProtocolError(f"Failed to decode presence response: {e}")


def encode_batch_set(items: List[Tuple[str, str]]) -> bytes:
    """Encode batch set request: [count:4][key1Len:2][key1][val1Len:4][val1][key2Len:2][key2][val2Len:4][val2]..."""
    if not items:
        return struct.pack(">I", 0)

    # Calculate total size first
    total_size = 4  # count (4 bytes)
    for key, value in items:
        if len(key) > MAX_KEY_SIZE:
            raise ProtocolError(f"Key too large: {len(key)} bytes (max {MAX_KEY_SIZE})")
        if len(value) > MAX_VALUE_SIZE:
            raise ProtocolError(f"Value too large: {len(value)} bytes (max {MAX_VALUE_SIZE})")
        total_size += 2 + len(key) + 4 + len(value)

    buf = bytearray(total_size)
    offset = 0

    # Write count
    buf[offset:offset+4] = struct.pack(">I", len(items))
    offset += 4

    for key, value in items:
        key_bytes = key.encode("utf-8")
        val_bytes = value.encode("utf-8")

        # Key length and key
        buf[offset:offset+2] = struct.pack(">H", len(key_bytes))
        offset += 2
        buf[offset:offset+len(key_bytes)] = key_bytes
        offset += len(key_bytes)

        # Value length and value
        buf[offset:offset+4] = struct.pack(">I", len(val_bytes))
        offset += 4
        buf[offset:offset+len(val_bytes)] = val_bytes
        offset += len(val_bytes)

    return bytes(buf)


def encode_batch_get(keys: List[str]) -> bytes:
    """Encode batch get request: [count:4][key1Len:2][key1][key2Len:2][key2]..."""
    if not keys:
        return struct.pack(">I", 0)

    # Calculate total size
    total_size = 4  # count (4 bytes)
    for key in keys:
        if len(key) > MAX_KEY_SIZE:
            raise ProtocolError(f"Key too large: {len(key)} bytes (max {MAX_KEY_SIZE})")
        total_size += 2 + len(key)

    buf = bytearray(total_size)
    offset = 0

    # Write count
    buf[offset:offset+4] = struct.pack(">I", len(keys))
    offset += 4

    for key in keys:
        key_bytes = key.encode("utf-8")

        # Key length and key
        buf[offset:offset+2] = struct.pack(">H", len(key_bytes))
        offset += 2
        buf[offset:offset+len(key_bytes)] = key_bytes
        offset += len(key_bytes)

    return bytes(buf)


def encode_batch_delete(keys: List[str]) -> bytes:
    """Encode batch delete request (same format as batch get)."""
    return encode_batch_get(keys)


def decode_batch_get_response(data: bytes) -> List[Tuple[str, str]]:
    """Decode batch get response: [count:4][key1Len:2][key1][val1Len:4][val1][status1:1][key2Len:2][key2][val2Len:4][val2][status2:1]..."""
    if len(data) < 4:
        raise ProtocolError("Batch response too short")

    offset = 0
    count = struct.unpack(">I", data[offset:offset+4])[0]
    offset += 4

    results: List[Tuple[str, str]] = []

    for i in range(count):
        if offset + 2 > len(data):
            raise ProtocolError("Truncated batch response: missing key length")

        # Key length and key
        key_len = struct.unpack(">H", data[offset:offset+2])[0]
        offset += 2
        if offset + key_len > len(data):
            raise ProtocolError("Truncated batch response: key extends beyond buffer")
        key = data[offset:offset+key_len].decode("utf-8")
        offset += key_len

        # Value length
        if offset + 4 > len(data):
            raise ProtocolError("Truncated batch response: missing value length")
        val_len = struct.unpack(">I", data[offset:offset+4])[0]
        offset += 4
        if offset + val_len > len(data):
            raise ProtocolError("Truncated batch response: value extends beyond buffer")
        value = data[offset:offset+val_len].decode("utf-8") if val_len > 0 else ""
        offset += val_len

        # Status byte
        if offset + 1 > len(data):
            raise ProtocolError("Truncated batch response: missing status byte")
        status = data[offset]
        offset += 1

        # Only include found items (status == 0)
        if status == 0:
            results.append((key, value))

    return results
