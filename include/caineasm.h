/* CaineASM-Library - a small Discord bot library written in x86-64 assembly (NASM).
 *
 * Gateway v10 (WebSocket, heartbeat, resume/reconnect) + REST helpers on top of
 * libcurl. Callable from C or assembly (SysV ABI). One client per process.
 *
 *   casm_init(token, CASM_INTENTS_DEFAULT);
 *   casm_on_message(my_cb, NULL);
 *   casm_run();                       // blocks
 *
 * Strings that come from Discord are slices (ptr + len) into the gateway
 * buffer, still in their JSON-escaped form (\" \n \uXXXX ...). They are only
 * valid during the callback - copy what you need to keep. Callbacks run on the
 * gateway thread: start a thread for slow work. The REST functions are
 * thread-safe (calls recycle a small pool of libcurl handles, so connections are
 * kept alive between requests).
 */
#ifndef CAINEASM_H
#define CAINEASM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- gateway intents (https://docs.discord.com/developers/events/gateway) ---- */
#define CASM_INTENT_GUILDS                  (1UL << 0)
#define CASM_INTENT_GUILD_MEMBERS           (1UL << 1)   /* privileged */
#define CASM_INTENT_GUILD_PRESENCES         (1UL << 8)   /* privileged */
#define CASM_INTENT_GUILD_MESSAGES          (1UL << 9)
#define CASM_INTENT_GUILD_MESSAGE_REACTIONS (1UL << 10)
#define CASM_INTENT_DIRECT_MESSAGES         (1UL << 12)
#define CASM_INTENT_MESSAGE_CONTENT         (1UL << 15)  /* privileged */
/* guilds + guild/DM messages + message content */
#define CASM_INTENTS_DEFAULT (CASM_INTENT_GUILDS | CASM_INTENT_GUILD_MESSAGES | \
                              CASM_INTENT_DIRECT_MESSAGES | CASM_INTENT_MESSAGE_CONTENT)

typedef struct casm_str {
    const char *ptr;          /* NULL when the field is absent / null */
    size_t      len;
} casm_str;

/* MESSAGE_CREATE, parsed. All casm_str are JSON-escaped slices. */
typedef struct casm_message {
    casm_str id;
    casm_str channel_id;
    casm_str guild_id;        /* ptr == NULL in DMs */
    casm_str author_id;
    casm_str author_name;     /* author.username */
    casm_str nick;            /* member.nick (ptr == NULL when none) */
    casm_str content;
    casm_str attachments;     /* JSON array text (ptr == NULL when absent) */
    casm_str mentions;        /* JSON array text of user objects */
    casm_str ref_author_id;   /* referenced_message.author.id when it is a reply */
    casm_str raw;             /* the whole "d" object, parse more with any JSON scanner */
    long     author_is_bot;
    long     mention_everyone;
} casm_message;

typedef void (*casm_message_cb)(const casm_message *msg, void *user);

/* Every dispatch event (READY, RESUMED, MESSAGE_CREATE, GUILD_CREATE, ...):
 * `type` is the event name, `data` the raw JSON of its "d" object. */
typedef void (*casm_event_cb)(const char *type, size_t type_len,
                              const char *data, size_t data_len, void *user);

/* INTERACTION_CREATE, parsed (slash commands, buttons, ...). Same slice rules as
 * casm_message. user_id/user_name come from member.user in servers, user in DMs.
 * To keep one after the callback returns, use casm_interaction_keep. */
typedef struct casm_interaction {
    casm_str id;
    casm_str application_id;
    casm_str token;           /* valid 15 minutes */
    casm_str guild_id;        /* ptr == NULL in DMs */
    casm_str channel_id;
    casm_str user_id;
    casm_str user_name;
    casm_str command_name;    /* data.name (application commands) */
    casm_str command_id;      /* data.id */
    casm_str custom_id;       /* data.custom_id (buttons, selects, modals) */
    casm_str options;         /* data.options, JSON array text (ptr == NULL when none) */
    casm_str raw;             /* the whole "d" object */
    long     type;            /* 1 PING, 2 APPLICATION_COMMAND, 3 MESSAGE_COMPONENT,
                                 4 AUTOCOMPLETE, 5 MODAL_SUBMIT */
    long     command_type;    /* data.type: 1 chat input, 2 user, 3 message (0 = none) */
} casm_interaction;

typedef void (*casm_interaction_cb)(const casm_interaction *i, void *user);

/* ---- setup ---- */
/* Call once. Returns 0, or -1 on an empty token / libcurl failure. */
int  casm_init(const char *token, unsigned long intents);
/* Optional overrides (call before casm_run; the strings are copied). */
void casm_set_api_base(const char *url);        /* default https://discord.com/api/v10 */
void casm_set_gateway_url(const char *url);     /* default wss://gateway.discord.gg/?v=10&encoding=json */
void casm_set_user_agent(const char *ua);       /* must look like "DiscordBot (url, version)" */
void casm_set_ca_file(const char *path);        /* custom CA bundle (tests, odd systems) */
void casm_set_quiet(int quiet);                 /* 1 = no log lines on stderr */

void casm_on_message(casm_message_cb cb, void *user);
void casm_on_event(casm_event_cb cb, void *user);
/* Runs on the gateway thread. Discord wants the FIRST response within 3 seconds:
 * answer (casm_respond) or casm_defer right away, do slow work afterwards. */
void casm_on_interaction(casm_interaction_cb cb, void *user);

/* Blocks. 0 = stopped by casm_stop, 1 = fatal (bad token / intents not enabled),
 * -1 = casm_init was not called. Reconnects and resumes by itself. */
