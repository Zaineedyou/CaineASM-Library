#!/usr/bin/env python3
"""Runs the C test client against the mock Discord and verifies everything.
usage: run_test.py <test binary>      (VALGRIND=1 to run under valgrind)"""
import json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mock_discord import Mock  # noqa: E402

binary = os.path.abspath(sys.argv[1])
vg = (['valgrind', '-q', '--error-exitcode=9', '--leak-check=no'] if os.environ.get('VALGRIND') else [])
# throw-away self-signed certificate for the local mock (nothing secret is stored in the repo)
certdir = tempfile.mkdtemp(prefix='caineasm-test-')
cafile = os.path.join(certdir, 'cert.pem')
subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=localhost',
                '-addext', 'subjectAltName=DNS:localhost', '-keyout', os.path.join(certdir, 'key.pem'), '-out', cafile],
               check=True, capture_output=True)
fails = []
checks = [0]


def check(cond, what):
    checks[0] += 1
    if not cond:
        fails.append(what)
        print('FAIL:', what)


def run(mode, mock=None, timeout=180):
    args = vg + [binary, mode] + ([str(mock.port), cafile] if mock else [])
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


# ------------------------------------------------------------ misc (no network)
p = run('misc')
check(p.returncode == 0, f'misc exit {p.returncode} {p.stderr[-300:]}')
check('MISC version 0.3.0 0.3.0\n' in p.stdout, f'casm_version() matches CASM_VERSION_STRING: {p.stdout[:80]!r}')
for k, v in [('init_null', '-1'), ('init_empty', '-1'), ('run_noinit', '-1'), ('botid', 'null')]:
    check(f'MISC {k} {v}' in p.stdout, f'misc {k} expected {v}: {p.stdout!r}')

# ------------------------------------------------------------ crash reporter (plain binary, valgrind would intercept signals)
for mode in ('crash', 'crashstack'):
    p = subprocess.run([binary, mode], capture_output=True, text=True, timeout=60)
    check(p.returncode == -11, f'{mode}: still dies from SIGSEGV after reporting (rc {p.returncode})')
    check('HANDLER 0' in p.stdout, f'{mode}: casm_set_crash_handler(1) returned 0')
    check('CaineASM crash: SIGSEGV' in p.stderr and 'fault address 0x' in p.stderr and 'instruction 0x' in p.stderr, f'{mode}: header on stderr: {p.stderr[:200]!r}')
    check('backtrace' in p.stderr and p.stderr.count('[0x') >= (2 if mode == 'crash' else 1), f'{mode}: backtrace lines: {p.stderr[-300:]!r}')
    if shutil.which('addr2line'):
        check('resolved (addr2line):' in p.stderr, f'{mode}: addr2line output present: {p.stderr[-300:]!r}')
        if mode == 'crash':
            check('ix_path' in p.stderr and 'ix_send' in p.stderr and 'interact.asm' in p.stderr, f'{mode}: names and source lines resolved: {p.stderr[-500:]!r}')
p = subprocess.run([binary, 'crash'], capture_output=True, text=True, timeout=60)
check('fault address 0x28,' in p.stderr, f'fault address of the garbage pointer is reported: {p.stderr[:160]!r}')
p = subprocess.run([binary, 'crashoff'], capture_output=True, text=True, timeout=60)
check(p.returncode == -11 and 'CaineASM crash' not in p.stderr and 'HANDLER off 0' in p.stdout, f'handler disabled: plain SIGSEGV, no report ({p.returncode})')

# ------------------------------------------------------------ helper unit tests
p = run('unit')
check(p.returncode == 0 and re.search(r'UNIT pass=\d+ fail=0', p.stdout) is not None, f'unit tests: {p.stdout[-600:]!r} {p.stderr[-200:]}')

# unescape fuzz against json.dumps + atomic truncation
import random
rnd = random.Random(12345)
pool = ['a', 'Z', ' ', '"', '\\', '/', '\n', '\t', '\r', '\x01', '\x1f', 'é', 'ñ', '€', '中', '\U0001F600', '\U0001D11E', '\u00a0']
cases = []
for _ in range(5000):
    t = ''.join(rnd.choice(pool) for _ in range(rnd.randint(0, 12)))
    cases.append(json.dumps(t, ensure_ascii=rnd.random() < 0.5)[1:-1])
inp = '\n'.join(c.encode().hex() for c in cases) + '\n'
p = subprocess.run(vg + [binary, 'unescape'], input=inp, capture_output=True, text=True, timeout=300)
check(p.returncode == 0, f'unescape fuzz exit {p.returncode} {p.stderr[-200:]}')
outl = p.stdout.split('\n')
bad = 0
for idx, c in enumerate(cases):
    full = json.loads('"' + c + '"').encode()
    exp = [f'full {len(full)} {full.hex()}']
    for cap in range(1, 10):
        k = min(len(full), cap - 1)
        while k > 0 and k < len(full) and (full[k] & 0xC0) == 0x80:
            k -= 1
        exp.append(f'cap {cap} {len(full)} {full[:k].hex()}')
    got = outl[idx * 10: idx * 10 + 10]
    if [g.rstrip() for g in got] != [e.rstrip() for e in exp]:
        bad += 1
        if bad <= 3:
            print('fuzz mismatch', repr(c), got[:3], exp[:3])
