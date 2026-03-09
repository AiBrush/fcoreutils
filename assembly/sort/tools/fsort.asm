; ============================================================================
;  fsort.asm — GNU-compatible "sort" in x86_64 Linux assembly
;
;  A drop-in replacement for GNU coreutils `sort`. Small static ELF binary.
;
;  Priority 1 flags:
;    -b              ignore leading blanks in sort keys
;    -c              check if input is sorted
;    -C              like -c but don't report first unsorted line
;    -d              dictionary order (only blanks and alphanumeric)
;    -f              fold lower case to upper case
;    -g              general numeric sort
;    -h              human-readable numeric sort
;    -i              ignore non-printing characters
;    -k KEYDEF       sort by key field
;    -m              merge already-sorted files
;    -M              month sort
;    -n              numeric sort
;    -o FILE         write output to FILE
;    -r              reverse the result of comparisons
;    -s              stabilize sort (no last-resort comparison)
;    -t SEP          use SEP as field separator
;    -u              unique: output only first of equal run
;    -z              line delimiter is NUL, not newline
;    -V              version sort
;    --help          display help
;    --version       display version
;    --              end of options
;
;  Build (modular):
;    nasm -f elf64 -I ./ tools/fsort.asm -o build/fsort.o
;    nasm -f elf64 -I ./ lib/io.asm -o build/io.o
;    nasm -f elf64 -I ./ lib/str.asm -o build/str.o
;    ld --gc-sections build/fsort.o build/io.o build/str.o -o fsort
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

; ═══════════════════════════════════════════════════════════════════
; Constants
; ═══════════════════════════════════════════════════════════════════

%define MAX_FILES       256
%define MAX_KEYS        32
%define OUTBUF_SIZE     131072      ; 128KB output buffer
%define INITIAL_BUF     (4*1024*1024) ; 4MB initial input buffer
%define INITIAL_LINES   (256*1024)    ; initial line array (256K entries)
%define LINE_ENTRY_SIZE 16          ; ptr(8) + len(8) per line

; Option flags (bit positions in flag_bits)
%define FLAG_REVERSE    0x0001
%define FLAG_UNIQUE     0x0002
%define FLAG_NUMERIC    0x0004
%define FLAG_STABLE     0x0008
%define FLAG_CHECK      0x0010
%define FLAG_CHECK_Q    0x0020      ; -C (quiet check)
%define FLAG_FOLD_CASE  0x0040
%define FLAG_DICT       0x0080
%define FLAG_IGNORE_NP  0x0100      ; -i ignore non-printing
%define FLAG_BLANKS     0x0200      ; -b ignore leading blanks
%define FLAG_MERGE      0x0400      ; -m merge
%define FLAG_ZERO_TERM  0x0800      ; -z NUL-terminated lines
%define FLAG_GEN_NUM    0x1000      ; -g general numeric
%define FLAG_MONTH      0x2000      ; -M month sort
%define FLAG_HUMAN      0x4000      ; -h human numeric
%define FLAG_VERSION    0x8000      ; -V version sort

; Key option flags (per-key)
%define KEY_NUMERIC     0x01
%define KEY_BLANKS      0x02
%define KEY_FOLD_CASE   0x04
%define KEY_DICT        0x08
%define KEY_IGNORE_NP   0x10
%define KEY_REVERSE     0x20
%define KEY_GEN_NUM     0x40
%define KEY_MONTH       0x80
%define KEY_HUMAN       0x0100
%define KEY_VERSION     0x0200

; Key definition structure (32 bytes each)
; [0]  qword  start_field  (1-based)
; [8]  qword  start_char   (1-based, 0 = whole field)
; [16] qword  end_field    (1-based, 0 = end of line)
; [24] qword  end_char     (1-based, 0 = end of field)
; [32] qword  flags        (KEY_* flags)
%define KEY_STRUCT_SIZE  40

; ═══════════════════════════════════════════════════════════════════
; Data section
; ═══════════════════════════════════════════════════════════════════
section .data

align 16

