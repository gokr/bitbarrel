"""BitBarrel Python client.

This package provides Python bindings to the BitBarrel key-value storage
via WebSocket connection.

The client is built using Nim + Nimpy for performance and correctness,
reusing the existing Nim network protocol implementation.
"""

from .errors import (
    BitBarrelError,
    ConnectionError,
    ProtocolError,
    TimeoutError,
    NotFoundError,
    NoBarrelError,
    BarrelExistsError,
    BarrelNotFoundError,
    InvalidRequestError,
    ServerError,
)

from .helpers import (
    paginate_range_result,
    iterate_range,
    get_all_with_prefix,
    get_all_in_range,
    batch_set,
    batch_get,
    batch_delete,
)

__all__ = [
    # Core client (imported from compiled Nim extension)
    "Client",
    "ClientConfig",
    # Types
    "TraverseOptions",
    "TraverseResult",
    "RangeResult",
    # Errors
    "BitBarrelError",
    "ConnectionError",
    "ProtocolError",
    "TimeoutError",
    "NotFoundError",
    "NoBarrelError",
    "BarrelExistsError",
    "BarrelNotFoundError",
    "InvalidRequestError",
    "ServerError",
    # Helpers
    "paginate_range_result",
    "iterate_range",
    "get_all_with_prefix",
    "get_all_in_range",
    "batch_set",
    "batch_get",
    "batch_delete",
]

__version__ = "0.1.0"

# Import the compiled Nim extension
try:
    from bitbarrel_core import (
        BitBarrelClient as Client,
        ClientConfig,
        TraverseOptions,
        TraverseResult,
        RangeResult,
    )
except ImportError:
    # Extension not built yet - this will happen during development
    # Provide helpful message
    import sys

    class NotBuiltError(Exception):
        pass

    raise NotBuiltError(
        "BitBarrel extension not built. Run: pip install -e .\n"
        "This requires Nim compiler to compile the extension."
    )