check(bad == 0 and len(outl) >= 50000, f'unescape fuzz: {bad} mismatches of {len(cases)}, lines {len(outl)}')

# ------------------------------------------------------------ interactions (slash commands)
m = Mock('inter', certdir)
p = run('inter', m, 120)
o, e = p.stdout, p.stderr
check(p.returncode == 0 and 'RUN 0' in o, f'inter run: {o[-300:]!r} {e[-300:]}')
ir = [d for k, d in m.log if k == 'rest']
check(all(d['headers'].get('authorization') == 'Bot tok.en' for d in ir), 'interaction calls carry the bot Authorization header')
ints = [l for l in o.split('\n') if l.startswith('INT ')]
check(len(ints) == 17, f'17 parsed interactions ({len(ints)})')
i1 = ints[0] if ints else ''
for frag in ['id=3001', 'app=700', 'tok=tok_A-b.c1', 'guild=G1', 'chan=1001', 'uid=U1', 'uname=alice', 'cmd=ping',
             'cid=c1', 'custom=<null>', 'type=2 ctype=1 appid=700', '"name":"text","type":3,"value":"he said \\"hi\\" \u00e9\\n"']:
    check(frag in i1, f'interaction 3001 has {frag!r}: {i1!r}')
i2 = next((l for l in ints if 'id=3002' in l), '')
check('guild=<null>' in i2 and 'uid=U2' in i2 and 'uname=bob' in i2 and 'opts=<null>' in i2, f'DM interaction uses user.*: {i2!r}')
i4 = next((l for l in ints if 'id=3004' in l), '')
check('custom=btn1' in i4 and 'type=3' in i4 and 'cmd=<null>' in i4, f'component interaction: {i4!r}')
check('OPT text 115 he said "hi" \u00e9\n' in o, 'option string value unescapes')
check('OPT n 100 42\n' in o and 'OPT flag 98 true\n' in o and 'OPT nope 0 1' in o, 'number / bool / missing options')
check('SUB1 2 ban' in o and 'SUB2 1 user' in o and 'SUB3 115 U9' in o and 'SUB4 0' in o, 'subcommand group -> subcommand -> option walk')
for k, v in [('respond', 204), ('defer', 204), ('followup', 200), ('editresp', 200), ('delresp', 204), ('defer2', 204),
             ('update', 204), ('plainresp', 204), ('badtype', -1), ('regglobal', 200), ('regguild', 200)]:
    check(f'RET {k} {v}\n' in o, f'RET {k} {v}')
for k in range(1, 9):
    check(f'RET bad{k} -1\n' in o, f'invalid interaction argument bad{k} returns -1')
check('KEEPPTR 1' in o and 'KEEP id=3002 app=700 tok=tok_B uname=bob cmd=work raw={"id":"3002","applic' in o,
      'casm_interaction_keep copy is intact after the gateway buffer was reused')
want = [
    ('POST', '/api/v10/interactions/3001/tok_A-b.c1/callback',
     {'type': 4, 'data': {'content': 'he said "hi" \u00e9\n', 'flags': 64, 'allowed_mentions': {'parse': ['users']}}}),
    ('POST', '/api/v10/interactions/3002/tok_B/callback', {'type': 5}),
    ('POST', '/api/v10/webhooks/700/tok_B', {'content': 'later "q" \u00e9', 'flags': 64, 'allowed_mentions': {'parse': ['users']}}),
    ('PATCH', '/api/v10/webhooks/700/tok_B/messages/@original', {'content': 'edited', 'allowed_mentions': {'parse': ['users']}}),
    ('DELETE', '/api/v10/webhooks/700/tok_B/messages/@original', None),
    ('POST', '/api/v10/interactions/3003/tok_A-b.c1/callback', {'type': 5, 'data': {'flags': 64}}),
    ('POST', '/api/v10/interactions/3004/tok_C/callback', {'type': 7, 'data': {'content': 'updated "x"'}}),
    ('POST', '/api/v10/interactions/3004/tok_C/callback', {'type': 6}),
    ('PUT', '/api/v10/applications/700/commands', json.loads('[{"name":"ping","description":"Pong","type":1,"options":[{"name":"text","description":"t","type":3}]}]')),
    ('PUT', '/api/v10/applications/700/guilds/555/commands', json.loads('[{"name":"ping","description":"Pong","type":1,"options":[{"name":"text","description":"t","type":3}]}]')),
]
for meth, path, bd in want:
    got = [d for d in ir if d['method'] == meth and d['path'] == path and not d['headers'].get('content-type', '').startswith('multipart/') and (json.loads(d['body']) if d['body'] else None) == bd]
    check(len(got) == 1, f'REST {meth} {path} body {bd}: matches {len(got)}')
