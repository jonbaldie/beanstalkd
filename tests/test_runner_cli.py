#!/usr/bin/env python3
"""Exercise the public runner CLI without Docker or network connections."""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
CASES = {
    'stats': (1, 0, []),
    'non_root': (1, 0, []),
    'install_artifact': (1, 0, []),
    'expose': (0, 0, []),
    'image_size': (0, 0, []),
    'kick_bounds': (1, 0, ['kick_bounds']),
    'persistence': (2, 1, ['put_persistent', 'reserve_persistent']),
    'volume_leak': (1, 0, []),
    'reserve_timeout_bounds': (1, 0, ['reserve_timeout_bounds']),
    'split_buffer': (1, 0, ['split_buffer']),
    'pause_tube_delimiter': (1, 0, ['pause_tube_delimiter']),
    'quit_prefix': (1, 0, ['quit_prefix']),
    'put_oversize_trailing_garbage': (1, 0, ['put_oversize_trailing_garbage']),
    'reserve_job_persistence': (2, 1, ['setup_reserve_job', 'held', 'reserved',
                                       'verify_reserve_job']),
    'release_persistence': (2, 1, ['release_persistence'] * 2),
    'bury_replay': (3, 1, ['bury_replay'] * 3),
    'ttr_timeout_persistence': (2, 1, ['ttr_timeout_persistence'] * 2),
    'max_job_size_replay': (2, 1, ['max_job_size_replay'] * 2),
}


