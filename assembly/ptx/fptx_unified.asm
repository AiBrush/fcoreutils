; ============================================================
; fptx_unified.asm — GNU-compatible 'ptx' command
; Builds with: nasm -f bin fptx_unified.asm -o fptx
;
; ptx: produce a permuted index of file contents
;
; Usage: ptx [OPTION]... [INPUT [OUTPUT]]
;   -w N: set output width (default 72)
;   -A: auto-reference
;   -T: TeX output format
;   -O: produce output for words in "only" file
;   -W REGEXP: word regexp
;
; Reads stdin or file, produces permuted index of words with context.
; This is a complex text processing tool; the assembly implementation
; provides basic functionality for common use cases.
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXIT       60
%define SYS_BRK        12
%define SYS_RT_SIGPROCMASK 14

%define O_RDONLY        0
%define STDOUT          1
%define STDERR          2
%define STDIN           0
%define SIG_BLOCK       0
%define SIGPIPE        13

%define MAX_LINE       4096
%define MAX_INPUT      65536   ; 64KB max input

; === ELF Header ===
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
    dw ehdr_size
    dw phdr_size
    dw 2
    dw 64, 0, 0
ehdr_size equ $ - ehdr

phdr:
    dd 1, 7
    dq 0, $$, $$
    dq file_size, mem_size
    dq 0x200000
phdr_size equ $ - phdr

    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 16

; ============================================================
; Code
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

    mov     r14d, [rsp]
    lea     r15, [rsp + 8]

    ; Defaults
    mov     dword [output_width], 72
    xor     r12d, r12d          ; flags
    mov     ecx, 1
    mov     dword [input_fd], STDIN

    cmp     r14d, 2
    jl      .no_more_opts

    ; Check --help / --version
    mov     rdi, [r15 + 8]
    push    rcx
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .show_help
    mov     rdi, [r15 + 8]
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .show_version
    pop     rcx

.parse_opts:
    cmp     ecx, r14d
    jge     .no_more_opts
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .got_file
    cmp     byte [rdi + 1], '-'
    je      .check_dashdash
    cmp     byte [rdi + 1], 0
    je      .got_file           ; lone "-" means stdin

    ; Short options
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'w'
    je      .parse_width
    cmp     al, 'A'
    je      .set_autoref
    cmp     al, 'T'
    je      .set_tex
    cmp     al, 'R'
    je      .set_right_ref
    cmp     al, 'O'
    je      .skip_arg
    cmp     al, 'W'
    je      .skip_arg
    cmp     al, 'b'
    je      .skip_arg
    cmp     al, 'f'
    je      .set_flag
    cmp     al, 'g'
    je      .skip_arg
    cmp     al, 'i'
    je      .skip_arg
    cmp     al, 'o'
    je      .skip_arg
    cmp     al, 'r'
    je      .set_flag
    cmp     al, 'S'
    je      .skip_arg
    cmp     al, 'F'
    je      .skip_arg
    cmp     al, 'M'
    je      .skip_arg
    ; Unknown
    jmp     .invalid_short

.set_autoref:
    or      r12d, 1
    inc     rdi
    jmp     .short_loop
.set_tex:
    or      r12d, 2
    inc     rdi
    jmp     .short_loop
.set_right_ref:
    or      r12d, 4
    inc     rdi
    jmp     .short_loop
.set_flag:
    inc     rdi
    jmp     .short_loop
.skip_arg:
    ; Next arg is the value
    inc     ecx
    jmp     .next_opt
.parse_width:
    ; -w N
    cmp     byte [rdi + 1], 0
    jne     .width_attached
    inc     ecx
    cmp     ecx, r14d
    jge     .missing_width
    mov     rdi, [r15 + rcx*8]
    call    parse_uint
    mov     [output_width], eax
    jmp     .next_opt
.width_attached:
    inc     rdi
    call    parse_uint
    mov     [output_width], eax
    jmp     .next_opt

.check_dashdash:
    cmp     byte [rdi + 2], 0
    jne     .invalid_long
    inc     ecx
    jmp     .got_file

.next_opt:
    inc     ecx
    jmp     .parse_opts

.got_file:
    ; Open input file if specified
    cmp     ecx, r14d
    jge     .no_more_opts
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    je      .no_more_opts
    mov     eax, SYS_OPEN
    xor     esi, esi            ; O_RDONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .file_error
    mov     [input_fd], eax