AM = {'parse': ['users']}
EMB = {'title': 'Judul "q"', 'description': 'baris1\nbaris2 \u00e9', 'url': 'https://x/e', 'timestamp': '2026-10-13T11:00:00Z',
       'footer': {'text': 'foot'}, 'author': {'name': 'auth'}, 'image': {'url': 'https://x/i.png'},
       'thumbnail': {'url': 'https://x/t.png'}, 'color': 0x5865F2,
       'fields': [{'name': 'f1', 'value': 'v1', 'inline': True}, {'name': 'f2', 'value': 'v2'}]}
ROWS = [{'type': 1, 'components': [
            {'type': 2, 'style': 1, 'label': 'Klik', 'custom_id': 'btn_ok'},
            {'type': 2, 'style': 4, 'label': 'Hapus "x"', 'custom_id': 'btn_del', 'disabled': True},
            {'type': 2, 'style': 5, 'label': 'Web', 'url': 'https://example.com/a?b=1&c=2'}]},
        {'type': 1, 'components': [{'type': 3, 'custom_id': 'sel1', 'placeholder': 'Pilih', 'min_values': 1, 'max_values': 2,
            'options': [{'label': 'A', 'value': 'a', 'description': 'desc A', 'default': True}, {'label': 'B', 'value': 'b'}]}]}]
PAY = {'content': 'hai "dunia"', 'embeds': [EMB], 'components': ROWS}
ui = [
    ('POST', '/api/v10/interactions/3010/tok_U/callback', {'type': 4, 'data': dict(PAY, allowed_mentions=AM)}),
    ('POST', '/api/v10/channels/1001/messages', dict(PAY, message_reference={'message_id': '2001', 'fail_if_not_exists': False},
                                                    allowed_mentions={'parse': ['users'], 'replied_user': True})),
    ('POST', '/api/v10/channels/1001/messages', dict(PAY, allowed_mentions=AM)),
    ('PATCH', '/api/v10/channels/1001/messages/5000', dict(PAY, allowed_mentions=AM)),
    ('POST', '/api/v10/webhooks/700/tok_U', {'content': 'only text', 'flags': 64, 'allowed_mentions': AM}),
    ('PATCH', '/api/v10/webhooks/700/tok_U/messages/@original', {'content': 'only text', 'flags': 64, 'allowed_mentions': AM}),
    ('POST', '/api/v10/interactions/3011/tok_U/callback', {'type': 9, 'data': {'custom_id': 'mod1', 'title': 'Titulo "q"', 'components': [
        {'type': 18, 'label': 'Nama', 'component': {'type': 4, 'custom_id': 'name', 'style': 1, 'placeholder': 'isi nama',
                                                    'min_length': 1, 'max_length': 50, 'required': True}},
        {'type': 18, 'label': 'Bio', 'component': {'type': 4, 'custom_id': 'bio', 'style': 2, 'required': False}}]}}),
    ('POST', '/api/v10/interactions/3012/tok_U/callback', {'type': 4, 'data': {'content': 'ok', 'allowed_mentions': AM}}),
    ('POST', '/api/v10/interactions/3013/tok_U/callback', {'type': 7, 'data': {'content': 'updated', 'allowed_mentions': AM}}),
    ('POST', '/api/v10/interactions/3014/tok_U/callback', {'type': 8, 'data': {'choices': [
        {'name': 'Alpha', 'value': 'a'}, {'name': 'Be"ta', 'value': 'b'}]}}),
]
for meth, path, bd in ui:
    got = [d for d in ir if d['method'] == meth and d['path'] == path and not d['headers'].get('content-type', '').startswith('multipart/') and (json.loads(d['body']) if d['body'] else None) == bd]
    check(len(got) == 1, f'UI {meth} {path} body {json.dumps(bd)[:90]}: matches {len(got)}')
for k, v in [('panel', 204), ('sendreply', 200), ('sendreply2', 200), ('editmsg', 200), ('followreply', 200), ('editreply', 200),
             ('badr1', -1), ('badr2', -1), ('badr3', -1), ('bade1', -1), ('bade2', -1), ('bade3', -1), ('bade4', -1), ('bade5', -1),
             ('bade6', 1), ('showmodal', 204), ('badmodal', -1), ('modalresp', 204), ('selupdate', 204), ('ac', 204),
             ('acbad1', -1), ('acbad2', -1)]:
    check(f'RET {k} {v}\n' in o, f'RET {k} {v}')
check('MODAL name 115 Bud \\"i\\"\\n\n' in o and 'MODAL pick 97\n' in o and 'MODAL pick1 115 y\n' in o and 'MODAL none 0 1' in o,
      'modal values: text, select values, missing')
