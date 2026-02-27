; fwc.asm — GNU-compatible "wc" in x86-64 Linux assembly
;
; Implements: -l (lines), -w (words), -c (bytes), -m (chars),
;             -L (max-line-length), --files0-from=F, --total=WHEN,
;             --help, --version, -- (end of options), - (stdin)
;
; SIMD: Uses SSE2 for fast newline counting and whitespace classification
;       in the hot loop. Falls back to scalar for remaining bytes.
;
; Build (modular):
;   nasm -f elf64 -I include/ tools/fwc.asm -o build/tools/fwc.o
;   nasm -f elf64 -I include/ lib/io.asm -o build/lib/io.o
;   nasm -f elf64 -I include/ lib/str.asm -o build/lib/str.o
;   ld --gc-sections -n build/tools/fwc.o build/lib/io.o build/lib/str.o -o fwc

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close
extern asm_strlen

; ═══════════════════════════════════════════════════════════════════
; Constants
; ═══════════════════════════════════════════════════════════════════

%define MAX_FILES       4096
%define OUTBUF_SIZE     8192
%define ITOA_BUF_SIZE   24

; Show flags (bit positions)
%define FLAG_LINES      0x01
%define FLAG_WORDS      0x02
%define FLAG_BYTES      0x04
%define FLAG_CHARS      0x08
%define FLAG_MAXLEN     0x10

; Total mode
%define TOTAL_AUTO      0
%define TOTAL_ALWAYS    1
%define TOTAL_NEVER     2
%define TOTAL_ONLY      3

; ═══════════════════════════════════════════════════════════════════
; Data section — string constants
; ═══════════════════════════════════════════════════════════════════
section .data

align 16
; SSE2 constants for whitespace classification
vec_9:      times 16 db 9       ; '\t' for subtraction
vec_4:      times 16 db 4       ; range check: 0x09-0x0D → (byte-9) in [0,4]
vec_space:  times 16 db 0x20    ; space character
vec_newline: times 16 db 0x0A   ; newline character
vec_c0:     times 16 db 0xC0    ; UTF-8 mask
vec_80:     times 16 db 0x80    ; UTF-8 continuation marker

; Strings
str_total:      db "total", 0
str_total_len   equ 5

