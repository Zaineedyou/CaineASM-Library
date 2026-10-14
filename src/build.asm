; =====================================================================
; build.asm - builders for embeds, buttons / select menus, modals and
; message payloads, plus the calls that send them, and readers for
; component / modal / autocomplete interactions.
; JSON shapes follow the Discord docs: Message resource (embed object,
; message create body), Components reference (action row, button,
; string select, label + text input) and Receiving and responding.
; Every builder handle is 80 bytes: three sbufs (a, b, c).
; =====================================================================
%include "defs.inc"

extern malloc, free, memcmp
extern c_strlen, parse_u64
extern sb_init, sb_free, sb_append, sb_appends, sb_putc, sb_append_u64, sb_append_json_esc
extern json_get, json_path, json_arr_next, json_true
extern do_call, valid_id, ix_send, build_path

%define H_A 0
%define H_B 24
%define H_C 48
%define H_SIZE 80
%define I_RAW 176
%define I_OPTS 160

section .rodata
c_k1:        db '":', 0
c_ob:        db '{', 0
c_cb:        db '}', 0
c_q:         db '"', 0
c_true:      db "true", 0
c_false:     db "false", 0
p_chan:      db "/channels/", 0
p_msgs:      db "/messages", 0
p_msgs1:     db "/messages/", 0
j_fields:    db '"fields":[', 0
j_embeds:    db '"embeds":[', 0
j_comps:     db '"components":[', 0
j_opts:      db ',"options":[', 0
j_mcomps:    db ',"components":[', 0
j_ref:       db '"message_reference":{"message_id":"', 0
j_refend:    db '","fail_if_not_exists":false},"allowed_mentions":{"parse":["users"],"replied_user":true}}', 0
j_amend:     db '"allowed_mentions":{"parse":["users"]}}', 0
j_wrap4:     db '{"type":', 0
j_wrapdata:  db ',"data":', 0
j_btn:       db '{"type":2,"style":', 0
j_lbl:       db ',"label":', 0
j_cid:       db ',"custom_id":', 0
j_url:       db ',"url":', 0
j_dis:       db ',"disabled":true', 0
j_opt:       db '{"label":', 0
j_val:       db ',"value":', 0
j_desc:      db ',"description":', 0
j_def:       db ',"default":true', 0
j_label:     db '{"type":18,"label":', 0
j_comp:      db ',"component":{"type":4,"custom_id":', 0
j_style:     db ',"style":', 0
j_ph:        db ',"placeholder":', 0
j_minl:      db ',"min_length":', 0
j_maxl:      db ',"max_length":', 0
j_req:       db ',"required":', 0
j_close2:    db '}}', 0
j_ac:        db '{"type":8,"data":{"choices":[', 0
j_ac_n:      db '{"name":', 0
j_ac_end:    db ']}}', 0
k_type:      db "type", 0
k_custom:    db "custom_id", 0
k_title:     db "title", 0
k_min:       db "min_values", 0
k_max:       db "max_values", 0
k_value:     db "value", 0
k_values:    db "values", 0
k_component: db "component", 0
k_components:db "components", 0
k_options:   db "options", 0
k_focused:   db "focused", 0
k_name:      db "name", 0
k_dvalues:   db "data.values", 0
k_dcomps:    db "data.components", 0
k_dopts:     db "data.options", 0

section .text

