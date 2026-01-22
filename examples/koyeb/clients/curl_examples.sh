#!/bin/bash
#
# BitBarrel Koyeb cURL Examples
# Demonstrates using BitBarrel via HTTP API with cURL
#

# Configuration - update these for your deployment
ENDPOINT="${BITBARREL_ENDPOINT:-https://my-bitbarrel.koyeb.app}"
AUTH_TOKEN="${BITBARREL_JWT_SECRET:-}"

# Build headers
HEADERS=(-H "Content-Type: application/json")
if [[ -n "$AUTH_TOKEN" ]]; then
    HEADERS+=(-H "Authorization: Bearer $AUTH_TOKEN")
fi

echo "BitBarrel Koyeb cURL Examples"
echo "Endpoint: $ENDPOINT"
echo ""

# 1. Basic Operations
echo "📦 Basic Operations"
echo "=================="

# Set a value
echo "1. Set a value"
curl -X POST "$ENDPOINT/api/set" \
    "${HEADERS[@]}" \
    -d '{"key": "user:1001:name", "value": "Alice Smith"}'
echo ""

# Get a value
echo "2. Get a value"
curl -X GET "$ENDPOINT/api/get/user:1001:name" \
    "${HEADERS[@]}"
echo ""

# Update a value
echo "3. Update a value"
curl -X POST "$ENDPOINT/api/set" \
    "${HEADERS[@]}" \
    -d '{"key": "user:1001:name", "value": "Alice Johnson"}'
echo ""

# Delete a value
echo "4. Delete a value"
curl -X DELETE "$ENDPOINT/api/delete/user:1001:name" \
    "${HEADERS[@]}"
echo ""

# Try to get deleted value
echo "5. Get deleted value (should return null)"
curl -X GET "$ENDPOINT/api/get/user:1001:name" \
    "${HEADERS[@]}"
echo ""

# 2. Batch Operations
echo ""
echo "📦 Batch Operations"
echo "=================="

# Set multiple values
echo "1. Set multiple values"
for i in {1..3}; do
    curl -X POST "$ENDPOINT/api/set" \
        "${HEADERS[@]}" \
        -d "{\"key\": \"item:$i\", \"value\": \"Value $i\"}"
    echo ""
done

# Get all keys
echo "2. Get all keys"
curl -X GET "$ENDPOINT/api/keys" \
    "${HEADERS[@]}"
echo ""

# Get keys with pattern
echo "3. Get keys with pattern 'item:*'"
curl -X GET "$ENDPOINT/api/keys/item:" \
    "${HEADERS[@]}"
echo ""

# 3. Session Management
echo ""
echo "🎫 Session Management"
echo "===================="

SESSION_ID="sess_$(date +%s)"

# Create session
echo "1. Create session"
curl -X POST "$ENDPOINT/api/set" \
    "${HEADERS[@]}" \
    -d "{\"key\": \"$SESSION_ID:user_id\", \"value\": \"1001\"}"
echo ""

curl -X POST "$ENDPOINT/api/set" \
    "${HEADERS[@]}" \
    -d "{\"key\": \"$SESSION_ID:created\", \"value\": \"$(date +%s)\"}"
echo ""

# Read session
echo "2. Read session data"
curl -X GET "$ENDPOINT/api/get/$SESSION_ID:user_id" \
    "${HEADERS[@]}"
echo ""

# Update session
echo "3. Update session"
curl -X POST "$ENDPOINT/api/set" \
    "${HEADERS[@]}" \
    -d "{\"key\": \"$SESSION_ID:last_access\", \"value\": \"$(date +%s)\"}"
echo ""

# 4. Feature Flags
echo ""
echo "🚩 Feature Flags"
echo "================"

# Set feature flags
echo "1. Set feature flags"
features=(
    "new_dashboard:true"
    "dark_mode:true"
    "beta_api:false"
)

for feature in "${features[@]}"; do
    IFS=':' read -r flag value <<< "$feature"
    curl -X POST "$ENDPOINT/api/set" \
        "${HEADERS[@]}" \
        -d "{\"key\": \"feature:$flag\", \"value\": \"$value\"}"
    echo ""
done

# Check feature
echo "2. Check if feature is enabled"
curl -X GET "$ENDPOINT/api/get/feature:new_dashboard" \
    "${HEADERS[@]}"
echo ""

# 5. Counters and Rate Limiting
echo ""
echo "🧮 Counters & Rate Limiting"
echo "==========================="

