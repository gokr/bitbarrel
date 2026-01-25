"""WebSocket wrapper using websocket-client library."""

import threading
from typing import Optional, Dict

import websocket as ws_lib

from .errors import ConnectionError, TimeoutError

# Check if select is available (not on all platforms)
try:
    import select
    select_available = True
except ImportError:
    select_available = False


class WebSocket:
    """Simple WebSocket wrapper using websocket-client library."""

    def __init__(self, address: str, connect_timeout: float = 5.0, request_timeout: float = 3.0,
                 headers: Optional[Dict[str, str]] = None):
        """Initialize the WebSocket connection.

        Args:
            address: Server address in form "host:port"
            connect_timeout: Timeout for initial connection in seconds
            request_timeout: Timeout for read operations in seconds
            headers: Optional headers to send during WebSocket handshake
        """
        self.address = address
        self.connect_timeout = connect_timeout
        self.request_timeout = request_timeout
        self._original_request_timeout = request_timeout  # Store original for reset
        self.headers = headers or {}
        self._ws: Optional[ws_lib.WebSocket] = None
        self._lock = threading.Lock()
        self._connected = False

    def connect(self) -> None:
        """Establish WebSocket connection to the server."""
        with self._lock:
            if self._connected:
                return

            # Create URL from address
            url = f"ws://{self.address}/ws"

            # Create WebSocket connection
            self._ws = ws_lib.WebSocket()

            # Prepare headers (merge custom headers with default protocol header)
            connect_headers = {"Sec-WebSocket-Protocol": "bitbarrel"}
            connect_headers.update(self.headers)

            try:
                self._ws.connect(
                    url,
                    timeout=self.connect_timeout,
                    header=connect_headers
                )
            except ws_lib.WebSocketTimeoutException:
                raise TimeoutError(f"Connection timeout after {self.connect_timeout}s")
            except Exception as e:
                raise ConnectionError(f"Failed to connect: {e}")

            self._connected = True


    def send_binary(self, data: bytes) -> None:
        """Send binary data to the server."""
        if not self._ws or not self._connected:
            raise ConnectionError("Not connected to server")

        try:
            self._ws.send(data, opcode=ws_lib.ABNF.OPCODE_BINARY)
        except Exception as e:
            self._connected = False
            raise ConnectionError(f"Failed to send: {e}")

    def recv_binary(self, size_hint: int = 4096) -> bytes:
        """Receive binary message from the server."""
        if not self._ws or not self._connected:
            raise ConnectionError("Not connected to server")

        # Set timeout on the underlying socket for this receive operation
        # The websocket-client library will handle the timeout properly
        sock = self._ws.sock
        if sock:
            sock.settimeout(self.request_timeout)

        try:
            result = self._ws.recv()
            if isinstance(result, str):
                return result.encode("utf-8")
            return result
        except ws_lib.WebSocketTimeoutException:
            raise TimeoutError(f"Operation timeout after {self.request_timeout}s")
        except ws_lib.WebSocketConnectionClosedException:
            self._connected = False
            raise ConnectionError("Server closed connection")
        except Exception as e:
            self._connected = False
            raise ConnectionError(f"Failed to receive: {e}")

    def close(self) -> None:
        """Close the WebSocket connection."""
        with self._lock:
            if self._ws:
                try:
                    self._ws.close()
                except Exception:
                    pass
                self._ws = None
            self._connected = False

    def set_timeout(self, timeout: float) -> None:
        """Set a temporary timeout for the next operation.

        Args:
            timeout: Timeout in seconds for the next operation
        """
        self.request_timeout = timeout

    def reset_timeout(self) -> None:
        """Reset timeout to the original value."""
        self.request_timeout = self._original_request_timeout

    @property
    def connected(self) -> bool:
        """Check if connected."""
        return self._connected
