package bitbarrel

import (
	"testing"
	"time"
)

// TestGetHistory tests retrieving message history for a topic
func TestGetHistory(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	topic := uniqueTopicName("test:history")

	// Publish some messages
	seq1, err := client.PublishData(topic, "message 1")
	if err != nil {
		t.Fatalf("PublishData() error = %v", err)
	}
	time.Sleep(10 * time.Millisecond)

	seq2, err := client.PublishData(topic, "message 2")
	if err != nil {
		t.Fatalf("PublishData() error = %v", err)
	}
	time.Sleep(10 * time.Millisecond)

	seq3, err := client.PublishData(topic, "message 3")
	if err != nil {
		t.Fatalf("PublishData() error = %v", err)
	}
	time.Sleep(100 * time.Millisecond) // Wait for history to be stored

	// Get history
	history, err := client.GetHistory(topic, DefaultHistoryRequest())
	if err != nil {
		t.Fatalf("GetHistory() error = %v", err)
	}

	if len(history) < 3 {
		t.Errorf("GetHistory() returned %d messages, want >= 3", len(history))
	}

	// Verify messages (should be in order received)
	expectedPayloads := []string{"message 1", "message 2", "message 3"}
	for i, event := range history {
		if i < len(expectedPayloads) && event.Payload != expectedPayloads[i] {
			t.Errorf("History[%d].Payload = %q, want %q", i, event.Payload, expectedPayloads[i])
		}
		if event.Topic != topic {
			t.Errorf("History[%d].Topic = %q, want %q", i, event.Topic, topic)
		}
		if event.MessageType != MessageTypeData {
			t.Errorf("History[%d].MessageType = %v, want %v", i, event.MessageType, MessageTypeData)
		}
	}

	// Verify sequence numbers
	actualSeq := []uint64{history[0].Sequence, history[1].Sequence, history[2].Sequence}
	expectedSeq := []uint64{seq1, seq2, seq3}
	for i := range actualSeq {
		if actualSeq[i] != expectedSeq[i] {
			t.Errorf("History[%d].Sequence = %d, want %d", i, actualSeq[i], expectedSeq[i])
		}
	}
}

// TestGetHistoryWithLimit tests retrieving limited message history
func TestGetHistoryWithLimit(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	topic := uniqueTopicName("test:history_limit")

	// Publish 5 messages
	for i := 1; i <= 5; i++ {
		_, err := client.PublishData(topic, "message " + string(rune(i+48)))
		if err != nil {
			t.Fatalf("PublishData() error = %v", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond)

	// Get only 2 messages
	history, err := client.GetHistory(topic, HistoryRequest{Limit: 2})
	if err != nil {
		t.Fatalf("GetHistory() error = %v", err)
	}

	if len(history) > 2 {
		t.Errorf("GetHistory() with limit=2 returned %d messages, want <= 2", len(history))
	}

	if len(history) < 2 {
		t.Logf("Warning: GetHistory() returned only %d messages, expected at least 2", len(history))
	}
}

// TestGetHistoryWithSinceSeq tests retrieving history since a sequence number
func TestGetHistoryWithSinceSeq(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	topic := uniqueTopicName("test:history_since")

	// Publish 5 messages and record sequence numbers
	var seqNumbers []uint64
	for i := 1; i <= 5; i++ {
		seq, err := client.PublishData(topic, "message " + string(rune(i+48)))
		if err != nil {
			t.Fatalf("PublishData() error = %v", err)
		}
		seqNumbers = append(seqNumbers, seq)
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond)

	// Get messages since the 3rd message (index 2)
	sinceSeq := seqNumbers[2]
	history, err := client.GetHistory(topic, HistoryRequest{Limit: 10, SinceSeq: sinceSeq})
	if err != nil {
		t.Fatalf("GetHistory() error = %v", err)
	}

	// Should get messages 3, 4, 5 (at least 3 messages)
	if len(history) < 3 {
		t.Errorf("GetHistory(sinceSeq=%d) returned %d messages, want >= 3", sinceSeq, len(history))
	}

	// Verify all messages have sequence >= sinceSeq
	for _, event := range history {
		if event.Sequence < sinceSeq {
			t.Errorf("History event has sequence %d < sinceSeq %d", event.Sequence, sinceSeq)
		}
	}
}

// TestGetHistoryEmptyTopic tests retrieving history for topic with no messages
func TestGetHistoryEmptyTopic(t *testing.T) {
	skipIfNoServer(t)

	client := NewClient(testServerHost, testServerPort)
	defer client.Close()

	err := client.Connect()
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	topic := uniqueTopicName("test:history_empty")

	// Don't publish any messages, just get history
	history, err := client.GetHistory(topic, DefaultHistoryRequest())
	if err != nil {
		t.Fatalf("GetHistory() error = %v", err)
	}

	if len(history) != 0 {
		t.Errorf("GetHistory() for empty topic returned %d messages, want 0", len(history))
	}
}
