; =====================================================================
; CaineASM Lite - shared definitions
; NASM, x86-64, System V AMD64 ABI, Linux
; =====================================================================
%ifndef DEFS_INC
%define DEFS_INC

default rel

; ---- libcurl constants (checked against curl 8.5.0 include/curl/curl.h) ----
%define CURLOPT_WRITEDATA        10001
%define CURLOPT_HEADERDATA       10029
%define CURLOPT_HEADERFUNCTION   20079
%define CURLOPT_URL              10002
%define CURLOPT_ERRORBUFFER      10010
%define CURLOPT_WRITEFUNCTION    20011
%define CURLOPT_TIMEOUT          13
%define CURLOPT_POSTFIELDS       10015
%define CURLOPT_USERAGENT        10018
%define CURLOPT_HTTPHEADER       10023
%define CURLOPT_CUSTOMREQUEST    10036
%define CURLOPT_POST             47
%define CURLOPT_POSTFIELDSIZE    60
%define CURLOPT_CAINFO           10065
%define CURLOPT_CONNECTTIMEOUT   78
%define CURLOPT_HTTPGET          80
%define CURLOPT_HTTP_VERSION     84
%define CURLOPT_NOSIGNAL         99
%define CURLOPT_TCP_NODELAY      121
%define CURLOPT_CONNECT_ONLY     141
%define CURLINFO_RESPONSE_CODE   0x200002
%define CURLINFO_ACTIVESOCKET    0x50002C
%define CURLE_OK                 0
%define CURLE_AGAIN              81
%define CURL_HTTP_VERSION_1_1    2
%define CURL_GLOBAL_DEFAULT      3

; ---- libc / kernel constants ----
%define CLOCK_MONOTONIC 1
%define POLLIN   1
%define POLLOUT  4
%define POLLERR  8
%define POLLHUP  16
%define SIGINT   2
%define SIGPIPE  13
%define SIGTERM  15
%define SIG_IGN  1
%define STDOUT   1
%define STDERR   2

; ---- Discord gateway intents: GUILDS|GUILD_MESSAGES|DIRECT_MESSAGES|MESSAGE_CONTENT ----

; ---- struct sbuf { char *data; size_t len; size_t cap; } ----
%define SB_DATA 0
%define SB_LEN  8
%define SB_CAP  16
%define SB_SIZE 24

; ---- struct jv { const char *ptr; size_t len; long type; } ----
%define JV_PTR  0
%define JV_LEN  8
%define JV_TYPE 16
%define JV_SIZE 24

; ---- struct job (one inbound Discord message that triggered the bot) ----

; ---------------------------------------------------------------------
; Function frame helpers.
; ENTER n  : saves rbp + 5 callee-saved regs, reserves >= n bytes of
;            locals addressed as [rsp+0 .. rsp+n-1]. rsp is 16-aligned
;            afterwards, so calls can be made directly.
; LEAVE_RET: restores everything and returns.
; ---------------------------------------------------------------------
%macro ENTER 1
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, (((%1) + 15) & ~15) + 8
%endmacro

%macro LEAVE_RET 0
    lea rsp, [rbp-40]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
%endmacro

; call a libc / libcurl function through the PLT (PIE safe)
%macro CALLC 1
    call %1 wrt ..plt
%endmacro

; lower-case an ASCII letter held in 32-bit reg %1 (scratch %2)
%macro LOWER 2
    lea %2, [%1-65]
    cmp %2, 25
    ja %%no
    add %1, 32
%%no:
%endmacro

; curl_easy_setopt(handle in r12, %1 = option, %2 = value (imm/reg/mem))
%macro SETOPT 2
    mov rdi, r12
    mov esi, %1
    mov rdx, %2
    xor eax, eax
    CALLC curl_easy_setopt
%endmacro

; curl_easy_setopt with address of a static symbol
%macro SETOPT_SYM 2
    mov rdi, r12
    mov esi, %1
    lea rdx, [rel %2]
    xor eax, eax
    CALLC curl_easy_setopt
%endmacro

%endif
