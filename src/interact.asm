; =====================================================================
; interact.asm - slash commands / interactions:
;   responses (callback, followup, edit/delete original), command
;   registration, option helpers and casm_interaction_keep/release.
; Endpoints and bodies follow the Discord docs "Receiving and responding"
; and "Application commands" pages.
; =====================================================================
%include "defs.inc"

extern malloc, free, memcpy, memcmp
extern c_strlen, parse_u64
extern sb_init, sb_free, sb_append, sb_appends, sb_append_u64, sb_append_json_esc
extern json_get, json_arr_next
extern do_call, valid_id
extern g_app_id

; offsets inside casm_interaction (see include/caineasm.h)
%define I_ID     0
%define I_APP    16
%define I_TOK    32
%define I_RAW    176
%define I_SIZE   208

section .rodata
p_inter:     db "/interactions/", 0
p_cb:        db "/callback", 0
p_hooks:     db "/webhooks/", 0
p_orig:      db "/messages/@original", 0
p_apps:      db "/applications/", 0
p_guilds:    db "/guilds/", 0
p_cmds:      db "/commands", 0
p_slash:     db "/", 0
j_t4:        db '{"type":4,"data":', 0
j_t5:        db '{"type":5', 0
j_t5d:       db ',"data":{"flags":', 0
j_typ:       db '{"type":', 0
j_data:      db ',"data":', 0
j_cont:      db '{"content":"', 0
j_flags:     db ',"flags":', 0
j_am:        db ',"allowed_mentions":{"parse":["users"]}}', 0
k_name:      db "name", 0
k_value:     db "value", 0
k_type:      db "type", 0
k_options:   db "options", 0

section .text

; ---------------------------------------------------------------------
; int span_id(const char *p, size_t n)   1 for 1..20 ASCII digits
; ---------------------------------------------------------------------
span_id:
    test rdi, rdi
    jz .bad
    test rsi, rsi
    jz .bad
    cmp rsi, 20
    ja .bad
    xor ecx, ecx
.l:
    movzx eax, byte [rdi + rcx]
    sub eax, '0'
    cmp eax, 9
    ja .bad
    inc rcx
    cmp rcx, rsi
    jb .l
    mov eax, 1
    ret
.bad:
    xor eax, eax
    ret

; int span_tok(const char *p, size_t n)   1 for 1..512 chars of [A-Za-z0-9_.-]
span_tok:
    test rdi, rdi
    jz .bad
    test rsi, rsi
    jz .bad
    cmp rsi, 512
    ja .bad
    xor ecx, ecx
.l:
    movzx eax, byte [rdi + rcx]
    mov edx, eax
    sub edx, '0'
    cmp edx, 9
    jbe .ok
    mov edx, eax
    or edx, 32
    sub edx, 'a'
    cmp edx, 25
    jbe .ok
    cmp al, '_'
    je .ok
    cmp al, '-'
    je .ok
    cmp al, '.'
    je .ok
    jmp .bad
.ok:
    inc rcx
    cmp rcx, rsi
    jb .l
    mov eax, 1
    ret
.bad:
    xor eax, eax
    ret

; ---------------------------------------------------------------------
; long ix_path(sbuf *sb, const casm_interaction *i, long kind)
; kind 0: /interactions/{id}/{token}/callback
;      1: /webhooks/{application_id}/{token}
;      2: /webhooks/{application_id}/{token}/messages/@original
; returns 0, or -1 when a needed field is missing / has odd characters
; ---------------------------------------------------------------------
global ix_path
ix_path:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r12, r12
    jz .bad
    mov rdi, [r12 + I_TOK]
    mov rsi, [r12 + I_TOK + 8]
    call span_tok
    test eax, eax
    jz .bad
    test r13, r13
    jnz .hook
    mov rdi, [r12 + I_ID]
    mov rsi, [r12 + I_ID + 8]
    call span_id
    test eax, eax
    jz .bad
    mov rdi, rbx
    lea rsi, [rel p_inter]
    call sb_appends
    mov rdi, rbx
    mov rsi, [r12 + I_ID]
    mov rdx, [r12 + I_ID + 8]
    call sb_append
    jmp .tok
