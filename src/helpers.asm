; =====================================================================
; helpers.asm - convenience helpers for handling messages:
;   casm_unescape, casm_mentions_user, casm_mentions_me,
;   casm_is_reply_to_me, casm_match_prefix, casm_next_word
; =====================================================================
%include "defs.inc"

extern memcmp
extern c_strlen, trim_span
extern json_get, json_arr_next
extern g_bot_id

; offsets inside casm_message (see include/caineasm.h)
%define M_MENT    128
%define M_REFAID  144

section .text

; ---------------------------------------------------------------------
; long ue_hex4(const char *p)   value of 4 hex digits, or -1
; ---------------------------------------------------------------------
ue_hex4:
    xor eax, eax
    mov ecx, 4
.l:
    movzx edx, byte [rdi]
    cmp dl, '0'
    jb .bad
    cmp dl, '9'
    jbe .dig
    or dl, 32
    cmp dl, 'a'
    jb .bad
    cmp dl, 'f'
    ja .bad
    sub edx, 'a' - 10
    jmp .acc
.dig:
    sub edx, '0'
.acc:
    shl eax, 4
    or eax, edx
    inc rdi
    dec ecx
    jnz .l
    ret
.bad:
    mov eax, -1
    ret

; ---------------------------------------------------------------------
; void ue_emit(ctx *c, uint32 packed_bytes, long n)
;   ctx: 0 dst, 8 cap, 16 pos, 24 total, 32 full
;   counts n bytes in total; stores them only when they still fit (a character
;   is never cut in half) and nothing was dropped before.
; ---------------------------------------------------------------------
ue_emit:
    add [rdi + 24], rdx
    cmp qword [rdi + 32], 0
    jne .d
    mov rcx, [rdi + 8]
    test rcx, rcx
    jz .d
    mov rax, [rdi + 16]
    lea r8, [rax + rdx]
    dec rcx
    cmp r8, rcx
    ja .full
    mov r9, [rdi]
    mov [rdi + 16], r8
.w:
    mov [r9 + rax], sil
    shr esi, 8
    inc rax
    dec rdx
    jnz .w
.d:
    ret
.full:
    mov qword [rdi + 32], 1
    ret

