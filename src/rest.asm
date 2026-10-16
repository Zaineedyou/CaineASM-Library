; =====================================================================
; rest.asm - Discord REST: generic request + message helpers.
;   Every call uses its own libcurl handle, so all functions are safe to
;   call from any thread. 429 responses are retried once after
;   retry_after (capped at 10 s).
; =====================================================================
%include "defs.inc"

%define POOL_MAX 8

extern free, pthread_mutex_lock, pthread_mutex_unlock, curl_slist_append, curl_slist_free_all
extern now_ms
extern sb_init, sb_free, sb_reset, sb_append, sb_appends, sb_append_json_esc
extern json_get, parse_u64, sleep_ms, chunk_next, trim_span
extern http_new, http_free, http_do
extern g_api_base, g_hdr_discord, g_user_agent

section .bss
alignb 8
pool_mutex:    resb 40                  ; all zeros == PTHREAD_MUTEX_INITIALIZER (glibc)
pool_n:        resq 1
pool_h:        resq POOL_MAX

section .rodata
s_retry_after: db "retry_after", 0
s_empty:       db 0
p_channels:    db "/channels/", 0
p_messages:    db "/messages", 0
p_msg_slash:   db "/messages/", 0
p_typing:      db "/typing", 0
p_react:       db "/reactions/", 0
p_me:          db "/@me", 0
j_content:     db '{"content":"', 0
j_ref:         db '","message_reference":{"message_id":"', 0
j_refend:      db '","fail_if_not_exists":false},"allowed_mentions":{"parse":["users"],"replied_user":true}}', 0
j_noref:       db '","allowed_mentions":{"parse":["users"],"replied_user":true}}', 0
j_edit_tail:   db '","allowed_mentions":{"parse":["users"]}}', 0

section .text

; long parse_retry_ms(const char *p, size_t n)  "1.5" -> 1500 (3 decimals)
parse_retry_ms:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    call parse_u64
    imul rbx, rax, 1000
    add r12, rdx
    sub r13, rdx
    test r13, r13
    jz .d
    cmp byte [r12], '.'
    jne .d
    inc r12
    dec r13
    mov ecx, 100                    ; weight of the first decimal
.f:
    test r13, r13
    jz .d
    test ecx, ecx
    jz .d
    movzx eax, byte [r12]
    sub eax, '0'
    cmp eax, 9
    ja .d
    imul eax, ecx
    add rbx, rax
    mov eax, ecx
    xor edx, edx
    mov esi, 10
    div esi
    mov ecx, eax
    inc r12
    dec r13
    jmp .f
.d:
    mov rax, rbx
    LEAVE_RET

; ---------------------------------------------------------------------
; rate limits (Discord docs, "Rate Limits"): the response headers say how many
; requests are left in a bucket and when it resets. Buckets are tracked per
; route (method + path, with the top-level resource id of channels / guilds /
; webhooks kept and other ids folded), and a request on an empty bucket waits
; for the reset instead of earning a 429. A 429 still retries once, and a
; global 429 pauses every route. Interaction endpoints are not tracked (they
; are exempt from the global limit and limited per interaction).
; ---------------------------------------------------------------------
%define RL_SLOTS 64
section .bss
alignb 8
rl_mutex:        resb 40
rl_global_until: resq 1
rl_tab:          resb RL_SLOTS * 24     ; {hash, remaining, reset_at_ms}

section .rodata
h_remaining: db "x-ratelimit-remaining:", 0
h_resetafter:db "x-ratelimit-reset-after:", 0
h_global:    db "x-ratelimit-global:", 0
w_interact:  db "interactions", 0
w_channels:  db "channels", 0
w_guilds:    db "guilds", 0
w_webhooks:  db "webhooks", 0
c_idseg:     db ":id", 0
c_xseg:      db ":x", 0

section .text

; unsigned long fnv_bytes(unsigned long h, const char *p, size_t n)   FNV-1a
fnv_bytes:
    mov rax, rdi
    mov r8, 0x100000001b3
    xor ecx, ecx
.l:
    cmp rcx, rdx
    jae .d
    movzx edi, byte [rsi + rcx]
    xor rax, rdi
    imul rax, r8
    inc rcx
    jmp .l
.d:
    ret

; int seg_eq(const char *p, size_t n, const char *lit)   exact match
seg_eq:
    xor ecx, ecx
.l:
    movzx eax, byte [rdx + rcx]
    test al, al
    jz .end
    cmp rcx, rsi
    jae .no
    cmp al, [rdi + rcx]
    jne .no
    inc rcx
    jmp .l
