#!/bin/bash

# BitBarrel Koyeb Connection Test Script
# Tests connectivity and basic operations on a Koyeb-deployed BitBarrel instance

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
NC='\033[0m'

ENDPOINT=""
AUTH_TOKEN=""
USE_HTTPS=true

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         BitBarrel Koyeb Connection Test                      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --endpoint)
            ENDPOINT="$2"
            shift 2
            ;;
        --token)
            AUTH_TOKEN="$2"
            shift 2
            ;;
        --http)
            USE_HTTPS=false
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo
            echo "Test BitBarrel deployment on Koyeb"
            echo
            echo "Options:"
            echo "  --endpoint URL       BitBarrel endpoint (required)"
            echo "  --token TOKEN        JWT token (if authentication enabled)"
            echo "  --http               Use HTTP instead of HTTPS"
            echo "  --help               Show this help message"
            echo
            echo "Examples:"
            echo "  $0 --endpoint https://my-bitbarrel.koyeb.app"
            echo "  $0 --endpoint https://my-bitbarrel.koyeb.app --token YOUR_TOKEN"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Prompt for endpoint if not provided
if [[ -z "$ENDPOINT" ]]; then
    read -p "Enter your BitBarrel endpoint (e.g., https://my-bitbarrel.koyeb.app): " ENDPOINT
fi

# Validate endpoint
if [[ -z "$ENDPOINT" ]]; then
    echo -e "${RED}Error: Endpoint is required${NC}"
    exit 1
fi

# Build base URL
PROTOCOL="https"
if [[ "$USE_HTTPS" == false ]]; then
    PROTOCOL="http"
fi

# Remove protocol if included in endpoint
BASE_URL="$ENDPOINT"
if [[ "$ENDPOINT" =~ ^https?:// ]]; then
    BASE_URL=$(echo "$ENDPOINT" | sed 's/^https\?:\/\///')
    PROTOCOL=$(echo "$ENDPOINT" | sed 's/:.*//')
fi

API_URL="${PROTOCOL}://${BASE_URL}/api"
WS_URL=$(echo "$BASE_URL" | sed 's/^/wss:\/\//; s/^wss:wss:/wss:/')
if [[ "$USE_HTTPS" == false ]]; then
    WS_URL=$(echo "$BASE_URL" | sed 's/^/ws:\/\//; s/^ws:ws:/ws:/')
fi

echo -e "${WHITE}Testing endpoint:${NC} ${BLUE}$ENDPOINT${NC}"
echo -e "${WHITE}API URL:${NC} ${BLUE}$API_URL${NC}"
echo -e "${WHITE}WebSocket URL:${NC} ${BLUE}$WS_URL${NC}"
echo

# Check if we have required tools
check_tool() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}✗ $1 not found${NC}"
        return 1
    else
        echo -e "${GREEN}✓${NC} $1 found"
        return 0
    fi
}

echo -e "${CYAN}Checking prerequisites...${NC}"
check_tool curl
check_tool jq || echo -e "${YELLOW}  jq optional, for better output formatting${NC}"

# Optional tools
HAVE_WEBSOCAT=false
if check_tool websocat &> /dev/null; then
    HAVE_WEBSOCAT=true
fi

echo

# Function to make API call
api_call() {
    local method="$1"
    local url="$2"
    local data="$3"

    local headers=()
    headers+=(-H "Content-Type: application/json")
    headers+=(-H "Accept: application/json")

    if [[ -n "$AUTH_TOKEN" ]]; then
        headers+=(-H "Authorization: Bearer $AUTH_TOKEN")
    fi

    if [[ -n "$data" ]]; then
        curl -s -X "$method" "${headers[@]}" -d "$data" "$url"
    else
        curl -s -X "$method" "${headers[@]}" "$url"
    fi
}

# Test counter
tests_run=0
tests_passed=0

# Test function
run_test() {
    local test_name="$1"
    local test_command="$2"

    ((tests_run++))
    echo -e "${CYAN}Test $tests_run:${NC} $test_name"

    if eval "$test_command" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ PASSED${NC}"
        ((tests_passed++))
        return 0
    else
        echo -e "${RED}✗ FAILED${NC}"
        return 1
    fi
}

# Test API connection
echo -e "${WHITE}Running tests...${NC}"
echo

# Test 1: API Health Check
echo -e "${CYAN}Test 1:${NC} API health check"
RESPONSE=$(api_call "GET" "$API_URL/info" 2>&1)
if [[ $? -eq 0 ]] && [[ -n "$RESPONSE" ]]; then
    if [[ "$RESPONSE" == *"version"* ]] || [[ "$RESPONSE" == *"BitBarrel"* ]]; then
        echo -e "${GREEN}✓ PASSED${NC}"
        echo -e "  Response: ${GREEN}$(echo "$RESPONSE" | head -c 100)...${NC}"
        ((tests_passed++))
    else
        echo -e "${RED}✗ FAILED${NC}"
        echo -e "  Response: ${RED}$RESPONSE${NC}"
    fi
else
    echo -e "${RED}✗ FAILED${NC}"
    echo -e "  Error: Could not connect to API"
fi
((tests_run++))
echo

