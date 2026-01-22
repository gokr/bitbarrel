#!/bin/bash
set -e

# One-Click BitBarrel Deployment to Koyeb
# This script deploys BitBarrel to Koyeb with persistent storage

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
GRAY='\033[0;37m'
NC='\033[0m'

APP_NAME=""
IMAGE="ghcr.io/gokr/bitbarrel:latest"
PRIVATE=false
VOLUME_SIZE=10
REGION="fra"  # Frankfurt (good default for EU)

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         BitBarrel Koyeb Deployment Script                    ║${NC}"
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
        --private)
            PRIVATE=true
            shift
            ;;
        --volume-size)
            VOLUME_SIZE="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo
            echo "Options:"
            echo "  --name NAME          Application name (default: bitbarrel-YYYYMMDDHHMMSS)"
            echo "  --image IMAGE        Docker image to use (default: ghcr.io/gokr/bitbarrel:latest)"
            echo "  --private            Deploy as private (no public URL)"
            echo "  --volume-size SIZE   Volume size in GB (default: 10)"
            echo "  --region REGION      Deployment region: fra, was, par, lhr (default: fra)"
            echo "  --help               Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check prerequisites
echo -e "${CYAN}Checking prerequisites...${NC}"

if ! command -v koyeb &> /dev/null; then
    echo -e "${RED}✗ Koyeb CLI not found${NC}"
    echo
    echo "Please install Koyeb CLI first:"
    echo "  curl -sSL https://raw.githubusercontent.com/gokr/bitbarrel/main/scripts/install-koyeb-cli.sh | bash"
    echo
    exit 1
fi
echo -e "${GREEN}✓${NC} Koyeb CLI found"

# Check if authenticated (works with both user and organization tokens)
echo -e "${GRAY}Verifying authentication...${NC}"
if ! koyeb apps list &> /dev/null; then
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
        echo -e "${GRAY}File permissions: $(ls -la $HOME/.koyeb.yaml | awk '{print $1}')${NC}"
    else
        echo -e "${RED}✗${NC} Config file not found at $HOME/.koyeb.yaml"
        echo -e "${YELLOW}Run 'koyeb login' to create it${NC}"
    fi

    echo -e "${GRAY}Trying koyeb commands with verbose output...${NC}"
    echo -e "${GRAY}Attempting: koyeb apps list${NC}"
    koyeb apps list 2>&1 || true

    exit 1
fi
echo -e "${GREEN}✓${NC} Authenticated with Koyeb"

# Generate default app name if not provided
if [[ -z "$APP_NAME" ]]; then
    TIMESTAMP=$(date +%Y%m%d%H%M%S)
    APP_NAME="bitbarrel-${TIMESTAMP}"
fi

echo
echo -e "${BLUE}Deployment Configuration:${NC}"
echo -e "  App name:     ${GREEN}${APP_NAME}${NC}"
echo -e "  Image:        ${GREEN}${IMAGE}${NC}"
echo -e "  Region:       ${GREEN}${REGION}${NC}"
echo -e "  Volume size:  ${GREEN}${VOLUME_SIZE}GB${NC}"
echo -e "  Public URL:   ${GREEN}$([ "$PRIVATE" = true ] && echo "No (private)" || echo "Yes")${NC}"
echo

# Check if app already exists
echo -e "${CYAN}Checking if app '${APP_NAME}' already exists...${NC}"
if koyeb app describe "$APP_NAME" &> /dev/null; then
    echo -e "${RED}✗ App '${APP_NAME}' already exists${NC}"
    echo
    echo "Options:"
    echo "  1. Use a different name with --name"
    echo "  2. Delete the existing app: koyeb app delete ${APP_NAME}"
    echo "  3. Update the existing app: ./scripts/update-koyeb.sh --name ${APP_NAME}"
    echo
    exit 1
fi
echo -e "${GREEN}✓${NC} App name is available"

# Generate JWT secret if not already set
if [[ -z "$BITBARREL_JWT_SECRET" ]]; then
    echo -e "${CYAN}Generating JWT secret...${NC}"
    JWT_SECRET=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)
    export BITBARREL_JWT_SECRET="$JWT_SECRET"
    echo -e "${GREEN}✓${NC} JWT secret generated"
else
    echo -e "${GREEN}✓${NC} Using existing JWT secret"
fi

# Create the app
echo
echo -e "${CYAN}Creating Koyeb app '${APP_NAME}'...${NC}"
koyeb app create "$APP_NAME"

# Create volume
echo
echo -e "${CYAN}Creating volume '$APP_NAME-data'...${NC}"
koyeb volumes create "${APP_NAME}-data" \
    --region "$REGION" \
    --size "$VOLUME_SIZE"
echo -e "${GREEN}✓${NC} Volume created"

# Create the service
echo
echo -e "${CYAN}Creating BitBarrel service...${NC}"

# Build the koyeb service create command
SERVICE_CMD="koyeb service create ${APP_NAME}/${APP_NAME} \
    --app ${APP_NAME} \
    --image ${IMAGE} \
    --port 8080:http \
    --route /:8080 \
    --regions ${REGION} \
    --volumes ${APP_NAME}-data:/data \
    --env BITBARREL_JWT_SECRET=${BITBARREL_JWT_SECRET} \
    --env BITBARREL_HOST=0.0.0.0 \
    --env BITBARREL_PORT=8080 \
    --env BITBARREL_DATA_DIR=/data"

# Add private flag if requested
if [[ "$PRIVATE" = true ]]; then
    SERVICE_CMD="${SERVICE_CMD} \
    --private"
fi

# Execute the command
eval $SERVICE_CMD

# Wait for deployment to start
echo
echo -e "${CYAN}Waiting for deployment to start...${NC}"
sleep 5

# Show deployment status
echo
echo -e "${CYAN}Deployment Status:${NC}"
koyeb service describe "${APP_NAME}/${APP_NAME}" --output json | grep -E '"status"|"messages"|"deployment_id"' || true

echo
echo -e "${CYAN}Monitoring deployment (press Ctrl+C to stop)...${NC}"
echo -e "${YELLOW}Note: Initial deployment may take 2-5 minutes${NC}"

# Show logs in background
koyeb service logs "${APP_NAME}/${APP_NAME}" --tail 100 --follow &
LOGS_PID=$!

# Wait for service to be healthy
trap "kill $LOGS_PID 2>/dev/null" EXIT

# Check deployment status
echo
echo -e "${CYAN}Checking deployment status...${NC}"
MAX_ATTEMPTS=30
ATTEMPT=0

while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
    STATUS=$(koyeb service describe "${APP_NAME}/${APP_NAME}" --output json 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "checking")

    case $STATUS in
        "HEALTHY")
            echo -e "${GREEN}✓${NC} Service is healthy!"
            break
            ;;
        "UNHEALTHY"|"UNHEALTHY_TRANSIENT")
            echo -e "${RED}✗ Service is unhealthy${NC}"
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

# Get public URL if available
if [[ "$PRIVATE" != true ]]; then
    PUBLIC_URL=$(koyeb service describe "${APP_NAME}/${APP_NAME}" --output json 2>/dev/null | grep -o '"public_url":"[^"]*"' | cut -d'"' -f4 || echo "")

    if [[ -n "$PUBLIC_URL" ]]; then
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                 Deployment Successful!                       ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo
        echo -e "${BLUE}Your BitBarrel instance is ready:${NC}"
        echo -e "  Public URL: ${GREEN}${PUBLIC_URL}${NC}"
        echo
        echo -e "${BLUE}Access points:${NC}"
        echo -e "  WebSocket: ${GREEN}${PUBLIC_URL}${NC}"
        echo -e "  HTTP API:  ${GREEN}${PUBLIC_URL}/api${NC}"
        echo -e "  WebAdmin:  ${GREEN}${PUBLIC_URL}/webadmin${NC}"
        echo
    fi
else
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Private Deployment Successful!                  ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${YELLOW}Note: This is a private deployment (no public URL)${NC}"
    echo
fi

echo -e "${BLUE}Configuration:${NC}"
echo -e "  App name:      ${GREEN}${APP_NAME}${NC}"
echo -e "  Region:        ${GREEN}${REGION}${NC}"
echo -e "  Volume size:   ${GREEN}${VOLUME_SIZE}GB${NC}"
echo -e "  Image:         ${GREEN}${IMAGE}${NC}"
echo

echo -e "${BLUE}Management commands:${NC}"
echo -e "  View logs:       ${GREEN}koyeb service logs ${APP_NAME}/${APP_NAME}${NC}"
echo -e "  Check status:    ${GREEN}koyeb service describe ${APP_NAME}/${APP_NAME}${NC}"
echo -e "  View app:        ${GREEN}koyeb app describe ${APP_NAME}${NC}"
echo -e "  Delete app:      ${GREEN}koyeb app delete ${APP_NAME}${NC}"
echo

echo -e "${BLUE}To update your deployment:${NC}"
echo -e "  ${GREEN}./scripts/update-koyeb.sh --name ${APP_NAME}${NC}"
echo

echo -e "${YELLOW}Your JWT secret (save this!):${NC}"
echo -e "  ${BITBARREL_JWT_SECRET}"
echo

echo -e "${CYAN}Next steps:${NC}"
echo "  1. Test your deployment with the included scripts"
echo "  2. Configure client libraries with the public URL"
echo "  3. Set up monitoring and backup strategies"
echo
