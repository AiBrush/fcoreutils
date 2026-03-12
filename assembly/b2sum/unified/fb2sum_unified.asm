; fb2sum_unified.asm
; Hand-crafted minimal ELF binary for fb2sum (BLAKE2b)
; Fully self-contained — no libc, no linker needed
; Build: nasm -f bin fb2sum_unified.asm -o fb2sum && chmod +x fb2sum

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
; BLAKE2b state
%define b2_h         (BSS_BASE + IO_SIZE*3 + 4096)          ; 64 bytes (8 x u64)
%define b2_t         (b2_h + 64)                             ; 16 bytes (t[0], t[1])
%define b2_f         (b2_t + 16)                             ; 16 bytes (f[0], f[1])
%define b2_buf       (b2_f + 16)                             ; 128 bytes block buffer
%define b2_buflen    (b2_buf + 128)                          ; 4 bytes
%define b2_outlen    (b2_buflen + 4)                         ; 4 bytes
%define b2_v         (b2_outlen + 4)                         ; 128 bytes working state
%define b2_m         (b2_v + 128)                            ; 128 bytes message schedule
%define hex_out      (b2_m + 128)                            ; 129 bytes
%define fname_buf    (hex_out + 130)
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
%define digest_bits  (flag_zero + 4)                         ; 4 bytes, default 512
%define cnt_ok       (digest_bits + 4)
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

    ; Default digest length 512 bits
    mov     dword [digest_bits], 512

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
    cmp     al, 'w'
    je      .sw
    cmp     al, 'l'
    je      .sl
    ; Unknown short option
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
.sw: mov byte [flag_warn], 1
    inc rsi
    jmp .short_loop
.sl:
    ; -l N: next arg is the length in bits
    inc     ebx
    cmp     ebx, r13d
    jge     .arg_done
    mov     rdi, [r12 + rbx*8]
    call    parse_number
    mov     [digest_bits], eax
    inc     ebx
    jmp     .arg_loop
.long_opt:
    push    rcx
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2

    ; Check for --length=N
    lea     rsi, [s_length_eq]
    call    strncmp_prefix
    test    eax, eax
    jz      .lo_length_eq

    lea     rsi, [s_length]
    call    strcmp
    test    eax, eax
    jz      .lo_length

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
.lo_help: pop rcx
    WRITE STDOUT, str_help, str_help_len
    EXIT 0
.lo_version: pop rcx
    WRITE STDOUT, str_version, str_version_len
    EXIT 0
.lo_length_eq:
    ; rdi points past "length=", parse the number
    pop     rcx
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    ; skip "length="
    add     rdi, 7
    call    parse_number
    mov     [digest_bits], eax
    jmp     .next_arg
.lo_length:
    ; --length N: next arg is the value
    pop     rcx
    inc     ebx
    cmp     ebx, r13d
    jge     .arg_done
    mov     rdi, [r12 + rbx*8]
    call    parse_number
    mov     [digest_bits], eax
    jmp     .next_arg
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

; ── Parse decimal number from string ──
; rdi = string pointer, returns eax = number
parse_number:
    xor     eax, eax
.loop:
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .done
    sub     cl, '0'
    cmp     cl, 9
    ja      .done
    imul    eax, 10
    add     eax, ecx
    inc     rdi
    jmp     .loop
.done:
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

; ── String prefix comparison (checks if rdi starts with rsi) ──
strncmp_prefix:
.loop:
    movzx ecx, byte [rsi]
    test cl, cl
    jz .match
    movzx eax, byte [rdi]
    cmp al, cl
    jne .diff
    inc rdi
    inc rsi
    jmp .loop
.match: xor eax, eax
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

; ════════════════════════════════════════════════════════════════
; BLAKE2b Implementation
; ════════════════════════════════════════════════════════════════

; ── BLAKE2b Init ──
; Uses digest_bits / 8 as outlen
blake2b_init:
    push    rbx
    push    r12

    ; Compute digest byte length
    mov     eax, [digest_bits]
    shr     eax, 3              ; bytes
    mov     [b2_outlen], eax

    ; Zero the state
    xor     eax, eax
    mov     qword [b2_t], 0
    mov     qword [b2_t+8], 0
    mov     qword [b2_f], 0
    mov     qword [b2_f+8], 0
    mov     dword [b2_buflen], 0

    ; Zero the buffer
    mov     rdi, b2_buf
    mov     ecx, 128
    xor     al, al
    rep     stosb

    ; Load IV into h
    lea     rsi, [blake2b_IV]
    lea     rdi, [b2_h]
    mov     ecx, 8
.load_iv:
    mov     rax, [rsi]
    mov     [rdi], rax
    add     rsi, 8
    add     rdi, 8
    dec     ecx
    jnz     .load_iv

    ; XOR parameter block into h[0]
    ; param: digest_length | (1<<8) key_length=0 | (1<<16) fanout=1 | (1<<24) depth=1
    mov     eax, [b2_outlen]
    or      eax, 0x01010000     ; fanout=1, depth=1, key_length=0
    mov     rcx, [b2_h]
    xor     rcx, rax
    mov     [b2_h], rcx

    pop     r12
    pop     rbx
    ret

