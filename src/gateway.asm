; =====================================================================
; gateway.asm - Discord Gateway v10 session loop
;   Hello -> Identify/Resume -> heartbeats -> dispatch, with reconnect
;   and resume handling per the Discord Gateway documentation.
; =====================================================================
%include "defs.inc"

extern getrandom
extern sb_init, sb_free, sb_reset, sb_append, sb_appends, sb_putc, sb_append_u64, sb_append_json_esc
extern json_get, json_path, json_true
extern ws_connect, ws_close, ws_poll_message, ws_send_text, ws_send_close, ws_msg, ws_close_code
extern g_cb_event, g_cb_event_user, g_cb_msg, g_cb_msg_user, g_intents
extern now_ms, sleep_ms, ieq, parse_u64, c_strlen, log_line, log_sb
extern g_discord_token, g_gateway_url, g_bot_id, g_stop

section .rodata
j_hb:        db '{"op":1,"d":', 0
j_null:      db "null", 0
j_close:     db "}", 0
j_id1:       db '{"op":2,"d":{"token":"', 0
j_id2:       db '","intents":', 0
j_id3:       db ',"properties":{"os":"linux","browser":"caineasm","device":"caineasm"}}}', 0
j_rs1:       db '{"op":6,"d":{"token":"', 0
j_rs2:       db '","session_id":"', 0
j_rs3:       db '","seq":', 0
j_rs4:       db "}}", 0
u_params:    db "/?v=10&encoding=json", 0
u_params2:   db "?v=10&encoding=json", 0
k_op:        db "op", 0
k_s:         db "s", 0
k_t:         db "t", 0
k_d:         db "d", 0
k_hbint:     db "d.heartbeat_interval", 0
k_sid:       db "session_id", 0
k_rurl:      db "resume_gateway_url", 0
k_uid:       db "user.id", 0
k_uname:     db "user.username", 0
m_id:        db "id", 0
m_chan:      db "channel_id", 0
m_guild:     db "guild_id", 0
m_aid:       db "author.id", 0
m_aname:     db "author.username", 0
m_abot:      db "author.bot", 0
m_nick:      db "member.nick", 0
m_content:   db "content", 0
m_attach:    db "attachments", 0
m_ment:      db "mentions", 0
m_refaid:    db "referenced_message.author.id", 0
m_everyone:  db "mention_everyone", 0
e_ready:     db "READY", 0
e_resumed:   db "RESUMED", 0
e_msg:       db "MESSAGE_CREATE", 0
l_online:    db "✅ Bot online: ", 0
l_resumed:   db "✅ Gateway session resumed", 0
l_connfail:  db "⚠️ Failed to connect to the Discord gateway, retrying...", 0
l_nohello:   db "⚠️ No HELLO from the gateway", 0
l_fatal:     db "❌ Gateway closed the connection and it cannot be resumed (check DISCORD_TOKEN and enabled intents, close code ", 0
l_fatal2:    db ")", 0
l_lost:      db "⚠️ Gateway connection lost, reconnecting...", 0
l_zombie:    db "⚠️ No heartbeat ACK, reconnecting...", 0

section .bss
alignb 8
g_seq:       resq 1
g_have_sess: resq 1
g_sess:      resb 128
g_resume:    resb 256
g_hb_int:    resq 1
g_next_hb:   resq 1
g_acked:     resq 1

section .text

; void copy_jv(char *dst, size_t max, const jv *v)   copy slice as cstr (truncating)
copy_jv:
    ENTER 0
    mov r12, rdi
    mov rax, [rdx + JV_LEN]
    lea rcx, [rsi - 1]
    cmp rax, rcx
    jbe .ok
    mov rax, rcx
.ok:
    mov r13, rax
    mov rsi, [rdx + JV_PTR]
    xor ecx, ecx
.l:
    cmp rcx, r13
    jae .d
    mov al, [rsi + rcx]
    mov [r12 + rcx], al
    inc rcx
    jmp .l
