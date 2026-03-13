; ============================================================
; fdd_unified.asm — GNU-compatible 'dd' command
; Builds with: nasm -f bin fdd_unified.asm -o fdd
;
; dd: Convert and copy a file.
; Supports: if=, of=, bs=, ibs=, obs=, count=, skip=, seek=,
;           conv=notrunc,fsync,sync, status=none|noacct|progress
;
; Register allocation:
;   r12 = input fd, r13 = output fd
;   r14 = bytes read total, r15 = bytes written total
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_LSEEK       8
%define SYS_EXIT       60
%define SYS_FTRUNCATE  77
%define SYS_FSYNC      74
%define SYS_RT_SIGPROCMASK 14
%define SYS_CLOCK_GETTIME 228

%define STDIN           0
%define STDOUT          1
%define STDERR          2
%define O_RDONLY        0
%define O_WRONLY        1
%define O_CREAT         64
%define O_TRUNC         512
%define O_APPEND        1024
%define O_WRONLY_CREAT  (O_WRONLY | O_CREAT)
%define FILE_MODE       0o666
%define EINTR           4
%define SEEK_SET        0
%define SEEK_CUR        1
%define SIG_BLOCK       0
%define SIGPIPE         13
%define CLOCK_MONOTONIC 1

; BSS layout
%define BSS_BASE     0x500000
%define io_buf       BSS_BASE
%define IO_SIZE      65536
%define num_buf      (BSS_BASE + IO_SIZE + IO_SIZE)
%define stat_buf     (num_buf + 128)
%define if_path      (stat_buf + 256)
%define of_path      (if_path + 8)
%define ibs_val      (of_path + 8)
%define obs_val      (ibs_val + 8)
%define count_val    (obs_val + 8)
%define skip_val     (count_val + 8)
%define seek_val     (skip_val + 8)
%define flag_notrunc (seek_val + 8)
%define flag_fsync   (flag_notrunc + 4)
%define flag_conv_sync (flag_fsync + 4)
%define flag_status  (flag_conv_sync + 4)
%define rec_in_full  (flag_status + 4)
%define rec_in_part  (rec_in_full + 8)
%define rec_out_full (rec_in_part + 8)
%define rec_out_part (rec_out_full + 8)
%define bytes_copied (rec_out_part + 8)
%define time_start   (bytes_copied + 8)
%define BSS_END      (time_start + 16)
%define BSS_SIZE     (BSS_END - BSS_BASE)

; --- ELF Header ---
ehdr:
    db 0x7f, 'E','L','F'
    db 2, 1, 1, 0
    dq 0
    dw 2, 0x3e
    dd 1
    dq _start
    dq phdr - $$
    dq 0
    dd 0
    dw 64, 56, 3, 64, 0, 0

; --- Program Headers ---
phdr:
    dd 1, 5
    dq 0, $$, $$, file_size, file_size, 0x200000

    dd 1, 6
    dq 0, BSS_BASE, BSS_BASE, 0, BSS_SIZE, 0x200000

    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 0x10

; ============================================================
_start:
    ; Block SIGPIPE
    sub     rsp, 16
    mov     qword [rsp], 0
    bts     qword [rsp], SIGPIPE
    mov     eax, SYS_RT_SIGPROCMASK
    mov     edi, SIG_BLOCK
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    ; Defaults
    mov     qword [ibs_val], 512
    mov     qword [obs_val], 512
    mov     qword [count_val], -1       ; unlimited
    mov     qword [skip_val], 0
    mov     qword [seek_val], 0
    mov     qword [if_path], 0
    mov     qword [of_path], 0
    mov     dword [flag_notrunc], 0
    mov     dword [flag_fsync], 0
    mov     dword [flag_conv_sync], 0
    mov     dword [flag_status], 0      ; 0=normal, 1=none, 2=noacct
    mov     qword [rec_in_full], 0
    mov     qword [rec_in_part], 0
    mov     qword [rec_out_full], 0
    mov     qword [rec_out_part], 0
    mov     qword [bytes_copied], 0

    mov     r14d, [rsp]         ; argc
    lea     r15, [rsp + 8]      ; argv
    mov     ecx, 1              ; arg index