; ── BLAKE2b compress ──
; Called with block pointer in rdi
blake2b_compress:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8              ; align stack

    mov     r14, rdi            ; r14 = block pointer

    ; Copy message block to b2_m (as 16 little-endian u64)
    lea     rdi, [b2_m]
    mov     rsi, r14
    mov     ecx, 128
    rep     movsb

    ; Initialize v[0..15]
    lea     rdi, [b2_v]
    ; v[0..7] = h[0..7]
    lea     rsi, [b2_h]
    mov     ecx, 64
    rep     movsb
    ; v[8..11] = IV[0..3]
    lea     rsi, [blake2b_IV]
    mov     ecx, 32
    rep     movsb

    ; v[12] = IV[4] ^ t[0]
    mov     rax, [blake2b_IV + 32]
    xor     rax, [b2_t]
    mov     [b2_v + 96], rax
    ; v[13] = IV[5] ^ t[1]
    mov     rax, [blake2b_IV + 40]
    xor     rax, [b2_t + 8]
    mov     [b2_v + 104], rax
    ; v[14] = IV[6] ^ f[0]
    mov     rax, [blake2b_IV + 48]
    xor     rax, [b2_f]
    mov     [b2_v + 112], rax
    ; v[15] = IV[7] ^ f[1]
    mov     rax, [blake2b_IV + 56]
    xor     rax, [b2_f + 8]
    mov     [b2_v + 120], rax

    ; 12 rounds of mixing
    xor     r15d, r15d          ; round counter
.round_loop:
    cmp     r15d, 12
    jge     .round_done

    ; Get sigma row pointer: sigma[round % 10]
    mov     eax, r15d
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    ; edx = round % 10
    shl     edx, 4              ; * 16 bytes per row
    lea     rbp, [blake2b_sigma + rdx]

    ; Column step (4 G calls)
    ; G(v, 0, 4,  8, 12, m[sigma[2i]], m[sigma[2i+1]])

    ; G(0,4,8,12, sigma[0], sigma[1])
    movzx   eax, byte [rbp]
    movzx   ecx, byte [rbp+1]
    call    blake2b_G_0_4_8_12

    ; G(1,5,9,13, sigma[2], sigma[3])
    movzx   eax, byte [rbp+2]
    movzx   ecx, byte [rbp+3]
    call    blake2b_G_1_5_9_13

    ; G(2,6,10,14, sigma[4], sigma[5])
    movzx   eax, byte [rbp+4]
    movzx   ecx, byte [rbp+5]
    call    blake2b_G_2_6_10_14

    ; G(3,7,11,15, sigma[6], sigma[7])
    movzx   eax, byte [rbp+6]
    movzx   ecx, byte [rbp+7]
    call    blake2b_G_3_7_11_15

    ; Diagonal step (4 G calls)
    ; G(0,5,10,15, sigma[8], sigma[9])
    movzx   eax, byte [rbp+8]
    movzx   ecx, byte [rbp+9]
    call    blake2b_G_0_5_10_15

    ; G(1,6,11,12, sigma[10], sigma[11])
    movzx   eax, byte [rbp+10]
    movzx   ecx, byte [rbp+11]
    call    blake2b_G_1_6_11_12

    ; G(2,7,8,13, sigma[12], sigma[13])
    movzx   eax, byte [rbp+12]
    movzx   ecx, byte [rbp+13]
    call    blake2b_G_2_7_8_13

    ; G(3,4,9,14, sigma[14], sigma[15])
    movzx   eax, byte [rbp+14]
    movzx   ecx, byte [rbp+15]
    call    blake2b_G_3_4_9_14

    inc     r15d
    jmp     .round_loop
.round_done:

    ; Finalize: h[i] ^= v[i] ^ v[i+8]
    xor     ecx, ecx
.final_loop:
    cmp     ecx, 8
    jge     .compress_done
    mov     rax, [b2_v + rcx*8]
    xor     rax, [b2_v + rcx*8 + 64]
    xor     [b2_h + rcx*8], rax
    inc     ecx
    jmp     .final_loop
.compress_done:
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── G function implementations ──
; Each G(a,b,c,d,x,y) where a,b,c,d are indices into v[]
; eax = sigma index for x, ecx = sigma index for y
; Both are indices into b2_m (as u64 array)

