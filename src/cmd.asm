; =====================================================================
; cmd.asm - application command builder (slash commands, user / message
; context menu commands) so command JSON does not have to be written by hand.
; Shapes and limits follow the Discord docs, "Application Commands":
;   command: name 1-32, description 1-100 (CHAT_INPUT) or "" (USER / MESSAGE),
;            options max 25, default_member_permissions (string), nsfw,
;            contexts [0 GUILD, 1 BOT_DM, 2 PRIVATE_CHANNEL]
;   option:  type 1..11, name 1-32 (CHAT_INPUT names: lowercase, [-_a-z0-9] or
;            non-ASCII), description 1-100, required (not for types 1 / 2, and
;            required options must come before optional ones), choices max 25
;            (name 1-100, string value up to 100, integer / number), min_value /
;            max_value (INTEGER / NUMBER, integers within +-(2^53-1)), min_length /
;            max_length (STRING, 0-6000 / 1-6000), autocomplete (STRING / INTEGER /
;            NUMBER, not together with choices), options (SUB_COMMAND 1 and
;            SUB_COMMAND_GROUP 2 only, max 25)
; Handles are the 104-byte builder handles of build.asm:
;   a = members, b = choices (option) / options (command), c = sub-options (option)
;   [72] flags: word 0 = count of b entries, word 1 (+74) = count of c entries,
;               bit 32 = a non-required child was added, bit 33 = autocomplete,
;               bit 34 = range / length / contexts set, bit 35 = this option is required,
;               byte +77 = command type (1 chat input, 2 user, 3 message),
;               byte +78 = option type
; =====================================================================
%include "defs.inc"

extern strtod, snprintf
extern sb_init, sb_free, sb_append, sb_appends, sb_putc, sb_append_u64
extern j_sep, j_key, js, jn, j_esc, bnew
extern casm_register_commands, casm_register_guild_commands

%define H_A 0
%define H_B 24
%define H_C 48

section .rodata
s_empty:    db 0
c_ob:       db '{', 0
c_cb:       db '}', 0
c_true:     db "true", 0
j_cn:       db '{"name":', 0
j_cv:       db ',"value":', 0
j_choices:  db ',"choices":[', 0
j_options:  db ',"options":[', 0
k_type:     db "type", 0
k_name:     db "name", 0
k_desc:     db "description", 0
k_required: db "required", 0
k_minv:     db "min_value", 0
k_maxv:     db "max_value", 0
k_minl:     db "min_length", 0
k_maxl:     db "max_length", 0
k_ac:       db "autocomplete", 0
k_perm:     db "default_member_permissions", 0
k_nsfw:     db "nsfw", 0
k_ctx:      db "contexts", 0
f_g15:      db "%.15g", 0
f_g17:      db "%.17g", 0

section .text

; ---------------------------------------------------------------------
; validation helpers (leaf functions, clobber rax rcx rdi r8 r9)
; ---------------------------------------------------------------------
; int ulen(const char *s)   number of UTF-8 code points
ulen:
    xor eax, eax
.l:
    movzx ecx, byte [rdi]
    test ecx, ecx
    jz .d
    inc rdi
    and ecx, 0xC0
    cmp ecx, 0x80
    je .l
    inc eax
    jmp .l
.d:
    ret

global chk_len
; int chk_len(const char *s, long min, long max)   1 when min <= chars <= max (NULL = 0)
chk_len:
    test rdi, rdi
    jz .no
    mov r8, rsi
    mov r9, rdx
    call ulen
    cmp rax, r8
    jb .no
    cmp rax, r9
    ja .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; int chk_slug(const char *s)   only [-_a-z0-9] and non-ASCII bytes
chk_slug:
    test rdi, rdi
    jz .no
.l:
    movzx eax, byte [rdi]
    test eax, eax
    jz .yes
    inc rdi
    cmp eax, 0x80
    jae .l
    cmp eax, '-'
    je .l
    cmp eax, '_'
    je .l
    cmp eax, '0'
    jb .no
    cmp eax, '9'
    jbe .l
    cmp eax, 'a'
    jb .no
    cmp eax, 'z'
    jbe .l
.no:
    xor eax, eax
    ret
.yes:
    mov eax, 1
    ret

