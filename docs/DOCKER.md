# Running BitBarrel with Docker

BitBarrel provides official Docker images for easy deployment. The Docker image bundles the BitBarrel server with the Flutter web admin interface in a single container.

## Quick Start

### Using Docker Compose (Recommended)

1. Start BitBarrel with default settings:

```bash
docker-compose up -d
```

2. Access the services:
   - BitBarrel Server: `ws://localhost:8080` (WebSocket) or `http://localhost:8080` (HTTP)
   - Web Admin: http://localhost:8081

3. View logs:

```bash
docker-compose logs -f
```

4. Stop BitBarrel:

```bash
docker-compose down
```

### Using Docker Run

```bash
docker run -d \
  --name bitbarrel \
  -p 8080:8080 \
  -p 8081:8081 \
  -v bitbarrel-data:/data \
  bitbarrel:latest
```

## Prerequisites

- Docker Engine 20.10 or newer
- Docker Compose 2.0 or newer (for compose method)

## Configuration

### Environment Variables

BitBarrel uses environment variables for configuration. All settings from the YAML config file can be set via environment variables using the pattern `BITBARREL_SECTION_SETTING`.

#### Server Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BITBARREL_SERVER_PORT` | 8080 | Server port |
| `BITBARREL_SERVER_ADDRESS` | 0.0.0.0 | Bind address |
| `BITBARREL_SERVER_MAX_CONNECTIONS` | 10000 | Maximum concurrent connections |
| `BITBARREL_SERVER_TIMEOUT` | 30000 | Connection timeout (ms) |

#### Storage Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BITBARREL_STORAGE_DATA_DIR` | /data | Data directory |
| `BITBARREL_STORAGE_MAX_FILE_SIZE` | 1073741824 | Max file size (1GB) |
| `BITBARREL_STORAGE_SYNC_MODE` | immediate | Sync mode: immediate, buffered, batched, time_based |
| `BITBARREL_STORAGE_FSYNC_INTERVAL` | 100 | Fsync interval for time_based mode (ms) |

#### Authentication

| Variable | Default | Description |
|----------|---------|-------------|
| `BITBARREL_AUTH_ENABLED` | false | Enable JWT authentication |
| `BITBARREL_AUTH_SECRET` | (none) | JWT secret (min 32 chars) |

> **Important**: When enabling authentication, always set a persistent secret. Generate one with:
> ```bash
> openssl rand -base64 32
> ```

#### Performance & Other Settings

See `docker-compose.yml` for all available configuration options with their defaults.

### Example: Running with Authentication

```bash
docker run -d \
  --name bitbarrel-secure \
  -p 8080:8080 \
  -p 8081:8081 \
  -v bitbarrel-data:/data \
  -e BITBARREL_AUTH_ENABLED=true \
  -e BITBARREL_AUTH_SECRET="your-32-char-secret-here" \
  bitbarrel:latest
```

### Example: Custom Port and Data Directory

```bash
docker run -d \
  --name bitbarrel-custom \
  -p 9090:9090 \
  -p 9091:8081 \
  -v /path/to/your/data:/data \
  -e BITBARREL_SERVER_PORT=9090 \
  -e BITBARREL_ADMIN_PORT=9091 \
  -e BITBARREL_STORAGE_DATA_DIR=/data \
  bitbarrel:latest
```

## Data Persistence

BitBarrel stores all data in the `/data` directory inside the container. Mount a volume to persist data between container restarts.

### Using Named Volume (Docker Compose default)

```yaml
volumes:
  - bitbarrel-data:/data
```

### Using Bind Mount

```yaml
volumes:
  - ./bitbarrel-data:/data
```

Or with docker run:

```bash
-v $(pwd)/data:/data
```

## Building from Source

### Prerequisites

- Docker
- Nim >= 2.2.6
- Nimble
- Flutter (optional, for web admin)

### Build Steps

1. Clone the repository:

```bash
git clone https://github.com/gokr/bitbarrel.git
cd bitbarrel
```

2. Build the Docker image:

```bash
# Using the build script
./build_docker.sh

# Or using Nimble
nimble dockerBuild
```

The build process:
- Compiles BitBarrel binary with Nim
- Builds Flutter web admin (if Flutter available)
- Creates multi-stage Docker image with Alpine Linux
- Runs smoke tests

### Build Options

```bash
# Skip smoke tests
./build_docker.sh --skip-test

# Build and publish to registry
./build_docker.sh --publish --registry your-registry.com

# Show help
./build_docker.sh --help
```

## Docker Compose Reference

### Basic Configuration

```yaml
version: '3.8'
services:
  bitbarrel:
    image: bitbarrel:latest
    ports:
      - "8080:8080"  # Server
      - "8081:8081"  # Web Admin
    volumes:
      - bitbarrel-data:/data
    environment:
      - BITBARREL_SERVER_PORT=8080
      - BITBARREL_STORAGE_DATA_DIR=/data
      - BITBARREL_AUTH_ENABLED=false
    restart: unless-stopped

volumes:
  bitbarrel-data:
```

