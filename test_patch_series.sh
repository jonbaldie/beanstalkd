#!/bin/sh
set -eu
cd "$(dirname "$0")"
work=$(mktemp -d "${TMPDIR:-/tmp}/patch-series.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir "$work/patches" "$work/source"
printf 'start\n' > "$work/source/value"
printf '%s\n' '--- a/value' '+++ b/value' '@@ -1 +1 @@' '-start' '+middle' > "$work/patches/z.patch"
printf '%s\n' '--- a/value' '+++ b/value' '@@ -1 +1 @@' '-middle' '+end' > "$work/patches/a.patch"
printf 'z.patch\na.patch' > "$work/patches/series"
./ct-tests/apply-patches.sh "$work/patches" "$work/source" > "$work/output"
[ "$(cat "$work/source/value")" = end ]
echo 'PASS: manifest order and final line without newline'
reject() {
    printf 'start\n' > "$work/source/value"
    if ./ct-tests/apply-patches.sh "$work/patches" "$work/source" > "$work/output" 2> "$work/error"; then
        echo "FAIL: accepted $1" >&2
        exit 1
    fi
    grep -Fq "$2" "$work/error"
    echo "PASS: rejects $1"
}
printf 'z.patch\nz.patch\na.patch\n' > "$work/patches/series"
reject duplicate 'duplicate entries'
[ "$(cat "$work/source/value")" = start ]
printf 'z.patch\nmissing.patch\na.patch\n' > "$work/patches/series"
reject missing 'missing patch: missing.patch'
printf 'z.patch\n' > "$work/patches/series"
reject undeclared 'unlisted patch: a.patch'
printf '../z.patch\na.patch\n' > "$work/patches/series"
reject traversal 'invalid entry'
printf 'a.patch\nz.patch\n' > "$work/patches/series"
reject 'patch that does not apply' 'failed to apply: a.patch'