.hook:
    mov rdi, [r12 + I_APP]
    mov rsi, [r12 + I_APP + 8]
    call span_id
    test eax, eax
    jz .bad
    mov rdi, rbx
    lea rsi, [rel p_hooks]
    call sb_appends
    mov rdi, rbx
    mov rsi, [r12 + I_APP]
    mov rdx, [r12 + I_APP + 8]
    call sb_append
.tok:
    mov rdi, rbx
    lea rsi, [rel p_slash]
    call sb_appends
    mov rdi, rbx
    mov rsi, [r12 + I_TOK]
    mov rdx, [r12 + I_TOK + 8]
    call sb_append
    test r13, r13
    jnz .h2
    mov rdi, rbx
    lea rsi, [rel p_cb]
    call sb_appends
    jmp .ok
.h2:
    cmp r13, 2
    jne .ok
    mov rdi, rbx
    lea rsi, [rel p_orig]
    call sb_appends
.ok:
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; long ix_send(long method, const casm_interaction *i, long kind, sbuf *body /*or NULL*/)
global ix_send
ix_send:
    ENTER 32                        ; [0] path
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp]
    mov rsi, r13
    mov rdx, r14
    call ix_path
    test rax, rax
    jnz .bad
    mov rdi, r12
    lea rsi, [rsp]
    mov rdx, r15
    call do_call
    mov r12, rax
    lea rdi, [rsp]
    call sb_free
    mov rax, r12
    LEAVE_RET
.bad:
    lea rdi, [rsp]
    call sb_free
    mov rax, -1
    LEAVE_RET

; void content_obj(sbuf *sb, const char *text, size_t len, long flags)
; {"content":"<escaped>"[,"flags":F],"allowed_mentions":{"parse":["users"]}}
content_obj:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rdi, rbx
    lea rsi, [rel j_cont]
    call sb_appends
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_append_json_esc
    mov rdi, rbx
    mov esi, '"'
    call sb_putc_
    test r14, r14
    jz .nof
    mov rdi, rbx
    lea rsi, [rel j_flags]
    call sb_appends
    mov rdi, rbx
    mov rsi, r14
    call sb_append_u64
.nof:
    mov rdi, rbx
    lea rsi, [rel j_am]
    call sb_appends
    LEAVE_RET

extern sb_putc
sb_putc_:
    jmp sb_putc

; ---------------------------------------------------------------------
; long text_call(long mode, const casm_interaction *i, const char *text, size_t len, long flags)
;   mode = method | kind << 8 | wrap << 16   (wrap: body is {"type":4,"data":{...}})
; builds the content body and sends it
; ---------------------------------------------------------------------
text_call:
    ENTER 40                        ; [0] body
    mov r15, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rbx, r8
    test r13, r13
    jz .bad
    test r14, r14
    jz .bad
    test rbx, rbx
    js .bad
    lea rdi, [rsp]
    call sb_init
    test r15d, 0x10000
    jz .nowrap
    lea rdi, [rsp]
    lea rsi, [rel j_t4]
    call sb_appends
.nowrap:
    lea rdi, [rsp]
    mov rsi, r13
    mov rdx, r14
    mov rcx, rbx
    call content_obj
    test r15d, 0x10000
    jz .go
    lea rdi, [rsp]
    mov esi, '}'
    call sb_putc
.go:
    movzx edi, r15b
    mov rsi, r12
    mov rdx, r15
    shr rdx, 8
    and edx, 0xff
    lea rcx, [rsp]
    call ix_send
    mov r12, rax
    lea rdi, [rsp]
    call sb_free
    mov rax, r12
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; long casm_respond(const casm_interaction *i, const char *text, size_t len, long flags)
; first response (callback type 4). flags: 64 = ephemeral. 204 on success.
global casm_respond
casm_respond:
    mov r8, rcx
    mov rcx, rdx
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 1 | (0 << 8) | 0x10000
    jmp text_call

