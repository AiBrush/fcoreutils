; ============================================================================
;  ftr.asm — GNU-compatible "tr" in x86_64 Linux assembly
;
;  A drop-in replacement for GNU coreutils `tr` written in pure x86_64
;  assembly. Reads from stdin, translates/deletes/squeezes characters,
;  writes to stdout. No libc, no dynamic linker, no runtime allocations.
;
;  BUILD:
;    cd asm && make ftr
;
;  USAGE:
;    echo "hello" | ./ftr 'a-z' 'A-Z'
;    echo "hello" | ./ftr -d 'l'
;    echo "aaabbb" | ./ftr -s 'ab'
;
;  GNU COMPATIBILITY:
;    - All flags: -c/-C, -d, -s, -t
;    - Long options: --complement, --delete, --squeeze-repeats, --truncate-set1
;    - --help, --version, --
;    - Set notation: ranges (a-z), character classes ([:alpha:]),
;      equivalence classes ([=c=]), repeats ([c*n]), octal (\NNN),
;      escape sequences (\n, \t, etc.)
;    - Proper error messages to stderr
;    - Correct exit codes
;    - SIGPIPE handling
;    - EINTR retry on all syscalls
;    - Partial write handling
;
;  REGISTER CONVENTIONS:
;    r12 = flags (bit 0=complement, 1=delete, 2=squeeze, 3=truncate)
;    r13 = set1 string pointer (argv)
;    r14 = set2 string pointer (argv), or 0 if none
;    r15 = base of stack frame (saved rsp)
; ============================================================================

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_read
extern asm_exit

; Flag bits
%define FLAG_COMPLEMENT  1
%define FLAG_DELETE       2
%define FLAG_SQUEEZE      4
%define FLAG_TRUNCATE     8

section .data

; ── Help text ──
help_text:
    db "Usage: tr [OPTION]... SET1 [SET2]", 10
    db "Translate, squeeze, and/or delete characters from standard input,", 10
    db "writing to standard output.", 10, 10
    db "  -c, -C, --complement    use the complement of SET1", 10
    db "  -d, --delete            delete characters in SET1, do not translate", 10
    db "  -s, --squeeze-repeats   replace each sequence of a repeated character", 10
    db "                            that is listed in the last specified SET,", 10
    db "                            with a single occurrence of that character", 10
    db "  -t, --truncate-set1     first truncate SET1 to length of SET2", 10
    db "      --help              display this help and exit", 10
    db "      --version           output version information and exit", 10
help_text_len equ $ - help_text

; ── Version text ──
version_text:
    db "tr (fcoreutils) 0.1.0", 10
version_text_len equ $ - version_text

; ── Error messages ──
err_prefix:
    db "tr: "
err_prefix_len equ $ - err_prefix

err_missing_operand:
    db "tr: missing operand", 10
err_missing_operand_len equ $ - err_missing_operand

err_missing_operand_after:
    db "tr: missing operand after '"
err_missing_operand_after_len equ $ - err_missing_operand_after

err_extra_operand:
    db "tr: extra operand '"
err_extra_operand_len equ $ - err_extra_operand

err_invalid_option:
    db "tr: invalid option -- '"
err_invalid_option_len equ $ - err_invalid_option

err_unrecognized_option:
    db "tr: unrecognized option '"
err_unrecognized_option_len equ $ - err_unrecognized_option

err_try_help:
    db "Try 'tr --help' for more information.", 10
err_try_help_len equ $ - err_try_help

err_two_strings_translate:
    db "Two strings must be given when translating.", 10
err_two_strings_translate_len equ $ - err_two_strings_translate

err_two_strings_ds:
    db "Two strings must be given when both deleting and squeezing repeats.", 10
err_two_strings_ds_len equ $ - err_two_strings_ds

err_one_string_delete:
    db "Only one string may be given when deleting without squeezing repeats.", 10
err_one_string_delete_len equ $ - err_one_string_delete

; Closing quote + newline for error messages
err_quote_nl:
    db "'", 10
err_quote_nl_len equ $ - err_quote_nl

err_range_reversed_prefix:
    db "tr: range-endpoints of '"
err_range_reversed_prefix_len equ $ - err_range_reversed_prefix

err_range_reversed_suffix:
    db "' are in reverse collating sequence order", 10
err_range_reversed_suffix_len equ $ - err_range_reversed_suffix

; ── SIMD constants ──
align 16
mask_0f:
    times 16 db 0x0F

; Nibble broadcast constants for SSSE3 translate
align 16
nibble_0:  times 16 db 0
nibble_1:  times 16 db 1
nibble_2:  times 16 db 2
nibble_3:  times 16 db 3
nibble_4:  times 16 db 4
nibble_5:  times 16 db 5
nibble_6:  times 16 db 6
nibble_7:  times 16 db 7
nibble_8:  times 16 db 8
nibble_9:  times 16 db 9
nibble_10: times 16 db 10
nibble_11: times 16 db 11
nibble_12: times 16 db 12
nibble_13: times 16 db 13
nibble_14: times 16 db 14
nibble_15: times 16 db 15

; ── Character class names (null-terminated) ──
cls_alnum:  db "alnum", 0
cls_alpha:  db "alpha", 0
cls_blank:  db "blank", 0
cls_cntrl:  db "cntrl", 0
cls_digit:  db "digit", 0
cls_graph:  db "graph", 0
cls_lower:  db "lower", 0
cls_print:  db "print", 0
cls_punct:  db "punct", 0
cls_space:  db "space", 0
cls_upper:  db "upper", 0
cls_xdigit: db "xdigit", 0

; Table of class name pointers and their handler labels
; Each entry: 8 bytes pointer to name, 8 bytes handler ID
cls_table:
    dq cls_alnum,  0
    dq cls_alpha,  1
    dq cls_blank,  2
    dq cls_cntrl,  3
    dq cls_digit,  4
    dq cls_graph,  5
    dq cls_lower,  6
    dq cls_print,  7
    dq cls_punct,  8
    dq cls_space,  9
    dq cls_upper, 10
    dq cls_xdigit,11
cls_table_entries equ 12

section .bss

; ── I/O buffers ──
read_buf:       resb BUF_SIZE       ; 64KB input buffer
write_buf:      resb BUF_SIZE       ; 64KB output buffer

; ── Set expansion buffers ──
; Maximum expanded set size is 256 * 256 for pathological repeat cases
; but practically limited. 8192 bytes is generous.
set1_expanded:  resb 8192
set2_expanded:  resb 8192

; ── Processing tables ──
alignb 16
translate_table: resb 256            ; byte-to-byte mapping for translate
member_set:      resb 32             ; 256-bit bitmap for delete/squeeze set
squeeze_set:     resb 32             ; 256-bit bitmap for squeeze set

; ── State variables ──
write_pos:      resq 1              ; current position in write_buf
set1_len:       resq 1              ; expanded set1 length
set2_len:       resq 1              ; expanded set2 length
has_ssse3:      resb 1              ; CPUID: SSSE3 available?

section .text
global _start

; ============================================================================
;                           ENTRY POINT
; ============================================================================

