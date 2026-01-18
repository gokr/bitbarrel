package bitbarrel

import (
	"testing"
	"time"
)

// TestGetPresence tests getting presence for a topic
func TestGetPresence(t *testing.T) {
	skipIfNoServer(t)

	client1 := NewClient(testServerHost, testServerPort)
	client2 := NewClient(testServerHost, testServerPort)
	defer client1.Close()
	defer client2.Close()

	err := client1.Connect()
	if err != nil {
		t.Fatalf("Client1 Connect() error = %v", err)
	}
	err = client2.Connect()
	if err != nil {
		t.Fatalf("Client2 Connect() error = %v", err)
	}

	topic := uniqueTopicName("test:presence")

	// Subscribe to topic with presence tracking
	opts := SubscriptionOptions{
		EnablePresence: true,
	}
	subId1, err := client1.Subscribe(topic, opts)
	if err != nil {
		t.Fatalf("Client1 Subscribe() error = %v", err)
	}
	subId2, err := client2.Subscribe(topic, opts)
	if err != nil {
		t.Fatalf("Client2 Subscribe() error = %v", err)
	}

	time.Sleep(100 * time.Millisecond)

	// Get presence
	presence, err := client1.GetPresence(topic)
	if err != nil {
		t.Fatalf("GetPresence() error = %v", err)
	}

	if len(presence.Members) < 2 {
		t.Errorf("GetPresence() returned %d members, want >= 2", len(presence.Members))
	}

	// Verify both clients are in presence
	clientIdMap := make(map[uint64]bool)
	for _, member := range presence.Members {
		clientIdMap[member.ClientID] = true
	}

	if len(clientIdMap) < 2 {
		t.Error("Expected at least 2 unique client IDs in presence")
	}

	// Cleanup
	client1.Unsubscribe(subId1)
	client2.Unsubscribe(subId2)
}

// TestGetPresenceEmpty tests getting presence for a topic with no subscribers
func TestGetPresenceEmpty(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	topic := uniqueTopicName("test:presence_empty")

	// Get presence for topic with no active subscribers
	presence, err := client.GetPresence(topic)
	if err != nil {
		t.Fatalf("GetPresence() error = %v", err)
	}

	if len(presence.Members) != 0 {
		t.Errorf("GetPresence() for empty topic returned %d members, want 0", len(presence.Members))
	}
}

// TestGetPresenceMultipleClients tests presence with multiple clients
func TestGetPresenceMultipleClients(t *testing.T) {
	skipIfNoServer(t)

	// Create 3 clients
	client1 := NewClient(testServerHost, testServerPort)
	client2 := NewClient(testServerHost, testServerPort)
	client3 := NewClient(testServerHost, testServerPort)
	defer client1.Close()
	defer client2.Close()
	defer client3.Close()

	for _, c := range []*Client{client1, client2, client3} {
		err := c.Connect()
		if err != nil {
			t.Fatalf("Connect() error = %v", err)
		}
	}

	topic := uniqueTopicName("test:presence_multi")

	// All clients subscribe with presence
	opts := SubscriptionOptions{
		EnablePresence: true,
	}

	var subIds []string
	for i, c := range []*Client{client1, client2, client3} {
		subId, err := c.Subscribe(topic, opts)
		if err != nil {
			t.Fatalf("Client%d Subscribe() error = %v", i+1, err)
		}
		subIds = append(subIds, subId)
	}

	time.Sleep(100 * time.Millisecond)

	// Get presence from first client
	presence, err := client1.GetPresence(topic)
	if err != nil {
		t.Fatalf("GetPresence() error = %v", err)
	}

	if len(presence.Members) < 3 {
		t.Errorf("GetPresence() returned %d members, want >= 3", len(presence.Members))
	}

	// Verify all 3 clients are present
	clientIdMap := make(map[uint64]bool)
	for _, member := range presence.Members {
		clientIdMap[member.ClientID] = true
	}

	if len(clientIdMap) < 3 {
		t.Error("Expected at least 3 unique client IDs in presence")
	}

	// Cleanup
	for i, c := range []*Client{client1, client2, client3} {
		if i < len(subIds) {
			c.Unsubscribe(subIds[i])
		}
	}
}
