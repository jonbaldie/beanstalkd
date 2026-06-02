#!/usr/bin/env sh
set -e

IMAGE="${1:-jonbaldie/beanstalkd:latest}"

echo "Starting beanstalkd container from image: $IMAGE"
CONTAINER_ID=$(docker run -d -p 11300:11300 "$IMAGE")

# Ensure the container is destroyed when the script exits
trap "echo 'Tearing down container...'; docker rm -f $CONTAINER_ID > /dev/null" EXIT

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
        docker logs $CONTAINER_ID
        exit 1
    fi
    sleep 1
done

echo "PASS: beanstalkd is responding on port 11300."

# ---- Test 2: Process runs as non-root user ----
echo "Checking process user..."
RUNNING_USER=$(docker exec "$CONTAINER_ID" whoami)
if [ "$RUNNING_USER" = "root" ]; then
    echo "FAIL: beanstalkd is running as root (got: $RUNNING_USER)"
    exit 1
fi
echo "PASS: beanstalkd is running as non-root user '$RUNNING_USER'."

# ---- Test 3: Install script cleaned up from image ----
echo "Checking for install script artifact..."
if docker exec "$CONTAINER_ID" test -f /install.sh 2>/dev/null; then
    echo "FAIL: install.sh was not cleaned up and is present inside the image."
    exit 1
fi
echo "PASS: install.sh is not present in the image."

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

# ---- Test 5: Process runs as the 'beanstalk' user specifically ----
#
# Escaped mutant caught: switching USER to 'nobody' passes Test 2 (not root) but
# the daemon should run as the dedicated 'beanstalk' system account created by the
# beanstalkd package, not a generic catch-all user.

echo "Checking process runs as 'beanstalk' user..."
if [ "$RUNNING_USER" != "beanstalk" ]; then
    echo "FAIL: beanstalkd is not running as the 'beanstalk' user (got: $RUNNING_USER)"
    exit 1
fi
echo "PASS: beanstalkd is running as the dedicated 'beanstalk' user."

# ---- Test 6: Image is Alpine-based ----
#
# Escaped mutant caught: swapping FROM alpine for a heavier base (e.g. Ubuntu)
# keeps the daemon functional but inflates the image 8x and changes OS semantics.
# /etc/alpine-release is present only in Alpine-derived images.

echo "Checking image is Alpine-based..."
ALPINE_RELEASE=$(docker run --rm "$IMAGE" cat /etc/alpine-release 2>/dev/null || true)
if [ -z "$ALPINE_RELEASE" ]; then
    echo "FAIL: /etc/alpine-release not found — image does not appear to be Alpine-based."
    exit 1
fi
echo "PASS: Image is Alpine-based (version: $ALPINE_RELEASE)."

# ---- Test 7: APK package cache is empty ----
#
# Escaped mutant caught: removing --no-cache from 'apk add' installs beanstalkd
# but leaves ~3 MB of APKINDEX files in /var/cache/apk/, producing a bloated image.
# This test verifies the cache directory is empty, confirming --no-cache was used.

echo "Checking APK cache is clean..."
APK_CACHE=$(docker run --rm "$IMAGE" ls /var/cache/apk/ 2>/dev/null || true)
if [ -n "$APK_CACHE" ]; then
    echo "FAIL: APK cache is not empty (found: $APK_CACHE)"
    exit 1
fi
echo "PASS: APK cache is empty."

# ---- Test 8: CMD explicitly specifies -p 11300 ----
#
# Escaped mutant caught: omitting '-p 11300' from CMD still works because
# beanstalkd defaults to port 11300 — but the explicit flag is required for
# auditable intent and to guard against upstream default-port changes.

echo "Checking CMD includes explicit -p 11300..."
CMD_JSON=$(docker image inspect "$IMAGE" --format='{{json .Config.Cmd}}')
if ! printf '%s' "$CMD_JSON" | grep -q '"-p"'; then
    echo "FAIL: CMD does not include the -p flag (got: $CMD_JSON)"
    exit 1
fi
if ! printf '%s' "$CMD_JSON" | grep -q '"11300"'; then
    echo "FAIL: CMD does not specify port 11300 via -p (got: $CMD_JSON)"
    exit 1
fi
echo "PASS: CMD explicitly specifies -p 11300."
