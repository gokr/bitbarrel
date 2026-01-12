package main

import (
	"fmt"
	"log"

	"github.com/yourusername/bitbarrel-go"
)

func main() {
	client := bitbarrel.NewClient("localhost", 9876)

	if err := client.Connect(); err != nil {
		log.Fatal("Failed to connect: ", err)
	}
	defer client.Close()

	log.Println("Connected to BitBarrel server")

	// Create multiple barrels
	barrels := []string{"users", "products", "orders", "cache", "sessions"}

	for _, barrel := range barrels {
		if err := client.CreateBarrel(barrel, ""); err != nil {
			if err == bitbarrel.ErrBarrelExists {
				log.Printf("Barrel '%s' already exists\n", barrel)
			} else {
				log.Printf("Failed to create barrel '%s': %v\n", barrel, err)
			}
		} else {
			log.Printf("Created barrel: %s\n", barrel)
		}
	}

	// List all barrels
	allBarrels, err := client.ListBarrels()
	if err != nil {
		log.Fatal("Failed to list barrels: ", err)
	}
	log.Printf("All barrels: %v\n", allBarrels)

	// Use users barrel and add data
	if err := client.UseBarrel("users"); err != nil {
		log.Fatal("Failed to use users barrel: ", err)
	}
	log.Println("Using users barrel")

	users := map[string]string{
		"user:alice":   `{"name":"Alice","email":"alice@example.com","role":"admin"}`,
		"user:bob":     `{"name":"Bob","email":"bob@example.com","role":"user"}`,
		"user:charlie": `{"name":"Charlie","email":"charlie@example.com","role":"user"}`,
	}

	for key, data := range users {
		if err := client.Set(key, data); err != nil {
			log.Printf("Failed to add user %s: %v\n", key, err)
			continue
		}
		log.Printf("Added user: %s\n", key)
	}

	// Switch to products barrel
	if err := client.UseBarrel("products"); err != nil {
		log.Fatal("Failed to use products barrel: ", err)
	}
	log.Println("Using products barrel")

	products := map[string]string{
		"product:laptop":  `{"name":"Laptop","price":999.99,"stock":50}`,
		"product:mouse":   `{"name":"Mouse","price":29.99,"stock":200}`,
		"product:keyboard": `{"name":"Keyboard","price":79.99,"stock":100}`,
	}

	for key, data := range products {
		if err := client.Set(key, data); err != nil {
			log.Printf("Failed to add product %s: %v\n", key, err)
			continue
		}
		log.Printf("Added product: %s\n", key)
	}

	// Switch back to users and retrieve data
	if err := client.UseBarrel("users"); err != nil {
		log.Fatal("Failed to use users barrel: ", err)
	}

	alice, err := client.Get("user:alice")
	if err != nil {
		log.Fatal("Failed to get user:alice: ", err)
	}
	log.Printf("Alice's data: %s\n", alice)

	// Create another barrel for logs
	if err := client.CreateBarrel("logs", ""); err != nil && err != bitbarrel.ErrBarrelExists {
		log.Fatal("Failed to create logs barrel: ", err)
	}
	log.Println("Created logs barrel")

	// Use logs barrel
	if err := client.UseBarrel("logs"); err != nil {
		log.Fatal("Failed to use logs barrel: ", err)
	}

	// Add log entries
	for i := 1; i <= 5; i++ {
		key := fmt.Sprintf("log:%03d", i)
		value := fmt.Sprintf(`{"timestamp":"2023-01-0%dT10:00:00Z","level":"info","message":"Log entry %d"}`, i, i)
		if err := client.Set(key, value); err != nil {
			log.Printf("Failed to add log entry: %v\n", err)
			continue
		}
		log.Printf("Added log entry: %s\n", key)
	}

	// Try to access data from wrong barrel (should fail)
	if err := client.UseBarrel("orders"); err != nil {
		log.Fatal("Failed to use orders barrel: ", err)
	}

	// This should return error as the key is in users barrel
	_, err = client.Get("user:alice")
	if err == bitbarrel.ErrNotFound {
		log.Println("Correctly found no data in orders barrel (data is in users)")
	} else if err != nil {
		log.Printf("Unexpected error: %v\n", err)
	}

	// Drop a barrel
	if err := client.DropBarrel("cache"); err != nil {
		log.Printf("Failed to drop cache barrel: %v\n", err)
	} else {
		log.Println("Dropped cache barrel")
	}

	// Verify it's gone
	allBarrels, err = client.ListBarrels()
	if err != nil {
		log.Fatal("Failed to list barrels: ", err)
	}
	log.Printf("Remaining barrels: %v\n", allBarrels)

	log.Println("\n=== Barrel management completed successfully ===")
}
