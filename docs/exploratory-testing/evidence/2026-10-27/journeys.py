import socket, subprocess, time

def docker(*args):
    return subprocess.check_output(['docker', *args], text=True).strip()
def connect(port):
    for _ in range(100):
        try: return socket.create_connection(('127.0.0.1', port), timeout=8)
        except OSError: time.sleep(.1)
    raise RuntimeError('daemon not ready')
def command(s, cmd, expected):
    s.sendall(cmd.encode())
    data = b''
    while not data.endswith(b'\r\n'):
        chunk = s.recv(1)
        if not chunk: raise RuntimeError('connection closed')
        data += chunk
    text = data.decode().strip()
    print(repr(cmd), '=>', repr(text), flush=True)
    assert text == expected, (text, expected)

def port():
    return int(docker('port', name, '11300/tcp').rsplit(':', 1)[1])
name='explore-beanstalkd-20261027'
image=name+':local'
volume=name
for kind, args in [('container', ['container', 'inspect', name]),
                   ('volume', ['volume', 'inspect', volume]),
                   ('image', ['image', 'inspect', image])]:
    if subprocess.run(['docker', *args], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode == 0:
        raise RuntimeError(f'{kind} already exists: {name}')
try:
    subprocess.run(['docker','build','-t',image,'.'], check=True, stdout=subprocess.DEVNULL)
    docker('volume','create',volume)
    docker('run','-d','--name',name,'-p','127.0.0.1::11300','-v',volume+':/data',image,'beanstalkd','-b','/data','-f','0')
    p=port(); print('port',p,flush=True)
    a=connect(p); b=connect(p)
    print('JOURNEY 1 priority, ownership and delete',flush=True)
    command(a,'use alpha\r\n','USING alpha')
    command(a,'put 100 0 30 3\r\nlow\r\n','INSERTED 1')
    command(a,'put 10 0 30 4\r\nhigh\r\n','INSERTED 2')
    command(b,'watch alpha\r\n','WATCHING 2')
    command(b,'ignore default\r\n','WATCHING 1')
    command(b,'reserve-with-timeout 1\r\n','RESERVED 2 4')
    assert b.recv(6)==b'high\r\n'
    command(a,'delete 2\r\n','NOT_FOUND')
    command(b,'delete 2\r\n','DELETED')
    command(b,'reserve-with-timeout 1\r\n','RESERVED 1 3')
    assert b.recv(5)==b'low\r\n'
    command(b,'delete 1\r\n','DELETED')
    command(b,'reserve-with-timeout 0\r\n','TIMED_OUT')
    print('JOURNEY 2 delayed, buried, kicked',flush=True)
    command(a,'put 20 2 30 4\r\nwait\r\n','INSERTED 3')
    command(b,'reserve-with-timeout 0\r\n','TIMED_OUT')
    command(b,'reserve-with-timeout 4\r\n','RESERVED 3 4')
    assert b.recv(6)==b'wait\r\n'
    command(b,'bury 3 20\r\n','BURIED')
    command(b,'reserve-with-timeout 0\r\n','TIMED_OUT')
    command(a,'kick 1\r\n','KICKED 1')
    command(b,'reserve-with-timeout 1\r\n','RESERVED 3 4')
    assert b.recv(6)==b'wait\r\n'
    command(b,'delete 3\r\n','DELETED')
    print('JOURNEY 3 persistent ready and buried jobs',flush=True)
    command(a,'put 10 0 30 4\r\nkeep\r\n','INSERTED 4')
    command(a,'put 20 0 30 4\r\nhold\r\n','INSERTED 5')
    command(b,'reserve-with-timeout 1\r\n','RESERVED 4 4')
    assert b.recv(6)==b'keep\r\n'
    command(b,'release 4 10 0\r\n','RELEASED')
    command(b,'reserve-job 5\r\n','RESERVED 5 4')
    assert b.recv(6)==b'hold\r\n'
    command(b,'bury 5 20\r\n','BURIED')
    a.close(); b.close(); docker('restart',name)
    a=connect(port()); b=connect(port())
    command(a,'use alpha\r\n','USING alpha')
    command(b,'watch alpha\r\n','WATCHING 2')
    command(b,'ignore default\r\n','WATCHING 1')
    command(b,'reserve-with-timeout 1\r\n','RESERVED 4 4')
    assert b.recv(6)==b'keep\r\n'
    command(b,'delete 4\r\n','DELETED')
    command(b,'reserve-with-timeout 0\r\n','TIMED_OUT')
    command(a,'kick 1\r\n','KICKED 1')
    command(b,'reserve-with-timeout 1\r\n','RESERVED 5 4')
    assert b.recv(6)==b'hold\r\n'
    command(b,'delete 5\r\n','DELETED')
    a.close(); b.close()
    print('PASS all journeys',flush=True)
finally:
    for args in [('rm','-f',name),('volume','rm',volume),('image','rm',image)]:
        subprocess.run(['docker',*args],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
