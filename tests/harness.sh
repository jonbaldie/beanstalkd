#!/usr/bin/env sh
# Shared test harness lifecycle helper module for resource isolation,
# scratch directory management, and assertions across meta-tests.

harness_init() {
    _harness_prefix="${1:-test-run}"

    RUN_SUFFIX=$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    if [ -z "$RUN_SUFFIX" ]; then
        echo "FAIL: could not generate a random suffix for test resource names." >&2
        exit 1
    fi

    RUN_ID="$$-$RUN_SUFFIX"
    OWNER_LABEL="beanstalkd-${_harness_prefix}=$RUN_ID"

    SCRATCH_DIR=$(mktemp -d "${TMPDIR:-/tmp}/beanstalkd-${_harness_prefix}.XXXXXX")
    if [ ! -d "$SCRATCH_DIR" ]; then
        echo "FAIL: could not create scratch directory." >&2
        exit 1
    fi
    TEMP_DIR="$SCRATCH_DIR"

    trap harness_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
}

harness_cleanup() {
    if [ -n "${OWNER_LABEL:-}" ]; then
        if command -v docker >/dev/null 2>&1; then
            _owned_containers=$(docker ps -aq --filter "label=$OWNER_LABEL" 2>/dev/null || true)
            for _owned in $_owned_containers; do
                [ -n "$_owned" ] || continue
                docker rm -fv "$_owned" >/dev/null 2>&1 || true
            done
            _owned_volumes=$(docker volume ls -q --filter "label=$OWNER_LABEL" 2>/dev/null || true)
            for _owned in $_owned_volumes; do
                [ -n "$_owned" ] || continue
                docker volume rm -f "$_owned" >/dev/null 2>&1 || true
            done
        fi
    fi
    if [ -n "${SCRATCH_DIR:-}" ] && [ -d "$SCRATCH_DIR" ]; then
        rm -rf "$SCRATCH_DIR"
    fi
}

assert_loopback_port() {
    loopback_container="${1:-}"
    if [ -z "$loopback_container" ]; then
        echo "FAIL: assert_loopback_port requires a container name." >&2
        return 1
    fi
    host_ips=$(docker inspect --format='{{range (index .NetworkSettings.Ports "11300/tcp")}}{{.HostIp}}{{"\n"}}{{end}}' "$loopback_container" 2>/dev/null || true)
    if [ -z "$host_ips" ]; then
        echo "FAIL: $loopback_container did not publish port 11300." >&2
        return 1
    fi
    for host_ip in $host_ips; do
        if [ "$host_ip" != "127.0.0.1" ]; then
            echo "FAIL: $loopback_container published port 11300 on $host_ip instead of loopback." >&2
            return 1
        fi
    done
}