.end:
    xor eax, eax
    cmp rcx, rsi
    sete al
    ret
.no:
    xor eax, eax
    ret

; unsigned long rl_hash(long method, const char *path)
; 0 = do not rate-limit here (interaction endpoints)
rl_hash:
    ENTER 0
    mov rbx, 0xcbf29ce484222325
    xor rbx, rdi
    mov rax, 0x100000001b3
    imul rbx, rax
    mov r13, rsi                    ; cursor
    xor r14d, r14d                  ; 1 major literal just seen, 2 major id kept, 4 webhook token next, 8 that literal was "webhooks"
.seg:
    cmp byte [r13], '/'
    jne .end
    mov rdi, rbx
    lea rsi, [r13]
    mov edx, 1
    call fnv_bytes                  ; feeds the '/'
    mov rbx, rax
    inc r13
    mov r15, r13                    ; segment start
.scan:
    movzx eax, byte [r13]
    test al, al
    jz .sd
    cmp al, '/'
    je .sd
    cmp al, '?'
    je .sd
    inc r13
    jmp .scan
.sd:
    mov r12, r13
    sub r12, r15                    ; segment length
    test r12, r12
    jz .seg
    xor ecx, ecx
.dg:
    cmp rcx, r12
    jae .numeric
    movzx eax, byte [r15 + rcx]
    sub eax, '0'
    cmp eax, 9
    ja .literal
    inc rcx
    jmp .dg
.numeric:
    test r14d, 1
    jz .idx
    test r14d, 2
    jnz .idx
    ; the top-level resource id: keep it
    mov edx, r14d
    and edx, 8
    shr edx, 1                      ; 8 -> 4 (webhook: a token follows)
    or edx, 2
    mov r14d, edx
    mov rdi, rbx
    mov rsi, r15
    mov rdx, r12
    call fnv_bytes
    mov rbx, rax
    jmp .seg
.idx:
    and r14d, 2                     ; forget "major literal seen" and "token next"
    mov rdi, rbx
    lea rsi, [rel c_idseg]
    mov edx, 3
    call fnv_bytes
    mov rbx, rax
    jmp .seg
.literal:
    test r14d, 4
    jz .nottok
    and r14d, 2                     ; the webhook token is part of the key
    mov rdi, rbx
    mov rsi, r15
    mov rdx, r12
    call fnv_bytes
    mov rbx, rax
    jmp .seg
.nottok:
    mov rdi, r15
    mov rsi, r12
    lea rdx, [rel w_interact]
    call seg_eq
    test eax, eax
    jnz .bypass
    xor ecx, ecx
.pc:                                ; a '%' or ':' marks an emoji / odd segment
    cmp rcx, r12
    jae .plain
    movzx eax, byte [r15 + rcx]
    cmp al, '%'
    je .odd
    cmp al, ':'
    je .odd
    inc rcx
    jmp .pc
.odd:
    and r14d, 2
    mov rdi, rbx
    lea rsi, [rel c_xseg]
    mov edx, 2
    call fnv_bytes
    mov rbx, rax
    jmp .seg
.plain:
    mov rdi, rbx
    mov rsi, r15
    mov rdx, r12
    call fnv_bytes
    mov rbx, rax
    and r14d, 2
    test r14d, 2
    jnz .seg
    mov rdi, r15
    mov rsi, r12
    lea rdx, [rel w_channels]
    call seg_eq
    test eax, eax
    jnz .major
    mov rdi, r15
    mov rsi, r12
    lea rdx, [rel w_guilds]
    call seg_eq
    test eax, eax
    jnz .major
    mov rdi, r15
    mov rsi, r12
    lea rdx, [rel w_webhooks]
    call seg_eq
    test eax, eax
    jz .seg
    or r14d, 8
.major:
    or r14d, 1
    jmp .seg
.end:
    mov rax, rbx
    or rax, 1                       ; never 0
    LEAVE_RET
.bypass:
    xor eax, eax
    LEAVE_RET

; struct rl { long remaining (-1 unknown); long reset_after_ms (-1 unknown); long global; long shared }
%define RL_REM    0
%define RL_RESET  8
%define RL_GLOBAL 16
%define RL_SHARED 24

; const char *hdr_val(const char *line, size_t n, const char *lowercase_prefix)
; value start (spaces skipped) in rax and its length in rdx, or rax = 0 when the line is another header
hdr_val:
    xor ecx, ecx
.l:
    movzx eax, byte [rdx + rcx]
    test al, al
    jz .m
    cmp rcx, rsi
    jae .no
    movzx r8d, byte [rdi + rcx]
    LOWER r8d, r9d
    cmp r8b, al
    jne .no
    inc rcx
    jmp .l
