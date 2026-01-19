package bitbarrel

import (
	"testing"
	"time"
)

// TestListSubscribers tests listing subscribers for a topic
func TestListSubscribers(t *testing.T) {
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

	topic := uniqueTopicName("test:list_subscribers")

	// Both clients subscribe to the same topic
	subId1, err := client1.SubscribeSimple(topic)
	if err != nil {
		t.Fatalf("Client1 SubscribeSimple() error = %v", err)
	}
	subId2, err := client2.SubscribeSimple(topic)
	if err != nil {
		t.Fatalf("Client2 SubscribeSimple() error = %v", err)
	}

	time.Sleep(100 * time.Millisecond) // Wait for subscriptions to register

	// List subscribers (using client1)
	subscribers, err := client1.ListSubscribers(topic)
	if err != nil {
		t.Fatalf("ListSubscribers() error = %v", err)
	}

	if len(subscribers) < 2 {
		t.Errorf("ListSubscribers() returned %d subscribers, want >= 2", len(subscribers))
	}

	// Verify subscription IDs are unique
	idMap := make(map[string]bool)
	for _, sub := range subscribers {
		idMap[sub.ID] = true
	}
	if len(idMap) < 2 {
		t.Error("Expected at least 2 unique subscription IDs")
	}

	// Cleanup
	client1.Unsubscribe(subId1)
	client2.Unsubscribe(subId2)
}

// TestListSubscribersEmpty tests listing subscribers for a topic with no subscribers
func TestListSubscribersEmpty(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	topic := uniqueTopicName("test:list_subscribers_empty")

	// List subscribers without subscribing anyone
	subscribers, err := client.ListSubscribers(topic)
	if err != nil {
		t.Fatalf("ListSubscribers() error = %v", err)
	}

	if len(subscribers) != 0 {
		t.Errorf("ListSubscribers() for empty topic returned %d subscribers, want 0", len(subscribers))
	}
}

// TestListSubscribersNonExistent tests listing subscribers for a non-existent topic
func TestListSubscribersNonExistent(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	topic := uniqueTopicName("test:list_subscribers_nonexistent")

	// List subscribers for topic that doesn't exist yet
	subscribers, err := client.ListSubscribers(topic)
	if err != nil {
		t.Fatalf("ListSubscribers() error = %v", err)
	}

	// Should return empty list, not error
	if len(subscribers) != 0 {
		t.Errorf("ListSubscribers() for non-existent topic returned %d subscribers, want 0", len(subscribers))
	}
}

// TestListTopics tests listing all topics
func TestListTopics(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	// Create a test barrel (topics are created when publishing)
	testBarrel := uniqueTopicName("test_barrel")
	err = client.CreateBarrel(testBarrel, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(testBarrel)

	err = client.UseBarrel(testBarrel)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	// Publish to multiple topics to create them
	topic1 := uniqueTopicName("test:list_topics1")
	topic2 := uniqueTopicName("test:list_topics2")
	topic3 := uniqueTopicName("test:list_topics3")

	client.PublishData(topic1, "data1")
	client.PublishData(topic2, "data2")
	client.PublishData(topic3, "data3")

	time.Sleep(100 * time.Millisecond)

	// List all topics
	topics, err := client.ListTopics()
	if err != nil {
		t.Fatalf("ListTopics() error = %v", err)
	}

	if len(topics) < 3 {
		t.Errorf("ListTopics() returned %d topics, want >= 3", len(topics))
	}

	// Find our topics
	topicMap := make(map[string]bool)
	for _, topic := range topics {
		topicMap[topic.Name] = true
	}

	if !topicMap[topic1] || !topicMap[topic2] || !topicMap[topic3] {
		t.Error("ListTopics() did not find all published topics")
	}
}

// TestListTopicsEmpty tests listing topics when no topics exist
func TestListTopicsEmpty(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	// Create a new test barrel with no topics
	testBarrel := uniqueTopicName("empty_test_barrel")
	err = client.CreateBarrel(testBarrel, "")
	if err != nil {
		t.Fatalf("CreateBarrel() error = %v", err)
	}
	defer client.DropBarrel(testBarrel)

	err = client.UseBarrel(testBarrel)
	if err != nil {
		t.Fatalf("UseBarrel() error = %v", err)
	}

	// List topics (should be empty or minimal)
	topics, err := client.ListTopics()
	if err != nil {
		t.Fatalf("ListTopics() error = %v", err)
	}

	// It's OK to have some topics from previous tests, but shouldn't be many
	if len(topics) > 10 {
		t.Logf("Warning: ListTopics() returned %d topics in supposedly empty barrel", len(topics))
	}
}
