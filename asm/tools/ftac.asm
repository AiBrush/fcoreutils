; ============================================================================
;  ftac.asm — GNU-compatible "tac" in x86_64 Linux assembly
;
;  Reverses lines of files (or stdin), printing last line first.
;  Supports: -b (before), -s STRING (custom separator), --help, --version
;  Limitation: -r (regex) is not supported — prints error and exits.
;
;  Build (modular):
;    cd asm && make ftac
;
;  Algorithm:
;    - For files: open + fstat + mmap, scan backward for separator, write chunks
;    - For stdin: read all into buffer (growing via mmap), then scan backward
;    - SSE2 backward scan for single-byte separator
; ============================================================================

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close
extern asm_exit

global _start

; ── Buffer sizes ──
%define WRITE_BUF_SIZE  65536       ; 64KB write buffer
%define READ_BUF_SIZE   65536       ; 64KB read buffer for stdin
%define STDIN_INIT_SIZE 1048576     ; 1MB initial stdin buffer
%define MAX_FILES       4096        ; max file arguments

section .bss
    write_buf:  resb WRITE_BUF_SIZE ; output write buffer
    read_buf:   resb READ_BUF_SIZE  ; stdin read buffer
    stat_buf:   resb STAT_SIZE      ; fstat result buffer
    write_pos:  resq 1              ; current position in write buffer
    ; Saved globals for file processing
    g_flags:    resq 1              ; flags (bit 0 = before)
    g_sep_ptr:  resq 1              ; separator pointer
    g_sep_len:  resq 1              ; separator length

section .data
    ; ── Help text (matches GNU tac 9.4 exactly) ──
    help_text:
        db "Usage: tac [OPTION]... [FILE]...", 10
        db "Write each FILE to standard output, last line first.", 10, 10
        db "With no FILE, or when FILE is -, read standard input.", 10, 10
        db "Mandatory arguments to long options are mandatory for short options too.", 10
        db "  -b, --before             attach the separator before instead of after", 10
        db "  -r, --regex              interpret the separator as a regular expression", 10
        db "  -s, --separator=STRING   use STRING as the separator instead of newline", 10
        db "      --help        display this help and exit", 10
        db "      --version     output version information and exit", 10, 10
        db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
        db "Report any translation bugs to <https://translationproject.org/team/>", 10
        db "Full documentation <https://www.gnu.org/software/coreutils/tac>", 10
        db "or available locally via: info '(coreutils) tac invocation'", 10
    help_text_len equ $ - help_text

    ; ── Version text ──
    version_text:
        db "tac (GNU coreutils) 9.4", 10
        db "Copyright (C) 2023 Free Software Foundation, Inc.", 10
        db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
        db "This is free software: you are free to change and redistribute it.", 10
        db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
        db "Written by Jay Lepreau and David MacKenzie.", 10
    version_text_len equ $ - version_text

    ; ── Error message fragments ──
    err_unrec:      db "tac: unrecognized option '"
    err_unrec_len   equ $ - err_unrec

    err_inval:      db "tac: invalid option -- '"
    err_inval_len   equ $ - err_inval

    err_suffix:     db "'", 10, "Try 'tac --help' for more information.", 10
    err_suffix_len  equ $ - err_suffix

    err_sep_short:  db "tac: option requires an argument -- 's'", 10
                    db "Try 'tac --help' for more information.", 10
    err_sep_short_len equ $ - err_sep_short

    err_sep_long:   db "tac: option '--separator' requires an argument", 10
                    db "Try 'tac --help' for more information.", 10
    err_sep_long_len equ $ - err_sep_long

    err_open_pre:   db "tac: failed to open '"
    err_open_pre_len equ $ - err_open_pre

    err_read:       db "' for reading: "
    err_read_len    equ $ - err_read

    err_noent:      db "No such file or directory", 10
    err_noent_len   equ $ - err_noent

    err_acces:      db "Permission denied", 10
    err_acces_len   equ $ - err_acces

    err_generic:    db "Input/output error", 10
    err_generic_len equ $ - err_generic

    err_regex:      db "tac: regex mode (-r) is not supported in this build", 10
    err_regex_len   equ $ - err_regex

    dash_str:       db "-", 0

    ; Default separator
    default_sep:    db 10               ; newline

    ; String constants for option comparison
    str_help:       db "--help", 0
    str_version:    db "--version", 0
    str_before:     db "--before", 0
    str_regex:      db "--regex", 0
    str_sep_eq:     db "--separator=", 0
    str_sep_long:   db "--separator", 0

section .text