; Macro for the G function body
; %1=a_off, %2=b_off, %3=c_off, %4=d_off
%macro G_BODY 4
    ; Load x and y from message schedule
    mov     r8, [b2_m + rax*8]    ; x = m[sigma_x]
    mov     r9, [b2_m + rcx*8]    ; y = m[sigma_y]

    ; Load v[a], v[b], v[c], v[d]
    mov     r10, [b2_v + %1]      ; va
    mov     r11, [b2_v + %2]      ; vb
    mov     r12, [b2_v + %3]      ; vc
    mov     r13, [b2_v + %4]      ; vd

    ; va = va + vb + x
    add     r10, r11
    add     r10, r8
    ; vd = ROTR(vd ^ va, 32)
    xor     r13, r10
    ror     r13, 32
    ; vc = vc + vd
    add     r12, r13
    ; vb = ROTR(vb ^ vc, 24)
    xor     r11, r12
    ror     r11, 24
    ; va = va + vb + y
    add     r10, r11
    add     r10, r9
    ; vd = ROTR(vd ^ va, 16)
    xor     r13, r10
    ror     r13, 16
    ; vc = vc + vd
    add     r12, r13
    ; vb = ROTR(vb ^ vc, 63)
    xor     r11, r12
    ror     r11, 63

    ; Store back
    mov     [b2_v + %1], r10
    mov     [b2_v + %2], r11
    mov     [b2_v + %3], r12
    mov     [b2_v + %4], r13
%endmacro

; Column G functions
blake2b_G_0_4_8_12:
    G_BODY 0, 32, 64, 96
    ret

blake2b_G_1_5_9_13:
    G_BODY 8, 40, 72, 104
    ret

blake2b_G_2_6_10_14:
    G_BODY 16, 48, 80, 112
    ret

blake2b_G_3_7_11_15:
    G_BODY 24, 56, 88, 120
    ret

; Diagonal G functions
blake2b_G_0_5_10_15:
    G_BODY 0, 40, 80, 120
    ret

blake2b_G_1_6_11_12:
    G_BODY 8, 48, 88, 96
    ret

blake2b_G_2_7_8_13:
    G_BODY 16, 56, 64, 104
    ret

blake2b_G_3_4_9_14:
    G_BODY 24, 32, 72, 112
    ret

; ── BLAKE2b Update ──
; rdi = data pointer, rsi = data length
blake2b_update:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12, rdi            ; data pointer
    mov     r13, rsi            ; data length

    ; If we have buffered data and new data would fill a block, compress
    mov     eax, [b2_buflen]

.update_loop:
    test    r13, r13
    jz      .update_done

    mov     eax, [b2_buflen]

    ; Check if buffer has data and adding more would complete a block
    ; We need to keep at least 1 byte for the final block
    mov     ecx, 128
    sub     ecx, eax            ; remaining space in buffer

    ; If we can fit all remaining data in buffer, just buffer it
    cmp     r13, rcx
    jl      .buffer_remaining
    je      .buffer_remaining_check

    ; We have more data than fits; fill buffer, compress, continue
    test    eax, eax
    jz      .direct_blocks

    ; Fill the buffer
    lea     rdi, [b2_buf + rax]
    mov     rsi, r12
    mov     ecx, 128
    sub     ecx, eax
    push    rcx
    rep     movsb
    pop     rcx
    add     r12, rcx
    sub     r13, rcx
    mov     dword [b2_buflen], 128

    ; If we still have more data, compress the buffer
    test    r13, r13
    jz      .update_done

    ; Increment counter
    add     qword [b2_t], 128
    adc     qword [b2_t+8], 0

    mov     rdi, b2_buf
    call    blake2b_compress
    mov     dword [b2_buflen], 0

.direct_blocks:
    ; Process full blocks directly, but always keep the last partial/full for final
    cmp     r13, 128
    jle     .buffer_remaining

    ; Increment counter
    add     qword [b2_t], 128
    adc     qword [b2_t+8], 0

    mov     rdi, r12
    call    blake2b_compress
    add     r12, 128
    sub     r13, 128
    jmp     .direct_blocks

.buffer_remaining_check:
    ; Exactly fills buffer - only buffer if no more data coming
    ; Since we don't know, just buffer it
.buffer_remaining:
    ; Copy remaining data to buffer
    test    r13, r13
    jz      .update_done
    mov     eax, [b2_buflen]
    lea     rdi, [b2_buf + rax]
    mov     rsi, r12
    mov     rcx, r13
    rep     movsb
    add     eax, r13d
    mov     [b2_buflen], eax

.update_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── BLAKE2b Final ──
blake2b_final:
    push    rbx

    ; Set last block flag
    mov     rax, 0xFFFFFFFFFFFFFFFF
    mov     [b2_f], rax

    ; Increment counter by buflen
    mov     eax, [b2_buflen]
    ; eax is already zero-extended to rax
    add     [b2_t], rax
    adc     qword [b2_t+8], 0

    ; Pad remaining buffer with zeros
    mov     eax, [b2_buflen]
    cmp     eax, 128
    jge     .no_pad
    lea     rdi, [b2_buf + rax]
    mov     ecx, 128
    sub     ecx, eax
    xor     al, al
    rep     stosb
.no_pad:
    ; Compress the final block
    mov     rdi, b2_buf
    call    blake2b_compress

    pop     rbx
    ret

