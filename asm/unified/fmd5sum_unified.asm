; fmd5sum_unified.asm
; Hand-crafted minimal ELF binary for fmd5sum
; Fully self-contained — no libc, no linker needed
; Build: nasm -f bin fmd5sum_unified.asm -o fmd5sum && chmod +x fmd5sum

BITS 64
org 0x400000

; ── System constants ──
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXIT       60
%define SYS_RT_SIGPROCMASK 14

%define STDIN           0
%define STDOUT          1
%define STDERR          2
%define O_RDONLY        0
%define EINTR           4
%define IO_SIZE     65536

; ── Macros ──
%macro WRITE 3
    mov rax, SYS_WRITE
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    syscall
%endmacro

%macro EXIT 1
    mov rax, SYS_EXIT
    mov rdi, %1
    syscall
%endmacro

; MD5 round macros (fully unrolled, no branches)
%macro ROUND_F 7
    mov r8d, %4
    xor r8d, %3
    and r8d, %2
    xor r8d, %4
    add %1, r8d
    add %1, dword [r14 + 4*%5]
    add %1, %7
    rol %1, %6
    add %1, %2
%endmacro

%macro ROUND_G 7
    mov r8d, %2
    xor r8d, %3
    and r8d, %4
    xor r8d, %3
    add %1, r8d
    add %1, dword [r14 + 4*%5]
    add %1, %7
    rol %1, %6
    add %1, %2
%endmacro

%macro ROUND_H 7
    mov r8d, %2
    xor r8d, %3
    xor r8d, %4
    add %1, r8d
    add %1, dword [r14 + 4*%5]
    add %1, %7
    rol %1, %6
    add %1, %2
%endmacro

%macro ROUND_I 7
    mov r8d, %4
    not r8d
    or  r8d, %2
    xor r8d, %3
    add %1, r8d
    add %1, dword [r14 + 4*%5]
    add %1, %7
    rol %1, %6
    add %1, %2
%endmacro

; BSS layout constants (must be before ELF headers that reference them)
%define BSS_BASE     0x500000
%define io_buf       BSS_BASE
%define io_buf2      (BSS_BASE + IO_SIZE)
%define out_buf      (BSS_BASE + IO_SIZE*2)
%define line_buf     (BSS_BASE + IO_SIZE*2 + 4096)
%define hash_state   (BSS_BASE + IO_SIZE*3 + 4096)
%define msg_len      (hash_state + 16)
%define block_buf    (msg_len + 8)
%define block_used   (block_buf + 64)
%define hex_out      (block_used + 4)
%define fname_buf    (hex_out + 33)
%define num_buf      (fname_buf + 4096)
%define flag_binary  (num_buf + 32)
%define flag_check   (flag_binary + 1)
%define flag_tag     (flag_check + 1)
%define flag_text    (flag_tag + 1)
%define flag_ignore  (flag_text + 1)
%define flag_quiet   (flag_ignore + 1)
%define flag_status  (flag_quiet + 1)
%define flag_strict  (flag_status + 1)
%define flag_warn    (flag_strict + 1)
%define flag_zero    (flag_warn + 1)
%define cnt_ok       (flag_zero + 4)
%define cnt_mismatch (cnt_ok + 4)
%define cnt_format_err (cnt_mismatch + 4)
%define cnt_read_err (cnt_format_err + 4)
%define cnt_ignored  (cnt_read_err + 4)
%define had_error    (cnt_ignored + 4)
%define argc_save    (had_error + 4)
%define argv_save    (argc_save + 8)
%define file_args    (argv_save + 8)
%define file_count   (file_args + 256*8)
%define BSS_END      (file_count + 4)
%define BSS_SIZE     (BSS_END - BSS_BASE)

; ── ELF Header ──
ehdr:
    db 0x7F, "ELF"
    db 2, 1, 1, 0
    dq 0
    dw 2
    dw 0x3E
    dd 1
    dq _start
    dq phdr - ehdr
    dq 0
    dd 0
    dw ehdr_end - ehdr
    dw phdr_size
    dw 3
    dw 0, 0, 0
ehdr_end:

; ── Program Headers ──
phdr:
    ; PT_LOAD: code + data (R+X)
    dd 1
    dd 5
    dq 0
    dq 0x400000
    dq 0x400000
    dq file_end - ehdr
    dq file_end - ehdr
    dq 0x1000
phdr_size equ $ - phdr

    ; PT_LOAD: BSS (R+W)
    dd 1
    dd 6
    dq 0
    dq BSS_BASE
    dq BSS_BASE
    dq 0
    dq BSS_SIZE
    dq 0x1000

    ; PT_GNU_STACK (NX)
    dd 0x6474E551
    dd 6
    dq 0, 0, 0, 0, 0
    dq 0x10

; ════════════════════════════════════════════════════════════════
; CODE
; ════════════════════════════════════════════════════════════════

_start:
    ; Block SIGPIPE
    sub     rsp, 16
    mov     qword [rsp], 0x1000
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    ; Save argc/argv
    mov     eax, [rsp]
    mov     [argc_save], eax
    lea     rax, [rsp + 8]
    mov     [argv_save], rax

    call    parse_args

    ; Validate --tag + --check conflict
    cmp     byte [flag_tag], 0
    je      .no_tc
    cmp     byte [flag_check], 0
    je      .no_tc
    WRITE   STDERR, err_tag_check, err_tag_check_len
    EXIT    1
