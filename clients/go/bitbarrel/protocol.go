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
	CmdRangeQuery   byte = 0x21
	CmdPrefixQuery  byte = 0x22
	CmdRangeCount   byte = 0x23
	CmdCreateBarrel byte = 0x10
	CmdOpenBarrel   byte = 0x11
	CmdUseBarrel    byte = 0x12
	CmdCloseBarrel  byte = 0x13
	CmdListBarrels  byte = 0x14
	CmdDropBarrel   byte = 0x15
	CmdGetBarrelConfig byte = 0x16
	CmdSetBarrelConfig byte = 0x17
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
		CmdTraverse, CmdRangeQuery, CmdPrefixQuery, CmdRangeCount,
		CmdCreateBarrel, CmdOpenBarrel, CmdUseBarrel,
		CmdCloseBarrel, CmdListBarrels, CmdDropBarrel,
		CmdGetBarrelConfig, CmdSetBarrelConfig:
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

// EncodeRangeRequest encodes a range query request
// Format: [startKeyLen:2][startKey:N][endKeyLen:2][endKey:N][limit:4][cursorLen:2][cursor:M]
func EncodeRangeRequest(req RangeQueryRequest) ([]byte, error) {
	buf := make([]byte, 0,
		2+len(req.StartKey)+
			2+len(req.EndKey)+
			4+
			2+len(req.Cursor))

	// Start key
	buf = append(buf, byte(len(req.StartKey)>>8), byte(len(req.StartKey)))
	buf = append(buf, []byte(req.StartKey)...)

	// End key
	buf = append(buf, byte(len(req.EndKey)>>8), byte(len(req.EndKey)))
	buf = append(buf, []byte(req.EndKey)...)

	// Limit
	buf = append(buf,
		byte(req.Limit>>24),
		byte(req.Limit>>16),
		byte(req.Limit>>8),
		byte(req.Limit))

	// Cursor
	buf = append(buf, byte(len(req.Cursor)>>8), byte(len(req.Cursor)))
	buf = append(buf, []byte(req.Cursor)...)

	return buf, nil
}

// DecodeRangeRequest decodes a range query request
func DecodeRangeRequest(data []byte) (RangeQueryRequest, error) {
	var result RangeQueryRequest

	if len(data) < 10 { // Minimum: 2 + 0 + 2 + 0 + 4 + 2 + 0
		return result, errors.New("range request too short")
	}

	offset := 0

	// Start key length
	startKeyLen := int(binary.BigEndian.Uint16(data[offset : offset+2]))
	offset += 2

	if len(data) < offset+startKeyLen+2 {
		return result, errors.New("truncated start key")
	}
	result.StartKey = string(data[offset : offset+startKeyLen])
	offset += startKeyLen

	// End key length
	endKeyLen := int(binary.BigEndian.Uint16(data[offset : offset+2]))
	offset += 2

	if len(data) < offset+endKeyLen+4 {
		return result, errors.New("truncated end key")
	}
	result.EndKey = string(data[offset : offset+endKeyLen])
	offset += endKeyLen

	// Limit
	if len(data) < offset+4 {
		return result, errors.New("truncated limit")
	}
	result.Limit = int(binary.BigEndian.Uint32(data[offset : offset+4]))
	offset += 4

	// Cursor length
	cursorLen := int(binary.BigEndian.Uint16(data[offset : offset+2]))
	offset += 2

	if len(data) < offset+cursorLen {
		return result, errors.New("truncated cursor")
	}
	result.Cursor = string(data[offset : offset+cursorLen])

	return result, nil
}

// EncodePrefixRequest encodes a prefix query request
// Format: [prefixLen:2][prefix:N][limit:4][cursorLen:2][cursor:M]
func EncodePrefixRequest(req PrefixQueryRequest) ([]byte, error) {
	buf := make([]byte, 0,
		2+len(req.Prefix)+
			4+
			2+len(req.Cursor))

	// Prefix
	buf = append(buf, byte(len(req.Prefix)>>8), byte(len(req.Prefix)))
	buf = append(buf, []byte(req.Prefix)...)

	// Limit
	buf = append(buf,
		byte(req.Limit>>24),
		byte(req.Limit>>16),
		byte(req.Limit>>8),
		byte(req.Limit))

	// Cursor
	buf = append(buf, byte(len(req.Cursor)>>8), byte(len(req.Cursor)))
	buf = append(buf, []byte(req.Cursor)...)

	return buf, nil
}

// DecodePrefixRequest decodes a prefix query request
func DecodePrefixRequest(data []byte) (PrefixQueryRequest, error) {
	var result PrefixQueryRequest

	if len(data) < 8 { // Minimum: 2 + 0 + 4 + 2 + 0
		return result, errors.New("prefix request too short")
	}

	offset := 0

	// Prefix length
	prefixLen := int(binary.BigEndian.Uint16(data[offset : offset+2]))
	offset += 2

	if len(data) < offset+prefixLen+4 {
		return result, errors.New("truncated prefix")
	}
	result.Prefix = string(data[offset : offset+prefixLen])
	offset += prefixLen

	// Limit
	if len(data) < offset+4 {
		return result, errors.New("truncated limit")
	}
	result.Limit = int(binary.BigEndian.Uint32(data[offset : offset+4]))
	offset += 4

	// Cursor length
	cursorLen := int(binary.BigEndian.Uint16(data[offset : offset+2]))
	offset += 2

	if len(data) < offset+cursorLen {
		return result, errors.New("truncated cursor")
	}
	result.Cursor = string(data[offset : offset+cursorLen])

	return result, nil
}

