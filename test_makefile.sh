#!/usr/bin/env sh
set -eu

# Regression for issue #65: the Makefile owns the image reference, so
# `make build`, `make test` and `make push` must all use the same IMAGE,
# whether it is the default or an override.

DEFAULT_IMAGE="jonbaldie/beanstalkd:latest"
CUSTOM_IMAGE="example/beanstalkd:issue-65"
FAILED=0

fail() {
    echo "FAIL: $1"
    FAILED=1
}

# Print the recipe lines `make` would run, without running them. Drop the
# parent make's flags so `make test IMAGE=...` cannot override IMAGE here.
recipe() {
    image="$1"
    shift
    if [ -n "$image" ]; then
        env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL IMAGE="$image" \
            make --no-print-directory -n "$@"
    else
        env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u IMAGE \
            make --no-print-directory -n "$@"
    fi
}

expect_line() {
    if ! printf '%s\n' "$1" | grep -Fxq -- "$2"; then
        fail "$3: expected recipe line: $2"
        printf '%s\n' "$1"
    fi
}

check_image() {
    image="$1"
    expected="${image:-$DEFAULT_IMAGE}"
    context="IMAGE=${image:-<unset>}"

    out=$(recipe "$image" build) || fail "$context make build: make -n failed"
    expect_line "$out" "docker build -t $expected ." "$context make build"

    out=$(recipe "$image" test) || fail "$context make test: make -n failed"
    expect_line "$out" "docker build -t $expected ." "$context make test"
    for script in test_cleanup.sh test_volume_isolation.sh test_busy_port.sh \
                  test_name_collision.sh test.sh; do
        expect_line "$out" "./$script \"$expected\"" "$context make test"
    done

    out=$(recipe "$image" push) || fail "$context make push: make -n failed"
    expect_line "$out" "docker push $expected" "$context make push"
}

check_image ""
check_image "$CUSTOM_IMAGE"

# CI must publish through the Makefile rather than naming the tag itself.
if grep -Fq "$DEFAULT_IMAGE" .github/workflows/ci.yml; then
    fail ".github/workflows/ci.yml names $DEFAULT_IMAGE instead of using the Makefile's IMAGE."
fi

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi

echo "PASS: make build, test and push share one IMAGE reference."