.m:
    add rdi, rcx
    sub rsi, rcx
.s:
    test rsi, rsi
    jz .e
    movzx eax, byte [rdi]
    cmp al, ' '
    je .adv
    cmp al, 9
    jne .e
.adv:
    inc rdi
    dec rsi
    jmp .s
.e:
    mov rax, rdi
    mov rdx, rsi
    ret
.no:
    xor eax, eax
    ret

; size_t header_cb(char *buffer, size_t size, size_t nitems, void *userdata)   libcurl header callback
header_cb:
    ENTER 0
    mov r12, rdi
    mov rax, rsi
    imul rax, rdx
    mov r13, rax                    ; n
    mov r14, rcx                    ; struct rl *
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel h_remaining]
    call hdr_val
    test rax, rax
    jz .t2
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    test rdx, rdx
    jz .t2
    mov [r14 + RL_REM], rax
    jmp .done
.t2:
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel h_resetafter]
    call hdr_val
    test rax, rax
    jz .t3
    mov rdi, rax
    mov rsi, rdx
    call parse_retry_ms
    mov [r14 + RL_RESET], rax
    jmp .done
.t3:
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel h_global]
    call hdr_val
    test rax, rax
    jz .done
    cmp byte [rax], 't'
    jne .done
    mov qword [r14 + RL_GLOBAL], 1
.done:
    mov rax, r13
    LEAVE_RET

; long *rl_slot(unsigned long hash, long create, unsigned long now)   caller holds rl_mutex
rl_slot:
    mov rax, rdi
    and eax, RL_SLOTS - 1
    lea r8, [rel rl_tab]
    mov r9, rax
    mov ecx, 4
.p:
    imul r10, r9, 24
    add r10, r8
    cmp [r10], rdi
    je .found
    inc r9
    and r9, RL_SLOTS - 1
    dec ecx
    jnz .p
    test rsi, rsi
    jz .none
    mov r9, rax                     ; claim an empty or expired slot among the 4 probes
    mov ecx, 4
.c:
    imul r10, r9, 24
    add r10, r8
    cmp qword [r10], 0
    je .claim
    cmp [r10 + 16], rdx
    jb .claim
    inc r9
    and r9, RL_SLOTS - 1
    dec ecx
    jnz .c
    imul r10, rax, 24               ; all busy: take over the first probe
    add r10, r8
.claim:
    mov [r10], rdi
    mov qword [r10 + 8], -1
    mov qword [r10 + 16], 0
.found:
    mov rax, r10
    ret
.none:
    xor eax, eax
    ret

; void rl_wait(unsigned long hash)   returns when the route's bucket (and the global one) allow a request
rl_wait:
    ENTER 0
    mov r12, rdi
    test r12, r12
    jz .ret
    mov r13d, 8
.l:
    call now_ms
    mov r14, rax
    lea rdi, [rel rl_mutex]
    CALLC pthread_mutex_lock
    xor r15d, r15d                  ; ms to wait
    mov rax, [rel rl_global_until]
    sub rax, r14
    jbe .g
    mov r15, rax
.g:
    mov rdi, r12
    xor esi, esi
    mov rdx, r14
    call rl_slot
    test rax, rax
    jz .unl
    mov rcx, [rax + 16]
    cmp rcx, r14
    jbe .reset
    mov rdx, [rax + 8]
    test rdx, rdx
    jg .take
    jl .unl                         ; unknown: let it through
    sub rcx, r14                    ; empty bucket: wait for the reset
    cmp rcx, r15
    cmovg r15, rcx
    jmp .unl
.take:
    dec qword [rax + 8]
    jmp .unl
.reset:
    mov qword [rax + 8], -1
.unl:
    lea rdi, [rel rl_mutex]
    CALLC pthread_mutex_unlock
    test r15, r15
    jz .ret
    cmp r15, 10000
    jbe .s
    mov r15d, 10000
.s:
    mov edi, r15d
    call sleep_ms
    dec r13d
    jnz .l
.ret:
    LEAVE_RET

; void rl_set(unsigned long hash, long remaining, long ms, long global)
; remaining requests left, bucket resets in ms (global: pause every route for ms)
rl_set:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    call now_ms
    mov rbx, rax
    lea rdi, [rel rl_mutex]
    CALLC pthread_mutex_lock
    mov rdi, r12
    mov esi, 1
    mov rdx, rbx
    call rl_slot
    mov [rax + 8], r13
    lea rcx, [rbx + r14]
    mov [rax + 16], rcx
    test r15, r15
    jz .u
    lea rcx, [rbx + r14]
    mov [rel rl_global_until], rcx