; ---------------------------------------------------------------------
; JSON writing primitives (sbufs hold comma separated members without the outer braces)
; ---------------------------------------------------------------------
; void j_sep(sbuf *sb)   ',' unless empty or right after { or [
j_sep:
    mov rcx, [rdi + SB_LEN]
    test rcx, rcx
    jz .r
    mov rax, [rdi + SB_DATA]
    movzx eax, byte [rax + rcx - 1]
    cmp al, '{'
    je .r
    cmp al, '['
    je .r
    mov esi, ','
    jmp sb_putc
.r:
    ret

; void j_esc(sbuf *sb, const char *s)   "escaped"
j_esc:
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

; void j_escn(sbuf *sb, const char *s, size_t n)
j_escn:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    lea rsi, [rel c_q]
    call sb_appends
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_append_json_esc
    mov rdi, rbx
    lea rsi, [rel c_q]
    call sb_appends
    LEAVE_RET

; void j_key(sbuf *sb, const char *key)   [,]"key":
j_key:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    call j_sep
    mov rdi, rbx
    lea rsi, [rel c_q]
    call sb_appends
    mov rdi, rbx
    mov rsi, r12
    call sb_appends
    mov rdi, rbx
    lea rsi, [rel c_k1]
    call sb_appends
    LEAVE_RET

; int js(sbuf *sb, const char *key, const char *s)
js:
    ENTER 0
    mov rbx, rdi
    mov r12, rdx
    call j_key
    mov rdi, rbx
    mov rsi, r12
    call j_esc
    xor eax, eax
    LEAVE_RET

; int jn(sbuf *sb, const char *key, unsigned long n)
jn:
    ENTER 0
    mov rbx, rdi
    mov r12, rdx
    call j_key
    mov rdi, rbx
    mov rsi, r12
    call sb_append_u64
    xor eax, eax
    LEAVE_RET

; int jobj(sbuf *sb, const char *key, const char *subkey, const char *s)  "key":{"subkey":"s"}
jobj:
    ENTER 0
    mov rbx, rdi
    mov r12, rdx
    mov r13, rcx
    call j_key
    mov rdi, rbx
    lea rsi, [rel c_ob]
    call sb_appends
    mov rdi, rbx
    lea rsi, [rel c_q]
    call sb_appends
    mov rdi, rbx
    mov rsi, r12
    call sb_appends
    mov rdi, rbx
    lea rsi, [rel c_k1]
    call sb_appends
    mov rdi, rbx
    mov rsi, r13
    call j_esc
    mov rdi, rbx
    lea rsi, [rel c_cb]
    call sb_appends
    xor eax, eax
    LEAVE_RET

; void jbool(sbuf *sb, long v)   true / false
jbool:
    test rsi, rsi
    lea rsi, [rel c_true]
    lea rax, [rel c_false]
    cmovz rsi, rax
    jmp sb_appends

; ---------------------------------------------------------------------
; handles
; ---------------------------------------------------------------------
; void *bnew(void)
bnew:
    ENTER 0
    mov edi, H_SIZE
    CALLC malloc
    test rax, rax
    jz .d
    mov rbx, rax
    lea rdi, [rbx + H_A]
    call sb_init
    lea rdi, [rbx + H_B]
    call sb_init
    lea rdi, [rbx + H_C]
    call sb_init
    mov rax, rbx
.d:
    LEAVE_RET

; void casm_builder_free(void *h)   frees any builder (embed, row, select, modal, reply)
global casm_builder_free
casm_builder_free:
    ENTER 0
    mov rbx, rdi
    test rbx, rbx
    jz .d
    lea rdi, [rbx + H_A]
    call sb_free
    lea rdi, [rbx + H_B]
    call sb_free
    lea rdi, [rbx + H_C]
    call sb_free
    mov rdi, rbx
    CALLC free
.d:
    LEAVE_RET

; STRSET name, "key": int name(h, const char *s) -> "key":"s" into h->a
%macro STRSET 2
section .rodata
%%k: db %2, 0
section .text
global %1
%1:
    test rdi, rdi
    jz bad_ret
    test rsi, rsi
    jz bad_ret
    mov rdx, rsi
    lea rsi, [rel %%k]
    jmp js
%endmacro

; OBJSET name, "key", "subkey": int name(h, const char *s) -> "key":{"subkey":"s"}
%macro OBJSET 3
section .rodata
%%k: db %2, 0
%%s: db %3, 0
section .text
global %1
%1:
    test rdi, rdi
    jz bad_ret
    test rsi, rsi
    jz bad_ret
    mov rcx, rsi
    lea rsi, [rel %%k]
    lea rdx, [rel %%s]
    jmp jobj
%endmacro

bad_ret:
    mov rax, -1
    ret

; ---------------------------------------------------------------------
; embeds (a = members, b = fields)
; ---------------------------------------------------------------------
global casm_embed_new
casm_embed_new:
    jmp bnew

STRSET casm_embed_title,       "title"
STRSET casm_embed_description, "description"
STRSET casm_embed_url,         "url"
STRSET casm_embed_timestamp,   "timestamp"       ; ISO8601, e.g. 2026-10-13T11:00:00Z
OBJSET casm_embed_footer,      "footer",    "text"
OBJSET casm_embed_author,      "author",    "name"
OBJSET casm_embed_image,       "image",     "url"
OBJSET casm_embed_thumbnail,   "thumbnail", "url"

; int casm_embed_color(embed *e, unsigned long rgb)   e.g. 0x5865F2
section .rodata
k_color: db "color", 0
section .text
global casm_embed_color
casm_embed_color:
    test rdi, rdi
    jz bad_ret
    cmp rsi, 0xFFFFFF
    ja bad_ret
    mov rdx, rsi
    lea rsi, [rel k_color]
    jmp jn

; int casm_embed_field(embed *e, const char *name, const char *value, int inline_)
global casm_embed_field
casm_embed_field:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    test rbx, rbx
    jz .bad
    test r12, r12
    jz .bad
    test r13, r13
    jz .bad
    lea rdi, [rbx + H_B]
    call j_sep
    lea rdi, [rbx + H_B]
    lea rsi, [rel j_ac_n]
    call sb_appends
    lea rdi, [rbx + H_B]
    mov rsi, r12
    call j_esc
    lea rdi, [rbx + H_B]
    lea rsi, [rel j_val]
    call sb_appends
    lea rdi, [rbx + H_B]
    mov rsi, r13
    call j_esc
    test r14, r14
    jz .close
    lea rdi, [rbx + H_B]
    lea rsi, [rel j_inline]
    call sb_appends
.close:
    lea rdi, [rbx + H_B]
    lea rsi, [rel c_cb]
    call sb_appends
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET
section .rodata
j_inline: db ',"inline":true', 0
section .text

; void embed_json(embed *e, sbuf *out)
embed_json:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rel c_ob]
    call sb_appends
    mov rdi, r12
    mov rsi, [rbx + H_A + SB_DATA]
    mov rdx, [rbx + H_A + SB_LEN]
    call sb_append
    cmp qword [rbx + H_B + SB_LEN], 0
    je .end
    mov rdi, r12
    call j_sep
    mov rdi, r12
    lea rsi, [rel j_fields]
    call sb_appends
    mov rdi, r12
    mov rsi, [rbx + H_B + SB_DATA]
    mov rdx, [rbx + H_B + SB_LEN]
    call sb_append
    mov rdi, r12
    mov esi, ']'
    call sb_putc
.end:
    mov rdi, r12
    lea rsi, [rel c_cb]
    call sb_appends
    LEAVE_RET

; ---------------------------------------------------------------------
; action rows, buttons (a = components)
; ---------------------------------------------------------------------
global casm_row_new
casm_row_new:
    jmp bnew

; int casm_row_button(row *r, int style, const char *label, const char *id_or_url, int disabled)
; style 1 primary, 2 secondary, 3 success, 4 danger (id_or_url = custom_id), 5 link (= url)
global casm_row_button
casm_row_button:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    test rbx, rbx
    jz .bad
    cmp r12, 1
    jl .bad
    cmp r12, 5
    jg .bad
    test r13, r13
    jz .bad
    test r14, r14
    jz .bad
    lea rdi, [rbx + H_A]
    call j_sep
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_btn]
    call sb_appends
    lea rdi, [rbx + H_A]
    mov rsi, r12
    call sb_append_u64
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_lbl]
    call sb_appends
    lea rdi, [rbx + H_A]
    mov rsi, r13
    call j_esc
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_cid]
    lea rax, [rel j_url]
    cmp r12, 5
    cmove rsi, rax
    call sb_appends
    lea rdi, [rbx + H_A]
    mov rsi, r14
    call j_esc
    test r15, r15
    jz .close
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_dis]
    call sb_appends
