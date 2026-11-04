#!/usr/bin/env python3
import os
import socket
import subprocess
import time

NAME = os.environ['PASS_NAME']
IMAGE = os.environ['PASS_IMAGE']


def docker(*args):
    result = subprocess.check_output(['docker', *args], text=True).strip()
    print('$ docker', *args, '\n', result, flush=True)
    return result


def ready_port():
    port = int(docker('port', NAME, '11300/tcp').rsplit(':', 1)[1])
    for attempt in range(100):
        try:
            sock = socket.create_connection(('127.0.0.1', port), timeout=1)
            sock.close()
            return port
        except OSError:
            time.sleep(.1)
    raise RuntimeError('daemon did not become ready')


def start(persistent=False):
    args = ['run', '-d', '--name', NAME, '-p', '127.0.0.1::11300']
    if persistent:
        args += ['-v', NAME + ':/data']
    args += [IMAGE]
    if persistent:
        args += ['beanstalkd', '-p', '11300', '-b', '/data', '-f', '0']
    docker(*args)
    return ready_port()


class Client:
    def __init__(self, port):
        self.sock = socket.create_connection(('127.0.0.1', port), timeout=3)
        self.file = self.sock.makefile('rb')

    def cmd(self, command, expected, body=None):
        data = command.encode() + b'\r\n'
        if body is not None:
            data += body + b'\r\n'
        self.sock.sendall(data)
        reply = self.file.readline().decode().rstrip('\r\n')
        print('>', command, 'body=' + repr(body) if body is not None else '', '\n<', reply, flush=True)
        assert reply == expected, (command, reply, expected)
        if reply.startswith(('RESERVED ', 'FOUND ', 'OK ')):
            size = int(reply.split()[-1])
            content = self.file.read(size)
            assert self.file.read(2) == b'\r\n'
            print('< body', repr(content), flush=True)
            return content

    def close(self):
        self.file.close()
        self.sock.close()


def stop():
    docker('rm', '-f', '-v', NAME)


print('Journey 1: priority, tube isolation, delete', flush=True)
port = start()
p, w = Client(port), Client(port)
p.cmd('use alpha', 'USING alpha')
p.cmd('put 100 0 30 3', 'INSERTED 1', b'low')
p.cmd('put 1 0 30 4', 'INSERTED 2', b'high')
w.cmd('reserve-with-timeout 0', 'TIMED_OUT')
w.cmd('watch alpha', 'WATCHING 2')
w.cmd('ignore default', 'WATCHING 1')
assert w.cmd('reserve-with-timeout 0', 'RESERVED 2 4') == b'high'
w.cmd('delete 2', 'DELETED')
assert w.cmd('reserve-with-timeout 0', 'RESERVED 1 3') == b'low'
w.cmd('delete 1', 'DELETED')
w.cmd('reserve-with-timeout 0', 'TIMED_OUT')
p.close(); w.close(); stop()

print('Journey 2: disconnect and TTR recovery', flush=True)
port = start()
p, w = Client(port), Client(port)
p.cmd('put 0 0 2 4', 'INSERTED 1', b'work')
assert w.cmd('reserve-with-timeout 0', 'RESERVED 1 4') == b'work'
w.close()
w = Client(port)
assert w.cmd('reserve-with-timeout 1', 'RESERVED 1 4') == b'work'
w.cmd('release 1 0 0', 'RELEASED')
assert w.cmd('reserve-with-timeout 0', 'RESERVED 1 4') == b'work'
time.sleep(3)
assert p.cmd('reserve-with-timeout 1', 'RESERVED 1 4') == b'work'
p.cmd('delete 1', 'DELETED')
w.cmd('delete 1', 'NOT_FOUND')
p.close(); w.close(); stop()

print('Journey 3: persistent ready and buried work across restart', flush=True)
docker('volume', 'create', NAME)
port = start(True)
p = Client(port)
p.cmd('put 0 0 30 5', 'INSERTED 1', b'ready')
p.cmd('put 0 0 30 6', 'INSERTED 2', b'buried')
assert p.cmd('reserve-with-timeout 0', 'RESERVED 1 5') == b'ready'
p.cmd('bury 1 10', 'BURIED')
p.close()
docker('restart', NAME)
port = ready_port()
p = Client(port)
assert p.cmd('peek-buried', 'FOUND 1 5') == b'ready'
assert p.cmd('reserve-with-timeout 0', 'RESERVED 2 6') == b'buried'
p.cmd('delete 2', 'DELETED')
p.cmd('kick 1', 'KICKED 1')
assert p.cmd('reserve-with-timeout 0', 'RESERVED 1 5') == b'ready'
p.cmd('delete 1', 'DELETED')
p.close()
docker('restart', NAME)
port = ready_port()
p = Client(port)
p.cmd('reserve-with-timeout 0', 'TIMED_OUT')
p.cmd('peek-buried', 'NOT_FOUND')
p.close(); stop()
print('All journeys passed', flush=True)
