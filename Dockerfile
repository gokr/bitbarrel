# BitBarrel Dockerfile
# Uses pre-built bitbarrel binary (build with: nimble build)
# Note: Binary must be built with glibc (not musl)

FROM ubuntu:24.04

# Install minimal runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    liblz4-1 \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user (Ubuntu 24.04 has ubuntu:1000, so use 1001)
RUN groupadd -g 1001 bitbarrel && useradd -u 1001 -g bitbarrel -s /bin/sh bitbarrel

# Create data directory
RUN install -d -m 0755 -o bitbarrel -g bitbarrel /data

# Copy pre-built bitbarrel binary from local filesystem
COPY bitbarrel /usr/local/bin/
RUN chmod +x /usr/local/bin/bitbarrel

# Copy webadmin build files if available
# If webadmin is not built, the server will still work but webadmin won't be available
# Build webadmin first: cd webadmin && flutter build web --release
# Using .dockerignore to handle missing webadmin
ONBUILD COPY --chown=bitbarrel:bitbarrel webadmin/build/web /opt/bitbarrel/webadmin

# Switch to non-root user
USER bitbarrel
WORKDIR /data

# Expose default server port
EXPOSE 8080

# Default command starts the server with webadmin
# If webadmin dir doesn't exist, it will just run in API-only mode
ENTRYPOINT ["/usr/local/bin/bitbarrel", "serve"]

# Run with webadmin by default (won't fail if dir missing)
ONBUILD ENTRYPOINT ["/usr/local/bin/bitbarrel", "serve", "--webadmin-path=/opt/bitbarrel/webadmin", "--webadmin-enabled"]
