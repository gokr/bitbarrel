package bitbarrel

import (
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Client represents a BitBarrel client connection
type Client struct {
	host         string
	port         int
	ws           *WebSocket
	seq          uint32
	currentBarrel string
	mu           sync.Mutex
	connectTimeout time.Duration
	requestTimeout time.Duration
	token        string  // JWT authorization token

	// Pub/Sub support
	subscriptions sync.Map    // map[string]SubscriptionInfo
	onMessage     func(PubSubEvent)
	eventRecvDone chan struct{}
}

// ClientConfig holds client configuration
type ClientConfig struct {
	Host           string
	Port           int
	ConnectTimeout time.Duration
	RequestTimeout time.Duration
	Token          string  // JWT authorization token
}

// NewClient creates a new BitBarrel client
func NewClient(host string, port int) *Client {
	return NewClientWithConfig(ClientConfig{
		Host:           host,
		Port:           port,
		ConnectTimeout: 5 * time.Second,
		RequestTimeout: 3 * time.Second,
	})
}

// NewClientWithConfig creates a new client with custom configuration
func NewClientWithConfig(config ClientConfig) *Client {
	return &Client{
		host:           config.Host,
		port:           config.Port,
		connectTimeout: config.ConnectTimeout,
		requestTimeout: config.RequestTimeout,
		token:          config.Token,
	}
}

// Connect establishes a connection to the BitBarrel server
func (c *Client) Connect() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.ws != nil {
		return NewError("connect", errors.New("already connected"))
	}

	address := fmt.Sprintf("%s:%d", c.host, c.port)

	var ws *WebSocket
	var err error
	if c.token != "" {
		// Connect with token authentication
		headers := map[string]string{
			"Authorization": "Bearer " + c.token,
		}
		ws, err = DialWithHeaders(address, headers)
	} else {
		// Connect without authentication
		ws, err = Dial(address)
	}
	if err != nil {
		return NewError("connect", err)
	}

	// Set connection deadline
	if err := ws.SetDeadline(time.Now().Add(c.connectTimeout)); err != nil {
		ws.Close()
		return NewError("connect", err)
	}

	c.ws = ws

	// Read welcome message
	_, msg, err := ws.ReadMessage()
	if err != nil {
		ws.Close()
		c.ws = nil
		return NewError("connect", fmt.Errorf("failed to read welcome: %w", err))
	}

	if !contains(string(msg), "Connected to BitBarrel") {
		ws.Close()
		c.ws = nil
		return NewError("connect", errors.New("invalid welcome from server"))
	}

	return nil
}

// Close closes the connection to the server
func (c *Client) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closeUnlocked()
}

// closeUnlocked closes the connection without acquiring the lock
// Caller must hold c.mu
func (c *Client) closeUnlocked() error {
	if c.ws == nil {
		return nil
	}

	err := c.ws.Close()
	c.ws = nil
	return err
}

// ensureConnected ensures the client is connected to the server
func (c *Client) ensureConnected() error {
	c.mu.Lock()
	connected := c.ws != nil
	c.mu.Unlock()

	if !connected {
		return c.Connect()
	}
	return nil
}

// sendRequest sends a request and waits for a response
// Thread-safe: holds lock for entire send-receive cycle to prevent interleaving
func (c *Client) sendRequest(req *Request) (*Response, error) {
	if err := c.ensureConnected(); err != nil {
		return nil, err
	}

	// Hold lock for entire send-receive cycle to prevent concurrent goroutines
	// from interleaving their requests and responses
	c.mu.Lock()
	defer c.mu.Unlock()

	ws := c.ws
	if ws == nil {
		return nil, NewError("connection", fmt.Errorf("not connected"))
	}

	// Increment sequence number
	seq := atomic.AddUint32(&c.seq, 1) - 1
	req.Seq = seq

	// Encode request
	data, err := req.Encode()
	if err != nil {
		return nil, NewError("encode", err)
	}

	// Set request deadline
	if err := ws.SetWriteDeadline(time.Now().Add(c.requestTimeout)); err != nil {
		c.closeUnlocked()
		return nil, NewError("timeout", err)
	}

	// Send request
	if err := ws.WriteMessage(BinaryMessage, data); err != nil {
		c.closeUnlocked()
		return nil, NewError("write", err)
	}

	// Read response (handle case where we might read a PubSub event)
	if err := ws.SetReadDeadline(time.Now().Add(c.requestTimeout)); err != nil {
		c.closeUnlocked()
		return nil, NewError("timeout", err)
	}

	var respData []byte
	for {
		_, data, err := ws.ReadMessage()
		if err != nil {
			c.closeUnlocked()
			return nil, NewError("read", err)
		}

		// Check if this is a PubSub event (command 0xFF)
		// If so, handle it and continue reading for our response
		if IsPubSubEvent(data) {
			event, err := DecodePubSubEvent(data)
			if err == nil && c.onMessage != nil {
				// Lock released briefly to call handler
				c.mu.Unlock()
				c.onMessage(event)
				c.mu.Lock()
				ws = c.ws // Reset ws pointer after potential close
			}
			continue
		}

		respData = data
		break
	}

	// Decode response
	resp, err := DecodeResponse(respData)
	if err != nil {
		return nil, NewError("decode", err)
	}

	// Verify sequence number
	if resp.Seq != seq {
		return nil, NewError("sequence", fmt.Errorf("sequence mismatch: expected %d, got %d", seq, resp.Seq))
	}

	return resp, nil
}

