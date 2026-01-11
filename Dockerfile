# BitBarrel Dockerfile
# Multi-stage build that builds bitbarrel and webadmin from source

# Stage 1: Build bitbarrel binary with Nim
FROM ubuntu:24.04 AS nim-builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    xz-utils \
    curl \
    ca-certificates \
    git \
    gcc \
    g++ \
    make \
    clang \
    libclang-dev \
    liblz4-dev \
    libsnappy-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Nim from source (Nim 2.2.6)
RUN curl -L -o nim-2.2.6-linux_x64.tar.xz https://nim-lang.org/download/nim-2.2.6-linux_x64.tar.xz && \
    tar -xf nim-2.2.6-linux_x64.tar.xz && \
    mv nim-2.2.6 /opt/nim && \
    rm nim-2.2.6-linux_x64.tar.xz

# Add Nim to PATH
ENV PATH="/opt/nim/bin:/root/.nimble/bin:${PATH}"

# Copy source code
WORKDIR /src
COPY . .

# Build bitbarrel binary with LZ4 compression
RUN nimble install -y --depsOnly && \
    nimble build -d:lz4Compression

# Stage 2: Build webadmin with Flutter
FROM ghcr.io/cirruslabs/flutter:3.38.5 AS flutter-builder

WORKDIR /src
COPY . .

# Run flutter as root (default user in this image)
RUN cd webadmin && flutter build web --release

# Stage 3: Prepare runtime-only image
FROM ubuntu:24.04

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    liblz4-1 \
    ca-certificates \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -g 1001 bitbarrel && useradd -u 1001 -g bitbarrel -s /bin/sh bitbarrel

# Create directories
RUN install -d -m 0755 -o bitbarrel -g bitbarrel /data \
    && install -d -m 0755 -o bitbarrel -g bitbarrel /opt/bitbarrel

# Copy bitbarrel binary from nim-builder
COPY --from=nim-builder --chown=bitbarrel:bitbarrel /src/bitbarrel /usr/local/bin/
RUN chmod +x /usr/local/bin/bitbarrel

# Copy webadmin build files from flutter-builder
COPY --from=flutter-builder --chown=bitbarrel:bitbarrel /src/webadmin/build/web /opt/bitbarrel/webadmin

# Switch to non-root user
USER bitbarrel
WORKDIR /data

# Expose default server port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD wget -q --spider http://localhost:8080/status || exit 1

# Default command starts the server with webadmin
ENTRYPOINT ["/usr/local/bin/bitbarrel", "serve", "--webadmin-path=/opt/bitbarrel/webadmin"]