; int ok_name(const char *s)   1..32 chars and a valid CHAT_INPUT name
ok_name:
    mov r10, rdi
    call chk_slug
    test eax, eax
    jz .r
    mov rdi, r10
    mov esi, 1
    mov edx, 32
    call chk_len
.r:
    ret

; void fix_dot(char *s)   ',' -> '.' (a locale with decimal commas must not leak into JSON)
fix_dot:
.l:
    mov al, [rdi]
    test al, al
    jz .d
    cmp al, ','
    jne .n
    mov byte [rdi], '.'
.n:
    inc rdi
    jmp .l
.d:
    ret

; ---------------------------------------------------------------------
; number writers
; ---------------------------------------------------------------------
; void sb_i64(sbuf *sb, long v)
sb_i64:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jns .p
    mov rdi, rbx
    mov esi, '-'
    call sb_putc
    neg r12
.p:
    mov rdi, rbx
    mov rsi, r12
    call sb_append_u64
    LEAVE_RET

; void sb_dbl(sbuf *sb, double v /*xmm0, finite*/)   shortest of %.15g / %.17g that round-trips
sb_dbl:
    ENTER 64                         ; [0..40) text, [40] the value
    mov rbx, rdi
    movsd [rsp + 40], xmm0
    lea rdi, [rsp]
    mov esi, 40
    lea rdx, [rel f_g15]
    mov eax, 1
    CALLC snprintf
    lea rdi, [rsp]
    call fix_dot
    lea rdi, [rsp]
    xor esi, esi
    CALLC strtod
    ucomisd xmm0, [rsp + 40]
    jp .p17
    jne .p17
    jmp .out
.p17:
    lea rdi, [rsp]
    mov esi, 40
    lea rdx, [rel f_g17]
    movsd xmm0, [rsp + 40]
    mov eax, 1
    CALLC snprintf
    lea rdi, [rsp]
    call fix_dot
.out:
    mov rdi, rbx
    lea rsi, [rsp]
    call sb_appends
    LEAVE_RET

; int dbl_class(double xmm0)   0 finite, 1 infinite, 2 NaN
dbl_class:
    ucomisd xmm0, xmm0
    jp .nan
    movq rax, xmm0
    shr rax, 52
    and eax, 0x7FF
    cmp eax, 0x7FF
    je .inf
    xor eax, eax
    ret
.inf:
    mov eax, 1
    ret
.nan:
    mov eax, 2
    ret

; void jk_i64(sbuf *sb, const char *key, long v)   [,]"key":v
jk_i64:
    ENTER 0
    mov rbx, rdi
    mov r12, rdx
    call j_key
    mov rdi, rbx
    mov rsi, r12
    call sb_i64
    LEAVE_RET

; void jk_dbl(sbuf *sb, const char *key, double xmm0)
jk_dbl:
    ENTER 16
    mov rbx, rdi
    movsd [rsp], xmm0
    call j_key
    mov rdi, rbx
    movsd xmm0, [rsp]
    call sb_dbl
    LEAVE_RET

; void jk_true(sbuf *sb, const char *key)   "key":true
jk_true:
    ENTER 0
    mov rbx, rdi
    call j_key
    mov rdi, rbx
    lea rsi, [rel c_true]
    call sb_appends
    LEAVE_RET

; ---------------------------------------------------------------------
; JSON assembly
; ---------------------------------------------------------------------
; void obj_json(h, sbuf *out, long is_cmd)
; {a[,"choices"|"options":[b]][,"options":[c]]}
obj_json:
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
    je .nob
    lea rsi, [rel j_choices]
    lea rax, [rel j_options]
    test r13, r13
    cmovnz rsi, rax
    mov rdi, r12
    call sb_appends
    mov rdi, r12
    mov rsi, [rbx + H_B + SB_DATA]
    mov rdx, [rbx + H_B + SB_LEN]
    call sb_append
    mov rdi, r12
    mov esi, ']'
    call sb_putc
.nob:
    cmp qword [rbx + H_C + SB_LEN], 0
    je .noc
    mov rdi, r12
    lea rsi, [rel j_options]
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
    lea rsi, [rel c_cb]
    call sb_appends
    LEAVE_RET