// CreateBarrel creates a new barrel
func (c *Client) CreateBarrel(name string, config string) error {
	req := NewRequest(CmdCreateBarrel, name, config)
	resp, err := c.sendRequest(req)
	if err != nil {
		return err
	}

	if resp.Status == StatusBarrelExists {
		return ErrBarrelExists
	}

	if resp.Status != StatusOk {
		return StatusToError(resp.Status, resp.Value)
	}

	return nil
}

// UseBarrel sets the current barrel for the session
func (c *Client) UseBarrel(name string) error {
	req := NewRequest(CmdUseBarrel, name, "")
	resp, err := c.sendRequest(req)
	if err != nil {
		return err
	}

	if resp.Status == StatusBarrelNotFound {
		return ErrBarrelNotFound
	}

	if resp.Status != StatusOk {
		return StatusToError(resp.Status, resp.Value)
	}

	c.mu.Lock()
	c.currentBarrel = name
	c.mu.Unlock()

	return nil
}

// OpenBarrel opens an existing barrel
func (c *Client) OpenBarrel(name string) error {
	req := NewRequest(CmdOpenBarrel, name, "")
	resp, err := c.sendRequest(req)
	if err != nil {
		return err
	}

	if resp.Status == StatusBarrelNotFound {
		return ErrBarrelNotFound
	}

	if resp.Status != StatusOk {
		return StatusToError(resp.Status, resp.Value)
	}

	return nil
}

// ListBarrels returns a list of all barrels
func (c *Client) ListBarrels() ([]string, error) {
	req := NewRequest(CmdListBarrels, "", "")
	resp, err := c.sendRequest(req)
	if err != nil {
		return nil, err
	}

	if resp.Status != StatusOk {
		return nil, StatusToError(resp.Status, resp.Value)
	}

	if resp.Value == "" {
		return []string{}, nil
	}

	// Split comma-separated list
	barrels := []string{}
	for _, barrel := range split(resp.Value, ",") {
		if barrel != "" {
			barrels = append(barrels, barrel)
		}
	}

	return barrels, nil
}

// CloseBarrel closes the current barrel
func (c *Client) CloseBarrel() error {
	req := NewRequest(CmdCloseBarrel, "", "")
	resp, err := c.sendRequest(req)
	if err != nil {
		return err
	}

	if resp.Status != StatusOk {
		return StatusToError(resp.Status, resp.Value)
	}

	c.mu.Lock()
	c.currentBarrel = ""
	c.mu.Unlock()

	return nil
}

// DropBarrel drops a barrel and all its data
func (c *Client) DropBarrel(name string) error {
	req := NewRequest(CmdDropBarrel, name, "")
	resp, err := c.sendRequest(req)
	if err != nil {
		return err
	}

	if resp.Status == StatusBarrelNotFound {
		return ErrBarrelNotFound
	}

	if resp.Status != StatusOk {
		return StatusToError(resp.Status, resp.Value)
	}

	return nil
}

// ensureBarrel ensures a barrel is selected
func (c *Client) ensureBarrel() error {
	c.mu.Lock()
	barrel := c.currentBarrel
	c.mu.Unlock()

	if barrel == "" {
		return ErrNoBarrel
	}
	return nil
}

