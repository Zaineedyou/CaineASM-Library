; =====================================================================
; core.asm - CaineASM-Library public entry points: configuration, callbacks,
;            run/stop, logging.  One client per process.
; =====================================================================
%include "defs.inc"

extern malloc, free, strdup, write
extern sb_init, sb_free, sb_append, sb_putc, c_strlen
extern net_init, gateway_run
extern g_ca_file

section .rodata
s_default_api: db "https://discord.com/api/v10", 0
s_default_gw:  db "wss://gateway.discord.gg/?v=10&encoding=json", 0
s_default_ua:  db "DiscordBot (https://github.com/Zaineedyou/CaineASM-Library, 0.3.0)", 0
s_version:     db "0.3.0", 0

section .bss
alignb 8
global g_discord_token, g_gateway_url, g_api_base, g_user_agent
global g_bot_id, g_stop, g_intents, g_quiet
global g_cb_event, g_cb_event_user, g_cb_msg, g_cb_msg_user
global g_app_id, g_cb_inter, g_cb_inter_user, g_cb_log, g_cb_log_user
g_discord_token: resq 1
g_gateway_url:   resq 1
g_api_base:      resq 1
g_user_agent:    resq 1
g_bot_id:        resb 32
g_stop:          resq 1
g_intents:       resq 1
g_quiet:         resq 1
g_cb_event:      resq 1
g_cb_event_user: resq 1
g_cb_msg:        resq 1
g_cb_msg_user:   resq 1
g_cb_inter:      resq 1
g_cb_inter_user: resq 1
g_app_id:        resb 32
g_cb_log:        resq 1
g_cb_log_user:   resq 1

section .text

; ---------------------------------------------------------------------
; logging (stderr). silenced by casm_set_quiet(1)
; ---------------------------------------------------------------------
; void log_line(const char *s)
global log_line
log_line:
    ENTER 32
    mov r12, rdi
    cmp qword [rel g_cb_log], 0
    je .stderr
    call c_strlen                   ; a log callback gets every line, quiet or not
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rel g_cb_log_user]
    call [rel g_cb_log]
    jmp .d
.stderr:
    cmp qword [rel g_quiet], 0
    jne .d
    mov rdi, r12
    call c_strlen
    mov r13, rax
    lea rbx, [rsp]
    mov rdi, rbx
    call sb_init
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_append
    mov rdi, rbx
    mov esi, 10
    call sb_putc
    mov edi, STDERR
    mov rsi, [rbx]
    mov rdx, [rbx + 8]
    CALLC write
    mov rdi, rbx
    call sb_free
.d:
    LEAVE_RET

; void log_sb(sbuf *sb)   prints the buffer + newline and frees it
global log_sb
log_sb:
    ENTER 0
    mov rbx, rdi
    cmp qword [rel g_cb_log], 0
    je .stderr
    mov rdi, [rbx + SB_DATA]
    mov rsi, [rbx + SB_LEN]
    mov rdx, [rel g_cb_log_user]
    call [rel g_cb_log]
    jmp .free
.stderr:
    cmp qword [rel g_quiet], 0
    jne .free
    mov rdi, rbx
    mov esi, 10
    call sb_putc
    mov edi, STDERR
    mov rsi, [rbx + SB_DATA]
    mov rdx, [rbx + SB_LEN]
    CALLC write
.free:
    mov rdi, rbx
    call sb_free
    LEAVE_RET

; ---------------------------------------------------------------------
; static void set_str(const char **slot, const char *s, const char *dflt)
; stores a private copy; frees the previous copy unless it was the default
; ---------------------------------------------------------------------
set_str:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rdi, r13
    CALLC strdup
    test rax, rax
    jz .d
    mov rbx, [r12]
    mov [r12], rax
    test rbx, rbx
    jz .d
    cmp rbx, r14
    je .d
    mov rdi, rbx
    CALLC free
.d:
    LEAVE_RET

