#define _GNU_SOURCE
/* Minimal bot: replies "pong" to "!ping" and says hi when mentioned.
 *   DISCORD_TOKEN=... ./build/ping_bot
 * Enable "Message Content Intent" for the bot in the Discord Developer Portal. */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "caineasm.h"

static void on_signal(int sig) { (void)sig; casm_stop(); }

/* slices are not NUL terminated: copy before using them as C strings */
static void copy(char *dst, size_t cap, casm_str s) {
    size_t n = s.len < cap - 1 ? s.len : cap - 1;
    if (s.ptr) memcpy(dst, s.ptr, n); else n = 0;
    dst[n] = 0;
}

static void on_message(const casm_message *m, void *user) {
    (void)user;
    if (m->author_is_bot || !m->channel_id.ptr) return;       /* never answer bots (incl. ourselves) */

    char chan[32], id[32];
    copy(chan, sizeof chan, m->channel_id);
    copy(id, sizeof id, m->id);

    if (m->content.len == 5 && memcmp(m->content.ptr, "!ping", 5) == 0) {
        casm_send(chan, "pong", 4, id);
    } else if (m->mentions.ptr && casm_bot_id() && memmem(m->mentions.ptr, m->mentions.len, casm_bot_id(), strlen(casm_bot_id()))) {
        casm_typing(chan);
        casm_send(chan, "Hai! Coba ketik !ping", 21, id);
    }
}

int main(void) {
    const char *token = getenv("DISCORD_TOKEN");
    if (!token || !*token) { fprintf(stderr, "set DISCORD_TOKEN\n"); return 1; }
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    if (casm_init(token, CASM_INTENTS_DEFAULT) != 0) { fprintf(stderr, "init failed\n"); return 1; }
    casm_on_message(on_message, NULL);
    int r = casm_run();
    return r == 1 ? 2 : 0;       /* 1 = fatal: bad token or intents not enabled */
}
