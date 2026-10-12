#!/usr/bin/env python3
"""Runs the C test client against the mock Discord and verifies everything.
usage: run_test.py <test binary>      (VALGRIND=1 to run under valgrind)"""
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mock_discord import Mock  # noqa: E402

binary = os.path.abspath(sys.argv[1])
vg = (['valgrind', '-q', '--error-exitcode=9', '--leak-check=no'] if os.environ.get('VALGRIND') else [])
cafile = os.path.join(HERE, 'cert.pem')
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
for k, v in [('init_null', '-1'), ('init_empty', '-1'), ('run_noinit', '-1'), ('botid', 'null')]:
    check(f'MISC {k} {v}' in p.stdout, f'misc {k} expected {v}: {p.stdout!r}')

# ------------------------------------------------------------ REST from many threads
m = Mock('main')
p = run('threads', m, 120)
check(p.returncode == 0, f'threads exit {p.returncode} {p.stderr[-300:]}')
check('THREADS ok=80 bad=0' in p.stdout, f'80 parallel sends all returned 200: {p.stdout!r}')
tp = [d for k, d in m.log if k == 'rest' and d['method'] == 'POST']
check(len(tp) == 80, f'mock saw 80 POSTs, got {len(tp)}')
check(len({json.loads(d['body'])['content'] for d in tp}) == 80, 'every parallel message body is intact and distinct')

# ------------------------------------------------------------ fatal close code
m = Mock('fatal')
p = run('fatal', m, 60)
check(p.returncode == 0, f'fatal exit {p.returncode} {p.stderr[-300:]}')
check('RUN 1' in p.stdout, f'fatal run result: {p.stdout!r}')
check('close code 4004' in p.stderr, 'fatal message logged on stderr')
check(m.conn_n == 1, f'no reconnect after 4004 (conns={m.conn_n})')

# ------------------------------------------------------------ full session
m = Mock('main')
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
m2 = next((l for l in msgs if ' id=2002 ' in l), '')
check('guild=<null>' in m2 and 'nick=<null>' in m2 and 'chan=1002' in m2, f'DM message parse: {m2!r}')
m3 = next((l for l in msgs if ' id=2003 ' in l), '')
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
check(all(d['headers'].get('user-agent', '').startswith('DiscordBot (') for d in rest), 'User-Agent follows the DiscordBot format')
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
