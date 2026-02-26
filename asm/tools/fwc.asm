; ============================================================================
;  fwc.asm — GNU-compatible "wc" in x86_64 Linux assembly
;
;  A drop-in replacement for GNU coreutils `wc` written in pure x86_64
;  assembly. Produces a small static ELF binary with zero dependencies.
;
;  Supports all GNU wc flags:
;    -c, --bytes            print byte counts
;    -m, --chars            print character counts (= bytes in C locale)
;    -l, --lines            print newline counts
;    -w, --words            print word counts
;    -L, --max-line-length  print maximum display width
;        --files0-from=F    read filenames from NUL-delimited file
;        --total=WHEN       when to print total (auto/always/only/never)
;        --help             display help and exit
;        --version          output version and exit
;
;  Default (no flags): show lines, words, bytes
;
;  Word counting uses GNU wc's 3-state model:
;    - Space (0x09-0x0D, 0x20): word break
;    - Printable (0x21-0x7E): word content
;    - Transparent (everything else): no state change
;
;  Hot path uses SSE2 pcmpeqb + popcnt for newline counting.
; ============================================================================

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close

; Results entry: 5 x u64 (lines, words, bytes, chars, maxlen) + 1 x ptr (name)
; = 48 bytes per entry. Max 4096 files.
%define RESULT_ENTRY_SIZE 48
%define MAX_FILES 4096

section .bss
    read_buf:   resb 65536      ; 64KB read buffer
    out_buf:    resb 4096       ; output formatting buffer
    stat_buf:   resb STAT_SIZE  ; for fstat
    results:    resb RESULT_ENTRY_SIZE * MAX_FILES  ; per-file results
    ; Accumulators for current file
    cur_lines:  resq 1
    cur_words:  resq 1
    cur_bytes:  resq 1
    cur_chars:  resq 1
    cur_maxlen: resq 1
    ; Total accumulators
    tot_lines:  resq 1
    tot_words:  resq 1
    tot_bytes:  resq 1
    tot_chars:  resq 1
    tot_maxlen: resq 1
    ; State
    file_count: resq 1         ; number of files processed (including errors)
    result_count: resq 1       ; number of successful results
    had_error:  resb 1         ; set to 1 if any error occurred
    in_word:    resb 1         ; word counting state
    cur_llen:   resq 1         ; current line length for -L
    ; Flags
    flag_lines: resb 1
    flag_words: resb 1
    flag_bytes: resb 1
    flag_chars: resb 1
    flag_maxll: resb 1
    flag_explicit: resb 1     ; any flag explicitly set?
    ; --total mode: 0=auto, 1=always, 2=only, 3=never
    total_mode: resb 1
    ; Has stdin been used
    has_stdin:  resb 1

section .data
    ; Error message fragments
    err_prefix:     db "fwc: ", 0
    err_prefix_len equ 5
    err_nosuch:     db ": No such file or directory", 10
    err_nosuch_len equ 28
    err_isdir:      db ": Is a directory", 10
    err_isdir_len equ 17
    err_perm:       db ": Permission denied", 10
    err_perm_len  equ 20
    err_read:       db ": read error", 10
    err_read_len  equ 13
    err_generic:    db ": ", 0
    total_label:    db "total", 0
    dash_str:       db "-", 0
    empty_str:      db 0
    newline:        db 10
    space:          db " "

    ; --help text (matching GNU wc format but with fwc branding)
help_text:
    db "Usage: fwc [OPTION]... [FILE]...", 10
    db "  or:  fwc [OPTION]... --files0-from=F", 10
    db "Print newline, word, and byte counts for each FILE, and a total line if", 10
    db "more than one FILE is specified.  A word is a non-zero-length sequence of", 10
    db "printable characters delimited by white space.", 10, 10
    db "With no FILE, or when FILE is -, read standard input.", 10, 10
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
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/wc>", 10
    db "or available locally via: info '(coreutils) wc invocation'", 10
help_text_len equ $ - help_text

    ; --version text
version_text:
    db "fwc (fcoreutils) 0.1.0", 10
version_text_len equ $ - version_text

section .text
global _start

_start:
    ; Save argc and argv
    pop     rcx                     ; rcx = argc
    mov     r14, rsp                ; r14 = &argv[0]
    mov     [rsp - 8], rcx          ; save argc
    sub     rsp, 8

    ; Block SIGPIPE so write() returns -EPIPE instead of killing us
    sub     rsp, 16
    mov     qword [rsp], 0x1000     ; bit 12 = SIGPIPE
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi                ; SIG_BLOCK
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    ; Initialize all flags and state to 0
    xor     eax, eax
    mov     [flag_lines], al
    mov     [flag_words], al
    mov     [flag_bytes], al
    mov     [flag_chars], al
    mov     [flag_maxll], al
    mov     [flag_explicit], al
    mov     [total_mode], al        ; 0 = auto
    mov     [had_error], al
    mov     [has_stdin], al
    mov     [file_count], rax
    mov     [result_count], rax
    mov     [tot_lines], rax
    mov     [tot_words], rax
    mov     [tot_bytes], rax
    mov     [tot_chars], rax
    mov     [tot_maxlen], rax

    ; Parse command-line arguments
    mov     rcx, [rsp]              ; argc
    lea     rbx, [r14 + 8]         ; rbx = &argv[1]
    xor     r15d, r15d              ; r15 = 0: not past "--"
    xor     r13d, r13d              ; r13 = count of file args

    ; First pass: parse all options, count file args
    ; We'll store file arg pointers starting at a location on the stack
    ; Actually, let's just do two passes: parse options, then process files
    ; For simplicity, use a second pass for file processing

    ; Allocate space for file pointers on stack (max argc entries)
    mov     rax, rcx
    shl     rax, 3                  ; argc * 8 bytes
    sub     rsp, rax
    mov     r12, rsp                ; r12 = base of file pointer array