; ---------------------------------------------------------------------
; commands
; ---------------------------------------------------------------------
; casm_cmd *casm_cmd_new(const char *name, const char *description)    slash command (CHAT_INPUT)
; NULL when name / description break the docs' rules (name: 1-32 chars, lowercase, [-_a-z0-9];
; description: 1-100 chars)
global casm_cmd_new
casm_cmd_new:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    mov rdi, r12
    call ok_name
    test eax, eax
    jz .bad
    mov rdi, r13
    mov esi, 1
    mov edx, 100
    call chk_len
    test eax, eax
    jz .bad
    call bnew
    test rax, rax
    jz .bad
    mov rbx, rax
    mov byte [rbx + 77], 1
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_type]
    mov edx, 1
    call jn
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_name]
    mov rdx, r12
    call js
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_desc]
    mov rdx, r13
    call js
    mov rax, rbx
    LEAVE_RET
.bad:
    xor eax, eax
    LEAVE_RET

; casm_cmd *casm_cmd_new_context(const char *name, int type)   type 2 = user menu, 3 = message menu
; name: 1-32 chars (mixed case and spaces are allowed here); no description, no options
global casm_cmd_new_context
casm_cmd_new_context:
    ENTER 0
    mov r12, rdi
    movsxd r13, esi
    cmp r13, 2
    jl .bad
    cmp r13, 3
    jg .bad
    mov rdi, r12
    mov esi, 1
    mov edx, 32
    call chk_len
    test eax, eax
    jz .bad
    call bnew
    test rax, rax
    jz .bad
    mov rbx, rax
    mov [rbx + 77], r13b
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_type]
    mov rdx, r13
    call jn
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_name]
    mov rdx, r12
    call js
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_desc]
    lea rdx, [rel s_empty]
    call js
    mov rax, rbx
    LEAVE_RET
.bad:
    xor eax, eax
    LEAVE_RET

; int casm_cmd_option(casm_cmd *c, casm_opt *o)   slash commands only, max 25, required first
global casm_cmd_option
casm_cmd_option:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    test rbx, rbx
    jz .bad
    test r12, r12
    jz .bad
    cmp byte [rbx + 77], 1
    jne .bad
    movzx eax, word [rbx + 72]
    cmp eax, 25
    jae .bad
    bt qword [r12 + 72], 35
    jnc .optional
    bt qword [rbx + 72], 32
    jc .bad
    jmp .go
.optional:
    bts qword [rbx + 72], 32
.go:
    lea rdi, [rbx + H_B]
    call j_sep
    mov rdi, r12
    lea rsi, [rbx + H_B]
    xor edx, edx
    call obj_json
    inc word [rbx + 72]
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; int casm_cmd_permissions(casm_cmd *c, const char *bits)   default_member_permissions, a decimal
; permission bit set as a string ("0" = administrators only)
global casm_cmd_permissions
casm_cmd_permissions:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    test rbx, rbx
    jz .bad
    test r12, r12
    jz .bad
    xor ecx, ecx
.l:
    movzx eax, byte [r12 + rcx]
    test eax, eax
    jz .e
    cmp eax, '0'
    jb .bad
    cmp eax, '9'
    ja .bad
    inc ecx
    cmp ecx, 20
    ja .bad
    jmp .l
.e:
    test ecx, ecx
    jz .bad
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_perm]
    mov rdx, r12
    call js
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; int casm_cmd_nsfw(casm_cmd *c)
global casm_cmd_nsfw
casm_cmd_nsfw:
    ENTER 0
    test rdi, rdi
    jz .bad
    add rdi, H_A
    lea rsi, [rel k_nsfw]
    call jk_true
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; int casm_cmd_contexts(casm_cmd *c, int mask)   1 = guild, 2 = bot DM, 4 = private channel (global commands)
global casm_cmd_contexts
casm_cmd_contexts:
    ENTER 0
    mov rbx, rdi
    movsxd r12, esi
    test rbx, rbx
    jz .bad
    cmp r12, 1
    jl .bad
    cmp r12, 7
    jg .bad
    bts qword [rbx + 72], 34
    jc .bad
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_ctx]
    call j_key
    lea rdi, [rbx + H_A]
    mov esi, '['
    call sb_putc
    xor r13d, r13d
.l:
    bt r12, r13
    jnc .n
    lea rdi, [rbx + H_A]
    call j_sep
    lea rdi, [rbx + H_A]
    mov rsi, r13
    call sb_append_u64