; ---------------------------------------------------------------------
; size_t casm_unescape(const char *src, size_t len, char *dst, size_t cap)
; Decodes JSON string escapes (\" \\ \/ \b \f \n \r \t \uXXXX, surrogate pairs)
; into UTF-8. Returns the decoded length (like snprintf: even when dst was too
; small); writes at most cap-1 bytes and always NUL terminates when cap > 0.
; dst may be NULL with cap 0 to just measure. The result never exceeds len, so
; a buffer of len+1 bytes always suffices. Malformed escapes are copied as is;
; lone surrogates become U+FFFD.
; ---------------------------------------------------------------------
global casm_unescape
casm_unescape:
    ENTER 48                        ; ctx at [rsp]
    mov r12, rdi
    lea r13, [rdi + rsi]
    mov [rsp], rdx
    mov [rsp + 8], rcx
    mov qword [rsp + 16], 0
    mov qword [rsp + 24], 0
    mov qword [rsp + 32], 0
    lea rbx, [rsp]
.loop:
    cmp r12, r13
    jae .done
    movzx eax, byte [r12]
    cmp al, '\'
    jne .plain
    lea rcx, [r12 + 1]
    cmp rcx, r13
    jae .plain                      ; trailing backslash: keep it
    movzx edx, byte [r12 + 1]
    cmp dl, 'u'
    je .uni
    cmp dl, '"'
    mov esi, '"'
    je .simple
    cmp dl, '\'
    mov esi, '\'
    je .simple
    cmp dl, '/'
    mov esi, '/'
    je .simple
    cmp dl, 'n'
    mov esi, 10
    je .simple
    cmp dl, 't'
    mov esi, 9
    je .simple
    cmp dl, 'r'
    mov esi, 13
    je .simple
    cmp dl, 'b'
    mov esi, 8
    je .simple
    cmp dl, 'f'
    mov esi, 12
    je .simple
.plain:
    cmp eax, 0xC0
    jb .plain1
    ; a raw UTF-8 lead byte: copy the whole sequence as one unit
    mov edx, 2
    cmp eax, 0xE0
    jb .gotlen
    mov edx, 3
    cmp eax, 0xF0
    jb .gotlen
    mov edx, 4
.gotlen:
    mov rcx, r13
    sub rcx, r12
    cmp rdx, rcx
    jbe .lenok
    mov rdx, rcx
.lenok:
    mov r14, rdx
    mov rcx, rdx
    xor esi, esi
.pk:
    dec rcx
    shl esi, 8
    movzx eax, byte [r12 + rcx]
    or esi, eax
    test rcx, rcx
    jnz .pk
    mov rdi, rbx
    mov rdx, r14
    call ue_emit
    add r12, r14
    jmp .loop
.plain1:
    mov rdi, rbx
    mov esi, eax
    mov edx, 1
    call ue_emit
    inc r12
    jmp .loop
.simple:
    mov rdi, rbx
    mov edx, 1
    call ue_emit
    add r12, 2
    jmp .loop

.uni:
    lea rcx, [r12 + 6]
    cmp rcx, r13
    ja .plain_bs
    lea rdi, [r12 + 2]
    call ue_hex4
    test eax, eax
    js .plain_bs
    mov r14d, eax                   ; code unit
    add r12, 6
    cmp r14d, 0xD800
    jb .encode
    cmp r14d, 0xDBFF
    jbe .high
    cmp r14d, 0xDFFF
    jbe .bad_sur
    jmp .encode
.high:
    lea rcx, [r12 + 6]
    cmp rcx, r13
    ja .bad_sur
    cmp byte [r12], '\'
    jne .bad_sur
    cmp byte [r12 + 1], 'u'
    jne .bad_sur
    lea rdi, [r12 + 2]
    call ue_hex4
    cmp eax, 0xDC00
    jb .bad_sur
    cmp eax, 0xDFFF
    ja .bad_sur
    sub eax, 0xDC00
    sub r14d, 0xD800
    shl r14d, 10
    lea r14d, [r14 + rax + 0x10000]
    add r12, 6
    jmp .encode
.bad_sur:
    mov r14d, 0xFFFD
.encode:
    mov eax, r14d
    cmp eax, 0x80
    jb .e1
    cmp eax, 0x800
    jb .e2
    cmp eax, 0x10000
    jb .e3
    ; 4 bytes
    mov esi, eax
    shr esi, 18
    or esi, 0xF0
    mov ecx, eax
    shr ecx, 12
    and ecx, 0x3F
    or ecx, 0x80
    shl ecx, 8
    or esi, ecx
    mov ecx, eax
    shr ecx, 6
    and ecx, 0x3F
    or ecx, 0x80
    shl ecx, 16
    or esi, ecx
    and eax, 0x3F
    or eax, 0x80
    shl eax, 24
    or esi, eax
    mov edx, 4
    jmp .out
.e3:
    mov esi, eax
    shr esi, 12
    or esi, 0xE0
    mov ecx, eax
    shr ecx, 6
    and ecx, 0x3F
    or ecx, 0x80
    shl ecx, 8
    or esi, ecx
    and eax, 0x3F
    or eax, 0x80
    shl eax, 16
    or esi, eax
    mov edx, 3
    jmp .out
.e2:
    mov esi, eax
    shr esi, 6
    or esi, 0xC0
    and eax, 0x3F
    or eax, 0x80
    shl eax, 8
    or esi, eax
    mov edx, 2
    jmp .out
.e1:
    mov esi, eax
    mov edx, 1
.out:
    mov rdi, rbx
    call ue_emit
    jmp .loop
.plain_bs:
    mov rdi, rbx
    mov esi, '\'
    mov edx, 1
    call ue_emit
    inc r12
    jmp .loop

.done:
    mov rcx, [rsp + 8]
    test rcx, rcx
    jz .ret
    mov rax, [rsp + 16]
    mov rdx, [rsp]
    mov byte [rdx + rax], 0
.ret:
    mov rax, [rsp + 24]
    LEAVE_RET

; ---------------------------------------------------------------------
; int casm_mentions_user(const casm_message *m, const char *user_id)
; 1 when the message's mentions array contains that user id
; ---------------------------------------------------------------------
global casm_mentions_user
casm_mentions_user:
    ENTER 64                        ; [0] element jv, [24] id jv
    mov r12, rdi
    mov r13, rsi
    test r12, r12
    jz .no
    test r13, r13
    jz .no
    mov rdi, r13
    call c_strlen
    mov rbx, rax
    mov rax, [r12 + M_MENT]
    test rax, rax
    jz .no
    lea r14, [rax + 1]
    add rax, [r12 + M_MENT + 8]
    mov r15, rax
.loop:
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rsp]
    call json_arr_next
    test rax, rax
    jz .no
    mov r14, rax
    cmp qword [rsp + 16], 'o'
    jne .loop
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rel k_id]
    lea rcx, [rsp + 24]
    mov qword [rsp + 24 + 16], 0
    call json_get
    test eax, eax
    jz .loop
    cmp qword [rsp + 24 + 16], 's'
    jne .loop
    cmp [rsp + 24 + 8], rbx
    jne .loop
    mov rdi, [rsp + 24]
    mov rsi, r13
    mov rdx, rbx
    CALLC memcmp
    test eax, eax
    jnz .loop
    mov eax, 1
    LEAVE_RET
.no:
    xor eax, eax
    LEAVE_RET

; int casm_mentions_me(const casm_message *m)   1 when the bot itself is mentioned
global casm_mentions_me
casm_mentions_me:
    lea rsi, [rel g_bot_id]
    cmp byte [rsi], 0
    je .no
    jmp casm_mentions_user
.no:
    xor eax, eax
    ret

; int casm_is_reply_to_me(const casm_message *m)   1 when it replies to one of the bot's messages
global casm_is_reply_to_me
casm_is_reply_to_me:
    ENTER 0
    mov r12, rdi
    test r12, r12
    jz .no
    cmp byte [rel g_bot_id], 0
    je .no
    mov r13, [r12 + M_REFAID]
    test r13, r13
    jz .no
    lea rdi, [rel g_bot_id]
    call c_strlen
    cmp [r12 + M_REFAID + 8], rax
    jne .no
    mov rdi, r13
    lea rsi, [rel g_bot_id]
    mov rdx, rax
    CALLC memcmp
    test eax, eax
    jnz .no
    mov eax, 1
    LEAVE_RET
.no:
    xor eax, eax
    LEAVE_RET

; ---------------------------------------------------------------------
; size_t word_end(const char *p, size_t n)  length of the first token
; (ends at a space, tab, or the JSON escapes \n \r \t)
; ---------------------------------------------------------------------
word_end:
    xor eax, eax
.l:
    cmp rax, rsi
    jae .d
    movzx ecx, byte [rdi + rax]
    cmp cl, ' '
    je .d
    cmp cl, 9
    je .d
    cmp cl, '\'
    jne .n
    lea rdx, [rax + 1]
    cmp rdx, rsi
    jae .n
    movzx ecx, byte [rdi + rdx]
    cmp cl, 'n'
    je .d
    cmp cl, 'r'
    je .d
    cmp cl, 't'
    je .d
.n:
    inc rax
    jmp .l
.d:
    ret

; ---------------------------------------------------------------------
; int casm_match_prefix(const casm_str *content, const char *prefix, casm_str *rest)
; 1 when content starts with prefix (ASCII case-insensitive) followed by the end
; of the text or whitespace (space, tab, or the escapes \n \r \t). rest (may be
; NULL) receives what follows, trimmed.
; ---------------------------------------------------------------------
global casm_match_prefix
casm_match_prefix:
    ENTER 0
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    test r12, r12
    jz .no
    test r13, r13
    jz .no
    mov rdi, r13
    call c_strlen
    mov rbx, rax                    ; prefix length
    test rbx, rbx
    jz .no
    mov r15, [r12]                  ; content ptr
    test r15, r15
    jz .no
    cmp [r12 + 8], rbx
    jb .no
    xor edx, edx
.cmp:
    cmp rdx, rbx
    jae .matched
    movzx eax, byte [r15 + rdx]
    movzx edi, byte [r13 + rdx]
    LOWER eax, r8d
    LOWER edi, r9d
    cmp eax, edi
    jne .no
    inc rdx
    jmp .cmp
.matched:
    mov rax, [r12 + 8]
    sub rax, rbx                    ; bytes after the prefix
    lea rsi, [r15 + rbx]            ; their start
    test rax, rax
    jz .bounded
    movzx ecx, byte [rsi]
    cmp cl, ' '
    je .bounded
    cmp cl, 9
    je .bounded
    cmp cl, '\'
    jne .no
    cmp rax, 2
    jb .no
    movzx ecx, byte [rsi + 1]
    cmp cl, 'n'
    je .bounded
    cmp cl, 'r'
    je .bounded
    cmp cl, 't'
    jne .no
.bounded:
    mov rdi, rsi
    mov rsi, rax
    call trim_span
    test r14, r14
    jz .yes
    mov [r14], rax
    mov [r14 + 8], rdx
.yes:
    mov eax, 1
    LEAVE_RET
.no:
    xor eax, eax
    LEAVE_RET

; ---------------------------------------------------------------------
; int casm_next_word(const casm_str *text, casm_str *word, casm_str *rest)
; Splits off the first whitespace-delimited word. 1 when there was one.
; rest (may be NULL) is what remains, trimmed. text may be the same object as rest.
; ---------------------------------------------------------------------
global casm_next_word
casm_next_word:
    ENTER 0
    mov r12, rsi                    ; word out
    mov r13, rdx                    ; rest out
    test rdi, rdi
    jz .none
    mov rax, [rdi]
    mov rsi, [rdi + 8]
    mov rdi, rax
    test rdi, rdi
    jz .none
    call trim_span
    mov r14, rax                    ; p
    mov r15, rdx                    ; n
    test r15, r15
    jz .none
    mov rdi, r14
    mov rsi, r15
    call word_end
    mov rbx, rax                    ; word length
    test r12, r12
    jz .norw
    mov [r12], r14
    mov [r12 + 8], rbx
.norw:
    lea rdi, [r14 + rbx]
    mov rsi, r15
    sub rsi, rbx
    call trim_span
    test r13, r13
    jz .yes
    mov [r13], rax
    mov [r13 + 8], rdx
.yes:
    mov eax, 1
    LEAVE_RET
.none:
    test r12, r12
    jz .n2
    mov qword [r12], 0
    mov qword [r12 + 8], 0
.n2:
    test r13, r13
    jz .n3
    mov qword [r13], 0
    mov qword [r13 + 8], 0
.n3:
    xor eax, eax
    LEAVE_RET

section .rodata
k_id: db "id", 0

section .note.GNU-stack noalloc noexec nowrite progbits
