; ============================================================================
;  fshuf_unified.asm — Unified flat-binary build of fshuf
;  Self-contained: includes ELF headers, all code, and BSS definitions.
;  Build: nasm -f bin unified/fshuf_unified.asm -o fshuf_release && chmod +x fshuf_release
; ============================================================================

BITS 64
org 0x400000

; ── Syscall numbers ──
%define SYS_READ         0
%define SYS_WRITE        1
%define SYS_OPEN         2
%define SYS_CLOSE        3
%define SYS_FSTAT        5
%define SYS_MMAP         9
%define SYS_MUNMAP      11
%define SYS_RT_SIGACTION 13
%define SYS_MREMAP      25
%define SYS_EXIT        60

%define STDIN            0
%define STDOUT           1
%define STDERR           2
%define O_RDONLY         0
%define O_WRONLY         1
%define O_CREAT        0x40
%define O_TRUNC       0x200
%define EINTR            4
%define EPIPE           32
%define SIGPIPE         13
%define SIG_IGN          1

%define PROT_READ        1
%define PROT_WRITE       2
%define MAP_PRIVATE      2
%define MAP_ANONYMOUS   0x20
%define MAP_POPULATE    0x8000
%define MREMAP_MAYMOVE   1

%define STAT_SIZE       48
%define STAT_STRUCT_SIZE 144
%define BUF_SIZE     131072

%define OUTBUF_SIZE     262144
%define INITIAL_BUF     (4*1024*1024)
%define LINE_ENTRY_SIZE 16
%define INITIAL_LINES   (64*1024)
%define ITOA_BUF_SIZE   24

; Option flags
%define FLAG_ECHO       0x01
%define FLAG_REPEAT     0x02
%define FLAG_ZERO_TERM  0x04
%define FLAG_HAS_COUNT  0x08
%define FLAG_HAS_RANGE  0x10
%define FLAG_HAS_OUTPUT 0x20
%define FLAG_HAS_RSRC   0x40

; ── ELF Header ──
ehdr:
    db      0x7f, "ELF"
    db      2, 1, 1, 0         ; 64-bit, little-endian, ELF v1, System V ABI
    dq      0                   ; padding
    dw      2                   ; ET_EXEC
    dw      0x3E                ; x86-64
    dd      1                   ; ELF version
    dq      _start              ; entry point
    dq      phdr - ehdr         ; program header offset
    dq      0                   ; section header offset (none)
    dd      0                   ; flags
    dw      ehdr_end - ehdr     ; ELF header size
    dw      phdr_size           ; program header entry size
    dw      3                   ; number of program headers
    dw      0, 0, 0             ; section header stuff (unused)
ehdr_end:

; ── Program Headers ──
phdr:
    ; LOAD: Code + Data (R+X)
    dd      1                   ; PT_LOAD
    dd      5                   ; PF_R | PF_X
    dq      0                   ; file offset
    dq      0x400000            ; virtual address
    dq      0x400000            ; physical address
    dq      code_end - ehdr     ; file size
    dq      code_end - ehdr     ; memory size
    dq      0x1000              ; alignment
phdr_size equ $ - phdr

    ; LOAD: BSS (R+W)
    dd      1                   ; PT_LOAD
    dd      6                   ; PF_R | PF_W
    dq      bss_file_offset     ; file offset
    dq      bss_start           ; virtual address
    dq      bss_start           ; physical address
    dq      0                   ; file size = 0
    dq      bss_end - bss_start ; memory size
    dq      0x1000              ; alignment

    ; GNU_STACK: NX
    dd      0x6474E551          ; PT_GNU_STACK
    dd      6                   ; PF_R | PF_W (no PF_X = NX stack)
    dq      0, 0, 0, 0, 0
    dq      0x10                ; alignment

; ════════════════════════════════════════════════════════════════
; DATA
; ════════════════════════════════════════════════════════════════

; @@DATA_START@@
str_help:
    db "Usage: shuf [OPTION]... [FILE]", 10
    db "  or:  shuf -e [OPTION]... [ARG]...", 10
    db "  or:  shuf -i LO-HI [OPTION]...", 10
    db "Write a random permutation of the input lines to standard output.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -e, --echo                treat each ARG as an input line", 10
    db "  -i, --input-range=LO-HI   treat each number LO through HI as an input line", 10
    db "  -n, --head-count=COUNT    output at most COUNT lines", 10
    db "  -o, --output=FILE         write result to FILE instead of standard output", 10
    db "      --random-source=FILE  get random bytes from FILE", 10
    db "  -r, --repeat              output lines can be repeated", 10
    db "  -z, --zero-terminated     line delimiter is NUL, not newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/shuf>", 10
    db "or available locally via: info '(coreutils) shuf invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "shuf (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Paul Eggert.", 10
str_version_len equ $ - str_version
; @@DATA_END@@

str_shuf_prefix: db "shuf: ", 0
str_shuf_prefix_len equ 6

str_try_help:
    db "Try 'shuf --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_inv_opt:    db "invalid option -- '", 0
str_inv_opt_len equ $ - str_inv_opt - 1
str_inv_opt2:   db "'", 10, 0

str_opt_req:    db "option requires an argument -- '", 0
str_opt_req_len equ $ - str_opt_req - 1

str_unrecog:    db "unrecognized option '", 0
str_unrecog_len equ $ - str_unrecog - 1
str_unrecog2:   db "'", 10, 0

str_extra_op:   db "extra operand ", 0
str_extra_op_len equ $ - str_extra_op - 1

str_no_lines:   db "no lines to repeat", 10, 0
str_no_lines_len equ $ - str_no_lines - 1

str_inv_range:  db "invalid input range: ", 0
str_inv_range_len equ $ - str_inv_range - 1

str_inv_count:  db "invalid line count: ", 0
str_inv_count_len equ $ - str_inv_count - 1

str_cannot_ei:  db "cannot combine -e and -i options", 10, 0
str_cannot_ei_len equ $ - str_cannot_ei - 1

str_no_such:    db "No such file or directory", 10, 0
str_no_such_len equ $ - str_no_such - 1

str_write_err:  db "write error", 10, 0
str_write_err_len equ $ - str_write_err - 1

str_lquote:     db 0xe2, 0x80, 0x98
str_lquote_len equ 3
str_rquote:     db 0xe2, 0x80, 0x99
str_rquote_len equ 3

str_dash:       db "-", 0
str_devurandom: db "/dev/urandom", 0
str_newline:    db 10
str_colon_space: db ": "

str_opt_echo:           db "--echo", 0
str_opt_repeat:         db "--repeat", 0
str_opt_zero:           db "--zero-terminated", 0
str_opt_input_range:    db "--input-range", 0
str_opt_input_range_eq: db "--input-range=", 0
str_opt_head_count:     db "--head-count", 0
str_opt_head_count_eq:  db "--head-count=", 0
str_opt_output:         db "--output", 0
str_opt_output_eq:      db "--output=", 0
str_opt_random_src:     db "--random-source", 0
str_opt_random_src_eq:  db "--random-source=", 0
str_opt_help:           db "--help", 0
str_opt_version:        db "--version", 0
str_opt_end:            db "--", 0

; Two-digit lookup table
align 16
digit_pairs:
    db "00010203040506070809"
    db "10111213141516171819"
    db "20212223242526272829"
    db "30313233343536373839"
    db "40414243444546474849"
    db "50515253545556575859"
    db "60616263646566676869"
    db "70717273747576777879"
    db "80818283848586878889"
    db "90919293949596979899"

; ════════════════════════════════════════════════════════════════
; CODE
; ════════════════════════════════════════════════════════════════

; ── I/O library (inlined) ──

asm_write:
.retry:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -EINTR
    je      .retry
    ret

asm_write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.loop:
    test    r13, r13
    jle     .success
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -EINTR
    je      .loop
    cmp     rax, -EPIPE
    je      .epipe
    test    rax, rax
    js      .error
    add     r12, rax
    sub     r13, rax
    jmp     .loop
.success:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.epipe:
    mov     rax, -EPIPE
    pop     r13
    pop     r12
    pop     rbx
    ret
.error:
    mov     rax, -1
    pop     r13
    pop     r12
    pop     rbx
    ret

asm_read:
.retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, -EINTR
    je      .retry
    ret

asm_open:
    mov     rax, SYS_OPEN
    syscall
    ret

asm_close:
    mov     rax, SYS_CLOSE
    syscall
    ret

asm_exit:
    mov     rax, SYS_EXIT
    syscall

; ── String library (inlined) ──

asm_strlen:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

asm_memcpy:
    mov     rax, rdi
    mov     rcx, rdx
    rep movsb
    ret

asm_itoa:
    push    rbx
    mov     rax, rdi
    mov     rbx, rsi
    test    rax, rax
    jnz     .convert
    mov     byte [rsi], '0'
    mov     rax, 1
    pop     rbx
    ret
.convert:
    mov     r8, rsi
.digit_loop:
    xor     edx, edx
    mov     rcx, 10
    div     rcx
    add     dl, '0'
    mov     [rsi], dl
    inc     rsi
    test    rax, rax
    jnz     .digit_loop
    mov     rax, rsi
    sub     rax, r8
    dec     rsi
    mov     rdi, r8
.reverse_loop:
    cmp     rdi, rsi
    jge     .reverse_done
    mov     cl, [rdi]
    mov     ch, [rsi]
    mov     [rdi], ch
    mov     [rsi], cl
    inc     rdi
    dec     rsi
    jmp     .reverse_loop
.reverse_done:
    pop     rbx
    ret

; ════════════════════════════════════════════════════════════════
; MAIN CODE — Entry point
; ════════════════════════════════════════════════════════════════

_start:
    ; Block SIGPIPE
    call    block_sigpipe

    ; Initialize defaults
    xor     eax, eax
    mov     [opt_flags], rax
    mov     qword [opt_head_count], -1
    mov     qword [opt_output_fd], STDOUT
    mov     qword [opt_rsrc_fd], -1
    mov     [output_file], rax
    mov     [rsrc_file], rax
    mov     [input_file], rax
    mov     [line_ptrs], rax
    mov     [line_count], rax
    mov     [echo_ptrs], rax
    mov     [echo_count], rax
    mov     [outbuf_pos], rax

    mov     r14, [rsp]
    lea     r15, [rsp + 8]

    ; Allocate output buffer
    mov     rdi, 0
    mov     rsi, OUTBUF_SIZE
    mov     rdx, PROT_READ | PROT_WRITE
    mov     r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .mmap_fail
    mov     [outbuf], rax

    call    parse_args

    ; Validate
    mov     rax, [opt_flags]
    test    rax, FLAG_ECHO
    jz      .no_echo_check
    test    rax, FLAG_HAS_RANGE
    jnz     .err_ei_conflict
.no_echo_check:
    mov     rax, [opt_flags]
    test    rax, FLAG_HAS_RANGE
    jz      .no_range_check
    cmp     qword [input_file], 0
    jne     .err_extra_operand
.no_range_check:

    call    seed_prng

    mov     rax, [opt_flags]
    test    rax, FLAG_ECHO
    jnz     .do_echo
    test    rax, FLAG_HAS_RANGE
    jnz     .do_range
    jmp     .do_file

.do_echo:
    call    run_echo_mode
    jmp     .finish
.do_range:
    call    run_range_mode
    jmp     .finish
.do_file:
    call    run_file_mode
    jmp     .finish

.finish:
    call    flush_outbuf
    cmp     qword [opt_output_fd], STDOUT
    je      .exit_ok
    mov     rdi, [opt_output_fd]
    call    asm_close
.exit_ok:
    xor     edi, edi
    call    asm_exit

.mmap_fail:
    mov     edi, 1
    call    asm_exit

.err_ei_conflict:
    mov     rdi, STDERR
    mov     rsi, str_shuf_prefix
    mov     rdx, str_shuf_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_cannot_ei
    mov     rdx, str_cannot_ei_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_try_help
    mov     rdx, str_try_help_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.err_extra_operand:
    mov     rdi, [input_file]
    call    err_extra_operand

; ── Include all the remaining code from the modular build ──
; (block_sigpipe, parse_args, seed_prng, xoshiro256_next, rand_bounded,
;  outbuf functions, mode runners, error functions, etc.)
; These are identical to tools/fshuf.asm — inlined below.

; ─── block_sigpipe ───
block_sigpipe:
    sub     rsp, 160
    xor     eax, eax
    mov     rcx, 20
    mov     rdi, rsp
    rep     stosq
    mov     qword [rsp], SIG_IGN
    mov     rax, SYS_RT_SIGACTION
    mov     rdi, SIGPIPE
    mov     rsi, rsp
    xor     edx, edx
    mov     r10, 8
    syscall
    add     rsp, 160
    ret

; ─── parse_args ───
parse_args:
    push    rbx
    push    r12
    push    r13
    push    rbp
    mov     rbx, 1
    xor     r12d, r12d
    xor     r13d, r13d

    ; Check for -e/--echo
    mov     rcx, 1
.check_echo_loop:
    cmp     rcx, r14
    jge     .check_echo_done
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .check_echo_next
    cmp     byte [rdi+1], '-'
    je      .check_echo_long
    mov     rsi, rdi
    inc     rsi
.check_echo_short:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .check_echo_next
    cmp     al, 'e'
    je      .found_echo
    cmp     al, 'i'
    je      .check_echo_next
    cmp     al, 'n'
    je      .check_echo_next
    cmp     al, 'o'
    je      .check_echo_next
    inc     rsi
    jmp     .check_echo_short
.check_echo_long:
    mov     rsi, str_opt_echo
    call    str_match_long
    test    eax, eax
    jnz     .found_echo
    jmp     .check_echo_next
.found_echo:
    or      qword [opt_flags], FLAG_ECHO
.check_echo_next:
    inc     rcx
    jmp     .check_echo_loop
.check_echo_done:

.parse_main:
.arg_loop:
    cmp     rbx, r14
    jge     .parse_done
    mov     rdi, [r15 + rbx*8]
    test    r13d, r13d
    jnz     .positional_arg
    cmp     byte [rdi], '-'
    jne     .positional_arg
    cmp     byte [rdi+1], 0
    je      .positional_arg
    cmp     byte [rdi+1], '-'
    jne     .short_opts
    cmp     byte [rdi+2], 0
    je      .end_options

    mov     rsi, str_opt_help
    call    str_match_long
    test    eax, eax
    jnz     .do_help

    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_version
    call    str_match_long
    test    eax, eax
    jnz     .do_version

    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_echo
    call    str_match_long
    test    eax, eax
    jnz     .set_echo

    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_repeat
    call    str_match_long
    test    eax, eax
    jnz     .set_repeat

    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_zero
    call    str_match_long
    test    eax, eax
    jnz     .set_zero

    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_input_range_eq
    call    str_starts_with
    test    eax, eax
    jnz     .input_range_eq

    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_input_range
    call    str_match_long
    test    eax, eax
    jnz     .input_range_next

    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_head_count_eq
    call    str_starts_with
    test    eax, eax
    jnz     .head_count_eq

    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_head_count
    call    str_match_long
    test    eax, eax
    jnz     .head_count_next

    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_output_eq
    call    str_starts_with
    test    eax, eax
    jnz     .output_eq

    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_output
    call    str_match_long
    test    eax, eax
    jnz     .output_next

    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_random_src_eq
    call    str_starts_with
    test    eax, eax
    jnz     .rsrc_eq

    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_random_src
    call    str_match_long
    test    eax, eax
    jnz     .rsrc_next

    mov     rdi, [r15 + rbx*8]
    call    err_unrecog_option

.end_options:
    mov     r13d, 1
    inc     rbx
    jmp     .arg_loop

.set_echo:
    or      qword [opt_flags], FLAG_ECHO
    inc     rbx
    jmp     .arg_loop
.set_repeat:
    or      qword [opt_flags], FLAG_REPEAT
    inc     rbx
    jmp     .arg_loop
.set_zero:
    or      qword [opt_flags], FLAG_ZERO_TERM
    inc     rbx
    jmp     .arg_loop

.input_range_eq:
    mov     rdi, [r15 + rbx*8]
    call    find_eq_value
    mov     rdi, rax
    call    parse_range_str
    or      qword [opt_flags], FLAG_HAS_RANGE
    inc     rbx
    jmp     .arg_loop
.input_range_next:
    inc     rbx
    cmp     rbx, r14
    jge     .err_opt_req_i
    mov     rdi, [r15 + rbx*8]
    call    parse_range_str
    or      qword [opt_flags], FLAG_HAS_RANGE
    inc     rbx
    jmp     .arg_loop

.head_count_eq:
    mov     rdi, [r15 + rbx*8]
    call    find_eq_value
    mov     rdi, rax
    call    parse_count_str
    cmp     rax, [opt_head_count]
    jae     .hc_eq_skip
    mov     [opt_head_count], rax
.hc_eq_skip:
    or      qword [opt_flags], FLAG_HAS_COUNT
    inc     rbx
    jmp     .arg_loop
.head_count_next:
    inc     rbx
    cmp     rbx, r14
    jge     .err_opt_req_n
    mov     rdi, [r15 + rbx*8]
    call    parse_count_str
    cmp     rax, [opt_head_count]
    jae     .hc_next_skip
    mov     [opt_head_count], rax
.hc_next_skip:
    or      qword [opt_flags], FLAG_HAS_COUNT
    inc     rbx
    jmp     .arg_loop

.output_eq:
    mov     rdi, [r15 + rbx*8]
    call    find_eq_value
    mov     [output_file], rax
    or      qword [opt_flags], FLAG_HAS_OUTPUT
    inc     rbx
    jmp     .arg_loop
.output_next:
    inc     rbx
    cmp     rbx, r14
    jge     .err_opt_req_o
    mov     rax, [r15 + rbx*8]
    mov     [output_file], rax
    or      qword [opt_flags], FLAG_HAS_OUTPUT
    inc     rbx
    jmp     .arg_loop

.rsrc_eq:
    mov     rdi, [r15 + rbx*8]
    call    find_eq_value
    mov     [rsrc_file], rax
    or      qword [opt_flags], FLAG_HAS_RSRC
    inc     rbx
    jmp     .arg_loop
.rsrc_next:
    inc     rbx
    cmp     rbx, r14
    jge     .err_opt_req_rs
    mov     rax, [r15 + rbx*8]
    mov     [rsrc_file], rax
    or      qword [opt_flags], FLAG_HAS_RSRC
    inc     rbx
    jmp     .arg_loop

.do_help:
    mov     rdi, STDOUT
    mov     rsi, str_help
    mov     rdx, str_help_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit
.do_version:
    mov     rdi, STDOUT
    mov     rsi, str_version
    mov     rdx, str_version_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit

.short_opts:
    mov     rdi, [r15 + rbx*8]
    inc     rdi
    mov     rbp, rdi
.short_loop:
    movzx   eax, byte [rbp]
    test    al, al
    jz      .short_done
    cmp     al, 'e'
    je      .short_e
    cmp     al, 'r'
    je      .short_r
    cmp     al, 'z'
    je      .short_z
    cmp     al, 'i'
    je      .short_i
    cmp     al, 'n'
    je      .short_n
    cmp     al, 'o'
    je      .short_o
    jmp     .err_invalid_short

.short_e:
    or      qword [opt_flags], FLAG_ECHO
    inc     rbp
    jmp     .short_loop
.short_r:
    or      qword [opt_flags], FLAG_REPEAT
    inc     rbp
    jmp     .short_loop
.short_z:
    or      qword [opt_flags], FLAG_ZERO_TERM
    inc     rbp
    jmp     .short_loop

.short_i:
    inc     rbp
    cmp     byte [rbp], 0
    je      .short_i_next
    mov     rdi, rbp
    call    parse_range_str
    or      qword [opt_flags], FLAG_HAS_RANGE
    jmp     .short_done
.short_i_next:
    inc     rbx
    cmp     rbx, r14
    jge     .err_opt_req_i
    mov     rdi, [r15 + rbx*8]
    call    parse_range_str
    or      qword [opt_flags], FLAG_HAS_RANGE
    jmp     .short_done

.short_n:
    inc     rbp
    cmp     byte [rbp], 0
    je      .short_n_next
    mov     rdi, rbp
    call    parse_count_str
    cmp     rax, [opt_head_count]
    jae     .short_n_skip
    mov     [opt_head_count], rax
.short_n_skip:
    or      qword [opt_flags], FLAG_HAS_COUNT
    jmp     .short_done
.short_n_next:
    inc     rbx
    cmp     rbx, r14
    jge     .err_opt_req_n
    mov     rdi, [r15 + rbx*8]
    call    parse_count_str
    cmp     rax, [opt_head_count]
    jae     .short_n_skip2
    mov     [opt_head_count], rax
.short_n_skip2:
    or      qword [opt_flags], FLAG_HAS_COUNT
    jmp     .short_done

.short_o:
    inc     rbp
    cmp     byte [rbp], 0
    je      .short_o_next
    mov     [output_file], rbp
    or      qword [opt_flags], FLAG_HAS_OUTPUT
    jmp     .short_done
.short_o_next:
    inc     rbx
    cmp     rbx, r14
    jge     .err_opt_req_o
    mov     rax, [r15 + rbx*8]
    mov     [output_file], rax
    or      qword [opt_flags], FLAG_HAS_OUTPUT
    jmp     .short_done

.short_done:
    inc     rbx
    jmp     .arg_loop
.err_invalid_short:
    movzx   edi, byte [rbp]
    call    err_invalid_option

.positional_arg:
    mov     rax, [opt_flags]
    test    rax, FLAG_ECHO
    jnz     .echo_arg
    cmp     qword [input_file], 0
    jne     .err_extra_op_pos
    mov     rax, [r15 + rbx*8]
    mov     [input_file], rax
    inc     rbx
    jmp     .arg_loop
.err_extra_op_pos:
    mov     rdi, [r15 + rbx*8]
    call    err_extra_operand

.echo_arg:
    mov     rax, [echo_count]
    cmp     rax, [echo_cap]
    jb      .echo_has_space
    call    grow_echo_array
.echo_has_space:
    mov     rcx, [echo_ptrs]
    mov     rax, [echo_count]
    mov     rdx, [r15 + rbx*8]
    mov     [rcx + rax*8], rdx
    inc     qword [echo_count]
    inc     rbx
    jmp     .arg_loop

.err_opt_req_i:
    mov     dil, 'i'
    call    err_opt_requires_arg
.err_opt_req_n:
    mov     dil, 'n'
    call    err_opt_requires_arg
.err_opt_req_o:
    mov     dil, 'o'
    call    err_opt_requires_arg
.err_opt_req_rs:
    mov     rdi, [r15 + rbx*8]
    call    err_unrecog_option

.parse_done:
    test    qword [opt_flags], FLAG_HAS_OUTPUT
    jz      .no_output_file
    mov     rdi, [output_file]
    mov     rsi, O_WRONLY | O_CREAT | O_TRUNC
    mov     rdx, 0o666
    call    asm_open
    test    rax, rax
    js      .err_open_output
    mov     [opt_output_fd], rax
.no_output_file:
    pop     rbp
    pop     r13
    pop     r12
    pop     rbx
    ret
.err_open_output:
    mov     rdi, STDERR
    mov     rsi, str_shuf_prefix
    mov     rdx, str_shuf_prefix_len
    call    asm_write_all
    mov     rdi, [output_file]
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, [output_file]
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_colon_space
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_no_such
    mov     rdx, str_no_such_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

; ─── grow_echo_array ───
grow_echo_array:
    push    rbx
    mov     rax, [echo_cap]
    test    rax, rax
    jz      .alloc_new
    shl     rax, 1
    jmp     .do_grow
.alloc_new:
    mov     rax, 64
.do_grow:
    mov     [echo_cap], rax
    shl     rax, 3
    mov     rsi, rax

    cmp     qword [echo_ptrs], 0
    je      .mmap_new

    ; mremap existing
    mov     rdi, [echo_ptrs]
    mov     rdx, rsi
    mov     rax, [echo_cap]
    shr     rax, 1
    shl     rax, 3
    push    rsi
    mov     rsi, rax
    pop     rdx
    mov     r10, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    test    rax, rax
    js      .oom
    mov     [echo_ptrs], rax
    pop     rbx
    ret

.mmap_new:
    mov     rdi, 0
    mov     rdx, PROT_READ | PROT_WRITE
    mov     r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .oom
    mov     [echo_ptrs], rax
    pop     rbx
    ret

.oom:
    mov     edi, 1
    call    asm_exit

; ─── str_match_long ───
str_match_long:
    push    rbx
.sml_cmp_loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    test    cl, cl
    jz      .sml_check_end
    cmp     al, cl
    jne     .sml_no_match
    inc     rdi
    inc     rsi
    jmp     .sml_cmp_loop
.sml_check_end:
    test    al, al
    jnz     .sml_no_match
    mov     eax, 1
    pop     rbx
    ret
.sml_no_match:
    xor     eax, eax
    pop     rbx
    ret

; ─── str_starts_with ───
str_starts_with:
.ssw_cmp_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .ssw_match
    movzx   ecx, byte [rdi]
    cmp     al, cl
    jne     .ssw_no_match
    inc     rdi
    inc     rsi
    jmp     .ssw_cmp_loop
.ssw_match:
    mov     eax, 1
    ret
.ssw_no_match:
    xor     eax, eax
    ret

; ─── find_eq_value ───
find_eq_value:
.fev_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .fev_not_found
    cmp     al, '='
    je      .fev_found
    inc     rdi
    jmp     .fev_loop
.fev_found:
    lea     rax, [rdi + 1]
    ret
.fev_not_found:
    mov     rax, rdi
    ret

; ─── parse_range_str ───
parse_range_str:
    push    rbx
    push    r12
    mov     r12, rdi

    call    parse_uint64
    test    edx, edx
    jnz     .prs_invalid
    mov     [opt_range_lo], rax
    mov     rbx, rdi

    cmp     byte [rbx], '-'
    jne     .prs_invalid
    inc     rbx

    mov     rdi, rbx
    call    parse_uint64
    test    edx, edx
    jnz     .prs_invalid
    mov     [opt_range_hi], rax

    cmp     byte [rdi], 0
    jne     .prs_invalid

    mov     rax, [opt_range_lo]
    cmp     rax, [opt_range_hi]
    ja      .prs_invalid

    pop     r12
    pop     rbx
    ret

.prs_invalid:
    mov     rdi, r12
    call    err_invalid_range

; ─── parse_count_str ───
parse_count_str:
    push    rbx
    mov     rbx, rdi
    call    parse_uint64
    test    edx, edx
    jnz     .pcs_invalid
    cmp     byte [rdi], 0
    jne     .pcs_invalid
    pop     rbx
    ret
.pcs_invalid:
    mov     rdi, rbx
    call    err_invalid_count

; ─── parse_uint64 ───
parse_uint64:
    xor     eax, eax
    xor     edx, edx
    movzx   ecx, byte [rdi]
    sub     cl, '0'
    cmp     cl, 9
    ja      .pu64_error
.pu64_digit_loop:
    movzx   ecx, byte [rdi]
    sub     cl, '0'
    cmp     cl, 9
    ja      .pu64_done
    imul    rax, 10
    movzx   ecx, byte [rdi]
    sub     cl, '0'
    add     rax, rcx
    inc     rdi
    jmp     .pu64_digit_loop
.pu64_done:
    ret
.pu64_error:
    mov     edx, 1
    ret

; ─── seed_prng ───
seed_prng:
    push    rbx

    test    qword [opt_flags], FLAG_HAS_RSRC
    jnz     .sp_open_rsrc

    mov     rdi, str_devurandom
    mov     rsi, O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .sp_fallback_seed
    mov     rbx, rax

    mov     rdi, rbx
    mov     rsi, prng_s0
    mov     rdx, 32
    call    asm_read

    mov     rdi, rbx
    call    asm_close

    mov     rax, [prng_s0]
    or      rax, [prng_s1]
    or      rax, [prng_s2]
    or      rax, [prng_s3]
    test    rax, rax
    jnz     .sp_seed_done
    jmp     .sp_fallback_seed

.sp_open_rsrc:
    mov     rdi, [rsrc_file]
    mov     rsi, O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .sp_err_rsrc_open
    mov     [opt_rsrc_fd], rax

    mov     rdi, rax
    mov     rsi, prng_s0
    mov     rdx, 32
    call    asm_read
    cmp     rax, 32
    jl      .sp_fallback_seed

    mov     rax, [prng_s0]
    or      rax, [prng_s1]
    or      rax, [prng_s2]
    or      rax, [prng_s3]
    test    rax, rax
    jnz     .sp_seed_done
    jmp     .sp_fallback_seed

.sp_fallback_seed:
    mov     rax, 0x123456789abcdef0
    mov     [prng_s0], rax
    mov     rax, 0xfedcba9876543210
    mov     [prng_s1], rax
    mov     rax, 0x0123456789abcdef
    mov     [prng_s2], rax
    mov     rax, 0xdeadbeefcafebabe
    mov     [prng_s3], rax

.sp_seed_done:
    pop     rbx
    ret

.sp_err_rsrc_open:
    mov     rdi, STDERR
    mov     rsi, str_shuf_prefix
    mov     rdx, str_shuf_prefix_len
    call    asm_write_all
    mov     rdi, [rsrc_file]
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, [rsrc_file]
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_colon_space
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_no_such
    mov     rdx, str_no_such_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

; ─── xoshiro256_next ───
xoshiro256_next:
    mov     rax, [prng_s1]
    lea     rax, [rax + rax*4]
    rol     rax, 7
    lea     rax, [rax + rax*8]
    push    rax

    mov     r8, [prng_s1]
    shl     r8, 17

    mov     rax, [prng_s0]
    xor     [prng_s2], rax

    mov     rax, [prng_s1]
    xor     [prng_s3], rax

    mov     rax, [prng_s2]
    xor     [prng_s1], rax

    mov     rax, [prng_s3]
    xor     [prng_s0], rax

    xor     [prng_s2], r8

    mov     rax, [prng_s3]
    rol     rax, 45
    mov     [prng_s3], rax

    pop     rax
    ret

; ─── rand_bounded ───
rand_bounded:
    push    rbx
    push    r12
    mov     r12, rdi

    cmp     r12, 1
    jbe     .rb_return_zero

.rb_retry:
    call    xoshiro256_next
    mul     r12
    mov     rbx, rax
    mov     rax, rdx
    push    rax

    cmp     rbx, r12
    jae     .rb_accept

    mov     rax, r12
    neg     rax
    xor     edx, edx
    div     r12
    cmp     rbx, rdx
    jb      .rb_reject

.rb_accept:
    pop     rax
    pop     r12
    pop     rbx
    ret

.rb_reject:
    pop     rax
    jmp     .rb_retry

.rb_return_zero:
    xor     eax, eax
    pop     r12
    pop     rbx
    ret

; ─── outbuf_write ───
outbuf_write:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, [outbuf_pos]

.obw_write_loop:
    test    r12, r12
    jz      .obw_write_done

    mov     rax, OUTBUF_SIZE
    sub     rax, r13
    jz      .obw_flush_first

    cmp     r12, rax
    jbe     .obw_copy_all
    mov     rdi, [outbuf]
    add     rdi, r13
    mov     rsi, rbx
    mov     rdx, rax
    push    rax
    call    asm_memcpy
    pop     rax
    add     rbx, rax
    sub     r12, rax
    mov     r13, OUTBUF_SIZE

.obw_flush_first:
    mov     rdi, [opt_output_fd]
    mov     rsi, [outbuf]
    mov     rdx, r13
    call    asm_write_all
    cmp     rax, -EPIPE
    je      .obw_broken_pipe
    test    rax, rax
    jnz     .obw_write_error
    xor     r13d, r13d
    jmp     .obw_write_loop

.obw_copy_all:
    mov     rdi, [outbuf]
    add     rdi, r13
    mov     rsi, rbx
    mov     rdx, r12
    call    asm_memcpy
    add     r13, r12
    xor     r12d, r12d

.obw_write_done:
    mov     [outbuf_pos], r13
    pop     r13
    pop     r12
    pop     rbx
    ret

.obw_broken_pipe:
    xor     edi, edi
    call    asm_exit

.obw_write_error:
    mov     rdi, STDERR
    mov     rsi, str_shuf_prefix
    mov     rdx, str_shuf_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_write_err
    mov     rdx, str_write_err_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

; ─── outbuf_byte ───
outbuf_byte:
    mov     rax, [outbuf_pos]
    cmp     rax, OUTBUF_SIZE
    jge     .obb_flush_first
    mov     rcx, [outbuf]
    mov     [rcx + rax], dil
    inc     rax
    mov     [outbuf_pos], rax
    ret
.obb_flush_first:
    push    rdi
    call    flush_outbuf
    pop     rdi
    mov     rax, [outbuf_pos]
    mov     rcx, [outbuf]
    mov     [rcx + rax], dil
    inc     rax
    mov     [outbuf_pos], rax
    ret

; ─── flush_outbuf ───
flush_outbuf:
    mov     rdx, [outbuf_pos]
    test    rdx, rdx
    jz      .fo_nothing
    mov     rdi, [opt_output_fd]
    mov     rsi, [outbuf]
    call    asm_write_all
    cmp     rax, -EPIPE
    je      .fo_epipe
    test    rax, rax
    jnz     .fo_werr
    mov     qword [outbuf_pos], 0
.fo_nothing:
    ret
.fo_epipe:
    xor     edi, edi
    call    asm_exit
.fo_werr:
    mov     rdi, STDERR
    mov     rsi, str_shuf_prefix
    mov     rdx, str_shuf_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_write_err
    mov     rdx, str_write_err_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

; ─── outbuf_u64_delim ───
outbuf_u64_delim:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    movzx   r12d, sil

    mov     r13, [outbuf_pos]
    lea     rax, [r13 + 24]
    cmp     rax, OUTBUF_SIZE
    jb      .u64d_have_space
    call    flush_outbuf
    mov     r13, [outbuf_pos]
.u64d_have_space:
    sub     rsp, 24
    mov     rax, rbx
    lea     rdi, [rsp + 20]
    xor     ecx, ecx

    test    rax, rax
    jnz     .u64d_nonzero
    mov     byte [rdi], '0'
    dec     rdi
    inc     ecx
    jmp     .u64d_copy

.u64d_nonzero:
    lea     r8, [rel digit_pairs]
.u64d_pair_loop:
    cmp     rax, 99
    jbe     .u64d_last_digits

    xor     edx, edx
    mov     r9, 100
    div     r9

    movzx   r9d, word [r8 + rdx*2]
    mov     [rdi-1], r9w
    sub     rdi, 2
    add     ecx, 2
    jmp     .u64d_pair_loop

.u64d_last_digits:
    cmp     rax, 9
    jbe     .u64d_single
    movzx   r9d, word [r8 + rax*2]
    mov     [rdi-1], r9w
    sub     rdi, 2
    add     ecx, 2
    jmp     .u64d_copy
.u64d_single:
    add     al, '0'
    mov     [rdi], al
    dec     rdi
    inc     ecx

.u64d_copy:
    inc     rdi
    mov     rsi, [outbuf]
    add     rsi, r13

    push    rdi
    push    rcx
    mov     rax, rsi
    mov     rsi, rdi
    mov     rdi, rax
    rep     movsb
    pop     rcx
    pop     rdi

    mov     rax, [outbuf]
    add     r13, rcx
    mov     byte [rax + r13], r12b
    inc     r13
    mov     [outbuf_pos], r13

    add     rsp, 24
    pop     r13
    pop     r12
    pop     rbx
    ret

; ─── get_delimiter ───
get_delimiter:
    test    qword [opt_flags], FLAG_ZERO_TERM
    jnz     .gd_zero
    mov     al, 10
    ret
.gd_zero:
    xor     al, al
    ret

; ═══════════════════════════════════════════════════════════════════
; MODE: Echo (-e)
; ═══════════════════════════════════════════════════════════════════
run_echo_mode:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    call    get_delimiter
    movzx   r14d, al

    mov     r15, [echo_count]

    test    r15, r15
    jz      .rem_echo_empty_check

    test    qword [opt_flags], FLAG_REPEAT
    jnz     .rem_echo_repeat

    ; Non-repeat: Fisher-Yates shuffle
    mov     rbx, [echo_ptrs]
    xor     r12d, r12d

.rem_echo_shuffle:
    cmp     r12, r15
    jge     .rem_echo_output

    mov     rdi, r15
    sub     rdi, r12
    call    rand_bounded
    add     rax, r12

    mov     rcx, [rbx + r12*8]
    mov     rdx, [rbx + rax*8]
    mov     [rbx + r12*8], rdx
    mov     [rbx + rax*8], rcx

    inc     r12
    jmp     .rem_echo_shuffle

.rem_echo_output:
    mov     r13, r15
    mov     rax, [opt_head_count]
    cmp     rax, -1
    je      .rem_echo_out_loop
    cmp     rax, r13
    jae     .rem_echo_out_loop
    mov     r13, rax

.rem_echo_out_loop:
    xor     r12d, r12d
.rem_echo_out_iter:
    cmp     r12, r13
    jge     .rem_echo_done

    mov     rdi, [rbx + r12*8]
    call    asm_strlen
    mov     rsi, rax
    mov     rdi, [rbx + r12*8]
    call    outbuf_write

    mov     dil, r14b
    call    outbuf_byte

    inc     r12
    jmp     .rem_echo_out_iter

.rem_echo_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.rem_echo_empty_check:
    test    qword [opt_flags], FLAG_REPEAT
    jz      .rem_echo_done
    mov     rax, [opt_head_count]
    test    rax, rax
    jz      .rem_echo_done
    mov     rdi, STDERR
    mov     rsi, str_shuf_prefix
    mov     rdx, str_shuf_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_no_lines
    mov     rdx, str_no_lines_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.rem_echo_repeat:
    mov     r13, [opt_head_count]
    cmp     r13, -1
    jne     .rem_echo_rep_check
    mov     r13, -1
.rem_echo_rep_check:
    test    r13, r13
    jz      .rem_echo_done

    test    r15, r15
    jz      .rem_echo_empty_check

    mov     rbx, [echo_ptrs]
    xor     r12d, r12d

.rem_echo_rep_loop:
    cmp     r12, r13
    jge     .rem_echo_done

    mov     rdi, r15
    call    rand_bounded

    mov     rdi, [rbx + rax*8]
    push    rax
    call    asm_strlen
    mov     rsi, rax
    pop     rax
    mov     rdi, [rbx + rax*8]
    call    outbuf_write

    mov     dil, r14b
    call    outbuf_byte

    inc     r12
    jmp     .rem_echo_rep_loop

; ═══════════════════════════════════════════════════════════════════
; MODE: Input range (-i LO-HI)
; ═══════════════════════════════════════════════════════════════════
run_range_mode:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    call    get_delimiter
    movzx   r14d, al

    mov     rax, [opt_range_hi]
    sub     rax, [opt_range_lo]
    inc     rax
    mov     r15, rax

    test    qword [opt_flags], FLAG_REPEAT
    jnz     .rrm_range_repeat

    mov     r13, r15
    mov     rax, [opt_head_count]
    cmp     rax, -1
    je      .rrm_range_no_hc
    cmp     rax, r13
    jae     .rrm_range_no_hc
    mov     r13, rax
.rrm_range_no_hc:
    test    r13, r13
    jz      .rrm_range_done

    ; Allocate array
    mov     rdi, 0
    mov     rsi, r15
    shl     rsi, 3
    mov     rdx, PROT_READ | PROT_WRITE
    mov     r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .rrm_range_oom
    mov     rbx, rax

    ; Fill array
    mov     rcx, [opt_range_lo]
    xor     edx, edx
.rrm_range_fill:
    cmp     rdx, r15
    jge     .rrm_range_shuffle
    mov     [rbx + rdx*8], rcx
    inc     rcx
    inc     rdx
    jmp     .rrm_range_fill

.rrm_range_shuffle:
    xor     r12d, r12d
.rrm_range_fy:
    cmp     r12, r13
    jge     .rrm_range_output

    mov     rdi, r15
    sub     rdi, r12
    call    rand_bounded
    add     rax, r12

    mov     rcx, [rbx + r12*8]
    mov     rdx, [rbx + rax*8]
    mov     [rbx + r12*8], rdx
    mov     [rbx + rax*8], rcx

    inc     r12
    jmp     .rrm_range_fy

.rrm_range_output:
    xor     r12d, r12d
.rrm_range_out_loop:
    cmp     r12, r13
    jge     .rrm_range_unmap

    mov     rdi, [rbx + r12*8]
    mov     sil, r14b
    call    outbuf_u64_delim

    inc     r12
    jmp     .rrm_range_out_loop

.rrm_range_unmap:
    mov     rdi, rbx
    mov     rsi, r15
    shl     rsi, 3
    mov     rax, SYS_MUNMAP
    syscall

.rrm_range_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.rrm_range_repeat:
    mov     r13, [opt_head_count]
    cmp     r13, -1
    jne     .rrm_range_rep_check
    mov     r13, -1
.rrm_range_rep_check:
    test    r13, r13
    jz      .rrm_range_done

    xor     r12d, r12d
.rrm_range_rep_loop:
    cmp     r12, r13
    jge     .rrm_range_done

    mov     rdi, r15
    call    rand_bounded
    add     rax, [opt_range_lo]

    mov     rdi, rax
    mov     sil, r14b
    call    outbuf_u64_delim

    inc     r12
    jmp     .rrm_range_rep_loop

.rrm_range_oom:
    mov     edi, 1
    call    asm_exit

; ═══════════════════════════════════════════════════════════════════
; MODE: File/stdin
; ═══════════════════════════════════════════════════════════════════
run_file_mode:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    call    get_delimiter
    movzx   r14d, al
    mov     rbp, r14

    call    read_input_data

    mov     rax, [input_size]
    test    rax, rax
    jz      .rfm_file_empty

    call    split_lines

    mov     r15, [line_count]
    test    r15, r15
    jz      .rfm_file_empty

    test    qword [opt_flags], FLAG_REPEAT
    jnz     .rfm_file_repeat

    mov     r13, r15
    mov     rax, [opt_head_count]
    cmp     rax, -1
    je      .rfm_file_no_hc
    cmp     rax, r13
    jae     .rfm_file_no_hc
    mov     r13, rax
.rfm_file_no_hc:
    test    r13, r13
    jz      .rfm_file_done

    ; Fisher-Yates shuffle
    mov     rbx, [line_ptrs]
    xor     r12d, r12d
.rfm_file_fy:
    cmp     r12, r13
    jge     .rfm_file_output

    mov     rdi, r15
    sub     rdi, r12
    call    rand_bounded
    add     rax, r12

    ; Swap line_ptrs[i] and line_ptrs[j] (each entry is 16 bytes)
    mov     rdx, r12
    shl     rdx, 4
    add     rdx, rbx
    mov     rcx, rax
    shl     rcx, 4
    add     rcx, rbx

    mov     r8, [rdx]
    mov     r9, [rdx+8]
    mov     r10, [rcx]
    mov     r11, [rcx+8]
    mov     [rdx], r10
    mov     [rdx+8], r11
    mov     [rcx], r8
    mov     [rcx+8], r9

    inc     r12
    jmp     .rfm_file_fy

.rfm_file_output:
    xor     r12d, r12d
.rfm_file_out_loop:
    cmp     r12, r13
    jge     .rfm_file_done

    mov     rax, r12
    shl     rax, 4
    add     rax, rbx
    mov     rdi, [rax]
    mov     rsi, [rax+8]
    call    outbuf_write

    mov     dil, r14b
    call    outbuf_byte

    inc     r12
    jmp     .rfm_file_out_loop

.rfm_file_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.rfm_file_empty:
    test    qword [opt_flags], FLAG_REPEAT
    jz      .rfm_file_done
    mov     rax, [opt_head_count]
    test    rax, rax
    jz      .rfm_file_done
    mov     rdi, STDERR
    mov     rsi, str_shuf_prefix
    mov     rdx, str_shuf_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_no_lines
    mov     rdx, str_no_lines_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.rfm_file_repeat:
    mov     r13, [opt_head_count]
    cmp     r13, -1
    jne     .rfm_file_rep_check
    mov     r13, -1
.rfm_file_rep_check:
    test    r13, r13
    jz      .rfm_file_done

    mov     rbx, [line_ptrs]
    xor     r12d, r12d
.rfm_file_rep_loop:
    cmp     r12, r13
    jge     .rfm_file_done

    mov     rdi, r15
    call    rand_bounded

    shl     rax, 4
    add     rax, rbx
    mov     rdi, [rax]
    mov     rsi, [rax+8]
    call    outbuf_write

    mov     dil, r14b
    call    outbuf_byte

    inc     r12
    jmp     .rfm_file_rep_loop

; ─── read_input_data ───
read_input_data:
    push    rbx
    push    r12

    mov     rax, [input_file]
    test    rax, rax
    jz      .rid_read_stdin
    cmp     byte [rax], '-'
    jne     .rid_read_file
    cmp     byte [rax+1], 0
    je      .rid_read_stdin

.rid_read_file:
    mov     rdi, [input_file]
    mov     rsi, O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .rid_err_open_file
    mov     rbx, rax

    sub     rsp, STAT_STRUCT_SIZE
    mov     rdi, rbx
    mov     rsi, rsp
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .rid_err_stat
    mov     r12, [rsp + STAT_SIZE]
    add     rsp, STAT_STRUCT_SIZE

    test    r12, r12
    jz      .rid_empty_file

    mov     rdi, 0
    mov     rsi, r12
    mov     rdx, PROT_READ
    mov     r10, MAP_PRIVATE
    mov     r8, rbx
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .rid_err_mmap

    mov     [input_data], rax
    mov     [input_size], r12

    mov     rdi, rbx
    call    asm_close

    pop     r12
    pop     rbx
    ret

.rid_empty_file:
    mov     qword [input_data], 0
    mov     qword [input_size], 0
    mov     rdi, rbx
    call    asm_close
    pop     r12
    pop     rbx
    ret

.rid_read_stdin:
    mov     rdi, 0
    mov     rsi, INITIAL_BUF
    mov     rdx, PROT_READ | PROT_WRITE
    mov     r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .rid_err_mmap_stdin
    mov     rbx, rax
    xor     r12d, r12d
    mov     r13, INITIAL_BUF

.rid_stdin_read_loop:
    mov     rdi, STDIN
    lea     rsi, [rbx + r12]
    mov     rdx, r13
    sub     rdx, r12
    cmp     rdx, BUF_SIZE
    jbe     .rid_stdin_read_do
    mov     rdx, BUF_SIZE
.rid_stdin_read_do:
    call    asm_read
    test    rax, rax
    jz      .rid_stdin_eof
    js      .rid_stdin_eof
    add     r12, rax

    cmp     r12, r13
    jl      .rid_stdin_read_loop

    ; Grow buffer
    mov     rdi, rbx
    mov     rsi, r13
    lea     rdx, [r13 * 2]
    mov     r10, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    test    rax, rax
    js      .rid_err_mmap_stdin
    mov     rbx, rax
    shl     r13, 1
    jmp     .rid_stdin_read_loop

.rid_stdin_eof:
    mov     [input_data], rbx
    mov     [input_size], r12
    pop     r12
    pop     rbx
    ret

.rid_err_open_file:
    mov     rdi, STDERR
    mov     rsi, str_shuf_prefix
    mov     rdx, str_shuf_prefix_len
    call    asm_write_all
    mov     rdi, [input_file]
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, [input_file]
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_colon_space
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_no_such
    mov     rdx, str_no_such_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.rid_err_stat:
    add     rsp, STAT_STRUCT_SIZE
    mov     edi, 1
    call    asm_exit

.rid_err_mmap:
    mov     edi, 1
    call    asm_exit

.rid_err_mmap_stdin:
    mov     edi, 1
    call    asm_exit

; ─── split_lines ───
split_lines:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     rdi, 0
    mov     rsi, INITIAL_LINES
    shl     rsi, 4
    mov     rdx, PROT_READ | PROT_WRITE
    mov     r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .sl_split_oom
    mov     [line_ptrs], rax
    mov     qword [line_cap], INITIAL_LINES

    mov     rbx, [input_data]
    mov     r12, [input_size]
    xor     r13d, r13d
    mov     r14, rbx

.sl_split_loop:
    test    r12, r12
    jz      .sl_split_last

    movzx   eax, byte [rbx]
    cmp     al, bpl
    je      .sl_found_sep

    inc     rbx
    dec     r12
    jmp     .sl_split_loop

.sl_found_sep:
    mov     rdi, r14
    mov     rsi, rbx
    sub     rsi, r14

    call    store_line

    inc     rbx
    dec     r12
    mov     r14, rbx
    jmp     .sl_split_loop

.sl_split_last:
    cmp     r14, rbx
    je      .sl_split_done

    mov     rdi, r14
    mov     rsi, rbx
    sub     rsi, r14
    call    store_line

.sl_split_done:
    mov     [line_count], r13
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.sl_split_oom:
    mov     edi, 1
    call    asm_exit

; ─── store_line ───
store_line:
    cmp     r13, [line_cap]
    jb      .stl_store_ok

    push    rdi
    push    rsi
    mov     rdi, [line_ptrs]
    mov     rsi, [line_cap]
    shl     rsi, 4
    mov     rdx, [line_cap]
    shl     rdx, 1
    mov     [line_cap], rdx
    shl     rdx, 4
    mov     r10, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    test    rax, rax
    js      .stl_store_oom
    mov     [line_ptrs], rax
    pop     rsi
    pop     rdi

.stl_store_ok:
    mov     rax, [line_ptrs]
    mov     rcx, r13
    shl     rcx, 4
    add     rax, rcx
    mov     [rax], rdi
    mov     [rax+8], rsi
    inc     r13
    ret

.stl_store_oom:
    mov     edi, 1
    call    asm_exit

; ═══════════════════════════════════════════════════════════════════
; Error reporting functions
; ═══════════════════════════════════════════════════════════════════

err_invalid_option:
    push    rdi
    mov     rdi, STDERR
    mov     rsi, str_shuf_prefix
    mov     rdx, str_shuf_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_inv_opt
    mov     rdx, str_inv_opt_len
    call    asm_write_all
    pop     rax
    sub     rsp, 8
    mov     [rsp], al
    mov     rdi, STDERR
    mov     rsi, rsp
    mov     rdx, 1
    call    asm_write_all
    add     rsp, 8
    mov     rdi, STDERR
    mov     rsi, str_inv_opt2
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_try_help
    mov     rdx, str_try_help_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

err_opt_requires_arg:
    push    rdi
    mov     rdi, STDERR
    mov     rsi, str_shuf_prefix
    mov     rdx, str_shuf_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_opt_req
    mov     rdx, str_opt_req_len
    call    asm_write_all
    pop     rax
    sub     rsp, 8
    mov     [rsp], al
    mov     rdi, STDERR
    mov     rsi, rsp
    mov     rdx, 1
    call    asm_write_all
    add     rsp, 8
    mov     rdi, STDERR
    mov     rsi, str_inv_opt2
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_try_help
    mov     rdx, str_try_help_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

err_unrecog_option:
    push    rdi
    mov     rdi, STDERR
    mov     rsi, str_shuf_prefix
    mov     rdx, str_shuf_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_unrecog
    mov     rdx, str_unrecog_len
    call    asm_write_all
    pop     rdi
    push    rdi
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    pop     rsi
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_unrecog2
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_try_help
    mov     rdx, str_try_help_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

err_extra_operand:
    push    rdi
    mov     rdi, STDERR
    mov     rsi, str_shuf_prefix
    mov     rdx, str_shuf_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_extra_op
    mov     rdx, str_extra_op_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_lquote
    mov     rdx, str_lquote_len
    call    asm_write_all
    pop     rdi
    push    rdi
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    pop     rsi
    call    asm_write_all
    sub     rsp, 8
    mov     byte [rsp], 0xe2
    mov     byte [rsp+1], 0x80
    mov     byte [rsp+2], 0x99
    mov     byte [rsp+3], 10
    mov     rdi, STDERR
    mov     rsi, rsp
    mov     rdx, 4
    call    asm_write_all
    add     rsp, 8
    mov     rdi, STDERR
    mov     rsi, str_try_help
    mov     rdx, str_try_help_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

err_invalid_range:
    push    rdi
    mov     rdi, STDERR
    mov     rsi, str_shuf_prefix
    mov     rdx, str_shuf_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_inv_range
    mov     rdx, str_inv_range_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_lquote
    mov     rdx, str_lquote_len
    call    asm_write_all
    pop     rdi
    push    rdi
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    pop     rsi
    call    asm_write_all
    sub     rsp, 8
    mov     byte [rsp], 0xe2
    mov     byte [rsp+1], 0x80
    mov     byte [rsp+2], 0x99
    mov     byte [rsp+3], 10
    mov     rdi, STDERR
    mov     rsi, rsp
    mov     rdx, 4
    call    asm_write_all
    add     rsp, 8
    mov     edi, 1
    call    asm_exit

err_invalid_count:
    push    rdi
    mov     rdi, STDERR
    mov     rsi, str_shuf_prefix
    mov     rdx, str_shuf_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_inv_count
    mov     rdx, str_inv_count_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_lquote
    mov     rdx, str_lquote_len
    call    asm_write_all
    pop     rdi
    push    rdi
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    pop     rsi
    call    asm_write_all
    sub     rsp, 8
    mov     byte [rsp], 0xe2
    mov     byte [rsp+1], 0x80
    mov     byte [rsp+2], 0x99
    mov     byte [rsp+3], 10
    mov     rdi, STDERR
    mov     rsi, rsp
    mov     rdx, 4
    call    asm_write_all
    add     rsp, 8
    mov     edi, 1
    call    asm_exit

code_end equ $
bss_file_offset equ code_end - ehdr

; ════════════════════════════════════════════════════════════════
; BSS — Uninitialized data (zero-filled by kernel)
; ════════════════════════════════════════════════════════════════
align 4096
bss_start:

opt_flags:      resq 1
opt_head_count: resq 1
opt_range_lo:   resq 1
opt_range_hi:   resq 1
opt_output_fd:  resq 1
opt_rsrc_fd:    resq 1
output_file:    resq 1
rsrc_file:      resq 1
input_file:     resq 1
line_ptrs:      resq 1
line_count:     resq 1
line_cap:       resq 1
input_data:     resq 1
input_size:     resq 1
echo_ptrs:      resq 1
echo_count:     resq 1
echo_cap:       resq 1

align 32
prng_s0:        resq 1
prng_s1:        resq 1
prng_s2:        resq 1
prng_s3:        resq 1

outbuf:         resq 1
outbuf_pos:     resq 1

stat_buf:       resb STAT_STRUCT_SIZE
itoa_buf:       resb ITOA_BUF_SIZE

bss_end:
