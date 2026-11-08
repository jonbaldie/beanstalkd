"""Small, connection-owning beanstalk protocol client for integration tests."""

import socket


class BeanstalkError(Exception):
    """A response was incomplete or did not follow the expected protocol."""


class BeanstalkEOF(BeanstalkError):
    """The peer closed before completing a response."""


class BeanstalkProtocolError(BeanstalkError):
    """The peer sent an invalid response."""


class BeanstalkClient:
    def __init__(self, host, port, timeout=5):
        self.socket = socket.create_connection((host, port), timeout=timeout)
        self.buffer = bytearray()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def close(self):
        self.socket.close()

    def settimeout(self, timeout):
        self.socket.settimeout(timeout)

    def send(self, data):
        self.socket.sendall(data)

    def read_line(self, allow_eof=False):
        while True:
            end = self.buffer.find(b'\r\n')
            if end >= 0:
                result = bytes(self.buffer[:end + 2])
                del self.buffer[:end + 2]
                return result
            chunk = self.socket.recv(4096)
            if not chunk:
                if allow_eof and not self.buffer:
                    return None
                raise BeanstalkEOF('connection closed before response line')
            self.buffer.extend(chunk)

    def read_exact(self, length, allow_eof=False):
        if length < 0:
            raise ValueError('length must be non-negative')
        while len(self.buffer) < length:
            chunk = self.socket.recv(max(4096, length - len(self.buffer)))
            if not chunk:
                if allow_eof and not self.buffer:
                    return None
                raise BeanstalkEOF('connection closed before response body')
            self.buffer.extend(chunk)
        result = bytes(self.buffer[:length])
        del self.buffer[:length]
        return result

    def cmd(self, line, body=None, allow_eof=False):
        self.send(line)
        if body is not None:
            self.send(body)
        return self.read_line(allow_eof=allow_eof)

    def _stats(self, command):
        header = self.cmd(command)
        parts = header.rstrip(b'\r\n').split(b' ')
        if len(parts) != 2 or parts[0] != b'OK' or not parts[1].isdigit():
            raise BeanstalkProtocolError('invalid stats response: %r' % header)
        body = self.read_exact(int(parts[1]) + 2)
        if not body.endswith(b'\r\n'):
            raise BeanstalkProtocolError('invalid stats body terminator')
        result = {}
        for line in body[:-2].splitlines():
            line = line.strip()
            if b': ' in line:
                key, value = line.split(b': ', 1)
                result[key] = value
        return result

    def stats(self):
        return self._stats(b'stats\r\n')

    def stats_tube(self, tube=b'default'):
        return self._stats(b'stats-tube ' + tube + b'\r\n')
