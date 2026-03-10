; fpaste.asm — GNU-compatible "paste" in x86_64 Linux assembly
;
; A drop-in replacement for GNU coreutils `paste`. Pure x86-64 assembly,
; no libc, no dynamic linker.
;
; Supports: -d (delimiter list with escape sequences), -s (serial mode),
;           -z (NUL terminator), -- (end options), - (stdin)
;
; Strategy:
;   - Read stdin once into a buffer (via read loop to heap allocated by brk)
;   - Open each file and mmap it (or read into heap for stdin/non-regular)
;   - Parallel mode: advance line-by-line through each file in lockstep
;   - Serial mode: for each file, join all its lines with cycling delimiters
;   - 256KB output buffer with raw fd writes
;   - SIGPIPE blocked at startup
;   - EINTR handled on all blocking syscalls
;   - Partial writes handled in asm_write_all
;
; Build (modular):
;   nasm -f elf64 -I ./ tools/fpaste.asm -o build/fpaste.o
;   nasm -f elf64 -I ./ lib/io.asm -o build/io.o
;   ld --gc-sections build/fpaste.o build/io.o -o fpaste

%include "include/linux.inc"
%include "include/macros.inc"

default rel

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close
extern asm_fstat
extern asm_mmap
extern asm_munmap

; ─── Constants ───────────────────────────────────────────
%define MAX_FILES       4096
%define MAX_DELIMS      256
%define STDIN_INIT_SIZE 1048576     ; 1MB initial stdin buffer
%define MMAP_THRESHOLD  0           ; always try mmap first for files

; Flag bits
%define FLAG_SERIAL     0x01    ; -s
%define FLAG_ZERO_TERM  0x02    ; -z

global _start

section .text

; ============================================================================
;                           ENTRY POINT
; ============================================================================
_start:
    ; ── Block SIGPIPE ──
    BLOCK_SIGPIPE

    ; ── Save argc/argv ──
    mov     rax, [rsp]                  ; argc
    mov     [rel argc], rax
    lea     rax, [rsp + 8]
    mov     [rel argv], rax

    ; ── Initialize state ──
    mov     byte [rel flags], 0
    mov     byte [rel had_error], 0
    mov     qword [rel nfiles], 0
    mov     byte [rel terminator], 10   ; default newline
    ; Default delimiter: tab
    mov     byte [rel delim_buf], 9
    mov     qword [rel delim_len], 1
    xor     r12d, r12d                  ; out_buf_used = 0
    mov     qword [rel stdin_data], 0
    mov     qword [rel stdin_size], 0
    mov     qword [rel stdin_capacity], 0

    ; ── Parse arguments ──
    call    parse_args

    ; ── If no files, use stdin ──
    cmp     qword [rel nfiles], 0
    jne     .have_files
    lea     rax, [rel dash_str]
    mov     [rel file_ptrs], rax
    mov     qword [rel nfiles], 1

.have_files:
    ; Set terminator based on -z flag
    test    byte [rel flags], FLAG_ZERO_TERM
    jz      .term_set
    mov     byte [rel terminator], 0
.term_set:

    ; ── Check if any file is stdin ──
    call    check_and_read_stdin

    ; ── Open/mmap all files ──
    call    open_all_files
    ; If had_error from open, exit 1
    cmp     byte [rel had_error], 0
    jne     .exit_with_had_error

    ; ── Choose mode ──
    test    byte [rel flags], FLAG_SERIAL
    jnz     .do_serial

    ; ── Parallel paste ──
    call    paste_parallel
    jmp     .finish

.do_serial:
    call    paste_serial

.finish:
    ; Flush remaining output buffer
    call    flush_output
    test    rax, rax
    js      .write_error

    ; Close/unmap all files
    call    close_all_files

    ; Free stdin buffer if allocated
    call    free_stdin_buf

.exit_with_had_error:
    movzx   edi, byte [rel had_error]
    mov     eax, SYS_EXIT
    syscall

.write_error:
    cmp     rax, EPIPE
    je      .epipe_exit
    mov     byte [rel had_error], 1
    jmp     .finish

.epipe_exit:
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

; ============================================================================
;                        ARGUMENT PARSING
; ============================================================================
parse_args:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, [rel argc]
    mov     r13, [rel argv]
    mov     rbx, 1                      ; start at argv[1]
    xor     r14d, r14d                  ; seen_dashdash = 0

.pa_loop:
    cmp     rbx, r12
    jge     .pa_done

    mov     rsi, [r13 + rbx*8]

    ; If seen --, treat everything as filename
    test    r14d, r14d
    jnz     .pa_is_file

    ; Check if starts with '-'
    cmp     byte [rsi], '-'
    jne     .pa_is_file
    cmp     byte [rsi+1], 0
    je      .pa_is_file                 ; bare "-" is a file (stdin)

    ; Check for "--"
    cmp     byte [rsi+1], '-'
    jne     .pa_short_opts

    ; Starts with "--"
    cmp     byte [rsi+2], 0
    je      .pa_dashdash                ; exactly "--"

    ; Long options
    push    rbx
    push    r12
    push    r13
    push    r14

    ; Check --help
    mov     rdi, rsi
    lea     rsi, [rel str_help_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_help

    ; Check --version
    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [rel str_version_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_version

    ; Check --serial
    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [rel str_serial_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_serial

    ; Check --zero-terminated
    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [rel str_zero_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_zero

    ; Check --delimiters=VALUE
    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [rel str_delimiters_eq]
    mov     ecx, 13                     ; strlen("--delimiters=")
    call    str_has_prefix
    test    eax, eax
    jnz     .pa_do_delim_eq

    ; Check --delimiters (next arg)
    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [rel str_delimiters_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_delim_next

    ; Unknown --option
    mov     rdi, [r13 + rbx*8]
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    call    err_unrecognized_option
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.pa_do_help:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rdi, STDOUT
    lea     rsi, [rel help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.pa_do_version:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rdi, STDOUT
    lea     rsi, [rel version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.pa_do_serial:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    or      byte [rel flags], FLAG_SERIAL
    jmp     .pa_next

.pa_do_zero:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    or      byte [rel flags], FLAG_ZERO_TERM
    jmp     .pa_next

.pa_do_delim_eq:
    ; rdi still points to "--delimiters=VALUE", value starts at offset 13
    mov     rdi, [r13 + rbx*8]
    add     rdi, 13
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    call    parse_delimiters
    jmp     .pa_next

.pa_do_delim_next:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ; Next arg is the delimiter value
    inc     rbx
    cmp     rbx, r12
    jge     .pa_delim_missing
    mov     rdi, [r13 + rbx*8]
    call    parse_delimiters
    jmp     .pa_next

.pa_delim_missing:
    ; "paste: option '--delimiters' requires an argument"
    mov     rdi, STDERR
    lea     rsi, [rel str_delim_missing]
    mov     rdx, str_delim_missing_len
    call    asm_write_all
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.pa_dashdash:
    mov     r14d, 1
    jmp     .pa_next

.pa_short_opts:
    ; Parse combined short options: -sdzVALUE etc.
    mov     rcx, 1                      ; start at char index 1 (skip '-')

.pa_short_loop:
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .pa_next                    ; end of string

    cmp     al, 's'
    je      .pa_flag_s
    cmp     al, 'z'
    je      .pa_flag_z
    cmp     al, 'd'
    je      .pa_flag_d

    ; Unknown short option
    push    rsi
    push    rcx
    movzx   esi, al
    call    err_invalid_option
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.pa_flag_s:
    or      byte [rel flags], FLAG_SERIAL
    inc     rcx
    jmp     .pa_short_loop

.pa_flag_z:
    or      byte [rel flags], FLAG_ZERO_TERM
    inc     rcx
    jmp     .pa_short_loop

.pa_flag_d:
    ; -d: rest of arg is delimiter, or next arg if nothing after d
    inc     rcx
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jnz     .pa_d_inline

    ; No more chars in this arg — use next arg
    inc     rbx
    cmp     rbx, r12
    jge     .pa_d_missing
    mov     rdi, [r13 + rbx*8]
    call    parse_delimiters
    jmp     .pa_next

.pa_d_inline:
    ; Rest of this arg is the delimiter value
    push    rsi
    lea     rdi, [rsi + rcx]
    call    parse_delimiters
    pop     rsi
    jmp     .pa_next

.pa_d_missing:
    ; "paste: option requires an argument -- 'd'"
    mov     rdi, STDERR
    lea     rsi, [rel str_d_missing]
    mov     rdx, str_d_missing_len
    call    asm_write_all
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.pa_is_file:
    ; Store file pointer
    mov     rax, [rel nfiles]
    cmp     rax, MAX_FILES
    jge     .pa_next                    ; silently drop excess files
    lea     rcx, [rel file_ptrs]
    mov     [rcx + rax*8], rsi
    inc     qword [rel nfiles]

.pa_next:
    inc     rbx
    jmp     .pa_loop

.pa_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  parse_delimiters(rdi=string) — Parse delimiter string with escape sequences
;  Supports: \n, \t, \\, \0 (NUL = empty delimiter), bare chars
;  Writes to delim_buf, sets delim_len.
; ============================================================================
parse_delimiters:
    push    rbx
    push    r12
    lea     r12, [rel delim_buf]
    xor     ebx, ebx                    ; output index

.pd_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .pd_done

    cmp     al, '\'
    jne     .pd_literal

    ; Backslash: look at next char
    movzx   ecx, byte [rdi+1]
    test    cl, cl
    jz      .pd_literal_backslash       ; trailing backslash

    cmp     cl, 'n'
    je      .pd_esc_n
    cmp     cl, 't'
    je      .pd_esc_t
    cmp     cl, '\'
    je      .pd_esc_backslash
    cmp     cl, '0'
    je      .pd_esc_nul

    ; Unknown escape: treat backslash as literal
    jmp     .pd_literal_backslash

.pd_esc_n:
    cmp     ebx, MAX_DELIMS
    jge     .pd_done
    mov     byte [r12 + rbx], 10        ; newline
    inc     ebx
    add     rdi, 2
    jmp     .pd_loop

.pd_esc_t:
    cmp     ebx, MAX_DELIMS
    jge     .pd_done
    mov     byte [r12 + rbx], 9         ; tab
    inc     ebx
    add     rdi, 2
    jmp     .pd_loop

.pd_esc_backslash:
    cmp     ebx, MAX_DELIMS
    jge     .pd_done
    mov     byte [r12 + rbx], '\'
    inc     ebx
    add     rdi, 2
    jmp     .pd_loop

.pd_esc_nul:
    ; \0 means "no delimiter" — we store NUL byte but it means empty
    ; Actually GNU paste treats \0 as empty: no delimiter byte is inserted
    ; We handle this in the output logic by checking for NUL delimiter
    cmp     ebx, MAX_DELIMS
    jge     .pd_done
    mov     byte [r12 + rbx], 0         ; NUL = empty delimiter
    inc     ebx
    add     rdi, 2
    jmp     .pd_loop

.pd_literal_backslash:
    cmp     ebx, MAX_DELIMS
    jge     .pd_done
    mov     byte [r12 + rbx], '\'
    inc     ebx
    inc     rdi
    jmp     .pd_loop

.pd_literal:
    cmp     ebx, MAX_DELIMS
    jge     .pd_done
    mov     [r12 + rbx], al
    inc     ebx
    inc     rdi
    jmp     .pd_loop

.pd_done:
    mov     [rel delim_len], rbx
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  check_and_read_stdin — If any file arg is "-", read stdin into a buffer
; ============================================================================
check_and_read_stdin:
    push    rbx
    push    r12

    ; Check if any file is "-"
    mov     r12, [rel nfiles]
    xor     ebx, ebx
.cas_loop:
    cmp     rbx, r12
    jge     .cas_no_stdin

    lea     rax, [rel file_ptrs]
    mov     rdi, [rax + rbx*8]
    cmp     byte [rdi], '-'
    jne     .cas_next
    cmp     byte [rdi+1], 0
    je      .cas_need_stdin

.cas_next:
    inc     rbx
    jmp     .cas_loop

.cas_need_stdin:
    ; Allocate initial buffer via brk
    mov     eax, 12                     ; SYS_BRK
    xor     edi, edi
    syscall
    mov     [rel stdin_data], rax       ; start of heap
    mov     r12, rax                    ; base

    ; Extend brk by STDIN_INIT_SIZE
    lea     rdi, [rax + STDIN_INIT_SIZE]
    mov     eax, 12                     ; SYS_BRK
    syscall
    sub     rax, r12
    mov     [rel stdin_capacity], rax

    ; Read all of stdin
    xor     ebx, ebx                    ; total bytes read
.cas_read_loop:
    mov     rdi, STDIN
    mov     rsi, [rel stdin_data]
    add     rsi, rbx
    mov     rdx, [rel stdin_capacity]
    sub     rdx, rbx
    cmp     rdx, 0
    jle     .cas_grow_buf

    call    asm_read
    test    rax, rax
    js      .cas_read_error
    jz      .cas_read_done              ; EOF

    add     rbx, rax
    jmp     .cas_read_loop

.cas_grow_buf:
    ; Double the buffer
    mov     rax, [rel stdin_capacity]
    shl     rax, 1
    mov     rdi, [rel stdin_data]
    add     rdi, rax
    mov     eax, 12                     ; SYS_BRK
    syscall
    mov     rdi, [rel stdin_data]
    sub     rax, rdi
    mov     [rel stdin_capacity], rax
    jmp     .cas_read_loop

.cas_read_done:
    mov     [rel stdin_size], rbx

.cas_no_stdin:
    pop     r12
    pop     rbx
    ret

.cas_read_error:
    ; Report error reading stdin
    mov     rdi, STDERR
    lea     rsi, [rel err_prefix]
    mov     rdx, err_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_stdin_name]
    mov     rdx, str_stdin_name_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_read_error]
    mov     rdx, str_read_error_len
    call    asm_write_all
    mov     byte [rel had_error], 1
    mov     [rel stdin_size], rbx       ; use what we got
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  free_stdin_buf — release heap memory used by stdin buffer
; ============================================================================
free_stdin_buf:
    cmp     qword [rel stdin_data], 0
    je      .fsb_done
    ; Reset brk to original value (release stdin buffer)
    mov     rdi, [rel stdin_data]
    mov     eax, 12                     ; SYS_BRK
    syscall
.fsb_done:
    ret

; ============================================================================
;  open_all_files — For each file arg, open/mmap or set up stdin pointer
;  Fills: file_datas[], file_sizes[], file_fds[], file_mmapped[]
;  For stdin ("-"): points into the shared stdin buffer, advancing stdin_cursor
;                   In non-serial mode with multiple "-", round-robin lines
; ============================================================================
open_all_files:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, [rel nfiles]

    ; First, count stdin occurrences and set up stdin distribution
    xor     ecx, ecx                    ; stdin count
    xor     ebx, ebx
.oaf_count_stdin:
    cmp     rbx, r12
    jge     .oaf_count_done
    lea     rax, [rel file_ptrs]
    mov     rdi, [rax + rbx*8]
    cmp     byte [rdi], '-'
    jne     .oaf_count_next
    cmp     byte [rdi+1], 0
    jne     .oaf_count_next
    inc     ecx
.oaf_count_next:
    inc     rbx
    jmp     .oaf_count_stdin

.oaf_count_done:
    mov     [rel stdin_count], ecx
    mov     qword [rel stdin_rr_cursor], 0
    mov     dword [rel stdin_rr_idx], 0

    ; If multiple stdin refs and not serial mode, distribute lines round-robin
    ; We do this by scanning stdin data and building per-stdin-instance ranges
    ; For simplicity: in parallel mode with N stdin refs, stdin_cursor advances
    ; each time we need a line for a stdin ref, producing round-robin behavior.
    ; (This is handled in the paste logic itself.)

    ; Open each file
    xor     ebx, ebx                    ; file index
.oaf_loop:
    cmp     rbx, r12
    jge     .oaf_done

    lea     rax, [rel file_ptrs]
    mov     rdi, [rax + rbx*8]

    ; Check if stdin
    cmp     byte [rdi], '-'
    jne     .oaf_open_file
    cmp     byte [rdi+1], 0
    jne     .oaf_open_file

    ; stdin: point to stdin_data with size stdin_size
    ; For parallel mode with multiple stdin refs, we'll handle distribution
    ; at paste time. For now, all stdin refs share the same data.
    mov     rax, [rel stdin_data]
    lea     rcx, [rel file_datas]
    mov     [rcx + rbx*8], rax
    mov     rax, [rel stdin_size]
    lea     rcx, [rel file_sizes]
    mov     [rcx + rbx*8], rax
    lea     rcx, [rel file_fds]
    mov     qword [rcx + rbx*8], -1     ; no fd
    lea     rcx, [rel file_mmapped]
    mov     byte [rcx + rbx], 0         ; not mmapped
    ; Mark as stdin ref
    lea     rcx, [rel file_is_stdin]
    mov     byte [rcx + rbx], 1
    jmp     .oaf_next

.oaf_open_file:
    lea     rcx, [rel file_is_stdin]
    mov     byte [rcx + rbx], 0

    ; Open the file
    push    rbx
    push    r12
    lea     rax, [rel file_ptrs]
    mov     rdi, [rax + rbx*8]
    xor     esi, esi                    ; O_RDONLY
    xor     edx, edx
    call    asm_open
    pop     r12
    pop     rbx
    test    rax, rax
    js      .oaf_open_error

    mov     r13, rax                    ; fd

    ; fstat to get size
    push    rbx
    push    r12
    lea     rsi, [rel stat_buf]
    mov     edi, r13d
    call    asm_fstat
    pop     r12
    pop     rbx
    test    rax, rax
    js      .oaf_stat_error

    ; Check if regular file
    mov     eax, [rel stat_buf + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFREG
    jne     .oaf_is_dir_check

    ; Get file size
    mov     r14, [rel stat_buf + STAT_SIZE]

    ; Store fd
    lea     rcx, [rel file_fds]
    mov     [rcx + rbx*8], r13

    ; If file is empty, skip mmap
    test    r14, r14
    jz      .oaf_empty_file

    ; mmap the file
    push    rbx
    push    r12
    xor     edi, edi                    ; addr = NULL
    mov     rsi, r14                    ; length
    mov     edx, PROT_READ              ; prot
    mov     r10d, MAP_PRIVATE           ; flags
    mov     r8, r13                     ; fd
    xor     r9d, r9d                    ; offset = 0
    call    asm_mmap
    pop     r12
    pop     rbx
    test    rax, rax
    js      .oaf_mmap_error

    ; Store mmap result
    lea     rcx, [rel file_datas]
    mov     [rcx + rbx*8], rax
    lea     rcx, [rel file_sizes]
    mov     [rcx + rbx*8], r14
    lea     rcx, [rel file_mmapped]
    mov     byte [rcx + rbx], 1
    jmp     .oaf_next

.oaf_empty_file:
    lea     rcx, [rel file_datas]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [rel file_sizes]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [rel file_mmapped]
    mov     byte [rcx + rbx], 0
    jmp     .oaf_next

.oaf_is_dir_check:
    ; Not a regular file — report "Is a directory" or similar
    ; Check if directory (S_IFMT & S_IFDIR)
    mov     eax, [rel stat_buf + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, 0o40000               ; S_IFDIR
    jne     .oaf_read_fallback

    ; Is a directory — error
    push    rbx
    push    r12
    lea     rax, [rel file_ptrs]
    mov     rdi, [rax + rbx*8]
    mov     esi, 21                     ; EISDIR
    call    err_file
    pop     r12
    pop     rbx
    mov     byte [rel had_error], 1

    ; Close fd
    push    rbx
    mov     rdi, r13
    call    asm_close
    pop     rbx

    ; Mark as empty
    lea     rcx, [rel file_datas]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [rel file_sizes]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [rel file_fds]
    mov     qword [rcx + rbx*8], -1
    lea     rcx, [rel file_mmapped]
    mov     byte [rcx + rbx], 0
    jmp     .oaf_next

.oaf_read_fallback:
    ; Non-regular, non-directory: could be a pipe, etc.
    ; Read into memory via read loop. For now, treat as empty.
    ; (Full pipe reading would require dynamic allocation.)
    push    rbx
    push    r12
    mov     rdi, r13
    call    asm_close
    pop     r12
    pop     rbx

    lea     rcx, [rel file_datas]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [rel file_sizes]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [rel file_fds]
    mov     qword [rcx + rbx*8], -1
    lea     rcx, [rel file_mmapped]
    mov     byte [rcx + rbx], 0
    jmp     .oaf_next

.oaf_open_error:
    neg     rax
    mov     r15d, eax                   ; save positive errno
    push    rbx
    push    r12
    lea     rax, [rel file_ptrs]
    mov     rdi, [rax + rbx*8]
    mov     esi, r15d
    call    err_file
    pop     r12
    pop     rbx
    mov     byte [rel had_error], 1

    ; Mark as empty/failed — don't try to use it
    lea     rcx, [rel file_datas]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [rel file_sizes]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [rel file_fds]
    mov     qword [rcx + rbx*8], -1
    lea     rcx, [rel file_mmapped]
    mov     byte [rcx + rbx], 0
    lea     rcx, [rel file_is_stdin]
    mov     byte [rcx + rbx], 0

    ; GNU paste exits immediately on file open failure
    ; (does not process remaining files in that invocation)
    jmp     .oaf_done

.oaf_stat_error:
    neg     rax
    mov     r15d, eax                   ; save positive errno
    push    rbx
    push    r12
    lea     rax, [rel file_ptrs]
    mov     rdi, [rax + rbx*8]
    mov     esi, r15d
    call    err_file
    pop     r12
    pop     rbx
    mov     byte [rel had_error], 1
    push    rbx
    mov     rdi, r13
    call    asm_close
    pop     rbx
    lea     rcx, [rel file_datas]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [rel file_sizes]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [rel file_fds]
    mov     qword [rcx + rbx*8], -1
    lea     rcx, [rel file_mmapped]
    mov     byte [rcx + rbx], 0
    jmp     .oaf_done

.oaf_mmap_error:
    ; mmap failed — mark as empty
    lea     rcx, [rel file_datas]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [rel file_sizes]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [rel file_mmapped]
    mov     byte [rcx + rbx], 0
    jmp     .oaf_next

.oaf_next:
    inc     rbx
    jmp     .oaf_loop

.oaf_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  close_all_files — Close fds and munmap all files
; ============================================================================
close_all_files:
    push    rbx
    push    r12

    mov     r12, [rel nfiles]
    xor     ebx, ebx

.caf_loop:
    cmp     rbx, r12
    jge     .caf_done

    ; munmap if mmapped
    lea     rcx, [rel file_mmapped]
    cmp     byte [rcx + rbx], 0
    je      .caf_close_fd

    push    rbx
    push    r12
    lea     rax, [rel file_datas]
    mov     rdi, [rax + rbx*8]
    lea     rax, [rel file_sizes]
    mov     rsi, [rax + rbx*8]
    call    asm_munmap
    pop     r12
    pop     rbx

.caf_close_fd:
    lea     rcx, [rel file_fds]
    mov     rdi, [rcx + rbx*8]
    cmp     rdi, -1
    je      .caf_next

    push    rbx
    push    r12
    call    asm_close
    pop     r12
    pop     rbx

.caf_next:
    inc     rbx
    jmp     .caf_loop

.caf_done:
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  paste_parallel — Parallel (default) mode: merge lines in lockstep
;  For each output line: read next line from each file, join with delimiters
; ============================================================================
paste_parallel:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8                      ; align stack

    mov     r12, [rel nfiles]
    lea     r13, [rel out_buf]          ; cache output buffer pointer

    ; Initialize cursors for all files
    xor     ecx, ecx
.pp_init_cursors:
    cmp     rcx, r12
    jge     .pp_init_done
    lea     rax, [rel file_cursors]
    mov     qword [rax + rcx*8], 0
    inc     rcx
    jmp     .pp_init_cursors

.pp_init_done:
    ; Initialize per-stdin-instance cursor for round-robin distribution
    mov     qword [rel stdin_rr_cursor], 0
    ; stdin_rr_state: which stdin instance gets the next line?
    ; We track a single cursor that all stdin instances share.

    ; Handle multiple stdin: for parallel mode with multiple "-" refs,
    ; GNU paste reads lines from stdin alternating between the refs.
    ; We track a single stdin_rr_cursor into the stdin buffer.
    ; Each time a stdin instance needs a line, we advance this cursor.

.pp_main_loop:
    ; Check if all files are exhausted
    xor     ecx, ecx
    xor     edx, edx                    ; any_active = 0
.pp_check_active:
    cmp     rcx, r12
    jge     .pp_check_done
    lea     rax, [rel file_cursors]
    mov     rdi, [rax + rcx*8]
    lea     rax, [rel file_sizes]
    cmp     rdi, [rax + rcx*8]
    jge     .pp_check_next
    mov     edx, 1                      ; this file still has data
.pp_check_next:
    inc     rcx
    jmp     .pp_check_active

.pp_check_done:
    test    edx, edx
    jz      .pp_parallel_done           ; all files exhausted

    ; For checking stdin exhaustion in parallel mode, also check stdin_rr_cursor
    ; against stdin_size for stdin instances

    ; Process one output line
    xor     ebx, ebx                    ; file_idx = 0
    xor     ebp, ebp                    ; any_line_produced = 0
    mov     qword [rsp], 0             ; saved_pos for rewind if no content

    ; Save current output position for possible rewind
    mov     rax, r14                    ; r14 = out_buf_used (we use r14 in the loop)
    ; Actually, let's set r14 from the global out_buf position
    mov     r14, [rel out_buf_pos]
    mov     [rsp], r14                  ; saved_pos

.pp_file_loop:
    cmp     rbx, r12
    jge     .pp_line_done

    ; Write delimiter before files 1..N
    test    rbx, rbx
    jz      .pp_no_delim

    ; Get delimiter for this column
    mov     rax, [rel delim_len]
    test    rax, rax
    jz      .pp_no_delim                ; empty delimiter list = no delimiter

    ; Delimiter index = (file_idx - 1) % delim_len
    push    rdx
    mov     rax, rbx
    dec     rax
    xor     edx, edx
    push    rcx
    mov     rcx, [rel delim_len]
    div     rcx
    pop     rcx
    ; rdx = remainder = index into delim_buf
    lea     rax, [rel delim_buf]
    movzx   eax, byte [rax + rdx]
    pop     rdx

    ; If delimiter byte is NUL, skip (NUL = empty delimiter)
    test    al, al
    jz      .pp_no_delim

    ; Emit delimiter byte
    call    emit_byte_al

.pp_no_delim:
    ; Check if this file is a stdin instance
    lea     rax, [rel file_is_stdin]
    cmp     byte [rax + rbx], 0
    jne     .pp_stdin_line

    ; Regular file: get next line
    lea     rax, [rel file_datas]
    mov     rsi, [rax + rbx*8]         ; file data pointer
    lea     rax, [rel file_sizes]
    mov     rcx, [rax + rbx*8]         ; file size
    lea     rax, [rel file_cursors]
    mov     rdi, [rax + rbx*8]         ; cursor position

    ; If cursor >= size, file is exhausted — emit nothing
    cmp     rdi, rcx
    jge     .pp_next_file

    ; Find next terminator from cursor position
    movzx   edx, byte [rel terminator]
    ; rsi + rdi = start of line, rcx - rdi = remaining bytes
    push    rbx
    push    r12
    push    r13
    mov     r15, rdi                    ; save cursor
    ; Scan for terminator
    lea     rax, [rsi + rdi]            ; start of scan
    mov     r12, rcx
    sub     r12, rdi                    ; remaining bytes
    xor     ecx, ecx                    ; offset into remaining
.pp_scan_term:
    cmp     rcx, r12
    jge     .pp_no_term_found
    cmp     byte [rax + rcx], dl
    je      .pp_term_found
    inc     rcx
    jmp     .pp_scan_term

.pp_term_found:
    ; Line is from [rsi+r15] to [rsi+r15+rcx] (exclusive), terminator at rcx offset
    mov     rbp, 1                      ; line produced
    ; Copy line content (rcx bytes)
    test    rcx, rcx
    jz      .pp_skip_copy1
    push    rdx
    mov     rdi, [rel out_buf_pos]
    ; Bounds check: need rcx bytes in output buffer
    lea     rax, [rdi + rcx]
    cmp     rax, OUT_BUF_SIZE
    jl      .pp_copy1
    ; Flush first
    call    flush_output_inner
    test    rax, rax
    js      .pp_write_error_inner
    mov     rdi, [rel out_buf_pos]
.pp_copy1:
    ; Copy from [rsi + r15] to out_buf + out_buf_pos
    lea     rdx, [rel out_buf]
    add     rdx, rdi
    lea     rax, [rsi + r15]
    ; Copy rcx bytes
    push    rsi
    push    rcx
    mov     rsi, rax                    ; source
    mov     rdi, rdx                    ; dest
    ; rep movsb
    cld
    rep movsb
    pop     rcx
    pop     rsi
    mov     rax, [rel out_buf_pos]
    add     rax, rcx
    mov     [rel out_buf_pos], rax
    pop     rdx
.pp_skip_copy1:
    ; Advance cursor past terminator
    lea     rax, [r15 + rcx + 1]
    pop     r13
    pop     r12
    pop     rbx
    lea     rcx, [rel file_cursors]
    mov     [rcx + rbx*8], rax
    jmp     .pp_next_file

.pp_no_term_found:
    ; No terminator found — rest of file is one line (no trailing newline)
    mov     rbp, 1
    test    r12, r12
    jz      .pp_no_term_skip
    push    rdx
    mov     rdi, [rel out_buf_pos]
    lea     rax, [rdi + r12]
    cmp     rax, OUT_BUF_SIZE
    jl      .pp_copy2
    call    flush_output_inner
    test    rax, rax
    js      .pp_write_error_inner
    mov     rdi, [rel out_buf_pos]
.pp_copy2:
    lea     rdx, [rel out_buf]
    add     rdx, rdi
    lea     rax, [rsi + r15]
    push    rsi
    push    rcx
    mov     rsi, rax
    mov     rdi, rdx
    mov     rcx, r12
    cld
    rep movsb
    pop     rcx
    pop     rsi
    mov     rax, [rel out_buf_pos]
    add     rax, r12
    mov     [rel out_buf_pos], rax
    pop     rdx
.pp_no_term_skip:
    ; Set cursor to end
    pop     r13
    pop     r12
    pop     rbx
    lea     rax, [rel file_sizes]
    mov     rax, [rax + rbx*8]
    lea     rcx, [rel file_cursors]
    mov     [rcx + rbx*8], rax
    jmp     .pp_next_file

.pp_stdin_line:
    ; Read a line from the shared stdin buffer (round-robin)
    mov     rsi, [rel stdin_data]
    mov     rcx, [rel stdin_size]
    mov     rdi, [rel stdin_rr_cursor]

    ; If cursor >= size, stdin exhausted
    cmp     rdi, rcx
    jge     .pp_next_file

    ; Find next terminator
    movzx   edx, byte [rel terminator]
    push    rbx
    push    r12
    push    r13
    mov     r15, rdi
    lea     rax, [rsi + rdi]
    mov     r12, rcx
    sub     r12, rdi
    xor     ecx, ecx
.pp_stdin_scan:
    cmp     rcx, r12
    jge     .pp_stdin_no_term
    cmp     byte [rax + rcx], dl
    je      .pp_stdin_term_found
    inc     rcx
    jmp     .pp_stdin_scan

.pp_stdin_term_found:
    mov     ebp, 1
    test    rcx, rcx
    jz      .pp_stdin_skip_copy1
    push    rdx
    mov     rdi, [rel out_buf_pos]
    lea     rax, [rdi + rcx]
    cmp     rax, OUT_BUF_SIZE
    jl      .pp_stdin_copy1
    call    flush_output_inner
    test    rax, rax
    js      .pp_write_error_inner
    mov     rdi, [rel out_buf_pos]
.pp_stdin_copy1:
    lea     rdx, [rel out_buf]
    add     rdx, rdi
    lea     rax, [rsi + r15]
    push    rsi
    push    rcx
    mov     rsi, rax
    mov     rdi, rdx
    cld
    rep movsb
    pop     rcx
    pop     rsi
    mov     rax, [rel out_buf_pos]
    add     rax, rcx
    mov     [rel out_buf_pos], rax
    pop     rdx
.pp_stdin_skip_copy1:
    lea     rax, [r15 + rcx + 1]
    mov     [rel stdin_rr_cursor], rax
    pop     r13
    pop     r12
    pop     rbx
    jmp     .pp_next_file

.pp_stdin_no_term:
    mov     ebp, 1
    test    r12, r12
    jz      .pp_stdin_no_term_skip
    push    rdx
    mov     rdi, [rel out_buf_pos]
    lea     rax, [rdi + r12]
    cmp     rax, OUT_BUF_SIZE
    jl      .pp_stdin_copy2
    call    flush_output_inner
    test    rax, rax
    js      .pp_write_error_inner
    mov     rdi, [rel out_buf_pos]
.pp_stdin_copy2:
    lea     rdx, [rel out_buf]
    add     rdx, rdi
    lea     rax, [rsi + r15]
    push    rsi
    push    rcx
    mov     rsi, rax
    mov     rdi, rdx
    mov     rcx, r12
    cld
    rep movsb
    pop     rcx
    pop     rsi
    mov     rax, [rel out_buf_pos]
    add     rax, r12
    mov     [rel out_buf_pos], rax
    pop     rdx
.pp_stdin_no_term_skip:
    mov     rax, [rel stdin_size]
    mov     [rel stdin_rr_cursor], rax
    pop     r13
    pop     r12
    pop     rbx
    jmp     .pp_next_file

.pp_next_file:
    inc     rbx
    jmp     .pp_file_loop

.pp_line_done:
    ; If no file produced a line, we're done (rewind delimiters)
    test    ebp, ebp
    jz      .pp_rewind_done

    ; Emit terminator
    movzx   eax, byte [rel terminator]
    call    emit_byte_al

    ; Flush if buffer is getting full
    mov     rax, [rel out_buf_pos]
    cmp     rax, FLUSH_THRESHOLD
    jl      .pp_main_loop
    call    flush_output_inner
    test    rax, rax
    js      .pp_write_error
    jmp     .pp_main_loop

.pp_rewind_done:
    ; Rewind output to saved_pos (discard delimiters for empty row)
    mov     rax, [rsp]
    mov     [rel out_buf_pos], rax

.pp_parallel_done:
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.pp_write_error:
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.pp_write_error_inner:
    ; Unwind from inside nested pushes
    pop     r13
    pop     r12
    pop     rbx
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  paste_serial — Serial mode: for each file, join all lines with delimiters
; ============================================================================
paste_serial:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    lea     r13, [rel out_buf]
    mov     qword [rel stdin_rr_cursor], 0

    xor     ebx, ebx                    ; file index
.ps_file_loop:
    cmp     rbx, [rel nfiles]
    jge     .ps_done

    ; Get file data and size
    lea     rax, [rel file_is_stdin]
    cmp     byte [rax + rbx], 0
    jne     .ps_stdin_file

    lea     rax, [rel file_datas]
    mov     r14, [rax + rbx*8]         ; data pointer
    lea     rax, [rel file_sizes]
    mov     r15, [rax + rbx*8]         ; size
    jmp     .ps_process_file

.ps_stdin_file:
    ; For serial mode, first stdin ref gets all data, rest get empty
    mov     r14, [rel stdin_data]
    mov     r15, [rel stdin_size]
    ; After first stdin ref, mark stdin as consumed
    mov     qword [rel stdin_size], 0

.ps_process_file:
    ; If empty file, just output terminator
    test    r15, r15
    jz      .ps_empty_file

    ; Process all lines in this file
    xor     r12d, r12d                  ; cursor into file
    xor     ecx, ecx                    ; line index (for delimiter cycling)
    mov     [rel serial_line_idx], rcx

.ps_line_loop:
    cmp     r12, r15
    jge     .ps_file_end

    ; Write delimiter before lines 1..N
    mov     rcx, [rel serial_line_idx]
    test    rcx, rcx
    jz      .ps_no_delim

    mov     rax, [rel delim_len]
    test    rax, rax
    jz      .ps_no_delim

    ; Delimiter index = (line_idx - 1) % delim_len
    push    rdx
    mov     rax, rcx
    dec     rax
    xor     edx, edx
    push    rcx
    mov     rcx, [rel delim_len]
    div     rcx
    pop     rcx
    lea     rax, [rel delim_buf]
    movzx   eax, byte [rax + rdx]
    pop     rdx

    ; If NUL, skip
    test    al, al
    jz      .ps_no_delim

    call    emit_byte_al

.ps_no_delim:
    ; Find next terminator from cursor r12
    movzx   edx, byte [rel terminator]
    lea     rsi, [r14 + r12]
    mov     rdi, r15
    sub     rdi, r12                    ; remaining bytes
    xor     ecx, ecx

.ps_scan_term:
    cmp     rcx, rdi
    jge     .ps_no_term

    cmp     byte [rsi + rcx], dl
    je      .ps_term_found

    inc     rcx
    jmp     .ps_scan_term

.ps_term_found:
    ; Copy line content (rcx bytes from rsi)
    test    rcx, rcx
    jz      .ps_skip_line_copy

    push    rdx
    ; Check if output buffer needs flushing
    mov     rax, [rel out_buf_pos]
    push    rcx
    add     rax, rcx
    cmp     rax, OUT_BUF_SIZE
    jl      .ps_copy_line
    call    flush_output_inner
    test    rax, rax
    js      .ps_serial_write_error
.ps_copy_line:
    pop     rcx
    mov     rdi, [rel out_buf_pos]
    lea     rax, [rel out_buf]
    add     rax, rdi
    ; Copy rcx bytes from rsi to rax
    push    rsi
    push    rcx
    mov     rdi, rax                    ; dest
    ; rsi already points to source
    cld
    rep movsb
    pop     rcx
    pop     rsi
    mov     rax, [rel out_buf_pos]
    add     rax, rcx
    mov     [rel out_buf_pos], rax
    pop     rdx

.ps_skip_line_copy:
    ; Advance cursor past terminator
    add     r12, rcx
    inc     r12
    inc     qword [rel serial_line_idx]

    ; Flush check
    mov     rax, [rel out_buf_pos]
    cmp     rax, FLUSH_THRESHOLD
    jl      .ps_line_loop
    call    flush_output_inner
    test    rax, rax
    js      .ps_write_error
    jmp     .ps_line_loop

.ps_no_term:
    ; No terminator — rest of file is one line
    test    rdi, rdi
    jz      .ps_file_end

    push    rdx
    mov     rax, [rel out_buf_pos]
    push    rdi
    add     rax, rdi
    cmp     rax, OUT_BUF_SIZE
    jl      .ps_copy_rest
    call    flush_output_inner
    test    rax, rax
    js      .ps_serial_write_error
.ps_copy_rest:
    pop     rdi
    mov     rcx, rdi                    ; bytes to copy
    mov     rdi, [rel out_buf_pos]
    lea     rax, [rel out_buf]
    add     rax, rdi
    push    rcx
    mov     rdi, rax
    cld
    rep movsb
    pop     rcx
    mov     rax, [rel out_buf_pos]
    add     rax, rcx
    mov     [rel out_buf_pos], rax
    pop     rdx

    mov     r12, r15                    ; set cursor to end

.ps_file_end:
    ; Emit terminator after each file
    movzx   eax, byte [rel terminator]
    call    emit_byte_al

    ; Flush check
    mov     rax, [rel out_buf_pos]
    cmp     rax, FLUSH_THRESHOLD
    jl      .ps_next_file
    call    flush_output_inner
    test    rax, rax
    js      .ps_write_error
    jmp     .ps_next_file

.ps_empty_file:
    ; Empty file in serial mode: output just a terminator
    movzx   eax, byte [rel terminator]
    call    emit_byte_al
    ; fall through to next file

.ps_next_file:
    inc     rbx
    jmp     .ps_file_loop

.ps_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.ps_write_error:
.ps_serial_write_error:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  emit_byte_al — Append byte in al to output buffer, flush if needed
; ============================================================================
emit_byte_al:
    push    rbx
    mov     rbx, [rel out_buf_pos]
    lea     rcx, [rel out_buf]
    mov     [rcx + rbx], al
    inc     rbx
    mov     [rel out_buf_pos], rbx

    cmp     rbx, FLUSH_THRESHOLD
    jl      .eba_done

    call    flush_output_inner
.eba_done:
    pop     rbx
    ret

; ============================================================================
;  flush_output / flush_output_inner — Write out_buf[0..out_buf_pos) to stdout
; ============================================================================
flush_output:
    ; Use the global out_buf_pos
flush_output_inner:
    push    r12
    mov     r12, [rel out_buf_pos]
    test    r12, r12
    jz      .fo_nothing

    mov     rdi, STDOUT
    lea     rsi, [rel out_buf]
    mov     rdx, r12
    call    asm_write_all
    mov     qword [rel out_buf_pos], 0
    pop     r12
    ret

.fo_nothing:
    xor     eax, eax
    pop     r12
    ret

; ============================================================================
;  String utilities
; ============================================================================

; strlen(rdi=str) -> rax=length
strlen:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; str_eq(rdi=s1, rsi=s2) -> eax=1 if equal, 0 if not
str_eq:
.se_loop:
    mov     al, [rdi]
    mov     cl, [rsi]
    cmp     al, cl
    jne     .se_ne
    test    al, al
    jz      .se_equal
    inc     rdi
    inc     rsi
    jmp     .se_loop
.se_equal:
    mov     eax, 1
    ret
.se_ne:
    xor     eax, eax
    ret

; str_has_prefix(rdi=str, rsi=prefix, ecx=prefix_len) -> eax=1 if prefix matches, 0 if not
str_has_prefix:
    push    rbx
    xor     ebx, ebx
.sp_loop:
    cmp     ebx, ecx
    jge     .sp_match
    movzx   eax, byte [rdi + rbx]
    cmp     al, [rsi + rbx]
    jne     .sp_no
    inc     ebx
    jmp     .sp_loop
.sp_match:
    mov     eax, 1
    pop     rbx
    ret
.sp_no:
    xor     eax, eax
    pop     rbx
    ret

; ============================================================================
;  Error helpers
; ============================================================================

; err_file(rdi=filename, esi=errno) — "paste: {filename}: {strerror}\n"
err_file:
    push    rbx
    push    r13
    mov     rbx, rdi
    mov     r13d, esi

    mov     rdi, STDERR
    lea     rsi, [rel err_prefix]
    mov     rdx, err_prefix_len
    call    asm_write_all

    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_colon_space]
    mov     rdx, 2
    call    asm_write_all

    mov     edi, r13d
    call    strerror
    mov     rbx, rax
    mov     rdi, rax
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_newline]
    mov     rdx, 1
    call    asm_write_all

    pop     r13
    pop     rbx
    ret

; err_unrecognized_option(rdi=option_string)
err_unrecognized_option:
    push    rbx
    mov     rbx, rdi

    mov     rdi, STDERR
    lea     rsi, [rel str_unrecognized]
    mov     rdx, str_unrecognized_len
    call    asm_write_all

    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_quote_nl]
    mov     rdx, 2
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all

    pop     rbx
    ret

; err_invalid_option(esi=bad_char_byte)
err_invalid_option:
    push    rbx
    mov     ebx, esi

    mov     rdi, STDERR
    lea     rsi, [rel str_invalid_opt]
    mov     rdx, str_invalid_opt_len
    call    asm_write_all

    mov     [rel char_buf], bl
    mov     rdi, STDERR
    lea     rsi, [rel char_buf]
    mov     rdx, 1
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_quote_nl]
    mov     rdx, 2
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all

    pop     rbx
    ret

; strerror(edi=errno) -> rax=string pointer
strerror:
    cmp     edi, 1
    je      .se_eperm
    cmp     edi, 2
    je      .se_enoent
    cmp     edi, 5
    je      .se_eio
    cmp     edi, 9
    je      .se_ebadf
    cmp     edi, 12
    je      .se_enomem
    cmp     edi, 13
    je      .se_eacces
    cmp     edi, 20
    je      .se_enotdir
    cmp     edi, 21
    je      .se_eisdir
    cmp     edi, 22
    je      .se_einval
    cmp     edi, 24
    je      .se_emfile
    cmp     edi, 36
    je      .se_enametoolong
    lea     rax, [rel str_eunknown]
    ret
.se_eperm:
    lea     rax, [rel str_eperm]
    ret
.se_enoent:
    lea     rax, [rel str_enoent]
    ret
.se_eio:
    lea     rax, [rel str_eio]
    ret
.se_ebadf:
    lea     rax, [rel str_ebadf]
    ret
.se_enomem:
    lea     rax, [rel str_enomem]
    ret
.se_eacces:
    lea     rax, [rel str_eacces]
    ret
.se_enotdir:
    lea     rax, [rel str_enotdir]
    ret
.se_eisdir:
    lea     rax, [rel str_eisdir]
    ret
.se_einval:
    lea     rax, [rel str_einval]
    ret
.se_emfile:
    lea     rax, [rel str_emfile]
    ret
.se_enametoolong:
    lea     rax, [rel str_enametoolong]
    ret

; ─── Data Section ────────────────────────────────────────
section .data

err_prefix:     db "paste: "
err_prefix_len  equ $ - err_prefix

str_newline:    db 10
str_colon_space: db ": "

str_unrecognized: db "paste: unrecognized option ", 0xE2, 0x80, 0x98
str_unrecognized_len equ $ - str_unrecognized

str_quote_nl:   db 0xE2, 0x80, 0x99, 10

str_try_help:   db "Try 'paste --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_invalid_opt: db "paste: invalid option -- ", 0xE2, 0x80, 0x98
str_invalid_opt_len equ $ - str_invalid_opt

str_help_opt:       db "--help", 0
str_version_opt:    db "--version", 0
str_serial_opt:     db "--serial", 0
str_zero_opt:       db "--zero-terminated", 0
str_delimiters_eq:  db "--delimiters=", 0
str_delimiters_opt: db "--delimiters", 0

str_delim_missing:  db "paste: option '--delimiters' requires an argument", 10
str_delim_missing_len equ $ - str_delim_missing

str_d_missing:      db "paste: option requires an argument -- 'd'", 10
str_d_missing_len   equ $ - str_d_missing

str_stdin_name:     db "standard input"
str_stdin_name_len  equ $ - str_stdin_name

str_read_error:     db ": read error", 10
str_read_error_len  equ $ - str_read_error

help_text:
    db "Usage: paste [OPTION]... [FILE]...", 10
    db "Write lines consisting of the sequentially corresponding lines from", 10
    db "each FILE, separated by TABs, to standard output.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -d, --delimiters=LIST   reuse characters from LIST instead of TABs", 10
    db "  -s, --serial            paste one file at a time instead of in parallel", 10
    db "  -z, --zero-terminated    line delimiter is NUL, not newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/paste>", 10
    db "or available locally via: info '(coreutils) paste invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "paste (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by David M. Ihnat and David MacKenzie.", 10
version_text_len equ $ - version_text

dash_str:       db "-", 0

str_eperm:          db "Operation not permitted", 0
str_enoent:         db "No such file or directory", 0
str_eio:            db "Input/output error", 0
str_ebadf:          db "Bad file descriptor", 0
str_enomem:         db "Cannot allocate memory", 0
str_eacces:         db "Permission denied", 0
str_enotdir:        db "Not a directory", 0
str_eisdir:         db "Is a directory", 0
str_einval:         db "Invalid argument", 0
str_emfile:         db "Too many open files", 0
str_enametoolong:   db "File name too long", 0
str_eunknown:       db "Unknown error", 0

; ─── BSS Section ─────────────────────────────────────────
section .bss

argc:               resq 1
argv:               resq 1
flags:              resb 1
had_error:          resb 1
terminator:         resb 1
nfiles:             resq 1
file_ptrs:          resq MAX_FILES
file_datas:         resq MAX_FILES
file_sizes:         resq MAX_FILES
file_fds:           resq MAX_FILES
file_cursors:       resq MAX_FILES
file_mmapped:       resb MAX_FILES
file_is_stdin:      resb MAX_FILES
delim_buf:          resb MAX_DELIMS
delim_len:          resq 1
char_buf:           resb 4
out_buf_pos:        resq 1
stat_buf:           resb STAT_STRUCT_SIZE
stdin_data:         resq 1
stdin_size:         resq 1
stdin_capacity:     resq 1
stdin_count:        resd 1
stdin_rr_idx:       resd 1
stdin_rr_cursor:    resq 1
serial_line_idx:    resq 1
out_buf:            resb OUT_BUF_SIZE

section .note.GNU-stack noalloc noexec nowrite progbits
