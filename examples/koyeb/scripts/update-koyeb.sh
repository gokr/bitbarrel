#!/bin/bash
set -e

# BitBarrel Update/Redeploy Script for Koyeb
# Updates an existing BitBarrel deployment with new configuration or image

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
GRAY='\033[0;37m'
NC='\033[0m'

APP_NAME=""
IMAGE=""
FORCE=false
SKIP_BUILD=false

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         BitBarrel Koyeb Update Script                        ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --name)
            APP_NAME="$2"
            shift 2
            ;;
        --image)
            IMAGE="$2"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo
            echo "Update/Redeploy an existing BitBarrel deployment on Koyeb"
            echo
            echo "Options:"
            echo "  --name NAME          Application name (required if .env.koyeb not found)"
            echo "  --image IMAGE        New Docker image to use"
            echo "  --force              Skip confirmation prompts"
            echo "  --skip-build         Skip Docker build (use existing image)"
            echo "  --help               Show this help message"
            echo
            echo "Examples:"
            echo "  # Update with new image"
            echo "  $0 --name my-bitbarrel --image ghcr.io/gokr/bitbarrel:v1.2.0"
            echo
            echo "  # Redeploy with latest image"
            echo "  $0 --name my-bitbarrel"
            echo
            echo "  # Update from configuration file"
            echo "  $0"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Load configuration from file if available
if [[ -f ".env.koyeb" ]]; then
    echo -e "${GREEN}✓${NC} Loading configuration from .env.koyeb"
    source ".env.koyeb"
fi

# Check prerequisites
echo -e "${CYAN}Checking prerequisites...${NC}"

if ! command -v koyeb &> /dev/null; then
    echo -e "${RED}✗ Koyeb CLI not found${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC} Koyeb CLI found"

# Check if authenticated (works with both user and organization tokens)
echo -e "${GRAY}Verifying authentication...${NC}"
if ! koyeb apps list &> /dev/null; then
    if ! koyeb organizations list &> /dev/null; then
        echo -e "${RED}✗ Not logged in to Koyeb or invalid token${NC}"
        echo
        echo "Please login first:"
        echo "  koyeb login"
        echo

        # Show debugging information
        echo -e "${YELLOW}Debugging information:${NC}"
        echo -e "${GRAY}Checking koyeb config file...${NC}"
        if [[ -f "$HOME/.koyeb.yaml" ]]; then
            echo -e "${GREEN}✓${NC} Found config file at $HOME/.koyeb.yaml"
            # Check if file has content
            if [[ -s "$HOME/.koyeb.yaml" ]]; then
                echo -e "${GRAY}File size: $(wc -c < $HOME/.koyeb.yaml) bytes${NC}"
            else
                echo -e "${YELLOW}⚠ Config file is empty${NC}"
            fi
        else
            echo -e "${RED}✗${NC} Config file not found at $HOME/.koyeb.yaml"
            echo -e "${YELLOW}Run 'koyeb login' to create it${NC}"
        fi

        echo -e "${GRAY}Trying koyeb commands with verbose output...${NC}"
        echo -e "${GRAY}Attempting: koyeb apps list${NC}"
        koyeb apps list 2>&1 || true

        exit 1
    fi
fi
echo -e "${GREEN}✓${NC} Authenticated with Koyeb"

# Check for Docker if building
if [[ "$SKIP_BUILD" = false ]] && [[ -n "$IMAGE" ]] && echo "$IMAGE" | grep -q "/"; then
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}✗ Docker not found but needed for custom image${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓${NC} Docker found"
fi

# Get app name if not provided
if [[ -z "$APP_NAME" ]]; then
    echo -e "${RED}✗ Application name is required${NC}"
    echo
    echo "Please provide --name or ensure .env.koyeb exists with APP_NAME"
    exit 1
fi

# Verify app exists
echo -e "${CYAN}Checking if app '${APP_NAME}' exists...${NC}"
if ! koyeb app describe "$APP_NAME" &> /dev/null; then
    echo -e "${RED}✗ App '${APP_NAME}' not found${NC}"
    echo
    echo "Available apps:"
    koyeb app list
    exit 1
fi
echo -e "${GREEN}✓${NC} App '${APP_NAME}' found"

# Get current service info
echo -e "${CYAN}Getting current service information...${NC}"
SERVICE_INFO=$(koyeb service describe "${APP_NAME}/${APP_NAME}" --output json 2>/dev/null || true)

if [[ -z "$SERVICE_INFO" ]]; then
    echo -e "${RED}✗ Service '${APP_NAME}' not found in app '${APP_NAME}'${NC}"
    exit 1
fi

CURRENT_IMAGE=$(echo "$SERVICE_INFO" | grep -o '"image":"[^"]*"' | cut -d'"' -f4 | cut -d: -f1)
CURRENT_TAG=$(echo "$SERVICE_INFO" | grep -o '"image":"[^"]*"' | cut -d'"' -f4 | cut -d: -f2-)
CURRENT_STATUS=$(echo "$SERVICE_INFO" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)

# Helper function for status colors
status_color() {
    case $1 in
        "HEALTHY") echo -e "$GREEN" ;;
        "DEPLOYING") echo -e "$CYAN" ;;
        "UNHEALTHY"|"UNHEALTHY_TRANSIENT") echo -e "$RED" ;;
        *) echo -e "$YELLOW" ;;
    esac
}