str_help:
    db "Usage: wc [OPTION]... [FILE]...", 10
    db "  or:  wc [OPTION]... --files0-from=F", 10
    db "Print newline, word, and byte counts for each FILE, and a total line if", 10
    db "more than one FILE is specified.  A word is a non-zero-length sequence of", 10
    db "printable characters delimited by white space.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "The options below may be used to select which counts are printed, always in", 10
    db "the following order: newline, word, character, byte, maximum line length.", 10
    db "  -c, --bytes            print the byte counts", 10
    db "  -m, --chars            print the character counts", 10
    db "  -l, --lines            print the newline counts", 10
    db "      --files0-from=F    read input from the files specified by", 10
    db "                           NUL-terminated names in file F;", 10
    db "                           If F is - then read names from standard input", 10
    db "  -L, --max-line-length  print the maximum display width", 10
    db "  -w, --words            print the word counts", 10
    db "      --total=WHEN       when to print a line with total counts;", 10
    db "                           WHEN can be: auto, always, only, never", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/wc>", 10
    db "or available locally via: info '(coreutils) wc invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "wc (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Paul Rubin and David MacKenzie.", 10
str_version_len equ $ - str_version

str_wc_prefix:  db "wc: ", 0
str_wc_prefix_len equ 4

str_try_help:
    db "Try 'wc --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_inv_opt:    db "invalid option -- '", 0
str_inv_opt2:   db "'", 10, 0

str_unrec_opt:  db "unrecognized option '", 0
str_unrec_opt2: db "'", 10, 0

str_enoent:     db "No such file or directory", 10, 0
str_eacces:     db "Permission denied", 10, 0
str_eisdir:     db "Is a directory", 10, 0
str_read_err:   db "read error", 10, 0
str_generic_err: db "Error", 10, 0

str_inv_total_pre: db "invalid argument '", 0
str_inv_total_mid:
    db "' for '--total'", 10
str_inv_total_mid_len equ $ - str_inv_total_mid
str_inv_total_valid:
    db "Valid arguments are:", 10
    db "  - 'auto'", 10
    db "  - 'always'", 10
    db "  - 'only'", 10
    db "  - 'never'", 10
str_inv_total_valid_len equ $ - str_inv_total_valid

str_extra_operand: db "extra operand '", 0
str_extra_operand2: db "'", 10, 0
str_files0_combined:
    db "file operands cannot be combined with --files0-from", 10, 0
str_files0_combined_len equ $ - str_files0_combined - 1

str_stdin_name: db "-", 0
str_dash:       db "-", 0

; Long option strings for comparison
opt_bytes:      db "--bytes", 0
opt_chars:      db "--chars", 0
opt_lines:      db "--lines", 0
opt_words:      db "--words", 0
opt_maxlen:     db "--max-line-length", 0
opt_help:       db "--help", 0
opt_version:    db "--version", 0
opt_files0:     db "--files0-from=", 0
opt_files0_len  equ 14
opt_total:      db "--total=", 0
opt_total_len   equ 8

; Total mode strings
str_auto:       db "auto", 0
str_always:     db "always", 0
str_never:      db "never", 0
str_only:       db "only", 0

; Newline
newline:        db 10

; Empty string
empty_str:      db 0

; Locale detection strings
str_lc_all:     db "LC_ALL=", 0
str_lc_all_len  equ 7
str_lc_ctype:   db "LC_CTYPE=", 0
str_lc_ctype_len equ 9
str_lang:       db "LANG=", 0
str_lang_len    equ 5

; ─── Unicode width tables (BMP, for wcwidth-compatible -L) ───
; Width-2 BMP ranges (sorted, for binary search)
align 2
wide_ranges:
    dw 0x1100, 0x115F, 0x231A, 0x231B, 0x2329, 0x232A, 0x23E9, 0x23EC
    dw 0x23F0, 0x23F0, 0x23F3, 0x23F3, 0x25FD, 0x25FE, 0x2614, 0x2615
    dw 0x2648, 0x2653, 0x267F, 0x267F, 0x2693, 0x2693, 0x26A1, 0x26A1
    dw 0x26AA, 0x26AB, 0x26BD, 0x26BE, 0x26C4, 0x26C5, 0x26CE, 0x26CE
    dw 0x26D4, 0x26D4, 0x26EA, 0x26EA, 0x26F2, 0x26F3, 0x26F5, 0x26F5
    dw 0x26FA, 0x26FA, 0x26FD, 0x26FD, 0x2705, 0x2705, 0x270A, 0x270B
    dw 0x2728, 0x2728, 0x274C, 0x274C, 0x274E, 0x274E, 0x2753, 0x2755
    dw 0x2757, 0x2757, 0x2795, 0x2797, 0x27B0, 0x27B0, 0x27BF, 0x27BF
    dw 0x2B1B, 0x2B1C, 0x2B50, 0x2B50, 0x2B55, 0x2B55
    dw 0x2E80, 0x2E99, 0x2E9B, 0x2EF3, 0x2F00, 0x2FD5, 0x2FF0, 0x3029
    dw 0x302E, 0x303E, 0x3041, 0x3096, 0x309B, 0x30FF, 0x3105, 0x312F
    dw 0x3131, 0x318E, 0x3190, 0x31E3, 0x31EF, 0x321E, 0x3220, 0xA48C
    dw 0xA490, 0xA4C6, 0xA960, 0xA97C, 0xAC00, 0xD7A3
    dw 0xF900, 0xFA6D, 0xFA70, 0xFAD9
    dw 0xFE10, 0xFE19, 0xFE30, 0xFE52, 0xFE54, 0xFE66, 0xFE68, 0xFE6B
    dw 0xFF01, 0xFF60, 0xFFE0, 0xFFE6
WIDE_COUNT equ ($ - wide_ranges) / 4

; Width-0 BMP ranges (combining marks, format chars — sorted)
zero_ranges:
    dw 0x0300, 0x036F, 0x0483, 0x0489, 0x0591, 0x05BD, 0x05BF, 0x05BF
    dw 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7, 0x05C7, 0x0610, 0x061A
    dw 0x061C, 0x061C, 0x064B, 0x065F, 0x0670, 0x0670, 0x06D6, 0x06DC
    dw 0x06DF, 0x06E4, 0x06E7, 0x06E8, 0x06EA, 0x06ED, 0x0711, 0x0711
    dw 0x0730, 0x074A, 0x07A6, 0x07B0, 0x07EB, 0x07F3, 0x07FD, 0x07FD
    dw 0x0816, 0x0819, 0x081B, 0x0823, 0x0825, 0x0827, 0x0829, 0x082D
    dw 0x0859, 0x085B, 0x0898, 0x089F, 0x08CA, 0x08E1, 0x08E3, 0x0902
    dw 0x093A, 0x093A, 0x093C, 0x093C, 0x0941, 0x0948, 0x094D, 0x094D
    dw 0x0951, 0x0957, 0x0962, 0x0963, 0x0981, 0x0981, 0x09BC, 0x09BC
    dw 0x09C1, 0x09C4, 0x09CD, 0x09CD, 0x09E2, 0x09E3, 0x09FE, 0x09FE
    dw 0x0A01, 0x0A02, 0x0A3C, 0x0A3C, 0x0A41, 0x0A42, 0x0A47, 0x0A48
    dw 0x0A4B, 0x0A4D, 0x0A51, 0x0A51, 0x0A70, 0x0A71, 0x0A75, 0x0A75
    dw 0x0A81, 0x0A82, 0x0ABC, 0x0ABC, 0x0AC1, 0x0AC5, 0x0AC7, 0x0AC8
    dw 0x0ACD, 0x0ACD, 0x0AE2, 0x0AE3, 0x0AFA, 0x0AFF, 0x0B01, 0x0B01
    dw 0x0B3C, 0x0B3C, 0x0B3F, 0x0B3F, 0x0B41, 0x0B44, 0x0B4D, 0x0B4D
    dw 0x0B55, 0x0B56, 0x0B62, 0x0B63, 0x0B82, 0x0B82, 0x0BC0, 0x0BC0
    dw 0x0BCD, 0x0BCD, 0x0C00, 0x0C00, 0x0C04, 0x0C04, 0x0C3C, 0x0C3C
    dw 0x0C3E, 0x0C40, 0x0C46, 0x0C48, 0x0C4A, 0x0C4D, 0x0C55, 0x0C56
    dw 0x0C62, 0x0C63, 0x0C81, 0x0C81, 0x0CBC, 0x0CBC, 0x0CBF, 0x0CBF
    dw 0x0CC6, 0x0CC6, 0x0CCC, 0x0CCD, 0x0CE2, 0x0CE3, 0x0D00, 0x0D01
    dw 0x0D3B, 0x0D3C, 0x0D41, 0x0D44, 0x0D4D, 0x0D4D, 0x0D62, 0x0D63
    dw 0x0D81, 0x0D81, 0x0DCA, 0x0DCA, 0x0DD2, 0x0DD4, 0x0DD6, 0x0DD6
    dw 0x0E31, 0x0E31, 0x0E34, 0x0E3A, 0x0E47, 0x0E4E, 0x0EB1, 0x0EB1
    dw 0x0EB4, 0x0EBC, 0x0EC8, 0x0ECE, 0x0F18, 0x0F19, 0x0F35, 0x0F35
    dw 0x0F37, 0x0F37, 0x0F39, 0x0F39, 0x0F71, 0x0F7E, 0x0F80, 0x0F84
    dw 0x0F86, 0x0F87, 0x0F8D, 0x0F97, 0x0F99, 0x0FBC, 0x0FC6, 0x0FC6
    dw 0x102D, 0x1030, 0x1032, 0x1037, 0x1039, 0x103A, 0x103D, 0x103E
    dw 0x1058, 0x1059, 0x105E, 0x1060, 0x1071, 0x1074, 0x1082, 0x1082
    dw 0x1085, 0x1086, 0x108D, 0x108D, 0x109D, 0x109D, 0x1160, 0x11FF
    dw 0x135D, 0x135F, 0x1712, 0x1714, 0x1732, 0x1733, 0x1752, 0x1753
    dw 0x1772, 0x1773, 0x17B4, 0x17B5, 0x17B7, 0x17BD, 0x17C6, 0x17C6
    dw 0x17C9, 0x17D3, 0x17DD, 0x17DD, 0x180B, 0x180F, 0x1885, 0x1886
    dw 0x18A9, 0x18A9, 0x1920, 0x1922, 0x1927, 0x1928, 0x1932, 0x1932
    dw 0x1939, 0x193B, 0x1A17, 0x1A18, 0x1A1B, 0x1A1B, 0x1A56, 0x1A56
    dw 0x1A58, 0x1A5E, 0x1A60, 0x1A60, 0x1A62, 0x1A62, 0x1A65, 0x1A6C
    dw 0x1A73, 0x1A7C, 0x1A7F, 0x1A7F, 0x1AB0, 0x1ACE, 0x1B00, 0x1B03
    dw 0x1B34, 0x1B34, 0x1B36, 0x1B3A, 0x1B3C, 0x1B3C, 0x1B42, 0x1B42
    dw 0x1B6B, 0x1B73, 0x1B80, 0x1B81, 0x1BA2, 0x1BA5, 0x1BA8, 0x1BA9
    dw 0x1BAB, 0x1BAD, 0x1BE6, 0x1BE6, 0x1BE8, 0x1BE9, 0x1BED, 0x1BED
    dw 0x1BEF, 0x1BF1, 0x1C2C, 0x1C33, 0x1C36, 0x1C37, 0x1CD0, 0x1CD2
    dw 0x1CD4, 0x1CE0, 0x1CE2, 0x1CE8, 0x1CED, 0x1CED, 0x1CF4, 0x1CF4
    dw 0x1CF8, 0x1CF9, 0x1DC0, 0x1DFF, 0x200B, 0x200F, 0x202A, 0x202E
    dw 0x2060, 0x2064, 0x2066, 0x206F, 0x20D0, 0x20F0, 0x2CEF, 0x2CF1
    dw 0x2D7F, 0x2D7F, 0x2DE0, 0x2DFF, 0x302A, 0x302D, 0x3099, 0x309A
    dw 0xA66F, 0xA672, 0xA674, 0xA67D, 0xA69E, 0xA69F, 0xA6F0, 0xA6F1
    dw 0xA802, 0xA802, 0xA806, 0xA806, 0xA80B, 0xA80B, 0xA825, 0xA826
    dw 0xA82C, 0xA82C, 0xA8C4, 0xA8C5, 0xA8E0, 0xA8F1, 0xA8FF, 0xA8FF
    dw 0xA926, 0xA92D, 0xA947, 0xA951, 0xA980, 0xA982, 0xA9B3, 0xA9B3
    dw 0xA9B6, 0xA9B9, 0xA9BC, 0xA9BD, 0xA9E5, 0xA9E5, 0xAA29, 0xAA2E
    dw 0xAA31, 0xAA32, 0xAA35, 0xAA36, 0xAA43, 0xAA43, 0xAA4C, 0xAA4C
    dw 0xAA7C, 0xAA7C, 0xAAB0, 0xAAB0, 0xAAB2, 0xAAB4, 0xAAB7, 0xAAB8
    dw 0xAABE, 0xAABF, 0xAAC1, 0xAAC1, 0xAAEC, 0xAAED, 0xAAF6, 0xAAF6
    dw 0xABE5, 0xABE5, 0xABE8, 0xABE8, 0xABED, 0xABED
    dw 0xD7B0, 0xD7C6, 0xD7CB, 0xD7FB
    dw 0xFB1E, 0xFB1E, 0xFE00, 0xFE0F, 0xFE20, 0xFE2F, 0xFEFF, 0xFEFF
    dw 0xFFF9, 0xFFFB
ZERO_COUNT equ ($ - zero_ranges) / 4

; ═══════════════════════════════════════════════════════════════════
; BSS section — uninitialized data
; ═══════════════════════════════════════════════════════════════════
section .bss

align 16
read_buf:       resb BUF_SIZE           ; 64KB read buffer
outbuf:         resb OUTBUF_SIZE        ; output buffer
outbuf_pos:     resq 1                  ; current position in outbuf

stat_buf:       resb STAT_STRUCT_SIZE   ; for fstat

; File list (pointers to argv strings or files0 data)
file_ptrs:      resq MAX_FILES
file_count:     resq 1

; Results storage: 5 u64 per file (lines, words, bytes, chars, maxlen)
; Plus one extra for totals
results:        resq (MAX_FILES + 1) * 5

; Display names for results (pointers)
result_names:   resq MAX_FILES
result_count:   resq 1

; Files0-from buffer
files0_buf:     resb BUF_SIZE

; Itoa scratch buffer
itoa_buf:       resb ITOA_BUF_SIZE

; Output line buffer (must hold 5 numeric fields + spaces + PATH_MAX filename + newline)
line_buf:       resb 4352

; ═══════════════════════════════════════════════════════════════════
; Code section
; ═══════════════════════════════════════════════════════════════════
section .text

global _start

; ───────────────────────────────────────────────────────────────────
; Entry point
; ───────────────────────────────────────────────────────────────────
_start:
    ; Ignore SIGPIPE: set handler to SIG_IGN
    ; struct sigaction { handler, flags, restorer, mask }
    ; Minimal: just set sa_handler = SIG_IGN
    sub     rsp, 152                ; struct sigaction (new)
    sub     rsp, 152                ; struct sigaction (old)
    mov     qword [rsp + 152], SIG_IGN  ; new.sa_handler = SIG_IGN
    mov     qword [rsp + 152 + 8], 0    ; sa_flags = 0
    mov     qword [rsp + 152 + 16], 0   ; sa_restorer = 0
    ; Zero the mask (128 bits = 16 bytes starting at offset 24... actually sa_mask is at different offset)
    ; Simpler: zero the whole new sigaction struct
    lea     rdi, [rsp + 152]
    mov     rcx, 19                 ; 152/8 = 19 qwords
    xor     eax, eax
    rep stosq
    mov     qword [rsp + 152], SIG_IGN  ; re-set handler after zero

    mov     rax, SYS_RT_SIGACTION
    mov     rdi, SIGPIPE            ; signal number
    lea     rsi, [rsp + 152]        ; new action
    lea     rdx, [rsp]              ; old action (ignored)
    mov     r10, 8                  ; sizeof(sigset_t) for kernel
    syscall
    add     rsp, 304                ; clean up both structs

    ; Get argc and argv from stack
    mov     r12, [rsp]              ; argc
    lea     r13, [rsp + 8]          ; argv

    ; Initialize state
    xor     eax, eax
    mov     [rel file_count], rax
    mov     byte [rel show_flags], 0
    mov     byte [rel total_mode], TOTAL_AUTO
    mov     qword [rel files0_from_ptr], 0
    mov     qword [rel outbuf_pos], 0
    mov     byte [rel stdin_implicit], 0
    mov     byte [rel has_stdin], 0
    mov     byte [rel has_nonreg], 0
    mov     qword [rel result_count], 0

    ; Detect UTF-8 locale by scanning environment variables
    call    detect_utf8_locale

    ; Parse arguments
    call    parse_args

    ; If no explicit flags, default to -lwc
    cmp     byte [rel show_flags], 0
    jne     .flags_set
    mov     byte [rel show_flags], FLAG_LINES | FLAG_WORDS | FLAG_BYTES
.flags_set:

    ; If no files, add stdin ("-")
    cmp     qword [rel file_count], 0
    jne     .has_files
    lea     rax, [rel str_dash]
    mov     [rel file_ptrs], rax
    mov     qword [rel file_count], 1
    mov     byte [rel stdin_implicit], 1
.has_files:

    ; Process all files
    call    process_all_files

    ; Flush output buffer
    call    flush_outbuf

    ; Exit with appropriate code
    movzx   edi, byte [rel had_error]
    EXIT    rdi

; ───────────────────────────────────────────────────────────────────
; Argument parsing
; ───────────────────────────────────────────────────────────────────
parse_args:
    push    rbx
    push    r14
    push    r15

    mov     rbx, 1                  ; start at argv[1]
    xor     r14d, r14d              ; options_ended = false
    xor     r15d, r15d              ; file count

.arg_loop:
    cmp     rbx, r12                ; rbx < argc?
    jge     .arg_done

    mov     rdi, [r13 + rbx * 8]    ; argv[rbx]

    ; If options ended, treat as filename
    test    r14d, r14d
    jnz     .add_file

    ; Check for "--" (end of options)
    cmp     byte [rdi], '-'
    jne     .add_file
    cmp     byte [rdi + 1], '-'
    jne     .short_opt
    cmp     byte [rdi + 2], 0
    jne     .long_opt

    ; It's "--" exactly: end options
    mov     r14d, 1
    jmp     .next_arg

.short_opt:
    ; Single dash alone = stdin filename
    cmp     byte [rdi + 1], 0
    je      .add_file

    ; Parse short options: -lwcmL (can be combined: -lw)
    inc     rdi                     ; skip '-'
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_arg

    cmp     al, 'l'
    je      .set_lines
    cmp     al, 'w'
    je      .set_words
    cmp     al, 'c'
    je      .set_bytes
    cmp     al, 'm'
    je      .set_chars
    cmp     al, 'L'
    je      .set_maxlen

    ; Invalid short option
    ; Save bad char early, then maintain stack alignment for calls
    mov     [rel itoa_buf], al      ; save bad char
    mov     byte [rel itoa_buf + 1], 0
    sub     rsp, 16                 ; align stack (parse_args has 3 pushes,
                                    ; rsp was 0-mod-16; sub 16 keeps 0-mod-16)
    ; Write "wc: invalid option -- 'X'\n"
    mov     rdi, STDERR
    lea     rsi, [rel str_wc_prefix]
    mov     rdx, str_wc_prefix_len
    call    asm_write_all
    lea     rdi, [rel str_inv_opt]
    call    asm_strlen
    mov     rdx, rax
    lea     rsi, [rel str_inv_opt]
    mov     rdi, STDERR
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel itoa_buf]
    mov     rdx, 1
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_inv_opt2]
    mov     rdx, 2                  ; "'\n"
    call    asm_write_all
    ; Print "Try 'wc --help' ..."
    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all
    ; EXIT never returns, no need to restore stack
    mov     edi, 1
    EXIT    rdi