_start:
    ; ── Save stack frame ──
    mov     r15, rsp                ; save original stack pointer

    ; ── Block SIGPIPE ──
    ; rt_sigprocmask(SIG_BLOCK, &{1<<12}, NULL, 8)
    sub     rsp, 16
    mov     qword [rsp], 0x1000     ; bit 12 = SIGPIPE
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi                ; SIG_BLOCK = 0
    mov     rsi, rsp                ; &new_set
    xor     edx, edx                ; old_set = NULL
    mov     r10d, 8                 ; sigsetsize
    syscall
    add     rsp, 16

    ; ── Detect SSSE3 ──
    mov     eax, 1
    cpuid
    bt      ecx, 9                  ; bit 9 = SSSE3
    setc    [has_ssse3]

    ; ── Parse arguments ──
    mov     rsp, r15                ; restore stack pointer
    pop     rcx                     ; rcx = argc
    mov     rsi, rsp                ; rsi = &argv[0]
    dec     ecx                     ; skip argv[0]
    lea     rsi, [rsi + 8]          ; skip argv[0] pointer

    ; Initialize flags and set pointers
    xor     r12d, r12d              ; flags = 0
    xor     r13, r13                ; set1_ptr = NULL
    xor     r14, r14                ; set2_ptr = NULL
    xor     ebx, ebx                ; positional arg count = 0

    ; Parse arguments
    test    ecx, ecx
    jz      .args_done

.parse_loop:
    mov     rdi, [rsi]              ; rdi = current argv string
    cmp     byte [rdi], '-'
    jne     .positional_arg
    cmp     byte [rdi+1], 0         ; bare "-" is positional
    je      .positional_arg
    cmp     byte [rdi+1], '-'
    je      .long_option

    ; ── Short options: -c, -d, -s, -t (can be combined) ──
    lea     rdi, [rdi + 1]          ; skip leading '-'
.short_opt_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_arg
    cmp     al, 'c'
    je      .flag_complement
    cmp     al, 'C'
    je      .flag_complement
    cmp     al, 'd'
    je      .flag_delete
    cmp     al, 's'
    je      .flag_squeeze
    cmp     al, 't'
    je      .flag_truncate
    ; Invalid short option
    jmp     .err_invalid_opt

.flag_complement:
    or      r12d, FLAG_COMPLEMENT
    inc     rdi
    jmp     .short_opt_loop
.flag_delete:
    or      r12d, FLAG_DELETE
    inc     rdi
    jmp     .short_opt_loop
.flag_squeeze:
    or      r12d, FLAG_SQUEEZE
    inc     rdi
    jmp     .short_opt_loop
.flag_truncate:
    or      r12d, FLAG_TRUNCATE
    inc     rdi
    jmp     .short_opt_loop

    ; ── Long options ──
.long_option:
    mov     rdi, [rsi]              ; reload full arg
    ; Check for "--" (end of options)
    cmp     byte [rdi+2], 0
    je      .end_of_options

    ; Check --help
    lea     rax, [rdi + 2]
    cmp     dword [rax], 'help'
    jne     .chk_version
    cmp     byte [rax+4], 0
    je      .do_help

.chk_version:
    ; Check --version (8 chars: "version\0")
    cmp     dword [rax], 'vers'
    jne     .chk_complement
    cmp     dword [rax+4], 'ion' | (0 << 24)
    jne     .chk_complement
    jmp     .do_version

.chk_complement:
    ; --complement (10 chars)
    cmp     dword [rax], 'comp'
    jne     .chk_long_delete
    cmp     dword [rax+4], 'leme'
    jne     .chk_long_delete
    cmp     word [rax+8], 'nt'
    jne     .chk_long_delete
    cmp     byte [rax+10], 0
    jne     .chk_long_delete
    or      r12d, FLAG_COMPLEMENT
    jmp     .next_arg

.chk_long_delete:
    ; --delete (6 chars)
    cmp     dword [rax], 'dele'
    jne     .chk_long_squeeze
    cmp     word [rax+4], 'te'
    jne     .chk_long_squeeze
    cmp     byte [rax+6], 0
    jne     .chk_long_squeeze
    or      r12d, FLAG_DELETE
    jmp     .next_arg

.chk_long_squeeze:
    ; --squeeze-repeats (16 chars)
    cmp     dword [rax], 'sque'
    jne     .chk_long_truncate
    cmp     dword [rax+4], 'eze-'
    jne     .chk_long_truncate
    cmp     dword [rax+8], 'repe'
    jne     .chk_long_truncate
    cmp     dword [rax+12], 'ats' | (0 << 24)
    jne     .chk_long_truncate
    or      r12d, FLAG_SQUEEZE
    jmp     .next_arg

.chk_long_truncate:
    ; --truncate-set1 (14 chars)
    cmp     dword [rax], 'trun'
    jne     .err_unrecognized_opt
    cmp     dword [rax+4], 'cate'
    jne     .err_unrecognized_opt
    cmp     dword [rax+8], '-set'
    jne     .err_unrecognized_opt
    cmp     word [rax+12], '1' | (0 << 8)
    jne     .err_unrecognized_opt
    or      r12d, FLAG_TRUNCATE
    jmp     .next_arg

.positional_arg:
    ; Store SET1 or SET2
    test    ebx, ebx
    jnz     .store_set2
    mov     r13, rdi                ; set1_ptr
    inc     ebx
    jmp     .next_arg
.store_set2:
    cmp     ebx, 1
    jne     .store_extra
    mov     r14, rdi                ; set2_ptr
    inc     ebx
    jmp     .next_arg
.store_extra:
    ; Save first extra operand pointer for error reporting
    cmp     ebx, 2
    jne     .store_extra_skip
    mov     rbp, rdi                ; save third operand pointer
.store_extra_skip:
    inc     ebx
    jmp     .next_arg

.end_of_options:
    ; "--" means everything after is positional
    add     rsi, 8
    dec     ecx
.end_of_options_loop:
    test    ecx, ecx
    jz      .args_done
    mov     rdi, [rsi]
    test    ebx, ebx
    jnz     .eo_set2
    mov     r13, rdi
    inc     ebx
    jmp     .eo_next
.eo_set2:
    cmp     ebx, 1
    jne     .eo_extra
    mov     r14, rdi
    inc     ebx
    jmp     .eo_next
.eo_extra:
    cmp     ebx, 2
    jne     .eo_extra_skip
    mov     rbp, rdi
.eo_extra_skip:
    inc     ebx
.eo_next:
    add     rsi, 8
    dec     ecx
    jmp     .end_of_options_loop

.next_arg:
    add     rsi, 8
    dec     ecx
    jnz     .parse_loop

.args_done:
    ; ── Validate arguments ──
    ; ebx = number of positional args
    test    ebx, ebx
    jz      .err_no_operand

    ; ── Dispatch to appropriate mode ──
    test    r12d, FLAG_DELETE
    jnz     .mode_delete_check
    test    r12d, FLAG_SQUEEZE
    jnz     .mode_squeeze_check

    ; Pure translate mode: need exactly 2 sets
    cmp     ebx, 2
    jl      .err_missing_set2_translate
    jg      .err_extra_operand_general
    jmp     do_translate