; ── BLAKE2b to hex ──
blake2b_to_hex:
    mov     edx, [b2_outlen]   ; number of bytes to convert
    xor     ecx, ecx
.loop:
    cmp     ecx, edx
    jge     .done
    movzx   eax, byte [b2_h + rcx]
    mov     ebx, eax
    shr     ebx, 4
    movzx   ebx, byte [hex_digits + rbx]
    mov     [hex_out + rcx*2], bl
    and     eax, 0x0F
    movzx   eax, byte [hex_digits + rax]
    mov     [hex_out + rcx*2 + 1], al
    inc     ecx
    jmp     .loop
.done:
    ; Null terminate
    mov     eax, edx
    shl     eax, 1              ; * 2 for hex chars
    mov     byte [hex_out + rax], 0
    ret

; ── Hash one file ──
hash_one_file:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    call    blake2b_init
    cmp     byte [r12], '-'
    jne     .open_file
    cmp     byte [r12+1], 0
    jne     .open_file
    xor     ebx, ebx
    jmp     .read_loop
.open_file:
    mov     rax, SYS_OPEN
    mov     rdi, r12
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    js      .open_error
    mov     ebx, eax
.read_loop:
    mov     rax, SYS_READ
    mov     edi, ebx
    mov     rsi, io_buf
    mov     edx, IO_SIZE
    syscall
    cmp     rax, -EINTR
    je      .read_loop
    test    rax, rax
    js      .read_error
    jz      .read_done
    mov     rdi, io_buf
    mov     rsi, rax
    call    blake2b_update
    jmp     .read_loop
.read_done:
    test    ebx, ebx
    jz      .finalize
    mov     rax, SYS_CLOSE
    mov     edi, ebx
    syscall
.finalize:
    call    blake2b_final
    call    blake2b_to_hex

    ; Calculate hex length
    mov     eax, [b2_outlen]
    shl     eax, 1
    mov     r13d, eax           ; r13d = hex_len

    cmp     byte [flag_tag], 0
    jne     .output_tag
    cmp     byte [flag_zero], 0
    jne     .output_no_escape
    mov     rdi, r12
    call    needs_escape
    test    eax, eax
    jz      .output_no_escape
    ; Escaped output
    mov     rdi, out_buf
    mov     byte [rdi], '\'
    inc     rdi
    mov     rsi, hex_out
    mov     ecx, r13d
    rep     movsb
    mov     byte [rdi], ' '
    inc     rdi
    cmp     byte [flag_binary], 0
    je      .et
    mov     byte [rdi], '*'
    jmp     .em
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
    mov     rdi, out_buf
    mov     rsi, hex_out
    mov     ecx, r13d
    rep     movsb
    mov     byte [rdi], ' '
    inc     rdi
    cmp     byte [flag_binary], 0
    je      .nt
    mov     byte [rdi], '*'
    jmp     .nm
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
    mov     rdi, out_buf
    ; Write "BLAKE2b" or "BLAKE2b-N" tag
    mov     eax, [digest_bits]
    cmp     eax, 512
    je      .tag_default
    ; Write "BLAKE2b-NNN ("
    mov     rsi, str_b2b_tag_prefix
    mov     ecx, str_b2b_tag_prefix_len
    rep     movsb
    ; Write the number
    push    rdi
    mov     eax, [digest_bits]
    call    format_number_to_buf  ; writes to rdi, returns rdi past end
    pop     rsi                   ; old rdi (unused, we need the new rdi)
    ; Actually we need to write directly
    jmp     .tag_after_name
.tag_default:
    mov     rsi, str_b2b_tag_prefix
    mov     ecx, str_b2b_tag_prefix_len
    rep     movsb
    mov     rsi, str_b2b_tag_512
    mov     ecx, str_b2b_tag_512_len
    rep     movsb
.tag_after_name:
    mov     byte [rdi], ' '
    inc     rdi
    mov     byte [rdi], '('
    inc     rdi
    mov     rsi, r12
.tcf: lodsb
    test al, al
    jz .tcfd
    stosb
    jmp .tcf
.tcfd:
    mov     rsi, str_tag_eq
    mov     ecx, str_tag_eq_len
    rep     movsb
    mov     rsi, hex_out
    mov     ecx, r13d
    rep     movsb
    cmp     byte [flag_zero], 0
    jne     .tzt
    mov     byte [rdi], 10
    jmp     .ttd
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

; ── Format number to buffer ──
; eax = number, rdi = output buffer
; Returns with rdi past last written char
format_number_to_buf:
    push    rbx
    push    rcx
    push    rdx
    ; Write digits in reverse to a temp area, then copy
    sub     rsp, 32
    lea     rbx, [rsp + 30]
    mov     byte [rbx+1], 0
    test    eax, eax
    jnz     .fnl
    mov     byte [rbx], '0'
    dec     rbx
    jmp     .fnd