.close:
    lea rdi, [rbx + H_A]
    lea rsi, [rel c_cb]
    call sb_appends
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; int casm_row_select(row *r, select *s)   a row holds one select (or up to 5 buttons)
global casm_row_select
casm_row_select:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    test rbx, rbx
    jz .bad
    test r12, r12
    jz .bad
    lea rdi, [rbx + H_A]
    call j_sep
    mov rdi, r12
    lea rsi, [rbx + H_A]
    call select_json
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; void row_json(row *r, sbuf *out)
row_json:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rel j_row1]
    call sb_appends
    mov rdi, r12
    mov rsi, [rbx + H_A + SB_DATA]
    mov rdx, [rbx + H_A + SB_LEN]
    call sb_append
    mov rdi, r12
    lea rsi, [rel j_close_arr]
    call sb_appends
    LEAVE_RET
section .rodata
j_row1:      db '{"type":1,"components":[', 0
j_close_arr: db ']}', 0
section .text

; ---------------------------------------------------------------------
; string select menus (b = header members, a = options)
; ---------------------------------------------------------------------
; select *casm_select_new(const char *custom_id, const char *placeholder /*or NULL*/,
;                         long min_values /*<0 = default*/, long max_values /*<=0 = default*/)
global casm_select_new
casm_select_new:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    test r12, r12
    jz .null
    call bnew
    test rax, rax
    jz .null
    mov rbx, rax
    lea rdi, [rbx + H_B]
    lea rsi, [rel k_type]
    mov edx, 3
    call jn
    lea rdi, [rbx + H_B]
    lea rsi, [rel k_custom]
    mov rdx, r12
    call js
    test r13, r13
    jz .nph
    lea rdi, [rbx + H_B]
    lea rsi, [rel k_placeholder]
    mov rdx, r13
    call js
.nph:
    test r14, r14
    js .nmin
    lea rdi, [rbx + H_B]
    lea rsi, [rel k_min]
    mov rdx, r14
    call jn
