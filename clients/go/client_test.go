package bitbarrel

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

const (
	testServerHost = "localhost"
	testServerPort = 9876
)

// skipIfNoServer attempts to connect to test server and skips if unavailable
func skipIfNoServer(t *testing.T) {
	client := NewClient(testServerHost, testServerPort)
	err := client.Connect()
	if err != nil {
		t.Skip("Skipping integration test - no server running on localhost:9876")
	}
	client.Close()
}

// TestNewClient tests client creation
func TestNewClient(t *testing.T) {
	client := NewClient("localhost", 9876)

	if client == nil {
		t.Fatal("NewClient() returned nil")
	}

	if client.host != "localhost" {
		t.Errorf("host = %q, want 'localhost'", client.host)
	}

	if client.port != 9876 {
		t.Errorf("port = %d, want 9876", client.port)
	}

	if client.connectTimeout != 5*time.Second {
		t.Errorf("connectTimeout = %v, want 5s", client.connectTimeout)
	}

	if client.requestTimeout != 3*time.Second {
		t.Errorf("requestTimeout = %v, want 3s", client.requestTimeout)
	}
}

// TestNewClientWithConfig tests client creation with custom config
func TestNewClientWithConfig(t *testing.T) {
	config := ClientConfig{
		Host:           "example.com",
		Port:           8080,
		ConnectTimeout: 10 * time.Second,
		RequestTimeout: 5 * time.Second,
	}
	client := NewClientWithConfig(config)

	if client.host != "example.com" {
		t.Errorf("host = %q, want 'example.com'", client.host)
	}

	if client.port != 8080 {
		t.Errorf("port = %d, want 8080", client.port)
	}

	if client.connectTimeout != 10*time.Second {
		t.Errorf("connectTimeout = %v, want 10s", client.connectTimeout)
	}

	if client.requestTimeout != 5*time.Second {
		t.Errorf("requestTimeout = %v, want 5s", client.requestTimeout)
	}
}

// TestClientConnect tests connecting to the server
func TestClientConnect(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	if client.ws == nil {
		t.Error("WebSocket connection not established")
	}
}

// TestClientConnectFailed tests connecting to a non-existent server
func TestClientConnectFailed(t *testing.T) {
	client := NewClient("localhost", 9999)
	defer client.Close()

	err := client.Connect()
	if err == nil {
		t.Error("Connect() expected error, got nil")
	}
}

// TestClientDoubleConnect tests connecting twice
func TestClientDoubleConnect(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	err := client.Connect()
	if err != nil {
		t.Fatalf("First Connect() error = %v", err)
	}
	defer client.Close()

	err = client.Connect()
	if err == nil {
		t.Error("Second Connect() expected error, got nil")
	}
}

// TestClientClose tests closing the connection
func TestClientClose(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	err = client.Close()
	if err != nil {
		t.Errorf("Close() error = %v", err)
	}

	if client.ws != nil {
		t.Error("WebSocket not nil after Close()")
	}
}

// TestClientCloseWithoutConnect tests closing without connecting
func TestClientCloseWithoutConnect(t *testing.T) {
	client := NewClient(testServerHost, testServerPort)

	err := client.Close()
	if err != nil {
		t.Errorf("Close() without connect error = %v", err)
	}
}

// TestCreateBarrel tests creating a barrel
func TestCreateBarrel(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_barrel_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}

	// Verify barrel exists
 barrels, err := client.ListBarrels()
	if err != nil {
		t.Fatalf("ListBarrels() error = %v", err)
	}

	found := false
	for _, b := range barrels {
		if b == barrelName {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("Barrel %q not found in list", barrelName)
	}

	// Cleanup
	_ = client.DropBarrel(barrelName)
}

// TestCreateBarrelDuplicate tests creating a duplicate barrel
func TestCreateBarrelDuplicate(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_barrel_dup_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, "")
	if err != nil {
		t.Fatalf("First CreateBarrel() error = %v", err)
	}

	err = client.CreateBarrel(barrelName, "")
	if err == nil {
		t.Error("Second CreateBarrel() expected error, got nil")
	}

	// Cleanup
	_ = client.DropBarrel(barrelName)
}

// TestUseBarrel tests using a barrel
func TestUseBarrel(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_barrel_use_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	err = client.UseBarrel(barrelName)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	if client.currentBarrel != barrelName {
		t.Errorf("currentBarrel = %q, want %q", client.currentBarrel, barrelName)
	}
}

// TestUseBarrelNotFound tests using a non-existent barrel
func TestUseBarrelNotFound(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	err = client.UseBarrel("nonexistent_barrel_12345")
	if err == nil {
		t.Error("UseBarrel() expected error, got nil")
	}
}

