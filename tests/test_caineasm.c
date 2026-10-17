/* End-to-end test client for libcaineasm. Modes (argv[1]):
 *   main  <port> <cafile>   full scripted session against tests/mock_discord.py
 *   fatal <port> <cafile>   gateway answers with close code 4004 -> casm_run() == 1
 *   threads <port> <cafile>  8 threads x 10 casm_send in parallel (REST only)
 *   reuse <port> <cafile>    12 sequential casm_send calls (connection reuse)
 *   misc                    argument checks that need no network
 *   unit                    helper functions (unescape, prefix, words, mentions)
 *   inter <port> <cafile>   slash commands / interactions against the mock
 *   crash | crashoff | crashstack   deliberate crashes (no network) for casm_set_crash_handler
 *   unescape                fuzz tool: hex lines on stdin -> decoded hex on stdout
 * Everything the harness verifies is printed on stdout as "KEY value" lines. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <limits.h>
#include <math.h>
#include "caineasm.h"

static void pr(const char *k, casm_str s) {
    if (!s.ptr) printf(" %s=<null>", k); else printf(" %s=%.*s", k, (int)s.len, s.ptr);
}

static int starts(const casm_message *m, const char *cmd) {
    size_t n = strlen(cmd);
    return m->content.ptr && m->content.len >= n && memcmp(m->content.ptr, cmd, n) == 0;
}

static int starts_str(casm_str s, const char *x) { size_t n = strlen(x); return s.ptr && s.len == n && memcmp(s.ptr, x, n) == 0; }

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
    {
        casm_str rest = {0, 0};
        int pre = casm_match_prefix(&m->content, "!PING", &rest);
        printf(" mme=%d rtm=%d pre=%d", casm_mentions_me(m), casm_is_reply_to_me(m), pre);
        pr("prerest", rest);
    }
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
        printf("RET pres %d\n", casm_set_presence("idle", CASM_ACTIVITY_CUSTOM, "custom text \xC3\xA9", NULL));
        printf("RET presbad1 %d\n", casm_set_presence("banana", 0, "x", NULL));
        printf("RET presbad2 %d\n", casm_set_presence("online", 9, "x", NULL));
        printf("RET presbad3 %d\n", casm_set_presence("online", 0, NULL, NULL));
        printf("RET presbad4 %d\n", casm_set_presence("online", -2, "x", NULL));
        printf("RET edit %ld\n", casm_edit(chan, "5000", "edited \"x\"", 10));
    } else if (starts(m, "!del")) {
        printf("RET del %ld\n", casm_delete(chan, "5000"));
    } else if (starts(m, "!react")) {
        printf("RET pres2 %d\n", casm_set_presence(NULL, CASM_ACTIVITY_STREAMING, "stream", "https://t.tv/x"));
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


static int u_pass, u_fail;
#define UCHECK(c) do { if (c) u_pass++; else { u_fail++; printf("UNIT FAIL line %d: %s\n", __LINE__, #c); } } while (0)

static int unesc_is(const char *src, const char *want) {
    char buf[256];
    size_t n = casm_unescape(src, strlen(src), buf, sizeof buf);
    return n == strlen(want) && strcmp(buf, want) == 0;
}

static casm_str S(const char *s) { casm_str r = { s, strlen(s) }; return r; }
static int eq(casm_str a, const char *b) { return a.ptr && a.len == strlen(b) && memcmp(a.ptr, b, a.len) == 0; }

static void unit_tests(void) {
    char buf[64];
    UCHECK(unesc_is("", ""));
    UCHECK(unesc_is("plain", "plain"));
    UCHECK(unesc_is("a\\\"b\\\\c\\/d", "a\"b\\c/d"));
    UCHECK(unesc_is("l1\\nl2\\tx\\r\\b\\f", "l1\nl2\tx\r\b\f"));
    UCHECK(unesc_is("\\u00e9", "\xC3\xA9"));
    UCHECK(unesc_is("\\u20AC", "\xE2\x82\xAC"));
    UCHECK(unesc_is("\\ud83d\\ude00", "\xF0\x9F\x98\x80"));
    UCHECK(unesc_is("\\ud83d x", "\\ud83d x") || unesc_is("\\ud83d x", "\xEF\xBF\xBD x"));
    UCHECK(unesc_is("\\ude00", "\xEF\xBF\xBD"));
    UCHECK(unesc_is("\\ud83d\\u0041", "\xEF\xBF\xBD" "A"));
    UCHECK(unesc_is("raw \xC3\xA9 \xF0\x9F\x98\x80", "raw \xC3\xA9 \xF0\x9F\x98\x80"));
    UCHECK(unesc_is("bad \\q x", "bad \\q x"));
    UCHECK(unesc_is("bad \\u12", "bad \\u12"));
    UCHECK(unesc_is("end\\", "end\\"));
    /* snprintf style return + truncation */
    UCHECK(casm_unescape("hello", 5, NULL, 0) == 5);
    UCHECK(casm_unescape("hello", 5, buf, 4) == 5 && strcmp(buf, "hel") == 0);
    UCHECK(casm_unescape("hello", 5, buf, 1) == 5 && buf[0] == 0);
    UCHECK(casm_unescape("hello", 5, buf, 6) == 5 && strcmp(buf, "hello") == 0);
    UCHECK(casm_unescape("a\\u00e9", 7, buf, 3) == 3 && strcmp(buf, "a") == 0);   /* é does not fit in 2 bytes */
    UCHECK(casm_unescape("a\\u00e9", 7, buf, 4) == 3 && strcmp(buf, "a\xC3\xA9") == 0);
    UCHECK(casm_unescape("\xC3\xA9", 2, buf, 2) == 2 && buf[0] == 0);             /* raw sequence stays whole */
    /* respects len, not the terminator */
    UCHECK(casm_unescape("abcdef", 3, buf, sizeof buf) == 3 && strcmp(buf, "abc") == 0);

    /* prefix */
    casm_str rest = {0, 0}, c;
    c = S("Caine halo");   UCHECK(casm_match_prefix(&c, "caine", &rest) == 1 && eq(rest, "halo"));
    c = S("caine");        UCHECK(casm_match_prefix(&c, "CAINE", &rest) == 1 && rest.len == 0);
    c = S("cainex halo");  UCHECK(casm_match_prefix(&c, "caine", &rest) == 0);
    c = S("ca");           UCHECK(casm_match_prefix(&c, "caine", &rest) == 0);
    c = S("caine   a b  ");UCHECK(casm_match_prefix(&c, "caine", &rest) == 1 && eq(rest, "a b"));
    c = S("caine\\nhi");   UCHECK(casm_match_prefix(&c, "caine", &rest) == 1 && eq(rest, "hi"));
    c = S("caine\thi");   UCHECK(casm_match_prefix(&c, "caine", NULL) == 1);
    c = S("!ping x");      UCHECK(casm_match_prefix(&c, "!ping", &rest) == 1 && eq(rest, "x"));
    c = S("");             UCHECK(casm_match_prefix(&c, "a", &rest) == 0);
    { casm_str n = {0, 0}; UCHECK(casm_match_prefix(&n, "a", &rest) == 0); UCHECK(casm_match_prefix(NULL, "a", &rest) == 0); }

    /* next_word */
    casm_str w, t = S("  one  two three ");
    UCHECK(casm_next_word(&t, &w, &rest) == 1 && eq(w, "one") && eq(rest, "two three"));
    t = rest;
    UCHECK(casm_next_word(&t, &w, &t) == 1 && eq(w, "two") && eq(t, "three"));
    UCHECK(casm_next_word(&t, &w, &t) == 1 && eq(w, "three") && t.len == 0);
    UCHECK(casm_next_word(&t, &w, &t) == 0);
    t = S("   ");           UCHECK(casm_next_word(&t, &w, &rest) == 0);
    t = S("a\\nb");         UCHECK(casm_next_word(&t, &w, &rest) == 1 && eq(w, "a") && eq(rest, "b"));

    /* mentions */
    casm_message m;
    memset(&m, 0, sizeof m);
    m.mentions = S("[{\"id\":\"900\",\"username\":\"x\"},{\"id\":\"1234\"}]");
    UCHECK(casm_mentions_user(&m, "900") == 1);
    UCHECK(casm_mentions_user(&m, "1234") == 1);
    UCHECK(casm_mentions_user(&m, "90") == 0);
    UCHECK(casm_mentions_user(&m, "9000") == 0);
    UCHECK(casm_mentions_user(&m, "") == 0);
    UCHECK(casm_mentions_user(&m, NULL) == 0);
    m.mentions = S("[]");  UCHECK(casm_mentions_user(&m, "900") == 0);
    m.mentions.ptr = NULL; m.mentions.len = 0; UCHECK(casm_mentions_user(&m, "900") == 0);
    UCHECK(casm_mentions_me(&m) == 0);                 /* no READY yet -> no bot id */
    UCHECK(casm_is_reply_to_me(&m) == 0);

    printf("UNIT pass=%d fail=%d\n", u_pass, u_fail);
}

