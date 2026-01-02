"""Binary protocol codec for BitBarrel WebSocket communication.

Request Format: [type:1][seq:4][keyLen:2][key:N][valLen:4][value:M]
Response Format: [status:1][seq:4][valLen:4][value:M]

All multi-byte integers use big-endian encoding.
"""

import struct
from enum import IntEnum
from typing import Tuple, Optional, Union


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
    CREATE_BARREL = 0x10
    OPEN_BARREL = 0x11
    USE_BARREL = 0x12
    CLOSE_BARREL = 0x13
    LIST_BARRELS = 0x14
    DROP_BARREL = 0x15
    GET_BARREL_CONFIG = 0x16
    SET_BARREL_CONFIG = 0x17
    GET_BARREL_STATS = 0x18


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