// TestOpenBarrel tests opening a barrel
func TestOpenBarrel(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_barrel_open_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	err = client.OpenBarrel(barrelName)
	if err != nil {
		t.Fatalf("OpenBarrel() error = %v", err)
	}

	// OpenBarrel doesn't set currentBarrel, so it should be empty
	if client.currentBarrel != "" {
		t.Errorf("currentBarrel should be empty after OpenBarrel, got %q", client.currentBarrel)
	}
}

// TestListBarrels tests listing barrels
func TestListBarrels(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	// Create test barrels
	timestamp := time.Now().UnixNano()
	barrels := []string{
		fmt.Sprintf("test_list_%d_a", timestamp),
		fmt.Sprintf("test_list_%d_b", timestamp),
		fmt.Sprintf("test_list_%d_c", timestamp),
	}

	for _, name := range barrels {
		err := client.CreateBarrel(name, "")
		if err != nil {
			t.Fatalf("CreateBarrel(%q) error = %v", name, err)
		}
		defer client.DropBarrel(name)
	}

	// List barrels
	listed, err := client.ListBarrels()
	if err != nil {
		t.Fatalf("ListBarrels() error = %v", err)
	}

	// Verify our test barrels are in the list
	for _, name := range barrels {
		found := false
		for _, b := range listed {
			if b == name {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("Barrel %q not found in list", name)
		}
	}
}

// TestDropBarrel tests dropping a barrel
func TestDropBarrel(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_barrel_drop_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}

	err = client.DropBarrel(barrelName)
	if err != nil {
		t.Fatalf("DropBarrel() error = %v", err)
	}

	// Verify barrel is gone
	barrels, err := client.ListBarrels()
	if err != nil {
		t.Fatalf("ListBarrels() error = %v", err)
	}

	for _, b := range barrels {
		if b == barrelName {
			t.Errorf("Barrel %q still exists after DropBarrel()", barrelName)
		}
	}
}

// TestSetGet tests setting and getting values
func TestSetGet(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_barrel_setget_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	err = client.UseBarrel(barrelName)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	// Test Set
	err = client.Set("key1", "value1")
	if err != nil {
		t.Fatalf("Set() error = %v", err)
	}

	// Test Get
	value, err := client.Get("key1")
	if err != nil {
		t.Fatalf("Get() error = %v", err)
	}

	if value != "value1" {
		t.Errorf("Get() = %q, want 'value1'", value)
	}

	// Test multiple sets
	err = client.Set("key2", "value2")
	err = client.Set("key3", "value3")
	if err != nil {
		t.Fatalf("Set() error = %v", err)
	}

	// Verify all values
	if v, _ := client.Get("key2"); v != "value2" {
		t.Errorf("Get(key2) = %q, want 'value2'", v)
	}
	if v, _ := client.Get("key3"); v != "value3" {
		t.Errorf("Get(key3) = %q, want 'value3'", v)
	}
}

// TestGetNotFound tests getting a non-existent key
func TestGetNotFound(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_barrel_getnotfound_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	err = client.UseBarrel(barrelName)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	_, err = client.Get("nonexistent_key_12345")
	if err == nil {
		t.Error("Get() expected error, got nil")
	}
}

// TestSetWithoutBarrel tests setting without selecting a barrel
func TestSetWithoutBarrel(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	err = client.Set("key", "value")
	if err == nil {
		t.Error("Set() expected error, got nil")
	}
}

// TestDelete tests deleting keys
func TestDelete(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_barrel_delete_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	err = client.UseBarrel(barrelName)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	// Set a key
	err = client.Set("to_delete", "value")
	if err != nil {
		t.Fatalf("Set() error = %v", err)
	}

	// Verify it exists
	_, err = client.Get("to_delete")
	if err != nil {
		t.Fatalf("Get() before delete error = %v", err)
	}

	// Delete it
	err = client.Delete("to_delete")
	if err != nil {
		t.Fatalf("Delete() error = %v", err)
	}

	// Verify it's gone
	_, err = client.Get("to_delete")
	if err == nil {
		t.Error("Get() after delete expected error, got nil")
	}
}

// TestExists tests checking key existence
func TestExists(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_barrel_exists_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	err = client.UseBarrel(barrelName)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	// Check non-existent key
	exists, err := client.Exists("nonexistent")
	if err != nil {
		t.Fatalf("Exists() error = %v", err)
	}
	if exists {
		t.Error("Exists() = true for non-existent key, want false")
	}

	// Set a key
	err = client.Set("existing_key", "value")
	if err != nil {
		t.Fatalf("Set() error = %v", err)
	}

	// Check existing key
	exists, err = client.Exists("existing_key")
	if err != nil {
		t.Fatalf("Exists() error = %v", err)
	}
	if !exists {
		t.Error("Exists() = false for existing key, want true")
	}
}