; ---------------------------------------------------------------------
; int casm_init(const char *token, unsigned long intents)   0 ok, -1 error
; ---------------------------------------------------------------------
global casm_init
casm_init:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    test r12, r12
    jz .fail
    cmp byte [r12], 0
    je .fail
    lea rdi, [rel g_discord_token]
    mov rsi, r12
    xor edx, edx
    call set_str
    cmp qword [rel g_discord_token], 0
    je .fail
    mov [rel g_intents], r13
    cmp qword [rel g_api_base], 0
    jne .a
    lea rax, [rel s_default_api]
    mov [rel g_api_base], rax
.a:
    cmp qword [rel g_gateway_url], 0
    jne .g
    lea rax, [rel s_default_gw]
    mov [rel g_gateway_url], rax
.g:
    cmp qword [rel g_user_agent], 0
    jne .u
    lea rax, [rel s_default_ua]
    mov [rel g_user_agent], rax
.u:
    mov rdi, [rel g_discord_token]
    call net_init
    test eax, eax
    jnz .fail
    xor eax, eax
    LEAVE_RET
.fail:
    mov eax, -1
    LEAVE_RET

; ---------------------------------------------------------------------
; setters (each copies the string)
; ---------------------------------------------------------------------
global casm_set_api_base
casm_set_api_base:
    mov rsi, rdi
    lea rdi, [rel g_api_base]
    lea rdx, [rel s_default_api]
    jmp set_str

global casm_set_gateway_url
casm_set_gateway_url:
    mov rsi, rdi
    lea rdi, [rel g_gateway_url]
    lea rdx, [rel s_default_gw]
    jmp set_str

global casm_set_user_agent
casm_set_user_agent:
    mov rsi, rdi
    lea rdi, [rel g_user_agent]
    lea rdx, [rel s_default_ua]
    jmp set_str

global casm_set_ca_file
casm_set_ca_file:
    mov rsi, rdi
    lea rdi, [rel g_ca_file]
    xor edx, edx
    jmp set_str

global casm_set_quiet
casm_set_quiet:
    movsxd rax, edi
    mov [rel g_quiet], rax
    ret

; void casm_set_log_callback(void (*cb)(const char *line, size_t len, void *user), void *user)
; the library's log lines (no trailing newline) go to cb instead of stderr; NULL = back to stderr
global casm_set_log_callback
casm_set_log_callback:
    mov [rel g_cb_log], rdi
    mov [rel g_cb_log_user], rsi
    ret

; const char *casm_version(void)
global casm_version
casm_version:
    lea rax, [rel s_version]
    ret

global casm_on_event
casm_on_event:
    mov [rel g_cb_event], rdi
    mov [rel g_cb_event_user], rsi
    ret

global casm_on_message
casm_on_message:
    mov [rel g_cb_msg], rdi
    mov [rel g_cb_msg_user], rsi
    ret

global casm_on_interaction
casm_on_interaction:
    mov [rel g_cb_inter], rdi
    mov [rel g_cb_inter_user], rsi
    ret

; const char *casm_app_id(void)   the application id, NULL before READY
global casm_app_id
casm_app_id:
    lea rax, [rel g_app_id]
    cmp byte [rax], 0
    jne .r
    xor eax, eax
.r:
    ret

; ---------------------------------------------------------------------
; int casm_run(void)   blocks. 0 = stopped by casm_stop, 1 = fatal
; (bad token / disallowed intents), -1 = casm_init was not called
; ---------------------------------------------------------------------
global casm_run
casm_run:
    ENTER 0
    cmp qword [rel g_discord_token], 0
    je .noinit
    call gateway_run
    LEAVE_RET
.noinit:
    mov eax, -1
    LEAVE_RET

; void casm_stop(void)   async-signal-safe
global casm_stop
casm_stop:
    mov qword [rel g_stop], 1
    ret

; const char *casm_bot_id(void)   the bot's user id, NULL before READY
global casm_bot_id
casm_bot_id:
    lea rax, [rel g_bot_id]
    cmp byte [rax], 0
    jne .r
    xor eax, eax
.r: ret

section .note.GNU-stack noalloc noexec nowrite progbits