.u:
    lea rdi, [rel rl_mutex]
    CALLC pthread_mutex_unlock
    LEAVE_RET

; long rest_do(CURL *h, long method, const char *path, const char *body, size_t blen, sbuf *resp)
; returns the HTTP status (0 when the transfer itself failed). One retry after a 429.
%define D_URL   0
%define D_HTTP  24                  ; struct req, 96 bytes
%define D_RL    120                 ; struct rl, 32 bytes
%define D_JV    152
%define D_RESP  176
%define D_HASH  184
%define D_MS    192
%define D_HDRS  200                 ; curl_slist* to send instead of the default JSON headers (0 = default)
rest_do:
    ENTER 208
    mov [rsp + D_HDRS], r10
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rbx, r8
    mov [rsp + D_RESP], r9
    lea rdi, [rsp + D_URL]
    call sb_init
    lea rdi, [rsp + D_URL]
    mov rsi, [rel g_api_base]
    call sb_appends
    lea rdi, [rsp + D_URL]
    mov rsi, r14
    call sb_appends
    mov rdi, r13
    mov rsi, r14
    call rl_hash
    mov [rsp + D_HASH], rax
    xor r14d, r14d                  ; attempt counter
.again:
    mov rdi, [rsp + D_HASH]
    call rl_wait
    mov qword [rsp + D_RL + RL_REM], -1
    mov qword [rsp + D_RL + RL_RESET], -1
    mov qword [rsp + D_RL + RL_GLOBAL], 0
    mov qword [rsp + D_RL + RL_SHARED], 0
    mov [rsp + D_HTTP + 0], r12
    mov [rsp + D_HTTP + 8], r13
    mov rax, [rsp + D_URL + SB_DATA]
    mov [rsp + D_HTTP + 16], rax
    mov rax, [rsp + D_HDRS]
    test rax, rax
    jnz .hdrs
    mov rax, [rel g_hdr_discord]
.hdrs:
    mov [rsp + D_HTTP + 24], rax
    mov rax, [rel g_user_agent]
    mov [rsp + D_HTTP + 32], rax
    mov [rsp + D_HTTP + 40], r15
    mov [rsp + D_HTTP + 48], rbx
    mov rax, [rsp + D_RESP]
    mov [rsp + D_HTTP + 56], rax
    mov qword [rsp + D_HTTP + 64], 0
    mov rax, rbx                    ; transfer timeout: 20 s plus 1 s per 128 KiB of body (file uploads)
    shr rax, 17
    add rax, 20
    mov [rsp + D_HTTP + 72], rax
    lea rax, [rel header_cb]
    mov [rsp + D_HTTP + 80], rax
    lea rax, [rsp + D_RL]
    mov [rsp + D_HTTP + 88], rax
    lea rdi, [rsp + D_HTTP]
    call http_do
    test eax, eax
    jnz .netfail
    mov rax, [rsp + D_HTTP + 64]
    cmp rax, 429
    jne .okresp
    test r14d, r14d
    jnz .out
    inc r14d
    ; wait retry_after (capped) and try once more
    mov rax, [rsp + D_RESP]
    mov rdi, [rax + SB_DATA]
    mov rsi, [rax + SB_LEN]
    lea rdx, [rel s_retry_after]
    lea rcx, [rsp + D_JV]
    mov qword [rsp + D_JV + JV_TYPE], 0
    call json_get
    mov ecx, 1000
    test eax, eax
    jz .sleep
    cmp qword [rsp + D_JV + JV_TYPE], 'd'
    jne .sleep
    mov rdi, [rsp + D_JV + JV_PTR]
    mov rsi, [rsp + D_JV + JV_LEN]
    call parse_retry_ms
    mov rcx, rax
    add rcx, 100
    cmp rcx, 10000
    jbe .sleep
    mov ecx, 10000
.sleep:
    mov [rsp + D_MS], rcx
    mov rdi, [rsp + D_HASH]
    test rdi, rdi
    jz .dosleep
    xor esi, esi                    ; bucket empty until the retry time; a global 429 pauses everything
    mov rdx, rcx
    mov rcx, [rsp + D_RL + RL_GLOBAL]
    call rl_set
.dosleep:
    mov rdi, [rsp + D_MS]
    call sleep_ms
    mov rax, [rsp + D_RESP]
    mov rdi, rax
    call sb_reset
    jmp .again