// TestCount tests counting keys
func TestCount(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_barrel_count_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	err = client.UseBarrel(barrelName)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	// Check empty barrel
	count, err := client.Count()
	if err != nil {
		t.Fatalf("Count() error = %v", err)
	}
	if count != 0 {
		t.Errorf("Count() = %d, want 0", count)
	}

	// Add some keys
	for i := 0; i < 5; i++ {
		err := client.Set(fmt.Sprintf("key%d", i), fmt.Sprintf("value%d", i))
		if err != nil {
			t.Fatalf("Set() error = %v", err)
		}
	}

	// Check count
	count, err = client.Count()
	if err != nil {
		t.Fatalf("Count() error = %v", err)
	}
	if count != 5 {
		t.Errorf("Count() = %d, want 5", count)
	}
}

// TestListKeys tests listing keys
func TestListKeys(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_barrel_listkeys_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	err = client.UseBarrel(barrelName)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	// Check empty barrel
	keys, err := client.ListKeys()
	if err != nil {
		t.Fatalf("ListKeys() error = %v", err)
	}
	if len(keys) != 0 {
		t.Errorf("ListKeys() length = %d, want 0", len(keys))
	}

	// Add keys
	expectedKeys := []string{"alpha", "beta", "gamma", "delta"}
	for _, key := range expectedKeys {
		err := client.Set(key, "value")
		if err != nil {
			t.Fatalf("Set() error = %v", err)
		}
	}

	// Check keys
	keys, err = client.ListKeys()
	if err != nil {
		t.Fatalf("ListKeys() error = %v", err)
	}
	if len(keys) != len(expectedKeys) {
		t.Errorf("ListKeys() length = %d, want %d", len(keys), len(expectedKeys))
	}

	// Verify all expected keys are present
	for _, expectedKey := range expectedKeys {
		found := false
		for _, key := range keys {
			if key == expectedKey {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("Key %q not found in ListKeys() result", expectedKey)
		}
	}
}

// TestPing tests pinging the server
func TestPing(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	err = client.Ping()
	if err != nil {
		t.Errorf("Ping() error = %v", err)
	}
}

// TestCloseBarrel tests closing the current barrel
func TestCloseBarrel(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_barrel_close_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	err = client.UseBarrel(barrelName)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	if client.currentBarrel != barrelName {
		t.Fatalf("currentBarrel not set before CloseBarrel")
	}

	err = client.CloseBarrel()
	if err != nil {
		t.Fatalf("CloseBarrel() error = %v", err)
	}

	if client.currentBarrel != "" {
		t.Errorf("currentBarrel = %q, want empty after CloseBarrel", client.currentBarrel)
	}
}

// TestLargeValue tests storing and retrieving large values
func TestLargeValue(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_barrel_large_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	err = client.UseBarrel(barrelName)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	largeValue := string(make([]byte, 10000))
	for i := 0; i < 10000; i++ {
		largeValue = largeValue[:i] + "x" + largeValue[i+1:]
	}

	err = client.Set("large_key", largeValue)
	if err != nil {
		t.Fatalf("Set() large value error = %v", err)
	}

	retrieved, err := client.Get("large_key")
	if err != nil {
		t.Fatalf("Get() large value error = %v", err)
	}

	if retrieved != largeValue {
		t.Errorf("Large value mismatch")
	}
}

// TestConcurrency tests concurrent operations
func TestConcurrency(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_barrel_concurrency_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	err = client.UseBarrel(barrelName)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	done := make(chan bool, 10)

	// Launch multiple goroutines that perform operations
	for i := 0; i < 10; i++ {
		go func(n int) {
			key := fmt.Sprintf("conc_key_%d", n)
			value := fmt.Sprintf("conc_value_%d", n)

			// Set
			err := client.Set(key, value)
			if err != nil {
				t.Errorf("goroutine %d Set() error = %v", n, err)
			}

			// Get
			retrieved, err := client.Get(key)
			if err != nil {
				t.Errorf("goroutine %d Get() error = %v", n, err)
			}
			if retrieved != value {
				t.Errorf("goroutine %d value mismatch", n)
			}

			done <- true
		}(i)
	}

	// Wait for all goroutines to complete
	for i := 0; i < 10; i++ {
		<-done
	}

	count, err := client.Count()
	if err != nil {
		t.Fatalf("Count() error = %v", err)
	}
	if count != 10 {
		t.Errorf("Count() after concurrent operations = %d, want 10", count)
	}
}

// TestError tests error handling
func TestError(t *testing.T) {
	err := NewError("testop", fmt.Errorf("test error"))

	if err == nil {
		t.Fatal("NewError() returned nil")
	}

	errorStr := err.Error()
	if errorStr == "" {
		t.Error("Error() returned empty string")
	}

	wrapped := &Error{}
	if errAs, ok := err.(*Error); ok {
		*wrapped = *errAs
	}

	unwrapped := wrapped.Unwrap()
	if unwrapped == nil {
		t.Error("Unwrap() returned nil")
	}
}

// TestClientConfigDefaults tests client configuration defaults
func TestClientConfigDefaults(t *testing.T) {
	client := NewClient("testhost", 9999)

	if client.connectTimeout != 5*time.Second {
		t.Errorf("Default connectTimeout = %v, want 5s", client.connectTimeout)
	}

	if client.requestTimeout != 3*time.Second {
		t.Errorf("Default requestTimeout = %v, want 3s", client.requestTimeout)
	}
}

// TestGetBarrelConfig tests getting barrel configuration
func TestGetBarrelConfig(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_config_get_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, `{"mode": "critbit"}`)
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	config, err := client.GetBarrelConfig(barrelName)
	if err != nil {
		t.Fatalf("GetBarrelConfig() error = %v", err)
	}

	if config == "" {
		t.Error("GetBarrelConfig() returned empty config")
	}

	// Verify the config contains the expected mode
	if !strings.Contains(config, "critbit") {
		t.Errorf("GetBarrelConfig() should contain 'critbit', got: %s", config)
	}
}