// Set stores a key-value pair
func (c *Client) Set(key, value string) error {
	if err := c.ensureBarrel(); err != nil {
		return err
	}

	req := NewRequest(CmdSet, key, value)
	resp, err := c.sendRequest(req)
	if err != nil {
		return err
	}

	if resp.Status != StatusOk {
		return StatusToError(resp.Status, resp.Value)
	}

	return nil
}

// Get retrieves a value by key
func (c *Client) Get(key string) (string, error) {
	if err := c.ensureBarrel(); err != nil {
		return "", err
	}

	req := NewRequest(CmdGet, key, "")
	resp, err := c.sendRequest(req)
	if err != nil {
		return "", err
	}

	if resp.Status == StatusNotFound {
		return "", ErrNotFound
	}

	if resp.Status != StatusOk {
		return "", StatusToError(resp.Status, resp.Value)
	}

	return resp.Value, nil
}

// GetOrDefault retrieves a value by key, returning defaultValue if key doesn't exist
func (c *Client) GetOrDefault(key string, defaultValue string) (string, error) {
	value, err := c.Get(key)
	if err == ErrNotFound {
		return defaultValue, nil
	}
	return value, err
}

// Delete deletes a key
func (c *Client) Delete(key string) error {
	if err := c.ensureBarrel(); err != nil {
		return err
	}

	req := NewRequest(CmdDelete, key, "")
	resp, err := c.sendRequest(req)
	if err != nil {
		return err
	}

	if resp.Status != StatusOk {
		return StatusToError(resp.Status, resp.Value)
	}

	return nil
}

// Exists checks if a key exists
func (c *Client) Exists(key string) (bool, error) {
	if err := c.ensureBarrel(); err != nil {
		return false, err
	}

	req := NewRequest(CmdExists, key, "")
	resp, err := c.sendRequest(req)
	if err != nil {
		return false, err
	}

	if resp.Status == StatusNotFound {
		return false, nil
	}

	if resp.Status != StatusOk {
		return false, StatusToError(resp.Status, resp.Value)
	}

	return resp.Value == "true", nil
}

// Count returns the number of keys in the current barrel
func (c *Client) Count() (int, error) {
	if err := c.ensureBarrel(); err != nil {
		return 0, err
	}

	req := NewRequest(CmdCount, "", "")
	resp, err := c.sendRequest(req)
	if err != nil {
		return 0, err
	}

	if resp.Status != StatusOk {
		return 0, StatusToError(resp.Status, resp.Value)
	}

	var count int
	fmt.Sscanf(resp.Value, "%d", &count)
	return count, nil
}

// ListKeys returns all keys in the current barrel
func (c *Client) ListKeys() ([]string, error) {
	if err := c.ensureBarrel(); err != nil {
		return nil, err
	}

	req := NewRequest(CmdListKeys, "", "")
	resp, err := c.sendRequest(req)
	if err != nil {
		return nil, err
	}

	if resp.Status != StatusOk {
		return nil, StatusToError(resp.Status, resp.Value)
	}

	if resp.Value == "" {
		return []string{}, nil
	}

	keys := []string{}
	for _, key := range split(resp.Value, ",") {
		if key != "" {
			keys = append(keys, key)
		}
	}

	return keys, nil
}

// Ping sends a ping to the server
func (c *Client) Ping() error {
	req := NewRequest(CmdPing, "", "")
	resp, err := c.sendRequest(req)
	if err != nil {
		return err
	}

	if resp.Status != StatusOk || resp.Value != "pong" {
		return errors.New("ping failed")
	}

	return nil
}

// GetBarrelConfig gets the configuration for a barrel
func (c *Client) GetBarrelConfig(name string) (string, error) {
	req := NewRequest(CmdGetBarrelConfig, name, "")
	resp, err := c.sendRequest(req)
	if err != nil {
		return "", err
	}

	if resp.Status == StatusBarrelNotFound {
		return "", ErrBarrelNotFound
	}

	if resp.Status != StatusOk {
		return "", StatusToError(resp.Status, resp.Value)
	}

	return resp.Value, nil
}

// SetBarrelConfig sets the configuration for a barrel
func (c *Client) SetBarrelConfig(name, config string) error {
	req := NewRequest(CmdSetBarrelConfig, name, config)
	resp, err := c.sendRequest(req)
	if err != nil {
		return err
	}

	if resp.Status == StatusBarrelNotFound {
		return ErrBarrelNotFound
	}

	if resp.Status != StatusOk {
		return StatusToError(resp.Status, resp.Value)
	}

	return nil
}

