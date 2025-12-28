"""WebSocket wrapper using websocket-client library."""

import threading
select_available = False
try:
    import select
    select_available = True
except ImportError:
    pass
from typing import Optional
import websocket as ws_lib
from .errors import ConnectionError, TimeoutError


class WebSocket:
    """Simple WebSocket wrapper using websocket-client library."""

    def __init__(self, address: str, connect_timeout: float = 5.0, request_timeout: float = 3.0):
        """Initialize the WebSocket connection.

        Args:
            address: Server address in form "host:port"
            connect_timeout: Timeout for initial connection in seconds
            request_timeout: Timeout for read operations in seconds
        """
        self.address = address
        self.connect_timeout = connect_timeout
        self.request_timeout = request_timeout
        self._ws: Optional[ws_lib.WebSocket] = None
        self._lock = threading.Lock()
        self._connected = False
        self._welcome_consumed = False

    def connect(self) -> None:
        """Establish WebSocket connection to the server."""
        with self._lock:
            if self._connected:
                return

            # Create URL from address
            url = f"ws://{self.address}/ws"

            # Create WebSocket connection
            self._ws = ws_lib.WebSocket()

            try:
                self._ws.connect(
                    url,
                    timeout=self.connect_timeout,
                    header={"Sec-WebSocket-Protocol": "bitbarrel"}
                )
            except ws_lib.WebSocketTimeoutException:
                raise TimeoutError(f"Connection timeout after {self.connect_timeout}s")
            except Exception as e:
                raise ConnectionError(f"Failed to connect: {e}")

            self._connected = True

    def _skip_welcome_messages(self) -> None:
        """Skip any welcome messages from the server - called non-blocking."""
        # Try to consume welcome messages without blocking
        if self._welcome_consumed:
            return

        try:
            # Use select with 0 timeout to check if data is available
            if select_available:
                sock = self._ws.sock
                if sock:
                    readable, _, _ = select.select([sock], [], [], 0)
                    if not readable:
                        # No data available, nothing to skip
                        return

            # Data available, try to read and skip welcome messages
            while True:
                if select_available:
                    sock = self._ws.sock
                    if sock:
                        readable, _, _ = select.select([sock], [], [], 0)
                        if not readable:
                            # No more data available to skip
                            break

                result = self._ws.recv()
                if not isinstance(result, str) or "Connected" not in result:
                    # This is not a welcome message, put it back in the buffer
                    # Since we can't put it back, just return and set consumed flag
                    # The next recv_binary call will get this message
                    break
            self._welcome_consumed = True
        except:
            # Any error during welcome skip, just mark as consumed
            self._welcome_consumed = True

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
        """Receive binary message from the server.

        Skips any welcome messages that the server sends after connection.
        """
        if not self._ws or not self._connected:
            raise ConnectionError("Not connected to server")

        # Try to skip welcome messages first (non-blocking)
        self._skip_welcome_messages()

        try:
            # Use select to implement timeout
            if select_available:
                sock = self._ws.sock
                if sock:
                    # Wait for data to be available or timeout
                    readable, _, _ = select.select([sock], [], [], self.request_timeout)
                    if not readable:
                        raise TimeoutError(f"Operation timeout after {self.request_timeout}s")

            result = self._ws.recv()

            # Handle welcome message and other text messages
            # The BitBarrel server sends "Connected to BitBarrel network server"
            # as a welcome message that we should skip
            while isinstance(result, str) and "Connected" in result:
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
                except:
                    pass
                self._ws = None
            self._connected = False

    @property
    def connected(self) -> bool:
        """Check if connected."""
        return self._connected