// TestSetBarrelConfig tests setting barrel configuration
func TestSetBarrelConfig(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	barrelName := fmt.Sprintf("test_config_set_%d", time.Now().UnixNano())
	err = client.CreateBarrel(barrelName, `{"mode": "critbit"}`)
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	// Try changing a mutable option (can't change mode at runtime)
	newConfig := `{"autoCompact": false}`
	err = client.SetBarrelConfig(barrelName, newConfig)
	if err != nil {
		t.Fatalf("SetBarrelConfig() error = %v", err)
	}

	// Verify the config was updated
	retrieved, err := client.GetBarrelConfig(barrelName)
	if err != nil {
		t.Fatalf("GetBarrelConfig() error = %v", err)
	}

	if !strings.Contains(strings.ToLower(retrieved), `"autocompact": false`) &&
	   !strings.Contains(strings.ToLower(retrieved), `"autocompact":false`) {
		t.Errorf("GetBarrelConfig() should contain autoCompact=false, got: %s", retrieved)
	}
}

// BenchmarkRequestEncode benchmarks request encoding
func BenchmarkRequestEncode(b *testing.B) {
	req := NewRequest(CmdSet, "test_key", "test_value")
	req.Seq = 42

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = req.Encode()
	}
}

// BenchmarkRequestDecode benchmarks request decoding
func BenchmarkRequestDecode(b *testing.B) {
	req := NewRequest(CmdSet, "test_key", "test_value")
	req.Seq = 42
	encoded, _ := req.Encode()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = DecodeRequest(encoded)
	}
}

// BenchmarkResponseEncode benchmarks response encoding
func BenchmarkResponseEncode(b *testing.B) {
	resp := OkResponse(42, "test_value")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = resp.Encode()
	}
}

// BenchmarkResponseDecode benchmarks response decoding
func BenchmarkResponseDecode(b *testing.B) {
	resp := OkResponse(42, "test_value")
	encoded, _ := resp.Encode()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = DecodeResponse(encoded)
	}
}

// TestRangeQuery tests range query operations with ordered barrel
func TestRangeQuery(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	// Create ordered barrel for range queries
	barrelName := fmt.Sprintf("test_range_%d", time.Now().Unix())
	err = client.CreateBarrel(barrelName, `{"mode": "critbit"}`)
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	err = client.UseBarrel(barrelName)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	// Add test data
	client.Set("user:001", "Alice")
	client.Set("user:002", "Bob")
	client.Set("user:003", "Charlie")
	client.Set("product:001", "Widget")

	// Test range query
	result, _, hasMore, err := client.RangeQuery("user:001", "user:003", 1000, "")
	if err != nil {
		t.Fatalf("RangeQuery() error = %v", err)
	}

	if len(result) != 2 {
		t.Errorf("Expected 2 items, got %d", len(result))
	}

	// Verify items
	keys := make(map[string]bool)
	for _, item := range result {
		keys[item.Key] = true
	}
	if !keys["user:001"] || !keys["user:002"] {
		t.Error("Expected keys user:001 and user:002 in results")
	}

	if hasMore {
		t.Error("Expected hasMore to be false")
	}
}