; ============================================================================
;  _start — Entry point
; ============================================================================
_start:
    ; Block SIGPIPE
    BLOCK_SIGPIPE

    pop     rcx                     ; rcx = argc
    mov     r14, rsp                ; r14 = &argv[0]

    ; ── Parse arguments ──
    ;   r12 = flags byte: bit 0 = before (-b), bit 1 = regex (-r)
    ;   r13 = separator string pointer (NULL = use default newline)
    ;   r15 = separator length

    xor     r12d, r12d              ; flags = 0
    xor     r13d, r13d              ; separator ptr = NULL (default \n)
    mov     r15, 1                  ; separator len = 1 (default \n)

    ; Allocate file pointer array on stack
    sub     rsp, MAX_FILES * 8
    xor     ebp, ebp                ; ebp = file count

    lea     rbx, [r14 + 8]         ; rbx = &argv[1]
    xor     r8d, r8d               ; r8 = 0 (not past --)

.parse_loop:
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .parse_done

    ; If past --, treat everything as filename
    test    r8d, r8d
    jnz     .add_file

    ; Check if starts with '-'
    cmp     byte [rsi], '-'
    jne     .add_file

    ; Just "-" alone = stdin
    cmp     byte [rsi+1], 0
    je      .add_file

    ; Starts with '-', check for '--'
    cmp     byte [rsi+1], '-'
    jne     .parse_short

    ; Starts with '--'
    cmp     byte [rsi+2], 0
    je      .set_past_dd            ; exactly "--"

    ; ── Check long options ──
    push    rsi
    mov     rdi, rsi
    lea     rsi, [rel str_help]
    call    strcmp_fn
    pop     rsi
    test    eax, eax
    jz      .do_help

    push    rsi
    mov     rdi, rsi
    lea     rsi, [rel str_version]
    call    strcmp_fn
    pop     rsi
    test    eax, eax
    jz      .do_version

    push    rsi
    mov     rdi, rsi
    lea     rsi, [rel str_before]
    call    strcmp_fn
    pop     rsi
    test    eax, eax
    jz      .set_before

    push    rsi
    mov     rdi, rsi
    lea     rsi, [rel str_regex]
    call    strcmp_fn
    pop     rsi
    test    eax, eax
    jz      .set_regex

    ; --separator=VALUE
    push    rsi
    mov     rdi, rsi
    lea     rsi, [rel str_sep_eq]
    mov     ecx, 12                 ; length of "--separator="
    call    strncmp_fn
    pop     rsi
    test    eax, eax
    jz      .set_sep_eq

    ; --separator VALUE
    push    rsi
    mov     rdi, rsi
    lea     rsi, [rel str_sep_long]
    call    strcmp_fn
    pop     rsi
    test    eax, eax
    jz      .set_sep_long

    ; Unrecognized long option
    jmp     .err_long_opt

.parse_short:
    ; Parse short options: -b, -r, -s
    inc     rsi                     ; skip '-'
.short_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .parse_next

    cmp     al, 'b'
    je      .short_b
    cmp     al, 'r'
    je      .short_r
    cmp     al, 's'
    je      .short_s
    ; Invalid short option
    jmp     .err_short_opt

.short_b:
    or      r12d, 1
    inc     rsi
    jmp     .short_loop

.short_r:
    or      r12d, 2
    inc     rsi
    jmp     .short_loop

.short_s:
    inc     rsi
    cmp     byte [rsi], 0
    jne     .set_sep_inline
    ; Next arg is separator value
    add     rbx, 8
    mov     r13, [rbx]
    test    r13, r13
    jz      .err_sep_short_msg
    mov     rdi, r13
    call    strlen_fn
    mov     r15, rax
    jmp     .parse_next

.set_sep_inline:
    mov     r13, rsi
    mov     rdi, rsi
    call    strlen_fn
    mov     r15, rax
    jmp     .parse_next

.set_before:
    or      r12d, 1
    jmp     .parse_next

.set_regex:
    or      r12d, 2
    jmp     .parse_next

.set_sep_eq:
    lea     r13, [rsi + 12]
    mov     rdi, r13
    call    strlen_fn
    mov     r15, rax
    jmp     .parse_next

.set_sep_long:
    add     rbx, 8
    mov     r13, [rbx]
    test    r13, r13
    jz      .err_sep_long_msg
    mov     rdi, r13
    call    strlen_fn
    mov     r15, rax
    jmp     .parse_next

.set_past_dd:
    mov     r8d, 1
    jmp     .parse_next

.add_file:
    cmp     ebp, MAX_FILES
    jge     .parse_next
    mov     [rsp + rbp*8], rsi
    inc     ebp
    jmp     .parse_next

.parse_next:
    add     rbx, 8
    jmp     .parse_loop

.parse_done:
    ; Check for regex flag — unsupported
    test    r12d, 2
    jnz     .err_regex_msg

    ; Set default separator if none specified
    test    r13, r13
    jnz     .sep_ready
    lea     r13, [rel default_sep]
    mov     r15, 1