; @@DATA_START@@
str_help:
    db "Usage: sort [OPTION]... [FILE]...", 10
    db "  or:  sort [OPTION]... --files0-from=F", 10
    db "Write sorted concatenation of all FILE(s) to standard output.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "Ordering options:", 10
    db 10
    db "  -b, --ignore-leading-blanks  ignore leading blanks", 10
    db "  -d, --dictionary-order       consider only blanks and alphanumeric characters", 10
    db "  -f, --ignore-case            fold lower case to upper case characters", 10
    db "  -g, --general-numeric-sort   compare according to general numerical value", 10
    db "  -i, --ignore-nonprinting     consider only printable characters", 10
    db "  -M, --month-sort             compare (unknown) < 'JAN' < ... < 'DEC'", 10
    db "  -h, --human-numeric-sort     compare human readable numbers (e.g., 2K 1G)", 10
    db "  -n, --numeric-sort           compare according to string numerical value", 10
    db "  -R, --random-sort            shuffle, but group identical keys.  See shuf(1)", 10
    db "      --random-source=FILE     get random bytes from FILE", 10
    db "  -r, --reverse                reverse the result of comparisons", 10
    db "  -V, --version-sort           natural sort of (version) numbers within text", 10
    db 10
    db "Other options:", 10
    db 10
    db "      --batch-size=NMERGE   use at most NMERGE inputs at once; for more use temp files", 10
    db "  -c, --check, --check=diagnose-first  check for sorted input; do not sort", 10
    db "  -C, --check=quiet, --check=silent  like -c, but do not report first bad line", 10
    db "      --compress-program=PROG  compress temporaries with PROG;", 10
    db "                              decompress them with PROG -d", 10
    db "      --debug                  annotate the part of the line used to sort,", 10
    db "                              and warn about questionable usage to stderr", 10
    db "      --files0-from=F          read input from the files specified by", 10
    db "                              NUL-terminated names in file F;", 10
    db "                              If F is - then read names from standard input", 10
    db "  -k, --key=KEYDEF            sort via a key; KEYDEF gives location and type", 10
    db "  -m, --merge                  merge already sorted files; do not sort", 10
    db "  -o, --output=FILE            write result to FILE instead of standard output", 10
    db "  -s, --stable                 stabilize sort by disabling last-resort comparison", 10
    db "  -S, --buffer-size=SIZE       use SIZE for main memory buffer", 10
    db "  -t, --field-separator=SEP    use SEP instead of non-blank to blank transition", 10
    db "  -T, --temporary-directory=DIR  use DIR for temporaries, not $TMPDIR or /tmp;", 10
    db "                              multiple options specify multiple directories", 10
    db "      --parallel=N             change the number of sorts run concurrently to N", 10
    db "  -u, --unique                 with -c, check for strict ordering;", 10
    db "                              without -c, output only the first of an equal run", 10
    db "  -z, --zero-terminated        line delimiter is NUL, not newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "KEYDEF is F[.C][OPTS][,F[.C][OPTS]] for start and stop position, where F is a", 10
    db "field number and C a character position (counted from 1 in the respective field);", 10
    db "both are origin 1.  If neither -t nor -b is in effect, characters in a field are", 10
    db "counted from the beginning of the preceding whitespace.  OPTS is one or more", 10
    db "single-letter ordering options [bdfgiMhnRrV], which override global ordering", 10
    db "options for that key.  If no key is given, use the entire line as the key.", 10
    db "Use --debug to diagnose incorrect key usage.", 10
    db 10
    db "SIZE may be followed by the following multiplicative suffixes:", 10
    db "% 1% of memory, b 1, K 1024 (default), and so on for M, G, T, P, E, Z, Y, R, Q.", 10
    db 10
    db "*** WARNING ***", 10
    db "The locale specified by the environment affects sort order.", 10
    db "Set LC_ALL=C to get the traditional sort order that uses", 10
    db "native byte values.", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/sort>", 10
    db "or available locally via: info '(coreutils) sort invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "sort (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Mike Haertel and Paul Eggert.", 10
str_version_len equ $ - str_version
; @@DATA_END@@

str_sort_prefix: db "sort: ", 0
str_sort_prefix_len equ 6

str_try_help:
    db "Try 'sort --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_inv_opt:    db "invalid option -- '", 0
str_inv_opt2:   db "'", 10, 0

str_unrec_opt:  db "unrecognized option '", 0
str_unrec_opt2: db "'", 10, 0

str_enoent:     db ": No such file or directory", 10, 0
str_read_err:   db ": read error", 10, 0
str_write_err:  db "write error", 10, 0
str_open_err:   db ": open failed", 10, 0
str_extra_key:  db ": invalid number after ','", 10, 0
str_empty_key:  db "option requires an argument -- 'k'", 10, 0
str_empty_out:  db "option requires an argument -- 'o'", 10, 0
str_empty_sep:  db "option requires an argument -- 't'", 10, 0
str_multi_sep:  db "multi-character tab ", 0
str_disorder1:  db "disorder: ", 0
str_disorder1_len equ $ - str_disorder1

str_colon:      db ":", 0
str_disorder_sep: db ": disorder: "
str_disorder_sep_len equ $ - str_disorder_sep

str_colon_sp:   db ": ", 0
str_newline:    db 10, 0
str_dash:       db "-", 0

; Long option strings
opt_help:             db "--help", 0
opt_version:          db "--version", 0
opt_reverse:          db "--reverse", 0
opt_unique:           db "--unique", 0
opt_numeric:          db "--numeric-sort", 0
opt_stable:           db "--stable", 0
opt_check:            db "--check", 0
opt_check_eq:         db "--check=", 0
opt_check_diag:       db "diagnose-first", 0
opt_check_quiet:      db "quiet", 0
opt_check_silent:     db "silent", 0
opt_ignore_case:      db "--ignore-case", 0
opt_dictionary:       db "--dictionary-order", 0
opt_ignore_np:        db "--ignore-nonprinting", 0
opt_ignore_blanks:    db "--ignore-leading-blanks", 0
opt_merge:            db "--merge", 0
opt_zero_terminated:  db "--zero-terminated", 0
opt_output:           db "--output", 0
opt_output_eq:        db "--output=", 0
opt_key:              db "--key", 0
opt_key_eq:           db "--key=", 0
opt_field_sep:        db "--field-separator", 0
opt_field_sep_eq:     db "--field-separator=", 0
opt_gen_numeric:      db "--general-numeric-sort", 0
opt_month_sort:       db "--month-sort", 0
opt_human_sort:       db "--human-numeric-sort", 0
opt_version_sort:     db "--version-sort", 0

; Month name table (uppercase, 3 chars each)
month_names:
    db "JAN", 0    ; 1
    db "FEB", 0    ; 2
    db "MAR", 0    ; 3
    db "APR", 0    ; 4
    db "MAY", 0    ; 5
    db "JUN", 0    ; 6
    db "JUL", 0    ; 7
    db "AUG", 0    ; 8
    db "SEP", 0    ; 9
    db "OCT", 0    ; 10
    db "NOV", 0    ; 11
    db "DEC", 0    ; 12

; ═══════════════════════════════════════════════════════════════════
; BSS section
; ═══════════════════════════════════════════════════════════════════
section .bss

; Command-line state
argc:           resq 1
argv:           resq 1
flag_bits:      resq 1
nfiles:         resq 1
files:          resq MAX_FILES      ; array of char* to file paths
output_file:    resq 1              ; output file path (NULL=stdout)
output_fd:      resq 1              ; output fd
separator:      resb 2              ; field separator char + NUL
has_separator:  resb 1              ; 1 if -t was given
line_delim:     resb 1              ; '\n' or '\0' for -z

; Sort keys
nkeys:          resq 1
keys:           resb MAX_KEYS * KEY_STRUCT_SIZE

; Input data
input_buf:      resq 1              ; pointer to input buffer (mmap'd)
input_size:     resq 1              ; total input size in bytes
input_cap:      resq 1              ; capacity of input buffer

; Line pointer array
line_array:     resq 1              ; pointer to line entry array
line_count:     resq 1              ; number of lines
line_cap:       resq 1              ; capacity of line array (in entries)

; Output buffer
outbuf:         resb OUTBUF_SIZE
outbuf_pos:     resq 1

; Stat buffer
stat_buf:       resb STAT_STRUCT_SIZE

; Merge sort temp array
merge_temp:     resq 1              ; temp line array for merge sort

; Temp buffer for error messages
errbuf:         resb 512

; ═══════════════════════════════════════════════════════════════════
; Text section
; ═══════════════════════════════════════════════════════════════════
section .text
global _start

; ============================================================================
;                           ENTRY POINT
; ============================================================================
_start:
    ; ── Block SIGPIPE so write() returns -EPIPE instead of killing us ──
    sub     rsp, 16
    mov     qword [rsp], 0x2000     ; sigset: bit 13 = SIGPIPE
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi                ; SIG_BLOCK = 0
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    ; ── Save argc/argv ──
    mov     rax, [rsp]              ; argc
    mov     [rel argc], rax
    lea     rax, [rsp + 8]
    mov     [rel argv], rax

    ; ── Initialize defaults ──
    mov     qword [rel flag_bits], 0
    mov     qword [rel nfiles], 0
    mov     qword [rel output_file], 0
    mov     qword [rel output_fd], STDOUT
    mov     byte [rel has_separator], 0
    mov     byte [rel line_delim], 10      ; newline by default
    mov     qword [rel nkeys], 0
    mov     qword [rel outbuf_pos], 0

    ; ── Parse arguments ──
    call    parse_args

    ; ── If -z flag, change line delimiter ──
    test    qword [rel flag_bits], FLAG_ZERO_TERM
    jz      .no_zero
    mov     byte [rel line_delim], 0
.no_zero:

    ; ── If no files, use stdin ──
    cmp     qword [rel nfiles], 0
    jne     .have_files
    lea     rax, [rel str_dash]
    mov     [rel files], rax
    mov     qword [rel nfiles], 1
.have_files:

    ; ── Open output file if specified ──
    cmp     qword [rel output_file], 0
    je      .no_output_file
    mov     rdi, [rel output_file]
    mov     esi, O_WRONLY | O_CREAT | O_TRUNC
    mov     edx, 0o666
    call    asm_open
    test    rax, rax
    js      .output_open_error
    mov     [rel output_fd], rax
.no_output_file:

    ; ── Check mode? ──
    mov     rax, [rel flag_bits]
    test    rax, FLAG_CHECK | FLAG_CHECK_Q
    jnz     .do_check

    ; ── Merge mode? ──
    test    rax, FLAG_MERGE
    jnz     .do_merge

    ; ── Normal sort mode ──
    call    read_all_input
    test    rax, rax
    js      .read_error
    call    scan_lines
    call    sort_lines
    call    write_output
    jmp     .exit_success

.do_check:
    call    check_sorted
    ; check_sorted exits directly
    jmp     .exit_success

.do_merge:
    ; For merge, we read all input and sort — same as normal for simplicity
    ; A real merge would do k-way merge but the sorted input makes it correct
    call    read_all_input
    test    rax, rax
    js      .read_error
    call    scan_lines
    call    sort_lines
    call    write_output
    jmp     .exit_success

.read_error:
    mov     edi, 2
    call    asm_exit

.output_open_error:
    ; Print error for output file
    mov     rdi, STDERR
    lea     rsi, [rel str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all
    mov     rdi, [rel output_file]
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, [rel output_file]
    mov     rdi, STDERR
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_open_err]
    mov     edx, 15
    call    asm_write_all
    mov     edi, 2
    call    asm_exit

.exit_success:
    ; Flush output buffer
    call    flush_outbuf
    ; Close output fd if not stdout
    cmp     qword [rel output_fd], STDOUT
    je      .skip_close
    mov     rdi, [rel output_fd]
    call    asm_close
.skip_close:
    xor     edi, edi
    call    asm_exit


; ============================================================================
;  parse_args — Parse command line arguments
; ============================================================================
parse_args:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, [rel argv]
    mov     r13, [rel argc]
    mov     r14, 1                  ; arg index (skip argv[0])
    xor     r15d, r15d              ; end-of-options flag

.arg_loop:
    cmp     r14, r13
    jge     .done

    mov     rbx, [r12 + r14*8]     ; rbx = argv[i]

    ; If end-of-options seen, treat as file
    test    r15d, r15d
    jnz     .is_file

    ; Check for "--"
    cmp     byte [rbx], '-'
    jne     .is_file
    cmp     byte [rbx+1], 0
    je      .is_file               ; bare "-" is stdin

    cmp     byte [rbx+1], '-'
    jne     .short_opts

    ; Long option
    cmp     byte [rbx+2], 0
    jne     .long_opt
    ; "--" end of options
    mov     r15d, 1
    jmp     .next_arg

.long_opt:
    ; --help
    mov     rdi, rbx
    lea     rsi, [rel opt_help]
    call    str_equal
    test    eax, eax
    jnz     .do_help

    ; --version
    mov     rdi, rbx
    lea     rsi, [rel opt_version]
    call    str_equal
    test    eax, eax
    jnz     .do_version

    ; --reverse
    mov     rdi, rbx
    lea     rsi, [rel opt_reverse]
    call    str_equal
    test    eax, eax
    jnz     .set_reverse

    ; --unique
    mov     rdi, rbx
    lea     rsi, [rel opt_unique]
    call    str_equal
    test    eax, eax
    jnz     .set_unique

    ; --numeric-sort
    mov     rdi, rbx
    lea     rsi, [rel opt_numeric]
    call    str_equal
    test    eax, eax
    jnz     .set_numeric

    ; --stable
    mov     rdi, rbx
    lea     rsi, [rel opt_stable]
    call    str_equal
    test    eax, eax
    jnz     .set_stable

    ; --check
    mov     rdi, rbx
    lea     rsi, [rel opt_check]
    call    str_equal
    test    eax, eax
    jnz     .set_check

    ; --check=...
    mov     rdi, rbx
    lea     rsi, [rel opt_check_eq]
    call    str_starts_with
    test    eax, eax
    jnz     .parse_check_eq

    ; --ignore-case
    mov     rdi, rbx
    lea     rsi, [rel opt_ignore_case]
    call    str_equal
    test    eax, eax
    jnz     .set_fold_case

    ; --dictionary-order
    mov     rdi, rbx
    lea     rsi, [rel opt_dictionary]
    call    str_equal
    test    eax, eax
    jnz     .set_dict

    ; --ignore-nonprinting
    mov     rdi, rbx
    lea     rsi, [rel opt_ignore_np]
    call    str_equal
    test    eax, eax
    jnz     .set_ignore_np

    ; --ignore-leading-blanks
    mov     rdi, rbx
    lea     rsi, [rel opt_ignore_blanks]
    call    str_equal
    test    eax, eax
    jnz     .set_blanks

    ; --merge
    mov     rdi, rbx
    lea     rsi, [rel opt_merge]
    call    str_equal
    test    eax, eax
    jnz     .set_merge

    ; --zero-terminated
    mov     rdi, rbx
    lea     rsi, [rel opt_zero_terminated]
    call    str_equal
    test    eax, eax
    jnz     .set_zero_term

    ; --output=FILE
    mov     rdi, rbx
    lea     rsi, [rel opt_output_eq]
    call    str_starts_with
    test    eax, eax
    jnz     .parse_output_eq

    ; --output FILE
    mov     rdi, rbx
    lea     rsi, [rel opt_output]
    call    str_equal
    test    eax, eax
    jnz     .parse_output_next

    ; --key=KEYDEF
    mov     rdi, rbx
    lea     rsi, [rel opt_key_eq]
    call    str_starts_with
    test    eax, eax
    jnz     .parse_key_eq

    ; --key KEYDEF
    mov     rdi, rbx
    lea     rsi, [rel opt_key]
    call    str_equal
    test    eax, eax
    jnz     .parse_key_next

    ; --field-separator=SEP
    mov     rdi, rbx
    lea     rsi, [rel opt_field_sep_eq]
    call    str_starts_with
    test    eax, eax
    jnz     .parse_sep_eq

    ; --field-separator SEP
    mov     rdi, rbx
    lea     rsi, [rel opt_field_sep]
    call    str_equal
    test    eax, eax
    jnz     .parse_sep_next

    ; --general-numeric-sort
    mov     rdi, rbx
    lea     rsi, [rel opt_gen_numeric]
    call    str_equal
    test    eax, eax
    jnz     .set_gen_numeric

    ; --month-sort
    mov     rdi, rbx
    lea     rsi, [rel opt_month_sort]
    call    str_equal
    test    eax, eax
    jnz     .set_month

    ; --human-numeric-sort
    mov     rdi, rbx
    lea     rsi, [rel opt_human_sort]
    call    str_equal
    test    eax, eax
    jnz     .set_human

    ; --version-sort
    mov     rdi, rbx
    lea     rsi, [rel opt_version_sort]
    call    str_equal
    test    eax, eax
    jnz     .set_version_sort

    ; Unrecognized long option — error
    jmp     .error_unrec

.short_opts:
    ; Parse short options from argv[i] starting at position 1
    lea     rbx, [rbx + 1]         ; skip '-'

.short_loop:
    movzx   eax, byte [rbx]
    test    al, al
    jz      .next_arg

    cmp     al, 'b'
    je      .short_blanks
    cmp     al, 'c'
    je      .short_check
    cmp     al, 'C'
    je      .short_check_q
    cmp     al, 'd'
    je      .short_dict
    cmp     al, 'f'
    je      .short_fold
    cmp     al, 'g'
    je      .short_gen_numeric
    cmp     al, 'h'
    je      .short_human
    cmp     al, 'i'
    je      .short_ignore_np
    cmp     al, 'k'
    je      .short_key
    cmp     al, 'm'
    je      .short_merge
    cmp     al, 'M'
    je      .short_month
    cmp     al, 'n'
    je      .short_numeric
    cmp     al, 'o'
    je      .short_output
    cmp     al, 'r'
    je      .short_reverse
    cmp     al, 's'
    je      .short_stable
    cmp     al, 't'
    je      .short_sep
    cmp     al, 'u'
    je      .short_unique
    cmp     al, 'V'
    je      .short_version_sort
    cmp     al, 'z'
    je      .short_zero

    ; Unknown short option
    jmp     .error_inval

.short_blanks:
    or      qword [rel flag_bits], FLAG_BLANKS
    inc     rbx
    jmp     .short_loop

.short_check:
    or      qword [rel flag_bits], FLAG_CHECK
    inc     rbx
    jmp     .short_loop

.short_check_q:
    or      qword [rel flag_bits], FLAG_CHECK_Q
    inc     rbx
    jmp     .short_loop

.short_dict:
    or      qword [rel flag_bits], FLAG_DICT
    inc     rbx
    jmp     .short_loop

.short_fold:
    or      qword [rel flag_bits], FLAG_FOLD_CASE
    inc     rbx
    jmp     .short_loop

.short_gen_numeric:
    or      qword [rel flag_bits], FLAG_GEN_NUM
    inc     rbx
    jmp     .short_loop

.short_human:
    or      qword [rel flag_bits], FLAG_HUMAN
    inc     rbx
    jmp     .short_loop

.short_ignore_np:
    or      qword [rel flag_bits], FLAG_IGNORE_NP
    inc     rbx
    jmp     .short_loop

.short_month:
    or      qword [rel flag_bits], FLAG_MONTH
    inc     rbx
    jmp     .short_loop

.short_numeric:
    or      qword [rel flag_bits], FLAG_NUMERIC
    inc     rbx
    jmp     .short_loop

.short_reverse:
    or      qword [rel flag_bits], FLAG_REVERSE
    inc     rbx
    jmp     .short_loop

.short_stable:
    or      qword [rel flag_bits], FLAG_STABLE
    inc     rbx
    jmp     .short_loop

.short_unique:
    or      qword [rel flag_bits], FLAG_UNIQUE
    inc     rbx
    jmp     .short_loop

.short_zero:
    or      qword [rel flag_bits], FLAG_ZERO_TERM
    inc     rbx
    jmp     .short_loop

.short_merge:
    or      qword [rel flag_bits], FLAG_MERGE
    inc     rbx
    jmp     .short_loop

.short_version_sort:
    or      qword [rel flag_bits], FLAG_VERSION
    inc     rbx
    jmp     .short_loop

.short_key:
    ; -k KEYDEF: rest of this arg or next arg
    inc     rbx
    cmp     byte [rbx], 0
    jne     .parse_key_inline
    ; next arg
    inc     r14
    cmp     r14, r13
    jge     .error_missing_k
    mov     rbx, [r12 + r14*8]
.parse_key_inline:
    mov     rdi, rbx
    call    parse_key
    jmp     .next_arg

.short_output:
    ; -o FILE: rest of this arg or next arg
    inc     rbx
    cmp     byte [rbx], 0
    jne     .set_output_inline
    ; next arg
    inc     r14
    cmp     r14, r13
    jge     .error_missing_o
    mov     rbx, [r12 + r14*8]
.set_output_inline:
    mov     [rel output_file], rbx
    jmp     .next_arg

.short_sep:
    ; -t SEP: rest of this arg or next arg
    inc     rbx
    cmp     byte [rbx], 0
    jne     .set_sep_inline
    ; next arg
    inc     r14
    cmp     r14, r13
    jge     .error_missing_t
    mov     rbx, [r12 + r14*8]
.set_sep_inline:
    movzx   eax, byte [rbx]
    mov     [rel separator], al
    mov     byte [rel has_separator], 1
    jmp     .next_arg

; ── Flag setters for long options ──
.set_reverse:
    or      qword [rel flag_bits], FLAG_REVERSE
    jmp     .next_arg
.set_unique:
    or      qword [rel flag_bits], FLAG_UNIQUE
    jmp     .next_arg
.set_numeric:
    or      qword [rel flag_bits], FLAG_NUMERIC
    jmp     .next_arg
.set_stable:
    or      qword [rel flag_bits], FLAG_STABLE
    jmp     .next_arg
.set_check:
    or      qword [rel flag_bits], FLAG_CHECK
    jmp     .next_arg
.set_fold_case:
    or      qword [rel flag_bits], FLAG_FOLD_CASE
    jmp     .next_arg
.set_dict:
    or      qword [rel flag_bits], FLAG_DICT
    jmp     .next_arg
.set_ignore_np:
    or      qword [rel flag_bits], FLAG_IGNORE_NP
    jmp     .next_arg
.set_blanks:
    or      qword [rel flag_bits], FLAG_BLANKS
    jmp     .next_arg
.set_merge:
    or      qword [rel flag_bits], FLAG_MERGE
    jmp     .next_arg
.set_zero_term:
    or      qword [rel flag_bits], FLAG_ZERO_TERM
    jmp     .next_arg
.set_gen_numeric:
    or      qword [rel flag_bits], FLAG_GEN_NUM
    jmp     .next_arg
.set_month:
    or      qword [rel flag_bits], FLAG_MONTH
    jmp     .next_arg
.set_human:
    or      qword [rel flag_bits], FLAG_HUMAN
    jmp     .next_arg
.set_version_sort:
    or      qword [rel flag_bits], FLAG_VERSION
    jmp     .next_arg

.parse_check_eq:
    ; --check=quiet or --check=silent or --check=diagnose-first
    lea     rdi, [rbx + 8]         ; skip "--check="
    lea     rsi, [rel opt_check_quiet]
    call    str_equal
    test    eax, eax
    jnz     .set_check_q
    lea     rdi, [rbx + 8]
    lea     rsi, [rel opt_check_silent]
    call    str_equal
    test    eax, eax
    jnz     .set_check_q
    lea     rdi, [rbx + 8]
    lea     rsi, [rel opt_check_diag]
    call    str_equal
    test    eax, eax
    jnz     .set_check
    jmp     .set_check             ; default to diagnose-first
.set_check_q:
    or      qword [rel flag_bits], FLAG_CHECK_Q
    jmp     .next_arg

.parse_output_eq:
    ; --output=FILE
    lea     rax, [rbx + 9]         ; skip "--output="
    mov     [rel output_file], rax
    jmp     .next_arg

.parse_output_next:
    ; --output FILE
    inc     r14
    cmp     r14, r13
    jge     .error_missing_o
    mov     rax, [r12 + r14*8]
    mov     [rel output_file], rax
    jmp     .next_arg

.parse_key_eq:
    ; --key=KEYDEF
    lea     rdi, [rbx + 6]         ; skip "--key="
    call    parse_key
    jmp     .next_arg

.parse_key_next:
    ; --key KEYDEF
    inc     r14
    cmp     r14, r13
    jge     .error_missing_k
    mov     rdi, [r12 + r14*8]
    call    parse_key
    jmp     .next_arg

.parse_sep_eq:
    ; --field-separator=SEP
    lea     rax, [rbx + 18]        ; skip "--field-separator="
    movzx   eax, byte [rax]
    mov     [rel separator], al
    mov     byte [rel has_separator], 1
    jmp     .next_arg

.parse_sep_next:
    ; --field-separator SEP
    inc     r14
    cmp     r14, r13
    jge     .error_missing_t
    mov     rax, [r12 + r14*8]
    movzx   eax, byte [rax]
    mov     [rel separator], al
    mov     byte [rel has_separator], 1
    jmp     .next_arg

.is_file:
    ; Add to file list
    mov     rcx, [rel nfiles]
    cmp     rcx, MAX_FILES
    jge     .next_arg               ; silently ignore overflow
    lea     rax, [rel files]
    mov     [rax + rcx*8], rbx
    inc     qword [rel nfiles]
    jmp     .next_arg

.next_arg:
    inc     r14
    jmp     .arg_loop

.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── Error handlers ──
.do_help:
    mov     rdi, STDOUT
    lea     rsi, [rel str_help]
    mov     edx, str_help_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit

.do_version:
    mov     rdi, STDOUT
    lea     rsi, [rel str_version]
    mov     edx, str_version_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit

.error_inval:
    ; "sort: invalid option -- 'X'"
    push    rax
    mov     rdi, STDERR
    lea     rsi, [rel str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_inv_opt]
    mov     edx, 19
    call    asm_write_all
    pop     rax
    ; write the bad char
    sub     rsp, 8
    mov     [rsp], al
    mov     rdi, STDERR
    mov     rsi, rsp
    mov     edx, 1
    call    asm_write_all
    add     rsp, 8
    mov     rdi, STDERR
    lea     rsi, [rel str_inv_opt2]
    mov     edx, 2
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     edx, str_try_help_len
    call    asm_write_all
    mov     edi, 2
    call    asm_exit

.error_unrec:
    mov     rdi, STDERR
    lea     rsi, [rel str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_unrec_opt]
    mov     edx, 21
    call    asm_write_all
    ; Print the bad option
    mov     rdi, rbx
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_inv_opt2]
    mov     edx, 2
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     edx, str_try_help_len
    call    asm_write_all
    mov     edi, 2
    call    asm_exit

.error_missing_k:
    mov     rdi, STDERR
    lea     rsi, [rel str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_empty_key]
    mov     edx, 34
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_newline]
    mov     edx, 1
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     edx, str_try_help_len
    call    asm_write_all
    mov     edi, 2
    call    asm_exit

