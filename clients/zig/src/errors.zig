const std = @import("std");
const c = @cImport({
    @cInclude("bitbarrel.h");
});

pub const Error = error{
    ConnectionError,
    Timeout,
    ProtocolError,
    InvalidRequest,
    BarrelNotFound,
    BarrelExists,
    UnknownError,
    OutOfMemory,
};

pub fn translateCError(result: c.BBResult) Error {
    return switch (result) {
        c.BB_OK => unreachable,
        c.BB_ERROR => Error.UnknownError,
        c.BB_NOT_FOUND => Error.UnknownError,
        c.BB_NO_BARREL => Error.BarrelNotFound,
        c.BB_BARREL_EXISTS => Error.BarrelExists,
        c.BB_INVALID_REQUEST => Error.InvalidRequest,
        c.BB_CONNECTION_ERROR => Error.ConnectionError,
        c.BB_TIMEOUT => Error.Timeout,
        c.BB_PROTOCOL_ERROR => Error.ProtocolError,
        else => Error.UnknownError,
    };
}
