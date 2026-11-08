---
name: verify-wal-replay
description: Verify beanstalkd WAL replay size acceptance and rejection with CBMC after changes to replay patches, upstream source, job size limits, or stored body representation.
---

# Verify WAL replay sizes

A fresh full WAL record must replay exactly when its stored body size minus the two CRLF bytes fits the configured limit. Rejecting a valid record stops replay of the rest of that binlog and can lose later jobs.

## Run the check

From the repository root, run:

```sh
python3 .agents/skills/verify-wal-replay/scripts/verify.py
```

Use Python 3.9 or newer, `curl`, `tar`, `patch`, a SHA-256 utility, and CBMC 6.11.0. Install CBMC with `brew install cbmc` on macOS if that formula supplies 6.11.0. Otherwise install the matching build from the [CBMC 6.11.0 release](https://github.com/diffblue/cbmc/releases/tag/cbmc-6.11.0). The runner rejects other versions. Source reconstruction requires network access to GitHub.

The runner calls `ct-tests/prepare-source.sh`, the same source-preparation script used by the Docker build. That script verifies the archive checksum and applies `patches/series` in order. It extracts complete `readrec`, `readrec5`, and `readfull` bodies verbatim from patched `file.c`. It also extracts the legacy record declaration and uses upstream `dat.h`. No reader condition is copied into the harness.

Expect `baseline: PASS`. The printed evidence directory contains reconstructed source, extracted C, exact commands, patch hashes, tool version, and CBMC JSON results. To select a new empty evidence directory, append `--output /tmp/beanstalkd-wal-check`.

## Check a change

1. Compare the coverage files below against the sync commit before trusting a pass.
2. Confirm that extraction still includes the complete readers and that the harness substitutes still match their dependencies.
3. Confirm that `dispatch_cmd` still stores the accepted body length plus two and that `optparse` still bounds the size limit.
4. Run the command above.
5. After a harness or covered-code change, run the same command with `--self-test`.
6. Advance the sync commit only after confirming that the verification describes the code at the new commit.

The self-test first checks the current code. It then edits each actual reader in reconstructed scratch `file.c` independently. Removing `+ 2` must fail `legal stored size replays`. Changing the allowance to `+ 3` must fail `oversize rejected before allocation`. Each failure must be a CBMC assertion violation, not a tool error. The runner restores the source in a `finally` block and checks the baseline again. It never edits product files in the checkout.

## Interpret a result

For a failure, open `result.json` in the named run directory. Find a property with `status` equal to `FAILURE`. Follow its trace through `job_data_size_limit`, `stored_size`, `legacy`, the reader, and `result`. `legacy` selects `readrec5` when true.

The demonstrated current-format regression has limit 1,073,741,824 and stored size 1,073,741,826. The body fits the limit. Without the CRLF allowance, `readrec` enters `Error` and returns zero. `fileread` then stops its loop before later records. The legacy regression exhibits the same failure in `readrec5`.

If the trace violates the record assumptions below, correct the harness and repeat the mutation checks. If it is a real reader failure, report it in code terms and retain the trace. Do not weaken an assertion to make the result pass. Do not fix product code without a request to do so.

For an intended format or size-policy change, update the property, extraction, substitutes, and scope together. Keep both acceptance and rejection mutation-sensitive. Use `/maintain-formal-verification-skill` to reconcile changes that skipped this check.

## Coverage and assumptions

Last source sync commit is `25e8d389bdcafec8dc35d289456a9f6f26f27181`.

| Source | Covered behavior or reviewed assumption |
| --- | --- |
| `Dockerfile`, `ct-tests/run.sh`, `ct-tests/prepare-source.sh`, `ct-tests/apply-patches.sh`, `patches/series` | Shared upstream v1.13 source preparation, SHA-256 verification, patch order |
| `patches/replay-max-job-size.patch` | Size checks in both replay readers |
| Reconstructed `file.c`, `readrec`, `readrec5`, `readfull` | Complete reader control flow for a fresh full record |
| Reconstructed `dat.h`, `Jobrec`, `JOB_DATA_SIZE_LIMIT_MAX` | Actual types and maximum size constant |
| Reconstructed `prot.c`, `dispatch_cmd`, `OP_PUT` | Reviewed assumption that stored size is body length plus two, not symbolically executed |
| Reconstructed `util.c`, `optparse` | Reviewed assumption that the configured limit is clamped, not symbolically executed |
| Reconstructed `file.c`, `fileread` | Reviewed consequence that a zero reader return stops replay, not symbolically executed |
| `ct-tests/replay-max-job-size.c` | Complementary daemon restart tests, not run by this skill |

Upstream archive SHA-256 is `26292dcdc0a7011d2f8ad968612f2cd8b2ef07687224876015399ae85e9e5263`.

The harness checks the following scope:

- A 64-bit C data model with 32-bit `int` and 64-bit `size_t`.
- Every configured limit from zero through 1,073,741,824 bytes.
- Every stored size from 2 through `INT32_MAX`, including oversize records.
- Both WAL record formats and Ready, Reserved, Buried, and Delayed states.
- One fresh full record with ID 1, a one-byte tube name, and no existing job. Other record fields start at zero.
- Successful complete reads and allocation. The body-read substitute returns the requested count without copying body bytes. List and file bookkeeping are substitutes.

`replay.c` asserts acceptance with one allocation and one body read for legal sizes. It asserts rejection before allocation and body reads for oversize records. CBMC also checks generated safety properties. Loop unwinding is one with unwinding assertions enabled. A failed unwinding assertion is an incomplete proof, not a product bug.

The check does not verify arbitrary metadata, existing-job update records, negative or truncated stored sizes, body bytes, allocator behavior, actual queue membership, 32-bit targets, filesystem persistence, crashes, or ordering between multiple records. It does not prove that every job survives restart. Preserve the integration tests for those broader behaviors.

The initial baseline and restored run each passed 399 generated checks with CBMC 6.11.0. All four scratch regressions failed their intended property. A future run may generate a different number of checks after source changes. Judge the assertions and scope, not that count.