.no_tc:

    cmp     byte [flag_check], 0
    jne     do_check_mode

    ; Default to stdin
    cmp     dword [file_count], 0
    jne     .has_files
    mov     qword [file_args], str_dash
    mov     dword [file_count], 1
.has_files:
    xor     r12d, r12d
.hash_loop:
    cmp     r12d, [file_count]
    jge     .hash_done
    mov     rdi, [file_args + r12*8]
    call    hash_one_file
    inc     r12d
    jmp     .hash_loop
.hash_done:
    movzx   edi, byte [had_error]
    EXIT    rdi

; ── Argument parser ──
parse_args:
    push    rbx
    push    r12
    push    r13
    mov     r12, [argv_save]
    mov     r13d, [argc_save]
    xor     ebx, ebx
    inc     ebx
    xor     ecx, ecx
    mov     dword [file_count], 0
.arg_loop:
    cmp     ebx, r13d
    jge     .arg_done
    mov     rsi, [r12 + rbx*8]
    test    ecx, ecx
    jnz     .add_file
    cmp     word [rsi], 0x2D2D
    jne     .not_dd
    cmp     byte [rsi+2], 0
    jne     .not_dd
    mov     ecx, 1
    inc     ebx
    jmp     .arg_loop
.not_dd:
    cmp     byte [rsi], '-'
    jne     .add_file
    cmp     byte [rsi+1], 0
    je      .add_file
    cmp     byte [rsi+1], '-'
    je      .long_opt
    inc     rsi
.short_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .next_arg
    cmp     al, 'b'
    je      .sb
    cmp     al, 'c'
    je      .sc
    cmp     al, 't'
    je      .st
    cmp     al, 'w'
    je      .sw
    cmp     al, 'z'
    je      .sz
    sub     rsp, 8
    mov     [rsp], al
    WRITE   STDERR, err_inval, err_inval_len
    WRITE   STDERR, rsp, 1
    add     rsp, 8
    WRITE   STDERR, err_suffix, err_suffix_len
    EXIT    1
.sb: mov byte [flag_binary], 1
    inc rsi
    jmp .short_loop
.sc: mov byte [flag_check], 1
    inc rsi
    jmp .short_loop
.st: mov byte [flag_text], 1
    inc rsi
    jmp .short_loop
.sw: mov byte [flag_warn], 1
    inc rsi
    jmp .short_loop
.sz: mov byte [flag_zero], 1
    inc rsi
    jmp .short_loop
.long_opt:
    push    rcx
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_binary]
    call    strcmp
    test    eax, eax
    jz      .lo_binary
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_check]
    call    strcmp
    test    eax, eax
    jz      .lo_check
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_tag]
    call    strcmp
    test    eax, eax
    jz      .lo_tag
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_text]
    call    strcmp
    test    eax, eax
    jz      .lo_text
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_ignore_missing]
    call    strcmp
    test    eax, eax
    jz      .lo_ignore
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_quiet]
    call    strcmp
    test    eax, eax
    jz      .lo_quiet
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_status]
    call    strcmp
    test    eax, eax
    jz      .lo_status
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_strict]
    call    strcmp
    test    eax, eax
    jz      .lo_strict
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_warn]
    call    strcmp
    test    eax, eax
    jz      .lo_warn_s
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_zero]
    call    strcmp
    test    eax, eax
    jz      .lo_zero
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_help]
    call    strcmp
    test    eax, eax
    jz      .lo_help
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_version]
    call    strcmp
    test    eax, eax
    jz      .lo_version
    pop     rcx
    WRITE   STDERR, err_unrec, err_unrec_len
    mov     rdi, [r12 + rbx*8]
    call    strlen
    mov     rdx, rax
    mov     rsi, [r12 + rbx*8]
    WRITE   STDERR, rsi, rdx
    WRITE   STDERR, err_suffix, err_suffix_len
    EXIT    1
.lo_binary: pop rcx
    mov byte [flag_binary], 1
    jmp .next_arg
.lo_check: pop rcx
    mov byte [flag_check], 1
    jmp .next_arg
.lo_tag: pop rcx
    mov byte [flag_tag], 1
    jmp .next_arg
.lo_text: pop rcx
    mov byte [flag_text], 1
    jmp .next_arg
.lo_ignore: pop rcx
    mov byte [flag_ignore], 1
    jmp .next_arg
.lo_quiet: pop rcx
    mov byte [flag_quiet], 1
    jmp .next_arg
.lo_status: pop rcx
    mov byte [flag_status], 1
    jmp .next_arg
.lo_strict: pop rcx
    mov byte [flag_strict], 1
    jmp .next_arg
.lo_warn_s: pop rcx
    mov byte [flag_warn], 1
    jmp .next_arg
.lo_zero: pop rcx
    mov byte [flag_zero], 1
    jmp .next_arg
.lo_help: pop rcx
    WRITE STDOUT, str_help, str_help_len
    EXIT 0
.lo_version: pop rcx
    WRITE STDOUT, str_version, str_version_len
    EXIT 0
.add_file:
    mov     eax, [file_count]
    cmp     eax, 255
    jge     .next_arg
    mov     [file_args + rax*8], rsi
    inc     dword [file_count]
.next_arg:
    inc     ebx
    jmp     .arg_loop
.arg_done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── String comparison ──
strcmp:
.loop:
    movzx eax, byte [rdi]
    movzx ecx, byte [rsi]
    cmp al, cl
    jne .diff
    test al, al
    jz .eq
    inc rdi
    inc rsi
    jmp .loop
.eq: xor eax, eax
    ret
