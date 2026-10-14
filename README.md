# CaineASM-Library

Library bot Discord yang ditulis dalam **Assembly (NASM x86-64)**, bisa dipakai dari C atau assembly lain. Dibangun dari modul CaineASM Lite yang sudah teruji.

Isinya:
- **Gateway v10**: WebSocket (RFC 6455 ditulis manual), heartbeat dengan jitter, deteksi koneksi zombie, resume otomatis, reconnect dengan backoff, dan berhenti kalau close code fatal (token salah / intents belum diaktifkan).
- **REST**: kirim/reply, edit, hapus, reaction, typing, plus `casm_request` untuk endpoint apa saja. 429 di-retry otomatis.
- **Callback**: `casm_on_message` (pesan sudah di-parse), `casm_on_interaction` (slash command / tombol, sudah di-parse) dan `casm_on_event` (semua event dispatch, JSON mentah).
- **Slash command**: respond, defer, followup, edit/hapus jawaban, daftar command (global/guild), helper option & subcommand.
- **Embed, tombol, menu pilihan, modal**: builder (`casm_embed_*`, `casm_row_*`, `casm_select_*`, `casm_modal_*`, `casm_reply_*`) plus pengirim (`casm_send_reply`, `casm_respond_reply`, `casm_update_reply`, `casm_show_modal`, `casm_autocomplete`) dan pembaca jawaban (`casm_modal_value`, `casm_select_values`, `casm_option_focused`).
- **Helper pesan**: `casm_unescape`, cek mention bot, cek reply ke bot, `casm_match_prefix`, `casm_next_word`.
- **Koneksi REST dipakai ulang** (keep-alive lewat pool handle curl).

Dependensi: **libcurl** (cuma untuk koneksi TCP+TLS dan HTTPS) dan libc. Tidak ada library bot Discord lain.

## Build
Butuh `nasm`, `gcc`, `ld`, `objcopy`, `ar`, `libcurl4-openssl-dev`.

```
make            # build/libcaineasm.a
make test       # tes end-to-end lawan mock Discord lokal (188 pengecekan)
make valgrind   # tes yang sama di bawah valgrind
make example    # build/ping_bot dan build/slash_bot
```

Hanya 78 simbol `casm_*` yang terlihat dari luar (simbol internal dijadikan lokal lewat `objcopy`), jadi tidak bentrok dengan nama di kode kamu.

## Contoh
```c
#include "caineasm.h"

static void on_message(const casm_message *m, void *user) {
    if (m->author_is_bot) return;
    char chan[32], id[32];                       /* slice tidak diakhiri NUL */
    snprintf(chan, sizeof chan, "%.*s", (int)m->channel_id.len, m->channel_id.ptr);
    snprintf(id,   sizeof id,   "%.*s", (int)m->id.len,         m->id.ptr);
    if (m->content.len == 5 && !memcmp(m->content.ptr, "!ping", 5))
        casm_send(chan, "pong", 4, id);          /* reply ke pesan itu */
}

int main(void) {
    casm_init(getenv("DISCORD_TOKEN"), CASM_INTENTS_DEFAULT);
    casm_on_message(on_message, NULL);
    return casm_run();                           /* blocking */
}
```
Link: `cc app.c libcaineasm.a -Iinclude -l:libcurl.so.4 -pthread`. Contoh lengkap di `examples/ping_bot.c` (prefix command) dan `examples/slash_bot.c` (slash command dengan defer + thread). Aktifkan **Message Content Intent** di Discord Developer Portal.

## API
| Fungsi | Kegunaan |
|---|---|
| `casm_init(token, intents)` | Siapkan client (sekali). `0` ok, `-1` gagal |
| `casm_on_message(cb, user)` / `casm_on_event(cb, user)` | Pasang callback |
| `casm_run()` | Blocking. `0` dihentikan, `1` fatal (token/intents), `-1` belum init |
| `casm_stop()` | Berhenti (aman dipanggil dari signal handler) |
| `casm_bot_id()` | ID bot, `NULL` sebelum READY |
| `casm_send(chan, teks, len, reply_to)` | Satu pesan. `reply_to` boleh `NULL` |
| `casm_send_long(...)` | Potong otomatis per 1900 byte (rapi di baris baru), hanya potongan pertama yang me-reply |
| `casm_edit`, `casm_delete`, `casm_react`, `casm_typing` | Edit, hapus, reaction (emoji sudah URL-encoded), indikator mengetik |
| `casm_request(method, path, body, len, &resp, &resp_len)` | Endpoint REST bebas (GET/POST/PUT/PATCH/DELETE). Hasil dibebaskan dengan `casm_free` |
| `casm_on_interaction(cb, user)` | Callback `INTERACTION_CREATE` (slash command, tombol, dll). Jawaban pertama wajib dalam **3 detik** |
| `casm_respond(i, teks, len, flags)` / `casm_defer(i, flags)` | Jawaban pertama (type 4) / "thinking..." (type 5). `flags = CASM_MSG_EPHEMERAL` (64) supaya hanya pengguna itu yang lihat |
| `casm_interaction_response(i, type, json, len)` | Jawaban pertama dengan type apa saja (1..99) dan `data` JSON mentah (embed, komponen, modal, autocomplete) |
| `casm_followup`, `casm_edit_response`, `casm_delete_response` | Pesan lanjutan, edit, hapus jawaban pertama (token berlaku 15 menit) |
| `casm_register_commands(json, len)` / `casm_register_guild_commands(guild, json, len)` | Daftarkan command (bulk overwrite). Perlu READY dulu |
| `casm_option(i, nama, &v)`, `casm_option_in(opts, nama, &v)`, `casm_subcommand(opts, &nama, &sub)` | Baca option command. Return tipe JSON: `'s'` string, `'d'` angka, `'b'` bool, `0` tidak ada |
| `casm_interaction_keep(i)` / `casm_interaction_release(p)` | Salinan interaction yang tetap valid setelah callback selesai (untuk thread kerja) |
| `casm_embed_new` + `casm_embed_title/description/url/timestamp/footer/author/image/thumbnail/color/field` | Bangun embed (semua string C biasa, di-escape otomatis) |
| `casm_row_new`, `casm_row_button(r, style, label, id_atau_url, disabled)`, `casm_select_new`, `casm_select_option`, `casm_row_select` | Tombol (primary/secondary/success/danger/link) dan menu pilihan |
| `casm_modal_new`, `casm_modal_input(...)` | Modal dengan text input (dibungkus Label, sesuai dokumentasi terbaru) |
| `casm_reply_new`, `casm_reply_content/flags/embed/row` | Susun payload pesan; bebaskan semua builder dengan `casm_builder_free` |
| `casm_send_reply`, `casm_edit_message`, `casm_respond_reply`, `casm_update_reply`, `casm_followup_reply`, `casm_edit_response_reply`, `casm_show_modal` | Kirim payload ke channel / sebagai jawaban interaction |
| `casm_autocomplete(i, names, values, n)`, `casm_option_focused(i, &nama, &isi)` | Autocomplete (maks 25 pilihan) |
| `casm_modal_value(i, custom_id, &v)`, `casm_select_values(i, &arr)`, `casm_array_at(&arr, idx, &v)` | Baca isi modal dan pilihan menu |
| `casm_unescape(src, len, dst, cap)` | Decode escape JSON ke UTF-8 (return gaya `snprintf`, tidak memotong karakter UTF-8) |
| `casm_mentions_user(m, id)`, `casm_mentions_me(m)`, `casm_is_reply_to_me(m)` | Cek mention / reply |
| `casm_match_prefix(&content, "caine", &rest)`, `casm_next_word(&teks, &kata, &sisa)` | Parsing perintah |
| `casm_app_id()`, `casm_cleanup()` | ID aplikasi (setelah READY), bebaskan pool koneksi |
| `casm_set_crash_handler(1)` | Kalau crash (SIGSEGV/SIGBUS/SIGFPE/SIGILL/SIGABRT) cetak sinyal, alamat fault, instruction pointer, dan backtrace ke stderr, lalu mati seperti biasa (core dump tetap ada) |
| `casm_set_api_base / set_gateway_url / set_user_agent / set_ca_file / set_quiet` | Opsional |

Fungsi REST mengembalikan status HTTP (2xx = sukses), `0` kalau transfer gagal, `-1` kalau argumen tidak valid (ID harus 1–20 digit, jadi tidak mungkin menyisipkan `/` atau `..` ke path).

## Aturan penting
- Teks dari Discord berupa **slice (ptr + len) ke buffer internal**, masih dalam bentuk **JSON-escaped** (`\"`, `\n`, `\uXXXX`), dan hanya valid selama callback berjalan. Salin kalau mau disimpan.
- Teks yang kamu kirim lewat `casm_send*` adalah UTF-8 biasa. Library yang meng-escape-nya.
- Callback jalan di thread gateway. Pekerjaan lambat (misalnya panggil API AI) sebaiknya di thread sendiri. Fungsi REST aman dipanggil dari thread mana saja (tiap panggilan pakai handle curl sendiri).
- Mention di pesan yang dikirim dibatasi ke user saja (`allowed_mentions.parse = ["users"]`), jadi tidak bisa ping `@everyone` atau role.

## Kalau crash
Panggil `casm_set_crash_handler(1)` di thread yang menjalankan `casm_run` (stack overflow ikut terlapor). Contoh keluaran:
```
💥 CaineASM crash: SIGSEGV (invalid memory access), fault address 0x28, instruction 0x557b10580ae1
backtrace (addr2line -f -e <binary> <+offset>):
./app(+0x9ae1)[0x557b10580ae1]
```
Ubah offset jadi nama fungsi dan baris: `addr2line -f -e ./app +0x9ae1` (binary harus punya info debug, bangun dengan `-g`). Backtrace mengikuti rantai `rbp`, jadi kode tanpa frame pointer (libc, libcurl, C dengan `-O2`) bisa tidak muncul. Alternatif tanpa handler: `gdb -batch -ex run -ex bt ./app` atau `valgrind ./app`.

## Batasan v0.1
- **Satu client per proses** (state global).
- Belum ada: voice, sharding, cache guild/user, rate limit per-bucket (hanya retry 1x untuk 429), kirim file/lampiran, komponen lain (user/role/channel select, Components V2 seperti Section/Container), builder command (JSON ditulis sendiri), pengecekan batas panjang (Discord yang menolak dengan 400), verifikasi tanda tangan interaksi via webhook HTTP (library ini menerima interaction lewat gateway).
- Pool koneksi REST maksimal 8 handle; koneksi yang diputus server dibuka ulang otomatis.
- Hanya x86-64 Linux (ELF64, SysV ABI).
- **Belum dites langsung ke Discord asli**, hanya ke mock lokal (gateway + REST lewat TLS).

## Tes
`tests/run_test.py` menjalankan `tests/test_caineasm.c` lawan `tests/mock_discord.py`: identify, heartbeat, resume dengan seq yang benar, invalid session lalu identify ulang, close code fatal 4004, parsing semua field pesan (guild, DM, reply, bot, attachment, mention), semua fungsi REST (isi body, header, method), pemecahan pesan panjang, retry 429, validasi argumen, 80 pengiriman paralel dari 8 thread, reuse koneksi (termasuk saat server memutus koneksi), vektor tes + fuzz 5000 kasus untuk `casm_unescape` (dibanding `json.dumps`, termasuk pemotongan UTF-8), helper pesan, crash handler (sinyal tetap mematikan proses, alamat fault dan backtrace tercetak, termasuk stack overflow), dan seluruh alur slash command: parsing (member/DM/komponen), respond/defer/followup/edit/delete (body, path, header), option & subcommand, daftar command, validasi argumen, `casm_interaction_keep` setelah buffer gateway dipakai ulang, dan semua builder (embed, tombol, menu, modal, payload) dibandingkan field demi field dengan JSON yang diharapkan, plus pembaca modal / menu / autocomplete.
