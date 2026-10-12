; =====================================================================
; util.asm - string builder, text helpers, time, base64, message chunking
; =====================================================================
%include "defs.inc"

extern malloc, realloc, free, memcpy, abort, clock_gettime, poll

section .rodata
hexdigits:  db "0123456789abcdef"
b64tab:     db "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
s_esc_quote: db '\"'
s_esc_bs:    db '\\'
s_esc_nl:    db '\n'
s_esc_cr:    db '\r'
s_esc_tab:   db '\t'

section .text

; ---------------------------------------------------------------------
; void sb_init(sbuf *sb)       allocate a small initial buffer
; ---------------------------------------------------------------------
global sb_init
sb_init:
    push rbx
    mov rbx, rdi
    mov edi, 256
    CALLC malloc
    test rax, rax
    jz .oom
    mov [rbx + SB_DATA], rax
    mov byte [rax], 0
    mov qword [rbx + SB_LEN], 0
    mov qword [rbx + SB_CAP], 256
    pop rbx
    ret
.oom:
    CALLC abort

; void sb_free(sbuf *sb)
global sb_free
sb_free:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + SB_DATA]
    CALLC free
    mov qword [rbx + SB_DATA], 0
    mov qword [rbx + SB_LEN], 0
    mov qword [rbx + SB_CAP], 0
    pop rbx
    ret

; void sb_reset(sbuf *sb)
global sb_reset
sb_reset:
    mov qword [rdi + SB_LEN], 0
    mov rax, [rdi + SB_DATA]
    test rax, rax
    jz .r
    mov byte [rax], 0
.r: ret

; void sb_reserve(sbuf *sb, size_t extra)  -> room for len+extra+1 bytes
global sb_reserve
sb_reserve:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx + SB_LEN]
    add rax, r12
    inc rax                         ; needed capacity
    cmp rax, [rbx + SB_CAP]
    jbe .ok
    mov r13, [rbx + SB_CAP]
    test r13, r13
    jnz .dbl
    mov r13, 256
.dbl:
    cmp r13, rax
    jae .alloc
    shl r13, 1
    jmp .dbl
.alloc:
    mov rdi, [rbx + SB_DATA]
    mov rsi, r13
    CALLC realloc
    test rax, rax
    jz .oom
    mov [rbx + SB_DATA], rax
    mov [rbx + SB_CAP], r13
.ok:
    LEAVE_RET
.oom:
    CALLC abort

; void sb_append(sbuf *sb, const char *p, size_t n)
global sb_append
sb_append:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rsi, r13
    call sb_reserve
    mov rdi, [rbx + SB_DATA]
    add rdi, [rbx + SB_LEN]
    mov rsi, r12
    mov rdx, r13
    test rdx, rdx
    jz .nocopy
    CALLC memcpy
.nocopy:
    add [rbx + SB_LEN], r13
    mov rax, [rbx + SB_DATA]
    add rax, [rbx + SB_LEN]
    mov byte [rax], 0
    LEAVE_RET

; void sb_appends(sbuf *sb, const char *cstr)
global sb_appends
sb_appends:
    ENTER 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call c_strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call sb_append
    LEAVE_RET

; size_t c_strlen(const char*)   (tiny local strlen, no libc dependency)
global c_strlen
c_strlen:
    xor eax, eax
.l: cmp byte [rdi + rax], 0
    je .d
    inc rax
    jmp .l
.d: ret

; void sb_putc(sbuf *sb, int c)
global sb_putc
sb_putc:
    ENTER 16
    mov [rsp], sil
    lea rsi, [rsp]
    mov edx, 1
    call sb_append
    LEAVE_RET

; void sb_append_u64(sbuf *sb, uint64_t v)
global sb_append_u64
sb_append_u64:
    ENTER 32
    mov rbx, rdi
    mov rax, rsi
    lea r12, [rsp + 32]
    mov ecx, 10
