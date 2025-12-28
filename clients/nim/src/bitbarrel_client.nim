## BitBarrel Client Library for Nim
##
## A WebSocket client for connecting to BitBarrel key-value store servers.
##
## **Installation:**
## ```bash
## nimble install bitbarrel_client
## ```
##
## **Quick Start:**
## ```nim
## import bitbarrel_client
##
## var client = newClient("localhost", 9876.Port)
## client.connect()
##
## # Create and use a barrel
## discard client.createBarrel("mydb")
## discard client.useBarrel("mydb")
##
## # Store and retrieve data
## discard client.set("key", "value")
## echo client.get("key")  # "value"
##
## client.close()
## ```
##
## **Features:**
## - Binary protocol over WebSocket for efficient communication
## - Barrel management (create, open, use, close, drop)
## - Key-value operations (get, set, delete, exists)
## - Range queries and prefix searches (requires bmCritBit mode)
## - Reference traversal for graph-like data
##
## **Keeping Protocol in Sync:**
## The protocol.nim file is shared with the server. To update it:
## ```bash
## nimble syncProtocol
## ```

import bitbarrel_client/client
import bitbarrel_client/protocol

export client
export protocol