.n:
    inc r13d
    cmp r13d, 3
    jb .l
    lea rdi, [rbx + H_A]
    mov esi, ']'
    call sb_putc
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; ---------------------------------------------------------------------
; options
; ---------------------------------------------------------------------
; casm_opt *casm_opt_new(int type, const char *name, const char *description, int required)
; type: 1 sub-command, 2 sub-command group, 3 string, 4 integer, 5 boolean, 6 user, 7 channel,
;       8 role, 9 mentionable, 10 number, 11 attachment  (CASM_OPT_*)
global casm_opt_new
casm_opt_new:
    ENTER 0
    movsxd r14, edi
    mov r12, rsi
    mov r13, rdx
    mov r15, rcx
    cmp r14, 1
    jl .bad
    cmp r14, 11
    jg .bad
    test r15d, r15d
    jz .norq
    cmp r14, 2
    jle .bad                         ; sub-commands cannot be required
.norq:
    mov rdi, r12
    call ok_name
    test eax, eax
    jz .bad
    mov rdi, r13
    mov esi, 1
    mov edx, 100
    call chk_len
    test eax, eax
    jz .bad
    call bnew
    test rax, rax
    jz .bad
    mov rbx, rax
    mov [rbx + 78], r14b
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_type]
    mov rdx, r14
    call jn
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_name]
    mov rdx, r12
    call js
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_desc]
    mov rdx, r13
    call js
    test r15d, r15d
    jz .done
    bts qword [rbx + 72], 35
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_required]
    call jk_true
.done:
    mov rax, rbx
    LEAVE_RET
.bad:
    xor eax, eax
    LEAVE_RET

; long choice_head(opt, int type, const char *name)   -> 0, or -1 (wrong type, autocomplete set,
; 25 choices already, bad name); leaves {"name":"..","value": open in b
choice_head:
    ENTER 0
    mov rbx, rdi
    mov r12, rdx
    test rbx, rbx
    jz .bad
    movzx eax, byte [rbx + 78]
    cmp eax, esi
    jne .bad
    bt qword [rbx + 72], 33
    jc .bad
    movzx eax, word [rbx + 72]
    cmp eax, 25
    jae .bad
    mov rdi, r12
    mov esi, 1
    mov edx, 100
    call chk_len
    test eax, eax
    jz .bad
    lea rdi, [rbx + H_B]
    call j_sep
    lea rdi, [rbx + H_B]
    lea rsi, [rel j_cn]
    call sb_appends
    lea rdi, [rbx + H_B]
    mov rsi, r12
    call j_esc
    lea rdi, [rbx + H_B]
    lea rsi, [rel j_cv]
    call sb_appends
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; void choice_tail(opt)
choice_tail:
    ENTER 0
    mov rbx, rdi
    lea rdi, [rbx + H_B]
    lea rsi, [rel c_cb]
    call sb_appends
    inc word [rbx + 72]
    LEAVE_RET

; int casm_opt_choice(casm_opt *o, const char *name, const char *value)   STRING option, value 0-100 chars
global casm_opt_choice
casm_opt_choice:
    ENTER 0
    mov rbx, rdi
    mov r13, rsi
    mov r12, rdx
    mov rdi, r12
    xor esi, esi
    mov edx, 100
    call chk_len
    test eax, eax
    jz .bad
    mov rdi, rbx
    mov esi, 3
    mov rdx, r13
    call choice_head
    test rax, rax
    jnz .bad
    lea rdi, [rbx + H_B]
    mov rsi, r12
    call j_esc
    mov rdi, rbx
    call choice_tail
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; int casm_opt_choice_int(casm_opt *o, const char *name, long value)   INTEGER option, |value| <= 2^53-1
global casm_opt_choice_int
casm_opt_choice_int:
    ENTER 0
    mov rbx, rdi
    mov r13, rsi
    mov r12, rdx
    mov rax, 9007199254740991
    cmp r12, rax
    jg .bad
    neg rax
    cmp r12, rax
    jl .bad
    mov rdi, rbx
    mov esi, 4
    mov rdx, r13
    call choice_head
    test rax, rax
    jnz .bad
    lea rdi, [rbx + H_B]
    mov rsi, r12
    call sb_i64
    mov rdi, rbx
    call choice_tail
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; int casm_opt_choice_num(casm_opt *o, const char *name, double value)   NUMBER option (finite)
global casm_opt_choice_num
casm_opt_choice_num:
    ENTER 16
    mov rbx, rdi
    mov r13, rsi
    movsd [rsp], xmm0
    call dbl_class
    test eax, eax
    jnz .bad
    mov rdi, rbx
    mov esi, 10
    mov rdx, r13
    call choice_head
    test rax, rax
    jnz .bad
    lea rdi, [rbx + H_B]
    movsd xmm0, [rsp]
    call sb_dbl
    mov rdi, rbx
    call choice_tail
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; int casm_opt_range_int(casm_opt *o, long min, long max)   INTEGER option; LONG_MIN / LONG_MAX = no limit
global casm_opt_range_int
casm_opt_range_int:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test rbx, rbx
    jz .bad
    cmp byte [rbx + 78], 4
    jne .bad
    mov r14, 0x8000000000000000
    mov r15, 0x7FFFFFFFFFFFFFFF
    mov rax, 9007199254740991
    cmp r12, r14
    je .chkmax
    cmp r12, rax
    jg .bad
    neg rax
    cmp r12, rax
    jl .bad
    mov rax, 9007199254740991
.chkmax:
    cmp r13, r15
    je .order
    cmp r13, rax
    jg .bad
    neg rax
    cmp r13, rax
    jl .bad
.order:
    cmp r12, r14
    je .ok
    cmp r13, r15
    je .ok
    cmp r12, r13
    jg .bad
.ok:
    cmp r12, r14
    jne .set
    cmp r13, r15
    je .none
.set:
    bts qword [rbx + 72], 34
    jc .bad
    cmp r12, r14
    je .max
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_minv]
    mov rdx, r12
    call jk_i64
