package main

import (
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/yourusername/bitbarrel-go"
)

func worker(id int, wg *sync.WaitGroup, errors *int) {
	defer wg.Done()

	// Each worker creates its own client
	client := bitbarrel.NewClient("localhost", 9876)
	if err := client.Connect(); err != nil {
		log.Printf("Worker %d: Failed to connect: %v\n", id, err)
		*errors++
		return
	}
	defer client.Close()

	// Use the test barrel
	if err := client.UseBarrel("concurrent_test"); err != nil {
		log.Printf("Worker %d: Failed to use barrel: %v\n", id, err)
		*errors++
		return
	}

	// Perform operations
	for i := 0; i < 100; i++ {
		key := fmt.Sprintf("worker%d:key%d", id, i)
		value := fmt.Sprintf("value_%d_%d", id, i)

		// Set the value
		if err := client.Set(key, value); err != nil {
			log.Printf("Worker %d: Failed to set %s: %v\n", id, key, err)
			*errors++
			continue
		}

		// Get the value back
		retrieved, err := client.Get(key)
		if err != nil {
			log.Printf("Worker %d: Failed to get %s: %v\n", id, key, err)
			*errors++
			continue
		}

		// Verify the value
		if retrieved != value {
			log.Printf("Worker %d: Value mismatch for %s: expected %s, got %s\n",
				id, key, value, retrieved)
			*errors++
		}

		// Delete the key
		if err := client.Delete(key); err != nil {
			log.Printf("Worker %d: Failed to delete %s: %v\n", id, key, err)
			*errors++
		}
	}

	log.Printf("Worker %d: Completed successfully\n", id)
}

func readerWorker(id int, wg *sync.WaitGroup, keys []string, errors *int) {
	defer wg.Done()

	client := bitbarrel.NewClient("localhost", 9876)
	if err := client.Connect(); err != nil {
		log.Printf("Reader %d: Failed to connect: %v\n", id, err)
		*errors++
		return
	}
	defer client.Close()

	if err := client.UseBarrel("concurrent_test"); err != nil {
		log.Printf("Reader %d: Failed to use barrel: %v\n", id, err)
		*errors++
		return
	}

	// Read existing keys
	for _, key := range keys {
		_, err := client.Get(key)
		if err != nil && err != bitbarrel.ErrNotFound {
			log.Printf("Reader %d: Error reading %s: %v\n", id, key, err)
			*errors++
		}
	}

	log.Printf("Reader %d: Completed reading %d keys\n", id, len(keys))
}

func main() {
	// Setup: Create barrel and pre-populate some data
	setupClient := bitbarrel.NewClient("localhost", 9876)
	if err := setupClient.Connect(); err != nil {
		log.Fatal("Failed to connect for setup: ", err)
	}
	defer setupClient.Close()

	if err := setupClient.CreateBarrel("concurrent_test", ""); err != nil && err != bitbarrel.ErrBarrelExists {
		log.Fatal("Failed to create test barrel: ", err)
	}

	if err := setupClient.UseBarrel("concurrent_test"); err != nil {
		log.Fatal("Failed to use test barrel: ", err)
	}

	// Pre-populate some shared data
	log.Println("Pre-populating test data...")
	for i := 0; i < 100; i++ {
		key := fmt.Sprintf("shared:key%d", i)
		value := fmt.Sprintf("shared_value_%d", i)
		if err := setupClient.Set(key, value); err != nil {
			log.Printf("Failed to pre-populate %s: %v\n", key, err)
		}
	}

	log.Println("Starting concurrent workers...")

	startTime := time.Now()

	var wg sync.WaitGroup
	errors := 0
	errorMutex := sync.Mutex{}

	// Launch writer workers
	numWriters := 5
	wg.Add(numWriters)
	for i := 1; i <= numWriters; i++ {
		go worker(i, &wg, &errors)
	}

	// Launch reader workers
	numReaders := 3
	wg.Add(numReaders)

	// Prepare key list for readers
	sharedKeys := make([]string, 100)
	for i := 0; i < 100; i++ {
		sharedKeys[i] = fmt.Sprintf("shared:key%d", i)
	}

	for i := 1; i <= numReaders; i++ {
		go readerWorker(i, &wg, sharedKeys, &errors)
	}

	// Wait for all workers to complete
	wg.Wait()

	duration := time.Since(startTime)

	// Verify results
	log.Println("\nVerifying results...")

	verifyClient := bitbarrel.NewClient("localhost", 9876)
	if err := verifyClient.Connect(); err != nil {
		log.Fatal("Failed to connect for verification: ", err)
	}
	defer verifyClient.Close()

	if err := verifyClient.UseBarrel("concurrent_test"); err != nil {
		log.Fatal("Failed to use test barrel for verification: ", err)
	}

	count, err := verifyClient.Count()
	if err != nil {
		log.Fatal("Failed to count: ", err)
	}

	// Should only have the pre-populated shared keys
	expectedCount := 100
	if count != expectedCount {
		log.Printf("WARNING: Expected %d keys, but found %d\n", expectedCount, count)
	}

	log.Printf("Total keys: %d\n", count)
	log.Printf("Total errors: %d\n", errors)
	log.Printf("Total duration: %v\n", duration)
	log.Printf("Total operations: %d\n", (numWriters*100*3)+(numReaders*100))

	if errors == 0 {
		log.Println("\n=== Concurrent test completed successfully ===")
	} else {
		log.Printf("\n=== Concurrent test completed with %d errors ===\n", errors)
	}
}
