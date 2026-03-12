; fsha224sum_unified.asm
; Hand-crafted minimal ELF binary for fsha224sum
; Fully self-contained — no libc, no linker needed
; Build: nasm -f bin fsha224sum_unified.asm -o fsha224sum && chmod +x fsha224sum
;
; SHA-224 is a truncated SHA-256 with different initial hash values.
; Same compression function, same message schedule, same round constants.
; Output: first 224 bits (28 bytes, 56 hex chars) of the hash state.

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

; BSS layout constants
%define BSS_BASE     0x500000
%define io_buf       BSS_BASE
%define io_buf2      (BSS_BASE + IO_SIZE)
%define out_buf      (BSS_BASE + IO_SIZE*2)
%define line_buf     (BSS_BASE + IO_SIZE*2 + 4096)
%define hash_state   (BSS_BASE + IO_SIZE*3 + 4096)
%define msg_len      (hash_state + 32)
%define block_buf    (msg_len + 8)
%define block_used   (block_buf + 64)
%define hex_out      (block_used + 4)
%define W_schedule   (hex_out + 65 + 3)
%define fname_buf    (W_schedule + 256)
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

; SHA-224 constants
%define HASH_HEX_LEN  56      ; 224 bits = 28 bytes = 56 hex chars
%define HASH_DWORDS    7      ; 7 dwords to output

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

; ── SHA-224 Init ──
; SHA-224 uses different initial hash values than SHA-256 (FIPS 180-4 section 5.3.2)
sha224_init:
    mov dword [hash_state],    0xc1059ed8
    mov dword [hash_state+4],  0x367cd507
    mov dword [hash_state+8],  0x3070dd17
    mov dword [hash_state+12], 0xf70e5939
    mov dword [hash_state+16], 0xffc00b31
    mov dword [hash_state+20], 0x68581511
    mov dword [hash_state+24], 0x64f98fa7
    mov dword [hash_state+28], 0xbefa4fa4
    mov qword [msg_len], 0
    mov dword [block_used], 0
    ret

; ── SHA-256 Transform (shared with SHA-224) ──
; Input: rdi = pointer to 64-byte block
; Uses W_schedule for the message schedule (64 dwords)
sha256_transform:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub  rsp, 40          ; local space: 32 bytes for saved hash + 8 alignment

    mov  r14, rdi         ; r14 = block pointer

    ; Load hash state into local vars on stack
    mov  eax, [hash_state]
    mov  [rsp],    eax
    mov  ebx, [hash_state+4]
    mov  [rsp+4],  ebx
    mov  ecx, [hash_state+8]
    mov  [rsp+8],  ecx
    mov  edx, [hash_state+12]
    mov  [rsp+12], edx
    mov  r8d, [hash_state+16]
    mov  [rsp+16], r8d
    mov  r9d, [hash_state+20]
    mov  [rsp+20], r9d
    mov  r10d, [hash_state+24]
    mov  [rsp+24], r10d
    mov  r11d, [hash_state+28]
    mov  [rsp+28], r11d

    ; Prepare message schedule W[0..15] from block (big-endian to host)
    xor  r12d, r12d
.load_w:
    cmp  r12d, 16
    jge  .extend_w
    mov  r13d, [r14 + r12*4]
    bswap r13d
    mov  [W_schedule + r12*4], r13d
    inc  r12d
    jmp  .load_w

    ; Extend W[16..63]
.extend_w:
    cmp  r12d, 64
    jge  .rounds

    ; sigma1(W[t-2]): ROTR(x,17) ^ ROTR(x,19) ^ (x >> 10)
    mov  r13d, [W_schedule + r12*4 - 8]   ; W[t-2]
    mov  r15d, r13d
    ror  r15d, 17
    mov  ebp, r13d
    ror  ebp, 19
    xor  r15d, ebp
    shr  r13d, 10
    xor  r15d, r13d        ; r15d = sigma1(W[t-2])

    ; sigma0(W[t-15]): ROTR(x,7) ^ ROTR(x,18) ^ (x >> 3)
    mov  r13d, [W_schedule + r12*4 - 60]  ; W[t-15]
    mov  ebp, r13d
    ror  ebp, 7
    mov  eax, r13d         ; temporarily use eax
    ror  eax, 18
    xor  ebp, eax
    shr  r13d, 3
    xor  ebp, r13d         ; ebp = sigma0(W[t-15])

    add  r15d, ebp                         ; sigma1 + sigma0
    add  r15d, [W_schedule + r12*4 - 28]   ; + W[t-7]
    add  r15d, [W_schedule + r12*4 - 64]   ; + W[t-16]
    mov  [W_schedule + r12*4], r15d
    inc  r12d
    jmp  .extend_w

