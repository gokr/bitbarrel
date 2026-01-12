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


def encode_request(cmd: int, seq: int, key: str = "", value: Union[str, bytes] = "") -> bytes:
    """Encode a request to binary format.

    Args:
        cmd: Command byte
        seq: Sequence number
        key: Key string
        value: Value as string or bytes (for binary payloads like range queries)
    """
    if len(key) > MAX_KEY_SIZE:
        raise ProtocolError(f"Key too large: {len(key)} bytes")
    if len(value) > MAX_VALUE_SIZE:
        raise ProtocolError(f"Value too large: {len(value)} bytes")

    # Encode value to bytes if it's a string
    value_bytes = value if isinstance(value, bytes) else value.encode("utf-8")
    key_bytes = key.encode("utf-8")

    # Calculate total size: 1 + 4 + 2 + key + 4 + value
    total_size = 1 + 4 + 2 + len(key_bytes) + 4 + len(value_bytes)
    buf = bytearray(total_size)

    offset = 0

    # Command (1 byte)
    buf[offset] = cmd
    offset += 1

    # Sequence (4 bytes, big-endian)
    buf[offset:offset+4] = struct.pack(">I", seq)
    offset += 4

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

    return bytes(buf)


def decode_request(data: bytes) -> Tuple[int, int, str, str]:
    """Decode a request from binary format."""
    if len(data) < 11:  # Minimum: 1+4+2+0+4+0
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

    def __init__(self, client_id: int, joined_at: int, last_ping: int):
        self.client_id = client_id
        self.joined_at = joined_at
        self.last_ping = last_ping


class PresenceInfo:
    """Presence information for a topic."""

    def __init__(self, topic: str, members: List[PresenceMember], last_update: int):
        self.topic = topic
        self.members = members
        self.last_update = last_update


class SubscriptionInfo:
    """Information about a subscription."""

    def __init__(self, sub_id: str, topic: str, pattern: str = ""):
        self.sub_id = sub_id
        self.topic = topic
        self.pattern = pattern


class HistoryRequest:
    """Parameters for history queries."""

    def __init__(self, limit: int = 100, since_seq: int = 0):
        self.limit = limit
        self.since_seq = since_seq


# Pub/Sub encoding/decoding

def encode_subscribe_request(topic: str, pattern: str,
                            options: SubscriptionOptions) -> bytes:
    """Encode a subscribe request.

    Format: [topicLen:2][topic][patternLen:2][pattern][options:1]
    """
    buf = bytearray()

    # Topic
    buf.extend(struct.pack(">H", len(topic)))
    buf.extend(topic.encode("utf-8"))

    # Pattern
    buf.extend(struct.pack(">H", len(pattern)))
    buf.extend(pattern.encode("utf-8"))

    # Options
    buf.append(options.encode())

    return bytes(buf)


def decode_subscribe_response(data: bytes) -> str:
    """Decode subscribe response.

    Response value is the subscription ID.
    """
    return data.decode("utf-8") if data else ""


def encode_publish_request(topic: str, msg_type: int,
                          payload: str, headers: str) -> bytes:
    """Encode a publish request.

    Format: [topicLen:2][topic][msgType:1][headersLen:2][headers][payloadLen:4][payload]
    """
    buf = bytearray()

    # Topic
    buf.extend(struct.pack(">H", len(topic)))
    buf.extend(topic.encode("utf-8"))

    # Message type
    buf.append(msg_type)

    # Headers length and headers
    buf.extend(struct.pack(">H", len(headers)))
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

    Format: [cmd:1][topicLen:2][topic][msgType:1][seq:8][ts:8][headersLen:2][headers][payloadLen:4][payload]
    """
    if len(data) < 32:  # Minimum size
        raise ProtocolError("PubSub event too short")

    offset = 0

    # Command (should be 0xFF)
    cmd = data[offset]
    if cmd != Command.PUBSUB_EVENT:
        raise ProtocolError(f"Not a PubSub event: cmd=0x{cmd:02x}")
    offset += 1

    # Topic length and topic
    topic_len = struct.unpack(">H", data[offset:offset+2])[0]
    offset += 2
    topic = data[offset:offset+topic_len].decode("utf-8")
    offset += topic_len

    # Message type
    msg_type = data[offset]
    offset += 1

    # Sequence number
    sequence = struct.unpack(">Q", data[offset:offset+8])[0]
    offset += 8

    # Timestamp
    timestamp = struct.unpack(">Q", data[offset:offset+8])[0]
    offset += 8

    # Headers length and headers
    headers_len = struct.unpack(">H", data[offset:offset+2])[0]
    offset += 2
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