.d:
    mov byte [r12 + r13], 0
    LEAVE_RET

; int send_heartbeat(void)
send_heartbeat:
    ENTER 32
    lea rbx, [rsp]
    mov rdi, rbx
    call sb_init
    mov rdi, rbx
    lea rsi, [rel j_hb]
    call sb_appends
    mov rax, [rel g_seq]
    test rax, rax
    js .null
    mov rdi, rbx
    mov rsi, rax
    call sb_append_u64
    jmp .tail
.null:
    mov rdi, rbx
    lea rsi, [rel j_null]
    call sb_appends
.tail:
    mov rdi, rbx
    lea rsi, [rel j_close]
    call sb_appends
    mov rdi, [rbx + SB_DATA]
    mov rsi, [rbx + SB_LEN]
    call ws_send_text
    mov r12d, eax
    mov rdi, rbx
    call sb_free
    mov qword [rel g_acked], 0
    mov eax, r12d
    LEAVE_RET

; int send_identify_or_resume(void)
send_login:
    ENTER 32
    lea rbx, [rsp]
    mov rdi, rbx
    call sb_init
    cmp qword [rel g_have_sess], 0
    je .ident
    cmp qword [rel g_seq], 0
    jl .ident
    ; ---- Resume ----
    mov rdi, rbx
    lea rsi, [rel j_rs1]
    call sb_appends
    mov rdi, rbx
    mov rsi, [rel g_discord_token]
    call tok_esc
    mov rdi, rbx
    lea rsi, [rel j_rs2]
    call sb_appends
    mov rdi, rbx
    lea rsi, [rel g_sess]
    call sb_appends
    mov rdi, rbx
    lea rsi, [rel j_rs3]
    call sb_appends
    mov rdi, rbx
    mov rsi, [rel g_seq]
    call sb_append_u64
    mov rdi, rbx
    lea rsi, [rel j_rs4]
    call sb_appends
    jmp .send
.ident:
    mov rdi, rbx
    lea rsi, [rel j_id1]
    call sb_appends
    mov rdi, rbx
    mov rsi, [rel g_discord_token]
    call tok_esc
    mov rdi, rbx
    lea rsi, [rel j_id2]
    call sb_appends
    mov rdi, rbx
    mov rsi, [rel g_intents]
    call sb_append_u64
    mov rdi, rbx
    lea rsi, [rel j_id3]
    call sb_appends
.send:
    mov rdi, [rbx + SB_DATA]
    mov rsi, [rbx + SB_LEN]
    call ws_send_text
    mov r12d, eax
    mov rdi, rbx
    call sb_free
    mov eax, r12d
    LEAVE_RET

; void tok_esc(sbuf *sb, const char *token)  append the JSON-escaped token
tok_esc:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    call c_strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call sb_append_json_esc
    LEAVE_RET

; long rand_below(long n)
rand_below:
    ENTER 16
    mov r12, rdi
    mov qword [rsp], 0
    lea rdi, [rsp]
    mov esi, 8
    xor edx, edx
    CALLC getrandom
    mov rax, [rsp]
    xor edx, edx
    test r12, r12
    jz .z
    div r12
    mov rax, rdx
    LEAVE_RET
.z:
    xor eax, eax
    LEAVE_RET

; ---------------------------------------------------------------------
; user callbacks
; ---------------------------------------------------------------------
; void fill_slice(casm_str *dst, const char *obj, size_t len, const char *path,
;                 long want_type, jv *tmp)   NULL/0 when missing or another type
fill_slice:
    ENTER 0
    mov r12, rdi
    mov r13, r8
    mov rbx, r9
    mov qword [r12], 0
    mov qword [r12 + 8], 0
    mov qword [rbx + JV_TYPE], 0
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, rcx
    mov rcx, rbx
    call json_path
    test eax, eax
    jz .d
    cmp [rbx + JV_TYPE], r13
    jne .d
    mov rax, [rbx + JV_PTR]
    mov [r12], rax
    mov rax, [rbx + JV_LEN]
    mov [r12 + 8], rax