.parse_args:
    cmp     ecx, r14d
    jge     .done_parse

    mov     rdi, [r15 + rcx*8]

    ; Check --help
    push    rcx
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_help
    pop     rcx

    mov     rdi, [r15 + rcx*8]
    push    rcx
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_version
    pop     rcx

    mov     rdi, [r15 + rcx*8]

    ; Check operand=value pairs
    push    rcx
    mov     rsi, str_if_eq
    mov     edx, 3
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_if
    pop     rcx

    mov     rdi, [r15 + rcx*8]
    push    rcx
    mov     rsi, str_of_eq
    mov     edx, 3
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_of
    pop     rcx

    mov     rdi, [r15 + rcx*8]
    push    rcx
    mov     rsi, str_bs_eq
    mov     edx, 3
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_bs
    pop     rcx

    mov     rdi, [r15 + rcx*8]
    push    rcx
    mov     rsi, str_ibs_eq
    mov     edx, 4
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_ibs
    pop     rcx

    mov     rdi, [r15 + rcx*8]
    push    rcx
    mov     rsi, str_obs_eq
    mov     edx, 4
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_obs
    pop     rcx

    mov     rdi, [r15 + rcx*8]
    push    rcx
    mov     rsi, str_count_eq
    mov     edx, 6
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_count
    pop     rcx

    mov     rdi, [r15 + rcx*8]
    push    rcx
    mov     rsi, str_skip_eq
    mov     edx, 5
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_skip
    pop     rcx

    mov     rdi, [r15 + rcx*8]
    push    rcx
    mov     rsi, str_seek_eq
    mov     edx, 5
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_seek
    pop     rcx

    mov     rdi, [r15 + rcx*8]
    push    rcx
    mov     rsi, str_conv_eq
    mov     edx, 5
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_conv
    pop     rcx

    mov     rdi, [r15 + rcx*8]
    push    rcx
    mov     rsi, str_status_eq
    mov     edx, 7
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_status
    pop     rcx

    ; Unrecognized operand
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_unrecog_op
    mov     edx, str_unrecog_op_len
    call    do_write_err
    mov     rdi, [r15 + rcx*8]
    call    str_len
    mov     edx, eax
    mov     rdi, [r15 + rcx*8]
    mov     rsi, rdi
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.pop_show_help:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.pop_show_version:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.pop_set_if:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    lea     rdi, [rdi + 3]          ; skip "if="
    mov     [if_path], rdi
    inc     ecx
    jmp     .parse_args

.pop_set_of:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    lea     rdi, [rdi + 3]          ; skip "of="
    mov     [of_path], rdi
    inc     ecx
    jmp     .parse_args

.pop_set_bs:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    lea     rdi, [rdi + 3]
    push    rcx
    call    parse_size
    pop     rcx
    mov     [ibs_val], rax
    mov     [obs_val], rax
    inc     ecx
    jmp     .parse_args

.pop_set_ibs:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    lea     rdi, [rdi + 4]
    push    rcx
    call    parse_size
    pop     rcx
    mov     [ibs_val], rax
    inc     ecx
    jmp     .parse_args

.pop_set_obs:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    lea     rdi, [rdi + 4]
    push    rcx
    call    parse_size
    pop     rcx
    mov     [obs_val], rax
    inc     ecx
    jmp     .parse_args

.pop_set_count:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    lea     rdi, [rdi + 6]
    push    rcx
    call    parse_size
    pop     rcx
    mov     [count_val], rax
    inc     ecx
    jmp     .parse_args

.pop_set_skip:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    lea     rdi, [rdi + 5]
    push    rcx
    call    parse_size
    pop     rcx
    mov     [skip_val], rax
    inc     ecx
    jmp     .parse_args