### Production Configuration with Authentication

```yaml
version: '3.8'
services:
  bitbarrel:
    image: bitbarrel:latest
    ports:
      - "8080:8080"
      - "8081:8081"
    volumes:
      - bitbarrel-data:/data
    environment:
      - BITBARREL_SERVER_PORT=8080
      - BITBARREL_STORAGE_DATA_DIR=/data
      - BITBARREL_AUTH_ENABLED=true
      - BITBARREL_AUTH_SECRET=${BITBARREL_AUTH_SECRET}  # Set in .env file
      - BITBARREL_LOGGING_LEVEL=info
      - BITBARREL_SERVER_MAX_CONNECTIONS=10000
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8080"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  bitbarrel-data:
    driver: local
```

Create a `.env` file for secrets:

```bash
BITBARREL_AUTH_SECRET=your-secure-jwt-secret-here
```

### Swarm Deployment

For Docker Swarm, use secrets:

```yaml
version: '3.8'
secrets:
  bitbarrel_secret:
    external: true

services:
  bitbarrel:
    image: bitbarrel:latest
    secrets:
      - bitbarrel_secret
    environment:
      - BITBARREL_AUTH_ENABLED=true
      - BITBARREL_AUTH_SECRET_FILE=/run/secrets/bitbarrel_secret
```

## Networking

### Port Mapping

- **8080**: BitBarrel WebSocket/HTTP server
- **8081**: Flutter web admin interface

### Client Connections

Connect to BitBarrel using:
- WebSocket: `ws://localhost:8080` (or your domain)
- HTTP: `http://localhost:8080` (for non-streaming operations)

### Web Admin

Access the web admin at: `http://localhost:8081`

The web admin automatically connects to the BitBarrel server at the same hostname.

## Monitoring and Logging

### View Logs

```bash
# Using Docker Compose
docker-compose logs -f

# Using Docker
docker logs -f bitbarrel

# Show only errors
docker logs bitbarrel 2>&1 | grep -i error
```

### Log Configuration

Set log level and format via environment variables:

```yaml
environment:
  - BITBARREL_LOGGING_LEVEL=info  # debug, info, warn, error
  - BITBARREL_LOGGING_FORMAT=text  # text or json
```

### Health Checks

The Docker image includes a health check that verifies the server is responding. Health status can be viewed with:

```bash
docker ps
docker inspect --format='{{json .State.Health}}' bitbarrel
```

## Security Best Practices

### 1. Use Non-Root User

The official BitBarrel image runs as a non-root user (UID 1000) by default.

### 2. Enable Authentication in Production

Always enable JWT authentication in production:

```bash
# Generate a secure secret
openssl rand -base64 32

# Use environment variable
-e BITBARREL_AUTH_SECRET="your-secure-secret-here"
```

### 3. Use Secrets Management

For production deployments, use Docker secrets or external secrets management:

```bash
# Docker secret
echo "your-secret" | docker secret create bitbarrel_jwt -
```

### 4. Network Security

- Don't expose BitBarrel directly to the internet
- Use a reverse proxy (nginx, haproxy) with TLS
- Consider Docker networks for service-to-service communication

### 5. Resource Limits

Set resource limits to prevent container from consuming all host resources:

```yaml
deploy:
  resources:
    limits:
      cpus: '2'
      memory: 4G
    reservations:
      cpus: '0.5'
      memory: 512M
```

## Troubleshooting

### Container Won't Start

Check logs:
```bash
docker logs bitbarrel
```

Common issues:
- Port conflict: Ensure ports 8080 and 8081 are available
- Permission issues: Check volume mount permissions

### Can't Connect to Server

Verify server is running:
```bash
curl -v http://localhost:8080
```

Check container status:
```bash
docker ps
docker inspect bitbarrel
```

### Data Not Persisting

Ensure volume is properly mounted:
```bash
docker inspect bitbarrel | grep -A 10 Mounts
```

Check directory permissions:
```bash
docker exec bitbarrel ls -la /data
```

### Web Admin Not Accessible

If web admin build was skipped during Docker build:
1. Ensure Flutter is installed on host
2. Rebuild with: `./build_docker.sh`

### Memory Issues

If experiencing memory issues:
- Increase cache size: `BITBARREL_PERFORMANCE_CACHE_SIZE=512`
- Reduce worker threads: `BITBARREL_PERFORMANCE_WORKER_THREADS=2`
- Set container memory limit (see Resource Limits above)

## Upgrading

### Using Docker Compose

```bash
# Pull latest image
docker-compose pull

# Restart with new image
docker-compose up -d

# Cleanup old images
docker image prune
```

### Using Docker Run

```bash
# Stop and remove old container
docker stop bitbarrel
docker rm bitbarrel

# Pull latest image
docker pull bitbarrel:latest

# Run new container
docker run -d ... bitbarrel:latest
```

## Support

For issues and feature requests, visit:
- GitHub Issues: https://github.com/gokr/bitbarrel/issues
- Documentation: https://github.com/gokr/bitbarrel/tree/main/docs
