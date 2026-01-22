# Deploying BitBarrel to Koyeb

This guide covers deploying BitBarrel to Koyeb with persistent storage, public/private access, and authentication.

## Overview

Koyeb provides a developer-friendly serverless platform that's perfect for running BitBarrel with:
- **Persistent volumes** for data storage
- **Automatic scaling** based on demand
- **Global deployment** across multiple regions
- **Simple deployment** via CLI or Git integration

## Prerequisites

- A [Koyeb account](https://app.koyeb.com) (free tier available)
- Koyeb CLI installed (see installation below)
- A Koyeb API token (generate at https://app.koyeb.com/user/settings/api/)
  - For deployment scripts, we recommend using a **user token** (not organization token)
  - Organization tokens work but have limited CLI capabilities
- Git (for version control)
- Docker (optional, for custom builds)

## Quick Start (5 minutes)

### 1. Install Koyeb CLI

```bash
curl -sSL https://raw.githubusercontent.com/gokr/bitbarrel/main/examples/koyeb/scripts/install-koyeb-cli.sh | bash
```

After installation, authenticate:

```bash
koyeb login
```

### 2. Deploy BitBarrel

Using the interactive wizard:

```bash
./examples/koyeb/scripts/configure-koyeb.sh
```

Or deploy directly:

```bash
./examples/koyeb/scripts/deploy-to-koyeb.sh --name my-bitbarrel
```

Your BitBarrel instance will be ready in 2-5 minutes!

### 3. Access Your Instance

Once deployed, you'll receive a public URL:
- **WebSocket:** `wss://my-bitbarrel.koyeb.app`
- **HTTP API:** `https://my-bitbarrel.koyeb.app/api`
- **WebAdmin:** `https://my-bitbarrel.koyeb.app/webadmin`

## Detailed Deployment Options

### Interactive Configuration

The configuration wizard helps set up your deployment:

```bash
./examples/koyeb/scripts/configure-koyeb.sh
```

This will guide you through:
1. Application naming
2. Region selection
3. Volume sizing
4. Public/private access
5. Authentication setup
6. Advanced configuration

### Direct Deployment

For automated deployments or CI/CD:

```bash
./examples/koyeb/scripts/deploy-to-koyeb.sh \
  --name my-bitbarrel \
  --region fra \
  --volume-size 10 \
  --image ghcr.io/gokr/bitbarrel:latest
```

#### Options

- `--name`: Application name (required)
- `--region`: Deployment region: `fra`, `was`, `par`, `lhr`
- `--volume-size`: Persistent volume size in GB (default: 10)
- `--image`: Docker image to use
- `--private`: Deploy without public URL
- `--help`: Show all options

### Updating Your Deployment

To update with a new image:

```bash
./examples/koyeb/scripts/update-koyeb.sh --name my-bitbarrel --image ghcr.io/gokr/bitbarrel:v1.1.0
```

To redeploy with the same image:

```bash
./examples/koyeb/scripts/update-koyeb.sh --name my-bitbarrel
```

## Configuration

### Environment Variables

All BitBarrel configuration options are supported via `BITBARREL_*` environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `BITBARREL_JWT_SECRET` | JWT secret for authentication | Generated |
| `BITBARREL_ADMIN_TOKEN` | Admin token for management | Generated |
| `BITBARREL_PORT` | Server port | 8080 |
| `BITBARREL_DATA_DIR` | Data directory | /data |
| `BITBARREL_SYNC_INTERVAL` | Sync interval (ms) | 1000 |
| `BITBARREL_BUFFER_SIZE` | Read buffer size | 65536 |
| `BITBARREL_MAX_CONNECTIONS` | Max connections | 1000 |

### Volume Configuration

Koyeb automatically provisions persistent volumes:
- Mount path: `/data`
- Backed by SSD storage
- Resized via service update
- Backups with snapshots (manual)

### Regions

Choose the region closest to your users:
- `fra`: Frankfurt, Germany (EU)
- `was`: Washington, US (East Coast)
- `par`: Paris, France (EU)
- `lhr`: London, UK

## Authentication

### JWT Authentication

Enable authentication during deployment:

```bash
# Interactive wizard will ask
./examples/koyeb/scripts/configure-koyeb.sh

# Or set these in your environment
export BITBARREL_JWT_SECRET="your-secure-secret"
export BITBARREL_ADMIN_TOKEN="your-admin-token"

./examples/koyeb/scripts/deploy-to-koyeb.sh --name my-bitbarrel
```

### Generating Tokens

Generate secure tokens:

```bash
# JWT Secret
openssl rand -base64 32

# Admin Token
openssl rand -hex 16
```

### Using Authentication

Include the JWT token in the `Authorization` header:

```bash
# HTTP API
curl -H "Authorization: Bearer YOUR_JWT_TOKEN" \
     https://my-bitbarrel.koyeb.app/api/get/mykey

# WebSocket
websocat -H "Authorization: Bearer YOUR_JWT_TOKEN" \
         wss://my-bitbarrel.koyeb.app
```

## Client Examples

### Nim Client

```nim
import bitbarrel, std/[asyncdispatch, json]

let client = newBitBarrelClient("wss://my-bitbarrel.koyeb.app")
client.setAuthToken("your-jwt-token")

await client.connect()
await client.set("key", "value")
let value = await client.get("key")
echo value
```

### Python Client

```python
from bitbarrel_client import BitBarrelClient

client = BitBarrelClient("wss://my-bitbarrel.koyeb.app")
client.set_auth_token("your-jwt-token")

client.connect()
client.set("key", "value")
value = client.get("key")
print(value)
```

### cURL Examples

```bash
# Set a value
curl -X POST https://my-bitbarrel.koyeb.app/api/set \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer YOUR_TOKEN" \
     -d '{"key": "username", "value": "alice"}'

# Get a value
curl https://my-bitbarrel.koyeb.app/api/get/username \
     -H "Authorization: Bearer YOUR_TOKEN"

# Delete a key
curl -X DELETE https://my-bitbarrel.koyeb.app/api/delete/username \
     -H "Authorization: Bearer YOUR_TOKEN"
```

### WebSocket Example

```bash
websocat -H "Authorization: Bearer YOUR_TOKEN" \
         --jsonrpc wss://my-bitbarrel.koyeb.app <<EOF
{"jsonrpc": "2.0", "method": "set", "params": ["key", "value"], "id": 1}
{"jsonrpc": "2.0", "method": "get", "params": ["key"], "id": 2}
EOF
```

## Monitoring and Logs

### View Logs

```bash
# Live logs
koyeb service logs my-bitbarrel/my-bitbarrel --follow

# Recent logs
koyeb service logs my-bitbarrel/my-bitbarrel --tail 100

# Filter by time
koyeb service logs my-bitbarrel/my-bitbarrel --since 1h
```

### Check Service Status

```bash
# Service details
koyeb service describe my-bitbarrel/my-bitbarrel

# Deployment status
koyeb service describe my-bitbarrel/my-bitbarrel --output json | jq '.status'
```

### Health Checks

BitBarrel includes built-in health checks:
- Service responds on port 8080
- WebSocket connections accepted
- Disk space monitored

## Backup and Recovery

### Manual Backups

Create volume snapshots:

```bash
# Via Koyeb dashboard or API
# Snapshots are point-in-time copies of your volume
```

### Export Data

Use the CLI to export data:

```bash
# Connect to your instance
websocat wss://my-bitbarrel.koyeb.app <<EOF
{"jsonrpc": "2.0", "method": "keys", "params": [], "id": 1}
{"jsonrpc": "2.0", "method": "get", "params": ["key1"], "id": 2}
EOF
```

## Scaling

Koyeb automatically scales based on:
- CPU usage
- Memory usage
- Request volume

Manual scaling:

```bash
# Scale to fixed instance count
koyeb service update my-bitbarrel/my-bitbarrel \
  --instance-type nano \
  --scaling-min 1 \
  --scaling-max 3
```

## Troubleshooting

### Deployment Fails

Check logs for errors:

```bash
koyeb service logs my-bitbarrel/my-bitbarrel --tail 50
```

Common issues:
- **Invalid JWT secret**: Must be at least 32 characters
- **Port conflicts**: Ensure BITBARREL_PORT matches exposed port
- **Volume mount errors**: Verify /data mount path

### Authentication Issues

**"Not logged in to Koyeb" error when already logged in**

This typically happens when using an **organization token** instead of a **user token**. Organization tokens have limited permissions and cannot run certain commands.

**To fix:**
1. Generate a user token from https://app.koyeb.com/user/settings/api/
2. Re-authenticate: `koyeb login`
3. Paste your user token when prompted

**Note:** The deployment scripts now support both token types, but organization tokens may have other limitations with CLI commands.

**Verifying your authentication:**
```bash
# Should work with both token types
koyeb apps list

# Only works with user tokens
koyeb organizations list
```

**Token types explained:**
- **User tokens**: Linked to your user account, can perform all operations (recommended)
- **Organization tokens**: Linked to an organization, limited operations but works for deployments

If you must use an organization token, ensure it has sufficient permissions to create apps, services, and volumes.

### Service Unhealthy

Check service status:

```bash
koyeb service describe my-bitbarrel/my-bitbarrel
```

Look for:
- Resource limits exceeded
- Health check failures
- Disk space issues

### Connection Refused

- Verify service is `HEALTHY`
- Check authentication tokens
- Confirm URL and port

### High Latency

- Choose a region closer to users
- Check volume performance
- Monitor CPU/memory usage

## Volumes

### Creating Volumes

Create a persistent volume:

```bash
koyeb volumes create my-bitbarrel-data \
  --region fra \
  --size 10
```

### Attaching Volumes

Attach a volume to a service:

```bash
koyeb service update my-bitbarrel/my-bitbarrel \
  --volumes my-bitbarrel-data:/data
```

### Volume Management

**Resizing volumes:**
Volumes can be resized to increase capacity, but this typically requires:
1. Taking a snapshot of the existing volume
2. Creating a new volume from the snapshot with the desired size
3. Updating the service to use the new volume

The deployment scripts create volumes sized according to your specifications:
```bash
./examples/koyeb/scripts/deploy-to-koyeb.sh --name my-bitbarrel --volume-size 50
```

**Volume pricing:**
- Pricing varies by plan (Starter, Pro, Scale, Enterprise)
- Generally charged per GB per month
- Check https://koyeb.com/pricing for current rates
- Volume storage may be included with your instance (e.g., GPU instances include local NVMe storage)

**Best practices:**
- Start with smaller volumes and scale as needed
- Use compression in BitBarrel to reduce storage needs
- Regular compaction removes old versions and frees space
- Monitor volume usage and set up alerts at 80% capacity

### Volume Performance

BitBarrel performs best with:
- SSD-backed storage (default on Koyeb)
- Sufficient IOPS for your workload
- Adequate buffer sizes (configured via `BITBARREL_BUFFER_SIZE`)

## Cost Optimization

### Free Tier

Koyeb's free tier includes:
- 1 service
- 1 concurrent instance
- 100GB data transfer
- 2GB volume storage

### Optimization Tips

1. **Right-size volumes**: Start small, scale up as needed
2. **Choose appropriate regions**: Fra is often cheapest
3. **Use private deployments**: Reduce data transfer costs
4. **Monitor usage**: Set up alerts for unexpected spikes
5. **Clean up old data**: Regular compaction reduces volume size

### Estimating Costs

Example monthly costs (production):
- Service: ~$5-10
- Volume (10GB): ~$1
- Data transfer: Variable by usage

## Security Best Practices

1. **Use strong JWT secrets**: Generate with `openssl rand -base64 32`
2. **Rotate tokens regularly**: Update BITBARREL_ADMIN_TOKEN
3. **Use private deployments**: For internal services
4. **Enable authentication**: Always for production
5. **Monitor access logs**: Check for unusual patterns
6. **Regular updates**: Keep BitBarrel image current

## CI/CD Integration

### GitHub Actions

See `.github/workflows/deploy-to-koyeb.yml` for a complete example.

### GitLab CI

```yaml
deploy:
  stage: deploy
  script:
    - curl -sSL https://raw.githubusercontent.com/gokr/bitbarrel/main/examples/koyeb/scripts/install-koyeb-cli.sh | bash
    - koyeb login --token $KOYEB_TOKEN
    - ./examples/koyeb/scripts/deploy-to-koyeb.sh --name $APP_NAME
```

## Support

- **Issues**: Report on [GitHub](https://github.com/gokr/bitbarrel/issues)
- **Discussions**: Ask questions in [Discussions](https://github.com/gokr/bitbarrel/discussions)
- **Documentation**: See [docs/](.) for more guides

## Comparison: Koyeb vs Other Platforms

| Feature | Koyeb | Heroku | DigitalOcean | AWS |
|---------|-------|--------|--------------|-----|
| **Persistent Storage** | ✅ Yes | ❌ No | ✅ Yes | ✅ Yes |
| **WebSocket Support** | ✅ Yes | ✅ Yes | ✅ Yes | ✅ Yes |
| **Deployment Speed** | ⚡ Fast | ⚡ Fast | 🐢 Slow | 🐢 Slow |
| **Pricing** | 💰 Free tier | 💰 Free tier | 💰💰 Paid | 💰💰💰 Paid |
| **Complexity** | 🟢 Low | 🟢 Low | 🟡 Medium | 🔴 High |
| **Global Regions** | 4 | 2 | 12 | 25+ |

## Next Steps

1. **Test your deployment**: Run the included test scripts
2. **Set up monitoring**: Configure alerts and dashboards
3. **Plan for scale**: Understand scaling behavior
4. **Implement backups**: Set up regular backup processes
5. **Integrate clients**: Connect your applications
6. **Optimize performance**: Tune for your workload

---

**Happy deploying!** 🚀