static int hexv(int c) { return c <= '9' ? c - '0' : (c | 32) - 'a' + 10; }

/* stdin: one hex-encoded JSON-escaped string per line. For each line prints
 * "full <retlen> <hex>" and for caps 1..9 "cap <cap> <retlen> <hex>". */
static void unescape_stdin(void) {
    char line[8192];
    while (fgets(line, sizeof line, stdin)) {
        size_t hl = strcspn(line, "\r\n"), n = hl / 2;
        char *src = malloc(n + 1), *dst = malloc(n + 2);
        for (size_t i = 0; i < n; i++) src[i] = (char)(hexv(line[2*i]) * 16 + hexv(line[2*i+1]));
        size_t r = casm_unescape(src, n, dst, n + 1);
        printf("full %zu ", r);
        for (size_t i = 0; i < r && i < n; i++) printf("%02x", (unsigned char)dst[i]);
        printf("\n");
        for (size_t cap = 1; cap <= 9; cap++) {
            char small[16]; memset(small, 0x7f, sizeof small);
            r = casm_unescape(src, n, small, cap);
            size_t l = strlen(small);
            printf("cap %zu %zu ", cap, r);
            for (size_t i = 0; i < l; i++) printf("%02x", (unsigned char)small[i]);
            printf("\n");
        }
        free(src); free(dst);
    }
}

/* ---------------- interactions ---------------- */
static pthread_t inter_thr;
static int inter_thr_started;

static void *inter_worker(void *arg) {
    casm_interaction *k = arg;
    struct timespec ts = { 0, 300 * 1000000L };
    nanosleep(&ts, NULL);                   /* the gateway buffer is long gone by now */
    printf("KEEP");
    pr("id", k->id); pr("app", k->application_id); pr("tok", k->token); pr("uname", k->user_name);
    pr("cmd", k->command_name); pr("raw", (casm_str){ k->raw.ptr, k->raw.len > 20 ? 20 : k->raw.len });
    printf("\n");
    printf("RET followup %ld\n", casm_followup(k, "later \"q\" \xC3\xA9", 12, CASM_MSG_EPHEMERAL));
    printf("RET editresp %ld\n", casm_edit_response(k, "edited", 6));
    printf("RET delresp %ld\n", casm_delete_response(k));
    fflush(stdout);
    casm_interaction_release(k);
    return NULL;
}


