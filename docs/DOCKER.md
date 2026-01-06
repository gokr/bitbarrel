# Running BitBarrel with Docker

BitBarrel provides official Docker images for easy deployment. The Docker image bundles the BitBarrel server with the Flutter web admin interface in a single container.

Images are published to GitHub Container Registry (ghcr.io) and updated automatically on each release.

## Quick Start

### Using Docker Compose

1. Start BitBarrel with default settings:

```bash
docker-compose up -d
```

2. Access the services:
   - BitBarrel Server: `ws://localhost:8080` (WebSocket) or `http://localhost:8080` (HTTP)
   - Web Admin: http://localhost:8080/admin/

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
  -v bitbarrel-data:/data \
  ghcr.io/gokr/bitbarrel:latest
```

## Prerequisites

- Docker Engine 20.10 or newer
- Docker Compose 2.0 or newer (for compose method)

## Building the Docker Image

The Docker image copies pre-built artifacts. First, build the bitbarrel binary and webadmin:

```bash
# Build bitbarrel
nimble build

# Build webadmin (requires Flutter)
cd webadmin && flutter build web --release

# Build Docker image
docker build -t bitbarrel:latest .
```

## Configuration

### Environment Variables

BitBarrel uses environment variables for configuration.

#### Server Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BITBARREL_SERVER_PORT` | 8080 | Server port |
| `BITBARREL_SERVER_ADDRESS` | 0.0.0.0 | Bind address |

#### WebAdmin Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BITBARREL_WEB_ADMIN_PATH` | /opt/bitbarrel/webadmin | Path to webadmin build files |
| `BITBARREL_WEB_ADMIN_ENABLED` | false | Enable webadmin UI |

#### Storage Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `BITBARREL_STORAGE_DATA_DIR` | /data | Data directory |

#### Authentication

| Variable | Default | Description |
|----------|---------|-------------|
| `BITBARREL_AUTH_ENABLED` | false | Enable JWT authentication |
| `BITBARREL_AUTH_SECRET` | (none) | JWT secret (min 32 chars) |

> **Important**: When enabling authentication, always set a persistent secret. Generate one with:
> ```bash
> openssl rand -base64 32
> ```

### Example: Running with Authentication

```bash
docker run -d \
  --name bitbarrel-secure \
  -p 8080:8080 \
  -v bitbarrel-data:/data \
  -e BITBARREL_AUTH_ENABLED=true \
  -e BITBARREL_AUTH_SECRET="your-32-char-secret-here" \
  ghcr.io/gokr/bitbarrel:latest
```

### Example: Custom Port

```bash
docker run -d \
  --name bitbarrel-custom \
  -p 9090:8080 \
  -v bitbarrel-data:/data \
  -e BITBARREL_SERVER_PORT=8080 \
  ghcr.io/gokr/bitbarrel:latest
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

## Docker Compose Reference

### Basic Configuration

```yaml
version: '3.8'
services:
  bitbarrel:
    image: ghcr.io/gokr/bitbarrel:latest
    ports:
      - "8080:8080"
    volumes:
      - bitbarrel-data:/data
    environment:
      - BITBARREL_SERVER_PORT=8080
      - BITBARREL_STORAGE_DATA_DIR=/data
    restart: unless-stopped

volumes:
  bitbarrel-data:
```

### Production Configuration with Authentication

```yaml
version: '3.8'
services:
  bitbarrel:
    image: ghcr.io/gokr/bitbarrel:latest
    ports:
      - "8080:8080"
    volumes:
      - bitbarrel-data:/data
    environment:
      - BITBARREL_SERVER_PORT=8080
      - BITBARREL_STORAGE_DATA_DIR=/data
      - BITBARREL_AUTH_ENABLED=true
      - BITBARREL_AUTH_SECRET=${BITBARREL_AUTH_SECRET}
      - BITBARREL_LOGGING_LEVEL=info
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8080/status"]
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
    image: ghcr.io/gokr/bitbarrel:latest
    secrets:
      - bitbarrel_secret
    environment:
      - BITBARREL_AUTH_ENABLED=true
      - BITBARREL_AUTH_SECRET_FILE=/run/secrets/bitbarrel_secret
```

## Networking

### Port Mapping

- **8080**: BitBarrel WebSocket/HTTP server and web admin UI

### Client Connections

Connect to BitBarrel using:
- WebSocket: `ws://localhost:8080` (or your domain)
- HTTP: `http://localhost:8080` (for REST API)

### Web Admin

Access the web admin at: `http://localhost:8080/admin/`

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

Set log level via environment variable:

```yaml
environment:
  - BITBARREL_LOGGING_LEVEL=info  # debug, info, warn, error
```

### Health Checks

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
- Port conflict: Ensure port 8080 is available
- Permission issues: Check volume mount permissions

### Can't Connect to Server

Verify server is running:
```bash
curl -v http://localhost:8080/status
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
2. Rebuild webadmin: `cd webadmin && flutter build web --release`
3. Rebuild Docker image: `docker build -t bitbarrel:latest .`

### Memory Issues

If experiencing memory issues:
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
docker pull ghcr.io/gokr/bitbarrel:latest

# Run new container
docker run -d ... ghcr.io/gokr/bitbarrel:latest
```

## Support

For issues and feature requests, visit:
- GitHub Issues: https://github.com/gokr/bitbarrel/issues
- Documentation: https://github.com/gokr/bitbarrel/tree/main/docs