.set_lines:
    or      byte [rel show_flags], FLAG_LINES
    inc     rdi
    jmp     .short_loop
.set_words:
    or      byte [rel show_flags], FLAG_WORDS
    inc     rdi
    jmp     .short_loop
.set_bytes:
    or      byte [rel show_flags], FLAG_BYTES
    inc     rdi
    jmp     .short_loop
.set_chars:
    or      byte [rel show_flags], FLAG_CHARS
    inc     rdi
    jmp     .short_loop
.set_maxlen:
    or      byte [rel show_flags], FLAG_MAXLEN
    inc     rdi
    jmp     .short_loop

.long_opt:
    ; rdi points to "--..."
    ; Check --help
    lea     rsi, [rel opt_help]
    call    str_eq
    test    eax, eax
    jnz     .do_help

    ; Check --version
    mov     rdi, [r13 + rbx * 8]
    lea     rsi, [rel opt_version]
    call    str_eq
    test    eax, eax
    jnz     .do_version

    ; Check --bytes
    mov     rdi, [r13 + rbx * 8]
    lea     rsi, [rel opt_bytes]
    call    str_eq
    test    eax, eax
    jnz     .long_set_bytes

    ; Check --chars
    mov     rdi, [r13 + rbx * 8]
    lea     rsi, [rel opt_chars]
    call    str_eq
    test    eax, eax
    jnz     .long_set_chars

    ; Check --lines
    mov     rdi, [r13 + rbx * 8]
    lea     rsi, [rel opt_lines]
    call    str_eq
    test    eax, eax
    jnz     .long_set_lines

    ; Check --words
    mov     rdi, [r13 + rbx * 8]
    lea     rsi, [rel opt_words]
    call    str_eq
    test    eax, eax
    jnz     .long_set_words

    ; Check --max-line-length
    mov     rdi, [r13 + rbx * 8]
    lea     rsi, [rel opt_maxlen]
    call    str_eq
    test    eax, eax
    jnz     .long_set_maxlen

    ; Check --files0-from=
    mov     rdi, [r13 + rbx * 8]
    lea     rsi, [rel opt_files0]
    mov     rdx, opt_files0_len
    call    str_prefix
    test    eax, eax
    jnz     .do_files0

    ; Check --total=
    mov     rdi, [r13 + rbx * 8]
    lea     rsi, [rel opt_total]
    mov     rdx, opt_total_len
    call    str_prefix
    test    eax, eax
    jnz     .do_total

    ; Unrecognized long option
    mov     rdi, [r13 + rbx * 8]
    call    err_unrecognized_opt
    mov     edi, 1
    EXIT    rdi

.long_set_bytes:
    or      byte [rel show_flags], FLAG_BYTES
    jmp     .next_arg
.long_set_chars:
    or      byte [rel show_flags], FLAG_CHARS
    jmp     .next_arg
.long_set_lines:
    or      byte [rel show_flags], FLAG_LINES
    jmp     .next_arg
.long_set_words:
    or      byte [rel show_flags], FLAG_WORDS
    jmp     .next_arg
.long_set_maxlen:
    or      byte [rel show_flags], FLAG_MAXLEN
    jmp     .next_arg

.do_help:
    mov     rdi, STDOUT
    lea     rsi, [rel str_help]
    mov     rdx, str_help_len
    call    asm_write_all
    xor     edi, edi
    EXIT    rdi

.do_version:
    mov     rdi, STDOUT
    lea     rsi, [rel str_version]
    mov     rdx, str_version_len
    call    asm_write_all
    xor     edi, edi
    EXIT    rdi

.do_files0:
    ; Extract path after --files0-from=
    mov     rdi, [r13 + rbx * 8]
    add     rdi, opt_files0_len     ; point past "="
    mov     [rel files0_from_ptr], rdi
    jmp     .next_arg

.do_total:
    ; Extract WHEN after --total=
    mov     rdi, [r13 + rbx * 8]
    add     rdi, opt_total_len      ; point past "="

    ; Compare with known values
    push    rdi
    lea     rsi, [rel str_auto]
    call    str_eq
    pop     rdi
    test    eax, eax
    jnz     .total_auto

    push    rdi
    lea     rsi, [rel str_always]
    call    str_eq
    pop     rdi
    test    eax, eax
    jnz     .total_always

    push    rdi
    lea     rsi, [rel str_never]
    call    str_eq
    pop     rdi
    test    eax, eax
    jnz     .total_never

    push    rdi
    lea     rsi, [rel str_only]
    call    str_eq
    pop     rdi
    test    eax, eax
    jnz     .total_only

    ; Invalid --total value: print error and exit
    ; "wc: invalid argument 'VALUE' for '--total'\n"
    push    rdi                     ; save value ptr
    sub     rsp, 8                  ; align stack to 0-mod-16
    mov     rdi, STDERR
    lea     rsi, [rel str_wc_prefix]
    mov     rdx, str_wc_prefix_len
    call    asm_write_all

    lea     rdi, [rel str_inv_total_pre]
    call    asm_strlen
    mov     rdx, rax
    lea     rsi, [rel str_inv_total_pre]
    mov     rdi, STDERR
    call    asm_write_all

    mov     rdi, [rsp + 8]          ; read saved value ptr without popping
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, [rsp + 8]
    mov     rdi, STDERR
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_inv_total_mid]
    mov     rdx, str_inv_total_mid_len
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_inv_total_valid]
    mov     rdx, str_inv_total_valid_len
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all

    ; EXIT never returns, no need to restore stack
    mov     edi, 1
    EXIT    rdi

.total_auto:
    mov     byte [rel total_mode], TOTAL_AUTO
    jmp     .next_arg
.total_always:
    mov     byte [rel total_mode], TOTAL_ALWAYS
    jmp     .next_arg
.total_never:
    mov     byte [rel total_mode], TOTAL_NEVER
    jmp     .next_arg
.total_only:
    mov     byte [rel total_mode], TOTAL_ONLY
    jmp     .next_arg

.add_file:
    ; Check if --files0-from is active (can't combine with file operands)
    cmp     qword [rel files0_from_ptr], 0
    jne     .files0_conflict

    ; Add file to list
    lea     rax, [rel file_ptrs]
    mov     [rax + r15 * 8], rdi
    inc     r15
    jmp     .next_arg

.files0_conflict:
    ; Print error about combining --files0-from with file operands
    mov     rdi, STDERR
    lea     rsi, [rel str_wc_prefix]
    mov     rdx, str_wc_prefix_len
    call    asm_write_all

    lea     rdi, [rel str_extra_operand]
    call    asm_strlen
    mov     rdx, rax
    lea     rsi, [rel str_extra_operand]
    mov     rdi, STDERR
    call    asm_write_all

    ; Print the offending operand (maintain stack alignment)
    mov     rdi, [r13 + rbx * 8]
    push    rdi                     ; save operand, rsp now 0-mod-16
    sub     rsp, 8                  ; align to 0-mod-16 for calls
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, [rsp + 8]          ; read saved operand from stack
    mov     rdi, STDERR
    call    asm_write_all
    add     rsp, 16                 ; clean up push + alignment padding

    mov     rdi, STDERR
    lea     rsi, [rel str_extra_operand2]
    mov     rdx, 2
    call    asm_write_all

    ; "file operands cannot be combined with --files0-from"
    mov     rdi, STDERR
    lea     rsi, [rel str_files0_combined]
    mov     rdx, str_files0_combined_len
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all

    mov     edi, 1
    EXIT    rdi

.next_arg:
    inc     rbx
    jmp     .arg_loop

.arg_done:
    mov     [rel file_count], r15

    ; Handle --files0-from if specified
    cmp     qword [rel files0_from_ptr], 0
    je      .parse_done
    call    read_files0_from

.parse_done:
    pop     r15
    pop     r14
    pop     rbx
    ret

; ───────────────────────────────────────────────────────────────────
; Locale detection: check if environment uses UTF-8
; Sets utf8_mode = 1 if LC_ALL, LC_CTYPE, or LANG contains "UTF-8" or "utf8"
; Priority: LC_ALL > LC_CTYPE > LANG
; Uses: r12 = argc, r13 = &argv[0]
; envp starts at r13 + (r12+1)*8
; ───────────────────────────────────────────────────────────────────
detect_utf8_locale:
    push    rbx
    push    r14
    push    r15

    mov     byte [rel utf8_mode], 0

    ; envp = r13 + (r12+1)*8
    lea     rbx, [r12 + 1]
    lea     rbx, [r13 + rbx * 8]   ; rbx = envp

    ; Scan environment in priority order: LC_ALL, LC_CTYPE, LANG
    ; For each, find the matching env var and check for UTF-8

    ; First pass: find LC_ALL, LC_CTYPE, LANG values
    xor     r14, r14                ; LC_ALL value (0 = not found)
    xor     r15, r15                ; LC_CTYPE value
    mov     qword [rsp - 8], 0     ; LANG value (use red zone)

.env_loop:
    mov     rdi, [rbx]
    test    rdi, rdi
    jz      .env_done

    ; Check for "LC_ALL="
    cmp     dword [rdi], 'LC_A'
    jne     .env_not_lc_all
    cmp     word [rdi + 4], 'LL'
    jne     .env_not_lc_all
    cmp     byte [rdi + 6], '='
    jne     .env_not_lc_all
    lea     r14, [rdi + 7]          ; value after "LC_ALL="
    jmp     .env_next

.env_not_lc_all:
    ; Check for "LC_CTYPE="
    cmp     dword [rdi], 'LC_C'
    jne     .env_not_lc_ctype
    cmp     dword [rdi + 4], 'TYPE'
    jne     .env_not_lc_ctype
    cmp     byte [rdi + 8], '='
    jne     .env_not_lc_ctype
    lea     r15, [rdi + 9]          ; value after "LC_CTYPE="
    jmp     .env_next

.env_not_lc_ctype:
    ; Check for "LANG="
    cmp     dword [rdi], 'LANG'
    jne     .env_next
    cmp     byte [rdi + 4], '='
    jne     .env_next
    lea     rax, [rdi + 5]
    mov     [rsp - 8], rax          ; LANG value

.env_next:
    add     rbx, 8
    jmp     .env_loop

.env_done:
    ; Priority: LC_ALL > LC_CTYPE > LANG
    ; Use LC_ALL if non-empty, else LC_CTYPE, else LANG
    mov     rdi, r14                ; try LC_ALL
    test    rdi, rdi
    jz      .try_lc_ctype
    cmp     byte [rdi], 0
    jne     .check_utf8
.try_lc_ctype:
    mov     rdi, r15                ; try LC_CTYPE
    test    rdi, rdi
    jz      .try_lang
    cmp     byte [rdi], 0
    jne     .check_utf8
.try_lang:
    mov     rdi, [rsp - 8]          ; try LANG
    test    rdi, rdi
    jz      .locale_done
    cmp     byte [rdi], 0
    je      .locale_done

.check_utf8:
    ; Check if the locale string contains "UTF-8", "utf-8", "UTF8", "utf8"
    ; Simple approach: scan for 'U'/'u' followed by 'T'/'t' 'F'/'f' '-'? '8'
    ; Simpler: just check for ".UTF-8", ".utf-8", ".UTF8", ".utf8" or "UTF-8" at start
    ; Even simpler: scan for "UTF" or "utf" (case insensitive) followed by optional '-' then '8'
.utf_scan:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .locale_done

    ; Check for 'U' or 'u'
    or      al, 0x20                ; to lowercase
    cmp     al, 'u'
    jne     .utf_scan_next
    ; Check 'T'/'t'
    movzx   eax, byte [rdi + 1]
    or      al, 0x20
    cmp     al, 't'
    jne     .utf_scan_next
    ; Check 'F'/'f'
    movzx   eax, byte [rdi + 2]
    or      al, 0x20
    cmp     al, 'f'
    jne     .utf_scan_next
    ; Check optional '-' then '8'
    movzx   eax, byte [rdi + 3]
    cmp     al, '-'
    je      .utf_check_8_at_4
    cmp     al, '8'
    je      .found_utf8
    jmp     .utf_scan_next
.utf_check_8_at_4:
    cmp     byte [rdi + 4], '8'
    je      .found_utf8
.utf_scan_next:
    inc     rdi
    jmp     .utf_scan

.found_utf8:
    mov     byte [rel utf8_mode], 1

.locale_done:
    pop     r15
    pop     r14
    pop     rbx
    ret

; ───────────────────────────────────────────────────────────────────
; Binary search in sorted (u16 lo, u16 hi) range table
; Input: eax = code point (16-bit value to search for)
;        rdi = table base pointer
;        edx = number of ranges
; Output: CF=1 if found in a range, CF=0 if not
; Clobbers: r15d, edx, edi (but rdi base is only used via r15 offset)
; Preserves: eax, rsi, rcx, r8-r11, rbx, rbp
; ───────────────────────────────────────────────────────────────────
bsearch_range16:
    push    rcx                     ; save remaining byte count
    mov     ecx, edx                ; hi = count
    dec     ecx                     ; hi = count - 1
    xor     edx, edx                ; lo = 0
    js      .bs_not_found           ; count was 0

.bs_loop:
    cmp     edx, ecx
    jg      .bs_not_found

    ; mid = (lo + hi) / 2
    lea     r15d, [edx + ecx]
    shr     r15d, 1

    ; Compare with range[mid]
    cmp     ax, [rdi + r15 * 4]     ; range[mid].lo
    jb      .bs_go_left
    cmp     ax, [rdi + r15 * 4 + 2] ; range[mid].hi
    ja      .bs_go_right

    ; Found — in range
    pop     rcx
    stc
    ret

.bs_go_left:
    lea     ecx, [r15d - 1]        ; hi = mid - 1
    jmp     .bs_loop

.bs_go_right:
    lea     edx, [r15d + 1]        ; lo = mid + 1
    jmp     .bs_loop

.bs_not_found:
    pop     rcx
    clc
    ret

; ───────────────────────────────────────────────────────────────────
; String comparison: str_eq(rdi=s1, rsi=s2) -> eax=1 if equal, 0 if not
; ───────────────────────────────────────────────────────────────────
str_eq:
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

; ───────────────────────────────────────────────────────────────────
; String prefix check: str_prefix(rdi=str, rsi=prefix, rdx=prefix_len)
;   -> eax=1 if str starts with prefix
; ───────────────────────────────────────────────────────────────────
str_prefix:
    xor     ecx, ecx
.loop:
    cmp     rcx, rdx
    jge     .match
    movzx   eax, byte [rdi + rcx]
    cmp     al, [rsi + rcx]
    jne     .no_match
    inc     rcx
    jmp     .loop
.match:
    mov     eax, 1
    ret
.no_match:
    xor     eax, eax
    ret

; ───────────────────────────────────────────────────────────────────
; Print unrecognized option error
; ───────────────────────────────────────────────────────────────────
err_unrecognized_opt:
    push    rdi                     ; save bad option string, stack now 0-mod-16
    mov     rdi, STDERR
    lea     rsi, [rel str_wc_prefix]
    mov     rdx, str_wc_prefix_len
    call    asm_write_all

    lea     rdi, [rel str_unrec_opt]
    call    asm_strlen
    mov     rdx, rax
    lea     rsi, [rel str_unrec_opt]
    mov     rdi, STDERR
    call    asm_write_all

    ; Read saved option string without popping (keeps stack aligned)
    mov     rdi, [rsp]
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, [rsp]
    mov     rdi, STDERR
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_unrec_opt2]
    mov     rdx, 2
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all
    add     rsp, 8                  ; clean up pushed rdi
    ret

; ───────────────────────────────────────────────────────────────────
; Read files from --files0-from source
; ───────────────────────────────────────────────────────────────────
read_files0_from:
    push    rbx
    push    r14
    push    r15

    mov     rdi, [rel files0_from_ptr]

    ; Check if it's "-" (stdin)
    cmp     byte [rdi], '-'
    jne     .open_file
    cmp     byte [rdi + 1], 0
    jne     .open_file
    ; Use stdin (fd 0)
    xor     ebx, ebx                ; fd = 0
    jmp     .read_names

.open_file:
    mov     rsi, O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .open_error
    mov     rbx, rax                ; fd

.read_names:
    ; Read entire content into files0_buf
    lea     rsi, [rel files0_buf]
    mov     rdi, rbx
    mov     rdx, BUF_SIZE - 1
    call    asm_read
    test    rax, rax
    js      .read_error
    mov     r14, rax                ; bytes read

    ; Close file if not stdin
    test    ebx, ebx
    jz      .parse_names
    mov     rdi, rbx
    call    asm_close

.parse_names:
    ; Parse NUL-delimited filenames
    lea     rsi, [rel files0_buf]
    xor     r15d, r15d              ; file count
    xor     ecx, ecx                ; position

.name_loop:
    cmp     rcx, r14
    jge     .names_done

    ; Skip NUL bytes
    cmp     byte [rsi + rcx], 0
    jne     .name_start
    inc     rcx
    jmp     .name_loop

.name_start:
    ; Start of a filename
    lea     rax, [rsi + rcx]
    lea     rdi, [rel file_ptrs]
    mov     [rdi + r15 * 8], rax
    inc     r15

    ; Skip to next NUL
.name_skip:
    inc     rcx
    cmp     rcx, r14
    jge     .names_done
    cmp     byte [rsi + rcx], 0
    jne     .name_skip
    jmp     .name_loop

.names_done:
    mov     [rel file_count], r15
    pop     r15
    pop     r14
    pop     rbx
    ret

.open_error:
.read_error:
    ; Print error and exit
    mov     rdi, STDERR
    lea     rsi, [rel str_wc_prefix]
    mov     rdx, str_wc_prefix_len
    call    asm_write_all
    mov     edi, 1
    EXIT    rdi

; ───────────────────────────────────────────────────────────────────
; Process all files, compute totals, format output
; ───────────────────────────────────────────────────────────────────
process_all_files:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8                  ; align stack

    xor     ebx, ebx                ; file index (input)
    xor     ebp, ebp                ; result index (output, only successful files)
    mov     byte [rel had_error], 0

    ; Zero total counts
    lea     rdi, [rel total_lines]
    xor     eax, eax
    mov     [rdi], rax              ; total_lines
    mov     [rdi + 8], rax          ; total_words
    mov     [rdi + 16], rax         ; total_bytes
    mov     [rdi + 24], rax         ; total_chars
    mov     [rdi + 32], rax         ; total_maxlen