.diff: mov eax, 1
    ret

; ── String length ──
strlen:
    xor eax, eax
.loop:
    cmp byte [rdi + rax], 0
    je .done
    inc rax
    jmp .loop
.done: ret

; ── Write all bytes ──
write_all:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
.loop:
    test r13, r13
    jle .done
    mov rax, SYS_WRITE
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    syscall
    cmp rax, -EINTR
    je .loop
    test rax, rax
    js .done
    add r12, rax
    sub r13, rax
    jmp .loop
.done:
    pop r13
    pop r12
    pop rbx
    ret

; ── MD5 Init ──
md5_init:
    mov dword [hash_state], 0x67452301
    mov dword [hash_state+4], 0xefcdab89
    mov dword [hash_state+8], 0x98badcfe
    mov dword [hash_state+12], 0x10325476
    mov qword [msg_len], 0
    mov dword [block_used], 0
    ret

; ── MD5 Transform (fully unrolled) ──
md5_transform:
    push rbx
    push r14
    mov r14, rdi
    mov eax, [hash_state]
    mov ebx, [hash_state+4]
    mov ecx, [hash_state+8]
    mov edx, [hash_state+12]
    push rax
    push rbx
    push rcx
    push rdx

    ROUND_F eax,ebx,ecx,edx, 0, 7,0xd76aa478
    ROUND_F edx,eax,ebx,ecx, 1,12,0xe8c7b756
    ROUND_F ecx,edx,eax,ebx, 2,17,0x242070db
    ROUND_F ebx,ecx,edx,eax, 3,22,0xc1bdceee
    ROUND_F eax,ebx,ecx,edx, 4, 7,0xf57c0faf
    ROUND_F edx,eax,ebx,ecx, 5,12,0x4787c62a
    ROUND_F ecx,edx,eax,ebx, 6,17,0xa8304613
    ROUND_F ebx,ecx,edx,eax, 7,22,0xfd469501
    ROUND_F eax,ebx,ecx,edx, 8, 7,0x698098d8
    ROUND_F edx,eax,ebx,ecx, 9,12,0x8b44f7af
    ROUND_F ecx,edx,eax,ebx,10,17,0xffff5bb1
    ROUND_F ebx,ecx,edx,eax,11,22,0x895cd7be
    ROUND_F eax,ebx,ecx,edx,12, 7,0x6b901122
    ROUND_F edx,eax,ebx,ecx,13,12,0xfd987193
    ROUND_F ecx,edx,eax,ebx,14,17,0xa679438e
    ROUND_F ebx,ecx,edx,eax,15,22,0x49b40821

    ROUND_G eax,ebx,ecx,edx, 1, 5,0xf61e2562
    ROUND_G edx,eax,ebx,ecx, 6, 9,0xc040b340
    ROUND_G ecx,edx,eax,ebx,11,14,0x265e5a51
    ROUND_G ebx,ecx,edx,eax, 0,20,0xe9b6c7aa
    ROUND_G eax,ebx,ecx,edx, 5, 5,0xd62f105d
    ROUND_G edx,eax,ebx,ecx,10, 9,0x02441453
    ROUND_G ecx,edx,eax,ebx,15,14,0xd8a1e681
    ROUND_G ebx,ecx,edx,eax, 4,20,0xe7d3fbc8
    ROUND_G eax,ebx,ecx,edx, 9, 5,0x21e1cde6
    ROUND_G edx,eax,ebx,ecx,14, 9,0xc33707d6
    ROUND_G ecx,edx,eax,ebx, 3,14,0xf4d50d87
    ROUND_G ebx,ecx,edx,eax, 8,20,0x455a14ed
    ROUND_G eax,ebx,ecx,edx,13, 5,0xa9e3e905
    ROUND_G edx,eax,ebx,ecx, 2, 9,0xfcefa3f8
    ROUND_G ecx,edx,eax,ebx, 7,14,0x676f02d9
    ROUND_G ebx,ecx,edx,eax,12,20,0x8d2a4c8a

    ROUND_H eax,ebx,ecx,edx, 5, 4,0xfffa3942
    ROUND_H edx,eax,ebx,ecx, 8,11,0x8771f681
    ROUND_H ecx,edx,eax,ebx,11,16,0x6d9d6122
    ROUND_H ebx,ecx,edx,eax,14,23,0xfde5380c
    ROUND_H eax,ebx,ecx,edx, 1, 4,0xa4beea44
    ROUND_H edx,eax,ebx,ecx, 4,11,0x4bdecfa9
    ROUND_H ecx,edx,eax,ebx, 7,16,0xf6bb4b60
    ROUND_H ebx,ecx,edx,eax,10,23,0xbebfbc70
    ROUND_H eax,ebx,ecx,edx,13, 4,0x289b7ec6
    ROUND_H edx,eax,ebx,ecx, 0,11,0xeaa127fa
    ROUND_H ecx,edx,eax,ebx, 3,16,0xd4ef3085
    ROUND_H ebx,ecx,edx,eax, 6,23,0x04881d05
    ROUND_H eax,ebx,ecx,edx, 9, 4,0xd9d4d039
    ROUND_H edx,eax,ebx,ecx,12,11,0xe6db99e5
    ROUND_H ecx,edx,eax,ebx,15,16,0x1fa27cf8
    ROUND_H ebx,ecx,edx,eax, 2,23,0xc4ac5665

    ROUND_I eax,ebx,ecx,edx, 0, 6,0xf4292244
    ROUND_I edx,eax,ebx,ecx, 7,10,0x432aff97
    ROUND_I ecx,edx,eax,ebx,14,15,0xab9423a7
    ROUND_I ebx,ecx,edx,eax, 5,21,0xfc93a039
    ROUND_I eax,ebx,ecx,edx,12, 6,0x655b59c3
    ROUND_I edx,eax,ebx,ecx, 3,10,0x8f0ccc92
    ROUND_I ecx,edx,eax,ebx,10,15,0xffeff47d
    ROUND_I ebx,ecx,edx,eax, 1,21,0x85845dd1
    ROUND_I eax,ebx,ecx,edx, 8, 6,0x6fa87e4f
    ROUND_I edx,eax,ebx,ecx,15,10,0xfe2ce6e0
    ROUND_I ecx,edx,eax,ebx, 6,15,0xa3014314
    ROUND_I ebx,ecx,edx,eax,13,21,0x4e0811a1
    ROUND_I eax,ebx,ecx,edx, 4, 6,0xf7537e82
    ROUND_I edx,eax,ebx,ecx,11,10,0xbd3af235
    ROUND_I ecx,edx,eax,ebx, 2,15,0x2ad7d2bb
    ROUND_I ebx,ecx,edx,eax, 9,21,0xeb86d391

    pop r8
    add edx, r8d
    pop r8
    add ecx, r8d
    pop r8
    add ebx, r8d
    pop r8
    add eax, r8d
    mov [hash_state], eax
    mov [hash_state+4], ebx
    mov [hash_state+8], ecx
    mov [hash_state+12], edx
    pop r14
    pop rbx
    ret

