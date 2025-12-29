package bitbarrel

import (
	"errors"
	"fmt"
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

	// Read response
	if err := ws.SetReadDeadline(time.Now().Add(c.requestTimeout)); err != nil {
		c.closeUnlocked()
		return nil, NewError("timeout", err)
	}

	_, respData, err := ws.ReadMessage()
	if err != nil {
		c.closeUnlocked()
		return nil, NewError("read", err)
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
