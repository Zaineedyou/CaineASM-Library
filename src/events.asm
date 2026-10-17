; =====================================================================
; events.asm - parsed gateway events beyond MESSAGE_CREATE / INTERACTION_CREATE,
; plus casm_json_get. Payload fields follow the Discord docs, "Gateway Events":
;   MESSAGE_UPDATE          message object (same shape as casm_message; fields can be absent)
;   MESSAGE_DELETE          id, channel_id, guild_id?
;   MESSAGE_REACTION_ADD    user_id, channel_id, message_id, guild_id?, emoji{id,name}, message_author_id?, burst
;   MESSAGE_REACTION_REMOVE user_id, channel_id, message_id, guild_id?, emoji{id,name}, burst
;   GUILD_MEMBER_ADD        guild member object + guild_id (user, nick, ...)
;   GUILD_MEMBER_REMOVE     guild_id, user
; The callbacks run on the gateway thread; slices follow the casm_message rules.
; =====================================================================
%include "defs.inc"

extern fill_slice, fill_bool, json_path

section .bss
alignb 8
global g_cb_msgupd, g_cb_msgupd_user, g_cb_msgdel, g_cb_msgdel_user
global g_cb_react, g_cb_react_user, g_cb_member, g_cb_member_user
g_cb_msgupd:       resq 1
g_cb_msgupd_user:  resq 1
g_cb_msgdel:       resq 1
g_cb_msgdel_user:  resq 1
g_cb_react:        resq 1
g_cb_react_user:   resq 1
g_cb_member:       resq 1
g_cb_member_user:  resq 1

section .rodata
p_id:        db "id", 0
p_chan:      db "channel_id", 0
p_guild:     db "guild_id", 0
p_user:      db "user_id", 0
p_msg:       db "message_id", 0
p_ename:     db "emoji.name", 0
p_eid:       db "emoji.id", 0
p_mauthor:   db "message_author_id", 0
p_burst:     db "burst", 0
p_uid:       db "user.id", 0
p_uname:     db "user.username", 0
p_nick:      db "nick", 0

section .text

global casm_on_message_update, casm_on_message_delete, casm_on_reaction, casm_on_member
casm_on_message_update:
    mov [rel g_cb_msgupd], rdi
    mov [rel g_cb_msgupd_user], rsi
    ret
casm_on_message_delete:
    mov [rel g_cb_msgdel], rdi
    mov [rel g_cb_msgdel_user], rsi
    ret
casm_on_reaction:
    mov [rel g_cb_react], rdi
    mov [rel g_cb_react_user], rsi
    ret
casm_on_member:
    mov [rel g_cb_member], rdi
    mov [rel g_cb_member_user], rsi
    ret

; EFILL offset, path label, json type   (r12 = d, r13 = len, tmp jv at [rsp + TMP])
%macro EFILL 3
    lea rdi, [rsp + %1]
    mov rsi, r12
    mov rdx, r13
    lea rcx, [rel %2]
    mov r8d, %3
    lea r9, [rsp + TMP]
    call fill_slice
%endmacro

; ---------------------------------------------------------------------
; struct casm_message_delete { casm_str id, channel_id, guild_id, raw; }
; ---------------------------------------------------------------------
%define TMP 64
global emit_msgdel
emit_msgdel:
    ENTER 96
    mov r12, rdi
    mov r13, rsi
    EFILL 0,  p_id,    's'
    EFILL 16, p_chan,  's'
    EFILL 32, p_guild, 's'
    mov [rsp + 48], r12
    mov [rsp + 56], r13
    lea rdi, [rsp]
    mov rsi, [rel g_cb_msgdel_user]
    call [rel g_cb_msgdel]
    LEAVE_RET
%undef TMP

; ---------------------------------------------------------------------
; struct casm_reaction { casm_str user_id, channel_id, message_id, guild_id, emoji_name,
;                        emoji_id, message_author_id, raw; long added, burst; }
; ---------------------------------------------------------------------
%define TMP 144
; void emit_react(const char *d, size_t len, long added)
emit_react:
    ENTER 176
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    EFILL 0,   p_user,    's'
    EFILL 16,  p_chan,    's'
    EFILL 32,  p_msg,     's'
    EFILL 48,  p_guild,   's'
    EFILL 64,  p_ename,   's'
    EFILL 80,  p_eid,     's'
    EFILL 96,  p_mauthor, 's'
    mov [rsp + 112], r12
    mov [rsp + 120], r13
    mov [rsp + 128], r14
    lea rdi, [rsp + 136]
    mov rsi, r12
    mov rdx, r13
    lea rcx, [rel p_burst]
    lea r8, [rsp + TMP]
    call fill_bool
    lea rdi, [rsp]
    mov rsi, [rel g_cb_react_user]
    call [rel g_cb_react]
    LEAVE_RET
%undef TMP

global emit_react_add, emit_react_remove
emit_react_add:
    mov edx, 1
    jmp emit_react
emit_react_remove:
    xor edx, edx
    jmp emit_react

; ---------------------------------------------------------------------
; struct casm_member_event { casm_str guild_id, user_id, user_name, nick, raw; long joined; }
; ---------------------------------------------------------------------
%define TMP 88
emit_member:
    ENTER 120
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    EFILL 0,  p_guild, 's'
    EFILL 16, p_uid,   's'
    EFILL 32, p_uname, 's'
    EFILL 48, p_nick,  's'
    mov [rsp + 64], r12
    mov [rsp + 72], r13
    mov [rsp + 80], r14
    lea rdi, [rsp]
    mov rsi, [rel g_cb_member_user]
    call [rel g_cb_member]
    LEAVE_RET
%undef TMP

global emit_member_add, emit_member_remove
emit_member_add:
    mov edx, 1
    jmp emit_member
emit_member_remove:
    xor edx, edx
    jmp emit_member

; ---------------------------------------------------------------------
; int casm_json_get(const casm_str *json, const char *path, casm_str *out)
; Dotted path into a JSON object text (for example &i->raw and
; "data.resolved.users.123.username"). Returns the JSON type of the value:
; 's' string (JSON-escaped slice without quotes), 'o', 'a', 'd', 'b', 'n'; 0 = not found.
; ---------------------------------------------------------------------
global casm_json_get
casm_json_get:
    ENTER 24                        ; [0] jv
    mov rbx, rdi
    mov r12, rdx
    test rbx, rbx
    jz .no
    test rsi, rsi
    jz .no
    mov rax, [rbx]
    test rax, rax
    jz .no
    mov qword [rsp + JV_TYPE], 0
    mov rdi, rax
    mov rdx, rsi
    mov rsi, [rbx + 8]
    lea rcx, [rsp]
    call json_path
    test eax, eax
    jz .no
    test r12, r12
    jz .t
    mov rax, [rsp + JV_PTR]
    mov [r12], rax
    mov rax, [rsp + JV_LEN]
    mov [r12 + 8], rax
.t:
    mov rax, [rsp + JV_TYPE]
    LEAVE_RET
.no:
    xor eax, eax
    LEAVE_RET

section .note.GNU-stack noalloc noexec nowrite progbits
