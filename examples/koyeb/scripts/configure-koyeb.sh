#!/bin/bash

# Interactive Configuration Helper for BitBarrel on Koyeb
# Guides users through setting up their BitBarrel deployment configuration

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
GRAY='\033[0;37m'
NC='\033[0m'

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         BitBarrel Koyeb Configuration Wizard                 ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo

# Configuration file
CONFIG_FILE=".env.koyeb"

# Default values
APP_NAME=""
REGION="fra"
VOLUME_SIZE=10
PRIVATE=false
ENABLE_AUTH=true
IMAGE="ghcr.io/gokr/bitbarrel:latest"
BITBARREL_JWT_SECRET=""
BITBARREL_ADMIN_TOKEN=""
BITBARREL_PORT=8080
BITBARREL_SYNC_INTERVAL=1000
BITBARREL_BUFFER_SIZE=65536

# Load existing configuration if available
if [[ -f "$CONFIG_FILE" ]]; then
    echo -e "${YELLOW}Found existing configuration file: $CONFIG_FILE${NC}"
    read -p "Load existing configuration? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        source "$CONFIG_FILE"
        echo -e "${GREEN}✓${NC} Configuration loaded"
        echo
    fi
fi

# App Name
echo -e "${BLUE}1. Application Name${NC}"
echo "This will be used as the Koyeb app name and service name."
read -p "Enter app name (default: bitbarrel-$(date +%Y%m%d%H%M%S)): " input
APP_NAME=${input:-"bitbarrel-$(date +%Y%m%d%H%M%S)"}
echo

# Region
echo -e "${BLUE}2. Deployment Region${NC}"
echo "Choose the region closest to your users:"
echo "  fra - Frankfurt, Germany (EU)"
echo "  was - Washington, US (East Coast)"
echo "  par - Paris, France (EU)"
echo "  lhr - London, UK"
read -p "Select region (default: fra): " input
REGION=${input:-fra}
case $REGION in
    fra|was|par|lhr) ;;
    *) echo -e "${YELLOW}Warning: Unknown region. Using fra.${NC}"; REGION="fra" ;;
esac
echo

# Volume Size
echo -e "${BLUE}3. Persistent Volume Size${NC}"
echo "Size of the persistent storage for your data (in GB)."
echo "Minimum: 1GB, Maximum: 2000GB"
read -p "Enter volume size in GB (default: 10): " input
VOLUME_SIZE=${input:-10}
if [[ ! "$VOLUME_SIZE" =~ ^[0-9]+$ ]] || [[ $VOLUME_SIZE -lt 1 ]] || [[ $VOLUME_SIZE -gt 2000 ]]; then
    echo -e "${YELLOW}Invalid volume size. Using default of 10GB.${NC}"
    VOLUME_SIZE=10
fi
echo

# Public/Private
echo -e "${BLUE}4. Public Access${NC}"
echo "Should your BitBarrel instance be accessible from the internet?"
echo "  Yes - Public URL will be created (recommended for tutorials)"
echo "  No  - Private deployment (requires service mesh or direct access)"
read -p "Make public? (Y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    PRIVATE=true
    echo -e "${YELLOW}Deployment will be private.${NC}"
else
    echo -e "${GREEN}Deployment will be public.${NC}"
fi
echo

# Authentication
echo -e "${BLUE}5. Authentication${NC}"
echo "Do you want to enable JWT authentication?"
echo "  Yes - Secure with JWT tokens (recommended for production)"
echo "  No  - No authentication (useful for testing)"
read -p "Enable authentication? (Y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    ENABLE_AUTH=false
    echo -e "${YELLOW}Authentication disabled.${NC}"
else
    echo -e "${GREEN}Authentication enabled.${NC}"
fi
echo

# Generate secrets if needed
if [[ "$ENABLE_AUTH" = true ]]; then
    echo -e "${CYAN}Generating secure tokens...${NC}"

    if [[ -z "$BITBARREL_JWT_SECRET" ]]; then
        BITBARREL_JWT_SECRET=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)
        echo -e "${GREEN}✓${NC} JWT secret generated"
    fi

    if [[ -z "$BITBARREL_ADMIN_TOKEN" ]]; then
        BITBARREL_ADMIN_TOKEN=$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | xxd -p)
        echo -e "${GREEN}✓${NC} Admin token generated"
    fi
fi

# Advanced Settings
echo -e "${BLUE}6. Advanced Settings${NC}"
read -p "Configure advanced settings? (y/N): " -n 1 -r
echo
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Docker Image
    echo -e "${CYAN}Docker Image:${NC}"
    read -p "  Image (default: ghcr.io/gokr/bitbarrel:latest): " input
    IMAGE=${input:-ghcr.io/gokr/bitbarrel:latest}
    echo

    # Port
    echo -e "${CYAN}BitBarrel Configuration:${NC}"
    read -p "  Server port (default: 8080): " input
    BITBARREL_PORT=${input:-8080}
    echo

    # Sync Interval
    read -p "  Sync interval in ms (default: 1000): " input
    BITBARREL_SYNC_INTERVAL=${input:-1000}
    echo

    # Buffer Size
    read -p "  Read buffer size in bytes (default: 65536): " input
    BITBARREL_BUFFER_SIZE=${input:-65536}
    echo
else
    echo -e "${YELLOW}Using default advanced settings.${NC}"
    echo
fi

# Review Configuration
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                     Configuration Summary                    ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${BLUE}Basic Settings:${NC}"
echo -e "  App Name:        ${GREEN}${APP_NAME}${NC}"
echo -e "  Region:          ${GREEN}${REGION}${NC}"
echo -e "  Volume Size:     ${GREEN}${VOLUME_SIZE}GB${NC}"
echo -e "  Public Access:   ${GREEN}$([ "$PRIVATE" = true ] && echo "No" || echo "Yes")${NC}"
echo -e "  Authentication:  ${GREEN}$([ "$ENABLE_AUTH" = true ] && echo "Enabled" || echo "Disabled")${NC}"
echo
echo -e "${BLUE}Docker Image:${NC}"
echo -e "  Image:           ${GREEN}${IMAGE}${NC}"
echo
echo -e "${BLUE}BitBarrel Settings:${NC}"
echo -e "  Port:            ${GREEN}${BITBARREL_PORT}${NC}"
echo -e "  Sync Interval:   ${GREEN}${BITBARREL_SYNC_INTERVAL}ms${NC}"
echo -e "  Buffer Size:     ${GREEN}${BITBARREL_BUFFER_SIZE} bytes${NC}"
echo

if [[ "$ENABLE_AUTH" = true ]]; then
    echo -e "${BLUE}Authentication Secrets:${NC}"
    echo -e "  JWT Secret:        ${GREEN}${BITBARREL_JWT_SECRET:0:20}...${NC}"
    if [[ -n "$BITBARREL_ADMIN_TOKEN" ]]; then
        echo -e "  Admin Token:       ${GREEN}${BITBARREL_ADMIN_TOKEN}${NC}"
    fi
    echo
fi

# Confirm
read -p "Save this configuration? (Y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo -e "${YELLOW}Configuration cancelled.${NC}"
    exit 0
fi

# Save configuration
echo -e "${CYAN}Saving configuration to ${CONFIG_FILE}...${NC}"
{
    echo "# BitBarrel Koyeb Configuration"
    echo "# Generated on: $(date)"
    echo
    echo "# Basic Settings"
    echo "APP_NAME=${APP_NAME}"
    echo "REGION=${REGION}"
    echo "VOLUME_SIZE=${VOLUME_SIZE}"
    echo "PRIVATE=${PRIVATE}"
    echo "ENABLE_AUTH=${ENABLE_AUTH}"
    echo
    echo "# Docker Image"
    echo "IMAGE=${IMAGE}"
    echo
    echo "# BitBarrel Configuration"
    echo "BITBARREL_PORT=${BITBARREL_PORT}"
    echo "BITBARREL_SYNC_INTERVAL=${BITBARREL_SYNC_INTERVAL}"
    echo "BITBARREL_BUFFER_SIZE=${BITBARREL_BUFFER_SIZE}"
    echo
    echo "# Authentication (KEEP THESE SECURE!)"
    echo "BITBARREL_JWT_SECRET=${BITBARREL_JWT_SECRET}"
    if [[ -n "$BITBARREL_ADMIN_TOKEN" ]]; then
        echo "BITBARREL_ADMIN_TOKEN=${BITBARREL_ADMIN_TOKEN}"
    fi
} > "$CONFIG_FILE"

echo -e "${GREEN}✓${NC} Configuration saved to ${CONFIG_FILE}"
echo

# Offer to deploy now
echo -e "${CYAN}Deploy now with this configuration?${NC}"
read -p "Deploy to Koyeb? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}Starting deployment...${NC}"
    echo

    # Export variables for deploy script
    export APP_NAME REGION VOLUME_SIZE PRIVATE IMAGE
    export BITBARREL_JWT_SECRET BITBARREL_ADMIN_TOKEN
    export BITBARREL_PORT BITBARREL_SYNC_INTERVAL BITBARREL_BUFFER_SIZE

    # Call deploy script with configuration
    if [[ "$PRIVATE" = true ]]; then
        ./scripts/deploy-to-koyeb.sh --name "$APP_NAME" --private
    else
        ./scripts/deploy-to-koyeb.sh --name "$APP_NAME"
    fi
else
    echo -e "${YELLOW}Deployment skipped.${NC}"
    echo
    echo -e "${CYAN}To deploy later, run:${NC}"
    echo -e "  ${GREEN}source ${CONFIG_FILE} && ./scripts/deploy-to-koyeb.sh --name ${APP_NAME}${NC}"
    echo
fi

echo -e "${GREEN}Configuration wizard completed!${NC}"
echo