.okresp:
    mov rdi, [rsp + D_HASH]
    test rdi, rdi
    jz .out
    mov rsi, [rsp + D_RL + RL_REM]
    test rsi, rsi
    js .out
    mov rdx, [rsp + D_RL + RL_RESET]
    test rdx, rdx
    js .out
    xor ecx, ecx
    call rl_set
.out:
    mov rax, [rsp + D_HTTP + 64]
    jmp .free
.netfail:
    xor eax, eax
.free:
    mov r12, rax
    lea rdi, [rsp + D_URL]
    call sb_free
    mov rax, r12
    LEAVE_RET

; ---------------------------------------------------------------------
; handle pool: libcurl keeps live connections inside an easy handle across
; curl_easy_reset, so recycling handles gives keep-alive for free. A handle
; is only ever used by one thread at a time (libcurl's rule).
; ---------------------------------------------------------------------
; CURL *pool_get(void)
pool_get:
    ENTER 0
    lea rdi, [rel pool_mutex]
    CALLC pthread_mutex_lock
    mov rax, [rel pool_n]
    test rax, rax
    jz .none
    dec rax
    mov [rel pool_n], rax
    lea rcx, [rel pool_h]
    mov rbx, [rcx + rax*8]
    jmp .unlock
.none:
    xor ebx, ebx
.unlock:
    lea rdi, [rel pool_mutex]
    CALLC pthread_mutex_unlock
    test rbx, rbx
    jnz .ret
    call http_new
    mov rbx, rax
.ret:
    mov rax, rbx
    LEAVE_RET

; void pool_put(CURL *h)   keep it for reuse, or free it when the pool is full
pool_put:
    ENTER 0
    mov rbx, rdi
    test rbx, rbx
    jz .d
    lea rdi, [rel pool_mutex]
    CALLC pthread_mutex_lock
    mov rax, [rel pool_n]
    cmp rax, POOL_MAX
    jae .full
    lea rcx, [rel pool_h]
    mov [rcx + rax*8], rbx
    inc rax
    mov [rel pool_n], rax
    xor ebx, ebx
.full:
    lea rdi, [rel pool_mutex]
    CALLC pthread_mutex_unlock
    test rbx, rbx
    jz .d
    mov rdi, rbx
    call http_free
.d:
    LEAVE_RET

; void casm_cleanup(void)   frees the pooled handles (call after casm_run returned)
global casm_cleanup
casm_cleanup:
    ENTER 0
.l:
    lea rdi, [rel pool_mutex]
    CALLC pthread_mutex_lock
    xor ebx, ebx
    mov rax, [rel pool_n]
    test rax, rax
    jz .u
    dec rax
    mov [rel pool_n], rax
    lea rcx, [rel pool_h]
    mov rbx, [rcx + rax*8]
.u:
    lea rdi, [rel pool_mutex]
    CALLC pthread_mutex_unlock
    test rbx, rbx
    jz .d
    mov rdi, rbx
    call http_free
    jmp .l
.d:
    LEAVE_RET

; ---------------------------------------------------------------------
; argument validation (ids go straight into URL paths)
; ---------------------------------------------------------------------
; int valid_id(const char *s)   1 for 1..20 ASCII digits
global valid_id
valid_id:
    test rdi, rdi
    jz .bad
    xor ecx, ecx
.l:
    movzx eax, byte [rdi + rcx]
    test al, al
    jz .end
    sub eax, '0'
    cmp eax, 9
    ja .bad
    inc ecx
    cmp ecx, 20
    ja .bad
    jmp .l
.end:
    test ecx, ecx
    jz .bad
    mov eax, 1
    ret
.bad:
    xor eax, eax
    ret

; int valid_emoji(const char *s)   1 for a non-empty, already percent-encoded
; token: letters, digits and - _ . ~ % :   (at most 128 bytes)
valid_emoji:
    test rdi, rdi
    jz .bad
    xor ecx, ecx
.l:
    movzx eax, byte [rdi + rcx]
    test al, al
    jz .end
    mov edx, eax
    sub edx, '0'
    cmp edx, 9
    jbe .ok
    mov edx, eax
    or edx, 32
    sub edx, 'a'
    cmp edx, 25
    jbe .ok
    cmp al, '-'
    je .ok
    cmp al, '_'
    je .ok
    cmp al, '.'
    je .ok
    cmp al, '~'
    je .ok
    cmp al, '%'
    je .ok
    cmp al, ':'
    je .ok
    jmp .bad
.ok:
    inc ecx
    cmp ecx, 128
    ja .bad
    jmp .l
.end:
    test ecx, ecx
    jz .bad
    mov eax, 1
    ret
.bad:
    xor eax, eax
    ret

; ---------------------------------------------------------------------
; long do_call(long method, sbuf *path, sbuf *body /*may be NULL*/)
; one request on a private handle; returns the HTTP status (0 = transport failure)
; ---------------------------------------------------------------------
global do_call
do_call:
    ENTER 32                        ; [0] resp sbuf, [24] handle
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    call pool_get
    test rax, rax
    jz .fail
    mov [rsp + 24], rax
    lea rdi, [rsp]
    call sb_init
    mov rdi, [rsp + 24]
    mov rsi, r12
    mov rdx, [r13 + SB_DATA]
    lea rcx, [rel s_empty]
    xor r8d, r8d
    test r14, r14
    jz .nb
    mov rcx, [r14 + SB_DATA]
    mov r8, [r14 + SB_LEN]
.nb:
    lea r9, [rsp]
    xor r10d, r10d
    call rest_do
    mov r12, rax
    mov rdi, [rsp + 24]
    call pool_put
    lea rdi, [rsp]
    call sb_free
    mov rax, r12
    LEAVE_RET
.fail:
    xor eax, eax
    LEAVE_RET

; ---------------------------------------------------------------------
; long do_call_mp(long method, sbuf *path, sbuf *body, const char *boundary)
; like do_call, but with Content-Type: multipart/form-data; boundary=<boundary>
; ---------------------------------------------------------------------
section .rodata
s_ct_mp:       db "Content-Type: multipart/form-data; boundary=", 0
section .text
global do_call_mp
do_call_mp:
    ENTER 80                        ; [0] resp sbuf, [24] handle, [32] slist, [40] header sbuf
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    lea rdi, [rsp + 40]
    call sb_init
    lea rdi, [rsp + 40]
    lea rsi, [rel s_ct_mp]
    call sb_appends
    lea rdi, [rsp + 40]
    mov rsi, r15
    call sb_appends
    mov rax, [rel g_hdr_discord]    ; first node = the Authorization line
    xor edi, edi
    mov rsi, [rax]
    CALLC curl_slist_append
    mov rdi, rax
    mov rsi, [rsp + 40 + SB_DATA]
    CALLC curl_slist_append
    mov [rsp + 32], rax
    lea rdi, [rsp + 40]
    call sb_free
    cmp qword [rsp + 32], 0
    je .fail
    call pool_get
    test rax, rax
    jz .nohandle
    mov [rsp + 24], rax
    lea rdi, [rsp]
    call sb_init
    mov rdi, [rsp + 24]
    mov rsi, r12
    mov rdx, [r13 + SB_DATA]
    mov rcx, [r14 + SB_DATA]
    mov r8, [r14 + SB_LEN]
    lea r9, [rsp]
    mov r10, [rsp + 32]
    call rest_do
    mov r12, rax
    mov rdi, [rsp + 24]
    call pool_put
    lea rdi, [rsp]
    call sb_free
    mov rdi, [rsp + 32]
    CALLC curl_slist_free_all
    mov rax, r12
    LEAVE_RET
.nohandle:
    mov rdi, [rsp + 32]
    CALLC curl_slist_free_all
.fail:
    xor eax, eax
    LEAVE_RET

; void build_path(sbuf *sb, const char *chan, const char *msg /*or NULL*/, const char *suffix /*or NULL*/)
global build_path
build_path:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rdi, rbx
    lea rsi, [rel p_channels]
    call sb_appends
    mov rdi, rbx
    mov rsi, r12
    call sb_appends
    test r13, r13
    jz .nomsg
    mov rdi, rbx
    lea rsi, [rel p_msg_slash]
    call sb_appends
    mov rdi, rbx
    mov rsi, r13
    call sb_appends
.nomsg:
    test r14, r14
    jz .d
    mov rdi, rbx
    mov rsi, r14
    call sb_appends
.d:
    LEAVE_RET

; ---------------------------------------------------------------------
; long casm_request(int method, const char *path, const char *body, size_t body_len,
;                   char **resp, size_t *resp_len)
; method: 0 GET, 1 POST, 2 PUT, 3 PATCH, 4 DELETE.  path is relative to the API
; base (e.g. "/channels/123/messages").  Returns the HTTP status, 0 when the
; transfer failed, -1 for bad arguments.  When resp is non-NULL the response
; body (NUL terminated) is stored there and must be released with casm_free.
; ---------------------------------------------------------------------
global casm_request
casm_request:
    ENTER 48                        ; [0] resp sbuf, [24] handle, [32] resp**, [40] resp_len*
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov [rsp + 32], r8
    mov [rsp + 40], r9
    test r13, r13
    jz .bad
    cmp byte [r13], '/'
    jne .bad
    test r14, r14
    jnz .hasbody
    lea r14, [rel s_empty]
    xor r15d, r15d
.hasbody:
    call pool_get
    test rax, rax
    jz .netfail
    mov [rsp + 24], rax
    lea rdi, [rsp]
    call sb_init
    mov rdi, [rsp + 24]
    mov esi, r12d
    mov rdx, r13
    mov rcx, r14
    mov r8, r15
    lea r9, [rsp]
    xor r10d, r10d
    call rest_do
    mov r12, rax
    mov rdi, [rsp + 24]
    call pool_put
    mov rax, [rsp + 32]
    test rax, rax
    jz .drop
    mov rcx, [rsp]
    mov [rax], rcx
    mov rax, [rsp + 40]
    test rax, rax
    jz .ret
    mov rcx, [rsp + 8]
    mov [rax], rcx
    jmp .ret
.drop:
    lea rdi, [rsp]
    call sb_free
.ret:
    mov rax, r12
    LEAVE_RET
.bad:
    mov r12, -1
    jmp .outnull
.netfail:
    xor r12d, r12d
.outnull:
    mov rax, [rsp + 32]
    test rax, rax
    jz .z
    mov qword [rax], 0
.z:
    mov rax, [rsp + 40]
    test rax, rax
    jz .z2
    mov qword [rax], 0
.z2:
    mov rax, r12
    LEAVE_RET

; void casm_free(void *p)   releases a response returned by casm_request
global casm_free
casm_free:
    jmp free wrt ..plt

; ---------------------------------------------------------------------
; long send_esc(const char *chan, const char *ep, size_t el, const char *reply)
; posts already JSON-escaped text; reply may be NULL
; ---------------------------------------------------------------------
send_esc:
    ENTER 64                        ; [0] path, [24] body
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp + 24]
    call sb_init
    lea rdi, [rsp]
    mov rsi, r12
    xor edx, edx
    lea rcx, [rel p_messages]
    call build_path
    lea rdi, [rsp + 24]
    lea rsi, [rel j_content]
    call sb_appends
    lea rdi, [rsp + 24]
    mov rsi, r13
    mov rdx, r14
    call sb_append
    test r15, r15
    jz .noref
    lea rdi, [rsp + 24]
    lea rsi, [rel j_ref]
    call sb_appends
    lea rdi, [rsp + 24]
    mov rsi, r15
    call sb_appends
    lea rsi, [rel j_refend]
    jmp .tail
