; =====================================================================
; net.asm - HTTPS requests (libcurl easy) and a WebSocket client.
;
; libcurl's own WebSocket API is not compiled into most distro builds
; (Ubuntu's curl 8.5.0 lists no ws/wss protocol), so the WebSocket
; layer here is RFC 6455 written directly: libcurl only provides the
; TCP+TLS connection (CURLOPT_CONNECT_ONLY=1 + curl_easy_send/recv).
; =====================================================================
%include "defs.inc"

extern curl_global_init, curl_easy_init, curl_easy_cleanup, curl_easy_reset
extern curl_easy_setopt, curl_easy_perform, curl_easy_getinfo
extern curl_easy_send, curl_easy_recv, curl_slist_append
extern malloc, realloc, free, memcpy, memmove, memmem, memcmp, poll, getrandom, abort
extern sb_init, sb_free, sb_reset, sb_append, sb_appends, sb_putc
extern now_ms, b64_encode, c_strlen

%define WS_MAX_FRAME   33554432        ; refuse frames above 32 MB
%define WS_READ_CHUNK  16384
%define HTTP_MAX_BODY  16777216        ; refuse HTTP bodies above 16 MB

section .rodata
hs_get:     db "GET ", 0
hs_mid:     db " HTTP/1.1", 13, 10, "Host: ", 0
hs_hdrs:    db 13, 10, "Upgrade: websocket", 13, 10, "Connection: Upgrade", 13, 10
            db "Sec-WebSocket-Version: 13", 13, 10, "Sec-WebSocket-Key: ", 0
hs_end:     db 13, 10, 13, 10, 0
s_wss:      db "wss://"
s_ws:       db "ws://"
s_https:    db "https://", 0
s_http:     db "http://", 0
s_ok101:    db "HTTP/1.1 101"
s_auth_bot: db "Authorization: Bot ", 0
s_ctype:    db "Content-Type: application/json", 0
v_put:      db "PUT", 0
v_patch:    db "PATCH", 0
v_delete:   db "DELETE", 0

section .bss
alignb 8
global g_ca_file, g_hdr_discord
g_ca_file:      resq 1                  ; optional CA bundle path (tests / odd systems)
g_hdr_discord:  resq 1                  ; curl_slist* with Authorization + Content-Type

ws_h:           resq 1
ws_fd:          resq 1
ws_rx:          resq 1
ws_rx_len:      resq 1
ws_rx_off:      resq 1
ws_rx_cap:      resq 1
ws_need:        resq 1
global ws_msg, ws_close_code
ws_msg:         resb 24                 ; sbuf holding the last complete message
ws_active:      resq 1                  ; a fragmented message is in progress
ws_close_code:  resq 1

section .text

; ---------------------------------------------------------------------
; int net_init(const char *discord_token)
; curl_global_init + the shared (read-only) header lists
; ---------------------------------------------------------------------
global net_init
net_init:
    ENTER 64                        ; [0..23] sbuf
    mov r12, rdi
    mov edi, CURL_GLOBAL_DEFAULT
    CALLC curl_global_init
    test eax, eax
    jnz .fail
    lea rbx, [rsp]
    ; ---- Discord ----
    mov rdi, rbx
    call sb_init
    mov rdi, rbx
    lea rsi, [rel s_auth_bot]
    call sb_appends
    mov rdi, rbx
    mov rsi, r12
    call sb_appends
    xor edi, edi
    mov rsi, [rbx]
    CALLC curl_slist_append
    mov rdi, rax
    lea rsi, [rel s_ctype]
    CALLC curl_slist_append
    mov [rel g_hdr_discord], rax
    mov rdi, rbx
    call sb_free
    xor eax, eax
    LEAVE_RET
.fail:
    mov eax, -1
    LEAVE_RET

; CURL *http_new(void) / void http_free(CURL*)
global http_new, http_free
http_new:
    push rbx
    CALLC curl_easy_init
    pop rbx
    ret
http_free:
    push rbx
    test rdi, rdi
    jz .r
    CALLC curl_easy_cleanup
.r: pop rbx
    ret

; size_t write_cb(char *ptr, size_t size, size_t nmemb, void *userdata)
write_cb:
    push rbx
    push r12
    push r13
    mov rbx, rcx                    ; sbuf*
    mov rax, rsi
    imul rax, rdx
    mov r12, rax                    ; n
    mov rax, [rbx + SB_LEN]
    add rax, r12
    cmp rax, HTTP_MAX_BODY
    ja .abort
    mov rsi, rdi
    mov rdi, rbx
    mov rdx, r12
    call sb_append
    mov rax, r12
    pop r13
    pop r12
    pop rbx
    ret
.abort:
    xor eax, eax                    ; short return aborts the transfer
    pop r13
    pop r12
    pop rbx
    ret

; ---------------------------------------------------------------------
; struct req {                      one HTTPS request
;   0 CURL *h; 8 method (0 GET, 1 POST, 2 PUT, 3 PATCH, 4 DELETE); 16 url; 24 curl_slist *hdrs;
;   32 user-agent; 40 body; 48 body_len; 56 sbuf *resp;
;   64 long status (out); 72 timeout seconds;
;   80 header callback (or 0); 88 its userdata }
; int http_do(req *r)  -> CURLcode (0 = transport ok)
; ---------------------------------------------------------------------
global http_do
http_do:
    ENTER 0
    mov rbx, rdi
    mov r12, [rbx]
    mov rdi, r12
    CALLC curl_easy_reset
    SETOPT CURLOPT_URL, [rbx + 16]
    SETOPT CURLOPT_USERAGENT, [rbx + 32]
    SETOPT CURLOPT_HTTPHEADER, [rbx + 24]
    SETOPT CURLOPT_NOSIGNAL, 1
    SETOPT_SYM CURLOPT_WRITEFUNCTION, write_cb
    SETOPT CURLOPT_WRITEDATA, [rbx + 56]
    mov rax, [rbx + 80]
    test rax, rax
    jz .nohdr
    SETOPT CURLOPT_HEADERFUNCTION, rax
    SETOPT CURLOPT_HEADERDATA, [rbx + 88]
.nohdr:
    SETOPT CURLOPT_TIMEOUT, [rbx + 72]
    SETOPT CURLOPT_CONNECTTIMEOUT, 10
    mov rax, [rel g_ca_file]
    test rax, rax
    jz .noca
    SETOPT CURLOPT_CAINFO, rax
.noca:
    mov rax, [rbx + 8]
    test rax, rax
    jz .get
    cmp rax, 1
    je .post
    cmp rax, 2
    je .put
    cmp rax, 3
    je .patch
    cmp rax, 4
    je .delete
    jmp .get                        ; unknown method -> GET
.put:
    lea r13, [rel v_put]
    jmp .custom
.patch:
    lea r13, [rel v_patch]
    jmp .custom
.delete:
    lea r13, [rel v_delete]
.custom:
    SETOPT CURLOPT_POST, 1
    SETOPT CURLOPT_CUSTOMREQUEST, r13
    SETOPT CURLOPT_POSTFIELDSIZE, [rbx + 48]
    SETOPT CURLOPT_POSTFIELDS, [rbx + 40]
    jmp .go
.post:
    SETOPT CURLOPT_POST, 1
    SETOPT CURLOPT_POSTFIELDSIZE, [rbx + 48]
    SETOPT CURLOPT_POSTFIELDS, [rbx + 40]
    jmp .go
.get:
    SETOPT CURLOPT_HTTPGET, 1
.go:
    mov rdi, r12
    CALLC curl_easy_perform
    mov r13d, eax
    mov qword [rbx + 64], 0
    mov rdi, r12
    mov esi, CURLINFO_RESPONSE_CODE
    lea rdx, [rbx + 64]
    xor eax, eax
    CALLC curl_easy_getinfo
    mov eax, r13d
    LEAVE_RET

; =====================================================================
; WebSocket client (single-threaded: only the gateway thread uses it)
; =====================================================================

; int ws_poll_fd(int events, int timeout_ms) -> poll() result
ws_poll_fd:
    ENTER 16
    mov eax, [rel ws_fd]
    mov [rsp], eax
    mov [rsp + 4], di
    mov word [rsp + 6], 0
    mov edx, esi
    lea rdi, [rsp]
    mov esi, 1
    CALLC poll
    LEAVE_RET

; int ws_send_all(const void *buf, size_t len) -> 0 ok / -1 fail
ws_send_all:
    ENTER 16
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d
    call now_ms
    lea r15, [rax + 10000]          ; deadline
.loop:
    cmp r14, r13
    jae .ok
    mov qword [rsp], 0
    mov rdi, [rel ws_h]
    lea rsi, [r12 + r14]
    mov rdx, r13
    sub rdx, r14
    lea rcx, [rsp]
    CALLC curl_easy_send
    test eax, eax
    jz .sent
    cmp eax, CURLE_AGAIN
    jne .fail
.wait:
    call now_ms
    cmp rax, r15
    ja .fail
    mov edi, POLLOUT
    mov esi, 1000
    call ws_poll_fd
    jmp .loop
.sent:
    mov rax, [rsp]
    add r14, rax
    test rax, rax
    jnz .loop
    jmp .wait
.ok:
    xor eax, eax
    LEAVE_RET
.fail:
    mov eax, -1
    LEAVE_RET

; int ws_send_frame(int opcode, const void *payload, size_t len)
; builds a single, final, masked client frame
global ws_send_frame
ws_send_frame:
    ENTER 16
    mov r12d, edi                   ; opcode
    mov r13, rsi                    ; payload
    mov r14, rdx                    ; len
    ; header size: 2 + ext + 4 mask
    mov ebx, 6
    cmp r14, 126
    jb .szok
    mov ebx, 8
    cmp r14, 65536
    jb .szok
    mov ebx, 14
.szok:
    lea rdi, [rbx + r14]
    CALLC malloc
    test rax, rax
    jz .oom
    mov r15, rax                    ; frame buffer
    mov al, r12b
    or al, 0x80                     ; FIN
    mov [r15], al
    cmp r14, 126
    jb .l7
    cmp r14, 65536
    jb .l16
    mov byte [r15 + 1], 0xFF        ; mask bit | 127
    mov rax, r14
    bswap rax
    mov [r15 + 2], rax
    lea rdi, [r15 + 10]
    jmp .mask
.l16:
    mov byte [r15 + 1], 0xFE        ; mask bit | 126
    mov rax, r14
    rol ax, 8
    mov [r15 + 2], ax
    lea rdi, [r15 + 4]
    jmp .mask
.l7:
    mov rax, r14
    or al, 0x80
    mov [r15 + 1], al
    lea rdi, [r15 + 2]
.mask:
    ; rdi -> 4 mask bytes
    mov [rsp], rdi
    mov esi, 4
    xor edx, edx
    CALLC getrandom
    cmp rax, 4
    je .rand_ok
    ; getrandom failed: fall back to the clock so frames are still masked
    call now_ms
    mov rdi, [rsp]
    mov [rdi], eax
.rand_ok:
    mov rdi, [rsp]                  ; mask ptr
    mov edx, [rdi]                  ; 4 mask bytes
    lea rsi, [rdi + 4]              ; payload dest
    xor ecx, ecx
.xor:
    cmp rcx, r14
    jae .send
    movzx eax, byte [r13 + rcx]
    mov r8d, ecx
    and r8d, 3
    lea r9, [rdi + r8]
    xor al, [r9]
    mov [rsi + rcx], al
    inc rcx
    jmp .xor
.send:
    lea rsi, [rbx + r14]
    mov rdi, r15
    call ws_send_all
    mov ebx, eax
    mov rdi, r15
    CALLC free
    mov eax, ebx
    LEAVE_RET
.oom:
    CALLC abort

; int ws_send_text(const char *p, size_t n)
global ws_send_text
ws_send_text:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 1
    jmp ws_send_frame

; int ws_send_close(int code)
global ws_send_close
ws_send_close:
    ENTER 16
    mov eax, edi
    rol ax, 8
    mov [rsp], ax
    mov edi, 8
    lea rsi, [rsp]
    mov edx, 2
    call ws_send_frame
    LEAVE_RET

; void ws_close(void)  drop the connection and reset the parser
global ws_close
ws_close:
    push rbx
    mov rdi, [rel ws_h]
    test rdi, rdi
    jz .r
    CALLC curl_easy_cleanup
.r:
    mov qword [rel ws_h], 0
    mov qword [rel ws_fd], 0
    mov qword [rel ws_rx_len], 0
    mov qword [rel ws_rx_off], 0
    mov qword [rel ws_need], 0
    mov qword [rel ws_active], 0
    pop rbx
    ret

; long ws_read_some(int timeout_ms)
; appends received bytes to the rx buffer.
;   > 0 bytes read, 0 nothing yet (timeout / TLS-internal data), -1 closed or error
ws_read_some:
    ENTER 16
    mov r15d, edi
    ; compact consumed bytes
    mov rax, [rel ws_rx_off]
    test rax, rax
    jz .nocompact
    mov rdi, [rel ws_rx]
    lea rsi, [rdi + rax]
    mov rdx, [rel ws_rx_len]
    sub rdx, rax
    mov [rel ws_rx_len], rdx
    mov qword [rel ws_rx_off], 0
    test rdx, rdx
    jz .nocompact
    CALLC memmove
.nocompact:
    mov rax, [rel ws_rx_len]
    add rax, WS_READ_CHUNK
    mov rcx, [rel ws_need]
    inc rcx
    cmp rcx, rax
    cmova rax, rcx
    cmp rax, [rel ws_rx_cap]
    jbe .capok
    add rax, 65535
    and rax, -65536
    mov r12, rax
    mov rdi, [rel ws_rx]
    mov rsi, r12
    CALLC realloc
    test rax, rax
    jz .oom
    mov [rel ws_rx], rax
    mov [rel ws_rx_cap], r12
.capok:
    xor r13d, r13d                  ; already polled once?
.again:
    mov qword [rsp], 0
    mov rdi, [rel ws_h]
    mov rsi, [rel ws_rx]
    add rsi, [rel ws_rx_len]
    mov rdx, [rel ws_rx_cap]
    sub rdx, [rel ws_rx_len]
    lea rcx, [rsp]
    CALLC curl_easy_recv
    test eax, eax
    jz .got
    cmp eax, CURLE_AGAIN
    jne .err
    test r13d, r13d
    jnz .none
    mov edi, POLLIN
    mov esi, r15d
    call ws_poll_fd
    test eax, eax
    jle .none
    mov r13d, 1
    jmp .again
.got:
    mov rax, [rsp]
    test rax, rax
    jz .err                         ; 0 bytes with CURLE_OK == connection closed
    add [rel ws_rx_len], rax
    LEAVE_RET
.none:
    xor eax, eax
    LEAVE_RET
.err:
    mov rax, -1
    LEAVE_RET
.oom:
    CALLC abort

; int ws_try_parse(void)
;   2 a complete message is in ws_msg, 1 a frame was consumed,
;   0 need more bytes, -1 protocol error, -2 peer sent Close
ws_try_parse:
    ENTER 32                        ; [0] payload len, [8] header len
    mov rbx, [rel ws_rx]
    add rbx, [rel ws_rx_off]        ; frame start
    mov r12, [rel ws_rx_len]
    sub r12, [rel ws_rx_off]        ; bytes available
    cmp r12, 2
    jb .more
    movzx eax, byte [rbx]
    movzx ecx, byte [rbx + 1]
    test al, 0x70                   ; RSV bits must be 0 (no extensions offered)
    jnz .err
    test cl, 0x80                   ; server frames must not be masked
    jnz .err
    mov r14d, eax
    and r14d, 15                    ; opcode
    mov r15d, eax
    shr r15d, 7                     ; FIN
    and ecx, 0x7F
    cmp ecx, 126
    jb .l7
    je .l16
    cmp r12, 10
    jb .more
    mov rax, [rbx + 2]
    bswap rax
    test rax, rax
    js .err
    mov qword [rsp + 8], 10
    jmp .haslen
.l16:
    cmp r12, 4
    jb .more
    movzx eax, word [rbx + 2]
    rol ax, 8
    movzx eax, ax
    mov qword [rsp + 8], 4
    jmp .haslen
.l7:
    mov eax, ecx
    mov qword [rsp + 8], 2
.haslen:
    mov [rsp], rax
    cmp rax, WS_MAX_FRAME
    ja .err
    mov rcx, [rsp + 8]
    add rcx, rax
    cmp rcx, r12
    jbe .have
    mov [rel ws_need], rcx          ; tell the reader how much room is needed
.more:
    xor eax, eax
    LEAVE_RET
.have:
    mov qword [rel ws_need], 0
    mov r13, rbx
    add r13, [rsp + 8]              ; payload pointer
    cmp r14d, 8
    je .close
    cmp r14d, 9
    je .ping
    cmp r14d, 10
    je .consume1
    cmp r14d, 1
    je .first
    cmp r14d, 2
    je .first
    test r14d, r14d
    jz .cont
    jmp .err
.first:
    cmp qword [rel ws_active], 0
    jne .err
    lea rdi, [rel ws_msg]
    call sb_reset
    jmp .append
.cont:
    cmp qword [rel ws_active], 0
    je .err
.append:
    lea rdi, [rel ws_msg]
    mov rsi, r13
    mov rdx, [rsp]
    call sb_append
    mov rax, [rsp + 8]
    add rax, [rsp]
    add [rel ws_rx_off], rax
    test r15d, r15d
    jz .partial
    mov qword [rel ws_active], 0
    mov eax, 2
    LEAVE_RET
.partial:
    mov qword [rel ws_active], 1
    mov eax, 1
    LEAVE_RET
.ping:
    cmp qword [rsp], 125
    ja .err
    mov edi, 10
    mov rsi, r13
    mov rdx, [rsp]
    call ws_send_frame
.consume1:
    mov rax, [rsp + 8]
    add rax, [rsp]
    add [rel ws_rx_off], rax
    mov eax, 1
    LEAVE_RET
.close:
    mov eax, 1005                   ; "no status received"
    cmp qword [rsp], 2
    jb .cstore
    movzx eax, word [r13]
    rol ax, 8
    movzx eax, ax
.cstore:
    mov [rel ws_close_code], rax
    mov edi, 8
    mov rsi, r13
    mov rdx, [rsp]
    cmp rdx, 2
    jbe .echo
    mov edx, 2
.echo:
    call ws_send_frame
    mov eax, -2
    LEAVE_RET
.err:
    mov eax, -1
    LEAVE_RET

; int ws_poll_message(int timeout_ms)
;   1 message ready in ws_msg, 0 nothing yet, -1 connection closed / failed
global ws_poll_message
ws_poll_message:
    ENTER 0
    mov r12d, edi
.loop:
    call ws_try_parse
    cmp eax, 2
    je .msg
    cmp eax, 1
    je .loop
    test eax, eax
    js .closed
    mov edi, r12d
    call ws_read_some
    test rax, rax
    js .closed
    jz .none
    jmp .loop
.msg:
    mov eax, 1
    LEAVE_RET
.none:
    xor eax, eax
    LEAVE_RET
.closed:
    mov eax, -1
    LEAVE_RET

; ---------------------------------------------------------------------
; int ws_connect(const char *url)    ws:// or wss:// (https:// accepted)
; returns 0 when the HTTP upgrade completed with "101", else -1
; ---------------------------------------------------------------------
%define L_URL   0                   ; sbuf (https url for curl)
%define L_REQ   24                  ; sbuf (upgrade request)
%define L_RAND  48                  ; 16 random bytes
%define L_B64   64                  ; 24 chars + NUL
%define L_FD    96                  ; int
%define L_DEAD  104                 ; deadline

global ws_connect
ws_connect:
    ENTER 128
    mov r15, rdi                    ; original url
    call ws_close
    mov qword [rel ws_close_code], 0
    cmp qword [rel ws_rx], 0
    jne .rxok
    mov edi, 65536
    CALLC malloc
    test rax, rax
    jz .oom
    mov [rel ws_rx], rax
    mov qword [rel ws_rx_cap], 65536
.rxok:
    cmp qword [rel ws_msg], 0
    jne .msgok
    lea rdi, [rel ws_msg]
    call sb_init
.msgok:
    lea rdi, [rsp + L_URL]
    call sb_init
    lea rdi, [rsp + L_REQ]
    call sb_init

    ; ---- scheme -> curl url, find host start (r13) ----
    mov rdi, r15
    lea rsi, [rel s_wss]
    mov edx, 6
    CALLC memcmp
    test eax, eax
    jnz .notwss
    lea rdi, [rsp + L_URL]
    lea rsi, [rel s_https]
    call sb_appends
    lea r13, [r15 + 6]
    jmp .rest
.notwss:
    mov rdi, r15
    lea rsi, [rel s_ws]
    mov edx, 5
    CALLC memcmp
    test eax, eax
    jnz .plain
    lea rdi, [rsp + L_URL]
    lea rsi, [rel s_http]
    call sb_appends
    lea r13, [r15 + 5]
    jmp .rest
.plain:
    ; keep the url as is; locate "://"
    mov r13, r15
.scan:
    movzx eax, byte [r13]
    test al, al
    jz .noscheme
    cmp al, ':'
    jne .scan1
    cmp byte [r13 + 1], '/'
    jne .scan1
    cmp byte [r13 + 2], '/'
    jne .scan1
    add r13, 3
    jmp .plainhost
.scan1:
    inc r13
    jmp .scan
.noscheme:
    mov r13, r15
.plainhost:
    lea rdi, [rsp + L_URL]
    mov rsi, r15
    call sb_appends
    jmp .host
.rest:
    lea rdi, [rsp + L_URL]
    mov rsi, r13
    call sb_appends
.host:
    ; host = [r13, r14) up to '/', '?' or NUL
    mov r14, r13
.hl:
    movzx eax, byte [r14]
    test al, al
    jz .hostend
    cmp al, '/'
    je .hostend
    cmp al, '?'
    je .hostend
    inc r14
    jmp .hl
.hostend:
    ; ---- request line + Host ----
    lea rbx, [rsp + L_REQ]
    mov rdi, rbx
    lea rsi, [rel hs_get]
    call sb_appends
    movzx eax, byte [r14]
    cmp al, '/'
    je .pathfull
    mov rdi, rbx
    mov esi, '/'
    call sb_putc
    cmp byte [r14], '?'
    jne .pathdone
.pathfull:
    mov rdi, rbx
    mov rsi, r14
    call sb_appends
.pathdone:
    mov rdi, rbx
    lea rsi, [rel hs_mid]
    call sb_appends
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    sub rdx, r13
    call sb_append
    mov rdi, rbx
    lea rsi, [rel hs_hdrs]
    call sb_appends

    ; ---- TCP + TLS via libcurl ----
    CALLC curl_easy_init
    test rax, rax
    jz .fail
    mov r12, rax
    mov [rel ws_h], rax
    SETOPT CURLOPT_URL, [rsp + L_URL]
    SETOPT CURLOPT_CONNECT_ONLY, 1
    SETOPT CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1
    SETOPT CURLOPT_NOSIGNAL, 1
    SETOPT CURLOPT_CONNECTTIMEOUT, 10
    SETOPT CURLOPT_TCP_NODELAY, 1
    mov rax, [rel g_ca_file]
    test rax, rax
    jz .noca
    SETOPT CURLOPT_CAINFO, rax
.noca:
    mov rdi, r12
    CALLC curl_easy_perform
    test eax, eax
    jnz .fail
    mov qword [rsp + L_FD], 0
    mov rdi, r12
    mov esi, CURLINFO_ACTIVESOCKET
    lea rdx, [rsp + L_FD]
    xor eax, eax
    CALLC curl_easy_getinfo
    test eax, eax
    jnz .fail
    movsxd rax, dword [rsp + L_FD]
    mov [rel ws_fd], rax

    ; ---- Sec-WebSocket-Key = base64(16 random bytes) ----
    lea rdi, [rsp + L_RAND]
    mov esi, 16
    xor edx, edx
    CALLC getrandom
    cmp rax, 16
    je .keyok
    call now_ms
    mov [rsp + L_RAND], rax
    mov [rsp + L_RAND + 8], rax
.keyok:
    lea rdi, [rsp + L_RAND]
    mov esi, 16
    lea rdx, [rsp + L_B64]
    call b64_encode
    mov rdi, rbx
    lea rsi, [rsp + L_B64]
    call sb_appends
    mov rdi, rbx
    lea rsi, [rel hs_end]
    call sb_appends
    mov rdi, [rbx + SB_DATA]
    mov rsi, [rbx + SB_LEN]
    call ws_send_all
    test eax, eax
    jnz .fail

    ; ---- read the 101 response ----
    call now_ms
    add rax, 10000
    mov [rsp + L_DEAD], rax
.rd:
    mov rdi, [rel ws_rx]
    mov rsi, [rel ws_rx_len]
    lea rdx, [rel hs_end]
    mov ecx, 4
    CALLC memmem
    test rax, rax
    jnz .gothdr
    call now_ms
    mov rcx, [rsp + L_DEAD]
    sub rcx, rax
    jle .fail
    cmp rcx, 1000
    jbe .t
    mov ecx, 1000
.t:
    mov edi, ecx
    call ws_read_some
    test rax, rax
    js .fail
    jmp .rd
.gothdr:
    sub rax, [rel ws_rx]            ; offset of CRLFCRLF
    add rax, 4
    cmp rax, 12
    jb .fail
    mov r13, rax                    ; header length
    mov rdi, [rel ws_rx]
    lea rsi, [rel s_ok101]
    mov edx, 12
    CALLC memcmp
    test eax, eax
    jnz .fail
    mov [rel ws_rx_off], r13        ; bytes after the headers are already frames
    lea rdi, [rsp + L_URL]
    call sb_free
    lea rdi, [rsp + L_REQ]
    call sb_free
    xor eax, eax
    LEAVE_RET
.fail:
    call ws_close
    lea rdi, [rsp + L_URL]
    call sb_free
    lea rdi, [rsp + L_REQ]
    call sb_free
    mov eax, -1
    LEAVE_RET
.oom:
    CALLC abort

section .note.GNU-stack noalloc noexec nowrite progbits
