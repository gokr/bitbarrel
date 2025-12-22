package bitbarrel

import (
	"encoding/binary"
	"errors"
	"fmt"
)

// Command types - must match BitBarrel protocol
const (
	CmdGet          byte = 0x01
	CmdSet          byte = 0x02
	CmdDelete       byte = 0x03
	CmdExists       byte = 0x04
	CmdCount        byte = 0x05
	CmdListKeys     byte = 0x06
	CmdPing         byte = 0x09
	CmdTraverse     byte = 0x20
	CmdCreateBarrel byte = 0x10
	CmdOpenBarrel   byte = 0x11
	CmdUseBarrel    byte = 0x12
	CmdCloseBarrel  byte = 0x13
	CmdListBarrels  byte = 0x14
	CmdDropBarrel   byte = 0x15
)

// Status codes - must match BitBarrel protocol
const (
	StatusOk              byte = 0x00
	StatusNotFound        byte = 0x01
	StatusError           byte = 0x02
	StatusInvalid         byte = 0x03
	StatusNoBarrel        byte = 0x04
	StatusBarrelExists    byte = 0x05
	StatusBarrelNotFound  byte = 0x06
)

// Limits as per protocol specification
const (
	MaxKeySize   = 65535     // 64KB
	MaxValueSize = 1048576   // 1MB
)

// Request represents a BitBarrel protocol request
type Request struct {
	Command byte
	Seq     uint32
	Key     string
	Value   string
}

// Response represents a BitBarrel protocol response
type Response struct {
	Status byte
	Seq    uint32
	Value  string
}

// IsValid checks if the command is valid
func IsValidCommand(cmd byte) bool {
	switch cmd {
	case CmdGet, CmdSet, CmdDelete, CmdExists, CmdCount, CmdListKeys, CmdPing,
		CmdTraverse, CmdCreateBarrel, CmdOpenBarrel, CmdUseBarrel,
		CmdCloseBarrel, CmdListBarrels, CmdDropBarrel:
		return true
	default:
		return false
	}
}

// IsValidStatus checks if the status code is valid
func IsValidStatus(status byte) bool {
	return status <= StatusBarrelNotFound
}

// NewRequest creates a new request
func NewRequest(command byte, key, value string) *Request {
	return &Request{
		Command: command,
		Key:     key,
		Value:   value,
	}
}

// NewResponse creates a new response
func NewResponse(status byte, seq uint32, value string) *Response {
	return &Response{
		Status: status,
		Seq:    seq,
		Value:  value,
	}
}

// OkResponse creates an OK response
func OkResponse(seq uint32, value string) *Response {
	return NewResponse(StatusOk, seq, value)
}

// ErrorResponse creates an error response
func ErrorResponse(seq uint32, message string) *Response {
	return NewResponse(StatusError, seq, message)
}

// NotFoundResponse creates a not found response
func NotFoundResponse(seq uint32) *Response {
	return NewResponse(StatusNotFound, seq, "")
}

// Encode serializes a request to binary format
func (r *Request) Encode() ([]byte, error) {
	if len(r.Key) > MaxKeySize {
		return nil, fmt.Errorf("key too large: %d bytes (max %d)", len(r.Key), MaxKeySize)
	}
	if len(r.Value) > MaxValueSize {
		return nil, fmt.Errorf("value too large: %d bytes (max %d)", len(r.Value), MaxValueSize)
	}

	// Calculate total size: 1 (cmd) + 4 (seq) + 2 (key len) + key + 4 (val len) + value
	totalSize := 1 + 4 + 2 + len(r.Key) + 4 + len(r.Value)
	buf := make([]byte, totalSize)

	offset := 0

	// Command type (1 byte)
	buf[offset] = r.Command
	offset += 1

	// Sequence number (4 bytes, big-endian)
	binary.BigEndian.PutUint32(buf[offset:], r.Seq)
	offset += 4

	// Key length (2 bytes, big-endian)
	if len(r.Key) > MaxKeySize {
		return nil, errors.New("key too large")
	}
	binary.BigEndian.PutUint16(buf[offset:], uint16(len(r.Key)))
	offset += 2

	// Key data
	copy(buf[offset:], r.Key)
	offset += len(r.Key)

	// Value length (4 bytes, big-endian)
	if len(r.Value) > MaxValueSize {
		return nil, errors.New("value too large")
	}
	binary.BigEndian.PutUint32(buf[offset:], uint32(len(r.Value)))
	offset += 4

	// Value data
	copy(buf[offset:], r.Value)

	return buf, nil
}

