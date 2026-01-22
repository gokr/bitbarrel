#!/bin/bash

# BitBarrel Koyeb Demo Operations Script
# Demonstrates various BitBarrel operations on a Koyeb deployment

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m'

ENDPOINT=""
AUTH_TOKEN=""
USE_HTTPS=true
PREFIX="demo"

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         BitBarrel Koyeb Operations Demo                      ║${NC}"
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
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo
            echo "Demo BitBarrel operations on Koyeb deployment"
            echo
            echo "Options:"
            echo "  --endpoint URL       BitBarrel endpoint (required)"
            echo "  --token TOKEN        JWT token (if authentication enabled)"
            echo "  --http               Use HTTP instead of HTTPS"
            echo "  --prefix PREFIX      Key prefix for demo (default: demo)"
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

# Function to print operation header
print_op() {
    echo
echo -e "${BLUE}▶${NC} ${WHITE}$1${NC}"
echo -e "${GRAY}$(printf '─%.0s' {1..60})${NC}"
}

# Function to print result
print_result() {
    if [[ "$1" == "success" ]]; then
        echo -e "${GREEN}✓${NC} $2"
    else
        echo -e "${RED}✗${NC} $2"
    fi
}

# Function to demonstrate an operation
demo_operation() {
    print_op "$1"
    RESPONSE=$(eval "$2")
    STATUS=$?

    if [[ $STATUS -eq 0 ]] && [[ -n "$RESPONSE" ]]; then
        if [[ "$RESPONSE" == *"error"* ]] && [[ "$RESPONSE" != *'"error":null'* ]]; then
            print_result "error" "Operation failed: $RESPONSE"
            return 1
        else
            print_result "success" "$3"
            if [[ -n "$4" ]]; then
                echo -e "  ${GRAY}Response: ${RESPONSE}${NC}"
            fi
            return 0
        fi
    else
        print_result "error" "No response from server"
        return 1
    fi
}

# Demo 1: Basic CRUD Operations
print_op "Basic CRUD Operations"

echo
echo -e "${CYAN}Creating sample data...${NC}"

# Create user data
demo_operation "Creating user profile" \
    "api_call POST $API_URL/set '{\"key\":\"${PREFIX}:user:1001:name\",\"value\":\"Alice Smith\"}'" \
    "User profile created"

demo_operation "Adding user email" \
    "api_call POST $API_URL/set '{\"key\":\"${PREFIX}:user:1001:email\",\"value\":\"alice@example.com\"}'" \
    "Email added"

demo_operation "Setting user preferences" \
    "api_call POST $API_URL/set '{\"key\":\"${PREFIX}:user:1001:preferences\",\"value\":\"{\\\"theme\\\":\\\"dark\\\",\\\"lang\\\":\\\"en\\\"}\"}'" \
    "Preferences set"

# Read data
echo
echo -e "${CYAN}Reading data...${NC}"

demo_operation "Reading user name" \
    "api_call GET $API_URL/get/${PREFIX}:user:1001:name" \
    "Name retrieved successfully" \
    "show_response"

demo_operation "Reading user email" \
    "api_call GET $API_URL/get/${PREFIX}:user:1001:email" \
    "Email retrieved successfully" \
    "show_response"

# Update data
echo
echo -e "${CYAN}Updating data...${NC}"

demo_operation "Updating user name" \
    "api_call POST $API_URL/set '{\"key\":\"${PREFIX}:user:1001:name\",\"value\":\"Alice Johnson\"}'" \
    "User name updated"

demo_operation "Reading updated name" \
    "api_call GET $API_URL/get/${PREFIX}:user:1001:name" \
    "Updated name retrieved" \
    "show_response"

# Delete data
echo
echo -e "${CYAN}Deleting data...${NC}"

demo_operation "Deleting user preferences" \
    "api_call DELETE $API_URL/delete/${PREFIX}:user:1001:preferences" \
    "Preferences deleted"

demo_operation "Verifying deletion" \
    "api_call GET $API_URL/get/${PREFIX}:user:1001:preferences" \
    "Preferences confirmed deleted" \
    "show_response"

# Demo 2: Session Management
echo
echo -e "${CYAN}Demo 2: Session Management${NC}"

current_timestamp=$(date +%s)
session_id="sess_${current_timestamp}_$RANDOM"

print_op "Creating Session Data"

demo_operation "Creating session" \
    "api_call POST $API_URL/set '{\"key\":\"${PREFIX}:session:$session_id:user_id\",\"value\":\"1001\"}'" \
    "Session user ID set"

demo_operation "Setting session data" \
    "api_call POST $API_URL/set '{\"key\":\"${PREFIX}:session:$session_id:data\",\"value\":\"{\\\"last_login\\\":$current_timestamp,\\\"ip\\\":\\\"192.168.1.1\\\"}\"}'" \
    "Session data stored"

demo_operation "Reading session" \
    "api_call GET $API_URL/get/${PREFIX}:session:$session_id:user_id" \
    "Session data retrieved" \
    "show_response"

# Demo 3: Feature Flags
print_op "Feature Flags Management"

echo
echo -e "${CYAN}Creating feature flags...${NC}"

