#!/usr/bin/env sh
set -eu

# Exercise the real cleanup meta-test while another workflow creates a volume
# during its failure-injecting docker create. Only this test owns that volume.
IMAGE="${1:-jonbaldie/beanstalkd:latest}"
REAL_DOCKER=$(command -v docker)
. ./tests/harness.sh
harness_init receipt-regression
FOREIGN="beanstalkd-foreign-$RUN_ID"
mkdir "$SCRATCH_DIR/bin"
cat >"$SCRATCH_DIR/bin/docker" <<EOF
#!/usr/bin/env sh
set -eu
if [ "\${1:-}" = create ]; then
    "$REAL_DOCKER" volume create --label "$OWNER_LABEL" "$FOREIGN" >/dev/null
fi
exec "$REAL_DOCKER" "\$@"
EOF
chmod +x "$SCRATCH_DIR/bin/docker"
if ! PATH="$SCRATCH_DIR/bin:$PATH" ./test_cleanup.sh "$IMAGE" >"$SCRATCH_DIR/output" 2>&1; then
    cat "$SCRATCH_DIR/output"
    echo 'FAIL: concurrent foreign volume caused cleanup verification to fail.'
    exit 1
fi
"$REAL_DOCKER" volume inspect "$FOREIGN" >/dev/null
printf '%s\n' 'PASS: concurrent foreign volume survives cleanup verification.'

# A differently owned invocation cannot admit this named volume to its receipt.
if (OWNER_LABEL="beanstalkd-other=$RUN_ID"; harness_record_volume "$FOREIGN") >"$SCRATCH_DIR/rejected" 2>&1; then
    echo 'FAIL: receipt adopted a named volume without matching ownership.'
    exit 1
fi
[ ! -s "$RESOURCE_RECEIPT" ]

# Retain real resources deliberately. The foreign named mount is NOT owned by
# this receipt even though the new container references it.
OWNED_VOLUME="beanstalkd-receipt-$RUN_ID"
docker volume create --label "$OWNER_LABEL" "$OWNED_VOLUME" >/dev/null
harness_record_volume "$OWNED_VOLUME"
CONTAINER=$(docker create --label "$OWNER_LABEL" -v /receipt-data \
    -v "$FOREIGN:/foreign" "$IMAGE")
harness_record_container "$CONTAINER" /receipt-data
ANONYMOUS=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/receipt-data"}}{{.Name}}{{end}}{{end}}' "$CONTAINER")
[ -n "$ANONYMOUS" ]
# Docker may add its own anonymous-volume marker, but not our ownership label.
[ "$(docker volume inspect --format "{{index .Labels \"${OWNER_LABEL%%=*}\"}}" "$ANONYMOUS")" != "${OWNER_LABEL#*=}" ]
cp -f "$RESOURCE_RECEIPT" "$SCRATCH_DIR/receipt-before"
if harness_assert_resources_gone >"$SCRATCH_DIR/leaks" 2>&1; then
    echo 'FAIL: retained resources were not reported.'
    exit 1
fi
grep -Fq "leaked container $CONTAINER" "$SCRATCH_DIR/leaks"
grep -Fq "leaked volume $ANONYMOUS" "$SCRATCH_DIR/leaks"
grep -Fq "leaked volume $OWNED_VOLUME" "$SCRATCH_DIR/leaks"
cmp "$RESOURCE_RECEIPT" "$SCRATCH_DIR/receipt-before"
docker container inspect "$CONTAINER" >/dev/null
docker volume inspect "$ANONYMOUS" "$OWNED_VOLUME" "$FOREIGN" >/dev/null
printf '%s\n' 'PASS: read-only assertion observes retained container and unlabelled anonymous volume.'

docker rm -f "$CONTAINER" >/dev/null
if harness_assert_resources_gone >"$SCRATCH_DIR/leaks" 2>&1; then
    echo 'FAIL: detached anonymous volume was not reported.'
    exit 1
fi
grep -Fq "leaked volume $ANONYMOUS" "$SCRATCH_DIR/leaks"
if grep -Fq 'leaked container' "$SCRATCH_DIR/leaks"; then
    echo 'FAIL: assertion reported a removed container.'
    exit 1
fi
# Exercise the same receipt teardown on a failing process's EXIT path.
if (trap harness_cleanup_receipt EXIT; exit 1); then
    echo 'FAIL: expected failing teardown fixture.'
    exit 1
fi
harness_assert_resources_gone
docker volume inspect "$FOREIGN" >/dev/null
printf '%s\n' 'PASS: failure teardown removes recorded leftovers but preserves unrelated named mounts.'