.nmin:
    test r15, r15
    jle .nmax
    lea rdi, [rbx + H_B]
    lea rsi, [rel k_max]
    mov rdx, r15
    call jn
.nmax:
    mov rax, rbx
    LEAVE_RET
.null:
    xor eax, eax
    LEAVE_RET
section .rodata
k_placeholder: db "placeholder", 0
section .text

; int casm_select_option(select *s, const char *label, const char *value,
;                        const char *description /*or NULL*/, int is_default)
global casm_select_option
casm_select_option:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    test rbx, rbx
    jz .bad
    test r12, r12
    jz .bad
    test r13, r13
    jz .bad
    lea rdi, [rbx + H_A]
    call j_sep
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_opt]
    call sb_appends
    lea rdi, [rbx + H_A]
    mov rsi, r12
    call j_esc
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_val]
    call sb_appends
    lea rdi, [rbx + H_A]
    mov rsi, r13
    call j_esc
    test r14, r14
    jz .nd
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_desc]
    call sb_appends
    lea rdi, [rbx + H_A]
    mov rsi, r14
    call j_esc
.nd:
    test r15, r15
    jz .close
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_def]
    call sb_appends
.close:
    lea rdi, [rbx + H_A]
    lea rsi, [rel c_cb]
    call sb_appends
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; void select_json(select *s, sbuf *out)
select_json:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rel c_ob]
    call sb_appends
    mov rdi, r12
    mov rsi, [rbx + H_B + SB_DATA]
    mov rdx, [rbx + H_B + SB_LEN]
    call sb_append
    mov rdi, r12
    lea rsi, [rel j_opts]
    call sb_appends
    mov rdi, r12
    mov rsi, [rbx + H_A + SB_DATA]
    mov rdx, [rbx + H_A + SB_LEN]
    call sb_append
    mov rdi, r12
    lea rsi, [rel j_close_arr]
    call sb_appends
    LEAVE_RET

; ---------------------------------------------------------------------
; modals (b = header, a = labelled inputs)
; ---------------------------------------------------------------------
; modal *casm_modal_new(const char *custom_id, const char *title)
global casm_modal_new
casm_modal_new:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    test r12, r12
    jz .null
    test r13, r13
    jz .null
    call bnew
    test rax, rax
    jz .null
    mov rbx, rax
    lea rdi, [rbx + H_B]
    lea rsi, [rel k_custom]
    mov rdx, r12
    call js
    lea rdi, [rbx + H_B]
    lea rsi, [rel k_title]
    mov rdx, r13
    call js
    mov rax, rbx
    LEAVE_RET
.null:
    xor eax, eax
    LEAVE_RET

; int casm_modal_input(modal *m, const char *custom_id, const char *label, int paragraph,
;                      const char *placeholder /*or NULL*/, long min_length /*0 = none*/,
;                      long max_length /*0 = none*/, int required)
; a text input wrapped in a Label (type 18), as the current docs require. max 5 per modal.
global casm_modal_input
casm_modal_input:
    ENTER 0
    sub rsp, 16                      ; keeps the two stack arguments reachable below
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    test rbx, rbx
    jz .bad
    test r12, r12
    jz .bad
    test r13, r13
    jz .bad
    mov rax, r9                      ; min_length
    mov [rsp], rax
    mov rax, [rbp + 16]              ; max_length
    mov [rsp + 8], rax
    test rax, rax
    js .bad
    cmp qword [rsp], 0
    jl .bad
    lea rdi, [rbx + H_A]
    call j_sep
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_label]
    call sb_appends
    lea rdi, [rbx + H_A]
    mov rsi, r13
    call j_esc
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_comp]
    call sb_appends
    lea rdi, [rbx + H_A]
    mov rsi, r12
    call j_esc
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_style]
    call sb_appends
    mov esi, 1
    mov edx, 2
    test r14, r14
    cmovnz rsi, rdx
    lea rdi, [rbx + H_A]
    call sb_append_u64
    test r15, r15
    jz .nph
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_ph]
    call sb_appends
    lea rdi, [rbx + H_A]
    mov rsi, r15
    call j_esc
.nph:
    cmp qword [rsp], 0
    je .nmin
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_minl]
    call sb_appends
    lea rdi, [rbx + H_A]
    mov rsi, [rsp]
    call sb_append_u64
.nmin:
    cmp qword [rsp + 8], 0
    je .nmax
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_maxl]
    call sb_appends
    lea rdi, [rbx + H_A]
    mov rsi, [rsp + 8]
    call sb_append_u64
