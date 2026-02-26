; fcut_unified.asm — Unified single-file build of fcut
; Auto-merged from modular source — DO NOT EDIT
; Edit tools/fcut.asm and rebuild instead
; Build: nasm -f bin unified/fcut_unified.asm -o fcut_tiny && chmod +x fcut_tiny

BITS 64
org 0x400000

; ── Linux syscall numbers and constants ──
; linux.inc — Linux x86-64 syscall numbers and constants
; Shared across all fcoreutils assembly tools
%define LINUX_INC
; ── Syscall Numbers ──
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_FSTAT           5
%define SYS_LSEEK           8
%define SYS_MMAP            9
%define SYS_MUNMAP         11
%define SYS_BRK            12
%define SYS_RT_SIGACTION   13
%define SYS_RT_SIGPROCMASK 14
%define SYS_IOCTL          16
%define SYS_ACCESS         21
%define SYS_PIPE           22
%define SYS_DUP2           33
%define SYS_NANOSLEEP      35
%define SYS_GETPID         39
%define SYS_FORK           57
%define SYS_EXECVE         59
%define SYS_EXIT           60
%define SYS_UNAME          63
%define SYS_GETCWD         79
%define SYS_GETUID        102
%define SYS_GETGID        104
%define SYS_GETEUID       107
%define SYS_GETEGID       108
%define SYS_SYNC          162
%define SYS_OPENAT        257
; ── File Descriptors ──
%define STDIN               0
%define STDOUT              1
%define STDERR              2
; ── Open Flags ──
%define O_RDONLY            0
; ── Signal Numbers ──
%define SIGPIPE            13
%define SIG_BLOCK           0
; ── Error Codes (negated) ──
%define EINTR              -4
%define EPIPE             -32
%define ENOENT             -2
%define EACCES            -13
; ── Buffer Sizes ──
%define BUF_SIZE        65536

; ── fcut configuration ──
%define MAX_RANGES      256
%define MAX_LINE        (256*1024)
%define RANGE_SHIFT     4
%define MAX_FILES       256
%define MAX_OUTDELIM    256
%define BITSET_SIZE     8192
%define BITSET_MAXBIT   65536

%define MODE_NONE       0
%define MODE_BYTES      1
%define MODE_CHARS      2
%define MODE_FIELDS     3

; ── Macros ──
; macros.inc — Reusable assembly macros for fcoreutils
; Shared across all fcoreutils assembly tools


; WRITE fd, buf, len — raw write syscall
%macro WRITE 3
    mov     rax, SYS_WRITE
    mov     rdi, %1
    mov     rsi, %2
    mov     rdx, %3
    syscall
%endmacro

; READ fd, buf, len — raw read syscall
%macro READ 3
    mov     rax, SYS_READ
    mov     rdi, %1
    mov     rsi, %2
    mov     rdx, %3
    syscall
%endmacro

; EXIT code — exit process
%macro EXIT 1
    mov     rax, SYS_EXIT
    mov     rdi, %1
    syscall
%endmacro

; OPEN path, flags, mode — open file
%macro OPEN 3
    mov     rax, SYS_OPEN
    mov     rdi, %1
    mov     rsi, %2
    mov     rdx, %3
    syscall
%endmacro

; CLOSE fd — close file descriptor
%macro CLOSE 1
    mov     rax, SYS_CLOSE
    mov     rdi, %1
    syscall
%endmacro

; BLOCK_SIGPIPE — block SIGPIPE so write returns EPIPE instead of killing us
%macro BLOCK_SIGPIPE 0
    sub     rsp, 16
    mov     qword [rsp], (1 << (SIGPIPE - 1))
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi            ; SIG_BLOCK
    mov     rsi, rsp
    xor     edx, edx            ; old_set = NULL
    mov     r10d, 8             ; sigsetsize
    syscall
    add     rsp, 16
%endmacro



; ── BSS Variables (at 0x500000, zero-filled by kernel) ──
%define mode  0x500000
%define delim  0x500001
%define line_delim  0x500002
%define only_delimited  0x500003
%define complement  0x500004
%define zero_terminated  0x500005
%define past_dashdash  0x500006
%define had_error  0x500007
%define has_open_end  0x500008
%define out_delim_set  0x500009
%define tmp_char  0x50000A
%define range_spec  0x50000C
%define num_ranges  0x500014
%define ranges  0x50001C
%define num_files  0x50101C
%define current_fd  0x501020
%define files  0x501024
%define out_delim_len  0x501824
%define out_delim_buf  0x501828
%define bitset  0x501930
%define in_buf  0x503930
%define out_buf  0x513930
%define out_buf_pos  0x523930
%define line_buf  0x523940
%define line_buf_pos  0x563940
%define BSS_SIZE  407876

; ── ELF64 Header ──
ehdr:
    db      0x7f, "ELF"
    db      2, 1, 1, 0
    dq      0
    dw      2
    dw      0x3E
    dd      1
    dq      _start
    dq      phdr - ehdr
    dq      0
    dd      0
    dw      ehdr_end - ehdr
    dw      phdr_size
    dw      3
    dw      0, 0, 0
ehdr_end:

; ── Program Headers ──
phdr:
    dd      1                       ; PT_LOAD
    dd      5                       ; PF_R | PF_X
    dq      0
    dq      0x400000
    dq      0x400000
    dq      file_end - ehdr
    dq      file_end - ehdr
    dq      0x1000
phdr_size equ $ - phdr

    ; BSS segment
    dd      1                       ; PT_LOAD
    dd      6                       ; PF_R | PF_W
    dq      0
    dq      0x500000
    dq      0x500000
    dq      0
    dq      BSS_SIZE
    dq      0x1000

    ; GNU Stack (NX)
    dd      0x6474E551              ; PT_GNU_STACK
    dd      6                       ; PF_R | PF_W (NX)
    dq      0, 0, 0, 0, 0
    dq      0x10

; ── Code ──

_start:
    BLOCK_SIGPIPE

    ; Save argc and argv
    mov     ecx, [rsp]
    lea     r14, [rsp + 8]          ; r14 = &argv[0]

    ; Initialize state
    mov     byte [mode], MODE_NONE
    mov     byte [delim], 9
    mov     byte [line_delim], 10
    mov     byte [only_delimited], 0
    mov     byte [complement], 0
    mov     byte [zero_terminated], 0
    mov     dword [num_ranges], 0
    mov     dword [num_files], 0
    mov     dword [out_delim_len], 0
    mov     byte [out_delim_set], 0
    mov     byte [had_error], 0
    mov     dword [out_buf_pos], 0
    mov     qword [range_spec], 0

    ; Parse arguments
    lea     rbx, [r14 + 8]
    dec     ecx
    mov     byte [past_dashdash], 0

.parse_loop:
    test    ecx, ecx
    jle     .parse_done
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .parse_done

    cmp     byte [past_dashdash], 1
    je      .add_file

    ; Check for "--"
    cmp     byte [rsi], '-'
    jne     .add_file
    cmp     byte [rsi + 1], '-'
    jne     .check_short
    cmp     byte [rsi + 2], 0
    jne     .long_opt
    ; Exactly "--"
    mov     byte [past_dashdash], 1
    jmp     .next_arg

.long_opt:
    call    parse_long_option
    jmp     .next_arg

.check_short:
    cmp     byte [rsi + 1], 0
    je      .add_file              ; bare "-" is stdin
    inc     rsi
    call    parse_short_options
    jmp     .next_arg

