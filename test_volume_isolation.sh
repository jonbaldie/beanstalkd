#!/usr/bin/env sh
set -eu

# Regression for issue #31: the default-run volume check must not use a
# host-wide volume snapshot as a deletion list. An unrelated volume created
# while that check is running must survive, and the check must still pass.

IMAGE="${1:-jonbaldie/beanstalkd:latest}"
REAL_DOCKER=$(command -v docker)
if [ -z "$REAL_DOCKER" ]; then
    echo "FAIL: real docker is required by test_volume_isolation.sh but was not found in PATH."
    exit 1
fi

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/beanstalkd-volume-isolation-test.XXXXXX")
BIN_DIR="$TEMP_DIR/bin"
OUTPUT_FILE="$TEMP_DIR/output"
RUN_SUFFIX=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
MARKER_VOLUME="beanstalkd-unrelated-volume-$RUN_SUFFIX"
mkdir "$BIN_DIR"

cleanup() {
    "$REAL_DOCKER" volume rm -f "$MARKER_VOLUME" >/dev/null 2>&1 || true
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM

if "$REAL_DOCKER" volume inspect "$MARKER_VOLUME" >/dev/null 2>&1; then
    echo "FAIL: generated marker volume already exists: $MARKER_VOLUME"
    exit 1
fi

cat >"$BIN_DIR/docker" <<EOF
#!/usr/bin/env sh
set -eu
REAL="$REAL_DOCKER"
MARKER="$MARKER_VOLUME"

if [ "\${1:-}" = rm ] && [ "\${2:-}" = -f ]; then
    for arg in "\$@"; do
        case "\$arg" in
            beanstalkd-volume-leak-test-*)
                "\$REAL" volume create "\$MARKER" >/dev/null
                break
                ;;
        esac
    done
fi

exec "\$REAL" "\$@"
EOF
chmod +x "$BIN_DIR/docker"

set +e
PATH="$BIN_DIR:$PATH" ./test.sh "$IMAGE" >"$OUTPUT_FILE" 2>&1
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
    echo "FAIL: test.sh failed while an unrelated volume was created (exit $RC)."
    cat "$OUTPUT_FILE"
    exit 1
fi

if ! "$REAL_DOCKER" volume inspect "$MARKER_VOLUME" >/dev/null 2>&1; then
    echo "FAIL: test.sh deleted the unrelated volume $MARKER_VOLUME."
    cat "$OUTPUT_FILE"
    exit 1
fi

echo "PASS: test.sh ignores an unrelated volume created during the default-run check."
