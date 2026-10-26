#!/bin/sh
# Validate the complete inventory before emitting helpers and C fragments.
set -eu
suite=${1:-$(dirname "$0")}
fail() { echo "ct-tests: $*" >&2; exit 1; }
[ -f "$suite/series" ] || fail 'missing series'
[ -f "$suite/testserv-helpers.h" ] || fail 'missing testserv-helpers.h'
entries=$(cat "$suite/series")
[ -n "$entries" ] || fail 'empty series'
while IFS= read -r entry || [ -n "$entry" ]; do
    case "$entry" in
        ''|*[!a-z0-9.-]*|.*) fail "invalid entry: $entry" ;;
        *.c) ;;
        *) fail "not a C fragment: $entry" ;;
    esac
    [ -f "$suite/$entry" ] || fail "missing fragment: $entry"
done < "$suite/series"
[ -z "$(printf '%s\n' "$entries" | sort | uniq -d)" ] || fail 'duplicate entries'
for file in "$suite"/*.c; do
    [ -f "$file" ] || fail 'no C fragments'
    printf '%s\n' "$entries" | grep -Fxq "${file##*/}" || fail "unlisted fragment: ${file##*/}"
done
cat "$suite/testserv-helpers.h"
while IFS= read -r entry || [ -n "$entry" ]; do
    cat "$suite/$entry"
done < "$suite/series"
