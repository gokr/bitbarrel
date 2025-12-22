package main

import (
	"log"

	"github.com/yourusername/bitbarrel-go"
)

func main() {
	// Create a new client
	client := bitbarrel.NewClient("localhost", 9876)

	// Connect to the server
	if err := client.Connect(); err != nil {
		log.Fatal("Failed to connect: ", err)
	}
	defer client.Close()

	log.Println("Connected to BitBarrel server")

	// Create a barrel
	if err := client.CreateBarrel("mydb", ""); err != nil {
		log.Fatal("Failed to create barrel: ", err)
	}
	log.Println("Created barrel: mydb")

	// Use the barrel
	if err := client.UseBarrel("mydb"); err != nil {
		log.Fatal("Failed to use barrel: ", err)
	}
	log.Println("Using barrel: mydb")

	// Store some data
	if err := client.Set("greeting", "Hello, BitBarrel!"); err != nil {
		log.Fatal("Failed to set: ", err)
	}
	log.Println("Stored: greeting = Hello, BitBarrel!")

	// Retrieve data
	value, err := client.Get("greeting")
	if err != nil {
		log.Fatal("Failed to get: ", err)
	}
	log.Printf("Retrieved: greeting = %s\n", value)

	// Check if key exists
	exists, err := client.Exists("greeting")
	if err != nil {
		log.Fatal("Failed to check existence: ", err)
	}
	log.Printf("Key 'greeting' exists: %v\n", exists)

	// Delete the key
	if err := client.Delete("greeting"); err != nil {
		log.Fatal("Failed to delete: ", err)
	}
	log.Println("Deleted key: greeting")

	// Verify deletion
	_, err = client.Get("greeting")
	if err == bitbarrel.ErrNotFound {
		log.Println("Confirmed: key 'greeting' no longer exists")
	} else if err != nil {
		log.Fatal("Unexpected error: ", err)
	}

	// Store multiple items
	items := map[string]string{
		"user:1":   `{"name":"Alice","age":30}`,
		"user:2":   `{"name":"Bob","age":25}`,
		"user:3":   `{"name":"Charlie","age":35}`,
		"product:1": "Laptop",
		"product:2": "Mouse",
		"product:3": "Keyboard",
	}

	for key, value := range items {
		if err := client.Set(key, value); err != nil {
			log.Printf("Failed to set %s: %v\n", key, err)
			continue
		}
		log.Printf("Stored: %s = %s\n", key, value)
	}

	// Count keys
	count, err := client.Count()
	if err != nil {
		log.Fatal("Failed to count: ", err)
	}
	log.Printf("Total keys in barrel: %d\n", count)

	// List all keys
	keys, err := client.ListKeys()
	if err != nil {
		log.Fatal("Failed to list keys: ", err)
	}
	log.Printf("All keys: %v\n", keys)

	log.Println("\n=== Basic operations completed successfully ===")
}