// GetBarrelStats gets comprehensive statistics for a barrel.
//
// Returns JSON string containing metrics:
//   - totalKeys: Total keys including tombstones
//   - activeKeys: Active keys (excluding tombstones)
//   - deletedKeys: Tombstone/deleted keys
//   - fileCount: Number of data files
//   - totalSize: Total bytes on disk for all files
//   - activeFileSize: Size of active data file
//   - avgKeySize: Average key size in bytes
//   - avgValueSize: Average value size in bytes
//   - avgRecordSize: Average record size in bytes
//   - fragmentationRatio: Fragmentation ratio (0.0 to 1.0)
//   - isCompacting: Is compaction currently in progress
//   - lastCompactTime: ISO timestamp of last compaction
//   - recordsScanned: Records scanned in last compaction
//   - recordsKept: Records kept in last compaction
//   - recordsDropped: Records dropped in last compaction
//   - indexMode: Index mode (hash, critbit, hugecritbit)
//   - syncMode: Sync mode (none, sync, fsync)
//   - dataPath: Path to data files
//   - lastModified: ISO timestamp of last modification
//
// Returns ErrBarrelNotFound if barrel doesn't exist.
// Requires read access authentication if enabled.
//
// Example:
//
//	statsJSON, err := client.GetBarrelStats("mydb")
//	if err != nil {
//	    return err
//	}
//
//	var stats map[string]interface{}
//	if err := json.Unmarshal([]byte(statsJSON), &stats); err != nil {
//	    return err
//	}
//
//	fmt.Printf("Total keys: %v\n", stats["totalKeys"])
//	fmt.Printf("Disk usage: %v bytes\n", stats["totalSize"])
//	fmt.Printf("Fragmentation: %.1f%%\n", stats["fragmentationRatio"].(float64)*100)
func (c *Client) GetBarrelStats(name string) (string, error) {
	req := NewRequest(CmdGetBarrelStats, name, "")
	resp, err := c.sendRequest(req)
	if err != nil {
		return "", err
	}

	if resp.Status == StatusBarrelNotFound {
		return "", ErrBarrelNotFound
	}

	if resp.Status != StatusOk {
		return "", StatusToError(resp.Status, resp.Value)
	}

	return resp.Value, nil
}

// RangeQuery queries key-value pairs in range [startKey, endKey)
// Requires barrel opened in bmCritBit mode
func (c *Client) RangeQuery(startKey, endKey string, limit int, cursor string) ([]KeyValue, string, bool, error) {
	if err := c.ensureBarrel(); err != nil {
		return nil, "", false, err
	}

	params := RangeQueryRequest{
		StartKey: startKey,
		EndKey:   endKey,
		Limit:    limit,
		Cursor:   cursor,
	}

	encoded, err := EncodeRangeRequest(params)
	if err != nil {
		return nil, "", false, err
	}

	req := NewRequest(CmdRangeQuery, "", string(encoded))
	resp, err := c.sendRequest(req)
	if err != nil {
		return nil, "", false, err
	}

	if resp.Status != StatusOk {
		return nil, "", false, StatusToError(resp.Status, resp.Value)
	}

	rangeResp, err := DecodeRangeResponse(resp.Value)
	if err != nil {
		return nil, "", false, err
	}

	return rangeResp.Items, rangeResp.NextCursor, rangeResp.HasMore, nil
}

// PrefixQuery queries key-value pairs with prefix
// Requires barrel opened in bmCritBit mode
func (c *Client) PrefixQuery(prefix string, limit int, cursor string) ([]KeyValue, string, bool, error) {
	if err := c.ensureBarrel(); err != nil {
		return nil, "", false, err
	}

	params := PrefixQueryRequest{
		Prefix: prefix,
		Limit:  limit,
		Cursor: cursor,
	}

	encoded, err := EncodePrefixRequest(params)
	if err != nil {
		return nil, "", false, err
	}

	req := NewRequest(CmdPrefixQuery, "", string(encoded))
	resp, err := c.sendRequest(req)
	if err != nil {
		return nil, "", false, err
	}

	if resp.Status != StatusOk {
		return nil, "", false, StatusToError(resp.Status, resp.Value)
	}

	rangeResp, err := DecodeRangeResponse(resp.Value)
	if err != nil {
		return nil, "", false, err
	}

	return rangeResp.Items, rangeResp.NextCursor, rangeResp.HasMore, nil
}

// RangeCount counts keys in range [startKey, endKey)
func (c *Client) RangeCount(startKey, endKey string) (int, error) {
	if err := c.ensureBarrel(); err != nil {
		return 0, err
	}

	params := RangeQueryRequest{
		StartKey: startKey,
		EndKey:   endKey,
		Limit:    0,
		Cursor:   "",
	}

	encoded, err := EncodeRangeRequest(params)
	if err != nil {
		return 0, err
	}

	req := NewRequest(CmdRangeCount, "", string(encoded))
	resp, err := c.sendRequest(req)
	if err != nil {
		return 0, err
	}

	if resp.Status != StatusOk {
		return 0, StatusToError(resp.Status, resp.Value)
	}

	var count int
	fmt.Sscanf(resp.Value, "%d", &count)
	return count, nil
}

// RangeQueryKeys queries only keys in range [startKey, endKey)
// Requires barrel opened in bmCritBit mode
// Empty startKey/endKey queries entire barrel
func (c *Client) RangeQueryKeys(startKey, endKey string, limit int, cursor string) ([]string, string, bool, error) {
	if err := c.ensureBarrel(); err != nil {
		return nil, "", false, err
	}

	params := RangeQueryRequest{
		StartKey: startKey,
		EndKey:   endKey,
		Limit:    limit,
		Cursor:   cursor,
	}

	encoded, err := EncodeRangeRequest(params)
	if err != nil {
		return nil, "", false, err
	}

	req := NewRequest(CmdRangeKeys, "", string(encoded))
	resp, err := c.sendRequest(req)
	if err != nil {
		return nil, "", false, err
	}

	if resp.Status != StatusOk {
		return nil, "", false, StatusToError(resp.Status, resp.Value)
	}

	keysResp, err := DecodeKeysResponse(resp.Value)
	if err != nil {
		return nil, "", false, err
	}

	return keysResp.Keys, keysResp.NextCursor, keysResp.HasMore, nil
}

// PrefixQueryKeys queries only keys with prefix
// Requires barrel opened in bmCritBit mode
func (c *Client) PrefixQueryKeys(prefix string, limit int, cursor string) ([]string, string, bool, error) {
	if err := c.ensureBarrel(); err != nil {
		return nil, "", false, err
	}

	params := PrefixQueryRequest{
		Prefix: prefix,
		Limit:  limit,
		Cursor: cursor,
	}

	encoded, err := EncodePrefixRequest(params)
	if err != nil {
		return nil, "", false, err
	}

	req := NewRequest(CmdPrefixKeys, "", string(encoded))
	resp, err := c.sendRequest(req)
	if err != nil {
		return nil, "", false, err
	}

	if resp.Status != StatusOk {
		return nil, "", false, StatusToError(resp.Status, resp.Value)
	}

	keysResp, err := DecodeKeysResponse(resp.Value)
	if err != nil {
		return nil, "", false, err
	}

	return keysResp.Keys, keysResp.NextCursor, keysResp.HasMore, nil
}

// Traverse traverses references from a key using path specification
func (c *Client) Traverse(key, pathSpec string, options TraverseOptions) ([]TraverseResult, error) {
	if err := c.ensureBarrel(); err != nil {
		return nil, err
	}

	c.mu.Lock()
	seq := atomic.AddUint32(&c.seq, 1) - 1
	c.mu.Unlock()

	// Build options byte
	var optionsByte uint8
	if options.IncludeFullData {
		optionsByte |= 0x01
	}
	if options.ExtractArrays {
		optionsByte |= 0x02
	}
	if options.FirstOnly {
		optionsByte |= 0x04
	}

	tReq := TraverseRequest{
		Seq:      seq,
		Key:      key,
		PathSpec: pathSpec,
		Options:  optionsByte,
	}

	encoded, err := EncodeTraverseRequest(tReq)
	if err != nil {
		return nil, err
	}

	req := NewRequest(CmdTraverse, "", string(encoded))
	resp, err := c.sendRequest(req)
	if err != nil {
		return nil, err
	}

	if resp.Status != StatusOk {
		return nil, StatusToError(resp.Status, resp.Value)
	}

	_, _, results, err := DecodeTraverseResults(resp.Value)
	if err != nil {
		return nil, err
	}

	return results, nil
}

