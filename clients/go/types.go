package bitbarrel

// KeyValue represents a key-value pair
type KeyValue struct {
	Key   string
	Value string
}

// RangeQueryRequest represents parameters for range queries
type RangeQueryRequest struct {
	StartKey string
	EndKey   string
	Limit    int
	Cursor   string
}

// PrefixQueryRequest represents parameters for prefix queries
type PrefixQueryRequest struct {
	Prefix string
	Limit  int
	Cursor string
}

// RangeQueryResponse represents the response from range/prefix queries
type RangeQueryResponse struct {
	Items      []KeyValue
	NextCursor string
	HasMore    bool
}

// KeysResponse represents the response from keys-only range/prefix queries
type KeysResponse struct {
	Keys       []string
	NextCursor string
	HasMore    bool
}

// TraverseOptions represents options for reference traversal
type TraverseOptions struct {
	IncludeFullData bool
	ExtractArrays   bool
	FirstOnly       bool
}

// TraverseResult represents a result from reference traversal
type TraverseResult struct {
	Path          string
	Key           string
	Value         string
	ExtractedData string
}

// TraverseRequest represents parameters for traversal requests
type TraverseRequest struct {
	Seq      uint32
	Key      string
	PathSpec string
	Options  uint8
}
