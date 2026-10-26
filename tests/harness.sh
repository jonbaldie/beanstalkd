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
    RESOURCE_RECEIPT="$SCRATCH_DIR/resources"
    : >"$RESOURCE_RECEIPT"

    trap harness_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
}

harness_cleanup() {
    if [ -n "${OWNER_LABEL:-}" ]; then
        if command -v docker >/dev/null 2>&1; then
            harness_cleanup_receipt
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

# Record only a known newly-created container. Optional arguments are mount
# destinations the caller explicitly requested as NEW anonymous volumes (e.g.
# create -v /receipt-data), never named/bind mounts or inherited volumes.
# The file crosses process boundaries and is retained unchanged by verification.
harness_record_container() {
    printf 'container %s\n' "$1" >>"$RESOURCE_RECEIPT"
    _receipt_mounts=$(docker inspect --format='{{range .Mounts}}{{if eq .Type "volume"}}{{.Destination}} {{.Name}}{{"\n"}}{{end}}{{end}}' "$1") || return 1
    shift
    for _receipt_destination do
        _receipt_found=false
        while read -r _receipt_path _receipt_volume; do
            if [ "$_receipt_path" = "$_receipt_destination" ] && [ -n "$_receipt_volume" ]; then
                printf 'volume %s\n' "$_receipt_volume" >>"$RESOURCE_RECEIPT"
                _receipt_found=true
            fi
        done <<EOF
$_receipt_mounts
EOF
        if [ "$_receipt_found" != true ]; then
            echo "FAIL: no anonymous fixture volume at $_receipt_destination." >&2
            return 1
        fi
    done
}

# Explicit named volumes require this invocation's label as ownership evidence.
harness_record_volume() {
    _receipt_owner=$(docker volume inspect --format "{{index .Labels \"${OWNER_LABEL%%=*}\"}}" "$1") || return 1
    if [ "$_receipt_owner" != "${OWNER_LABEL#*=}" ]; then
        echo "FAIL: refusing to record unowned volume $1." >&2
        return 1
    fi
    printf 'volume %s\n' "$1" >>"$RESOURCE_RECEIPT"
}

# Query Docker, not receipt contents alone. Verification never deletes resources.
harness_assert_resources_gone() {
    _receipt_result=0
    while read -r _receipt_kind _receipt_id; do
        if docker "$_receipt_kind" inspect "$_receipt_id" >/dev/null 2>&1; then
            echo "FAIL: leaked $_receipt_kind $_receipt_id." >&2
            _receipt_result=1
        fi
    done <"$RESOURCE_RECEIPT"
    return "$_receipt_result"
}

harness_cleanup_receipt() {
    [ -f "${RESOURCE_RECEIPT:-}" ] || return 0
    # Containers first, including their anonymous mounts; then detached volumes.
    for _receipt_type in container volume; do
        while read -r _receipt_kind _receipt_id; do
            [ "$_receipt_kind" = "$_receipt_type" ] || continue
            case "$_receipt_kind" in
                container) docker rm -fv "$_receipt_id" >/dev/null 2>&1 || true ;;
                volume) docker volume rm -f "$_receipt_id" >/dev/null 2>&1 || true ;;
            esac
        done <"$RESOURCE_RECEIPT"
    done
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
