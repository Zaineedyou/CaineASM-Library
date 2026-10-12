/* End-to-end test client for libcaineasm. Modes (argv[1]):
 *   main  <port> <cafile>   full scripted session against tests/mock_discord.py
 *   fatal <port> <cafile>   gateway answers with close code 4004 -> casm_run() == 1
 *   threads <port> <cafile>  8 threads x 10 casm_send in parallel (REST only)
 *   misc                    argument checks that need no network
 * Everything the harness verifies is printed on stdout as "KEY value" lines. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include "caineasm.h"

static void pr(const char *k, casm_str s) {
    if (!s.ptr) printf(" %s=<null>", k); else printf(" %s=%.*s", k, (int)s.len, s.ptr);
}

static int starts(const casm_message *m, const char *cmd) {
    size_t n = strlen(cmd);
    return m->content.ptr && m->content.len >= n && memcmp(m->content.ptr, cmd, n) == 0;
}

static void on_event(const char *t, size_t tl, const char *d, size_t dl, void *u) {
    (void)u; (void)d;
    printf("EVT %.*s %zu\n", (int)tl, t, dl);
}

static char *cstr(casm_str s) { char *p = malloc(s.len + 1); memcpy(p, s.ptr, s.len); p[s.len] = 0; return p; }

static void on_message(const casm_message *m, void *u) {
    (void)u;
    printf("MSG");
    pr("id", m->id); pr("chan", m->channel_id); pr("guild", m->guild_id); pr("aid", m->author_id);
    pr("name", m->author_name); pr("nick", m->nick); pr("content", m->content);
    pr("attach", m->attachments); pr("ment", m->mentions); pr("refaid", m->ref_author_id);
    printf(" bot=%ld every=%ld raw=%zu botid=%s\n", m->author_is_bot, m->mention_everyone, m->raw.len,
           casm_bot_id() ? casm_bot_id() : "<null>");
    fflush(stdout);
    if (!m->channel_id.ptr || !m->id.ptr) return;
    char *chan = cstr(m->channel_id), *id = cstr(m->id);
    if (starts(m, "!ping")) {
        const char *t = "pong \"q\" \\ back\nline2 \xF0\x9F\x98\x80 \xC3\xA9";
        printf("RET send %ld\n", casm_send(chan, t, strlen(t), id));
    } else if (starts(m, "!typing")) {
        printf("RET typing %ld\n", casm_typing(chan));
    } else if (starts(m, "!edit")) {
        printf("RET edit %ld\n", casm_edit(chan, "5000", "edited \"x\"", 10));
    } else if (starts(m, "!del")) {
        printf("RET del %ld\n", casm_delete(chan, "5000"));
    } else if (starts(m, "!react")) {
        printf("RET react %ld\n", casm_react(chan, id, "%F0%9F%91%8D"));
    } else if (starts(m, "!long")) {
        char *buf = malloc(6000); size_t n = 0;
        for (int i = 0; i < 100; i++)
            n += (size_t)sprintf(buf + n, "line %03d aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", i);
        n--;                                    /* drop the final newline */
        printf("RET long %ld len=%zu\n", casm_send_long(chan, buf, n, id), n);
        free(buf);
    } else if (starts(m, "!req")) {
        char *resp = NULL; size_t rl = 0;
        long s = casm_request(0, "/users/@me", NULL, 0, &resp, &rl);
        printf("RET req %ld len=%zu body=%s\n", s, rl, resp ? resp : "<null>");
        casm_free(resp);
        s = casm_request(1, "/channels/1/messages", "{\"content\":\"raw\"}", 17, NULL, NULL);
        printf("RET rawpost %ld\n", s);
    } else if (starts(m, "!bad")) {
        printf("RET bad1 %ld\n", casm_send("abc/../x", "t", 1, NULL));
        printf("RET bad2 %ld\n", casm_send(chan, NULL, 5, NULL));
        printf("RET bad3 %ld\n", casm_send(chan, "t", 1, "12x"));
        printf("RET bad4 %ld\n", casm_react(chan, id, "a/b"));
        printf("RET bad5 %ld\n", casm_react(chan, id, ""));
        printf("RET bad6 %ld\n", casm_send_long(chan, "", 0, NULL));
        printf("RET bad7 %ld\n", casm_request(0, "noslash", NULL, 0, NULL, NULL));
        printf("RET bad8 %ld\n", casm_delete(chan, "123456789012345678901"));
        printf("RET bad9 %ld\n", casm_edit(chan, NULL, "x", 1));
    } else if (starts(m, "!429")) {
        printf("RET 429 %ld\n", casm_send(chan, "429TEST", 7, NULL));
    } else if (starts(m, "!done")) {
        casm_stop();
    }
    fflush(stdout);
    free(chan); free(id);
}

static volatile long thr_ok, thr_bad;
static void *thr(void *arg) {
    char txt[64];
    for (int i = 0; i < 10; i++) {
        int n = snprintf(txt, sizeof txt, "thread %ld msg %d \"q\"", (long)(size_t)arg, i);
        long r = casm_send("1001", txt, (size_t)n, NULL);
        if (r == 200) __sync_fetch_and_add(&thr_ok, 1); else __sync_fetch_and_add(&thr_bad, 1);
    }
    return NULL;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc >= 2 && strcmp(argv[1], "misc") == 0) {
        printf("MISC init_null %d\n", casm_init(NULL, 1));
        printf("MISC init_empty %d\n", casm_init("", 1));
        printf("MISC run_noinit %d\n", casm_run());
        printf("MISC botid %s\n", casm_bot_id() ? "set" : "null");
        return 0;
    }
    if (argc < 4) { fprintf(stderr, "usage: %s main|fatal|misc port cafile\n", argv[0]); return 2; }
    char api[128], gw[128];
    snprintf(api, sizeof api, "https://localhost:%s/api/v10", argv[2]);
    snprintf(gw, sizeof gw, "wss://localhost:%s/?v=10&encoding=json", argv[2]);
    casm_set_api_base(api);
    casm_set_gateway_url(gw);
    casm_set_ca_file(argv[3]);
    if (casm_init("tok.en", CASM_INTENTS_DEFAULT) != 0) { puts("INIT failed"); return 1; }
    if (strcmp(argv[1], "threads") == 0) {      /* REST only, 8 threads x 10 messages */
        pthread_t t[8];
        for (long i = 0; i < 8; i++) pthread_create(&t[i], NULL, thr, (void *)(size_t)i);
        for (int i = 0; i < 8; i++) pthread_join(t[i], NULL);
        printf("THREADS ok=%ld bad=%ld\n", thr_ok, thr_bad);
        return 0;
    }
    casm_on_event(on_event, NULL);
    casm_on_message(on_message, NULL);
    int r = casm_run();
    printf("RUN %d\n", r);
    return 0;
}
