// Pub/Sub Chat History Example for Go
//
// Demonstrates building a chat room with message history:
// - Publishing messages to different rooms
// - Retrieving historical messages
// - Pattern subscriptions across multiple rooms
// - Querying subscribers and presence information
//
// Prerequisites:
// - BitBarrel server with pub/sub enabled
// - History storage configured (memory or persistent)
//
// Run: go run examples/pubsub/main.go

package main

import (
	"fmt"
	"log"
	"time"

	"github.com/yourusername/bitbarrel-go"
)

func main() {
	fmt.Println("BitBarrel Pub/Sub Chat History Example (Go)")
	fmt.Println("===========================================")
	fmt.Println()

	// 1. Connect to server
	fmt.Println("1. Connecting to BitBarrel server...")
	client := bitbarrel.NewClient("localhost", 1337)
	defer client.Close()

	if err := client.Connect(); err != nil {
		log.Fatalf("Failed to connect: %v", err)
	}

	// 2. Ensure chat room barrel exists (for persistent storage)
	fmt.Println("2. Setting up chat storage...")
	if err := client.CreateBarrel("chat_storage", ""); err != nil {
		fmt.Println("   Using existing chat storage barrel")
	}

	// 3. Subscribe to a chat room
	fmt.Println()
	fmt.Println("3. Subscribing to 'room:general'...")
	opts := bitbarrel.SubscriptionOptions{
		EnableKvEvents: false,
		EnablePresence: true, // Enable presence notifications
	}

	subId, err := client.Subscribe("room:general", opts)
	if err != nil {
		log.Fatalf("Failed to subscribe: %v", err)
	}
	fmt.Printf("   ✓ Subscribed with ID: %s\n", subId)

	// 4. Publish some chat messages
	fmt.Println()
	fmt.Println("4. Publishing chat messages...")
	usernames := []string{"Alice", "Bob", "Charlie", "Dave", "Eve"}
	messages := []string{
		"Hello everyone!",
		"Hi there! How are you?",
		"Doing great! Just testing BitBarrel pub/sub",
		"This is really cool!",
		"History replay works perfectly!",
	}

	for i := 0; i < len(usernames); i++ {
		username := usernames[i]
		message := messages[i]

		seq, err := client.PublishData("room:general", fmt.Sprintf("[%s] %s", username, message))
		if err != nil {
			log.Printf("Failed to publish: %v", err)
		} else {
			fmt.Printf("   Sent: %s: %s (seq: %d)\n", username, message, seq)
		}
		time.Sleep(200 * time.Millisecond) // Small delay between messages
	}

	// Wait for messages to be stored
	time.Sleep(1 * time.Second)

	// 5. Retrieve message history
	fmt.Println()
	fmt.Println("5. Retrieving message history...")
	req := bitbarrel.DefaultHistoryRequest()
	req.Limit = 10

	history, err := client.GetHistory("room:general", req)
	if err != nil {
		if isNotSupported(err) || isNotEnabled(err) {
			fmt.Println("   ⚠ History not enabled on server")
			fmt.Println("     Run with history storage to see this feature")
		} else {
			log.Printf("Failed to get history: %v", err)
		}
	} else {
		fmt.Printf("   ✓ Found %d historical messages:\n", len(history))
		fmt.Println()
		for _, msg := range history {
			timestamp := time.Unix(msg.Timestamp, 0)
			timeStr := timestamp.Format("01/02 15:04:05")
			fmt.Printf("     [%2d | %s] %s\n", msg.Sequence, timeStr, msg.Payload)
		}
	}

	// 6. Demonstrate pattern subscription across multiple rooms
	fmt.Println()
	fmt.Println("6. Subscribing to ALL rooms with pattern 'room:*'...")
	patternSubId, err := client.Subscribe("room:*", opts)
	if err != nil {
		log.Printf("Failed to subscribe to pattern: %v", err)
	} else {
		fmt.Printf("   ✓ Pattern subscription ID: %s\n", patternSubId)
		fmt.Println("   Now listening to all chat rooms simultaneously")
	}

	// 7. Publish to different rooms
	fmt.Println()
	fmt.Println("7. Publishing to multiple rooms...")
	if _, err := client.PublishData("room:tech", "Dave: Tech discussion: BitBarrel is awesome!"); err != nil {
		log.Printf("Failed to publish: %v", err)
	} else {
		fmt.Println("   → Posted in room:tech")
	}

	if _, err := client.PublishData("room:random", "Eve: Random chat: Anyone up for coffee?"); err != nil {
		log.Printf("Failed to publish: %v", err)
	} else {
		fmt.Println("   → Posted in room:random")
	}

	if _, err := client.PublishData("room:general", "Frank: General: Hello from all rooms!"); err != nil {
		log.Printf("Failed to publish: %v", err)
	} else {
		fmt.Println("   → Posted in room:general")
	}

	time.Sleep(1 * time.Second) // Wait for messages to be stored

	// 8. Query subscribers in the general room
	fmt.Println()
	fmt.Println("8. Querying subscribers in 'room:general'...")
	subscribers, err := client.ListSubscribers("room:general")
	if err != nil {
		if isNotSupported(err) {
			fmt.Println("   ⚠ Query methods not fully implemented in this client")
		} else {
			log.Printf("Failed to list subscribers: %v", err)
		}
	} else {
		fmt.Printf("   ✓ Found %d subscriber(s):\n", len(subscribers))
		for _, sub := range subscribers {
			fmt.Printf("     - ID: %s | Pattern: %s\n", sub.ID, sub.Pattern)
		}
	}

	// 9. Check presence information
	fmt.Println()
	fmt.Println("9. Checking presence for 'room:general'...")
	presence, err := client.GetPresence("room:general")
	if err != nil {
		if isNotSupported(err) {
			fmt.Println("   ⚠ Presence not fully implemented")
		} else {
			log.Printf("Failed to get presence: %v", err)
		}
	} else {
		fmt.Printf("   ✓ Presence info: %s\n", presence)
	}

	// 10. Demonstrate history filtering with sinceSeq
	fmt.Println()
	fmt.Println("10. Demonstrating history filtering (messages since seq #3)...")
	recentReq := bitbarrel.HistoryRequest{
		Limit:    100,
		SinceSeq: 3,
	}

	recentHistory, err := client.GetHistory("room:general", recentReq)
	if err != nil {
		if isNotSupported(err) || isNotEnabled(err) {
			fmt.Println("   ⚠ History filtering not available")
		} else {
			log.Printf("Failed to get filtered history: %v", err)
		}
	} else {
		fmt.Printf("   ✓ Found %d messages since sequence #3\n", len(recentHistory))
		for _, msg := range recentHistory {
			fmt.Printf("     - Seq %d: %s\n", msg.Sequence, msg.Payload)
		}
	}

	// 11. Subscribe to more rooms and show history per room
	fmt.Println()
	fmt.Println("11. Checking history in all rooms...")
	rooms := []string{"room:general", "room:tech", "room:random"}
	for _, room := range rooms {
		fmt.Printf("   History for %s:\n", room)
		req := bitbarrel.DefaultHistoryRequest()
		req.Limit = 3

		if roomHistory, err := client.GetHistory(room, req); err == nil && len(roomHistory) > 0 {
			for _, msg := range roomHistory {
				fmt.Printf("     - Seq %d: %s\n", msg.Sequence, msg.Payload)
			}
		} else {
			fmt.Printf("     (no messages or error: %v)\n", err)
		}
	}

	// 12. Clean up
	fmt.Println()
	fmt.Println("12. Cleaning up...")
	client.Unsubscribe(subId)
	client.Unsubscribe(patternSubId)
	fmt.Println("   ✓ Unsubscribed from all topics")

	fmt.Println()
	fmt.Println("👋 Example completed successfully!")
	fmt.Println()
	fmt.Println("NOTE: This example demonstrated publishing and history retrieval.")
	fmt.Println("The Go client currently focuses on these features.")
}

// Helper function to check if an error indicates a feature is not supported
func isNotSupported(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return contains(msg, "not supported") || contains(msg, "not implemented")
}

// Helper function to check if an error indicates a feature is not enabled
func isNotEnabled(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return contains(msg, "not enabled") || contains(msg, "disabled")
}

// Helper function to check if string contains substring
func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > len(substr) && (s[:len(substr)] == substr || contains(s[1:], substr)))
}