; long casm_followup(const casm_interaction *i, const char *text, size_t len, long flags)
; POST /webhooks/{app}/{token}. 200 on success.
global casm_followup
casm_followup:
    mov r8, rcx
    mov rcx, rdx
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 1 | (1 << 8)
    jmp text_call

; long casm_edit_response(const casm_interaction *i, const char *text, size_t len)
; PATCH .../messages/@original. 200 on success.
global casm_edit_response
casm_edit_response:
    mov rcx, rdx
    mov rdx, rsi
    mov rsi, rdi
    xor r8d, r8d
    mov edi, 3 | (2 << 8)
    jmp text_call

; long casm_delete_response(const casm_interaction *i)   DELETE .../messages/@original, 204
global casm_delete_response
casm_delete_response:
    mov rsi, rdi
    mov edi, 4
    mov edx, 2
    xor ecx, ecx
    jmp ix_send

; long casm_defer(const casm_interaction *i, long flags)
; callback type 5 (DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE): shows "thinking...", then
; use casm_followup / casm_edit_response. flags 64 makes the later message ephemeral.
global casm_defer
casm_defer:
    ENTER 40                        ; [0] body
    mov r12, rdi
    mov r13, rsi
    test r13, r13
    js .bad
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp]
    lea rsi, [rel j_t5]
    call sb_appends
    test r13, r13
    jz .close
    lea rdi, [rsp]
    lea rsi, [rel j_t5d]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, r13
    call sb_append_u64
    lea rdi, [rsp]
    mov esi, '}'
    call sb_putc
.close:
    lea rdi, [rsp]
    mov esi, '}'
    call sb_putc
    mov edi, 1
    mov rsi, r12
    xor edx, edx
    lea rcx, [rsp]
    call ix_send
    mov r12, rax
    lea rdi, [rsp]
    call sb_free
    mov rax, r12
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; long casm_interaction_response(const casm_interaction *i, long type,
;                                const char *data_json, size_t data_len)
; any callback type (1..99); data_json is a raw JSON object (or NULL). 204 on success.
global casm_interaction_response
casm_interaction_response:
    ENTER 40                        ; [0] body
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    cmp r13, 1
    jl .bad
    cmp r13, 99
    jg .bad
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp]
    lea rsi, [rel j_typ]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, r13
    call sb_append_u64
    test r14, r14
    jz .close
    test r15, r15
    jz .close
    lea rdi, [rsp]
    lea rsi, [rel j_data]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, r14
    mov rdx, r15
    call sb_append
.close:
    lea rdi, [rsp]
    mov esi, '}'
    call sb_putc
    mov edi, 1
    mov rsi, r12
    xor edx, edx
    lea rcx, [rsp]
    call ix_send
    mov r12, rax
    lea rdi, [rsp]
    call sb_free
    mov rax, r12
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; ---------------------------------------------------------------------
; long reg_commands(const char *guild_id /*or NULL*/, const char *json, size_t len)
; PUT /applications/{app}/commands  or  /applications/{app}/guilds/{guild}/commands
; ---------------------------------------------------------------------
reg_commands:
    ENTER 56                        ; [0] path, [24] body
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    test r13, r13
    jz .bad
    test r14, r14
    jz .bad
    cmp byte [rel g_app_id], 0
    je .bad
    test r12, r12
    jz .ok
    mov rdi, r12
    call valid_id
    test eax, eax
    jz .bad
.ok:
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp + 24]
    call sb_init
    lea rdi, [rsp]
    lea rsi, [rel p_apps]
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rel g_app_id]
    call sb_appends
    test r12, r12
    jz .tail
    lea rdi, [rsp]
    lea rsi, [rel p_guilds]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, r12
    call sb_appends
.tail:
    lea rdi, [rsp]
    lea rsi, [rel p_cmds]
    call sb_appends
    lea rdi, [rsp + 24]
    mov rsi, r13
    mov rdx, r14
    call sb_append
    mov edi, 2
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

