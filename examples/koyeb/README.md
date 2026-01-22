# BitBarrel Koyeb Examples

This directory contains examples and scripts for deploying and using BitBarrel on Koyeb.

## Quick Start

1. **Deploy BitBarrel to Koyeb:**
   ```bash
   ./examples/koyeb/scripts/deploy-to-koyeb.sh --name my-bitbarrel
   ```

2. **Test the deployment:**
   ```bash
   ./test-connection.sh --endpoint https://my-bitbarrel.koyeb.app
   ```

3. **Run the demo:**
   ```bash
   ./demo-operations.sh --endpoint https://my-bitbarrel.koyeb.app
   ```

4. **Try client examples:**
   ```bash
   # Python
   cd clients && python python_example.py

   # Nim
   cd clients && nim c -r nim_example.nim

   # cURL
   cd clients && ./curl_examples.sh
   ```

## Files and Scripts

### Deployment Scripts

Located in `./scripts/`:

- **install-koyeb-cli.sh** - Install Koyeb CLI
- **configure-koyeb.sh** - Interactive configuration wizard
- **deploy-to-koyeb.sh** - One-click deployment
- **update-koyeb.sh** - Update/redeploy existing instance

### Testing Scripts

- **test-connection.sh** - Test connectivity and basic operations
- **demo-operations.sh** - Comprehensive demo of BitBarrel features

### Client Examples

Located in `clients/`:

- **python_example.py** - Python WebSocket client
- **nim_example.nim** - Nim WebSocket client
- **curl_examples.sh** - cURL HTTP API examples

## Configuration

Set these environment variables or pass as arguments:

```bash
export BITBARREL_ENDPOINT="https://my-bitbarrel.koyeb.app"
export BITBARREL_JWT_SECRET="your-jwt-token"

# Then run scripts without arguments
./test-connection.sh
```

Or pass arguments:

```bash
./test-connection.sh \
  --endpoint https://my-bitbarrel.koyeb.app \
  --token your-jwt-token
```

## Use Cases Demonstrated

### 1. Basic CRUD Operations
- Set, get, update, and delete key-value pairs
- See `demo-operations.sh` and client examples

### 2. Session Management
- User sessions with timestamps
- Session cleanup patterns

### 3. Feature Flags
- Dynamic feature toggles
- Gradual rollouts

### 4. Rate Limiting
- Per-IP rate limiting
- Time-window counters

### 5. Counters & Analytics
- Page view counters
- Unique visitor tracking

### 6. JSON Data Storage
- Complex data structures
- Nested objects

### 7. Performance Testing
- Throughput measurement
- Bulk operations

## Authentication

If you enabled JWT authentication, provide the token:

```bash
# Via environment variable
export BITBARREL_JWT_SECRET="your-secret-token"

# Or via argument
./test-connection.sh --token "your-secret-token"
```

## Troubleshooting

### Connection Refused
- Check endpoint URL includes `https://`
- Verify service is HEALTHY: `koyeb service describe my-bitbarrel/my-bitbarrel`

### Authentication Errors
- Ensure token is correct
- Check token hasn't expired
- Verify token format: `Authorization: Bearer <token>`

### Operations Fail
- Check service logs: `koyeb service logs my-bitbarrel/my-bitbarrel`
- Verify volume mount: `/data`
- Check memory/disk usage

## Next Steps

1. **Read the blog post:** [Deploying BitBarrel to Koyeb in 5 Minutes](../../blog/deploy-bitbarrel-to-koyeb.md)
2. **Full documentation:** [Koyeb Deployment Guide](../../docs/KOYEB_DEPLOYMENT.md)
3. **Client libraries:** See [clients/](../../clients/) for more language support
4. **Production guide:** Learn about monitoring, backups, and scaling

## Support

- **Issues:** Report on [GitHub](https://github.com/gokr/bitbarrel/issues)
- **Discussions:** Ask questions in [Discussions](https://github.com/gokr/bitbarrel/discussions)
- **Documentation:** See [docs/](../../docs/)

## Contributing

Feel free to add more:
- Client examples for other languages
- Use case demonstrations
- Performance benchmarks
- Monitoring integrations
