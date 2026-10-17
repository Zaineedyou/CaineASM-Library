# Changelog

All notable changes to CaineASM-Library. Versions follow `MAJOR.MINOR.PATCH`; `casm_version()` returns the current one.

## [0.3.0]

### Added
- **Command builder**: `casm_cmd_*` / `casm_opt_*` build slash commands, user/message context-menu commands, options, choices, ranges, length limits, autocomplete and sub-command groups. Discord's documented limits are checked before anything is sent (constructors return `NULL`, setters `-1`). Register with `casm_register_cmds` / `casm_register_guild_cmds`.
- **File attachments**: `casm_reply_file` and `casm_send_file` upload files as `multipart/form-data` for channel messages, message edits and interaction follow-ups. Limit 25 MiB per request. The first interaction response cannot carry files (use `casm_defer` + `casm_followup_reply`).
- **Entity select menus**: `casm_select_new_entity` (user / role / mentionable / channel), `casm_select_channel_type`, `casm_select_disabled` and `casm_modal_select` (select inside a modal).
- **Typed gateway events**: `casm_on_message_update`, `casm_on_message_delete`, `casm_on_reaction` (add and remove) and `casm_on_member` (member join and leave), each with a struct that includes the raw JSON.
- `casm_json_get` reads a dotted path from any raw JSON (for example the `resolved` data of an interaction).
- `casm_set_log_callback` redirects the library's log lines to your own function.
- `casm_version()` and `CASM_VERSION_MAJOR/MINOR/PATCH/STRING` in `caineasm.h`.
- `CASM_INTENT_DIRECT_MESSAGE_REACTIONS`.
- New examples in `examples/slash_bot.c`: commands registered through the builder and a `/file` command.
- 386 automated checks (up from 326), all passing, also under valgrind. Includes flood tests: 20,000 back-to-back messages and a slow-callback run.

### Changed
- The default User-Agent is now `DiscordBot (https://github.com/Zaineedyou/CaineASM-Library, 0.3.0)`.
- The REST timeout grows with the body size (20 s + 1 s per 128 KiB) so large uploads are not cut off.
- Exported symbols: 109 `casm_*` functions (was 98).
- README restructured.

### Fixed
- Pointer tables moved to `.data.rel.ro`, which removes a TEXTREL linker warning.

## [0.2]

### Added
- **Per-route rate limiter**: reads `X-RateLimit-Remaining` / `Reset-After`, waits before an empty bucket instead of hitting a 429, handles the global limit and retries a 429 once. Interaction endpoints are exempt.
- **Presence**: `casm_set_presence` (status + Playing / Streaming / Listening / Watching / Custom / Competing), sent in Identify and as Update Presence, at least 4 s apart.
- **Crash reporter**: `casm_set_crash_handler` prints the signal, fault address and backtrace, and resolves function names and lines with `addr2line` when it is installed.
- **REST connection reuse** through a mutex-protected pool of curl handles.
- Live testing on real Discord (slash commands, stress test, crash reporter), documented in the README.

## [0.1]

### Added
- **Gateway v10** with a hand-written WebSocket (RFC 6455): heartbeat with jitter, zombie-connection detection, resume, reconnect with backoff, clean stop on fatal close codes.
- **REST**: `casm_send`, `casm_send_long`, `casm_edit`, `casm_delete`, `casm_react`, `casm_typing` and `casm_request` for any endpoint.
- **Callbacks**: `casm_on_message`, `casm_on_interaction`, `casm_on_event`.
- **Slash commands**: respond, defer, follow-up, edit / delete the response, command registration from raw JSON, option and sub-command readers, `casm_interaction_keep`.
- **Embeds, buttons, select menus, modals, autocomplete** builders, senders and readers.
- Message helpers: `casm_unescape`, mention and reply checks, `casm_match_prefix`, `casm_next_word`.
- Static library `libcaineasm.a` with only `casm_*` symbols exported.
