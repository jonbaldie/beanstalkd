#!/usr/bin/env sh
set -eu

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/beanstalkd-test.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

BIN_DIR="$TEMP_DIR/bin"
OUTPUT_FILE="$TEMP_DIR/output"
mkdir "$BIN_DIR"

ln -s "$(command -v sh)" "$BIN_DIR/sh"
ln -s /usr/bin/true "$BIN_DIR/docker"
ln -s /usr/bin/true "$BIN_DIR/sleep"

set +e
PATH="$BIN_DIR" ./test.sh >"$OUTPUT_FILE" 2>&1
RC=$?
set -e

if [ "$RC" -ne 1 ]; then
    echo "FAIL: expected test.sh to exit 1 when python3 is unavailable (got $RC)."
    cat "$OUTPUT_FILE"
    exit 1
fi

if ! grep -Fq "FAIL: 'python3' is required by test.sh but was not found in PATH." "$OUTPUT_FILE"; then
    echo "FAIL: test.sh did not report the missing python3 dependency."
    cat "$OUTPUT_FILE"
    exit 1
fi

if grep -Fq "Starting beanstalkd container" "$OUTPUT_FILE" ||
   grep -Fq "beanstalkd did not respond on port 11300" "$OUTPUT_FILE"; then
    echo "FAIL: test.sh started the daemon or reported a daemon response failure."
    cat "$OUTPUT_FILE"
    exit 1
fi

echo "PASS: test.sh reports missing python3 before starting beanstalkd."
