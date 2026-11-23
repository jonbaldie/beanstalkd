# zlib 1.4 security fixes — applicability to this image (#109)

Date: 2026-11-23. Assessed against `origin/master` at `a4638b4`
(plus the fix in the same change). This document records the per-fix
evidence behind the image change in the same change; it is not a claim
that a version match alone proves exploitability.

## Conclusion

- A **fresh** build (`docker build --no-cache`) already installed
  `zlib-1.4-r0` in the runtime stage, because the Dockerfile runs
  `apk upgrade --no-cache` after `apk add`. The issue baseline was a
  **cached** image: Alpine 3.24.3 with `zlib-1.3.2-r1`.
- Alpine backported **only** CVE-2026-85091 into `1.3.2-r1`. Every other
  zlib 1.4 security fix is present only in `1.4-r0`.
- No installed runtime consumer imports any of the affected zlib
  functions, and `beanstalkd` itself does not link zlib at all. The
  affected code is **present in `libz` but not reachable** through the
  image's runtime binaries. The build stage is the only place an
  affected function (`gzwrite`, via libctf) is imported, and that fix
  is already in `1.3.2-r1`.
- The remaining gap was freshness, not reachability: the build stage
  had no `apk upgrade`, so its zlib stayed at the base image's version
  even on a fresh build, and nothing failed the build if a cached
  layer shipped `1.3.2-r1` in the runtime stage. The fix adds
  `apk upgrade --no-cache` to the build stage and adds the
  `zlib_fixed` integration case, which fails if the installed zlib is
  below `1.4-r0`.

## Fresh-build record

Command: `docker build --no-cache -t local/beanstalkd:issue109-fresh .`
(arm64, linux). Runtime stage upgrade output included:

```
Upgrading libapk (3.0.8-r0 -> 3.0.9-r0)
Upgrading apk-tools (3.0.8-r0 -> 3.0.9-r0)
Upgrading alpine-release (3.24.3-r0 -> 3.24.4-r0)
Upgrading libcrypto3 (3.5.9-r0 -> 3.5.9-r1)
Upgrading libssl3 (3.5.9-r0 -> 3.5.9-r1)
Upgrading zlib (1.3.2-r1 -> 1.4-r0)
```

Installed packages in the fresh runtime image (`apk info -v`):

| Package | Version |
| --- | --- |
| alpine-release | 3.24.4-r0 |
| apk-tools / libapk | 3.0.9-r0 |
| beanstalkd | 1.13-r1 (binary replaced by patched upstream v1.13 build) |
| busybox | 1.37.0-r31 |
| ca-certificates-bundle | 20261020-r0 |
| libcrypto3 / libssl3 | 3.5.9-r1 |
| musl | 1.2.6-r3 |
| scanelf | 1.3.9-r1 |
| zlib | **1.4-r0** (`/usr/lib/libz.so.1 -> libz.so.1.4`) |

Baseline (cached) image for comparison: Alpine 3.24.3, `zlib-1.3.2-r1`,
`apk-tools`/`libapk` 3.0.8-r0, image ID
`sha256:cb12994d…` (arm64). Fresh image ID `sha256:330257ea…` (arm64).

Base image: the local cached `alpine:latest` arm64 digest was
`alpine@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a`
(Alpine 3.24.3) — the same digest recorded in the issue. The remote
`alpine:latest` index at assessment time was
`sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf`
(Alpine 3.24.4). The fresh build reused the cached base layer but
fetched the current repository index at `RUN` time, which is why the
runtime upgrade reached `1.4-r0`.

Repository state at assessment time (Alpine v3.24, `main`, aarch64 and
x86_64 `APKINDEX`): `zlib-1.4-r0`, `libapk`/`apk-tools-3.0.9-r0`.
Alpine secdb (`secdb.alpinelinux.org/v3.24/main.json`, also v3.22,
v3.23 and edge) records for `zlib`:

```
1.3.2-r0: CVE-2026-22184, CVE-2026-27171
1.3.2-r1: CVE-2026-85091
1.4-r0:   CVE-2026-4738
```

## Alpine backports

From the Alpine aports mirror (`alpinelinux/aports`, `main/zlib`):

- `main/zlib: backport fix for CVE-2026-85091` (`ed7d11b`, 2026-10-06)
  added exactly one patch, `CVE-2026-85091.patch`, to 1.3.2 → `1.3.2-r1`.
  The patch is upstream `df84af25` (“Fix buffer overflow bug in
  non-blocking gzwrite”, `gzwrite.c` only).