.file_loop:
    cmp     rbx, [rel file_count]
    jge     .files_done

    ; Get filename
    lea     rax, [rel file_ptrs]
    mov     rdi, [rax + rbx * 8]    ; filename ptr

    ; Check if it's stdin ("-")
    cmp     byte [rdi], '-'
    jne     .open_regular
    cmp     byte [rdi + 1], 0
    jne     .open_regular

    ; Stdin
    xor     r14d, r14d              ; fd = 0 (stdin)
    mov     r15, rdi                ; save filename ptr
    mov     byte [rel has_stdin], 1
    mov     byte [rel has_nonreg], 1
    jmp     .do_count

.open_regular:
    mov     r15, rdi                ; save filename ptr

    ; Check for bytes-only optimization: use fstat
    movzx   eax, byte [rel show_flags]
    cmp     al, FLAG_BYTES
    jne     .open_and_read

    ; -c only: try fstat to get file size
    mov     rsi, O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .file_error
    mov     r14, rax                ; fd

    FSTAT   r14, stat_buf
    test    rax, rax
    js      .close_and_count        ; fstat failed, fall back to reading

    ; Check if it's a regular file
    mov     eax, [rel stat_buf + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFREG
    je      .is_regular_c_only
    mov     byte [rel has_nonreg], 1
    jmp     .close_and_count        ; not regular file, must read
.is_regular_c_only:

    ; Get file size from stat
    mov     rax, [rel stat_buf + STAT_SIZE]
    xor     ecx, ecx
    mov     qword [rel cur_lines], 0
    mov     qword [rel cur_words], 0
    mov     [rel cur_bytes], rax
    mov     qword [rel cur_chars], 0
    mov     qword [rel cur_maxlen], 0

    ; Close file
    mov     rdi, r14
    call    asm_close

    jmp     .accumulate

.close_and_count:
    ; fstat failed or not regular file, fall back to reading
    ; fd is already in r14
    jmp     .do_count

.open_and_read:
    mov     rdi, r15
    mov     rsi, O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .file_error
    mov     r14, rax                ; fd

    ; Check if regular file for column width heuristic
    FSTAT   r14, stat_buf
    test    rax, rax
    js      .open_nonreg            ; fstat failed, assume non-regular
    mov     eax, [rel stat_buf + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFREG
    je      .do_count
.open_nonreg:
    mov     byte [rel has_nonreg], 1

.do_count:
    ; Count the file contents
    ; r14 = fd, results go to cur_lines/words/bytes/chars/maxlen
    mov     qword [rel cur_lines], 0
    mov     qword [rel cur_words], 0
    mov     qword [rel cur_bytes], 0
    mov     qword [rel cur_chars], 0
    mov     qword [rel cur_maxlen], 0
    mov     qword [rel cur_line_len], 0
    mov     byte [rel prev_was_space], 1   ; start "in whitespace" for word counting

    ; Determine what to count based on flags
    movzx   eax, byte [rel show_flags]
    mov     [rel cur_flags], al

.read_loop:
    mov     rdi, r14
    lea     rsi, [rel read_buf]
    mov     rdx, BUF_SIZE
    call    asm_read

    test    rax, rax
    js      .read_error_file
    jz      .read_done              ; EOF

    ; rax = bytes read
    add     [rel cur_bytes], rax

    ; Count based on active flags
    lea     rsi, [rel read_buf]
    mov     rcx, rax                ; byte count
    call    count_chunk

    jmp     .read_loop

.read_done:
    ; Final max line length update: check if last line (no trailing newline)
    ; has a longer length than the current max
    movzx   eax, byte [rel show_flags]
    test    al, FLAG_MAXLEN
    jz      .skip_final_maxlen
    mov     rax, [rel cur_line_len]
    cmp     rax, [rel cur_maxlen]
    jbe     .skip_final_maxlen
    mov     [rel cur_maxlen], rax
.skip_final_maxlen:

    ; Close file if not stdin
    test    r14d, r14d
    jz      .accumulate
    mov     rdi, r14
    call    asm_close

.accumulate:
    ; Accumulate into totals
    mov     rax, [rel cur_lines]
    add     [rel total_lines], rax
    mov     rax, [rel cur_words]
    add     [rel total_words], rax
    mov     rax, [rel cur_bytes]
    add     [rel total_bytes], rax
    mov     rax, [rel cur_chars]
    add     [rel total_chars], rax
    mov     rax, [rel cur_maxlen]
    cmp     rax, [rel total_maxlen]
    jbe     .no_update_maxlen
    mov     [rel total_maxlen], rax
.no_update_maxlen:

    ; Store results using result index (rbp), not file index (rbx)
    lea     rdi, [rel results]
    imul    rax, rbp, 40           ; 5 * 8 bytes per result
    mov     rcx, [rel cur_lines]
    mov     [rdi + rax], rcx
    mov     rcx, [rel cur_words]
    mov     [rdi + rax + 8], rcx
    mov     rcx, [rel cur_bytes]
    mov     [rdi + rax + 16], rcx
    mov     rcx, [rel cur_chars]
    mov     [rdi + rax + 24], rcx
    mov     rcx, [rel cur_maxlen]
    mov     [rdi + rax + 32], rcx

    ; Store display name for this result
    ; For stdin: use empty string if implicit, "-" if explicit
    lea     rdi, [rel result_names]
    mov     rax, r15                ; filename ptr
    cmp     byte [r15], '-'
    jne     .store_name
    cmp     byte [r15 + 1], 0
    jne     .store_name
    ; It's "-" (stdin)
    cmp     byte [rel stdin_implicit], 1
    jne     .store_name             ; explicit "-", keep it
    lea     rax, [rel empty_str]    ; implicit stdin: empty display name
.store_name:
    mov     [rdi + rbp * 8], rax

    inc     rbp                     ; result index
    inc     rbx                     ; file index
    jmp     .file_loop

.file_error:
    ; rax has negative errno
    neg     rax
    mov     r14, rax                ; save errno
    ; Print error: "wc: filename: error\n"
    call    print_file_error
    mov     byte [rel had_error], 1
    inc     rbx
    jmp     .file_loop

.read_error_file:
    neg     rax
    push    rax                     ; save errno
    ; Close fd if not stdin
    test    r14d, r14d
    jz      .read_err_report
    mov     rdi, r14
    call    asm_close
.read_err_report:
    pop     r14                     ; errno
    call    print_file_error
    mov     byte [rel had_error], 1
    jmp     .accumulate             ; still store (zero) results for this file

.files_done:
    ; Store result count
    mov     [rel result_count], rbp

    ; Now compute column width and print results
    call    compute_width_and_print

    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ───────────────────────────────────────────────────────────────────
; Print file error message
; r15 = filename ptr, r14 = errno
; ───────────────────────────────────────────────────────────────────
print_file_error:
    push    rbx
    ; "wc: "
    mov     rdi, STDERR
    lea     rsi, [rel str_wc_prefix]
    mov     rdx, str_wc_prefix_len
    call    asm_write_all

    ; filename
    mov     rdi, r15
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, r15
    mov     rdi, STDERR
    call    asm_write_all

    ; ": "
    mov     byte [rel itoa_buf], ':'
    mov     byte [rel itoa_buf + 1], ' '
    mov     rdi, STDERR
    lea     rsi, [rel itoa_buf]
    mov     rdx, 2
    call    asm_write_all

    ; Error message based on errno
    cmp     r14, 2                  ; ENOENT
    je      .err_noent
    cmp     r14, 13                 ; EACCES
    je      .err_acces
    cmp     r14, 21                 ; EISDIR
    je      .err_isdir
    jmp     .err_generic

.err_noent:
    lea     rsi, [rel str_enoent]
    mov     rdx, 26                 ; "No such file or directory\n"
    jmp     .err_write
.err_acces:
    lea     rsi, [rel str_eacces]
    mov     rdx, 18                 ; "Permission denied\n"
    jmp     .err_write
.err_isdir:
    lea     rsi, [rel str_eisdir]
    mov     rdx, 15                 ; "Is a directory\n"
    jmp     .err_write
.err_generic:
    lea     rsi, [rel str_generic_err]
    mov     rdx, 6                  ; "Error\n"
.err_write:
    mov     rdi, STDERR
    call    asm_write_all
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════════════
; Counting engine — processes a chunk of data
; rsi = buffer, rcx = length
; Updates cur_lines, cur_words, cur_bytes, cur_chars, cur_maxlen
; ═══════════════════════════════════════════════════════════════════
count_chunk:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, rsi                ; buffer ptr
    mov     r13, rcx                ; length
    movzx   eax, byte [rel cur_flags]
    mov     r14d, eax               ; flags in r14d

    ; Determine if we need word counting (most complex path)
    test    r14d, FLAG_WORDS
    jnz     .full_count

    ; Lines only? Use SIMD fast path
    test    r14d, FLAG_LINES
    jz      .check_chars_only
    ; Check if ONLY lines (no other flags that need content scan)
    mov     eax, r14d
    and     eax, ~(FLAG_LINES | FLAG_BYTES)  ; bytes are tracked separately
    jz      .lines_only_simd

.check_chars_only:
    ; Check if we need chars or maxlen
    test    r14d, FLAG_CHARS | FLAG_MAXLEN
    jz      .count_done             ; only bytes, already counted

    ; Need chars and/or maxlen (and possibly lines)
    jmp     .full_count

.lines_only_simd:
    ; ─── SIMD line counting (SSE2) ───
    ; Count newlines using pcmpeqb + pmovmskb + popcnt
    mov     rsi, r12
    mov     rcx, r13
    xor     r15d, r15d              ; line count accumulator

    movdqa  xmm1, [rel vec_newline]

    ; Process 16 bytes at a time
    cmp     rcx, 16
    jl      .lines_simd_tail

.lines_simd_loop:
    movdqu  xmm0, [rsi]
    pcmpeqb xmm0, xmm1             ; compare with '\n'
    pmovmskb eax, xmm0             ; extract bit mask
    popcnt  eax, eax                ; count set bits
    add     r15, rax
    add     rsi, 16
    sub     rcx, 16
    cmp     rcx, 16
    jge     .lines_simd_loop

.lines_simd_tail:
    ; Process remaining bytes scalar
    test    rcx, rcx
    jz      .lines_simd_done

.lines_scalar_loop:
    cmp     byte [rsi], 10          ; '\n'
    jne     .lines_not_nl
    inc     r15
.lines_not_nl:
    inc     rsi
    dec     rcx
    jnz     .lines_scalar_loop

.lines_simd_done:
    add     [rel cur_lines], r15
    jmp     .count_done

.full_count:
    ; ─── Full counting: lines, words, chars, maxlen ───
    ; Scalar loop that handles all metrics in a single pass
    mov     rsi, r12                ; buffer
    mov     rcx, r13                ; length
    xor     r8d, r8d                ; line count
    xor     r9d, r9d                ; word count
    xor     r10d, r10d              ; char count
    mov     r11, [rel cur_maxlen]   ; max line length
    mov     rbp, [rel cur_line_len] ; current line length (persisted across chunks)
    movzx   ebx, byte [rel prev_was_space]  ; prev whitespace state

    ; Word counting requires scalar path due to isprint() semantics
    ; (non-printable bytes don't start/end words, only printable ones do)
    ; SIMD is only used for lines-only counting (above)

.scalar_only:
    ; ─── Scalar counting loop ───
    test    rcx, rcx
    jz      .full_count_done

.scalar_loop:
    movzx   eax, byte [rsi]

    ; Check if whitespace
    cmp     al, 0x20                ; space
    je      .is_ws
    cmp     al, 0x09                ; tab
    je      .is_ws
    cmp     al, 0x0A                ; newline
    je      .is_newline
    cmp     al, 0x0D                ; CR
    je      .is_cr
    cmp     al, 0x0C                ; FF
    je      .is_ws
    cmp     al, 0x0B                ; VT
    je      .is_ws
    cmp     al, 0x08                ; backspace
    je      .is_backspace

    ; Non-whitespace byte: check if printable or multi-byte
    cmp     al, 0x21
    jb      .non_printable          ; < 0x21: non-printable (and not whitespace)
    cmp     al, 0x7E
    jbe     .ascii_printable        ; 0x21-0x7E: ASCII printable

    ; Byte > 0x7E: check for UTF-8 multi-byte sequence
    cmp     byte [rel utf8_mode], 0
    je      .non_printable          ; C locale: all > 0x7E are non-printable

    ; ─── UTF-8 multi-byte decode ───
    ; al has lead byte (0x80-0xFF)
    cmp     al, 0xBF
    jbe     .non_printable          ; 0x80-0xBF: continuation byte (invalid as lead)
    cmp     al, 0xC1
    jbe     .non_printable          ; 0xC0-0xC1: overlong 2-byte (invalid)

    cmp     al, 0xDF
    jbe     .utf8_2byte             ; 0xC2-0xDF: 2-byte sequence
    cmp     al, 0xEF
    jbe     .utf8_3byte             ; 0xE0-0xEF: 3-byte sequence
    cmp     al, 0xF4
    jbe     .utf8_4byte             ; 0xF0-0xF4: 4-byte sequence
    jmp     .non_printable          ; 0xF5-0xFF: invalid

.utf8_2byte:
    cmp     rcx, 2
    jb      .non_printable          ; not enough bytes
    movzx   edi, byte [rsi + 1]
    mov     edx, edi
    and     edx, 0xC0
    cmp     edx, 0x80
    jne     .non_printable          ; not a valid continuation byte
    ; Decode: cp = (al & 0x1F) << 6 | (edi & 0x3F)
    and     eax, 0x1F
    shl     eax, 6
    and     edi, 0x3F
    or      eax, edi
    ; Consume 1 extra byte (scalar_next will consume 1 more)
    inc     rsi
    dec     rcx
    jmp     .utf8_got_cp

.utf8_3byte:
    cmp     rcx, 3
    jb      .non_printable
    movzx   edi, byte [rsi + 1]
    mov     edx, edi
    and     edx, 0xC0
    cmp     edx, 0x80
    jne     .non_printable
    movzx   edx, byte [rsi + 2]
    push    rdx
    and     edx, 0xC0
    cmp     edx, 0x80
    pop     rdx                     ; restore full byte 2
    jne     .non_printable
    ; Decode: cp = (al & 0x0F) << 12 | (edi & 0x3F) << 6 | (edx & 0x3F)
    and     eax, 0x0F
    shl     eax, 12
    and     edi, 0x3F
    shl     edi, 6
    or      eax, edi
    and     edx, 0x3F
    or      eax, edx
    ; Check for overlong (must be >= 0x0800) and surrogates (0xD800-0xDFFF)
    cmp     eax, 0x0800
    jb      .utf8_3byte_invalid
    cmp     eax, 0xD800
    jb      .utf8_3byte_ok
    cmp     eax, 0xDFFF
    jbe     .utf8_3byte_invalid     ; surrogate: invalid
.utf8_3byte_ok:
    ; Consume 2 extra bytes
    add     rsi, 2
    sub     rcx, 2
    jmp     .utf8_got_cp
.utf8_3byte_invalid:
    ; Invalid sequence — treat lead byte as non-printable, don't consume extras
    jmp     .non_printable

.utf8_4byte:
    cmp     rcx, 4
    jb      .non_printable
    ; Validate all 3 continuation bytes
    movzx   edi, byte [rsi + 1]
    mov     edx, edi
    and     edx, 0xC0
    cmp     edx, 0x80
    jne     .non_printable
    movzx   edx, byte [rsi + 2]
    push    rdx
    and     edx, 0xC0
    cmp     edx, 0x80
    pop     rdx
    jne     .non_printable
    push    rdx                     ; save byte 2
    movzx   edx, byte [rsi + 3]
    push    rdx                     ; save byte 3
    and     edx, 0xC0
    cmp     edx, 0x80
    pop     rdx                     ; restore byte 3
    jne     .utf8_4byte_bad
    ; Decode: cp = (al & 0x07) << 18 | (cont1 & 0x3F) << 12 | (cont2 & 0x3F) << 6 | (cont3 & 0x3F)
    and     eax, 0x07
    shl     eax, 18
    and     edi, 0x3F
    shl     edi, 12
    or      eax, edi
    pop     rdi                     ; byte 2 (was pushed as rdx)
    and     edi, 0x3F
    shl     edi, 6
    or      eax, edi
    and     edx, 0x3F
    or      eax, edx
    ; Check valid range (must be 0x10000-0x10FFFF)
    cmp     eax, 0x10000
    jb      .non_printable
    cmp     eax, 0x10FFFF
    ja      .non_printable
    ; Consume 3 extra bytes
    add     rsi, 3
    sub     rcx, 3
    jmp     .utf8_got_cp_nonbmp
.utf8_4byte_bad:
    pop     rdx                     ; clean up saved byte 2
    jmp     .non_printable

.utf8_got_cp:
    ; eax = code point (BMP: 0x0080 - 0xFFFF)
    ; Check if printable: cp >= 0xA0 → printable in Unicode
    cmp     eax, 0xA0
    jb      .utf8_ctrl              ; 0x80-0x9F: C1 control chars

    ; Printable multi-byte char — update words
    test    ebx, ebx
    jz      .utf8_not_word_start
    inc     r9d                     ; new word
.utf8_not_word_start:
    xor     ebx, ebx                ; in_word = true

    ; Char counting: 1 character for the whole multi-byte sequence
    test    r14d, FLAG_CHARS
    jz      .utf8_no_char
    inc     r10d
.utf8_no_char:

    ; Max line length: look up width in BMP tables
    test    r14d, FLAG_MAXLEN
    jz      .scalar_next

    ; Binary search zero_ranges first (width 0)
    push    rax
    lea     rdi, [rel zero_ranges]
    mov     edx, ZERO_COUNT
    call    bsearch_range16
    jc      .utf8_width_0

    ; Binary search wide_ranges (width 2)
    lea     rdi, [rel wide_ranges]
    mov     edx, WIDE_COUNT
    call    bsearch_range16
    jc      .utf8_width_2

    ; Default: width 1
    pop     rax
    inc     ebp
    jmp     .scalar_next

.utf8_width_0:
    pop     rax
    ; width 0: don't increment ebp
    jmp     .scalar_next

.utf8_width_2:
    pop     rax
    add     ebp, 2
    jmp     .scalar_next

.utf8_ctrl:
    ; C1 control character (0x80-0x9F): non-printable
    ; Don't change word state, display width 0
    test    r14d, FLAG_CHARS
    jz      .scalar_next
    inc     r10d                    ; still a character for -m
    jmp     .scalar_next

.utf8_got_cp_nonbmp:
    ; eax = non-BMP code point (0x10000 - 0x10FFFF)
    ; Always printable (non-BMP control chars are extremely rare)
    test    ebx, ebx
    jz      .utf8_nonbmp_not_ws
    inc     r9d
.utf8_nonbmp_not_ws:
    xor     ebx, ebx                ; in_word = true

    test    r14d, FLAG_CHARS
    jz      .utf8_nonbmp_no_char
    inc     r10d
.utf8_nonbmp_no_char:

    test    r14d, FLAG_MAXLEN
    jz      .scalar_next

    ; Simplified non-BMP width heuristic
    cmp     eax, 0x20000
    jae     .utf8_nonbmp_wide       ; CJK supplementary → width 2
    cmp     eax, 0x16FE0
    jb      .utf8_nonbmp_check_emoji
    cmp     eax, 0x18D08
    jbe     .utf8_nonbmp_wide       ; Tangut etc → width 2
.utf8_nonbmp_check_emoji:
    cmp     eax, 0x1F000
    jb      .utf8_nonbmp_w1
    cmp     eax, 0x1FAFF
    jbe     .utf8_nonbmp_wide       ; Emoji range → width 2
    cmp     eax, 0x1B000
    jb      .utf8_nonbmp_w1
    cmp     eax, 0x1B2FB
    jbe     .utf8_nonbmp_wide       ; Kana supplement → width 2
.utf8_nonbmp_w1:
    ; Check for non-BMP zero-width (variation selectors etc)
    cmp     eax, 0xE0100
    jb      .utf8_nonbmp_default_w1
    cmp     eax, 0xE01EF
    jbe     .scalar_next            ; variation selector: width 0
.utf8_nonbmp_default_w1:
    inc     ebp                     ; default: width 1
    jmp     .scalar_next
.utf8_nonbmp_wide:
    add     ebp, 2
    jmp     .scalar_next

.ascii_printable:
    ; ASCII printable non-whitespace (0x21-0x7E)
    ; Check if this starts a new word
    test    ebx, ebx                ; was not-in-word? (1 = not in word)
    jz      .not_word_start
    inc     r9d                     ; word count++ (transition: not-in-word → in-word)
.not_word_start:
    xor     ebx, ebx                ; in_word = true (prev_was_space = 0)

    ; Chars counting
    test    r14d, FLAG_CHARS
    jz      .printable_no_char
    inc     r10d                    ; printable char is always a character
.printable_no_char:

    ; Max line length: printable char has display width 1
    test    r14d, FLAG_MAXLEN
    jz      .scalar_next
    inc     ebp
    jmp     .scalar_next

.non_printable:
    ; Non-printable, non-whitespace byte: don't change in_word state
    ; Display width = 0 for max line length

    ; Chars counting: in C locale, every byte is a character
    ; In UTF-8 mode, bytes > 0x7F that fail validation are NOT characters
    ; (matches GNU wc mbrtowc behavior: invalid bytes are silently skipped)
    test    r14d, FLAG_CHARS
    jz      .scalar_next
    cmp     byte [rel utf8_mode], 0
    je      .np_count_char          ; C locale: always count
    cmp     al, 0x80
    jae     .scalar_next            ; UTF-8 mode: skip invalid high bytes
.np_count_char:
    inc     r10d
    ; Max line length: non-printable has display width 0, don't increment ebp
    jmp     .scalar_next

.is_newline:
    inc     r8d                     ; line count++
    mov     ebx, 1                  ; not in word

    ; Chars: newline is a character
    test    r14d, FLAG_CHARS
    jz      .nl_no_char
    inc     r10d
.nl_no_char:

    ; Max line length update
    test    r14d, FLAG_MAXLEN
    jz      .scalar_next
    cmp     rbp, r11
    jbe     .nl_no_max_update
    mov     r11, rbp
.nl_no_max_update:
    xor     ebp, ebp                ; reset current line length
    jmp     .scalar_next

.is_ws:
    mov     ebx, 1                  ; not in word

    ; Chars: whitespace chars are characters too
    test    r14d, FLAG_CHARS
    jz      .ws_no_char
    inc     r10d                    ; all ASCII whitespace are single-byte chars
.ws_no_char:

    ; Max line length for whitespace:
    ; - Space (0x20): display width 1
    ; - Tab (0x09): advance to next 8-column tabstop
    ; - Other whitespace (CR, FF, VT): display width 0
    test    r14d, FLAG_MAXLEN
    jz      .scalar_next
    cmp     al, 0x20                ; space?
    je      .ws_width_1
    cmp     al, 0x09                ; tab?
    je      .ws_tab
    ; Other whitespace (CR, FF, VT): width 0
    jmp     .scalar_next

.ws_width_1:
    inc     ebp
    jmp     .scalar_next

.ws_tab:
    ; Tab: advance to next 8-column boundary
    ; new_col = (cur_col | 7) + 1
    or      ebp, 7
    inc     ebp
    jmp     .scalar_next

.is_cr:
    ; Carriage return: whitespace (ends word), resets column to 0
    mov     ebx, 1                  ; not in word
    test    r14d, FLAG_CHARS
    jz      .cr_no_char
    inc     r10d
.cr_no_char:
    test    r14d, FLAG_MAXLEN
    jz      .scalar_next
    xor     ebp, ebp                ; reset column to 0 (not updating max!)
    jmp     .scalar_next

.is_backspace:
    ; Backspace: non-whitespace, non-printable, display width -1
    ; Don't change in_word state
    test    r14d, FLAG_CHARS
    jz      .bs_no_char
    inc     r10d                    ; backspace is a character in C locale
.bs_no_char:
    test    r14d, FLAG_MAXLEN
    jz      .scalar_next
    test    ebp, ebp
    jz      .scalar_next            ; already at column 0
    dec     ebp                     ; move back one column
    jmp     .scalar_next

.scalar_next:
    inc     rsi
    dec     rcx
    jnz     .scalar_loop

.full_count_done:
    ; Store results back (do NOT update max for final line here — that's done at EOF)
    add     [rel cur_lines], r8
    add     [rel cur_words], r9
    add     [rel cur_chars], r10
    mov     [rel cur_maxlen], r11
    mov     [rel cur_line_len], rbp     ; persist current line length across chunks
    mov     [rel prev_was_space], bl

.count_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════════════
; Output formatting
; ═══════════════════════════════════════════════════════════════════

; Compute column width and print all results
compute_width_and_print:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    movzx   eax, byte [rel show_flags]
    mov     r14d, eax               ; flags

    mov     r12, [rel result_count] ; number of successful results

    ; Determine if we show totals
    ; For total, use file_count (including errored files) for auto decision
    movzx   eax, byte [rel total_mode]
    cmp     al, TOTAL_ALWAYS
    je      .show_total
    cmp     al, TOTAL_ONLY
    je      .show_total
    cmp     al, TOTAL_NEVER
    je      .no_total
    ; TOTAL_AUTO: show if more than 1 file was attempted
    mov     rcx, [rel file_count]
    cmp     rcx, 1
    jg      .show_total
.no_total:
    xor     r13d, r13d              ; show_total = false
    jmp     .compute_width
.show_total:
    mov     r13d, 1                 ; show_total = true

.compute_width:
    ; Count number of columns
    xor     ecx, ecx
    test    r14d, FLAG_LINES
    jz      .no_col_l
    inc     ecx
.no_col_l:
    test    r14d, FLAG_WORDS
    jz      .no_col_w
    inc     ecx
.no_col_w:
    test    r14d, FLAG_CHARS
    jz      .no_col_m
    inc     ecx
.no_col_m:
    test    r14d, FLAG_BYTES
    jz      .no_col_c
    inc     ecx
.no_col_c:
    test    r14d, FLAG_MAXLEN
    jz      .no_col_L
    inc     ecx
.no_col_L:
    mov     ebp, ecx                ; num_columns

    ; Compute number of output rows
    movzx   eax, byte [rel total_mode]
    cmp     al, TOTAL_ONLY
    je      .rows_only
    mov     rcx, r12                ; result count
    test    r13d, r13d
    jz      .no_add_total_row
    inc     rcx
.no_add_total_row:
    mov     r15, rcx                ; num_output_rows
    jmp     .calc_width

.rows_only:
    mov     r15, r13                ; 1 if show_total, 0 otherwise
    jmp     .calc_width_only

.calc_width_only:
    ; --total=only: use width 1 (natural width, no padding)
    mov     ebx, 1
    jmp     .do_print

.calc_width:
    ; Check for single value output (single column, single row)
    cmp     ebp, 1
    jg      .multi_col_width
    cmp     r15, 1
    jg      .multi_col_width

    ; Single value: use natural width
    ; Determine which single value based on the sole result
    cmp     r12, 0
    je      .sw_use_totals
    ; Use the first result's values
    lea     rax, [rel results]
    test    r14d, FLAG_LINES
    jz      .sw1_not_lines
    mov     rdi, [rax]
    jmp     .sw_calc
.sw1_not_lines:
    test    r14d, FLAG_WORDS
    jz      .sw1_not_words
    mov     rdi, [rax + 8]
    jmp     .sw_calc
.sw1_not_words:
    test    r14d, FLAG_CHARS
    jz      .sw1_not_chars
    mov     rdi, [rax + 24]
    jmp     .sw_calc
.sw1_not_chars:
    test    r14d, FLAG_BYTES
    jz      .sw1_not_bytes
    mov     rdi, [rax + 16]
    jmp     .sw_calc
.sw1_not_bytes:
    test    r14d, FLAG_MAXLEN
    jz      .sw_zero
    mov     rdi, [rax + 32]
    jmp     .sw_calc

.sw_use_totals:
    test    r14d, FLAG_LINES
    jz      .sw_not_lines
    mov     rdi, [rel total_lines]
    jmp     .sw_calc
.sw_not_lines:
    test    r14d, FLAG_WORDS
    jz      .sw_not_words
    mov     rdi, [rel total_words]
    jmp     .sw_calc
.sw_not_words:
    test    r14d, FLAG_CHARS
    jz      .sw_not_chars
    mov     rdi, [rel total_chars]
    jmp     .sw_calc
.sw_not_chars:
    test    r14d, FLAG_BYTES
    jz      .sw_not_bytes
    mov     rdi, [rel total_bytes]
    jmp     .sw_calc
.sw_not_bytes:
    test    r14d, FLAG_MAXLEN
    jz      .sw_zero
    mov     rdi, [rel total_maxlen]
    jmp     .sw_calc
.sw_zero:
    xor     edi, edi
.sw_calc:
    call    num_width
    mov     ebx, eax                ; width
    jmp     .do_print

.multi_col_width:
    ; Multiple columns or rows: max of all total values
    mov     rdi, [rel total_lines]
    mov     rsi, [rel total_words]
    cmp     rdi, rsi
    cmovl   rdi, rsi
    mov     rsi, [rel total_bytes]
    cmp     rdi, rsi
    cmovl   rdi, rsi
    mov     rsi, [rel total_chars]
    cmp     rdi, rsi
    cmovl   rdi, rsi
    mov     rsi, [rel total_maxlen]
    cmp     rdi, rsi
    cmovl   rdi, rsi

    call    num_width
    mov     ebx, eax

    ; Minimum width: 7 when any non-regular file is involved
    ; (stdin, char devices like /dev/null, directories, pipes, etc.)
    ; Matches GNU wc behavior: unknown file sizes default to width 7
    cmp     byte [rel has_nonreg], 1
    jne     .check_min_1
    cmp     ebx, 7
    jge     .do_print
    mov     ebx, 7
    jmp     .do_print

.check_min_1:
    ; Minimum width 1 (already guaranteed since num_width returns >= 1)

.do_print:
    ; ebx = column width
    ; Print each result
    movzx   eax, byte [rel total_mode]
    cmp     al, TOTAL_ONLY
    je      .skip_individual

    xor     ecx, ecx                ; result index
.print_loop:
    cmp     rcx, r12
    jge     .print_total

    push    rcx
    push    rbx

    ; Get results for this result
    lea     rdi, [rel results]
    imul    rax, rcx, 40
    lea     rdi, [rdi + rax]        ; point to this result's counts

    ; Get display name from result_names
    lea     rax, [rel result_names]
    mov     rsi, [rax + rcx * 8]

    pop     rbx
    push    rbx

    ; rdi = results ptr, rsi = display name, ebx = width
    call    print_one_result

    pop     rbx
    pop     rcx
    inc     rcx
    jmp     .print_loop

.skip_individual:

.print_total:
    test    r13d, r13d              ; show_total?
    jz      .print_done

    ; Print total line
    push    rbx
    lea     rdi, [rel total_lines]  ; total results
    movzx   eax, byte [rel total_mode]
    cmp     al, TOTAL_ONLY
    je      .total_no_label
    lea     rsi, [rel str_total]    ; "total"
    jmp     .print_total_line
.total_no_label:
    lea     rsi, [rel empty_str]    ; no label for --total=only
.print_total_line:
    pop     rbx
    call    print_one_result

.print_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ───────────────────────────────────────────────────────────────────
; Print one result line
; rdi = pointer to 5 u64s (lines, words, bytes, chars, maxlen)
; rsi = filename (null-terminated, or NULL for no name)
; ebx = column width
; ───────────────────────────────────────────────────────────────────
print_one_result:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi                ; results ptr
    mov     r13, rsi                ; filename
    mov     r14d, ebx               ; width
    movzx   r15d, byte [rel show_flags]

    ; Build output line in line_buf
    lea     rdi, [rel line_buf]
    xor     ecx, ecx                ; position in line_buf
    xor     ebx, ebx                ; first field flag (0 = first)

    ; Lines
    test    r15d, FLAG_LINES
    jz      .pr_no_lines
    test    ebx, ebx
    jz      .pr_lines_first
    mov     byte [rdi + rcx], ' '
    inc     rcx
.pr_lines_first:
    mov     rsi, [r12]              ; lines count
    push    rdi
    push    rcx
    mov     rdi, rsi                ; value
    mov     esi, r14d               ; width
    lea     rdx, [rel line_buf]
    add     rdx, rcx                ; dest
    call    fmt_u64_right
    pop     rcx
    pop     rdi
    add     rcx, rax                ; advance position
    mov     ebx, 1
.pr_no_lines:

    ; Words
    test    r15d, FLAG_WORDS
    jz      .pr_no_words
    test    ebx, ebx
    jz      .pr_words_first
    mov     byte [rdi + rcx], ' '
    inc     rcx
.pr_words_first:
    mov     rsi, [r12 + 8]          ; words count
    push    rdi
    push    rcx
    mov     rdi, rsi
    mov     esi, r14d
    lea     rdx, [rel line_buf]
    add     rdx, rcx
    call    fmt_u64_right
    pop     rcx
    pop     rdi
    add     rcx, rax
    mov     ebx, 1
.pr_no_words:

    ; Chars
    test    r15d, FLAG_CHARS
    jz      .pr_no_chars
    test    ebx, ebx
    jz      .pr_chars_first
    mov     byte [rdi + rcx], ' '
    inc     rcx
.pr_chars_first:
    mov     rsi, [r12 + 24]         ; chars count
    push    rdi
    push    rcx
    mov     rdi, rsi
    mov     esi, r14d
    lea     rdx, [rel line_buf]
    add     rdx, rcx
    call    fmt_u64_right
    pop     rcx
    pop     rdi
    add     rcx, rax
    mov     ebx, 1
.pr_no_chars:

    ; Bytes
    test    r15d, FLAG_BYTES
    jz      .pr_no_bytes
    test    ebx, ebx
    jz      .pr_bytes_first
    mov     byte [rdi + rcx], ' '
    inc     rcx
.pr_bytes_first:
    mov     rsi, [r12 + 16]         ; bytes count
    push    rdi
    push    rcx
    mov     rdi, rsi
    mov     esi, r14d
    lea     rdx, [rel line_buf]
    add     rdx, rcx
    call    fmt_u64_right
    pop     rcx
    pop     rdi
    add     rcx, rax
    mov     ebx, 1
.pr_no_bytes:

    ; Max line length
    test    r15d, FLAG_MAXLEN
    jz      .pr_no_maxlen
    test    ebx, ebx
    jz      .pr_maxlen_first
    mov     byte [rdi + rcx], ' '
    inc     rcx
.pr_maxlen_first:
    mov     rsi, [r12 + 32]         ; maxlen
    push    rdi
    push    rcx
    mov     rdi, rsi
    mov     esi, r14d
    lea     rdx, [rel line_buf]
    add     rdx, rcx
    call    fmt_u64_right
    pop     rcx
    pop     rdi
    add     rcx, rax
    mov     ebx, 1
.pr_no_maxlen:

    ; Filename (already resolved: empty_str for implicit stdin, actual name otherwise)
    test    r13, r13
    jz      .pr_no_name
    cmp     byte [r13], 0
    jz      .pr_no_name

.pr_print_name:
    mov     byte [rdi + rcx], ' '
    inc     rcx

    ; Copy filename
    push    rdi
    push    rcx
    mov     rdi, r13
    call    asm_strlen
    pop     rcx
    pop     rdi
    mov     rdx, rax                ; name length
    ; Copy name bytes
    push    rsi
    mov     rsi, r13
    lea     r8, [rdi + rcx]
    push    rcx
    mov     rcx, rdx
.copy_name:
    test    rcx, rcx
    jz      .copy_name_done
    movzx   eax, byte [rsi]
    mov     [r8], al
    inc     rsi
    inc     r8
    dec     rcx
    jmp     .copy_name
.copy_name_done:
    pop     rcx
    pop     rsi
    add     rcx, rdx

.pr_no_name:
    ; Add newline
    mov     byte [rdi + rcx], 10
    inc     rcx

    ; Write the line
    mov     rdi, STDOUT
    lea     rsi, [rel line_buf]
    mov     rdx, rcx
    call    write_with_retry

    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ───────────────────────────────────────────────────────────────────
; fmt_u64_right: format u64 right-aligned into buffer
; rdi = value, esi = width, rdx = dest buffer
; returns rax = number of bytes written
; ───────────────────────────────────────────────────────────────────
fmt_u64_right:
    push    rbx
    push    r12
    push    r13

    mov     r12, rdi                ; value
    mov     r13d, esi               ; width
    mov     rbx, rdx                ; dest

    ; Convert value to decimal digits (reverse order)
    lea     rdi, [rel itoa_buf]
    xor     ecx, ecx                ; digit count

    mov     rax, r12
    test    rax, rax
    jnz     .fmt_digits
    ; Zero
    mov     byte [rdi], '0'
    mov     ecx, 1
    jmp     .fmt_pad

.fmt_digits:
    xor     ecx, ecx
.fmt_digit_loop:
    xor     edx, edx
    mov     r8, 10
    div     r8
    add     dl, '0'
    mov     [rdi + rcx], dl
    inc     ecx
    test    rax, rax
    jnz     .fmt_digit_loop

.fmt_pad:
    ; ecx = number of digits
    ; Pad with spaces on the left
    mov     eax, r13d
    sub     eax, ecx                ; pad count
    jle     .fmt_no_pad

    ; Write pad spaces
    push    rcx
    mov     ecx, eax
    mov     rdi, rbx
.fmt_pad_loop:
    mov     byte [rdi], ' '
    inc     rdi
    dec     ecx
    jnz     .fmt_pad_loop
    pop     rcx

    ; Write digits in reverse
    lea     rsi, [rel itoa_buf]
    mov     edx, ecx                ; digit count
    dec     edx
.fmt_write_digits:
    movzx   eax, byte [rsi + rdx]
    mov     [rdi], al
    inc     rdi
    dec     edx
    jns     .fmt_write_digits

    ; Total bytes written = max(width, digits)
    mov     eax, r13d
    pop     r13
    pop     r12
    pop     rbx
    ret

.fmt_no_pad:
    ; No padding needed (digits >= width)
    lea     rdi, [rbx]
    lea     rsi, [rel itoa_buf]
    mov     edx, ecx
    dec     edx
.fmt_write_digits2:
    movzx   eax, byte [rsi + rdx]
    mov     [rdi], al
    inc     rdi
    dec     edx
    jns     .fmt_write_digits2

    mov     eax, ecx                ; return digit count
    pop     r13
    pop     r12
    pop     rbx
    ret

; ───────────────────────────────────────────────────────────────────
; num_width: compute decimal digit count
; rdi = value -> eax = width
; ───────────────────────────────────────────────────────────────────
num_width:
    test    rdi, rdi
    jnz     .nw_nonzero
    mov     eax, 1
    ret
.nw_nonzero:
    xor     ecx, ecx
    mov     rax, rdi
.nw_loop:
    xor     edx, edx
    mov     r8, 10
    div     r8
    inc     ecx
    test    rax, rax
    jnz     .nw_loop
    mov     eax, ecx
    ret

; ───────────────────────────────────────────────────────────────────
; write_with_retry: write to fd with EINTR and partial write handling
; rdi = fd, rsi = buf, rdx = len
; ───────────────────────────────────────────────────────────────────
write_with_retry:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi                ; fd
    mov     r12, rsi                ; buf
    mov     r13, rdx                ; remaining
.wr_loop:
    test    r13, r13
    jle     .wr_done
    mov     eax, SYS_WRITE
    mov     edi, ebx
    mov     rsi, r12
    mov     rdx, r13
    syscall
    cmp     rax, -4                 ; EINTR
    je      .wr_loop
    test    rax, rax
    js      .wr_done                ; error (EPIPE etc.) — just stop
    add     r12, rax
    sub     r13, rax
    jmp     .wr_loop
.wr_done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ───────────────────────────────────────────────────────────────────
; flush_outbuf: flush the output buffer
; ───────────────────────────────────────────────────────────────────
flush_outbuf:
    mov     rdx, [rel outbuf_pos]
    test    rdx, rdx
    jz      .flush_done
    mov     rdi, STDOUT
    lea     rsi, [rel outbuf]
    call    write_with_retry
    mov     qword [rel outbuf_pos], 0
.flush_done:
    ret

; ═══════════════════════════════════════════════════════════════════
; Additional BSS variables (appended to bss section)
; ═══════════════════════════════════════════════════════════════════
section .bss

show_flags:     resb 1
total_mode:     resb 1
had_error:      resb 1
prev_was_space: resb 1
cur_flags:      resb 1
stdin_implicit: resb 1
has_stdin:      resb 1
has_nonreg:     resb 1
utf8_mode:      resb 1
align 8
files0_from_ptr: resq 1

; Current file counts
cur_lines:      resq 1
cur_words:      resq 1
cur_bytes:      resq 1
cur_chars:      resq 1
cur_maxlen:     resq 1
cur_line_len:   resq 1

; Total counts
total_lines:    resq 1
total_words:    resq 1
total_bytes:    resq 1
total_chars:    resq 1
total_maxlen:   resq 1

section .note.GNU-stack noalloc noexec nowrite progbits