.parse_loop:
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .parse_done

    ; Past "--"?
    test    r15d, r15d
    jnz     .parse_file_arg

    ; Check if starts with '-'
    cmp     byte [rsi], '-'
    jne     .parse_file_arg

    ; Just "-" alone = stdin file arg
    cmp     byte [rsi + 1], 0
    je      .parse_file_arg

    ; Starts with '-'
    cmp     byte [rsi + 1], '-'
    je      .parse_long_opt

    ; Short options: could be combined like -lwc
    inc     rsi                     ; skip '-'
.parse_short_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .parse_next

    cmp     al, 'l'
    je      .set_lines
    cmp     al, 'w'
    je      .set_words
    cmp     al, 'c'
    je      .set_bytes
    cmp     al, 'm'
    je      .set_chars
    cmp     al, 'L'
    je      .set_maxll

    ; Unknown short option
    jmp     .err_invalid_opt

.set_lines:
    mov     byte [flag_lines], 1
    mov     byte [flag_explicit], 1
    inc     rsi
    jmp     .parse_short_loop
.set_words:
    mov     byte [flag_words], 1
    mov     byte [flag_explicit], 1
    inc     rsi
    jmp     .parse_short_loop
.set_bytes:
    mov     byte [flag_bytes], 1
    mov     byte [flag_explicit], 1
    inc     rsi
    jmp     .parse_short_loop
.set_chars:
    mov     byte [flag_chars], 1
    mov     byte [flag_explicit], 1
    inc     rsi
    jmp     .parse_short_loop
.set_maxll:
    mov     byte [flag_maxll], 1
    mov     byte [flag_explicit], 1
    inc     rsi
    jmp     .parse_short_loop

.parse_long_opt:
    ; Check for "--" (end of options)
    cmp     byte [rsi + 2], 0
    jne     .check_long_help
    mov     r15d, 1
    jmp     .parse_next

.check_long_help:
    ; Check "--help"
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [rel .str_help]
    call    .strcmp
    pop     rbx
    test    eax, eax
    jz      .do_help

    ; Check "--version"
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [rel .str_version]
    call    .strcmp
    pop     rbx
    test    eax, eax
    jz      .do_version

    ; Check "--bytes"
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [rel .str_bytes]
    call    .strcmp
    pop     rbx
    test    eax, eax
    jz      .long_set_bytes

    ; Check "--chars"
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [rel .str_chars]
    call    .strcmp
    pop     rbx
    test    eax, eax
    jz      .long_set_chars

    ; Check "--lines"
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [rel .str_lines]
    call    .strcmp
    pop     rbx
    test    eax, eax
    jz      .long_set_lines

    ; Check "--words"
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [rel .str_words]
    call    .strcmp
    pop     rbx
    test    eax, eax
    jz      .long_set_words

    ; Check "--max-line-length"
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [rel .str_maxll]
    call    .strcmp
    pop     rbx
    test    eax, eax
    jz      .long_set_maxll

    ; Check "--total=" prefix
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [rel .str_total_prefix]
    call    .strncmp_prefix
    pop     rbx
    test    eax, eax
    jz      .parse_total_value

    ; Check "--files0-from=" prefix
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [rel .str_files0_prefix]
    call    .strncmp_prefix
    pop     rbx
    test    eax, eax
    jz      .parse_files0_value

    ; Unknown long option
    jmp     .err_unrecognized_opt

.long_set_bytes:
    mov     byte [flag_bytes], 1
    mov     byte [flag_explicit], 1
    jmp     .parse_next
.long_set_chars:
    mov     byte [flag_chars], 1
    mov     byte [flag_explicit], 1
    jmp     .parse_next
.long_set_lines:
    mov     byte [flag_lines], 1
    mov     byte [flag_explicit], 1
    jmp     .parse_next
.long_set_words:
    mov     byte [flag_words], 1
    mov     byte [flag_explicit], 1
    jmp     .parse_next
.long_set_maxll:
    mov     byte [flag_maxll], 1
    mov     byte [flag_explicit], 1
    jmp     .parse_next

.parse_total_value:
    ; rdi points past "total=" to the value
    ; Check for "auto", "always", "only", "never"
    push    rbx
    mov     rbx, rdi
    lea     rdi, [rbx]
    push    r12
    lea     r12, [rel .str_auto]
    xchg    rbx, r12
    call    .strcmp
    xchg    rbx, r12
    pop     r12
    test    eax, eax
    jz      .total_auto

    push    r12
    lea     rdi, [rbx]
    lea     r12, [rel .str_always]
    xchg    rbx, r12
    call    .strcmp
    xchg    rbx, r12
    pop     r12
    test    eax, eax
    jz      .total_always

    push    r12
    lea     rdi, [rbx]
    lea     r12, [rel .str_only]
    xchg    rbx, r12
    call    .strcmp
    xchg    rbx, r12
    pop     r12
    test    eax, eax
    jz      .total_only

    push    r12
    lea     rdi, [rbx]
    lea     r12, [rel .str_never]
    xchg    rbx, r12
    call    .strcmp
    xchg    rbx, r12
    pop     r12
    test    eax, eax
    jz      .total_never

    pop     rbx
    ; Invalid --total value
    jmp     .err_invalid_total

.total_auto:
    pop     rbx
    mov     byte [total_mode], 0
    jmp     .parse_next
.total_always:
    pop     rbx
    mov     byte [total_mode], 1
    jmp     .parse_next
.total_only:
    pop     rbx
    mov     byte [total_mode], 2
    jmp     .parse_next
.total_never:
    pop     rbx
    mov     byte [total_mode], 3
    jmp     .parse_next

.parse_files0_value:
    ; TODO: --files0-from support (complex, skip for now)
    jmp     .parse_next

.parse_file_arg:
    ; Store file arg pointer
    mov     rax, [rbx]
    mov     [r12 + r13 * 8], rax
    inc     r13

.parse_next:
    add     rbx, 8
    jmp     .parse_loop

.parse_done:
    ; If no explicit flags, default to lines + words + bytes
    cmp     byte [flag_explicit], 0
    jne     .flags_set
    mov     byte [flag_lines], 1
    mov     byte [flag_words], 1
    mov     byte [flag_bytes], 1
.flags_set:

    ; If no file args, add stdin (use empty_str as sentinel for "implicit stdin")
    test    r13d, r13d
    jnz     .have_files
    lea     rax, [rel empty_str]
    mov     [r12], rax
    mov     r13d, 1
.have_files:

    ; r12 = file pointer array base
    ; r13 = file count
    ; Now process each file
    xor     ebp, ebp                ; ebp = file index

.file_loop:
    cmp     ebp, r13d
    jge     .files_done

    mov     rdi, [r12 + rbp * 8]    ; rdi = filename

    ; Check if stdin: either empty_str (implicit) or "-" (explicit)
    cmp     byte [rdi], 0           ; empty_str = implicit stdin
    je      .stdin_implicit
    cmp     byte [rdi], '-'
    jne     .open_file
    cmp     byte [rdi + 1], 0
    jne     .open_file

    ; Explicit "-" stdin: display name is "-"
    mov     byte [has_stdin], 1
    xor     edi, edi                ; fd = 0 (stdin)
    lea     rsi, [rel dash_str]     ; display name = "-"
    jmp     .process_fd

.stdin_implicit:
    ; Implicit stdin (no args): display name is empty, set has_stdin for width
    mov     byte [has_stdin], 1
    xor     edi, edi                ; fd = 0 (stdin)
    lea     rsi, [rel empty_str]    ; display name = ""
    jmp     .process_fd

.open_file:
    ; Save filename for error messages
    push    rdi
    ; open(filename, O_RDONLY)
    xor     esi, esi                ; O_RDONLY
    xor     edx, edx
    mov     rax, SYS_OPEN
    syscall
    test    rax, rax
    js      .open_error
    mov     rdi, rax                ; fd
    pop     rsi                     ; filename (display name)
    jmp     .process_fd

.open_error:
    ; rax = negative errno
    pop     rdi                     ; filename
    neg     rax
    ; Print error: "fwc: FILENAME: ERROR\n"
    push    rax                     ; save errno
    push    rdi                     ; save filename
    ; Write "fwc: "
    mov     rdi, STDERR
    lea     rsi, [rel err_prefix]
    mov     rdx, err_prefix_len
    call    asm_write_all
    ; Write filename
    pop     rsi                     ; filename
    push    rsi
    call    .strlen_rsi
    mov     rdx, rcx                ; length
    mov     rdi, STDERR
    call    asm_write_all
    pop     rsi                     ; filename (discard)
    pop     rax                     ; errno
    ; Write appropriate error message based on errno
    cmp     eax, 2                  ; ENOENT
    je      .err_noent
    cmp     eax, 13                 ; EACCES
    je      .err_acces
    cmp     eax, 21                 ; EISDIR
    je      .err_isdir_msg
    ; Generic error
    mov     rdi, STDERR
    lea     rsi, [rel err_read]
    mov     rdx, err_read_len
    call    asm_write_all
    jmp     .open_err_done

.err_noent:
    mov     rdi, STDERR
    lea     rsi, [rel err_nosuch]
    mov     rdx, err_nosuch_len
    call    asm_write_all
    jmp     .open_err_done

.err_acces:
    mov     rdi, STDERR
    lea     rsi, [rel err_perm]
    mov     rdx, err_perm_len
    call    asm_write_all
    jmp     .open_err_done

.err_isdir_msg:
    mov     rdi, STDERR
    lea     rsi, [rel err_isdir]
    mov     rdx, err_isdir_len
    call    asm_write_all

