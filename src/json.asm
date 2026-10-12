; =====================================================================
; json.asm - minimal zero-copy JSON scanner (RFC 8259 grammar)
;
; All values are returned as slices into the original text, still in
; their JSON-escaped form. Strings are returned WITHOUT the quotes.
;
; struct jv { const char *ptr; size_t len; long type; }
;   type: 's' string, 'o' object, 'a' array, 'n' null, 'b' bool, 'd' number
; =====================================================================
%include "defs.inc"

extern memcmp, c_strlen

section .text

; const char *json_skip_ws(const char *p, const char *end)
global json_skip_ws
json_skip_ws:
.l:
    cmp rdi, rsi
    jae .d
    movzx eax, byte [rdi]
    cmp al, ' '
    je .n
    cmp al, 9
    je .n
    cmp al, 10
    je .n
    cmp al, 13
    je .n
.d:
    mov rax, rdi
    ret
.n:
    inc rdi
    jmp .l

; const char *json_str_end(const char *p, const char *end)
; p points at the opening quote; returns pointer to the closing quote or NULL
global json_str_end
json_str_end:
    inc rdi
.l:
    cmp rdi, rsi
    jae .null
    movzx eax, byte [rdi]
    cmp al, '"'
    je .found
    cmp al, '\'
    jne .n
    inc rdi
.n:
    inc rdi
    jmp .l
.found:
    mov rax, rdi
    ret
.null:
    xor eax, eax
    ret

; const char *json_skip_container(const char *p, const char *end)
; p at '{' or '['; returns pointer just after the matching close or NULL
global json_skip_container
json_skip_container:
    push rbx
    mov rbx, rsi                    ; end
    xor ecx, ecx                    ; depth
.l:
    cmp rdi, rbx
    jae .null
    movzx eax, byte [rdi]
    cmp al, '"'
    je .str
    cmp al, '{'
    je .open
    cmp al, '['
    je .open
    cmp al, '}'
    je .close
    cmp al, ']'
    je .close
    inc rdi
    jmp .l
.open:
    inc ecx
    inc rdi
    jmp .l
.close:
    dec ecx
    inc rdi
    test ecx, ecx
    jnz .l
    mov rax, rdi
    pop rbx
    ret
.str:
    mov rsi, rbx
    push rcx
    sub rsp, 8
    call json_str_end
    add rsp, 8
    pop rcx
    test rax, rax
    jz .null
    lea rdi, [rax + 1]
    jmp .l
.null:
    xor eax, eax
    pop rbx
    ret

; const char *json_value(const char *p, const char *end, jv *out)
; parses ONE value starting at p (leading whitespace allowed).
; returns pointer after the value, or NULL on error.
global json_value
json_value:
    ENTER 0
    mov rbx, rdx                    ; out
    mov r12, rsi                    ; end
    call json_skip_ws               ; rdi already p, rsi end
    mov r13, rax                    ; p
    cmp r13, r12
    jae .err
    movzx eax, byte [r13]
    cmp al, '"'
    je .string
    cmp al, '{'
    je .object
    cmp al, '['
    je .array
    cmp al, 't'
    je .true
    cmp al, 'f'
    je .false
    cmp al, 'n'
    je .null
    cmp al, '-'
    je .number
    mov ecx, eax
    sub ecx, '0'
    cmp ecx, 9
    jbe .number
.err:
    xor eax, eax
    LEAVE_RET

.string:
    mov rdi, r13
    mov rsi, r12
    call json_str_end
    test rax, rax
    jz .err
    lea rcx, [r13 + 1]
    mov [rbx + JV_PTR], rcx
    mov rdx, rax
    sub rdx, rcx
    mov [rbx + JV_LEN], rdx
    mov qword [rbx + JV_TYPE], 's'
    lea rax, [rax + 1]
    LEAVE_RET

.object:
    mov r14d, 'o'
    jmp .container
.array:
    mov r14d, 'a'
.container:
    mov rdi, r13
    mov rsi, r12
    call json_skip_container
    test rax, rax
    jz .err
    mov [rbx + JV_PTR], r13
    mov rdx, rax
    sub rdx, r13
    mov [rbx + JV_LEN], rdx
    mov [rbx + JV_TYPE], r14
    LEAVE_RET

.true:
    mov ecx, 4
    mov r14d, 'b'
    jmp .literal
.false:
    mov ecx, 5
    mov r14d, 'b'
    jmp .literal
.null:
    mov ecx, 4
    mov r14d, 'n'
.literal:
    mov rax, r12
    sub rax, r13
    cmp rax, rcx
    jb .err
    mov [rbx + JV_PTR], r13
    mov [rbx + JV_LEN], rcx
    mov [rbx + JV_TYPE], r14
    lea rax, [r13 + rcx]
    LEAVE_RET

.number:
    mov rcx, r13