.d:
    LEAVE_RET

; void fill_bool(long *dst, const char *obj, size_t len, const char *path, jv *tmp)
fill_bool:
    ENTER 0
    mov r12, rdi
    mov rbx, r8
    mov qword [r12], 0
    mov qword [rbx + JV_TYPE], 0
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, rcx
    mov rcx, rbx
    call json_path
    test eax, eax
    jz .d
    mov rdi, rbx
    call json_true
    mov [r12], rax
.d:
    LEAVE_RET

%define M_ID      0
%define M_CHAN    16
%define M_GUILD   32
%define M_AID     48
%define M_ANAME   64
%define M_NICK    80
%define M_CONTENT 96
%define M_ATTACH  112
%define M_MENT    128
%define M_REFAID  144
%define M_RAW     160
%define M_ABOT    176
%define M_EVERY   184
%define M_TMP     192

%macro FILL 3                       ; offset, path label, json type
    lea rdi, [rsp + %1]
    mov rsi, r12
    mov rdx, r13
    lea rcx, [rel %2]
    mov r8d, %3
    lea r9, [rsp + M_TMP]
    call fill_slice
%endmacro

; void emit_message(const char *d, size_t len)   builds casm_message, calls the callback
emit_message:
    ENTER 224
    mov r12, rdi
    mov r13, rsi
    FILL M_ID,      m_id,      's'
    FILL M_CHAN,    m_chan,    's'
    FILL M_GUILD,   m_guild,   's'
    FILL M_AID,     m_aid,     's'
    FILL M_ANAME,   m_aname,   's'
    FILL M_NICK,    m_nick,    's'
    FILL M_CONTENT, m_content, 's'
    FILL M_ATTACH,  m_attach,  'a'
    FILL M_MENT,    m_ment,    'a'
    FILL M_REFAID,  m_refaid,  's'
    mov [rsp + M_RAW], r12
    mov [rsp + M_RAW + 8], r13
    lea rdi, [rsp + M_ABOT]
    mov rsi, r12
    mov rdx, r13
    lea rcx, [rel m_abot]
    lea r8, [rsp + M_TMP]
    call fill_bool
    lea rdi, [rsp + M_EVERY]
    mov rsi, r12
    mov rdx, r13
    lea rcx, [rel m_everyone]
    lea r8, [rsp + M_TMP]
    call fill_bool
    lea rdi, [rsp]
    mov rsi, [rel g_cb_msg_user]
    call [rel g_cb_msg]
    LEAVE_RET

; void emit_dispatch(const char *t, size_t tlen, const char *d, size_t dlen)
; event callback first (every dispatch), then the parsed MESSAGE_CREATE callback
emit_dispatch:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rax, [rel g_cb_event]
    test rax, rax
    jz .nev
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    mov r8, [rel g_cb_event_user]
    call rax
.nev:
    cmp qword [rel g_cb_msg], 0
    je .done
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel e_msg]
    call ieq
    test eax, eax
    jz .done
    mov rdi, r14
    mov rsi, r15
    call emit_message
.done:
    LEAVE_RET

; ---------------------------------------------------------------------
; int gw_dispatch(void)   handles ws_msg
;   0 keep going, 1 reconnect and resume, 2 reconnect with a fresh Identify
; ---------------------------------------------------------------------
%define X_OP   0
%define X_T    24
%define X_D    48
%define X_J1   72
%define X_SB   96
gw_dispatch:
    ENTER 128
    mov r12, [rel ws_msg + SB_DATA]
    mov r13, [rel ws_msg + SB_LEN]
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_op]
    lea rcx, [rsp + X_OP]
    call json_get
    test eax, eax
    jz .keep
    cmp qword [rsp + X_OP + JV_TYPE], 'd'
    jne .keep
    mov rdi, [rsp + X_OP + JV_PTR]
    mov rsi, [rsp + X_OP + JV_LEN]
    call parse_u64
    mov r14, rax                    ; opcode
    cmp r14, 0
    je .dispatch
    cmp r14, 1
    je .hbreq
    cmp r14, 7
    je .reconnect
    cmp r14, 9
    je .invalid
    cmp r14, 11
    je .ack
    jmp .keep