# Test 2: Set a value
echo -e "${CYAN}Test 2:${NC} Set a key-value pair"
TEST_KEY="test:key:$RANDOM"
TEST_VALUE="Hello from Koyeb at $(date)"
RESPONSE=$(api_call "POST" "$API_URL/set" "{\"key\":\"$TEST_KEY\",\"value\":\"$TEST_VALUE\"}" 2>&1)
if [[ $? -eq 0 ]] && [[ "$RESPONSE" == *"{\"error\":null}"* ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    ((tests_passed++))
else
    echo -e "${RED}✗ FAILED${NC}"
    if [[ -n "$RESPONSE" ]]; then
        echo -e "  Response: ${RED}$RESPONSE${NC}"
    fi
fi
((tests_run++))
echo

# Test 3: Get the value
echo -e "${CYAN}Test 3:${NC} Get the key-value pair"
RESPONSE=$(api_call "GET" "$API_URL/get/$TEST_KEY" 2>&1)
if [[ $? -eq 0 ]] && [[ "$RESPONSE" == *"$TEST_VALUE"* ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    echo -e "  Value retrieved: ${GREEN}$TEST_VALUE${NC}"
    ((tests_passed++))
else
    echo -e "${RED}✗ FAILED${NC}"
    if [[ -n "$RESPONSE" ]]; then
        echo -e "  Response: ${RED}$RESPONSE${NC}"
    fi
fi
((tests_run++))
echo

# Test 4: Update the value
echo -e "${CYAN}Test 4:${NC} Update the key-value pair"
UPDATED_VALUE="Updated at $(date)"
RESPONSE=$(api_call "POST" "$API_URL/set" "{\"key\":\"$TEST_KEY\",\"value\":\"$UPDATED_VALUE\"}" 2>&1)
if [[ $? -eq 0 ]] && [[ "$RESPONSE" == *"{\"error\":null}"* ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    ((tests_passed++))
else
    echo -e "${RED}✗ FAILED${NC}"
fi
((tests_run++))
echo

# Test 5: Delete the key
echo -e "${CYAN}Test 5:${NC} Delete the key"
RESPONSE=$(api_call "DELETE" "$API_URL/delete/$TEST_KEY" 2>&1)
if [[ $? -eq 0 ]] && [[ "$RESPONSE" == *"{\"error\":null}"* ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    ((tests_passed++))
else
    echo -e "${RED}✗ FAILED${NC}"
fi
((tests_run++))
echo

# Test 6: Verify deletion
echo -e "${CYAN}Test 6:${NC} Verify key was deleted"
RESPONSE=$(api_call "GET" "$API_URL/get/$TEST_KEY" 2>&1)
if [[ $? -eq 0 ]] && [[ "$RESPONSE" == *"null"* ]]; then
    echo -e "${GREEN}✓ PASSED${NC}"
    ((tests_passed++))
else
    echo -e "${RED}✗ FAILED${NC}"
    echo -e "  Expected null, got: ${RED}$RESPONSE${NC}"
fi
((tests_run++))
echo

# Test 7: WebSocket connection (if websocat is available)
if [[ "$HAVE_WEBSOCAT" == true ]]; then
    echo -e "${CYAN}Test 7:${NC} WebSocket connection"

    # Prepare auth header if token is provided
    AUTH_HEADER=""
    if [[ -n "$AUTH_TOKEN" ]]; then
        AUTH_HEADER="-H 'Authorization: Bearer $AUTH_TOKEN'"
    fi

    # Test WebSocket connection
    TEST_RESULT=$(echo '{"jsonrpc":"2.0","method":"info","id":1}' | websocat $AUTH_HEADER "$WS_URL" 2>&1 | head -1)

    if [[ $? -eq 0 ]] && [[ -n "$TEST_RESULT" ]]; then
        echo -e "${GREEN}✓ PASSED${NC}"
        echo -e "  WebSocket is working"
        ((tests_passed++))
    else
        echo -e "${YELLOW}✗ SKIPPED${NC}"
        echo -e "  WebSocket test skipped (websocat response: $TEST_RESULT)"
    fi
else
    echo -e "${CYAN}Test 7:${NC} WebSocket connection"
    echo -e "${YELLOW}✗ SKIPPED${NC} (websocat not available)"
    echo -e "  Install websocat to test WebSocket: https://github.com/vi/websocat"
fi
((tests_run++))
echo

# Test results summary
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                      Test Summary                            ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo

if [[ $tests_passed -eq $tests_run ]]; then
    echo -e "${GREEN}All tests passed! (${tests_passed}/${tests_run})${NC}"
    echo
    echo -e "${GREEN}✓${NC} Your BitBarrel instance is working correctly"
    exit 0
else
    echo -e "${YELLOW}Some tests failed (${tests_passed}/${tests_run})${NC}"
    echo
    if [[ $tests_passed -eq 0 ]]; then
        echo -e "${RED}✗${NC} Cannot connect to BitBarrel instance"
        echo
        echo -e "${YELLOW}Troubleshooting:${NC}"
        echo -e "  1. Check the endpoint URL: ${WHITE}$ENDPOINT${NC}"
        echo -e "  2. Verify the service is running: koyeb service describe $BASE_URL"
        echo -e "  3. Check service logs: koyeb service logs $BASE_URL"
        echo -e "  4. Verify authentication: Check if JWT token is required"
    else
        echo -e "${YELLOW}Partial success - some operations are working${NC}"
    fi
    exit 1
fi
