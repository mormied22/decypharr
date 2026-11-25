# xx provides cross-compilation toolchains for CGO builds
FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.10.0@sha256:40fe21f44bb8cddf1eb1226db190d0a984118f62ee02a91b77d99448d28264a6 AS xx

# Stage 1: Build binaries — pinned to BUILDPLATFORM so Go runs natively (fast)
FROM --platform=$BUILDPLATFORM golang:1.26.5-alpine3.24@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2 AS builder

ARG TARGETOS
ARG TARGETARCH
ARG TARGETPLATFORM
ARG VERSION=2.7
ARG CHANNEL=linkfix
ENV GOTOOLCHAIN=local

# Copy xx scripts for cross-compilation
COPY --from=xx / /

WORKDIR /app

# Install cross-compilation toolchain via xx
RUN apk add --no-cache clang lld && \
    xx-apk add --no-cache gcc g++ musl-dev libc-dev fuse-dev

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download -x

COPY . .

# Build main binary — xx-go sets CC/CXX/GOOS/GOARCH automatically.
# Use native libutp to avoid large Go allocations during peer connection setup.
# The final image includes its C++ runtime dependencies.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=1 \
    xx-go build -trimpath \
    -ldflags="-w -s -X github.com/sirrobot01/decypharr/pkg/version.Version=${VERSION} -X github.com/sirrobot01/decypharr/pkg/version.Channel=${CHANNEL}" \
    -o /decypharr && \
    xx-verify /decypharr

# Build healthcheck (no CGO needed, plain cross-compile)
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-w -s" \
    -o /healthcheck cmd/healthcheck/main.go

# Optional Linux acceptance target. Tests retain nonzero exits for the CI gate.
FROM builder AS acceptance-tests
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    sh build/owned-baseline-tests.sh

FROM scratch AS acceptance-results
COPY --from=acceptance-tests /acceptance/ /

# Stage 2: Final image
FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS runtime

ARG VERSION=2.7
ARG CHANNEL=linkfix
ARG VCS_REF
ARG BUILD_DATE
ARG RCLONE_VERSION=1.76.0

RUN test "${#VCS_REF}" -eq 40 && \
    case "$VCS_REF" in *[!0-9a-f]*) exit 1 ;; esac && \
    test -n "$BUILD_DATE"

LABEL version="${VERSION}-${CHANNEL}"
LABEL org.opencontainers.image.source="https://github.com/mormied22/decypharr"
LABEL org.opencontainers.image.revision="${VCS_REF}"
LABEL org.opencontainers.image.version="${VERSION}-${CHANNEL}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.base.name="docker.io/library/alpine:3.24.1"
LABEL org.opencontainers.image.base.digest="sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"
LABEL org.opencontainers.image.title="decypharr"
LABEL org.opencontainers.image.vendor="mormied22"
LABEL org.opencontainers.image.documentation="https://github.com/mormied22/decypharr/blob/maintenance/linkfix-2.7-build/build/OWNED_BASELINE.md"
LABEL io.mormied22.decypharr.code.revision="bc6e64b3374aa80a92127c8ff570ebb1fb9c5568"
LABEL io.mormied22.decypharr.patch.origin="https://github.com/h1n054ur/decypharr"

# Install dependencies including rclone (from binary).
# libstdc++/libgcc: required at runtime by rapidyenc's C++ decoder.
RUN apk add --no-cache fuse3 ca-certificates su-exec shadow curl unzip tzdata libstdc++ libgcc && \
    echo "user_allow_other" >> /etc/fuse.conf && \
    case "$(uname -m)" in \
        x86_64) ARCH=amd64; RCLONE_SHA256=b00f00b3266c3764413afe599d3ec316f6f43b3e0ea8a0bc1d186d2133e46df7 ;; \
        aarch64) ARCH=arm64; RCLONE_SHA256=ee169016675e23a69d77240565133ff7dbc9b33d16fa8f7053d4af39f1eaeb78 ;; \
        armv7l|armv7) ARCH=arm; RCLONE_SHA256=ecd7145f2565a40d1318c8d79866e6294503bd17abdb17e39e1157eefc8fa72a ;; \
        *) echo "Unsupported architecture: $(uname -m)" && exit 1 ;; \
    esac && \
    curl --fail --location --retry 3 --output /tmp/rclone.zip "https://downloads.rclone.org/v${RCLONE_VERSION}/rclone-v${RCLONE_VERSION}-linux-${ARCH}.zip" && \
    printf '%s  %s\n' "$RCLONE_SHA256" /tmp/rclone.zip | sha256sum -c - && \
    unzip /tmp/rclone.zip -d /tmp/rclone && \
    cp "/tmp/rclone/rclone-v${RCLONE_VERSION}-linux-${ARCH}/rclone" /usr/local/bin/ && \
    chmod +x /usr/local/bin/rclone && \
    rm -rf /tmp/rclone /tmp/rclone.zip && \
    apk del curl unzip

# Copy binaries and entrypoint
COPY --from=builder /decypharr /usr/bin/decypharr
COPY --from=builder /healthcheck /usr/bin/healthcheck
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set environment variables
ENV PUID=1000
ENV PGID=1000
ENV LOG_PATH=/app/logs
# This anacrolix diagnostic fires whenever an internal unlock handler takes
# 20ms; actual torrent errors remain visible and operators can override it.
ENV GO_LOG=client-unlock-handlers.go=err

EXPOSE 8282
VOLUME ["/app"]

HEALTHCHECK --interval=10s --retries=10 CMD ["/usr/bin/healthcheck", "--config", "/app"]

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/decypharr", "--config", "/app"]
