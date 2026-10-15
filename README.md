# CaineASM-Library

A Discord bot library written in **x86-64 NASM assembly**, usable from C or other assembly code. Built from the proven CaineASM Lite modules.

Features:
- **Gateway v10**: hand-written WebSocket (RFC 6455), heartbeat with jitter, zombie-connection detection, automatic resume, reconnect with backoff, and a clean stop on fatal close codes (bad token / missing intents).
- **REST**: send/reply, edit, delete, reactions, typing, plus `casm_request` for any endpoint.
- **Per-route rate limiting**: reads `X-RateLimit-Remaining` / `Reset-After` on every response and waits *before* the next request on the same route instead of hitting a 429. Handles the global limit and retries a 429 once using `retry_after`. Interaction endpoints are exempt, as in Discord's docs.
- **Callbacks**: `casm_on_message` (parsed message), `casm_on_interaction` (parsed slash command / button / modal) and `casm_on_event` (every dispatch event, raw JSON).
- **Slash commands**: respond, defer, followup, edit/delete the response, register commands (global/guild), option and subcommand helpers.
- **Embeds, buttons, select menus, modals**: builders (`casm_embed_*`, `casm_row_*`, `casm_select_*`, `casm_modal_*`, `casm_reply_*`), senders (`casm_send_reply`, `casm_respond_reply`, `casm_update_reply`, `casm_show_modal`, `casm_autocomplete`) and readers (`casm_modal_value`, `casm_select_values`, `casm_option_focused`).
- **Presence / status**: `casm_set_presence` (online/idle/dnd/invisible + Playing/Streaming/Listening/Watching/Custom/Competing). Sent in Identify and as Update Presence, throttled to Discord's limit.
- **Message helpers**: `casm_unescape`, bot-mention check, reply-to-bot check, `casm_match_prefix`, `casm_next_word`.
- **REST connection reuse** (keep-alive through a pool of curl handles).
- **Crash reporter**: on SIGSEGV and friends prints the fault address and a backtrace, and resolves function names and lines with `addr2line` automatically.

Dependencies: **libcurl** (only for TCP+TLS and HTTPS) and libc. No other Discord library is used.

## Build
Requires `nasm`, `gcc`, `ld`, `objcopy`, `ar`, `libcurl4-openssl-dev`. The crash reporter's name resolution additionally uses `addr2line` (binutils) at runtime if present.

```
make            # build/libcaineasm.a
make test       # end-to-end tests against a local mock Discord (209 checks)
make valgrind   # the same tests under valgrind
make example    # build/ping_bot and build/slash_bot
```

Only the 79 `casm_*` symbols are visible from outside (internal symbols are made local with `objcopy`), so nothing collides with names in your code.

## Example
```c
#include "caineasm.h"

static void on_message(const casm_message *m, void *user) {
    if (m->author_is_bot) return;
    char chan[32], id[32];                       /* slices are not NUL-terminated */
    snprintf(chan, sizeof chan, "%.*s", (int)m->channel_id.len, m->channel_id.ptr);
    snprintf(id,   sizeof id,   "%.*s", (int)m->id.len,         m->id.ptr);
    if (m->content.len == 5 && !memcmp(m->content.ptr, "!ping", 5))
        casm_send(chan, "pong", 4, id);          /* reply to that message */
}

int main(void) {
    casm_init(getenv("DISCORD_TOKEN"), CASM_INTENTS_DEFAULT);
    casm_set_presence("online", CASM_ACTIVITY_WATCHING, "the gateway", NULL);
    casm_on_message(on_message, NULL);
    return casm_run();                           /* blocking */
}
```
Link: `cc app.c libcaineasm.a -Iinclude -l:libcurl.so.4 -pthread`. Full examples: `examples/ping_bot.c` (prefix command) and `examples/slash_bot.c` (slash commands with defer + worker thread, embed, buttons, select menu, modal). Enable the **Message Content Intent** in the Discord Developer Portal for prefix commands.

