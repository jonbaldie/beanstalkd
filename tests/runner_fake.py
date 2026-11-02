"""Deterministic process doubles for test.sh's orchestration contract tests.

Protocol correctness remains the responsibility of the real integration cases.
Unknown Docker commands or Python programs fail instead of touching a daemon.
"""

import json
import os
from pathlib import Path
import signal
import sys
import time

root = Path(os.environ['RUNNER_FAKE_DIR'])
args = sys.argv[1:]
mode = os.environ.get('RUNNER_FAKE_MODE', '')


def record(kind, value):
    with (root / 'events').open('a') as log:
        log.write(json.dumps([kind, value]) + '\n')


def finish(value='', status=0):
    if value:
        print(value)
    raise SystemExit(status)


if Path(sys.argv[0]).name == 'python3':
    source = args[1] if args[0] == '-c' else sys.stdin.read()
    if args[0] == '-c' and "s.sendall(b'stats" in source:
        record('client', 'readiness')
        finish()
    if 'threading.Event().wait(120)' in source:
        record('client', 'held')
        (root / 'held').write_text(json.dumps([os.getpid(), os.getppid()]))
        Path(args[2]).write_text('ready\n')
        with open(os.devnull, 'w') as sink:
            os.dup2(sink.fileno(), 1)
            os.dup2(sink.fileno(), 2)
        signal.alarm(30)
        while True:
            signal.pause()
    if 'stats-job 3 is not reserved' in source:
        record('client', 'reserved')
        finish()
    markers = {
        'kick regression:': 'kick_bounds',
        'reserve-timeout regression:': 'reserve_timeout_bounds',
        'split-buffer regression:': 'split_buffer',
        'pause-tube regression:': 'pause_tube_delimiter',
        'quit-prefix regression:': 'quit_prefix',
        'put-oversize-trailing-garbage regression:': 'put_oversize_trailing_garbage',
        'expected INSERTED response': 'put_persistent',
        'expected persisted job body': 'reserve_persistent',
        '# 1. Buried job ->': 'setup_reserve_job',
        'reserve-job WAL persistence regression:': 'verify_reserve_job',
    }
    for marker, case in markers.items():
        if marker in source:
            record('client', case)
            finish(status=42 if mode == 'client_failure' else 0)
    if '("state", "pri", "reserves", "releases")' in source:
        record('client', 'release_persistence')
        finish('state: ready\npri: 10\nreserves: 1\nreleases: 1')
    if '("state", "buries")' in source:
        record('client', 'bury_replay')
        finish('state: buried\nburies: 1')
    if '("state", "reserves", "timeouts")' in source:
        record('client', 'ttr_timeout_persistence')
        finish('state: ready\nreserves: 1\ntimeouts: 1')
    if 'SIZES = [5, 65535, 65534, 65533, 5]' in source:
        record('client', 'max_job_size_replay')
        finish('job 1: 5 bytes intact\njob 2: 65535 bytes intact\n'
               'job 3: 65534 bytes intact\njob 4: 65533 bytes intact\n'
               'job 5: 5 bytes intact\ncurrent-jobs-ready: 5')
    raise SystemExit('unexpected Python client program')

record('docker', [Path(sys.argv[0]).name, args])
state_file = root / 'state'
state = json.loads(state_file.read_text()) if state_file.exists() else {
    'containers': {}, 'volumes': {}}


def save():
    state_file.write_text(json.dumps(state))


def option(flag):
    return args[args.index(flag) + 1]


if args[0] == 'run':
    name = option('--name')
    state['containers'][name] = option('--label')
    save()
    if mode == 'run_failure':
        finish(status=125)
    finish(name)
if args[0] == 'inspect':
    template = ' '.join(args)
    if args[-1] not in state['containers']:
        finish(status=1)
    if '.State.Running' in template:
        finish('true')
    if '.HostIp' in template:
        finish('127.0.0.1')
    if '.HostPort' in template:
        finish('43123')
    if '.Mounts' in template:
        finish()
if args[:2] == ['image', 'inspect']:
    if '.Size' in args[-1]:
        finish('9000000')
    if '.Config.ExposedPorts' in args[-1]:
        finish('{"11300/tcp": {}}')
if args[0] == 'exec':
    if args[2:] == ['ps', '-o', 'user,comm']:
        finish('USER COMMAND\nbeanstalk beanstalkd')
    if args[2:] == ['test', '-f', '/install.sh']:
        finish(status=1)
if args[0] in ('history', 'logs'):
    finish()
if args[0] == 'stop':
    if mode == 'stop_failure':
        finish(status=45)
    if mode == 'signal_stop':
        (root / 'stopping').write_text('ready')
        time.sleep(0.5)
    finish()
if args[0] == 'rm':
    for name in args[1:]:
        state['containers'].pop(name, None)
    save()
    finish()
if args[0] == 'ps':
    label = option('--filter').removeprefix('label=')
    finish('\n'.join(n for n, owner in state['containers'].items() if owner == label))
if args[:2] == ['volume', 'create']:
    state['volumes'][args[-1]] = option('--label')
    save()
    finish(args[-1])
if args[:2] == ['volume', 'inspect']:
    finish(status=0 if args[-1] in state['volumes'] else 1)
if args[:2] == ['volume', 'ls']:
    label = option('--filter').removeprefix('label=')
    finish('\n'.join(n for n, owner in state['volumes'].items() if owner == label))
if args[:2] == ['volume', 'rm']:
    for name in args[2:]:
        state['volumes'].pop(name, None)
    save()
    finish()
raise SystemExit('unexpected Docker command: %r' % args)
