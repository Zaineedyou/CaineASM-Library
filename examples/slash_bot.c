/* Slash command bot: registers /ping and /echo on startup, answers them.
 *   DISCORD_TOKEN=... [GUILD_ID=123...] ./build/slash_bot
 * With GUILD_ID the commands are registered for that server (shows up at once),
 * without it they are global (can take a while to appear). No intents needed. */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include "caineasm.h"

static const char *COMMANDS =
    "[{\"name\":\"ping\",\"description\":\"Pong\",\"type\":1},"
    "{\"name\":\"echo\",\"description\":\"Ulangi teks (jawaban tertunda)\",\"type\":1,"
    "\"options\":[{\"name\":\"text\",\"description\":\"Teksnya\",\"type\":3,\"required\":true}]}]";

static void on_signal(int sig) { (void)sig; casm_stop(); }

/* slow work runs on its own thread with a kept copy of the interaction */
static void *slow_echo(void *arg) {
    casm_interaction *k = arg;
    casm_str v; char text[512];
    size_t n = 0;
    if (casm_option(k, "text", &v) == 's') n = casm_unescape(v.ptr, v.len, text, sizeof text);
    sleep(1);                                       /* pretend this is an API call */
    if (n >= sizeof text) n = sizeof text - 1;      /* unescape reports the full length */
    if (n == 0) casm_edit_response(k, "(kosong)", 8);
    else casm_edit_response(k, text, n);            /* replaces the "thinking..." message */
    casm_interaction_release(k);
    return NULL;
}

static void on_interaction(const casm_interaction *i, void *user) {
    (void)user;
    if (i->type != 2) return;                       /* application commands only */
    if (i->command_name.len == 4 && !memcmp(i->command_name.ptr, "ping", 4)) {
        casm_respond(i, "pong", 4, 0);              /* first response within 3 seconds */
    } else if (i->command_name.len == 4 && !memcmp(i->command_name.ptr, "echo", 4)) {
        if (casm_defer(i, CASM_MSG_EPHEMERAL) != 204) return;
        casm_interaction *k = casm_interaction_keep(i);
        pthread_t t;
        if (k && pthread_create(&t, NULL, slow_echo, k) == 0) pthread_detach(t);
        else casm_interaction_release(k);
    }
}

static void on_event(const char *type, size_t tl, const char *d, size_t dl, void *user) {
    (void)d; (void)dl; (void)user;
    if (tl != 5 || memcmp(type, "READY", 5) != 0) return;       /* application id is known now */
    const char *guild = getenv("GUILD_ID");
    long r = (guild && *guild) ? casm_register_guild_commands(guild, COMMANDS, strlen(COMMANDS))
                               : casm_register_commands(COMMANDS, strlen(COMMANDS));
    fprintf(stderr, "register commands: HTTP %ld\n", r);
}

int main(void) {
    const char *token = getenv("DISCORD_TOKEN");
    if (!token || !*token) { fprintf(stderr, "set DISCORD_TOKEN\n"); return 1; }
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    if (casm_init(token, CASM_INTENT_GUILDS) != 0) return 1;
    casm_on_event(on_event, NULL);
    casm_on_interaction(on_interaction, NULL);
    int r = casm_run();
    casm_cleanup();
    return r;
}
