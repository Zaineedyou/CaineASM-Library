; =====================================================================
; upload.asm - file attachments (multipart/form-data) for messages.
; Format per the Discord docs, "Uploading Files":
;   Content-Type: multipart/form-data; boundary=...
;   part  name="payload_json"      Content-Type: application/json   (message JSON + "attachments")
;   parts name="files[n]"; filename="..."   one per file, n matching attachments[].id
;   "attachments":[{"id":n,"filename":"..."}]
; Endpoints that accept it here: create message, edit message (new files
; replace the existing attachments), webhook follow-up and edit-original
; for interactions. Request limit 25 MiB. Embeds can show an uploaded
; image with attachment://<filename> (casm_embed_image).
; A reply handle keeps its files in the files sbuf H_F as records:
;   u64 name_len, u64 ctype_len, u64 data_len, name, ctype, data   (word [72] = file count)
; =====================================================================
%include "defs.inc"

extern getrandom
extern sb_init, sb_free, sb_append, sb_appends, sb_putc, sb_append_u64, sb_append_json_esc
extern c_strlen
extern do_call_mp, ix_path, reply_finish
extern casm_reply_new, casm_reply_content, casm_builder_free, casm_send_reply

%define H_F 80
%define MAX_UPLOAD 26112000             ; 25 MiB request limit minus room for the JSON part

section .rodata
c_q:        db '"', 0
c_dd:       db "--", 0
c_crlf:     db 13, 10, 0
hexd:       db "0123456789abcdef"
j_att:      db ',"attachments":[', 0
j_att_id:   db '{"id":', 0
j_att_fn:   db ',"filename":', 0
j_att_end:  db ']}', 0
h_json:     db 13, 10, 'Content-Disposition: form-data; name="payload_json"', 13, 10
            db 'Content-Type: application/json', 13, 10, 13, 10, 0
h_file1:    db 13, 10, 'Content-Disposition: form-data; name="files[', 0
h_file2:    db ']"; filename="', 0
h_file3:    db '"', 13, 10, 'Content-Type: ', 0
h_end:      db 13, 10, 13, 10, 0
d_octet:    db "application/octet-stream", 0
t_png:      db "png", 0
t_jpg:      db "jpg", 0
t_jpeg:     db "jpeg", 0
t_gif:      db "gif", 0
t_webp:     db "webp", 0
t_txt:      db "txt", 0
t_log:      db "log", 0
t_csv:      db "csv", 0
t_json:     db "json", 0
t_pdf:      db "pdf", 0
t_mp3:      db "mp3", 0
t_mp4:      db "mp4", 0
t_zip:      db "zip", 0
m_png:      db "image/png", 0
m_jpeg:     db "image/jpeg", 0
m_gif:      db "image/gif", 0
m_webp:     db "image/webp", 0
m_txt:      db "text/plain", 0
m_csv:      db "text/csv", 0
m_json:     db "application/json", 0
m_pdf:      db "application/pdf", 0
m_mp3:      db "audio/mpeg", 0
m_mp4:      db "video/mp4", 0
m_zip:      db "application/zip", 0
section .data.rel.ro progbits alloc noexec write align=8   ; pointers live here, not in read-only .rodata (text relocations)
ext_tab:    dq t_png,  m_png
            dq t_jpg,  m_jpeg
            dq t_jpeg, m_jpeg
            dq t_gif,  m_gif
            dq t_webp, m_webp
            dq t_txt,  m_txt
            dq t_log,  m_txt
            dq t_csv,  m_csv
            dq t_json, m_json
            dq t_pdf,  m_pdf
            dq t_mp3,  m_mp3
            dq t_mp4,  m_mp4
            dq t_zip,  m_zip
            dq 0, 0

section .text

; const char *ctype_for(const char *filename)   by extension (case-insensitive), else octet-stream
ctype_for:
    mov rsi, rdi
    xor rdx, rdx                    ; last '.'
.scan:
    movzx eax, byte [rsi]
    test eax, eax
    jz .have
    cmp eax, '.'
    jne .next
    lea rdx, [rsi + 1]
.next:
    inc rsi
    jmp .scan
.have:
    test rdx, rdx
    jz .def
    lea r8, [rel ext_tab]
.ent:
    mov rax, [r8]
    test rax, rax
    jz .def
    mov rsi, rdx
.cmp:
    movzx ecx, byte [rsi]
    movzx edi, byte [rax]
    test edi, edi
    jz .endent
    or ecx, 0x20
    cmp ecx, edi
    jne .nope
    inc rsi
    inc rax
    jmp .cmp
.endent:
    test ecx, ecx
    jnz .nope
    mov rax, [r8 + 8]
    ret
.nope:
    add r8, 16
    jmp .ent
.def:
    lea rax, [rel d_octet]
    ret

