#!/usr/bin/env sh
set -eu

# Regression for issue #17: when `docker run` creates a container then fails
# with empty stdout (exit 125), test.sh must still remove that container.

IMAGE="${1:-jonbaldie/beanstalkd:latest}"
REAL_DOCKER=$(command -v docker)
if [ -z "$REAL_DOCKER" ]; then
    echo "FAIL: real docker is required by test_cleanup.sh but was not found in PATH."
    exit 1
fi

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/beanstalkd-cleanup-test.XXXXXX")
LABEL="beanstalkd-cleanup-test=$$"
BIN_DIR="$TEMP_DIR/bin"
mkdir "$BIN_DIR"

cleanup() {
    "$REAL_DOCKER" ps -aq --filter "label=$LABEL" | while read -r id; do
        [ -n "$id" ] || continue
        "$REAL_DOCKER" rm -f "$id" >/dev/null 2>&1 || true
    done
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM

cat >"$BIN_DIR/docker" <<EOF
#!/usr/bin/env sh
set -eu
REAL="$REAL_DOCKER"
LABEL="$LABEL"
if [ "\${1:-}" = run ]; then
    shift
    tmp=\$(mktemp)
    for a in "\$@"; do
        case "\$a" in
            -d|--detach) continue ;;
        esac
        printf '%s\0' "\$a" >> "\$tmp"
    done
    xargs -0 "\$REAL" create --label "\$LABEL" < "\$tmp" >/dev/null
    rm -f "\$tmp"
    exit 125
fi
exec "\$REAL" "\$@"
EOF
chmod +x "$BIN_DIR/docker"

OUTPUT_FILE="$TEMP_DIR/output"
set +e
PATH="$BIN_DIR:$PATH" ./test.sh "$IMAGE" >"$OUTPUT_FILE" 2>&1
RC=$?
set -e

LEAKED=$("$REAL_DOCKER" ps -aq --filter "label=$LABEL" || true)
if [ -n "$LEAKED" ]; then
    echo "FAIL: test.sh leaked container(s) after docker run failed post-create (exit $RC):"
    echo "$LEAKED" | while read -r id; do
        [ -n "$id" ] || continue
        "$REAL_DOCKER" ps -a --filter id="$id" --format '{{.ID}} {{.Image}} {{.Status}} {{.Names}}'
    done
    cat "$OUTPUT_FILE"
    exit 1
fi

if [ "$RC" -eq 0 ]; then
    echo "FAIL: expected test.sh to fail when docker run fails post-create (got 0)."
    cat "$OUTPUT_FILE"
    exit 1
fi

echo "PASS: test.sh removes containers created by a failing docker run."