.add_file:
    mov     eax, [num_files]
    cmp     eax, MAX_FILES
    jge     .next_arg
    lea     rdi, [files]
    mov     rdx, rax
    mov     [rdi + rdx*8], rsi
    inc     eax
    mov     [num_files], eax
    jmp     .next_arg

.next_arg:
    add     rbx, 8
    dec     ecx
    jmp     .parse_loop

.parse_done:
    ; Validate mode
    cmp     byte [mode], MODE_NONE
    jne     .mode_ok
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_no_mode]
    mov     edx, err_no_mode_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_try_help]
    mov     edx, err_try_help_len
    WRITE   STDERR, rsi, rdx
    EXIT    1

.mode_ok:
    ; Parse range specification
    mov     rsi, [range_spec]
    test    rsi, rsi
    jz      .err_no_spec
    call    parse_ranges
    test    eax, eax
    jnz     .exit_error

    ; Build bitset from ranges
    call    build_bitset

    ; If complement AND fields mode, invert bitset
    ; (bytes/chars complement is handled inline in process_line)
    cmp     byte [complement], 1
    jne     .no_comp
    cmp     byte [mode], MODE_FIELDS
    jne     .no_comp
    call    invert_bitset
.no_comp:

    ; Set up output delimiter
    cmp     byte [out_delim_set], 1
    je      .outdelim_ready
    cmp     byte [mode], MODE_FIELDS
    jne     .outdelim_empty
    mov     al, [delim]
    mov     [out_delim_buf], al
    mov     dword [out_delim_len], 1
    jmp     .outdelim_ready
.outdelim_empty:
    mov     dword [out_delim_len], 0
.outdelim_ready:

    ; Default to stdin if no files
    cmp     dword [num_files], 0
    jne     .process_files
    lea     rax, [stdin_name]
    mov     [files], rax
    mov     dword [num_files], 1

.process_files:
    xor     r12d, r12d

.file_loop:
    cmp     r12d, [num_files]
    jge     .all_done

    lea     rdi, [files]
    mov     rdx, r12
    mov     rsi, [rdi + rdx*8]

    cmp     byte [rsi], '-'
    jne     .open_file
    cmp     byte [rsi + 1], 0
    jne     .open_file
    xor     edi, edi
    jmp     .process_fd

.open_file:
    mov     rdi, rsi
    xor     esi, esi
    xor     edx, edx
    mov     rax, SYS_OPEN
    syscall
    test    rax, rax
    js      .open_error
    mov     edi, eax
    jmp     .process_fd

.open_error:
    push    r12
    push    rax                    ; save errno
    lea     rdi, [files]
    mov     rdx, r12
    mov     rsi, [rdi + rdx*8]
    pop     rax
    neg     eax                    ; positive errno
    call    print_file_error
    mov     byte [had_error], 1
    pop     r12
    inc     r12d
    jmp     .file_loop

.process_fd:
    mov     [current_fd], edi
    call    process_input
    mov     edi, [current_fd]
    test    edi, edi
    jz      .no_close
    CLOSE   rdi
.no_close:
    inc     r12d
    jmp     .file_loop

.all_done:
    call    flush_output
    test    eax, eax
    jnz     .exit_pipe

    movzx   edi, byte [had_error]
    EXIT    rdi

.exit_pipe:
    EXIT    0

.exit_error:
    EXIT    1

.err_no_spec:
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_no_mode]
    mov     edx, err_no_mode_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_try_help]
    mov     edx, err_try_help_len
    WRITE   STDERR, rsi, rdx
    EXIT    1

; ============================================================================
;                    ARGUMENT PARSING - LONG OPTIONS
; ============================================================================

; parse_long_option: rsi = arg (starts with "--")
;   rbx = current argv pointer, ecx = remaining args
parse_long_option:
    push    rbx
    push    rcx

    lea     rdi, [rsi + 2]         ; skip "--"

    ; --help
    push    rdi
    lea     rax, [opt_help]
    mov     rsi, rdi
    call    streq
    pop     rdi
    test    eax, eax
    jnz     .lo_help

    ; --version
    push    rdi
    lea     rax, [opt_version]
    mov     rsi, rdi
    call    streq
    pop     rdi
    test    eax, eax
    jnz     .lo_version

    ; --complement
    push    rdi
    lea     rax, [opt_complement]
    mov     rsi, rdi
    call    streq
    pop     rdi
    test    eax, eax
    jnz     .lo_complement

    ; --only-delimited
    push    rdi
    lea     rax, [opt_only_delimited]
    mov     rsi, rdi
    call    streq
    pop     rdi
    test    eax, eax
    jnz     .lo_only_delimited

    ; --zero-terminated
    push    rdi
    lea     rax, [opt_zero_terminated]
    mov     rsi, rdi
    call    streq
    pop     rdi
    test    eax, eax
    jnz     .lo_zero_terminated

    ; --bytes, --bytes=VALUE
    push    rdi
    lea     rax, [opt_bytes]
    mov     rsi, rdi
    call    str_match_eq
    pop     rdi
    test    eax, eax
    jnz     .lo_bytes

    ; --characters, --characters=VALUE
    push    rdi
    lea     rax, [opt_characters]
    mov     rsi, rdi
    call    str_match_eq
    pop     rdi
    test    eax, eax
    jnz     .lo_characters

    ; --fields, --fields=VALUE
    push    rdi
    lea     rax, [opt_fields]
    mov     rsi, rdi
    call    str_match_eq
    pop     rdi
    test    eax, eax
    jnz     .lo_fields

    ; --delimiter, --delimiter=VALUE
    push    rdi
    lea     rax, [opt_delimiter]
    mov     rsi, rdi
    call    str_match_eq
    pop     rdi
    test    eax, eax
    jnz     .lo_delimiter

    ; --output-delimiter, --output-delimiter=VALUE
    push    rdi
    lea     rax, [opt_output_delim]
    mov     rsi, rdi
    call    str_match_eq
    pop     rdi
    test    eax, eax
    jnz     .lo_output_delim

    ; Unrecognized
    sub     rdi, 2                 ; back to include --
    jmp     .lo_unrec

.lo_help:
    lea     rsi, [help_text]
    mov     edx, help_text_len
    WRITE   STDOUT, rsi, rdx
    EXIT    0

.lo_version:
    lea     rsi, [version_text]
    mov     edx, version_text_len
    WRITE   STDOUT, rsi, rdx
    EXIT    0

.lo_complement:
    mov     byte [complement], 1
    pop     rcx
    pop     rbx
    ret

.lo_only_delimited:
    mov     byte [only_delimited], 1
    pop     rcx
    pop     rbx
    ret

.lo_zero_terminated:
    mov     byte [zero_terminated], 1
    mov     byte [line_delim], 0
    pop     rcx
    pop     rbx
    ret

.lo_bytes:
    ; rdx = value pointer from str_match_eq
    cmp     byte [mode], MODE_NONE
    je      .lo_bytes_set
    cmp     byte [mode], MODE_BYTES
    jne     .lo_multi_mode
.lo_bytes_set:
    mov     byte [mode], MODE_BYTES
    mov     [range_spec], rdx
    pop     rcx
    pop     rbx
    ret

.lo_characters:
    cmp     byte [mode], MODE_NONE
    je      .lo_chars_set
    cmp     byte [mode], MODE_CHARS
    jne     .lo_multi_mode