; long casm_register_commands(const char *json, size_t len)
; replaces the application's global commands with the JSON array (bulk overwrite). 200 on success.
global casm_register_commands
casm_register_commands:
    mov rdx, rsi
    mov rsi, rdi
    xor edi, edi
    jmp reg_commands

; long casm_register_guild_commands(const char *guild_id, const char *json, size_t len)
global casm_register_guild_commands
casm_register_guild_commands:
    test rdi, rdi
    jz .bad
    jmp reg_commands
.bad:
    mov rax, -1
    ret

; ---------------------------------------------------------------------
; option helpers
; ---------------------------------------------------------------------
; int casm_option_in(const casm_str *options, const char *name, casm_str *value)
; looks `name` up in a command options array. Returns the value's JSON type:
; 's' string (escaped slice), 'd' number, 'b' bool; 0 when not found / has no value.
global casm_option_in
casm_option_in:
    ENTER 80                        ; [0] elem, [24] name, [48] value, [72] name length
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    test r12, r12
    jz .no
    test r13, r13
    jz .no
    mov rax, [r12]
    test rax, rax
    jz .no
    mov rdi, r13
    call c_strlen
    mov [rsp + 72], rax
    mov rax, [r12]
    lea r15, [rax + 1]
    add rax, [r12 + 8]
    mov rbx, rax
.loop:
    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rsp]
    call json_arr_next
    test rax, rax
    jz .no
    mov r15, rax
    cmp qword [rsp + 16], 'o'
    jne .loop
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rel k_name]
    lea rcx, [rsp + 24]
    mov qword [rsp + 24 + 16], 0
    call json_get
    test eax, eax
    jz .loop
    cmp qword [rsp + 24 + 16], 's'
    jne .loop
    mov rax, [rsp + 72]
    cmp [rsp + 24 + 8], rax
    jne .loop
    mov rdi, [rsp + 24]
    mov rsi, r13
    mov rdx, rax
    CALLC memcmp
    test eax, eax
    jnz .loop
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rel k_value]
    lea rcx, [rsp + 48]
    mov qword [rsp + 48 + 16], 0
    call json_get
    test eax, eax
    jz .no
    test r14, r14
    jz .ret
    mov rax, [rsp + 48]
    mov [r14], rax
    mov rax, [rsp + 56]
    mov [r14 + 8], rax
.ret:
    mov rax, [rsp + 48 + 16]
    LEAVE_RET
.no:
    test r14, r14
    jz .z
    mov qword [r14], 0
    mov qword [r14 + 8], 0
.z:
    xor eax, eax
    LEAVE_RET

; int casm_option(const casm_interaction *i, const char *name, casm_str *value)
global casm_option
casm_option:
    test rdi, rdi
    jz .no
    add rdi, 160                    ; &i->options
    jmp casm_option_in
.no:
    test rdx, rdx
    jz .z
    mov qword [rdx], 0
    mov qword [rdx + 8], 0
.z:
    xor eax, eax
    ret

; int casm_subcommand(const casm_str *options, casm_str *name, casm_str *sub_options)
; first option that is a subcommand (1) or subcommand group (2): returns that type and
; fills its name and its own options array (ptr NULL when it has none); 0 when none.
global casm_subcommand
casm_subcommand:
    ENTER 88                        ; [0] elem, [24] tmp jv, [48] type jv(unused), [72] pad
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    test r13, r13
    jz .o1
    mov qword [r13], 0
    mov qword [r13 + 8], 0
.o1:
    test r14, r14
    jz .o2
    mov qword [r14], 0
    mov qword [r14 + 8], 0
.o2:
    test r12, r12
    jz .no
    mov rax, [r12]
    test rax, rax
    jz .no
    lea r15, [rax + 1]
    add rax, [r12 + 8]
    mov rbx, rax