.fnl:
    test    eax, eax
    jz      .fnd
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    add     dl, '0'
    mov     [rbx], dl
    dec     rbx
    jmp     .fnl
.fnd:
    inc     rbx
    ; Copy from rbx to rdi
.fncopy:
    mov     al, [rbx]
    test    al, al
    jz      .fnret
    mov     [rdi], al
    inc     rdi
    inc     rbx
    jmp     .fncopy
.fnret:
    add     rsp, 32
    pop     rdx
    pop     rcx
    pop     rbx
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
    cmp     dword [file_count], 0
    jne     .has_files
    mov     qword [file_args], str_dash
    mov     dword [file_count], 1
.has_files:
    mov     dword [cnt_ok], 0
    mov     dword [cnt_mismatch], 0
    mov     dword [cnt_format_err], 0
    mov     dword [cnt_read_err], 0
    mov     dword [cnt_ignored], 0
    xor     r12d, r12d
.file_loop:
    cmp     r12d, [file_count]
    jge     .files_done
    mov     rdi, [file_args + r12*8]
    call    check_one_file
    inc     r12d
    jmp     .file_loop
.files_done:
    mov     eax, [cnt_ok]
    add     eax, [cnt_mismatch]
    add     eax, [cnt_read_err]
    test    eax, eax
    jnz     .has_valid
    cmp     dword [cnt_format_err], 0
    je      .skip_no_proper
    cmp     byte [flag_status], 0
    jne     .set_error
    WRITE   STDERR, err_prefix, err_prefix_len
    mov     rdi, [file_args]
    cmp     byte [rdi], '-'
    jne     .np_fname
    cmp     byte [rdi+1], 0
    jne     .np_fname
    WRITE   STDERR, str_stdin_name, 14
    jmp     .np_msg
.np_fname:
    mov     rdi, [file_args]
    call    strlen
    mov     rdx, rax
    WRITE   STDERR, [file_args], rdx
.np_msg:
    WRITE   STDERR, str_no_proper, str_no_proper_len
.set_error:
    mov     byte [had_error], 1
    jmp     .print_warns
.has_valid:
.skip_no_proper:
.print_warns:
    cmp     byte [flag_status], 0
    jne     .cm_exit
    cmp     dword [cnt_mismatch], 0
    je      .no_mm
    WRITE   STDERR, str_warn_prefix, str_warn_prefix_len
    cmp     dword [cnt_mismatch], 1
    jne     .mm_p
    WRITE   STDERR, str_checksum_not_match_1, str_checksum_not_match_1_len
    jmp     .no_mm
.mm_p:
    mov     edi, [cnt_mismatch]
    call    print_number_stderr
    WRITE   STDERR, str_checksums_not_match, str_checksums_not_match_len
.no_mm:
    cmp     dword [cnt_read_err], 0
    je      .no_re
    WRITE   STDERR, str_warn_prefix, str_warn_prefix_len
    cmp     dword [cnt_read_err], 1
    jne     .re_p
    WRITE   STDERR, str_file_not_read_1, str_file_not_read_1_len
    jmp     .no_re
.re_p:
    mov     edi, [cnt_read_err]
    call    print_number_stderr
    WRITE   STDERR, str_files_not_read, str_files_not_read_len
.no_re:
    cmp     dword [cnt_format_err], 0
    je      .no_fe
    WRITE   STDERR, str_warn_prefix, str_warn_prefix_len
    cmp     dword [cnt_format_err], 1
    jne     .fe_p
    WRITE   STDERR, str_line_improper_1, str_line_improper_1_len
    jmp     .no_fe
.fe_p:
    mov     edi, [cnt_format_err]
    call    print_number_stderr
    WRITE   STDERR, str_lines_improper, str_lines_improper_len
.no_fe:
.cm_exit:
    movzx   edi, byte [had_error]
    cmp     dword [cnt_mismatch], 0
    je      .n1
    mov     edi, 1
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
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12, rdi
    cmp     byte [r12], '-'
    jne     .cof_open
    cmp     byte [r12+1], 0
    jne     .cof_open
    xor     ebx, ebx
    jmp     .cof_read
.cof_open:
    mov     rax, SYS_OPEN
    mov     rdi, r12
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    js      .cof_open_err
    mov     ebx, eax
.cof_read:
    mov     dword [rsp+4], 0
    mov     dword [rsp+8], 0
    xor     r13d, r13d
.next_line:
    mov     rdi, line_buf
    xor     r14d, r14d
.getchar:
    mov     eax, [rsp+4]
    cmp     eax, [rsp+8]
    jl      .have_char
    mov     rax, SYS_READ
    mov     edi, ebx
    mov     rsi, io_buf
    mov     edx, IO_SIZE
    syscall
    cmp     rax, -EINTR
    je      .getchar
    test    rax, rax
    jle     .eof
    mov     [rsp+8], eax
    mov     dword [rsp+4], 0
