# CaineASM-Library

Library bot Discord yang ditulis dalam **Assembly (NASM x86-64)**, bisa dipakai dari C atau assembly lain. Dibangun dari modul CaineASM Lite yang sudah teruji.

Isinya:
- **Gateway v10**: WebSocket (RFC 6455 ditulis manual), heartbeat dengan jitter, deteksi koneksi zombie, resume otomatis, reconnect dengan backoff, dan berhenti kalau close code fatal (token salah / intents belum diaktifkan).
- **REST**: kirim/reply, edit, hapus, reaction, typing, plus `casm_request` untuk endpoint apa saja. 429 di-retry otomatis.
- **Callback**: `casm_on_message` (pesan sudah di-parse) dan `casm_on_event` (semua event dispatch, JSON mentah).

Dependensi: **libcurl** (cuma untuk koneksi TCP+TLS dan HTTPS) dan libc. Tidak ada library bot Discord lain.

## Build
Butuh `nasm`, `gcc`, `ld`, `objcopy`, `ar`, `libcurl4-openssl-dev`.

```
make            # build/libcaineasm.a
make test       # tes end-to-end lawan mock Discord lokal (81 pengecekan)
make valgrind   # tes yang sama di bawah valgrind
make example    # build/ping_bot
```

Hanya 19 simbol `casm_*` yang terlihat dari luar (simbol internal dijadikan lokal lewat `objcopy`), jadi tidak bentrok dengan nama di kode kamu.

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
Link: `cc app.c libcaineasm.a -Iinclude -l:libcurl.so.4 -pthread`. Contoh lengkap di `examples/ping_bot.c`. Aktifkan **Message Content Intent** di Discord Developer Portal.

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
| `casm_set_api_base / set_gateway_url / set_user_agent / set_ca_file / set_quiet` | Opsional |

Fungsi REST mengembalikan status HTTP (2xx = sukses), `0` kalau transfer gagal, `-1` kalau argumen tidak valid (ID harus 1–20 digit, jadi tidak mungkin menyisipkan `/` atau `..` ke path).

## Aturan penting
- Teks dari Discord berupa **slice (ptr + len) ke buffer internal**, masih dalam bentuk **JSON-escaped** (`\"`, `\n`, `\uXXXX`), dan hanya valid selama callback berjalan. Salin kalau mau disimpan.
- Teks yang kamu kirim lewat `casm_send*` adalah UTF-8 biasa. Library yang meng-escape-nya.
- Callback jalan di thread gateway. Pekerjaan lambat (misalnya panggil API AI) sebaiknya di thread sendiri. Fungsi REST aman dipanggil dari thread mana saja (tiap panggilan pakai handle curl sendiri).
- Mention di pesan yang dikirim dibatasi ke user saja (`allowed_mentions.parse = ["users"]`), jadi tidak bisa ping `@everyone` atau role.

## Batasan v0.1
- **Satu client per proses** (state global).
- Belum ada: slash command/interactions, voice, sharding, cache guild/user, rate limit per-bucket (hanya retry 1x untuk 429), kirim file/embed lewat helper (bisa lewat `casm_request` dengan JSON sendiri), fungsi unescape JSON.
- Tiap panggilan REST membuka koneksi TLS baru (belum ada reuse koneksi).
- Hanya x86-64 Linux (ELF64, SysV ABI).
- **Belum dites langsung ke Discord asli**, hanya ke mock lokal (gateway + REST lewat TLS).

## Tes
`tests/run_test.py` menjalankan `tests/test_caineasm.c` lawan `tests/mock_discord.py`: identify, heartbeat, resume dengan seq yang benar, invalid session lalu identify ulang, close code fatal 4004, parsing semua field pesan (guild, DM, reply, bot, attachment, mention), semua fungsi REST (isi body, header, method), pemecahan pesan panjang, retry 429, validasi argumen, dan 80 pengiriman paralel dari 8 thread.

## Lisensi

CaineASM-Library dilisensikan di bawah GNU Affero General Public License versi 3. Lihat [LICENSE](LICENSE).