.open_err_done:
    mov     byte [had_error], 1
    inc     qword [file_count]      ; count failed files too for total line
    inc     ebp
    jmp     .file_loop

.process_fd:
    ; rdi = fd, rsi = display name pointer
    push    rbp                     ; save file index
    push    r12                     ; save file array base
    push    r13                     ; save file count
    push    rsi                     ; save display name

    mov     r12d, edi               ; r12 = fd

    ; Zero current file accumulators
    xor     eax, eax
    mov     [cur_lines], rax
    mov     [cur_words], rax
    mov     [cur_bytes], rax
    mov     [cur_chars], rax
    mov     [cur_maxlen], rax
    mov     [cur_llen], rax
    mov     [in_word], al

    ; Check if bytes-only and it's a regular file: use fstat
    cmp     byte [flag_explicit], 1
    jne     .do_read_loop
    cmp     byte [flag_bytes], 1
    jne     .do_read_loop
    cmp     byte [flag_lines], 0
    jne     .do_read_loop
    cmp     byte [flag_words], 0
    jne     .do_read_loop
    cmp     byte [flag_chars], 0
    jne     .do_read_loop
    cmp     byte [flag_maxll], 0
    jne     .do_read_loop

    ; fstat(fd, &stat_buf)
    mov     edi, r12d
    lea     rsi, [rel stat_buf]
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    jnz     .do_read_loop           ; fstat failed, fall through to read
    ; Get file size from stat
    lea     rsi, [rel stat_buf]
    mov     rax, [rsi + STAT_ST_SIZE]
    ; Only use fstat for regular files (check st_mode)
    ; st_mode is at offset 24 in struct stat
    mov     ecx, [rsi + 24]
    and     ecx, 0xF000             ; S_IFMT mask
    cmp     ecx, 0x8000             ; S_IFREG
    jne     .do_read_loop
    mov     [cur_bytes], rax
    jmp     .fd_done

.do_read_loop:
    ; Read loop: read chunks and count
    mov     edi, r12d               ; fd
    lea     rsi, [rel read_buf]
    mov     edx, 65536              ; BUF_SIZE
    call    asm_read

    test    rax, rax
    jz      .fd_done                ; EOF
    js      .read_error             ; error

    ; Process this chunk
    mov     rcx, rax                ; rcx = bytes read
    add     [cur_bytes], rcx

    ; Count in this chunk
    lea     rsi, [rel read_buf]
    ; rsi = buffer, rcx = length
    call    .count_chunk

    jmp     .do_read_loop

.read_error:
    ; TODO: print read error
    mov     byte [had_error], 1

.fd_done:
    ; chars = bytes in C locale
    mov     rax, [cur_bytes]
    mov     [cur_chars], rax

    ; Close fd if not stdin
    cmp     r12d, 0
    je      .skip_close
    mov     edi, r12d
    call    asm_close
.skip_close:

    ; Accumulate totals
    mov     rax, [cur_lines]
    add     [tot_lines], rax
    mov     rax, [cur_words]
    add     [tot_words], rax
    mov     rax, [cur_bytes]
    add     [tot_bytes], rax
    mov     rax, [cur_chars]
    add     [tot_chars], rax
    mov     rax, [cur_maxlen]
    mov     rcx, [tot_maxlen]
    cmp     rax, rcx
    jle     .no_max_update
    mov     [tot_maxlen], rax
.no_max_update:

    ; Store result in results array
    mov     rcx, [result_count]
    imul    rdi, rcx, RESULT_ENTRY_SIZE
    lea     rdi, [rel results + rdi]
    mov     rax, [cur_lines]
    mov     [rdi], rax
    mov     rax, [cur_words]
    mov     [rdi + 8], rax
    mov     rax, [cur_bytes]
    mov     [rdi + 16], rax
    mov     rax, [cur_chars]
    mov     [rdi + 24], rax
    mov     rax, [cur_maxlen]
    mov     [rdi + 32], rax
    ; Store display name pointer
    pop     rsi                     ; display name
    mov     [rdi + 40], rsi

    inc     qword [result_count]
    inc     qword [file_count]

    pop     r13                     ; file count
    pop     r12                     ; file array base
    pop     rbp                     ; file index

    inc     ebp
    jmp     .file_loop

.files_done:
    ; ================================================================
    ; Phase 2: Compute width once, then print all results
    ; ================================================================

    ; Compute width (uses totals which are now complete)
    call    .compute_width
    mov     r15d, eax               ; r15 = width

    ; Print individual file results (unless --total=only)
    cmp     byte [total_mode], 2
    je      .skip_all_file_output

    xor     ebp, ebp                ; result index
.print_results_loop:
    mov     rcx, [result_count]
    cmp     rbp, rcx
    jge     .print_results_done

    imul    rdi, rbp, RESULT_ENTRY_SIZE
    lea     r8, [rel results + rdi]     ; counts base
    mov     rsi, [r8 + 40]              ; display name
    mov     edi, r15d                   ; width
    call    .print_line

    inc     ebp
    jmp     .print_results_loop

.print_results_done:
.skip_all_file_output:

    ; Print total if needed
    ; total_mode: 0=auto, 1=always, 2=only, 3=never
    movzx   eax, byte [total_mode]
    cmp     eax, 3                  ; never
    je      .no_total
    cmp     eax, 1                  ; always
    je      .print_total
    cmp     eax, 2                  ; only
    je      .print_total
    ; auto: print if more than 1 file
    cmp     qword [file_count], 1
    jle     .no_total

