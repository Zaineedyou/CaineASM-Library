"""Local TLS mock of the Discord gateway + REST, used by run_test.py."""
import base64, hashlib, json, os, socket, ssl, struct, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'


def frame(op, payload, fin=True):
    n = len(payload)
    b0 = (0x80 if fin else 0) | op
    if n < 126:
        h = struct.pack('!BB', b0, n)
    elif n < 65536:
        h = struct.pack('!BBH', b0, 126, n)
    else:
        h = struct.pack('!BBQ', b0, 127, n)
    return h + payload


def readn(c, n):
    d = b''
    while len(d) < n:
        x = c.recv(n - len(d))
        if not x:
            raise EOFError
        d += x
    return d


def readframe(c):
    b0, b1 = readn(c, 2)
    n = b1 & 0x7f
    if n == 126:
        n = struct.unpack('!H', readn(c, 2))[0]
    elif n == 127:
        n = struct.unpack('!Q', readn(c, 8))[0]
    m = readn(c, 4)
    d = bytearray(readn(c, n))
    for i in range(n):
        d[i] ^= m[i % 4]
    return b0 & 15, bytes(d)


class Mock:
    def __init__(self, mode='main'):
        self.mode = mode
        self.log = []
        self.lock = threading.Lock()
        self.seq = 0
        self.conn_n = 0
        self.rate_done = False
        self.finished = threading.Event()
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(os.path.join(HERE, 'cert.pem'), os.path.join(HERE, 'key.pem'))
        self.ctx = ctx
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(('127.0.0.1', 0))
        self.sock.listen(50)
        self.port = self.sock.getsockname()[1]
        threading.Thread(target=self._accept, daemon=True).start()

    def ev(self, k, d):
        with self.lock:
            self.log.append((k, d))

    def _accept(self):
        while True:
            try:
                r, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._conn, args=(r,), daemon=True).start()

    def _conn(self, raw):
        try:
            c = self.ctx.wrap_socket(raw, server_side=True)
            first = b''
            while b'\r\n\r\n' not in first:
                x = c.recv(65536)
                if not x:
                    return
                first += x
            if b'Upgrade: websocket' in first:
                self._ws(c, first.split(b'\r\n\r\n')[0])
            else:
                self._http(c, first)
        except Exception as e:
            self.ev('conn_err', repr(e))

    # ---------------- REST ----------------
    def _http(self, c, buf):
        while True:
            while b'\r\n\r\n' not in buf:
                x = c.recv(65536)
                if not x:
                    return
                buf += x
            head, _, rest = buf.partition(b'\r\n\r\n')
            lines = head.decode().split('\r\n')
            meth, path, _ = lines[0].split(' ', 2)
            hd = {l.split(':', 1)[0].lower(): l.split(':', 1)[1].strip() for l in lines[1:] if ':' in l}
            n = int(hd.get('content-length', '0'))
            while len(rest) < n:
                rest += c.recv(65536)
            body, buf = rest[:n], rest[n:]
            status, out = 200, b'{}'
            self.ev('rest', {'method': meth, 'path': path, 'headers': hd, 'body': body.decode('utf-8', 'replace')})
            if meth == 'POST' and path.endswith('/messages') and b'429TEST' in body and not self.rate_done:
                self.rate_done = True
                status, out = 429, b'{"message":"You are being rate limited.","retry_after":0.3,"global":false}'
            elif meth == 'POST' and path.endswith('/messages'):
                out = b'{"id":"5000"}'
            elif path.endswith('/typing'):
                status, out = 204, b''
            elif meth in ('PUT', 'DELETE'):
                status, out = 204, b''
            elif meth == 'PATCH':
                out = b'{"id":"5000","content":"edited"}'
            elif meth == 'GET' and path.endswith('/users/@me'):
                out = b'{"id":"900","username":"MockBot"}'
            c.sendall((f"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\n"
                       f"Content-Length: {len(out)}\r\n\r\n").encode() + out)

    # ---------------- gateway ----------------
    def _send(self, c, obj):
        if obj.get('op') == 0:
            self.seq += 1
            obj['s'] = self.seq
        c.sendall(frame(1, json.dumps(obj, separators=(',', ':'), ensure_ascii=False).encode()))

    def _msg(self, id, content, uid='U1', uname='alice', guild='G1', chan='1001', bot=False, nick=None, extra=None):
        d = {'id': id, 'channel_id': chan, 'content': content,
             'author': {'id': uid, 'username': uname, 'bot': bot},
             'mentions': [], 'mention_everyone': False, 'attachments': []}
        if guild:
            d['guild_id'] = guild
            d['member'] = {'nick': nick, 'roles': []}
        if extra:
            d.update(extra)
        return {'op': 0, 't': 'MESSAGE_CREATE', 'd': d}

    def _ws(self, c, req):
        self.conn_n += 1
        n = self.conn_n
        key = [l for l in req.decode().split('\r\n') if l.lower().startswith('sec-websocket-key')][0].split(': ')[1]
        acc = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.ev('ws_open', {'n': n, 'request_line': req.decode().split('\r\n')[0]})
        c.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                   'Sec-WebSocket-Accept: %s\r\n\r\n' % acc).encode())
        self._send(c, {'op': 10, 'd': {'heartbeat_interval': 1500}})
        login = threading.Event()

        def reader():
            try:
                while True:
                    op, d = readframe(c)
                    if op == 1:
                        j = json.loads(d)
                        if j['op'] in (2, 6):
                            self.ev('login', {'n': n, 'op': j['op'], 'd': j['d']})
                            login.set()
                        elif j['op'] == 1:
                            self.ev('heartbeat', {'n': n, 'd': j['d']})
                            c.sendall(frame(1, b'{"op":11}'))
                    elif op == 8:
                        self.ev('client_close', {'n': n})
                        break
            except Exception as e:
                self.ev('ws_reader_end', {'n': n, 'e': repr(e)})

        threading.Thread(target=reader, daemon=True).start()
        if not login.wait(5):
            self.ev('no_login', {'n': n})
            return
        if self.mode == 'fatal':
            time.sleep(0.3)
            c.sendall(frame(8, struct.pack('!H', 4004) + b'Authentication failed'))
            time.sleep(0.5)
            self.finished.set()
            return

        def ready(sess):
            self._send(c, {'op': 0, 't': 'READY', 'd': {
                'v': 10, 'user': {'id': '900', 'username': 'MockBot'}, 'session_id': sess,
                'resume_gateway_url': f'wss://localhost:{self.port}'}})

        if n == 1:
            ready('SESS1')
            time.sleep(0.3)
            self._send(c, {'op': 0, 't': 'GUILD_CREATE', 'd': {'id': 'G1', 'name': 'Test guild'}})
            time.sleep(0.3)
            msgs = [
                self._msg('2001', '!ping "x"\nnl \U0001F600 é', nick='Nick', extra={
                    'mentions': [{'id': '900', 'username': 'MockBot'}], 'mention_everyone': True,
                    'attachments': [{'url': 'https://cdn.example/a.png?x=1&y=2', 'content_type': 'image/png'}]}),
                self._msg('2002', '!typing', guild=None, chan='1002', uid='U2', uname='bob'),
                self._msg('2003', '!edit', uid='U3', uname='carl', extra={
                    'type': 19, 'referenced_message': {'id': 'X', 'author': {'id': '900'}}}),
                self._msg('2004', '!react', uid='B1', uname='botty', bot=True),
                self._msg('2005', '!del'), self._msg('2006', '!long'), self._msg('2007', '!req'),
                self._msg('2008', '!bad'), self._msg('2009', '!429'),
            ]
            for m in msgs:
                self._send(c, m)
                time.sleep(1.0)
            self.ev('seq_before_reconnect', {'seq': self.seq})
            self._send(c, {'op': 7, 'd': None})
            time.sleep(2)
        elif n == 2:
            self._send(c, {'op': 0, 't': 'RESUMED', 'd': {}})
            time.sleep(0.3)
            self._send(c, self._msg('2101', '!ping after resume'))
            time.sleep(1.0)
            self._send(c, {'op': 9, 'd': False})
            time.sleep(2)
        else:
            ready('SESS2')
            time.sleep(0.3)
            self._send(c, self._msg('2102', '!done'))
            time.sleep(1.5)
            self.finished.set()