; int casm_reply_file(reply *r, const char *filename, const void *data, size_t len, const char *content_type)
; Attach a file to a reply (the bytes are copied). content_type may be NULL (guessed from the extension).
; filename: 1-255 bytes, no control characters, '"', '\\' or '/'. 0 ok, -1 invalid argument / over 25 MiB.
global casm_reply_file
casm_reply_file:
    ENTER 32                        ; [0] name_len, [8] ctype_len, [16] data_len
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
    jnz .hasdata
    test r14, r14
    jnz .bad
.hasdata:
    xor ecx, ecx
.nl:
    movzx eax, byte [r12 + rcx]
    test eax, eax
    jz .nend
    cmp eax, 0x20
    jb .bad
    cmp eax, 0x7F
    je .bad
    cmp eax, '"'
    je .bad
    cmp eax, '\'
    je .bad
    cmp eax, '/'
    je .bad
    inc rcx
    cmp rcx, 255
    ja .bad
    jmp .nl
.nend:
    test rcx, rcx
    jz .bad
    mov [rsp], rcx
    test r15, r15
    jnz .given
    mov rdi, r12
    call ctype_for
    mov r15, rax
.given:
    xor ecx, ecx
    xor edx, edx
.cl:
    movzx eax, byte [r15 + rcx]
    test eax, eax
    jz .cend
    cmp eax, 0x20
    jb .bad
    cmp eax, 0x7F
    je .bad
    cmp eax, '/'
    jne .cn
    mov edx, 1
.cn:
    inc rcx
    cmp rcx, 127
    ja .bad
    jmp .cl
.cend:
    test edx, edx
    jz .bad
    mov [rsp + 8], rcx
    mov [rsp + 16], r14
    mov rax, [rbx + H_F + SB_LEN]
    add rax, r14
    jc .bad
    add rax, 1024
    cmp rax, MAX_UPLOAD
    ja .bad
    cmp word [rbx + 72], 0xFFFF
    je .bad
    lea rdi, [rbx + H_F]
    lea rsi, [rsp]
    mov edx, 24
    call sb_append
    lea rdi, [rbx + H_F]
    mov rsi, r12
    mov rdx, [rsp]
    call sb_append
    lea rdi, [rbx + H_F]
    mov rsi, r15
    mov rdx, [rsp + 8]
    call sb_append
    test r14, r14
    jz .done
    lea rdi, [rbx + H_F]
    mov rsi, r13
    mov rdx, r14
    call sb_append
.done:
    inc word [rbx + 72]
    xor eax, eax
    LEAVE_RET
.bad:
    mov rax, -1
    LEAVE_RET

; long casm_send_file(const char *channel_id, const char *filename, const void *data, size_t len,
;                     const char *content_type /*or NULL*/, const char *text /*or NULL*/)
; One call: a message with one attached file and optional text. HTTP status like casm_send.
global casm_send_file
casm_send_file:
    ENTER 16                        ; [0] reply
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov [rsp + 8], r8
    mov rbx, r9
    call casm_reply_new
    test rax, rax
    jz .bad
    mov [rsp], rax
    test rbx, rbx
    jz .nt
    mov rdi, rbx
    call c_strlen
    mov rdx, rax
    mov rdi, [rsp]
    mov rsi, rbx
    call casm_reply_content
    test rax, rax
    jnz .fail
.nt:
    mov rdi, [rsp]
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    mov r8, [rsp + 8]
    call casm_reply_file
    test rax, rax
    jnz .fail
    mov rdi, r12
    mov rsi, [rsp]
    xor edx, edx
    call casm_send_reply
    mov r12, rax
    mov rdi, [rsp]
    call casm_builder_free
    mov rax, r12
    LEAVE_RET
.fail:
    mov rdi, [rsp]
    call casm_builder_free
.bad:
    mov rax, -1
    LEAVE_RET

; ---------------------------------------------------------------------
; long mp_send(long method, sbuf *path, reply *r, sbuf *json)
; json = the finished message JSON ({...}); sends it plus the reply's files as multipart
; ---------------------------------------------------------------------
global mp_send
mp_send:
    ENTER 96                        ; [0] body, [24] boundary (41 bytes), [72] random, [88] file index
    mov r14, rdi
    mov r13, rsi
    mov rbx, rdx
    mov r12, rcx
    lea rdi, [rsp + 72]
    mov esi, 16
    xor edx, edx
    CALLC getrandom
    cmp rax, 16
    je .rnd
    rdtsc                           ; fallback: not secret, only has to differ from the data
    shl rdx, 32
    or rax, rdx
    mov [rsp + 72], rax
    lea rcx, [rsp]
    xor rax, rcx
    rdtsc
    mov [rsp + 80], rax
.rnd:
    mov rax, "CaineASM"
    mov [rsp + 24], rax
    lea r8, [rel hexd]
    xor ecx, ecx
