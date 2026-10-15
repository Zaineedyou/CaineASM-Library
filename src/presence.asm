; =====================================================================
; presence.asm - bot status / activity (Gateway "Update Presence", opcode 3,
; and the `presence` field of Identify). casm_set_presence may be called from
; any thread; the gateway thread does the sending (the WebSocket is only ever
; touched by that thread). Discord allows 5 presence updates per 20 seconds, so
; updates go out at least 4 seconds apart and the latest one wins.
; =====================================================================
%include "defs.inc"

extern malloc, free, strcmp, pthread_mutex_lock, pthread_mutex_unlock
extern sb_init, sb_free, sb_append, sb_appends, sb_putc, sb_append_u64, sb_append_json_esc
extern c_strlen, ws_send_text

section .bss
alignb 8
pr_mutex:    resb 40
pr_json:     resq 1                 ; malloc'd {"since":null,"activities":[...],"status":"..","afk":false}
pr_len:      resq 1
pr_pending:  resq 1
pr_last:     resq 1

section .rodata
st_online:   db "online", 0
st_idle:     db "idle", 0
st_dnd:      db "dnd", 0
st_invis:    db "invisible", 0
st_off:      db "offline", 0
j_p1:        db '{"since":null,"activities":[', 0
j_p2:        db '],"status":"', 0
j_p3:        db '","afk":false}', 0
j_a1:        db '{"name":', 0
j_a2:        db ',"type":', 0
j_a3:        db ',"url":', 0
j_cust:      db '{"name":"Custom Status","type":4,"state":', 0
j_end:       db '}', 0
c_q:         db '"', 0
j_op3:       db '{"op":3,"d":', 0
j_pres:      db ',"presence":', 0

section .text

; void p_esc(sbuf *sb, const char *s)   "escaped"
p_esc:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    lea rsi, [rel c_q]
    call sb_appends
    mov rdi, r12
    call c_strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call sb_append_json_esc
    mov rdi, rbx
    lea rsi, [rel c_q]
    call sb_appends
    LEAVE_RET

; int casm_set_presence(const char *status, int activity_type, const char *text, const char *url)
; status: "online" (NULL = online), "idle", "dnd", "invisible", "offline".
; activity_type: -1 none, 0 playing, 1 streaming (url optional), 2 listening, 3 watching,
;                4 custom (text is the status line), 5 competing.
; Returns 0, or -1 for an unknown status / type or a missing text.
global casm_set_presence
casm_set_presence:
    ENTER 40                         ; [0] sbuf
    mov r12, rdi
    mov r13d, esi
    mov r14, rdx
    mov r15, rcx
    test r12, r12
    jnz .have
    lea r12, [rel st_online]
.have:
    mov rdi, r12
    lea rsi, [rel st_online]
    CALLC strcmp
    test eax, eax
    jz .stok
    mov rdi, r12
    lea rsi, [rel st_idle]
    CALLC strcmp
    test eax, eax
    jz .stok
    mov rdi, r12
    lea rsi, [rel st_dnd]
    CALLC strcmp
    test eax, eax
    jz .stok
    mov rdi, r12
    lea rsi, [rel st_invis]
    CALLC strcmp
    test eax, eax
    jz .stok
    mov rdi, r12
    lea rsi, [rel st_off]
    CALLC strcmp
    test eax, eax
    jnz .bad
.stok:
    movsxd r13, r13d
    cmp r13, -1
    jl .bad
    cmp r13, 5
    jg .bad
    cmp r13, 0
    jl .build
    test r14, r14
    jz .bad
.build:
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp]
    lea rsi, [rel j_p1]
    call sb_appends
    cmp r13, 0
    jl .close
    cmp r13, 4
    jne .normal
    lea rdi, [rsp]
    lea rsi, [rel j_cust]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, r14
    call p_esc
    jmp .actend
.normal:
    lea rdi, [rsp]
    lea rsi, [rel j_a1]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, r14
    call p_esc
    lea rdi, [rsp]
    lea rsi, [rel j_a2]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, r13
    call sb_append_u64
    cmp r13, 1
    jne .actend
    test r15, r15
    jz .actend
    lea rdi, [rsp]
    lea rsi, [rel j_a3]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, r15
    call p_esc
.actend:
    lea rdi, [rsp]
    lea rsi, [rel j_end]
    call sb_appends
.close:
    lea rdi, [rsp]
    lea rsi, [rel j_p2]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, r12
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rel j_p3]
    call sb_appends
    lea rdi, [rel pr_mutex]
    CALLC pthread_mutex_lock
    mov rbx, [rel pr_json]
    mov rax, [rsp + SB_DATA]
    mov [rel pr_json], rax
    mov rax, [rsp + SB_LEN]
    mov [rel pr_len], rax
    mov qword [rel pr_pending], 1
    lea rdi, [rel pr_mutex]
    CALLC pthread_mutex_unlock
    mov rdi, rbx
    CALLC free                       ; the previous one (free(NULL) is fine)
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; void pres_append_identify(sbuf *sb)   ,"presence":{...} when a presence was set
global pres_append_identify
pres_append_identify:
    ENTER 0
    mov rbx, rdi
    lea rdi, [rel pr_mutex]
    CALLC pthread_mutex_lock
    cmp qword [rel pr_json], 0
    je .u
    mov rdi, rbx
    lea rsi, [rel j_pres]
    call sb_appends
    mov rdi, rbx
    mov rsi, [rel pr_json]
    mov rdx, [rel pr_len]
    call sb_append
    mov qword [rel pr_pending], 0    ; Identify carries it
.u:
    lea rdi, [rel pr_mutex]
    CALLC pthread_mutex_unlock
    LEAVE_RET

; int pres_tick(unsigned long now_ms)   gateway thread: send a pending update when 4 s have passed
; returns 0, or the ws_send_text error
global pres_tick
pres_tick:
    ENTER 32                         ; [0] sbuf
    mov r12, rdi
    xor r13d, r13d
    lea rdi, [rel pr_mutex]
    CALLC pthread_mutex_lock
    cmp qword [rel pr_pending], 0
    je .u
    cmp qword [rel pr_json], 0
    je .u
    mov rax, r12
    sub rax, [rel pr_last]
    cmp rax, 4000
    jb .u
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp]
    lea rsi, [rel j_op3]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, [rel pr_json]
    mov rdx, [rel pr_len]
    call sb_append
    lea rdi, [rsp]
    lea rsi, [rel j_end]
    call sb_appends
    mov qword [rel pr_pending], 0
    mov [rel pr_last], r12
    mov r13d, 1
.u:
    lea rdi, [rel pr_mutex]
    CALLC pthread_mutex_unlock
    xor eax, eax
    test r13d, r13d
    jz .r
    mov rdi, [rsp + SB_DATA]
    mov rsi, [rsp + SB_LEN]
    call ws_send_text
    mov r12d, eax
    lea rdi, [rsp]
    call sb_free
    mov eax, r12d
.r:
    LEAVE_RET

section .note.GNU-stack noalloc noexec nowrite progbits