.have_char:
    mov     eax, [rsp+4]
    movzx   ecx, byte [io_buf + rax]
    inc     dword [rsp+4]
    cmp     cl, 10
    je      .have_line
    cmp     r14d, 65530
    jge     .getchar
    mov     [line_buf + r14], cl
    inc     r14d
    jmp     .getchar
.eof:
    test    r14d, r14d
    jz      .cof_done
.have_line:
    inc     r13d
    mov     byte [line_buf + r14], 0
    mov     rsi, line_buf
    xor     r15d, r15d
    cmp     byte [rsi], '\'
    jne     .no_esc
    mov     r15d, 1
    inc     rsi
.no_esc:
    ; Try to match "BLAKE2b (" or "BLAKE2b-NNN (" for BSD tag format
    ; For now, try standard format: HEXHASH  filename
    ; Count hex digits
    mov     rdi, rsi
    xor     ecx, ecx
.count_hex:
    movzx   eax, byte [rdi + rcx]
    cmp     al, '0'
    jl      .hex_end
    cmp     al, '9'
    jle     .hex_ok
    cmp     al, 'a'
    jl      .check_upper
    cmp     al, 'f'
    jle     .hex_ok
    jmp     .hex_end
.check_upper:
    cmp     al, 'A'
    jl      .hex_end
    cmp     al, 'F'
    jle     .hex_ok
    jmp     .hex_end
.hex_ok:
    inc     ecx
    jmp     .count_hex
.hex_end:
    ; Valid BLAKE2b hash lengths: 2-128 hex chars, must be even
    cmp     ecx, 2
    jl      .bad_fmt
    cmp     ecx, 128
    jg      .bad_fmt
    test    ecx, 1
    jnz     .bad_fmt

    ; Save the hex length for comparison
    push    rcx                  ; hex_len on stack

    mov     rsi, rdi             ; rsi = start of hex
    lea     rdi, [rsi + rcx]     ; rdi = past hex
    cmp     byte [rdi], ' '
    jne     .bad_fmt_pop
    inc     rdi
    cmp     byte [rdi], ' '
    je      .std_ok
    cmp     byte [rdi], '*'
    je      .std_ok
    jmp     .bad_fmt_pop
.std_ok:
    inc     rdi                  ; rdi = filename

    ; Save hex len in bits for init
    mov     eax, [rsp]           ; hex_len
    shr     eax, 1               ; byte_len
    shl     eax, 3               ; bit_len
    mov     [digest_bits], eax

.verify:
    push    rsi                  ; saved hex string
    push    rdi                  ; saved filename
    call    blake2b_init
    mov     rdi, [rsp]           ; filename
    cmp     byte [rdi], '-'
    jne     .cv_open
    cmp     byte [rdi+1], 0
    jne     .cv_open
    xor     ebx, ebx
    jmp     .cv_read_loop
.cv_open:
    mov     rax, SYS_OPEN
    mov     rdi, [rsp]
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    js      .cv_open_err
    mov     ebx, eax
.cv_read_loop:
    mov     rax, SYS_READ
    mov     edi, ebx
    mov     rsi, io_buf2
    mov     edx, IO_SIZE
    syscall
    cmp     rax, -EINTR
    je      .cv_read_loop
    test    rax, rax
    js      .cv_read_err
    jz      .cv_done
    mov     rdi, io_buf2
    mov     rsi, rax
    call    blake2b_update
    jmp     .cv_read_loop
.cv_done:
    test    ebx, ebx
    jz      .cv_final
    push    rbx
    mov     rax, SYS_CLOSE
    mov     edi, ebx
    syscall
    pop     rbx
.cv_final:
    call    blake2b_final
    call    blake2b_to_hex

    pop     rdi                  ; filename
    pop     rsi                  ; expected hex
    pop     rcx                  ; hex_len

    ; Compare hex_out with expected hex (case-insensitive)
    mov     rax, hex_out
    xor     edx, edx
.cmp_loop:
    cmp     edx, ecx
    jge     .match
    movzx   r8d, byte [rax + rdx]
    movzx   r9d, byte [rsi + rdx]
    ; tolower both
    cmp     r8b, 'A'
    jl      .c1
    cmp     r8b, 'F'
    jg      .c1
    add     r8b, 32
.c1: cmp r9b, 'A'
    jl .c2
    cmp r9b, 'F'
    jg .c2
    add r9b, 32
.c2: cmp r8b, r9b
    jne .no_match
    inc edx
    jmp .cmp_loop
.match:
    inc     dword [cnt_ok]
    cmp     byte [flag_status], 0
    jne     .next_jmp
    cmp     byte [flag_quiet], 0
    jne     .next_jmp
    push    rdi
    call    strlen
    mov     rdx, rax
    pop     rsi
    push    rsi
    WRITE   STDOUT, rsi, rdx
    WRITE   STDOUT, str_ok, str_ok_len
    pop     rdi
    jmp     .next_jmp
