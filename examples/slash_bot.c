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

/* Commands built with the command builder (no JSON by hand). */
static long register_all(const char *guild) {
    casm_cmd *ping = casm_cmd_new("ping", "Pong");
    casm_cmd *panel = casm_cmd_new("panel", "Embed + tombol + menu + modal");
    casm_cmd *echo = casm_cmd_new("echo", "Ulangi teks (jawaban tertunda)");
    casm_cmd *file = casm_cmd_new("file", "Kirim file teks sebagai lampiran");
    casm_opt *text = casm_opt_new(CASM_OPT_STRING, "text", "Teksnya", 1);
    casm_opt_length(text, 1, 200);
    casm_cmd_option(echo, text);
    casm_cmd *list[] = { ping, panel, echo, file };
    long r = (guild && *guild) ? casm_register_guild_cmds(guild, list, 4) : casm_register_cmds(list, 4);
    for (int k = 0; k < 4; k++) casm_builder_free(list[k]);
    casm_builder_free(text);
    return r;
}

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

static int is(casm_str s, const char *x) { return s.ptr && s.len == strlen(x) && !memcmp(s.ptr, x, s.len); }

static void show_panel(const casm_interaction *i) {
    casm_embed *e = casm_embed_new();
    casm_embed_title(e, "CaineASM-Library");
    casm_embed_description(e, "Embed, tombol, menu pilihan dan modal dari Assembly.");
    casm_embed_color(e, 0x5865F2);
    casm_embed_field(e, "Fitur", "gateway, REST, slash command", 1);
    casm_row *buttons = casm_row_new();
    casm_row_button(buttons, CASM_BUTTON_PRIMARY, "Isi form", "open_form", 0);
    casm_row_button(buttons, CASM_BUTTON_LINK, "Dokumentasi", "https://docs.discord.com/developers", 0);
    casm_select *menu = casm_select_new("pick", "Pilih satu", -1, 0);
    casm_select_option(menu, "Merah", "red", NULL, 0);
    casm_select_option(menu, "Biru", "blue", "warna dingin", 0);
    casm_row *menu_row = casm_row_new();
    casm_row_select(menu_row, menu);
    casm_reply *r = casm_reply_new();
    casm_reply_embed(r, e); casm_reply_row(r, buttons); casm_reply_row(r, menu_row);
    casm_respond_reply(i, r);
    casm_builder_free(r); casm_builder_free(menu_row); casm_builder_free(menu);
    casm_builder_free(buttons); casm_builder_free(e);
}

static void on_interaction(const casm_interaction *i, void *user) {
    (void)user;
    if (i->type == 3) {                             /* button / select menu */
        if (is(i->custom_id, "open_form")) {
            casm_modal *m = casm_modal_new("form", "Form kecil");
            casm_modal_input(m, "nama", "Nama kamu", 0, "ketik di sini", 1, 40, 1);
            casm_show_modal(i, m);
            casm_builder_free(m);
        } else if (is(i->custom_id, "pick")) {
            casm_str vs, v;
            if (casm_select_values(i, &vs) && casm_array_at(&vs, 0, &v) == 's') {
                char t[160]; int n = snprintf(t, sizeof t, "Kamu pilih: %.*s", (int)v.len, v.ptr);
                casm_respond(i, t, (size_t)n, CASM_MSG_EPHEMERAL);
            }
        }
        return;
    }
    if (i->type == 5) {                             /* modal submitted */
        casm_str v; char dec[128], t[200];
        if (casm_modal_value(i, "nama", &v) == 's') {
            size_t n = casm_unescape(v.ptr, v.len, dec, sizeof dec);
            if (n >= sizeof dec) n = sizeof dec - 1;
            int k = snprintf(t, sizeof t, "Halo, %.*s!", (int)n, dec);
            casm_respond(i, t, (size_t)k, CASM_MSG_EPHEMERAL);
        }
        return;
    }
    if (i->type != 2) return;                       /* application commands only */
    if (is(i->command_name, "panel")) { show_panel(i); return; }
    if (i->command_name.len == 4 && !memcmp(i->command_name.ptr, "ping", 4)) {
        casm_respond(i, "pong", 4, 0);              /* first response within 3 seconds */
    } else if (i->command_name.len == 4 && !memcmp(i->command_name.ptr, "echo", 4)) {
        if (casm_defer(i, CASM_MSG_EPHEMERAL) != 204) return;
        casm_interaction *k = casm_interaction_keep(i);
        pthread_t t;
        if (k && pthread_create(&t, NULL, slow_echo, k) == 0) pthread_detach(t);
        else casm_interaction_release(k);
    } else if (is(i->command_name, "file")) {
        /* callback responses cannot carry files: defer, then follow up with the attachment */
        if (casm_defer(i, 0) != 204) return;
        static const char body[] = "Dibuat oleh CaineASM-Library.\nIni lampiran teks.\n";
        casm_reply *r = casm_reply_new();
        casm_reply_content(r, "Ini filenya:", 12);
        casm_reply_file(r, "hello.txt", body, sizeof body - 1, NULL);   /* type guessed: text/plain */
        casm_followup_reply(i, r);
        casm_builder_free(r);
    }
}

static void on_event(const char *type, size_t tl, const char *d, size_t dl, void *user) {
    (void)d; (void)dl; (void)user;
    if (tl != 5 || memcmp(type, "READY", 5) != 0) return;       /* application id is known now */
    const char *guild = getenv("GUILD_ID");
    long r = register_all(guild);
    fprintf(stderr, "register commands: HTTP %ld\n", r);
}

int main(void) {
    const char *token = getenv("DISCORD_TOKEN");
    if (!token || !*token) { fprintf(stderr, "set DISCORD_TOKEN\n"); return 1; }
    fprintf(stderr, "CaineASM-Library %s\n", casm_version());
    casm_set_crash_handler(1);                      /* crash report + backtrace on stderr */
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    if (casm_init(token, CASM_INTENT_GUILDS) != 0) return 1;
    casm_on_event(on_event, NULL);
    casm_on_interaction(on_interaction, NULL);
    int r = casm_run();
    casm_cleanup();
    return r;
}