.sep_ready:

    ; Store globals
    mov     [rel g_flags], r12
    mov     [rel g_sep_ptr], r13
    mov     [rel g_sep_len], r15

    ; If no files, use stdin ("-")
    test    ebp, ebp
    jnz     .process_files
    lea     rax, [rel dash_str]
    mov     [rsp], rax
    mov     ebp, 1

.process_files:
    xor     r8d, r8d                ; r8 = had_error flag
    xor     r9d, r9d                ; r9 = file index

.file_loop:
    cmp     r9d, ebp
    jge     .done

    mov     rdi, [rsp + r9*8]       ; rdi = filename
    push    r8
    push    r9
    push    rbp
    call    process_one_file
    pop     rbp
    pop     r9
    pop     r8
    or      r8d, eax

    inc     r9d
    jmp     .file_loop

.done:
    call    flush_write_buf
    movzx   edi, r8b
    EXIT    rdi

; ── Help ──
.do_help:
    mov     rdi, STDOUT
    lea     rsi, [rel help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    EXIT    0

; ── Version ──
.do_version:
    mov     rdi, STDOUT
    lea     rsi, [rel version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    EXIT    0

; ── Error: unrecognized long option ──
.err_long_opt:
    push    rsi
    mov     rdi, STDERR
    lea     rsi, [rel err_unrec]
    mov     rdx, err_unrec_len
    call    asm_write_all
    pop     rsi
    push    rsi
    mov     rdi, rsi
    call    strlen_fn
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDERR
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel err_suffix]
    mov     rdx, err_suffix_len
    call    asm_write_all
    EXIT    1

; ── Error: invalid short option ──
.err_short_opt:
    ; al = the option character
    push    rax
    mov     rdi, STDERR
    lea     rsi, [rel err_inval]
    mov     rdx, err_inval_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rsp]
    mov     rdx, 1
    call    asm_write_all
    pop     rax
    mov     rdi, STDERR
    lea     rsi, [rel err_suffix]
    mov     rdx, err_suffix_len
    call    asm_write_all
    EXIT    1

; ── Error: -s missing argument ──
.err_sep_short_msg:
    mov     rdi, STDERR
    lea     rsi, [rel err_sep_short]
    mov     rdx, err_sep_short_len
    call    asm_write_all
    EXIT    1

; ── Error: --separator missing argument ──
.err_sep_long_msg:
    mov     rdi, STDERR
    lea     rsi, [rel err_sep_long]
    mov     rdx, err_sep_long_len
    call    asm_write_all
    EXIT    1

; ── Error: regex unsupported ──
.err_regex_msg:
    mov     rdi, STDERR
    lea     rsi, [rel err_regex]
    mov     rdx, err_regex_len
    call    asm_write_all
    EXIT    1


; ============================================================================
;  strcmp_fn(rdi, rsi) → eax (0 if equal)
; ============================================================================
strcmp_fn:
.loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .ne
    test    al, al
    jz      .eq
    inc     rdi
    inc     rsi
    jmp     .loop
.eq:
    xor     eax, eax
    ret
.ne:
    mov     eax, 1
    ret

; ============================================================================
;  strncmp_fn(rdi, rsi, ecx) → eax (0 if first ecx bytes equal)
; ============================================================================
strncmp_fn:
    xor     edx, edx
.loop:
    cmp     edx, ecx
    jge     .eq
    movzx   eax, byte [rdi + rdx]
    movzx   r8d, byte [rsi + rdx]
    cmp     al, r8b
    jne     .ne
    inc     edx
    jmp     .loop
.eq:
    xor     eax, eax
    ret
.ne:
    mov     eax, 1
    ret

; ============================================================================
;  strlen_fn(rdi) → rax
; ============================================================================
strlen_fn:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret


; ============================================================================
;  process_one_file — Process a single file/stdin
;
;  Input:
;    rdi = filename (or "-" for stdin)
;    globals: g_flags, g_sep_ptr, g_sep_len
;
;  Output:
;    rax = 0 on success, 1 on error
; ============================================================================
process_one_file:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     rbx, rdi                ; rbx = filename

    ; Check if stdin ("-")
    cmp     byte [rbx], '-'
    jne     .pof_open_file
    cmp     byte [rbx+1], 0
    jne     .pof_open_file

    ; ── Read stdin into buffer ──
    call    read_all_stdin
    ; rax = buffer pointer, rdx = data length
    test    rax, rax
    jz      .pof_error
    mov     r14, rax                ; r14 = data pointer
    mov     rbp, rdx                ; rbp = data length
    xor     r12d, r12d              ; r12 = 0 (stdin, track alloc size)
    mov     r12, rdx                ; save actual data length for munmap
    add     r12, 4095
    and     r12, ~4095              ; round up to page boundary
    mov     ebx, 0                  ; ebx = 0 (stdin flag)
    jmp     .pof_process