// DecodeRangeResponse decodes a range query response
// Format: [count:4][items...][hasMore:1][nextCursorLen:2][nextCursor:N]
// Each item: [keyLen:2][key:N][valLen:4][val:M]
func DecodeRangeResponse(data string) (RangeQueryResponse, error) {
	result := RangeQueryResponse{}
	buf := []byte(data)
	offset := 0

	if len(buf) < 5 {
		return result, errors.New("response too short")
	}

	// Count
	count := int(binary.BigEndian.Uint32(buf[offset : offset+4]))
	offset += 4

	result.Items = make([]KeyValue, 0, count)

	// Items
	for i := 0; i < count; i++ {
		if len(buf) < offset+2 {
			return result, errors.New("truncated item key length")
		}
		keyLen := int(binary.BigEndian.Uint16(buf[offset : offset+2]))
		offset += 2

		if len(buf) < offset+keyLen {
			return result, errors.New("truncated item key")
		}
		key := string(buf[offset : offset+keyLen])
		offset += keyLen

		if len(buf) < offset+4 {
			return result, errors.New("truncated item value length")
		}
		valLen := int(binary.BigEndian.Uint32(buf[offset : offset+4]))
		offset += 4

		if len(buf) < offset+valLen {
			return result, errors.New("truncated item value")
		}
		value := string(buf[offset : offset+valLen])
		offset += valLen

		result.Items = append(result.Items, KeyValue{Key: key, Value: value})
	}

	if len(buf) < offset+1 {
		return result, errors.New("truncated hasMore flag")
	}
	result.HasMore = buf[offset] != 0
	offset += 1

	if len(buf) < offset+2 {
		return result, errors.New("truncated cursor length")
	}
	cursorLen := int(binary.BigEndian.Uint16(buf[offset : offset+2]))
	offset += 2

	if len(buf) < offset+cursorLen {
		return result, errors.New("truncated cursor")
	}
	result.NextCursor = string(buf[offset : offset+cursorLen])

	return result, nil
}

// EncodeTraverseRequest encodes a traversal request
// Format: [seq:4][keyLen:2][key:N][pathLen:2][path:N][options:1]
func EncodeTraverseRequest(req TraverseRequest) ([]byte, error) {
	buf := make([]byte, 0,
		4+
			2+len(req.Key)+
			2+len(req.PathSpec)+
			1)

	// Sequence
	buf = append(buf,
		byte(req.Seq>>24),
		byte(req.Seq>>16),
		byte(req.Seq>>8),
		byte(req.Seq))

	// Key
	buf = append(buf, byte(len(req.Key)>>8), byte(len(req.Key)))
	buf = append(buf, []byte(req.Key)...)

	// Path spec
	buf = append(buf, byte(len(req.PathSpec)>>8), byte(len(req.PathSpec)))
	buf = append(buf, []byte(req.PathSpec)...)

	// Options
	buf = append(buf, req.Options)

	return buf, nil
}

// DecodeTraverseResults decodes traversal results
// Format: [status:1][seq:4][count:4][results...]
// Each result: [pathLen:2][path:N][valLen:4][val:M][extFlags:1][extLen:4][ext:M]
func DecodeTraverseResults(data string) (byte, uint32, []TraverseResult, error) {
	buf := []byte(data)
	offset := 0

	if len(buf) < 9 {
		return 0, 0, nil, errors.New("response too short")
	}

	// Status
	status := buf[offset]
	offset += 1

	// Sequence
	seq := binary.BigEndian.Uint32(buf[offset : offset+4])
	offset += 4

	// Count
	count := int(binary.BigEndian.Uint32(buf[offset : offset+4]))
	offset += 4

	results := make([]TraverseResult, 0, count)

	for i := 0; i < count; i++ {
		result := TraverseResult{}

		// Path length
		if len(buf) < offset+2 {
			return status, seq, nil, errors.New("truncated path length")
		}
		pathLen := int(binary.BigEndian.Uint16(buf[offset : offset+2]))
		offset += 2

		// Path
		if len(buf) < offset+pathLen {
			return status, seq, nil, errors.New("truncated path")
		}
		result.Path = string(buf[offset : offset+pathLen])
		offset += pathLen

		// Value length
		if len(buf) < offset+4 {
			return status, seq, nil, errors.New("truncated value length")
		}
		valLen := int(binary.BigEndian.Uint32(buf[offset : offset+4]))
		offset += 4

		// Value
		if valLen > 0 {
			if len(buf) < offset+valLen {
				return status, seq, nil, errors.New("truncated value")
			}
			result.Value = string(buf[offset : offset+valLen])
			offset += valLen
		}

		// Extracted data flag and length
		if len(buf) < offset+1 {
			return status, seq, nil, errors.New("truncated ext flags")
		}
		hasExtracted := buf[offset]
		offset += 1

		if len(buf) < offset+4 {
			return status, seq, nil, errors.New("truncated ext length")
		}
		extLen := int(binary.BigEndian.Uint32(buf[offset : offset+4]))
		offset += 4

		if hasExtracted != 0 && extLen > 0 {
			if len(buf) < offset+extLen {
				return status, seq, nil, errors.New("truncated ext data")
			}
			result.ExtractedData = string(buf[offset : offset+extLen])
			offset += extLen
		}

		// Extract key from path (last element after -> if present)
		if result.Path != "" {
			parts := split(result.Path, "->")
			result.Key = parts[len(parts)-1]
		}

		results = append(results, result)
	}

	return status, seq, results, nil
}

// Helper function to split strings (simple replacement for strings.Split with custom behavior)
func split(s, sep string) []string {
	var parts []string
	start := 0
	for i := 0; i <= len(s)-len(sep); i++ {
		if s[i:i+len(sep)] == sep {
			if i > start {
				parts = append(parts, s[start:i])
			}
			start = i + len(sep)
		}
	}
	if start < len(s) {
		parts = append(parts, s[start:])
	}
	return parts
}
