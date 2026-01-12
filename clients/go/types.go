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

// ============================================================================
// Pub/Sub types
// ============================================================================

// PubSubMessageType represents the type of a PubSub message
type PubSubMessageType byte

const (
	MessageTypeData PubSubMessageType = iota
	MessageTypePresence
)

// PubSubEvent represents a PubSub event received from the server
type PubSubEvent struct {
	Topic        string
	MessageType  PubSubMessageType
	Sequence     uint64
	Timestamp    int64
	Headers      string
	Payload      string
}

// SubscriptionOptions represents options for subscribing to a topic
type SubscriptionOptions struct {
	EnableKvEvents  bool
	EnablePresence  bool
	ReplayHistory   bool
}

// DefaultSubscriptionOptions returns default subscription options
func DefaultSubscriptionOptions() SubscriptionOptions {
	return SubscriptionOptions{
		EnableKvEvents:  false,
		EnablePresence:  false,
		ReplayHistory:   false,
	}
}

// PresenceMember represents a single member in presence data
type PresenceMember struct {
	ClientID uint64
	JoinedAt int64
	LastPing int64
}

// PresenceInfo represents presence information for a topic
type PresenceInfo struct {
	Topic     string
	Members   []PresenceMember
	LastUpdate int64
}

// SubscriptionInfo represents information about a subscription
type SubscriptionInfo struct {
	ID      string
	Topic   string
	Pattern string
}

// HistoryRequest represents parameters for history queries
type HistoryRequest struct {
	Limit    int
	SinceSeq uint64
}