check('SELV 1\n' in o and 'SELV0 115 a\n' in o and 'SELV1 115 b\n' in o and 'SELV2 0 \n' in o, 'select values via casm_array_at')
check('FOCUS 1 q he\n' in o, 'focused option found inside a subcommand')
# ---- command builder: JSON compared with the shapes from the Discord docs
HELLO = {'type': 1, 'name': 'hello', 'description': 'Say "hello" é', 'default_member_permissions': '8', 'nsfw': True,
         'contexts': [0, 2], 'options': [
    {'type': 3, 'name': 'who', 'description': 'Who', 'required': True,
     'choices': [{'name': 'Alice', 'value': 'a'}, {'name': 'Bo"b', 'value': 'b'}]},
    {'type': 4, 'name': 'count', 'description': 'How many', 'min_value': 1, 'max_value': 10},
    {'type': 10, 'name': 'ratio', 'description': 'Ratio', 'min_value': 0.1, 'max_value': 99.5},
    {'type': 3, 'name': 'q', 'description': 'Query', 'min_length': 2, 'max_length': 50, 'autocomplete': True},
    {'type': 4, 'name': 'level', 'description': 'Level', 'choices': [{'name': 'Low', 'value': 1}, {'name': 'High', 'value': -5}]},
    {'type': 10, 'name': 'pi', 'description': 'Pi', 'choices': [{'name': 'Pi', 'value': 3.14159}]},
    {'type': 4, 'name': 'min', 'description': 'Min only', 'min_value': -3},
    {'type': 10, 'name': 'big', 'description': 'Max only', 'max_value': 1e20}]}
ADMIN = {'type': 1, 'name': 'admin', 'description': 'Admin tools', 'options': [
    {'type': 2, 'name': 'ban', 'description': 'Ban tools', 'options': [
        {'type': 1, 'name': 'user', 'description': 'Ban a user', 'options': [
            {'type': 6, 'name': 'target', 'description': 'Target', 'required': True}]}]}]}
CTXC = {'type': 2, 'name': 'Show Info', 'description': ''}
for path in ('/api/v10/applications/700/commands', '/api/v10/applications/700/guilds/555/commands'):
    got = [json.loads(d['body']) for d in ir if d['method'] == 'PUT' and d['path'] == path and d['body'].startswith('[{"type":1,"name":"hello"')]
    check(got == [[HELLO, ADMIN, CTXC]], f'command builder PUT {path}: {json.dumps(got)[:300]}')
for k, v in [('bok', '0'), ('breg', '200'), ('bregguild', '200'), ('b10', '0 -1'), ('b32', '-1 -1 -1'), ('b35', '25 2'), ('b36', '25 2')]:
    check(f'RET {k} {v}\n' in o, f'RET {k} {v}')
for k in list(range(1, 10)):
    check(f'RET b{k} 1\n' in o, f'builder rule violation b{k} gives NULL')
for k in list(range(11, 32)) + [33, 34]:
    check(f'RET b{k} -1\n' in o, f'builder rule violation b{k} gives -1')

# ---- file uploads: exact multipart structure from the Discord docs
def mkdata(n):
    b = bytearray((k * 7 + 3) & 255 for k in range(n))
    if n > 30:
        b[10:18] = b'\r\n--\r\n\r\n'
    return bytes(b)

def parse_mp(d):
    ct = d['headers'].get('content-type', '')
    mm = re.fullmatch(r'multipart/form-data; boundary=(CaineASM[0-9a-f]{32})', ct)
    if not mm:
        return None, None, f'bad content-type {ct!r}'
    B = mm.group(1).encode()
    raw = d['raw']
    head, tail = b'--' + B + b'\r\n', b'\r\n--' + B + b'--\r\n'
    if not (raw.startswith(head) and raw.endswith(tail)):
        return None, None, 'bad framing'
    parts = []
    for part in raw[len(head):-len(tail)].split(b'\r\n--' + B + b'\r\n'):
        h, sep, data = part.partition(b'\r\n\r\n')
        parts.append((h.decode().split('\r\n'), data))
    return B, parts, ''

D1, D2 = mkdata(300), mkdata(1000000)
AMU = {'parse': ['users']}
cases = [
    ('POST', '/api/v10/channels/1001/messages', {'content': 'caption "q" é', 'allowed_mentions': AMU,
        'attachments': [{'id': 0, 'filename': 'cat.png'}]}, [('cat.png', 'image/png', D1)]),
    ('POST', '/api/v10/channels/1001/messages', {'allowed_mentions': AMU, 'attachments': [{'id': 0, 'filename': 'report.txt'}]},
        [('report.txt', 'text/plain', b'hello\n')]),
    ('POST', '/api/v10/channels/1001/messages', {'allowed_mentions': AMU, 'attachments': [{'id': 0, 'filename': 'Big é.BIN'}]},
        [('Big é.BIN', 'application/x-custom', D2)]),
    ('POST', '/api/v10/channels/1001/messages', {'allowed_mentions': AMU, 'attachments': [{'id': 0, 'filename': 'empty.log'}]},
        [('empty.log', 'text/plain', b'')]),
]
two = [('a.txt', 'text/plain', b'AAA'), ('b.jpeg', 'image/jpeg', D1)]
TWO = {'content': 'two files', 'embeds': [{'title': 'T', 'image': {'url': 'attachment://a.txt'}}],
       'attachments': [{'id': 0, 'filename': 'a.txt'}, {'id': 1, 'filename': 'b.jpeg'}]}
