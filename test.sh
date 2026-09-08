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
CONTAINER_ID=""
PERSISTENCE_CONTAINER_ID=""
PERSISTENCE_VOLUME=""

cleanup() {
    echo "Tearing down containers..."
    if [ -n "$CONTAINER_ID" ]; then
        docker rm -f "$CONTAINER_ID" > /dev/null 2>&1 || true
    fi
    if [ -n "$PERSISTENCE_CONTAINER_ID" ]; then
        docker rm -f "$PERSISTENCE_CONTAINER_ID" > /dev/null 2>&1 || true
    fi
    if [ -n "$PERSISTENCE_VOLUME" ]; then
        docker volume rm -f "$PERSISTENCE_VOLUME" > /dev/null 2>&1 || true
    fi
}

trap cleanup EXIT
CONTAINER_ID=$(docker run -d -p 11300:11300 "$IMAGE")

# ---- Test 1: beanstalkd responds to the stats command on port 11300 ----
#
# NOTE: nc -z is intentionally avoided here because Docker's userland proxy
# completes the TCP handshake on host:11300 before the container-side port
# is even open, giving a false positive. We instead send an actual beanstalkd
# command and require an "OK" response, which proves the daemon is running.

beanstalkd_ok() {
    port="$1"
    python3 -c "
import socket, sys

def read_line(sock):
    response = bytearray()
    while not response.endswith(b'\\r\\n'):
        chunk = sock.recv(1)
        if not chunk:
            raise RuntimeError('connection closed before response line')
        response.extend(chunk)
    return bytes(response)

def read_bytes(sock, length):
    response = bytearray()
    while len(response) < length:
        chunk = sock.recv(length - len(response))
        if not chunk:
            raise RuntimeError('connection closed before response body')
        response.extend(chunk)

try:
    s = socket.create_connection(('localhost', int(sys.argv[1])), timeout=1)
    s.sendall(b'stats\r\n')
    d = read_line(s)
    if not d.startswith(b'OK '):
        raise RuntimeError('unexpected stats response')
    read_bytes(s, int(d.split()[1]) + 2)
    s.sendall(b'quit\r\n')
    s.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
" "$port" 2>/dev/null
}

MAX_RETRIES=15
RETRY_COUNT=0
echo "Waiting for beanstalkd to respond on port 11300..."

while ! beanstalkd_ok 11300; do
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

# ---- Test 6: Persistence works on a Docker-managed named volume ----
#
# Docker creates a new named volume as root-owned when the image does not
# provide the mount point. The image must provide a beanstalk-owned /data
# directory so an unprivileged daemon can write its WAL there.

echo "Checking persistence on a Docker-managed named volume..."
PERSISTENCE_VOLUME=$(docker volume create "beanstalkd-persistence-test-$$")
PERSISTENCE_CONTAINER_ID=$(docker run -d -p 0:11300 -v "$PERSISTENCE_VOLUME:/data" "$IMAGE" beanstalkd -b /data)
PERSISTENCE_RUNNING=$(docker inspect --format='{{.State.Running}}' "$PERSISTENCE_CONTAINER_ID")
if [ "$PERSISTENCE_RUNNING" != true ]; then
    echo "FAIL: persistent beanstalkd container exited before it became ready."
    echo "Container logs:"
    docker logs "$PERSISTENCE_CONTAINER_ID"
    exit 1
fi
PERSISTENCE_PORT=$(docker inspect --format='{{(index (index .NetworkSettings.Ports "11300/tcp") 0).HostPort}}' "$PERSISTENCE_CONTAINER_ID")

put_persistent_job() {
    python3 - "$1" <<'PY'
import socket
import sys

def read_line(sock):
    response = bytearray()
    while not response.endswith(b"\r\n"):
        chunk = sock.recv(1)
        if not chunk:
            raise RuntimeError("connection closed before a response")
        response.extend(chunk)
    return bytes(response)

try:
    with socket.create_connection(("localhost", int(sys.argv[1])), timeout=1) as sock:
        sock.settimeout(5)
        sock.sendall(b"put 0 0 60 7\r\npersist\r\n")
        response = read_line(sock)
        if not response.startswith(b"INSERTED "):
            print("expected INSERTED response, got %r" % response, file=sys.stderr)
            raise SystemExit(2)
except OSError:
    raise SystemExit(1)
PY
}