.ack:
    mov qword [rel g_acked], 1
    jmp .keep
.hbreq:
    call send_heartbeat
    jmp .keep
.reconnect:
    mov eax, 1
    LEAVE_RET
.invalid:
    ; d == true  -> session may be resumed; false -> start over
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_d]
    lea rcx, [rsp + X_D]
    mov qword [rsp + X_D + JV_TYPE], 0
    call json_get
    mov eax, 2
    cmp qword [rsp + X_D + JV_TYPE], 'b'
    jne .inv2
    mov rax, [rsp + X_D + JV_PTR]
    cmp byte [rax], 't'
    jne .inv2
    mov eax, 1
    LEAVE_RET
.inv2:
    mov qword [rel g_have_sess], 0
    mov eax, 2
    LEAVE_RET

.dispatch:
    ; sequence number
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_s]
    lea rcx, [rsp + X_J1]
    mov qword [rsp + X_J1 + JV_TYPE], 0
    call json_get
    cmp qword [rsp + X_J1 + JV_TYPE], 'd'
    jne .noseq
    mov rdi, [rsp + X_J1 + JV_PTR]
    mov rsi, [rsp + X_J1 + JV_LEN]
    call parse_u64
    mov [rel g_seq], rax
.noseq:
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_t]
    lea rcx, [rsp + X_T]
    mov qword [rsp + X_T + JV_TYPE], 0
    call json_get
    cmp qword [rsp + X_T + JV_TYPE], 's'
    jne .keep
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_d]
    lea rcx, [rsp + X_D]
    mov qword [rsp + X_D + JV_TYPE], 0
    call json_get
    cmp qword [rsp + X_D + JV_TYPE], 'o'
    jne .keep
    mov rdi, [rsp + X_T + JV_PTR]
    mov rsi, [rsp + X_T + JV_LEN]
    lea rdx, [rel e_ready]
    call ieq
    test eax, eax
    jz .notready
    ; session id
    mov rdi, [rsp + X_D + JV_PTR]
    mov rsi, [rsp + X_D + JV_LEN]
    lea rdx, [rel k_sid]
    lea rcx, [rsp + X_J1]
    mov qword [rsp + X_J1 + JV_TYPE], 0
    call json_get
    cmp qword [rsp + X_J1 + JV_TYPE], 's'
    jne .r2
    lea rdi, [rel g_sess]
    mov esi, 128
    lea rdx, [rsp + X_J1]
    call copy_jv
    mov qword [rel g_have_sess], 1
.r2:
    mov rdi, [rsp + X_D + JV_PTR]
    mov rsi, [rsp + X_D + JV_LEN]
    lea rdx, [rel k_rurl]
    lea rcx, [rsp + X_J1]
    mov qword [rsp + X_J1 + JV_TYPE], 0
    call json_get
    cmp qword [rsp + X_J1 + JV_TYPE], 's'
    jne .r3
    lea rdi, [rel g_resume]
    mov esi, 256
    lea rdx, [rsp + X_J1]
    call copy_jv
.r3:
    mov rdi, [rsp + X_D + JV_PTR]
    mov rsi, [rsp + X_D + JV_LEN]
    lea rdx, [rel k_uid]
    lea rcx, [rsp + X_J1]
    mov qword [rsp + X_J1 + JV_TYPE], 0
    call json_path
    cmp qword [rsp + X_J1 + JV_TYPE], 's'
    jne .r4
    lea rdi, [rel g_bot_id]
    mov esi, 32
    lea rdx, [rsp + X_J1]
    call copy_jv
