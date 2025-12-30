// Auto-generated from documentation example
package main

import (
    "fmt"
    "log"
)

func main() {
    // Recover from panics to show build success/failure cleanly
    defer func() {
        if r := recover(); r != nil {
            log.Printf("Panic during execution: %v", r)
        }
    }()

    // Code from documentation
    {CODE_SNIPPET}

    fmt.Println("Go build: OK")
}
