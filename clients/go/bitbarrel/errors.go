package bitbarrel

import "errors"

// BitBarrel error types
var (
    // Connection errors
    ErrNotConnected    = errors.New("not connected to server")
    ErrConnectFailed   = errors.New("failed to connect to server")
    ErrTimeout         = errors.New("operation timeout")
    ErrConnClosed      = errors.New("connection closed")

    // Operation errors
    ErrNotFound        = errors.New("key not found")
    ErrNoBarrel        = errors.New("no barrel selected")
    ErrBarrelExists    = errors.New("barrel already exists")
    ErrBarrelNotFound  = errors.New("barrel not found")
    ErrInvalidRequest  = errors.New("invalid request")
    ErrServerError     = errors.New("server error")
)

// Error represents a BitBarrel error with additional context
type Error struct {
    Op   string
    Err  error
}

func (e *Error) Error() string {
    if e.Op == "" {
        return e.Err.Error()
    }
    return e.Op + ": " + e.Err.Error()
}

func (e *Error) Unwrap() error {
    return e.Err
}

// NewError creates a new Error
func NewError(op string, err error) error {
    return &Error{Op: op, Err: err}
}

// Is checks if the error matches a specific error
func (e *Error) Is(target error) bool {
    return errors.Is(e.Err, target)
}