- `main/zlib: security upgrade to 1.4` (`b2950bb`, 2026-11-05) removed
  the patch and set `pkgver=1.4 pkgrel=0` with no patches;
  `3.24-stable` has the same `APKBUILD`.
- No other 1.4 fix was backported to `1.3.2-r1`.

So a `1.3.2-r1` image has the `gzwrite` fix but not the other fixes
below; a `1.4-r0` image has all of them.

## Per-fix assessment

Sources: [zlib 1.4 release notes](https://github.com/madler/zlib/releases/tag/v1.4)
(2026-11-04), upstream 1.3.2→1.4 source diff, Alpine secdb/APKINDEX/
aports as above. “Present” means the symbol is exported by the installed
`libz.so.1`; “reachable” means an installed binary imports it.

Installed runtime zlib consumers (ELF `NEEDED`, via `scanelf -n` and
host `nm -D --undefined-only` on the extracted binaries):

- `/sbin/apk` — imports `inflate`, `inflateEnd`, `inflateInit2_`,
  `uncompress` (plus apk-internal `adb_*` wrappers).
- `/usr/lib/libapk.so.3.0.0` — imports `deflate`, `deflateEnd`,
  `deflateInit2_`, `inflate`, `inflateEnd`, `inflateInit2_`.
- `/usr/bin/beanstalkd` — `NEEDED` is only `libc.musl-aarch64.so.1`;
  no zlib import at all.

apk-tools v3.0.8 source (`src/applet.c`, `src/io_gunzip.c`,
`src/app_fetch.c`) calls only `inflateInit2`, `inflate`, `inflateEnd`,
`deflate`, `deflateInit2`, `deflateEnd` and `uncompress`, matching the
binary symbols; the fresh 3.0.9 binaries import the same set.

| zlib 1.4 security fix | Alpine fixed in | Present in `libz` 1.3.2-r1? | Reachable in this image? |
| --- | --- | --- | --- |
| Non-blocking `gzwrite()` overflow, CVE-2026-85091 / TOB-ZLIB-003 (`gzwrite.c: gz_write`) | `1.3.2-r1` (backport) and `1.4-r0` | Yes, exported | Runtime: no (no consumer imports `gzwrite`). Build stage: yes, `libctf-nobfd` (binutils, pulled by gcc) imports `gzwrite` — but the fix is in `1.3.2-r1`, so both baseline and fresh builds are fixed. |
| `inflateGetDictionary()` up to 8 MB write past 32K buffer, THM-ZLIB-001, affects 1.2.8–1.3.2 (needs invalid window header, then `inflateReset()`/`inflateSync()`) | `1.4-r0` only | Yes, exported | No. No installed binary imports `inflateGetDictionary`, `inflateReset` or `inflateSync`; apk uses `inflateInit2`+`inflate` only, so the preconditions cannot be met through installed consumers. |
| `inflateSync()` before window size known, TOB-ZLIB-004 | `1.4-r0` only | Yes, exported | No. `inflateSync` is not imported by any installed binary (runtime or build stage). |
| `inflatePrime()` makes `inflate()` read before input, TOB-ZLIB-014 | `1.4-r0` only | Yes, exported | No. `inflatePrime` is not imported anywhere in the image. |
| Repeated `deflatePrime()` writes past pending buffer, TOB-ZLIB-013 | `1.4-r0` only | Yes, exported | No. `deflatePrime` is not imported anywhere in the image. |
| `inflateBack()` does not detect too-far distances, copies uninitialised memory (`infback.c`) | `1.4-r0` only | Yes, exported (`inflateBack`) | No. Neither `inflateBack` nor `inflateBackInit_` is imported; apk uses `inflate`, not `inflateBack`. |
| `gzseek()` forward before any write writes uninitialised memory (`gzlib.c`) | `1.4-r0` only | Yes, exported | No. `gzseek` is not imported anywhere in the image. |
| `deflateResetKeep()` used mid-stream reads outside window (`deflate.c`) | `1.4-r0` only | Yes, exported | No. `deflateResetKeep` is not imported anywhere in the image. |
| `gzdopen()` close-on-exec flag, TOB-ZLIB-008 (`gzlib.c`) | `1.4-r0` only | Yes, exported | No. `gzdopen` is not imported (gcc uses `gzopen`, a different function). Low severity in any case. |
| minizip: double free in `block_central_name()`, NULL dereference in `zipAlreadyThere()`, extra-field/Zip64 validation, miniunz path traversal (`contrib/minizip`) | `1.4-r0` only | No — contrib code is not built into the Alpine `zlib` package | No. No minizip/miniunz/libminizip in the image. `/usr/bin/unzip` is busybox unzip (musl only), not minizip. |
| contrib/infback9 out-of-bounds pointer arithmetic in `inftree9.c`, CVE-2026-4738 | `1.4-r0` (Alpine secdb mapping) | No — contrib code is not in the installed `libz.so.1.4` | No. No infback9 files or binaries in the image. |
| (secdb, not in 1.4 list) CVE-2026-22184: `untgz` contrib utility buffer overflow | `1.3.2-r0` | No — `untgz` is not installed | No; also fixed in both baseline and fresh (1.3.2+). |
| (secdb, not in 1.4 list) CVE-2026-27171: `crc32_combine64` CPU consumption | `1.3.2-r0` | Yes, exported | Fixed in both baseline and fresh (1.3.2+); no consumer was found importing `crc32_combine64`. |

Core `inflate()`/`deflate()` note: the upstream 1.3.2→1.4 diff for
`inflate.c`/`deflate.c`/`infback.c` confines the security changes to
the helper functions above (plus non-security bug fixes such as
`total_in` on `Z_NEED_DICT` and the `inflateFast` `bits < 8` guard).
There is no core `inflate()`/`deflate()` overflow fix that would affect
libapk's plain `inflate`/`deflate` use without those helpers.

Build-stage consumers (for completeness; the stage is discarded except
for the copied `/beanstalkd` binary): `curl`/`libcurl` (`inflate`,
`inflateReset2`), binutils `as`/`readelf`/`dwp` (`deflate`, `inflate`,
`compress`, `uncompress`, `inflateReset`; `libctf` also `gzwrite`),
gcc `cc1`/`lto1` (`gzopen`, `gzputs`, `deflate`, `inflate`), and
apk/libapk as above. The only affected-function import in the build
stage is `libctf`'s `gzwrite`, fixed in `1.3.2-r1`. Build-stage inputs
are the Alpine repository (signed index, via libapk) and the
checksum-verified upstream beanstalkd tarball (`curl -fL`, then
SHA-256 checked in `ct-tests/prepare-source.sh`; `tar` is busybox tar
with no libz dependency). Neither path was shown to feed untrusted
data to an affected function.

## Verification

- Phase-1 loop (red-capable): a check that asserts installed
  `zlib >= 1.3.2-r1` (CVE-2026-85091) and `>= 1.4-r0`
  (CVE-2026-4738) plus the consumer/symbol inventory. It was RED on
  the cached baseline (`zlib-1.3.2-r1`) and GREEN on the fresh build
  (`zlib-1.4-r0`).
- Regression test: `test.sh --test zlib_fixed` (also in the full
  suite) runs the same `>= 1.4-r0` assertion inside the running
  daemon container, so a stale-cache image fails `make test`.
- After the fix, `make test` (full Makefile suite: patch series,
  C tests, CLI tests, resource tests, and the full integration suite
  including protocol and WAL restart as the `beanstalk` user) was
  run against a fresh rebuild; see the run log / PR for the recorded
  output. The build-stage `apk upgrade` was verified to leave the
  build-stage `zlib` at the repository version instead of the base
  image's version.

## Residual uncertainty

- The symbol-import audit covers the installed ELF binaries in the
  fresh and baseline images at assessment time. It is not a complete
  call-graph proof: a future package that imports an affected function
  would need re-assessment. The `zlib_fixed` case guards the version,
  not future reachability.
- Alpine's per-CVE mapping lists only CVE-2026-85091 and
  CVE-2026-4738 for zlib; the other 1.4 fixes above have no CVE numbers
  in the release notes and are tracked here by their upstream
  identifiers. Their Alpine fixed version is inferred from the aports
  history (no backport patches) rather than a per-CVE secdb entry.
- `security.alpinelinux.org` returned 406/500 during the assessment;
  secdb, APKINDEX and the aports mirror were used instead and agree
  with each other.
- The base remains the floating `alpine` tag. The assessment covers
  the Alpine 3.24 branch that tag currently resolves to; if the tag
  moves to a new branch, the secdb fixed versions and this assessment
  should be re-checked. The `zlib_fixed` case will still fail if the
  installed zlib drops below `1.4-r0`.