; ── MD5 Update ──
md5_update:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    add [msg_len], r13
    mov eax, [block_used]
    test eax, eax
    jz .full_blocks
    mov ecx, 64
    sub ecx, eax
    cmp r13, rcx
    jl .partial_only
    lea rdi, [block_buf + rax]
    mov rsi, r12
    ; ecx already = 64 - block_used (bytes to fill)
    push rcx
    rep movsb
    pop rcx
    add r12, rcx
    sub r13, rcx
    mov dword [block_used], 0
    mov rdi, block_buf
    call md5_transform
    jmp .full_blocks
.partial_only:
    lea rdi, [block_buf + rax]
    mov rsi, r12
    mov rcx, r13
    rep movsb
    add eax, r13d
    mov [block_used], eax
    jmp .update_done
.full_blocks:
    cmp r13, 64
    jl .remaining
    mov rdi, r12
    call md5_transform
    add r12, 64
    sub r13, 64
    jmp .full_blocks
.remaining:
    test r13, r13
    jz .update_done
    mov rdi, block_buf
    mov rsi, r12
    mov rcx, r13
    rep movsb
    mov [block_used], r13d
.update_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ── MD5 Final ──
md5_final:
    push rbx
    mov eax, [block_used]
    mov byte [block_buf + rax], 0x80
    inc eax
    cmp eax, 56
    jle .pad_zeros
    mov rdi, block_buf
    add rdi, rax
    mov ecx, 64
    sub ecx, eax
    xor al, al
    rep stosb
    mov rdi, block_buf
    call md5_transform
    xor eax, eax
.pad_zeros:
    mov rdi, block_buf
    add rdi, rax
    mov ecx, 56
    sub ecx, eax
    xor al, al
    rep stosb
    mov rax, [msg_len]
    shl rax, 3
    mov [block_buf + 56], rax
    mov rdi, block_buf
    call md5_transform
    pop rbx
    ret

; ── MD5 to hex ──
md5_to_hex:
    xor ecx, ecx
.loop:
    cmp ecx, 16
    jge .done
    movzx eax, byte [hash_state + rcx]
    mov edx, eax
    shr edx, 4
    movzx edx, byte [hex_digits + rdx]
    mov [hex_out + rcx*2], dl
    and eax, 0x0F
    movzx eax, byte [hex_digits + rax]
    mov [hex_out + rcx*2 + 1], al
    inc ecx
    jmp .loop
.done:
    mov byte [hex_out + 32], 0
    ret

; ── Hash one file ──
hash_one_file:
    push rbx
    push r12
    push r13
    mov r12, rdi
    call md5_init
    cmp byte [r12], '-'
    jne .open_file
    cmp byte [r12+1], 0
    jne .open_file
    xor ebx, ebx
    jmp .read_loop
.open_file:
    mov rax, SYS_OPEN
    mov rdi, r12
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .open_error
    mov ebx, eax
.read_loop:
    mov rax, SYS_READ
    mov edi, ebx
    mov rsi, io_buf
    mov edx, IO_SIZE
    syscall
    cmp rax, -EINTR
    je .read_loop
    test rax, rax
    js .read_error
    jz .read_done
    mov rdi, io_buf
    mov rsi, rax
    call md5_update
    jmp .read_loop
.read_done:
    test ebx, ebx
    jz .finalize
    mov rax, SYS_CLOSE
    mov edi, ebx
    syscall
.finalize:
    call md5_final
    call md5_to_hex
    cmp byte [flag_tag], 0
    jne .output_tag
    cmp byte [flag_zero], 0
    jne .output_no_escape
    mov rdi, r12
    call needs_escape
    test eax, eax
    jz .output_no_escape
    ; Escaped output
    mov rdi, out_buf
    mov byte [rdi], '\'
    inc rdi
    mov rsi, hex_out
    mov ecx, 32
    rep movsb
    mov byte [rdi], ' '
    inc rdi
    cmp byte [flag_binary], 0
    je .et
    mov byte [rdi], '*'
    jmp .em