# Page view counter
echo "1. Increment counter"
current=$(curl -s -X GET "$ENDPOINT/api/get/pageviews:home" "${HEADERS[@]}" | grep -o '[0-9]*' || echo "0")
new_count=$((current + 1))
curl -X POST "$ENDPOINT/api/set" \
    "${HEADERS[@]}" \
    -d "{\"key\": \"pageviews:home\", \"value\": \"$new_count\"}"
echo ""

# Rate limiting example
echo "2. Rate limiting pattern"
ip="192.168.1.100"
minute=$(date +%Y%m%d%H%M)
current=$(curl -s -X GET "$ENDPOINT/api/get/ratelimit:$ip:$minute" "${HEADERS[@]}" | grep -o '[0-9]*' || echo "0")
new_count=$((current + 1))
curl -X POST "$ENDPOINT/api/set" \
    "${HEADERS[@]}" \
    -d "{\"key\": \"ratelimit:$ip:$minute\", \"value\": \"$new_count\"}"
echo ""
echo "Requests this minute: $new_count"

# 6. JSON Data
echo ""
echo "📄 JSON Data Storage"
echo "===================="

# Store JSON
echo "1. Store JSON data"
curl -X POST "$ENDPOINT/api/set" \
    "${HEADERS[@]}" \
    -d '{
        "key": "user:1001:profile",
        "value": "{\"name\": \"Alice\", \"age\": 30, \"city\": \"NYC\"}"
    }'
echo ""

# Read JSON
echo "2. Read JSON data"
curl -X GET "$ENDPOINT/api/get/user:1001:profile" \
    "${HEADERS[@]}"
echo ""

# 7. Advanced Operations
echo ""
echo "⚡ Advanced Operations"
echo "====================="

# TTL example (simulated - set expiration in application logic)
echo "1. Key with TTL pattern"
echo "   In application: Check timestamp and delete if expired"

# Conditional operations
key="inventory:item:123"
current=$(curl -s -X GET "$ENDPOINT/api/get/$key" "${HEADERS[@]}" | grep -o '[0-9]*' || echo "0")
new_count=$((current - 1))
if [[ $new_count -ge 0 ]]; then
    curl -X POST "$ENDPOINT/api/set" \
        "${HEADERS[@]}" \
        -d "{\"key\": \"$key\", \"value\": \"$new_count\"}"
    echo "Item sold! New inventory: $new_count"
else
    echo "Insufficient inventory!"
fi
echo ""

# 8. Error Handling
echo ""
echo "⚠️  Error Handling"
echo "=================="

# Try to get non-existent key
echo "1. Non-existent key (returns null)"
curl -X GET "$ENDPOINT/api/get/nonexistent:key" \
    "${HEADERS[@]}"
echo ""

# Invalid request
echo "2. Invalid request (missing key)"
curl -X POST "$ENDPOINT/api/set" \
    "${HEADERS[@]}" \
    -d '{"value": "test"}'
echo ""

# 9. Monitoring
echo ""
echo "📊 Monitoring"
echo "============="

# Get server info
echo "1. Server info"
curl -X GET "$ENDPOINT/api/info" \
    "${HEADERS[@]}"
echo ""

# Health check
echo "2. Health check"
curl -X GET "$ENDPOINT/api/health" \
    "${HEADERS[@]}"
echo ""

# 10. Cleanup
echo ""
echo "🧹 Cleanup"
echo "=========="

echo "Delete all demo keys:"
echo "Replace PREFIX with your actual key prefix"
echo ""
echo "# Delete pattern"
echo "curl -X GET $ENDPOINT/api/keys/PREFIX: | \\"
echo "  jq -r '.[]' | \\"
echo "  xargs -I {} curl -X DELETE $ENDPOINT/api/delete/{} ${HEADERS[@]}"
echo ""

# Batch delete example
if [[ -n "$AUTH_TOKEN" ]]; then
    echo "Alternatively, use the test script:"
    echo "./examples/koyeb/test-connection.sh --endpoint $ENDPOINT --token $AUTH_TOKEN"
fi

echo ""
echo "✓ All examples completed!"
echo ""
echo "Helpful tips:"
echo "  • Store JWT token in BITBARREL_JWT_SECRET environment variable"
echo "  • Use 'jq' for better JSON formatting: curl ... | jq ."
echo "  • Add -v to curl for verbose output"
echo "  • Use websocat for WebSocket testing: websocat wss://endpoint"
echo ""
