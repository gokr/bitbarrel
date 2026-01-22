#!/bin/bash
set -e

# Koyeb CLI Installation Script
# Detects OS and installs the appropriate Koyeb CLI version

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         Koyeb CLI Installation Script                        ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo

# Detect OS
OS="unknown"
ARCH="unknown"

case "$(uname -s)" in
    Linux*)     OS="linux";;
    Darwin*)    OS="darwin";;
    *)          echo -e "${RED}Unsupported OS: $(uname -s)${NC}"; exit 1;;
esac

case "$(uname -m)" in
    x86_64|amd64)   ARCH="amd64";;
    aarch64|arm64)  ARCH="arm64";;
    *)              echo -e "${RED}Unsupported architecture: $(uname -m)${NC}"; exit 1;;
esac

echo -e "${GREEN}✓${NC} Detected OS: ${OS}"
echo -e "${GREEN}✓${NC} Detected architecture: ${ARCH}"
echo

# Check if koyeb is already installed
if command -v koyeb &> /dev/null; then
    CURRENT_VERSION=$(koyeb version 2>/dev/null | grep -oP 'Version \K[0-9.]+' || echo "unknown")
    echo -e "${YELLOW}Koyeb CLI is already installed (version: ${CURRENT_VERSION})${NC}"
    read -p "Do you want to reinstall/upgrade? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Installation cancelled.${NC}"
        exit 0
    fi
fi

# Create temp directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Determine version (use latest)
VERSION=$(curl -s https://api.github.com/repos/koyeb/koyeb-cli/releases/latest | grep '"tag_name"' | grep -o '[0-9.]*' | head -1)
if [[ -z "$VERSION" ]]; then
    echo -e "${YELLOW}Warning: Could not get latest version, using 5.9.0${NC}"
    VERSION="5.9.0"
fi

# Map OS and ARCH to Koyeb's naming convention
KOYEB_OS=$OS
KOYEB_ARCH=$ARCH

# Download Koyeb CLI
echo -e "${CYAN}Downloading Koyeb CLI...${NC}"
DOWNLOAD_URL="https://github.com/koyeb/koyeb-cli/releases/latest/download/koyeb-cli_${VERSION}_${KOYEB_OS}_${KOYEB_ARCH}.tar.gz"

echo -e "${GRAY}URL: $DOWNLOAD_URL${NC}"

cd "$TEMP_DIR"
if command -v curl &> /dev/null; then
    curl -sSL "${DOWNLOAD_URL}" -o koyeb.tar.gz
elif command -v wget &> /dev/null; then
    wget -q "${DOWNLOAD_URL}" -O koyeb.tar.gz
else
    echo -e "${RED}Error: Neither curl nor wget found. Please install one of them.${NC}"
    exit 1
fi

# Check if download was successful
if [[ ! -f "koyeb.tar.gz" ]]; then
    echo -e "${RED}✗ Download failed - no file created${NC}"
    exit 1
fi

# Check if it's actually a tarball and not an error message
if ! tar -tzf koyeb.tar.gz &> /dev/null; then
    echo -e "${RED}✗ Download failed - file is not a valid archive${NC}"
    echo -e "${RED}The file may not exist at the URL or you may be rate limited${NC}"
    echo -e "${GRAY}URL was: $DOWNLOAD_URL${NC}"

    # Show first few lines of the file to help debug
    if [[ -s "koyeb.tar.gz" ]]; then
        echo -e "${YELLOW}File content:${NC}"
        head -n 5 koyeb.tar.gz
    fi
    exit 1
fi

# Extract the binary
echo -e "${CYAN}Extracting Koyeb CLI...${NC}"
tar -xzf koyeb.tar.gz

# Find the koyeb binary
if [[ -f "koyeb" ]]; then
    # Binary is in current directory
    : # No-op
elif [[ -f "bin/koyeb" ]]; then
    # Binary is in bin/ directory
    mv bin/koyeb ./koyeb
else
    # Try to find it
    KOYEB_FILE=$(find . -name "koyeb" -type f | head -1)
    if [[ -n "$KOYEB_FILE" ]]; then
        mv "$KOYEB_FILE" ./koyeb
    else
        echo -e "${RED}✗ Could not find koyeb binary in archive${NC}"
        echo -e "${YELLOW}Archive contents:${NC}"
        tar -tzf koyeb.tar.gz
        exit 1
    fi
fi

# Make executable
chmod +x koyeb

# Install to appropriate location
INSTALL_DIR="/usr/local/bin"
if [[ -w "$INSTALL_DIR" ]]; then
    mv koyeb "$INSTALL_DIR/koyeb"
else
    echo -e "${YELLOW}sudo required to install to $INSTALL_DIR${NC}"
    sudo mv koyeb "$INSTALL_DIR/koyeb"
fi

# Verify installation
echo
echo -e "${CYAN}Verifying installation...${NC}"
if command -v koyeb &> /dev/null; then
    VERSION=$(koyeb version 2>/dev/null | grep -oP 'Version \K[0-9.]+' || echo "unknown")
    echo -e "${GREEN}✓${NC} Koyeb CLI installed successfully!"
    echo -e "${GREEN}✓${NC} Version: ${VERSION}"
    echo

    # Check if user needs to configure
    if [[ ! -f "$HOME/.koyeb.yaml" ]]; then
        echo -e "${YELLOW}Next steps:${NC}"
        echo -e "  1. Get your API token from: https://app.koyeb.com/settings/api"
        echo -e "  2. Configure the CLI: koyeb login"
        echo
    fi

    echo -e "${CYAN}To get started:${NC}"
    echo -e "  koyeb login          # Authenticate with your API token"
    echo -e "  koyeb app list       # List your applications"
    echo -e "  koyeb service list   # List your services"
else
    echo -e "${RED}✗${NC} Installation failed. Please check the error messages above.${NC}"
    exit 1
fi