## API
| Function | Purpose |
|---|---|
| `casm_init(token, intents)` | Set up the client (once). `0` ok, `-1` failure |
| `casm_on_message(cb, user)` / `casm_on_event(cb, user)` | Register callbacks |
| `casm_run()` | Blocking. `0` stopped, `1` fatal (token/intents), `-1` not initialised |
| `casm_stop()` | Stop (safe to call from a signal handler) |
| `casm_bot_id()` | Bot ID, `NULL` before READY |
| `casm_send(chan, text, len, reply_to)` | Send one message. `reply_to` may be `NULL` |
| `casm_send_long(...)` | Splits automatically at 1900 bytes (at newlines where possible); only the first chunk replies |
| `casm_edit`, `casm_delete`, `casm_react`, `casm_typing` | Edit, delete, reaction (emoji already URL-encoded), typing indicator |
| `casm_request(method, path, body, len, &resp, &resp_len)` | Any REST endpoint (GET/POST/PUT/PATCH/DELETE). Free the result with `casm_free` |
| `casm_on_interaction(cb, user)` | `INTERACTION_CREATE` callback (slash command, button, ...). The first response is due within **3 seconds** |
| `casm_respond(i, text, len, flags)` / `casm_defer(i, flags)` | First response (type 4) / "thinking..." (type 5). `flags = CASM_MSG_EPHEMERAL` (64) makes it visible only to that user |
| `casm_interaction_response(i, type, json, len)` | First response with any type (1..99) and raw `data` JSON (embeds, components, modal, autocomplete) |
| `casm_followup`, `casm_edit_response`, `casm_delete_response` | Follow-up message, edit, delete the first response (token valid for 15 minutes) |
| `casm_register_commands(json, len)` / `casm_register_guild_commands(guild, json, len)` | Register commands (bulk overwrite). Needs READY first |
| `casm_option(i, name, &v)`, `casm_option_in(opts, name, &v)`, `casm_subcommand(opts, &name, &sub)` | Read command options. Returns the JSON type: `'s'` string, `'d'` number, `'b'` bool, `0` missing |
| `casm_interaction_keep(i)` / `casm_interaction_release(p)` | A copy of the interaction that stays valid after the callback returns (for worker threads) |
| `casm_embed_new` + `casm_embed_title/description/url/timestamp/footer/author/image/thumbnail/color/field` | Build an embed (plain C strings, escaped automatically) |
| `casm_row_new`, `casm_row_button(r, style, label, id_or_url, disabled)`, `casm_select_new`, `casm_select_option`, `casm_row_select` | Buttons (primary/secondary/success/danger/link) and select menus |
| `casm_modal_new`, `casm_modal_input(...)` | Modal with text inputs (wrapped in a Label, as the current docs require) |
| `casm_reply_new`, `casm_reply_content/flags/embed/row` | Compose a message payload; free every builder with `casm_builder_free` |
| `casm_send_reply`, `casm_edit_message`, `casm_respond_reply`, `casm_update_reply`, `casm_followup_reply`, `casm_edit_response_reply`, `casm_show_modal` | Send a payload to a channel / as an interaction response |
| `casm_autocomplete(i, names, values, n)`, `casm_option_focused(i, &name, &value)` | Autocomplete (max 25 choices) |
| `casm_modal_value(i, custom_id, &v)`, `casm_select_values(i, &arr)`, `casm_array_at(&arr, idx, &v)` | Read modal and select-menu submissions |
| `casm_set_presence(status, activity_type, text, url)` | Set the bot status and activity (see below) |
| `casm_unescape(src, len, dst, cap)` | Decode JSON escapes to UTF-8 (`snprintf`-style return, never cuts a UTF-8 character) |
| `casm_mentions_user(m, id)`, `casm_mentions_me(m)`, `casm_is_reply_to_me(m)` | Mention / reply checks |
| `casm_match_prefix(&content, "caine", &rest)`, `casm_next_word(&text, &word, &rest)` | Command parsing |
| `casm_app_id()`, `casm_cleanup()` | Application ID (after READY), free the connection pool |
| `casm_set_crash_handler(1)` | On a crash (SIGSEGV/SIGBUS/SIGFPE/SIGILL/SIGABRT) print the signal, fault address, instruction pointer and backtrace to stderr, then die as usual (core dump is kept) |
| `casm_set_api_base / set_gateway_url / set_user_agent / set_ca_file / set_quiet` | Optional |

REST functions return the HTTP status (2xx = success), `0` if the transfer failed, `-1` for invalid arguments (IDs must be 1–20 digits, so a `/` or `..` can never be injected into a path).

## Presence
```c
casm_set_presence("dnd", CASM_ACTIVITY_WATCHING, "uptime", NULL);
casm_set_presence("online", CASM_ACTIVITY_CUSTOM, "hello there", NULL);   /* custom status line */
casm_set_presence("online", CASM_ACTIVITY_STREAMING, "live", "https://twitch.tv/x");
casm_set_presence("idle", -1, NULL, NULL);                               /* status only */
```
- `status`: `"online"` (or `NULL`), `"idle"`, `"dnd"`, `"invisible"`, `"offline"`. `activity_type`: `-1` none, 0 Playing, 1 Streaming (`url` optional), 2 Listening, 3 Watching, 4 Custom (`text` is the status line), 5 Competing.
- Returns `0`, or `-1` for an unknown status/type or missing text.
- Can be called before `casm_run` (sent in Identify) or at any time from any thread (sent as Update Presence by the gateway thread). Discord allows 5 updates per 20 s, so updates go out at least 4 s apart and the latest one wins. After a reconnect with a fresh Identify the latest presence is sent again.

## Rate limiting
Every REST call goes through a small limiter (64 route slots, thread-safe):
- Limits are keyed the way Discord's docs describe: by method + route with the top-level resource (channel, guild, webhook) kept and other IDs folded, so two channels have separate buckets.
- `X-RateLimit-Remaining` and `X-RateLimit-Reset-After` from each response update the bucket. When a bucket is empty the call sleeps until it resets (each wait capped at 10 s) instead of sending a request that would be rejected.
- A global 429 pauses all routes for `retry_after`. A normal 429 is retried once after `retry_after`.
- Interaction callbacks (`/interactions/...`) are not limited, because Discord exempts them.

## Important rules
- Text from Discord arrives as **slices (ptr + len) into an internal buffer**, still **JSON-escaped** (`\"`, `\n`, `\uXXXX`), and valid only while the callback runs. Copy it if you need to keep it (or use `casm_interaction_keep`).
- Text you send with `casm_send*` is plain UTF-8; the library escapes it.
- Callbacks run on the gateway thread. Slow work (for example calling an AI API) belongs on your own thread. REST functions are safe to call from any thread (a mutex-protected pool of curl handles).
- Mentions in sent messages are limited to users (`allowed_mentions.parse = ["users"]`), so the bot cannot ping `@everyone` or roles.

## When it crashes
Call `casm_set_crash_handler(1)` on the thread that runs `casm_run` (stack overflows are reported too). Example output:
```
💥 CaineASM crash: SIGSEGV (invalid memory access), fault address 0x28, instruction 0x557b10580ae1
backtrace (addr2line -f -e <binary> <+offset>):
./app(+0x9ae1)[0x557b10580ae1]
```
If `addr2line` (binutils) is installed, the handler prints function names and lines for frames inside your binary (build with `-g`), e.g. `ix_path at src/interact.asm:124`. Without it, run it yourself: `addr2line -f -e ./app +0x9ae1`. The backtrace follows the `rbp` chain, so code without frame pointers (libc, libcurl, C built with `-O2`) may not appear. Alternatives without the handler: `gdb -batch -ex run -ex bt ./app` or `valgrind ./app`.

## Limitations (v0.2)
- **One client per process** (global state).
- Not included: voice, sharding, guild/user cache, file attachments, other components (user/role/channel select, Components V2 such as Section/Container), a command builder (write the JSON yourself), length-limit checks (Discord rejects with 400), and interaction signature verification for HTTP webhooks (this library receives interactions over the gateway).
- The REST pool holds at most 8 handles; connections closed by the server are reopened automatically.
- The rate limiter is keyed by route, not by Discord's bucket hash, and the table has 64 slots (oldest entries are reused).
- x86-64 Linux only (ELF64, SysV ABI).
- The 209 automated checks run against a local mock Discord (gateway + REST over TLS). Live testing on real Discord is described under "Real-world testing" below.

## Real-world testing
Tested live against real Discord, deployed as a bot on Railway:
- **Slash commands**: `/panel` (embed, buttons, select menu, modal, `casm_update_reply`), `/about`, `/color`, `/echo` (defer + follow-up), `/ping` and `/raw` (REST through `casm_request`) all worked, including ephemeral replies.
- **Stress test**: 60 seconds with 4 workers. The bot stayed online with no errors, and memory went back to about 4 MB afterwards.
- **Crash reporter**: a deliberate crash on Railway printed the signal, fault address and backtrace, and `addr2line` resolved the function names and source lines (`ix_path at src/interact.asm:124`, and so on).

## Tests
`tests/run_test.py` runs `tests/test_caineasm.c` against `tests/mock_discord.py` (209 checks, also under valgrind with no errors and no definite leaks):
- Gateway: identify, heartbeat, resume with the right sequence, invalid session then re-identify, fatal close code 4004, parsing of every message field (guild, DM, reply, bot, attachment, mention).
- REST: every function (body, headers, method), long-message splitting, 429 retry, argument validation, 80 parallel sends from 8 threads, connection reuse (including when the server drops the connection).
- Rate limiting: a Discord-style bucket mock (2 requests / 1.5 s per channel) must never see a request on an empty bucket; separate channels don't wait on each other; a global 429 is retried after `retry_after`.
- Presence: payload in Identify, op 3 updates (exact JSON, at least 4 s apart), no presence on Resume, latest presence on re-Identify, invalid arguments rejected.
- `casm_unescape`: test vectors plus a 5000-case fuzz against `json.dumps`, including UTF-8 truncation.
- Message helpers, the crash handler (the signal still kills the process, fault address and backtrace are printed, stack overflow included), and the whole slash-command flow: parsing, respond/defer/followup/edit/delete, options and subcommands, command registration, `casm_interaction_keep`, and every builder compared field by field with the expected JSON, plus the modal / select / autocomplete readers.
