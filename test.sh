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

# Resource names must not be guessable from the PID alone (issue #30): PIDs are
# recycled, so a user-owned container or volume could take the name this run
# expects, get adopted by the test, and then be destroyed by cleanup. A random
# suffix makes the names ours, and an ownership label scoped to that same
# random id lets cleanup remove only what this invocation created.
RUN_SUFFIX=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
if [ -z "$RUN_SUFFIX" ]; then
    echo "FAIL: could not generate a random suffix for test resource names."
    exit 1
fi
RUN_ID="$$-$RUN_SUFFIX"
OWNER_LABEL="beanstalkd-test-run=$RUN_ID"
CONTAINER_NAME="beanstalkd-test-$RUN_ID"
PERSISTENCE_CONTAINER_NAME="beanstalkd-persistence-test-$RUN_ID"
PERSISTENCE_VOLUME="beanstalkd-persistence-test-$RUN_ID"
VOLUME_LEAK_CONTAINER_NAME="beanstalkd-volume-leak-test-$RUN_ID"

# Cleanup selects by the ownership label rather than by name, so it can never
# remove a resource this invocation did not create. The label is applied at
# creation time, which also covers containers that Docker created but failed to
# start (issue #17), where no id is ever returned to us.
cleanup() {
    echo "Tearing down containers..."
    OWNED_CONTAINERS=$(docker ps -aq --filter "label=$OWNER_LABEL" 2>/dev/null || true)
    for owned in $OWNED_CONTAINERS; do
        docker rm -fv "$owned" > /dev/null 2>&1 || true
    done
    OWNED_VOLUMES=$(docker volume ls -q --filter "label=$OWNER_LABEL" 2>/dev/null || true)
    for owned in $OWNED_VOLUMES; do
        docker volume rm -f "$owned" > /dev/null 2>&1 || true
    done
}