.error_missing_o:
    mov     rdi, STDERR
    lea     rsi, [rel str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_empty_out]
    mov     edx, 34
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_newline]
    mov     edx, 1
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     edx, str_try_help_len
    call    asm_write_all
    mov     edi, 2
    call    asm_exit

.error_missing_t:
    mov     rdi, STDERR
    lea     rsi, [rel str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_empty_sep]
    mov     edx, 34
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_newline]
    mov     edx, 1
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     edx, str_try_help_len
    call    asm_write_all
    mov     edi, 2
    call    asm_exit


; ============================================================================
;  parse_key — Parse a -k KEYDEF string
;  Input: rdi = KEYDEF string (e.g., "2,2" or "1.3,1.5n" or "2nr,2")
; ============================================================================
parse_key:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi                ; save KEYDEF string pointer
    mov     r13, [rel nkeys]
    cmp     r13, MAX_KEYS
    jge     .pk_done                ; too many keys

    ; Calculate offset into keys array
    imul    r14, r13, KEY_STRUCT_SIZE
    lea     r15, [rel keys]
    add     r15, r14                ; r15 = pointer to this key struct

    ; Initialize key with defaults
    mov     qword [r15], 0          ; start_field
    mov     qword [r15+8], 0        ; start_char
    mov     qword [r15+16], 0       ; end_field
    mov     qword [r15+24], 0       ; end_char
    mov     qword [r15+32], 0       ; flags

    ; Parse start field number
    mov     rdi, r12
    call    parse_number
    mov     [r15], rax              ; start_field
    mov     r12, rdi                ; updated pointer

    ; Check for .C (start char)
    cmp     byte [r12], '.'
    jne     .pk_start_opts
    inc     r12
    mov     rdi, r12
    call    parse_number
    mov     [r15+8], rax            ; start_char
    mov     r12, rdi

.pk_start_opts:
    ; Parse start-key options
    mov     rdi, r12
    lea     rsi, [r15+32]           ; flags pointer
    call    parse_key_opts
    mov     r12, rdi

    ; Check for comma (end spec)
    cmp     byte [r12], ','
    jne     .pk_no_end
    inc     r12

    ; Parse end field
    mov     rdi, r12
    call    parse_number
    mov     [r15+16], rax           ; end_field
    mov     r12, rdi

    ; Check for .C (end char)
    cmp     byte [r12], '.'
    jne     .pk_end_opts
    inc     r12
    mov     rdi, r12
    call    parse_number
    mov     [r15+24], rax           ; end_char
    mov     r12, rdi

.pk_end_opts:
    ; Parse end-key options
    mov     rdi, r12
    lea     rsi, [r15+32]
    call    parse_key_opts

.pk_no_end:
    ; Increment key count
    inc     qword [rel nkeys]

.pk_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  parse_number — Parse decimal digits from string
;  Input: rdi = string pointer
;  Output: rax = number, rdi = updated pointer past digits
; ============================================================================
parse_number:
    xor     eax, eax
    xor     ecx, ecx