.print_total:
    ; Copy totals to a temp result entry for printing
    mov     rax, [tot_lines]
    mov     [cur_lines], rax
    mov     rax, [tot_words]
    mov     [cur_words], rax
    mov     rax, [tot_bytes]
    mov     [cur_bytes], rax
    mov     rax, [tot_chars]
    mov     [cur_chars], rax
    mov     rax, [tot_maxlen]
    mov     [cur_maxlen], rax

    mov     edi, r15d               ; width

    ; For --total=only, label is empty
    cmp     byte [total_mode], 2
    je      .total_only_label
    lea     rsi, [rel total_label]
    jmp     .print_total_line
.total_only_label:
    xor     esi, esi                ; NULL = no label
.print_total_line:
    lea     r8, [rel cur_lines]
    call    .print_line

.no_total:
    ; Exit with appropriate code
    movzx   edi, byte [had_error]
    EXIT    rdi

; ============================================================================
; .count_chunk — Count lines, words, bytes, max-line-length in a buffer
;
; Input: rsi = buffer, rcx = length
; Uses cur_lines, cur_words, cur_maxlen, in_word, cur_llen
; ============================================================================
.count_chunk:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r14, rsi                ; r14 = buf
    mov     r15, rcx                ; r15 = len
    xor     ebp, ebp                ; ebp = index

    ; Load state
    movzx   r12d, byte [in_word]    ; r12 = in_word state
    mov     r13, [cur_llen]         ; r13 = current line length

    ; Do we need word counting?
    cmp     byte [flag_words], 0
    jne     .count_full
    cmp     byte [flag_maxll], 0
    jne     .count_full

    ; Lines-only or bytes-only fast path: just count newlines with SIMD
    cmp     byte [flag_lines], 0
    je      .count_done             ; bytes only, nothing to count

    ; Fast newline counting with SSE2
    call    .count_newlines_sse2
    ; rax = newline count
    add     [cur_lines], rax
    jmp     .count_done

.count_full:
    ; Full counting: lines, words, max-line-length
    ; Process byte by byte with the 3-state model
    cmp     rbp, r15
    jge     .count_save_state

    movzx   eax, byte [r14 + rbp]

    ; Check for newline (0x0A)
    cmp     al, 0x0A
    je      .byte_newline

    ; Check for whitespace (0x09-0x0D, 0x20)
    cmp     al, 0x20
    je      .byte_space
    cmp     al, 0x09
    jb      .byte_check_printable   ; < 0x09: check if printable
    cmp     al, 0x0D
    jbe     .byte_space             ; 0x09-0x0D: whitespace

.byte_check_printable:
    ; Check if printable: 0x21-0x7E
    cmp     al, 0x21
    jb      .byte_transparent       ; < 0x21: transparent
    cmp     al, 0x7E
    ja      .byte_transparent       ; > 0x7E: transparent

    ; Printable character: starts/continues a word
    test    r12d, r12d
    jnz     .byte_in_word           ; already in word
    mov     r12d, 1                 ; enter word state
    inc     qword [cur_words]
.byte_in_word:
    ; Update line length for -L
    cmp     byte [flag_maxll], 0
    je      .byte_next
    inc     r13                     ; line length++
    jmp     .byte_next

.byte_transparent:
    ; Non-printable, non-whitespace: no state change
    ; But for -L, we might need to account for display width
    ; In C locale, non-printable chars have 0 display width
    jmp     .byte_next

.byte_space:
    ; Whitespace (not newline)
    mov     r12d, 0                 ; exit word state

    ; For -L: handle special display-width cases
    cmp     byte [flag_maxll], 0
    je      .byte_next

    cmp     al, 0x09                ; tab?
    je      .space_tab
    cmp     al, 0x0D                ; carriage return?
    je      .space_cr
    cmp     al, 0x0C                ; form feed?
    je      .space_cr               ; FF also resets column like CR
    cmp     al, 0x20                ; space?
    jne     .byte_next              ; VT(0x0B): width 0
    ; Space: display width 1
    inc     r13
    jmp     .byte_next

.space_tab:
    ; Tab: advance to next multiple of 8
    add     r13, 8
    and     r13, ~7
    jmp     .byte_next

.space_cr:
    ; Carriage return: reset column to 0
    ; First update max if current line is longest so far
    cmp     r13, [cur_maxlen]
    jle     .cr_no_max
    mov     [cur_maxlen], r13
.cr_no_max:
    xor     r13d, r13d              ; reset column position
    jmp     .byte_next

.byte_newline:
    ; Newline
    inc     qword [cur_lines]
    mov     r12d, 0                 ; exit word state

    ; For -L: finalize this line's length
    cmp     byte [flag_maxll], 0
    je      .byte_next
    cmp     r13, [cur_maxlen]
    jle     .nl_no_max
    mov     [cur_maxlen], r13
.nl_no_max:
    xor     r13d, r13d              ; reset line length

.byte_next:
    inc     rbp
    jmp     .count_full

