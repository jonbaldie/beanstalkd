"""Unified WAL replay job persistence conformance seam (issue #74).

One table-driven check for "job state survives a persistent-daemon restart":
for each case it runs a setup transition, snapshots ``stats-job`` before the
restart, and after each restart asserts the expected fields are unchanged.
A mismatch is reported as a structured diff naming the job, the restart
number, and each differing field with its expected and actual values,
instead of a whole-text comparison.

This module sits on the shared protocol client (issue #51); the shell runner
in ``test.sh`` owns container lifecycle through the persistent start/restart
helpers (issue #64) and drives this module as::

    python3 -m tests.persistence <case> setup <port>
    python3 -m tests.persistence <case> check <port> <restart>
    python3 -m tests.persistence <case> restarts
"""

import sys
import time
from collections.abc import Callable
from dataclasses import dataclass

from tests.beanstalk_client import BeanstalkClient, BeanstalkError


def job_snapshot(client, job_id):
    """Return ``stats-job <job_id>`` as a ``{field: value}`` text mapping."""
    return {key.decode(): value.decode()
            for key, value in client.stats_job(job_id).items()}


def snapshot_or_empty(client, job_id):
    """Snapshot a job, or ``{}`` if replay dropped it (no ``stats-job``)."""
    try:
        return job_snapshot(client, job_id)
    except BeanstalkError:
        return {}


def snapshot_diffs(snapshot, expected, job_id, restart):
    """Diff ``snapshot`` against ``expected``, one line per differing field."""
    diffs = []
    for field, want in expected.items():
        got = snapshot.get(field)
        if got != want:
            diffs.append(
                "job %d restart %d field '%s': expected '%s', got '%s'"
                % (job_id, restart, field, want,
                   got if got is not None else '<missing>'))
    return diffs


def expect(client, cmd, want):
    """Run ``cmd`` and require exactly ``want`` back, as the old tests did."""
    got = client.cmd(cmd)
    if got != want:
        print("%r returned %r (expected %r)" % (cmd, got, want),
              file=sys.stderr)
        raise SystemExit(1)


# --- Setup transitions -------------------------------------------------
# Each takes the shared client (plus a worker factory for the TTR case,
# whose reservation must expire on a second connection) and performs the
# same command sequence the per-test routines performed before.

def setup_release(client, _open_worker=None):
    expect(client, b"put 100 0 0 5\r\nhello\r\n", b"INSERTED 1\r\n")
    expect(client, b"reserve\r\n", b"RESERVED 1 5\r\n")
    client.read_exact(7)
    expect(client, b"release 1 10 0\r\n", b"RELEASED\r\n")


def setup_bury(client, _open_worker=None):
    expect(client, b"put 0 0 0 5\r\nhello\r\n", b"INSERTED 1\r\n")
    expect(client, b"reserve\r\n", b"RESERVED 1 5\r\n")
    client.read_exact(7)
    expect(client, b"bury 1 0\r\n", b"BURIED\r\n")


def setup_ttr(client, open_worker):
    expect(client, b"put 0 0 1 3\r\nttr\r\n", b"INSERTED 1\r\n")
    worker = open_worker()
    try:
        expect(worker, b"reserve\r\n", b"RESERVED 1 3\r\n")
        worker.read_exact(5)
        # Keep the worker connected without deleting or releasing, so the
        # job returns to ready through TTR expiry rather than disconnection.
        deadline = time.time() + 10
        while job_snapshot(client, 1)["state"] != "ready":
            if time.time() > deadline:
                print("job 1 was not returned to ready after its TTR expired",
                      file=sys.stderr)
                raise SystemExit(1)
            time.sleep(0.2)
    finally:
        worker.close()


def setup_reserve_job(client, _open_worker=None):
    # 1. Buried job -> reserve-job -> release with delay 0
    client.cmd(b"use t1\r\n")
    client.cmd(b"watch t1\r\n")
    client.cmd(b"ignore default\r\n")
    expect(client, b"put 0 0 0 5\r\njob01\r\n", b"INSERTED 1\r\n")
    expect(client, b"reserve\r\n", b"RESERVED 1 5\r\n")
    client.read_exact(7)
    expect(client, b"bury 1 0\r\n", b"BURIED\r\n")
    expect(client, b"reserve-job 1\r\n", b"RESERVED 1 5\r\n")
    client.read_exact(7)
    expect(client, b"release 1 0 0\r\n", b"RELEASED\r\n")

    # 2. Delayed job -> reserve-job -> release with delay 0
    client.cmd(b"use t2\r\n")
    client.cmd(b"watch t2\r\n")
    client.cmd(b"ignore t1\r\n")
    expect(client, b"put 0 3600 60 5\r\njob02\r\n", b"INSERTED 2\r\n")
    expect(client, b"reserve-job 2\r\n", b"RESERVED 2 5\r\n")
    client.read_exact(7)
    expect(client, b"release 2 0 0\r\n", b"RELEASED\r\n")

    # 3. Buried job -> reserve-job -> in-flight during restart. This job is
    # left buried here; the held client (in test.sh) reserves it before the
    # daemon is stopped, as issue #64 requires.
    client.cmd(b"use t3\r\n")
    client.cmd(b"watch t3\r\n")
    client.cmd(b"ignore t2\r\n")
    expect(client, b"put 0 0 3600 5\r\njob03\r\n", b"INSERTED 3\r\n")
    expect(client, b"reserve\r\n", b"RESERVED 3 5\r\n")
    client.read_exact(7)
    expect(client, b"bury 3 0\r\n", b"BURIED\r\n")