.mode_delete_check:
    test    r12d, FLAG_SQUEEZE
    jnz     .mode_delete_squeeze
    ; Delete only: need exactly 1 set
    cmp     ebx, 2
    jge     .err_extra_operand_delete
    jmp     do_delete

.mode_delete_squeeze:
    ; Delete + squeeze: need exactly 2 sets
    cmp     ebx, 2
    jl      .err_missing_set2_ds
    jg      .err_extra_operand_general
    jmp     do_delete_squeeze

.mode_squeeze_check:
    ; Squeeze: 1 set = squeeze only, 2 sets = translate + squeeze
    cmp     ebx, 2
    jg      .err_extra_operand_general
    jge     do_translate_squeeze
    jmp     do_squeeze

; ============================================================================
;                       ERROR HANDLERS
; ============================================================================

.err_no_operand:
    WRITE   STDERR, err_missing_operand, err_missing_operand_len
    WRITE   STDERR, err_try_help, err_try_help_len
    EXIT    1

.err_missing_set2_translate:
    WRITE   STDERR, err_missing_operand_after, err_missing_operand_after_len
    mov     rdi, r13
    call    strlen
    mov     r15, rax                ; save length (rax clobbered by WRITE macro)
    WRITE   STDERR, r13, r15
    WRITE   STDERR, err_quote_nl, err_quote_nl_len
    WRITE   STDERR, err_two_strings_translate, err_two_strings_translate_len
    WRITE   STDERR, err_try_help, err_try_help_len
    EXIT    1

.err_missing_set2_ds:
    WRITE   STDERR, err_missing_operand_after, err_missing_operand_after_len
    mov     rdi, r13
    call    strlen
    mov     r15, rax
    WRITE   STDERR, r13, r15
    WRITE   STDERR, err_quote_nl, err_quote_nl_len
    WRITE   STDERR, err_two_strings_ds, err_two_strings_ds_len
    WRITE   STDERR, err_try_help, err_try_help_len
    EXIT    1

.err_extra_operand_delete:
    WRITE   STDERR, err_extra_operand, err_extra_operand_len
    mov     rdi, r14
    call    strlen
    mov     r15, rax
    WRITE   STDERR, r14, r15
    WRITE   STDERR, err_quote_nl, err_quote_nl_len
    WRITE   STDERR, err_one_string_delete, err_one_string_delete_len
    WRITE   STDERR, err_try_help, err_try_help_len
    EXIT    1

.err_extra_operand_general:
    ; rbp = pointer to the extra (3rd) operand, saved during arg parsing
    WRITE   STDERR, err_extra_operand, err_extra_operand_len
    mov     rdi, rbp
    call    strlen
    mov     r15, rax
    WRITE   STDERR, rbp, r15
    WRITE   STDERR, err_quote_nl, err_quote_nl_len
    WRITE   STDERR, err_try_help, err_try_help_len
    EXIT    1

.err_invalid_opt:
    ; rdi points to the bad character, al = the bad char
    push    rax                     ; save bad char
    WRITE   STDERR, err_invalid_option, err_invalid_option_len
    ; Write the bad character
    lea     rsi, [rsp]
    WRITE   STDERR, rsi, 1
    WRITE   STDERR, err_quote_nl, err_quote_nl_len
    pop     rax
    WRITE   STDERR, err_try_help, err_try_help_len
    EXIT    1

.err_unrecognized_opt:
    ; rdi still has the arg string from .long_option (e.g., "--bogus")
    mov     rbx, rdi                ; save arg string ptr (rbx is callee-saved)
    WRITE   STDERR, err_unrecognized_option, err_unrecognized_option_len
    mov     rdi, rbx
    call    strlen
    mov     r15, rax                ; save length (rax clobbered by WRITE macro)
    WRITE   STDERR, rbx, r15
    WRITE   STDERR, err_quote_nl, err_quote_nl_len
    WRITE   STDERR, err_try_help, err_try_help_len
    EXIT    1

.do_help:
    WRITE   STDOUT, help_text, help_text_len
    EXIT    0

.do_version:
    WRITE   STDOUT, version_text, version_text_len
    EXIT    0

; ── Range error handler (called from parse_set, not a local label) ──
; ecx = start char, edx = end char of the reversed range
err_range_reversed:
    ; Format: tr: range-endpoints of 'X-Y' are in reverse collating sequence order
    ; Build the range string "X-Y" on the stack
    sub     rsp, 8
    mov     byte [rsp], cl          ; start char
    mov     byte [rsp+1], '-'
    mov     byte [rsp+2], dl        ; end char
    WRITE   STDERR, err_range_reversed_prefix, err_range_reversed_prefix_len
    lea     rsi, [rsp]
    WRITE   STDERR, rsi, 3
    WRITE   STDERR, err_range_reversed_suffix, err_range_reversed_suffix_len
    add     rsp, 8
    EXIT    1

; ============================================================================
;                       UTILITY FUNCTIONS
; ============================================================================

; strlen(rdi=string) -> rax=length
; Counts bytes until null terminator
strlen:
    push    rcx
    xor     eax, eax
    mov     rcx, rdi
.strlen_loop:
    cmp     byte [rcx], 0
    je      .strlen_done
    inc     rcx
    jmp     .strlen_loop
.strlen_done:
    sub     rcx, rdi
    mov     rax, rcx
    pop     rcx
    ret

; ============================================================================
;                       SET PARSING
; ============================================================================

; parse_set(rdi=string, rsi=output_buf) -> rax=expanded_length
; Expands a SET string into a byte array.
; Handles: literals, escapes (\n,\t,\NNN), ranges (a-z),
;          character classes ([:alpha:]), equivalence ([=c=]),
;          repeats ([c*n], [c*])
;
; Uses: rdi=source ptr, rsi=output ptr, rbx=output start
;       r8=source ptr (working), r9=output ptr (working)
parse_set:
    push    rbx
    push    r8
    push    r9
    push    r10
    push    r11

    mov     r8, rdi                 ; r8 = source string pointer
    mov     r9, rsi                 ; r9 = output buffer pointer
    mov     rbx, rsi                ; rbx = output start (for length calc)

.ps_loop:
    ; Bounds check: stop if output buffer is full
    lea     rax, [r9]
    sub     rax, rbx
    cmp     rax, 8192
    jge     .ps_done

    movzx   eax, byte [r8]
    test    al, al
    jz      .ps_done

    ; Check for '['
    cmp     al, '['
    je      .ps_bracket

    ; Check for '\'
    cmp     al, '\'
    je      .ps_escape

    ; Regular character — check for range
    mov     r10b, al                ; r10b = current char
    inc     r8
    cmp     byte [r8], '-'
    jne     .ps_emit_char
    cmp     byte [r8+1], 0          ; '-' at end is literal
    je      .ps_emit_char
    ; It's a range: r10b - next_char
    inc     r8                      ; skip '-'
    call    .ps_get_char            ; get end char in al
    mov     r11b, al                ; r11b = end char
    ; Expand range r10b..r11b
    movzx   ecx, r10b
    movzx   edx, r11b
    cmp     ecx, edx
    jg      err_range_reversed      ; reversed range is an error (GNU compat)