cases += [
    ('POST', '/api/v10/channels/1001/messages', dict(TWO, message_reference={'message_id': '2001', 'fail_if_not_exists': False},
        allowed_mentions={'parse': ['users'], 'replied_user': True}), two),
    ('PATCH', '/api/v10/channels/1001/messages/5000', dict(TWO, allowed_mentions=AMU), two),
    ('POST', '/api/v10/webhooks/700/tok_U', dict(TWO, allowed_mentions=AMU), two),
    ('PATCH', '/api/v10/webhooks/700/tok_U/messages/@original', dict(TWO, allowed_mentions=AMU), two),
]
mp = [d for d in ir if d['headers'].get('content-type', '').startswith('multipart/')]
check(len(mp) == len(cases), f'{len(cases)} multipart requests (saw {len(mp)})')
bounds = set()
for n, (meth, path, js, files) in enumerate(cases):
    d = mp[n] if n < len(mp) else None
    if d is None:
        check(False, f'upload case {n}: missing request')
        continue
    B, parts, err = parse_mp(d)
    ok = (d['method'] == meth and d['path'] == path and parts is not None and len(parts) == 1 + len(files))
    check(ok, f'upload case {n} {meth} {path}: method/path/framing {err or ""} {d["method"]} {d["path"]}')
    if not ok:
        continue
    bounds.add(B)
    check(parts[0][0] == ['Content-Disposition: form-data; name="payload_json"', 'Content-Type: application/json'], f'upload case {n}: payload_json part headers {parts[0][0]}')
    check(json.loads(parts[0][1]) == js, f'upload case {n}: payload_json {parts[0][1][:300]!r}')
    for fi, (fname, fct, fdata) in enumerate(files):
        h, data = parts[1 + fi]
        check(h == [f'Content-Disposition: form-data; name="files[{fi}]"; filename="{fname}"', f'Content-Type: {fct}'], f'upload case {n} file {fi}: headers {h}')
        check(data == fdata, f'upload case {n} file {fi}: {len(data)} bytes equal {len(fdata)} bytes: {data == fdata}')
check(len(bounds) == len(cases), f'every upload used its own random boundary ({len(bounds)} distinct)')
for k, v in [('f1', 200), ('f2', 200), ('f3', 200), ('f4', 200), ('fadd', 0), ('fsend', 200), ('fedit', 200), ('ffollow', 200),
             ('feditresp', 200), ('frespond', -1), ('fupdate', -1), ('fok', 0)] + [(f'fbad{x}', -1) for x in range(1, 15)]:
    check(f'RET {k} {v}\n' in o, f'RET {k} {v}')

# ---- user / role / mentionable / channel selects
check('USEL has=1 v0=s:U9 v1=s:U10 v2=0:' in o, 'entity select values read with casm_select_values / casm_array_at')
for line in ['JG user s zed', 'JG nick s Zed \\"z\\"', 'JG missing 0 ', 'JG values a ', 'JG resolved o ', 'JG ctype d 5', 'JG token s tok_U',
             'JG nul n null', 'JG bad 0 ', 'JG nullargs 0 0 0', 'JG nullout 115']:
    check(line + '\n' in o, f'casm_json_get: {line!r}')
for k, v in [('selok', '0'), ('selresp', '204'), ('msok', '0'), ('msshow', '204'), ('sb10', '-1'), ('sb11', '-1 -1'), ('sb12', '-1 -1'), ('sb9', '-1 -1 -1')]:
    check(f'RET {k} {v}\n' in o, f'RET {k} {v}')
for k in (1, 2, 3, 4, 5, 6, 7, 8):
    check(f'RET sb{k} 1\n' in o, f'select rule violation sb{k} gives NULL')
SELS = [{'type': 1, 'components': [c]} for c in [
    {'type': 5, 'custom_id': 'u_sel', 'placeholder': 'Pick users', 'min_values': 1, 'max_values': 3},
    {'type': 8, 'custom_id': 'c_sel', 'min_values': 0, 'max_values': 5, 'disabled': True, 'channel_types': [0, 2]},
    {'type': 7, 'custom_id': 'm_sel'},
    {'type': 6, 'custom_id': 'r_sel', 'placeholder': 'Roles'},
    {'type': 3, 'custom_id': 's_sel', 'options': [{'label': 'A', 'value': 'a'}]}]]
ui += [
    ('POST', '/api/v10/interactions/3018/tok_U/callback', {'type': 4, 'data': {'components': SELS, 'allowed_mentions': AM}}),
    ('POST', '/api/v10/interactions/3019/tok_U/callback', {'type': 9, 'data': {'custom_id': 'mod2', 'title': 'Pick', 'components': [
        {'type': 18, 'label': 'Who', 'component': {'type': 5, 'custom_id': 'u2', 'min_values': 1, 'max_values': 2, 'required': True}},
        {'type': 18, 'label': 'Where', 'component': {'type': 8, 'custom_id': 'c2', 'channel_types': [0], 'min_values': 0, 'required': False}}]}}),
]
for meth, path, bd in ui[-2:]:
    got = [d for d in ir if d['method'] == meth and d['path'] == path and not d['headers'].get('content-type', '').startswith('multipart/') and (json.loads(d['body']) if d['body'] else None) == bd]
    check(len(got) == 1, f'SEL {meth} {path} body {json.dumps(bd)[:90]}: matches {len(got)}')

