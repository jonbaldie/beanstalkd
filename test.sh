#!/usr/bin/env sh
set -e

IMAGE="${1:-jonbaldie/beanstalkd:latest}"

for dep in docker python3; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        echo "FAIL: '$dep' is required by test.sh but was not found in PATH."
        exit 1
    fi
done

echo "Starting beanstalkd container from image: $IMAGE"
CONTAINER_ID=$(docker run -d -p 11300:11300 "$IMAGE")

# Ensure the container is destroyed when the script exits
trap 'echo "Tearing down container..."; [ -n "$CONTAINER_ID" ] && docker rm -f "$CONTAINER_ID" > /dev/null 2>&1 || true' EXIT

# ---- Test 1: beanstalkd responds to the stats command on port 11300 ----
#
# NOTE: nc -z is intentionally avoided here because Docker's userland proxy
# completes the TCP handshake on host:11300 before the container-side port
# is even open, giving a false positive. We instead send an actual beanstalkd
# command and require an "OK" response, which proves the daemon is running.

beanstalkd_ok() {
    python3 -c "
import socket, sys
try:
    s = socket.create_connection(('localhost', 11300), timeout=1)
    s.sendall(b'stats\r\n')
    d = s.recv(256)
    s.close()
    sys.exit(0 if d.startswith(b'OK') else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

MAX_RETRIES=15
RETRY_COUNT=0
echo "Waiting for beanstalkd to respond on port 11300..."

while ! beanstalkd_ok; do
    RETRY_COUNT=$((RETRY_COUNT+1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "FAIL: beanstalkd did not respond on port 11300 within $MAX_RETRIES seconds."
        echo "Container logs:"
        docker logs "$CONTAINER_ID"
        exit 1
    fi
    sleep 1
done

echo "PASS: beanstalkd is responding on port 11300."

# ---- Test 2: Process runs as non-root user ----
#
# NOTE: `docker exec whoami` is intentionally avoided because it spawns a new
# transient process using the image's default USER rather than inspecting the
# running daemon. We query the process table inside the container to verify
# that the beanstalkd process itself is executing under an unprivileged user.

echo "Checking process user..."
RUNNING_USER=$(docker exec "$CONTAINER_ID" ps -o user,comm | awk '$2 ~ /beanstalkd/ {print $1; exit}')
if [ -z "$RUNNING_USER" ]; then
    echo "FAIL: unable to determine beanstalkd process user."
    exit 1
fi
if [ "$RUNNING_USER" = "root" ] || [ "$RUNNING_USER" = "0" ]; then
    echo "FAIL: beanstalkd is running as root (got: $RUNNING_USER)"
    exit 1
fi
echo "PASS: beanstalkd is running as non-root user '$RUNNING_USER'."

# ---- Test 3: Install script not present in filesystem or image layers ----
echo "Checking for install script artifact..."
if docker exec "$CONTAINER_ID" test -f /install.sh 2>/dev/null; then
    echo "FAIL: install.sh was not cleaned up and is present inside the image."
    exit 1
fi
if docker history --no-trunc "$IMAGE" | grep -q "install\.sh"; then
    echo "FAIL: install.sh persists in image layer history."
    exit 1
fi
echo "PASS: install.sh is not present in image filesystem or layer history."

# ---- Test 4: EXPOSE metadata declares port 11300 ----
#
# NOTE: we inspect the IMAGE (not the running container) because `docker inspect`
# on a container merges runtime -p bindings into ExposedPorts, masking a missing
# EXPOSE directive. `docker image inspect` reflects only what the Dockerfile declared.

echo "Checking EXPOSE metadata..."
EXPOSED=$(docker image inspect "$IMAGE" --format='{{json .Config.ExposedPorts}}')
if ! printf '%s' "$EXPOSED" | grep -q '"11300/tcp"'; then
    echo "FAIL: port 11300/tcp is not declared in EXPOSE metadata (got: $EXPOSED)"
    exit 1
fi
echo "PASS: port 11300/tcp is correctly declared in EXPOSE metadata."

# ---- Test 5: Image is not bloated ----
#
# Users pulling this image notice its size directly (pull time, disk usage,
# attack surface). The correct Alpine build is ~9 MB; a heavier base such as
# Ubuntu inflates it to ~71 MB — an 8x regression that is plainly user-facing.
# 20 MB gives comfortable headroom over the current clean build while catching
# any inadvertent switch to a heavyweight base image.
#
# NOTE: Tests for the specific base distro (Alpine) or internal cache directories
# (/var/cache/apk) were considered but rejected: those are implementation details.
# What users observe is image size, so that is what we measure.

echo "Checking image size is under 20 MB..."
IMAGE_SIZE=$(docker image inspect "$IMAGE" --format='{{.Size}}')
MAX_BYTES=20971520   # 20 * 1024 * 1024
if [ "$IMAGE_SIZE" -gt "$MAX_BYTES" ]; then
    IMAGE_MB=$(( IMAGE_SIZE / 1048576 ))
    echo "FAIL: image is ${IMAGE_MB} MB, which exceeds the 20 MB limit (got ${IMAGE_SIZE} bytes)"
    exit 1
fi
IMAGE_MB=$(( IMAGE_SIZE / 1048576 ))
echo "PASS: image size is ${IMAGE_MB} MB (within 20 MB limit)."