int  casm_run(void);
void casm_stop(void);                           /* async-signal-safe */
const char *casm_bot_id(void);                  /* NULL until READY */
const char *casm_app_id(void);                  /* application id, NULL until READY */

/* Frees the pooled REST connections. Optional: call after casm_run() returned. */
void casm_cleanup(void);

/* ---- message helpers ---- */
/* Decodes JSON escapes (\" \\ \n \uXXXX, surrogate pairs ...) into UTF-8.
 * Returns the decoded length (snprintf style, even if dst was too small);
 * writes at most cap-1 bytes and NUL terminates when cap > 0 (never cuts a
 * UTF-8 character in half). dst may be NULL with cap 0 to just measure.
 * The result is never longer than len, so a (len + 1)-byte buffer always fits.
 * Malformed escapes are copied unchanged, lone surrogates become U+FFFD. */
size_t casm_unescape(const char *src, size_t len, char *dst, size_t cap);

/* 1 when the message mentions that user id / the bot itself. */
int casm_mentions_user(const casm_message *m, const char *user_id);
int casm_mentions_me(const casm_message *m);
/* 1 when the message is a reply to one of the bot's own messages. */
int casm_is_reply_to_me(const casm_message *m);

/* 1 when content starts with `prefix` (ASCII case-insensitive) followed by the
 * end of the text or whitespace. `rest` (may be NULL) gets the remaining text,
 * trimmed. Example: prefix "caine" on "Caine halo" -> rest = "halo". */
int casm_match_prefix(const casm_str *content, const char *prefix, casm_str *rest);

/* Splits the first whitespace-delimited word off `text`. Returns 1 when there
 * was one. `rest` (may be NULL, may alias `text`) gets the remainder, trimmed. */
int casm_next_word(const casm_str *text, casm_str *word, casm_str *rest);

/* ---- REST ---- */
/* All return the HTTP status (2xx = ok), 0 when the transfer failed, -1 for
 * invalid arguments. ids must be 1-20 digits. A 429 is retried once. */

/* text is raw UTF-8 (escaped for you). One message, <= 2000 characters.
 * reply_to may be NULL. Mentions are limited to users (no @everyone/@role). */
long casm_send(const char *channel_id, const char *text, size_t len, const char *reply_to);
/* Same, but splits long text into 1900-byte parts; only the first replies. */
long casm_send_long(const char *channel_id, const char *text, size_t len, const char *reply_to);
long casm_edit(const char *channel_id, const char *message_id, const char *text, size_t len);
long casm_delete(const char *channel_id, const char *message_id);
/* emoji must already be URL-encoded: "%F0%9F%91%8D", or "name:id" for custom */
long casm_react(const char *channel_id, const char *message_id, const char *emoji);
long casm_typing(const char *channel_id);

/* Any endpoint. method: 0 GET, 1 POST, 2 PUT, 3 PATCH, 4 DELETE.
 * path starts with "/" and is relative to the API base. If resp != NULL the
 * response body (NUL terminated) is returned there; release it with casm_free. */
long casm_request(int method, const char *path, const char *body, size_t body_len,
                  char **resp, size_t *resp_len);
void casm_free(void *p);

/* ---- slash commands / interactions ----
 * Return the HTTP status (204/200 = ok), 0 on transport failure, -1 for invalid
 * arguments (missing id/token, odd characters, empty text). text is raw UTF-8
 * (escaped for you), at most 2000 characters. flags: 0, or CASM_MSG_EPHEMERAL.
 * Mentions are limited to users. */
#define CASM_MSG_EPHEMERAL 64L

/* First response: a message (callback type 4). 204 on success. */
long casm_respond(const casm_interaction *i, const char *text, size_t len, long flags);
/* First response: "thinking..." (callback type 5), for answers that take longer than 3 s.
 * With flags = CASM_MSG_EPHEMERAL the later message is ephemeral. 204 on success. */
long casm_defer(const casm_interaction *i, long flags);
/* Any callback type (1..99) with raw JSON `data` (embeds, components, modals, autocomplete
 * choices...). data_json may be NULL. 204 on success. */
long casm_interaction_response(const casm_interaction *i, long type,
                               const char *data_json, size_t data_len);
/* After the first response (valid 15 minutes): extra message / edit / delete the first one. */
long casm_followup(const casm_interaction *i, const char *text, size_t len, long flags);
long casm_edit_response(const casm_interaction *i, const char *text, size_t len);
long casm_delete_response(const casm_interaction *i);

/* Register commands (bulk overwrite: the JSON array replaces all existing ones).
 * Needs READY first (the application id). 200 on success. Guild commands update at once,
 * global ones can take a while to show up. */
long casm_register_commands(const char *json_array, size_t len);
long casm_register_guild_commands(const char *guild_id, const char *json_array, size_t len);

/* Command options. Returns the JSON type of the value: 's' string (JSON-escaped slice,
 * use casm_unescape), 'd' number (digits, e.g. strtol), 'b' bool ("true"/"false");
 * 0 when absent. value may be NULL. */
int casm_option_in(const casm_str *options, const char *name, casm_str *value);
int casm_option(const casm_interaction *i, const char *name, casm_str *value);
/* First subcommand (returns 1) or subcommand group (returns 2) in an options array:
 * its name and its own options (ptr NULL when none). 0 when there is none. */
int casm_subcommand(const casm_str *options, casm_str *name, casm_str *sub_options);

/* Deep copy that outlives the callback (hand it to a worker thread after casm_defer).
 * Release with casm_interaction_release. NULL on failure. */
casm_interaction *casm_interaction_keep(const casm_interaction *i);
void casm_interaction_release(casm_interaction *i);

#ifdef __cplusplus
}
#endif
#endif
