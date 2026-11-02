#!/bin/sh
set -eu
patches=${1:?usage: apply-patches.sh PATCH_DIR SOURCE_DIR}
source=${2:?usage: apply-patches.sh PATCH_DIR SOURCE_DIR}
fail() { echo "patch series: $*" >&2; exit 1; }
[ -f "$patches/series" ] || fail 'missing series'
entries=$(cat "$patches/series")
[ -n "$entries" ] || fail 'empty series'
while IFS= read -r entry || [ -n "$entry" ]; do
    case "$entry" in
        ''|*[!a-z0-9.-]*|.*) fail "invalid entry: $entry" ;;
        *.patch) ;;
        *) fail "not a patch: $entry" ;;
    esac
    [ -f "$patches/$entry" ] || fail "missing patch: $entry"
done < "$patches/series"
[ -z "$(printf '%s\n' "$entries" | sort | uniq -d)" ] || fail 'duplicate entries'
for file in "$patches"/*.patch; do
    [ -f "$file" ] || fail 'no patches'
    printf '%s\n' "$entries" | grep -Fxq "${file##*/}" || fail "unlisted patch: ${file##*/}"
done
patches=$(CDPATH= cd -- "$patches" && pwd)
cd "$source"
while IFS= read -r entry || [ -n "$entry" ]; do
    echo "applying $entry"
    patch --forward --batch -p1 < "$patches/$entry" || fail "failed to apply: $entry"
done < "$patches/series"