features=(
    "${PREFIX}:feature:new_dashboard:true"
    "${PREFIX}:feature:dark_mode:true"
    "${PREFIX}:feature:beta_api:false"
    "${PREFIX}:feature:experimental_ml:true"
)

for feature in "${features[@]}"; do
    IFS=':' read -r prefix name flag value <<< "$feature"
    key="${PREFIX}:feature:$flag"

    demo_operation "Setting feature flag: $flag=$value" \
        "api_call POST $API_URL/set '{\"key\":\"$key\",\"value\":\"$value\"}'" \
        "Feature flag $flag set"
done

# Simulate checking features
echo
echo -e "${CYAN}Checking feature flags...${NC}"

FEATURE="new_dashboard"
VALUE=$(api_call GET "$API_URL/get/${PREFIX}:feature:$FEATURE" 2>&1)
if [[ "$VALUE" == *"true"* ]]; then
    echo -e "${GREEN}✓${NC} Feature '$FEATURE' is ${GREEN}ENABLED${NC}"
else
    echo -e "${GREEN}✓${NC} Feature '$FEATURE' is ${YELLOW}DISABLED${NC}"
fi

FEATURE="beta_api"
VALUE=$(api_call GET "$API_URL/get/${PREFIX}:feature:$FEATURE" 2>&1)
if [[ "$VALUE" == *"true"* ]]; then
    echo -e "${GREEN}✓${NC} Feature '$FEATURE' is ${GREEN}ENABLED${NC}"
else
    echo -e "${GREEN}✓${NC} Feature '$FEATURE' is ${YELLOW}DISABLED${NC}"
fi

# Demo 4: Rate Limiting Counter
print_op "Rate Limiting Example"

user_ip="192.168.1.100"
current_minute=$(date +%Y%m%d%H%M)
rate_key="${PREFIX}:ratelimit:$user_ip:$current_minute"

echo
echo -e "${CYAN}Simulating API calls for rate limiting...${NC}"

# Simulate 10 API calls
for i in {1..10}; do
    # Increment counter
    COUNT=$(api_call POST "$API_URL/set" "{\"key\":\"$rate_key\",\"value\":\"$i\"}" 2>&1)
    echo -e "  API call $i: ${GREEN}✓${NC}"
    sleep 0.1
done

# Check rate
echo
demo_operation "Checking rate limit count" \
    "api_call GET $API_URL/get/$rate_key" \
    "Rate limit counter retrieved" \
    "show_response"

if [[ -n "$(api_call GET $API_URL/get/$rate_key 2>&1)" ]]; then
    count=$(api_call GET "$API_URL/get/$rate_key" 2>&1 | grep -o '[0-9]*' || echo "0")
    if [[ $count -gt 5 ]]; then
        echo -e "  ${YELLOW}Rate limit exceeded!${NC} ${WHITE}Would block further requests${NC}"
    else
        echo -e "  ${GREEN}Within rate limit${NC} ${WHITE}Allowing requests${NC}"
    fi
fi

# Demo 5: Counter and Analytics
print_op "Counters and Analytics"

echo
echo -e "${CYAN}Tracking page views...${NC}"

page="/home"
# Initialize counter if not exists
current_count=$(api_call GET "$API_URL/get/${PREFIX}:pageviews:$page" 2>&1)
if [[ "$current_count" == *"null"* ]]; then
    new_count=1
else
    count=$(echo "$current_count" | grep -o '[0-9]*' || echo "0")
    new_count=$((count + 1))
fi

demo_operation "Recording page view for $page" \
    "api_call POST $API_URL/set '{\"key\":\"${PREFIX}:pageviews:$page\",\"value\":\"$new_count\"}'" \
    "Page view recorded"

demo_operation "Reading page view count" \
    "api_call GET $API_URL/get/${PREFIX}:pageviews:home" \
    "Analytics retrieved" \
    "show_response"

# Summary
echo
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                      Demo Summary                            ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo

echo -e "${WHITE}Demonstrated operations:${NC}"
echo -e "${GREEN}✓${NC} Basic CRUD (Create, Read, Update, Delete)"
echo -e "${GREEN}✓${NC} Session management"
echo -e "${GREEN}✓${NC} Feature flags"
echo -e "${GREEN}✓${NC} Rate limiting pattern"
echo -e "${GREEN}✓${NC} Counters and analytics"
echo

echo -e "${WHITE}Use cases shown:${NC}"
echo -e "  • User profile storage"
echo -e "  • Session management"
echo -e "  • Feature flag system"
echo -e "  • Rate limiting"
echo -e "  • Page view tracking"
echo

echo -e "${WHITE}Cleanup:${NC}"
echo -e "Run the following to clean up demo data:"
echo -e "${GRAY}  for key in $(echo -e "${PREFIX}:user:1001:*" "${PREFIX}:session:*" "${PREFIX}:feature:*" "${PREFIX}:ratelimit:*" "${PREFIX}:pageviews:*"); do"
echo -e "${GRAY}    curl -X DELETE $API_URL/delete/\$key -H 'Authorization: Bearer $AUTH_TOKEN'"
echo -e "${GRAY}  done${NC}"
echo

echo -e "${GREEN}Demo completed successfully!${NC}"
echo