check(len(ir) == len(want) + len(ui) + 2 + len(cases), f'exactly {len(want) + len(ui) + 2 + len(cases)} interaction REST calls, invalid ones never reached the network (saw {len(ir)})')

# ------------------------------------------------------------ per-route rate limiting
m = Mock('ratelimit', certdir)
p = run('rl', m, 120)
check(p.returncode == 0, f'rl exit {p.returncode} {p.stderr[-300:]}')
mm = re.search(r'RL phase1 (\d+)', p.stdout); phase1 = int(mm.group(1)) if mm else -1
mm = re.search(r'RL total (\d+)', p.stdout); total = int(mm.group(1)) if mm else -1
mm = re.search(r'RL global (\d+) (\d+)', p.stdout)
check(sum(1 for k, d in m.log if k == 'rl_violation') == 0, 'no request was sent on an empty bucket (the mock never answered 429 for a bucket)')
check('RL ok 8 of 8' in p.stdout, f'all 8 sends returned 200: {p.stdout!r}')
check(0 <= phase1 < (3000 if os.environ.get('VALGRIND') else 500), f'two channels have separate buckets, nothing waited (phase1 {phase1} ms)')
check(2600 <= total <= 5000, f'4 more sends on the exhausted channel waited for the bucket resets (total {total} ms)')
check(mm is not None and mm.group(1) == '200' and 500 <= int(mm.group(2)) <= 2500, f'global 429 retried after retry_after: {mm and mm.groups()}')
check(sum(1 for k, d in m.log if k == 'rest' and 'GLOBAL' in d['body']) == 2, 'the global 429 request was sent exactly twice')

# ------------------------------------------------------------ REST from many threads
m = Mock('main', certdir)
p = run('threads', m, 120)
check(p.returncode == 0, f'threads exit {p.returncode} {p.stderr[-300:]}')
check('THREADS ok=80 bad=0' in p.stdout, f'80 parallel sends all returned 200: {p.stdout!r}')
tp = [d for k, d in m.log if k == 'rest' and d['method'] == 'POST']
check(len(tp) == 80, f'mock saw 80 POSTs, got {len(tp)}')
check(len({json.loads(d['body'])['content'] for d in tp}) == 80, 'every parallel message body is intact and distinct')
conns = len({d['conn'] for d in tp})
check(1 < conns <= 8, f'parallel sends share at most 8 pooled connections, got {conns}')

# ------------------------------------------------------------ connection reuse
m = Mock('main', certdir)
p = run('reuse', m, 120)
check(p.returncode == 0 and 'REUSE ok=12 bad=0' in p.stdout, f'reuse run: {p.stdout!r} {p.stderr[-200:]}')
rc = {d['conn'] for k, d in m.log if k == 'rest'}
check(len(rc) == 1, f'12 sequential requests share ONE connection, got {len(rc)}')

m = Mock('main', certdir, drop_after=4)
p = run('reuse', m, 120)
check(p.returncode == 0 and 'REUSE ok=12 bad=0' in p.stdout, f'reuse with server dropping connections: {p.stdout!r} {p.stderr[-200:]}')
rc = [d for k, d in m.log if k == 'rest']
check(len({d['conn'] for d in rc}) <= 4, f'server-dropped connections are re-established, conns={len({d["conn"] for d in rc})}')
check(len(rc) == 12, f'no request is sent twice after a dropped connection (saw {len(rc)} for 12 calls)')

# ------------------------------------------------------------ fatal close code
m = Mock('fatal', certdir)
p = run('fatal', m, 60)
check(p.returncode == 0, f'fatal exit {p.returncode} {p.stderr[-300:]}')
check('RUN 1' in p.stdout, f'fatal run result: {p.stdout!r}')
check('close code 4004' in p.stderr, 'fatal message logged on stderr')
m = Mock('fatal', certdir)
p = run('fatallog', m, 60)
check(p.returncode == 0 and 'RUN 1' in p.stdout, f'fatallog run: {p.stdout!r}')
check(any(l.startswith('LOG ') and 'close code 4004' in l for l in p.stdout.split('\n')), f'log callback receives the fatal line: {p.stdout!r}')
check('close code' not in p.stderr, f'with a log callback nothing goes to stderr: {p.stderr!r}')
check(m.conn_n == 1, f'no reconnect after 4004 (conns={m.conn_n})')

# ------------------------------------------------------------ full session
m = Mock('main', certdir)
p = run('main', m, 240)
out, err = p.stdout, p.stderr
open('/tmp/caineasm_test_stdout.txt', 'w').write(out)
open('/tmp/caineasm_test_stderr.txt', 'w').write(err)
check(p.returncode == 0, f'main exit {p.returncode}: {err[-400:]}')
check('RUN 0' in out, 'casm_run returned 0 after casm_stop')
log = m.log
rest = [d for k, d in log if k == 'rest']
logins = [d for k, d in log if k == 'login']