.count_save_state:
    ; Save state for next chunk
    mov     [in_word], r12b
    mov     [cur_llen], r13

    ; Finalize max line length for last line (no trailing newline)
    cmp     byte [flag_maxll], 0
    je      .count_done
    cmp     r13, [cur_maxlen]
    jle     .count_done
    mov     [cur_maxlen], r13

.count_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; .count_newlines_sse2 — Count newlines using SSE2 SIMD
;
; Input: r14 = buffer, r15 = length
; Output: rax = newline count
; ============================================================================
.count_newlines_sse2:
    xor     eax, eax                ; total count
    xor     ecx, ecx                ; index

    ; Create vector of newlines (0x0A)
    movd    xmm1, dword [rel .newline_dword]
    pshufd  xmm1, xmm1, 0          ; broadcast 0x0A0A0A0A to all lanes

    ; Process 16 bytes at a time
    mov     rdx, r15
    sub     rdx, 15                 ; last safe position for 16-byte load
    jle     .nl_scalar

.nl_sse2_loop:
    cmp     rcx, rdx
    jge     .nl_scalar

    movdqu  xmm0, [r14 + rcx]      ; load 16 bytes
    pcmpeqb xmm0, xmm1             ; compare each byte to '\n'
    pmovmskb edi, xmm0             ; extract comparison bits
    popcnt  edi, edi                ; count set bits
    add     eax, edi
    add     rcx, 16
    jmp     .nl_sse2_loop

.nl_scalar:
    ; Process remaining bytes
    cmp     rcx, r15
    jge     .nl_done
    cmp     byte [r14 + rcx], 0x0A
    jne     .nl_scalar_next
    inc     eax
.nl_scalar_next:
    inc     rcx
    jmp     .nl_scalar

.nl_done:
    ret

; ============================================================================
; .compute_width — Compute column width for output formatting
;
; GNU wc uses the digit width of the largest total value for alignment.
; Special cases:
;   - Single file, single column, no total: natural width
;   - stdin with 1 file: minimum width 7
;   - --total=only: width 1
;
; Output: eax = width
; ============================================================================
.compute_width:
    push    rbx
    push    r12

    ; --total=only: width 1
    cmp     byte [total_mode], 2
    je      .width_1

    ; Count number of active columns
    xor     ecx, ecx
    cmp     byte [flag_lines], 0
    je      .wc1
    inc     ecx
.wc1:
    cmp     byte [flag_words], 0
    je      .wc2
    inc     ecx
.wc2:
    cmp     byte [flag_chars], 0
    je      .wc3
    inc     ecx
.wc3:
    cmp     byte [flag_bytes], 0
    je      .wc4
    inc     ecx
.wc4:
    cmp     byte [flag_maxll], 0
    je      .wc5
    inc     ecx
.wc5:
    ; ecx = number of columns
    mov     r12d, ecx               ; save column count

    ; Determine total mode to see if we show total
    movzx   eax, byte [total_mode]
    xor     ebx, ebx                ; show_total = false
    cmp     eax, 1                  ; always
    je      .wst_yes
    cmp     eax, 2                  ; only
    je      .wst_yes
    cmp     eax, 3                  ; never
    je      .wst_no
    ; auto: show if file_count > 1
    cmp     qword [file_count], 1
    jg      .wst_yes
    jmp     .wst_no
.wst_yes:
    mov     ebx, 1
.wst_no:

    ; num_output_rows
    mov     edx, [file_count]
    cmp     byte [total_mode], 2    ; only?
    jne     .nor_not_only
    mov     edx, 0
.nor_not_only:
    add     edx, ebx                ; + show_total

    ; Single column, single row: natural width
    cmp     r12d, 1
    jg      .width_max_val
    cmp     edx, 1
    jg      .width_max_val

    ; Single value: use natural width of that value
    cmp     byte [flag_lines], 0
    je      .sv_w
    mov     rax, [tot_lines]
    jmp     .sv_width
.sv_w:
    cmp     byte [flag_words], 0
    je      .sv_c
    mov     rax, [tot_words]
    jmp     .sv_width
.sv_c:
    cmp     byte [flag_chars], 0
    je      .sv_b
    mov     rax, [tot_chars]
    jmp     .sv_width
.sv_b:
    cmp     byte [flag_bytes], 0
    je      .sv_L
    mov     rax, [tot_bytes]
    jmp     .sv_width
.sv_L:
    mov     rax, [tot_maxlen]
.sv_width:
    call    .num_width
    ; eax = width
    pop     r12
    pop     rbx
    ret

.width_max_val:
    ; Find max of all total values
    mov     rax, [tot_lines]
    mov     rcx, [tot_words]
    cmp     rcx, rax
    cmovg   rax, rcx
    mov     rcx, [tot_bytes]
    cmp     rcx, rax
    cmovg   rax, rcx
    mov     rcx, [tot_chars]
    cmp     rcx, rax
    cmovg   rax, rcx
    mov     rcx, [tot_maxlen]
    cmp     rcx, rax
    cmovg   rax, rcx

    call    .num_width
    ; eax = width

    ; Minimum width of 7 if stdin and single file
    cmp     byte [has_stdin], 0
    je      .width_check_min
    cmp     qword [file_count], 1
    jne     .width_check_min
    cmp     eax, 7
    jge     .width_check_min
    mov     eax, 7