.no_match:
    inc     dword [cnt_mismatch]
    mov     byte [had_error], 1
    cmp     byte [flag_status], 0
    jne     .next_jmp
    push    rdi
    call    strlen
    mov     rdx, rax
    pop     rsi
    push    rsi
    WRITE   STDOUT, rsi, rdx
    WRITE   STDOUT, str_failed, str_failed_len
    pop     rdi
    jmp     .next_jmp
.cv_open_err:
    pop     rdi
    pop     rsi
    pop     rcx
    cmp     byte [flag_ignore], 0
    jne     .cv_ign
    inc     dword [cnt_read_err]
    mov     byte [had_error], 1
    cmp     byte [flag_status], 0
    jne     .next_jmp
    WRITE   STDERR, err_prefix, err_prefix_len
    push    rdi
    call    strlen
    mov     rdx, rax
    pop     rsi
    WRITE   STDERR, rsi, rdx
    WRITE   STDERR, err_no_such, err_no_such_len
    push    rsi
    mov     rdi, rsi
    call    strlen
    mov     rdx, rax
    pop     rsi
    WRITE   STDOUT, rsi, rdx
    WRITE   STDOUT, str_failed_open, str_failed_open_len
    jmp     .next_jmp
.cv_ign:
    inc     dword [cnt_ignored]
    jmp     .next_jmp
.cv_read_err:
    pop     rdi
    pop     rsi
    pop     rcx
    inc     dword [cnt_read_err]
    mov     byte [had_error], 1
    jmp     .next_jmp
.bad_fmt_pop:
    pop     rcx
.bad_fmt:
    inc     dword [cnt_format_err]
    cmp     byte [flag_warn], 0
    je      .next_jmp
    WRITE   STDERR, err_prefix, err_prefix_len
    push    r12
    mov     rdi, r12
    cmp     byte [rdi], '-'
    jne     .bf_ns
    cmp     byte [rdi+1], 0
    jne     .bf_ns
    WRITE   STDERR, str_stdin_name, 14
    jmp     .bf_c
.bf_ns:
    call    strlen
    mov     rdx, rax
    WRITE   STDERR, r12, rdx
.bf_c:
    WRITE   STDERR, str_colon_space, str_colon_space_len
    mov     edi, r13d
    call    print_number_stderr
    WRITE   STDERR, str_improperly, str_improperly_len
    pop     r12
.next_jmp:
    jmp     .next_line
.cof_done:
    test    ebx, ebx
    jz      .cof_end
    mov     rax, SYS_CLOSE
    mov     edi, ebx
    syscall
.cof_end:
    cmp     byte [flag_ignore], 0
    je      .cof_ret
    mov     eax, [cnt_ok]
    add     eax, [cnt_mismatch]
    test    eax, eax
    jnz     .cof_ret
    cmp     dword [cnt_ignored], 0
    je      .cof_ret
    cmp     byte [flag_status], 0
    jne     .cof_set_err
    WRITE   STDERR, err_prefix, err_prefix_len
    mov     rdi, r12
    cmp     byte [rdi], '-'
    jne     .nv_fn
    cmp     byte [rdi+1], 0
    jne     .nv_fn
    WRITE   STDERR, str_stdin_name, 14
    jmp     .nv_msg
.nv_fn:
    call    strlen
    mov     rdx, rax
    WRITE   STDERR, r12, rdx
.nv_msg:
    WRITE   STDERR, str_no_file_verified, str_no_file_verified_len
.cof_set_err:
    mov     byte [had_error], 1
.cof_ret:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.cof_open_err:
    WRITE   STDERR, err_prefix, err_prefix_len
    mov     rdi, r12
    call    strlen
    mov     rdx, rax
    WRITE   STDERR, r12, rdx
    WRITE   STDERR, err_no_such, err_no_such_len
    mov     byte [had_error], 1
    jmp     .cof_ret

; ── Print number to stderr ──
print_number_stderr:
    push    rbx
    sub     rsp, 32
    lea     rbx, [rsp + 30]
    mov     byte [rbx+1], 0
    mov     eax, edi
    test    eax, eax
    jnz     .pn_loop
    mov     byte [rbx], '0'
    dec     rbx
    jmp     .pn_done
.pn_loop:
    test    eax, eax
    jz      .pn_done
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    add     dl, '0'
    mov     [rbx], dl
    dec     rbx
    jmp     .pn_loop
.pn_done:
    inc     rbx
    mov     rsi, rbx
    lea     rdx, [rsp + 31]
    sub     rdx, rbx
    WRITE   STDERR, rsi, rdx
    add     rsp, 32
    pop     rbx
    ret

; ════════════════════════════════════════════════════════════════
; DATA SECTION
; ════════════════════════════════════════════════════════════════

hex_digits: db "0123456789abcdef"

; BLAKE2b IV (same as SHA-512 initial hash values)
blake2b_IV:
    dq 0x6A09E667F3BCC908
    dq 0xBB67AE8584CAA73B
    dq 0x3C6EF372FE94F82B
    dq 0xA54FF53A5F1D36F1
    dq 0x510E527FADE682D1
    dq 0x9B05688C2B3E6C1F
    dq 0x1F83D9ABFB41BD6B
    dq 0x5BE0CD19137E2179