.nl:
    cmp rcx, r12
    jae .nd
    movzx eax, byte [rcx]
    cmp al, '-'
    je .nn
    cmp al, '+'
    je .nn
    cmp al, '.'
    je .nn
    cmp al, 'e'
    je .nn
    cmp al, 'E'
    je .nn
    mov edx, eax
    sub edx, '0'
    cmp edx, 9
    ja .nd
.nn:
    inc rcx
    jmp .nl
.nd:
    mov [rbx + JV_PTR], r13
    mov rdx, rcx
    sub rdx, r13
    mov [rbx + JV_LEN], rdx
    mov qword [rbx + JV_TYPE], 'd'
    mov rax, rcx
    LEAVE_RET

; int json_get(const char *obj, size_t len, const char *key, jv *out)
; obj/len is a JSON object text; returns 1 and fills *out when key exists
global json_get
json_get:
    ENTER 48                        ; [0..23] temp jv, [24] key ptr, [32] key len
    mov r12, rdi                    ; p
    lea r13, [rdi + rsi]            ; end
    mov r14, rdx                    ; key
    mov r15, rcx                    ; out
    mov rdi, r14
    call c_strlen
    mov rbx, rax                    ; wanted key length
    mov rdi, r12
    mov rsi, r13
    call json_skip_ws
    mov r12, rax
    cmp r12, r13
    jae .no
    cmp byte [r12], '{'
    jne .no
    inc r12
.member:
    mov rdi, r12
    mov rsi, r13
    call json_skip_ws
    mov r12, rax
    cmp r12, r13
    jae .no
    movzx eax, byte [r12]
    cmp al, '}'
    je .no
    cmp al, ','
    jne .key
    inc r12
    jmp .member
.key:
    cmp al, '"'
    jne .no
    mov rdi, r12
    mov rsi, r13
    call json_str_end
    test rax, rax
    jz .no
    lea rcx, [r12 + 1]
    mov [rsp + 24], rcx             ; key text ptr
    mov rdx, rax
    sub rdx, rcx
    mov [rsp + 32], rdx             ; key text len
    lea rdi, [rax + 1]
    mov rsi, r13
    call json_skip_ws
    mov r12, rax
    cmp r12, r13
    jae .no
    cmp byte [r12], ':'
    jne .no
    inc r12
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rsp]
    call json_value
    test rax, rax
    jz .no
    mov r12, rax                    ; position after the value
    cmp [rsp + 32], rbx
    jne .member
    mov rdi, [rsp + 24]
    mov rsi, r14
    mov rdx, rbx
    CALLC memcmp
    test eax, eax
    jnz .member
    mov rax, [rsp]
    mov [r15 + JV_PTR], rax
    mov rax, [rsp + 8]
    mov [r15 + JV_LEN], rax
    mov rax, [rsp + 16]
    mov [r15 + JV_TYPE], rax
    mov eax, 1
    LEAVE_RET
.no:
    xor eax, eax
    LEAVE_RET

; int json_path(const char *obj, size_t len, const char *path, jv *out)
; path is dot separated object keys, e.g. "author.id"
global json_path
json_path:
    ENTER 64                        ; segment buffer
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
.seg:
    xor ecx, ecx
.cp:
    movzx eax, byte [r14 + rcx]
    test al, al
    jz .segend
    cmp al, '.'
    je .segend
    cmp ecx, 62
    jae .fail
    mov [rsp + rcx], al
    inc ecx
    jmp .cp
.segend:
    mov byte [rsp + rcx], 0
    add r14, rcx
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rsp]
    mov rcx, r15
    call json_get
    test eax, eax
    jz .fail
    cmp byte [r14], 0
    je .ok
    cmp qword [r15 + JV_TYPE], 'o'
    jne .fail
    mov r12, [r15 + JV_PTR]
    mov r13, [r15 + JV_LEN]
    inc r14
    jmp .seg
.ok:
    mov eax, 1
    LEAVE_RET
.fail:
    xor eax, eax
    LEAVE_RET

; const char *json_arr_next(const char *cur, const char *end, jv *out)
; cur starts at (array start + 1); returns the cursor for the next call,
; or NULL when the array is exhausted / malformed.
global json_arr_next
json_arr_next:
    push rbx
    mov rbx, rdx
.l:
    call json_skip_ws
    mov rdi, rax
    cmp rdi, rsi
    jae .null
    movzx eax, byte [rdi]
    cmp al, ']'
    je .null
    cmp al, ','
    jne .val
    inc rdi
    jmp .l
.val:
    mov rdx, rbx
    call json_value
    pop rbx
    ret
.null:
    xor eax, eax
    pop rbx
    ret

; int json_true(const jv *v)  -> 1 if type is bool and value is true
global json_true
json_true:
    cmp qword [rdi + JV_TYPE], 'b'
    jne .no
    mov rax, [rdi + JV_PTR]
    cmp byte [rax], 't'
    jne .no
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
