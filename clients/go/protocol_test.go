package bitbarrel

import (
	"bytes"
	"encoding/binary"
	"testing"
)

// TestIsValidCommand tests valid command checking
func TestIsValidCommand(t *testing.T) {
	tests := []struct {
		name     string
		cmd      byte
		expected bool
	}{
		{"Valid GET", CmdGet, true},
		{"Valid SET", CmdSet, true},
		{"Valid DELETE", CmdDelete, true},
		{"Valid EXISTS", CmdExists, true},
		{"Valid COUNT", CmdCount, true},
		{"Valid LIST_KEYS", CmdListKeys, true},
		{"Valid PING", CmdPing, true},
		{"Valid TRAVERSE", CmdTraverse, true},
		{"Valid RANGE_QUERY", CmdRangeQuery, true},
		{"Valid PREFIX_QUERY", CmdPrefixQuery, true},
		{"Valid RANGE_COUNT", CmdRangeCount, true},
		{"Valid CREATE_BARREL", CmdCreateBarrel, true},
		{"Valid OPEN_BARREL", CmdOpenBarrel, true},
		{"Valid USE_BARREL", CmdUseBarrel, true},
		{"Valid CLOSE_BARREL", CmdCloseBarrel, true},
		{"Valid LIST_BARRELS", CmdListBarrels, true},
		{"Valid DROP_BARREL", CmdDropBarrel, true},
		{"Valid GET_BARREL_CONFIG", CmdGetBarrelConfig, true},
		{"Valid SET_BARREL_CONFIG", CmdSetBarrelConfig, true},
		{"Invalid command 0x00", 0x00, false},
		{"Invalid command 0xFF", 0xFF, false},
		{"Invalid command 0x07", 0x07, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := IsValidCommand(tt.cmd)
			if result != tt.expected {
				t.Errorf("IsValidCommand(0x%02x) = %v, want %v", tt.cmd, result, tt.expected)
			}
		})
	}
}

// TestIsValidStatus tests valid status checking
func TestIsValidStatus(t *testing.T) {
	tests := []struct {
		name     string
		status   byte
		expected bool
	}{
		{"Valid OK", StatusOk, true},
		{"Valid NOT_FOUND", StatusNotFound, true},
		{"Valid ERROR", StatusError, true},
		{"Valid INVALID", StatusInvalid, true},
		{"Valid NO_BARREL", StatusNoBarrel, true},
		{"Valid BARREL_EXISTS", StatusBarrelExists, true},
		{"Valid BARREL_NOT_FOUND", StatusBarrelNotFound, true},
		{"Invalid status 0x07", 0x07, false},
		{"Invalid status 0xFF", 0xFF, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := IsValidStatus(tt.status)
			if result != tt.expected {
				t.Errorf("IsValidStatus(0x%02x) = %v, want %v", tt.status, result, tt.expected)
			}
		})
	}
}

// TestRequestEncodeDecode tests request encoding and decoding round-trip
func TestRequestEncodeDecode(t *testing.T) {
	tests := []struct {
		name string
		req  *Request
	}{
		{
			name: "Simple GET request",
			req:  NewRequest(CmdGet, "key", ""),
		},
		{
			name: "SET request with value",
			req:  NewRequest(CmdSet, "mykey", "myvalue"),
		},
		{
			name: "DELETE request",
			req:  NewRequest(CmdDelete, "deleteMe", ""),
		},
		{
			name: "Request with sequence number",
			req:  &Request{Command: CmdGet, Seq: 12345, Key: "test", Value: ""},
		},
		{
			name: "Request with key and value",
			req: &Request{
				Command: CmdSet,
				Seq:     0,
				Key:     "user:1234:profile",
				Value:   `{"name":"Alice","city":"Monaco"}`,
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			encoded, err := tt.req.Encode()
			if err != nil {
				t.Fatalf("Encode() error = %v", err)
			}

			decoded, err := DecodeRequest(encoded)
			if err != nil {
				t.Fatalf("DecodeRequest() error = %v", err)
			}

			if decoded.Command != tt.req.Command {
				t.Errorf("Command = 0x%02x, want 0x%02x", decoded.Command, tt.req.Command)
			}
			if decoded.Seq != tt.req.Seq {
				t.Errorf("Seq = %d, want %d", decoded.Seq, tt.req.Seq)
			}
			if decoded.Key != tt.req.Key {
				t.Errorf("Key = %q, want %q", decoded.Key, tt.req.Key)
			}
			if decoded.Value != tt.req.Value {
				t.Errorf("Value = %q, want %q", decoded.Value, tt.req.Value)
			}
		})
	}
}

// TestRequestEncodeBinaryFormat tests the binary format of encoded requests (v1.1)
func TestRequestEncodeBinaryFormat(t *testing.T) {
	req := NewRequest(CmdGet, "key", "value")
	req.Seq = 42

	encoded, err := req.Encode()
	if err != nil {
		t.Fatalf("Encode() error = %v", err)
	}

	// Expected format: [cmd:1][seq:4][flags:1][keyLen:2][key][valLen:4][value]
	// CmdGet = 0x01, seq = 42, flags = 0, key = "key" (3 bytes), value = "value" (5 bytes)
	expectedLen := 1 + 4 + 1 + 2 + 3 + 4 + 5
	if len(encoded) != expectedLen {
		t.Errorf("Encoded length = %d, want %d", len(encoded), expectedLen)
	}

	// Check command (byte 0)
	if encoded[0] != CmdGet {
		t.Errorf("Command byte = 0x%02x, want 0x%02x", encoded[0], CmdGet)
	}

	// Check sequence (bytes 1-4)
	seq := binary.BigEndian.Uint32(encoded[1:5])
	if seq != 42 {
		t.Errorf("Sequence = %d, want 42", seq)
	}

	// Check flags (byte 5)
	if encoded[5] != 0 {
		t.Errorf("Flags = 0x%02x, want 0x00", encoded[5])
	}

	// Check key length (bytes 6-7)
	keyLen := binary.BigEndian.Uint16(encoded[6:8])
	if keyLen != 3 {
		t.Errorf("Key length = %d, want 3", keyLen)
	}

	// Check key (bytes 8-10)
	key := string(encoded[8:11])
	if key != "key" {
		t.Errorf("Key = %q, want 'key'", key)
	}

	// Check value length (bytes 11-14)
	valLen := binary.BigEndian.Uint32(encoded[11:15])
	if valLen != 5 {
		t.Errorf("Value length = %d, want 5", valLen)
	}

	// Check value (bytes 15-19)
	value := string(encoded[15:20])
	if value != "value" {
		t.Errorf("Value = %q, want 'value'", value)
	}
}