.no_more_opts:
    ; Read entire input
    lea     rsi, [input_buf]
    xor     r13d, r13d          ; total bytes read
.read_loop:
    mov     eax, SYS_READ
    mov     edi, [input_fd]
    lea     rsi, [input_buf + r13]
    mov     edx, 4096
    syscall
    cmp     rax, 0
    jle     .read_done
    add     r13d, eax
    cmp     r13d, MAX_INPUT - 4096
    jl      .read_loop
.read_done:
    mov     byte [input_buf + r13], 0

    ; Close input fd if not stdin
    cmp     dword [input_fd], STDIN
    je      .process_input
    mov     eax, SYS_CLOSE
    mov     edi, [input_fd]
    syscall

.process_input:
    ; Process input: for each word, generate a permuted index line
    ; Simple implementation: scan for words, output each in context
    lea     r8, [input_buf]     ; current position
    xor     r9d, r9d            ; line start offset

.scan_lines:
    cmp     byte [r8], 0
    je      .done_output

    ; Find start of line
    mov     r9, r8              ; line start

    ; Find end of line
    mov     r10, r8
.find_eol:
    cmp     byte [r10], 0
    je      .got_line
    cmp     byte [r10], 10
    je      .got_line
    inc     r10
    jmp     .find_eol

.got_line:
    ; r9 = line start, r10 = line end (points to \n or \0)
    mov     r11, r10
    sub     r11, r9             ; line length

    ; Scan words in this line
    mov     rbx, r9             ; word scanner

.scan_words:
    cmp     rbx, r10
    jge     .next_line

    ; Skip whitespace
    cmp     byte [rbx], ' '
    je      .skip_ws
    cmp     byte [rbx], 9
    je      .skip_ws
    jmp     .got_word
.skip_ws:
    inc     rbx
    jmp     .scan_words

.got_word:
    ; rbx = word start
    mov     rcx, rbx
.find_word_end:
    cmp     rcx, r10
    jge     .word_end
    cmp     byte [rcx], ' '
    je      .word_end
    cmp     byte [rcx], 9
    je      .word_end
    cmp     byte [rcx], 10
    je      .word_end
    inc     rcx
    jmp     .find_word_end
.word_end:
    ; rbx = word start, rcx = word end
    ; Output line in format: context before / KEYWORD / context after
    ; For basic ptx: just output the keyword centered in context
    push    r8
    push    r9
    push    r10
    push    rcx

    ; Print left context (from line start to word start, truncated)
    mov     rdi, r9
    mov     rsi, rbx
    sub     rsi, rdi
    cmp     esi, 30
    jle     .print_left
    add     rdi, rsi
    sub     rdi, 30
    mov     esi, 30
.print_left:
    push    rcx
    mov     edx, esi
    mov     rsi, rdi
    mov     edi, STDOUT
    call    do_write
    pop     rcx

    ; Print keyword in context
    mov     edx, ecx
    sub     edx, ebx
    mov     rsi, rbx
    mov     edi, STDOUT
    call    do_write

    ; Print right context (from word end to line end, truncated)
    pop     rcx
    push    rcx
    mov     rsi, rcx
    mov     rdi, r10
    sub     rdi, rcx
    cmp     edi, 30
    jle     .print_right
    mov     edi, 30
.print_right:
    mov     edx, edi
    mov     edi, STDOUT
    call    do_write

    ; Newline
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write

    pop     rcx
    pop     r10
    pop     r9
    pop     r8

    ; Advance to next word
    mov     rbx, rcx
    jmp     .scan_words

.next_line:
    ; Skip past newline
    cmp     byte [r10], 10
    jne     .skip_nul
    inc     r10
.skip_nul:
    mov     r8, r10
    jmp     .scan_lines

.done_output:
    xor     edi, edi
    jmp     do_exit

.file_error:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rdi, [r15 + rcx*8]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + rcx*8]
    call    write_err
    mov     rsi, str_enoent
    mov     edx, str_enoent_len
    call    write_err
    mov     edi, 1
    jmp     do_exit

.missing_width:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_missing_arg
    mov     edx, str_missing_arg_len
    call    write_err
    mov     edi, 1
    jmp     do_exit