.ps_range_loop:
    ; Bounds check in range expansion
    lea     rax, [r9]
    sub     rax, rbx
    cmp     rax, 8192
    jge     .ps_done
    mov     [r9], cl
    inc     r9
    inc     ecx
    cmp     ecx, edx
    jle     .ps_range_loop
    jmp     .ps_loop

.ps_emit_char:
    mov     [r9], r10b
    inc     r9
    jmp     .ps_loop

.ps_escape:
    inc     r8                      ; skip '\'
    call    .ps_get_escape          ; get escaped char in al
    mov     r10b, al
    ; Check for range after escaped char
    cmp     byte [r8], '-'
    jne     .ps_emit_char
    cmp     byte [r8+1], 0
    je      .ps_emit_char
    inc     r8                      ; skip '-'
    call    .ps_get_char            ; get end char
    mov     r11b, al
    movzx   ecx, r10b
    movzx   edx, r11b
    cmp     ecx, edx
    jg      err_range_reversed
    jmp     .ps_range_loop

.ps_bracket:
    ; Check what follows '['
    cmp     byte [r8+1], ':'
    je      .ps_char_class
    cmp     byte [r8+1], '='
    je      .ps_equiv_class
    ; Check for [c*n] or [c*] — char at [r8+1], '*' at [r8+2]
    ; But the char might be escaped, so check [r8+2] for '*'
    ; For simplicity: if [r8+2] == '*', it's a repeat
    cmp     byte [r8+2], '*'
    je      .ps_repeat
    ; Check if escaped char inside bracket: [\x*...]
    cmp     byte [r8+1], '\'
    jne     .ps_literal_bracket
    ; After escape, check for repeat marker
    ; This is complex; for now treat '\' inside brackets:
    ; Parse the escaped char, then check if '*' follows
    push    r8
    lea     r8, [r8+2]             ; skip '[\'
    call    .ps_get_escape         ; get escaped char
    cmp     byte [r8], '*'
    pop     r8
    je      .ps_repeat_escaped
    jmp     .ps_literal_bracket

.ps_literal_bracket:
    ; '[' is just a literal character
    mov     r10b, '['
    inc     r8
    cmp     byte [r8], '-'
    jne     .ps_emit_char
    cmp     byte [r8+1], 0
    je      .ps_emit_char
    inc     r8
    call    .ps_get_char
    mov     r11b, al
    movzx   ecx, r10b
    movzx   edx, r11b
    cmp     ecx, edx
    jg      err_range_reversed
    jmp     .ps_range_loop

.ps_char_class:
    ; Parse [:classname:]
    add     r8, 2                   ; skip '[:'
    mov     rdi, r8                 ; rdi = start of class name
    ; Find closing ':]'
.ps_cc_find_end:
    cmp     byte [r8], ':'
    jne     .ps_cc_next
    cmp     byte [r8+1], ']'
    je      .ps_cc_found
.ps_cc_next:
    cmp     byte [r8], 0
    je      .ps_done                ; unterminated — bail
    inc     r8
    jmp     .ps_cc_find_end
.ps_cc_found:
    ; r8 points to ':', rdi points to start of name
    ; Calculate name length
    mov     rcx, r8
    sub     rcx, rdi                ; rcx = name length
    add     r8, 2                   ; skip ':]'

    ; Match class name and expand
    call    expand_char_class       ; rdi=name, rcx=namelen, r9=output ptr
    ; r9 is advanced by expand_char_class
    jmp     .ps_loop

.ps_equiv_class:
    ; Parse [=c=]
    add     r8, 2                   ; skip '[='
    ; Get the character (possibly escaped)
    call    .ps_get_char            ; al = char
    ; Expect '=]'
    cmp     byte [r8], '='
    jne     .ps_loop                ; malformed — skip
    cmp     byte [r8+1], ']'
    jne     .ps_loop
    add     r8, 2                   ; skip '=]'
    ; In C locale, equivalence class is just the single char
    mov     [r9], al
    inc     r9
    jmp     .ps_loop

.ps_repeat:
    ; Parse [c*n] or [c*]
    ; r8 points to '['
    inc     r8                      ; skip '['
    call    .ps_get_char            ; al = repeat char
    mov     r10b, al                ; save char
    inc     r8                      ; skip '*'
    ; Parse count (decimal, or octal if starts with 0)
    xor     edx, edx                ; count = 0
    xor     ecx, ecx                ; digit count = 0
    movzx   eax, byte [r8]
    cmp     al, ']'
    je      .ps_repeat_fill         ; [c*] = fill to match set1 length
    cmp     al, '0'
    je      .ps_repeat_octal_start
    jmp     .ps_repeat_decimal

.ps_repeat_octal_start:
    ; Could be octal or just 0
    inc     r8
    movzx   eax, byte [r8]
    cmp     al, ']'
    je      .ps_repeat_fill         ; [c*0] = fill (same as [c*] per GNU behavior)
    ; It's octal
.ps_repeat_octal:
    movzx   eax, byte [r8]
    cmp     al, ']'
    je      .ps_repeat_emit
    sub     al, '0'
    cmp     al, 7
    ja      .ps_repeat_emit         ; not octal digit
    imul    edx, 8
    movzx   eax, al
    add     edx, eax
    inc     r8
    jmp     .ps_repeat_octal

.ps_repeat_decimal:
    movzx   eax, byte [r8]
    cmp     al, ']'
    je      .ps_repeat_emit
    sub     al, '0'
    cmp     al, 9
    ja      .ps_repeat_emit         ; not a digit
    imul    edx, 10
    movzx   eax, al
    add     edx, eax
    inc     r8
    jmp     .ps_repeat_decimal

.ps_repeat_fill:
    ; [c*] — count will be determined later (when we know set1 length)
    ; For now, emit 0 copies and mark this as a fill character
    ; Actually, for simplicity, store a sentinel: we'll handle [c*] specially
    ; GNU tr: [c*] in SET2 means repeat c enough times to make SET2 as long as SET1
    ; We need set1_len to know how many. Store a large count for now.
    mov     edx, 8192              ; emit enough to fill any reasonable set
    jmp     .ps_repeat_emit

.ps_repeat_emit:
    ; Skip closing ']'
    cmp     byte [r8], ']'
    jne     .ps_repeat_skip
    inc     r8
.ps_repeat_skip:
    ; Emit r10b edx times
    test    edx, edx
    jz      .ps_loop
    ; Limit to prevent buffer overflow
    lea     rax, [r9]
    sub     rax, rbx                ; current output length
    add     rax, rdx                ; + repeat count
    cmp     rax, 8192
    jl      .ps_repeat_loop
    ; Truncate to fit buffer
    mov     edx, 8192
    lea     rax, [r9]
    sub     rax, rbx
    sub     edx, eax
    test    edx, edx
    jle     .ps_loop
.ps_repeat_loop:
    mov     [r9], r10b
    inc     r9
    dec     edx
    jnz     .ps_repeat_loop
    jmp     .ps_loop

.ps_repeat_escaped:
    ; [\\c*n] pattern — escaped char in repeat
    inc     r8                      ; skip '['
    call    .ps_get_char            ; get escaped char (handles \)
    mov     r10b, al
    inc     r8                      ; skip '*'
    ; Parse count same as above
    xor     edx, edx
    movzx   eax, byte [r8]
    cmp     al, ']'
    je      .ps_repeat_fill
    cmp     al, '0'
    je      .ps_repeat_octal_start
    jmp     .ps_repeat_decimal

.ps_done:
    ; Return length
    mov     rax, r9
    sub     rax, rbx                ; rax = output length

    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rbx
    ret

; ── Helper: get next char from set string (handles escapes) ──
; Input: r8 = current position
; Output: al = character value, r8 advanced past it
.ps_get_char:
    movzx   eax, byte [r8]
    cmp     al, '\'
    je      .ps_gc_escape
    inc     r8
    ret
.ps_gc_escape:
    inc     r8                      ; skip '\'
    ; Fall through to get_escape
.ps_get_escape:
    ; Parse escape sequence at r8
    ; Returns char in al, advances r8
    movzx   eax, byte [r8]
    inc     r8
    cmp     al, 'a'
    je      .esc_bel
    cmp     al, 'b'
    je      .esc_bs
    cmp     al, 'f'
    je      .esc_ff
    cmp     al, 'n'
    je      .esc_nl
    cmp     al, 'r'
    je      .esc_cr
    cmp     al, 't'
    je      .esc_tab
    cmp     al, 'v'
    je      .esc_vt
    cmp     al, '\'
    je      .esc_backslash
    ; Check for octal (\NNN)
    cmp     al, '0'
    jb      .esc_literal            ; not octal, return as-is
    cmp     al, '7'
    ja      .esc_literal
    ; Octal escape: first digit is al-'0'
    sub     al, '0'
    movzx   edx, al                 ; edx = octal value so far
    ; Second digit?
    movzx   eax, byte [r8]
    cmp     al, '0'
    jb      .esc_octal_done
    cmp     al, '7'
    ja      .esc_octal_done
    sub     al, '0'
    shl     edx, 3
    add     edx, eax
    inc     r8
    ; Third digit?
    movzx   eax, byte [r8]
    cmp     al, '0'
    jb      .esc_octal_done
    cmp     al, '7'
    ja      .esc_octal_done
    sub     al, '0'
    shl     edx, 3
    add     edx, eax
    inc     r8
.esc_octal_done:
    mov     eax, edx
    and     eax, 0xFF               ; clamp to byte
    ret
.esc_bel:
    mov     al, 7
    ret
.esc_bs:
    mov     al, 8
    ret
.esc_ff:
    mov     al, 12
    ret
.esc_nl:
    mov     al, 10
    ret
.esc_cr:
    mov     al, 13
    ret
.esc_tab:
    mov     al, 9
    ret
.esc_vt:
    mov     al, 11
    ret
.esc_backslash:
    mov     al, '\'
    ret
.esc_literal:
    ; Return character as-is (already in al)
    ret

; ============================================================================
;                   CHARACTER CLASS EXPANSION
; ============================================================================

; Helper macro: emit byte range [start, end] inclusive to [r9], advancing r9
; Includes bounds check against 8192-byte output buffer (rbx = output start)
%macro EMIT_RANGE 2
    mov     ecx, %1
%%loop:
    lea     rax, [r9]
    sub     rax, rbx
    cmp     rax, 8192
    jge     %%done
    mov     [r9], cl
    inc     r9
    inc     ecx
    cmp     ecx, %2 + 1
    jl      %%loop
%%done:
%endmacro

; Helper macro: emit single byte to [r9], advancing r9
; Includes bounds check against 8192-byte output buffer (rbx = output start)
%macro EMIT_BYTE 1
    lea     rax, [r9]
    sub     rax, rbx
    cmp     rax, 8192
    jge     %%skip
    mov     byte [r9], %1
    inc     r9
%%skip:
%endmacro

; expand_char_class(rdi=name_ptr, rcx=name_len, r9=output_ptr)
; Expands a POSIX character class into the output buffer.
; Advances r9 past the emitted bytes. Preserves r8.
expand_char_class:
    push    rbx
    push    r10
    push    r11
    push    r8

    mov     r10, rdi                ; r10 = name_ptr (from SET string)
    mov     r11, rcx                ; r11 = name_len

    ; Try each known class name
    lea     rbx, [cls_table]
    xor     r8d, r8d                ; class index

.ecc_loop:
    cmp     r8d, cls_table_entries
    jge     .ecc_done               ; unknown class — ignore

    mov     rdi, [rbx]              ; known class name (null-terminated)
    mov     rsi, r10                ; name from SET string
    mov     rcx, r11                ; name length

    ; Compare rcx bytes
.ecc_cmp:
    test    rcx, rcx
    jz      .ecc_check_end
    movzx   eax, byte [rsi]
    cmp     al, [rdi]
    jne     .ecc_next
    inc     rsi
    inc     rdi
    dec     rcx
    jmp     .ecc_cmp

.ecc_check_end:
    ; Known name must also be at its null terminator
    cmp     byte [rdi], 0
    je      .ecc_expand             ; match!

.ecc_next:
    add     rbx, 16                 ; next table entry (8 ptr + 8 id)
    inc     r8d
    jmp     .ecc_loop

.ecc_expand:
    ; Restore rbx to output buffer start (saved by parse_set) for EMIT bounds checks
    ; Stack layout: [rsp+0]=r8, [rsp+8]=r11, [rsp+16]=r10, [rsp+24]=rbx
    mov     rbx, [rsp + 24]
    ; r8d = class index (0=alnum, 1=alpha, ..., 11=xdigit)
    cmp     r8d, 0
    je      .ecc_alnum
    cmp     r8d, 1
    je      .ecc_alpha
    cmp     r8d, 2
    je      .ecc_blank
    cmp     r8d, 3
    je      .ecc_cntrl
    cmp     r8d, 4
    je      .ecc_digit
    cmp     r8d, 5
    je      .ecc_graph
    cmp     r8d, 6
    je      .ecc_lower
    cmp     r8d, 7
    je      .ecc_print
    cmp     r8d, 8
    je      .ecc_punct
    cmp     r8d, 9
    je      .ecc_space
    cmp     r8d, 10
    je      .ecc_upper
    cmp     r8d, 11
    je      .ecc_xdigit
    jmp     .ecc_done

.ecc_alnum:
    EMIT_RANGE '0', '9'
    EMIT_RANGE 'A', 'Z'
    EMIT_RANGE 'a', 'z'
    jmp     .ecc_done

.ecc_alpha:
    EMIT_RANGE 'A', 'Z'
    EMIT_RANGE 'a', 'z'
    jmp     .ecc_done

.ecc_blank:
    EMIT_BYTE 9
    EMIT_BYTE 32
    jmp     .ecc_done

.ecc_cntrl:
    EMIT_RANGE 0, 31
    EMIT_BYTE 127
    jmp     .ecc_done

.ecc_digit:
    EMIT_RANGE '0', '9'
    jmp     .ecc_done

.ecc_graph:
    EMIT_RANGE 33, 126
    jmp     .ecc_done

.ecc_lower:
    EMIT_RANGE 'a', 'z'
    jmp     .ecc_done

.ecc_print:
    EMIT_RANGE 32, 126
    jmp     .ecc_done