.lo_chars_set:
    mov     byte [mode], MODE_CHARS
    mov     [range_spec], rdx
    pop     rcx
    pop     rbx
    ret

.lo_fields:
    cmp     byte [mode], MODE_NONE
    je      .lo_fields_set
    cmp     byte [mode], MODE_FIELDS
    jne     .lo_multi_mode
.lo_fields_set:
    mov     byte [mode], MODE_FIELDS
    mov     [range_spec], rdx
    pop     rcx
    pop     rbx
    ret

.lo_delimiter:
    ; rdx = value, check length == 1
    mov     rdi, rdx
    call    my_strlen
    cmp     rax, 1
    jne     .lo_err_delim
    mov     al, [rdx]
    mov     [delim], al
    pop     rcx
    pop     rbx
    ret

.lo_output_delim:
    mov     rdi, rdx
    call    my_strlen
    cmp     rax, MAX_OUTDELIM
    jl      .lo_od_ok
    mov     rax, MAX_OUTDELIM - 1
.lo_od_ok:
    mov     [out_delim_len], eax
    lea     rdi, [out_delim_buf]
    mov     rsi, rdx
    mov     ecx, eax
    rep     movsb
    mov     byte [out_delim_set], 1
    pop     rcx
    pop     rbx
    ret

.lo_multi_mode:
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_multi_list]
    mov     edx, err_multi_list_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_try_help]
    mov     edx, err_try_help_len
    WRITE   STDERR, rsi, rdx
    EXIT    1

.lo_err_delim:
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_delim_single]
    mov     edx, err_delim_single_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_try_help]
    mov     edx, err_try_help_len
    WRITE   STDERR, rsi, rdx
    EXIT    1

.lo_unrec:
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_unrec1]
    mov     edx, err_unrec1_len
    WRITE   STDERR, rsi, rdx
    ; Print option name (rdi)
    push    rdi
    mov     rdi, rdi
    call    my_strlen
    mov     rdx, rax
    pop     rsi
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_unrec2]
    mov     edx, err_unrec2_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_try_help]
    mov     edx, err_try_help_len
    WRITE   STDERR, rsi, rdx
    EXIT    1

; streq: Compare rsi and rax as null-terminated strings
;   Returns eax=1 if equal, 0 otherwise
streq:
    push    rcx
    push    rdx
    mov     rcx, rsi
    mov     rdx, rax
.seq_loop:
    mov     al, [rcx]
    cmp     al, [rdx]
    jne     .seq_no
    test    al, al
    jz      .seq_yes
    inc     rcx
    inc     rdx
    jmp     .seq_loop
.seq_yes:
    mov     eax, 1
    pop     rdx
    pop     rcx
    ret
.seq_no:
    xor     eax, eax
    pop     rdx
    pop     rcx
    ret

; str_match_eq: Check if rsi matches rax exactly, or starts with rax followed by '='
;   Returns eax=1 and rdx=value pointer on match (value after = or next argv)
;   Returns eax=0 on no match
;   Uses outer rbx (argv pointer on stack) and rcx (remaining count on stack)
str_match_eq:
    push    r8
    push    r9
    mov     r8, rsi                ; input (past --)
    mov     r9, rax                ; option name
.sme_loop:
    mov     al, [r9]
    test    al, al
    jz      .sme_end_name
    cmp     al, [r8]
    jne     .sme_no
    inc     r8
    inc     r9
    jmp     .sme_loop
.sme_end_name:
    ; Name exhausted. Check next char in input.
    mov     al, [r8]
    cmp     al, '='
    je      .sme_has_eq
    test    al, al
    jz      .sme_need_next
    jmp     .sme_no
.sme_has_eq:
    inc     r8
    mov     rdx, r8
    mov     eax, 1
    pop     r9
    pop     r8
    ret
.sme_need_next:
    ; Exact match, need next arg as value
    ; outer rbx and ecx are on the stack from parse_long_option
    ; stack: [r8, r9, rbx_saved, rcx_saved, return_addr, ...]
    mov     rax, [rsp + 24]        ; outer rbx
    mov     r8d, [rsp + 16]        ; outer ecx
    cmp     r8d, 1
    jle     .sme_missing
    mov     rdx, [rax + 8]         ; next argv
    add     qword [rsp + 24], 8    ; advance outer rbx
    dec     dword [rsp + 16]       ; dec outer ecx
    mov     eax, 1
    pop     r9
    pop     r8
    ret
.sme_missing:
    ; Missing argument for option
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_opt_req1]
    mov     edx, err_opt_req1_len
    WRITE   STDERR, rsi, rdx
    ; Reconstruct option name with --
    ; Just print a generic message
    lea     rsi, [err_opt_req2]
    mov     edx, err_opt_req2_len
    WRITE   STDERR, rsi, rdx
    EXIT    1
.sme_no:
    xor     eax, eax
    pop     r9
    pop     r8
    ret

; ============================================================================
;                    ARGUMENT PARSING - SHORT OPTIONS
; ============================================================================

; parse_short_options: rsi = arg past initial '-'
;   rbx = current argv pointer, ecx = remaining count
parse_short_options:
    push    r12
    push    r13
    mov     r12, rsi

.pso_loop:
    movzx   eax, byte [r12]
    test    al, al
    jz      .pso_done

    cmp     al, 'n'
    je      .pso_next
    cmp     al, 's'
    je      .pso_s
    cmp     al, 'z'
    je      .pso_z
    cmp     al, 'b'
    je      .pso_b
    cmp     al, 'c'
    je      .pso_c
    cmp     al, 'f'
    je      .pso_f
    cmp     al, 'd'
    je      .pso_d

    ; Invalid option
    push    rax
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_inval1]
    mov     edx, err_inval1_len
    WRITE   STDERR, rsi, rdx
    pop     rax
    mov     [tmp_char], al
    lea     rsi, [tmp_char]
    WRITE   STDERR, rsi, 1
    lea     rsi, [err_inval2]
    mov     edx, err_inval2_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_try_help]
    mov     edx, err_try_help_len
    WRITE   STDERR, rsi, rdx
    EXIT    1

.pso_s:
    mov     byte [only_delimited], 1
    jmp     .pso_next

.pso_z:
    mov     byte [zero_terminated], 1
    mov     byte [line_delim], 0
    jmp     .pso_next

.pso_b:
    cmp     byte [mode], MODE_NONE
    je      .pso_b_ok
    cmp     byte [mode], MODE_BYTES
    jne     .pso_multi_mode
.pso_b_ok:
    mov     byte [mode], MODE_BYTES
    inc     r12
    jmp     .pso_get_value

.pso_c:
    cmp     byte [mode], MODE_NONE
    je      .pso_c_ok
    cmp     byte [mode], MODE_CHARS
    jne     .pso_multi_mode
.pso_c_ok:
    mov     byte [mode], MODE_CHARS
    inc     r12
    jmp     .pso_get_value

.pso_f:
    cmp     byte [mode], MODE_NONE
    je      .pso_f_ok
    cmp     byte [mode], MODE_FIELDS
    jne     .pso_multi_mode
.pso_f_ok:
    mov     byte [mode], MODE_FIELDS
    inc     r12
    jmp     .pso_get_value

.pso_d:
    inc     r12
    cmp     byte [r12], 0
    jne     .pso_d_val
    ; Need next arg
    add     rbx, 8
    dec     ecx
    test    ecx, ecx
    jle     .pso_missing_d
    mov     r12, [rbx]
.pso_d_val:
    ; Check delimiter length
    cmp     byte [r12], 0
    je      .pso_d_empty
    cmp     byte [r12 + 1], 0
    jne     .pso_err_delim
    mov     al, [r12]
    mov     [delim], al
    jmp     .pso_done
.pso_d_empty:
    mov     byte [delim], 0
    jmp     .pso_done

.pso_get_value:
    cmp     byte [r12], 0
    jne     .pso_have_val
    add     rbx, 8
    dec     ecx
    test    ecx, ecx
    jle     .pso_missing_arg
    mov     r12, [rbx]
.pso_have_val:
    mov     [range_spec], r12
    jmp     .pso_done

.pso_next:
    inc     r12
    jmp     .pso_loop

.pso_done:
    pop     r13
    pop     r12
    ret

.pso_multi_mode:
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_multi_list]
    mov     edx, err_multi_list_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_try_help]
    mov     edx, err_try_help_len
    WRITE   STDERR, rsi, rdx
    EXIT    1

.pso_missing_arg:
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_opt_req_short1]
    mov     edx, err_opt_req_short1_len
    WRITE   STDERR, rsi, rdx
    dec     r12
    WRITE   STDERR, r12, 1
    lea     rsi, [err_opt_req_short2]
    mov     edx, err_opt_req_short2_len
    WRITE   STDERR, rsi, rdx
    EXIT    1

.pso_missing_d:
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_opt_req_short1]
    mov     edx, err_opt_req_short1_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [char_d]
    WRITE   STDERR, rsi, 1
    lea     rsi, [err_opt_req_short2]
    mov     edx, err_opt_req_short2_len
    WRITE   STDERR, rsi, rdx
    EXIT    1

.pso_err_delim:
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_delim_single]
    mov     edx, err_delim_single_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_try_help]
    mov     edx, err_try_help_len
    WRITE   STDERR, rsi, rdx
    EXIT    1

; ============================================================================
;                    RANGE PARSING
; ============================================================================

; parse_ranges: Parse LIST string into sorted, merged ranges
;   rsi = LIST string
;   Returns eax=0 on success, 1 on error
parse_ranges:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rsi
    xor     r13d, r13d             ; range count

.pr_next:
    movzx   eax, byte [r12]
    test    al, al
    jz      .pr_done

    xor     r14d, r14d             ; start
    xor     r15d, r15d             ; end

    ; Parse start
    movzx   eax, byte [r12]
    cmp     al, '-'
    je      .pr_dash_first
    cmp     al, ','
    je      .pr_err_bad
    ; Must be a digit
    cmp     al, '0'
    jb      .pr_err_bad
    cmp     al, '9'
    ja      .pr_err_bad
    call    parse_number
    mov     r14, rax

    movzx   eax, byte [r12]
    cmp     al, '-'
    je      .pr_has_dash
    cmp     al, ','
    je      .pr_single
    test    al, al
    jz      .pr_single
    jmp     .pr_err_bad

.pr_single:
    mov     r15, r14
    jmp     .pr_store

.pr_dash_first:
    inc     r12
    mov     r14, 1
    movzx   eax, byte [r12]
    cmp     al, ','
    je      .pr_err_bad
    test    al, al
    jz      .pr_err_bad
    cmp     al, '0'
    jb      .pr_err_bad
    cmp     al, '9'
    ja      .pr_err_bad
    call    parse_number
    mov     r15, rax
    jmp     .pr_store

.pr_has_dash:
    inc     r12
    movzx   eax, byte [r12]
    cmp     al, ','
    je      .pr_open_end
    test    al, al
    jz      .pr_open_end
    cmp     al, '0'
    jb      .pr_err_bad
    cmp     al, '9'
    ja      .pr_err_bad
    call    parse_number
    mov     r15, rax
    cmp     r14, r15
    ja      .pr_err_dec
    jmp     .pr_store

.pr_open_end:
    mov     r15, 0xFFFFFFFF
    jmp     .pr_store

.pr_store:
    test    r14, r14
    jz      .pr_err_zero
    cmp     r13d, MAX_RANGES
    jge     .pr_done

    ; Store: ranges[r13].start = r14, ranges[r13].end = r15
    lea     rdi, [ranges]
    mov     rax, r13
    shl     rax, RANGE_SHIFT       ; rax = r13 * 16
    mov     [rdi + rax], r14
    mov     [rdi + rax + 8], r15
    inc     r13d

    cmp     byte [r12], ','
    jne     .pr_end_check
    inc     r12
    jmp     .pr_next

.pr_end_check:
    cmp     byte [r12], 0
    jne     .pr_err_bad

.pr_done:
    test    r13d, r13d
    jz      .pr_err_bad
    mov     [num_ranges], r13d

    call    sort_ranges
    call    merge_ranges

    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.pr_err_zero:
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx
    cmp     byte [mode], MODE_FIELDS
    je      .pr_err_fields_1
    lea     rsi, [err_pos_from_1]
    mov     edx, err_pos_from_1_len
    jmp     .pr_err_show
.pr_err_fields_1:
    lea     rsi, [err_fields_from_1]
    mov     edx, err_fields_from_1_len
.pr_err_show:
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_try_help]
    mov     edx, err_try_help_len
    WRITE   STDERR, rsi, rdx
    jmp     .pr_err_ret

.pr_err_dec:
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_decreasing]
    mov     edx, err_decreasing_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_try_help]
    mov     edx, err_try_help_len
    WRITE   STDERR, rsi, rdx
    jmp     .pr_err_ret

.pr_err_bad:
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_invalid_range]
    mov     edx, err_invalid_range_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_try_help]
    mov     edx, err_try_help_len
    WRITE   STDERR, rsi, rdx

.pr_err_ret:
    mov     eax, 1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; parse_number: Parse decimal from r12. Returns rax=number, r12 advanced.
parse_number:
    xor     eax, eax
.pn_loop:
    movzx   edx, byte [r12]
    sub     edx, '0'
    cmp     edx, 9
    ja      .pn_done
    imul    rax, 10
    add     rax, rdx
    inc     r12
    jmp     .pn_loop
.pn_done:
    ret

; sort_ranges: Insertion sort by (start, end)
sort_ranges:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     ecx, [num_ranges]
    cmp     ecx, 2
    jl      .sr_done

    lea     rbp, [ranges]          ; base pointer
    mov     r12d, 1                ; i = 1
.sr_outer:
    cmp     r12d, ecx
    jge     .sr_done

    ; Load key
    mov     rax, r12
    shl     rax, RANGE_SHIFT
    mov     r14, [rbp + rax]       ; key.start
    mov     r15, [rbp + rax + 8]   ; key.end

    mov     r13d, r12d
    dec     r13d                   ; j = i-1
.sr_inner:
    cmp     r13d, 0
    jl      .sr_insert
    mov     rax, r13
    shl     rax, RANGE_SHIFT
    mov     rbx, [rbp + rax]       ; ranges[j].start
    mov     rdx, [rbp + rax + 8]   ; ranges[j].end
    cmp     rbx, r14
    ja      .sr_shift
    jb      .sr_insert
    cmp     rdx, r15
    jbe     .sr_insert
.sr_shift:
    ; ranges[j+1] = ranges[j]
    mov     rax, r13
    shl     rax, RANGE_SHIFT
    lea     rdi, [rbp + rax + 16]  ; j+1 offset
    mov     [rdi], rbx
    mov     [rdi + 8], rdx
    dec     r13d
    jmp     .sr_inner
.sr_insert:
    lea     eax, [r13d + 1]
    shl     rax, RANGE_SHIFT
    mov     [rbp + rax], r14
    mov     [rbp + rax + 8], r15
    inc     r12d
    jmp     .sr_outer

.sr_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; merge_ranges: Merge overlapping/adjacent ranges in-place
merge_ranges:
    push    rbx
    push    r12
    push    r13
    push    rbp

    mov     ecx, [num_ranges]
    test    ecx, ecx
    jz      .mr_done

    lea     rbp, [ranges]
    xor     r12d, r12d             ; write index
    mov     r13d, 1                ; read index

.mr_loop:
    cmp     r13d, ecx
    jge     .mr_finish

    ; Current: ranges[r12]
    mov     rax, r12
    shl     rax, RANGE_SHIFT
    mov     rbx, [rbp + rax + 8]   ; current.end

    ; Next: ranges[r13]
    mov     rax, r13
    shl     rax, RANGE_SHIFT
    mov     rdx, [rbp + rax]       ; next.start

    ; Overlap? next.start <= current.end + 1
    lea     rdi, [rbx + 1]
    cmp     rdx, rdi
    ja      .mr_new

    ; Merge
    mov     rdx, [rbp + rax + 8]   ; next.end
    cmp     rdx, rbx
    jbe     .mr_skip
    mov     rax, r12
    shl     rax, RANGE_SHIFT
    mov     [rbp + rax + 8], rdx   ; update end
.mr_skip:
    inc     r13d
    jmp     .mr_loop

.mr_new:
    inc     r12d
    ; Copy next to r12
    mov     rax, r13
    shl     rax, RANGE_SHIFT
    mov     rdx, [rbp + rax]
    mov     rbx, [rbp + rax + 8]
    mov     rax, r12
    shl     rax, RANGE_SHIFT
    mov     [rbp + rax], rdx
    mov     [rbp + rax + 8], rbx
    inc     r13d
    jmp     .mr_loop

.mr_finish:
    inc     r12d
    mov     [num_ranges], r12d

.mr_done:
    pop     rbp
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;                    BITSET OPERATIONS
; ============================================================================

build_bitset:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; Clear bitset
    lea     rdi, [bitset]
    mov     ecx, BITSET_SIZE / 8
    xor     eax, eax
    rep     stosq

    lea     r14, [ranges]
    mov     r15d, [num_ranges]     ; use r15 for count (cl-safe)
    xor     r12d, r12d

.bb_range:
    cmp     r12d, r15d
    jge     .bb_done
    mov     rax, r12
    shl     rax, RANGE_SHIFT
    mov     rbx, [r14 + rax]       ; start (1-based)
    mov     r13, [r14 + rax + 8]   ; end (1-based)
    cmp     r13, BITSET_MAXBIT
    jbe     .bb_clamp_ok
    mov     r13, BITSET_MAXBIT
.bb_clamp_ok:
    dec     rbx                     ; 0-based
.bb_set:
    cmp     rbx, r13
    jge     .bb_next
    ; Set bit rbx in bitset
    mov     rax, rbx
    shr     rax, 3
    lea     rdi, [bitset]
    mov     cl, bl
    and     cl, 7
    mov     dl, 1
    shl     dl, cl
    or      [rdi + rax], dl
    inc     rbx
    jmp     .bb_set

.bb_next:
    inc     r12d
    jmp     .bb_range

.bb_done:
    ; Check for open-ended range
    mov     byte [has_open_end], 0
    mov     ecx, [num_ranges]
    test    ecx, ecx
    jz      .bb_ret
    dec     ecx
    mov     rax, rcx
    shl     rax, RANGE_SHIFT
    lea     rdi, [ranges]
    mov     rbx, [rdi + rax + 8]
    cmp     rbx, BITSET_MAXBIT
    jbe     .bb_ret
    mov     byte [has_open_end], 1
.bb_ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

invert_bitset:
    lea     rdi, [bitset]
    mov     ecx, BITSET_SIZE / 8
.ib_loop:
    not     qword [rdi]
    add     rdi, 8
    dec     ecx
    jnz     .ib_loop
    xor     byte [has_open_end], 1
    ret

; check_pos: Check if 1-based position rdi is selected
;   Returns al=1 if selected, 0 if not
check_pos:
    lea     rsi, [bitset]
    dec     rdi                     ; 0-based
    cmp     rdi, BITSET_MAXBIT
    jge     .cp_open
    mov     rcx, rdi
    shr     rcx, 3
    mov     al, [rsi + rcx]
    mov     cl, dil
    and     cl, 7
    shr     al, cl
    and     al, 1
    ret
.cp_open:
    mov     al, [has_open_end]
    ret

; ============================================================================
;                    BUFFERED I/O
; ============================================================================

; buf_write: Append data to output buffer, flushing as needed
;   rsi = data, edx = length
;   Returns eax=0 on success, -1 on EPIPE
buf_write:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    mov     r13d, edx

.bw_loop:
    test    r13d, r13d
    jle     .bw_ok

    mov     eax, [out_buf_pos]
    mov     ecx, BUF_SIZE
    sub     ecx, eax

    cmp     r13d, ecx
    jle     .bw_fits

    ; Copy ecx bytes, flush, continue
    lea     rdi, [out_buf]
    add     rdi, rax
    mov     rsi, r12
    push    rcx
    rep     movsb
    pop     rcx
    mov     dword [out_buf_pos], BUF_SIZE
    add     r12, rcx
    sub     r13d, ecx
    call    flush_output
    test    eax, eax
    jnz     .bw_pipe
    jmp     .bw_loop

.bw_fits:
    lea     rdi, [out_buf]
    add     rdi, rax
    mov     rsi, r12
    mov     ecx, r13d
    rep     movsb
    add     eax, r13d
    mov     [out_buf_pos], eax

.bw_ok:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret

.bw_pipe:
    mov     eax, -1
    pop     r13
    pop     r12
    pop     rbx
    ret

; buf_write_byte: Write single byte al to output buffer
;   Returns eax=0 on success, -1 on EPIPE
buf_write_byte:
    push    rbx
    mov     ebx, [out_buf_pos]
    cmp     ebx, BUF_SIZE
    jl      .bwb_ok
    push    rax
    call    flush_output
    test    eax, eax
    jnz     .bwb_pipe
    pop     rax
    xor     ebx, ebx
.bwb_ok:
    lea     rdi, [out_buf]
    mov     [rdi + rbx], al
    inc     ebx
    mov     [out_buf_pos], ebx
    xor     eax, eax
    pop     rbx
    ret
.bwb_pipe:
    pop     rax
    mov     eax, -1
    pop     rbx
    ret

; flush_output: Flush output buffer to stdout
;   Returns eax=0 on success, -1 on EPIPE
flush_output:
    push    rbx
    push    r12

    mov     r12d, [out_buf_pos]
    test    r12d, r12d
    jz      .fo_ok

    lea     rbx, [out_buf]
.fo_write:
    test    r12d, r12d
    jle     .fo_ok
    mov     rax, SYS_WRITE
    mov     edi, STDOUT
    mov     rsi, rbx
    mov     edx, r12d
    syscall
    cmp     rax, EINTR
    je      .fo_write
    cmp     rax, EPIPE
    je      .fo_pipe
    test    rax, rax
    js      .fo_err
    add     rbx, rax
    sub     r12d, eax
    jmp     .fo_write

.fo_ok:
    mov     dword [out_buf_pos], 0
    xor     eax, eax
    pop     r12
    pop     rbx
    ret

.fo_pipe:
    mov     dword [out_buf_pos], 0
    mov     eax, -1
    pop     r12
    pop     rbx
    ret

.fo_err:
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx
    lea     rsi, [err_write]
    mov     edx, err_write_len
    WRITE   STDERR, rsi, rdx
    mov     dword [out_buf_pos], 0
    mov     eax, -1
    pop     r12
    pop     rbx
    ret

; ============================================================================
;                    MAIN PROCESSING LOOP
; ============================================================================

; process_input: Read and process input from current_fd
process_input:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     dword [line_buf_pos], 0

.pi_read:
    mov     rax, SYS_READ
    mov     edi, [current_fd]
    lea     rsi, [in_buf]
    mov     edx, BUF_SIZE
    syscall
    cmp     rax, EINTR
    je      .pi_read
    test    rax, rax
    js      .pi_read_err
    jz      .pi_eof

    mov     r12, rax               ; bytes read
    lea     r13, [in_buf]          ; data pointer
    movzx   ebp, byte [line_delim] ; cache line delimiter

.pi_scan:
    test    r12, r12
    jle     .pi_read

    ; Find line delimiter using SSE2
    mov     rdi, r13
    mov     rcx, r12
    mov     eax, ebp

    cmp     rcx, 16
    jl      .pi_scan_byte

    movd    xmm1, eax
    punpcklbw xmm1, xmm1
    punpcklwd xmm1, xmm1
    pshufd  xmm1, xmm1, 0

.pi_scan_sse:
    cmp     rcx, 16
    jl      .pi_scan_byte
    movdqu  xmm0, [rdi]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0
    test    eax, eax
    jnz     .pi_found_sse
    add     rdi, 16
    sub     rcx, 16
    jmp     .pi_scan_sse

.pi_found_sse:
    bsf     eax, eax
    add     rdi, rax
    jmp     .pi_found

.pi_scan_byte:
    test    rcx, rcx
    jle     .pi_no_delim
    cmp     byte [rdi], bpl
    je      .pi_found
    inc     rdi
    dec     rcx
    jmp     .pi_scan_byte

.pi_found:
    ; rdi = pointer to line delimiter
    ; Save rdi before it might get clobbered
    mov     r14, rdi               ; save delimiter position
    mov     rax, rdi
    sub     rax, r13               ; line length (without delimiter)

    ; Check if we have accumulated data in line_buf
    mov     ebx, [line_buf_pos]
    test    ebx, ebx
    jnz     .pi_append

    ; Process line directly from input buffer
    mov     rsi, r13
    mov     edx, eax
    call    process_line
    test    eax, eax
    jnz     .pi_pipe
    jmp     .pi_advance

.pi_append:
    ; Append to line_buf and process
    mov     rcx, r14
    sub     rcx, r13               ; bytes to append
    lea     rdx, [rbx + rcx]
    cmp     rdx, MAX_LINE
    jge     .pi_trunc
    lea     rdi, [line_buf]
    add     rdi, rbx
    mov     rsi, r13
    push    rcx
    rep     movsb
    pop     rcx
    add     ebx, ecx
    lea     rsi, [line_buf]
    mov     edx, ebx
    call    process_line
    mov     dword [line_buf_pos], 0
    test    eax, eax
    jnz     .pi_pipe
    jmp     .pi_advance

.pi_trunc:
    mov     ecx, MAX_LINE
    sub     ecx, ebx
    jle     .pi_trunc_process
    lea     rdi, [line_buf]
    add     rdi, rbx
    mov     rsi, r13
    rep     movsb
.pi_trunc_process:
    lea     rsi, [line_buf]
    mov     edx, MAX_LINE
    call    process_line
    mov     dword [line_buf_pos], 0
    test    eax, eax
    jnz     .pi_pipe

.pi_advance:
    ; Advance past line + delimiter
    mov     rax, r14               ; saved delimiter position
    inc     rax                    ; past delimiter
    mov     rcx, rax
    sub     rcx, r13               ; bytes consumed
    add     r13, rcx
    sub     r12, rcx
    jmp     .pi_scan

.pi_no_delim:
    ; Accumulate remaining data in line_buf
    mov     ebx, [line_buf_pos]
    lea     edx, [ebx + r12d]
    cmp     edx, MAX_LINE
    jge     .pi_accum_trunc
    lea     rdi, [line_buf]
    add     rdi, rbx
    mov     rsi, r13
    mov     ecx, r12d
    rep     movsb
    mov     [line_buf_pos], edx
    jmp     .pi_read

.pi_accum_trunc:
    mov     ecx, MAX_LINE
    sub     ecx, ebx
    jle     .pi_read
    lea     rdi, [line_buf]
    add     rdi, rbx
    mov     rsi, r13
    rep     movsb
    mov     dword [line_buf_pos], MAX_LINE
    jmp     .pi_read

.pi_eof:
    mov     edx, [line_buf_pos]
    test    edx, edx
    jz      .pi_done
    lea     rsi, [line_buf]
    call    process_line
    mov     dword [line_buf_pos], 0

.pi_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.pi_read_err:
    mov     byte [had_error], 1
    jmp     .pi_done

.pi_pipe:
    ; EPIPE — stop processing
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;                    LINE PROCESSING
; ============================================================================

; process_line: Process one line (without line delimiter)
;   rsi = line data, edx = line length
;   Returns eax=0 on success, -1 on EPIPE
process_line:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, rsi               ; line start
    mov     r13d, edx              ; line length

    cmp     byte [mode], MODE_FIELDS
    je      .pl_fields

; ── Bytes/Characters mode ──
.pl_bytes:
    ; Check if complement mode — need to compute gap ranges
    cmp     byte [complement], 1
    je      .pl_bytes_complement

    ; Normal bytes mode: output ranges directly
    mov     ecx, [num_ranges]
    lea     rbp, [ranges]
    xor     r14d, r14d             ; range index
    xor     r15d, r15d             ; first_output flag

.pl_br_loop:
    cmp     r14d, ecx
    jge     .pl_br_done

    mov     rax, r14
    shl     rax, RANGE_SHIFT
    mov     rbx, [rbp + rax]       ; start (1-based)
    mov     rdx, [rbp + rax + 8]   ; end (1-based)

    ; Check if start > line_length
    cmp     ebx, r13d
    ja      .pl_br_next

    ; Clamp end to line length
    cmp     edx, r13d
    jbe     .pl_br_end_ok
    mov     edx, r13d
.pl_br_end_ok:
    ; Convert to 0-based start
    dec     ebx
    sub     edx, ebx              ; length = end - start_0based

    ; Output delimiter between ranges
    test    r15d, r15d
    jz      .pl_br_no_sep
    push    rbx
    push    rdx
    push    rcx
    mov     edx, [out_delim_len]
    test    edx, edx
    jz      .pl_br_sep_done
    lea     rsi, [out_delim_buf]
    call    buf_write
    test    eax, eax
    jnz     .pl_br_pipe3
.pl_br_sep_done:
    pop     rcx
    pop     rdx
    pop     rbx
.pl_br_no_sep:
    ; Output bytes
    push    rcx
    lea     rsi, [r12 + rbx]
    call    buf_write
    test    eax, eax
    jnz     .pl_br_pipe1
    pop     rcx
    mov     r15d, 1

.pl_br_next:
    inc     r14d
    jmp     .pl_br_loop

.pl_br_done:
    ; Write line delimiter
    movzx   eax, byte [line_delim]
    call    buf_write_byte
    test    eax, eax
    jnz     .pl_pipe

    xor     eax, eax
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.pl_br_pipe3:
    pop     rcx
    pop     rdx
    pop     rbx
    jmp     .pl_pipe
.pl_br_pipe1:
    pop     rcx
    jmp     .pl_pipe

; ── Bytes complement: output gaps between the original ranges ──
; For sorted ranges, the gaps are the complement.
; pos starts at 1. For each range [s,e]: output [pos, s-1], set pos=e+1.
; After all ranges: output [pos, line_len].
.pl_bytes_complement:
    mov     ecx, [num_ranges]
    lea     rbp, [ranges]
    xor     r14d, r14d             ; range index
    xor     r15d, r15d             ; first_output flag
    mov     ebx, 1                 ; pos = 1 (1-based current position)

.pl_bc_loop:
    cmp     r14d, ecx
    jge     .pl_bc_after

    mov     rax, r14
    shl     rax, RANGE_SHIFT
    mov     edi, [rbp + rax]       ; range start (1-based)
    mov     edx, [rbp + rax + 8]   ; range end (1-based)

    ; Gap before this range: [pos, start-1]
    cmp     ebx, edi
    jge     .pl_bc_skip_gap
    ; There's a gap: output bytes from pos to start-1
    ; Output delimiter between gaps
    test    r15d, r15d
    jz      .pl_bc_gap_no_sep
    push    rcx
    push    rdi
    push    rdx
    mov     edx, [out_delim_len]
    test    edx, edx
    jz      .pl_bc_gap_sep_done
    lea     rsi, [out_delim_buf]
    call    buf_write
    test    eax, eax
    jnz     .pl_bc_pipe3
.pl_bc_gap_sep_done:
    pop     rdx
    pop     rdi
    pop     rcx
.pl_bc_gap_no_sep:
    ; Output gap: r12 + (pos-1), length = start - pos
    push    rcx
    push    rdi
    push    rdx
    mov     eax, ebx
    dec     eax                    ; 0-based
    lea     rsi, [r12 + rax]
    mov     edx, edi
    sub     edx, ebx              ; length = start - pos
    ; Clamp to line length
    mov     ecx, r13d
    sub     ecx, eax              ; max bytes from this pos
    cmp     edx, ecx
    jle     .pl_bc_gap_len_ok
    mov     edx, ecx
.pl_bc_gap_len_ok:
    test    edx, edx
    jle     .pl_bc_gap_skip
    call    buf_write
    test    eax, eax
    jnz     .pl_bc_pipe3
    mov     r15d, 1
.pl_bc_gap_skip:
    pop     rdx
    pop     rdi
    pop     rcx

.pl_bc_skip_gap:
    ; Advance pos past this range
    lea     ebx, [edx + 1]        ; pos = end + 1
    inc     r14d
    jmp     .pl_bc_loop

.pl_bc_after:
    ; After all ranges: output [pos, line_len]
    cmp     ebx, r13d
    ja      .pl_bc_done
    ; Output delimiter
    test    r15d, r15d
    jz      .pl_bc_after_no_sep
    mov     edx, [out_delim_len]
    test    edx, edx
    jz      .pl_bc_after_no_sep
    lea     rsi, [out_delim_buf]
    call    buf_write
    test    eax, eax
    jnz     .pl_pipe
.pl_bc_after_no_sep:
    mov     eax, ebx
    dec     eax                    ; 0-based
    lea     rsi, [r12 + rax]
    mov     edx, r13d
    sub     edx, eax              ; remaining bytes
    test    edx, edx
    jle     .pl_bc_done
    call    buf_write
    test    eax, eax
    jnz     .pl_pipe

.pl_bc_done:
    movzx   eax, byte [line_delim]
    call    buf_write_byte
    test    eax, eax
    jnz     .pl_pipe

    xor     eax, eax
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.pl_bc_pipe3:
    pop     rdx
    pop     rdi
    pop     rcx
    jmp     .pl_pipe

; ── Fields mode ──
.pl_fields:
    ; Check if line contains the delimiter
    movzx   eax, byte [delim]
    mov     rdi, r12
    mov     ecx, r13d
    mov     r14d, eax              ; save delimiter byte

    ; SSE2 scan for delimiter
    cmp     ecx, 16
    jl      .pl_f_scan_byte

    movd    xmm1, eax
    punpcklbw xmm1, xmm1
    punpcklwd xmm1, xmm1
    pshufd  xmm1, xmm1, 0

.pl_f_scan_sse:
    cmp     ecx, 16
    jl      .pl_f_scan_byte
    movdqu  xmm0, [rdi]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0
    test    eax, eax
    jnz     .pl_f_has_delim
    add     rdi, 16
    sub     ecx, 16
    jmp     .pl_f_scan_sse

.pl_f_scan_byte:
    test    ecx, ecx
    jle     .pl_f_no_delim
    cmp     byte [rdi], r14b
    je      .pl_f_has_delim
    inc     rdi
    dec     ecx
    jmp     .pl_f_scan_byte

.pl_f_no_delim:
    ; No delimiter in line
    cmp     byte [only_delimited], 1
    je      .pl_f_suppress

    ; Output entire line + line delimiter
    mov     rsi, r12
    mov     edx, r13d
    call    buf_write
    test    eax, eax
    jnz     .pl_pipe
    movzx   eax, byte [line_delim]
    call    buf_write_byte
    test    eax, eax
    jnz     .pl_pipe
    xor     eax, eax
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.pl_f_suppress:
    xor     eax, eax
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.pl_f_has_delim:
    ; Line has delimiter. Walk through, extract selected fields.
    mov     rdi, r12               ; current pos
    mov     ecx, r13d              ; remaining length
    xor     r15d, r15d             ; field counter (1-based, incremented when we encounter a field)
    mov     rbp, r12               ; field start
    xor     ebx, ebx               ; first_output flag

.pl_f_field_loop:
    ; Look for next delimiter or end of data
    test    ecx, ecx
    jle     .pl_f_last_field

    cmp     byte [rdi], r14b
    je      .pl_f_got_delim
    inc     rdi
    dec     ecx
    jmp     .pl_f_field_loop

.pl_f_got_delim:
    ; Found delimiter at rdi. Field r15+1 spans rbp..rdi
    inc     r15d                    ; field number (1-based)

    ; Check if field is selected
    push    rdi
    push    rcx
    movzx   edi, r15w
    call    check_pos
    pop     rcx
    pop     rdi
    test    al, al
    jz      .pl_f_skip

    ; Output separator if not first
    test    ebx, ebx
    jz      .pl_f_nosep
    push    rdi
    push    rcx
    mov     edx, [out_delim_len]
    test    edx, edx
    jz      .pl_f_nosep_pop
    lea     rsi, [out_delim_buf]
    call    buf_write
    test    eax, eax
    jnz     .pl_f_pipe2
.pl_f_nosep_pop:
    pop     rcx
    pop     rdi
.pl_f_nosep:
    ; Output field: rbp to rdi
    push    rdi
    push    rcx
    mov     rsi, rbp
    mov     rdx, rdi
    sub     rdx, rbp
    call    buf_write
    test    eax, eax
    jnz     .pl_f_pipe2
    pop     rcx
    pop     rdi
    mov     ebx, 1

.pl_f_skip:
    ; Advance past delimiter
    inc     rdi
    dec     ecx
    mov     rbp, rdi
    jmp     .pl_f_field_loop

.pl_f_last_field:
    ; Last field from rbp to end of line (r12 + r13)
    inc     r15d

    push    rdi
    push    rcx
    movzx   edi, r15w
    call    check_pos
    pop     rcx
    pop     rdi
    test    al, al
    jz      .pl_f_end_line

    ; Separator
    test    ebx, ebx
    jz      .pl_f_last_nosep
    mov     edx, [out_delim_len]
    test    edx, edx
    jz      .pl_f_last_nosep
    push    rbp
    lea     rsi, [out_delim_buf]
    call    buf_write
    test    eax, eax
    jnz     .pl_f_pipe1
    pop     rbp
.pl_f_last_nosep:
    ; Output last field
    mov     rsi, rbp
    lea     rdx, [r12 + r13]
    sub     rdx, rbp
    call    buf_write
    test    eax, eax
    jnz     .pl_pipe

.pl_f_end_line:
    movzx   eax, byte [line_delim]
    call    buf_write_byte
    test    eax, eax
    jnz     .pl_pipe
    xor     eax, eax
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.pl_f_pipe2:
    pop     rcx
    pop     rdi
    jmp     .pl_pipe
.pl_f_pipe1:
    pop     rbp
.pl_pipe:
    mov     eax, -1
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;                    UTILITY FUNCTIONS
; ============================================================================

; my_strlen: rdi = null-terminated string → rax = length
my_strlen:
    push    rcx
    push    rdi
    xor     ecx, ecx
    dec     rcx
    xor     al, al
    repne   scasb
    not     rcx
    dec     rcx
    mov     rax, rcx
    pop     rdi
    pop     rcx
    ret

; print_file_error: Print "fcut: {filename}: {error}\n" to stderr
;   rsi = filename, eax = errno (positive)
print_file_error:
    push    r12
    push    r13
    mov     r12, rsi
    mov     r13d, eax

    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    WRITE   STDERR, rsi, rdx

    mov     rdi, r12
    call    my_strlen
    mov     rdx, rax
    mov     rsi, r12
    WRITE   STDERR, rsi, rdx

    lea     rsi, [err_colon_space]
    mov     edx, 2
    WRITE   STDERR, rsi, rdx

    ; Map errno to message
    cmp     r13d, 2                ; ENOENT
    je      .pfe_noent
    cmp     r13d, 13               ; EACCES
    je      .pfe_acces
    cmp     r13d, 21               ; EISDIR
    je      .pfe_isdir
    ; Generic
    lea     rsi, [err_generic_io]
    mov     edx, err_generic_io_len
    WRITE   STDERR, rsi, rdx
    jmp     .pfe_done

.pfe_noent:
    lea     rsi, [err_noent]
    mov     edx, err_noent_len
    WRITE   STDERR, rsi, rdx
    jmp     .pfe_done

.pfe_acces:
    lea     rsi, [err_acces]
    mov     edx, err_acces_len
    WRITE   STDERR, rsi, rdx
    jmp     .pfe_done

.pfe_isdir:
    lea     rsi, [err_isdir]
    mov     edx, err_isdir_len
    WRITE   STDERR, rsi, rdx

.pfe_done:
    pop     r13
    pop     r12
    ret

; ============================================================================
;                    DATA SECTION
; ============================================================================

; ── Data ──

opt_help:           db "help", 0
opt_version:        db "version", 0
opt_bytes:          db "bytes", 0
opt_characters:     db "characters", 0
opt_fields:         db "fields", 0
opt_delimiter:      db "delimiter", 0
opt_output_delim:   db "output-delimiter", 0
opt_complement:     db "complement", 0
opt_only_delimited: db "only-delimited", 0
opt_zero_terminated: db "zero-terminated", 0

stdin_name:         db "-", 0
char_d:             db "d"

err_prefix:         db "fcut: "
err_prefix_len      equ $ - err_prefix

err_colon_space:    db ": "

err_no_mode:        db "you must specify a list of bytes, characters, or fields", 10
err_no_mode_len     equ $ - err_no_mode

err_multi_list:     db "only one type of list may be specified", 10
err_multi_list_len  equ $ - err_multi_list

err_try_help:       db "Try 'fcut --help' for more information.", 10
err_try_help_len    equ $ - err_try_help

err_delim_single:   db "the delimiter must be a single character", 10
err_delim_single_len equ $ - err_delim_single

err_pos_from_1:     db "byte/character positions are numbered from 1", 10
err_pos_from_1_len  equ $ - err_pos_from_1

err_fields_from_1:  db "fields are numbered from 1", 10
err_fields_from_1_len equ $ - err_fields_from_1

err_decreasing:     db "invalid decreasing range", 10
err_decreasing_len  equ $ - err_decreasing

err_invalid_range:  db "invalid byte, character or field list", 10
err_invalid_range_len equ $ - err_invalid_range

err_write:          db "write error", 10
err_write_len       equ $ - err_write

err_unrec1:         db "unrecognized option '"
err_unrec1_len      equ $ - err_unrec1

err_unrec2:         db "'", 10
err_unrec2_len      equ $ - err_unrec2

err_inval1:         db "invalid option -- '"
err_inval1_len      equ $ - err_inval1

err_inval2:         db "'", 10
err_inval2_len      equ $ - err_inval2

err_opt_req1:       db "option '"
err_opt_req1_len    equ $ - err_opt_req1

err_opt_req2:       db "' requires an argument", 10
err_opt_req2_len    equ $ - err_opt_req2

err_opt_req_short1: db "option requires an argument -- '"
err_opt_req_short1_len equ $ - err_opt_req_short1

err_opt_req_short2: db "'", 10
err_opt_req_short2_len equ $ - err_opt_req_short2

err_noent:          db "No such file or directory", 10
err_noent_len       equ $ - err_noent

err_acces:          db "Permission denied", 10
err_acces_len       equ $ - err_acces

err_isdir:          db "Is a directory", 10
err_isdir_len       equ $ - err_isdir

err_generic_io:     db "Input/output error", 10
err_generic_io_len  equ $ - err_generic_io

help_text:
    db "Usage: fcut OPTION... [FILE]...", 10
    db "Print selected parts of lines from each FILE to standard output.", 10, 10
    db "With no FILE, or when FILE is -, read standard input.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -b, --bytes=LIST        select only these bytes", 10
    db "  -c, --characters=LIST   select only these characters", 10
    db "  -d, --delimiter=DELIM   use DELIM instead of TAB for field delimiter", 10
    db "  -f, --fields=LIST       select only these fields;  also print any line", 10
    db "                            that contains no delimiter character, unless", 10
    db "                            the -s option is specified", 10
    db "  -n                      (ignored)", 10
    db "      --complement        complement the set of selected bytes, characters", 10
    db "                            or fields", 10
    db "  -s, --only-delimited    do not print lines not containing delimiters", 10
    db "      --output-delimiter=STRING  use STRING as the output delimiter", 10
    db "                            the default is to use the input delimiter", 10
    db "  -z, --zero-terminated   line delimiter is NUL, not newline", 10
    db "      --help              display this help and exit", 10
    db "      --version           output version information and exit", 10
help_text_len       equ $ - help_text

version_text:       db "fcut (fcoreutils) 0.1.0", 10
version_text_len    equ $ - version_text

; ── NX stack ──

file_end:
