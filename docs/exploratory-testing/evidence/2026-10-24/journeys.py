#!/usr/bin/env python3
"""Replay: python3 journeys.py [image]; Docker resources are isolated and removed."""
import hashlib
import json
import socket
import subprocess
import sys
import time
import uuid

IMAGE = sys.argv[1] if len(sys.argv) > 1 else 'beanstalkd-et-20261024:run'
PREFIX = 'beanstalkd-et-' + uuid.uuid4().hex[:12]
containers, volumes = [], []


def docker(*args):
    p = subprocess.run(['docker', *args], capture_output=True, text=True)
    print('$ docker', ' '.join(args), 'exit=', p.returncode, flush=True)
    if p.stdout.strip():
        print(p.stdout.strip(), flush=True)
    if p.stderr.strip():
        print(p.stderr.strip(), flush=True)
    p.check_returncode()
    return p.stdout.strip()


class Client:
    def __init__(self, port):
        self.s = socket.create_connection(('127.0.0.1', port), timeout=4)
        self.f = self.s.makefile('rb')

    def close(self):
        self.f.close()
        self.s.close()

    def response(self):
        line = self.f.readline()
        if not line:
            raise EOFError('server closed connection')
        parts = line.split()
        if parts[0] in (b'OK', b'FOUND', b'RESERVED'):
            n = int(parts[-1])
            body = self.f.read(n)
            assert len(body) == n and self.f.read(2) == b'\r\n'
            if parts[0] == b'OK':
                print('<', line.strip(), body.decode().strip(), flush=True)
            else:
                print('<', line.strip(), 'sha256=' + hashlib.sha256(body).hexdigest(), flush=True)
            return line.strip().decode(), body
        print('<', line.strip(), flush=True)
        return line.strip().decode(), None

    def cmd(self, line):
        print('>', repr(line), flush=True)
        self.s.sendall(line.encode() + b'\r\n')
        return self.response()

    def expect(self, line, expected):
        reply, _ = self.cmd(line)
        assert reply == expected, (line, reply, expected)

    def put(self, body, pri=0, delay=0, ttr=10, split=False):
        header = f'put {pri} {delay} {ttr} {len(body)}'
        print('>', header, 'sha256=' + hashlib.sha256(body).hexdigest(), 'split=', split, flush=True)
        if split:
            self.s.sendall(header.encode() + b'\r')
            time.sleep(.03)
            self.s.sendall(b'\n' + body[:3])
            time.sleep(.03)
            self.s.sendall(body[3:] + b'\r\n')
        else:
            self.s.sendall(header.encode() + b'\r\n' + body + b'\r\n')
        reply, _ = self.response()
        assert reply.startswith('INSERTED '), reply
        return int(reply.split()[1])

    def stats(self, jid):
        reply, body = self.cmd(f'stats-job {jid}')
        assert reply.startswith('OK ')
        return dict(line.split(': ', 1) for line in body.decode().splitlines() if ': ' in line)


def start(suffix, *args, persistent=False):
    name = PREFIX + '-' + suffix
    opts = []
    if persistent:
        volume = name + '-data'
        volumes.append(volume)
        docker('volume', 'create', '--label', 'exploration=' + PREFIX, volume)
        opts += ['-v', volume + ':/data']
    containers.append(name)
    docker('run', '-d', '--name', name, '--label', 'exploration=' + PREFIX,
           '-p', '127.0.0.1::11300', *opts, IMAGE, 'beanstalkd', *args)
    return name, connect(name)


def connect(name):
    binding = json.loads(docker('inspect', '--format', '{{json .NetworkSettings.Ports}}', name))['11300/tcp'][0]
    port = int(binding['HostPort'])
    for _ in range(40):
        try:
            return Client(port)
        except OSError:
            time.sleep(.1)
    raise RuntimeError('daemon not ready')


def restart(name, client):
    client.close()
    docker('restart', '-t', '3', name)
    return connect(name)


try:
    print('JOURNEY 1: workers isolate paused queues; pause correction and recovery', flush=True)
    name, producer = start('queues')
    producer.expect('use email', 'USING email')
    email = producer.put(b'email invoice\x00\r\nopaque', ttr=2)
    producer.expect('use audit', 'USING audit')
    audit = producer.put(b'audit invoice', pri=100)
    worker = connect(name)
    worker.expect('watch email', 'WATCHING 2')
    worker.expect('watch audit', 'WATCHING 3')
    worker.expect('ignore default', 'WATCHING 2')
    producer.expect('pause-tube email 30', 'PAUSED')
    reply, body = worker.cmd('reserve-with-timeout 0')
    assert reply == f'RESERVED {audit} 13' and body == b'audit invoice'
    worker.expect(f'delete {audit}', 'DELETED')
    worker.expect('reserve-with-timeout 0', 'TIMED_OUT')
    for bad in ('-1', '4294967296', '1garbage'):
        producer.expect('pause-tube email ' + bad, 'BAD_FORMAT')
    # A rejected pause must not unpause the queue or change the job.
    worker.expect('reserve-with-timeout 0', 'TIMED_OUT')
    producer.expect('pause-tube email 0', 'PAUSED')
    reply, body = worker.cmd('reserve-with-timeout 0')
    assert reply.startswith(f'RESERVED {email} ') and body == b'email invoice\x00\r\nopaque'
    time.sleep(1.1)
    worker.expect(f'touch {email}', 'TOUCHED')
    time.sleep(1.1)
    assert producer.stats(email)['state'] == 'reserved'
    worker.close()  # disconnected worker: another worker can retry immediately
    retry = connect(name)
    retry.expect('watch email', 'WATCHING 2')
    retry.expect('ignore default', 'WATCHING 1')
    reply, body = retry.cmd('reserve-with-timeout 1')
    assert reply.startswith(f'RESERVED {email} ') and body == b'email invoice\x00\r\nopaque'
    retry.expect(f'delete {email}', 'DELETED')
    producer.expect(f'peek {email}', 'NOT_FOUND')
    retry.close()
    producer.close()
    print('PASS JOURNEY 1', flush=True)

    print('JOURNEY 2: custom size limit + opaque data persist across restarts', flush=True)
    name, client = start('wal', '-b', '/data', '-f', '0', '-z', '1000', '-s', '4096', persistent=True)
    bodies = [b'', bytes(range(256)), b'x' * 998, b'y' * 999, b'z' * 1000, b'after-boundary']
    jobs = [client.put(body, pri=i, split=(i == 1)) for i, body in enumerate(bodies)]
    client.expect(f'reserve-job {jobs[1]}', f'RESERVED {jobs[1]} 256')
    client.expect(f'bury {jobs[1]} 7', 'BURIED')
    before = client.stats(jobs[1])
    for attempt in range(2):
        client = restart(name, client)
        for jid, body in zip(jobs, bodies):
            reply, actual = client.cmd(f'peek {jid}')
            assert reply == f'FOUND {jid} {len(body)}' and actual == body
        after = client.stats(jobs[1])
        for key in ('state', 'pri', 'reserves', 'buries', 'kicks'):
            assert before[key] == after[key], (key, before, after)
    client.expect(f'delete {jobs[-1]}', 'DELETED')
    client = restart(name, client)
    client.expect(f'peek {jobs[-1]}', 'NOT_FOUND')
    client.expect(f'kick-job {jobs[1]}', 'KICKED')
    reply, actual = client.cmd(f'reserve-job {jobs[1]}')
    assert actual == bodies[1]
    client.expect(f'delete {jobs[1]}', 'DELETED')
    client.close()
    print('PASS JOURNEY 2', flush=True)

    print('JOURNEY 3: producer recovers after rejected payloads on same connection', flush=True)
    name, client = start('recovery', '-z', '1000')
    print('> pipelined oversize put (1001 bytes) then valid put (2 bytes)', flush=True)
    client.s.sendall(b'put 0 0 10 1001\r\n' + b'a' * 1001 + b'\r\nput 0 0 10 2\r\nok\r\n')
    assert client.response()[0] == 'JOB_TOO_BIG'
    reply, _ = client.response()
    jid = int(reply.split()[1])
    reply, body = client.cmd('reserve-with-timeout 0')
    assert reply == f'RESERVED {jid} 2' and body == b'ok'
    client.expect(f'delete {jid}', 'DELETED')
    print('> malformed size followed by corrected put', flush=True)
    client.expect('put 0 0 10 1001 garbage', 'BAD_FORMAT')
    jid = client.put(b'corrected', split=True)
    reply, body = client.cmd('reserve-with-timeout 0')
    assert reply == f'RESERVED {jid} 9' and body == b'corrected'
    client.expect(f'delete {jid}', 'DELETED')
    print('> invalid body terminator followed by same-connection retry', flush=True)
    client.s.sendall(b'put 0 0 10 2\r\nabXX')
    assert client.response()[0] == 'EXPECTED_CRLF'
    jid = client.put(b'retried')
    reply, body = client.cmd('reserve-with-timeout 0')
    assert reply == f'RESERVED {jid} 7' and body == b'retried'
    client.expect(f'delete {jid}', 'DELETED')
    client.expect('peek-ready', 'NOT_FOUND')
    client.close()
    print('PASS JOURNEY 3', flush=True)
finally:
    for name in containers:
        try:
            docker('logs', name)
        finally:
            docker('rm', '-fv', name)
    for volume in volumes:
        docker('volume', 'rm', volume)
    print('CLEANUP: all replay containers and volumes removed', flush=True)
