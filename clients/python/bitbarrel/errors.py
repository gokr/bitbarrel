"""BitBarrel client error types."""


class BitBarrelError(Exception):
    """Base exception for BitBarrel errors."""
    pass


class ConnectionError(BitBarrelError):
    """Connection-related errors."""
    pass


class ProtocolError(BitBarrelError):
    """Protocol encoding/decoding errors."""
    pass


class TimeoutError(BitBarrelError):
    """Operation timeout errors."""
    pass


class NotFoundError(BitBarrelError):
    """Key or barrel not found."""
    pass


class NoBarrelError(BitBarrelError):
    """No barrel selected for the session."""
    pass


class BarrelExistsError(BitBarrelError):
    """Barrel already exists."""
    pass


class BarrelNotFoundError(BitBarrelError):
    """Barrel not found."""
    pass


class InvalidRequestError(BitBarrelError):
    """Invalid request parameters."""
    pass


class ServerError(BitBarrelError):
    """Server-side error."""
    pass
