"""Local TLS mock of the Discord gateway + REST, used by run_test.py."""
import re, base64, hashlib, json, os, socket, ssl, struct, threading, time

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
    def __init__(self, mode='main', certdir=HERE, drop_after=0):
        self.mode = mode
        self.drop_after = drop_after      # close a REST connection after this many requests (0 = never)
        self.http_conns = 0
        self.log = []
        self.lock = threading.Lock()
        self.seq = 0
        self.conn_n = 0
        self.rate_done = False
        self.finished = threading.Event()
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(os.path.join(certdir, 'cert.pem'), os.path.join(certdir, 'key.pem'))
        self.ctx = ctx
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(('127.0.0.1', 0))
        self.sock.listen(50)
        self.rl = {}
        self.global_done = False
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
        with self.lock:
            self.http_conns += 1
            conn_id = self.http_conns
        served = 0
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
            status, out, extra = 200, b'{}', ''
            self.ev('rest', {'method': meth, 'path': path, 'headers': hd, 'body': body.decode('utf-8', 'replace'), 'raw': body, 'conn': conn_id, 'ts': time.time()})
            m_rl = re.fullmatch(r'/api/v10/channels/(\d+)/messages', path)
            if self.mode == 'ratelimit' and meth == 'POST' and m_rl:
                # Discord-style bucket: 2 requests per 1.5 s per channel, headers on every answer
                now = time.time()
                b = self.rl.setdefault(m_rl.group(1), {'rem': 2, 'reset': 0.0})
                if b'GLOBAL' in body and not self.global_done:
                    self.global_done = True
                    status, out = 429, b'{"message":"You are being rate limited.","retry_after":0.6,"global":true}'
                    extra = 'X-RateLimit-Global: true\r\nX-RateLimit-Scope: global\r\n'
                else:
                    if now >= b['reset']:
                        b['rem'], b['reset'] = 2, now + 1.5
                    if b['rem'] == 0:
                        self.ev('rl_violation', {'chan': m_rl.group(1)})
                        status, out = 429, b'{"message":"You are being rate limited.","retry_after":1.0,"global":false}'
                        extra = 'Retry-After: 1\r\nX-RateLimit-Scope: user\r\n'
                    else:
                        b['rem'] -= 1
                        out = b'{"id":"5000"}'
                        extra = ('X-RateLimit-Limit: 2\r\nX-Ratelimit-Remaining: %d\r\nX-RateLimit-Reset-After: %.3f\r\n'
                                 'X-RateLimit-Bucket: abc\r\n' % (b['rem'], max(0.0, b['reset'] - now)))
                c.sendall((f"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\n{extra}"
                           f"Content-Length: {len(out)}\r\n\r\n").encode() + out)
                served += 1
                continue
            if meth == 'POST' and path.endswith('/messages') and b'429TEST' in body and not self.rate_done:
                self.rate_done = True
                status, out = 429, b'{"message":"You are being rate limited.","retry_after":0.3,"global":false}'
            elif meth == 'POST' and path.endswith('/callback'):
                status, out = 204, b''
            elif meth == 'POST' and path.startswith('/api/v10/webhooks/'):
                out = b'{"id":"8000"}'
            elif meth == 'PUT' and path.startswith('/api/v10/applications/'):
                out = b'[]'
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
            served += 1
            if self.drop_after and served >= self.drop_after:
                c.close()
                return

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

    def _events(self):
        user = {'id': 'U7', 'username': 'newbie'}
        return [
            {'op': 0, 't': 'MESSAGE_UPDATE', 'd': {'id': '2001', 'channel_id': '1001', 'guild_id': 'G1',
                                                   'content': 'edited "x" \u00e9', 'author': {'id': 'U1', 'username': 'alice'}}},
            {'op': 0, 't': 'MESSAGE_UPDATE', 'd': {'id': '2002', 'channel_id': '1001', 'embeds': [{'title': 't'}]}},
            {'op': 0, 't': 'MESSAGE_DELETE', 'd': {'id': '2003', 'channel_id': '1001', 'guild_id': 'G1'}},
            {'op': 0, 't': 'MESSAGE_DELETE', 'd': {'id': '2004', 'channel_id': '1002'}},
            {'op': 0, 't': 'MESSAGE_REACTION_ADD', 'd': {'user_id': 'U1', 'channel_id': '1001', 'message_id': '2001', 'guild_id': 'G1',
                'member': {'nick': 'n', 'roles': []}, 'emoji': {'id': None, 'name': '\U0001F525'}, 'message_author_id': 'U2',
                'burst': False, 'type': 0}},
            {'op': 0, 't': 'MESSAGE_REACTION_ADD', 'd': {'user_id': 'U3', 'channel_id': '1002', 'message_id': '2002',
                'emoji': {'id': '555', 'name': 'party', 'animated': True}, 'burst': True, 'type': 1}},
            {'op': 0, 't': 'MESSAGE_REACTION_REMOVE', 'd': {'user_id': 'U1', 'channel_id': '1001', 'message_id': '2001', 'guild_id': 'G1',
                'emoji': {'id': None, 'name': '\U0001F525'}, 'burst': False, 'type': 0}},
            {'op': 0, 't': 'GUILD_MEMBER_ADD', 'd': {'guild_id': 'G1', 'user': user, 'nick': 'Nibb "n"', 'roles': [], 'joined_at': '2026-10-17T00:00:00Z'}},
            {'op': 0, 't': 'GUILD_MEMBER_REMOVE', 'd': {'guild_id': 'G1', 'user': user}},
        ]

    def _inter(self, id, name=None, type=2, token='tok_A-b.c1', user_in='member', data=None, **kw):
        u = {'id': 'U1', 'username': 'alice'}
        d = {'id': id, 'application_id': '700', 'type': type, 'token': token, 'version': 1,
             'channel_id': '1001', 'data': data if data is not None else {}}
        if name:
            d['data'].update({'id': 'c1', 'name': name, 'type': 1})
        if user_in == 'member':
            d['guild_id'] = 'G1'
            d['member'] = {'user': u, 'nick': 'Nick'}
        else:
            d['user'] = {'id': 'U2', 'username': 'bob'}
        d.update(kw)
        return {'op': 0, 't': 'INTERACTION_CREATE', 'd': d}

    def _interactions(self):
        return [
            self._inter('3001', 'ping', data={'options': [
                {'name': 'text', 'type': 3, 'value': 'he said "hi" \u00e9\n'},
                {'name': 'n', 'type': 4, 'value': 42}, {'name': 'flag', 'type': 5, 'value': True}]}),
            self._inter('3002', 'work', token='tok_B', user_in='user'),
            self._inter('3003', 'admin', data={'options': [{'name': 'x', 'type': 3, 'value': 'skip'},
                {'name': 'ban', 'type': 2, 'options': [{'name': 'user', 'type': 1, 'options': [
                    {'name': 'who', 'type': 6, 'value': 'U9'}]}]}]}),
            self._inter('3004', type=3, token='tok_C', data={'custom_id': 'btn1', 'component_type': 2}),
            self._inter('3005', 'bad', token='bad/tok'),
            self._inter('3006', 'register'),
            self._inter('3010', 'panel', token='tok_U'),
            self._inter('3011', 'form', token='tok_U'),
            self._inter('3012', type=5, token='tok_U', data={'custom_id': 'mod1', 'components': [
                {'type': 18, 'id': 1, 'component': {'type': 4, 'id': 2, 'custom_id': 'name', 'value': 'Bud "i"\n'}},
                {'type': 18, 'id': 3, 'component': {'type': 3, 'custom_id': 'pick', 'values': ['x', 'y']}}]}),
            self._inter('3013', type=3, token='tok_U', data={'custom_id': 'sel1', 'component_type': 3, 'values': ['a', 'b']}),
            self._inter('3014', 'search', type=4, token='tok_U', data={'options': [
                {'name': 'sub', 'type': 1, 'options': [{'name': 'q', 'type': 3, 'value': 'he', 'focused': True}]}]}),
            self._inter('3015', 'build', token='tok_U'),
            self._inter('3016', 'files', token='tok_U'),
            self._inter('3017', type=3, token='tok_U', data={'custom_id': 'usel', 'component_type': 5, 'values': ['U9', 'U10'],
                'resolved': {'users': {'U9': {'id': 'U9', 'username': 'zed'}, 'U10': {'id': 'U10', 'username': 'amy', 'avatar': None}},
                             'members': {'U9': {'nick': 'Zed "z"'}}}}),
            self._inter('3018', 'selects', token='tok_U'),
            self._inter('3019', 'selmodal', token='tok_U'),
            self._inter('3007', 'done'),
        ]

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
                        elif j['op'] == 3:
                            self.ev('presence', {'n': n, 'd': j['d'], 'ts': time.time()})
                        elif j['op'] == 1:
                            self.ev('heartbeat', {'n': n, 'd': j['d'], 'ts': time.time()})
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
                'v': 10, 'user': {'id': '900', 'username': 'MockBot'}, 'application': {'id': '700', 'flags': 0},
                'session_id': sess,
                'resume_gateway_url': f'wss://localhost:{self.port}'}})

        if self.mode == 'inter':
            ready('SESS1')
            time.sleep(0.3)
            for it in self._interactions():
                self._send(c, it)
                time.sleep(1.0)
            time.sleep(1.0)
            self.finished.set()
            return

        if self.mode.startswith('flood'):
            # N MESSAGE_CREATE events as fast as the socket takes them, then '!done'
            ready('SESS1')
            time.sleep(0.5)
            nmsg = int(os.environ.get('FLOOD_N', '20000'))
            t0 = time.time()
            batch = []
            for i in range(nmsg):
                m = self._msg(str(5000000 + i), 'm%d' % i, uid='U%d' % (i % 500), uname='user%d' % (i % 500), nick='Nick %d' % (i % 500),
                              extra={'mentions': [{'id': '900', 'username': 'MockBot'}], 'timestamp': '2026-10-17T12:00:00.000000+00:00',
                                     'member': {'nick': 'Nick', 'roles': ['1', '2', '3']}, 'tts': False, 'pinned': False, 'embeds': []})
                self.seq += 1
                m['s'] = self.seq
                batch.append(frame(1, json.dumps(m, separators=(',', ':')).encode()))
                if len(batch) == 200:
                    c.sendall(b''.join(batch))
                    batch = []
            if batch:
                c.sendall(b''.join(batch))
            self._send(c, self._msg('5999999', '!done'))
            self.ev('flood_sent', {'n': nmsg, 'send_s': time.time() - t0})
            for _ in range(600):
                if any(k == 'client_close' for k, d in self.log):
                    break
                time.sleep(0.1)
            time.sleep(0.3)
            self.finished.set()
            return

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
            for e in self._events():
                self._send(c, e)
                time.sleep(0.3)
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