.l: xor edx, edx
    div rcx
    add dl, '0'
    dec r12
    mov [r12], dl
    test rax, rax
    jnz .l
    lea rdx, [rsp + 32]
    sub rdx, r12
    mov rdi, rbx
    mov rsi, r12
    call sb_append
    LEAVE_RET

; void sb_append_json_esc(sbuf *sb, const char *p, size_t n)
; Appends raw text escaped so it can sit inside a JSON string literal.
global sb_append_json_esc
sb_append_json_esc:
    ENTER 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
.loop:
    test r13, r13
    jz .done
    movzx eax, byte [r12]
    inc r12
    dec r13
    cmp al, '"'
    je .quote
    cmp al, '\'
    je .bs
    cmp al, 0x20
    jb .ctrl
    mov rdi, rbx
    movzx esi, al
    call sb_putc
    jmp .loop
.quote:
    lea rsi, [rel s_esc_quote]
    jmp .two
.bs:
    lea rsi, [rel s_esc_bs]
    jmp .two
.ctrl:
    cmp al, 10
    jne .c1
    lea rsi, [rel s_esc_nl]
    jmp .two
.c1:
    cmp al, 13
    jne .c2
    lea rsi, [rel s_esc_cr]
    jmp .two
.c2:
    cmp al, 9
    jne .c3
    lea rsi, [rel s_esc_tab]
    jmp .two
.c3:
    mov byte [rsp + 0], '\'
    mov byte [rsp + 1], 'u'
    mov byte [rsp + 2], '0'
    mov byte [rsp + 3], '0'
    lea rcx, [rel hexdigits]
    movzx edx, al
    shr edx, 4
    mov dl, [rcx + rdx]
    mov [rsp + 4], dl
    and eax, 15
    mov al, [rcx + rax]
    mov [rsp + 5], al
    lea rsi, [rsp]
    mov edx, 6
    mov rdi, rbx
    call sb_append
    jmp .loop
.two:
    mov rdi, rbx
    mov edx, 2
    call sb_append
    jmp .loop
.done:
    LEAVE_RET

; ---------------------------------------------------------------------
; const char *mem_ifind(hay, hlen, needle, nlen)  ASCII case-insensitive
; returns pointer to first match or NULL
; ---------------------------------------------------------------------
global mem_ifind
mem_ifind:
    test rcx, rcx
    jz .retH
    cmp rsi, rcx
    jb .null
    sub rsi, rcx
    inc rsi                         ; number of start positions
.pos:
    xor r9d, r9d
.cmp:
    movzx eax, byte [rdi + r9]
    movzx r10d, byte [rdx + r9]
    LOWER eax, r11d
    LOWER r10d, r11d
    cmp eax, r10d
    jne .next
    inc r9
    cmp r9, rcx
    jb .cmp
    mov rax, rdi
    ret
.next:
    inc rdi
    dec rsi
    jnz .pos
.null:
    xor eax, eax
    ret
.retH:
    mov rax, rdi
    ret

; ---------------------------------------------------------------------
; int ieq(const char *p, size_t n, const char *cstr)
; 1 when p[0..n) equals cstr ignoring ASCII case
; ---------------------------------------------------------------------
global ieq
ieq:
    xor ecx, ecx
.l:
    movzx eax, byte [rdx + rcx]
    test eax, eax
    jz .end
    cmp rcx, rsi
    jae .no
    movzx r8d, byte [rdi + rcx]
    LOWER eax, r9d
    LOWER r8d, r9d
    cmp eax, r8d
    jne .no
    inc rcx
    jmp .l
.end:
    cmp rcx, rsi
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; ---------------------------------------------------------------------
; uint64_t parse_u64(const char *p, size_t n)  -> rax=value, rdx=digits read
; ---------------------------------------------------------------------
global parse_u64
parse_u64:
    xor eax, eax
    xor ecx, ecx
.l:
    cmp rcx, rsi
    jae .d
    movzx r8d, byte [rdi + rcx]
    sub r8d, '0'
    cmp r8d, 9
    ja .d
    imul rax, rax, 10
    add rax, r8
    inc rcx
    jmp .l