.ecc_punct:
    EMIT_RANGE 33, 47
    EMIT_RANGE 58, 64
    EMIT_RANGE 91, 96
    EMIT_RANGE 123, 126
    jmp     .ecc_done

.ecc_space:
    EMIT_RANGE 9, 13
    EMIT_BYTE 32
    jmp     .ecc_done

.ecc_upper:
    EMIT_RANGE 'A', 'Z'
    jmp     .ecc_done

.ecc_xdigit:
    EMIT_RANGE '0', '9'
    EMIT_RANGE 'A', 'F'
    EMIT_RANGE 'a', 'f'
    jmp     .ecc_done

.ecc_done:
    pop     r8
    pop     r11
    pop     r10
    pop     rbx
    ret

; ============================================================================
;                   TABLE / SET BUILDING
; ============================================================================

; build_translate_table()
; Builds the 256-byte translate table from set1_expanded and set2_expanded.
; set1_len and set2_len must be set. r12 = flags (not pushed/popped).
build_translate_table:
    push    rbx
    push    r13
    push    r14
    push    r15

    ; Initialize translate table to identity
    lea     rdi, [translate_table]
    xor     ecx, ecx
.btt_init:
    mov     [rdi + rcx], cl
    inc     ecx
    cmp     ecx, 256
    jl      .btt_init

    mov     r13, [set1_len]
    mov     r14, [set2_len]

    ; Cap set lengths to 256 (max meaningful for byte-to-byte translation)
    cmp     r13, 256
    jle     .btt_s1_ok
    mov     r13, 256
.btt_s1_ok:
    cmp     r14, 256
    jle     .btt_s2_ok
    mov     r14, 256
.btt_s2_ok:

    ; Handle complement
    test    r12d, FLAG_COMPLEMENT
    jz      .btt_no_complement

    ; Build complement of set1: all bytes 0-255 not in set1_expanded
    ; Build a 32-byte membership bitmap on the stack
    sub     rsp, 32
    xor     eax, eax
    mov     [rsp], rax
    mov     [rsp+8], rax
    mov     [rsp+16], rax
    mov     [rsp+24], rax

    ; Add set1 bytes to bitmap
    lea     rsi, [set1_expanded]
    xor     edx, edx
.btt_comp_add:
    cmp     rdx, r13
    jge     .btt_comp_build
    movzx   eax, byte [rsi + rdx]
    mov     ecx, eax
    and     ecx, 7                  ; bit within byte
    shr     eax, 3                  ; byte index
    mov     r15b, 1
    shl     r15b, cl
    or      [rsp + rax], r15b
    inc     rdx
    jmp     .btt_comp_add

.btt_comp_build:
    ; Build complement: all bytes NOT in bitmap
    lea     rdi, [set1_expanded]
    xor     ecx, ecx
    xor     r13d, r13d
.btt_comp_loop:
    cmp     ecx, 256
    jge     .btt_comp_done
    mov     eax, ecx
    and     eax, 7                  ; bit index within byte
    mov     edx, ecx
    shr     edx, 3                  ; byte index
    movzx   ebx, byte [rsp + rdx]
    bt      ebx, eax
    jc      .btt_comp_skip          ; bit set = in original set = skip
    mov     [rdi + r13], cl
    inc     r13d
.btt_comp_skip:
    inc     ecx
    cmp     ecx, 256
    jl      .btt_comp_loop
.btt_comp_done:
    add     rsp, 32
    mov     [set1_len], r13

.btt_no_complement:
    ; Handle truncate
    test    r12d, FLAG_TRUNCATE
    jz      .btt_no_truncate
    cmp     r13, r14
    jle     .btt_no_truncate
    mov     r13, r14
.btt_no_truncate:

    ; Extend set2 to match set1 length by repeating last char (capped at 256)
    cmp     r14, r13
    jge     .btt_sets_ready
    test    r14, r14
    jz      .btt_sets_ready
    lea     rsi, [set2_expanded]
    movzx   eax, byte [rsi + r14 - 1]
.btt_extend_set2:
    cmp     r14, r13
    jge     .btt_sets_ready
    cmp     r14, 256
    jge     .btt_sets_ready
    mov     [rsi + r14], al
    inc     r14
    jmp     .btt_extend_set2

.btt_sets_ready:
    ; Build the table: translate_table[set1[i]] = set2[i]
    lea     rsi, [set1_expanded]
    lea     rdi, [set2_expanded]
    lea     rbx, [translate_table]
    xor     ecx, ecx
.btt_map_loop:
    cmp     rcx, r13
    jge     .btt_map_done
    movzx   eax, byte [rsi + rcx]
    movzx   edx, byte [rdi + rcx]
    mov     [rbx + rax], dl
    inc     rcx
    jmp     .btt_map_loop
.btt_map_done:
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; build_member_set(rsi=expanded_set, rcx=set_len, rdi=bitmap_output)
; Builds a 256-bit membership bitmap from an expanded set.
; If FLAG_COMPLEMENT is set in r12, inverts the bitmap.
build_member_set:
    push    rax
    push    rdx
    push    rcx
    push    rbx
    push    r8

    ; Clear bitmap
    xor     eax, eax
    mov     [rdi], rax
    mov     [rdi+8], rax
    mov     [rdi+16], rax
    mov     [rdi+24], rax

    ; Set bits for each byte in the set
    xor     edx, edx
.bms_loop:
    cmp     rdx, rcx
    jge     .bms_complement_check
    movzx   eax, byte [rsi + rdx]
    ; Set bit eax in bitmap at [rdi]
    mov     ebx, eax
    shr     ebx, 3                  ; byte index
    and     eax, 7                  ; bit index within byte
    mov     r8b, 1
    push    rcx
    mov     ecx, eax
    shl     r8b, cl
    pop     rcx
    or      [rdi + rbx], r8b
    inc     rdx
    jmp     .bms_loop

.bms_complement_check:
    test    r12d, FLAG_COMPLEMENT
    jz      .bms_done
    ; Invert all 32 bytes
    not     qword [rdi]
    not     qword [rdi+8]
    not     qword [rdi+16]
    not     qword [rdi+24]

.bms_done:
    pop     r8
    pop     rbx
    pop     rcx
    pop     rdx
    pop     rax
    ret

; ============================================================================
;                   PROCESSING MODES
; ============================================================================

; ── Pure translate mode ──
do_translate:
    ; Parse set1
    mov     rdi, r13
    lea     rsi, [set1_expanded]
    call    parse_set
    mov     [set1_len], rax

    ; Parse set2
    mov     rdi, r14
    lea     rsi, [set2_expanded]
    call    parse_set
    mov     [set2_len], rax

    ; Build translate table
    call    build_translate_table

    ; Check if we can use SSSE3
    cmp     byte [has_ssse3], 0
    je      .dt_scalar_setup

    ; ── SSSE3 translate main loop ──
    ; Prepare SSSE3 nibble decomposition constants
    jmp     .dt_ssse3_loop

.dt_scalar_setup:
    ; ── Scalar translate main loop ──
    ; Read stdin in BUF_SIZE chunks, translate in-place, write to stdout