.rounds:
    ; Reload working variables after we clobbered eax
    mov  eax,  [rsp]       ; a
    mov  ebx,  [rsp+4]     ; b
    mov  ecx,  [rsp+8]     ; c
    mov  edx,  [rsp+12]    ; d
    mov  r8d,  [rsp+16]    ; e
    mov  r9d,  [rsp+20]    ; f
    mov  r10d, [rsp+24]    ; g
    mov  r11d, [rsp+28]    ; h

    ; 64 compression rounds
    xor  r12d, r12d
.round_loop:
    cmp  r12d, 64
    jge  .add_hash

    ; T1 = h + Sigma1(e) + Ch(e,f,g) + K[t] + W[t]
    ; Sigma1(e) = ROTR(e,6) ^ ROTR(e,11) ^ ROTR(e,25)
    mov  r13d, r8d
    ror  r13d, 6
    mov  r15d, r8d
    ror  r15d, 11
    xor  r13d, r15d
    mov  r15d, r8d
    ror  r15d, 25
    xor  r13d, r15d        ; r13d = Sigma1(e)

    ; Ch(e,f,g) = (e & f) ^ (~e & g)
    mov  r15d, r8d
    and  r15d, r9d
    mov  ebp, r8d
    not  ebp
    and  ebp, r10d
    xor  r15d, ebp         ; r15d = Ch(e,f,g)

    add  r13d, r11d        ; + h
    add  r13d, r15d        ; + Ch
    lea  rbp, [sha256_K]
    add  r13d, [rbp + r12*4] ; + K[t]
    add  r13d, [W_schedule + r12*4] ; + W[t]
    ; r13d = T1

    ; T2 = Sigma0(a) + Maj(a,b,c)
    ; Sigma0(a) = ROTR(a,2) ^ ROTR(a,13) ^ ROTR(a,22)
    mov  r15d, eax
    ror  r15d, 2
    mov  ebp, eax
    ror  ebp, 13
    xor  r15d, ebp
    mov  ebp, eax
    ror  ebp, 22
    xor  r15d, ebp         ; r15d = Sigma0(a)

    ; Maj(a,b,c) = (a & b) ^ (a & c) ^ (b & c)
    mov  ebp, eax
    and  ebp, ebx
    mov  r14d, eax
    and  r14d, ecx
    xor  ebp, r14d
    mov  r14d, ebx
    and  r14d, ecx
    xor  ebp, r14d         ; ebp = Maj(a,b,c)

    add  r15d, ebp         ; r15d = T2

    ; Update working variables
    mov  r11d, r10d        ; h = g
    mov  r10d, r9d         ; g = f
    mov  r9d, r8d          ; f = e
    mov  r8d, edx          ; e = d + T1
    add  r8d, r13d
    mov  edx, ecx          ; d = c
    mov  ecx, ebx          ; c = b
    mov  ebx, eax          ; b = a
    mov  eax, r13d         ; a = T1 + T2
    add  eax, r15d

    inc  r12d
    jmp  .round_loop

.add_hash:
    ; Add compressed chunk to hash state
    add  [hash_state],    eax
    add  [hash_state+4],  ebx
    add  [hash_state+8],  ecx
    add  [hash_state+12], edx
    add  [hash_state+16], r8d
    add  [hash_state+20], r9d
    add  [hash_state+24], r10d
    add  [hash_state+28], r11d

    add  rsp, 40
    pop  r15
    pop  r14
    pop  r13
    pop  r12
    pop  rbp
    pop  rbx
    ret

; ── SHA-224 Update (same as SHA-256 update) ──
sha224_update:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi           ; data pointer
    mov r13, rsi           ; data length
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
    push rcx
    rep movsb
    pop rcx
    add r12, rcx
    sub r13, rcx
    mov dword [block_used], 0
    mov rdi, block_buf
    call sha256_transform
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
    call sha256_transform
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

; ── SHA-224 Final (same as SHA-256 final) ──
sha224_final:
    push rbx
    mov eax, [block_used]
    mov byte [block_buf + rax], 0x80
    inc eax
    cmp eax, 56
    jle .pad_zeros
    ; Need extra block
    mov rdi, block_buf
    add rdi, rax
    mov ecx, 64
    sub ecx, eax
    xor al, al
    rep stosb
    mov rdi, block_buf
    call sha256_transform
    xor eax, eax
.pad_zeros:
    mov rdi, block_buf
    add rdi, rax
    mov ecx, 56
    sub ecx, eax
    xor al, al
    rep stosb
    ; Append length in bits as big-endian 64-bit
    mov rax, [msg_len]
    shl rax, 3
    bswap rax
    mov [block_buf + 56], rax
    mov rdi, block_buf
    call sha256_transform
    pop rbx
    ret

; ── SHA-224 to hex (big-endian output, 56 hex chars — truncated from 64) ──
sha224_to_hex:
    xor ecx, ecx
.loop:
    cmp ecx, HASH_DWORDS   ; 7 dwords = 28 bytes = 56 hex chars
    jge .done
    mov eax, [hash_state + rcx*4]
    mov edx, ecx
    shl edx, 3            ; edx = ecx * 8 (position in hex_out)

    mov r8d, eax
    shr r8d, 28
    and r8d, 0x0F
    movzx r8d, byte [hex_digits + r8]
    mov [hex_out + rdx], r8b

    mov r8d, eax
    shr r8d, 24
    and r8d, 0x0F
    movzx r8d, byte [hex_digits + r8]
    mov [hex_out + rdx + 1], r8b

    mov r8d, eax
    shr r8d, 20
    and r8d, 0x0F
    movzx r8d, byte [hex_digits + r8]
    mov [hex_out + rdx + 2], r8b

    mov r8d, eax
    shr r8d, 16
    and r8d, 0x0F
    movzx r8d, byte [hex_digits + r8]
    mov [hex_out + rdx + 3], r8b

    mov r8d, eax
    shr r8d, 12
    and r8d, 0x0F
    movzx r8d, byte [hex_digits + r8]
    mov [hex_out + rdx + 4], r8b

    mov r8d, eax
    shr r8d, 8
    and r8d, 0x0F
    movzx r8d, byte [hex_digits + r8]
    mov [hex_out + rdx + 5], r8b

    mov r8d, eax
    shr r8d, 4
    and r8d, 0x0F
    movzx r8d, byte [hex_digits + r8]
    mov [hex_out + rdx + 6], r8b

    mov r8d, eax
    and r8d, 0x0F
    movzx r8d, byte [hex_digits + r8]
    mov [hex_out + rdx + 7], r8b

    inc ecx
    jmp .loop
.done:
    mov byte [hex_out + HASH_HEX_LEN], 0
    ret

; ── Hash one file ──
hash_one_file:
    push rbx
    push r12
    push r13
    mov r12, rdi
    call sha224_init
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
    call sha224_update
    jmp .read_loop
.read_done:
    test ebx, ebx
    jz .finalize
    mov rax, SYS_CLOSE
    mov edi, ebx
    syscall
.finalize:
    call sha224_final
    call sha224_to_hex
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
    mov ecx, HASH_HEX_LEN
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
    mov ecx, HASH_HEX_LEN
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
    mov rsi, str_sha224_tag
    mov ecx, str_sha224_tag_len
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
    mov ecx, HASH_HEX_LEN
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
    ; Try BSD-style "SHA224 (" tag format
    cmp byte [rsi], 'S'
    jne .try_std
    cmp byte [rsi+1], 'H'
    jne .try_std
    cmp byte [rsi+2], 'A'
    jne .try_std
    cmp byte [rsi+3], '2'
    jne .try_std
    cmp byte [rsi+4], '2'
    jne .try_std
    cmp byte [rsi+5], '4'
    jne .try_std
    cmp byte [rsi+6], ' '
    jne .try_std
    cmp byte [rsi+7], '('
    jne .try_std
    add rsi, 8
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
    cmp ecx, HASH_HEX_LEN
    jne .bad_fmt
    mov rsi, rdi
    lea rdi, [rsi + HASH_HEX_LEN]
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
    call sha224_init
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
    call sha224_update
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
    call sha224_final
    call sha224_to_hex
    pop rdi
    pop rsi
    mov rax, hex_out
    xor ecx, ecx
