#!/usr/bin/env python3
"""Exercise the client against a scripted local TCP peer."""

import socket
import sys
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from tests.beanstalk_client import BeanstalkClient, BeanstalkError


class Peer:
    def __init__(self, script):
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.error = None
        def run():
            try:
                with self.listener, self.listener.accept()[0] as conn:
                    conn.settimeout(2)
                    script(conn)
            except BaseException as exc:
                self.error = exc
        self.thread = threading.Thread(target=run)
        self.thread.start()

    def finish(self):
        self.thread.join(3)
        if self.thread.is_alive():
            raise AssertionError('peer did not finish')
        if self.error:
            raise self.error


def receive(conn, length):
    data = b''
    while len(data) < length:
        part = conn.recv(length - len(data))
        if not part:
            raise AssertionError('client closed early')
        data += part
    return data


class ClientTests(unittest.TestCase):
    def peer(self, script):
        peer = Peer(script)
        self.addCleanup(peer.finish)
        return BeanstalkClient('127.0.0.1', peer.port, timeout=1)

    def test_fragmentation_pipelining_and_body(self):
        def script(conn):
            self.assertEqual(receive(conn, 13), b'one\r\ntwo\r\nx\r\n')
            for chunk in (b'FO', b'UND 1 3\r', b'\nabc\r\nNEXT\r\n'):
                conn.sendall(chunk)
        with self.peer(script) as client:
            client.send(b'one\r\ntwo\r\nx\r\n')
            self.assertEqual(client.read_line(), b'FOUND 1 3\r\n')
            self.assertEqual(client.read_exact(5), b'abc\r\n')
            self.assertEqual(client.read_line(), b'NEXT\r\n')

    def test_command_and_stats(self):
        def script(conn):
            self.assertEqual(receive(conn, 11), b'put\r\nbody\r\n')
            conn.sendall(b'INSERTED 1\r\n')
            self.assertEqual(receive(conn, 7), b'stats\r\n')
            conn.sendall(b'OK 13\r\n---\na: 1\nb: 2\r\n')
            self.assertEqual(receive(conn, 20), b'stats-tube default\r\n')
            conn.sendall(b'OK 8\r\n---\nx: y\r\n')
        with self.peer(script) as client:
            self.assertEqual(client.cmd(b'put\r\n', b'body\r\n'), b'INSERTED 1\r\n')
            self.assertEqual(client.stats(), {b'a': b'1', b'b': b'2'})
            self.assertEqual(client.stats_tube(), {b'x': b'y'})

    def test_eof_and_partial_responses(self):
        for data, reader in [(b'', lambda c: c.read_line()),
                             (b'partial', lambda c: c.read_line(allow_eof=True)),
                             (b'ab', lambda c: c.read_exact(3, allow_eof=True))]:
            with self.subTest(data=data):
                with self.peer(lambda conn: conn.sendall(data)) as client:
                    with self.assertRaises(BeanstalkError):
                        reader(client)
        with self.peer(lambda conn: None) as client:
            self.assertIsNone(client.read_exact(1, allow_eof=True))

    def test_invalid_stats_framing(self):
        for response in (b'NOT_FOUND\r\n', b'OK nope\r\n', b'OK 3\r\nabcXX',
                         b'OK 5\r\nab'):
            with self.subTest(response=response):
                def script(conn):
                    self.assertEqual(receive(conn, 7), b'stats\r\n')
                    conn.sendall(response)
                with self.peer(script) as client:
                    with self.assertRaises(BeanstalkError):
                        client.stats()

    def test_timeout_remains_catchable(self):
        ready = threading.Event()
        def script(conn):
            ready.wait(2)
        with self.peer(script) as client:
            client.settimeout(0.05)
            try:
                with self.assertRaises(socket.timeout):
                    client.read_line()
            finally:
                ready.set()


if __name__ == '__main__':
    unittest.main(verbosity=2)