.dt_scalar_loop:
    ; Read from stdin
    mov     edi, STDIN
    lea     rsi, [read_buf]
    mov     edx, BUF_SIZE
    call    asm_read
    test    rax, rax
    jz      .dt_done                ; EOF
    js      .dt_error               ; error

    ; Translate in-place
    mov     rcx, rax                ; byte count
    lea     rsi, [read_buf]
    lea     rbx, [translate_table]
    xor     edx, edx
.dt_scalar_byte:
    cmp     rdx, rcx
    jge     .dt_scalar_write
    movzx   eax, byte [rsi + rdx]
    mov     al, [rbx + rax]
    mov     [rsi + rdx], al
    inc     rdx
    jmp     .dt_scalar_byte

.dt_scalar_write:
    ; Write translated buffer
    mov     edi, STDOUT
    lea     rsi, [read_buf]
    mov     rdx, rcx
    call    asm_write_all
    test    rax, rax
    js      .dt_write_error
    jmp     .dt_scalar_loop

    ; ── SSSE3 translate loop ──
.dt_ssse3_loop:
    ; Read from stdin
    mov     edi, STDIN
    lea     rsi, [read_buf]
    mov     edx, BUF_SIZE
    call    asm_read
    test    rax, rax
    jz      .dt_done
    js      .dt_error

    mov     rcx, rax                ; total bytes
    lea     rsi, [read_buf]
    lea     rbx, [translate_table]

    ; Process 16 bytes at a time with SSSE3 pshufb
    movdqa  xmm15, [mask_0f]       ; 0x0F mask

    xor     edx, edx                ; current offset
.dt_simd_loop:
    lea     rax, [rdx + 16]
    cmp     rax, rcx
    jg      .dt_simd_tail           ; less than 16 bytes remaining

    ; Load 16 input bytes
    movdqu  xmm0, [rsi + rdx]

    ; Extract low and high nibbles
    movdqa  xmm1, xmm0
    pand    xmm1, xmm15            ; low nibbles
    movdqa  xmm2, xmm0
    psrlw   xmm2, 4
    pand    xmm2, xmm15            ; high nibbles

    ; Accumulate result
    pxor    xmm0, xmm0             ; result accumulator

    ; Unrolled: for each high nibble value 0-15, do pshufb lookup and mask
    ; Row 0
    movdqu  xmm3, [rbx + 0*16]     ; table row 0
    pshufb  xmm3, xmm1             ; lookup by low nibble
    movdqa  xmm4, xmm2
    pxor    xmm5, xmm5
    pcmpeqb xmm4, xmm5             ; mask where high nibble == 0
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Row 1
    movdqu  xmm3, [rbx + 1*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_1]
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Row 2
    movdqu  xmm3, [rbx + 2*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_2]
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Row 3
    movdqu  xmm3, [rbx + 3*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_3]
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Row 4
    movdqu  xmm3, [rbx + 4*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_4]
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Row 5
    movdqu  xmm3, [rbx + 5*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_5]
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Row 6
    movdqu  xmm3, [rbx + 6*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_6]
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Row 7
    movdqu  xmm3, [rbx + 7*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_7]
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Row 8
    movdqu  xmm3, [rbx + 8*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_8]
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Row 9
    movdqu  xmm3, [rbx + 9*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_9]
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Row 10
    movdqu  xmm3, [rbx + 10*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_10]
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Row 11
    movdqu  xmm3, [rbx + 11*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_11]
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Row 12
    movdqu  xmm3, [rbx + 12*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_12]
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Row 13
    movdqu  xmm3, [rbx + 13*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_13]
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Row 14
    movdqu  xmm3, [rbx + 14*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_14]
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Row 15
    movdqu  xmm3, [rbx + 15*16]
    pshufb  xmm3, xmm1
    movdqa  xmm4, xmm2
    pcmpeqb xmm4, [nibble_15]
    pand    xmm3, xmm4
    por     xmm0, xmm3

    ; Store result
    movdqu  [rsi + rdx], xmm0
    add     edx, 16
    jmp     .dt_simd_loop

.dt_simd_tail:
    ; Process remaining bytes with scalar
    cmp     rdx, rcx
    jge     .dt_simd_write
    movzx   eax, byte [rsi + rdx]
    mov     al, [rbx + rax]
    mov     [rsi + rdx], al
    inc     edx
    jmp     .dt_simd_tail

.dt_simd_write:
    mov     edi, STDOUT
    lea     rsi, [read_buf]
    mov     rdx, rcx
    call    asm_write_all
    test    rax, rax
    js      .dt_write_error
    jmp     .dt_ssse3_loop

.dt_write_error:
    cmp     rax, EPIPE
    je      .dt_done                ; SIGPIPE/EPIPE — exit quietly
    EXIT    1

.dt_error:
    EXIT    1

.dt_done:
    EXIT    0

; ── Delete mode ──
do_delete:
    ; Parse set1
    mov     rdi, r13
    lea     rsi, [set1_expanded]
    call    parse_set
    mov     [set1_len], rax

    ; Build membership set
    lea     rsi, [set1_expanded]
    mov     rcx, [set1_len]
    lea     rdi, [member_set]
    call    build_member_set

    ; Main delete loop
.dd_loop:
    ; Read from stdin
    mov     edi, STDIN
    lea     rsi, [read_buf]
    mov     edx, BUF_SIZE
    call    asm_read
    test    rax, rax
    jz      .dd_done
    js      .dd_error

    ; Delete: copy non-member bytes to write_buf
    mov     rcx, rax
    lea     rsi, [read_buf]
    lea     rdi, [write_buf]
    xor     edx, edx                ; read index
    xor     r8d, r8d                ; write index
.dd_byte:
    cmp     rdx, rcx
    jge     .dd_flush
    movzx   eax, byte [rsi + rdx]
    ; Check membership: bit eax in member_set
    push    rcx
    mov     ecx, eax
    and     ecx, 7                  ; bit within byte
    mov     ebx, eax
    shr     ebx, 3                  ; byte index
    movzx   r9d, byte [member_set + rbx]
    bt      r9d, ecx
    pop     rcx
    jc      .dd_skip                ; member — delete it
    mov     [rdi + r8], al
    inc     r8d
.dd_skip:
    inc     rdx
    jmp     .dd_byte

.dd_flush:
    ; Write output
    test    r8d, r8d
    jz      .dd_loop                ; nothing to write
    mov     edi, STDOUT
    lea     rsi, [write_buf]
    mov     edx, r8d
    call    asm_write_all
    test    rax, rax
    js      .dd_write_error
    jmp     .dd_loop

.dd_write_error:
    cmp     rax, EPIPE
    je      .dd_done
    EXIT    1
.dd_error:
    EXIT    1
.dd_done:
    EXIT    0

; ── Squeeze mode (1 set) ──
do_squeeze:
    ; Parse set1
    mov     rdi, r13
    lea     rsi, [set1_expanded]
    call    parse_set
    mov     [set1_len], rax

    ; Build squeeze membership set
    lea     rsi, [set1_expanded]
    mov     rcx, [set1_len]
    lea     rdi, [squeeze_set]
    call    build_member_set

    ; Initialize prev byte to -1 (impossible value)
    mov     ebp, -1

    ; Main squeeze loop
