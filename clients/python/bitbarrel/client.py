"""BitBarrel WebSocket client implementation."""

import threading
from typing import List, Tuple, Optional, Union
from .protocol import (
    Command, Status,
    encode_request, decode_response, decode_response_raw,
    encode_range_request, decode_range_response,
    encode_prefix_request,
    encode_traverse_request, decode_traverse_response,
    status_to_error,
)
from .websocket import WebSocket
from .errors import (
    ConnectionError, NotFoundError, NoBarrelError, ServerError,
)


class RangeResult:
    """Result from range or prefix query."""

    def __init__(self, items: List[Tuple[str, str]], next_cursor: str, has_more: bool):
        self.items = items
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

    def _send_request(self, cmd: int, key: str = "", value: str = "") -> Optional[str]:
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

            # Receive response
            try:
                response_data = self._ws.recv_binary()
            except ConnectionError:
                self._connected = False
                raise

            # Decode response
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

            # Receive response
            try:
                response_data = self._ws.recv_binary()
            except ConnectionError:
                self._connected = False
                raise

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