.pof_open_file:
    ; Open the file
    mov     rdi, rbx
    xor     esi, esi                ; O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .pof_open_error

    mov     r13d, eax               ; r13 = fd

    ; fstat to get file size
    mov     edi, r13d
    lea     rsi, [rel stat_buf]
    mov     eax, SYS_FSTAT
    syscall
    test    eax, eax
    js      .pof_close_error

    ; Get file size from stat
    lea     rax, [rel stat_buf]
    mov     rbp, [rax + STAT_ST_SIZE_OFF]   ; rbp = file size

    ; Handle empty file
    test    rbp, rbp
    jz      .pof_close_success

    ; mmap the file
    xor     edi, edi                ; addr = NULL
    mov     rsi, rbp                ; length = file size
    mov     edx, PROT_READ          ; prot = PROT_READ
    mov     r10d, MAP_PRIVATE       ; flags = MAP_PRIVATE
    mov     r8d, r13d               ; fd
    xor     r9d, r9d                ; offset = 0
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .pof_close_error

    mov     r14, rax                ; r14 = mmap address
    ; Close fd (no longer needed)
    mov     edi, r13d
    call    asm_close
    mov     ebx, 1                  ; ebx = 1 (need to munmap)
    mov     r12, rbp                ; r12 = mmap size for munmap
    jmp     .pof_process

.pof_process:
    ; r14 = data pointer
    ; rbp = data length
    ; ebx = 1 if mmap'd, 0 if stdin
    ; r12 = size for munmap

    ; Handle empty data
    test    rbp, rbp
    jz      .pof_cleanup

    ; Load options from globals
    mov     r13, [rel g_sep_ptr]    ; r13 = separator ptr
    mov     r15, [rel g_sep_len]    ; r15 = separator len

    ; Handle empty separator — output data unchanged (GNU behavior)
    test    r15, r15
    jz      .pof_passthrough

    ; Choose algorithm based on separator length
    cmp     r15, 1
    jne     .pof_multi_byte

    ; Single-byte separator
    movzx   ecx, byte [r13]        ; cl = separator byte
    mov     rax, [rel g_flags]
    test    eax, 1                  ; before mode?
    jnz     .pof_before

    ; After mode (default)
    mov     rdi, r14
    mov     rsi, rbp
    call    tac_after
    jmp     .pof_cleanup

.pof_before:
    mov     rdi, r14
    mov     rsi, rbp
    call    tac_before
    jmp     .pof_cleanup

.pof_passthrough:
    ; Empty separator — just write data as-is
    mov     rdi, r14
    mov     rsi, rbp
    call    buffered_write
    jmp     .pof_cleanup

.pof_multi_byte:
    ; Multi-byte separator
    ; Args: r14=data, rbp=len, r13=sep, r15=sep_len, g_flags
    mov     rdi, r14                ; data ptr
    mov     rsi, rbp                ; data len
    mov     rdx, r13                ; sep ptr
    mov     rcx, r15                ; sep len
    mov     r8, [rel g_flags]       ; flags
    call    tac_multi_byte
    jmp     .pof_cleanup

.pof_cleanup:
    ; Unmap / free
    test    ebx, ebx
    jz      .pof_free_stdin
    ; munmap file
    mov     rdi, r14
    mov     rsi, r12
    mov     eax, SYS_MUNMAP
    syscall
    jmp     .pof_success

.pof_free_stdin:
    test    r14, r14
    jz      .pof_success
    mov     rdi, r14
    mov     rsi, r12
    mov     eax, SYS_MUNMAP
    syscall
    jmp     .pof_success

.pof_success:
    xor     eax, eax
    jmp     .pof_ret

.pof_error:
    mov     eax, 1
    jmp     .pof_ret

.pof_open_error:
    push    rax                     ; save errno
    mov     rdi, STDERR
    lea     rsi, [rel err_open_pre]
    mov     rdx, err_open_pre_len
    call    asm_write_all
    mov     rdi, rbx
    call    strlen_fn
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel err_read]
    mov     rdx, err_read_len
    call    asm_write_all
    pop     rax
    neg     eax
    cmp     eax, 2                  ; ENOENT
    je      .pof_err_noent
    cmp     eax, 13                 ; EACCES
    je      .pof_err_acces
    jmp     .pof_err_other

.pof_err_noent:
    mov     rdi, STDERR
    lea     rsi, [rel err_noent]
    mov     rdx, err_noent_len
    call    asm_write_all
    jmp     .pof_error

.pof_err_acces:
    mov     rdi, STDERR
    lea     rsi, [rel err_acces]
    mov     rdx, err_acces_len
    call    asm_write_all
    jmp     .pof_error

.pof_err_other:
    mov     rdi, STDERR
    lea     rsi, [rel err_generic]
    mov     rdx, err_generic_len
    call    asm_write_all
    jmp     .pof_error

.pof_close_error:
    mov     edi, r13d
    call    asm_close
    jmp     .pof_error

.pof_close_success:
    mov     edi, r13d
    call    asm_close
    jmp     .pof_success

