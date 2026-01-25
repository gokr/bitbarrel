"""BitBarrel Python client.

This package provides Python bindings to the BitBarrel key-value storage
via WebSocket connection using the BitBarrel binary protocol.
"""

from .client import Client, RangeResult, TraverseResult
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
from .protocol import (
    PubSubMessageType,
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
    "Client",
    "RangeResult",
    "TraverseResult",
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
    "PubSubMessageType",
    "paginate_range_result",
    "iterate_range",
    "get_all_with_prefix",
    "get_all_in_range",
    "batch_set",
    "batch_get",
    "batch_delete",
]

__version__ = "0.1.0"