.r4:
    lea rdi, [rsp + X_SB]
    call sb_init
    lea rdi, [rsp + X_SB]
    lea rsi, [rel l_online]
    call sb_appends
    mov rdi, [rsp + X_D + JV_PTR]
    mov rsi, [rsp + X_D + JV_LEN]
    lea rdx, [rel k_uname]
    lea rcx, [rsp + X_J1]
    mov qword [rsp + X_J1 + JV_TYPE], 0
    call json_path
    cmp qword [rsp + X_J1 + JV_TYPE], 's'
    jne .r5
    lea rdi, [rsp + X_SB]
    mov rsi, [rsp + X_J1 + JV_PTR]
    mov rdx, [rsp + X_J1 + JV_LEN]
    call sb_append
.r5:
    lea rdi, [rsp + X_SB]
    mov rdi, [rsp + X_SB + SB_DATA]
    call log_line
    lea rdi, [rsp + X_SB]
    call sb_free
    jmp .notify
.notready:
    mov rdi, [rsp + X_T + JV_PTR]
    mov rsi, [rsp + X_T + JV_LEN]
    lea rdx, [rel e_resumed]
    call ieq
    test eax, eax
    jz .notify
    lea rdi, [rel l_resumed]
    call log_line
.notify:
    mov rdi, [rsp + X_T + JV_PTR]
    mov rsi, [rsp + X_T + JV_LEN]
    mov rdx, [rsp + X_D + JV_PTR]
    mov rcx, [rsp + X_D + JV_LEN]
    call emit_dispatch
.keep:
    xor eax, eax
    LEAVE_RET

; ---------------------------------------------------------------------
; int gw_session(const char *url)
;   0 reconnect (resume ok), 1 reconnect (fresh identify), 2 fatal,
;   3 could not connect, 4 shutdown requested
; ---------------------------------------------------------------------
gw_session:
    ENTER 64
    mov rdi, rdi
    call ws_connect
    test eax, eax
    jz .connected
    lea rdi, [rel l_connfail]
    call log_line
    mov eax, 3
    LEAVE_RET
.connected:
    ; ---- wait for HELLO ----
    xor r12d, r12d
.hello:
    cmp qword [rel g_stop], 0
    jne .stop
    cmp r12d, 20
    jae .nohello
    inc r12d
    mov edi, 1000
    call ws_poll_message
    test eax, eax
    js .lost
    jz .hello
    ; got a message: must be op 10
    mov rdi, [rel ws_msg + SB_DATA]
    mov rsi, [rel ws_msg + SB_LEN]
    lea rdx, [rel k_hbint]
    lea rcx, [rsp]
    mov qword [rsp + JV_TYPE], 0
    call json_path
    cmp qword [rsp + JV_TYPE], 'd'
    jne .hello
    mov rdi, [rsp + JV_PTR]
    mov rsi, [rsp + JV_LEN]
    call parse_u64
    test rax, rax
    jz .hello
    mov [rel g_hb_int], rax
    mov rdi, rax
    call rand_below                 ; jitter for the first heartbeat
    mov r13, rax
    call now_ms
    add rax, r13
    mov [rel g_next_hb], rax
    mov qword [rel g_acked], 1
    call send_login
    test eax, eax
    jnz .lost
.loop:
    cmp qword [rel g_stop], 0
    jne .stop
    call now_ms
    mov r13, rax
    cmp r13, [rel g_next_hb]
    jl .wait
    ; time for a heartbeat; no ACK for the previous one => zombie connection
    cmp qword [rel g_acked], 0
    jne .sendhb
    lea rdi, [rel l_zombie]
    call log_line
    mov edi, 4000
    call ws_send_close
    call ws_close
    xor eax, eax
    LEAVE_RET
.sendhb:
    call send_heartbeat
    test eax, eax
    jnz .lost
    mov rax, r13
    add rax, [rel g_hb_int]
    mov [rel g_next_hb], rax
.wait:
    mov rax, [rel g_next_hb]
    sub rax, r13
    cmp rax, 1
    jge .t1
    mov eax, 1