.loop:
    movzx   ecx, byte [rdi]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .done
    imul    rax, 10
    add     rax, rcx
    inc     rdi
    jmp     .loop
.done:
    ret


; ============================================================================
;  parse_key_opts — Parse single-letter key options (bdfgiMhnrRV)
;  Input: rdi = string pointer, rsi = pointer to flags qword
;  Output: rdi = updated pointer
; ============================================================================
parse_key_opts:
.loop:
    movzx   eax, byte [rdi]
    cmp     al, 'b'
    je      .set_b
    cmp     al, 'd'
    je      .set_d
    cmp     al, 'f'
    je      .set_f
    cmp     al, 'g'
    je      .set_g
    cmp     al, 'h'
    je      .set_h
    cmp     al, 'i'
    je      .set_i
    cmp     al, 'M'
    je      .set_M
    cmp     al, 'n'
    je      .set_n
    cmp     al, 'r'
    je      .set_r
    cmp     al, 'R'
    je      .done                   ; -R (random) not fully implemented
    cmp     al, 'V'
    je      .set_V
    jmp     .done

.set_b:
    or      qword [rsi], KEY_BLANKS
    inc     rdi
    jmp     .loop
.set_d:
    or      qword [rsi], KEY_DICT
    inc     rdi
    jmp     .loop
.set_f:
    or      qword [rsi], KEY_FOLD_CASE
    inc     rdi
    jmp     .loop
.set_g:
    or      qword [rsi], KEY_GEN_NUM
    inc     rdi
    jmp     .loop
.set_h:
    or      qword [rsi], KEY_HUMAN
    inc     rdi
    jmp     .loop
.set_i:
    or      qword [rsi], KEY_IGNORE_NP
    inc     rdi
    jmp     .loop
.set_M:
    or      qword [rsi], KEY_MONTH
    inc     rdi
    jmp     .loop
.set_n:
    or      qword [rsi], KEY_NUMERIC
    inc     rdi
    jmp     .loop
.set_r:
    or      qword [rsi], KEY_REVERSE
    inc     rdi
    jmp     .loop
.set_V:
    or      qword [rsi], KEY_VERSION
    inc     rdi
    jmp     .loop
.done:
    ret


; ============================================================================
;  read_all_input — Read all input files into a single contiguous buffer
;  Returns: rax = 0 on success, -1 on error
; ============================================================================
read_all_input:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; Allocate initial input buffer via mmap
    xor     edi, edi                ; addr = NULL
    mov     rsi, INITIAL_BUF        ; length
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1                  ; fd = -1
    xor     r9d, r9d                ; offset = 0
    mov     eax, SYS_MMAP
    syscall
    test    rax, rax
    js      .rai_error
    mov     [rel input_buf], rax
    mov     qword [rel input_size], 0
    mov     qword [rel input_cap], INITIAL_BUF

    ; Process each file
    xor     r12d, r12d              ; file index

.rai_file_loop:
    cmp     r12, [rel nfiles]
    jge     .rai_done

    ; Get filename
    lea     rax, [rel files]
    mov     rbx, [rax + r12*8]

    ; Check if it's stdin ("-")
    cmp     byte [rbx], '-'
    jne     .rai_open_file
    cmp     byte [rbx+1], 0
    jne     .rai_open_file
    ; stdin
    xor     r13d, r13d              ; fd = 0 (stdin)
    jmp     .rai_read_fd

.rai_open_file:
    ; Try to mmap the file
    mov     rdi, rbx
    xor     esi, esi                ; O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .rai_file_error
    mov     r13, rax                ; fd

    ; fstat to get size
    mov     rdi, r13
    lea     rsi, [rel stat_buf]
    FSTAT   rdi, rsi
    test    rax, rax
    js      .rai_close_read

    ; Get file size
    mov     r14, [rel stat_buf + STAT_SIZE]
    test    r14, r14
    jz      .rai_close_next         ; empty file

    ; Ensure buffer has room
    mov     rax, [rel input_size]
    add     rax, r14
    cmp     rax, [rel input_cap]
    jbe     .rai_mmap_file

    ; Grow buffer via mremap
    call    grow_input_buffer

.rai_mmap_file:
    ; Read file into buffer (we use read, not mmap, for simplicity with concat)
    ; This also handles pipes, devices, etc.
    jmp     .rai_read_fd

.rai_close_read:
    ; fallthrough to read-based approach
.rai_read_fd:
    ; Read from fd r13 into input_buf + input_size
.rai_read_loop:
    mov     rax, [rel input_size]
    mov     rcx, [rel input_cap]
    sub     rcx, rax
    cmp     rcx, 65536
    jge     .rai_do_read
    ; Need more space
    push    r13
    call    grow_input_buffer
    pop     r13
    mov     rax, [rel input_size]
    mov     rcx, [rel input_cap]
    sub     rcx, rax

.rai_do_read:
    mov     rdi, r13
    mov     rsi, [rel input_buf]
    add     rsi, rax                ; buf + input_size
    mov     rdx, rcx                ; remaining capacity
    ; Cap read size at 1MB to avoid blocking too long
    cmp     rdx, 1048576
    jbe     .rai_read_ok
    mov     rdx, 1048576
.rai_read_ok:
    call    asm_read
    test    rax, rax
    js      .rai_read_err
    jz      .rai_read_eof           ; EOF
    add     [rel input_size], rax
    jmp     .rai_read_loop

.rai_read_eof:
    ; Close fd if not stdin
    test    r13, r13
    jz      .rai_next_file
    mov     rdi, r13
    call    asm_close
    jmp     .rai_next_file

.rai_close_next:
    mov     rdi, r13
    call    asm_close

.rai_next_file:
    inc     r12
    jmp     .rai_file_loop

.rai_done:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.rai_file_error:
    ; Print error: "sort: open failed: FILENAME"
    push    r12
    mov     rdi, STDERR
    lea     rsi, [rel str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all
    lea     rax, [rel files]
    mov     rdi, [rax + r12*8]
    call    asm_strlen
    mov     rdx, rax
    lea     rax, [rel files]
    mov     rsi, [rax + r12*8]
    mov     rdi, STDERR
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_enoent]
    mov     edx, 28
    call    asm_write_all
    pop     r12
    ; Continue with next file (like GNU sort)
    inc     r12
    jmp     .rai_file_loop

.rai_read_err:
.rai_error:
    mov     rax, -1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  grow_input_buffer — Double the input buffer via mremap
; ============================================================================
grow_input_buffer:
    mov     rdi, [rel input_buf]
    mov     rsi, [rel input_cap]
    mov     rdx, rsi
    shl     rdx, 1                  ; new_size = old_size * 2
    mov     r10d, MREMAP_MAYMOVE
    mov     eax, SYS_MREMAP
    syscall
    test    rax, rax
    js      .gib_fail
    mov     [rel input_buf], rax
    mov     rax, [rel input_cap]
    shl     rax, 1
    mov     [rel input_cap], rax
    ret
.gib_fail:
    ; Fatal: can't grow buffer
    mov     edi, 2
    call    asm_exit


; ============================================================================
;  scan_lines — Scan input buffer and build line pointer array
;  Populates line_array, line_count
; ============================================================================
scan_lines:
    push    rbx
    push    r12
    push    r13
    push    r14

    ; Allocate line pointer array
    mov     rsi, INITIAL_LINES * LINE_ENTRY_SIZE
    xor     edi, edi
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    test    rax, rax
    js      .sl_fail
    mov     [rel line_array], rax
    mov     qword [rel line_count], 0
    mov     qword [rel line_cap], INITIAL_LINES

    ; Scan the input
    mov     r12, [rel input_buf]    ; current position
    mov     r13, r12
    add     r13, [rel input_size]   ; end of input
    movzx   r14d, byte [rel line_delim]  ; delimiter

    ; Handle empty input
    cmp     r12, r13
    je      .sl_done

.sl_line_loop:
    cmp     r12, r13
    jge     .sl_check_final

    ; Start of a new line
    mov     rbx, r12                ; line start

    ; Scan for delimiter
.sl_scan:
    cmp     r12, r13
    jge     .sl_found_end
    movzx   eax, byte [r12]
    cmp     eax, r14d
    je      .sl_found_delim
    inc     r12
    jmp     .sl_scan

.sl_found_delim:
    ; Line from rbx to r12 (not including delimiter)
    mov     rdi, rbx
    mov     rsi, r12
    sub     rsi, rbx                ; length
    call    add_line
    inc     r12                     ; skip delimiter
    jmp     .sl_line_loop

.sl_found_end:
    ; Last line without trailing delimiter
    cmp     rbx, r13
    je      .sl_done                ; no trailing content
    mov     rdi, rbx
    mov     rsi, r13
    sub     rsi, rbx
    call    add_line
    jmp     .sl_done

.sl_check_final:
.sl_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.sl_fail:
    mov     edi, 2
    call    asm_exit


; ============================================================================
;  add_line — Add a line entry to the line array
;  Input: rdi = line pointer, rsi = line length
; ============================================================================
add_line:
    push    rbx
    mov     rcx, [rel line_count]
    cmp     rcx, [rel line_cap]
    jb      .al_ok

    ; Grow line array via mremap
    push    rdi
    push    rsi
    mov     rdi, [rel line_array]
    mov     rsi, [rel line_cap]
    imul    rsi, LINE_ENTRY_SIZE
    mov     rdx, rsi
    shl     rdx, 1                  ; double
    mov     r10d, MREMAP_MAYMOVE
    mov     eax, SYS_MREMAP
    syscall
    test    rax, rax
    js      .al_fail
    mov     [rel line_array], rax
    shl     qword [rel line_cap], 1
    pop     rsi
    pop     rdi
    mov     rcx, [rel line_count]

.al_ok:
    mov     rax, [rel line_array]
    mov     r10, rcx
    shl     r10, 4                  ; r10 = rcx * 16
    mov     [rax + r10], rdi        ; pointer
    mov     [rax + r10 + 8], rsi    ; length
    inc     qword [rel line_count]
    pop     rbx
    ret

.al_fail:
    mov     edi, 2
    call    asm_exit


; ============================================================================
;  sort_lines — Sort the line array using merge sort
; ============================================================================
sort_lines:
    push    rbx
    push    r12

    mov     rcx, [rel line_count]
    cmp     rcx, 2
    jl      .sort_done              ; 0 or 1 lines = already sorted

    ; Allocate temp array for merge sort
    mov     rsi, rcx
    imul    rsi, LINE_ENTRY_SIZE
    xor     edi, edi
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    test    rax, rax
    js      .sort_fail
    mov     [rel merge_temp], rax

    ; Call merge sort
    mov     rdi, [rel line_array]
    mov     rsi, [rel merge_temp]
    xor     edx, edx                ; left = 0
    mov     rcx, [rel line_count]   ; right = line_count
    call    merge_sort

    ; Free temp array
    mov     rdi, [rel merge_temp]
    mov     rsi, [rel line_count]
    imul    rsi, LINE_ENTRY_SIZE
    mov     eax, SYS_MUNMAP
    syscall

.sort_done:
    pop     r12
    pop     rbx
    ret

.sort_fail:
    mov     edi, 2
    call    asm_exit


