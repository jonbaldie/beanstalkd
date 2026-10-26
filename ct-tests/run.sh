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
curl -fL --retry 3 -o "$work/upstream.tar.gz" \
    https://github.com/kr/beanstalkd/archive/v1.13.tar.gz
expected=26292dcdc0a7011d2f8ad968612f2cd8b2ef07687224876015399ae85e9e5263
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$work/upstream.tar.gz")
else
    actual=$(shasum -a 256 "$work/upstream.tar.gz")
fi
[ "${actual%% *}" = "$expected" ] || { echo 'upstream checksum mismatch' >&2; exit 1; }
tar xzf "$work/upstream.tar.gz" -C "$work"
cd "$work/beanstalkd-1.13"
for patch in "$root"/patches/*.patch; do
    patch -p1 < "$patch"
done
cat "$work/extensions.c" >> testserv.c
# Recent Apple Clang diagnoses an upstream test's constant-sized VLA.
# Keep all other warnings fatal, and leave Linux/Docker flags unchanged.
if [ "$(uname -s)" = Darwin ]; then
    CFLAGS="${CFLAGS:-} -Wno-error=gnu-folding-constant"
    export CFLAGS
fi
make
make check