.t1:
    cmp rax, 1000
    jle .t2
    mov eax, 1000
.t2:
    mov edi, eax
    call ws_poll_message
    test eax, eax
    js .lost
    jz .loop
    call gw_dispatch
    cmp eax, 1
    je .resume
    cmp eax, 2
    je .fresh
    jmp .loop

.resume:
    mov edi, 4000
    call ws_send_close
    call ws_close
    xor eax, eax
    LEAVE_RET
.fresh:
    mov edi, 4000
    call ws_send_close
    call ws_close
    mov eax, 1
    LEAVE_RET
.nohello:
    lea rdi, [rel l_nohello]
    call log_line
    call ws_close
    mov eax, 1
    LEAVE_RET
.stop:
    mov edi, 1000
    call ws_send_close
    call ws_close
    mov eax, 4
    LEAVE_RET
.lost:
    mov rbx, [rel ws_close_code]
    call ws_close
    ; close codes that forbid reconnecting (Discord opcodes & status codes)
    cmp rbx, 4004
    je .fatal
    cmp rbx, 4010
    jb .chk2
    cmp rbx, 4014
    jbe .fatal
.chk2:
    cmp rbx, 1000
    je .newsess
    cmp rbx, 1001
    je .newsess
    cmp rbx, 4007
    je .newsess
    cmp rbx, 4009
    je .newsess
    lea rdi, [rel l_lost]
    call log_line
    xor eax, eax
    LEAVE_RET
.newsess:
    mov qword [rel g_have_sess], 0
    lea rdi, [rel l_lost]
    call log_line
    mov eax, 1
    LEAVE_RET
.fatal:
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp]
    lea rsi, [rel l_fatal]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, rbx
    call sb_append_u64
    lea rdi, [rsp]
    lea rsi, [rel l_fatal2]
    call sb_appends
    lea rdi, [rsp]
    call log_sb
    mov eax, 2
    LEAVE_RET

; ---------------------------------------------------------------------
; int gateway_run(void)   blocks until shutdown (0) or a fatal close code (1)
; ---------------------------------------------------------------------
global gateway_run
gateway_run:
    ENTER 32                        ; [0] sbuf for the resume url
    mov qword [rel g_seq], -1
    mov r12d, 5000                  ; reconnect back-off after connect failures
.again:
    cmp qword [rel g_stop], 0
    jne .done
    mov rbx, [rel g_gateway_url]
    cmp qword [rel g_have_sess], 0
    je .go
    cmp byte [rel g_resume], 0
    je .go
    ; resume on the url Discord gave us (add the version/encoding query)
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp]
    lea rsi, [rel g_resume]
    call sb_appends
    lea rdi, [rel g_resume]
    call c_strlen
    lea rcx, [rel g_resume]
    lea rsi, [rel u_params]
    cmp byte [rcx + rax - 1], '/'
    jne .app
    lea rsi, [rel u_params2]
.app:
    lea rdi, [rsp]
    call sb_appends
    mov rbx, [rsp + SB_DATA]
    mov r13d, 1
    jmp .run
.go:
    xor r13d, r13d
.run:
    mov rdi, rbx
    call gw_session
    mov r14d, eax
    test r13d, r13d
    jz .afterrun
    lea rdi, [rsp]
    call sb_free
.afterrun:
    cmp r14d, 2
    je .fatalend
    cmp r14d, 4
    je .done
    cmp r14d, 3
    je .backoff
    mov r12d, 5000
    mov edi, 1000
    cmp r14d, 1
    jne .nap
    mov edi, 4000
    call rand_below
    lea edi, [rax + 1000]
.nap:
    call sleep_ms
    jmp .again
.backoff:
    mov edi, r12d
    call sleep_ms
    cmp r12d, 60000
    jae .again
    shl r12d, 1
    jmp .again
.done:
    xor eax, eax
    LEAVE_RET
.fatalend:
    mov eax, 1
    LEAVE_RET

section .note.GNU-stack noalloc noexec nowrite progbits