.nmax:
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_req]
    call sb_appends
    lea rdi, [rbx + H_A]
    mov rsi, [rbp + 24]              ; required
    call jbool
    lea rdi, [rbx + H_A]
    lea rsi, [rel j_close2]
    call sb_appends
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; void modal_json(modal *m, sbuf *out)
modal_json:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rel c_ob]
    call sb_appends
    mov rdi, r12
    mov rsi, [rbx + H_B + SB_DATA]
    mov rdx, [rbx + H_B + SB_LEN]
    call sb_append
    mov rdi, r12
    lea rsi, [rel j_mcomps]
    call sb_appends
    mov rdi, r12
    mov rsi, [rbx + H_A + SB_DATA]
    mov rdx, [rbx + H_A + SB_LEN]
    call sb_append
    mov rdi, r12
    lea rsi, [rel j_close_arr]
    call sb_appends
    LEAVE_RET

; ---------------------------------------------------------------------
; message payloads (a = content/flags members, b = embeds, c = rows)
; ---------------------------------------------------------------------
global casm_reply_new
casm_reply_new:
    jmp bnew

; int casm_reply_content(reply *r, const char *text, size_t len)   raw UTF-8, escaped for you
global casm_reply_content
casm_reply_content:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test rbx, rbx
    jz .bad
    test r12, r12
    jnz .ok
    test r13, r13
    jnz .bad
.ok:
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_content]
    call j_key
    lea rdi, [rbx + H_A]
    mov rsi, r12
    mov rdx, r13
    call j_escn
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET
section .rodata
k_content: db "content", 0
k_flags:   db "flags", 0
section .text

; int casm_reply_flags(reply *r, long flags)   e.g. CASM_MSG_EPHEMERAL
global casm_reply_flags
casm_reply_flags:
    test rdi, rdi
    jz bad_ret
    test rsi, rsi
    js bad_ret
    mov rdx, rsi
    lea rsi, [rel k_flags]
    jmp jn

; int casm_reply_embed(reply *r, embed *e)   up to 10
global casm_reply_embed
casm_reply_embed:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    test rbx, rbx
    jz .bad
    test r12, r12
    jz .bad
    lea rdi, [rbx + H_B]
    call j_sep
    mov rdi, r12
    lea rsi, [rbx + H_B]
    call embed_json
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; int casm_reply_row(reply *r, row *w)   up to 5
global casm_reply_row
casm_reply_row:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    test rbx, rbx
    jz .bad
    test r12, r12
    jz .bad
    lea rdi, [rbx + H_C]
    call j_sep
    mov rdi, r12
    lea rsi, [rbx + H_C]
    call row_json
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; void reply_finish(reply *r, sbuf *out, const char *reply_to /*or NULL*/)
reply_finish:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    lea rsi, [rel c_ob]
    call sb_appends
    mov rdi, r12
    mov rsi, [rbx + H_A + SB_DATA]
    mov rdx, [rbx + H_A + SB_LEN]
    call sb_append
    cmp qword [rbx + H_B + SB_LEN], 0
    je .norow1
    mov rdi, r12
    call j_sep
    mov rdi, r12
    lea rsi, [rel j_embeds]
    call sb_appends
    mov rdi, r12
    mov rsi, [rbx + H_B + SB_DATA]
    mov rdx, [rbx + H_B + SB_LEN]
    call sb_append
    mov rdi, r12
    mov esi, ']'
    call sb_putc
.norow1:
    cmp qword [rbx + H_C + SB_LEN], 0
    je .noc
    mov rdi, r12
    call j_sep
    mov rdi, r12
    lea rsi, [rel j_comps]
    call sb_appends
    mov rdi, r12
    mov rsi, [rbx + H_C + SB_DATA]
    mov rdx, [rbx + H_C + SB_LEN]
    call sb_append
    mov rdi, r12
    mov esi, ']'
    call sb_putc
.noc:
    mov rdi, r12
    call j_sep
    test r13, r13
    jz .noref
    mov rdi, r12
    lea rsi, [rel j_ref]
    call sb_appends
    mov rdi, r12
    mov rsi, r13
    call sb_appends
    mov rdi, r12
    lea rsi, [rel j_refend]
    call sb_appends
    LEAVE_RET
.noref:
    mov rdi, r12
    lea rsi, [rel j_amend]
    call sb_appends
    LEAVE_RET

; ---------------------------------------------------------------------
; sending
; ---------------------------------------------------------------------
; long chan_send(long method, const char *chan, const char *msg /*or NULL*/, reply *r, const char *reply_to)
chan_send:
    ENTER 56                         ; [0] path, [24] body
    mov r15, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rbx, r8
    test r14, r14
    jz .bad
    mov rdi, r12
    call valid_id
    test eax, eax
    jz .bad
    test r13, r13
    jz .nomsg
    mov rdi, r13
    call valid_id
    test eax, eax
    jz .bad
