# CaineASM-Library

A Discord bot library written in **x86-64 NASM assembly**, usable from C or other assembly code. It builds to a static library (`libcaineasm.a`) with one header (`include/caineasm.h`) and the prefix `casm_`.

Current version: **0.3.0**. See [CHANGELOG.md](CHANGELOG.md).

## Contents
- [Features](#features)
- [Build](#build)
- [Quick start](#quick-start)
- [Guides](#guides): [Rules](#important-rules), [Events](#events), [Slash commands](#slash-commands), [Command builder](#command-builder), [Select menus](#select-menus), [File attachments](#file-attachments), [Presence](#presence), [Rate limiting](#rate-limiting), [Version and logging](#version-and-logging), [Crash reporter](#when-it-crashes)
- [API reference](#api-reference)
- [Limitations](#limitations)
- [Testing](#testing)

## Features
- **Gateway v10**: hand-written WebSocket (RFC 6455), heartbeat with jitter, zombie-connection detection, automatic resume, reconnect with backoff, clean stop on fatal close codes (bad token / missing intents).
- **REST**: send, reply, edit, delete, reactions, typing, and `casm_request` for any endpoint. Connections are reused through a pool of curl handles.
- **Rate limiting**: per-route, waits before the next request instead of hitting a 429.
- **Events**: parsed callbacks for messages (create / update / delete), reactions, members and interactions, plus raw events.
- **Interactions**: slash commands, buttons, select menus (string, user, role, mentionable, channel), modals, autocomplete, defer and follow-ups.
- **Builders**: command builder, embeds, components, replies, with Discord's documented limits checked before sending.
- **File attachments** with `multipart/form-data`.
- **Presence / status**.
- **Crash reporter** with automatic `addr2line` resolution.
- **Message helpers**: `casm_unescape`, mention checks, prefix and word parsing.

Dependencies: **libcurl** (only for TCP + TLS and HTTPS) and libc. No other Discord library is used.

## Build
Requires `nasm`, `gcc`, `ld`, `objcopy`, `ar`, `libcurl4-openssl-dev`. The crash reporter additionally uses `addr2line` (binutils) at runtime if present.

```
make            # build/libcaineasm.a
make test       # end-to-end tests against a local mock Discord (386 checks)
make valgrind   # the same tests under valgrind
make example    # build/ping_bot and build/slash_bot
```

Only the 109 `casm_*` symbols are visible from outside (internal symbols are made local with `objcopy`), so nothing collides with names in your code.

Link your program with: `cc app.c libcaineasm.a -Iinclude -l:libcurl.so.4 -pthread`

## Quick start
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
Full examples: `examples/ping_bot.c` (prefix command) and `examples/slash_bot.c` (commands from the command builder, defer + worker thread, embed, buttons, select menu, modal, file upload). Enable the **Message Content Intent** in the Discord Developer Portal for prefix commands.

## Guides

### Important rules
- Text from Discord arrives as **slices (ptr + len) into an internal buffer**, still **JSON-escaped** (`\"`, `\n`, `\uXXXX`), and valid only while the callback runs. Copy it if you need to keep it (or use `casm_interaction_keep`).
- Text you send with `casm_send*` is plain UTF-8; the library escapes it.
- Callbacks run on the gateway thread, one event at a time. While a callback runs, no heartbeat is sent and no event is read. If the backlog takes longer than the heartbeat interval (about 41 s on real Discord) the pending heartbeat ACK is not read in time and the library reconnects and resumes, as the docs require for a zombied connection. Slow work (for example calling an AI API) belongs on your own thread. REST functions are safe to call from any thread (a mutex-protected pool of curl handles).
- Mentions in sent messages are limited to users (`allowed_mentions.parse = ["users"]`), so the bot cannot ping `@everyone` or roles.

### Events
Besides `casm_on_message` and `casm_on_interaction`, there are typed callbacks (structs in `caineasm.h`, slices valid only during the callback):
- `casm_on_message_update(cb, user)`: MESSAGE_UPDATE (same shape as a message; fields can be empty).
- `casm_on_message_delete(cb, user)`: MESSAGE_DELETE (`id`, `channel_id`, `guild_id`).
- `casm_on_reaction(cb, user)`: reaction add and remove (`added` tells which; emoji name/id, `burst`).
- `casm_on_member(cb, user)`: GUILD_MEMBER_ADD / GUILD_MEMBER_REMOVE (`joined` tells which). Needs `CASM_INTENT_GUILD_MEMBERS`, a privileged intent you must enable in the Developer Portal.
- `casm_json_get(&json, "a.b.c", &out)` reads a dotted path from any `raw` JSON (for example `resolved` data) and returns the value type.

Reactions need `GUILD_MESSAGE_REACTIONS` (and `DIRECT_MESSAGE_REACTIONS` for DMs); message update/delete need `GUILD_MESSAGES`.

### Slash commands
Register a callback with `casm_on_interaction(cb, user)`. The first response is due within **3 seconds**, so slow work goes on your own thread: call `casm_defer(i, flags)`, copy the interaction with `casm_interaction_keep(i)`, and answer later with `casm_followup` or `casm_edit_response` (the token is valid for 15 minutes).
- `casm_respond(i, text, len, flags)` answers at once. `flags = CASM_MSG_EPHEMERAL` makes it visible only to that user.
- Read options with `casm_option`, `casm_option_in`, `casm_subcommand`, and the focused option of an autocomplete with `casm_option_focused`.
- Read component and modal submissions with `casm_modal_value`, `casm_select_values` and `casm_array_at`.
- Register commands from the [command builder](#command-builder) or from raw JSON with `casm_register_commands` (bulk overwrite, needs READY first).
- See `examples/slash_bot.c` for a complete bot (embed, buttons, select menu, modal, file upload, defer + worker thread).

### Command builder
```c
casm_cmd *c = casm_cmd_new("ban", "Ban a member");
casm_opt *who = casm_opt_new(CASM_OPT_USER, "who", "Member", 1);
casm_opt *why = casm_opt_new(CASM_OPT_STRING, "reason", "Reason", 0);
casm_opt_length(why, 1, 200);
casm_cmd_option(c, who);                          /* required options first */
casm_cmd_option(c, why);
casm_cmd_permissions(c, "4");                     /* BAN_MEMBERS (decimal permission bits) */
casm_cmd *list[] = { c };
casm_register_guild_cmds(guild_id, list, 1);      /* or casm_register_cmds(list, 1) */
casm_builder_free(c); casm_builder_free(who); casm_builder_free(why);
```
- Constructors return `NULL`, setters `-1`, **before anything is sent**, when a documented rule is broken: names 1-32 characters and lowercase `[-_a-z0-9]` (non-ASCII allowed), descriptions 1-100, at most 25 options / choices per list, required options before optional ones, choices only on STRING / INTEGER / NUMBER options with a matching value type, no choices together with autocomplete, integers within ±(2^53-1).
- Adding an option **copies** it, so add an option's choices and sub-options first and the option to its parent afterwards. A sub-command group takes sub-commands, a sub-command takes normal options.
- `casm_cmd_new_context("Show Info", 2)` makes a user menu command (3 = message menu). `casm_cmd_contexts(c, CASM_CTX_GUILD | CASM_CTX_PRIVATE_CHANNEL)` sets where a global command is usable.
- Not covered: localizations, `channel_types`, `file_types`, `integration_types`. Use raw JSON with `casm_register_commands` for those. Discord still checks the rest (for example no top-level options next to sub-commands) and answers 400.

### Select menus
`casm_select_new_entity(CASM_SELECT_USER | ROLE | MENTIONABLE | CHANNEL, custom_id, placeholder, min, max)` creates user/role/mentionable/channel selects. `casm_select_channel_type()` restricts channel types, `casm_select_disabled()` disables it, and `casm_modal_select()` puts one inside a modal. Selected ids arrive in the interaction `values`; names are in `resolved` (read with `casm_json_get`).

### File attachments
```c
casm_send_file("123456789", "report.txt", data, len, NULL, "Here you go");        /* one call */

casm_reply *r = casm_reply_new();                                                 /* or several files */
casm_embed *e = casm_embed_new();
casm_embed_image(e, "attachment://chart.png");                                    /* show it in the embed */
casm_reply_embed(r, e);
casm_reply_file(r, "chart.png", png, png_len, NULL);
casm_reply_file(r, "data.csv", csv, csv_len, NULL);
casm_send_reply("123456789", r, NULL);
casm_builder_free(r); casm_builder_free(e);
```
- Sent as `multipart/form-data` exactly as in the Discord docs: a `payload_json` part with the message and an `attachments` array, plus one `files[n]` part per file.
- Works with `casm_send_reply`, `casm_edit_message` (the new files **replace** the existing attachments), `casm_followup_reply` and `casm_edit_response_reply`. The first interaction response (`casm_respond_reply`, `casm_update_reply`) cannot carry files and returns `-1`: call `casm_defer` first, then `casm_followup_reply`.
- The bytes are copied. `content_type` may be `NULL` (guessed from png jpg jpeg gif webp txt log csv json pdf mp3 mp4 zip, otherwise `application/octet-stream`). Filenames: 1-255 bytes, no control characters, `"`, `\` or `/`.
- A request is limited to 25 MiB (Discord docs); larger uploads return `-1` before anything is sent. Embeds can only display `.jpg .jpeg .png .webp .gif`. The transfer timeout grows with the body (20 s + 1 s per 128 KiB).

### Presence
```c
casm_set_presence("dnd", CASM_ACTIVITY_WATCHING, "uptime", NULL);
casm_set_presence("online", CASM_ACTIVITY_CUSTOM, "hello there", NULL);   /* custom status line */
casm_set_presence("online", CASM_ACTIVITY_STREAMING, "live", "https://twitch.tv/x");
casm_set_presence("idle", -1, NULL, NULL);                               /* status only */
```
- `status`: `"online"` (or `NULL`), `"idle"`, `"dnd"`, `"invisible"`, `"offline"`. `activity_type`: `-1` none, 0 Playing, 1 Streaming (`url` optional), 2 Listening, 3 Watching, 4 Custom (`text` is the status line), 5 Competing.
- Returns `0`, or `-1` for an unknown status/type or missing text.
- Can be called before `casm_run` (sent in Identify) or at any time from any thread (sent as Update Presence by the gateway thread). Discord allows 5 updates per 20 s, so updates go out at least 4 s apart and the latest one wins. After a reconnect with a fresh Identify the latest presence is sent again.

### Rate limiting
Every REST call goes through a small limiter (64 route slots, thread-safe):
- Limits are keyed the way Discord's docs describe: by method + route with the top-level resource (channel, guild, webhook) kept and other IDs folded, so two channels have separate buckets.
- `X-RateLimit-Remaining` and `X-RateLimit-Reset-After` from each response update the bucket. When a bucket is empty the call sleeps until it resets (each wait capped at 10 s) instead of sending a request that would be rejected.
- A global 429 pauses all routes for `retry_after`. A normal 429 is retried once after `retry_after`.
- Interaction callbacks (`/interactions/...`) are not limited, because Discord exempts them.

### Version and logging
- `casm_version()` and `CASM_VERSION_STRING` ("0.3.0"). The default User-Agent is `DiscordBot (<repo url>, 0.3.0)`; change it with `casm_set_user_agent`.
- `casm_set_log_callback(cb, user)` sends every library log line to your function instead of stderr (`NULL` restores stderr).

### When it crashes
Call `casm_set_crash_handler(1)` on the thread that runs `casm_run` (stack overflows are reported too). Example output:
```
💥 CaineASM crash: SIGSEGV (invalid memory access), fault address 0x28, instruction 0x557b10580ae1
backtrace (addr2line -f -e <binary> <+offset>):
./app(+0x9ae1)[0x557b10580ae1]
```
If `addr2line` (binutils) is installed, the handler prints function names and lines for frames inside your binary (build with `-g`), e.g. `ix_path at src/interact.asm:124`. Without it, run it yourself: `addr2line -f -e ./app +0x9ae1`. The backtrace follows the `rbp` chain, so code without frame pointers (libc, libcurl, C built with `-O2`) may not appear. Alternatives without the handler: `gdb -batch -ex run -ex bt ./app` or `valgrind ./app`.

## API reference
| Function | Purpose |
|---|---|
| `casm_init(token, intents)` | Set up the client (once). `0` ok, `-1` failure |
| `casm_on_message(cb, user)` / `casm_on_event(cb, user)` | Register callbacks |
| `casm_on_message_update`, `casm_on_message_delete`, `casm_on_reaction`, `casm_on_member` | Typed event callbacks (see [Events](#events)) |
| `casm_json_get(&json, path, &out)` | Read a dotted path from raw JSON |
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
| `casm_register_commands(json, len)` / `casm_register_guild_commands(guild, json, len)` | Register commands from raw JSON (bulk overwrite). Needs READY first |
| `casm_cmd_new(name, desc)`, `casm_cmd_new_context(name, 2\|3)`, `casm_cmd_option`, `casm_cmd_permissions`, `casm_cmd_nsfw`, `casm_cmd_contexts` | Build a slash command / user or message context-menu command (see below) |
| `casm_opt_new(type, name, desc, required)`, `casm_opt_choice/_int/_num`, `casm_opt_range_int/_num`, `casm_opt_length`, `casm_opt_autocomplete`, `casm_opt_add` | Build options, choices, limits, sub-commands and groups |
| `casm_register_cmds(list, n)` / `casm_register_guild_cmds(guild, list, n)` | Register built commands (up to 100). Needs READY first |
| `casm_option(i, name, &v)`, `casm_option_in(opts, name, &v)`, `casm_subcommand(opts, &name, &sub)` | Read command options. Returns the JSON type: `'s'` string, `'d'` number, `'b'` bool, `0` missing |
| `casm_interaction_keep(i)` / `casm_interaction_release(p)` | A copy of the interaction that stays valid after the callback returns (for worker threads) |
| `casm_embed_new` + `casm_embed_title/description/url/timestamp/footer/author/image/thumbnail/color/field` | Build an embed (plain C strings, escaped automatically) |
| `casm_row_new`, `casm_row_button(r, style, label, id_or_url, disabled)`, `casm_select_new`, `casm_select_option`, `casm_row_select`, `casm_select_new_entity`, `casm_select_channel_type`, `casm_select_disabled`, `casm_modal_select` | Buttons (primary/secondary/success/danger/link) and select menus |
| `casm_modal_new`, `casm_modal_input(...)` | Modal with text inputs (wrapped in a Label, as the current docs require) |
| `casm_reply_new`, `casm_reply_content/flags/embed/row` | Compose a message payload; free every builder with `casm_builder_free` |
| `casm_reply_file(r, filename, data, len, content_type)` / `casm_send_file(chan, filename, data, len, content_type, text)` | Attach a file to a reply / send one file in one call |
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
| `casm_set_log_callback(cb, user)`, `casm_version()` | Log redirection, library version |

REST functions return the HTTP status (2xx = success), `0` if the transfer failed, `-1` for invalid arguments (IDs must be 1–20 digits, so a `/` or `..` can never be injected into a path).

## Limitations
- **One client per process** (global state).
- Not included: voice, sharding, guild/user cache, other components (Components V2 such as Section/Container), command localizations, length-limit checks for embeds and messages (Discord rejects with 400), attachments on the first interaction response, and interaction signature verification for HTTP webhooks (this library receives interactions over the gateway).
- The REST pool holds at most 8 handles; connections closed by the server are reopened automatically.
- The rate limiter is keyed by route, not by Discord's bucket hash, and the table has 64 slots (oldest entries are reused).
- x86-64 Linux only (ELF64, SysV ABI).
- The 386 automated checks run against a local mock Discord (gateway + REST over TLS). Live testing on real Discord is described under "Tested on real Discord" below. The v0.3 additions (command builder, file upload, typed events, entity selects) have only been tested against the mock so far.

## Testing

### Tested on real Discord
Tested live against real Discord, deployed as a bot on Railway:
- **Slash commands**: `/panel` (embed, buttons, select menu, modal, `casm_update_reply`), `/about`, `/color`, `/echo` (defer + follow-up), `/ping` and `/raw` (REST through `casm_request`) all worked, including ephemeral replies.
- **Stress test**: 60 seconds with 4 workers. The bot stayed online with no errors, and memory went back to about 4 MB afterwards.
- **Crash reporter**: a deliberate crash on Railway printed the signal, fault address and backtrace, and `addr2line` resolved the function names and source lines (`ix_path at src/interact.asm:124`, and so on).

### Automated tests
`tests/run_test.py` runs `tests/test_caineasm.c` against `tests/mock_discord.py` (386 checks, also under valgrind with no errors and no definite leaks):
- Gateway: identify, heartbeat, resume with the right sequence, invalid session then re-identify, fatal close code 4004, parsing of every message field (guild, DM, reply, bot, attachment, mention).
- REST: every function (body, headers, method), long-message splitting, 429 retry, argument validation, 80 parallel sends from 8 threads, connection reuse (including when the server drops the connection).
- Rate limiting: a Discord-style bucket mock (2 requests / 1.5 s per channel) must never see a request on an empty bucket; separate channels don't wait on each other; a global 429 is retried after `retry_after`.
- Presence: payload in Identify, op 3 updates (exact JSON, at least 4 s apart), no presence on Resume, latest presence on re-Identify, invalid arguments rejected.
- Command builder: the registered JSON for slash commands, options, choices, ranges, autocomplete, groups, context menus and flags is compared with the documented shapes, and dozens of rule violations must return `NULL` / `-1` without reaching the network.
- File uploads: every multipart request is parsed and compared byte for byte (framing, `payload_json`, `files[n]` headers and data, including binary data that looks like multipart markers and a 1 MB file), each with its own boundary; invalid filenames, content types and over-limit uploads are rejected.
- `casm_unescape`: test vectors plus a 5000-case fuzz against `json.dumps`, including UTF-8 truncation.
- Flood: 20,000 `MESSAGE_CREATE` events sent back to back must all arrive in order with intact fields, with no reconnect (measured on a dev machine: about 9-11 us per event, over 90,000 events/s, +2 MB memory). A second run with a 2 ms-per-message callback checks that a slow callback still receives everything in order.
- Message helpers, the crash handler (the signal still kills the process, fault address and backtrace are printed, stack overflow included), and the whole slash-command flow: parsing, respond/defer/followup/edit/delete, options and subcommands, command registration, `casm_interaction_keep`, and every builder compared field by field with the expected JSON, plus the modal / select / autocomplete readers.