// Decode deserializes a request from binary format
func DecodeRequest(data []byte) (*Request, error) {
	if len(data) < 11 { // Minimum size: 1+4+2+0+4+0
		return nil, errors.New("request too short")
	}

	offset := 0

	// Command type (1 byte)
	cmd := data[offset]
	offset += 1

	if !IsValidCommand(cmd) {
		return nil, fmt.Errorf("invalid command: 0x%02x", cmd)
	}

	// Sequence number (4 bytes, big-endian)
	seq := binary.BigEndian.Uint32(data[offset:])
	offset += 4

	// Key length (2 bytes, big-endian)
	keyLen := binary.BigEndian.Uint16(data[offset:])
	offset += 2

	if keyLen > MaxKeySize {
		return nil, fmt.Errorf("key length too large: %d", keyLen)
	}

	if len(data) < offset+int(keyLen)+4 {
		return nil, errors.New("truncated request")
	}

	// Key data
	key := string(data[offset : offset+int(keyLen)])
	offset += int(keyLen)

	// Value length (4 bytes, big-endian)
	valueLen := binary.BigEndian.Uint32(data[offset:])
	offset += 4

	if valueLen > MaxValueSize {
		return nil, fmt.Errorf("value length too large: %d", valueLen)
	}

	if len(data) < offset+int(valueLen) {
		return nil, errors.New("truncated request")
	}

	// Value data
	value := string(data[offset : offset+int(valueLen)])

	return &Request{
		Command: cmd,
		Seq:     seq,
		Key:     key,
		Value:   value,
	}, nil
}

// Encode serializes a response to binary format
func (r *Response) Encode() ([]byte, error) {
	if len(r.Value) > MaxValueSize {
		return nil, fmt.Errorf("value too large: %d bytes (max %d)", len(r.Value), MaxValueSize)
	}

	// Calculate total size: 1 (status) + 4 (seq) + 4 (val len) + value
	totalSize := 1 + 4 + 4 + len(r.Value)
	buf := make([]byte, totalSize)

	offset := 0

	// Status code (1 byte)
	buf[offset] = r.Status
	offset += 1

	// Sequence number (4 bytes, big-endian)
	binary.BigEndian.PutUint32(buf[offset:], r.Seq)
	offset += 4

	// Value length (4 bytes, big-endian)
	binary.BigEndian.PutUint32(buf[offset:], uint32(len(r.Value)))
	offset += 4

	// Value data
	copy(buf[offset:], r.Value)

	return buf, nil
}

// Decode deserializes a response from binary format
func DecodeResponse(data []byte) (*Response, error) {
	if len(data) < 9 { // Minimum size: 1+4+4+0
		return nil, errors.New("response too short")
	}

	offset := 0

	// Status code (1 byte)
	status := data[offset]
	offset += 1

	if !IsValidStatus(status) {
		return nil, fmt.Errorf("invalid status: 0x%02x", status)
	}

	// Sequence number (4 bytes, big-endian)
	seq := binary.BigEndian.Uint32(data[offset:])
	offset += 4

	// Value length (4 bytes, big-endian)
	valueLen := binary.BigEndian.Uint32(data[offset:])
	offset += 4

	if valueLen > MaxValueSize {
		return nil, fmt.Errorf("value length too large: %d", valueLen)
	}

	if len(data) < offset+int(valueLen) {
		return nil, errors.New("truncated response")
	}

	// Value data
	value := string(data[offset : offset+int(valueLen)])

	return &Response{
		Status: status,
		Seq:    seq,
		Value:  value,
	}, nil
}

// StatusToError converts a response status to an error
func StatusToError(status byte, msg string) error {
	switch status {
	case StatusOk:
		return nil
	case StatusNotFound:
		return errors.New("key not found")
	case StatusError:
		return errors.New(msg)
	case StatusInvalid:
		return errors.New("invalid request")
	case StatusNoBarrel:
		return errors.New("no barrel selected")
	case StatusBarrelExists:
		return errors.New("barrel already exists")
	case StatusBarrelNotFound:
		return errors.New("barrel not found")
	default:
		return fmt.Errorf("unknown status: 0x%02x", status)
	}
}