.nomsg:
    test rbx, rbx
    jz .ok
    mov rdi, rbx
    call valid_id
    test eax, eax
    jz .bad
.ok:
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp + 24]
    call sb_init
    lea rdi, [rsp]
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    lea rax, [rel p_msgs]
    test r13, r13
    cmovz rcx, rax
    call build_path
    mov rdi, r14
    lea rsi, [rsp + 24]
    mov rdx, rbx
    call reply_finish
    mov rdi, r15
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

; long casm_send_reply(const char *channel_id, reply *r, const char *reply_to /*or NULL*/)
global casm_send_reply
casm_send_reply:
    mov r8, rdx
    mov rcx, rsi
    xor edx, edx
    mov rsi, rdi
    mov edi, 1
    jmp chan_send

; long casm_edit_message(const char *channel_id, const char *message_id, reply *r)
global casm_edit_message
casm_edit_message:
    test rsi, rsi
    jz bad_ret
    mov rcx, rdx
    mov rdx, rsi
    mov rsi, rdi
    xor r8d, r8d
    mov edi, 3
    jmp chan_send

; long ix_reply(long method, i, long kind, long wrap_type /*0 = none*/, reply *r)
ix_reply:
    ENTER 40                         ; [0] body
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rbx, r8
    test rbx, rbx
    jz .bad
    lea rdi, [rsp]
    call sb_init
    test r15, r15
    jz .nowrap
    lea rdi, [rsp]
    lea rsi, [rel j_wrap4]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, r15
    call sb_append_u64
    lea rdi, [rsp]
    lea rsi, [rel j_wrapdata]
    call sb_appends
.nowrap:
    mov rdi, rbx
    lea rsi, [rsp]
    xor edx, edx
    call reply_finish
    test r15, r15
    jz .go
    lea rdi, [rsp]
    lea rsi, [rel c_cb]
    call sb_appends
.go:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
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

; long casm_respond_reply(i, reply *r)        first response with embeds / buttons (type 4)
global casm_respond_reply
casm_respond_reply:
    mov r8, rsi
    mov rsi, rdi
    mov edi, 1
    xor edx, edx
    mov ecx, 4
    jmp ix_reply

; long casm_update_reply(i, reply *r)         edit the message a button / select sits on (type 7)
global casm_update_reply
casm_update_reply:
    mov r8, rsi
    mov rsi, rdi
    mov edi, 1
    xor edx, edx
    mov ecx, 7
    jmp ix_reply

; long casm_followup_reply(i, reply *r)
global casm_followup_reply
casm_followup_reply:
    mov r8, rsi
    mov rsi, rdi
    mov edi, 1
    mov edx, 1
    xor ecx, ecx
    jmp ix_reply

; long casm_edit_response_reply(i, reply *r)
global casm_edit_response_reply
casm_edit_response_reply:
    mov r8, rsi
    mov rsi, rdi
    mov edi, 3
    mov edx, 2
    xor ecx, ecx
    jmp ix_reply

; long casm_show_modal(i, modal *m)           callback type 9
global casm_show_modal
casm_show_modal:
    ENTER 40                         ; [0] body
    mov r12, rdi
    mov r13, rsi
    test r13, r13
    jz .bad
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp]
    lea rsi, [rel j_wrap9]
    call sb_appends
    mov rdi, r13
    lea rsi, [rsp]
    call modal_json
    lea rdi, [rsp]
    lea rsi, [rel c_cb]
    call sb_appends
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
section .rodata
j_wrap9: db '{"type":9,"data":', 0
section .text

; long casm_autocomplete(i, const char *const *names, const char *const *values, size_t n)
; callback type 8 with up to 25 string choices
global casm_autocomplete
casm_autocomplete:
    ENTER 40                         ; [0] body
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    cmp r15, 25
    ja .bad
    test r15, r15
    jz .init
    test r13, r13
    jz .bad
    test r14, r14
    jz .bad
    xor ebx, ebx
.chk:
    cmp qword [r13 + rbx*8], 0
    je .bad
    cmp qword [r14 + rbx*8], 0
    je .bad
    inc rbx
    cmp rbx, r15
    jb .chk
.init:
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp]
    lea rsi, [rel j_ac]
    call sb_appends
    xor ebx, ebx
.l:
    cmp rbx, r15
    jae .end
    lea rdi, [rsp]
    call j_sep
    lea rdi, [rsp]
    lea rsi, [rel j_ac_n]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, [r13 + rbx*8]
    call j_esc
    lea rdi, [rsp]
    lea rsi, [rel j_val]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, [r14 + rbx*8]
    call j_esc
    lea rdi, [rsp]
    lea rsi, [rel c_cb]
    call sb_appends
    inc rbx
    jmp .l