.max:
    cmp r13, r15
    je .none
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_maxv]
    mov rdx, r13
    call jk_i64
.none:
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; int casm_opt_range_num(casm_opt *o, double min, double max)   NUMBER option; +-INFINITY = no limit
global casm_opt_range_num
casm_opt_range_num:
    ENTER 32                         ; [0] min, [8] max, [16] min class, [24] max class
    mov rbx, rdi
    movsd [rsp], xmm0
    movsd [rsp + 8], xmm1
    test rbx, rbx
    jz .bad
    cmp byte [rbx + 78], 10
    jne .bad
    movsd xmm0, [rsp]
    call dbl_class
    cmp eax, 2
    je .bad
    mov [rsp + 16], rax
    movsd xmm0, [rsp + 8]
    call dbl_class
    cmp eax, 2
    je .bad
    mov [rsp + 24], rax
    cmp qword [rsp + 16], 0
    jne .set
    cmp qword [rsp + 24], 0
    jne .set
    movsd xmm0, [rsp]
    ucomisd xmm0, [rsp + 8]
    ja .bad
.set:
    mov rax, [rsp + 16]
    and rax, [rsp + 24]              ; both infinite = no limits at all
    jnz .none
    bts qword [rbx + 72], 34
    jc .bad
    cmp qword [rsp + 16], 0
    jne .max
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_minv]
    movsd xmm0, [rsp]
    call jk_dbl
.max:
    cmp qword [rsp + 24], 0
    jne .none
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_maxv]
    movsd xmm0, [rsp + 8]
    call jk_dbl
.none:
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; int casm_opt_length(casm_opt *o, long min, long max)   STRING option; min 0..6000, max 1..6000, negative = unset
global casm_opt_length
casm_opt_length:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test rbx, rbx
    jz .bad
    cmp byte [rbx + 78], 3
    jne .bad
    test r12, r12
    js .chkmax
    cmp r12, 6000
    jg .bad
.chkmax:
    test r13, r13
    js .order
    test r13, r13
    jz .bad                          ; max_length starts at 1
    cmp r13, 6000
    jg .bad
.order:
    test r12, r12
    js .go
    test r13, r13
    js .go
    cmp r12, r13
    jg .bad
.go:
    test r12, r12
    jns .set
    test r13, r13
    js .none
.set:
    bts qword [rbx + 72], 34
    jc .bad
    test r12, r12
    js .max
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_minl]
    mov rdx, r12
    call jk_i64