// TraversePath traverses with default options (include full data, no extraction)
func (c *Client) TraversePath(key, pathSpec string) ([]TraverseResult, error) {
	options := TraverseOptions{
		IncludeFullData: true,
		ExtractArrays:   false,
		FirstOnly:       false,
	}
	return c.Traverse(key, pathSpec, options)
}

// ============================================================================
// Pub/Sub Methods
// ============================================================================

// Subscribe to topic with options (supports pattern matching with *)
// Returns subscription ID
func (c *Client) Subscribe(topic string, opts SubscriptionOptions) (string, error) {
	if err := c.ensureConnected(); err != nil {
		return "", err
	}

	// Determine if this is a pattern subscription (contains *)
	isPattern := strings.Contains(topic, "*")
	actualTopic := ""
	actualPattern := ""
	if isPattern {
		actualPattern = topic
	} else {
		actualTopic = topic
	}

	// Encode subscribe request
	subscribeData, err := EncodeSubscribeRequest(actualTopic, actualPattern, opts)
	if err != nil {
		return "", NewError("subscribe", err)
	}

	req := NewRequest(CmdSubscribe, "", string(subscribeData))
	resp, err := c.sendRequest(req)
	if err != nil {
		return "", err
	}

	if resp.Status != StatusOk {
		return "", NewError("subscribe", errors.New(resp.Value))
	}

	// Response value is the subscription ID
	subId := DecodeSubscribeResponse(resp.Value)

	// Track subscription
	c.subscriptions.Store(subId, SubscriptionInfo{
		ID:      subId,
		Topic:   actualTopic,
		Pattern: actualPattern,
	})

	return subId, nil
}

// SubscribeSimple subscribes to exact topic with default options
func (c *Client) SubscribeSimple(topic string) (string, error) {
	opts := DefaultSubscriptionOptions()
	return c.Subscribe(topic, opts)
}

// IsSubscribed checks if subscription is active
func (c *Client) IsSubscribed(subId string) bool {
	_, ok := c.subscriptions.Load(subId)
	return ok
}

// Unsubscribe from subscription
// Returns true if subscription existed and was removed
func (c *Client) Unsubscribe(subId string) (bool, error) {
	if err := c.ensureConnected(); err != nil {
		return false, err
	}

	// Check if subscription exists
	_, ok := c.subscriptions.Load(subId)
	if !ok {
		return false, nil
	}

	req := NewRequest(CmdUnsubscribe, subId, "")
	resp, err := c.sendRequest(req)
	if err != nil {
		return false, err
	}

	if resp.Status == StatusOk {
		c.subscriptions.Delete(subId)
		return true, nil
	}
	return false, nil
}

// UnsubscribeAll unsubscribes from all active subscriptions
// Returns number of subscriptions removed
func (c *Client) UnsubscribeAll() (int, error) {
	count := 0
	c.subscriptions.Range(func(key, value interface{}) bool {
		subId := key.(string)
		if removed, err := c.Unsubscribe(subId); err == nil && removed {
			count++
		}
		return true
	})
	return count, nil
}

// Publish message with type and headers to topic
// Returns sequence number
func (c *Client) Publish(topic string, msgType PubSubMessageType, payload string, headers string) (uint64, error) {
	if err := c.ensureConnected(); err != nil {
		return 0, err
	}

	publishData, err := EncodePublishRequest(topic, msgType, payload, headers)
	if err != nil {
		return 0, NewError("publish", err)
	}

	req := NewRequest(CmdPublish, "", string(publishData))
	resp, err := c.sendRequest(req)
	if err != nil {
		return 0, err
	}

	if resp.Status != StatusOk {
		return 0, NewError("publish", errors.New(resp.Value))
	}

	// Response value contains the sequence number as uint64
	seq, err := DecodePublishResponse(resp.Value)
	if err != nil {
		return 0, NewError("publish", err)
	}

	return seq, nil
}

// PublishSimple publishes message with type to topic
func (c *Client) PublishSimple(topic string, msgType PubSubMessageType, payload string) (uint64, error) {
	return c.Publish(topic, msgType, payload, "")
}

// PublishData publishes data message to topic
func (c *Client) PublishData(topic string, payload string) (uint64, error) {
	return c.Publish(topic, MessageTypeData, payload, "")
}

