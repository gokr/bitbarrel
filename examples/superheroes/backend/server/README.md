# BitBarrel Server - Setup

## Starting the BitBarrel Server

From the bitbarrel project root:

```bash
nimble build
./bitbarrel -p=9876 serve
```

## Server Configuration

### Command Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `-p=PORT` | Port number | 9876 |
| `-h=HOST` | Host to bind to | 0.0.0.0 |
| `-d=DIR` | Data directory | ./barrels |

### Example Commands

```bash
# Default port (9876)
./bitbarrel serve

# Custom port
./bitbarrel -p=3000 serve

# Custom data directory
./bitbarrel -d=/path/to/data serve

# All options
./bitbarrel -p=9876 -h=localhost -d=./barrels serve
```

## Verification

Once the server is running, you can verify it's working by opening:

- HTTP: http://localhost:9876
- WebSocket: `ws://localhost:9876/ws` (used by TypeScript client)

## Stopping the Server

Press `Ctrl+C` in the terminal where the server is running.

## Data Storage

Barrel data is stored in the data directory (default: `./barrels/`). Each barrel gets its own subdirectory.

For this example, the superheroes data is stored in:
```
./barrels/superheroes/
```