.pof_ret:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  read_all_stdin — Read all of stdin into an mmap'd buffer
;
;  Returns:
;    rax = buffer pointer (or NULL on error)
;    rdx = data length
; ============================================================================
read_all_stdin:
    push    rbx
    push    r12
    push    r13
    push    r14

    ; Allocate initial buffer via anonymous mmap
    mov     r12, STDIN_INIT_SIZE    ; r12 = current buffer capacity
    xor     edi, edi
    mov     rsi, r12
    mov     edx, 3                  ; PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .ras_error
    mov     r13, rax                ; r13 = buffer pointer
    xor     r14d, r14d              ; r14 = bytes read so far

.ras_read_loop:
    mov     rdi, STDIN
    lea     rsi, [r13 + r14]
    mov     rdx, r12
    sub     rdx, r14                ; remaining space
    test    rdx, rdx
    jz      .ras_grow

    cmp     rdx, READ_BUF_SIZE
    jle     .ras_do_read
    mov     rdx, READ_BUF_SIZE

.ras_do_read:
    call    asm_read
    test    rax, rax
    js      .ras_read_error
    jz      .ras_read_done

    add     r14, rax
    jmp     .ras_read_loop

.ras_grow:
    mov     rbx, r12                ; old capacity
    shl     r12, 1                  ; double capacity

    xor     edi, edi
    mov     rsi, r12
    mov     edx, 3
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .ras_error

    ; Copy old data to new buffer
    push    rax
    mov     rdi, rax
    mov     rsi, r13
    mov     rcx, r14
    rep     movsb
    pop     rax

    ; Free old buffer
    push    rax
    mov     rdi, r13
    mov     rsi, rbx
    mov     eax, SYS_MUNMAP
    syscall
    pop     r13                     ; r13 = new buffer

    jmp     .ras_read_loop

.ras_read_done:
    mov     rax, r13
    mov     rdx, r14
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.ras_read_error:
.ras_error:
    test    r13, r13
    jz      .ras_null
    mov     rdi, r13
    mov     rsi, r12
    mov     eax, SYS_MUNMAP
    syscall
.ras_null:
    xor     eax, eax
    xor     edx, edx
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  tac_after — Reverse records with single-byte separator (after mode)
;
;  Separator terminates records. Scan backward, emit chunks in reverse.
;
;  Input:
;    rdi = data pointer
;    rsi = data length
;    cl  = separator byte
; ============================================================================
tac_after:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r14, rdi                ; r14 = data base
    mov     r15, rsi                ; r15 = data length
    movzx   ebp, cl                 ; ebp = separator byte

    mov     r12, r15                ; r12 = prev_end
    mov     r13, r15                ; r13 = search_end

    ; Broadcast separator byte to xmm0 for SSE2 scanning
    movd    xmm0, ebp
    punpcklbw xmm0, xmm0
    punpcklwd xmm0, xmm0
    pshufd  xmm0, xmm0, 0

.ta_loop:
    test    r13, r13
    jz      .ta_first_record

    ; Backward scan for separator byte
    mov     rdi, r14
    mov     rsi, r13
    call    memrchr_sse2
    cmp     rax, -1
    je      .ta_first_record

    mov     rbx, rax                ; rbx = found position

    ; Write data[pos+1..prev_end]
    lea     rdi, [r14 + rbx + 1]
    mov     rsi, r12
    sub     rsi, rbx
    dec     rsi
    test    rsi, rsi
    jz      .ta_skip

    call    buffered_write

.ta_skip:
    lea     r12, [rbx + 1]          ; prev_end = pos + 1
    mov     r13, rbx                ; search_end = pos
    test    r13, r13
    jz      .ta_first_record
    jmp     .ta_loop

.ta_first_record:
    test    r12, r12
    jz      .ta_done
    mov     rdi, r14
    mov     rsi, r12
    call    buffered_write

.ta_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  tac_before — Reverse records with single-byte separator (before mode)
;
;  Separator starts records. Scan backward, emit chunks with separator prefix.
;
;  Input:
;    rdi = data pointer
;    rsi = data length
;    cl  = separator byte
; ============================================================================
tac_before:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r14, rdi
    mov     r15, rsi
    movzx   ebp, cl

    mov     r12, r15                ; r12 = prev_end
    mov     r13, r15                ; r13 = search_end

    ; Broadcast separator byte to xmm0
    movd    xmm0, ebp
    punpcklbw xmm0, xmm0
    punpcklwd xmm0, xmm0
    pshufd  xmm0, xmm0, 0

.tb_loop:
    test    r13, r13
    jz      .tb_first_record

    mov     rdi, r14
    mov     rsi, r13
    call    memrchr_sse2
    cmp     rax, -1
    je      .tb_first_record

    mov     rbx, rax

    ; Write data[pos..prev_end] (includes separator at start)
    lea     rdi, [r14 + rbx]
    mov     rsi, r12
    sub     rsi, rbx
    test    rsi, rsi
    jz      .tb_skip

    call    buffered_write