# identify / resume
check(len(logins) == 3, f'3 logins (identify, resume, identify): {[(l["n"], l["op"]) for l in logins]}')
if len(logins) == 3:
    i1, r2, i3 = logins
    check(i1['op'] == 2 and i1['d']['token'] == 'tok.en' and i1['d']['intents'] == 37377, f'identify payload {i1}')
    check(i1['d']['properties']['browser'] == 'caineasm', 'identify properties')
    seq = [d for k, d in log if k == 'seq_before_reconnect'][0]['seq']
    check(r2['op'] == 6 and r2['d']['session_id'] == 'SESS1' and r2['d']['token'] == 'tok.en', f'resume payload {r2}')
    check(r2['d']['seq'] == seq, f'resume seq {r2["d"]["seq"]} == {seq}')
    check(i3['op'] == 2, 'identify again after invalid session (d=false)')
# ---- typed gateway events
RAWE = lambda tag: [l for l in out.split('\n') if l.startswith(tag + ' ') or l.startswith(tag + '\n') or l == tag]
for want_line in [
    'UPD id=2001 chan=1001 guild=G1 aid=U1 content=edited \\"x\\" \u00e9',
    'UPD id=2002 chan=1001 guild=<null> aid=<null> content=<null>',
    'DEL id=2003 chan=1001 guild=G1 raw=',
    'DEL id=2004 chan=1002 guild=<null> raw=',
    'REACT user=U1 chan=1001 msg=2001 guild=G1 emoji=\U0001F525 eid=<null> mauthor=U2 added=1 burst=0 raw=',
    'REACT user=U3 chan=1002 msg=2002 guild=<null> emoji=party eid=555 mauthor=<null> added=1 burst=1 raw=',
    'REACT user=U1 chan=1001 msg=2001 guild=G1 emoji=\U0001F525 eid=<null> mauthor=<null> added=0 burst=0 raw=',
    'MEMBER guild=G1 user=U7 name=newbie nick=Nibb \\"n\\" joined=1 raw=',
    'MEMBER guild=G1 user=U7 name=newbie nick=<null> joined=0 raw=',
]:
    check(any(l.startswith(want_line) for l in out.split('\n')), f'typed event line {want_line!r}')
for tag, n in [('UPD', 2), ('DEL', 2), ('REACT', 3), ('MEMBER', 2)]:
    check(len([l for l in out.split('\n') if l.startswith(tag + ' ')]) == n, f'{n} {tag} events (and nothing extra)')

PA = {'since': None, 'activities': [{'name': 'Custom Status', 'type': 4, 'state': 'custom text \u00e9'}], 'status': 'idle', 'afk': False}
PB = {'since': None, 'activities': [{'name': 'stream', 'type': 1, 'url': 'https://t.tv/x'}], 'status': 'online', 'afk': False}
if len(logins) == 3:
    check(logins[0]['d'].get('presence') == {'since': None, 'activities': [{'name': 'uptime "x"', 'type': 3}], 'status': 'dnd', 'afk': False},
          f'Identify carries the presence set before casm_run: {logins[0]["d"].get("presence")}')
    check('presence' not in logins[1]['d'], 'Resume has no presence')
    check(logins[2]['d'].get('presence') == PB, f'the second Identify carries the latest presence: {logins[2]["d"].get("presence")}')
pres = [d for k, d in log if k == 'presence']
check([d['d'] for d in pres] == [PA, PB], f'Update Presence (op 3) payloads: {[d["d"] for d in pres]}')
check(len(pres) == 2 and pres[1]['ts'] - pres[0]['ts'] >= 3.8, 'presence updates are at least 4 s apart (5 per 20 s limit)')
for k, v in [('pres', 0), ('pres2', 0), ('presbad1', -1), ('presbad2', -1), ('presbad3', -1), ('presbad4', -1)]:
    check(f'RET {k} {v}\n' in out, f'RET {k} {v}')
check(any(d['n'] == 2 and '/?v=10&encoding=json' in d['request_line'] for k, d in log if k == 'ws_open'),
      'resume connects to resume_gateway_url with ?v=10&encoding=json')
check(any(k == 'heartbeat' for k, d in log), 'heartbeats were sent')

# events and message parsing
for t, c in [('READY', 2), ('GUILD_CREATE', 1), ('RESUMED', 1)]:
    check(out.count(f'EVT {t} ') == c, f'event {t} x{c}')
check(out.count('EVT MESSAGE_CREATE ') == 11, f'11 MESSAGE_CREATE events, got {out.count("EVT MESSAGE_CREATE ")}')
msgs = [l for l in out.split('\n') if l.startswith('MSG ')]
check(len(msgs) == 11, f'11 parsed messages ({len(msgs)})')
m1 = msgs[0] if msgs else ''
for frag in ['id=2001', 'chan=1001', 'guild=G1', 'aid=U1', 'name=alice', 'nick=Nick',
             'content=!ping \\"x\\"\\nnl', 'every=1', 'bot=0', 'botid=900',
             'attach=[{"url":"https://cdn.example/a.png?x=1&y=2","content_type":"image/png"}]',
             'ment=[{"id":"900","username":"MockBot"}]', 'refaid=<null>']:
    check(frag in m1, f'2001 has {frag!r}: {m1!r}')