static void panel_test(const casm_interaction *i) {
    casm_embed *e = casm_embed_new();
    casm_embed_title(e, "Judul \"q\""); casm_embed_description(e, "baris1\nbaris2 \xC3\xA9");
    casm_embed_url(e, "https://x/e"); casm_embed_timestamp(e, "2026-10-13T11:00:00Z");
    casm_embed_footer(e, "foot"); casm_embed_author(e, "auth");
    casm_embed_image(e, "https://x/i.png"); casm_embed_thumbnail(e, "https://x/t.png");
    casm_embed_color(e, 0x5865F2);
    casm_embed_field(e, "f1", "v1", 1); casm_embed_field(e, "f2", "v2", 0);
    casm_row *r1 = casm_row_new();
    casm_row_button(r1, CASM_BUTTON_PRIMARY, "Klik", "btn_ok", 0);
    casm_row_button(r1, CASM_BUTTON_DANGER, "Hapus \"x\"", "btn_del", 1);
    casm_row_button(r1, CASM_BUTTON_LINK, "Web", "https://example.com/a?b=1&c=2", 0);
    casm_select *s = casm_select_new("sel1", "Pilih", 1, 2);
    casm_select_option(s, "A", "a", "desc A", 1);
    casm_select_option(s, "B", "b", NULL, 0);
    casm_row *r2 = casm_row_new();
    casm_row_select(r2, s);
    casm_reply *rp = casm_reply_new();
    casm_reply_content(rp, "hai \"dunia\"", 11);
    casm_reply_embed(rp, e); casm_reply_row(rp, r1); casm_reply_row(rp, r2);
    casm_reply *rp2 = casm_reply_new();
    casm_reply_content(rp2, "only text", 9); casm_reply_flags(rp2, CASM_MSG_EPHEMERAL);
    printf("RET panel %ld\n", casm_respond_reply(i, rp));
    printf("RET sendreply %ld\n", casm_send_reply("1001", rp, "2001"));
    printf("RET sendreply2 %ld\n", casm_send_reply("1001", rp, NULL));
    printf("RET editmsg %ld\n", casm_edit_message("1001", "5000", rp));
    printf("RET followreply %ld\n", casm_followup_reply(i, rp2));
    printf("RET editreply %ld\n", casm_edit_response_reply(i, rp2));
    printf("RET badr1 %ld\n", casm_send_reply("abc", rp, NULL));
    printf("RET badr2 %ld\n", casm_respond_reply(i, NULL));
    printf("RET badr3 %ld\n", casm_edit_message("1001", NULL, rp));
    printf("RET bade1 %d\n", casm_embed_title(NULL, "x"));
    printf("RET bade2 %d\n", casm_row_button(r1, 9, "a", "b", 0));
    printf("RET bade3 %d\n", casm_embed_color(e, 0x1000000));
    printf("RET bade4 %d\n", casm_embed_field(e, "n", NULL, 0));
    printf("RET bade5 %d\n", casm_reply_embed(rp, NULL));
    printf("RET bade6 %d\n", casm_select_new(NULL, NULL, -1, 0) == NULL);
    casm_builder_free(e); casm_builder_free(r1); casm_builder_free(s); casm_builder_free(r2);
    casm_builder_free(rp); casm_builder_free(rp2); casm_builder_free(NULL);
}

static void form_test(const casm_interaction *i) {
    casm_modal *m = casm_modal_new("mod1", "Titulo \"q\"");
    casm_modal_input(m, "name", "Nama", 0, "isi nama", 1, 50, 1);
    casm_modal_input(m, "bio", "Bio", 1, NULL, 0, 0, 0);
    printf("RET showmodal %ld\n", casm_show_modal(i, m));
    printf("RET badmodal %ld\n", casm_show_modal(i, NULL));
    casm_builder_free(m);
}

static casm_opt *junk[32]; static int nj;
#define NEWO(t) (junk[nj++] = casm_opt_new((t), "x", "d", 0))

static unsigned char *mkdata(size_t n) {
    unsigned char *p = malloc(n);
    for (size_t k = 0; k < n; k++) p[k] = (unsigned char)(k * 7 + 3);
    if (n > 30) memcpy(p + 10, "\r\n--\r\n\r\n", 8);              /* multipart-looking bytes inside the data */
    return p;
}

static void on_update(const casm_message *m, void *u) {
    (void)u;
    printf("UPD"); pr("id", m->id); pr("chan", m->channel_id); pr("guild", m->guild_id); pr("aid", m->author_id); pr("content", m->content);
    printf("\n"); fflush(stdout);
}
static void on_delete(const casm_message_delete *e, void *u) {
    (void)u;
    printf("DEL"); pr("id", e->id); pr("chan", e->channel_id); pr("guild", e->guild_id); printf(" raw=%zu\n", e->raw.len); fflush(stdout);
}
static void on_react(const casm_reaction *e, void *u) {
    (void)u;
    char nm[64] = "";
    if (e->emoji_name.ptr) casm_unescape(e->emoji_name.ptr, e->emoji_name.len, nm, sizeof nm);
    printf("REACT"); pr("user", e->user_id); pr("chan", e->channel_id); pr("msg", e->message_id); pr("guild", e->guild_id);
    printf(" emoji=%s", nm); pr("eid", e->emoji_id); pr("mauthor", e->message_author_id);
    printf(" added=%ld burst=%ld raw=%zu\n", e->added, e->burst, e->raw.len); fflush(stdout);
}
static void on_member(const casm_member_event *e, void *u) {
    (void)u;
    printf("MEMBER"); pr("guild", e->guild_id); pr("user", e->user_id); pr("name", e->user_name); pr("nick", e->nick);
    printf(" joined=%ld raw=%zu\n", e->joined, e->raw.len); fflush(stdout);
}
static void on_log(const char *line, size_t len, void *u) {
    (void)u;
    printf("LOG %.*s\n", (int)len, line); fflush(stdout);
}