PERSISTENCE_RETRY_COUNT=0
echo "Waiting for persistent beanstalkd to accept a job on port $PERSISTENCE_PORT..."
while ! put_persistent_job "$PERSISTENCE_PORT"; do
    PERSISTENCE_RETRY_COUNT=$((PERSISTENCE_RETRY_COUNT+1))
    if [ "$PERSISTENCE_RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
        echo "FAIL: persistent beanstalkd did not accept a job on port $PERSISTENCE_PORT within $MAX_RETRIES seconds."
        echo "Container logs:"
        docker logs "$PERSISTENCE_CONTAINER_ID"
        exit 1
    fi
    sleep 1
done

# Allow beanstalkd's default WAL fsync interval to complete before stopping it.
sleep 1

echo "Restarting persistent beanstalkd container..."
docker stop -t 15 "$PERSISTENCE_CONTAINER_ID" > /dev/null
docker rm "$PERSISTENCE_CONTAINER_ID" > /dev/null
PERSISTENCE_CONTAINER_ID=""
PERSISTENCE_CONTAINER_ID=$(docker run -d -p 0:11300 -v "$PERSISTENCE_VOLUME:/data" "$IMAGE" beanstalkd -b /data)
PERSISTENCE_RUNNING=$(docker inspect --format='{{.State.Running}}' "$PERSISTENCE_CONTAINER_ID")
if [ "$PERSISTENCE_RUNNING" != true ]; then
    echo "FAIL: restarted persistent beanstalkd container exited before it became ready."
    echo "Container logs:"
    docker logs "$PERSISTENCE_CONTAINER_ID"
    exit 1
fi
PERSISTENCE_PORT=$(docker inspect --format='{{(index (index .NetworkSettings.Ports "11300/tcp") 0).HostPort}}' "$PERSISTENCE_CONTAINER_ID")

reserve_persistent_job() {
    python3 - "$1" <<'PY'
import socket
import sys

def read_line(sock):
    response = bytearray()
    while not response.endswith(b"\r\n"):
        chunk = sock.recv(1)
        if not chunk:
            raise RuntimeError("connection closed before a complete response")
        response.extend(chunk)
    return bytes(response)

def read_bytes(sock, length):
    response = bytearray()
    while len(response) < length:
        chunk = sock.recv(length - len(response))
        if not chunk:
            raise RuntimeError("connection closed before the complete job body")
        response.extend(chunk)
    return bytes(response)

try:
    sock = socket.create_connection(("localhost", int(sys.argv[1])), timeout=1)
except OSError:
    raise SystemExit(1)

with sock:
    sock.settimeout(5)
    sock.sendall(b"reserve-with-timeout 2\r\n")
    response = read_line(sock)
    if response.startswith(b"TIMED_OUT"):
        print("expected RESERVED response, got %r" % response, file=sys.stderr)
        raise SystemExit(2)
    if not response.startswith(b"RESERVED "):
        print("expected RESERVED response, got %r" % response, file=sys.stderr)
        raise SystemExit(2)
    job_id, body_size = response.split()[1:3]
    body = read_bytes(sock, int(body_size) + 2)
    if body != b"persist\r\n":
        print("expected persisted job body, got %r" % body, file=sys.stderr)
        raise SystemExit(2)
    sock.sendall(b"delete " + job_id + b"\r\n")
    response = read_line(sock)
    if response != b"DELETED\r\n":
        print("expected DELETED response, got %r" % response, file=sys.stderr)
        raise SystemExit(2)
PY
}

PERSISTENCE_RETRY_COUNT=0
while :; do
    if reserve_persistent_job "$PERSISTENCE_PORT"; then
        break
    else
        RESERVE_RC=$?
    fi
    if [ "$RESERVE_RC" -ne 1 ]; then
        echo "FAIL: restarted persistent beanstalkd did not recover the persisted job."
        echo "Container logs:"
        docker logs "$PERSISTENCE_CONTAINER_ID"
        exit 1
    fi
    PERSISTENCE_RETRY_COUNT=$((PERSISTENCE_RETRY_COUNT+1))
    if [ "$PERSISTENCE_RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
        echo "FAIL: restarted persistent beanstalkd did not accept a connection on port $PERSISTENCE_PORT within $MAX_RETRIES seconds."
        echo "Container logs:"
        docker logs "$PERSISTENCE_CONTAINER_ID"
        exit 1
    fi
    sleep 1
done

echo "PASS: job survived a container restart on a Docker-managed named volume."