check(' mme=1 rtm=0 pre=1 prerest=\\"x\\"\\nnl ' in m1, f'helpers on 2001 (mentions me, prefix): {m1!r}')
m2 = next((l for l in msgs if ' id=2002 ' in l), '')
check('guild=<null>' in m2 and 'nick=<null>' in m2 and 'chan=1002' in m2, f'DM message parse: {m2!r}')
m3 = next((l for l in msgs if ' id=2003 ' in l), '')
check(' rtm=1 mme=0' not in m3 and ' mme=0 rtm=1 ' in m3, f'is_reply_to_me on 2003: {m3!r}')
check('refaid=900' in m3, f'reply ref author parse: {m3!r}')
m4 = next((l for l in msgs if ' id=2004 ' in l), '')
check('bot=1' in m4, f'bot flag parse: {m4!r}')


# REST calls
def find(method, path_end, pred=lambda d: True):
    return [d for d in rest if d['method'] == method and d['path'].endswith(path_end) and pred(d)]


def body(d):
    return json.loads(d['body']) if d['body'] else None


posts = [d for d in rest if d['method'] == 'POST' and d['path'] == '/api/v10/channels/1001/messages']
check(len(rest) > 0 and all(d['headers'].get('authorization') == 'Bot tok.en' for d in rest), 'Authorization: Bot tok.en on every request')
check(all(d['headers'].get('user-agent', '') == 'DiscordBot (https://github.com/Zaineedyou/CaineASM-Library, 0.3.0)' for d in rest), 'default User-Agent: DiscordBot (url, version) with this library and its version')
check(all(d['headers'].get('content-type', '').startswith('application/json') for d in rest), 'Content-Type json')

pong = [d for d in posts if body(d)['content'].startswith('pong')]
check(len(pong) == 2, f'two pong posts (2001 + after resume), got {len(pong)}')
if pong:
    b = body(pong[0])
    check(b['content'] == 'pong "q" \\ back\nline2 \U0001F600 é', f'send content escaping: {b["content"]!r}')
    check(b['message_reference'] == {'message_id': '2001', 'fail_if_not_exists': False}, f'reply reference {b}')
    check(b['allowed_mentions'] == {'parse': ['users'], 'replied_user': True}, f'allowed_mentions {b}')
check('RET send 200' in out, 'casm_send returned 200')

ty = find('POST', '/channels/1002/typing')
check(len(ty) == 1 and ty[0]['headers'].get('content-length') == '0', f'typing POST with empty body: {ty}')
check('RET typing 204' in out, 'casm_typing returned 204')

ed = find('PATCH', '/channels/1001/messages/5000')
check(len(ed) == 1 and body(ed[0])['content'] == 'edited "x"' and body(ed[0])['allowed_mentions'] == {'parse': ['users']}, f'edit: {ed}')
check('RET edit 200' in out, 'casm_edit returned 200')

de = find('DELETE', '/channels/1001/messages/5000')
check(len(de) == 1 and de[0]['body'] == '' and de[0]['headers'].get('content-length') == '0', f'delete: {de}')
check('RET del 204' in out, 'casm_delete returned 204')

re_ = find('PUT', '/channels/1001/messages/2004/reactions/%F0%9F%91%8D/@me')
check(len(re_) == 1 and re_[0]['headers'].get('content-length') == '0', f'react: {re_}')
check('RET react 204' in out, 'casm_react returned 204')

# long message
longp = [body(d) for d in posts if body(d)['content'].startswith('line ')]
check(len(longp) >= 3, f'long text split into >=3 messages, got {len(longp)}')
if longp:
    check(all(len(b['content']) <= 2000 for b in longp), 'every part <= 2000 chars')
    check('message_reference' in longp[0] and all('message_reference' not in b for b in longp[1:]), 'only the first part replies')
    lines = '\n'.join(b['content'] for b in longp).split('\n')
    check(len(lines) == 100 and all(re.fullmatch(r'line %03d a+' % i, l) for i, l in enumerate(lines)),
          'concatenated parts reproduce all 100 lines in order')
    check(all(not b['content'].startswith('\n') and not b['content'].endswith('\n') for b in longp), 'parts are trimmed')
check('RET long 200' in out, 'casm_send_long returned 200')

# generic request
check('RET req 200 len=' in out and '"username":"MockBot"' in out, 'casm_request returns the body')
rp = find('POST', '/api/v10/channels/1/messages', lambda d: d['body'] == '{"content":"raw"}')
check(len(rp) == 1, 'casm_request POST with body')
check('RET rawpost 200' in out, 'raw post status')

# validation
for i in range(1, 10):
    check(f'RET bad{i} -1' in out, f'invalid argument case bad{i} returns -1')
check(not any(('abc' in d['path'] or 'a/b' in d['path'] or '12x' in d['body'] or '1234567890123456789012' in d['path']) for d in rest),
      'invalid calls never reached the network')

# 429 retry
tt = [d for d in rest if d['method'] == 'POST' and '429TEST' in d['body']]
check(len(tt) == 2, f'429 retried once, attempts={len(tt)}')
check('RET 429 200' in out, 'casm_send succeeds after the 429 retry')

print(f'{checks[0]} checks, {len(fails)} failed')
sys.exit(1 if fails else 0)