static void on_interaction(const casm_interaction *i, void *u) {
    (void)u;
    printf("INT");
    pr("id", i->id); pr("app", i->application_id); pr("tok", i->token); pr("guild", i->guild_id);
    pr("chan", i->channel_id); pr("uid", i->user_id); pr("uname", i->user_name);
    pr("cmd", i->command_name); pr("cid", i->command_id); pr("custom", i->custom_id); pr("opts", i->options);
    printf(" type=%ld ctype=%ld appid=%s\n", i->type, i->command_type, casm_app_id() ? casm_app_id() : "<null>");
    fflush(stdout);
    if (starts_str(i->command_name, "ping")) {
        casm_str v; char dec[64];
        int t = casm_option(i, "text", &v);
        size_t n = t == 's' ? casm_unescape(v.ptr, v.len, dec, sizeof dec) : 0;
        printf("OPT text %d %s\n", t, dec);
        t = casm_option(i, "n", &v);   printf("OPT n %d %.*s\n", t, t ? (int)v.len : 0, t ? v.ptr : "");
        t = casm_option(i, "flag", &v); printf("OPT flag %d %.*s\n", t, t ? (int)v.len : 0, t ? v.ptr : "");
        t = casm_option(i, "nope", &v); printf("OPT nope %d %d\n", t, v.ptr == NULL);
        printf("RET respond %ld\n", casm_respond(i, dec, n, CASM_MSG_EPHEMERAL));
    } else if (starts_str(i->command_name, "work")) {
        printf("RET defer %ld\n", casm_defer(i, 0));
        casm_interaction *k = casm_interaction_keep(i);
        printf("KEEPPTR %d\n", k != NULL);
        pthread_create(&inter_thr, NULL, inter_worker, k);
        inter_thr_started = 1;
    } else if (starts_str(i->command_name, "admin")) {
        casm_str name, sub, name2, sub2, who;
        int a = casm_subcommand(&i->options, &name, &sub);
        printf("SUB1 %d %.*s\n", a, (int)name.len, name.ptr);
        int b = casm_subcommand(&sub, &name2, &sub2);
        printf("SUB2 %d %.*s\n", b, (int)name2.len, name2.ptr);
        int c = casm_option_in(&sub2, "who", &who);
        printf("SUB3 %d %.*s\n", c, (int)who.len, who.ptr);
        printf("SUB4 %d\n", casm_subcommand(&sub2, &name, &sub));
        printf("RET defer2 %ld\n", casm_defer(i, CASM_MSG_EPHEMERAL));
    } else if (starts_str(i->command_name, "panel")) {
        panel_test(i);
    } else if (starts_str(i->command_name, "form")) {
        form_test(i);
    } else if (i->type == 5) {
        casm_str v, e2; int t, c;
        t = casm_modal_value(i, "name", &v);   printf("MODAL name %d %.*s\n", t, (int)v.len, v.ptr);
        t = casm_modal_value(i, "pick", &v);   printf("MODAL pick %d\n", t);
        c = casm_array_at(&v, 1, &e2);         printf("MODAL pick1 %d %.*s\n", c, (int)e2.len, e2.ptr);
        t = casm_modal_value(i, "none", &v);   printf("MODAL none %d %d\n", t, v.ptr == NULL);
        printf("RET modalresp %ld\n", casm_respond(i, "ok", 2, 0));
    } else if (i->type == 4) {
        casm_str n, v;
        int f = casm_option_focused(i, &n, &v);
        printf("FOCUS %d %.*s %.*s\n", f, (int)n.len, n.ptr, (int)v.len, v.ptr);
        const char *names[2] = { "Alpha", "Be\"ta" }, *vals[2] = { "a", "b" };
        printf("RET ac %ld\n", casm_autocomplete(i, names, vals, 2));
        printf("RET acbad1 %ld\n", casm_autocomplete(i, names, vals, 26));
        printf("RET acbad2 %ld\n", casm_autocomplete(i, NULL, NULL, 1));
    } else if (starts_str(i->custom_id, "sel1")) {
        casm_str vs, e3; int c;
        printf("SELV %d\n", casm_select_values(i, &vs));
        for (size_t k = 0; k < 3; k++) { c = casm_array_at(&vs, k, &e3); printf("SELV%zu %d %.*s\n", k, c, (int)e3.len, c ? e3.ptr : ""); }
        casm_reply *r = casm_reply_new();
        casm_reply_content(r, "updated", 7);
        printf("RET selupdate %ld\n", casm_update_reply(i, r));
        casm_builder_free(r);
    } else if (starts_str(i->custom_id, "usel")) {
        casm_str arr = {0, 0}, v = {0, 0};
        int has = casm_select_values(i, &arr);
        printf("USEL has=%d", has);
        for (size_t k = 0; k < 3; k++) {
            v.ptr = NULL; v.len = 0;
            int t = casm_array_at(&arr, k, &v);
            printf(" v%zu=%c:%.*s", k, t ? t : '0', (int)v.len, v.ptr ? v.ptr : "");
        }
        printf("\n");
        struct { const char *name, *path; } jg[] = {
            {"user", "data.resolved.users.U9.username"}, {"nick", "data.resolved.members.U9.nick"},
            {"missing", "data.resolved.users.NOPE.username"}, {"values", "data.values"}, {"resolved", "data.resolved"},
            {"ctype", "data.component_type"}, {"token", "token"}, {"nul", "data.resolved.users.U10.avatar"}, {"bad", "data..x"} };
        for (size_t k = 0; k < sizeof jg / sizeof jg[0]; k++) {
            v.ptr = NULL; v.len = 0;
            int t = casm_json_get(&i->raw, jg[k].path, &v);
            printf("JG %s %c %.*s\n", jg[k].name, t ? t : '0', t == 'o' || t == 'a' ? 0 : (int)v.len, v.ptr ? v.ptr : "");
        }
        casm_str none = {0, 0};
        printf("JG nullargs %d %d %d\n", casm_json_get(NULL, "a", &v), casm_json_get(&none, "a", &v), casm_json_get(&i->raw, NULL, &v));
        printf("JG nullout %d\n", casm_json_get(&i->raw, "token", NULL));
    } else if (i->type == 3) {
        const char *d = "{\"content\":\"updated \\\"x\\\"\"}";
        printf("RET update %ld\n", casm_interaction_response(i, 7, d, strlen(d)));
        printf("RET plainresp %ld\n", casm_interaction_response(i, 6, NULL, 0));
        printf("RET badtype %ld\n", casm_interaction_response(i, 0, NULL, 0));
    } else if (starts_str(i->command_name, "bad")) {
        printf("RET bad1 %ld\n", casm_respond(i, "x", 1, 0));
        printf("RET bad2 %ld\n", casm_respond(NULL, "x", 1, 0));
        printf("RET bad3 %ld\n", casm_defer(i, -1));
        printf("RET bad4 %ld\n", casm_respond(i, "", 0, 0));
        printf("RET bad5 %ld\n", casm_delete_response(i));
        printf("RET bad6 %ld\n", casm_register_commands("[]", 0));
        printf("RET bad7 %ld\n", casm_register_guild_commands("12x", "[]", 2));
        printf("RET bad8 %ld\n", casm_register_guild_commands(NULL, "[]", 2));
    } else if (starts_str(i->command_name, "register")) {
        const char *cmds = "[{\"name\":\"ping\",\"description\":\"Pong\",\"type\":1,\"options\":[{\"name\":\"text\",\"description\":\"t\",\"type\":3}]}]";
        printf("RET regglobal %ld\n", casm_register_commands(cmds, strlen(cmds)));
        printf("RET regguild %ld\n", casm_register_guild_commands("555", cmds, strlen(cmds)));
    } else if (starts_str(i->command_name, "build")) {
        casm_cmd *h = casm_cmd_new("hello", "Say \"hello\" \xC3\xA9");
        casm_opt *who = casm_opt_new(CASM_OPT_STRING, "who", "Who", 1);
        int rc = 0;
        rc |= casm_opt_choice(who, "Alice", "a"); rc |= casm_opt_choice(who, "Bo\"b", "b");
        casm_opt *cnt = casm_opt_new(CASM_OPT_INTEGER, "count", "How many", 0);
        rc |= casm_opt_range_int(cnt, 1, 10);
        casm_opt *rat = casm_opt_new(CASM_OPT_NUMBER, "ratio", "Ratio", 0);
        rc |= casm_opt_range_num(rat, 0.1, 99.5);
        casm_opt *q = casm_opt_new(CASM_OPT_STRING, "q", "Query", 0);
        rc |= casm_opt_length(q, 2, 50); rc |= casm_opt_autocomplete(q);
        casm_opt *lv = casm_opt_new(CASM_OPT_INTEGER, "level", "Level", 0);
        rc |= casm_opt_choice_int(lv, "Low", 1); rc |= casm_opt_choice_int(lv, "High", -5);
        casm_opt *pi = casm_opt_new(CASM_OPT_NUMBER, "pi", "Pi", 0);
        rc |= casm_opt_choice_num(pi, "Pi", 3.14159);
        casm_opt *mn = casm_opt_new(CASM_OPT_INTEGER, "min", "Min only", 0);
        rc |= casm_opt_range_int(mn, -3, LONG_MAX);
        casm_opt *mx = casm_opt_new(CASM_OPT_NUMBER, "big", "Max only", 0);
        rc |= casm_opt_range_num(mx, -INFINITY, 1e20);
        rc |= casm_cmd_permissions(h, "8"); rc |= casm_cmd_nsfw(h); rc |= casm_cmd_contexts(h, CASM_CTX_GUILD | CASM_CTX_PRIVATE_CHANNEL);
        rc |= casm_cmd_option(h, who); rc |= casm_cmd_option(h, cnt); rc |= casm_cmd_option(h, rat); rc |= casm_cmd_option(h, q);
        rc |= casm_cmd_option(h, lv); rc |= casm_cmd_option(h, pi); rc |= casm_cmd_option(h, mn); rc |= casm_cmd_option(h, mx);
        casm_cmd *adm = casm_cmd_new("admin", "Admin tools");
        casm_opt *grp = casm_opt_new(CASM_OPT_SUB_COMMAND_GROUP, "ban", "Ban tools", 0);
        casm_opt *sub = casm_opt_new(CASM_OPT_SUB_COMMAND, "user", "Ban a user", 0);
        casm_opt *usr = casm_opt_new(CASM_OPT_USER, "target", "Target", 1);
        rc |= casm_opt_add(sub, usr); rc |= casm_opt_add(grp, sub); rc |= casm_cmd_option(adm, grp);
        casm_cmd *ctx = casm_cmd_new_context("Show Info", 2);
        printf("RET bok %d\n", rc);
        casm_cmd *list[3] = { h, adm, ctx };
        printf("RET breg %ld\n", casm_register_cmds(list, 3));
        printf("RET bregguild %ld\n", casm_register_guild_cmds("555", list, 3));
        /* rule violations: nothing may reach the network */
        printf("RET b1 %d\n", casm_cmd_new("Hello", "x") == NULL);
        printf("RET b2 %d\n", casm_cmd_new("a", "") == NULL);
        printf("RET b3 %d\n", casm_cmd_new("a b", "x") == NULL);
        printf("RET b4 %d\n", casm_cmd_new(NULL, "x") == NULL);
        printf("RET b5 %d\n", casm_cmd_new("a", NULL) == NULL);
        printf("RET b6 %d\n", casm_opt_new(CASM_OPT_SUB_COMMAND, "x", "d", 1) == NULL);
        printf("RET b7 %d\n", casm_opt_new(12, "x", "d", 0) == NULL);
        printf("RET b8 %d\n", casm_opt_new(0, "x", "d", 0) == NULL);
        printf("RET b9 %d\n", casm_cmd_new_context("x", 1) == NULL);
        casm_opt *opt = casm_opt_new(CASM_OPT_STRING, "o", "d", 0);          /* optional, then a required one */
        casm_opt *req = casm_opt_new(CASM_OPT_STRING, "r", "d", 1);
        casm_cmd *c2 = casm_cmd_new("c2", "d");
        { int a1 = casm_cmd_option(c2, opt); int a2 = casm_cmd_option(c2, req); printf("RET b10 %d %d\n", a1, a2); }
        printf("RET b11 %d\n", casm_opt_choice(lv, "x", "y"));               /* string choice on an integer option */
        printf("RET b12 %d\n", casm_opt_choice_int(opt, "x", 1));
        printf("RET b13 %d\n", casm_opt_choice_int(lv, "x", 9007199254740992L));
        printf("RET b14 %d\n", casm_opt_choice_num(pi, "x", NAN));
        printf("RET b15 %d\n", casm_opt_choice_num(pi, "x", INFINITY));
        printf("RET b16 %d\n", casm_opt_autocomplete(who));                   /* has choices */
        printf("RET b17 %d\n", casm_opt_choice(q, "x", "y"));                 /* has autocomplete */
        printf("RET b18 %d\n", casm_opt_range_int(opt, 1, 2));                /* wrong type */
        printf("RET b19 %d\n", casm_opt_range_int(NEWO(CASM_OPT_INTEGER), 5, 1));
        printf("RET b20 %d\n", casm_opt_range_num(NEWO(CASM_OPT_NUMBER), 2.0, 1.0));
        printf("RET b21 %d\n", casm_opt_range_num(NEWO(CASM_OPT_NUMBER), NAN, 1.0));
        printf("RET b22 %d\n", casm_opt_length(NEWO(CASM_OPT_STRING), 0, 0));
        printf("RET b23 %d\n", casm_opt_length(NEWO(CASM_OPT_STRING), 5, 2));
        printf("RET b24 %d\n", casm_opt_length(NEWO(CASM_OPT_STRING), 0, 6001));
        printf("RET b25 %d\n", casm_opt_add(opt, req));                       /* parent is not a sub-command */
        printf("RET b26 %d\n", casm_opt_add(grp, req));                       /* a group takes sub-commands only */
        printf("RET b27 %d\n", casm_cmd_permissions(c2, "abc"));
        printf("RET b28 %d\n", casm_cmd_permissions(c2, ""));
        printf("RET b29 %d\n", casm_cmd_contexts(c2, 0));
        printf("RET b30 %d\n", casm_cmd_contexts(c2, 8));
        printf("RET b31 %d\n", casm_cmd_option(ctx, opt));                    /* context menus take no options */
        printf("RET b32 %ld %ld %ld\n", casm_register_cmds(NULL, 1), casm_register_cmds(list, 0), casm_register_cmds(list, 101));
        printf("RET b33 %ld\n", casm_register_guild_cmds("12x", list, 3));
        { casm_cmd *nl[2] = { h, NULL }; printf("RET b34 %ld\n", casm_register_cmds(nl, 2)); }
        { casm_opt *big = casm_opt_new(CASM_OPT_STRING, "big", "d", 0); int ok = 0, bad = 0; char nm[8];
          for (int k = 0; k < 27; k++) { snprintf(nm, sizeof nm, "c%d", k); (casm_opt_choice(big, nm, "v") == 0 ? ok++ : bad++); }
          printf("RET b35 %d %d\n", ok, bad); casm_builder_free(big); }
        { casm_cmd *big = casm_cmd_new("many", "d"); int ok = 0, bad = 0; char nm[8];
          for (int k = 0; k < 27; k++) { snprintf(nm, sizeof nm, "o%d", k); casm_opt *o2 = casm_opt_new(CASM_OPT_BOOLEAN, nm, "d", 0);
              (casm_cmd_option(big, o2) == 0 ? ok++ : bad++); casm_builder_free(o2); }
          printf("RET b36 %d %d\n", ok, bad); casm_builder_free(big); }
        casm_builder_free(h); casm_builder_free(adm); casm_builder_free(ctx); casm_builder_free(c2);
        casm_builder_free(who); casm_builder_free(cnt); casm_builder_free(rat); casm_builder_free(q); casm_builder_free(lv);
        casm_builder_free(pi); casm_builder_free(mn); casm_builder_free(mx); casm_builder_free(grp); casm_builder_free(sub);
        casm_builder_free(usr); casm_builder_free(opt); casm_builder_free(req);
        for (int k = 0; k < nj; k++) casm_builder_free(junk[k]);
    } else if (starts_str(i->command_name, "files")) {
        unsigned char *d1 = mkdata(300), *d2 = mkdata(1000000);
        casm_reply *r;
        printf("RET f1 %ld\n", casm_send_file("1001", "cat.png", d1, 300, NULL, "caption \"q\" \xC3\xA9"));
        printf("RET f2 %ld\n", casm_send_file("1001", "report.txt", "hello\n", 6, NULL, NULL));
        printf("RET f3 %ld\n", casm_send_file("1001", "Big \xC3\xA9.BIN", d2, 1000000, "application/x-custom", NULL));
        printf("RET f4 %ld\n", casm_send_file("1001", "empty.log", NULL, 0, NULL, NULL));
        r = casm_reply_new();
        casm_embed *e = casm_embed_new(); casm_embed_image(e, "attachment://a.txt"); casm_embed_title(e, "T");
        casm_reply_content(r, "two files", 9); casm_reply_embed(r, e);
        int rc = casm_reply_file(r, "a.txt", "AAA", 3, NULL);
        rc |= casm_reply_file(r, "b.jpeg", d1, 300, NULL);
        printf("RET fadd %d\n", rc);
        printf("RET fsend %ld\n", casm_send_reply("1001", r, "2001"));
        printf("RET fedit %ld\n", casm_edit_message("1001", "5000", r));
        printf("RET ffollow %ld\n", casm_followup_reply(i, r));
        printf("RET feditresp %ld\n", casm_edit_response_reply(i, r));
        printf("RET frespond %ld\n", casm_respond_reply(i, r));          /* callbacks cannot carry files */
        printf("RET fupdate %ld\n", casm_update_reply(i, r));
        casm_builder_free(r); casm_builder_free(e);
        r = casm_reply_new();
        printf("RET fbad1 %d\n", casm_reply_file(r, "a/b.txt", "x", 1, NULL));
        printf("RET fbad2 %d\n", casm_reply_file(r, "", "x", 1, NULL));
        printf("RET fbad3 %d\n", casm_reply_file(r, "a\"b.txt", "x", 1, NULL));
        printf("RET fbad4 %d\n", casm_reply_file(r, "a\\b.txt", "x", 1, NULL));
        printf("RET fbad5 %d\n", casm_reply_file(r, "a\nb.txt", "x", 1, NULL));
        printf("RET fbad6 %d\n", casm_reply_file(r, "x.txt", NULL, 5, NULL));
        printf("RET fbad7 %d\n", casm_reply_file(r, "x.txt", "x", 1, "nonsense"));
        printf("RET fbad8 %d\n", casm_reply_file(r, "x.txt", "x", 1, "text/pl\nain"));
        printf("RET fbad9 %d\n", casm_reply_file(NULL, "x.txt", "x", 1, NULL));
        printf("RET fbad10 %d\n", casm_reply_file(r, NULL, "x", 1, NULL));
        { char *huge = calloc(26200000, 1);
          printf("RET fbad11 %d\n", huge ? casm_reply_file(r, "huge.bin", huge, 26200000, NULL) : -1);
          printf("RET fok %d\n", casm_reply_file(r, "ok.bin", huge, 20000000, NULL));          /* stays below the request limit */
          printf("RET fbad12 %d\n", casm_reply_file(r, "more.bin", huge, 10000000, NULL));     /* but not together with the first */
          free(huge); }
        casm_builder_free(r);
        printf("RET fbad13 %ld\n", casm_send_file("abc/../x", "a.txt", "x", 1, NULL, NULL));
        printf("RET fbad14 %ld\n", casm_send_file("1001", "a/b", "x", 1, NULL, NULL));
        free(d1); free(d2);
    } else if (starts_str(i->command_name, "selects")) {
        casm_reply *r = casm_reply_new();
        casm_select *su = casm_select_new_entity(CASM_SELECT_USER, "u_sel", "Pick users", 1, 3);
        casm_select *sc = casm_select_new_entity(CASM_SELECT_CHANNEL, "c_sel", NULL, 0, 5);
        casm_select *sm = casm_select_new_entity(CASM_SELECT_MENTIONABLE, "m_sel", NULL, -1, 0);
        casm_select *sr = casm_select_new_entity(CASM_SELECT_ROLE, "r_sel", "Roles", -1, 0);
        casm_select *ss = casm_select_new("s_sel", NULL, -1, 0);
        int rc = 0;
        rc |= casm_select_channel_type(sc, 0); rc |= casm_select_channel_type(sc, 2); rc |= casm_select_disabled(sc);
        rc |= casm_select_option(ss, "A", "a", NULL, 0);
        casm_select *all[5] = { su, sc, sm, sr, ss };
        for (int k = 0; k < 5; k++) { casm_row *row = casm_row_new(); rc |= casm_row_select(row, all[k]); rc |= casm_reply_row(r, row); casm_builder_free(row); }
        printf("RET selok %d\n", rc);
        printf("RET selresp %ld\n", casm_respond_reply(i, r));
        char longph[200]; memset(longph, 'p', sizeof longph - 1); longph[sizeof longph - 1] = 0;
        printf("RET sb1 %d\n", casm_select_new_entity(4, "x", NULL, -1, 0) == NULL);
        printf("RET sb2 %d\n", casm_select_new_entity(9, "x", NULL, -1, 0) == NULL);
        printf("RET sb3 %d\n", casm_select_new_entity(5, "", NULL, -1, 0) == NULL);
        printf("RET sb4 %d\n", casm_select_new_entity(5, NULL, NULL, -1, 0) == NULL);
        printf("RET sb5 %d\n", casm_select_new_entity(5, "x", longph, -1, 0) == NULL);
        printf("RET sb6 %d\n", casm_select_new_entity(5, "x", NULL, 26, 0) == NULL);
        printf("RET sb7 %d\n", casm_select_new_entity(5, "x", NULL, 3, 2) == NULL);
        printf("RET sb8 %d\n", casm_select_new_entity(5, "x", NULL, 0, 26) == NULL);
        printf("RET sb9 %d %d %d\n", casm_select_channel_type(su, 0), casm_select_channel_type(sc, -1), casm_select_channel_type(sc, 256));
        printf("RET sb10 %d\n", casm_select_option(su, "A", "a", NULL, 0));
        printf("RET sb11 %d %d\n", casm_select_channel_type(NULL, 0), casm_select_disabled(NULL));
        { casm_modal *mm = casm_modal_new("m", "t");
          printf("RET sb12 %d %d\n", casm_modal_select(NULL, "l", su, 1), casm_modal_select(mm, "l", NULL, 1)); casm_builder_free(mm); }
        casm_builder_free(r); casm_builder_free(su); casm_builder_free(sc); casm_builder_free(sm); casm_builder_free(sr); casm_builder_free(ss);
    } else if (starts_str(i->command_name, "selmodal")) {
        casm_modal *m = casm_modal_new("mod2", "Pick");
        casm_select *su = casm_select_new_entity(CASM_SELECT_USER, "u2", NULL, 1, 2);
        casm_select *sc = casm_select_new_entity(CASM_SELECT_CHANNEL, "c2", NULL, 0, 0);
        int rc = casm_select_channel_type(sc, 0);
        rc |= casm_modal_select(m, "Who", su, 1); rc |= casm_modal_select(m, "Where", sc, 0);
        printf("RET msok %d\n", rc);
        printf("RET msshow %ld\n", casm_show_modal(i, m));
        casm_builder_free(m); casm_builder_free(su); casm_builder_free(sc);
    } else if (starts_str(i->command_name, "done")) {
        if (inter_thr_started) pthread_join(inter_thr, NULL);
        casm_stop();
    }
    fflush(stdout);
}