.noref:
    lea rsi, [rel j_noref]
.tail:
    lea rdi, [rsp + 24]
    call sb_appends
    mov edi, 1
    lea rsi, [rsp]
    lea rdx, [rsp + 24]
    call do_call
    mov r12, rax
    lea rdi, [rsp]
    call sb_free
    lea rdi, [rsp + 24]
    call sb_free
    mov rax, r12
    LEAVE_RET

; ---------------------------------------------------------------------
; long casm_send(const char *channel_id, const char *text, size_t len, const char *reply_to)
; one message (the caller keeps it within Discord's 2000 character limit).
; reply_to may be NULL. Returns the HTTP status, 0 on transport failure,
; -1 for invalid arguments.
; ---------------------------------------------------------------------
global casm_send
casm_send:
    ENTER 32                        ; [0] escaped text
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rdi, r12
    call valid_id
    test eax, eax
    jz .bad
    test r15, r15
    jz .ok1
    mov rdi, r15
    call valid_id
    test eax, eax
    jz .bad
.ok1:
    test r13, r13
    jnz .ok2
    test r14, r14
    jnz .bad
.ok2:
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp]
    mov rsi, r13
    mov rdx, r14
    call sb_append_json_esc
    mov rdi, r12
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    mov rcx, r15
    call send_esc
    mov r12, rax
    lea rdi, [rsp]
    call sb_free
    mov rax, r12
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; ---------------------------------------------------------------------
; long casm_send_long(const char *channel_id, const char *text, size_t len, const char *reply_to)
; splits text into parts of at most 1900 bytes (preferring line breaks, never
; inside an escape / UTF-8 sequence) and sends each. Only the first part
; replies to reply_to. Returns the first non-2xx status if any part failed,
; else the status of the last part; -1 for invalid arguments or empty text.
; ---------------------------------------------------------------------
global casm_send_long
casm_send_long:
    ENTER 48                        ; [0] escaped, [24] first failure, [32] last status, [40] part size
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rdi, r12
    call valid_id
    test eax, eax
    jz .bad
    test r15, r15
    jz .ok1
    mov rdi, r15
    call valid_id
    test eax, eax
    jz .bad