.d:
    mov rdx, rcx
    ret

; ---------------------------------------------------------------------
; uint64_t now_ms(void)   monotonic clock in milliseconds
; ---------------------------------------------------------------------
global now_ms
now_ms:
    ENTER 16
    mov edi, CLOCK_MONOTONIC
    lea rsi, [rsp]
    CALLC clock_gettime
    mov rax, [rsp]
    imul rax, rax, 1000
    mov r8, rax
    mov rax, [rsp + 8]
    xor edx, edx
    mov ecx, 1000000
    div rcx
    add rax, r8
    LEAVE_RET

; void sleep_ms(uint64_t ms)  (returns early on a signal)
global sleep_ms
sleep_ms:
    push rbx                        ; keep the stack 16-byte aligned
    mov edx, edi                    ; poll(NULL, 0, ms)
    xor edi, edi
    xor esi, esi
    CALLC poll
    pop rbx
    ret

; ---------------------------------------------------------------------
; trim_span(const char *p, size_t n) -> rax=new ptr, rdx=new len
; Strips ASCII whitespace and the JSON escapes \n \r \t from both ends
; (text here is kept in JSON-escaped form, so a newline is the 2 bytes \n).
; ---------------------------------------------------------------------
global trim_span
trim_span:
    ; ---- leading ----
.lead:
    test rsi, rsi
    jz .done
    movzx eax, byte [rdi]
    cmp al, ' '
    je .lead1
    cmp al, 9
    je .lead1
    cmp al, 10
    je .lead1
    cmp al, 13
    je .lead1
    cmp al, '\'
    jne .trail
    cmp rsi, 2
    jb .trail
    movzx eax, byte [rdi + 1]
    cmp al, 'n'
    je .lead2
    cmp al, 'r'
    je .lead2
    cmp al, 't'
    je .lead2
    jmp .trail
.lead2:
    add rdi, 2
    sub rsi, 2
    jmp .lead
.lead1:
    inc rdi
    dec rsi
    jmp .lead
    ; ---- trailing ----
.trail:
    test rsi, rsi
    jz .done
    movzx eax, byte [rdi + rsi - 1]
    cmp al, ' '
    je .trail1
    cmp al, 9
    je .trail1
    cmp al, 10
    je .trail1
    cmp al, 13
    je .trail1
    cmp al, 'n'
    je .tesc
    cmp al, 'r'
    je .tesc
    cmp al, 't'
    je .tesc
    jmp .done
.tesc:
    ; count the run of backslashes before this letter; odd => it is an escape
    xor ecx, ecx
    lea rdx, [rsi - 2]              ; index of the byte before the letter
.cnt:
    cmp rdx, 0
    jl .cdone
    cmp byte [rdi + rdx], '\'
    jne .cdone
    inc ecx
    dec rdx
    jmp .cnt
.cdone:
    test ecx, 1
    jz .done
    sub rsi, 2
    jmp .trail
.trail1:
    dec rsi
    jmp .trail
.done:
    mov rax, rdi
    mov rdx, rsi
    ret

; ---------------------------------------------------------------------
; size_t b64_encode(const uint8_t *src, size_t n, char *dst)
; standard base64 with '=' padding, returns number of chars written
; ---------------------------------------------------------------------
%macro B64CHAR 1                    ; %1 = shift; value in ecx, writes to [r9]
    mov r10d, ecx
    shr r10d, %1
    and r10d, 63
    mov r10b, [r8 + r10]
    mov [r9], r10b
    inc r9
%endmacro

global b64_encode
b64_encode:
    lea r8, [rel b64tab]
    mov rax, rdx                    ; remember dst
    mov r9, rdx
.l3:
    cmp rsi, 3
    jb .tail
    movzx ecx, byte [rdi]
    shl ecx, 16
    movzx r10d, byte [rdi + 1]
    shl r10d, 8
    or ecx, r10d
    movzx r10d, byte [rdi + 2]
    or ecx, r10d
    B64CHAR 18
    B64CHAR 12
    B64CHAR 6
    B64CHAR 0
    add rdi, 3
    sub rsi, 3
    jmp .l3
