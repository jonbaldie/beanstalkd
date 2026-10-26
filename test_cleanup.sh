#!/usr/bin/env sh
set -eu

# Regression for issue #17: when `docker run` creates a container then fails
# with empty stdout (exit 125), test.sh must still remove that container.
# Regression for issue #23: cleanup must also remove any volumes Docker
# attaches to the created containers (e.g. an anonymous /data volume).

IMAGE="${1:-jonbaldie/beanstalkd:latest}"
REAL_DOCKER=$(command -v docker)
if [ -z "$REAL_DOCKER" ]; then
    echo "FAIL: real docker is required by test_cleanup.sh but was not found in PATH."
    exit 1
fi

. ./tests/harness.sh
harness_init "cleanup-test"

BIN_DIR="$SCRATCH_DIR/bin"
mkdir "$BIN_DIR"

cat >"$BIN_DIR/docker" <<EOF
#!/usr/bin/env sh
set -eu
REAL="$REAL_DOCKER"
LABEL="$OWNER_LABEL"
. "$(pwd)/tests/harness.sh"
RESOURCE_RECEIPT="$RESOURCE_RECEIPT"
if [ "\${1:-}" = run ]; then
    shift
    tmp=\$(mktemp)
    for a in "\$@"; do
        case "\$a" in
            -d|--detach) continue ;;
        esac
        printf '%s\0' "\$a" >> "\$tmp"
    done
    id=\$(xargs -0 "\$REAL" create --label "\$LABEL" -v /receipt-data < "\$tmp")
    rm -f "\$tmp"
    harness_record_container "\$id" /receipt-data
    exit 125
fi
exec "\$REAL" "\$@"
EOF
chmod +x "$BIN_DIR/docker"

OUTPUT_FILE="$SCRATCH_DIR/output"
set +e
PATH="$BIN_DIR:$PATH" ./test.sh "$IMAGE" >"$OUTPUT_FILE" 2>&1
RC=$?
set -e

if [ ! -s "$RESOURCE_RECEIPT" ]; then
    echo "FAIL: failed-create wrapper did not capture its resource receipt."
    cat "$OUTPUT_FILE"
    exit 1
fi
if ! harness_assert_resources_gone; then
    echo "FAIL: test.sh leaked recorded resources after docker run failed post-create (exit $RC)."
    cat "$OUTPUT_FILE"
    exit 1
fi

if [ "$RC" -eq 0 ]; then
    echo "FAIL: expected test.sh to fail when docker run fails post-create (got 0)."
    cat "$OUTPUT_FILE"
    exit 1
fi

if ! grep -Fq "Container logs:" "$OUTPUT_FILE"; then
    echo "FAIL: test.sh did not print container logs after docker run failed post-create."
    cat "$OUTPUT_FILE"
    exit 1
fi

echo "PASS: test.sh removes containers created by a failing docker run."
echo "PASS: test.sh removes anonymous volumes attached to those containers."