// ListSubscribers lists subscribers for a topic
func (c *Client) ListSubscribers(topic string) ([]SubscriptionInfo, error) {
	if err := c.ensureConnected(); err != nil {
		return nil, err
	}

	// Server expects topic in value field, not key
	req := NewRequest(CmdListSubscribers, "", topic)
	resp, err := c.sendRequest(req)
	if err != nil {
		return nil, err
	}

	if resp.Status != StatusOk {
		return nil, StatusToError(resp.Status, resp.Value)
	}

	return DecodeListSubscribersResponse(resp.Value)
}

// ListTopics lists all topics
func (c *Client) ListTopics() ([]TopicInfo, error) {
	if err := c.ensureConnected(); err != nil {
		return nil, err
	}

	req := NewRequest(CmdListTopics, "", "")
	resp, err := c.sendRequest(req)
	if err != nil {
		return nil, err
	}

	if resp.Status != StatusOk {
		return nil, StatusToError(resp.Status, resp.Value)
	}

	return DecodeListTopicsResponse(resp.Value)
}

// GetHistory gets message history for topic
// If req is zero-valued, defaults to limit=100, sinceSeq=0
func (c *Client) GetHistory(topic string, req HistoryRequest) ([]PubSubEvent, error) {
	if err := c.ensureConnected(); err != nil {
		return nil, err
	}

	// Use default request if not provided
	if req.Limit == 0 && req.SinceSeq == 0 {
		req = DefaultHistoryRequest()
	}

	historyData, err := EncodeHistoryRequest(topic, req.Limit, req.SinceSeq)
	if err != nil {
		return nil, NewError("history", err)
	}

	request := NewRequest(CmdHistory, "", string(historyData))
	resp, err := c.sendRequest(request)
	if err != nil {
		return nil, err
	}

	if resp.Status != StatusOk {
		return nil, StatusToError(resp.Status, resp.Value)
	}

	return DecodeHistoryResponse(resp.Value)
}

// GetPresence gets presence info for topic
func (c *Client) GetPresence(topic string) (PresenceInfo, error) {
	if err := c.ensureConnected(); err != nil {
		return PresenceInfo{}, err
	}

	// Presence request: operation 0 = get_online
	presenceData := EncodePresenceRequest(0)

	req := NewRequest(CmdPresence, topic, string(presenceData))
	resp, err := c.sendRequest(req)
	if err != nil {
		return PresenceInfo{}, err
	}

	if resp.Status != StatusOk {
		return PresenceInfo{}, StatusToError(resp.Status, resp.Value)
	}

	return DecodePresenceResponse(topic, resp.Value)
}

// SetMessageHandler sets the callback function for PubSub events
func (c *Client) SetMessageHandler(handler func(PubSubEvent)) {
	c.onMessage = handler
}

// StartEventReceiver starts a background goroutine to receive PubSub events
// The goroutine continuously reads messages and calls the message handler
// for any PubSub events (command 0xFF)
func (c *Client) StartEventReceiver() {
	c.mu.Lock()
	if c.eventRecvDone != nil {
		c.mu.Unlock()
		return // Already running
	}
	c.eventRecvDone = make(chan struct{})
	c.mu.Unlock()

	// Start goroutine to handle PubSub events
	go c.receivePubSubEvent()
}

// StopEventReceiver stops the event receiver goroutine
func (c *Client) StopEventReceiver() {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.eventRecvDone != nil {
		close(c.eventRecvDone)
		c.eventRecvDone = nil
	}
}

// receivePubSubEvent continuously reads messages and handles PubSub events
func (c *Client) receivePubSubEvent() {
	for {
		c.mu.Lock()
		ws := c.ws
		done := c.eventRecvDone
		c.mu.Unlock()

		if ws == nil {
			return // Connection closed
		}

		// Check if we should stop
		select {
		case <-done:
			return
		default:
		}

		// Try to read a message without blocking
		ws.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
		_, data, err := ws.ReadMessage()
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue // Timeout is expected
			}
			return // Connection error
		}

		// Check if this is a PubSub event (command 0xFF)
		if IsPubSubEvent(data) {
			event, err := DecodePubSubEvent(data)
			if err != nil {
				continue // Skip malformed events
			}

			// Call message handler if set
			c.mu.Lock()
			handler := c.onMessage
			c.mu.Unlock()

			if handler != nil {
				handler(event)
			}
		}
		// Skip non-event messages (responses will be read by sendRequest)
	}
}

// Helper functions

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > len(substr) && containsString(s, substr))
}

func containsString(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

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
