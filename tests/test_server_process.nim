## Test Server Process - Runs standalone for test_client

import os, std/net
import ../src/network/server

# Get data directory from command line
if paramCount() < 1:
  echo "Usage: test_server_process <data_directory>"
  quit(1)

let dataDir = paramStr(1)

# Create server
let config = ServerConfig(
  address: "127.0.0.1",
  port: Port(8081),
  dataDir: dataDir,
  workerThreads: 2
)

var s = newServer(config)

# Start server
s.start()