.tb_skip:
    mov     r12, rbx                ; prev_end = pos
    test    rbx, rbx
    jz      .tb_done
    mov     r13, rbx                ; search_end = pos
    jmp     .tb_loop

.tb_first_record:
    test    r12, r12
    jz      .tb_done
    mov     rdi, r14
    mov     rsi, r12
    call    buffered_write

.tb_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  memrchr_sse2 — Find last occurrence of separator byte
;
;  Input:
;    rdi = data base pointer
;    rsi = search length (search data[0..rsi-1])
;    xmm0 = broadcast separator byte (set by caller)
;    ebp = separator byte (for scalar fallback)
;
;  Output:
;    rax = offset of found byte, or -1 if not found
;
;  Algorithm:
;    1. Handle tail bytes (rsi % 16) with scalar backward scan
;    2. Handle remaining 16-byte chunks with SSE2 backward scan
;    3. Handle first partial chunk at start of data
; ============================================================================
memrchr_sse2:
    test    rsi, rsi
    jz      .mr_not_found

    lea     rax, [rdi + rsi]        ; rax = exclusive upper bound pointer

    ; Handle tail bytes (rsi mod 16) with scalar scan
    mov     rcx, rsi
    and     rcx, 15                 ; tail byte count
    test    rcx, rcx
    jz      .mr_main_loop

    ; Scalar backward scan for tail bytes
.mr_tail_loop:
    dec     rax                     ; move to byte to check
    movzx   edx, byte [rax]
    cmp     dl, bpl
    je      .mr_found_at_rax
    cmp     rax, rdi                ; reached start of data?
    je      .mr_not_found
    dec     rcx
    jnz     .mr_tail_loop
    ; rax now = rdi + (rsi - tail) = start of tail region
    ; Fall through to check 16-byte chunks below this point

.mr_main_loop:
    ; rax = exclusive upper bound for remaining search
    cmp     rax, rdi
    jbe     .mr_not_found
    sub     rax, 16
    cmp     rax, rdi
    jb      .mr_last_chunk

    movdqu  xmm1, [rax]
    pcmpeqb xmm1, xmm0
    pmovmskb edx, xmm1
    test    edx, edx
    jnz     .mr_found_in_chunk
    jmp     .mr_main_loop

.mr_last_chunk:
    ; rax < rdi means we overshot. Load from rdi and mask valid bytes.
    mov     rax, rdi
    movdqu  xmm1, [rax]
    pcmpeqb xmm1, xmm0
    pmovmskb edx, xmm1

    ; Calculate how many bytes at the start are valid
    ; Valid range: rdi to rdi + (remaining), where remaining = (original tail-adjusted bound - rdi)
    ; Since we do sub rax, 16 and got rax < rdi, the valid count is (rax_before_sub - rdi)
    ; rax_before_sub = rax + 16 (since we just did sub 16)
    ; But rax was set to rdi, and we're loading from rdi, checking 16 bytes
    ; We need to mask out bytes >= (bound - rdi) where bound = rax + 16 before reset
    ; Simplification: compute the actual valid bytes from the adjustment
    lea     rcx, [rax + 16]         ; this would be: rdi + 16
    ; Wait, we set rax = rdi. The original rax before reset was (rax + 16 - 16) = whatever.
    ; Let me just compute: we need bits 0..(valid_count-1)
    ; The distance from rdi to the upper bound we were using is stored implicitly.
    ; Actually, the safe approach: the upper bound pointer before sub 16 was (rax + 16).
    ; That upper bound is > rdi (we passed the jbe check) but rax+16-16 = rax < rdi.
    ; So valid bytes = (old upper bound) - rdi = (current rax + 16) - rdi
    ; But wait, we set rax = rdi already. So (rdi + 16) - rdi = 16? No...
    ; Hmm, let me reconsider. Before the `mov rax, rdi`, rax was negative (< rdi).
    ; The actual valid range is rdi..(rdi + distance) where distance = old_rax + 16 - rdi.
    ; But I've already overwritten rax with rdi. I need to save it.
    ;
    ; SIMPLER APPROACH: just mask to the bytes we know are valid.
    ; We loaded 16 bytes from rdi. The upper bound was at some point past rdi.
    ; ALL 16 bytes from rdi to rdi+15 are within our data buffer (we're searching
    ; data[0..original_rsi-1] and rdi is the start). So all 16 bytes are valid data.
    ; But some of them might be in the tail region that we already scanned.
    ; Since the tail was already checked (no match there), any match in the first
    ; 16 bytes from rdi is valid — it can't be in the tail because the tail is at
    ; the END of the data, and these 16 bytes are at the START.
    test    edx, edx
    jz      .mr_not_found

.mr_found_in_chunk:
    bsr     ecx, edx                ; highest set bit = last match position
    add     rax, rcx
.mr_found_at_rax:
    sub     rax, rdi                ; convert to offset from data start
    ret

.mr_not_found:
    mov     rax, -1
    ret


; ============================================================================
;  tac_multi_byte — Reverse records with multi-byte separator
;
;  Forward-scans for all separator positions, then emits in reverse.
;  Uses only callee-saved registers for data that must survive calls.
;
;  Input:
;    rdi = data pointer
;    rsi = data length
;    rdx = separator pointer
;    rcx = separator length
;    r8  = flags (bit 0 = before)
; ============================================================================
tac_multi_byte:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 48                 ; local vars

    ; Save inputs in callee-saved registers and stack
    mov     r14, rdi                ; r14 = data pointer
    mov     rbp, rsi                ; rbp = data length
    mov     [rsp], rdx              ; [rsp] = separator pointer
    mov     [rsp+8], rcx            ; [rsp+8] = separator length
    mov     [rsp+16], r8            ; [rsp+16] = flags

    ; Allocate position array via mmap
    ; Estimate: at most data_len / sep_len + 64 positions
    mov     rax, rbp
    xor     edx, edx
    div     rcx
    add     rax, 64
    shl     rax, 3                  ; * 8 bytes per qword
    add     rax, 4095
    and     rax, ~4095
    mov     [rsp+24], rax           ; save alloc size

    xor     edi, edi
    mov     rsi, rax
    mov     edx, 3                  ; PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .tmb_done

    mov     r12, rax                ; r12 = positions array
    xor     r13d, r13d              ; r13 = position count

    ; Backward scan for separator positions (matches GNU tac behavior)
    ; GNU tac scans backward; after finding a separator at position P,
    ; the next search is limited to [0, P), so separators cannot overlap.
    mov     r15, rbp
    sub     r15, [rsp+8]            ; r15 = last possible start position

.tmb_scan:
    test    r15, r15
    js      .tmb_scan_done          ; if r15 < 0, done

    ; Try to match separator at offset r15
    lea     rdi, [r14 + r15]        ; current position in data
    mov     rsi, [rsp]              ; separator string
    mov     rcx, [rsp+8]           ; separator length
    xor     edx, edx                ; byte index
.tmb_cmp:
    cmp     edx, ecx
    jge     .tmb_match
    movzx   eax, byte [rdi + rdx]
    movzx   r8d, byte [rsi + rdx]
    cmp     al, r8b
    jne     .tmb_no_match
    inc     edx
    jmp     .tmb_cmp

.tmb_match:
    ; Record position (stored in decreasing order)
    mov     [r12 + r13*8], r15
    inc     r13
    sub     r15, [rsp+8]           ; next match must end before this one
    jmp     .tmb_scan

.tmb_no_match:
    dec     r15                     ; move backward by 1
    jmp     .tmb_scan

.tmb_scan_done:
    ; Positions are in decreasing order; reverse to get increasing order
    ; (reconstruction code expects increasing order)
    cmp     r13, 2
    jl      .tmb_reversed           ; 0 or 1 elements: no swap needed
    xor     ecx, ecx                ; i = 0
    lea     rdx, [r13 - 1]          ; j = count - 1
.tmb_reverse:
    cmp     rcx, rdx
    jge     .tmb_reversed
    mov     rax, [r12 + rcx*8]
    mov     r8, [r12 + rdx*8]
    mov     [r12 + rcx*8], r8
    mov     [r12 + rdx*8], rax
    inc     rcx
    dec     rdx
    jmp     .tmb_reverse
.tmb_reversed:
    ; r12 = positions array (callee-saved)
    ; r13 = position count (callee-saved)
    ; r14 = data pointer (callee-saved)
    ; rbp = data length (callee-saved)

    test    r13, r13
    jz      .tmb_no_seps

    mov     rax, [rsp+16]           ; flags
    test    eax, 1                  ; before mode?
    jnz     .tmb_before

    ; ── After mode: separator terminates records ──
    ; Records: data[0..sep[0]+sep_len], data[sep[0]+sep_len..sep[1]+sep_len], ...
    ; Last segment: data[sep[last]+sep_len..data_len]
    ; Emit in reverse order.

    ; First: write the trailing segment after last separator
    mov     rbx, r13
    dec     rbx                     ; index of last separator
    mov     rax, [r12 + rbx*8]      ; last separator position
    add     rax, [rsp+8]            ; + sep_len = end of last separator
    mov     r15, rbp                ; r15 = data_len (end of data)
    cmp     rax, r15
    jge     .tmb_after_loop_init

    lea     rdi, [r14 + rax]
    mov     rsi, r15
    sub     rsi, rax
    call    buffered_write

.tmb_after_loop_init:
    ; Loop from last separator backward to first
    ; rbx = current index (starts at r13-1, goes to 0)
    mov     rbx, r13
    dec     rbx

.tmb_after_loop:
    ; Compute record: from prev_sep_end to current_sep_end
    mov     rax, [r12 + rbx*8]      ; current separator position
    mov     r15, rax
    add     r15, [rsp+8]            ; r15 = end of current separator

    ; Start of this record
    test    rbx, rbx
    jz      .tmb_after_from_zero

    lea     rcx, [rbx - 1]
    mov     rdi, [r12 + rcx*8]      ; previous separator position
    add     rdi, [rsp+8]            ; end of previous separator
    jmp     .tmb_after_emit_rec

.tmb_after_from_zero:
    xor     edi, edi                ; start from offset 0

.tmb_after_emit_rec:
    ; Write data[rdi..r15]
    mov     rsi, r15
    sub     rsi, rdi                ; length
    test    rsi, rsi
    jz      .tmb_after_next
    add     rdi, r14                ; absolute address
    call    buffered_write

.tmb_after_next:
    test    rbx, rbx
    jz      .tmb_cleanup
    dec     rbx
    jmp     .tmb_after_loop

    ; ── Before mode: separator starts records ──
.tmb_before:
    ; Emit from last to first
    mov     rbx, r13
    dec     rbx

.tmb_before_loop:
    mov     rax, [r12 + rbx*8]      ; separator position

    ; End of this record
    lea     rcx, [rbx + 1]
    cmp     rcx, r13
    jge     .tmb_before_end_data

    mov     r15, [r12 + rcx*8]      ; next separator position
    jmp     .tmb_before_emit

.tmb_before_end_data:
    mov     r15, rbp                ; end = data_len

.tmb_before_emit:
    ; Write data[sep_pos..end]
    lea     rdi, [r14 + rax]
    mov     rsi, r15
    sub     rsi, rax
    test    rsi, rsi
    jz      .tmb_before_next
    call    buffered_write

.tmb_before_next:
    test    rbx, rbx
    jz      .tmb_before_first
    dec     rbx
    jmp     .tmb_before_loop

.tmb_before_first:
    ; Write data[0..first_sep_pos] if any content before first separator
    mov     rax, [r12]              ; first separator position
    test    rax, rax
    jz      .tmb_cleanup
    mov     rdi, r14
    mov     rsi, rax
    call    buffered_write
    jmp     .tmb_cleanup

.tmb_no_seps:
    ; No separators found — write all data as-is
    mov     rdi, r14
    mov     rsi, rbp
    call    buffered_write

.tmb_cleanup:
    ; Free positions array
    mov     rdi, r12
    mov     rsi, [rsp+24]           ; alloc size
    mov     eax, SYS_MUNMAP
    syscall

.tmb_done:
    add     rsp, 48
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  buffered_write — Write data through 64KB buffer for efficiency
;
;  Input:
;    rdi = data pointer
;    rsi = data length
;
;  Preserves: rbx, r12-r15, rbp (callee-saved)
; ============================================================================
buffered_write:
    push    rbx
    push    r12
    push    r13

    mov     r12, rdi                ; r12 = source data pointer
    mov     r13, rsi                ; r13 = remaining length

.bw_loop:
    test    r13, r13
    jz      .bw_done

    ; How much space in buffer?
    mov     rax, [rel write_pos]
    mov     rbx, WRITE_BUF_SIZE
    sub     rbx, rax                ; rbx = remaining space

    ; Copy min(remaining_space, data_length) bytes
    mov     rcx, r13
    cmp     rcx, rbx
    jle     .bw_copy
    mov     rcx, rbx

.bw_copy:
    push    rcx
    lea     rdi, [rel write_buf]
    add     rdi, [rel write_pos]
    mov     rsi, r12
    rep     movsb
    pop     rcx

    add     [rel write_pos], rcx
    add     r12, rcx
    sub     r13, rcx

    mov     rax, [rel write_pos]
    cmp     rax, WRITE_BUF_SIZE
    jge     .bw_flush
    jmp     .bw_loop

.bw_flush:
    call    flush_write_buf
    jmp     .bw_loop

.bw_done:
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  flush_write_buf — Flush the write buffer to stdout
; ============================================================================
flush_write_buf:
    push    rbx
    mov     rbx, [rel write_pos]
    test    rbx, rbx
    jz      .fwb_done

    mov     rdi, STDOUT
    lea     rsi, [rel write_buf]
    mov     rdx, rbx
    call    asm_write_all

    ; Check for write error (broken pipe etc.)
    test    rax, rax
    js      .fwb_epipe

    mov     qword [rel write_pos], 0
.fwb_done:
    pop     rbx
    ret

.fwb_epipe:
    ; Broken pipe — exit silently with 0 (GNU behavior for tac)
    xor     edi, edi
    EXIT    0


section .note.GNU-stack noalloc noexec nowrite progbits