.ds_loop:
    mov     edi, STDIN
    lea     rsi, [read_buf]
    mov     edx, BUF_SIZE
    call    asm_read
    test    rax, rax
    jz      .ds_done
    js      .ds_error

    mov     rcx, rax
    lea     rsi, [read_buf]
    lea     rdi, [write_buf]
    xor     edx, edx                ; read index
    xor     r8d, r8d                ; write index

.ds_byte:
    cmp     rdx, rcx
    jge     .ds_flush
    movzx   eax, byte [rsi + rdx]

    ; Check if byte is in squeeze_set AND == prev byte
    cmp     eax, ebp                ; same as previous?
    jne     .ds_emit

    ; Same as previous — check if in squeeze set
    push    rcx
    mov     ecx, eax
    and     ecx, 7
    mov     ebx, eax
    shr     ebx, 3
    movzx   r9d, byte [squeeze_set + rbx]
    bt      r9d, ecx
    pop     rcx
    jc      .ds_skip                ; in squeeze set AND same as prev — skip

.ds_emit:
    mov     [rdi + r8], al
    inc     r8d
    mov     ebp, eax                ; update prev byte
.ds_skip:
    inc     rdx
    jmp     .ds_byte

.ds_flush:
    test    r8d, r8d
    jz      .ds_loop
    mov     edi, STDOUT
    lea     rsi, [write_buf]
    mov     edx, r8d
    call    asm_write_all
    test    rax, rax
    js      .ds_write_error
    jmp     .ds_loop

.ds_write_error:
    cmp     rax, EPIPE
    je      .ds_done
    EXIT    1
.ds_error:
    EXIT    1
.ds_done:
    EXIT    0

; ── Delete + Squeeze mode ──
do_delete_squeeze:
    ; Parse set1 (for delete)
    mov     rdi, r13
    lea     rsi, [set1_expanded]
    call    parse_set
    mov     [set1_len], rax

    ; Parse set2 (for squeeze)
    mov     rdi, r14
    lea     rsi, [set2_expanded]
    call    parse_set
    mov     [set2_len], rax

    ; Build delete membership set from set1
    ; Need to handle complement: complement applies to delete set
    lea     rsi, [set1_expanded]
    mov     rcx, [set1_len]
    lea     rdi, [member_set]
    call    build_member_set        ; this handles FLAG_COMPLEMENT

    ; Build squeeze membership set from set2 (NO complement)
    ; Save and clear complement flag temporarily
    push    r12
    and     r12d, ~FLAG_COMPLEMENT
    lea     rsi, [set2_expanded]
    mov     rcx, [set2_len]
    lea     rdi, [squeeze_set]
    call    build_member_set
    pop     r12

    ; Initialize prev byte
    mov     ebp, -1

    ; Main loop: delete from member_set, then squeeze from squeeze_set
.dds_loop:
    mov     edi, STDIN
    lea     rsi, [read_buf]
    mov     edx, BUF_SIZE
    call    asm_read
    test    rax, rax
    jz      .dds_done
    js      .dds_error

    mov     rcx, rax
    lea     rsi, [read_buf]
    lea     rdi, [write_buf]
    xor     edx, edx
    xor     r8d, r8d

.dds_byte:
    cmp     rdx, rcx
    jge     .dds_flush
    movzx   eax, byte [rsi + rdx]

    ; Check if in delete set
    push    rcx
    mov     ecx, eax
    and     ecx, 7
    mov     ebx, eax
    shr     ebx, 3
    movzx   r9d, byte [member_set + rbx]
    bt      r9d, ecx
    pop     rcx
    jc      .dds_deleted

    ; Not deleted — check squeeze
    cmp     eax, ebp
    jne     .dds_emit
    ; Same as prev — check squeeze set
    push    rcx
    mov     ecx, eax
    and     ecx, 7
    mov     ebx, eax
    shr     ebx, 3
    movzx   r9d, byte [squeeze_set + rbx]
    bt      r9d, ecx
    pop     rcx
    jc      .dds_deleted            ; squeeze — skip

.dds_emit:
    mov     [rdi + r8], al
    inc     r8d
    mov     ebp, eax
.dds_deleted:
    inc     rdx
    jmp     .dds_byte

.dds_flush:
    test    r8d, r8d
    jz      .dds_loop
    mov     edi, STDOUT
    lea     rsi, [write_buf]
    mov     edx, r8d
    call    asm_write_all
    test    rax, rax
    js      .dds_write_error
    jmp     .dds_loop

.dds_write_error:
    cmp     rax, EPIPE
    je      .dds_done
    EXIT    1
.dds_error:
    EXIT    1
.dds_done:
    EXIT    0

; ── Translate + Squeeze mode ──
do_translate_squeeze:
    ; Parse set1
    mov     rdi, r13
    lea     rsi, [set1_expanded]
    call    parse_set
    mov     [set1_len], rax

    ; Parse set2
    mov     rdi, r14
    lea     rsi, [set2_expanded]
    call    parse_set
    mov     [set2_len], rax

    ; Build translate table
    call    build_translate_table

    ; Build squeeze set from set2 (the LAST specified set)
    ; Squeeze set should NOT use complement
    push    r12
    and     r12d, ~FLAG_COMPLEMENT
    lea     rsi, [set2_expanded]
    mov     rcx, [set2_len]
    lea     rdi, [squeeze_set]
    call    build_member_set
    pop     r12

    ; Initialize prev byte
    mov     ebp, -1

    ; Main translate + squeeze loop
.dts_loop:
    mov     edi, STDIN
    lea     rsi, [read_buf]
    mov     edx, BUF_SIZE
    call    asm_read
    test    rax, rax
    jz      .dts_done
    js      .dts_error

    mov     rcx, rax
    lea     rsi, [read_buf]
    lea     rdi, [write_buf]
    lea     rbx, [translate_table]
    xor     edx, edx
    xor     r8d, r8d

.dts_byte:
    cmp     rdx, rcx
    jge     .dts_flush
    movzx   eax, byte [rsi + rdx]
    ; Translate
    movzx   eax, byte [rbx + rax]

    ; Check squeeze
    cmp     eax, ebp
    jne     .dts_emit
    ; Same as prev — check squeeze set
    push    rcx
    mov     ecx, eax
    and     ecx, 7
    mov     r9d, eax
    shr     r9d, 3
    movzx   r10d, byte [squeeze_set + r9]
    bt      r10d, ecx
    pop     rcx
    jc      .dts_skip

.dts_emit:
    mov     [rdi + r8], al
    inc     r8d
    mov     ebp, eax
.dts_skip:
    inc     rdx
    jmp     .dts_byte

.dts_flush:
    test    r8d, r8d
    jz      .dts_loop
    mov     edi, STDOUT
    lea     rsi, [write_buf]
    mov     edx, r8d
    call    asm_write_all
    test    rax, rax
    js      .dts_write_error
    jmp     .dts_loop

.dts_write_error:
    cmp     rax, EPIPE
    je      .dts_done
    EXIT    1
.dts_error:
    EXIT    1
.dts_done:
    EXIT    0

section .note.GNU-stack noalloc noexec nowrite progbits