echo -e "${GREEN}✓${NC} Current service information retrieved"
echo

# Determine new image
if [[ -z "$IMAGE" ]]; then
    # If no image specified, check if we should build or use existing
    if [[ "$SKIP_BUILD" = true ]]; then
        IMAGE="${CURRENT_IMAGE}:${CURRENT_TAG}"
        echo -e "${YELLOW}Using existing image: ${IMAGE}${NC}"
    else
n        # Default to latest
        IMAGE="ghcr.io/gokr/bitbarrel:latest"
        echo -e "${YELLOW}Using latest image: ${IMAGE}${NC}"
    fi
else
    echo -e "${GREEN}✓${NC} Using specified image: ${IMAGE}"
fi

# Check if this is a custom image that needs building
if echo "$IMAGE" | grep -q "/" && [[ "$SKIP_BUILD" = false ]]; then
    if [[ "$IMAGE" == *":latest"* ]] || [[ ! "$IMAGE" =~ .*:.* ]]; then
        echo -e "${YELLOW}Note: Custom image detected. Building may be required.${NC}"
    fi
fi

echo
echo -e "${BLUE}Update Summary:${NC}"
echo -e "  App Name:        ${GREEN}${APP_NAME}${NC}"
echo -e "  Current Image:   ${YELLOW}${CURRENT_IMAGE}:${CURRENT_TAG}${NC}"
echo -e "  New Image:       ${GREEN}${IMAGE}${NC}"
echo -e "  Current Status:  $(status_color $CURRENT_STATUS)${CURRENT_STATUS}${NC}"
echo

# Confirm update
if [[ "$FORCE" != true ]]; then
    read -p "Proceed with update? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Update cancelled.${NC}"
        exit 0
    fi
fi

# Trigger redeployment
echo -e "${CYAN}Triggering redeployment...${NC}"

if [[ "$IMAGE" == "${CURRENT_IMAGE}:${CURRENT_TAG}" ]] && [[ "$SKIP_BUILD" = true ]]; then
    # Just redeploy with same image (force restart)
    koyeb service redeploy "${APP_NAME}/${APP_NAME}"
else
    # Update with new image
    koyeb service update "${APP_NAME}/${APP_NAME}" \
        --image "$IMAGE"
fi

echo -e "${GREEN}✓${NC} Redeployment triggered"
echo

# Wait for update to start
sleep 5

# Monitor deployment
echo -e "${CYAN}Monitoring deployment (press Ctrl+C to stop)...${NC}"
echo -e "${YELLOW}Note: Deployment may take 2-5 minutes${NC}"

# Show logs in background
koyeb service logs "${APP_NAME}/${APP_NAME}" --tail 100 --follow &
LOGS_PID=$!

# Wait for service to be healthy
MAX_ATTEMPTS=30
ATTEMPT=0

trap "kill $LOGS_PID 2>/dev/null" EXIT

while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
    STATUS=$(koyeb service describe "${APP_NAME}/${APP_NAME}" --output json 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "checking")

    case $STATUS in
        "HEALTHY")
            echo -e "\n${GREEN}✓${NC} Service is healthy!"
            break
            ;;
        "DEPLOYING")
            printf "."
            sleep 10
            ((ATTEMPT++))
            ;;
        "UNHEALTHY"|"UNHEALTHY_TRANSIENT")
            echo -e "\n${RED}✗ Service is unhealthy${NC}"
            echo
            echo "Check logs for errors:"
            echo "  koyeb service logs ${APP_NAME}/${APP_NAME}"
            exit 1
            ;;
        *)
            printf "."
            sleep 10
            ((ATTEMPT++))
            ;;
    esac
done

kill $LOGS_PID 2>/dev/null || true

echo

# Show final status
if [[ "$STATUS" == "HEALTHY" ]]; then
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                   Update Successful!                         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo

    # Get public URL if available
    PUBLIC_URL=$(koyeb service describe "${APP_NAME}/${APP_NAME}" --output json 2>/dev/null | grep -o '"public_url":"[^"]*"' | cut -d'"' -f4 || echo "")

    if [[ -n "$PUBLIC_URL" ]]; then
        echo -e "${BLUE}Your updated BitBarrel instance:${NC}"
        echo -e "  Public URL: ${GREEN}${PUBLIC_URL}${NC}"
        echo
    fi

    echo -e "${BLUE}Deployment details:${NC}"
    echo -e "  App Name:      ${GREEN}${APP_NAME}${NC}"
    echo -e "  New Image:     ${GREEN}${IMAGE}${NC}"
    echo -e "  Status:        ${GREEN}${STATUS}${NC}"
    echo
else
    echo -e "${YELLOW}Update may still be in progress.${NC}"
    echo -e "Check status with: koyeb service describe ${APP_NAME}/${APP_NAME}"
fi

echo -e "${BLUE}Management commands:${NC}"
echo -e "  View logs:     ${GREEN}koyeb service logs ${APP_NAME}/${APP_NAME}${NC}"
echo -e "  Check status:  ${GREEN}koyeb service describe ${APP_NAME}/${APP_NAME}${NC}"
echo -e "  View app:      ${GREEN}koyeb app describe ${APP_NAME}${NC}"
echo

echo -e "${GREEN}Update completed!${NC}"
echo
