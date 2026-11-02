#!/bin/sh
# Build and check the pinned upstream source, leaving diagnostics in WORKDIR.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=${1:?usage: ct-tests/run.sh NEW_WORKDIR}
mkdir "$work"
work=$(CDPATH= cd -- "$work" && pwd)
echo "ct build and diagnostics: $work"
# Fail inventory validation before downloading or compiling anything.
"$root/ct-tests/assemble.sh" > "$work/extensions.c"
"$root/ct-tests/prepare-source.sh" "$work"
cd "$work/beanstalkd-1.13"
cat "$work/extensions.c" >> testserv.c
# Recent Apple Clang diagnoses an upstream test's constant-sized VLA.
# Keep all other warnings fatal, and leave Linux/Docker flags unchanged.
if [ "$(uname -s)" = Darwin ]; then
    CFLAGS="${CFLAGS:-} -Wno-error=gnu-folding-constant"
    export CFLAGS
fi
make
make check