// TestRequestEncodeErrors tests request encoding error cases
func TestRequestEncodeErrors(t *testing.T) {
	tests := []struct {
		name    string
		req     *Request
		wantErr string
	}{
		{
			name:    "Key too large",
			req:     NewRequest(CmdGet, string(make([]byte, MaxKeySize+1)), ""),
			wantErr: "key too large",
		},
		{
			name:    "Value too large",
			req:     NewRequest(CmdSet, "key", string(make([]byte, MaxValueSize+1))),
			wantErr: "value too large",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := tt.req.Encode()
			if err == nil {
				t.Fatal("Encode() expected error, got nil")
			}
			if err.Error() != tt.wantErr && !contains(err.Error(), tt.wantErr) {
				t.Errorf("Encode() error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

// TestDecodeRequestErrors tests request decoding error cases
func TestDecodeRequestErrors(t *testing.T) {
	tests := []struct {
		name    string
		data    []byte
		wantErr string
	}{
		{
			name:    "Empty data",
			data:    []byte{},
			wantErr: "request too short",
		},
		{
			name:    "Too short",
			data:    []byte{CmdGet},
			wantErr: "request too short",
		},
		{
			name:    "Invalid command",
			data:    []byte{0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, // 12 bytes minimum for v1.1
			wantErr: "invalid command",
		},
		{
			name:    "Truncated key",
			data:    []byte{CmdGet, 0, 0, 0, 0, 0, 0, 5, 0x74, 0x65, 0x73, 0x74}, // seq=0, flags=0, key len=5, 3 key bytes, truncated before value len
			wantErr: "truncated request",
		},
		{
			name:    "Key length too large",
			data:    []byte{CmdGet, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0, 0}, // key length 65535 but no data
			wantErr: "truncated request",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := DecodeRequest(tt.data)
			if err == nil {
				t.Fatal("DecodeRequest() expected error, got nil")
			}
			if !contains(err.Error(), tt.wantErr) {
				t.Errorf("DecodeRequest() error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

// TestResponseEncodeDecode tests response encoding and decoding round-trip
func TestResponseEncodeDecode(t *testing.T) {
	tests := []struct {
		name   string
		resp   *Response
	}{
		{
			name: "OK response without value",
			resp: OkResponse(0, ""),
		},
		{
			name: "OK response with value",
			resp: OkResponse(123, "value"),
		},
		{
			name: "Error response",
			resp: ErrorResponse(456, "Something went wrong"),
		},
		{
			name: "Not found response",
			resp: NotFoundResponse(789),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			encoded, err := tt.resp.Encode()
			if err != nil {
				t.Fatalf("Encode() error = %v", err)
			}

			decoded, err := DecodeResponse(encoded)
			if err != nil {
				t.Fatalf("DecodeResponse() error = %v", err)
			}

			if decoded.Status != tt.resp.Status {
				t.Errorf("Status = 0x%02x, want 0x%02x", decoded.Status, tt.resp.Status)
			}
			if decoded.Seq != tt.resp.Seq {
				t.Errorf("Seq = %d, want %d", decoded.Seq, tt.resp.Seq)
			}
			if decoded.Value != tt.resp.Value {
				t.Errorf("Value = %q, want %q", decoded.Value, tt.resp.Value)
			}
		})
	}
}

// TestResponseEncodeBinaryFormat tests the binary format of encoded responses
func TestResponseEncodeBinaryFormat(t *testing.T) {
	resp := OkResponse(42, "result")

	encoded, err := resp.Encode()
	if err != nil {
		t.Fatalf("Encode() error = %v", err)
	}

	// Expected format: [status:1][seq:4][valLen:4][value]
	// Status = 0x00, seq = 42, value = "result" (6 bytes)
	expectedLen := 1 + 4 + 4 + 6
	if len(encoded) != expectedLen {
		t.Errorf("Encoded length = %d, want %d", len(encoded), expectedLen)
	}

	// Check status (byte 0)
	if encoded[0] != StatusOk {
		t.Errorf("Status byte = 0x%02x, want 0x%02x", encoded[0], StatusOk)
	}

	// Check sequence (bytes 1-4)
	seq := binary.BigEndian.Uint32(encoded[1:5])
	if seq != 42 {
		t.Errorf("Sequence = %d, want 42", seq)
	}

	// Check value length (bytes 5-8)
	valLen := binary.BigEndian.Uint32(encoded[5:9])
	if valLen != 6 {
		t.Errorf("Value length = %d, want 6", valLen)
	}

	// Check value (bytes 9-14)
	value := string(encoded[9:15])
	if value != "result" {
		t.Errorf("Value = %q, want 'result'", value)
	}
}

// TestDecodeResponseErrors tests response decoding error cases
func TestDecodeResponseErrors(t *testing.T) {
	tests := []struct {
		name    string
		data    []byte
		wantErr string
	}{
		{
			name:    "Empty data",
			data:    []byte{},
			wantErr: "response too short",
		},
		{
			name:    "Too short",
			data:    []byte{StatusOk},
			wantErr: "response too short",
		},
		{
			name:    "Invalid status",
			data:    []byte{0xFF, 0, 0, 0, 0, 0, 0, 0, 0},
			wantErr: "invalid status",
		},
		{
			name:    "Truncated value",
			data:    []byte{StatusOk, 0, 0, 0, 0, 0, 0, 0, 5, 0x74, 0x65}, // says val len 5 but only 2 bytes
			wantErr: "truncated response",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := DecodeResponse(tt.data)
			if err == nil {
				t.Fatal("DecodeResponse() expected error, got nil")
			}
			if !contains(err.Error(), tt.wantErr) {
				t.Errorf("DecodeResponse() error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

// TestStatusToError tests status code to error conversion
func TestStatusToError(t *testing.T) {
	tests := []struct {
		name     string
		status   byte
		msg      string
		wantErr  string
	}{
		{"Status Ok", StatusOk, "", ""},
		{"Status Not Found", StatusNotFound, "", "key not found"},
		{"Status Error", StatusError, "Bad request", "Bad request"},
		{"Status Invalid", StatusInvalid, "", "invalid request"},
		{"Status No Barrel", StatusNoBarrel, "", "no barrel selected"},
		{"Status Barrel Exists", StatusBarrelExists, "", "barrel already exists"},
		{"Status Barrel Not Found", StatusBarrelNotFound, "", "barrel not found"},
		{"Unknown status", 0x99, "", "unknown status"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := StatusToError(tt.status, tt.msg)
			if tt.wantErr == "" {
				if err != nil {
					t.Errorf("StatusToError(%d, %q) expected no error, got %v", tt.status, tt.msg, err)
				}
			} else {
				if err == nil {
					t.Fatalf("StatusToError(%d, %q) expected error, got nil", tt.status, tt.msg)
				}
				if !contains(err.Error(), tt.wantErr) {
					t.Errorf("StatusToError(%d, %q) error = %v, want containing %v", tt.status, tt.msg, err.Error(), tt.wantErr)
				}
			}
		})
	}
}

// TestEncodeRangeRequest tests range query request encoding
func TestEncodeRangeRequest(t *testing.T) {
	tests := []struct {
		name string
		req  RangeQueryRequest
	}{
		{
			name: "Basic range query",
			req:  RangeQueryRequest{StartKey: "a", EndKey: "z", Limit: 100, Cursor: ""},
		},
		{
			name: "Range with cursor",
			req:  RangeQueryRequest{StartKey: "user:100", EndKey: "user:200", Limit: 50, Cursor: "user:150"},
		},
		{
			name: "Empty keys",
			req:  RangeQueryRequest{StartKey: "", EndKey: "", Limit: 0, Cursor: ""},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			encoded, err := EncodeRangeRequest(tt.req)
			if err != nil {
				t.Fatalf("EncodeRangeRequest() error = %v", err)
			}

			decoded, err := DecodeRangeRequest(encoded)
			if err != nil {
				t.Fatalf("DecodeRangeRequest() error = %v", err)
			}

			if decoded.StartKey != tt.req.StartKey {
				t.Errorf("StartKey = %q, want %q", decoded.StartKey, tt.req.StartKey)
			}
			if decoded.EndKey != tt.req.EndKey {
				t.Errorf("EndKey = %q, want %q", decoded.EndKey, tt.req.EndKey)
			}
			if decoded.Limit != tt.req.Limit {
				t.Errorf("Limit = %d, want %d", decoded.Limit, tt.req.Limit)
			}
			if decoded.Cursor != tt.req.Cursor {
				t.Errorf("Cursor = %q, want %q", decoded.Cursor, tt.req.Cursor)
			}
		})
	}
}

// TestDecodeRangeRequestErrors tests range request decoding errors
func TestDecodeRangeRequestErrors(t *testing.T) {
	tests := []struct {
		name    string
		data    []byte
		wantErr string
	}{
		{
			name:    "Empty data",
			data:    []byte{},
			wantErr: "too short",
		},
		{
			name:    "Truncated start key",
			data:    []byte{0, 7, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0, 0}, // start key len 7 but only 6 bytes, need len=10 to pass initial check but <11 to truncate
			wantErr: "truncated start key",
		},
		{
			name:    "Truncated end key",
			data:    []byte{0, 3, 0x61, 0x62, 0x63, 0, 5, 0x78, 0x79, 0, 0, 0, 0, 0}, // end key len 5 but only 2 bytes
			wantErr: "truncated end key",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := DecodeRangeRequest(tt.data)
			if err == nil {
				t.Fatal("DecodeRangeRequest() expected error")
			}
			if !contains(err.Error(), tt.wantErr) {
				t.Errorf("Error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

// TestEncodePrefixRequest tests prefix query request encoding
func TestEncodePrefixRequest(t *testing.T) {
	tests := []struct {
		name string
		req  PrefixQueryRequest
	}{
		{
			name: "Basic prefix query",
			req:  PrefixQueryRequest{Prefix: "user:", Limit: 100, Cursor: ""},
		},
		{
			name: "Prefix with cursor",
			req:  PrefixQueryRequest{Prefix: "item:category:", Limit: 50, Cursor: "item:category:widget:100"},
		},
		{
			name: "Empty prefix",
			req:  PrefixQueryRequest{Prefix: "", Limit: 1000, Cursor: ""},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			encoded, err := EncodePrefixRequest(tt.req)
			if err != nil {
				t.Fatalf("EncodePrefixRequest() error = %v", err)
			}

			decoded, err := DecodePrefixRequest(encoded)
			if err != nil {
				t.Fatalf("DecodePrefixRequest() error = %v", err)
			}

			if decoded.Prefix != tt.req.Prefix {
				t.Errorf("Prefix = %q, want %q", decoded.Prefix, tt.req.Prefix)
			}
			if decoded.Limit != tt.req.Limit {
				t.Errorf("Limit = %d, want %d", decoded.Limit, tt.req.Limit)
			}
			if decoded.Cursor != tt.req.Cursor {
				t.Errorf("Cursor = %q, want %q", decoded.Cursor, tt.req.Cursor)
			}
		})
	}
}

// TestDecodeRangeResponse tests range response decoding
func TestDecodeRangeResponse(t *testing.T) {
	buildRangeResponse := func(items []KeyValue, hasMore bool, nextCursor string) string {
		var buf bytes.Buffer

		binary.Write(&buf, binary.BigEndian, uint32(len(items)))

		for _, item := range items {
			binary.Write(&buf, binary.BigEndian, uint16(len(item.Key)))
			buf.WriteString(item.Key)
			binary.Write(&buf, binary.BigEndian, uint32(len(item.Value)))
			buf.WriteString(item.Value)
		}

		hasMoreByte := byte(0)
		if hasMore {
			hasMoreByte = 1
		}
		buf.WriteByte(hasMoreByte)

		binary.Write(&buf, binary.BigEndian, uint16(len(nextCursor)))
		buf.WriteString(nextCursor)

		return buf.String()
	}

	tests := []struct {
		name string
		resp RangeQueryResponse
	}{
		{
			name: "Empty response",
			resp: RangeQueryResponse{
				Items:      []KeyValue{},
				NextCursor: "",
				HasMore:    false,
			},
		},
		{
			name: "Single item",
			resp: RangeQueryResponse{
				Items:      []KeyValue{{Key: "key1", Value: "value1"}},
				NextCursor: "key1",
				HasMore:    true,
			},
		},
		{
			name: "Multiple items",
			resp: RangeQueryResponse{
				Items: []KeyValue{
					{Key: "user:001", Value: "Alice"},
					{Key: "user:002", Value: "Bob"},
					{Key: "user:003", Value: "Charlie"},
				},
				NextCursor: "user:003",
				HasMore:    false,
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			encoded := buildRangeResponse(tt.resp.Items, tt.resp.HasMore, tt.resp.NextCursor)

			decoded, err := DecodeRangeResponse(encoded)
			if err != nil {
				t.Fatalf("DecodeRangeResponse() error = %v", err)
			}

			if decoded.HasMore != tt.resp.HasMore {
				t.Errorf("HasMore = %v, want %v", decoded.HasMore, tt.resp.HasMore)
			}
			if decoded.NextCursor != tt.resp.NextCursor {
				t.Errorf("NextCursor = %q, want %q", decoded.NextCursor, tt.resp.NextCursor)
			}
			if len(decoded.Items) != len(tt.resp.Items) {
				t.Fatalf("Items length = %d, want %d", len(decoded.Items), len(tt.resp.Items))
			}
			for i, item := range decoded.Items {
				if item.Key != tt.resp.Items[i].Key {
					t.Errorf("Item[%d].Key = %q, want %q", i, item.Key, tt.resp.Items[i].Key)
				}
				if item.Value != tt.resp.Items[i].Value {
					t.Errorf("Item[%d].Value = %q, want %q", i, item.Value, tt.resp.Items[i].Value)
				}
			}
		})
	}
}

// TestDecodeRangeResponseErrors tests range response decoding errors
func TestDecodeRangeResponseErrors(t *testing.T) {
	tests := []struct {
		name    string
		data    string
		wantErr string
	}{
		{
			name:    "Empty data",
			data:    "",
			wantErr: "too short",
		},
		{
			name:    "Truncated item key length",
			data:    "\x00\x00\x00\x01", // says 1 item but stops there - actually too short for key length
			wantErr: "too short",
		},
		{
			name:    "Truncated item key",
			data:    "\x00\x00\x00\x01\x00\x05", // count=1, key_len=5 but no key bytes
			wantErr: "truncated item key",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := DecodeRangeResponse(tt.data)
			if err == nil {
				t.Fatal("DecodeRangeResponse() expected error")
			}
			if !contains(err.Error(), tt.wantErr) {
				t.Errorf("Error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

// TestEncodeTraverseRequest tests traverse request encoding
func TestEncodeTraverseRequest(t *testing.T) {
	tests := []struct {
		name string
		req  TraverseRequest
	}{
		{
			name: "Basic traverse request",
			req:  TraverseRequest{Seq: 1, Key: "root", PathSpec: "->", Options: 0x01},
		},
		{
			name: "Traverse with path",
			req:  TraverseRequest{Seq: 42, Key: "user:1", PathSpec: "->profile->name", Options: 0x03},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			encoded, err := EncodeTraverseRequest(tt.req)
			if err != nil {
				t.Fatalf("EncodeTraverseRequest() error = %v", err)
			}

			// Verify structure matches expected format
			if len(encoded) < 4+2+len(tt.req.Key)+2+len(tt.req.PathSpec)+1 {
				t.Errorf("Encoded length too short")
			}

			// Check sequence (bytes 0-3)
			seq := binary.BigEndian.Uint32(encoded[0:4])
			if seq != tt.req.Seq {
				t.Errorf("Seq = %d, want %d", seq, tt.req.Seq)
			}

			// Check options (last byte)
			if encoded[len(encoded)-1] != tt.req.Options {
				t.Errorf("Options = 0x%02x, want 0x%02x", encoded[len(encoded)-1], tt.req.Options)
			}
		})
	}
}

// TestDecodeTraverseResults tests traverse results decoding
func TestDecodeTraverseResults(t *testing.T) {
	buildTraverseResults := func(status byte, seq uint32, results []TraverseResult) string {
		var buf bytes.Buffer

		buf.WriteByte(status)
		binary.Write(&buf, binary.BigEndian, seq)
		binary.Write(&buf, binary.BigEndian, uint32(len(results)))

		for _, result := range results {
			binary.Write(&buf, binary.BigEndian, uint16(len(result.Path)))
			buf.WriteString(result.Path)

			binary.Write(&buf, binary.BigEndian, uint32(len(result.Value)))
			buf.WriteString(result.Value)

			hasExtracted := byte(0)
			if result.ExtractedData != "" {
				hasExtracted = 1
			}
			buf.WriteByte(hasExtracted)

			binary.Write(&buf, binary.BigEndian, uint32(len(result.ExtractedData)))
			buf.WriteString(result.ExtractedData)
		}

		return buf.String()
	}

	tests := []struct {
		name    string
		status  byte
		seq     uint32
		results []TraverseResult
	}{
		{
			name:   "Empty results",
			status: StatusOk,
			seq:    1,
			results: []TraverseResult{},
		},
		{
			name:   "Single result",
			status: StatusOk,
			seq:    42,
			results: []TraverseResult{
				{
					Path:          "->profile->name",
					Key:           "name",
					Value:         "Alice",
					ExtractedData: "Alice",
				},
			},
		},
		{
			name:   "Multiple results",
			status: StatusOk,
			seq:    100,
			results: []TraverseResult{
				{
					Path:  "->profile",
					Key:   "profile",
					Value: `{"name":"Alice","city":"Monaco"}`,
				},
				{
					Path:          "->profile->name",
					Key:           "name",
					Value:         "Alice",
					ExtractedData: "Alice",
				},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			encoded := buildTraverseResults(tt.status, tt.seq, tt.results)

			status, seq, results, err := DecodeTraverseResults(encoded)
			if err != nil {
				t.Fatalf("DecodeTraverseResults() error = %v", err)
			}

			if status != tt.status {
				t.Errorf("Status = 0x%02x, want 0x%02x", status, tt.status)
			}
			if seq != tt.seq {
				t.Errorf("Seq = %d, want %d", seq, tt.seq)
			}
			if len(results) != len(tt.results) {
				t.Fatalf("Results length = %d, want %d", len(results), len(tt.results))
			}
			for i, result := range results {
				if result.Path != tt.results[i].Path {
					t.Errorf("Result[%d].Path = %q, want %q", i, result.Path, tt.results[i].Path)
				}
				if result.Value != tt.results[i].Value {
					t.Errorf("Result[%d].Value = %q, want %q", i, result.Value, tt.results[i].Value)
				}
			}
		})
	}
}

// TestDecodeTraverseResultsErrors tests traverse results decoding errors
func TestDecodeTraverseResultsErrors(t *testing.T) {
	tests := []struct {
		name    string
		data    string
		wantErr string
	}{
		{
			name:    "Empty data",
			data:    "",
			wantErr: "too short",
		},
		{
			name:    "Truncated path length",
			data:    "\x00\x00\x00\x00\x00\x00\x00\x00\x01", // count=1 but missing path length
			wantErr: "truncated path length",
		},
		{
			name:    "Truncated path",
			data:    "\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x05", // path_len=5 but no path bytes
			wantErr: "truncated path",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, _, _, err := DecodeTraverseResults(tt.data)
			if err == nil {
				t.Fatal("DecodeTraverseResults() expected error")
			}
			if !contains(err.Error(), tt.wantErr) {
				t.Errorf("Error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

// TestRangeQueryRequestLimits tests that range query requests are properly bounded
func TestRangeQueryRequestLimits(t *testing.T) {
	tests := []struct {
		name     string
		prefix   string
		minLen   int
		expected bool // whether encoding should succeed
	}{
		{"Empty prefix", "", 0, true},
		{"Normal prefix", "user:", 0, true},
		{"Large prefix", string(make([]byte, 100)), 0, true},
		{"Max prefix", string(make([]byte, 65535)), 65535, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := PrefixQueryRequest{
				Prefix: tt.prefix,
				Limit:  100,
				Cursor: "",
			}
			encoded, err := EncodePrefixRequest(req)

			if tt.expected {
				if err != nil {
					t.Errorf("EncodePrefixRequest() unexpected error: %v", err)
				}
				if len(encoded) < tt.minLen {
					t.Errorf("Encoded length = %d, want >= %d", len(encoded), tt.minLen)
				}
			} else {
				if err == nil {
					t.Error("EncodePrefixRequest() expected error, got nil")
				}
			}
		})
	}
}

// TestCommandConstants tests that command constants match expected values
func TestCommandConstants(t *testing.T) {
	tests := []struct {
		name     string
		constant byte
		expected byte
	}{
		{"CmdGet", CmdGet, 0x01},
		{"CmdSet", CmdSet, 0x02},
		{"CmdDelete", CmdDelete, 0x03},
		{"CmdExists", CmdExists, 0x04},
		{"CmdCount", CmdCount, 0x05},
		{"CmdListKeys", CmdListKeys, 0x06},
		{"CmdPing", CmdPing, 0x09},
		{"CmdTraverse", CmdTraverse, 0x20},
		{"CmdRangeQuery", CmdRangeQuery, 0x21},
		{"CmdPrefixQuery", CmdPrefixQuery, 0x22},
		{"CmdRangeCount", CmdRangeCount, 0x23},
		{"CmdCreateBarrel", CmdCreateBarrel, 0x10},
		{"CmdOpenBarrel", CmdOpenBarrel, 0x11},
		{"CmdUseBarrel", CmdUseBarrel, 0x12},
		{"CmdCloseBarrel", CmdCloseBarrel, 0x13},
		{"CmdListBarrels", CmdListBarrels, 0x14},
		{"CmdDropBarrel", CmdDropBarrel, 0x15},
		{"CmdGetBarrelConfig", CmdGetBarrelConfig, 0x16},
		{"CmdSetBarrelConfig", CmdSetBarrelConfig, 0x17},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.constant != tt.expected {
				t.Errorf("%s = 0x%02x, want 0x%02x", tt.name, tt.constant, tt.expected)
			}
		})
	}
}

// TestStatusConstants tests that status constants match expected values
func TestStatusConstants(t *testing.T) {
	tests := []struct {
		name     string
		constant byte
		expected byte
	}{
		{"StatusOk", StatusOk, 0x00},
		{"StatusNotFound", StatusNotFound, 0x01},
		{"StatusError", StatusError, 0x02},
		{"StatusInvalid", StatusInvalid, 0x03},
		{"StatusNoBarrel", StatusNoBarrel, 0x04},
		{"StatusBarrelExists", StatusBarrelExists, 0x05},
		{"StatusBarrelNotFound", StatusBarrelNotFound, 0x06},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.constant != tt.expected {
				t.Errorf("%s = 0x%02x, want 0x%02x", tt.name, tt.constant, tt.expected)
			}
		})
	}
}

// TestLimitConstants tests that limit constants are correct
func TestLimitConstants(t *testing.T) {
	if MaxKeySize != 65535 {
		t.Errorf("MaxKeySize = %d, want 65535", MaxKeySize)
	}
	if MaxValueSize != 33554432 {
		t.Errorf("MaxValueSize = %d, want 33554432", MaxValueSize)
	}
}

// TestEncodingRoundTripComplex tests complex encoding round-trips
func TestEncodingRoundTripComplex(t *testing.T) {
	original := &Request{
		Command: CmdSet,
		Seq:     999999,
		Key:     "user:profile:settings:theme:dark",
		Value:   `{"enabled":true,"colors":["#ff0000","#00ff00","#0000ff"]}`,
	}

	encoded, err := original.Encode()
	if err != nil {
		t.Fatalf("Encode() error = %v", err)
	}

	decoded, err := DecodeRequest(encoded)
	if err != nil {
		t.Fatalf("DecodeRequest() error = %v", err)
	}

	if decoded.Command != original.Command {
		t.Errorf("Command mismatch")
	}
	if decoded.Seq != original.Seq {
		t.Errorf("Seq mismatch")
	}
	if decoded.Key != original.Key {
		t.Errorf("Key mismatch")
	}
	if decoded.Value != original.Value {
		t.Errorf("Value mismatch")
	}
}

// ============================================================================
// Pub/Sub Tests
// ============================================================================

// TestPubSubCommandConstants tests Pub/Sub command constants
func TestPubSubCommandConstants(t *testing.T) {
	tests := []struct {
		name     string
		constant byte
		expected byte
	}{
		{"CmdSubscribe", CmdSubscribe, 0x40},
		{"CmdUnsubscribe", CmdUnsubscribe, 0x41},
		{"CmdPublish", CmdPublish, 0x42},
		{"CmdListSubscribers", CmdListSubscribers, 0x43},
		{"CmdListTopics", CmdListTopics, 0x45},
		{"CmdHistory", CmdHistory, 0x44},
		{"CmdPresence", CmdPresence, 0x46},
		{"CmdPubSubEvent", CmdPubSubEvent, 0xFF},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.constant != tt.expected {
				t.Errorf("%s = 0x%02x, want 0x%02x", tt.name, tt.constant, tt.expected)
			}
		})
	}
}

// TestPubSubMessageType tests message type constants
func TestPubSubMessageType(t *testing.T) {
	if MessageTypeData != 0 {
		t.Errorf("MessageTypeData = %v, want 0", MessageTypeData)
	}
	if MessageTypePresence != 1 {
		t.Errorf("MessageTypePresence = %v, want 1", MessageTypePresence)
	}
}

// TestPubSubEventType tests PubSubEvent type initialization
func TestPubSubEventType(t *testing.T) {
	event := PubSubEvent{
		Topic:       "test:topic",
		MessageType: MessageTypeData,
		Sequence:    12345,
		Timestamp:   1234567890,
		Headers:     "",
		Payload:     "test payload",
	}

	if event.Topic != "test:topic" {
		t.Errorf("Topic = %q, want 'test:topic'", event.Topic)
	}
	if event.MessageType != MessageTypeData {
		t.Errorf("MessageType = %v, want 0", event.MessageType)
	}
	if event.Sequence != 12345 {
		t.Errorf("Sequence = %d, want 12345", event.Sequence)
	}
	if event.Timestamp != 1234567890 {
		t.Errorf("Timestamp = %d, want 1234567890", event.Timestamp)
	}
	if event.Payload != "test payload" {
		t.Errorf("Payload = %q, want 'test payload'", event.Payload)
	}
}

// TestSubscriptionOptions tests SubscriptionOptions
func TestSubscriptionOptions(t *testing.T) {
	opts := SubscriptionOptions{
		EnableKvEvents: true,
		EnablePresence: false,
		ReplayHistory:  true,
	}

	if !opts.EnableKvEvents {
		t.Errorf("EnableKvEvents should be true")
	}
	if opts.EnablePresence {
		t.Errorf("EnablePresence should be false")
	}
	if !opts.ReplayHistory {
		t.Errorf("ReplayHistory should be true")
	}
}

// TestDefaultSubscriptionOptions tests default subscription options
func TestDefaultSubscriptionOptions(t *testing.T) {
	opts := DefaultSubscriptionOptions()

	if opts.EnableKvEvents {
		t.Errorf("Default EnableKvEvents should be false")
	}
	if opts.EnablePresence {
		t.Errorf("Default EnablePresence should be false")
	}
	if opts.ReplayHistory {
		t.Errorf("Default ReplayHistory should be false")
	}
}

// TestPresenceMember tests PresenceMember type
func TestPresenceMember(t *testing.T) {
	member := PresenceMember{
		ClientID: 12345,
		Username: "alice",
		JoinedAt: 1234567890,
		LastPing: 1234567900,
		Metadata: `{"department":"engineering"}`,
	}

	if member.ClientID != 12345 {
		t.Errorf("ClientID = %d, want 12345", member.ClientID)
	}
	if member.Username != "alice" {
		t.Errorf("Username = %q, want 'alice'", member.Username)
	}
	if member.JoinedAt != 1234567890 {
		t.Errorf("JoinedAt = %d, want 1234567890", member.JoinedAt)
	}
	if member.LastPing != 1234567900 {
		t.Errorf("LastPing = %d, want 1234567900", member.LastPing)
	}
	if member.Metadata != `{"department":"engineering"}` {
		t.Errorf("Metadata incorrect")
	}
}

// TestPresenceInfo tests PresenceInfo type
func TestPresenceInfo(t *testing.T) {
	info := PresenceInfo{
		Topic: "chat:general",
		Members: []PresenceMember{
			{ClientID: 1, Username: "alice", JoinedAt: 100, LastPing: 200},
		},
		LastUpdate: 1234567890,
	}

	if info.Topic != "chat:general" {
		t.Errorf("Topic incorrect")
	}
	if len(info.Members) != 1 {
		t.Errorf("Members length = %d, want 1", len(info.Members))
	}
	if info.Members[0].Username != "alice" {
		t.Errorf("First member username incorrect")
	}
	if info.LastUpdate != 1234567890 {
		t.Errorf("LastUpdate incorrect")
	}
}

// TestSubscriptionInfo tests SubscriptionInfo type
func TestSubscriptionInfo(t *testing.T) {
	info := SubscriptionInfo{
		ID:       "sub-123",
		Topic:    "updates",
		Pattern:  "",
		ClientID: 456,
	}

	if info.ID != "sub-123" {
		t.Errorf("ID incorrect")
	}
	if info.Topic != "updates" {
		t.Errorf("Topic incorrect")
	}
	if info.Pattern != "" {
		t.Errorf("Pattern should be empty")
	}
	if info.ClientID != 456 {
		t.Errorf("ClientID incorrect")
	}
}

// TestTopicInfo tests TopicInfo type
func TestTopicInfo(t *testing.T) {
	info := TopicInfo{
		Name:            "news",
		Sequence:        999,
		SubscriberCount: 42,
		MessageCount:    1234,
	}

	if info.Name != "news" {
		t.Errorf("Name incorrect")
	}
	if info.Sequence != 999 {
		t.Errorf("Sequence incorrect")
	}
	if info.SubscriberCount != 42 {
		t.Errorf("SubscriberCount incorrect")
	}
	if info.MessageCount != 1234 {
		t.Errorf("MessageCount incorrect")
	}
}

// TestHistoryRequest tests HistoryRequest type
func TestHistoryRequest(t *testing.T) {
	req := HistoryRequest{
		Limit:    50,
		SinceSeq: 1000,
	}

	if req.Limit != 50 {
		t.Errorf("Limit = %d, want 50", req.Limit)
	}
	if req.SinceSeq != 1000 {
		t.Errorf("SinceSeq = %d, want 1000", req.SinceSeq)
	}
}

// TestDefaultHistoryRequest tests default history request
func TestDefaultHistoryRequest(t *testing.T) {
	req := DefaultHistoryRequest()

	if req.Limit != 100 {
		t.Errorf("Default Limit = %d, want 100", req.Limit)
	}
	if req.SinceSeq != 0 {
		t.Errorf("Default SinceSeq = %d, want 0", req.SinceSeq)
	}
}

// TestEncodeSubscribeRequest tests subscribe request encoding
func TestEncodeSubscribeRequest(t *testing.T) {
	tests := []struct {
		name    string
		topic   string
		pattern string
		opts    SubscriptionOptions
		wantErr bool
	}{
		{
			name:    "Simple subscription",
			topic:   "updates",
			pattern: "",
			opts:    DefaultSubscriptionOptions(),
		},
		{
			name:    "Subscription with all options",
			topic:   "chat",
			pattern: "",
			opts:    SubscriptionOptions{EnableKvEvents: true, EnablePresence: true, ReplayHistory: true},
		},
		{
			name:    "Pattern subscription",
			topic:   "",
			pattern: "news:*",
			opts:    DefaultSubscriptionOptions(),
		},
		{
			name:    "Pattern subscription with options",
			topic:   "",
			pattern: "events:*",
			opts:    SubscriptionOptions{EnablePresence: true},
		},
		{
			name:    "Subscription with KvEvents option",
			topic:   "notifications",
			pattern: "",
			opts:    SubscriptionOptions{EnableKvEvents: true},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			encoded, err := EncodeSubscribeRequest(tt.topic, tt.pattern, tt.opts)
			if tt.wantErr {
				if err == nil {
					t.Error("EncodeSubscribeRequest() expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("EncodeSubscribeRequest() error = %v", err)
			}

			// Verify structure: [options:1][topicLen:2][topic][patternLen:2][pattern]
			offset := 0

			// Check options byte
			if len(encoded) < 1 {
				t.Fatal("Encoded data too short")
			}
			optionsByte := encoded[offset]
			offset++

			expectedOptions := byte(0)
			if tt.opts.EnableKvEvents {
				expectedOptions |= 0x01
			}
			if tt.opts.EnablePresence {
				expectedOptions |= 0x02
			}
			if tt.opts.ReplayHistory {
				expectedOptions |= 0x04
			}
			if optionsByte != expectedOptions {
				t.Errorf("Options byte = 0x%02x, want 0x%02x", optionsByte, expectedOptions)
			}

			// Check topic
			if len(encoded) < offset+2 {
				t.Fatal("Encoded data too short for topic length")
			}
			topicLen := int(encoded[offset])<<8 | int(encoded[offset+1])
			offset += 2

			if topicLen != len(tt.topic) {
				t.Errorf("Topic length = %d, want %d", topicLen, len(tt.topic))
			}

			if string(encoded[offset:offset+topicLen]) != tt.topic {
				t.Errorf("Topic = %q, want %q", string(encoded[offset:offset+topicLen]), tt.topic)
			}
			offset += topicLen

			// Check pattern
			if len(encoded) < offset+2 {
				t.Fatal("Encoded data too short for pattern length")
			}
			patternLen := int(encoded[offset])<<8 | int(encoded[offset+1])
			offset += 2

			if patternLen != len(tt.pattern) {
				t.Errorf("Pattern length = %d, want %d", patternLen, len(tt.pattern))
			}

			if string(encoded[offset:offset+patternLen]) != tt.pattern {
				t.Errorf("Pattern = %q, want %q", string(encoded[offset:offset+patternLen]), tt.pattern)
			}
		})
	}
}

// TestEncodeSubscribeRequestError tests error cases
func TestEncodeSubscribeRequestError(t *testing.T) {
	tests := []struct {
		name    string
		topic   string
		pattern string
		opts    SubscriptionOptions
		wantErr string
	}{
		{
			name:    "Topic too large",
			topic:   string(make([]byte, MaxKeySize+1)),
			pattern: "",
			opts:    DefaultSubscriptionOptions(),
			wantErr: "topic too large",
		},
		{
			name:    "Pattern too large",
			topic:   "",
			pattern: string(make([]byte, MaxKeySize+1)),
			opts:    DefaultSubscriptionOptions(),
			wantErr: "pattern too large",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := EncodeSubscribeRequest(tt.topic, tt.pattern, tt.opts)
			if err == nil {
				t.Fatal("EncodeSubscribeRequest() expected error, got nil")
			}
			if !contains(err.Error(), tt.wantErr) {
				t.Errorf("Error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

// TestEncodeUnsubscribeRequest tests unsubscribe request (no encoding function, just testing command)
func TestEncodeUnsubscribeRequest(t *testing.T) {
	// Unsubscribe uses the standard Request format with CmdUnsubscribe
	// The value is the subscription ID
	req := NewRequest(CmdUnsubscribe, "sub-123", "")
	if req.Command != CmdUnsubscribe {
		t.Errorf("Command = 0x%02x, want 0x%02x", req.Command, CmdUnsubscribe)
	}
	if req.Key != "sub-123" {
		t.Errorf("Key = %q, want 'sub-123'", req.Key)
	}
}

// TestEncodePublishRequest tests publish request encoding
func TestEncodePublishRequest(t *testing.T) {
	tests := []struct {
		name    string
		topic   string
		msgType PubSubMessageType
		payload string
		headers string
	}{
		{
			name:    "Simple data message",
			topic:   "updates",
			msgType: MessageTypeData,
			payload: "hello world",
			headers: "",
		},
		{
			name:    "Message with headers",
			topic:   "events",
			msgType: MessageTypeData,
			payload: "event data",
			headers: `{"type":"user_action","priority":"high"}`,
		},
		{
			name:    "Presence message",
			topic:   "presence",
			msgType: MessageTypePresence,
			payload: `{}`,
			headers: "",
		},
		{
			name:    "Message with empty headers",
			topic:   "chat",
			msgType: MessageTypeData,
			payload: `{"text":"hi"}`,
			headers: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			encoded, err := EncodePublishRequest(tt.topic, tt.msgType, tt.payload, tt.headers)
			if err != nil {
				t.Fatalf("EncodePublishRequest() error = %v", err)
			}

			// Verify structure: [topicLen:2][topic][msgType:1][headersLen:4][headers][payloadLen:4][payload]
			offset := 0

			// Check topic length
			if len(encoded) < 2 {
				t.Fatal("Encoded data too short")
			}
			topicLen := int(encoded[offset])<<8 | int(encoded[offset+1])
			offset += 2
			if topicLen != len(tt.topic) {
				t.Errorf("Topic length = %d, want %d", topicLen, len(tt.topic))
			}

			// Check topic
			if string(encoded[offset:offset+topicLen]) != tt.topic {
				t.Errorf("Topic = %q, want %q", string(encoded[offset:offset+topicLen]), tt.topic)
			}
			offset += topicLen

			// Check message type
			if len(encoded) < offset+1 {
				t.Fatal("Encoded data too short for message type")
			}
			msgType := PubSubMessageType(encoded[offset])
			offset++
			if msgType != tt.msgType {
				t.Errorf("MessageType = %v, want %v", msgType, tt.msgType)
			}

			// Check headers length
			if len(encoded) < offset+4 {
				t.Fatal("Encoded data too short for headers length")
			}
			headersLen := int(encoded[offset])<<24 | int(encoded[offset+1])<<16 | int(encoded[offset+2])<<8 | int(encoded[offset+3])
			offset += 4
			if headersLen != len(tt.headers) {
				t.Errorf("Headers length = %d, want %d", headersLen, len(tt.headers))
			}

			// Check headers
			if string(encoded[offset:offset+headersLen]) != tt.headers {
				t.Errorf("Headers = %q, want %q", string(encoded[offset:offset+headersLen]), tt.headers)
			}
			offset += headersLen

			// Check payload length
			if len(encoded) < offset+4 {
				t.Fatal("Encoded data too short for payload length")
			}
			payloadLen := int(encoded[offset])<<24 | int(encoded[offset+1])<<16 | int(encoded[offset+2])<<8 | int(encoded[offset+3])
			offset += 4
			if payloadLen != len(tt.payload) {
				t.Errorf("Payload length = %d, want %d", payloadLen, len(tt.payload))
			}

			// Check payload
			if string(encoded[offset:offset+payloadLen]) != tt.payload {
				t.Errorf("Payload = %q, want %q", string(encoded[offset:offset+payloadLen]), tt.payload)
			}
		})
	}
}

// TestEncodePublishRequestWithHeaders tests publish message with JSON headers
func TestEncodePublishRequestWithHeaders(t *testing.T) {
	topic := "events"
	headers := `{"key":"value"}`
	payload := "data"

	encoded, err := EncodePublishRequest(topic, MessageTypeData, payload, headers)
	if err != nil {
		t.Fatalf("EncodePublishRequest() error = %v", err)
	}

	// Expected length: topicLen=2 + topic=6 + msgType=1 + headersLen=4 + headers=15 + payloadLen=4 + payload=4
	expectedLen := 2 + len(topic) + 1 + 4 + len(headers) + 4 + len(payload)
	if len(encoded) != expectedLen {
		t.Errorf("Encoded length = %d, want %d", len(encoded), expectedLen)
	}
}

// TestEncodePublishRequestError tests error cases
func TestEncodePublishRequestError(t *testing.T) {
	tests := []struct {
		name    string
		topic   string
		msgType PubSubMessageType
		payload string
		headers string
		wantErr string
	}{
		{
			name:    "Topic too large",
			topic:   string(make([]byte, MaxKeySize+1)),
			msgType: MessageTypeData,
			payload: "data",
			headers: "",
			wantErr: "topic too large",
		},
		{
			name:    "Payload too large",
			topic:   "topic",
			msgType: MessageTypeData,
			payload: string(make([]byte, MaxValueSize+1)),
			headers: "",
			wantErr: "payload too large",
		},
		{
			name:    "Headers too large",
			topic:   "topic",
			msgType: MessageTypeData,
			payload: "data",
			headers: string(make([]byte, MaxValueSize+1)),
			wantErr: "headers too large",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := EncodePublishRequest(tt.topic, tt.msgType, tt.payload, tt.headers)
			if err == nil {
				t.Fatal("EncodePublishRequest() expected error, got nil")
			}
			if !contains(err.Error(), tt.wantErr) {
				t.Errorf("Error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

// TestDecodeSubscribeResponse tests subscribe response decoding
func TestDecodeSubscribeResponse(t *testing.T) {
	subId := "sub-abc-123"
	result := DecodeSubscribeResponse(subId)
	if result != subId {
		t.Errorf("DecodeSubscribeResponse() = %q, want %q", result, subId)
	}

	// Empty string should also work
	result = DecodeSubscribeResponse("")
	if result != "" {
		t.Errorf("DecodeSubscribeResponse(\"\") = %q, want empty", result)
	}
}

// TestDecodePublishResponse tests publish response decoding
func TestDecodePublishResponse(t *testing.T) {
	tests := []struct {
		name    string
		data    string
		wantSeq uint64
		wantErr bool
	}{
		{
			name:    "Valid response",
			data:    "\x00\x00\x00\x00\x00\x00\x00\x01", // big-endian 1
			wantSeq: 1,
		},
		{
			name:    "Large sequence",
			data:    "\x00\x00\x00\x00\x7F\xFF\xFF\xFF", // big-endian 2147483647
			wantSeq: 2147483647,
		},
		{
			name:    "Zero sequence",
			data:    "\x00\x00\x00\x00\x00\x00\x00\x00",
			wantSeq: 0,
		},
		{
			name:    "Too short",
			data:    "\x00\x00",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			seq, err := DecodePublishResponse(tt.data)
			if tt.wantErr {
				if err == nil {
					t.Error("DecodePublishResponse() expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("DecodePublishResponse() error = %v", err)
			}
			if seq != tt.wantSeq {
				t.Errorf("DecodePublishResponse() = %d, want %d", seq, tt.wantSeq)
			}
		})
	}
}

// TestDecodePubSubEvent tests PubSub event decoding
func TestDecodePubSubEvent(t *testing.T) {
	buildPubSubEvent := func(topic string, msgType PubSubMessageType, seq uint64, ts int64, headers, payload string) []byte {
		var buf bytes.Buffer

		// Command byte (0xFF)
		buf.WriteByte(0xFF)

		// Message sequence (4 bytes, for matching responses)
		binary.Write(&buf, binary.BigEndian, uint32(0))

		// Topic length and topic
		binary.Write(&buf, binary.BigEndian, uint16(len(topic)))
		buf.WriteString(topic)

		// Message type
		buf.WriteByte(byte(msgType))

		// Event sequence (8 bytes)
		binary.Write(&buf, binary.BigEndian, seq)

		// Timestamp (8 bytes)
		binary.Write(&buf, binary.BigEndian, uint64(ts))

		// Headers length and headers
		binary.Write(&buf, binary.BigEndian, uint32(len(headers)))
		buf.WriteString(headers)

		// Payload length and payload
		binary.Write(&buf, binary.BigEndian, uint32(len(payload)))
		buf.WriteString(payload)

		return buf.Bytes()
	}

	tests := []struct {
		name    string
		data    []byte
		want    PubSubEvent
		wantErr bool
	}{
		{
			name: "Simple data event",
			data: buildPubSubEvent("updates", MessageTypeData, 123, 1234567890, "", "hello"),
			want: PubSubEvent{
				Topic:       "updates",
				MessageType: MessageTypeData,
				Sequence:    123,
				Timestamp:   1234567890,
				Headers:     "",
				Payload:     "hello",
			},
		},
		{
			name: "Event with headers",
			data: buildPubSubEvent("events", MessageTypeData, 456, 1234567900, `{"type":"msg"}`, "data"),
			want: PubSubEvent{
				Topic:       "events",
				MessageType: MessageTypeData,
				Sequence:    456,
				Timestamp:   1234567900,
				Headers:     `{"type":"msg"}`,
				Payload:     "data",
			},
		},
		{
			name: "Presence event",
			data: buildPubSubEvent("presence", MessageTypePresence, 789, 1234567910, "", `{}`),
			want: PubSubEvent{
				Topic:       "presence",
				MessageType: MessageTypePresence,
				Sequence:    789,
				Timestamp:   1234567910,
				Headers:     "",
				Payload:     `{}`,
			},
		},
		{
			name:    "Empty data",
			data:    []byte{},
			wantErr: true,
		},
		{
			name:    "Too short data",
			data:    []byte{0xFF, 0, 0, 0, 0, 0, 5}, // cmd + seq + partial topic length
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := DecodePubSubEvent(tt.data)
			if tt.wantErr {
				if err == nil {
					t.Error("DecodePubSubEvent() expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("DecodePubSubEvent() error = %v", err)
			}

			if result.Topic != tt.want.Topic {
				t.Errorf("Topic = %q, want %q", result.Topic, tt.want.Topic)
			}
			if result.MessageType != tt.want.MessageType {
				t.Errorf("MessageType = %v, want %v", result.MessageType, tt.want.MessageType)
			}
			if result.Sequence != tt.want.Sequence {
				t.Errorf("Sequence = %d, want %d", result.Sequence, tt.want.Sequence)
			}
			if result.Timestamp != tt.want.Timestamp {
				t.Errorf("Timestamp = %d, want %d", result.Timestamp, tt.want.Timestamp)
			}
			if result.Headers != tt.want.Headers {
				t.Errorf("Headers = %q, want %q", result.Headers, tt.want.Headers)
			}
			if result.Payload != tt.want.Payload {
				t.Errorf("Payload = %q, want %q", result.Payload, tt.want.Payload)
			}
		})
	}
}

// TestIsPubSubEvent tests checking if data is a PubSub event
func TestIsPubSubEvent(t *testing.T) {
	tests := []struct {
		name   string
		data   []byte
		result bool
	}{
		{"PubSub event data", []byte{0xFF, 0x01, 0x02}, true},
		{"Not PubSub event", []byte{0x01, 0x02}, false},
		{"Request data", []byte{CmdGet, 0, 0, 0, 0}, false},
		{"Response data", []byte{StatusOk, 0, 0, 0, 0}, false},
		{"Empty data", []byte{}, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := IsPubSubEvent(tt.data)
			if result != tt.result {
				t.Errorf("IsPubSubEvent() = %v, want %v", result, tt.result)
			}
		})
	}
}

// TestEncodeHistoryRequest tests history request encoding
func TestEncodeHistoryRequest(t *testing.T) {
	tests := []struct {
		name     string
		topic    string
		count    int
		sinceSeq uint64
	}{
		{
			name:     "Default request",
			topic:    "updates",
			count:    100,
			sinceSeq: 0,
		},
		{
			name:     "With since sequence",
			topic:    "chat",
			count:    50,
			sinceSeq: 1000,
		},
		{
			name:     "Large since sequence",
			topic:    "events",
			count:    200,
			sinceSeq: 0xFFFFFFFFFFFFFFFF,
		},
		{
			name:     "Empty topic",
			topic:    "",
			count:    10,
			sinceSeq: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			encoded, err := EncodeHistoryRequest(tt.topic, tt.count, tt.sinceSeq)
			if err != nil {
				t.Fatalf("EncodeHistoryRequest() error = %v", err)
			}

			// Verify structure: [topicLen:2][topic][count:4][sinceSeq:8]
			offset := 0

			// Check topic length
			if len(encoded) < 2 {
				t.Fatal("Encoded data too short")
			}
			topicLen := int(encoded[offset])<<8 | int(encoded[offset+1])
			offset += 2
			if topicLen != len(tt.topic) {
				t.Errorf("Topic length = %d, want %d", topicLen, len(tt.topic))
			}

			// Check topic
			if string(encoded[offset:offset+topicLen]) != tt.topic {
				t.Errorf("Topic = %q, want %q", string(encoded[offset:offset+topicLen]), tt.topic)
			}
			offset += topicLen

			// Check count
			if len(encoded) < offset+4 {
				t.Fatal("Encoded data too short for count")
			}
			count := int(encoded[offset])<<24 | int(encoded[offset+1])<<16 | int(encoded[offset+2])<<8 | int(encoded[offset+3])
			offset += 4
			if count != tt.count {
				t.Errorf("Count = %d, want %d", count, tt.count)
			}

			// Check sinceSeq
			if len(encoded) < offset+8 {
				t.Fatal("Encoded data too short for sinceSeq")
			}
			sinceSeq := uint64(encoded[offset])<<56 |
				uint64(encoded[offset+1])<<48 |
				uint64(encoded[offset+2])<<40 |
				uint64(encoded[offset+3])<<32 |
				uint64(encoded[offset+4])<<24 |
				uint64(encoded[offset+5])<<16 |
				uint64(encoded[offset+6])<<8 |
				uint64(encoded[offset+7])
			if sinceSeq != tt.sinceSeq {
				t.Errorf("SinceSeq = %d, want %d", sinceSeq, tt.sinceSeq)
			}
		})
	}
}

// TestEncodeHistoryRequestError tests topic size limit
func TestEncodeHistoryRequestError(t *testing.T) {
	topic := string(make([]byte, MaxKeySize+1))
	_, err := EncodeHistoryRequest(topic, 100, 0)
	if err == nil {
		t.Fatal("EncodeHistoryRequest() expected error, got nil")
	}
	if !contains(err.Error(), "topic too large") {
		t.Errorf("Error = %v, want 'topic too large'", err)
	}
}

// TestEncodePresenceRequest tests presence request encoding
func TestEncodePresenceRequest(t *testing.T) {
	tests := []struct {
		name      string
		operation byte
	}{
		{
			name:      "Get online operation",
			operation: 0,
		},
		{
			name:      "Broadcast update operation",
			operation: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			encoded := EncodePresenceRequest(tt.operation)
			if len(encoded) != 1 {
				t.Errorf("Encoded length = %d, want 1", len(encoded))
			}
			if encoded[0] != tt.operation {
				t.Errorf("Operation = %d, want %d", encoded[0], tt.operation)
			}
		})
	}
}

// TestDecodeListSubscribersResponse tests list subscribers response decoding
func TestDecodeListSubscribersResponse(t *testing.T) {
	tests := []struct {
		name    string
		data    string
		want    []SubscriptionInfo
		wantErr bool
	}{
		{
			name: "Empty response",
			data: "",
			want: []SubscriptionInfo{},
		},
		{
			name: "Single subscriber",
			data: `[{"subscriptionId":"sub-1","clientId":123,"topic":"updates","pattern":""}]`,
			want: []SubscriptionInfo{{
				ID:       "sub-1",
				Topic:    "updates",
				Pattern:  "",
				ClientID: 123,
			}},
		},
		{
			name: "Multiple subscribers",
			data: `[{"subscriptionId":"sub-1","clientId":100,"topic":"chat","pattern":""},{"subscriptionId":"sub-2","clientId":200,"topic":"notifications","pattern":""}]`,
			want: []SubscriptionInfo{
				{ID: "sub-1", Topic: "chat", Pattern: "", ClientID: 100},
				{ID: "sub-2", Topic: "notifications", Pattern: "", ClientID: 200},
			},
		},
		{
			name: "Pattern subscriptions",
			data: `[{"subscriptionId":"sub-1","clientId":50,"topic":"","pattern":"events:*"}]`,
			want: []SubscriptionInfo{{
				ID:       "sub-1",
				Topic:    "",
				Pattern:  "events:*",
				ClientID: 50,
			}},
		},
		{
			name:    "Invalid JSON",
			data:    `invalid json`,
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := DecodeListSubscribersResponse(tt.data)
			if tt.wantErr {
				if err == nil {
					t.Error("DecodeListSubscribersResponse() expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("DecodeListSubscribersResponse() error = %v", err)
			}

			if len(result) != len(tt.want) {
				t.Errorf("Result length = %d, want %d", len(result), len(tt.want))
			}

			for i, item := range result {
				if item.ID != tt.want[i].ID {
					t.Errorf("Item[%d].ID = %q, want %q", i, item.ID, tt.want[i].ID)
				}
				if item.Topic != tt.want[i].Topic {
					t.Errorf("Item[%d].Topic = %q, want %q", i, item.Topic, tt.want[i].Topic)
				}
				if item.Pattern != tt.want[i].Pattern {
					t.Errorf("Item[%d].Pattern = %q, want %q", i, item.Pattern, tt.want[i].Pattern)
				}
				if item.ClientID != tt.want[i].ClientID {
					t.Errorf("Item[%d].ClientID = %d, want %d", i, item.ClientID, tt.want[i].ClientID)
				}
			}
		})
	}
}

// TestDecodeListTopicsResponse tests list topics response decoding
func TestDecodeListTopicsResponse(t *testing.T) {
	tests := []struct {
		name    string
		data    string
		want    []TopicInfo
		wantErr bool
	}{
		{
			name: "Empty response",
			data: "",
			want: []TopicInfo{},
		},
		{
			name: "Single topic",
			data: `[{"name":"updates","sequence":100,"subscriberCount":5,"messageCount":20}]`,
			want: []TopicInfo{{
				Name:            "updates",
				Sequence:        100,
				SubscriberCount: 5,
				MessageCount:    20,
			}},
		},
		{
			name: "Multiple topics",
			data: `[{"name":"chat","sequence":200,"subscriberCount":10,"messageCount":100},{"name":"notifications","sequence":50,"subscriberCount":3,"messageCount":15}]`,
			want: []TopicInfo{
				{Name: "chat", Sequence: 200, SubscriberCount: 10, MessageCount: 100},
				{Name: "notifications", Sequence: 50, SubscriberCount: 3, MessageCount: 15},
			},
		},
		{
			name: "Topic with zero counts",
			data: `[{"name":"empty","sequence":0,"subscriberCount":0,"messageCount":0}]`,
			want: []TopicInfo{{
				Name:            "empty",
				Sequence:        0,
				SubscriberCount: 0,
				MessageCount:    0,
			}},
		},
		{
			name:    "Invalid JSON",
			data:    `invalid json`,
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := DecodeListTopicsResponse(tt.data)
			if tt.wantErr {
				if err == nil {
					t.Error("DecodeListTopicsResponse() expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("DecodeListTopicsResponse() error = %v", err)
			}

			if len(result) != len(tt.want) {
				t.Errorf("Result length = %d, want %d", len(result), len(tt.want))
			}

			for i, item := range result {
				if item.Name != tt.want[i].Name {
					t.Errorf("Item[%d].Name = %q, want %q", i, item.Name, tt.want[i].Name)
				}
				if item.Sequence != tt.want[i].Sequence {
					t.Errorf("Item[%d].Sequence = %d, want %d", i, item.Sequence, tt.want[i].Sequence)
				}
				if item.SubscriberCount != tt.want[i].SubscriberCount {
					t.Errorf("Item[%d].SubscriberCount = %d, want %d", i, item.SubscriberCount, tt.want[i].SubscriberCount)
				}
				if item.MessageCount != tt.want[i].MessageCount {
					t.Errorf("Item[%d].MessageCount = %d, want %d", i, item.MessageCount, tt.want[i].MessageCount)
				}
			}
		})
	}
}

// TestDecodeHistoryResponse tests history response decoding
func TestDecodeHistoryResponse(t *testing.T) {
	tests := []struct {
		name    string
		data    string
		want    []PubSubEvent
		wantErr bool
	}{
		{
			name: "Empty response",
			data: "",
			want: []PubSubEvent{},
		},
		{
			name: "Single data message",
			data: `[{"topic":"updates","messageType":0,"sequence":100,"timestamp":1234567890,"headers":"","payload":"hello"}]`,
			want: []PubSubEvent{{
				Topic:       "updates",
				MessageType: MessageTypeData,
				Sequence:    100,
				Timestamp:   1234567890,
				Headers:     "",
				Payload:     "hello",
			}},
		},
		{
			name: "Multiple messages",
			data: `[{"topic":"chat","messageType":0,"sequence":1,"timestamp":1234567800,"headers":"","payload":"msg1"},{"topic":"chat","messageType":0,"sequence":2,"timestamp":1234567900,"headers":"","payload":"msg2"}]`,
			want: []PubSubEvent{
				{Topic: "chat", MessageType: MessageTypeData, Sequence: 1, Timestamp: 1234567800, Headers: "", Payload: "msg1"},
				{Topic: "chat", MessageType: MessageTypeData, Sequence: 2, Timestamp: 1234567900, Headers: "", Payload: "msg2"},
			},
		},
		{
			name: "Message with object payload",
			data: `[{"topic":"events","messageType":0,"sequence":10,"timestamp":1234567890,"headers":"","payload":{"type":"action"}}]`,
			want: []PubSubEvent{{
				Topic:       "events",
				MessageType: MessageTypeData,
				Sequence:    10,
				Timestamp:   1234567890,
				Headers:     "",
				Payload:     `{"type":"action"}`,
			}},
		},
		{
			name: "Presence message",
			data: `[{"topic":"presence","messageType":1,"sequence":5,"timestamp":1234567890,"headers":"","payload":"user_joined"}]`,
			want: []PubSubEvent{{
				Topic:       "presence",
				MessageType: MessageTypePresence,
				Sequence:    5,
				Timestamp:   1234567890,
				Headers:     "",
				Payload:     "user_joined",
			}},
		},
		{
			name:    "Invalid JSON",
			data:    `invalid json`,
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := DecodeHistoryResponse(tt.data)
			if tt.wantErr {
				if err == nil {
					t.Error("DecodeHistoryResponse() expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("DecodeHistoryResponse() error = %v", err)
			}

			if len(result) != len(tt.want) {
				t.Errorf("Result length = %d, want %d", len(result), len(tt.want))
			}

			for i, event := range result {
				if event.Topic != tt.want[i].Topic {
					t.Errorf("Event[%d].Topic = %q, want %q", i, event.Topic, tt.want[i].Topic)
				}
				if event.MessageType != tt.want[i].MessageType {
					t.Errorf("Event[%d].MessageType = %v, want %v", i, event.MessageType, tt.want[i].MessageType)
				}
				if event.Sequence != tt.want[i].Sequence {
					t.Errorf("Event[%d].Sequence = %d, want %d", i, event.Sequence, tt.want[i].Sequence)
				}
				if event.Timestamp != tt.want[i].Timestamp {
					t.Errorf("Event[%d].Timestamp = %d, want %d", i, event.Timestamp, tt.want[i].Timestamp)
				}
				if event.Headers != tt.want[i].Headers {
					t.Errorf("Event[%d].Headers = %q, want %q", i, event.Headers, tt.want[i].Headers)
				}
				if event.Payload != tt.want[i].Payload {
					t.Errorf("Event[%d].Payload = %q, want %q", i, event.Payload, tt.want[i].Payload)
				}
			}
		})
	}
}

// TestDecodePresenceResponse tests presence response decoding
func TestDecodePresenceResponse(t *testing.T) {
	tests := []struct {
		name    string
		topic   string
		data    string
		want    PresenceInfo
		wantErr bool
	}{
		{
			name:  "Empty response",
			topic: "chat",
			data:  "",
			want: PresenceInfo{Topic: "chat", Members: []PresenceMember{}, LastUpdate: 0},
		},
		{
			name:  "Single member",
			topic: "chat",
			data:  `[{"topic":"chat","members":[{"clientId":100,"username":"alice","joinedAt":1234567890,"lastPing":1234567900}],"lastUpdate":1234567910}]`,
			want: PresenceInfo{
				Topic: "chat",
				Members: []PresenceMember{{
					ClientID: 100,
					Username: "alice",
					JoinedAt: 1234567890,
					LastPing: 1234567900,
					Metadata: "",
				}},
				LastUpdate: 1234567910,
			},
		},
		{
			name:  "Multiple members",
			topic: "chat",
			data:  `[{"topic":"chat","members":[{"clientId":100,"username":"alice","joinedAt":100,"lastPing":200},{"clientId":200,"username":"bob","joinedAt":150,"lastPing":250}],"lastUpdate":300}]`,
			want: PresenceInfo{
				Topic: "chat",
				Members: []PresenceMember{
					{ClientID: 100, Username: "alice", JoinedAt: 100, LastPing: 200, Metadata: ""},
					{ClientID: 200, Username: "bob", JoinedAt: 150, LastPing: 250, Metadata: ""},
				},
				LastUpdate: 300,
			},
		},
		{
			name:  "Member with metadata",
			topic: "chat",
			data:  `[{"topic":"chat","members":[{"clientId":100,"username":"alice","joinedAt":100,"lastPing":200,"metadata":"eyJuYW1lIjoiYWxpY2UifQ=="}],"lastUpdate":300}]`,
			want: PresenceInfo{
				Topic: "chat",
				Members: []PresenceMember{{
					ClientID: 100,
					Username: "alice",
					JoinedAt: 100,
					LastPing: 200,
					Metadata: `{"name":"alice"}`,
				}},
				LastUpdate: 300,
			},
		},
		{
			name:    "Invalid JSON",
			topic:   "chat",
			data:    `invalid json`,
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := DecodePresenceResponse(tt.topic, tt.data)
			if tt.wantErr {
				if err == nil {
					t.Error("DecodePresenceResponse() expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("DecodePresenceResponse() error = %v", err)
			}

			if result.Topic != tt.want.Topic {
				t.Errorf("Topic = %q, want %q", result.Topic, tt.want.Topic)
			}
			if result.LastUpdate != tt.want.LastUpdate {
				t.Errorf("LastUpdate = %d, want %d", result.LastUpdate, tt.want.LastUpdate)
			}

			if len(result.Members) != len(tt.want.Members) {
				t.Errorf("Members length = %d, want %d", len(result.Members), len(tt.want.Members))
			}

			for i, member := range result.Members {
				if member.ClientID != tt.want.Members[i].ClientID {
					t.Errorf("Member[%d].ClientID = %d, want %d", i, member.ClientID, tt.want.Members[i].ClientID)
				}
				if member.Username != tt.want.Members[i].Username {
					t.Errorf("Member[%d].Username = %q, want %q", i, member.Username, tt.want.Members[i].Username)
				}
				if member.JoinedAt != tt.want.Members[i].JoinedAt {
					t.Errorf("Member[%d].JoinedAt = %d, want %d", i, member.JoinedAt, tt.want.Members[i].JoinedAt)
				}
				if member.LastPing != tt.want.Members[i].LastPing {
					t.Errorf("Member[%d].LastPing = %d, want %d", i, member.LastPing, tt.want.Members[i].LastPing)
				}
				if member.Metadata != tt.want.Members[i].Metadata {
					t.Errorf("Member[%d].Metadata = %q, want %q", i, member.Metadata, tt.want.Members[i].Metadata)
				}
			}
		})
	}
}

// TestSerializeHistoryPayload tests history payload serialization
func TestSerializeHistoryPayload(t *testing.T) {
	tests := []struct {
		name     string
		payload  interface{}
		expected string
	}{
		{
			name:     "String payload",
			payload:  "hello world",
			expected: "hello world",
		},
		{
			name:     "Empty string",
			payload:  "",
			expected: "",
		},
		{
			name:     "Object payload",
			payload:  map[string]interface{}{"key": "value"},
			expected: `{"key":"value"}`,
		},
		{
			name:     "Nested object",
			payload:  map[string]interface{}{"user": map[string]interface{}{"name": "alice"}},
			expected: `{"user":{"name":"alice"}}`,
		},
		{
			name:     "Array payload",
			payload:  []interface{}{"a", "b", "c"},
			expected: `["a","b","c"]`,
		},
		{
			name:     "Number payload",
			payload:  123,
			expected: `123`,
		},
		{
			name:     "Boolean payload",
			payload:  true,
			expected: `true`,
		},
		{
			name:     "Nil payload",
			payload:  nil,
			expected: `null`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := serializeHistoryPayload(tt.payload)
			if result != tt.expected {
				t.Errorf("serializeHistoryPayload() = %q, want %q", result, tt.expected)
			}
		})
	}
}