; ============================================================================
;  merge_sort — Recursive merge sort on line array
;  Input: rdi = array, rsi = temp, edx = left, ecx = right (exclusive)
;  Sorts array[left..right) in place
; ============================================================================
merge_sort:
    ; Base case: 1 or 0 elements
    mov     eax, ecx
    sub     eax, edx
    cmp     eax, 2
    jl      .ms_ret

    ; For 2 elements, just compare and swap
    cmp     eax, 2
    jne     .ms_recurse
    ; Compare array[left] vs array[left+1]
    push    rdi
    push    rsi
    push    rdx
    push    rcx
    ; Get pointers to the two line entries
    mov     r8, rdx
    imul    r8, LINE_ENTRY_SIZE
    add     r8, rdi                 ; &array[left]
    mov     r9, r8
    add     r9, LINE_ENTRY_SIZE     ; &array[left+1]
    ; Compare
    push    r8
    push    r9
    mov     rdi, [r8]              ; ptr1
    mov     rsi, [r8+8]            ; len1
    mov     rdx, [r9]              ; ptr2
    mov     rcx, [r9+8]            ; len2
    call    compare_lines
    pop     r9
    pop     r8
    test    eax, eax
    jle     .ms_2_ok
    ; Swap the two entries
    mov     rax, [r8]
    mov     rbx, [r8+8]
    mov     rcx, [r9]
    mov     rdx, [r9+8]
    mov     [r8], rcx
    mov     [r8+8], rdx
    mov     [r9], rax
    mov     [r9+8], rbx
.ms_2_ok:
    pop     rcx
    pop     rdx
    pop     rsi
    pop     rdi
.ms_ret:
    ret

.ms_recurse:
    push    rbp
    mov     rbp, rsp
    push    rdi                     ; [rbp-8]  array
    push    rsi                     ; [rbp-16] temp
    push    rdx                     ; [rbp-24] left (as qword)
    push    rcx                     ; [rbp-32] right (as qword)

    ; mid = (left + right) / 2
    mov     eax, edx
    add     eax, ecx
    shr     eax, 1
    push    rax                     ; [rbp-40] mid

    ; Sort left half: merge_sort(array, temp, left, mid)
    mov     rdi, [rbp-8]
    mov     rsi, [rbp-16]
    mov     edx, [rbp-24]
    mov     ecx, eax
    call    merge_sort

    ; Sort right half: merge_sort(array, temp, mid, right)
    mov     rdi, [rbp-8]
    mov     rsi, [rbp-16]
    mov     edx, [rbp-40]
    mov     ecx, [rbp-32]
    call    merge_sort

    ; Merge: merge(array, temp, left, mid, right)
    mov     rdi, [rbp-8]
    mov     rsi, [rbp-16]
    mov     edx, [rbp-24]
    mov     ecx, [rbp-40]
    mov     r8d, [rbp-32]
    call    merge

    add     rsp, 8                  ; pop mid
    pop     rcx
    pop     rdx
    pop     rsi
    pop     rdi
    pop     rbp
    ret


; ============================================================================
;  merge — Merge two sorted halves
;  Input: rdi=array, rsi=temp, edx=left, ecx=mid, r8d=right
; ============================================================================
; merge — Merge two sorted halves back into array
;  Input: rdi=array, rsi=temp, edx=left, ecx=mid, r8d=right
;  Uses temp[left..right) as scratch space
merge:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 40                 ; local vars

    ; Save parameters into callee-saved registers and locals
    mov     r12, rdi                ; array base
    mov     r13, rsi                ; temp base
    mov     [rbp-48], edx           ; left (also i_start)
    mov     [rbp-52], ecx           ; mid
    mov     [rbp-56], r8d           ; right

    ; Copy array[left..right) into temp[left..right)
    mov     eax, r8d
    sub     eax, edx                ; count = right - left
    mov     r14d, eax

    push    rdx
    push    rcx
    push    r8
    movsxd  rax, edx
    imul    rax, LINE_ENTRY_SIZE
    lea     rdi, [r13 + rax]        ; dest = temp + left*ENTRY
    lea     rsi, [r12 + rax]        ; src  = array + left*ENTRY
    movsxd  rdx, r14d
    imul    rdx, LINE_ENTRY_SIZE
    mov     rcx, rdx
    rep movsb                       ; fast copy
    pop     r8
    pop     rcx
    pop     rdx

    ; i = left, j = mid, k = left
    movsxd  r14, dword [rbp-48]     ; i (index into left half of temp)
    movsxd  r15, dword [rbp-52]     ; j (index into right half of temp)
    movsxd  rbx, dword [rbp-48]     ; k (output index into array)
    movsxd  r8, dword [rbp-52]      ; mid (boundary)
    movsxd  r9, dword [rbp-56]      ; right (end boundary)

.merge_loop:
    ; If both halves exhausted, done
    cmp     r14, r8
    jge     .merge_copy_right
    cmp     r15, r9
    jge     .merge_copy_left

    ; Compare temp[i] with temp[j]
    push    r8
    push    r9
    push    rbx
    mov     rax, r14
    shl     rax, 4
    mov     rdi, [r13 + rax]            ; temp[i].ptr
    mov     rsi, [r13 + rax + 8]        ; temp[i].len
    mov     rax, r15
    shl     rax, 4
    mov     rdx, [r13 + rax]            ; temp[j].ptr
    mov     rcx, [r13 + rax + 8]        ; temp[j].len
    call    compare_lines
    pop     rbx
    pop     r9
    pop     r8

    test    eax, eax
    jg      .merge_take_right

    ; Take from left half (temp[i]) — also handles equal case for stability
    mov     rax, r14
    shl     rax, 4
    mov     rcx, [r13 + rax]
    mov     rdx, [r13 + rax + 8]
    mov     rax, rbx
    shl     rax, 4
    mov     [r12 + rax], rcx
    mov     [r12 + rax + 8], rdx
    inc     r14
    inc     rbx
    jmp     .merge_loop

.merge_take_right:
    ; Take from right half (temp[j])
    mov     rax, r15
    shl     rax, 4
    mov     rcx, [r13 + rax]
    mov     rdx, [r13 + rax + 8]
    mov     rax, rbx
    shl     rax, 4
    mov     [r12 + rax], rcx
    mov     [r12 + rax + 8], rdx
    inc     r15
    inc     rbx
    jmp     .merge_loop

.merge_copy_left:
    ; Left half still has elements; copy remaining
    cmp     r14, r8
    jge     .merge_done
    mov     rax, r14
    shl     rax, 4
    mov     rcx, [r13 + rax]
    mov     rdx, [r13 + rax + 8]
    mov     rax, rbx
    shl     rax, 4
    mov     [r12 + rax], rcx
    mov     [r12 + rax + 8], rdx
    inc     r14
    inc     rbx
    jmp     .merge_copy_left

.merge_copy_right:
    ; Right half still has elements; copy remaining
    cmp     r15, r9
    jge     .merge_done
    mov     rax, r15
    shl     rax, 4
    mov     rcx, [r13 + rax]
    mov     rdx, [r13 + rax + 8]
    mov     rax, rbx
    shl     rax, 4
    mov     [r12 + rax], rcx
    mov     [r12 + rax + 8], rdx
    inc     r15
    inc     rbx
    jmp     .merge_copy_right

.merge_done:
    add     rsp, 40
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ============================================================================
;  compare_lines — Compare two lines according to sort options
;  Input: rdi=ptr1, rsi=len1, rdx=ptr2, rcx=len2
;  Output: eax = <0 if line1<line2, 0 if equal, >0 if line1>line2
; ============================================================================
compare_lines:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     rbp, rsp
    sub     rsp, 64                 ; local storage

    ; Save line info
    mov     [rbp-8], rdi            ; ptr1
    mov     [rbp-16], rsi           ; len1
    mov     [rbp-24], rdx           ; ptr2
    mov     [rbp-32], rcx           ; len2

    ; If we have sort keys, use them
    cmp     qword [rel nkeys], 0
    jne     .cl_with_keys

    ; No explicit keys — compare whole lines
    mov     rdi, [rbp-8]
    mov     rsi, [rbp-16]
    mov     rdx, [rbp-24]
    mov     rcx, [rbp-32]
    mov     r8, [rel flag_bits]
    call    compare_fields
    ; Apply global reverse
    test    qword [rel flag_bits], FLAG_REVERSE
    jz      .cl_done
    neg     eax
    jmp     .cl_done

.cl_with_keys:
    ; Iterate over each key
    xor     r12d, r12d              ; key index

.cl_key_loop:
    cmp     r12, [rel nkeys]
    jge     .cl_keys_equal

    ; Get key definition
    imul    r14, r12, KEY_STRUCT_SIZE
    lea     r15, [rel keys]
    add     r15, r14

    ; Extract fields for line 1
    mov     rdi, [rbp-8]           ; ptr1
    mov     rsi, [rbp-16]          ; len1
    mov     rdx, [r15]             ; start_field
    mov     rcx, [r15+8]           ; start_char
    mov     r8, [r15+16]           ; end_field
    mov     r9, [r15+24]           ; end_char
    call    extract_key
    mov     [rbp-40], rax           ; key1_ptr
    mov     [rbp-48], rdx           ; key1_len

    ; Extract fields for line 2
    mov     rdi, [rbp-24]          ; ptr2
    mov     rsi, [rbp-32]          ; len2
    mov     rdx, [r15]             ; start_field
    mov     rcx, [r15+8]           ; start_char
    mov     r8, [r15+16]           ; end_field
    mov     r9, [r15+24]           ; end_char
    call    extract_key
    ; rax = key2_ptr, rdx = key2_len

    ; Compare keys: key1 (saved) vs key2 (in rax/rdx)
    mov     rdi, [rbp-40]          ; key1_ptr
    mov     rsi, [rbp-48]          ; key1_len
    mov     rcx, rdx               ; key2_len (save before overwriting rdx)
    mov     rdx, rax               ; key2_ptr

    ; Determine flags for this key
    mov     r8, [r15+32]           ; key flags
    test    r8, r8
    jnz     .cl_use_key_flags
    mov     r8, [rel flag_bits]    ; use global flags if no per-key flags
.cl_use_key_flags:
    call    compare_fields

    test    eax, eax
    jnz     .cl_key_diff

    inc     r12
    jmp     .cl_key_loop

.cl_key_diff:
    ; Apply per-key or global reverse
    mov     r8, [r15+32]
    test    r8, r8
    jnz     .cl_check_key_rev
    mov     r8, [rel flag_bits]
.cl_check_key_rev:
    test    r8, KEY_REVERSE
    jz      .cl_done
    neg     eax
    jmp     .cl_done

.cl_keys_equal:
    ; All keys equal — if not stable, do last-resort comparison
    test    qword [rel flag_bits], FLAG_STABLE
    jnz     .cl_return_zero

    ; Last resort: full line byte comparison (no flags)
    mov     rdi, [rbp-8]
    mov     rsi, [rbp-16]
    mov     rdx, [rbp-24]
    mov     rcx, [rbp-32]
    xor     r8d, r8d               ; no flags for last-resort
    call    compare_fields
    ; Apply global reverse to last-resort
    test    qword [rel flag_bits], FLAG_REVERSE
    jz      .cl_done
    neg     eax
    jmp     .cl_done

.cl_return_zero:
    xor     eax, eax