# --- Checks ------------------------------------------------------------

@dataclass(frozen=True)
class PersistenceCase:
    setup: Callable[..., None]  # (client, open_worker)
    expected: dict
    restarts: int


PERSISTENCE_CASES = {
    # (setup actions, expected stats-job fields, restarts) per case.
    "release_persistence": PersistenceCase(
        setup=setup_release,
        expected={"state": "ready", "pri": "10",
                  "reserves": "1", "releases": "1"},
        restarts=1),
    "bury_replay": PersistenceCase(
        setup=setup_bury,
        expected={"state": "buried", "buries": "1"},
        restarts=2),
    "ttr_timeout_persistence": PersistenceCase(
        setup=setup_ttr,
        expected={"state": "ready", "reserves": "1", "timeouts": "1"},
        restarts=1),
}


def check_case_diffs(client, case_name, restart):
    """Snapshot job 1 for ``case_name`` and diff it against expectations."""
    case = PERSISTENCE_CASES[case_name]
    # A job dropped by replay has no snapshot; every expected field then
    # reports as missing rather than failing with a traceback.
    snapshot = snapshot_or_empty(client, 1)
    return snapshot_diffs(snapshot, case.expected, job_id=1, restart=restart)


def _peek_tube(client, cmd):
    response = client.cmd(cmd)
    if response.startswith(b"FOUND "):
        size = int(response.split()[2])
        client.read_exact(size + 2)
    return response


def reserve_job_failures(client):
    """Verify the three reserve-job jobs recovered as Ready (issue #61).

    Uses the shared snapshot/diff code for the ``state`` assertion; the
    peek body and empty buried/delayed queue checks are preserved verbatim
    from the original routine because they are not ``stats-job`` fields.
    """
    failures = []
    bodies = {1: b"job01\r\n", 2: b"job02\r\n", 3: b"job03\r\n"}
    for job_id in (1, 2, 3):
        response = client.cmd(b"peek %d\r\n" % job_id)
        if response != b"FOUND %d 5\r\n" % job_id:
            failures.append("job %d peek returned %r (expected FOUND %d 5)"
                            % (job_id, response, job_id))
            continue
        body = client.read_exact(7)
        if body != bodies[job_id]:
            failures.append("job %d body returned %r (expected %r)"
                            % (job_id, body, bodies[job_id]))
        failures.extend(snapshot_diffs(
            snapshot_or_empty(client, job_id), {"state": "ready"},
            job_id=job_id, restart=1))

    for tube in (b"default", b"t1", b"t2", b"t3"):
        client.cmd(b"use " + tube + b"\r\n")
        buried = _peek_tube(client, b"peek-buried\r\n")
        if buried != b"NOT_FOUND\r\n":
            failures.append("tube %s peek-buried returned %r "
                            "(expected NOT_FOUND)" % (tube.decode(), buried))
        delayed = _peek_tube(client, b"peek-delayed\r\n")
        if delayed != b"NOT_FOUND\r\n":
            failures.append("tube %s peek-delayed returned %r "
                            "(expected NOT_FOUND)" % (tube.decode(), delayed))
    return failures


# --- CLI driven by test.sh ---------------------------------------------

def _client(port):
    client = BeanstalkClient("localhost", port, timeout=5)
    client.settimeout(5)
    return client


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) < 2:
        print("usage: tests.persistence <case> <setup|check|restarts> ...",
              file=sys.stderr)
        return 2
    case_name, phase = argv[0], argv[1]

    if case_name == "reserve_job_persistence":
        if phase == "setup":
            with _client(int(argv[2])) as client:
                setup_reserve_job(client)
            return 0
        if phase == "check":
            with _client(int(argv[2])) as client:
                failures = reserve_job_failures(client)
            for failure in failures:
                print("reserve-job WAL persistence regression: " + failure,
                      file=sys.stderr)
            return 2 if failures else 0
        print("unknown phase: %r" % phase, file=sys.stderr)
        return 2

    case = PERSISTENCE_CASES.get(case_name)
    if case is None:
        print("unknown persistence case: %r" % case_name, file=sys.stderr)
        return 2
    if phase == "restarts":
        print(case.restarts)
        return 0
    if phase == "setup":
        port = int(argv[2])
        with _client(port) as client:
            case.setup(client, lambda: _client(port))
        return 0
    if phase == "check":
        port, restart = int(argv[2]), int(argv[3])
        with _client(port) as client:
            diffs = check_case_diffs(client, case_name, restart)
        for diff in diffs:
            print(diff, file=sys.stderr)
        return 1 if diffs else 0
    print("unknown phase: %r" % phase, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