.end:
    lea rdi, [rsp]
    lea rsi, [rel j_ac_end]
    call sb_appends
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
; readers
; ---------------------------------------------------------------------
; int casm_array_at(const casm_str *arr, size_t index, casm_str *out)
; element `index` of a JSON array slice. Returns its JSON type ('s','d','b','o','a','n') or 0.
global casm_array_at
casm_array_at:
    ENTER 32                         ; [0] jv
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    test r14, r14
    jz .nz
    mov qword [r14], 0
    mov qword [r14 + 8], 0
.nz:
    test r12, r12
    jz .no
    mov rax, [r12]
    test rax, rax
    jz .no
    lea r15, [rax + 1]
    add rax, [r12 + 8]
    mov rbx, rax
.l:
    mov rdi, r15
    mov rsi, rbx
    lea rdx, [rsp]
    call json_arr_next
    test rax, rax
    jz .no
    mov r15, rax
    test r13, r13
    jz .got
    dec r13
    jmp .l
.got:
    test r14, r14
    jz .ty
    mov rax, [rsp]
    mov [r14], rax
    mov rax, [rsp + 8]
    mov [r14 + 8], rax
.ty:
    mov rax, [rsp + 16]
    LEAVE_RET
.no:
    xor eax, eax
    LEAVE_RET

; int casm_select_values(const casm_interaction *i, casm_str *values)
; data.values of a select-menu interaction (a JSON array slice; use casm_array_at). 1 / 0.
global casm_select_values
casm_select_values:
    ENTER 32
    mov r12, rdi
    mov r13, rsi
    test r13, r13
    jz .no
    mov qword [r13], 0
    mov qword [r13 + 8], 0
    test r12, r12
    jz .no
    mov rdi, [r12 + I_RAW]
    mov rsi, [r12 + I_RAW + 8]
    lea rdx, [rel k_dvalues]
    lea rcx, [rsp]
    mov qword [rsp + 16], 0
    call json_path
    test eax, eax
    jz .no
    cmp qword [rsp + 16], 'a'
    jne .no
    mov rax, [rsp]
    mov [r13], rax
    mov rax, [rsp + 8]
    mov [r13 + 8], rax
    mov eax, 1
    LEAVE_RET
.no:
    xor eax, eax
    LEAVE_RET

; int find_cid(const char *p, size_t n, const char *cid, size_t cl, jv *out)
; searches nested components for custom_id == cid; out = its "value" (or "values")
find_cid:
    ENTER 80                         ; [0] elem, [24] tmp, [48] tmp2
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rbx, r8
    test r12, r12
    jz .no
    test r13, r13
    jz .no
    cmp byte [r12], '['
    je .arr
    cmp byte [r12], '{'
    jne .no
    ; ---- object ----
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_custom]
    lea rcx, [rsp + 24]
    mov qword [rsp + 24 + 16], 0
    call json_get
    test eax, eax
    jz .children
    cmp qword [rsp + 24 + 16], 's'
    jne .children
    cmp [rsp + 24 + 8], r15
    jne .children
    mov rdi, [rsp + 24]
    mov rsi, r14
    mov rdx, r15
    CALLC memcmp
    test eax, eax
    jnz .children
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_value]
    mov rcx, rbx
    mov qword [rbx + 16], 0
    call json_get
    test eax, eax
    jnz .yes
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_values]
    mov rcx, rbx
    mov qword [rbx + 16], 0
    call json_get
    test eax, eax
    jnz .yes
    jmp .no
.children:
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_component]
    lea rcx, [rsp + 24]
    mov qword [rsp + 24 + 16], 0
    call json_get
    test eax, eax
    jz .try2
    cmp qword [rsp + 24 + 16], 'o'
    jne .try2
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    mov rdx, r14
    mov rcx, r15
    mov r8, rbx
    call find_cid
    test eax, eax
    jnz .yes
.try2:
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rel k_components]
    lea rcx, [rsp + 24]
    mov qword [rsp + 24 + 16], 0
    call json_get
    test eax, eax
    jz .no
    cmp qword [rsp + 24 + 16], 'a'
    jne .no
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    mov rdx, r14
    mov rcx, r15
    mov r8, rbx
    call find_cid
    test eax, eax
    jnz .yes
    jmp .no
.arr:
    lea rax, [r12 + 1]
    mov [rsp + 48], rax
    lea rax, [r12 + r13]
    mov [rsp + 56], rax
.al:
    mov rdi, [rsp + 48]
    mov rsi, [rsp + 56]
    lea rdx, [rsp]
    call json_arr_next
    test rax, rax
    jz .no
    mov [rsp + 48], rax
    mov rax, [rsp + 16]
    cmp rax, 'o'
    je .rec
    cmp rax, 'a'
    jne .al