; BLAKE2b sigma permutation table (10 rows of 16 bytes)
blake2b_sigma:
    db  0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15
    db 14,10, 4, 8, 9,15,13, 6, 1,12, 0, 2,11, 7, 5, 3
    db 11, 8,12, 0, 5, 2,15,13,10,14, 3, 6, 7, 1, 9, 4
    db  7, 9, 3, 1,13,12,11,14, 2, 6, 5,10, 4, 0,15, 8
    db  9, 0, 5, 7, 2, 4,10,15,14, 1,11,12, 6, 8, 3,13
    db  2,12, 6,10, 0,11, 8, 3, 4,13, 7, 5,15,14, 1, 9
    db 12, 5, 1,15,14,13, 4,10, 0, 7, 6, 3, 9, 2, 8,11
    db 13,11, 7,14,12, 1, 3, 9, 5, 0,15, 4, 8, 6, 2,10
    db  6,15,14, 9,11, 3, 0, 8,12, 2,13, 7, 1, 4,10, 5
    db 10, 2, 8, 4, 7, 6, 1, 5,15,11, 9,14, 3,13,12, 0

s_binary: db "binary", 0
s_check: db "check", 0
s_tag: db "tag", 0
s_text: db "text", 0
s_ignore_missing: db "ignore-missing", 0
s_quiet: db "quiet", 0
s_status: db "status", 0
s_strict: db "strict", 0
s_warn: db "warn", 0
s_help: db "help", 0
s_version: db "version", 0
s_length: db "length", 0
s_length_eq: db "length=", 0

str_dash: db "-", 0
str_stdin_name: db "standard input", 0

; @@DATA_START@@
str_help:
    db "Usage: b2sum [OPTION]... [FILE]...", 10
    db "Print or check BLAKE2b (512-bit) checksums.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db "  -b, --binary          read in binary mode", 10
    db "  -c, --check           read checksums from the FILEs and check them", 10
    db "  -l, --length=N        digest length in bits; must not exceed the max for", 10
    db "                          the blake2 algorithm and must be a multiple of 8", 10
    db "      --tag             create a BSD-style checksum", 10
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
    db "The sums are computed as described in RFC 7693.", 10
    db "When checking, the input should be a former output of this program.", 10
    db "The default mode is to print a line with: checksum, a space,", 10
    db "a character indicating input mode ('*' for binary, ' ' for text", 10
    db "or where binary is insignificant), and name for each FILE.", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/b2sum>", 10
    db "or available locally via: info '(coreutils) b2sum invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "b2sum (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Padraig Brady and Samuel Neves.", 10
str_version_len equ $ - str_version

str_ok: db ": OK", 10
str_ok_len equ $ - str_ok
str_failed: db ": FAILED", 10
str_failed_len equ $ - str_failed
str_failed_open: db ": FAILED open or read", 10
str_failed_open_len equ $ - str_failed_open

str_b2b_tag_prefix: db "BLAKE2b-"
str_b2b_tag_prefix_len equ $ - str_b2b_tag_prefix
str_b2b_tag_512: db "512"
str_b2b_tag_512_len equ $ - str_b2b_tag_512
str_tag_eq: db ") = "
str_tag_eq_len equ $ - str_tag_eq

str_colon_space: db ": "
str_colon_space_len equ $ - str_colon_space

err_prefix: db "b2sum: "
err_prefix_len equ $ - err_prefix
err_no_such: db ": No such file or directory", 10
err_no_such_len equ $ - err_no_such
err_perm: db ": Permission denied", 10
err_perm_len equ $ - err_perm
err_is_dir: db ": Is a directory", 10
err_is_dir_len equ $ - err_is_dir
err_io: db ": Input/output error", 10
err_io_len equ $ - err_io

err_unrec: db "b2sum: unrecognized option '"
err_unrec_len equ $ - err_unrec
err_inval: db "b2sum: invalid option -- '"
err_inval_len equ $ - err_inval
err_suffix:   db 0xE2, 0x80, 0x99, 10
err_suffix_len equ $ - err_suffix

err_tag_check: db "b2sum: the --tag option is meaningless when verifying checksums", 10
               db "Try 'b2sum --help' for more information.", 10
err_tag_check_len equ $ - err_tag_check

str_warn_prefix: db "b2sum: WARNING: "
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
str_no_proper: db ": no properly formatted BLAKE2b checksum lines found", 10
str_no_proper_len equ $ - str_no_proper
str_no_file_verified: db ": no file was verified", 10
str_no_file_verified_len equ $ - str_no_file_verified
str_improperly: db ": improperly formatted BLAKE2b checksum line", 10
str_improperly_len equ $ - str_improperly
; @@DATA_END@@

file_end:
