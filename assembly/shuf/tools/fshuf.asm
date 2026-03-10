; ============================================================================
;  fshuf.asm — GNU-compatible "shuf" in x86_64 Linux assembly
;
;  A drop-in replacement for GNU coreutils `shuf`. Small static ELF binary.
;
;  Flags:
;    -e, --echo              treat each ARG as an input line
;    -i, --input-range=LO-HI treat each number LO through HI as an input line
;    -n, --head-count=COUNT  output at most COUNT lines
;    -o, --output=FILE       write result to FILE instead of stdout
;    -r, --repeat            output lines can be repeated
;    -z, --zero-terminated   line delimiter is NUL, not newline
;        --random-source=FILE get random bytes from FILE
;        --help              display help and exit
;        --version           output version information and exit
;        --                  end of options
;
;  Algorithm: xoshiro256** PRNG seeded from /dev/urandom, Fisher-Yates shuffle
;
;  Build (modular):
;    nasm -f elf64 -I ./ tools/fshuf.asm -o build/fshuf.o
;    nasm -f elf64 -I ./ lib/io.asm -o build/io.o
;    nasm -f elf64 -I ./ lib/str.asm -o build/str.o
;    ld --gc-sections build/fshuf.o build/io.o build/str.o -o fshuf
; ============================================================================

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close
extern asm_exit
extern asm_strlen
extern asm_memcpy
extern asm_itoa

; ═══════════════════════════════════════════════════════════════════
; Constants
; ═══════════════════════════════════════════════════════════════════

%define OUTBUF_SIZE     262144          ; 256KB output buffer
%define INITIAL_BUF     (4*1024*1024)   ; 4MB initial read buffer
%define LINE_ENTRY_SIZE 16              ; ptr(8) + len(8) per line
%define INITIAL_LINES   (64*1024)       ; initial line array capacity
%define ITOA_BUF_SIZE   24              ; max digits for u64 + slack

; Option flags
%define FLAG_ECHO       0x01
%define FLAG_REPEAT     0x02
%define FLAG_ZERO_TERM  0x04
%define FLAG_HAS_COUNT  0x08
%define FLAG_HAS_RANGE  0x10
%define FLAG_HAS_OUTPUT 0x20
%define FLAG_HAS_RSRC   0x40

; ═══════════════════════════════════════════════════════════════════
; Data section
; ═══════════════════════════════════════════════════════════════════
section .data

align 16

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

; Unicode quotes: U+2018 (e2 80 98) and U+2019 (e2 80 99)
str_lquote:     db 0xe2, 0x80, 0x98
str_lquote_len equ 3
str_rquote:     db 0xe2, 0x80, 0x99
str_rquote_len equ 3

str_dash:       db "-", 0
str_devurandom: db "/dev/urandom", 0
str_newline:    db 10

; Long option strings
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

; ═══════════════════════════════════════════════════════════════════
; BSS section
; ═══════════════════════════════════════════════════════════════════
section .bss

align 16
opt_flags:      resq 1          ; option flags bitmask
opt_head_count: resq 1          ; -n value (max lines to output)
opt_range_lo:   resq 1          ; -i LO value
opt_range_hi:   resq 1          ; -i HI value
opt_output_fd:  resq 1          ; output fd (1=stdout)
opt_rsrc_fd:    resq 1          ; --random-source fd (-1 = none)
output_file:    resq 1          ; output file path ptr
rsrc_file:      resq 1          ; random-source file path ptr
input_file:     resq 1          ; input file path ptr (null = stdin)

; Line pointer array (dynamically grown)
line_ptrs:      resq 1          ; pointer to array of (ptr, len) pairs
line_count:     resq 1          ; number of lines
line_cap:       resq 1          ; capacity (number of entries)

; Input data buffer
input_data:     resq 1          ; pointer to mmap'd or read data
input_size:     resq 1          ; size of input data

; Echo args: pointers to arg strings
echo_ptrs:      resq 1          ; pointer to array of string pointers
echo_count:     resq 1          ; number of echo args

; xoshiro256** PRNG state
align 32
prng_s0:        resq 1
prng_s1:        resq 1
prng_s2:        resq 1
prng_s3:        resq 1

; Output buffer
outbuf:         resq 1          ; pointer to output buffer
outbuf_pos:     resq 1          ; current position in output buffer

; Temp buffers
stat_buf:       resb STAT_STRUCT_SIZE
itoa_buf:       resb ITOA_BUF_SIZE

; ═══════════════════════════════════════════════════════════════════
; Text section
; ═══════════════════════════════════════════════════════════════════
section .text

global _start

; ─────────────────────────────────────────────────────────────────
; _start — Entry point
; ─────────────────────────────────────────────────────────────────
_start:
    ; Block SIGPIPE (ignore it, handle EPIPE from write)
    call    block_sigpipe

    ; Initialize defaults
    xor     eax, eax
    mov     [opt_flags], rax
    mov     qword [opt_head_count], -1      ; no limit by default
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

    ; Get argc and argv from stack
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv[0]

    ; Allocate output buffer
    mov     rdi, 0              ; addr = NULL
    mov     rsi, OUTBUF_SIZE    ; length
    mov     rdx, PROT_READ | PROT_WRITE
    mov     r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1              ; fd
    xor     r9d, r9d            ; offset
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .mmap_fail
    mov     [outbuf], rax

    ; Parse arguments
    call    parse_args

    ; Validate option conflicts
    mov     rax, [opt_flags]
    test    rax, FLAG_ECHO
    jz      .no_echo_check
    test    rax, FLAG_HAS_RANGE
    jnz     .err_ei_conflict
.no_echo_check:

    ; Check extra operands with -i
    mov     rax, [opt_flags]
    test    rax, FLAG_HAS_RANGE
    jz      .no_range_check
    cmp     qword [input_file], 0
    jne     .err_extra_operand
.no_range_check:

    ; Seed PRNG
    call    seed_prng

    ; Dispatch to mode
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
    ; Flush output buffer
    call    flush_outbuf

    ; Close output file if not stdout
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
    ; "shuf: cannot combine -e and -i options\nTry ..."
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

; ─────────────────────────────────────────────────────────────────
; block_sigpipe — Set SIGPIPE to SIG_IGN
; ─────────────────────────────────────────────────────────────────
block_sigpipe:
    ; struct sigaction on stack (152 bytes)
    sub     rsp, 160
    ; Zero out
    xor     eax, eax
    mov     rcx, 20             ; 160/8
    mov     rdi, rsp
    rep     stosq
    ; sa_handler = SIG_IGN
    mov     qword [rsp], SIG_IGN
    ; sa_flags = 0 (already zeroed)
    ; rt_sigaction(SIGPIPE, &act, NULL, 8)
    mov     rax, SYS_RT_SIGACTION
    mov     rdi, SIGPIPE
    mov     rsi, rsp
    xor     edx, edx            ; oldact = NULL
    mov     r10, 8              ; sigsetsize
    syscall
    add     rsp, 160
    ret

; ─────────────────────────────────────────────────────────────────
; parse_args — Parse command line arguments
; Uses r14=argc, r15=argv
; ─────────────────────────────────────────────────────────────────
parse_args:
    push    rbx
    push    r12
    push    r13
    push    rbp

    mov     rbx, 1              ; arg index (skip argv[0])
    xor     r12d, r12d          ; echo_count counter
    xor     r13d, r13d          ; options_ended flag

    ; First pass: check if -e/--echo is present (affects positional arg handling)
    mov     rcx, 1
.check_echo_loop:
    cmp     rcx, r14
    jge     .check_echo_done
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .check_echo_next
    cmp     byte [rdi+1], '-'
    je      .check_echo_long
    ; Short option: check for 'e' in the string
    mov     rsi, rdi
    inc     rsi
.check_echo_short:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .check_echo_next
    cmp     al, 'e'
    je      .found_echo
    ; Skip value-taking options
    cmp     al, 'i'
    je      .check_echo_next    ; rest consumed
    cmp     al, 'n'
    je      .check_echo_next
    cmp     al, 'o'
    je      .check_echo_next
    inc     rsi
    jmp     .check_echo_short
.check_echo_long:
    ; Check for --echo
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

    ; Count echo args for pre-allocation (if echo mode)
    test    qword [opt_flags], FLAG_ECHO
    jz      .parse_main

    ; Count non-option args after options end
    ; (We'll collect them in the main parse loop)

.parse_main:
    ; Main argument parsing loop
.arg_loop:
    cmp     rbx, r14
    jge     .parse_done

    mov     rdi, [r15 + rbx*8]

    ; If options ended, treat as positional
    test    r13d, r13d
    jnz     .positional_arg

    ; Check if starts with -
    cmp     byte [rdi], '-'
    jne     .positional_arg

    ; Single dash = stdin
    cmp     byte [rdi+1], 0
    je      .positional_arg

    ; Check for --
    cmp     byte [rdi+1], '-'
    jne     .short_opts

    ; Long option
    cmp     byte [rdi+2], 0
    je      .end_options

    ; --help
    mov     rsi, str_opt_help
    call    str_match_long
    test    eax, eax
    jnz     .do_help

    ; --version
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_version
    call    str_match_long
    test    eax, eax
    jnz     .do_version

    ; --echo
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_echo
    call    str_match_long
    test    eax, eax
    jnz     .set_echo

    ; --repeat
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_repeat
    call    str_match_long
    test    eax, eax
    jnz     .set_repeat

    ; --zero-terminated
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_zero
    call    str_match_long
    test    eax, eax
    jnz     .set_zero

    ; --input-range=VALUE
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_input_range_eq
    call    str_starts_with
    test    eax, eax
    jnz     .input_range_eq

    ; --input-range VALUE
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_input_range
    call    str_match_long
    test    eax, eax
    jnz     .input_range_next

    ; --head-count=VALUE
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_head_count_eq
    call    str_starts_with
    test    eax, eax
    jnz     .head_count_eq

    ; --head-count VALUE
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_head_count
    call    str_match_long
    test    eax, eax
    jnz     .head_count_next

    ; --output=VALUE
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_output_eq
    call    str_starts_with
    test    eax, eax
    jnz     .output_eq

    ; --output VALUE
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_output
    call    str_match_long
    test    eax, eax
    jnz     .output_next

    ; --random-source=VALUE
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_random_src_eq
    call    str_starts_with
    test    eax, eax
    jnz     .rsrc_eq

    ; --random-source VALUE
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_random_src
    call    str_match_long
    test    eax, eax
    jnz     .rsrc_next

    ; Unrecognized long option
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
    ; rdi still points to --input-range=VALUE, find the =
    mov     rdi, [r15 + rbx*8]
    call    find_eq_value       ; rax = ptr past '='
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
    ; Use minimum of all -n values (GNU compat)
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
    WRITE   STDOUT, str_help, str_help_len
    xor     edi, edi
    call    asm_exit

.do_version:
    WRITE   STDOUT, str_version, str_version_len
    xor     edi, edi
    call    asm_exit

; ── Short options ────────────────────────────────────────────────
.short_opts:
    mov     rdi, [r15 + rbx*8]
    inc     rdi                 ; skip '-'
    mov     rbp, rdi            ; save pointer into option chars

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
    ; Invalid option
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
    je      .short_i_next_arg
    ; Rest of this arg is the range
    mov     rdi, rbp
    call    parse_range_str
    or      qword [opt_flags], FLAG_HAS_RANGE
    jmp     .short_done

.short_i_next_arg:
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
    je      .short_n_next_arg
    ; Rest of this arg is the count
    mov     rdi, rbp
    call    parse_count_str
    cmp     rax, [opt_head_count]
    jae     .short_n_skip
    mov     [opt_head_count], rax
.short_n_skip:
    or      qword [opt_flags], FLAG_HAS_COUNT
    jmp     .short_done

.short_n_next_arg:
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
    je      .short_o_next_arg
    ; Rest of this arg is the output file
    mov     [output_file], rbp
    or      qword [opt_flags], FLAG_HAS_OUTPUT
    jmp     .short_done

.short_o_next_arg:
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
    ; "shuf: invalid option -- 'X'"
    movzx   edi, byte [rbp]
    call    err_invalid_option

; ── Positional arguments ─────────────────────────────────────────
.positional_arg:
    mov     rax, [opt_flags]
    test    rax, FLAG_ECHO
    jnz     .echo_arg

    ; File mode: at most one file
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
    ; Collect echo arg into echo_ptrs array
    ; Grow array if needed
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

; Error handlers for missing option arguments
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
    ; For --random-source, use full long option error
    mov     rdi, [r15 + rbx*8]
    call    err_unrecog_option

.parse_done:
    ; Open output file if specified
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
    ; "shuf: OUTPUT_FILE: No such file or directory"
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

section .data
str_colon_space: db ": "
echo_cap_init:  dq 0

section .bss
echo_cap:       resq 1

section .text

; ─────────────────────────────────────────────────────────────────
; grow_echo_array — Grow or allocate echo_ptrs
; ─────────────────────────────────────────────────────────────────
grow_echo_array:
    push    rbx
    mov     rax, [echo_cap]
    test    rax, rax
    jz      .alloc_new
    ; Double capacity
    shl     rax, 1
    jmp     .do_grow
.alloc_new:
    mov     rax, 64             ; initial capacity
.do_grow:
    mov     [echo_cap], rax
    shl     rax, 3              ; * 8 bytes per pointer
    mov     rsi, rax            ; new size

    cmp     qword [echo_ptrs], 0
    je      .mmap_new

    ; mremap existing
    mov     rdi, [echo_ptrs]
    mov     rdx, rsi            ; new size
    ; old size = old_cap * 8
    mov     rax, [echo_cap]
    shr     rax, 1              ; old cap (before doubling)
    shl     rax, 3              ; old cap * 8
    push    rsi
    mov     rsi, rax            ; old size
    pop     rdx                 ; new size
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
    ; rsi already = new size
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

; ─────────────────────────────────────────────────────────────────
; str_match_long — Check if rdi matches long option in rsi
; Returns eax=1 if match, 0 if not
; Supports exact match only (no abbreviation for simplicity)
; ─────────────────────────────────────────────────────────────────
str_match_long:
    push    rbx
.cmp_loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    test    cl, cl
    jz      .check_end
    cmp     al, cl
    jne     .no_match
    inc     rdi
    inc     rsi
    jmp     .cmp_loop
.check_end:
    ; Pattern ended, arg must also end
    test    al, al
    jnz     .no_match
    mov     eax, 1
    pop     rbx
    ret
.no_match:
    xor     eax, eax
    pop     rbx
    ret

; ─────────────────────────────────────────────────────────────────
; str_starts_with — Check if string at rdi starts with prefix at rsi
; Returns eax=1 if prefix matches, 0 if not
; ─────────────────────────────────────────────────────────────────
str_starts_with:
.cmp_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .match
    movzx   ecx, byte [rdi]
    cmp     al, cl
    jne     .no_match
    inc     rdi
    inc     rsi
    jmp     .cmp_loop
.match:
    mov     eax, 1
    ret
.no_match:
    xor     eax, eax
    ret

; ─────────────────────────────────────────────────────────────────
; find_eq_value — Find '=' in string at rdi, return pointer after it
; ─────────────────────────────────────────────────────────────────
find_eq_value:
.loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .not_found
    cmp     al, '='
    je      .found
    inc     rdi
    jmp     .loop
.found:
    lea     rax, [rdi + 1]
    ret
.not_found:
    mov     rax, rdi
    ret

; ─────────────────────────────────────────────────────────────────
; parse_range_str — Parse "LO-HI" from string at rdi
; Sets opt_range_lo and opt_range_hi
; ─────────────────────────────────────────────────────────────────
parse_range_str:
    push    rbx
    push    r12
    mov     r12, rdi            ; save original string for error messages

    ; Parse LO
    call    parse_uint64
    test    edx, edx
    jnz     .invalid
    mov     [opt_range_lo], rax
    mov     rbx, rdi            ; rdi now points past LO

    ; Expect '-'
    cmp     byte [rbx], '-'
    jne     .invalid
    inc     rbx

    ; Parse HI
    mov     rdi, rbx
    call    parse_uint64
    test    edx, edx
    jnz     .invalid
    mov     [opt_range_hi], rax

    ; Check byte after HI is end of string
    cmp     byte [rdi], 0
    jne     .invalid

    ; Validate LO <= HI
    mov     rax, [opt_range_lo]
    cmp     rax, [opt_range_hi]
    ja      .invalid

    pop     r12
    pop     rbx
    ret

.invalid:
    ; "shuf: invalid input range: 'STRING'"
    mov     rdi, r12
    call    err_invalid_range

; ─────────────────────────────────────────────────────────────────
; parse_count_str — Parse non-negative integer from string at rdi
; Returns value in rax
; ─────────────────────────────────────────────────────────────────
parse_count_str:
    push    rbx
    mov     rbx, rdi            ; save for error
    call    parse_uint64
    test    edx, edx
    jnz     .invalid
    cmp     byte [rdi], 0
    jne     .invalid
    pop     rbx
    ret
.invalid:
    mov     rdi, rbx
    call    err_invalid_count

; ─────────────────────────────────────────────────────────────────
; parse_uint64 — Parse unsigned 64-bit integer from string at rdi
; Returns: rax=value, rdi=pointer past last digit, edx=0 on success/1 on error
; ─────────────────────────────────────────────────────────────────
parse_uint64:
    xor     eax, eax
    xor     edx, edx
    movzx   ecx, byte [rdi]
    ; Must start with a digit
    sub     cl, '0'
    cmp     cl, 9
    ja      .error
.digit_loop:
    movzx   ecx, byte [rdi]
    sub     cl, '0'
    cmp     cl, 9
    ja      .done
    ; rax = rax * 10 + digit
    imul    rax, 10
    movzx   ecx, byte [rdi]
    sub     cl, '0'
    add     rax, rcx
    inc     rdi
    jmp     .digit_loop
.done:
    ret
.error:
    mov     edx, 1
    ret

; ─────────────────────────────────────────────────────────────────
; seed_prng — Seed xoshiro256** from /dev/urandom or --random-source
; ─────────────────────────────────────────────────────────────────
seed_prng:
    push    rbx

    ; If --random-source specified, open it and save fd
    test    qword [opt_flags], FLAG_HAS_RSRC
    jnz     .open_rsrc

    ; Read 32 bytes from /dev/urandom
    mov     rdi, str_devurandom
    mov     rsi, O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .fallback_seed
    mov     rbx, rax            ; fd

    ; Read 32 bytes for 4 x uint64 state
    mov     rdi, rbx
    mov     rsi, prng_s0
    mov     rdx, 32
    call    asm_read

    mov     rdi, rbx
    call    asm_close

    ; Ensure state is not all-zero
    mov     rax, [prng_s0]
    or      rax, [prng_s1]
    or      rax, [prng_s2]
    or      rax, [prng_s3]
    test    rax, rax
    jnz     .seed_done
    ; All zero: use fallback
    jmp     .fallback_seed

.open_rsrc:
    mov     rdi, [rsrc_file]
    mov     rsi, O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .err_rsrc_open
    mov     [opt_rsrc_fd], rax

    ; Read 32 bytes for initial PRNG state from random source
    mov     rdi, rax
    mov     rsi, prng_s0
    mov     rdx, 32
    call    asm_read
    cmp     rax, 32
    jl      .fallback_seed

    ; Ensure non-zero
    mov     rax, [prng_s0]
    or      rax, [prng_s1]
    or      rax, [prng_s2]
    or      rax, [prng_s3]
    test    rax, rax
    jnz     .seed_done
    jmp     .fallback_seed

.fallback_seed:
    ; Use a fixed non-zero seed (must go through register for 64-bit immediates)
    mov     rax, 0x12345678_9abcdef0
    mov     [prng_s0], rax
    mov     rax, 0xfedcba98_76543210
    mov     [prng_s1], rax
    mov     rax, 0x0123456789abcdef
    mov     [prng_s2], rax
    mov     rax, 0xdeadbeefcafebabe
    mov     [prng_s3], rax

.seed_done:
    pop     rbx
    ret

.err_rsrc_open:
    ; "shuf: FILE: No such file or directory"
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

; ─────────────────────────────────────────────────────────────────
; xoshiro256_next — Generate next random u64
; Returns: rax = random value
; Clobbers: rcx, rdx, r8, r9, r10, r11
; Implements xoshiro256** algorithm
; ─────────────────────────────────────────────────────────────────
xoshiro256_next:
    ; result = rotl(s1 * 5, 7) * 9
    mov     rax, [prng_s1]
    lea     rax, [rax + rax*4]      ; s1 * 5
    rol     rax, 7
    lea     rax, [rax + rax*8]      ; * 9
    push    rax                     ; save result

    ; t = s1 << 17
    mov     r8, [prng_s1]
    shl     r8, 17

    ; s2 ^= s0
    mov     rax, [prng_s0]
    xor     [prng_s2], rax

    ; s3 ^= s1
    mov     rax, [prng_s1]
    xor     [prng_s3], rax

    ; s1 ^= s2
    mov     rax, [prng_s2]
    xor     [prng_s1], rax

    ; s0 ^= s3
    mov     rax, [prng_s3]
    xor     [prng_s0], rax

    ; s2 ^= t
    xor     [prng_s2], r8

    ; s3 = rotl(s3, 45)
    mov     rax, [prng_s3]
    rol     rax, 45
    mov     [prng_s3], rax

    pop     rax                     ; return result
    ret

; ─────────────────────────────────────────────────────────────────
; rand_bounded — Generate random number in [0, n)
; rdi = n (upper bound, exclusive)
; Returns: rax = random value in [0, n)
; Uses Lemire's nearly-divisionless method
; ─────────────────────────────────────────────────────────────────
rand_bounded:
    push    rbx
    push    r12
    mov     r12, rdi            ; n

    cmp     r12, 1
    jbe     .return_zero

.retry:
    call    xoshiro256_next
    ; x = rax (random u64)
    ; m = x * n (128-bit: hi in rdx, lo in rax)
    mul     r12                 ; rdx:rax = rax * r12
    mov     rbx, rax            ; l = low 64 bits
    mov     rax, rdx            ; result candidate = high 64 bits
    push    rax                 ; save result

    ; if l < n, potential rejection
    cmp     rbx, r12
    jae     .accept

    ; t = (-n) % n
    mov     rax, r12
    neg     rax
    xor     edx, edx
    div     r12                 ; rax = (-n)/n, rdx = (-n) % n
    cmp     rbx, rdx
    jb      .reject

.accept:
    pop     rax
    pop     r12
    pop     rbx
    ret

.reject:
    pop     rax                 ; discard
    jmp     .retry

.return_zero:
    xor     eax, eax
    pop     r12
    pop     rbx
    ret

; ─────────────────────────────────────────────────────────────────
; outbuf_write — Write bytes to output buffer, flushing as needed
; rdi = ptr to data, rsi = length
; ─────────────────────────────────────────────────────────────────
outbuf_write:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi            ; src
    mov     r12, rsi            ; len
    mov     r13, [outbuf_pos]

.write_loop:
    test    r12, r12
    jz      .write_done

    ; Space left in buffer
    mov     rax, OUTBUF_SIZE
    sub     rax, r13
    jz      .flush_first

    ; Copy min(remaining, space) bytes
    cmp     r12, rax
    jbe     .copy_all
    ; Copy 'space' bytes, flush, continue
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

.flush_first:
    ; Flush buffer
    mov     rdi, [opt_output_fd]
    mov     rsi, [outbuf]
    mov     rdx, r13
    call    asm_write_all
    cmp     rax, -EPIPE
    je      .broken_pipe
    test    rax, rax
    jnz     .write_error
    xor     r13d, r13d
    jmp     .write_loop

.copy_all:
    mov     rdi, [outbuf]
    add     rdi, r13
    mov     rsi, rbx
    mov     rdx, r12
    call    asm_memcpy
    add     r13, r12
    xor     r12d, r12d

.write_done:
    mov     [outbuf_pos], r13
    pop     r13
    pop     r12
    pop     rbx
    ret

.broken_pipe:
    ; Exit cleanly on broken pipe
    xor     edi, edi
    call    asm_exit

.write_error:
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

; ─────────────────────────────────────────────────────────────────
; outbuf_byte — Write a single byte to output buffer
; dil = byte value
; ─────────────────────────────────────────────────────────────────
outbuf_byte:
    mov     rax, [outbuf_pos]
    cmp     rax, OUTBUF_SIZE
    jge     .flush_first
    mov     rcx, [outbuf]
    mov     [rcx + rax], dil
    inc     rax
    mov     [outbuf_pos], rax
    ret
.flush_first:
    push    rdi                 ; save byte
    call    flush_outbuf
    pop     rdi
    mov     rax, [outbuf_pos]
    mov     rcx, [outbuf]
    mov     [rcx + rax], dil
    inc     rax
    mov     [outbuf_pos], rax
    ret

; ─────────────────────────────────────────────────────────────────
; flush_outbuf — Flush output buffer
; ─────────────────────────────────────────────────────────────────
flush_outbuf:
    mov     rdx, [outbuf_pos]
    test    rdx, rdx
    jz      .nothing
    mov     rdi, [opt_output_fd]
    mov     rsi, [outbuf]
    call    asm_write_all
    cmp     rax, -EPIPE
    je      .epipe
    test    rax, rax
    jnz     .werr
    mov     qword [outbuf_pos], 0
.nothing:
    ret
.epipe:
    xor     edi, edi
    call    asm_exit
.werr:
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

; ─────────────────────────────────────────────────────────────────
; outbuf_u64_delim — Write u64 as decimal + delimiter directly to outbuf
; rdi = value (u64), sil = delimiter byte
; Uses two-digit lookup table for fast conversion. Max 21 bytes (20 digits + delim).
; Flushes buffer if needed.
; ─────────────────────────────────────────────────────────────────
outbuf_u64_delim:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi            ; value
    movzx   r12d, sil           ; delimiter

    ; Check if we have enough space (max 21 bytes)
    mov     r13, [outbuf_pos]
    lea     rax, [r13 + 24]
    cmp     rax, OUTBUF_SIZE
    jb      .u64_have_space
    ; Flush first
    call    flush_outbuf
    mov     r13, [outbuf_pos]
.u64_have_space:
    ; Write digits into a stack temp buffer (reverse order), then copy forward
    sub     rsp, 24             ; temp buffer on stack
    mov     rax, rbx
    lea     rdi, [rsp + 20]     ; write pointer (from end)
    xor     ecx, ecx            ; digit count

    ; Handle zero
    test    rax, rax
    jnz     .u64_nonzero
    mov     byte [rdi], '0'
    dec     rdi
    inc     ecx
    jmp     .u64_copy

.u64_nonzero:
    ; Convert using pairs of digits with lookup table
    lea     r8, [rel digit_pairs]
.u64_pair_loop:
    cmp     rax, 99
    jbe     .u64_last_digits

    ; Divide by 100, get remainder
    xor     edx, edx
    mov     r9, 100
    div     r9                  ; rax = quotient, rdx = remainder

    ; Write two digits from lookup table
    movzx   r9d, word [r8 + rdx*2]
    mov     [rdi-1], r9w        ; write 2 bytes
    sub     rdi, 2
    add     ecx, 2
    jmp     .u64_pair_loop

.u64_last_digits:
    ; rax <= 99: write last 1-2 digits
    cmp     rax, 9
    jbe     .u64_single
    ; Two digits
    movzx   r9d, word [r8 + rax*2]
    mov     [rdi-1], r9w
    sub     rdi, 2
    add     ecx, 2
    jmp     .u64_copy
.u64_single:
    add     al, '0'
    mov     [rdi], al
    dec     rdi
    inc     ecx

.u64_copy:
    ; Copy ecx digits from (rdi+1) to outbuf
    inc     rdi                 ; rdi = start of digit string
    mov     rsi, [outbuf]
    add     rsi, r13            ; dest in outbuf

    ; Fast copy (max 20 bytes, just do it with rep movsb, rdi/rsi are src/dest)
    push    rdi
    push    rcx
    mov     rax, rsi            ; save dest
    mov     rsi, rdi            ; src = stack digits
    mov     rdi, rax            ; dest = outbuf pos
    rep     movsb
    pop     rcx
    pop     rdi

    ; Write delimiter
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

; Two-digit lookup table (00-99)
section .data
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

section .text

; ─────────────────────────────────────────────────────────────────
; get_delimiter — Return delimiter byte based on flags
; Returns: al = delimiter (10 or 0)
; ─────────────────────────────────────────────────────────────────
get_delimiter:
    test    qword [opt_flags], FLAG_ZERO_TERM
    jnz     .zero
    mov     al, 10              ; newline
    ret
.zero:
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
    movzx   r14d, al            ; delimiter

    mov     r15, [echo_count]   ; n = number of args

    ; If empty and not repeat: just return
    test    r15, r15
    jz      .echo_empty_check

    ; Check -r (repeat)
    test    qword [opt_flags], FLAG_REPEAT
    jnz     .echo_repeat

    ; Non-repeat: Fisher-Yates shuffle the pointer array, then output
    ; Shuffle echo_ptrs[0..r15)
    mov     rbx, [echo_ptrs]
    xor     r12d, r12d          ; i = 0

.echo_shuffle:
    cmp     r12, r15
    jge     .echo_output

    ; j = i + rand_bounded(n - i)
    mov     rdi, r15
    sub     rdi, r12
    call    rand_bounded
    add     rax, r12            ; j = i + rand

    ; swap echo_ptrs[i] and echo_ptrs[j]
    mov     rcx, [rbx + r12*8]
    mov     rdx, [rbx + rax*8]
    mov     [rbx + r12*8], rdx
    mov     [rbx + rax*8], rcx

    inc     r12
    jmp     .echo_shuffle

.echo_output:
    ; Determine count
    mov     r13, r15            ; default: all
    mov     rax, [opt_head_count]
    cmp     rax, -1
    je      .echo_out_loop
    cmp     rax, r13
    jae     .echo_out_loop
    mov     r13, rax            ; count = min(head_count, n)

.echo_out_loop:
    xor     r12d, r12d          ; i = 0
.echo_out_iter:
    cmp     r12, r13
    jge     .echo_done

    ; Write echo_ptrs[i]
    mov     rdi, [rbx + r12*8]
    call    asm_strlen
    mov     rsi, rax            ; len
    mov     rdi, [rbx + r12*8]
    call    outbuf_write

    ; Write delimiter
    mov     dil, r14b
    call    outbuf_byte

    inc     r12
    jmp     .echo_out_iter

.echo_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.echo_empty_check:
    ; -e with no args and -r: error "no lines to repeat"
    test    qword [opt_flags], FLAG_REPEAT
    jz      .echo_done
    ; With -r and no args, check if -n 0 was given
    mov     rax, [opt_head_count]
    test    rax, rax
    jz      .echo_done          ; -n 0: no output needed
    ; Error: no lines to repeat
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

.echo_repeat:
    ; -r mode: randomly pick from args, output count lines
    mov     r13, [opt_head_count]
    cmp     r13, -1
    jne     .echo_rep_check
    ; No -n: infinite loop (repeat forever)
    mov     r13, -1
.echo_rep_check:
    test    r13, r13
    jz      .echo_done

    ; Check empty
    test    r15, r15
    jz      .echo_empty_check

    mov     rbx, [echo_ptrs]
    xor     r12d, r12d

.echo_rep_loop:
    cmp     r12, r13
    jge     .echo_done

    ; Pick random index
    mov     rdi, r15
    call    rand_bounded

    ; Write echo_ptrs[rax]
    mov     rdi, [rbx + rax*8]
    push    rax
    call    asm_strlen
    mov     rsi, rax
    pop     rax
    mov     rdi, [rbx + rax*8]
    call    outbuf_write

    ; Write delimiter
    mov     dil, r14b
    call    outbuf_byte

    inc     r12
    jmp     .echo_rep_loop

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
    movzx   r14d, al            ; delimiter

    mov     rax, [opt_range_hi]
    sub     rax, [opt_range_lo]
    inc     rax
    mov     r15, rax            ; range_size = hi - lo + 1

    ; Check -r (repeat)
    test    qword [opt_flags], FLAG_REPEAT
    jnz     .range_repeat

    ; Determine count
    mov     r13, r15            ; default: all values
    mov     rax, [opt_head_count]
    cmp     rax, -1
    je      .range_no_hc
    cmp     rax, r13
    jae     .range_no_hc
    mov     r13, rax
.range_no_hc:
    test    r13, r13
    jz      .range_done

    ; Allocate array: range_size * 8 bytes for u64 values
    mov     rdi, 0
    mov     rsi, r15
    shl     rsi, 3              ; range_size * 8
    mov     rdx, PROT_READ | PROT_WRITE
    mov     r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .range_oom
    mov     rbx, rax            ; array pointer

    ; Fill array with lo..hi
    mov     rcx, [opt_range_lo]
    xor     edx, edx
.range_fill:
    cmp     rdx, r15
    jge     .range_shuffle
    mov     [rbx + rdx*8], rcx
    inc     rcx
    inc     rdx
    jmp     .range_fill

.range_shuffle:
    ; Partial Fisher-Yates: only r13 rounds
    xor     r12d, r12d          ; i = 0
.range_fy:
    cmp     r12, r13
    jge     .range_output

    ; j = i + rand_bounded(range_size - i)
    mov     rdi, r15
    sub     rdi, r12
    call    rand_bounded
    add     rax, r12

    ; swap array[i] and array[j]
    mov     rcx, [rbx + r12*8]
    mov     rdx, [rbx + rax*8]
    mov     [rbx + r12*8], rdx
    mov     [rbx + rax*8], rcx

    inc     r12
    jmp     .range_fy

.range_output:
    ; Output first r13 values using fast direct-to-buffer itoa
    xor     r12d, r12d
.range_out_loop:
    cmp     r12, r13
    jge     .range_unmap

    mov     rdi, [rbx + r12*8]
    mov     sil, r14b           ; delimiter
    call    outbuf_u64_delim

    inc     r12
    jmp     .range_out_loop

.range_unmap:
    ; Unmap array
    mov     rdi, rbx
    mov     rsi, r15
    shl     rsi, 3
    mov     rax, SYS_MUNMAP
    syscall

.range_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.range_repeat:
    ; -r mode: randomly pick from range, output count lines
    mov     r13, [opt_head_count]
    cmp     r13, -1
    jne     .range_rep_check
    mov     r13, -1             ; infinite
.range_rep_check:
    test    r13, r13
    jz      .range_done

    xor     r12d, r12d
.range_rep_loop:
    cmp     r12, r13
    jge     .range_done

    ; Random value in [lo, hi]
    mov     rdi, r15            ; range_size
    call    rand_bounded
    add     rax, [opt_range_lo]

    ; Convert to string and output using fast path
    mov     rdi, rax
    mov     sil, r14b
    call    outbuf_u64_delim

    inc     r12
    jmp     .range_rep_loop

.range_oom:
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
    movzx   r14d, al            ; delimiter
    ; Separator for splitting (same as delimiter)
    mov     rbp, r14            ; sep = delimiter

    ; Read input data
    call    read_input_data
    ; Now input_data = ptr, input_size = size

    ; If empty: nothing to output (unless -r with empty = error later)
    mov     rax, [input_size]
    test    rax, rax
    jz      .file_empty

    ; Split into lines using sep
    call    split_lines
    ; line_ptrs = array of (ptr, len) pairs, line_count = count

    mov     r15, [line_count]
    test    r15, r15
    jz      .file_empty

    ; Check -r (repeat)
    test    qword [opt_flags], FLAG_REPEAT
    jnz     .file_repeat

    ; Determine count
    mov     r13, r15
    mov     rax, [opt_head_count]
    cmp     rax, -1
    je      .file_no_hc
    cmp     rax, r13
    jae     .file_no_hc
    mov     r13, rax
.file_no_hc:
    test    r13, r13
    jz      .file_done

    ; Fisher-Yates shuffle (partial: only r13 rounds)
    mov     rbx, [line_ptrs]
    xor     r12d, r12d
.file_fy:
    cmp     r12, r13
    jge     .file_output

    mov     rdi, r15
    sub     rdi, r12
    call    rand_bounded
    add     rax, r12

    ; Swap line_ptrs[i] and line_ptrs[j] (each entry is 16 bytes: ptr+len)
    lea     rcx, [rbx + r12*8]
    lea     rcx, [rbx + r12*8]      ; i*16 via r12*8 won't work for 16-byte entries
    ; Calculate offsets: each entry = 16 bytes
    mov     rdx, r12
    shl     rdx, 4              ; i * 16
    add     rdx, rbx            ; &line_ptrs[i]
    mov     rcx, rax
    shl     rcx, 4              ; j * 16
    add     rcx, rbx            ; &line_ptrs[j]

    ; Swap 16 bytes
    mov     r8, [rdx]
    mov     r9, [rdx+8]
    mov     r10, [rcx]
    mov     r11, [rcx+8]
    mov     [rdx], r10
    mov     [rdx+8], r11
    mov     [rcx], r8
    mov     [rcx+8], r9

    inc     r12
    jmp     .file_fy

.file_output:
    xor     r12d, r12d
.file_out_loop:
    cmp     r12, r13
    jge     .file_done

    ; Get line ptr and len
    mov     rax, r12
    shl     rax, 4
    add     rax, rbx
    mov     rdi, [rax]          ; ptr
    mov     rsi, [rax+8]        ; len
    call    outbuf_write

    ; Write delimiter
    mov     dil, r14b
    call    outbuf_byte

    inc     r12
    jmp     .file_out_loop

.file_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.file_empty:
    test    qword [opt_flags], FLAG_REPEAT
    jz      .file_done
    ; -r with empty input: check if -n 0
    mov     rax, [opt_head_count]
    test    rax, rax
    jz      .file_done
    ; Error: no lines to repeat
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

.file_repeat:
    mov     r13, [opt_head_count]
    cmp     r13, -1
    jne     .file_rep_check
    mov     r13, -1
.file_rep_check:
    test    r13, r13
    jz      .file_done

    mov     rbx, [line_ptrs]
    xor     r12d, r12d
.file_rep_loop:
    cmp     r12, r13
    jge     .file_done

    mov     rdi, r15
    call    rand_bounded

    ; Get line ptr and len
    shl     rax, 4
    add     rax, rbx
    mov     rdi, [rax]
    mov     rsi, [rax+8]
    call    outbuf_write

    mov     dil, r14b
    call    outbuf_byte

    inc     r12
    jmp     .file_rep_loop

; ─────────────────────────────────────────────────────────────────
; read_input_data — Read from file or stdin into input_data
; ─────────────────────────────────────────────────────────────────
read_input_data:
    push    rbx
    push    r12

    mov     rax, [input_file]
    test    rax, rax
    jz      .read_stdin
    ; Check if "-"
    cmp     byte [rax], '-'
    jne     .read_file
    cmp     byte [rax+1], 0
    je      .read_stdin

.read_file:
    ; Open file
    mov     rdi, [input_file]
    mov     rsi, O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .err_open_file
    mov     rbx, rax            ; fd

    ; fstat to get size
    sub     rsp, STAT_STRUCT_SIZE
    mov     rdi, rbx
    mov     rsi, rsp
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .err_stat
    mov     r12, [rsp + STAT_SIZE]   ; file size
    add     rsp, STAT_STRUCT_SIZE

    test    r12, r12
    jz      .empty_file

    ; mmap the file
    mov     rdi, 0
    mov     rsi, r12
    mov     rdx, PROT_READ
    mov     r10, MAP_PRIVATE
    mov     r8, rbx             ; fd
    xor     r9d, r9d            ; offset = 0
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .err_mmap

    mov     [input_data], rax
    mov     [input_size], r12

    ; Close file (mmap keeps the mapping)
    mov     rdi, rbx
    call    asm_close

    pop     r12
    pop     rbx
    ret

.empty_file:
    mov     qword [input_data], 0
    mov     qword [input_size], 0
    mov     rdi, rbx
    call    asm_close
    pop     r12
    pop     rbx
    ret

.read_stdin:
    ; Read all stdin into a dynamically grown buffer
    ; Allocate initial buffer
    mov     rdi, 0
    mov     rsi, INITIAL_BUF
    mov     rdx, PROT_READ | PROT_WRITE
    mov     r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .err_mmap_stdin
    mov     rbx, rax            ; buffer
    xor     r12d, r12d          ; total_read = 0
    mov     r13, INITIAL_BUF    ; capacity

.stdin_read_loop:
    ; Read chunk
    mov     rdi, STDIN
    lea     rsi, [rbx + r12]
    mov     rdx, r13
    sub     rdx, r12
    ; Limit read size
    cmp     rdx, BUF_SIZE
    jbe     .stdin_read_do
    mov     rdx, BUF_SIZE
.stdin_read_do:
    call    asm_read
    test    rax, rax
    jz      .stdin_eof          ; EOF
    js      .stdin_eof          ; error treated as EOF
    add     r12, rax

    ; Check if buffer full
    cmp     r12, r13
    jl      .stdin_read_loop

    ; Grow buffer (double it)
    mov     rdi, rbx
    mov     rsi, r13            ; old size
    lea     rdx, [r13 * 2]     ; new size
    mov     r10, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    test    rax, rax
    js      .err_mmap_stdin
    mov     rbx, rax
    shl     r13, 1              ; capacity *= 2
    jmp     .stdin_read_loop

.stdin_eof:
    mov     [input_data], rbx
    mov     [input_size], r12
    pop     r12
    pop     rbx
    ret

.err_open_file:
    ; "shuf: FILE: No such file or directory"
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

.err_stat:
    add     rsp, STAT_STRUCT_SIZE
    mov     edi, 1
    call    asm_exit

.err_mmap:
    mov     edi, 1
    call    asm_exit

.err_mmap_stdin:
    mov     edi, 1
    call    asm_exit

; ─────────────────────────────────────────────────────────────────
; split_lines — Split input_data into lines using separator in bpl
; Uses rbp as separator byte
; Stores results in line_ptrs (array of ptr,len pairs) and line_count
; ─────────────────────────────────────────────────────────────────
split_lines:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; Allocate initial line array
    mov     rdi, 0
    mov     rsi, INITIAL_LINES
    shl     rsi, 4              ; * 16 bytes per entry
    mov     rdx, PROT_READ | PROT_WRITE
    mov     r10, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .split_oom
    mov     [line_ptrs], rax
    mov     qword [line_cap], INITIAL_LINES

    mov     rbx, [input_data]   ; current position
    mov     r12, [input_size]   ; remaining bytes
    xor     r13d, r13d          ; line count
    mov     r14, rbx            ; line start

.split_loop:
    test    r12, r12
    jz      .split_last

    ; Scan for separator byte (rbp low byte)
    movzx   eax, byte [rbx]
    cmp     al, bpl
    je      .found_sep

    inc     rbx
    dec     r12
    jmp     .split_loop

.found_sep:
    ; Line from r14 to rbx (exclusive of separator)
    mov     rdi, r14            ; ptr
    mov     rsi, rbx
    sub     rsi, r14            ; len

    ; Store in line_ptrs
    call    store_line

    ; Move past separator
    inc     rbx
    dec     r12
    mov     r14, rbx            ; next line start
    jmp     .split_loop

.split_last:
    ; If there's trailing data without a separator, add it as a line
    cmp     r14, rbx
    je      .split_done

    mov     rdi, r14
    mov     rsi, rbx
    sub     rsi, r14
    call    store_line

.split_done:
    mov     [line_count], r13
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.split_oom:
    mov     edi, 1
    call    asm_exit

; store_line — Store a line entry (rdi=ptr, rsi=len)
; Uses r13 as current count
store_line:
    ; Check capacity
    cmp     r13, [line_cap]
    jb      .store_ok

    ; Grow array
    push    rdi
    push    rsi
    mov     rdi, [line_ptrs]
    mov     rsi, [line_cap]
    shl     rsi, 4              ; old size in bytes
    mov     rdx, [line_cap]
    shl     rdx, 1              ; new cap
    mov     [line_cap], rdx
    shl     rdx, 4              ; new size in bytes
    mov     r10, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    test    rax, rax
    js      .store_oom
    mov     [line_ptrs], rax
    pop     rsi
    pop     rdi

.store_ok:
    mov     rax, [line_ptrs]
    mov     rcx, r13
    shl     rcx, 4              ; index * 16
    add     rax, rcx
    mov     [rax], rdi          ; ptr
    mov     [rax+8], rsi        ; len
    inc     r13
    ret

.store_oom:
    mov     edi, 1
    call    asm_exit

; ═══════════════════════════════════════════════════════════════════
; Error reporting functions
; ═══════════════════════════════════════════════════════════════════

; err_invalid_option — "shuf: invalid option -- 'X'"
; dil = the option character
err_invalid_option:
    push    rdi
    ; Write prefix
    mov     rdi, STDERR
    mov     rsi, str_shuf_prefix
    mov     rdx, str_shuf_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_inv_opt
    mov     rdx, str_inv_opt_len
    call    asm_write_all
    ; Write the character
    pop     rax
    sub     rsp, 8
    mov     [rsp], al
    mov     rdi, STDERR
    mov     rsi, rsp
    mov     rdx, 1
    call    asm_write_all
    add     rsp, 8
    ; Write closing quote + newline
    mov     rdi, STDERR
    mov     rsi, str_inv_opt2
    mov     rdx, 2
    call    asm_write_all
    ; Try help
    mov     rdi, STDERR
    mov     rsi, str_try_help
    mov     rdx, str_try_help_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

; err_opt_requires_arg — "shuf: option requires an argument -- 'X'"
; dil = the option character
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

; err_unrecog_option — "shuf: unrecognized option 'OPTION'"
; rdi = option string
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
    ; Write closing quote + newline (using ' not unicode here for long opts)
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

; err_extra_operand — "shuf: extra operand 'OPERAND'"
; rdi = operand string
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
    ; Unicode left quote
    mov     rdi, STDERR
    mov     rsi, str_lquote
    mov     rdx, str_lquote_len
    call    asm_write_all
    ; Operand string
    pop     rdi
    push    rdi
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    pop     rsi
    call    asm_write_all
    ; Unicode right quote + newline
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
    ; Try help
    mov     rdi, STDERR
    mov     rsi, str_try_help
    mov     rdx, str_try_help_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

; err_invalid_range — "shuf: invalid input range: 'RANGE'"
; rdi = range string
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
    ; Unicode left quote
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
    ; Unicode right quote + newline
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

; err_invalid_count — "shuf: invalid line count: \u2018COUNT\u2019"
; rdi = count string
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
    ; Unicode left quote
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
    ; Unicode right quote + newline
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

section .note.GNU-stack noalloc noexec nowrite progbits
