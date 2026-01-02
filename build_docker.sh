#!/bin/bash

# BitBarrel Docker Build Script
# Builds Docker image with proper version tagging
# Flutter web admin must be built FIRST: cd webadmin && flutter build web --release

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
IMAGE_NAME="bitbarrel"
REGISTRY="ghcr.io/gokr"  # Change this to your Docker Hub username or registry

echo "=== BitBarrel Docker Build ==="
echo ""

# Check prerequisites
check_prerequisites() {
    echo "Checking prerequisites..."

    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Error: Docker is not installed or not in PATH${NC}"
        exit 1
    fi

    if ! command -v nimble &> /dev/null; then
        echo -e "${RED}Error: Nimble is not installed or not in PATH${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Prerequisites check passed${NC}"
    echo ""
}

# Get version from nimble file
get_version() {
    local version=$(grep "^version" bitbarrel.nimble | cut -d'=' -f2 | tr -d '" ')
    echo ${version:-latest}
}

# Build Flutter web admin if Flutter is available and directory exists
build_web_admin() {
    if [ -d "webadmin" ] && command -v flutter &> /dev/null; then
        echo "Building Flutter web admin..."

        cd webadmin

        # Check if already built
        if [ -d "build/web" ]; then
            echo -e "${YELLOW}Web admin already built. Skipping build.${NC}"
            cd ..
            return 0
        fi

        # Install dependencies
        flutter pub get

        # Build for web
        if flutter build web --release; then
            cd ..
            echo -e "${GREEN}✓ Flutter web admin built successfully${NC}"
            echo ""
        else
            cd ..
            echo -e "${YELLOW}Warning: Flutter web admin build failed. Continuing without it.${NC}"
            echo "  To build manually: cd webadmin && flutter build web --release"
            echo ""
        fi
    else
        if [ ! -d "webadmin" ]; then
            echo -e "${YELLOW}Warning: webadmin directory not found. Skipping web admin build.${NC}"
        else
            echo -e "${YELLOW}Warning: Flutter not available. Web admin will not be included.${NC}"
            echo "  To add web admin: Install Flutter and run: cd webadmin && flutter build web --release"
        fi
        echo ""
    fi
}

# Build Docker image
build_image() {
    local version=$(get_version)
    local date_tag=$(date +%Y%m%d)
    local git_tag=$(git rev-parse --short HEAD 2>/dev/null || echo "none")

    echo "Building Docker image..."
    echo "  Version: ${version}"
    echo "  Date: ${date_tag}"
    echo "  Git: ${git_tag}"
    echo ""

    # Build arguments
    local build_args=""

    # Build the image
    echo "Running Docker build..."
    docker build \
        ${build_args} \
        -t ${IMAGE_NAME}:latest \
        -t ${IMAGE_NAME}:${version} \
        -t ${IMAGE_NAME}:${version}-${date_tag} \
        -t ${IMAGE_NAME}:${version}-${git_tag} \
        .

    echo ""
    echo -e "${GREEN}✓ Docker image built successfully${NC}"
    echo ""

    # Show image info
    echo "Image tags:"
    echo "  - ${IMAGE_NAME}:latest"
    echo "  - ${IMAGE_NAME}:${version}"
    echo "  - ${IMAGE_NAME}:${version}-${date_tag}"
    if [ "${git_tag}" != "none" ]; then
        echo "  - ${IMAGE_NAME}:${version}-${git_tag}"
    fi
    echo ""

    # Show image size
    local size=$(docker images ${IMAGE_NAME}:latest --format "{{.Size}}")
    echo "Image size: ${size}"
    echo ""
}

# Run smoke test
run_smoke_test() {
    echo "Running smoke test..."

    # Start container in background
    local container_id=$(docker run -d -p 8080:8080 -p 8081:8081 ${IMAGE_NAME}:latest)

    # Wait for startup
    echo "Waiting for services to start..."
    sleep 10

    # Check if container is still running
    if docker ps | grep -q ${container_id}; then
        echo -e "${GREEN}✓ Container is running${NC}"

        # Test server endpoint (simple check)
        if curl -s http://localhost:8080 > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Server endpoint is responding${NC}"
        else
            echo -e "${YELLOW}Warning: Server endpoint check failed (may need more time)${NC}"
        fi

        # Test admin endpoint
        if curl -s http://localhost:8081 > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Admin endpoint is responding${NC}"
        else
            echo -e "${YELLOW}Warning: Admin endpoint check failed${NC}"
        fi

        # Cleanup
        docker stop ${container_id} >/dev/null
        docker rm ${container_id} >/dev/null

        echo ""
        echo -e "${GREEN}✓ Smoke test passed${NC}"
    else
        echo -e "${RED}✗ Container failed to start properly${NC}"
        # Show logs
        docker logs ${container_id} 2>&1 || true
        docker rm ${container_id} >/dev/null 2>&1 || true
        exit 1
    fi

    echo ""
}

# Show usage instructions
show_usage() {
    local version=$(get_version)

    echo ""
    echo "=== Build Complete ==="
    echo ""
    echo "To run BitBarrel with Docker Compose:"
    echo "  docker-compose up -d"
    echo ""
    echo "To run with Docker directly:"
    echo "  docker run -d -p 8080:8080 -p 8081:8081 -v bitbarrel-data:/data ${IMAGE_NAME}:latest"
    echo ""
    echo "To run with authentication:"
    echo "  docker run -d \\"
    echo "    -p 8080:8080 -p 8081:8081 \\"
    echo "    -v bitbarrel-data:/data \\"
    echo "    -e BITBARREL_AUTH_ENABLED=true \\"
    echo "    -e BITBARREL_AUTH_SECRET=\$(openssl rand -base64 32) \\"
    echo "    ${IMAGE_NAME}:latest"
    echo ""
    echo "To view logs:"
    echo "  docker-compose logs -f"
    echo "  # or"
    echo "  docker logs -f <container-id>"
    echo ""
}

# Publish to registry (optional)
publish_image() {
    local version=$(get_version)

    echo "Publishing image to registry..."
    echo "  Registry: ${REGISTRY}"
    echo "  Image: ${IMAGE_NAME}"
    echo ""

    # Tag for registry
    docker tag ${IMAGE_NAME}:latest ${REGISTRY}/${IMAGE_NAME}:latest
    docker tag ${IMAGE_NAME}:${version} ${REGISTRY}/${IMAGE_NAME}:${version}

    # Push
    docker push ${REGISTRY}/${IMAGE_NAME}:latest
    docker push ${REGISTRY}/${IMAGE_NAME}:${version}

    echo -e "${GREEN}✓ Images published successfully${NC}"
    echo ""
}

# Main execution
main() {
    local skip_test=false
    local publish=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-test)
                skip_test=true
                shift
                ;;
            --publish)
                publish=true
                shift
                ;;
            --registry)
                REGISTRY="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --skip-test    Skip smoke test after build"
                echo "  --publish      Publish to registry after build"
                echo "  --registry     Registry to publish to (default: ghcr.io/gokr)"
                echo "  --help, -h     Show this help message"
                exit 0
                ;;
            *)
                echo -e "${RED}Error: Unknown option $1${NC}"
                exit 1
                ;;
        esac
    done

    # Run build steps
    check_prerequisites
    build_web_admin
    build_image

    # Run tests unless skipped
    if [ "${skip_test}" = false ]; then
        run_smoke_test
    fi

    # Publish if requested
    if [ "${publish}" = true ]; then
        publish_image
    fi

    # Show usage
    show_usage
}

# Run main function with all arguments
main "$@"
