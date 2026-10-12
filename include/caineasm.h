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
 * thread-safe (each call uses its own libcurl handle).
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

/* Blocks. 0 = stopped by casm_stop, 1 = fatal (bad token / intents not enabled),
 * -1 = casm_init was not called. Reconnects and resumes by itself. */
int  casm_run(void);
void casm_stop(void);                           /* async-signal-safe */
const char *casm_bot_id(void);                  /* NULL until READY */

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

#ifdef __cplusplus
}
#endif
#endif