.loop:
    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rsp]
    call json_arr_next
    test rax, rax
    jz .no
    mov r15, rax
    cmp qword [rsp + 16], 'o'
    jne .loop
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rel k_type]
    lea rcx, [rsp + 24]
    mov qword [rsp + 24 + 16], 0
    call json_get
    test eax, eax
    jz .loop
    cmp qword [rsp + 24 + 16], 'd'
    jne .loop
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    call parse_u64
    cmp rax, 1
    je .found
    cmp rax, 2
    jne .loop
.found:
    mov [rsp + 72], rax
    test r13, r13
    jz .nonm
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rel k_name]
    lea rcx, [rsp + 24]
    mov qword [rsp + 24 + 16], 0
    call json_get
    test eax, eax
    jz .nonm
    cmp qword [rsp + 24 + 16], 's'
    jne .nonm
    mov rax, [rsp + 24]
    mov [r13], rax
    mov rax, [rsp + 32]
    mov [r13 + 8], rax
.nonm:
    test r14, r14
    jz .done
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rel k_options]
    lea rcx, [rsp + 24]
    mov qword [rsp + 24 + 16], 0
    call json_get
    test eax, eax
    jz .done
    cmp qword [rsp + 24 + 16], 'a'
    jne .done
    mov rax, [rsp + 24]
    mov [r14], rax
    mov rax, [rsp + 32]
    mov [r14 + 8], rax
.done:
    mov rax, [rsp + 72]
    LEAVE_RET
.no:
    xor eax, eax
    LEAVE_RET

; ---------------------------------------------------------------------
; casm_interaction *casm_interaction_keep(const casm_interaction *i)
; heap copy that stays valid after the callback returns (for worker threads);
; free with casm_interaction_release. NULL on failure.
; ---------------------------------------------------------------------
global casm_interaction_keep
casm_interaction_keep:
    ENTER 0
    mov r12, rdi
    test r12, r12
    jz .null
    mov r13, I_SIZE
    add r13, [r12 + I_RAW + 8]
    xor ebx, ebx
.p1:
    mov rax, [r12 + rbx*8]
    test rax, rax
    jz .p1n
    mov rcx, [r12 + I_RAW]
    test rcx, rcx
    jz .p1add
    sub rax, rcx
    cmp rax, [r12 + I_RAW + 8]
    jb .p1n
.p1add:
    add r13, [r12 + rbx*8 + 8]
.p1n:
    add rbx, 2
    cmp rbx, 22                     ; 11 slices (all except raw)
    jb .p1
    lea rdi, [r13 + 1]
    CALLC malloc
    test rax, rax
    jz .null
    mov r14, rax
    mov rdi, r14
    mov rsi, r12
    mov edx, I_SIZE
    CALLC memcpy
    lea r15, [r14 + I_SIZE]
    mov rsi, [r12 + I_RAW]
    test rsi, rsi
    jz .p2s
    mov rdi, r15
    mov rdx, [r12 + I_RAW + 8]
    CALLC memcpy
    mov [r14 + I_RAW], r15
    add r15, [r12 + I_RAW + 8]
.p2s:
    xor ebx, ebx
.p2:
    mov rax, [r12 + rbx*8]
    test rax, rax
    jz .p2n
    mov rcx, [r12 + I_RAW]
    test rcx, rcx
    jz .p2copy
    mov rdx, rax
    sub rdx, rcx
    cmp rdx, [r12 + I_RAW + 8]
    jae .p2copy
    add rdx, [r14 + I_RAW]
    mov [r14 + rbx*8], rdx
    jmp .p2n
.p2copy:
    mov rdi, r15
    mov rsi, rax
    mov rdx, [r12 + rbx*8 + 8]
    CALLC memcpy
    mov [r14 + rbx*8], r15
    add r15, [r12 + rbx*8 + 8]
.p2n:
    add rbx, 2
    cmp rbx, 22
    jb .p2
    mov rax, r14
    LEAVE_RET
.null:
    xor eax, eax
    LEAVE_RET

; void casm_interaction_release(casm_interaction *p)
global casm_interaction_release
casm_interaction_release:
    jmp free wrt ..plt

section .note.GNU-stack noalloc noexec nowrite progbits
