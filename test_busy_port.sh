#!/usr/bin/env sh
set -eu

# Regression for issue #25: test.sh must succeed when host port 11300 is already
# allocated (another beanstalkd, a leftover mapping, or a concurrent make test).

IMAGE="${1:-jonbaldie/beanstalkd:latest}"
OCCUPIER_NAME="beanstalkd-busy-port-$$"
OUTPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/beanstalkd-busy-port.XXXXXX")
OCCUPIER_ERR=$(mktemp "${TMPDIR:-/tmp}/beanstalkd-busy-port-err.XXXXXX")

cleanup() {
    docker rm -f "$OCCUPIER_NAME" >/dev/null 2>&1 || true
    rm -f "$OUTPUT_FILE" "$OCCUPIER_ERR"
}
trap cleanup EXIT HUP INT TERM

assert_loopback_port() {
    host_ips=$(docker inspect --format='{{range (index .NetworkSettings.Ports "11300/tcp")}}{{.HostIp}}{{"\n"}}{{end}}' "$OCCUPIER_NAME")
    if [ -z "$host_ips" ]; then
        echo "FAIL: $OCCUPIER_NAME did not publish port 11300."
        exit 1
    fi
    for host_ip in $host_ips; do
        if [ "$host_ip" != "127.0.0.1" ]; then
            echo "FAIL: $OCCUPIER_NAME published port 11300 on $host_ip instead of loopback."
            exit 1
        fi
    done
}

if docker run -d --name "$OCCUPIER_NAME" -p 127.0.0.1:11300:11300 "$IMAGE" >/dev/null 2>"$OCCUPIER_ERR"; then
    assert_loopback_port
elif grep -q "port is already allocated" "$OCCUPIER_ERR"; then
    docker rm -f "$OCCUPIER_NAME" >/dev/null 2>&1 || true
else
    echo "FAIL: could not occupy host port 11300 to set up the regression."
    cat "$OCCUPIER_ERR"
    exit 1
fi

set +e
./test.sh "$IMAGE" >"$OUTPUT_FILE" 2>&1
RC=$?
set -e

if [ "$RC" -eq 125 ]; then
    echo "FAIL: test.sh exited 125 with host port 11300 already allocated."
    cat "$OUTPUT_FILE"
    exit 1
fi

if [ "$RC" -ne 0 ]; then
    echo "FAIL: test.sh failed with host port 11300 already allocated (exit $RC):"
    cat "$OUTPUT_FILE"
    exit 1
fi

echo "PASS: test.sh succeeds when host port 11300 is already allocated."