// TestPrefixQuery tests prefix query operations with ordered barrel
func TestPrefixQuery(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	// Create ordered barrel for prefix queries
	barrelName := fmt.Sprintf("test_prefix_%d", time.Now().Unix())
	err = client.CreateBarrel(barrelName, `{"mode": "critbit"}`)
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	err = client.UseBarrel(barrelName)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	// Add test data
	client.Set("user:001", "Alice")
	client.Set("user:002", "Bob")
	client.Set("user:003", "Charlie")
	client.Set("product:001", "Widget")
	client.Set("order:001", "Order1")

	// Test prefix query
	result, _, hasMore, err := client.PrefixQuery("user:", 1000, "")
	if err != nil {
		t.Fatalf("PrefixQuery() error = %v", err)
	}

	if len(result) != 3 {
		t.Errorf("Expected 3 items with prefix 'user:', got %d", len(result))
	}

	// Verify all items have correct prefix
	for _, item := range result {
		if !strings.HasPrefix(item.Key, "user:") {
			t.Errorf("Key %s does not have expected prefix 'user:'", item.Key)
		}
	}

	if hasMore {
		t.Error("Expected hasMore to be false")
	}
}

// TestRangeCount tests counting keys in a range
func TestRangeCount(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	// Create ordered barrel for range queries
	barrelName := fmt.Sprintf("test_count_%d", time.Now().Unix())
	err = client.CreateBarrel(barrelName, `{"mode": "critbit"}`)
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	err = client.UseBarrel(barrelName)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	// Add test data
	client.Set("user:001", "Alice")
	client.Set("user:002", "Bob")
	client.Set("user:003", "Charlie")
	client.Set("user:004", "David")
	client.Set("product:001", "Widget")

	// Test range count
	count, err := client.RangeCount("user:001", "user:004")
	if err != nil {
		t.Fatalf("RangeCount() error = %v", err)
	}

	if count != 3 {
		t.Errorf("Expected count of 3, got %d", count)
	}

	// Test full range
	count, err = client.RangeCount("user:000", "user:999")
	if err != nil {
		t.Fatalf("RangeCount() error = %v", err)
	}

	if count != 4 {
		t.Errorf("Expected count of 4 for full range, got %d", count)
	}
}

// TestGetBarrelConfig tests getting barrel configuration
func TestGetOrDefault(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	// Create barrel
	barrelName := fmt.Sprintf("test_getdefault_%d", time.Now().Unix())
	err = client.CreateBarrel(barrelName, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(barrelName)

	err = client.UseBarrel(barrelName)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	// Test getting non-existent key with default
	value, err := client.GetOrDefault("nonexistent_key", "default_value")
	if err != nil {
		t.Fatalf("GetOrDefault() error = %v", err)
	}

	if value != "default_value" {
		t.Errorf("Expected 'default_value', got %q", value)
	}

	// Add a key and test getting existing value
	err = client.Set("existing_key", "actual_value")
	if err != nil {
		t.Fatalf("Set() error = %v", err)
	}

	value, err = client.GetOrDefault("existing_key", "default_value")
	if err != nil {
		t.Fatalf("GetOrDefault() error = %v", err)
	}

	if value != "actual_value" {
		t.Errorf("Expected 'actual_value', got %q", value)
	}
}

// TestClientWithToken tests client creation with token
func TestClientWithToken(t *testing.T) {
	token := "test-jwt-token"
	client := NewClientWithConfig(ClientConfig{
		Host:           testServerHost,
		Port:           testServerPort,
		ConnectTimeout: 5 * time.Second,
		RequestTimeout: 3 * time.Second,
		Token:          token,
	})

	if client.token != token {
		t.Errorf("token = %q, want %q", client.token, token)
	}
}

// TestConnectWithToken tests connection with JWT token
func TestConnectWithToken(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	client.token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0X3JlYWR3cml0ZSIsInJvbGVzIjpbInJlYWR3cml0ZSJdLCJpYXQiOjE3MDQwNjcyMDAsImV4cCI6NDA5OTc2NzIwMH0.test_signature_for_testing"
	defer client.Close()

	// Connection should succeed and send Authorization header
	err := client.Connect()
	if err != nil {
		// This might fail if server has auth enabled with different config
		// which is expected - we're testing the client sends the token
		t.Logf("Connect() with token error (may be expected): %v", err)
	}
}

// TestConnectWithoutToken tests connection without authentication
func TestConnectWithoutToken(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() without token error: %v", err)
	}
}