.rec:
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    mov rdx, r14
    mov rcx, r15
    mov r8, rbx
    call find_cid
    test eax, eax
    jz .al
.yes:
    mov eax, 1
    LEAVE_RET
.no:
    xor eax, eax
    LEAVE_RET

; int casm_modal_value(const casm_interaction *i, const char *custom_id, casm_str *out)
; the submitted value of a modal input: 's' (text, JSON-escaped), or 'a' (select values),
; 0 when not found.
global casm_modal_value
casm_modal_value:
    ENTER 56                         ; [0] jv, [24] comps jv
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    test r14, r14
    jz .nz
    mov qword [r14], 0
    mov qword [r14 + 8], 0
.nz:
    test r12, r12
    jz .no
    test r13, r13
    jz .no
    mov rdi, r13
    call c_strlen
    mov r15, rax
    mov rdi, [r12 + I_RAW]
    mov rsi, [r12 + I_RAW + 8]
    lea rdx, [rel k_dcomps]
    lea rcx, [rsp + 24]
    mov qword [rsp + 24 + 16], 0
    call json_path
    test eax, eax
    jz .no
    cmp qword [rsp + 24 + 16], 'a'
    jne .no
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    mov rdx, r13
    mov rcx, r15
    lea r8, [rsp]
    mov qword [rsp + 16], 0
    call find_cid
    test eax, eax
    jz .no
    test r14, r14
    jz .ty
    mov rax, [rsp]
    mov [r14], rax
    mov rax, [rsp + 8]
    mov [r14 + 8], rax
.ty:
    mov rax, [rsp + 16]
    LEAVE_RET
.no:
    xor eax, eax
    LEAVE_RET

; int find_focused(const char *arr, size_t n, casm_str *name, casm_str *value)
find_focused:
    ENTER 80                         ; [0] elem, [24] tmp, [48] cursor, [56] end
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    test r12, r12
    jz .no
    lea rax, [r12 + 1]
    mov [rsp + 48], rax
    lea rax, [r12 + r13]
    mov [rsp + 56], rax
.l:
    mov rdi, [rsp + 48]
    mov rsi, [rsp + 56]
    lea rdx, [rsp]
    call json_arr_next
    test rax, rax
    jz .no
    mov [rsp + 48], rax
    cmp qword [rsp + 16], 'o'
    jne .l
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rel k_focused]
    lea rcx, [rsp + 24]
    mov qword [rsp + 24 + 16], 0
    call json_get
    test eax, eax
    jz .sub
    lea rdi, [rsp + 24]
    call json_true
    test eax, eax
    jz .sub
    ; focused option: name + value
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rel k_name]
    lea rcx, [rsp + 24]
    mov qword [rsp + 24 + 16], 0
    call json_get
    test r14, r14
    jz .nn
    mov rax, [rsp + 24]
    mov rcx, [rsp + 32]
    cmp qword [rsp + 24 + 16], 's'
    jne .nn
    mov [r14], rax
    mov [r14 + 8], rcx
.nn:
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rel k_value]
    lea rcx, [rsp + 24]
    mov qword [rsp + 24 + 16], 0
    call json_get
    test r15, r15
    jz .yes
    test eax, eax
    jz .yes
    mov rax, [rsp + 24]
    mov [r15], rax
    mov rax, [rsp + 32]
    mov [r15 + 8], rax
.yes:
    mov eax, 1
    LEAVE_RET
.sub:
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rel k_options]
    lea rcx, [rsp + 24]
    mov qword [rsp + 24 + 16], 0
    call json_get
    test eax, eax
    jz .l
    cmp qword [rsp + 24 + 16], 'a'
    jne .l
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    mov rdx, r14
    mov rcx, r15
    call find_focused
    test eax, eax
    jz .l
    mov eax, 1
    LEAVE_RET
.no:
    xor eax, eax
    LEAVE_RET

; int casm_option_focused(const casm_interaction *i, casm_str *name, casm_str *value)
; the option the user is typing in (autocomplete, interaction type 4). 1 / 0.
global casm_option_focused
casm_option_focused:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    test r13, r13
    jz .a
    mov qword [r13], 0
    mov qword [r13 + 8], 0
.a:
    test r14, r14
    jz .b
    mov qword [r14], 0
    mov qword [r14 + 8], 0
.b:
    test r12, r12
    jz .no
    mov rdi, [r12 + I_OPTS]
    mov rsi, [r12 + I_OPTS + 8]
    test rdi, rdi
    jz .no
    mov rdx, r13
    mov rcx, r14
    call find_focused
    LEAVE_RET
.no:
    xor eax, eax
    LEAVE_RET

section .note.GNU-stack noalloc noexec nowrite progbits