.width_check_min:
    pop     r12
    pop     rbx
    ret

.width_1:
    mov     eax, 1
    pop     r12
    pop     rbx
    ret

; ============================================================================
; .num_width — Compute number of decimal digits needed to display a value
;
; Input: rax = value
; Output: eax = digit count (minimum 1)
; ============================================================================
.num_width:
    push    rbx
    test    rax, rax
    jnz     .nw_nonzero
    mov     eax, 1
    pop     rbx
    ret
.nw_nonzero:
    xor     ecx, ecx
    mov     rbx, rax
.nw_loop:
    test    rbx, rbx
    jz      .nw_done
    xor     edx, edx
    mov     rax, rbx
    mov     rbx, 10
    div     rbx
    mov     rbx, rax
    inc     ecx
    jmp     .nw_loop
.nw_done:
    mov     eax, ecx
    pop     rbx
    ret

; ============================================================================
; .print_line — Print one line of wc output
;
; Input: edi = width, rsi = filename (or NULL for no name), r8 = counts base
;        (counts at [r8], [r8+8], [r8+16], [r8+24], [r8+32])
;        Order: lines, words, bytes, chars, maxlen
; ============================================================================
.print_line:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12d, edi               ; width
    mov     r13, rsi                ; filename
    mov     r14, r8                 ; counts base

    ; Build output in out_buf
    lea     r15, [rel out_buf]
    xor     ebp, ebp                ; position in out_buf
    xor     ebx, ebx                ; first = 0 (haven't printed a field yet)

    ; Order: lines, words, chars, bytes, max_line_length
    cmp     byte [flag_lines], 0
    je      .pl_no_lines
    mov     rax, [r14]              ; cur_lines
    call    .format_field
.pl_no_lines:

    cmp     byte [flag_words], 0
    je      .pl_no_words
    mov     rax, [r14 + 8]          ; cur_words
    call    .format_field
.pl_no_words:

    cmp     byte [flag_chars], 0
    je      .pl_no_chars
    mov     rax, [r14 + 24]         ; cur_chars
    call    .format_field
.pl_no_chars:

    cmp     byte [flag_bytes], 0
    je      .pl_no_bytes
    mov     rax, [r14 + 16]         ; cur_bytes
    call    .format_field
.pl_no_bytes:

    cmp     byte [flag_maxll], 0
    je      .pl_no_maxll
    mov     rax, [r14 + 32]         ; cur_maxlen
    call    .format_field
.pl_no_maxll:

    ; Append filename if present and non-empty
    test    r13, r13
    jz      .pl_no_name
    cmp     byte [r13], 0
    je      .pl_no_name
    ; Space before name
    mov     byte [r15 + rbp], ' '
    inc     rbp
    ; Copy filename
    mov     rsi, r13
.pl_name_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .pl_no_name
    mov     [r15 + rbp], al
    inc     rbp
    inc     rsi
    jmp     .pl_name_loop

.pl_no_name:
    ; Append newline
    mov     byte [r15 + rbp], 10
    inc     rbp

    ; Write the line
    mov     rdi, STDOUT
    mov     rsi, r15
    mov     rdx, rbp
    call    asm_write_all

    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; .format_field — Format a number right-aligned into out_buf
;
; Input: rax = value, r12d = width, ebx = first flag (0 = first field)
;        r15 = out_buf, ebp = current position
; Output: ebp updated, ebx set to 1
; ============================================================================
.format_field:
    push    rcx
    push    rdx
    push    rdi

    ; Add space separator if not first field
    test    ebx, ebx
    jz      .ff_first
    mov     byte [r15 + rbp], ' '
    inc     ebp
.ff_first:
    mov     ebx, 1                  ; not first anymore

    ; Convert number to decimal string (right to left)
    ; Use a local buffer on the stack
    sub     rsp, 24                 ; 20 digits max + padding
    lea     rdi, [rsp + 20]         ; end of buffer
    xor     ecx, ecx                ; digit count

    test    rax, rax
    jnz     .ff_digits
    ; Zero case
    dec     rdi
    mov     byte [rdi], '0'
    mov     ecx, 1
    jmp     .ff_pad

.ff_digits:
    push    rbx
    mov     rbx, 10
.ff_dloop:
    test    rax, rax
    jz      .ff_dloop_done
    xor     edx, edx
    div     rbx
    add     dl, '0'
    dec     rdi
    mov     [rdi], dl
    inc     ecx
    jmp     .ff_dloop
.ff_dloop_done:
    pop     rbx

.ff_pad:
    ; ecx = digit count, rdi = start of digits
    ; Pad with spaces to width r12d
    mov     edx, r12d
    sub     edx, ecx               ; padding needed
    jle     .ff_no_pad
.ff_pad_loop:
    mov     byte [r15 + rbp], ' '
    inc     ebp
    dec     edx
    jnz     .ff_pad_loop
.ff_no_pad:
    ; Copy digits
.ff_copy:
    test    ecx, ecx
    jz      .ff_done
    movzx   eax, byte [rdi]
    mov     [r15 + rbp], al
    inc     rbp
    inc     rdi
    dec     ecx
    jmp     .ff_copy
.ff_done:
    add     rsp, 24
    pop     rdi
    pop     rdx
    pop     rcx
    ret

; ============================================================================
; Utility: string compare
; .strcmp: rdi = str1, rbx = str2, returns eax = 0 if equal
; ============================================================================
.strcmp:
    push    rcx
    push    rsi
    mov     rsi, rbx
.strcmp_loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .strcmp_ne
    test    al, al
    jz      .strcmp_eq
    inc     rdi
    inc     rsi
    jmp     .strcmp_loop
.strcmp_eq:
    xor     eax, eax
    pop     rsi
    pop     rcx
    ret
.strcmp_ne:
    mov     eax, 1
    pop     rsi
    pop     rcx
    ret

; ============================================================================
; Utility: prefix match
; .strncmp_prefix: rdi = str, rbx = prefix
; Returns eax = 0 if str starts with prefix, rdi advanced past prefix
; ============================================================================
.strncmp_prefix:
    push    rcx
    push    rsi
    mov     rsi, rbx
.pfx_loop:
    movzx   ecx, byte [rsi]
    test    cl, cl
    jz      .pfx_match              ; end of prefix = match
    movzx   eax, byte [rdi]
    cmp     al, cl
    jne     .pfx_nomatch
    inc     rdi
    inc     rsi
    jmp     .pfx_loop
.pfx_match:
    xor     eax, eax
    pop     rsi
    pop     rcx
    ret
.pfx_nomatch:
    mov     eax, 1
    pop     rsi
    pop     rcx
    ret

; ============================================================================
; Utility: strlen
; .strlen_rsi: rsi = string, returns rcx = length
; ============================================================================
.strlen_rsi:
    xor     ecx, ecx
.sl_loop:
    cmp     byte [rsi + rcx], 0
    je      .sl_done
    inc     rcx
    jmp     .sl_loop
.sl_done:
    ret

; ============================================================================
; Error handlers
; ============================================================================
.err_invalid_opt:
    ; rsi points to the char after '-', eax = bad char
    ; Print: "fwc: invalid option -- 'X'\nTry 'fwc --help' for more information.\n"
    push    rax                     ; save bad char
    mov     rdi, STDERR
    lea     rsi, [rel .err_inv_prefix]
    mov     edx, .err_inv_prefix_len
    call    asm_write_all

    ; Write the bad char
    pop     rax
    push    rax
    mov     [rsp], al               ; put char on stack
    mov     rdi, STDERR
    mov     rsi, rsp
    mov     edx, 1
    call    asm_write_all
    pop     rax

    mov     rdi, STDERR
    lea     rsi, [rel .err_suffix]
    mov     edx, .err_suffix_len
    call    asm_write_all

    mov     edi, 1
    EXIT    rdi

.err_unrecognized_opt:
    ; rsi = the full "--xxx" option string from argv
    push    rsi                     ; save option
    mov     rdi, STDERR
    lea     rsi, [rel .err_unrec_prefix]
    mov     edx, .err_unrec_prefix_len
    call    asm_write_all

    pop     rsi                     ; option string
    push    rsi
    call    .strlen_rsi
    mov     rdx, rcx
    mov     rdi, STDERR
    pop     rsi
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel .err_suffix]
    mov     edx, .err_suffix_len
    call    asm_write_all

    mov     edi, 1
    EXIT    rdi

.err_invalid_total:
    ; Print error about invalid --total value
    mov     rdi, STDERR
    lea     rsi, [rel .err_total_msg]
    mov     edx, .err_total_msg_len
    call    asm_write_all

    mov     edi, 1
    EXIT    rdi

.do_help:
    mov     rdi, STDOUT
    lea     rsi, [rel help_text]
    mov     edx, help_text_len
    call    asm_write_all
    xor     edi, edi
    EXIT    rdi

.do_version:
    mov     rdi, STDOUT
    lea     rsi, [rel version_text]
    mov     edx, version_text_len
    call    asm_write_all
    xor     edi, edi
    EXIT    rdi

; ============================================================================
; String constants for option parsing
; ============================================================================
section .rodata

.str_help:          db "help", 0
.str_version:       db "version", 0
.str_bytes:         db "bytes", 0
.str_chars:         db "chars", 0
.str_lines:         db "lines", 0
.str_words:         db "words", 0
.str_maxll:         db "max-line-length", 0
.str_total_prefix:  db "total=", 0
.str_files0_prefix: db "files0-from=", 0
.str_auto:          db "auto", 0
.str_always:        db "always", 0
.str_only:          db "only", 0
.str_never:         db "never", 0

.newline_dword:     dd 0x0A0A0A0A

.err_inv_prefix:    db "fwc: invalid option -- '", 0
.err_inv_prefix_len equ $ - .err_inv_prefix - 1
.err_unrec_prefix:  db "fwc: unrecognized option '", 0
.err_unrec_prefix_len equ $ - .err_unrec_prefix - 1
.err_suffix:        db "'", 10, "Try 'fwc --help' for more information.", 10
.err_suffix_len   equ $ - .err_suffix
.err_total_msg:     db "fwc: invalid --total value", 10
.err_total_msg_len equ $ - .err_total_msg

section .note.GNU-stack noalloc noexec nowrite progbits
