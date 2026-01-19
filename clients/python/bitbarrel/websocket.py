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

    def _consume_welcome_message(self) -> None:
        """Consume the welcome message sent by server after connection.

        Called during connect() to ensure the welcome message doesn't interfere
        with request/response cycles.
        """
        if self._welcome_consumed:
            return

        try:
            # Wait for welcome message with a short timeout
            if select_available:
                sock = self._ws.sock
                if sock:
                    # Wait up to 1 second for welcome message
                    readable, _, _ = select.select([sock], [], [], 1.0)
                    if readable:
                        result = self._ws.recv()
                        # Verify it's the welcome message
                        if isinstance(result, str) and "Connected" in result:
                            self._welcome_consumed = True
                        # If it's not a welcome message, we have a problem -
                        # but this shouldn't happen during connect
            else:
                # No select available, just try a recv
                result = self._ws.recv()
                if isinstance(result, str) and "Connected" in result:
                    self._welcome_consumed = True
        except Exception:
            # If anything goes wrong, mark as consumed to avoid blocking later
            self._welcome_consumed = True

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

            # Check if we can peek at the message without consuming it
            # For websocket-client, we can check if data is text or binary via opcode
            # but we need to be careful not to consume binary data
            original_timeout = self._ws.timeout
            try:
                # Very short timeout to minimize blocking
                if hasattr(self._ws, 'timeout'):
                    self._ws.timeout = 0.001

                # Try to peek at next message to see if it's a welcome text
                # Only try this if we haven't already marked welcome as consumed
                if not self._welcome_consumed:
                    # For websocket-client, we can use the pending() method to check buffered data
                    if hasattr(self._ws, 'sock') and hasattr(self._ws.sock, 'pending'):
                        # Check if any data is buffered
                        if self._ws.sock.pending() > 0:
                            # Try to read just enough to check message type
                            # We'll use recv() but with the understanding that
                            # we might consume data we'll need later
                            result = self._ws.recv()
                            if isinstance(result, str) and "Connected" in result:
                                # It was a welcome message, successfully consumed
                                self._welcome_consumed = True
                            else:
                                # Not a welcome message or already consumed
                                # We mark as consumed since we consumed something
                                self._welcome_consumed = True
                    else:
                        # Fallback: try recv with very short timeout
                        result = self._ws.recv()
                        if isinstance(result, str) and "Connected" in result:
                            self._welcome_consumed = True
                        else:
                            self._welcome_consumed = True
            except ws_lib.WebSocketTimeoutException:
                # Timeout is expected if no data is immediately available
                pass
            except Exception:
                # Any other error, mark as consumed
                self._welcome_consumed = True
            finally:
                if hasattr(self._ws, 'timeout'):
                    self._ws.timeout = original_timeout
        except Exception:
            # If anything goes wrong, mark as consumed to avoid blocking later
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

        # Use select to implement timeout (outside try block so TimeoutError isn't caught)
        if select_available:
            sock = self._ws.sock
            if sock:
                # Wait for data to be available or timeout
                readable, _, _ = select.select([sock], [], [], self.request_timeout)
                if not readable:
                    raise TimeoutError(f"Operation timeout after {self.request_timeout}s")

        try:
            result = self._ws.recv()

            # Handle welcome message and other text messages
            # The BitBarrel server sends "Connected to BitBarrel network server"
            # as a welcome message that we should skip
            while isinstance(result, str) and "Connected" in result:
                print(f"DEBUG: Skipping welcome message: {result[:50]}...")
                result = self._ws.recv()

            if isinstance(result, str):
                print(f"DEBUG: Received unexpected text: {result[:50]}...")
                return result.encode("utf-8")
            print(f"DEBUG: Received binary data, length={len(result) if result else 0}")
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
