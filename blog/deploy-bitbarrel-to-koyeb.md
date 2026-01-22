# Deploying BitBarrel to Koyeb in 5 Minutes

*A complete guide to running your high-performance key-value store on Koyeb's serverless platform*

## Introduction

BitBarrel is a high-performance Bitcask-style key-value storage engine written in Nim that provides lightning-fast reads (O(1) via in-memory hash index) and robust crash recovery. But how do you deploy it to the cloud in a way that's both cost-effective and scales automatically?

Enter **Koyeb** - a developer-friendly serverless platform that makes deploying BitBarrel incredibly simple, with persistent storage, global regions, and pay-as-you-go pricing.

In this tutorial, we'll deploy BitBarrel to Koyeb with persistent storage, configure authentication, and connect client applications - all in under 5 minutes.

## Why Koyeb + BitBarrel?

Before we dive in, let's understand why this combination works so well:

**BitBarrel provides:**
- Bitcask storage model (append-only, O(1) reads)
- High performance (~250K ops/sec)
- Crash recovery with hint files
- WebSocket and HTTP APIs
- JWT authentication

**Koyeb provides:**
- Persistent volume mounting
- Automatic scaling
- Global edge network
- Simple CLI deployment
- Generous free tier

Together, you get a production-ready key-value store that handles the operational complexity for you.

## Prerequisites

- A [Koyeb account](https://app.koyeb.com) (free tier works great)
- A terminal with curl/wget
- 5 minutes of your time

## Step 1: Install Koyeb CLI (30 seconds)

Let's start by installing the Koyeb CLI:

```bash
curl -sSL https://raw.githubusercontent.com/gokr/bitbarrel/main/examples/koyeb/scripts/install-koyeb-cli.sh | bash
```

This script detects your OS and architecture, downloads the appropriate Koyeb CLI binary, and installs it to `/usr/local/bin`.

**Output:**
```
╔══════════════════════════════════════════════════════════════╗
║         Koyeb CLI Installation Script                        ║
╚══════════════════════════════════════════════════════════════╝

✓ Detected OS: linux
✓ Detected architecture: amd64
✓ Downloading Koyeb CLI...
✓ Koyeb CLI installed successfully!
✓ Version: 3.5.0

Next steps:
  1. Get your API token from: https://app.koyeb.com/settings/api
  2. Configure the CLI: koyeb login
```

Now authenticate with your Koyeb API token:

```bash
koyeb login
```

You'll be prompted to enter your API token, which you can generate at https://app.koyeb.com/settings/api.

> **⚠️ Token Type Important Note:**
>
> Use a **USER token** (not organization token) when prompted:
> - User tokens: Generated at https://app.koyeb.com/user/settings/api/
> - Organization tokens: Have limited permissions and may cause authentication errors
>
> If you see "Not logged in to Koyeb" errors despite logging in, you're likely using an organization token. Switch to a user token instead.

**Pro tip:** The free tier gives you 1 service, 1 concurrent instance, 100GB data transfer, and 2GB volume storage - perfect for getting started!

## Step 2: Deploy BitBarrel (2 minutes)

We have two deployment options:

### Option A: Interactive Wizard (Recommended for first time)

```bash
./examples/koyeb/scripts/configure-koyeb.sh
```

This interactive wizard will guide you through:
1. Naming your application
2. Choosing a region
3. Setting volume size
4. Configuring public/private access
5. Setting up authentication

### Option B: Direct Deployment

For a quick deployment with defaults:

```bash
./examples/koyeb/scripts/deploy-to-koyeb.sh --name my-bitbarrel
```

This creates:
- App: `my-bitbarrel`
- Service: `my-bitbarrel` (same name)
- Region: Frankfurt (`fra`)
- Volume: 10GB
- Public URL: Yes
- Authentication: Auto-generated JWT secret

**What's happening behind the scenes:**

The deployment script:
1. Validates prerequisites (Koyeb CLI, authentication)
2. Creates a Koyeb app in your chosen region
3. Provisions a persistent volume (mounted at `/data`)
4. Creates a service with BitBarrel container
5. Configures environment variables
6. Sets up networking and routing
7. Generates JWT secrets for authentication
8. Waits for the service to become healthy
9. Displays connection information

**Expected output:**
```bash
╔══════════════════════════════════════════════════════════════╗
║         BitBarrel Koyeb Deployment Script                    ║
╚══════════════════════════════════════════════════════════════╝

Checking prerequisites...
✓ Koyeb CLI found
✓ Authenticated with Koyeb
✓ App name is available
✓ JWT secret generated

Creating Koyeb app 'my-bitbarrel'...
✓ App created successfully

Creating BitBarrel service...
✓ Service created successfully

Monitoring deployment (press Ctrl+C to stop)...
Note: Initial deployment may take 2-5 minutes

✓ Service is healthy!

╔══════════════════════════════════════════════════════════════╗
║                 Deployment Successful!                       ║
╚══════════════════════════════════════════════════════════════╝

Your BitBarrel instance is ready:
  Public URL: https://my-bitbarrel.koyeb.app

Access points:
  WebSocket: wss://my-bitbarrel.koyeb.app
  HTTP API:  https://my-bitbarrel.koyeb.app/api
  WebAdmin:  https://my-bitbarrel.koyeb.app/webadmin

Configuration:
  App name:     my-bitbarrel
  Region:       fra
  Volume size:  10GB
  Image:        ghcr.io/gokr/bitbarrel:latest

Your JWT secret (save this!):
  f7s9v2mK4pL6nQ8rT1uV3wX5yZ7aB9cD2eF0gH1iJ3k=
```

**Important:** Save your JWT secret! You'll need it to authenticate clients.

## Step 3: Verify Your Deployment (30 seconds)

Let's test the deployment using the built-in test script:

```bash
./examples/koyeb/test-connection.sh
```

Or test manually with curl:

```bash
# Get service info
curl https://my-bitbarrel.koyeb.app/api/info

# Set a value
curl -X POST https://my-bitbarrel.koyeb.app/api/set \
  -H "Content-Type: application/json" \
  -d '{"key": "test", "value": "Hello from Koyeb!"}'

# Get the value
curl https://my-bitbarrel.koyeb.app/api/get/test
```

**Expected response:**
```json
{"result":"Hello from Koyeb!","error":null}
```

## Step 4: Access WebAdmin (30 seconds)

BitBarrel includes a built-in web administration interface. Open your browser:

```
https://my-bitbarrel.koyeb.app/webadmin
```

The WebAdmin provides:
- Real-time key listing
- Value inspection
- Key deletion
- Server statistics
- Connection monitoring

## Step 5: Connect Your Application (1 minute)

Now let's connect a real application. Here's an example using Python:

### Python Client Example

```python
from bitbarrel_client import BitBarrelClient

# Initialize client
client = BitBarrelClient("wss://my-bitbarrel.koyeb.app")

# Add authentication if enabled
# client.set_auth_token("your-jwt-secret")

# Connect
client.connect()

# Store data
client.set("user:123:name", "Alice")
client.set("user:123:email", "alice@example.com")

# Retrieve data
name = client.get("user:123:name")
print(f"User name: {name}")

# Close connection
client.close()
```

### Nim Client Example

```nim
import bitbarrel, asyncdispatch

proc main() {.async.} =
  let client = newBitBarrelClient("wss://my-bitbarrel.koyeb.app")
  # client.setAuthToken("your-jwt-secret")

  await client.connect()

  # Store session data
  await client.set("session:abc123", "{"user_id": 123}")

  # Get session data
  let session = await client.get("session:abc123")
  echo "Session: ", session

  await client.close()

waitFor main()
```

### WebSocket with Authentication

If you enabled authentication, include the JWT token:

```bash
websocat -H "Authorization: Bearer f7s9v2mK4pL6nQ8rT1uV3wX5yZ7aB9cD2eF0gH1iJ3k=" \
         wss://my-bitbarrel.koyeb.app <<EOF
{"jsonrpc": "2.0", "method": "set", "params": ["key", "value"], "id": 1}
{"jsonrpc": "2.0", "method": "get", "params": ["key"], "id": 2}
EOF
```

## Understanding the Architecture

Let's dive deeper into what we just deployed:

### Persistent Volumes

Koyeb automatically provisions persistent volumes:
- **Mount path:** `/data`
- **Technology:** SSD-backed block storage
- **Persistence:** Survives restarts and updates
- **Scaling:** Resizable via service update

The volume stores:
- Data files (append-only logs)
- Hint files (for fast recovery)
- KeyDir index (recovered on startup)
- Configuration files

### Recovery Process

On startup, BitBarrel:
1. Scans data directory for hint files
2. Rebuilds KeyDir from hints (40K+ keys/sec)
3. Falls back to full data scan if needed
4. Becomes ready in seconds

### Scaling Behavior

Koyeb automatically handles scaling:
- **Scaling triggers:** CPU, memory, request volume
- **Scaling type:** Horizontal (more instances)
- **Persistence:** Each instance gets its own volume
- **Best practice:** Use BitBarrel for stateless apps or implement replication

## Advanced Configuration

### Custom Environment Variables

Create a `.env.koyeb` file:

```bash
# Basic settings
APP_NAME=my-production-bitbarrel
REGION=was
VOLUME_SIZE=50
PRIVATE=false
ENABLE_AUTH=true

# BitBarrel tuning
BITBARREL_BUFFER_SIZE=131072
BITBARREL_SYNC_INTERVAL=500
BITBARREL_MAX_CONNECTIONS=2000

# Authentication
BITBARREL_JWT_SECRET=your-secure-secret-here
BITBARREL_ADMIN_TOKEN=your-admin-token-here
```

Then deploy:

```bash
source .env.koyeb
./examples/koyeb/scripts/deploy-to-koyeb.sh --name "$APP_NAME"
```

### Private Deployment

For internal services, deploy without a public URL:

```bash
./examples/koyeb/scripts/deploy-to-koyeb.sh --name internal-bitbarrel --private
```

Access via:
- Service mesh
- Direct instance IP (for debugging)
- Koyeb's private network

### Regional Deployment

Deploy closer to your users:

```bash
# US East Coast
./examples/koyeb/scripts/deploy-to-koyeb.sh --name us-bitbarrel --region was

# Europe (Paris)
./examples/koyeb/scripts/deploy-to-koyeb.sh --name eu-bitbarrel --region par

# UK (London)
./examples/koyeb/scripts/deploy-to-koyeb.sh --name uk-bitbarrel --region lhr
```

## Monitoring and Observability

### View Logs

```bash
# Live tail
koyeb service logs my-bitbarrel/my-bitbarrel --follow

# Search for errors
koyeb service logs my-bitbarrel/my-bitbarrel | grep -i error

# Time-based queries
koyeb service logs my-bitbarrel/my-bitbarrel --since 24h
```

### Check Metrics

```bash
# Service status
koyeb service describe my-bitbarrel/my-bitbarrel

# Detailed metrics (via JSON)
koyeb service describe my-bitbarrel/my-bitbarrel --output json | jq
```

### Set Up Alerts

Monitor via Koyeb dashboard:
1. Go to your service
2. Click "Metrics"
3. Set up alerts for:
   - High CPU usage
   - Memory warnings
   - Error rates
   - Response times

## Updating Your Deployment

### Update to Latest Version

```bash
./examples/koyeb/scripts/update-koyeb.sh --name my-bitbarrel
```

### Update with New Configuration

```bash
# Edit .env.koyeb
echo "BITBARREL_BUFFER_SIZE=262144" >> .env.koyeb

# Redeploy
source .env.koyeb
./examples/koyeb/scripts/update-koyeb.sh --name my-bitbarrel
```

### Rollback

If something goes wrong:

```bash
# Redeploy previous image
./examples/koyeb/scripts/update-koyeb.sh --name my-bitbarrel \
  --image ghcr.io/gokr/bitbarrel:previous-version
```

## Real-World Use Cases

### 1. Session Storage for Web Apps

```python
# Fast session storage with automatic cleanup
client.setex("session:" + session_id, user_data, ttl=3600)
```

Deploy close to your app servers for minimal latency.

### 2. Feature Flags

```python
# Toggle features without redeploying
if client.get("feature:new_ui") == "enabled":
    show_new_ui()
```

Use Koyeb's fast deployments to propagate flag changes.

### 3. Rate Limiting

```python
# Distributed rate limiting
key = f"ratelimit:{user_ip}"
current = client.incr(key)
if current > 100:
    return "Rate limit exceeded"
```

Leverage Koyeb's edge locations for distributed rate limiting.

### 4. Caching Layer

```python
# Cache expensive computations
def get_expensive_data():
    cache_key = "cache:expensive_calc"
    cached = client.get(cache_key)
    if cached:
        return cached
    result = do_expensive_calculation()
    client.setex(cache_key, result, ttl=300)
    return result
```

BitBarrel's O(1) reads make it perfect for caching.

### 5. IoT Data Ingestion

```python
# Store sensor data
for reading in sensor_readings:
    key = f"sensor:{device_id}:{reading.timestamp}"
    client.set(key, json.dumps(reading))
```

Koyeb's auto-scaling handles traffic spikes from device fleets.

## Cost Analysis

### Free Tier (Getting Started)

- **Koyeb:** $0/month
  - 1 service
  - 1 concurrent instance
  - 100GB data transfer
  - 2GB volume storage

- **BitBarrel:** $0/month (open source)

**Total: $0/month** ✅

### Production Deployment

For a production workload (estimates):

- **Koyeb:** ~$15-30/month
  - Service: $5-10
  - Volume (10GB): $1
  - Data transfer: $5-15 (varies by usage)
  - Additional instances: $5-10 each

- **BitBarrel:** $0/month (self-hosted)

**Total: ~$15-30/month** 💰

Compare to managed alternatives:
- DynamoDB: $50-200/month
- Redis Cloud: $30-100/month
- MongoDB Atlas: $60-200/month

## Troubleshooting Common Issues

### Issue: "Koyeb CLI not found"

**Solution:**
```bash
curl -sSL https://raw.githubusercontent.com/gokr/bitbarrel/main/examples/koyeb/scripts/install-koyeb-cli.sh | bash
export PATH="$PATH:/usr/local/bin"
```

### Issue: "Not logged in to Koyeb"

**Solution:**
```bash
koyeb login
# Enter your API token from https://app.koyeb.com/settings/api
```

### Issue: Service stuck in "Deploying"

**Diagnosis:**
```bash
# Check logs
koyeb service logs my-bitbarrel/my-bitbarrel

# Check status
koyeb service describe my-bitbarrel/my-bitbarrel
```

**Common causes:**
- Invalid JWT secret (too short)
- Port conflicts
- Resource limits

### Issue: "Connection refused"

**Solution:**
1. Check service is HEALTHY
2. Verify URL includes `https://`
3. For WebSockets: use `wss://`
4. Check authentication tokens

### Issue: High latency

**Solutions:**
1. Choose region closer to users
2. Increase buffer size (`BITBARREL_BUFFER_SIZE`)
3. Monitor resource usage
4. Consider scaling up

### Issue: Data persistence problems

**Diagnosis:**
```bash
# Check volume mount
koyeb service describe my-bitbarrel/my-bitbarrel

# Verify BitBarrel data directory
# Note: Direct SSH not available, but you can check through logs
koyeb service logs my-bitbarrel/my-bitbarrel --grep "data"
```

**Solution:** Ensure volume is mounted to `/data`

### Issue: Need to grow volume size

**Checking current volume size:**
```bash
koyeb volumes list
```

**Resizing volumes:
Koyeb volumes cannot be directly resized. Instead:**
1. Create a snapshot of your current volume (via dashboard or CLI)
2. Create a new volume from the snapshot with the desired size
3. Update your service to use the new volume

Example resize workflow:
```bash
# 1. Find your volume
VOLUME_ID=$(koyeb volumes list | grep my-bitbarrel | awk '{print $1}')

# 2. Create snapshot (via dashboard or API)
# In Koyeb dashboard: Volumes → Select volume → Create snapshot

# 3. Create new larger volume
koyeb volumes create my-bitbarrel-data-larger \
  --region fra \
  --size 50  # New size in GB

# 4. Update service to use new volume
koyeb service update my-bitbarrel/my-bitbarrel \
  --volumes my-bitbarrel-data-larger:/data

# 5. Wait for redeployment
koyeb service describe my-bitbarrel/my-bitbarrel
```

**Better approach for growing data:**
- Start with reasonable size (20-50GB for most apps)
- Monitor usage: `koyeb volumes list`
- Set up alerts at 80% capacity
- Use BitBarrel's built-in compression to maximize storage efficiency
- Regular compaction removes old data and frees space

**Volume pricing:**
Costs vary by Koyeb plan:
- **Starter**: Limited volume features
- **Pro** ($29/mo): Volume support with per-GB pricing
- **Scale/Enterprise**: Included in plan or volume discounts

Check https://koyeb.com/pricing for current rates. Generally charged per GB per month.

## Performance Tuning

### For High Read Workloads

```bash
# Increase read buffer
BITBARREL_BUFFER_SIZE=131072  # 128KB

# Increase max connections
BITBARREL_MAX_CONNECTIONS=5000

# Use larger instance type
koyeb service update my-bitbarrel/my-bitbarrel \
  --instance-type micro
```

### For High Write Workloads

```bash
# Reduce sync interval (fsync more often)
BITBARREL_SYNC_INTERVAL=100  # 100ms

# Or disable for max performance
BITBARREL_SYNC_INTERVAL=0    # No fsync

# Use larger write buffer
BITBARREL_BUFFER_SIZE=262144  # 256KB
```

### For Mixed Workloads

```bash
# Balanced configuration
BITBARREL_BUFFER_SIZE=131072
BITBARREL_SYNC_INTERVAL=500  # 500ms
BITBARREL_MAX_CONNECTIONS=2000
```

## Cleanup

When you're done testing, delete your deployment:

```bash
# Delete the entire app (including volumes)
koyeb app delete my-bitbarrel

# Or just the service
koyeb service delete my-bitbarrel/my-bitbarrel
```

## Next Steps

Now that you have BitBarrel running on Koyeb, consider:

1. **Set up monitoring:** Configure alerts and dashboards
2. **Implement backups:** Snapshot volumes regularly
3. **Plan for scale:** Understand your growth patterns
4. **Secure your deployment:** Use private networking
5. **Integrate clients:** Connect your applications
6. **Optimize costs:** Right-size your deployment

## Summary

In this tutorial, we:

✅ Installed Koyeb CLI (30 seconds)
✅ Deployed BitBarrel with one command (2 minutes)
✅ Verified the deployment (30 seconds)
✅ Explored the WebAdmin (30 seconds)
✅ Connected sample clients (1 minute)

**Total time: ~4.5 minutes** 🚀

You now have a production-ready key-value store with:
- Persistent storage (survives restarts)
- Automatic scaling (handles traffic spikes)
- Global regions (deploy close to users)
- JWT authentication (secure by default)
- WebSocket & HTTP APIs (flexible access)

The combination of BitBarrel's high-performance storage engine and Koyeb's simple deployment platform gives you a powerful, scalable key-value store without the operational overhead.

## Resources

- **BitBarrel Documentation:** [docs/README.md](../docs/README.md)
- **Koyeb Deployment Guide:** [docs/KOYEB_DEPLOYMENT.md](../docs/KOYEB_DEPLOYMENT.md)
- **Client Examples:** [examples/koyeb/](../examples/koyeb/)
- **Source Code:** [github.com/gokr/bitbarrel](https://github.com/gokr/bitbarrel)
- **Koyeb Documentation:** [koyeb.com/docs](https://www.koyeb.com/docs)

---

**Happy building!** 🎉