#!/usr/bin/env sh
# Mutation Testing Audit for Dockerfile
#
# Applies targeted mutations to the Dockerfile one at a time, builds each
# mutated image, and runs the full test suite against it.
#
#   KILLED   = tests caught the mutation       → coverage confirmed
#   SURVIVED = tests passed despite mutation   → testing gap
#
# The script exits non-zero if any mutation survives.

set -e

IMAGE_BASE="jonbaldie/beanstalkd-mutant"
SURVIVED_COUNT=0
KILLED_COUNT=0
REPORT=""

# ---- helpers ----

wait_port_free() {
    # Wait for localhost:11300 to stop accepting connections (up to 10 s)
    i=0
    while nc -z localhost 11300 2>/dev/null && [ "$i" -lt 10 ]; do
        sleep 1
        i=$((i+1))
    done
}

run_mutation() {
    MUTATION_ID="$1"
    DESCRIPTION="$2"
    SED_EXPR="$3"

    IMAGE_TAG="${IMAGE_BASE}:${MUTATION_ID}"

    printf "\n=== Mutation: %s ===\n" "$MUTATION_ID"
    printf "    %s\n" "$DESCRIPTION"

    # Apply mutation to a temp Dockerfile
    sed "$SED_EXPR" Dockerfile > Dockerfile.mutant

    printf "    Mutated Dockerfile:\n"
    sed 's/^/        /' Dockerfile.mutant

    # Build the mutated image
    if ! docker build -t "$IMAGE_TAG" -f Dockerfile.mutant . \
            > "/tmp/mutant_build_${MUTATION_ID}.log" 2>&1; then
        printf "    Result: KILLED (build failed)\n"
        KILLED_COUNT=$((KILLED_COUNT + 1))
        REPORT="${REPORT}KILLED_BUILD | ${MUTATION_ID} | ${DESCRIPTION}\n"
        rm -f Dockerfile.mutant
        return
    fi

    rm -f Dockerfile.mutant

    # Run the test suite against the mutant image; capture exit code without
    # letting set -e abort this script.
    set +e
    ./test.sh "$IMAGE_TAG" > "/tmp/mutant_test_${MUTATION_ID}.log" 2>&1
    TEST_EXIT=$?
    set -e

    docker rmi "$IMAGE_TAG" > /dev/null 2>&1 || true

    # Give port 11300 a moment to release before the next mutation run
    wait_port_free

    if [ "$TEST_EXIT" -eq 0 ]; then
        printf "    Result: ** SURVIVED ** (testing gap!)\n"
        SURVIVED_COUNT=$((SURVIVED_COUNT + 1))
        REPORT="${REPORT}SURVIVED     | ${MUTATION_ID} | ${DESCRIPTION}\n"
    else
        printf "    Result: KILLED (caught by tests)\n"
        KILLED_COUNT=$((KILLED_COUNT + 1))
        REPORT="${REPORT}KILLED       | ${MUTATION_ID} | ${DESCRIPTION}\n"
    fi
}

# ---- run from repo root ----
cd "$(dirname "$0")"

echo "=============================================="
echo "  Dockerfile Mutation Testing Audit"
echo "=============================================="

# M1 — Remove USER directive: process may fall back to root
run_mutation \
    "REMOVE_USER" \
    "Remove 'USER beanstalk' — process may run as root" \
    '/^USER beanstalk/d'

# M2 — Explicitly force root user
run_mutation \
    "SET_ROOT_USER" \
    "Change 'USER beanstalk' to 'USER root'" \
    's/^USER beanstalk$/USER root/'

# M3 — Strip EXPOSE metadata
run_mutation \
    "REMOVE_EXPOSE" \
    "Remove 'EXPOSE 11300' — port not declared in image metadata" \
    '/^EXPOSE/d'

# M4 — Wrong port in CMD: service is unreachable on the expected port
#       Use quoted form s/"11300"/"11301"/ so EXPOSE 11300 (unquoted) is untouched.
run_mutation \
    "WRONG_CMD_PORT" \
    "Change CMD port 11300 → 11301 — service starts but on wrong port" \
    's/"11300"/"11301"/'

# M5 — Corrupt the binary name in CMD: service never starts
run_mutation \
    "CORRUPT_CMD_BINARY" \
    "Rename CMD binary beanstalkd → beanstalkd-invalid — service fails to start" \
    's/"beanstalkd",/"beanstalkd-invalid",/'

# M6 — Skip cleanup: install script left inside the image
run_mutation \
    "SKIP_INSTALL_CLEANUP" \
    "Remove '&& rm install.sh' from RUN — install script remains in image" \
    's/ && rm install.sh//'

# ---- summary ----

echo ""
echo "=============================================="
echo "  RESULTS SUMMARY"
echo "=============================================="
printf "$REPORT"
echo ""
printf "Total mutations : %d\n" "$((SURVIVED_COUNT + KILLED_COUNT))"
printf "Killed          : %d  (tests cover these)\n" "$KILLED_COUNT"
printf "Survived        : %d  (testing gaps)\n" "$SURVIVED_COUNT"
echo ""

if [ "$SURVIVED_COUNT" -gt 0 ]; then
    echo "FAIL: $SURVIVED_COUNT mutation(s) survived — add tests to close these gaps."
    exit 1
else
    echo "PASS: All mutations killed — no testing gaps detected."
fi