.et: mov byte [rdi], ' '
.em: inc rdi
    mov rsi, r12
    call escape_filename_to
    mov byte [rdi], 10
    inc rdi
    mov rsi, out_buf
    mov rdx, rdi
    sub rdx, rsi
    mov rdi, STDOUT
    call write_all
    jmp .hf_done
.output_no_escape:
    mov rdi, out_buf
    mov rsi, hex_out
    mov ecx, 32
    rep movsb
    mov byte [rdi], ' '
    inc rdi
    cmp byte [flag_binary], 0
    je .nt
    mov byte [rdi], '*'
    jmp .nm
.nt: mov byte [rdi], ' '
.nm: inc rdi
    mov rsi, r12
.cf: lodsb
    test al, al
    jz .cfd
    stosb
    jmp .cf
.cfd:
    cmp byte [flag_zero], 0
    jne .zt
    mov byte [rdi], 10
    jmp .td
.zt: mov byte [rdi], 0
.td: inc rdi
    mov rsi, out_buf
    mov rdx, rdi
    sub rdx, rsi
    mov rdi, STDOUT
    call write_all
    jmp .hf_done
.output_tag:
    mov rdi, out_buf
    mov rsi, str_md5_tag
    mov ecx, str_md5_tag_len
    rep movsb
    mov rsi, r12
.tcf: lodsb
    test al, al
    jz .tcfd
    stosb
    jmp .tcf
.tcfd:
    mov rsi, str_tag_eq
    mov ecx, str_tag_eq_len
    rep movsb
    mov rsi, hex_out
    mov ecx, 32
    rep movsb
    cmp byte [flag_zero], 0
    jne .tzt
    mov byte [rdi], 10
    jmp .ttd
.tzt: mov byte [rdi], 0
.ttd: inc rdi
    mov rsi, out_buf
    mov rdx, rdi
    sub rdx, rsi
    mov rdi, STDOUT
    call write_all
    jmp .hf_done
.open_error:
    mov r13, rax
    neg r13d
    mov byte [had_error], 1
    WRITE STDERR, err_prefix, err_prefix_len
    mov rdi, r12
    call strlen
    mov rdx, rax
    WRITE STDERR, r12, rdx
    cmp r13d, 2
    je .enoent
    cmp r13d, 13
    je .eperm
    cmp r13d, 21
    je .eisdir
    WRITE STDERR, err_io, err_io_len
    jmp .hf_done
.enoent:
    WRITE STDERR, err_no_such, err_no_such_len
    jmp .hf_done
.eperm:
    WRITE STDERR, err_perm, err_perm_len
    jmp .hf_done
.eisdir:
    WRITE STDERR, err_is_dir, err_is_dir_len
    jmp .hf_done
.read_error:
    mov byte [had_error], 1
    test ebx, ebx
    jz .re_msg
    push rax
    mov rax, SYS_CLOSE
    mov edi, ebx
    syscall
    pop rax
.re_msg:
    WRITE STDERR, err_prefix, err_prefix_len
    mov rdi, r12
    call strlen
    mov rdx, rax
    WRITE STDERR, r12, rdx
    WRITE STDERR, err_io, err_io_len
.hf_done:
    pop r13
    pop r12
    pop rbx
    ret

; ── Needs escape ──
needs_escape:
.loop:
    movzx eax, byte [rdi]
    test al, al
    jz .no
    cmp al, '\'
    je .yes
    cmp al, 10
    je .yes
    inc rdi
    jmp .loop
.no: xor eax, eax
    ret
.yes: mov eax, 1
    ret

; ── Escape filename ──
escape_filename_to:
.loop:
    lodsb
    test al, al
    jz .done
    cmp al, '\'
    je .eb
    cmp al, 10
    je .en
    stosb
    jmp .loop
.eb: mov byte [rdi], '\'
    mov byte [rdi+1], '\'
    add rdi, 2
    jmp .loop
.en: mov byte [rdi], '\'
    mov byte [rdi+1], 'n'
    add rdi, 2
    jmp .loop
.done: ret

; ── Check mode ──
do_check_mode:
    cmp dword [file_count], 0
    jne .has_files
    mov qword [file_args], str_dash
    mov dword [file_count], 1
.has_files:
    mov dword [cnt_ok], 0
    mov dword [cnt_mismatch], 0
    mov dword [cnt_format_err], 0
    mov dword [cnt_read_err], 0
    mov dword [cnt_ignored], 0
    xor r12d, r12d
.file_loop:
    cmp r12d, [file_count]
    jge .files_done
    mov rdi, [file_args + r12*8]
    call check_one_file
    inc r12d
    jmp .file_loop
.files_done:
    mov eax, [cnt_ok]
    add eax, [cnt_mismatch]
    add eax, [cnt_read_err]
    test eax, eax
    jnz .has_valid
    cmp dword [cnt_format_err], 0
    je .skip_no_proper
    cmp byte [flag_status], 0
    jne .set_error
    WRITE STDERR, err_prefix, err_prefix_len
    mov rdi, [file_args]
    cmp byte [rdi], '-'
    jne .np_fname
    cmp byte [rdi+1], 0
    jne .np_fname
    WRITE STDERR, str_stdin_name, 14
    jmp .np_msg
.np_fname:
    mov rdi, [file_args]
    call strlen
    mov rdx, rax
    WRITE STDERR, [file_args], rdx
.np_msg:
    WRITE STDERR, str_no_proper, str_no_proper_len
