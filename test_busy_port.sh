#!/usr/bin/env sh
set -eu

# Regression for issue #25: test.sh must succeed when host port 11300 is already
# allocated (another beanstalkd, a leftover mapping, or a concurrent make test).

. ./tests/harness.sh
harness_init "busy-port"

IMAGE="${1:-jonbaldie/beanstalkd:latest}"
OCCUPIER_NAME="beanstalkd-busy-port-$RUN_ID"
OUTPUT_FILE="$SCRATCH_DIR/output"
OCCUPIER_ERR="$SCRATCH_DIR/occupier-err"

if docker run -d --label "$OWNER_LABEL" --name "$OCCUPIER_NAME" -p 127.0.0.1:11300:11300 "$IMAGE" >/dev/null 2>"$OCCUPIER_ERR"; then
    assert_loopback_port "$OCCUPIER_NAME"
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