.hx:
    movzx eax, byte [rsp + 72 + rcx]
    mov edx, eax
    shr edx, 4
    mov dl, [r8 + rdx]
    mov [rsp + 32 + rcx*2], dl
    and eax, 15
    mov al, [r8 + rax]
    mov [rsp + 33 + rcx*2], al
    inc ecx
    cmp ecx, 16
    jb .hx
    mov byte [rsp + 64], 0
    lea rdi, [rsp]
    call sb_init
    ; --B + payload_json header
    lea rdi, [rsp]
    lea rsi, [rel c_dd]
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rsp + 24]
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rel h_json]
    ; h_json starts with CRLF, which is exactly what ends the boundary line
    call sb_appends
    ; message JSON without its closing brace, plus the attachments array
    mov rdx, [r12 + SB_LEN]
    dec rdx
    lea rdi, [rsp]
    mov rsi, [r12 + SB_DATA]
    call sb_append
    lea rdi, [rsp]
    lea rsi, [rel j_att]
    call sb_appends
    mov r15, [rbx + H_F + SB_DATA]
    mov qword [rsp + 88], 0
.att:
    movzx eax, word [rbx + 72]
    cmp [rsp + 88], rax
    jae .attend
    cmp qword [rsp + 88], 0
    je .a1
    lea rdi, [rsp]
    mov esi, ','
    call sb_putc
.a1:
    lea rdi, [rsp]
    lea rsi, [rel j_att_id]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, [rsp + 88]
    call sb_append_u64
    lea rdi, [rsp]
    lea rsi, [rel j_att_fn]
    call sb_appends
    lea rdi, [rsp]
    mov esi, '"'
    call sb_putc
    lea rdi, [rsp]
    lea rsi, [r15 + 24]
    mov rdx, [r15]
    call sb_append_json_esc
    lea rdi, [rsp]
    mov esi, '"'
    call sb_putc
    lea rdi, [rsp]
    mov esi, '}'
    call sb_putc
    mov rax, [r15]
    add rax, [r15 + 8]
    add rax, [r15 + 16]
    lea r15, [r15 + rax + 24]
    inc qword [rsp + 88]
    jmp .att
.attend:
    lea rdi, [rsp]
    lea rsi, [rel j_att_end]
    call sb_appends
    ; files
    mov r15, [rbx + H_F + SB_DATA]
    mov qword [rsp + 88], 0
.file:
    movzx eax, word [rbx + 72]
    cmp [rsp + 88], rax
    jae .fend
    lea rdi, [rsp]
    lea rsi, [rel c_crlf]
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rel c_dd]
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rsp + 24]
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rel h_file1]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, [rsp + 88]
    call sb_append_u64
    lea rdi, [rsp]
    lea rsi, [rel h_file2]
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [r15 + 24]
    mov rdx, [r15]
    call sb_append
    lea rdi, [rsp]
    lea rsi, [rel h_file3]
    call sb_appends
    lea rdi, [rsp]
    mov rsi, [r15]
    lea rsi, [r15 + rsi + 24]
    mov rdx, [r15 + 8]
    call sb_append
    lea rdi, [rsp]
    lea rsi, [rel h_end]
    call sb_appends
    mov rdx, [r15 + 16]
    test rdx, rdx
    jz .nodata
    lea rdi, [rsp]
    mov rsi, [r15]
    add rsi, [r15 + 8]
    lea rsi, [r15 + rsi + 24]
    call sb_append
.nodata:
    mov rax, [r15]
    add rax, [r15 + 8]
    add rax, [r15 + 16]
    lea r15, [r15 + rax + 24]
    inc qword [rsp + 88]
    jmp .file
.fend:
    lea rdi, [rsp]
    lea rsi, [rel c_crlf]
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rel c_dd]
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rsp + 24]
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rel c_dd]
    call sb_appends
    lea rdi, [rsp]
    lea rsi, [rel c_crlf]
    call sb_appends
    mov rdi, r14
    mov rsi, r13
    lea rdx, [rsp]
    lea rcx, [rsp + 24]
    call do_call_mp
    mov r12, rax
    lea rdi, [rsp]
    call sb_free
    mov rax, r12
    LEAVE_RET

; ---------------------------------------------------------------------
; long ix_reply_mp(long method, const casm_interaction *i, long kind, reply *r)
; follow-up (kind 1) / edit original (kind 2) with files
; ---------------------------------------------------------------------
global ix_reply_mp
ix_reply_mp:
    ENTER 56                        ; [0] path, [24] json
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rbx, rcx
    lea rdi, [rsp]
    call sb_init
    lea rdi, [rsp + 24]
    call sb_init
    lea rdi, [rsp]
    mov rsi, r13
    mov rdx, r14
    call ix_path
    test rax, rax
    jnz .bad
    mov rdi, rbx
    lea rsi, [rsp + 24]
    xor edx, edx
    call reply_finish
    mov rdi, r12
    lea rsi, [rsp]
    mov rdx, rbx
    lea rcx, [rsp + 24]
    call mp_send
    mov r12, rax
    lea rdi, [rsp]
    call sb_free
    lea rdi, [rsp + 24]
    call sb_free
    mov rax, r12
    LEAVE_RET
.bad:
    lea rdi, [rsp]
    call sb_free
    lea rdi, [rsp + 24]
    call sb_free
    mov rax, -1
    LEAVE_RET

section .note.GNU-stack noalloc noexec nowrite progbits