.ok1:
    test r14, r14
    jz .bad
    test r13, r13
    jz .bad
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp]
    mov rsi, r13
    mov rdx, r14
    call sb_append_json_esc
    mov qword [rsp + 24], 0
    mov qword [rsp + 32], -1
    mov rbx, [rsp]                  ; cursor
    mov r14, [rsp + 8]              ; bytes left
.loop:
    test r14, r14
    jz .done
    mov rdi, rbx
    mov rsi, r14
    mov edx, 1900
    call chunk_next
    mov [rsp + 40], rax
    mov rdi, rbx
    mov rsi, rax
    call trim_span
    test rdx, rdx
    jz .skip
    mov rsi, rax
    mov rdi, r12
    mov rcx, r15
    call send_esc
    mov [rsp + 32], rax
    cmp rax, 200
    jb .failed
    cmp rax, 299
    ja .failed
    jmp .sent
.failed:
    cmp qword [rsp + 24], 0
    jne .sent
    mov [rsp + 24], rax
.sent:
    xor r15d, r15d
.skip:
    mov rax, [rsp + 40]
    add rbx, rax
    sub r14, rax
    jmp .loop
.done:
    mov r12, [rsp + 24]
    test r12, r12
    jnz .free
    mov r12, [rsp + 32]
.free:
    lea rdi, [rsp]
    call sb_free
    mov rax, r12
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; ---------------------------------------------------------------------
; long casm_edit(const char *channel_id, const char *message_id, const char *text, size_t len)
; ---------------------------------------------------------------------
global casm_edit
casm_edit:
    ENTER 72                        ; [0] path, [24] body, [48] escaped
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rdi, r12
    call valid_id
    test eax, eax
    jz .bad
    mov rdi, r13
    call valid_id
    test eax, eax
    jz .bad
    test r14, r14
    jnz .ok
    test r15, r15
    jnz .bad