assert_loopback_port() {
    container="$1"
    host_ips=$(docker inspect --format='{{range (index .NetworkSettings.Ports "11300/tcp")}}{{.HostIp}}{{"\n"}}{{end}}' "$container")
    if [ -z "$host_ips" ]; then
        echo "FAIL: $container did not publish port 11300."
        exit 1
    fi
    for host_ip in $host_ips; do
        if [ "$host_ip" != "127.0.0.1" ]; then
            echo "FAIL: $container published port 11300 on $host_ip instead of loopback."
            exit 1
        fi
    done
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
docker run -d --name "$CONTAINER_NAME" --label "$OWNER_LABEL" -p 127.0.0.1:0:11300 "$IMAGE" > /dev/null
assert_loopback_port "$CONTAINER_NAME"
PORT=$(docker inspect --format='{{(index (index .NetworkSettings.Ports "11300/tcp") 0).HostPort}}' "$CONTAINER_NAME")
if [ -z "$PORT" ] || [ "$PORT" = "<no value>" ]; then
    echo "FAIL: could not determine the mapped host port for $CONTAINER_NAME."
    echo "Container logs:"
    docker logs "$CONTAINER_NAME"
    exit 1
fi

# ---- Test 1: beanstalkd responds to the stats command on the mapped host port ----
#
# NOTE: nc -z is intentionally avoided here because Docker's userland proxy
# completes the TCP handshake on the mapped host port before the container-side
# port is even open, giving a false positive. We instead send an actual
# beanstalkd command and require an "OK" response, which proves the daemon is
# running. Host port 11300 is not required; a random mapping lets this run
# when that port is already allocated (issue #25).

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
echo "Waiting for beanstalkd to respond on port $PORT..."

while ! beanstalkd_ok "$PORT"; do
    RETRY_COUNT=$((RETRY_COUNT+1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "FAIL: beanstalkd did not respond on port $PORT within $MAX_RETRIES seconds."
        echo "Container logs:"
        docker logs "$CONTAINER_NAME"
        exit 1
    fi
    sleep 1
done

echo "PASS: beanstalkd is responding on port $PORT."

# ---- Test 2: Process runs as non-root user ----
#
# NOTE: `docker exec whoami` is intentionally avoided because it spawns a new
# transient process using the image's default USER rather than inspecting the
# running daemon. We query the process table inside the container to verify
# that the beanstalkd process itself is executing under an unprivileged user.

echo "Checking process user..."
RUNNING_USER=$(docker exec "$CONTAINER_NAME" ps -o user,comm | awk '$2 ~ /beanstalkd/ {print $1; exit}')
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
if docker exec "$CONTAINER_NAME" test -f /install.sh 2>/dev/null; then
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

# ---- Test 6: malformed kick bounds are rejected and leave the queue unmutated ----
#
# Regression for issue #36: the packaged daemon parsed the `kick` bound with a
# bare strtoul(), so trailing garbage was silently ignored and a negative bound
# wrapped to a huge unsigned count. In both cases the reply was `KICKED n` and
# every buried job was kicked to ready. Per the protocol (doc/protocol.txt),
# integers are non-negative and malformed commands must yield BAD_FORMAT, with
# no queue mutation. The assertion covers queue state, not just response text,
# so a future regression that only corrupts the response cannot pass here.
#
# Regression for issue #36: the packaged daemon parsed the `kick` bound with a
# bare strtoul(), so trailing garbage was silently ignored and a negative bound
# wrapped to a huge unsigned count. In both cases the reply was `KICKED n` and
# every buried job was kicked to ready. Per the protocol (doc/protocol.txt),
# integers are non-negative and malformed commands must yield BAD_FORMAT, with
# no queue mutation. The assertion covers queue state, not just response text,
# so a future regression that only corrupts the response cannot pass here.

check_kick_bounds() {
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
            raise RuntimeError("connection closed before the complete body")
        response.extend(chunk)
    return bytes(response)

failures = []

def check(cond, message):
    if not cond:
        failures.append(message)

def stats(sock):
    sock.sendall(b"stats\r\n")
    r = read_line(sock)
    if not r.startswith(b"OK "):
        return None
    body = read_bytes(sock, int(r.split()[1]) + 2)
    out = {}
    for line in body.split(b"\n"):
        line = line.strip()
        if b": " in line:
            k, v = line.split(b": ", 1)
            out[k] = v
    return out

sock = socket.create_connection(("localhost", int(sys.argv[1])), timeout=5)
sock.settimeout(5)

def cmd(line, body=None):
    sock.sendall(line)
    if body is not None:
        sock.sendall(body)
    return read_line(sock)

TUBE = b"kick-regression"
sock.sendall(b"use " + TUBE + b"\r\n"); read_line(sock)
sock.sendall(b"watch " + TUBE + b"\r\n"); read_line(sock)
sock.sendall(b"ignore default\r\n"); read_line(sock)

# --- malformed bound: trailing garbage must be rejected and must not kick ---
r = cmd(b"put 1 0 60 8\r\n", b"buried-a\r\n")
job_id = r.split()[1]
r = cmd(b"reserve-with-timeout 0\r\n")
read_bytes(sock, int(r.split()[2]) + 2)  # RESERVED body
if cmd(b"bury " + job_id + b" 1\r\n") != b"BURIED\r\n":
    failures.append("setup: bury of first job failed")

if cmd(b"kick 1garbage\r\n") != b"BAD_FORMAT\r\n":
    failures.append("kick 1garbage: expected BAD_FORMAT")
r = cmd(b"peek-ready\r\n")
if r.startswith(b"FOUND"):
    read_bytes(sock, int(r.split()[2]) + 2)  # drain FOUND body before continuing
if not r.startswith(b"NOT_FOUND"):
    failures.append("kick 1garbage mutated queue: a ready job appeared (got %r)" % r)
# Remove the residue so later counts are exact; buried jobs may be deleted.
if cmd(b"delete " + job_id + b"\r\n") != b"DELETED\r\n":
    failures.append("kick 1garbage: job could not be cleaned up")

# --- malformed bound: negative value must be rejected and must not kick ---
buried_ids = []
for body in (b"buried-b\r\n", b"buried-c\r\n"):
    r = cmd(b"put 1 0 60 %d\r\n" % (len(body) - 2), body)
    job_id = r.split()[1]
    r = cmd(b"reserve-with-timeout 0\r\n")
    read_bytes(sock, int(r.split()[2]) + 2)  # RESERVED body
    cmd(b"bury " + job_id + b" 1\r\n")
    buried_ids.append(job_id)

if cmd(b"kick -1\r\n") != b"BAD_FORMAT\r\n":
    failures.append("kick -1: expected BAD_FORMAT")
s = stats(sock)
if s is None or s.get(b"current-jobs-ready") != b"0" or s.get(b"current-jobs-buried") != b"2":
    failures.append("kick -1 mutated queue: %r (expected ready=0, buried=2)" % s)

# --- valid non-negative bounds must keep their semantics ---
if cmd(b"kick 1\r\n") != b"KICKED 1\r\n":
    failures.append("valid kick 1: expected KICKED 1")
r = cmd(b"peek-ready\r\n")
if not r.startswith(b"FOUND "):
    failures.append("valid kick 1: no ready job after kick (got %r)" % r)
else:
    body = read_bytes(sock, int(r.split()[2]) + 2)
    if body != b"buried-b\r\n":
        failures.append("valid kick 1: wrong job kicked (body %r)" % body)

sock.close()

if failures:
    for f in failures:
        print("kick regression: " + f, file=sys.stderr)
    raise SystemExit(2)
PY
}

echo "Checking malformed kick bounds are rejected and leave the queue unmutated..."
check_kick_bounds "$PORT"
echo "PASS: malformed kick bounds return BAD_FORMAT and the queue is unmutated."

# ---- Test 7: Persistence works on a Docker-managed named volume ----
#
# Docker creates a new named volume as root-owned when the image does not
# provide the mount point. The image must provide a beanstalk-owned /data
# directory so an unprivileged daemon can write its WAL there.

echo "Checking persistence on a Docker-managed named volume..."
if docker volume inspect "$PERSISTENCE_VOLUME" > /dev/null 2>&1; then
    echo "FAIL: volume $PERSISTENCE_VOLUME already exists; refusing to adopt a volume this run did not create."
    exit 1
fi
docker volume create --label "$OWNER_LABEL" "$PERSISTENCE_VOLUME" > /dev/null
docker run -d --name "$PERSISTENCE_CONTAINER_NAME" --label "$OWNER_LABEL" -p 127.0.0.1:0:11300 -v "$PERSISTENCE_VOLUME:/data" "$IMAGE" beanstalkd -b /data > /dev/null
PERSISTENCE_RUNNING=$(docker inspect --format='{{.State.Running}}' "$PERSISTENCE_CONTAINER_NAME")
if [ "$PERSISTENCE_RUNNING" != true ]; then
    echo "FAIL: persistent beanstalkd container exited before it became ready."
    echo "Container logs:"
    docker logs "$PERSISTENCE_CONTAINER_NAME"
    exit 1
fi
assert_loopback_port "$PERSISTENCE_CONTAINER_NAME"
PERSISTENCE_PORT=$(docker inspect --format='{{(index (index .NetworkSettings.Ports "11300/tcp") 0).HostPort}}' "$PERSISTENCE_CONTAINER_NAME")

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
        docker logs "$PERSISTENCE_CONTAINER_NAME"
        exit 1
    fi
    sleep 1
done

# Allow beanstalkd's default WAL fsync interval to complete before stopping it.
sleep 1

echo "Restarting persistent beanstalkd container..."
docker stop -t 15 "$PERSISTENCE_CONTAINER_NAME" > /dev/null
docker rm "$PERSISTENCE_CONTAINER_NAME" > /dev/null
docker run -d --name "$PERSISTENCE_CONTAINER_NAME" --label "$OWNER_LABEL" -p 127.0.0.1:0:11300 -v "$PERSISTENCE_VOLUME:/data" "$IMAGE" beanstalkd -b /data > /dev/null
PERSISTENCE_RUNNING=$(docker inspect --format='{{.State.Running}}' "$PERSISTENCE_CONTAINER_NAME")
if [ "$PERSISTENCE_RUNNING" != true ]; then
    echo "FAIL: restarted persistent beanstalkd container exited before it became ready."
    echo "Container logs:"
    docker logs "$PERSISTENCE_CONTAINER_NAME"
    exit 1
fi
assert_loopback_port "$PERSISTENCE_CONTAINER_NAME"
PERSISTENCE_PORT=$(docker inspect --format='{{(index (index .NetworkSettings.Ports "11300/tcp") 0).HostPort}}' "$PERSISTENCE_CONTAINER_NAME")

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
        docker logs "$PERSISTENCE_CONTAINER_NAME"
        exit 1
    fi
    PERSISTENCE_RETRY_COUNT=$((PERSISTENCE_RETRY_COUNT+1))
    if [ "$PERSISTENCE_RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
        echo "FAIL: restarted persistent beanstalkd did not accept a connection on port $PERSISTENCE_PORT within $MAX_RETRIES seconds."
        echo "Container logs:"
        docker logs "$PERSISTENCE_CONTAINER_NAME"
        exit 1
    fi
    sleep 1
done

echo "PASS: job survived a container restart on a Docker-managed named volume."

# ---- Test 8: default run leaves no anonymous volume behind ----
#
# Regression for issue #24: `VOLUME ["/data"]` attaches an anonymous volume to
# every container that does not explicitly mount /data, and the default CMD
# (no -b) never writes to it. `docker rm -f` does not delete anonymous volumes,
# so a plain `docker run -d` / `docker rm -f` cycle leaked storage on the host.
# A default run must attach no volume at all and leave nothing behind.

echo "Checking default run attaches no anonymous volume..."

docker run -d --name "$VOLUME_LEAK_CONTAINER_NAME" --label "$OWNER_LABEL" "$IMAGE" > /dev/null
ATTACHED_VOLUMES=$(docker inspect --format='{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' "$VOLUME_LEAK_CONTAINER_NAME")
docker rm -f "$VOLUME_LEAK_CONTAINER_NAME" > /dev/null

if [ -n "$ATTACHED_VOLUMES" ]; then
    echo "FAIL: a default run attached anonymous volume(s):"
    for volume in $ATTACHED_VOLUMES; do
        if docker volume inspect "$volume" > /dev/null 2>&1; then
            echo "FAIL: docker rm -f of a default container left volume $volume behind."
            docker volume rm -f "$volume" > /dev/null 2>&1 || true
        fi
    done
    exit 1
fi

echo "PASS: default run attaches no volume and docker rm -f leaves none behind."

# ---- Test 9: malformed reserve-with-timeout bounds are rejected and leave the queue unmutated ----
#
# Regression for issue #39: dispatch_cmd() parsed the `reserve-with-timeout`
# bound with read_u32(..., &end_buf), which disables read_u32()'s
# full-consumption check, and then fell through to the OP_RESERVE case whose
# trailing-garbage check only applies to `reserve` itself. So trailing garbage
# (`reserve-with-timeout 1garbage`), trailing arguments (`... 0 foo`), and
# trailing whitespace (`... 0 `) were silently accepted: the command replied
# `RESERVED id bytes` and moved a ready job to reserved. Per the protocol
# (doc/protocol.txt), all integers are non-negative decimal values and
# malformed commands must return BAD_FORMAT without mutating the queue. The
# assertion covers queue state, not just response text, so a future regression
# that only corrupts the response cannot pass here.

check_reserve_timeout_bounds() {
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
            raise RuntimeError("connection closed before the complete body")
        response.extend(chunk)
    return bytes(response)

failures = []

def check(cond, message):
    if not cond:
        failures.append(message)

def stats(sock):
    sock.sendall(b"stats\r\n")
    r = read_line(sock)
    if not r.startswith(b"OK "):
        return None
    body = read_bytes(sock, int(r.split()[1]) + 2)
    out = {}
    for line in body.split(b"\n"):
        line = line.strip()
        if b": " in line:
            k, v = line.split(b": ", 1)
            out[k] = v
    return out

sock = socket.create_connection(("localhost", int(sys.argv[1])), timeout=5)
sock.settimeout(5)

def cmd(line, body=None):
    sock.sendall(line)
    if body is not None:
        sock.sendall(body)
    return read_line(sock)

TUBE = b"reserve-timeout-regression"
sock.sendall(b"use " + TUBE + b"\r\n"); read_line(sock)
sock.sendall(b"watch " + TUBE + b"\r\n"); read_line(sock)
sock.sendall(b"ignore default\r\n"); read_line(sock)

def put_ready_job(body):
    r = cmd(b"put 1 0 60 %d\r\n" % (len(body) - 2), body)
    if not r.startswith(b"INSERTED "):
        return None
    return r.split()[1]

# Each malformed bound must yield BAD_FORMAT and leave the job exactly where
# it was: still ready, nothing reserved or buried.
for bound in (b"1garbage", b"0 foo", b"0 ", b"-1", b"99999999999", b""):
    job_id = put_ready_job(b"malformed-" + bound.replace(b" ", b"_") + b"\r\n")
    if job_id is None:
        failures.append("setup: put for bound %r failed" % bound)
        continue
    stats_before = stats(sock)
    r = cmd(b"reserve-with-timeout " + bound + b"\r\n")
    check(r == b"BAD_FORMAT\r\n",
          "reserve-with-timeout %r: expected BAD_FORMAT (got %r)" % (bound, r))
    if r.startswith(b"RESERVED"):
        # The buggy path reserves the job; drain its body so the command
        # stream stays in sync for the remaining assertions.
        read_bytes(sock, int(r.split()[2]) + 2)
    stats_after = stats(sock)
    if stats_before is not None and stats_after is not None:
        for key in (b"current-jobs-ready", b"current-jobs-reserved", b"current-jobs-buried"):
            check(stats_after.get(key) == stats_before.get(key),
                  "reserve-with-timeout %r mutated %s: %r -> %r"
                  % (bound, key, stats_before.get(key), stats_after.get(key)))
    r = cmd(b"peek-ready\r\n")
    if r.startswith(b"FOUND"):
        read_bytes(sock, int(r.split()[2]) + 2)  # drain FOUND body before continuing
    if not r.startswith(b"FOUND " + job_id + b" "):
        failures.append("reserve-with-timeout %r: job %s left the ready queue (got %r)"
                        % (bound, job_id, r))
    if cmd(b"delete " + job_id + b"\r\n") != b"DELETED\r\n":
        failures.append("reserve-with-timeout %r: job %s could not be cleaned up"
                        % (bound, job_id))

# --- valid non-negative bounds must keep their reserve semantics ---
# The RESERVED line reports the declared body size (10 for "valid-zero",
# 9 for "valid-one" — the body's trailing CRLF is the put terminator).
job_id = put_ready_job(b"valid-zero\r\n")
r = cmd(b"reserve-with-timeout 0\r\n")
if r != b"RESERVED " + job_id + b" 10\r\n":
    failures.append("valid reserve-with-timeout 0: expected RESERVED %s 10 (got %r)"
                    % (job_id, r))
else:
    read_bytes(sock, 10 + 2)  # drain the reserved body plus CRLF
if cmd(b"touch " + job_id + b"\r\n") != b"TOUCHED\r\n":
    failures.append("valid reserve-with-timeout 0: reserved job not touchable")

job_id = put_ready_job(b"valid-one\r\n")
r = cmd(b"reserve-with-timeout 1\r\n")
if r != b"RESERVED " + job_id + b" 9\r\n":
    failures.append("valid reserve-with-timeout 1: expected RESERVED %s 9 (got %r)"
                    % (job_id, r))
else:
    read_bytes(sock, 9 + 2)  # drain the reserved body plus CRLF

sock.close()

if failures:
    for f in failures:
        print("reserve-timeout regression: " + f, file=sys.stderr)
    raise SystemExit(2)
PY
}

echo "Checking malformed reserve-with-timeout bounds are rejected and leave the queue unmutated..."
check_reserve_timeout_bounds "$PORT"
echo "PASS: malformed reserve-with-timeout bounds return BAD_FORMAT and the queue is unmutated."
