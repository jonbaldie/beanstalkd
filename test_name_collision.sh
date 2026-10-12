#!/usr/bin/env sh
set -eu

# Regression for issue #30: test.sh derived every Docker resource name from $$
# alone and its cleanup force-removed those names unconditionally. A volume or
# container a user already owns under the same name was therefore adopted and
# then destroyed. Resource names must carry a random component, and cleanup
# must only remove resources this invocation actually created.
#
# `exec ./test.sh` below is load-bearing: it keeps test.sh on the same PID as
# the shell that pre-created the colliding resources, which is exactly the PID
# collision the issue describes.

. ./tests/harness.sh
harness_init "name-collision"

IMAGE="${1:-jonbaldie/beanstalkd:latest}"
OUTPUT_FILE="$SCRATCH_DIR/output"

set +e
sh -c '
    image="$1"
    owner_label="$2"
    docker volume create --label "$owner_label" "beanstalkd-persistence-test-$$" >/dev/null
    docker run -d --label "$owner_label" --name "beanstalkd-test-$$" --entrypoint sleep "$image" 300 >/dev/null
    exec ./test.sh "$image"
' sh "$IMAGE" "$OWNER_LABEL" >"$OUTPUT_FILE" 2>&1 &
COLLIDING_PID=$!
wait "$COLLIDING_PID"
RC=$?
set -e

MARKER_VOLUME="beanstalkd-persistence-test-$COLLIDING_PID"
MARKER_CONTAINER="beanstalkd-test-$COLLIDING_PID"

FAILED=0

if ! docker volume inspect "$MARKER_VOLUME" >/dev/null 2>&1; then
    echo "FAIL: test.sh deleted the pre-existing volume $MARKER_VOLUME."
    FAILED=1
fi

if ! docker inspect "$MARKER_CONTAINER" >/dev/null 2>&1; then
    echo "FAIL: test.sh deleted the pre-existing container $MARKER_CONTAINER."
    FAILED=1
fi

if [ "$RC" -ne 0 ]; then
    echo "FAIL: test.sh failed (exit $RC) when resources shared its PID-derived names."
    FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
    cat "$OUTPUT_FILE"
    exit 1
fi

echo "PASS: test.sh neither adopts nor deletes pre-existing resources whose names collide with its PID."