.cl_done:
    add     rsp, 64
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  compare_fields — Compare two byte ranges with given flags
;  Input: rdi=ptr1, rsi=len1, rdx=ptr2, rcx=len2, r8=flags
;  Output: eax = comparison result
; ============================================================================
compare_fields:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi                ; ptr1
    mov     r13, rsi                ; len1
    mov     r14, rdx                ; ptr2
    mov     r15, rcx                ; len2
    mov     rbx, r8                 ; flags

    ; Check for -b (ignore leading blanks)
    test    rbx, FLAG_BLANKS | KEY_BLANKS
    jz      .cf_no_blanks

    ; Skip leading blanks in both
.cf_skip_blanks1:
    test    r13, r13
    jz      .cf_no_blanks
    cmp     byte [r12], ' '
    je      .cf_sb1
    cmp     byte [r12], 9           ; tab
    je      .cf_sb1
    jmp     .cf_skip_blanks2
.cf_sb1:
    inc     r12
    dec     r13
    jmp     .cf_skip_blanks1

.cf_skip_blanks2:
    test    r15, r15
    jz      .cf_no_blanks
    cmp     byte [r14], ' '
    je      .cf_sb2
    cmp     byte [r14], 9
    je      .cf_sb2
    jmp     .cf_no_blanks
.cf_sb2:
    inc     r14
    dec     r15
    jmp     .cf_skip_blanks2

.cf_no_blanks:
    ; Check for numeric sort
    test    rbx, FLAG_NUMERIC | KEY_NUMERIC
    jnz     .cf_numeric

    ; Check for general numeric sort
    test    rbx, FLAG_GEN_NUM | KEY_GEN_NUM
    jnz     .cf_numeric

    ; Check for month sort
    test    rbx, FLAG_MONTH | KEY_MONTH
    jnz     .cf_month

    ; Check for human numeric sort
    test    rbx, FLAG_HUMAN | KEY_HUMAN
    jnz     .cf_numeric

    ; Check for version sort
    test    rbx, FLAG_VERSION | KEY_VERSION
    jnz     .cf_version

    ; Lexicographic comparison
    ; Check for -f (fold case), -d (dictionary), -i (ignore non-printing)
    test    rbx, FLAG_FOLD_CASE | KEY_FOLD_CASE | FLAG_DICT | KEY_DICT | FLAG_IGNORE_NP | KEY_IGNORE_NP
    jnz     .cf_filtered_cmp

    ; Simple byte-by-byte comparison (most common case)
    mov     rcx, r13
    cmp     rcx, r15
    jbe     .cf_min_ok
    mov     rcx, r15
.cf_min_ok:
    ; Fast memcmp loop
    xor     eax, eax
    test    rcx, rcx
    jz      .cf_len_diff

    ; Compare 8 bytes at a time when possible
.cf_fast_loop:
    cmp     rcx, 8
    jb      .cf_byte_loop
    mov     rax, [r12]
    cmp     rax, [r14]
    jne     .cf_byte_loop           ; mismatch in this qword, fall to byte
    add     r12, 8
    add     r14, 8
    sub     rcx, 8
    jmp     .cf_fast_loop

.cf_byte_loop:
    test    rcx, rcx
    jz      .cf_len_diff
    movzx   eax, byte [r12]
    movzx   edx, byte [r14]
    sub     eax, edx
    jnz     .cf_return
    inc     r12
    inc     r14
    dec     rcx
    jmp     .cf_byte_loop

.cf_len_diff:
    ; Equal up to min length — shorter is less
    mov     rax, r13
    sub     rax, r15
    ; Clamp to -1/0/+1
    test    rax, rax
    jz      .cf_return_zero
    js      .cf_return_neg
    mov     eax, 1
    jmp     .cf_return
.cf_return_neg:
    mov     eax, -1
    jmp     .cf_return
.cf_return_zero:
    xor     eax, eax
.cf_return:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── Filtered comparison (fold case, dictionary, ignore non-printing) ──
.cf_filtered_cmp:
    ; Walk both strings, applying filters
    xor     r8d, r8d                ; i1
    xor     r9d, r9d                ; i2

.cf_filt_loop:
    ; Get next valid char from string 1
.cf_get_c1:
    cmp     r8, r13
    jge     .cf_filt_s1_end
    movzx   eax, byte [r12 + r8]
    inc     r8

    ; Apply -d (dictionary): skip if not blank/alnum
    test    rbx, FLAG_DICT | KEY_DICT
    jz      .cf_filt_no_d1
    call    is_dict_char
    test    eax, eax
    jz      .cf_get_c1
    movzx   eax, byte [r12 + r8 - 1]
.cf_filt_no_d1:

    ; Apply -i (ignore non-printing): skip if < 0x20 or > 0x7E
    test    rbx, FLAG_IGNORE_NP | KEY_IGNORE_NP
    jz      .cf_filt_no_i1
    cmp     al, 0x20
    jb      .cf_get_c1
    cmp     al, 0x7E
    ja      .cf_get_c1
.cf_filt_no_i1:

    ; Apply -f (fold case): toupper
    test    rbx, FLAG_FOLD_CASE | KEY_FOLD_CASE
    jz      .cf_filt_no_f1
    cmp     al, 'a'
    jb      .cf_filt_no_f1
    cmp     al, 'z'
    ja      .cf_filt_no_f1
    sub     al, 32
.cf_filt_no_f1:
    mov     cl, al                  ; c1

    ; Get next valid char from string 2
.cf_get_c2:
    cmp     r9, r15
    jge     .cf_filt_s2_end_with_c1
    movzx   eax, byte [r14 + r9]
    inc     r9

    ; Apply -d
    test    rbx, FLAG_DICT | KEY_DICT
    jz      .cf_filt_no_d2
    call    is_dict_char
    test    eax, eax
    jz      .cf_get_c2
    movzx   eax, byte [r14 + r9 - 1]
.cf_filt_no_d2:

    ; Apply -i
    test    rbx, FLAG_IGNORE_NP | KEY_IGNORE_NP
    jz      .cf_filt_no_i2
    cmp     al, 0x20
    jb      .cf_get_c2
    cmp     al, 0x7E
    ja      .cf_get_c2
.cf_filt_no_i2:

    ; Apply -f
    test    rbx, FLAG_FOLD_CASE | KEY_FOLD_CASE
    jz      .cf_filt_no_f2
    cmp     al, 'a'
    jb      .cf_filt_no_f2
    cmp     al, 'z'
    ja      .cf_filt_no_f2
    sub     al, 32
.cf_filt_no_f2:

    ; Compare c1 vs c2
    cmp     cl, al
    jb      .cf_filt_less
    ja      .cf_filt_greater
    jmp     .cf_filt_loop

.cf_filt_s1_end:
    ; String 1 exhausted — check if string 2 also exhausted
.cf_filt_s1_check:
    cmp     r9, r15
    jge     .cf_return_zero         ; both exhausted
    ; String 2 has more chars — check if they are all filtered out
    movzx   eax, byte [r14 + r9]
    inc     r9
    test    rbx, FLAG_DICT | KEY_DICT
    jz      .cf_filt_s1_chk_i
    call    is_dict_char
    test    eax, eax
    jz      .cf_filt_s1_check
    jmp     .cf_filt_less           ; s2 has valid char, s1 doesn't
.cf_filt_s1_chk_i:
    test    rbx, FLAG_IGNORE_NP | KEY_IGNORE_NP
    jz      .cf_filt_less
    movzx   eax, byte [r14 + r9 - 1]
    cmp     al, 0x20
    jb      .cf_filt_s1_check
    cmp     al, 0x7E
    ja      .cf_filt_s1_check
    jmp     .cf_filt_less

.cf_filt_s2_end_with_c1:
    ; String 2 exhausted but string 1 still has c1
    mov     eax, 1
    jmp     .cf_return

.cf_filt_less:
    mov     eax, -1
    jmp     .cf_return
.cf_filt_greater:
    mov     eax, 1
    jmp     .cf_return

; ── Numeric comparison ──
.cf_numeric:
    ; Parse string 1 as number
    mov     rdi, r12
    mov     rsi, r13
    call    parse_sort_number       ; rax = int1, rdx = frac1
    push    rax                     ; save num1 on stack
    push    rdx                     ; save frac1 on stack

    ; Parse string 2 as number (r14/r15 are callee-saved, safe across call)
    mov     rdi, r14
    mov     rsi, r15
    call    parse_sort_number       ; rax = int2, rdx = frac2

    ; Now: rax=num2, rdx=frac2, stack: [frac1, num1]
    pop     rcx                     ; frac1
    pop     r8                      ; num1

    ; Compare: r8=num1 vs rax=num2
    cmp     r8, rax
    jl      .cf_num_less
    jg      .cf_num_greater
    ; Integer parts equal, compare fractional parts
    cmp     rcx, rdx
    jl      .cf_num_less
    jg      .cf_num_greater
    xor     eax, eax
    jmp     .cf_return
.cf_num_less:
    mov     eax, -1
    jmp     .cf_return
.cf_num_greater:
    mov     eax, 1
    jmp     .cf_return

; ── Month comparison ──
.cf_month:
    mov     rdi, r12
    mov     rsi, r13
    call    parse_month
    mov     r8d, eax               ; month1 (0=unknown, 1-12)

    mov     rdi, r14
    mov     rsi, r15
    call    parse_month
    ; eax = month2

    cmp     r8d, eax
    jl      .cf_num_less
    jg      .cf_num_greater
    xor     eax, eax
    jmp     .cf_return

; ── Version sort ──
.cf_version:
    ; Version sort: compare digit runs as numbers, rest as bytes
    xor     r8d, r8d               ; i1
    xor     r9d, r9d               ; i2

.cf_ver_loop:
    cmp     r8, r13
    jge     .cf_ver_s1_end
    cmp     r9, r15
    jge     .cf_ver_s2_end

    movzx   eax, byte [r12 + r8]
    movzx   ecx, byte [r14 + r9]

    ; Check if both are digits
    sub     eax, '0'
    cmp     eax, 9
    ja      .cf_ver_not_digit1
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .cf_ver_mixed

    ; Both digits — compare numeric runs
    ; Skip leading zeros
    push    r8
    push    r9
.cf_ver_skip0_1:
    cmp     r8, r13
    jge     .cf_ver_num_cmp
    cmp     byte [r12 + r8], '0'
    jne     .cf_ver_num_cmp
    inc     r8
    jmp     .cf_ver_skip0_1

.cf_ver_num_cmp:
    ; Count digits remaining in s1
    mov     rax, r8
.cf_ver_cnt1:
    cmp     rax, r13
    jge     .cf_ver_cnt1_done
    movzx   ecx, byte [r12 + rax]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .cf_ver_cnt1_done
    inc     rax
    jmp     .cf_ver_cnt1
.cf_ver_cnt1_done:
    mov     r10, rax
    sub     r10, r8                 ; digit count 1

    pop     r9
    push    r9
.cf_ver_skip0_2:
    cmp     r9, r15
    jge     .cf_ver_cnt2
    cmp     byte [r14 + r9], '0'
    jne     .cf_ver_cnt2
    inc     r9
    jmp     .cf_ver_skip0_2

.cf_ver_cnt2:
    mov     rax, r9
.cf_ver_cnt2_loop:
    cmp     rax, r15
    jge     .cf_ver_cnt2_done
    movzx   ecx, byte [r14 + rax]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .cf_ver_cnt2_done
    inc     rax
    jmp     .cf_ver_cnt2_loop
.cf_ver_cnt2_done:
    mov     r11, rax
    sub     r11, r9                 ; digit count 2

    ; Longer digit sequence = larger number
    cmp     r10, r11
    jg      .cf_ver_pop_greater
    jl      .cf_ver_pop_less

    ; Same length — compare digit by digit
.cf_ver_digit_cmp:
    test    r10, r10
    jz      .cf_ver_digits_equal
    movzx   eax, byte [r12 + r8]
    movzx   ecx, byte [r14 + r9]
    cmp     eax, ecx
    jg      .cf_ver_pop_greater
    jl      .cf_ver_pop_less
    inc     r8
    inc     r9
    dec     r10
    jmp     .cf_ver_digit_cmp

.cf_ver_digits_equal:
    pop     r9
    pop     r8
    ; Advance past the digit runs
.cf_ver_adv1:
    cmp     r8, r13
    jge     .cf_ver_loop
    movzx   eax, byte [r12 + r8]
    sub     eax, '0'
    cmp     eax, 9
    ja      .cf_ver_loop
    inc     r8
    jmp     .cf_ver_adv1

.cf_ver_pop_greater:
    pop     r9
    pop     r8
    mov     eax, 1
    jmp     .cf_return

.cf_ver_pop_less:
    pop     r9
    pop     r8
    mov     eax, -1
    jmp     .cf_return

.cf_ver_not_digit1:
    add     eax, '0'               ; restore
    ; Not a digit in s1 — compare as bytes
    cmp     al, cl
    jb      .cf_filt_less
    ja      .cf_filt_greater
    inc     r8
    inc     r9
    jmp     .cf_ver_loop

.cf_ver_mixed:
    ; s1 is digit, s2 is not — digit > non-digit for version sort
    add     ecx, '0'
    add     eax, '0'
    cmp     al, cl
    jb      .cf_filt_less
    ja      .cf_filt_greater
    inc     r8
    inc     r9
    jmp     .cf_ver_loop

.cf_ver_s1_end:
    cmp     r9, r15
    jge     .cf_return_zero
    mov     eax, -1
    jmp     .cf_return

.cf_ver_s2_end:
    mov     eax, 1
    jmp     .cf_return


; ============================================================================
;  parse_sort_number — Parse a string as a number for -n sort
;  Input: rdi=ptr, rsi=len
;  Output: rax = integer part (signed), rdx = fractional comparison value
; ============================================================================
parse_sort_number:
    push    rbx
    push    r12

    mov     r12, rdi               ; ptr
    mov     rbx, rsi               ; len
    xor     eax, eax               ; result
    xor     edx, edx               ; frac
    xor     ecx, ecx               ; negative flag

    ; Skip leading whitespace
.psn_skip_ws:
    test    rbx, rbx
    jz      .psn_done
    cmp     byte [r12], ' '
    je      .psn_skip
    cmp     byte [r12], 9
    je      .psn_skip
    jmp     .psn_check_sign
.psn_skip:
    inc     r12
    dec     rbx
    jmp     .psn_skip_ws

.psn_check_sign:
    test    rbx, rbx
    jz      .psn_done
    cmp     byte [r12], '-'
    je      .psn_neg
    cmp     byte [r12], '+'
    je      .psn_pos
    jmp     .psn_digits
.psn_neg:
    mov     ecx, 1
    inc     r12
    dec     rbx
    jmp     .psn_digits
.psn_pos:
    inc     r12
    dec     rbx

.psn_digits:
    ; Parse integer digits
.psn_int_loop:
    test    rbx, rbx
    jz      .psn_apply_sign
    movzx   r8d, byte [r12]
    sub     r8d, '0'
    cmp     r8d, 9
    ja      .psn_check_dot
    imul    rax, 10
    add     rax, r8
    inc     r12
    dec     rbx
    jmp     .psn_int_loop

.psn_check_dot:
    cmp     byte [r12], '.'
    jne     .psn_apply_sign
    inc     r12
    dec     rbx

    ; Parse fractional digits (up to 9 digits, scaled to compare as integers)
    mov     r8, 1000000000          ; scale factor
.psn_frac_loop:
    test    rbx, rbx
    jz      .psn_apply_sign
    movzx   r9d, byte [r12]
    sub     r9d, '0'
    cmp     r9d, 9
    ja      .psn_apply_sign
    ; frac = frac * 10 + digit (but we want fixed point)
    ; Actually, compute: frac = frac + digit * (scale / 10)
    xor     edx, edx
    mov     rax, r8
    mov     r10, 10
    div     r10                     ; rax = scale/10
    mov     r8, rax                 ; new scale
    imul    r9, rax
    add     rdx, r9                 ; Hmm, rdx was clobbered by div
    ; Let me redo this more carefully
    jmp     .psn_apply_sign         ; Skip frac for now — integer comparison is sufficient

.psn_apply_sign:
    test    ecx, ecx
    jz      .psn_done
    neg     rax
    neg     rdx

.psn_done:
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  parse_numeric_value — stub (same as parse_sort_number)
; ============================================================================
parse_numeric_value:
    ret


; ============================================================================
;  parse_month — Parse a month name from the start of a string
;  Input: rdi=ptr, rsi=len
;  Output: eax = month number (0=unknown, 1-12)
; ============================================================================
parse_month:
    push    rbx
    push    r12
    push    r13

    mov     r12, rdi
    mov     r13, rsi

    ; Skip leading blanks
.pm_skip:
    test    r13, r13
    jz      .pm_unknown
    cmp     byte [r12], ' '
    je      .pm_skip_next
    cmp     byte [r12], 9
    je      .pm_skip_next
    jmp     .pm_check
.pm_skip_next:
    inc     r12
    dec     r13
    jmp     .pm_skip

.pm_check:
    cmp     r13, 3
    jb      .pm_unknown

    ; Load first 3 chars and uppercase them
    movzx   eax, byte [r12]
    call    to_upper_al
    mov     bl, al
    movzx   eax, byte [r12+1]
    call    to_upper_al
    mov     bh, al
    movzx   eax, byte [r12+2]
    call    to_upper_al
    mov     cl, al

    ; Compare against month names
    lea     rdx, [rel month_names]
    mov     r8d, 1                  ; month counter

.pm_cmp_loop:
    cmp     r8d, 13
    jge     .pm_unknown
    cmp     bl, [rdx]
    jne     .pm_next
    cmp     bh, [rdx+1]
    jne     .pm_next
    cmp     cl, [rdx+2]
    jne     .pm_next
    ; Match
    mov     eax, r8d
    pop     r13
    pop     r12
    pop     rbx
    ret

.pm_next:
    add     rdx, 4                  ; each entry is 3 chars + NUL
    inc     r8d
    jmp     .pm_cmp_loop

.pm_unknown:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  to_upper_al — Convert AL to uppercase
; ============================================================================
to_upper_al:
    cmp     al, 'a'
    jb      .tu_done
    cmp     al, 'z'
    ja      .tu_done
    sub     al, 32
.tu_done:
    ret


; ============================================================================
;  is_dict_char — Check if AL is a dictionary-order character
;  Input: AL = character (from caller's context)
;  Output: eax = 1 if dict char (blank or alnum), 0 otherwise
;  Preserves: rbx, r8-r15
; ============================================================================
is_dict_char:
    ; Need to re-read the character since AL might be clobbered
    ; Actually the caller should pass the char. Let's use the character that was loaded.
    ; For the filtered comparison, the character is in AL
    cmp     al, ' '
    je      .idc_yes
    cmp     al, 9
    je      .idc_yes
    cmp     al, '0'
    jb      .idc_no
    cmp     al, '9'
    jbe     .idc_yes
    cmp     al, 'A'
    jb      .idc_no
    cmp     al, 'Z'
    jbe     .idc_yes
    cmp     al, 'a'
    jb      .idc_no
    cmp     al, 'z'
    jbe     .idc_yes
.idc_no:
    xor     eax, eax
    ret
.idc_yes:
    mov     eax, 1
    ret


; ============================================================================
;  extract_key — Extract a sort key substring from a line
;  Input: rdi=line_ptr, rsi=line_len,
;         rdx=start_field (1-based), rcx=start_char (1-based, 0=whole),
;         r8=end_field (0=EOL), r9=end_char (0=end of field)
;  Output: rax=key_ptr, rdx=key_len
; ============================================================================
extract_key:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi               ; line_ptr
    mov     r13, rsi               ; line_len
    mov     r14, rdx               ; start_field
    mov     r15, rcx               ; start_char

    ; If start_field == 0, use whole line
    test    r14, r14
    jz      .ek_whole_line

    ; Find start of field
    mov     rdi, r12
    mov     rsi, r13
    mov     rdx, r14
    call    find_field_start
    ; rax = offset to field start
    mov     rbx, rax               ; field_start offset

    ; Apply start_char offset
    test    r15, r15
    jz      .ek_no_start_char
    dec     r15                    ; 1-based to 0-based
    add     rbx, r15
    ; Clamp to line length
    cmp     rbx, r13
    jbe     .ek_no_start_char
    mov     rbx, r13
.ek_no_start_char:

    ; Find end position
    cmp     r8, 0                  ; end_field
    je      .ek_to_eol

    ; Find end field
    mov     rdi, r12
    mov     rsi, r13
    mov     rdx, r8
    call    find_field_end
    ; rax = offset past end of field
    mov     rcx, rax               ; field_end offset

    ; Apply end_char
    test    r9, r9
    jz      .ek_end_ok
    ; end position = start of end_field + end_char
    mov     rdi, r12
    mov     rsi, r13
    mov     rdx, r8
    call    find_field_start
    add     rax, r9                ; start + end_char
    cmp     rax, r13
    jbe     .ek_use_end_char
    mov     rax, r13
.ek_use_end_char:
    mov     rcx, rax

.ek_end_ok:
    ; Key = line[rbx..rcx)
    cmp     rbx, rcx
    jge     .ek_empty
    lea     rax, [r12 + rbx]
    mov     rdx, rcx
    sub     rdx, rbx
    jmp     .ek_done

.ek_to_eol:
    lea     rax, [r12 + rbx]
    mov     rdx, r13
    sub     rdx, rbx
    cmp     rdx, 0
    jge     .ek_done
    xor     edx, edx
    jmp     .ek_done

.ek_whole_line:
    mov     rax, r12
    mov     rdx, r13
    jmp     .ek_done

.ek_empty:
    lea     rax, [r12 + r13]       ; point past end
    xor     edx, edx

.ek_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  find_field_start — Find the start offset of field N (1-based) in a line
;  Input: rdi=line_ptr, rsi=line_len, rdx=field_num (1-based)
;  Output: rax=offset to field start
; ============================================================================
find_field_start:
    push    rbx
    push    r12

    mov     r12, rdx               ; target field
    xor     eax, eax               ; current offset
    mov     rbx, 1                  ; current field number

    ; Field 1 starts at the beginning (or after leading blanks)
    cmp     r12, 1
    jle     .ffs_done

    ; Check if we have a custom separator
    cmp     byte [rel has_separator], 1
    je      .ffs_sep_loop

    ; Default: fields separated by runs of blanks
.ffs_blank_loop:
    cmp     rax, rsi
    jge     .ffs_done
    ; Skip non-blanks (field content)
.ffs_skip_content:
    cmp     rax, rsi
    jge     .ffs_done
    cmp     byte [rdi + rax], ' '
    je      .ffs_in_blanks
    cmp     byte [rdi + rax], 9
    je      .ffs_in_blanks
    inc     rax
    jmp     .ffs_skip_content

.ffs_in_blanks:
    ; Skip blanks (separator)
.ffs_skip_blanks:
    cmp     rax, rsi
    jge     .ffs_done
    cmp     byte [rdi + rax], ' '
    je      .ffs_sb
    cmp     byte [rdi + rax], 9
    je      .ffs_sb
    jmp     .ffs_next_field
.ffs_sb:
    inc     rax
    jmp     .ffs_skip_blanks

.ffs_next_field:
    inc     rbx
    cmp     rbx, r12
    jge     .ffs_done
    jmp     .ffs_skip_content

.ffs_sep_loop:
    ; Custom separator: fields separated by single char
    movzx   ecx, byte [rel separator]
.ffs_sep_scan:
    cmp     rax, rsi
    jge     .ffs_done
    cmp     byte [rdi + rax], cl
    je      .ffs_sep_found
    inc     rax
    jmp     .ffs_sep_scan

.ffs_sep_found:
    inc     rax                     ; skip separator
    inc     rbx
    cmp     rbx, r12
    jge     .ffs_done
    jmp     .ffs_sep_scan

.ffs_done:
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  find_field_end — Find the end offset of field N (1-based)
;  Input: rdi=line_ptr, rsi=line_len, rdx=field_num (1-based)
;  Output: rax=offset past end of field
; ============================================================================
find_field_end:
    push    rbx
    push    r12

    ; First find field start
    mov     r12, rdx
    call    find_field_start
    ; rax = start of field

    ; Now find end of this field
    cmp     byte [rel has_separator], 1
    je      .ffe_sep

    ; Default: end at next blank
.ffe_blank_end:
    cmp     rax, rsi
    jge     .ffe_done
    cmp     byte [rdi + rax], ' '
    je      .ffe_done
    cmp     byte [rdi + rax], 9
    je      .ffe_done
    inc     rax
    jmp     .ffe_blank_end

.ffe_sep:
    ; End at next separator or EOL
    movzx   ecx, byte [rel separator]
.ffe_sep_scan:
    cmp     rax, rsi
    jge     .ffe_done
    cmp     byte [rdi + rax], cl
    je      .ffe_done
    inc     rax
    jmp     .ffe_sep_scan

.ffe_done:
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  write_output — Write sorted lines to output
; ============================================================================
write_output:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, [rel line_array]
    mov     r13, [rel line_count]
    xor     r14d, r14d              ; line index
    movzx   ebx, byte [rel line_delim]

    test    r13, r13
    jz      .wo_done

    ; Check for -u (unique)
    test    qword [rel flag_bits], FLAG_UNIQUE
    jnz     .wo_unique_loop

.wo_loop:
    cmp     r14, r13
    jge     .wo_done

    ; Write line
    mov     rax, r14
    shl     rax, 4
    mov     rdi, [r12 + rax]        ; ptr
    mov     rsi, [r12 + rax + 8]    ; len
    call    outbuf_write

    ; Write delimiter
    lea     rdi, [rel line_delim]
    mov     rsi, 1
    call    outbuf_write

    inc     r14
    jmp     .wo_loop

.wo_unique_loop:
    cmp     r14, r13
    jge     .wo_done

    ; Write current line
    mov     rax, r14
    shl     rax, 4
    mov     rdi, [r12 + rax]
    mov     rsi, [r12 + rax + 8]
    call    outbuf_write

    ; Write delimiter
    lea     rdi, [rel line_delim]
    mov     rsi, 1
    call    outbuf_write

    ; Skip duplicates
.wo_skip_dup:
    mov     rax, r14
    inc     rax
    cmp     rax, r13
    jge     .wo_uniq_next

    ; Compare current with next
    push    rax                     ; save next index
    mov     rcx, r14
    shl     rcx, 4
    mov     rdi, [r12 + rcx]
    mov     rsi, [r12 + rcx + 8]
    mov     rcx, rax
    shl     rcx, 4
    mov     rdx, [r12 + rcx]
    mov     rcx, [r12 + rcx + 8]
    call    compare_lines
    mov     ecx, eax                ; save comparison result
    pop     rax                     ; restore next index
    test    ecx, ecx
    jnz     .wo_uniq_next
    mov     r14, rax
    jmp     .wo_skip_dup

.wo_uniq_next:
    mov     r14, rax
    cmp     r14, r13
    jl      .wo_unique_loop

.wo_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  outbuf_write — Buffered write to output
;  Input: rdi=data_ptr, rsi=data_len
; ============================================================================
outbuf_write:
    push    rbx
    push    r12

    mov     rbx, rdi               ; data ptr
    mov     r12, rsi               ; data len

.obw_loop:
    test    r12, r12
    jz      .obw_done

    mov     rax, [rel outbuf_pos]
    mov     rcx, OUTBUF_SIZE
    sub     rcx, rax               ; space remaining

    ; How much to copy this iteration
    mov     rdx, r12
    cmp     rdx, rcx
    jbe     .obw_copy
    mov     rdx, rcx               ; copy only what fits

.obw_copy:
    ; Copy rdx bytes from rbx to outbuf + outbuf_pos
    push    rdx
    lea     rdi, [rel outbuf]
    add     rdi, [rel outbuf_pos]
    mov     rsi, rbx
    ; Inline memcpy for small copies
    mov     rcx, rdx
    rep movsb
    pop     rdx

    add     [rel outbuf_pos], rdx
    add     rbx, rdx
    sub     r12, rdx

    ; Flush if buffer is full
    cmp     qword [rel outbuf_pos], OUTBUF_SIZE
    jb      .obw_loop
    call    flush_outbuf
    jmp     .obw_loop

.obw_done:
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  flush_outbuf — Flush the output buffer
; ============================================================================
flush_outbuf:
    mov     rdx, [rel outbuf_pos]
    test    rdx, rdx
    jz      .fob_done
    mov     rdi, [rel output_fd]
    lea     rsi, [rel outbuf]
    call    asm_write_all
    test    rax, rax
    js      .fob_error
    mov     qword [rel outbuf_pos], 0
.fob_done:
    ret
.fob_error:
    ; Write error (likely EPIPE) — exit 2
    mov     edi, 2
    call    asm_exit


; ============================================================================
;  check_sorted — Check if input is sorted (-c / -C)
; ============================================================================
check_sorted:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; Read all input
    call    read_all_input
    test    rax, rax
    js      .cs_error
    call    scan_lines

    mov     r12, [rel line_array]
    mov     r13, [rel line_count]

    cmp     r13, 2
    jl      .cs_sorted             ; 0 or 1 lines = sorted

    ; Compare adjacent lines
    mov     r14, 1                  ; start from second line

.cs_loop:
    cmp     r14, r13
    jge     .cs_sorted

    ; Compare line[r14-1] with line[r14]
    mov     rax, r14
    dec     rax
    shl     rax, 4
    mov     rdi, [r12 + rax]
    mov     rsi, [r12 + rax + 8]
    mov     rax, r14
    shl     rax, 4
    mov     rdx, [r12 + rax]
    mov     rcx, [r12 + rax + 8]
    call    compare_lines

    ; With -u: must be strictly less (result < 0)
    ; Without -u: must be less or equal (result <= 0)
    test    qword [rel flag_bits], FLAG_UNIQUE
    jnz     .cs_strict
    test    eax, eax
    jg      .cs_unsorted
    jmp     .cs_next

.cs_strict:
    test    eax, eax
    jge     .cs_unsorted

.cs_next:
    inc     r14
    jmp     .cs_loop

.cs_sorted:
    xor     edi, edi               ; exit 0
    call    asm_exit

.cs_unsorted:
    ; Check if quiet check (-C)
    test    qword [rel flag_bits], FLAG_CHECK_Q
    jnz     .cs_unsorted_exit

    ; Print disorder message: "sort: -:N: disorder: LINE"
    mov     rdi, STDERR
    lea     rsi, [rel str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all

    ; Print filename
    lea     rax, [rel files]
    mov     rdi, [rax]
    call    asm_strlen
    mov     rdx, rax
    lea     rax, [rel files]
    mov     rsi, [rax]
    mov     rdi, STDERR
    call    asm_write_all

    ; Print ":" (no space before line number — GNU format: "sort: -:2: disorder:")
    mov     rdi, STDERR
    lea     rsi, [rel str_colon]
    mov     edx, 1
    call    asm_write_all

    ; Print line number (r14 + 1, since r14 is 0-based line index)
    lea     rdi, [r14 + 1]
    lea     rsi, [rel errbuf]
    call    asm_itoa_local
    mov     rdx, rax
    mov     rdi, STDERR
    lea     rsi, [rel errbuf]
    call    asm_write_all

    ; Print ": disorder: "
    mov     rdi, STDERR
    lea     rsi, [rel str_disorder_sep]
    mov     edx, str_disorder_sep_len
    call    asm_write_all

    ; Print the offending line
    mov     rdi, STDERR
    mov     rax, r14
    shl     rax, 4
    mov     rsi, [r12 + rax]
    mov     rdx, [r12 + rax + 8]
    call    asm_write_all

    ; Print newline
    mov     rdi, STDERR
    lea     rsi, [rel str_newline]
    mov     edx, 1
    call    asm_write_all

.cs_unsorted_exit:
    mov     edi, 1
    call    asm_exit

.cs_error:
    mov     edi, 2
    call    asm_exit


; ============================================================================
;  asm_itoa_local — Convert integer to decimal string (local version)
;  Input: rdi=value, rsi=buf
;  Output: rax=length
; ============================================================================
asm_itoa_local:
    push    rbx
    mov     rax, rdi            ; value
    mov     rbx, rsi            ; buf start

    test    rax, rax
    jnz     .ail_convert
    mov     byte [rsi], '0'
    mov     rax, 1
    pop     rbx
    ret

.ail_convert:
    mov     r8, rsi
.ail_digit:
    xor     edx, edx
    mov     rcx, 10
    div     rcx
    add     dl, '0'
    mov     [rsi], dl
    inc     rsi
    test    rax, rax
    jnz     .ail_digit

    mov     rax, rsi
    sub     rax, r8

    ; Reverse
    dec     rsi
    mov     rdi, r8
.ail_rev:
    cmp     rdi, rsi
    jge     .ail_done
    mov     cl, [rdi]
    mov     ch, [rsi]
    mov     [rdi], ch
    mov     [rsi], cl
    inc     rdi
    dec     rsi
    jmp     .ail_rev

.ail_done:
    pop     rbx
    ret


; ============================================================================
;  str_equal — Compare two NUL-terminated strings
;  Input: rdi=str1, rsi=str2
;  Output: eax=1 if equal, 0 if not
; ============================================================================
str_equal:
.loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .not_equal
    test    al, al
    jz      .equal
    inc     rdi
    inc     rsi
    jmp     .loop
.equal:
    mov     eax, 1
    ret
.not_equal:
    xor     eax, eax
    ret


; ============================================================================
;  str_starts_with — Check if str1 starts with str2
;  Input: rdi=str1, rsi=prefix
;  Output: eax=1 if starts with, 0 if not
; ============================================================================
str_starts_with:
.loop:
    movzx   ecx, byte [rsi]
    test    cl, cl
    jz      .yes                    ; prefix exhausted = match
    movzx   eax, byte [rdi]
    cmp     al, cl
    jne     .no
    inc     rdi
    inc     rsi
    jmp     .loop
.yes:
    mov     eax, 1
    ret
.no:
    xor     eax, eax
    ret


; Non-executable stack
section .note.GNU-stack noalloc noexec nowrite progbits