.tail:
    test rsi, rsi
    jz .done
    movzx ecx, byte [rdi]
    shl ecx, 16
    cmp rsi, 2
    jb .one
    movzx r10d, byte [rdi + 1]
    shl r10d, 8
    or ecx, r10d
    B64CHAR 18
    B64CHAR 12
    B64CHAR 6
    mov byte [r9], '='
    inc r9
    jmp .done
.one:
    B64CHAR 18
    B64CHAR 12
    mov word [r9], '=='
    add r9, 2
.done:
    mov byte [r9], 0
    sub r9, rax
    mov rax, r9
    ret

; ---------------------------------------------------------------------
; size_t token_len(const char *q, size_t rem)
; length of one indivisible unit of JSON-escaped text:
;   \uXXXX (or a full surrogate pair), \X, a UTF-8 sequence, or 1 byte
; ---------------------------------------------------------------------
token_len:
    movzx eax, byte [rdi]
    cmp al, '\'
    je .esc
    cmp al, 0xF0
    jae .u4
    cmp al, 0xE0
    jae .u3
    cmp al, 0xC0
    jae .u2
    mov eax, 1
    ret
.u4:
    mov eax, 4
    jmp .cap
.u3:
    mov eax, 3
    jmp .cap
.u2:
    mov eax, 2
.cap:
    cmp rax, rsi
    jbe .ret
    mov rax, rsi
.ret:
    ret
.esc:
    cmp rsi, 2
    jb .one
    movzx eax, byte [rdi + 1]
    cmp al, 'u'
    jne .two
    cmp rsi, 6
    jb .two
    movzx eax, byte [rdi + 2]
    or eax, 0x20
    cmp al, 'd'
    jne .six
    movzx eax, byte [rdi + 3]
    or eax, 0x20
    cmp al, '8'
    je .hi
    cmp al, '9'
    je .hi
    cmp al, 'a'
    je .hi
    cmp al, 'b'
    jne .six
.hi:
    cmp rsi, 12
    jb .six
    cmp byte [rdi + 6], '\'
    jne .six
    cmp byte [rdi + 7], 'u'
    jne .six
    mov eax, 12
    ret
.six:
    mov eax, 6
    ret
.two:
    mov eax, 2
    ret
.one:
    mov eax, 1
    ret

; ---------------------------------------------------------------------
; size_t chunk_next(const char *p, size_t n, size_t max)
; How many bytes of p to take for the next Discord message part.
; Never cuts inside an escape / UTF-8 sequence, prefers a \n boundary.
; ---------------------------------------------------------------------
global chunk_next
chunk_next:
    ENTER 0
    mov r12, rdi                    ; p
    mov r13, rsi                    ; n
    mov r14, rdx                    ; max
    cmp r13, r14
    jbe .all
    xor r15d, r15d                  ; i
    xor ebx, ebx                    ; last newline boundary
.loop:
    cmp r15, r13
    jae .pick
    lea rdi, [r12 + r15]
    mov rsi, r13
    sub rsi, r15
    call token_len
    lea rcx, [r15 + rax]
    cmp rcx, r14
    ja .pick
    mov r15, rcx
    cmp rax, 2
    jne .loop
    cmp byte [r12 + r15 - 2], '\'
    jne .loop
    cmp byte [r12 + r15 - 1], 'n'
    jne .loop
    mov rbx, r15
    jmp .loop
.pick:
    mov rax, r14
    shr rax, 2                      ; newline boundary must be past 25% of max
    cmp rbx, rax
    jbe .tok
    mov rax, rbx
    jmp .out
.tok:
    mov rax, r15
    test rax, rax
    jnz .out
    mov rax, r14                    ; degenerate: guarantee progress
    jmp .out
.all:
    mov rax, r13
.out:
    LEAVE_RET

section .note.GNU-stack noalloc noexec nowrite progbits