.max:
    test r13, r13
    js .none
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_maxl]
    mov rdx, r13
    call jk_i64
.none:
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; int casm_opt_autocomplete(casm_opt *o)   STRING / INTEGER / NUMBER without choices
global casm_opt_autocomplete
casm_opt_autocomplete:
    ENTER 0
    mov rbx, rdi
    test rbx, rbx
    jz .bad
    movzx eax, byte [rbx + 78]
    cmp eax, 3
    je .ty
    cmp eax, 4
    je .ty
    cmp eax, 10
    jne .bad
.ty:
    cmp word [rbx + 72], 0
    jne .bad                         ; choices and autocomplete exclude each other
    bts qword [rbx + 72], 33
    jc .bad
    lea rdi, [rbx + H_A]
    lea rsi, [rel k_ac]
    call jk_true
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; int casm_opt_add(casm_opt *parent, casm_opt *child)
; parent type 1 (sub-command): child is a normal option (type >= 3); parent type 2 (group): child is
; a sub-command (type 1). Max 25, required before optional. The child is copied; free it yourself.
global casm_opt_add
casm_opt_add:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    test rbx, rbx
    jz .bad
    test r12, r12
    jz .bad
    movzx eax, byte [rbx + 78]
    movzx ecx, byte [r12 + 78]
    cmp eax, 1
    je .sub
    cmp eax, 2
    jne .bad
    cmp ecx, 1
    jne .bad
    jmp .chk
.sub:
    cmp ecx, 3
    jb .bad
.chk:
    movzx eax, word [rbx + 74]
    cmp eax, 25
    jae .bad
    bt qword [r12 + 72], 35
    jnc .optional
    bt qword [rbx + 72], 32
    jc .bad
    jmp .go
.optional:
    bts qword [rbx + 72], 32
.go:
    lea rdi, [rbx + H_C]
    call j_sep
    mov rdi, r12
    lea rsi, [rbx + H_C]
    xor edx, edx
    call obj_json
    inc word [rbx + 74]
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; ---------------------------------------------------------------------
; registration
; ---------------------------------------------------------------------
; long cmd_list(casm_cmd *const *cmds, int n, sbuf *out)   "[c1,c2,...]"; 0 ok, -1 bad argument
cmd_list:
    ENTER 0
    mov r12, rdi
    movsxd r13, esi
    mov r14, rdx
    test r12, r12
    jz .bad
    cmp r13, 1
    jl .bad
    cmp r13, 100
    jg .bad
    xor ebx, ebx
.chk:
    mov rax, [r12 + rbx*8]
    test rax, rax
    jz .bad
    movzx ecx, byte [rax + 77]
    cmp ecx, 1
    jb .bad
    cmp ecx, 3
    ja .bad
    inc rbx
    cmp rbx, r13
    jb .chk
    mov rdi, r14
    mov esi, '['
    call sb_putc
    xor ebx, ebx
.w:
    test rbx, rbx
    jz .nc
    mov rdi, r14
    mov esi, ','
    call sb_putc
.nc:
    mov rdi, [r12 + rbx*8]
    mov rsi, r14
    mov edx, 1
    call obj_json
    inc rbx
    cmp rbx, r13
    jb .w
    mov rdi, r14
    mov esi, ']'
    call sb_putc
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; long casm_register_cmds(casm_cmd *const *cmds, int n)               global commands (bulk overwrite)
global casm_register_cmds
casm_register_cmds:
    ENTER 32                         ; [0] sbuf
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rsp]
    call sb_init
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rsp]
    call cmd_list
    test rax, rax
    jnz .bad
    mov rdi, [rsp + SB_DATA]
    mov rsi, [rsp + SB_LEN]
    call casm_register_commands
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

; long casm_register_guild_cmds(const char *guild_id, casm_cmd *const *cmds, int n)
global casm_register_guild_cmds
casm_register_guild_cmds:
    ENTER 32                         ; [0] sbuf
    mov r15, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rsp]
    call sb_init
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rsp]
    call cmd_list
    test rax, rax
    jnz .bad
    mov rdi, r15
    mov rsi, [rsp + SB_DATA]
    mov rdx, [rsp + SB_LEN]
    call casm_register_guild_commands
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

section .note.GNU-stack noalloc noexec nowrite progbits
