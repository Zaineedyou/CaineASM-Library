; =====================================================================
; crash.asm - optional crash reporter: casm_set_crash_handler(1)
;   On SIGSEGV / SIGBUS / SIGFPE / SIGILL / SIGABRT it writes the signal, the fault
;   address, the instruction pointer and a backtrace to stderr, then lets the
;   default action run (the process still dies and still dumps core).
;   Documented pieces only: sigaction (SA_SIGINFO | SA_ONSTACK | SA_RESETHAND),
;   sigaltstack, write(2), mincore(2) as a safe "is this address readable" probe,
;   backtrace_symbols_fd(3). The frames come from the rbp chain: every function in
;   this library keeps a frame pointer (glibc's backtrace() needs unwind tables
;   that hand-written assembly does not have).
; =====================================================================
%include "defs.inc"

extern sigaction, sigaltstack, write, mincore, backtrace_symbols_fd, open, close
extern c_strlen

%define ALT_SIZE 131072

section .bss
alignb 16
cr_stack:    resb ALT_SIZE

section .rodata
cr_head:     db 10, "💥 CaineASM crash: ", 0
cr_n11:      db "SIGSEGV (invalid memory access)", 0
cr_n7:       db "SIGBUS (bus error)", 0
cr_n8:       db "SIGFPE (arithmetic error)", 0
cr_n4:       db "SIGILL (illegal instruction)", 0
cr_n6:       db "SIGABRT (abort)", 0
cr_nx:       db "signal", 0
cr_at:       db ", fault address 0x", 0
cr_ip:       db ", instruction 0x", 0
cr_bt:       db "backtrace (addr2line -f -e <binary> <+offset>):", 10, 0
cr_nl:       db 10, 0
cr_null:     db "/dev/null", 0
cr_sigs:     dd 11, 7, 8, 4, 6

section .text

; void wr_cstr(const char *s)   write(2, s, strlen(s))
wr_cstr:
    ENTER 0
    mov r12, rdi
    call c_strlen
    mov edi, 2
    mov rsi, r12
    mov rdx, rax
    CALLC write
    LEAVE_RET

; void wr_hex(unsigned long v)   lower-case hex, no prefix
wr_hex:
    ENTER 32
    mov rax, rdi
    lea rcx, [rsp + 24]
.l:
    mov edx, eax
    and edx, 15
    add edx, '0'
    cmp edx, '9'
    jbe .s
    add edx, 39
.s:
    dec rcx
    mov [rcx], dl
    shr rax, 4
    jnz .l
    lea rdx, [rsp + 24]
    sub rdx, rcx
    mov rsi, rcx
    mov edi, 2
    CALLC write
    LEAVE_RET

; int probe(const void *p)   1 when the 16 bytes at p (16-aligned) are mapped
probe:
    ENTER 16
    and rdi, -4096
    mov esi, 1
    lea rdx, [rsp]
    CALLC mincore
    test eax, eax
    sete al
    movzx eax, al
    LEAVE_RET

; void crash_handler(int sig, siginfo_t *info, void *ucontext)
crash_handler:
    ENTER 288                        ; [0..256) frames
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
    lea rdi, [rel cr_head]
    call wr_cstr
    lea rdi, [rel cr_nx]
    cmp r12d, 11
    lea rax, [rel cr_n11]
    cmove rdi, rax
    cmp r12d, 7
    lea rax, [rel cr_n7]
    cmove rdi, rax
    cmp r12d, 8
    lea rax, [rel cr_n8]
    cmove rdi, rax
    cmp r12d, 4
    lea rax, [rel cr_n4]
    cmove rdi, rax
    cmp r12d, 6
    lea rax, [rel cr_n6]
    cmove rdi, rax
    call wr_cstr
    lea rdi, [rel cr_at]
    call wr_cstr
    mov rdi, [r13 + 16]              ; si_addr
    call wr_hex
    lea rdi, [rel cr_ip]
    call wr_cstr
    mov rdi, [r14 + 168]             ; gregs[REG_RIP]
    call wr_hex
    lea rdi, [rel cr_nl]
    call wr_cstr
    ; frames: rip, then the return addresses along the rbp chain
    mov rax, [r14 + 168]
    mov [rsp], rax
    mov ebx, 1
    mov r15, [r14 + 120]             ; gregs[REG_RBP]
    mov r13, [r14 + 160]             ; gregs[REG_RSP]
.walk:
    cmp ebx, 32
    jae .done
    test r15, 15
    jnz .done
    cmp r15, r13
    jb .done
    mov rax, r15
    sub rax, r13
    cmp rax, 0x800000
    ja .done
    mov rdi, r15
    call probe
    test eax, eax
    jz .done
    mov rax, [r15 + 8]
    test rax, rax
    jz .done
    mov [rsp + rbx*8], rax
    inc ebx
    mov rax, [r15]
    cmp rax, r15
    jbe .done
    mov r15, rax
    jmp .walk
.done:
    lea rdi, [rel cr_bt]
    call wr_cstr
    lea rdi, [rsp]
    mov esi, ebx
    mov edx, 2
    CALLC backtrace_symbols_fd
    LEAVE_RET                        ; SA_RESETHAND: the default action runs next

; int casm_set_crash_handler(int enable)
; 1 installs the handlers (call it from the thread that runs casm_run: the alternate
; signal stack is per thread, it lets stack overflows be reported too), 0 restores the
; default actions. Returns 0, or -1 when a system call failed.
global casm_set_crash_handler
casm_set_crash_handler:
    ENTER 192                        ; [0..152) sigaction, [160..184) stack_t
    mov r12d, edi
    xor r13d, r13d                   ; error flag
    test r12d, r12d
    jz .sigs
    ; warm up backtrace_symbols_fd (it may load libraries on first use)
    lea rdi, [rel cr_null]
    mov esi, 1
    CALLC open
    test eax, eax
    js .alt
    mov r14d, eax
    lea rax, [rel casm_set_crash_handler]
    mov [rsp + 160], rax
    lea rdi, [rsp + 160]
    mov esi, 1
    mov edx, r14d
    CALLC backtrace_symbols_fd
    mov edi, r14d
    CALLC close
.alt:
    lea rax, [rel cr_stack]
    mov [rsp + 160], rax
    mov qword [rsp + 168], 0
    mov qword [rsp + 176], ALT_SIZE
    lea rdi, [rsp + 160]
    xor esi, esi
    CALLC sigaltstack
    test eax, eax
    jz .sigs
    mov r13d, 1
.sigs:
    xor ebx, ebx
.l:
    lea rdi, [rsp]
    xor eax, eax
    mov ecx, 19
    rep stosq                        ; zero the 152-byte sigaction
    test r12d, r12d
    jz .go
    lea rax, [rel crash_handler]
    mov [rsp], rax
    mov dword [rsp + 136], 0x88000004      ; SA_SIGINFO | SA_ONSTACK | SA_RESETHAND
.go:
    lea rax, [rel cr_sigs]
    mov edi, [rax + rbx*4]
    lea rsi, [rsp]
    xor edx, edx
    CALLC sigaction
    test eax, eax
    jz .n
    mov r13d, 1
.n:
    inc ebx
    cmp ebx, 5
    jb .l
    mov eax, r13d
    neg eax
    LEAVE_RET

section .note.GNU-stack noalloc noexec nowrite progbits