.ok:
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp + 24]
    call sb_init
    lea rdi, [rsp]
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    call build_path
    lea rdi, [rsp + 24]
    lea rsi, [rel j_content]
    call sb_appends
    lea rdi, [rsp + 24]
    mov rsi, r14
    mov rdx, r15
    call sb_append_json_esc
    lea rdi, [rsp + 24]
    lea rsi, [rel j_edit_tail]
    call sb_appends
    mov edi, 3
    lea rsi, [rsp]
    lea rdx, [rsp + 24]
    call do_call
    mov r12, rax
    lea rdi, [rsp]
    call sb_free
    lea rdi, [rsp + 24]
    call sb_free
    mov rax, r12
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; ---------------------------------------------------------------------
; shared tail for the body-less calls:
;   long simple_call(long method, const char *chan, const char *msg, const char *suffix,
;                    const char *emoji)
; ---------------------------------------------------------------------
simple_call:
    ENTER 32                        ; [0] path
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rbx, r8
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp]
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    call build_path
    test rbx, rbx
    jz .go
    lea rdi, [rsp]
    lea rsi, [rel p_react]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, rbx
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rel p_me]
    call sb_appends
.go:
    mov rdi, r12
    lea rsi, [rsp]
    xor edx, edx
    call do_call
    mov r12, rax
    lea rdi, [rsp]
    call sb_free
    mov rax, r12
    LEAVE_RET

; long casm_typing(const char *channel_id)   shows "typing..." (POST, 204)
global casm_typing
casm_typing:
    ENTER 0
    mov r12, rdi
    call valid_id
    test eax, eax
    jz .bad
    mov edi, 1
    mov rsi, r12
    xor edx, edx
    lea rcx, [rel p_typing]
    xor r8d, r8d
    call simple_call
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; long casm_delete(const char *channel_id, const char *message_id)
global casm_delete
casm_delete:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    call valid_id
    test eax, eax
    jz .bad
    mov rdi, r13
    call valid_id
    test eax, eax
    jz .bad
    mov edi, 4
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    xor r8d, r8d
    call simple_call
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; long casm_react(const char *channel_id, const char *message_id, const char *emoji)
; emoji must already be URL-encoded (e.g. "%F0%9F%91%8D", or "name:id" for custom ones)
global casm_react
casm_react:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    call valid_id
    test eax, eax
    jz .bad
    mov rdi, r13
    call valid_id
    test eax, eax
    jz .bad
    mov rdi, r14
    call valid_emoji
    test eax, eax
    jz .bad
    mov edi, 2
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    mov r8, r14
    call simple_call
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

section .note.GNU-stack noalloc noexec nowrite progbits
