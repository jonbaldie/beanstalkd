#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=${1:?usage: prepare-source.sh EXISTING_WORKDIR}
work=$(CDPATH= cd -- "$work" && pwd)
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
"$root/ct-tests/apply-patches.sh" "$root/patches" "$work/beanstalkd-1.13"