class RunnerCLI(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='beanstalkd-cli-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.addCleanup(self.stop_held_double)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.scratch = self.root / 'scratch'
        self.scratch.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin), TMPDIR=str(self.scratch),
                        RUNNER_FAKE_DIR=str(self.root))
        for key in ('DOCKER_CMD', 'HARNESS_DOCKER_CMD', 'RUNNER_FAKE_MODE'):
            self.env.pop(key, None)
        for command in ('sh', 'od', 'tr', 'mktemp', 'rm', 'sleep', 'awk', 'grep'):
            (self.bin / command).symlink_to(shutil.which(command))
        source = (REPO / 'tests/runner_fake.py').read_text()
        self.fake = self.root / 'docker wrapper with spaces'
        self.fake.write_text('#!' + sys.executable + '\n' + source)
        self.fake.chmod(0o755)
        (self.bin / 'python3').symlink_to(self.fake)
        self.poison = self.bin / 'docker'
        self.poison.write_text('#!/bin/sh\nprintf bypass >>"$RUNNER_FAKE_DIR/bypass"\nexit 97\n')
        self.poison.chmod(0o755)

    def stop_held_double(self):
        held_file = self.root / 'held'
        if held_file.exists():
            pid = json.loads(held_file.read_text())[0]
            held_file.unlink()
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def run_cli(self, *args, env=None, inject=True):
        command = ['./test.sh']
        if inject:
            command += ['--docker-cmd', str(self.fake)]
        result = subprocess.run(command + list(args), cwd=REPO,
                                env=self.env if env is None else env,
                                text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=30)
        self.assertFalse((self.root / 'bypass').exists(), result.stdout)
        return result

    def events(self, kind):
        log = self.root / 'events'
        return [value for event, value in
                (json.loads(line) for line in log.read_text().splitlines())
                if event == kind] if log.exists() else []

    def assert_clean(self):
        state_file = self.root / 'state'
        if state_file.exists():
            self.assertEqual(json.loads(state_file.read_text()),
                             {'containers': {}, 'volumes': {}})
        self.assertEqual(list(self.scratch.iterdir()), [])
        held = self.root / 'held'
        if held.exists():
            pid, _ = json.loads(held.read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
            held.unlink()

    def reset(self):
        self.assert_clean()
        for name in ('events', 'state', 'held'):
            (self.root / name).unlink(missing_ok=True)

    def assert_execution(self, result, names, starts, volumes, clients):
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual([line.removeprefix('Running test: ')
                          for line in result.stdout.splitlines()
                          if line.startswith('Running test: ')], names)
        self.assertIn('PASS:', result.stdout)
        docker = self.events('docker')
        self.assertTrue(docker)
        self.assertEqual({wrapper for wrapper, _ in docker}, {self.fake.name})
        commands = [args for _, args in docker]
        runs = [args for args in commands if args[0] == 'run']
        self.assertEqual(len(runs), starts)
        self.assertEqual(sum(args[:2] == ['volume', 'create'] for args in commands), volumes)
        self.assertEqual([c for c in self.events('client') if c != 'readiness'], clients)
        for args in runs:
            self.assertIn('local/beanstalkd:cli-test', args)
            self.assertIn('127.0.0.1:0:11300', args)
        for args in commands:
            if args[:2] == ['image', 'inspect'] or args[0] == 'history':
                self.assertIn('local/beanstalkd:cli-test', args)
        self.assert_clean()

    def test_every_selector_runs_only_its_case_and_fixtures(self):
        for name, (starts, volumes, clients) in CASES.items():
            with self.subTest(selector=name):
                result = self.run_cli('--test', name, 'local/beanstalkd:cli-test')
                self.assert_execution(result, [name], starts, volumes, clients)
                self.reset()

    def test_full_suite_preserves_order_and_shares_daemon(self):
        result = self.run_cli('local/beanstalkd:cli-test')
        clients = [client for _, _, group in CASES.values() for client in group]
        self.assert_execution(result, list(CASES), 15, 6, clients)

    def test_inherited_port_does_not_skip_shared_fixture(self):
        result = self.run_cli('--test', 'kick_bounds', 'local/beanstalkd:cli-test',
                              env=dict(self.env, PORT='11300'))
        self.assert_execution(result, ['kick_bounds'], 1, 0, ['kick_bounds'])

    def test_invalid_cli_has_no_docker_or_scratch_side_effects(self):
        invalid = [('--test',), ('--test', ''), ('--test', 'unknown'),
                   ('--test', 'stats', '--test', 'stats'),
                   ('--test', 'stats; echo unsafe'), ('--test', '*'),
                   ('--test', '--help'), ('--docker-cmd',),
                   ('--docker-cmd', ''), ('--docker-cmd', '--test'),
                   ('--docker-cmd', str(self.fake), '--docker-cmd', str(self.fake)),
                   ('--unknown',), ('one', 'two'), ('',), ('--', 'one', 'two'),
                   ('one', '--', 'two'), ('--help', '--unknown')]
        for args in invalid:
            with self.subTest(args=args):
                result = self.run_cli(*args, env=dict(self.env, DOCKER_CMD=str(self.fake)),
                                      inject=False)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn('Usage:', result.stdout)
                self.assertEqual(self.events('docker'), [])
                self.assert_clean()

    def test_help_lists_all_selectors_without_dependencies(self):
        (self.bin / 'python3').unlink()
        result = self.run_cli('--help', env=dict(self.env, DOCKER_CMD='/missing'), inject=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual([line.strip() for line in result.stdout.splitlines()
                          if line.startswith('  ')], list(CASES))
        self.assertEqual(self.events('docker'), [])
        self.assert_clean()

    def test_environment_override_and_cli_precedence(self):
        result = self.run_cli('--test', 'expose', env=dict(self.env, DOCKER_CMD=str(self.fake)),
                              inject=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual({name for name, _ in self.events('docker')}, {self.fake.name})
        self.reset()
        result = self.run_cli('--test', 'expose', env=dict(self.env, DOCKER_CMD='/missing'))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual({name for name, _ in self.events('docker')}, {self.fake.name})
        self.assert_clean()

    def test_default_docker_and_image(self):
        self.poison.unlink()
        self.poison.symlink_to(self.fake)
        result = self.run_cli('--test', 'expose', inject=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual({name for name, _ in self.events('docker')}, {'docker'})
        self.assertIn('jonbaldie/beanstalkd:latest', self.events('docker')[0][1])
        self.assert_clean()

    def test_executable_is_one_literal_path(self):
        special = self.root / 'wrapper;$(touch SHOULD_NOT_EXIST)'
        special.symlink_to(self.fake)
        result = self.run_cli('--test', 'expose', '--docker-cmd', str(special), inject=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual({name for name, _ in self.events('docker')}, {special.name})
        self.assert_clean()
        self.reset()
        result = self.run_cli('--test', 'expose', '--docker-cmd', str(self.fake) + ' --flag',
                              inject=False)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('required by test.sh', result.stdout)
        self.assertEqual(self.events('docker'), [])
        self.assert_clean()

    def test_options_after_image_and_end_of_options(self):
        for args in [('local/beanstalkd:cli-test', '--test', 'expose'),
                     ('--test', 'expose', '--', 'local/beanstalkd:cli-test')]:
            result = self.run_cli(*args)
            self.assert_execution(result, ['expose'], 0, 0, [])
            self.reset()

    def test_failures_stop_execution_and_cleanup(self):
        for selector, mode, status in [('stats', 'run_failure', 1),
                                      ('kick_bounds', 'client_failure', 42),
                                      ('reserve_job_persistence', 'stop_failure', 1)]:
            with self.subTest(mode=mode):
                result = self.run_cli('--test', selector,
                                      env=dict(self.env, RUNNER_FAKE_MODE=mode))
                self.assertEqual(result.returncode, status, result.stdout)
                if mode == 'run_failure':
                    self.assertIn('Container logs:', result.stdout)
                if mode == 'client_failure':
                    self.assertNotIn('PASS: malformed kick', result.stdout)
                self.assert_clean()
                self.reset()

    def test_signal_cleanup_reaps_direct_child(self):
        for sig, status in [(signal.SIGTERM, 143), (signal.SIGHUP, 143), (signal.SIGINT, 130)]:
            with self.subTest(signal=sig):
                (self.root / 'stopping').unlink(missing_ok=True)
                proc = subprocess.Popen(['./test.sh', '--test', 'reserve_job_persistence',
                                         '--docker-cmd', str(self.fake)], cwd=REPO,
                                        env=dict(self.env, RUNNER_FAKE_MODE='signal_stop'),
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 10
                    while not (self.root / 'stopping').exists():
                        if proc.poll() is not None or time.monotonic() > deadline:
                            self.fail('runner did not reach held-client restart')
                        time.sleep(0.01)
                    held, parent = json.loads((self.root / 'held').read_text())
                    self.assertEqual(parent, proc.pid)
                    os.kill(held, 0)
                    proc.send_signal(sig)
                    output, _ = proc.communicate(timeout=10)
                    self.assertEqual(proc.returncode, status, output)
                    self.assert_clean()
                finally:
                    if proc.poll() is None:
                        proc.kill()
                        proc.communicate()
                    self.stop_held_double()
                self.reset()


if __name__ == '__main__':
    unittest.main(verbosity=2)