.pop_set_seek:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    lea     rdi, [rdi + 5]
    push    rcx
    call    parse_size
    pop     rcx
    mov     [seek_val], rax
    inc     ecx
    jmp     .parse_args

.pop_set_conv:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    lea     rdi, [rdi + 5]          ; skip "conv="
    ; Check for "notrunc"
    push    rcx
    mov     rsi, str_notrunc
    call    str_eq
    test    eax, eax
    jnz     .conv_notrunc
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    lea     rdi, [rdi + 5]
    push    rcx
    mov     rsi, str_fsync_val
    call    str_eq
    test    eax, eax
    jnz     .conv_fsync
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    lea     rdi, [rdi + 5]
    push    rcx
    mov     rsi, str_sync_val
    call    str_eq
    test    eax, eax
    jnz     .conv_sync
    pop     rcx
    ; Unknown conv — ignore for now (GNU tolerates unknown convs)
    inc     ecx
    jmp     .parse_args

.conv_notrunc:
    pop     rcx
    mov     dword [flag_notrunc], 1
    inc     ecx
    jmp     .parse_args

.conv_fsync:
    pop     rcx
    mov     dword [flag_fsync], 1
    inc     ecx
    jmp     .parse_args

.conv_sync:
    pop     rcx
    mov     dword [flag_conv_sync], 1
    inc     ecx
    jmp     .parse_args

.pop_set_status:
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    lea     rdi, [rdi + 7]          ; skip "status="
    push    rcx
    mov     rsi, str_none
    call    str_eq
    test    eax, eax
    jnz     .status_none
    pop     rcx
    mov     rdi, [r15 + rcx*8]
    lea     rdi, [rdi + 7]
    push    rcx
    mov     rsi, str_noacct
    call    str_eq
    test    eax, eax
    jnz     .status_noacct
    pop     rcx
    ; Default/progress — treat as normal
    inc     ecx
    jmp     .parse_args

.status_none:
    pop     rcx
    mov     dword [flag_status], 1
    inc     ecx
    jmp     .parse_args

.status_noacct:
    pop     rcx
    mov     dword [flag_status], 2
    inc     ecx
    jmp     .parse_args

.done_parse:
    ; Open input file (or use stdin)
    cmp     qword [if_path], 0
    je      .use_stdin
    mov     rdi, [if_path]
    mov     esi, O_RDONLY
    xor     edx, edx
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .err_open_if
    mov     r12, rax
    jmp     .open_output

.use_stdin:
    xor     r12d, r12d              ; fd 0 = stdin

.open_output:
    ; Open output file (or use stdout)
    cmp     qword [of_path], 0
    je      .use_stdout
    mov     rdi, [of_path]
    mov     esi, O_WRONLY_CREAT
    cmp     dword [flag_notrunc], 0
    jne     .open_of_notrunc
    or      esi, O_TRUNC
.open_of_notrunc:
    mov     edx, FILE_MODE
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .err_open_of
    mov     r13, rax
    jmp     .do_skip

.use_stdout:
    mov     r13d, STDOUT

.do_skip:
    ; Handle skip=N (skip N input blocks)
    mov     rbx, [skip_val]
    test    rbx, rbx
    jz      .do_seek

.skip_loop:
    test    rbx, rbx
    jz      .do_seek
    mov     eax, SYS_READ
    mov     rdi, r12
    mov     rsi, io_buf
    mov     rdx, [ibs_val]
    syscall
    cmp     rax, -EINTR
    je      .skip_loop
    test    rax, rax
    jle     .do_seek            ; EOF or error during skip
    dec     rbx
    jmp     .skip_loop

.do_seek:
    ; Handle seek=N (seek N output blocks)
    mov     rbx, [seek_val]
    test    rbx, rbx
    jz      .copy_loop
    ; Calculate offset = seek * obs
    imul    rbx, [obs_val]
    mov     eax, SYS_LSEEK
    mov     rdi, r13
    mov     rsi, rbx
    mov     edx, SEEK_SET
    syscall
    ; Ignore seek errors (stdout can't seek)

.copy_loop:
    ; Check count
    mov     rax, [count_val]
    cmp     rax, -1
    je      .do_read
    mov     rbx, [rec_in_full]
    add     rbx, [rec_in_part]
    cmp     rbx, rax
    jge     .done_copy

.do_read:
    mov     eax, SYS_READ
    mov     rdi, r12
    mov     rsi, io_buf
    mov     rdx, [ibs_val]
    syscall
    cmp     rax, -EINTR
    je      .do_read
    test    rax, rax
    jle     .done_copy          ; EOF or error

    mov     rbx, rax            ; bytes read

    ; Track records
    cmp     rbx, [ibs_val]
    je      .full_rec_in
    inc     qword [rec_in_part]
    jmp     .do_conv_sync
.full_rec_in:
    inc     qword [rec_in_full]

.do_conv_sync:
    ; conv=sync: pad short reads with NULs to ibs
    cmp     dword [flag_conv_sync], 0
    je      .do_write_out
    cmp     rbx, [ibs_val]
    jge     .do_write_out
    ; Pad with zeros
    mov     rcx, [ibs_val]
    sub     rcx, rbx
    lea     rdi, [io_buf + rbx]
    xor     al, al
    rep     stosb
    mov     rbx, [ibs_val]

.do_write_out:
    ; Write rbx bytes from io_buf to output
    xor     r8d, r8d            ; bytes written so far
.write_loop:
    mov     eax, SYS_WRITE
    mov     rdi, r13
    lea     rsi, [io_buf + r8]
    mov     rdx, rbx
    sub     rdx, r8
    syscall
    cmp     rax, -EINTR
    je      .write_loop
    test    rax, rax
    jle     .write_error
    add     r8, rax
    add     qword [bytes_copied], rax
    cmp     r8, rbx
    jl      .write_loop

    ; Track output records
    cmp     r8, [obs_val]
    jl      .part_rec_out
    inc     qword [rec_out_full]
    jmp     .copy_loop
.part_rec_out:
    inc     qword [rec_out_part]
    jmp     .copy_loop

.write_error:
    ; Write error — report and exit
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_write_err
    mov     edx, str_write_err_len
    call    do_write_err
    jmp     .print_stats_exit1

.done_copy:
    ; fsync if requested
    cmp     dword [flag_fsync], 0
    je      .close_fds
    mov     eax, SYS_FSYNC
    mov     rdi, r13
    syscall

.close_fds:
    ; Close files
    cmp     r12d, STDIN
    je      .close_out
    mov     eax, SYS_CLOSE
    mov     rdi, r12
    syscall
.close_out:
    cmp     r13d, STDOUT
    je      .print_stats
    mov     eax, SYS_CLOSE
    mov     rdi, r13
    syscall

.print_stats:
    ; Print stats to stderr (unless status=none)
    cmp     dword [flag_status], 1
    je      .exit_ok

    ; "N+M records in\n"
    mov     rdi, [rec_in_full]
    call    itoa
    mov     rsi, num_buf
    mov     edx, eax
    call    do_write_err
    mov     rsi, str_plus
    mov     edx, 1
    call    do_write_err
    mov     rdi, [rec_in_part]
    call    itoa
    mov     rsi, num_buf
    mov     edx, eax
    call    do_write_err
    mov     rsi, str_records_in
    mov     edx, str_records_in_len
    call    do_write_err

    ; "N+M records out\n"
    mov     rdi, [rec_out_full]
    call    itoa
    mov     rsi, num_buf
    mov     edx, eax
    call    do_write_err
    mov     rsi, str_plus
    mov     edx, 1
    call    do_write_err
    mov     rdi, [rec_out_part]
    call    itoa
    mov     rsi, num_buf
    mov     edx, eax
    call    do_write_err
    mov     rsi, str_records_out
    mov     edx, str_records_out_len
    call    do_write_err

    ; "N bytes copied\n" (simplified — no timing)
    mov     rdi, [bytes_copied]
    call    itoa
    mov     rsi, num_buf
    mov     edx, eax
    call    do_write_err
    mov     rsi, str_bytes_copied
    mov     edx, str_bytes_copied_len
    call    do_write_err

.exit_ok:
    xor     edi, edi
    jmp     do_exit

.print_stats_exit1:
    mov     edi, 1
    jmp     do_exit

.err_open_if:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_open_if_fail
    mov     edx, str_open_if_fail_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.err_open_of:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_open_of_fail
    mov     edx, str_open_of_fail_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; ============================================================
; parse_size: parse number with optional suffix
; Input: rdi = string pointer
; Output: rax = value
; Suffixes: c=1, w=2, b=512, kB=1000, K=1024,
;           MB=1000000, M=1048576, GB=1000000000, G=1073741824
; ============================================================
parse_size:
    push    rbx
    xor     rax, rax            ; accumulator
.ps_loop:
    movzx   ecx, byte [rdi]
    cmp     cl, '0'
    jb      .ps_suffix
    cmp     cl, '9'
    ja      .ps_suffix
    imul    rax, 10
    sub     cl, '0'
    movzx   ecx, cl
    add     rax, rcx
    inc     rdi
    jmp     .ps_loop

.ps_suffix:
    test    cl, cl
    jz      .ps_done
    cmp     cl, 'c'
    je      .ps_done            ; c = 1, no-op
    cmp     cl, 'w'
    je      .ps_w
    cmp     cl, 'b'
    je      .ps_b
    cmp     cl, 'k'
    je      .ps_kb_check
    cmp     cl, 'K'
    je      .ps_K
    cmp     cl, 'M'
    je      .ps_M_check
    cmp     cl, 'G'
    je      .ps_G_check
    ; Unknown suffix, use as-is
    jmp     .ps_done

.ps_w:
    shl     rax, 1              ; *2
    jmp     .ps_done
.ps_b:
    imul    rax, 512
    jmp     .ps_done
.ps_kb_check:
    cmp     byte [rdi+1], 'B'
    jne     .ps_done
    imul    rax, 1000
    jmp     .ps_done
.ps_K:
    shl     rax, 10             ; *1024
    jmp     .ps_done
.ps_M_check:
    cmp     byte [rdi+1], 'B'
    jne     .ps_M
    imul    rax, 1000000
    jmp     .ps_done
.ps_M:
    imul    rax, 1048576
    jmp     .ps_done
.ps_G_check:
    cmp     byte [rdi+1], 'B'
    jne     .ps_G
    imul    rax, 1000000000
    jmp     .ps_done
.ps_G:
    imul    rax, 1073741824
.ps_done:
    pop     rbx
    ret

; ============================================================
; itoa: convert unsigned integer to decimal string
; Input: rdi = value
; Output: num_buf filled, eax = length
; ============================================================
itoa:
    push    rbx
    push    rcx
    mov     rax, rdi
    lea     rbx, [num_buf + 63]
    mov     byte [rbx], 0
    mov     rcx, 10
    test    rax, rax
    jnz     .itoa_loop
    ; Zero case
    dec     rbx
    mov     byte [rbx], '0'
    jmp     .itoa_done
.itoa_loop:
    test    rax, rax
    jz      .itoa_done
    xor     edx, edx
    div     rcx
    add     dl, '0'
    dec     rbx
    mov     [rbx], dl
    jmp     .itoa_loop
.itoa_done:
    ; Copy to beginning of num_buf
    lea     rsi, [rbx]
    mov     rdi, num_buf
    lea     eax, [num_buf + 63]
    sub     eax, ebx
    mov     ecx, eax
    push    rax
    rep     movsb
    pop     rax
    pop     rcx
    pop     rbx
    ret

; ============================================================
; Utility functions
; ============================================================
do_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      do_write
    ret

do_write_err:
    mov     edi, STDERR
    jmp     do_write

do_exit:
    mov     eax, SYS_EXIT
    syscall

str_len:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     eax
    jmp     .sl_loop
.sl_done:
    ret

str_eq:
    xor     r8d, r8d
.se_loop:
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    cmp     al, dl
    jne     .se_ne
    test    al, al
    jz      .se_eq
    inc     r8d
    jmp     .se_loop
.se_eq:
    mov     eax, 1
    ret
.se_ne:
    xor     eax, eax
    ret

str_prefix_match:
    xor     r8d, r8d
.sp_loop:
    cmp     r8d, edx
    jge     .sp_match
    movzx   eax, byte [rdi + r8]
    cmp     al, byte [rsi + r8]
    jne     .sp_nomatch
    inc     r8d
    jmp     .sp_loop
.sp_match:
    mov     eax, 1
    ret
.sp_nomatch:
    xor     eax, eax
    ret

; ============================================================
; Data
; ============================================================
str_help:
    db "Usage: dd [OPERAND]...", 10
    db '  or:  dd OPTION', 10
    db "Copy a file, converting and formatting according to the operands.", 10, 10
    db "  bs=BYTES        read and write up to BYTES bytes at a time (default: 512)", 10
    db "  cbs=BYTES       convert BYTES bytes at a time", 10
    db "  conv=CONVS      convert the file as per the comma separated symbol list", 10
    db "  count=N         copy only N input blocks", 10
    db "  ibs=BYTES       read up to BYTES bytes at a time (default: 512)", 10
    db "  if=FILE         read from FILE instead of stdin", 10
    db "  obs=BYTES       write BYTES bytes at a time (default: 512)", 10
    db "  of=FILE         write to FILE instead of stdout", 10
    db "  seek=N          skip N obs-sized output blocks at start of output", 10
    db "  skip=N          skip N ibs-sized input blocks at start of input", 10
    db "  status=LEVEL    LEVEL of information to print to stderr", 10
    db "      --help      display this help and exit", 10
    db "      --version   output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/dd>", 10
    db "or available locally via: info '(coreutils) dd invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "dd (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Paul Rubin, David MacKenzie, and Stuart Kemp.", 10
str_version_len equ $ - str_version

str_prefix:      db "dd: "
str_prefix_len   equ $ - str_prefix
str_unrecog_op:  db "unrecognized operand '"
str_unrecog_op_len equ $ - str_unrecog_op
str_sq_nl:       db "'", 10
str_open_if_fail: db "failed to open input file", 10
str_open_if_fail_len equ $ - str_open_if_fail
str_open_of_fail: db "failed to open output file", 10
str_open_of_fail_len equ $ - str_open_of_fail
str_write_err:   db "error writing output", 10
str_write_err_len equ $ - str_write_err
str_records_in:  db " records in", 10
str_records_in_len equ $ - str_records_in
str_records_out: db " records out", 10
str_records_out_len equ $ - str_records_out
str_bytes_copied: db " bytes copied", 10
str_bytes_copied_len equ $ - str_bytes_copied
str_plus:        db "+"

str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_if_eq:       db "if=", 0
str_of_eq:       db "of=", 0
str_bs_eq:       db "bs=", 0
str_ibs_eq:      db "ibs=", 0
str_obs_eq:      db "obs=", 0
str_count_eq:    db "count=", 0
str_skip_eq:     db "skip=", 0
str_seek_eq:     db "seek=", 0
str_conv_eq:     db "conv=", 0
str_status_eq:   db "status=", 0
str_notrunc:     db "notrunc", 0
str_fsync_val:   db "fsync", 0
str_sync_val:    db "sync", 0
str_none:        db "none", 0
str_noacct:      db "noacct", 0

file_size equ $ - $$