.cmp_loop:
    cmp ecx, HASH_HEX_LEN
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

; SHA-256 round constants K[0..63] (shared with SHA-224)
sha256_K:
    dd 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5
    dd 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
    dd 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3
    dd 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
    dd 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc
    dd 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
    dd 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7
    dd 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
    dd 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13
    dd 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
    dd 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3
    dd 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
    dd 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5
    dd 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
    dd 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208
    dd 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2

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

; @@DATA_START@@
str_help:
    db "Usage: sha224sum [OPTION]... [FILE]...", 10
    db "Print or check SHA224 (224-bit) checksums.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db "  -b, --binary          read in binary mode", 10
    db "  -c, --check           read checksums from the FILEs and check them", 10
    db "      --tag             create a BSD-style checksum", 10
    db "  -t, --text            read in text mode (default)", 10
    db "  -z, --zero            end each output line with NUL, not newline,", 10
    db "                          and disable file name escaping", 10
    db 10
    db "The following five options are useful only when verifying checksums:", 10
    db "      --ignore-missing  don't fail or report status for missing files", 10
    db "      --quiet           don't print OK for each successfully verified file", 10
    db "      --status          don't output anything, status code shows success", 10
    db "      --strict          exit non-zero for improperly formatted checksum lines", 10
    db "  -w, --warn            warn about improperly formatted checksum lines", 10
    db 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "The sums are computed as described in FIPS-180-2.", 10
    db "When checking, the input should be a former output of this program.", 10
    db "The default mode is to print a line with: checksum, a space,", 10
    db "a character indicating input mode ('*' for binary, ' ' for text", 10
    db "or where binary is insignificant), and name for each FILE.", 10
    db 10
    db "There is no difference between binary mode and text mode on GNU systems.", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/sha224sum>", 10
    db "or available locally via: info '(coreutils) sha224sum invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "sha224sum (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Ulrich Drepper, Scott Miller, and David Madore.", 10
str_version_len equ $ - str_version

str_ok: db ": OK", 10
str_ok_len equ $ - str_ok
str_failed: db ": FAILED", 10
str_failed_len equ $ - str_failed
str_failed_open: db ": FAILED open or read", 10
str_failed_open_len equ $ - str_failed_open

str_sha224_tag: db "SHA224 ("
str_sha224_tag_len equ $ - str_sha224_tag
str_tag_eq: db ") = "
str_tag_eq_len equ $ - str_tag_eq

str_colon_space: db ": "
str_colon_space_len equ $ - str_colon_space

err_prefix: db "sha224sum: "
err_prefix_len equ $ - err_prefix
err_no_such: db ": No such file or directory", 10
err_no_such_len equ $ - err_no_such
err_perm: db ": Permission denied", 10
err_perm_len equ $ - err_perm
err_is_dir: db ": Is a directory", 10
err_is_dir_len equ $ - err_is_dir
err_io: db ": Input/output error", 10
err_io_len equ $ - err_io

err_unrec: db "sha224sum: unrecognized option '"
err_unrec_len equ $ - err_unrec
err_inval: db "sha224sum: invalid option -- '"
err_inval_len equ $ - err_inval
err_suffix:   db 0xE2, 0x80, 0x99, 10
err_suffix_len equ $ - err_suffix

err_tag_check: db "sha224sum: the --tag option is meaningless when verifying checksums", 10
               db "Try 'sha224sum --help' for more information.", 10
err_tag_check_len equ $ - err_tag_check

str_warn_prefix: db "sha224sum: WARNING: "
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
str_no_proper: db ": no properly formatted SHA224 checksum lines found", 10
str_no_proper_len equ $ - str_no_proper
str_no_file_verified: db ": no file was verified", 10
str_no_file_verified_len equ $ - str_no_file_verified
str_improperly: db ": improperly formatted SHA224 checksum line", 10
str_improperly_len equ $ - str_improperly
; @@DATA_END@@

file_end:
