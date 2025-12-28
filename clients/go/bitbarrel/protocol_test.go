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

// TestRequestEncodeBinaryFormat tests the binary format of encoded requests
func TestRequestEncodeBinaryFormat(t *testing.T) {
	req := NewRequest(CmdGet, "key", "value")
	req.Seq = 42

	encoded, err := req.Encode()
	if err != nil {
		t.Fatalf("Encode() error = %v", err)
	}

	// Expected format: [cmd:1][seq:4][keyLen:2][key][valLen:4][value]
	// CmdGet = 0x01, seq = 42, key = "key" (3 bytes), value = "value" (5 bytes)
	expectedLen := 1 + 4 + 2 + 3 + 4 + 5
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

	// Check key length (bytes 5-6)
	keyLen := binary.BigEndian.Uint16(encoded[5:7])
	if keyLen != 3 {
		t.Errorf("Key length = %d, want 3", keyLen)
	}

	// Check key (bytes 7-9)
	key := string(encoded[7:10])
	if key != "key" {
		t.Errorf("Key = %q, want 'key'", key)
	}

	// Check value length (bytes 10-13)
	valLen := binary.BigEndian.Uint32(encoded[10:14])
	if valLen != 5 {
		t.Errorf("Value length = %d, want 5", valLen)
	}

	// Check value (bytes 14-18)
	value := string(encoded[14:19])
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
			data:    []byte{0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
			wantErr: "invalid command",
		},
		{
			name:    "Truncated key",
			data:    []byte{CmdGet, 0, 0, 0, 0, 0, 5, 0x74, 0x65, 0x73, 0x74}, // seq=0, key len=5, 3 key bytes, truncated before value len
			wantErr: "truncated request",
		},
		{
			name:    "Key length too large",
			data:    []byte{CmdGet, 0, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0, 0}, // key length 65535 but no data
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
