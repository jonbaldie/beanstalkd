#!/bin/sh
set -eu
cd "$(dirname "$0")"
work=$(mktemp -d "${TMPDIR:-/tmp}/ct-manifest.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir "$work/tests"
printf 'helpers\n' > "$work/tests/testserv-helpers.h"
printf 'first\n' > "$work/tests/a.c"
printf 'second\n' > "$work/tests/b.c"
printf 'b.c\na.c\n' > "$work/tests/series"
./ct-tests/assemble.sh "$work/tests" > "$work/actual"
printf 'helpers\nsecond\nfirst\n' > "$work/expected"
cmp "$work/expected" "$work/actual"
echo 'PASS: helpers precede fragments in manifest order'

reject() {
    if ./ct-tests/assemble.sh "$work/tests" > "$work/actual" 2> "$work/error"; then
        echo "FAIL: accepted $1" >&2
        exit 1
    fi
    grep -Fq "$2" "$work/error"
    [ ! -s "$work/actual" ]
    echo "PASS: rejects $1 before emitting output"
}
printf 'a.c\na.c\nb.c\n' > "$work/tests/series"
reject duplicates 'duplicate entries'
printf 'a.c\nb.c\nmissing.c\n' > "$work/tests/series"
reject missing 'missing fragment: missing.c'
printf 'a.c\n' > "$work/tests/series"
reject orphans 'unlisted fragment: b.c'
printf '../a.c\nb.c\n' > "$work/tests/series"
reject traversal 'invalid entry'
# A final line without a newline is still an entry.
printf 'b.c\na.c' > "$work/tests/series"
./ct-tests/assemble.sh "$work/tests" > "$work/actual"
cmp "$work/expected" "$work/actual"