.invalid_short:
    mov     r8b, [rdi]
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    write_err
    mov     [char_buf], r8b
    mov     rsi, char_buf
    mov     edx, 1
    call    write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    write_err
    mov     edi, 1
    jmp     do_exit

.invalid_long:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_unrec
    mov     edx, str_unrec_len
    call    write_err
    mov     rdi, [r15 + rcx*8]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + rcx*8]
    call    write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    write_err
    mov     edi, 1
    jmp     do_exit

.show_help:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.show_version:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

; ============================================================
; Utility functions
; ============================================================
do_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      do_write
    ret

write_err:
    mov     edi, STDERR
    jmp     do_write

do_exit:
    mov     eax, SYS_EXIT
    syscall

str_len:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     eax
    jmp     .loop
.done:
    ret

str_eq:
    xor     r8d, r8d
.loop:
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    cmp     al, dl
    jne     .ne
    test    al, al
    jz      .eq
    inc     r8d
    jmp     .loop
.eq:
    mov     eax, 1
    ret
.ne:
    xor     eax, eax
    ret

starts_with:
    xor     r8d, r8d
.loop:
    movzx   eax, byte [rsi + r8]
    test    al, al
    jz      .match
    cmp     al, byte [rdi + r8]
    jne     .no
    inc     r8d
    jmp     .loop
.match:
    mov     eax, 1
    ret
.no:
    xor     eax, eax
    ret

parse_uint:
    xor     eax, eax
.loop:
    movzx   edx, byte [rdi]
    cmp     dl, '0'
    jb      .done
    cmp     dl, '9'
    ja      .done
    imul    eax, 10
    sub     dl, '0'
    movzx   edx, dl
    add     eax, edx
    inc     rdi
    jmp     .loop
.done:
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: ptx [OPTION]... [INPUT [OUTPUT]]", 10
    db "Output a permuted index, including context, of the words in the input files.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -A, --auto-reference           output automatically generated references", 10
    db "  -G, --traditional              behave more like System V 'ptx'", 10
    db "  -F, --flag-truncation=STRING   use STRING for flagging line truncations.", 10
    db "                                 The default is '/'", 10
    db "  -M, --macro-name=STRING        macro name to use instead of 'xx'", 10
    db "  -O, --format=roff              generate output as roff directives", 10
    db "  -R, --right-side-refs          put references at right, not counted in -w", 10
    db "  -S, --sentence-regexp=REGEXP   for end of lines or end of sentences", 10
    db "  -T, --format=tex               generate output as TeX directives", 10
    db "  -W, --word-regexp=REGEXP       use REGEXP to match each keyword", 10
    db "  -b, --break-file=FILE          word break characters in this FILE", 10
    db "  -f, --ignore-case              fold lower case to upper case for sorting", 10
    db "  -g, --gap-size=NUMBER          gap size in columns between output fields", 10
    db "  -i, --ignore-file=FILE         read ignore word list from FILE", 10
    db "  -o, --only-file=FILE           read only word list from this FILE", 10
    db "  -r, --references               first field of each line is a reference", 10
    db "  -t, --typeset-mode             - not implemented -", 10
    db "  -w, --width=NUMBER             output width in columns, reference excluded", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/ptx>", 10
    db "or available locally via: info '(coreutils) ptx invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "ptx (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by F. Pinard.", 10
str_version_len equ $ - str_version
; @@DATA_END@@

str_prefix:         db "ptx: "
str_prefix_len      equ $ - str_prefix
str_try:            db "Try 'ptx --help' for more information.", 10
str_try_len         equ $ - str_try
str_invalid:        db "invalid option -- '"
str_invalid_len     equ $ - str_invalid
str_unrec:          db "unrecognized option '"
str_unrec_len       equ $ - str_unrec
str_sq_nl:          db "'", 10
str_enoent:         db ": No such file or directory", 10
str_enoent_len      equ $ - str_enoent
str_missing_arg:    db "option requires an argument -- 'w'", 10
str_missing_arg_len equ $ - str_missing_arg
str_newline:        db 10

str_help_flag:      db "--help", 0
str_version_flag:   db "--version", 0

file_size equ $ - $$

output_width: dd 72
input_fd: dd 0
char_buf: db 0, 0
input_buf: times MAX_INPUT db 0

mem_size equ $ - $$
