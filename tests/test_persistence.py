#!/usr/bin/env python3
"""Unit tests for the unified WAL replay job persistence conformance seam.

The seam is exercised through stub clients at the beanstalk protocol client
boundary (#51): no daemon or Docker is required. Expected values are
independent literals taken from the WAL regression issues (#61, #66, #67, #70),
not recomputed by the code under test.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tests.beanstalk_client import BeanstalkError
from tests.persistence import (
    PERSISTENCE_CASES,
    check_case_diffs,
    job_snapshot,
    reserve_job_failures,
    setup_bury,
    setup_release,
    setup_reserve_job,
    setup_ttr,
    snapshot_diffs,
)


class StubClient:
    """Records commands and replays queued responses, in order."""

    def __init__(self, responses=(), stats=None, stats_sequence=None):
        self.responses = list(responses)
        self.commands = []
        self.bodies_read = []
        self.closed = False
        self.stats = stats or {}
        self.stats_sequence = list(stats_sequence) if stats_sequence else None

    def cmd(self, line, body=None):
        self.commands.append(line)
        if body is not None:
            self.commands.append(body)
        return self.responses.pop(0)

    def read_exact(self, length):
        self.bodies_read.append(length)
        return b'x' * length

    def stats_job(self, job_id):
        if self.stats_sequence is not None:
            return self.stats_sequence.pop(0)
        return self.stats.get(job_id, {})

    def close(self):
        self.closed = True


class SnapshotTests(unittest.TestCase):
    def test_job_snapshot_decodes_stats_job_fields(self):
        client = StubClient(stats={1: {b'state': b'ready', b'pri': b'10',
                                       b'reserves': b'1', b'releases': b'1'}})
        self.assertEqual(job_snapshot(client, 1),
                         {'state': 'ready', 'pri': '10',
                          'reserves': '1', 'releases': '1'})

    def test_snapshot_diffs_name_job_restart_and_field(self):
        diffs = snapshot_diffs(
            {'state': 'ready', 'pri': '0', 'reserves': '0'},
            {'state': 'ready', 'pri': '10', 'reserves': '1'},
            job_id=1, restart=2)
        self.assertEqual(len(diffs), 2)
        for diff in diffs:
            self.assertIn('job 1', diff)
            self.assertIn('restart 2', diff)
        self.assertIn("'pri'", diffs[0])
        self.assertIn("'10'", diffs[0])
        self.assertIn("'0'", diffs[0])
        self.assertIn("'reserves'", diffs[1])

    def test_snapshot_diffs_report_missing_field(self):
        diffs = snapshot_diffs({'state': 'ready'},
                               {'state': 'ready', 'buries': '1'},
                               job_id=1, restart=1)
        self.assertEqual(len(diffs), 1)
        self.assertIn('buries', diffs[0])
        self.assertIn('missing', diffs[0])

    def test_snapshot_diffs_empty_when_matching(self):
        snapshot = {'state': 'buried', 'buries': '1'}
        self.assertEqual(snapshot_diffs(snapshot, dict(snapshot),
                                        job_id=1, restart=1), [])

    def test_check_case_diffs_missing_job_reports_fields_missing(self):
        class MissingJob(StubClient):
            def stats_job(self, job_id):
                raise BeanstalkError('NOT_FOUND')
        diffs = check_case_diffs(MissingJob(), 'bury_replay', restart=2)
        self.assertEqual(len(diffs), 2)
        for diff in diffs:
            self.assertIn('job 1 restart 2', diff)
            self.assertIn('<missing>', diff)

    def test_check_case_diffs_uses_case_expected_fields(self):
        drifted = StubClient(stats={1: {b'state': b'buried', b'buries': b'2'}})
        diffs = check_case_diffs(drifted, 'bury_replay', restart=1)
        self.assertEqual(len(diffs), 1)
        self.assertIn('buries', diffs[0])
        self.assertIn("'1'", diffs[0])
        self.assertIn("'2'", diffs[0])


class CaseTableTests(unittest.TestCase):
    def test_table_covers_release_bury_and_ttr_cases(self):
        self.assertEqual(set(PERSISTENCE_CASES),
                         {'release_persistence', 'bury_replay',
                          'ttr_timeout_persistence'})

    def test_table_expected_values_and_restart_counts(self):
        # Independent literals from issues #66, #67, #70.
        self.assertEqual(PERSISTENCE_CASES['release_persistence'].expected,
                         {'state': 'ready', 'pri': '10',
                          'reserves': '1', 'releases': '1'})
        self.assertEqual(PERSISTENCE_CASES['release_persistence'].restarts, 1)
        self.assertEqual(PERSISTENCE_CASES['bury_replay'].expected,
                         {'state': 'buried', 'buries': '1'})
        self.assertEqual(PERSISTENCE_CASES['bury_replay'].restarts, 2)
        self.assertEqual(PERSISTENCE_CASES['ttr_timeout_persistence'].expected,
                         {'state': 'ready', 'reserves': '1', 'timeouts': '1'})
        self.assertEqual(PERSISTENCE_CASES['ttr_timeout_persistence'].restarts, 1)

    def test_table_setups_are_callable(self):
        for case in PERSISTENCE_CASES.values():
            self.assertTrue(callable(case.setup))


class SetupTests(unittest.TestCase):
    def test_setup_release_runs_put_reserve_release(self):
        client = StubClient(responses=[b'INSERTED 1\r\n', b'RESERVED 1 5\r\n',
                                       b'RELEASED\r\n'])
        setup_release(client, lambda: StubClient())
        self.assertEqual(client.commands,
                         [b'put 100 0 0 5\r\nhello\r\n', b'reserve\r\n',
                          b'release 1 10 0\r\n'])
        self.assertEqual(client.bodies_read, [7])

    def test_setup_bury_runs_put_reserve_bury(self):
        client = StubClient(responses=[b'INSERTED 1\r\n', b'RESERVED 1 5\r\n',
                                       b'BURIED\r\n'])
        setup_bury(client, lambda: StubClient())
        self.assertEqual(client.commands,
                         [b'put 0 0 0 5\r\nhello\r\n', b'reserve\r\n',
                          b'bury 1 0\r\n'])
        self.assertEqual(client.bodies_read, [7])

    def test_setup_ttr_reserves_on_worker_and_waits_for_ready(self):
        client = StubClient(
            responses=[b'INSERTED 1\r\n'],
            stats_sequence=[{b'state': b'reserved'}, {b'state': b'ready'}])
        worker = StubClient(responses=[b'RESERVED 1 3\r\n'])
        setup_ttr(client, lambda: worker)
        self.assertEqual(client.commands, [b'put 0 0 1 3\r\nttr\r\n'])
        self.assertEqual(worker.commands, [b'reserve\r\n'])
        self.assertTrue(worker.closed)

    def test_setup_reserve_job_runs_three_scenarios(self):
        ok = b'OK\r\n'
        client = StubClient(responses=[
            ok, ok, ok, b'INSERTED 1\r\n', b'RESERVED 1 5\r\n',
            b'BURIED\r\n', b'RESERVED 1 5\r\n', b'RELEASED\r\n',
            ok, ok, ok, b'INSERTED 2\r\n', b'RESERVED 2 5\r\n',
            b'RELEASED\r\n',
            ok, ok, ok, b'INSERTED 3\r\n', b'RESERVED 3 5\r\n',
            b'BURIED\r\n',
        ])
        setup_reserve_job(client, lambda: StubClient())
        joined = b''.join(client.commands)
        for marker in (b'use t1\r\n', b'use t2\r\n', b'use t3\r\n',
                       b'reserve-job 1\r\n', b'reserve-job 2\r\n',
                       b'release 1 0 0\r\n', b'release 2 0 0\r\n',
                       b'bury 3 0\r\n'):
            self.assertIn(marker, joined)


class ReserveJobCheckTests(unittest.TestCase):
    def test_reserve_job_failures_use_snapshot_state(self):
        # Jobs 1-2 ready, job 3 still buried -> exactly one structured diff.
        client = StubClient(
            responses=[
                b'FOUND 1 5\r\n', b'FOUND 2 5\r\n', b'FOUND 3 5\r\n',
                b'USING t\r\n', b'NOT_FOUND\r\n', b'NOT_FOUND\r\n',
                b'USING t\r\n', b'NOT_FOUND\r\n', b'NOT_FOUND\r\n',
                b'USING t\r\n', b'NOT_FOUND\r\n', b'NOT_FOUND\r\n',
                b'USING t\r\n', b'NOT_FOUND\r\n', b'NOT_FOUND\r\n',
            ],
            stats={1: {b'state': b'ready'}, 2: {b'state': b'ready'},
                   3: {b'state': b'buried'}})
        bodies = iter([b'job01\r\n', b'job02\r\n', b'job03\r\n'])
        client.read_exact = lambda length: next(bodies)
        failures = reserve_job_failures(client)
        self.assertEqual(len(failures), 1)
        self.assertIn('job 3', failures[0])
        self.assertIn('state', failures[0])
        self.assertIn('ready', failures[0])
        self.assertIn('buried', failures[0])

    def test_reserve_job_failures_missing_job_is_a_state_diff(self):
        class MissingJobs(StubClient):
            def stats_job(self, job_id):
                raise BeanstalkError('NOT_FOUND')
        client = MissingJobs(responses=[
            b'FOUND 1 5\r\n', b'FOUND 2 5\r\n', b'FOUND 3 5\r\n',
            b'USING t\r\n', b'NOT_FOUND\r\n', b'NOT_FOUND\r\n',
            b'USING t\r\n', b'NOT_FOUND\r\n', b'NOT_FOUND\r\n',
            b'USING t\r\n', b'NOT_FOUND\r\n', b'NOT_FOUND\r\n',
            b'USING t\r\n', b'NOT_FOUND\r\n', b'NOT_FOUND\r\n',
        ])
        bodies = iter([b'job01\r\n', b'job02\r\n', b'job03\r\n'])
        client.read_exact = lambda length: next(bodies)
        failures = reserve_job_failures(client)
        self.assertEqual(len(failures), 3)
        for failure, job_id in zip(failures, (1, 2, 3)):
            self.assertIn('job %d' % job_id, failure)
            self.assertIn('<missing>', failure)


if __name__ == '__main__':
    unittest.main(verbosity=2)