static int overflow(int n) { volatile char pad[512]; pad[0] = (char)n; return overflow(n + 1) + pad[0]; }

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
        printf("MISC version %s %s\n", casm_version(), CASM_VERSION_STRING);
        printf("MISC init_null %d\n", casm_init(NULL, 1));
        printf("MISC init_empty %d\n", casm_init("", 1));
        printf("MISC run_noinit %d\n", casm_run());
        printf("MISC botid %s\n", casm_bot_id() ? "set" : "null");
        return 0;
    }
    if (argc >= 2 && strncmp(argv[1], "crash", 5) == 0) {        /* run by the harness without valgrind */
        if (strcmp(argv[1], "crashoff") != 0) printf("HANDLER %d\n", casm_set_crash_handler(1));
        else { casm_set_crash_handler(1); printf("HANDLER off %d\n", casm_set_crash_handler(0)); }
        fflush(stdout);
        if (strcmp(argv[1], "crashstack") == 0) return overflow(1);
        casm_str s = { "x", 1 };
        (void)s;
        return (int)casm_respond((const casm_interaction *)(size_t)8, "hi", 2, 0);   /* garbage pointer inside the library */
    }
    if (argc >= 2 && strcmp(argv[1], "unit") == 0) { unit_tests(); return u_fail != 0; }
    if (argc >= 2 && strcmp(argv[1], "unescape") == 0) { unescape_stdin(); return 0; }
    if (argc < 4) { fprintf(stderr, "usage: %s main|fatal|misc port cafile\n", argv[0]); return 2; }
    char api[128], gw[128];
    snprintf(api, sizeof api, "https://localhost:%s/api/v10", argv[2]);
    snprintf(gw, sizeof gw, "wss://localhost:%s/?v=10&encoding=json", argv[2]);
    casm_set_api_base(api);
    casm_set_gateway_url(gw);
    casm_set_ca_file(argv[3]);
    if (casm_init("tok.en", CASM_INTENTS_DEFAULT) != 0) { puts("INIT failed"); return 1; }
    if (strcmp(argv[1], "rl") == 0) {               /* per-route rate limiting against the bucket mock */
        struct timespec a, b;
        clock_gettime(CLOCK_MONOTONIC, &a);
        long st[8]; int k = 0;
        st[k++] = casm_send("1001", "a1", 2, NULL); st[k++] = casm_send("1001", "a2", 2, NULL);
        st[k++] = casm_send("1002", "b1", 2, NULL); st[k++] = casm_send("1002", "b2", 2, NULL);
        clock_gettime(CLOCK_MONOTONIC, &b);
        printf("RL phase1 %ld\n", (b.tv_sec - a.tv_sec) * 1000 + (b.tv_nsec - a.tv_nsec) / 1000000);
        for (int i = 0; i < 4; i++) st[k++] = casm_send("1001", "c", 1, NULL);
        clock_gettime(CLOCK_MONOTONIC, &b);
        printf("RL total %ld\n", (b.tv_sec - a.tv_sec) * 1000 + (b.tv_nsec - a.tv_nsec) / 1000000);
        int ok = 0;
        for (int i = 0; i < k; i++) ok += st[i] == 200;
        printf("RL ok %d of %d\n", ok, k);
        clock_gettime(CLOCK_MONOTONIC, &a);
        long g = casm_send("1002", "GLOBAL", 6, NULL);
        clock_gettime(CLOCK_MONOTONIC, &b);
        printf("RL global %ld %ld\n", g, (b.tv_sec - a.tv_sec) * 1000 + (b.tv_nsec - a.tv_nsec) / 1000000);
        casm_cleanup();
        return 0;
    }
    if (strcmp(argv[1], "threads") == 0) {      /* REST only, 8 threads x 10 messages */
        pthread_t t[8];
        for (long i = 0; i < 8; i++) pthread_create(&t[i], NULL, thr, (void *)(size_t)i);
        for (int i = 0; i < 8; i++) pthread_join(t[i], NULL);
        printf("THREADS ok=%ld bad=%ld\n", thr_ok, thr_bad);
        return 0;
    }
    if (strcmp(argv[1], "reuse") == 0) {        /* REST only, sequential */
        int ok = 0, bad = 0;
        for (int i = 0; i < 12; i++) {
            char t[32]; int n = snprintf(t, sizeof t, "seq %d", i);
            if (casm_send("1001", t, (size_t)n, NULL) == 200) ok++; else bad++;
        }
        casm_cleanup();
        printf("REUSE ok=%d bad=%d\n", ok, bad);
        return 0;
    }
    casm_on_event(on_event, NULL);
    if (strcmp(argv[1], "inter") == 0) casm_on_interaction(on_interaction, NULL);
    else casm_on_message(on_message, NULL);
    if (strcmp(argv[1], "main") == 0) {
        casm_on_message_update(on_update, NULL); casm_on_message_delete(on_delete, NULL);
        casm_on_reaction(on_react, NULL); casm_on_member(on_member, NULL);
    }
    if (strcmp(argv[1], "fatallog") == 0) casm_set_log_callback(on_log, NULL);
    if (strcmp(argv[1], "main") == 0) casm_set_presence("dnd", CASM_ACTIVITY_WATCHING, "uptime \"x\"", NULL);
    int r = casm_run();
    printf("RUN %d\n", r);
    return 0;
}