.set_error:
    mov byte [had_error], 1
    jmp .print_warns
.has_valid:
.skip_no_proper:
.print_warns:
    cmp byte [flag_status], 0
    jne .cm_exit
    cmp dword [cnt_mismatch], 0
    je .no_mm
    WRITE STDERR, str_warn_prefix, str_warn_prefix_len
    cmp dword [cnt_mismatch], 1
    jne .mm_p
    WRITE STDERR, str_checksum_not_match_1, str_checksum_not_match_1_len
    jmp .no_mm
.mm_p:
    mov edi, [cnt_mismatch]
    call print_number_stderr
    WRITE STDERR, str_checksums_not_match, str_checksums_not_match_len
.no_mm:
    cmp dword [cnt_read_err], 0
    je .no_re
    WRITE STDERR, str_warn_prefix, str_warn_prefix_len
    cmp dword [cnt_read_err], 1
    jne .re_p
    WRITE STDERR, str_file_not_read_1, str_file_not_read_1_len
    jmp .no_re
.re_p:
    mov edi, [cnt_read_err]
    call print_number_stderr
    WRITE STDERR, str_files_not_read, str_files_not_read_len
.no_re:
    cmp dword [cnt_format_err], 0
    je .no_fe
    WRITE STDERR, str_warn_prefix, str_warn_prefix_len
    cmp dword [cnt_format_err], 1
    jne .fe_p
    WRITE STDERR, str_line_improper_1, str_line_improper_1_len
    jmp .no_fe
.fe_p:
    mov edi, [cnt_format_err]
    call print_number_stderr
    WRITE STDERR, str_lines_improper, str_lines_improper_len
.no_fe:
.cm_exit:
    movzx edi, byte [had_error]
    cmp dword [cnt_mismatch], 0
    je .n1
    mov edi, 1
.n1: cmp dword [cnt_read_err], 0
    je .n2
    mov edi, 1
.n2: cmp byte [flag_strict], 0
    je .n3
    cmp dword [cnt_format_err], 0
    je .n3
    mov edi, 1
.n3: EXIT rdi

; ── Check one file ──
check_one_file:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov r12, rdi
    cmp byte [r12], '-'
    jne .cof_open
    cmp byte [r12+1], 0
    jne .cof_open
    xor ebx, ebx
    jmp .cof_read
.cof_open:
    mov rax, SYS_OPEN
    mov rdi, r12
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .cof_open_err
    mov ebx, eax
.cof_read:
    mov dword [rsp+4], 0
    mov dword [rsp+8], 0
    xor r13d, r13d
.next_line:
    mov rdi, line_buf
    xor r14d, r14d
.getchar:
    mov eax, [rsp+4]
    cmp eax, [rsp+8]
    jl .have_char
    mov rax, SYS_READ
    mov edi, ebx
    mov rsi, io_buf
    mov edx, IO_SIZE
    syscall
    cmp rax, -EINTR
    je .getchar
    test rax, rax
    jle .eof
    mov [rsp+8], eax
    mov dword [rsp+4], 0
.have_char:
    mov eax, [rsp+4]
    movzx ecx, byte [io_buf + rax]
    inc dword [rsp+4]
    cmp cl, 10
    je .have_line
    cmp r14d, 65530
    jge .getchar
    mov [line_buf + r14], cl
    inc r14d
    jmp .getchar
.eof:
    test r14d, r14d
    jz .cof_done
.have_line:
    inc r13d
    mov byte [line_buf + r14], 0
    mov rsi, line_buf
    xor r15d, r15d
    cmp byte [rsi], '\'
    jne .no_esc
    mov r15d, 1
    inc rsi
.no_esc:
    cmp dword [rsi], 0x2035444D
    jne .try_std
    cmp byte [rsi+4], '('
    jne .try_std
    add rsi, 5
    mov rdi, rsi
.find_paren:
    cmp byte [rsi], 0
    je .bad_fmt
    cmp byte [rsi], ')'
    jne .fp_next
    cmp byte [rsi+1], ' '
    jne .fp_next
    cmp byte [rsi+2], '='
    jne .fp_next
    cmp byte [rsi+3], ' '
    jne .fp_next
    mov byte [rsi], 0
    add rsi, 4
    jmp .verify
.fp_next:
    inc rsi
    jmp .find_paren
.try_std:
    mov rdi, rsi
    xor ecx, ecx
.count_hex:
    movzx eax, byte [rdi + rcx]
    cmp al, '0'
    jl .hex_end
    cmp al, '9'
    jle .hex_ok
    cmp al, 'a'
    jl .check_upper
    cmp al, 'f'
    jle .hex_ok
    jmp .hex_end
.check_upper:
    cmp al, 'A'
    jl .hex_end
    cmp al, 'F'
    jle .hex_ok
    jmp .hex_end
.hex_ok:
    inc ecx
    jmp .count_hex
.hex_end:
    cmp ecx, 32
    jne .bad_fmt
    mov rsi, rdi
    lea rdi, [rsi + 32]
    cmp byte [rdi], ' '
    jne .bad_fmt
    inc rdi
    cmp byte [rdi], ' '
    je .std_ok
    cmp byte [rdi], '*'
    je .std_ok
    jmp .bad_fmt
.std_ok:
    inc rdi
.verify:
    push rsi
    push rdi
    call md5_init
    mov rdi, [rsp]
    cmp byte [rdi], '-'
    jne .cv_open
    cmp byte [rdi+1], 0
    jne .cv_open
    xor ebx, ebx
    jmp .cv_read_loop
.cv_open:
    mov rax, SYS_OPEN
    mov rdi, [rsp]
    xor esi, esi
    xor edx, edx
    syscall
    test rax, rax
    js .cv_open_err
    mov ebx, eax
.cv_read_loop:
    mov rax, SYS_READ
    mov edi, ebx
    mov rsi, io_buf2
    mov edx, IO_SIZE
    syscall
    cmp rax, -EINTR
    je .cv_read_loop
    test rax, rax
    js .cv_read_err
    jz .cv_done
    mov rdi, io_buf2
    mov rsi, rax
    call md5_update
    jmp .cv_read_loop
.cv_done:
    test ebx, ebx
    jz .cv_final
    push rbx
    mov rax, SYS_CLOSE
    mov edi, ebx
    syscall
    pop rbx
.cv_final:
    call md5_final
    call md5_to_hex
    pop rdi
    pop rsi
    mov rax, hex_out
    xor ecx, ecx
.cmp_loop:
    cmp ecx, 32
    jge .match
    movzx edx, byte [rax + rcx]
    movzx r8d, byte [rsi + rcx]
    cmp dl, 'A'
    jl .c1
    cmp dl, 'F'
    jg .c1
    add dl, 32
.c1: cmp r8b, 'A'
    jl .c2
    cmp r8b, 'F'
    jg .c2
    add r8b, 32
.c2: cmp dl, r8b
    jne .no_match
    inc ecx
    jmp .cmp_loop
.match:
    inc dword [cnt_ok]
    cmp byte [flag_status], 0
    jne .next_jmp
    cmp byte [flag_quiet], 0
    jne .next_jmp
    push rdi
    call strlen
    mov rdx, rax
    pop rsi
    push rsi
    WRITE STDOUT, rsi, rdx
    WRITE STDOUT, str_ok, str_ok_len
    pop rdi
    jmp .next_jmp
.no_match:
    inc dword [cnt_mismatch]
    mov byte [had_error], 1
    cmp byte [flag_status], 0
    jne .next_jmp
    push rdi
    call strlen
    mov rdx, rax
    pop rsi
    push rsi
    WRITE STDOUT, rsi, rdx
    WRITE STDOUT, str_failed, str_failed_len
    pop rdi
    jmp .next_jmp
.cv_open_err:
    pop rdi
    pop rsi
    cmp byte [flag_ignore], 0
    jne .cv_ign
    inc dword [cnt_read_err]
    mov byte [had_error], 1
    cmp byte [flag_status], 0
    jne .next_jmp
    WRITE STDERR, err_prefix, err_prefix_len
    push rdi
    call strlen
    mov rdx, rax
    pop rsi
    WRITE STDERR, rsi, rdx
    WRITE STDERR, err_no_such, err_no_such_len
    push rsi
    mov rdi, rsi
    call strlen
    mov rdx, rax
    pop rsi
    WRITE STDOUT, rsi, rdx
    WRITE STDOUT, str_failed_open, str_failed_open_len
    jmp .next_jmp
.cv_ign:
    inc dword [cnt_ignored]
    jmp .next_jmp
.cv_read_err:
    pop rdi
    pop rsi
    inc dword [cnt_read_err]
    mov byte [had_error], 1
    jmp .next_jmp
.bad_fmt:
    inc dword [cnt_format_err]
    cmp byte [flag_warn], 0
    je .next_jmp
    WRITE STDERR, err_prefix, err_prefix_len
    push r12
    mov rdi, r12
    cmp byte [rdi], '-'
    jne .bf_ns
    cmp byte [rdi+1], 0
    jne .bf_ns
    WRITE STDERR, str_stdin_name, 14
    jmp .bf_c
.bf_ns:
    call strlen
    mov rdx, rax
    WRITE STDERR, r12, rdx
.bf_c:
    WRITE STDERR, str_colon_space, str_colon_space_len
    mov edi, r13d
    call print_number_stderr
    WRITE STDERR, str_improperly, str_improperly_len
    pop r12
.next_jmp:
    jmp .next_line
.cof_done:
    test ebx, ebx
    jz .cof_end
    mov rax, SYS_CLOSE
    mov edi, ebx
    syscall
.cof_end:
    cmp byte [flag_ignore], 0
    je .cof_ret
    mov eax, [cnt_ok]
    add eax, [cnt_mismatch]
    test eax, eax
    jnz .cof_ret
    cmp dword [cnt_ignored], 0
    je .cof_ret
    cmp byte [flag_status], 0
    jne .cof_set_err
    WRITE STDERR, err_prefix, err_prefix_len
    mov rdi, r12
    cmp byte [rdi], '-'
    jne .nv_fn
    cmp byte [rdi+1], 0
    jne .nv_fn
    WRITE STDERR, str_stdin_name, 14
    jmp .nv_msg
.nv_fn:
    call strlen
    mov rdx, rax
    WRITE STDERR, r12, rdx
.nv_msg:
    WRITE STDERR, str_no_file_verified, str_no_file_verified_len
.cof_set_err:
    mov byte [had_error], 1
.cof_ret:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.cof_open_err:
    WRITE STDERR, err_prefix, err_prefix_len
    mov rdi, r12
    call strlen
    mov rdx, rax
    WRITE STDERR, r12, rdx
    WRITE STDERR, err_no_such, err_no_such_len
    mov byte [had_error], 1
    jmp .cof_ret

; ── Print number to stderr ──
print_number_stderr:
    push rbx
    sub rsp, 32
    lea rbx, [rsp + 30]
    mov byte [rbx+1], 0
    mov eax, edi
    test eax, eax
    jnz .pn_loop
    mov byte [rbx], '0'
    dec rbx
    jmp .pn_done
.pn_loop:
    test eax, eax
    jz .pn_done
    xor edx, edx
    mov ecx, 10
    div ecx
    add dl, '0'
    mov [rbx], dl
    dec rbx
    jmp .pn_loop
.pn_done:
    inc rbx
    mov rsi, rbx
    lea rdx, [rsp + 31]
    sub rdx, rbx
    WRITE STDERR, rsi, rdx
    add rsp, 32
    pop rbx
    ret

; ════════════════════════════════════════════════════════════════
; DATA SECTION
; ════════════════════════════════════════════════════════════════

hex_digits: db "0123456789abcdef"

s_binary: db "binary", 0
s_check: db "check", 0
s_tag: db "tag", 0
s_text: db "text", 0
s_ignore_missing: db "ignore-missing", 0
s_quiet: db "quiet", 0
s_status: db "status", 0
s_strict: db "strict", 0
s_warn: db "warn", 0
s_zero: db "zero", 0
s_help: db "help", 0
s_version: db "version", 0

str_dash: db "-", 0
str_stdin_name: db "standard input", 0

str_help:
    db "Usage: md5sum [OPTION]... [FILE]...", 10
    db "Print or check MD5 (128-bit) checksums.", 10, 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db "  -b, --binary          read in binary mode", 10
    db "  -c, --check           read checksums from the FILEs and check them", 10
    db "      --tag             create a BSD-style checksum", 10
    db "  -t, --text            read in text mode (default)", 10
    db "  -z, --zero            end each output line with NUL, not newline,", 10
    db "                          and disable file name escaping", 10, 10
    db "The following five options are useful only when verifying checksums:", 10
    db "      --ignore-missing  don't fail or report status for missing files", 10
    db "      --quiet           don't print OK for each successfully verified file", 10
    db "      --status          don't output anything, status code shows success", 10
    db "      --strict          exit non-zero for improperly formatted checksum lines", 10
    db "  -w, --warn            warn about improperly formatted checksum lines", 10, 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "The sums are computed as described in RFC 1321.", 10
    db "When checking, the input should be a former output of this program.", 10
    db "The default mode is to print a line with: checksum, a space,", 10
    db "a character indicating input mode ('*' for binary, ' ' for text", 10
    db "or where binary is insignificant), and name for each FILE.", 10, 10
    db "Note: There is no difference between binary mode and text mode on GNU systems.", 10
str_help_len equ $ - str_help

str_version:
    db "md5sum (fcoreutils) 0.1.0", 10
str_version_len equ $ - str_version

str_ok: db ": OK", 10
str_ok_len equ $ - str_ok
str_failed: db ": FAILED", 10
str_failed_len equ $ - str_failed
str_failed_open: db ": FAILED open or read", 10
str_failed_open_len equ $ - str_failed_open

str_md5_tag: db "MD5 ("
str_md5_tag_len equ $ - str_md5_tag
str_tag_eq: db ") = "
str_tag_eq_len equ $ - str_tag_eq

str_colon_space: db ": "
str_colon_space_len equ $ - str_colon_space

err_prefix: db "md5sum: "
err_prefix_len equ $ - err_prefix
err_no_such: db ": No such file or directory", 10
err_no_such_len equ $ - err_no_such
err_perm: db ": Permission denied", 10
err_perm_len equ $ - err_perm
err_is_dir: db ": Is a directory", 10
err_is_dir_len equ $ - err_is_dir
err_io: db ": Input/output error", 10
err_io_len equ $ - err_io

err_unrec: db "md5sum: unrecognized option '"
err_unrec_len equ $ - err_unrec
err_inval: db "md5sum: invalid option -- '"
err_inval_len equ $ - err_inval
err_suffix: db "'", 10, "Try 'md5sum --help' for more information.", 10
err_suffix_len equ $ - err_suffix

err_tag_check: db "md5sum: the --tag option is meaningless when verifying checksums", 10
               db "Try 'md5sum --help' for more information.", 10
err_tag_check_len equ $ - err_tag_check

str_warn_prefix: db "md5sum: WARNING: "
str_warn_prefix_len equ $ - str_warn_prefix
str_checksum_not_match_1: db "1 computed checksum did NOT match", 10
str_checksum_not_match_1_len equ $ - str_checksum_not_match_1
str_checksums_not_match: db " computed checksums did NOT match", 10
str_checksums_not_match_len equ $ - str_checksums_not_match
str_file_not_read_1: db "1 listed file could not be read", 10
str_file_not_read_1_len equ $ - str_file_not_read_1
str_files_not_read: db " listed files could not be read", 10
str_files_not_read_len equ $ - str_files_not_read
str_line_improper_1: db "1 line is improperly formatted", 10
str_line_improper_1_len equ $ - str_line_improper_1
str_lines_improper: db " lines are improperly formatted", 10
str_lines_improper_len equ $ - str_lines_improper
str_no_proper: db ": no properly formatted MD5 checksum lines found", 10
str_no_proper_len equ $ - str_no_proper
str_no_file_verified: db ": no file was verified", 10
str_no_file_verified_len equ $ - str_no_file_verified
str_improperly: db ": improperly formatted MD5 checksum line", 10
str_improperly_len equ $ - str_improperly

file_end:
