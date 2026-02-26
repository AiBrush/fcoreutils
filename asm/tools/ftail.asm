; ============================================================================
; ftail.asm — GNU-compatible "tail" in x86-64 Linux assembly
;
; Drop-in replacement for GNU coreutils `tail`. Pure x86-64 assembly,
; no libc. Handles all major flags, seekable/non-seekable files, multiple
; files with headers, size suffixes, and SIMD-accelerated newline scanning.
;
; Supported flags:
;   -n [+]NUM, --lines=[+]NUM   — output last/from NUM lines
;   -c [+]NUM, --bytes=[+]NUM   — output last/from NUM bytes
;   -q, --quiet, --silent       — never output headers
;   -v, --verbose               — always output headers
;   -z, --zero-terminated       — NUL delimiter instead of newline
;   --help                      — usage text, exit 0
;   --version                   — version text, exit 0
;   --                          — end of options
;   Legacy: -N (same as -n N), +N (same as -n +N)
;
; Accepted but not implemented (follow mode):
;   -f, --follow, -F, --retry, --pid, -s, --sleep-interval,
;   --max-unchanged-stats
;
; Build (modular):
;   nasm -f elf64 -I include/ tools/ftail.asm -o build/tools/ftail.o
;   nasm -f elf64 -I include/ lib/io.asm -o build/lib/io.o
;   ld --gc-sections -n build/tools/ftail.o build/lib/io.o -o ftail
; ============================================================================

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close

; === Mode constants ===
%define MODE_LINES       0
%define MODE_LINES_FROM  1
%define MODE_BYTES       2
%define MODE_BYTES_FROM  3

; === Buffer sizes ===
%define RDBUF_SZ         65536
%define STDIN_ALLOC      (256 * 1024 * 1024)   ; 256MB mmap for stdin
%define MAX_FILES        1024

section .text
global _start

; ============================================================================
;                          ENTRY POINT
; ============================================================================
_start:
    pop     rcx                     ; argc
    mov     [rel argc], rcx
    mov     r14, rsp                ; r14 = &argv[0]
    mov     [rel argv_base], r14

    ; ---- Block SIGPIPE ----
    push    rcx
    sub     rsp, 16
    mov     qword [rsp], (1 << (SIGPIPE - 1))
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi                ; SIG_BLOCK
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16
    pop     rcx

    ; ---- Initialize defaults ----
    mov     qword [rel mode], MODE_LINES
    mov     qword [rel count], 10
    mov     byte [rel delimiter], 10    ; newline
    mov     byte [rel quiet], 0
    mov     byte [rel verbose], 0
    mov     byte [rel had_error], 0
    mov     qword [rel file_count], 0

    ; ---- Parse arguments ----
    call    parse_args

    ; ---- Determine show_headers ----
    ; quiet → never; verbose → always; else → file_count > 1
    cmp     byte [rel quiet], 0
    jne     .no_headers
    cmp     byte [rel verbose], 0
    jne     .yes_headers
    cmp     qword [rel file_count], 1
    jg      .yes_headers
.no_headers:
    mov     byte [rel show_hdr], 0
    jmp     .headers_done
.yes_headers:
    mov     byte [rel show_hdr], 1
.headers_done:

    ; ---- If no files, use stdin ----
    cmp     qword [rel file_count], 0
    jne     .have_files
    lea     rdi, [rel str_stdin_marker]  ; "-"
    mov     [rel file_ptrs], rdi
    mov     qword [rel file_count], 1
.have_files:

    ; ---- Process each file ----
    xor     r12d, r12d              ; r12 = file index
    mov     byte [rel first_file], 1

.file_loop:
    cmp     r12, [rel file_count]
    jge     .files_done

    lea     rax, [rel file_ptrs]
    mov     rdi, [rax + r12 * 8]    ; rdi = filename pointer
    call    process_file

    inc     r12
    jmp     .file_loop

.files_done:
    ; Exit with appropriate code
    movzx   edi, byte [rel had_error]
    SYSCALL_EXIT rdi


; ============================================================================
;                       ARGUMENT PARSING
; ============================================================================
parse_args:
    push    rbx
    push    r12
    push    r13
    push    r15

    mov     rcx, [rel argc]
    cmp     rcx, 2
    jl      .pa_done                ; no args

    lea     rbx, [r14 + 8]         ; rbx = &argv[1]
    xor     r15d, r15d              ; r15 = past_options flag

.pa_loop:
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .pa_done

    ; If past "--", treat everything as file
    test    r15d, r15d
    jnz     .pa_add_file

    ; Check if starts with '-'
    cmp     byte [rsi], '-'
    jne     .pa_add_file

    ; Just "-" alone → stdin marker (add as file)
    cmp     byte [rsi + 1], 0
    je      .pa_add_file

    ; Starts with '-'. Check for "--"
    cmp     byte [rsi + 1], '-'
    je      .pa_long_opt

    ; Short option(s): skip the '-'
    inc     rsi
    jmp     .pa_short_loop

; ---- Short option processing ----
.pa_short_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .pa_next_arg

    cmp     al, 'n'
    je      .pa_opt_n
    cmp     al, 'c'
    je      .pa_opt_c
    cmp     al, 'q'
    je      .pa_opt_q
    cmp     al, 'v'
    je      .pa_opt_v
    cmp     al, 'z'
    je      .pa_opt_z
    cmp     al, 'f'
    je      .pa_opt_ignore_flag     ; accept -f silently
    cmp     al, 'F'
    je      .pa_opt_ignore_flag     ; accept -F silently
    cmp     al, 's'
    je      .pa_opt_s_skip          ; accept -s N silently

    ; Legacy: digit or '+' → implicit -n
    cmp     al, '+'
    je      .pa_opt_legacy
    cmp     al, '0'
    jb      .pa_invalid_short
    cmp     al, '9'
    jbe     .pa_opt_legacy

.pa_invalid_short:
    ; "tail: invalid option -- 'X'"
    movzx   r12d, byte [rsi]
    lea     rdi, [rel err_inval_prefix]
    call    write_str_stderr
    ; Write the character
    push    r12
    mov     rdi, STDERR
    mov     rsi, rsp
    mov     rdx, 1
    call    asm_write_all
    pop     r12
    lea     rdi, [rel err_inval_suffix]
    call    write_str_stderr
    SYSCALL_EXIT 1

.pa_opt_n:
    ; -n: value is rest of this arg, or next arg
    inc     rsi
    cmp     byte [rsi], 0
    jne     .pa_parse_lines_val
    ; Next arg
    add     rbx, 8
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .pa_n_missing
    jmp     .pa_parse_lines_val
.pa_n_missing:
    lea     rdi, [rel err_n_requires]
    call    write_str_stderr
    SYSCALL_EXIT 1

.pa_parse_lines_val:
    ; rsi = value string. Check for '+' prefix
    cmp     byte [rsi], '+'
    je      .pa_lines_from
    cmp     byte [rsi], '-'
    je      .pa_lines_skip_minus
    jmp     .pa_lines_last
.pa_lines_skip_minus:
    inc     rsi
.pa_lines_last:
    call    parse_number
    test    rdx, rdx
    jnz     .pa_bad_lines
    mov     qword [rel mode], MODE_LINES
    mov     [rel count], rax
    jmp     .pa_next_arg
.pa_lines_from:
    inc     rsi                     ; skip '+'
    call    parse_number
    test    rdx, rdx
    jnz     .pa_bad_lines
    mov     qword [rel mode], MODE_LINES_FROM
    mov     [rel count], rax
    jmp     .pa_next_arg
.pa_bad_lines:
    ; Save the original value for error message
    lea     rdi, [rel err_bad_lines_prefix]
    call    write_str_stderr
    ; We need the original value string - reconstruct from rsi
    ; For simplicity, just print a generic error
    lea     rdi, [rel err_bad_lines_suffix]
    call    write_str_stderr
    SYSCALL_EXIT 1

.pa_opt_c:
    ; -c: value is rest of this arg, or next arg
    inc     rsi
    cmp     byte [rsi], 0
    jne     .pa_parse_bytes_val
    add     rbx, 8
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .pa_c_missing
    jmp     .pa_parse_bytes_val
.pa_c_missing:
    lea     rdi, [rel err_c_requires]
    call    write_str_stderr
    SYSCALL_EXIT 1

.pa_parse_bytes_val:
    cmp     byte [rsi], '+'
    je      .pa_bytes_from
    cmp     byte [rsi], '-'
    je      .pa_bytes_skip_minus
    jmp     .pa_bytes_last
.pa_bytes_skip_minus:
    inc     rsi
.pa_bytes_last:
    call    parse_number
    test    rdx, rdx
    jnz     .pa_bad_bytes
    mov     qword [rel mode], MODE_BYTES
    mov     [rel count], rax
    jmp     .pa_next_arg
.pa_bytes_from:
    inc     rsi
    call    parse_number
    test    rdx, rdx
    jnz     .pa_bad_bytes
    mov     qword [rel mode], MODE_BYTES_FROM
    mov     [rel count], rax
    jmp     .pa_next_arg
.pa_bad_bytes:
    lea     rdi, [rel err_bad_bytes_prefix]
    call    write_str_stderr
    lea     rdi, [rel err_bad_bytes_suffix]
    call    write_str_stderr
    SYSCALL_EXIT 1

.pa_opt_q:
    mov     byte [rel quiet], 1
    inc     rsi
    jmp     .pa_short_loop

.pa_opt_v:
    mov     byte [rel verbose], 1
    inc     rsi
    jmp     .pa_short_loop

.pa_opt_z:
    mov     byte [rel delimiter], 0
    inc     rsi
    jmp     .pa_short_loop

.pa_opt_ignore_flag:
    inc     rsi
    jmp     .pa_short_loop

.pa_opt_s_skip:
    ; -s: skip the value (rest of arg or next arg)
    inc     rsi
    cmp     byte [rsi], 0
    jne     .pa_next_arg            ; value was rest of arg
    add     rbx, 8                  ; skip next arg (the value)
    jmp     .pa_next_arg

.pa_opt_legacy:
    ; Legacy: -N or +N syntax (rsi points at digit/+)
    cmp     byte [rsi], '+'
    je      .pa_legacy_from
    ; -N: last N lines
    call    parse_number
    test    rdx, rdx
    jnz     .pa_next_arg            ; ignore parse errors for legacy
    mov     qword [rel mode], MODE_LINES
    mov     [rel count], rax
    jmp     .pa_next_arg
.pa_legacy_from:
    inc     rsi
    call    parse_number
    test    rdx, rdx
    jnz     .pa_next_arg
    mov     qword [rel mode], MODE_LINES_FROM
    mov     [rel count], rax
    jmp     .pa_next_arg

; ---- Long option processing ----
.pa_long_opt:
    ; rsi points at "--..."
    ; Check for exactly "--" (end of options)
    cmp     byte [rsi + 2], 0
    je      .pa_set_past

    ; Try each long option
    ; --help
    lea     rdi, [rel str_help_opt]
    call    str_eq
    je      .pa_do_help

    ; --version
    lea     rdi, [rel str_version_opt]
    call    str_eq
    je      .pa_do_version

    ; --lines=N or --lines N
    lea     rdi, [rel str_lines_prefix]
    mov     r13, rsi                ; save original
    call    str_startswith
    je      .pa_long_lines

    ; --bytes=N or --bytes N
    mov     rsi, r13
    lea     rdi, [rel str_bytes_prefix]
    call    str_startswith
    je      .pa_long_bytes

    ; --quiet
    mov     rsi, r13
    lea     rdi, [rel str_quiet_opt]
    call    str_eq
    je      .pa_long_quiet

    ; --silent
    mov     rsi, r13
    lea     rdi, [rel str_silent_opt]
    call    str_eq
    je      .pa_long_quiet

    ; --verbose
    mov     rsi, r13
    lea     rdi, [rel str_verbose_opt]
    call    str_eq
    je      .pa_long_verbose

    ; --zero-terminated
    mov     rsi, r13
    lea     rdi, [rel str_zero_opt]
    call    str_eq
    je      .pa_long_zero

    ; --follow, --follow=name, --follow=descriptor (accept silently)
    mov     rsi, r13
    lea     rdi, [rel str_follow_prefix]
    call    str_startswith
    je      .pa_next_arg

    mov     rsi, r13
    lea     rdi, [rel str_follow_opt]
    call    str_eq
    je      .pa_next_arg

    ; --retry (accept silently)
    mov     rsi, r13
    lea     rdi, [rel str_retry_opt]
    call    str_eq
    je      .pa_next_arg

    ; --pid=N or --pid N (accept silently, skip value)
    mov     rsi, r13
    lea     rdi, [rel str_pid_prefix]
    call    str_startswith
    je      .pa_next_arg

    mov     rsi, r13
    lea     rdi, [rel str_pid_opt]
    call    str_eq
    je      .pa_skip_next_value

    ; --sleep-interval=N or --sleep-interval N (accept silently)
    mov     rsi, r13
    lea     rdi, [rel str_sleep_prefix]
    call    str_startswith
    je      .pa_next_arg

    mov     rsi, r13
    lea     rdi, [rel str_sleep_opt]
    call    str_eq
    je      .pa_skip_next_value

    ; --max-unchanged-stats=N or --max-unchanged-stats N (accept silently)
    mov     rsi, r13
    lea     rdi, [rel str_maxu_prefix]
    call    str_startswith
    je      .pa_next_arg

    mov     rsi, r13
    lea     rdi, [rel str_maxu_opt]
    call    str_eq
    je      .pa_skip_next_value

    ; Unrecognized long option
    mov     rsi, r13
    jmp     .pa_unrec_long

.pa_long_lines:
    ; rsi is advanced past "--lines=", check if '=' was there
    cmp     byte [rsi], 0
    jne     .pa_ll_have_val
    ; --lines with separate value
    add     rbx, 8
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .pa_lines_opt_missing
.pa_ll_have_val:
    jmp     .pa_parse_lines_val
.pa_lines_opt_missing:
    lea     rdi, [rel err_lines_requires]
    call    write_str_stderr
    SYSCALL_EXIT 1

.pa_long_bytes:
    cmp     byte [rsi], 0
    jne     .pa_lb_have_val
    add     rbx, 8
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .pa_bytes_opt_missing
.pa_lb_have_val:
    jmp     .pa_parse_bytes_val
.pa_bytes_opt_missing:
    lea     rdi, [rel err_bytes_requires]
    call    write_str_stderr
    SYSCALL_EXIT 1

.pa_long_quiet:
    mov     byte [rel quiet], 1
    jmp     .pa_next_arg

.pa_long_verbose:
    mov     byte [rel verbose], 1
    jmp     .pa_next_arg

.pa_long_zero:
    mov     byte [rel delimiter], 0
    jmp     .pa_next_arg

.pa_do_help:
    mov     rdi, STDOUT
    lea     rsi, [rel help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    SYSCALL_EXIT 0

.pa_do_version:
    mov     rdi, STDOUT
    lea     rsi, [rel version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    SYSCALL_EXIT 0

.pa_set_past:
    mov     r15d, 1
    jmp     .pa_next_arg

.pa_skip_next_value:
    add     rbx, 8
    jmp     .pa_next_arg

.pa_unrec_long:
    ; "tail: unrecognized option 'OPTION'"
    lea     rdi, [rel err_unrec_prefix]
    call    write_str_stderr
    mov     rdi, rsi
    call    write_str_stderr
    lea     rdi, [rel err_unrec_suffix]
    call    write_str_stderr
    SYSCALL_EXIT 1

.pa_add_file:
    mov     rcx, [rel file_count]
    cmp     rcx, MAX_FILES
    jge     .pa_next_arg            ; silently ignore excess files
    lea     rax, [rel file_ptrs]
    mov     [rax + rcx * 8], rsi
    inc     qword [rel file_count]
    jmp     .pa_next_arg

.pa_add_file_stdin:
    ; "-" as file argument → stdin marker
    lea     rdi, [rel str_stdin_marker]
    mov     rcx, [rel file_count]
    cmp     rcx, MAX_FILES
    jge     .pa_next_arg
    lea     rax, [rel file_ptrs]
    mov     [rax + rcx * 8], rdi
    inc     qword [rel file_count]
    jmp     .pa_next_arg

.pa_next_arg:
    add     rbx, 8
    jmp     .pa_loop

.pa_done:
    pop     r15
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;                    STRING COMPARISON HELPERS
; ============================================================================

; str_eq: Compare null-terminated string rsi with rdi
; Returns: ZF set if equal
str_eq:
    push    rsi
    push    rdi
.se_loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .se_ne
    test    al, al
    jz      .se_eq
    inc     rdi
    inc     rsi
    jmp     .se_loop
.se_eq:
    pop     rdi
    pop     rsi
    xor     eax, eax                ; set ZF
    ret
.se_ne:
    pop     rdi
    pop     rsi
    or      eax, 1                  ; clear ZF
    ret

; str_startswith: Check if rsi starts with rdi (prefix ends at '=' or '\0')
; On match: ZF set, rsi advanced past prefix and '='
; On no match: ZF clear, rsi unchanged
str_startswith:
    push    r8
    mov     r8, rsi                 ; save original rsi
.sw_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .sw_check_eq            ; end of prefix
    cmp     al, [rsi]
    jne     .sw_no
    inc     rdi
    inc     rsi
    jmp     .sw_loop
.sw_check_eq:
    ; Prefix matched. Next char in rsi should be '=' or '\0'
    cmp     byte [rsi], '='
    je      .sw_yes_eq
    cmp     byte [rsi], 0
    je      .sw_yes_end
    ; Prefix matched but option continues (e.g., --linesXXX) → no match
.sw_no:
    mov     rsi, r8                 ; restore rsi
    pop     r8
    or      eax, 1                  ; clear ZF
    ret
.sw_yes_eq:
    inc     rsi                     ; skip '='
    pop     r8
    xor     eax, eax                ; set ZF
    ret
.sw_yes_end:
    pop     r8
    xor     eax, eax                ; set ZF
    ret


; ============================================================================
;                    NUMBER PARSING WITH SIZE SUFFIXES
; ============================================================================

; parse_number: Parse decimal number with optional size suffix
; Input:  rsi = pointer to string
; Output: rax = parsed number, rdx = 0 on success, 1 on error
;         rsi advanced past consumed characters
parse_number:
    push    rbx
    push    rcx
    push    r8

    xor     rax, rax                ; accumulator
    xor     ecx, ecx                ; digit count

.pn_digit:
    movzx   edx, byte [rsi]
    sub     dl, '0'
    cmp     dl, 9
    ja      .pn_suffix

    ; rax = rax * 10 + digit
    imul    rax, 10
    jo      .pn_overflow
    movzx   edx, byte [rsi]
    sub     dl, '0'
    add     rax, rdx
    inc     rsi
    inc     ecx
    jmp     .pn_digit

.pn_suffix:
    ; Check we got at least one digit
    test    ecx, ecx
    jz      .pn_error

    ; Check suffix
    movzx   edx, byte [rsi]
    test    dl, dl
    jz      .pn_ok                  ; no suffix

    mov     rbx, rax                ; save base number

    cmp     dl, 'b'
    je      .pn_b
    cmp     dl, 'K'
    je      .pn_K
    cmp     dl, 'k'
    je      .pn_k
    cmp     dl, 'M'
    je      .pn_M
    cmp     dl, 'G'
    je      .pn_G
    cmp     dl, 'T'
    je      .pn_T
    cmp     dl, 'P'
    je      .pn_P
    cmp     dl, 'E'
    je      .pn_E
    jmp     .pn_error               ; unknown suffix

.pn_b:
    ; b = 512
    mov     rcx, 512
    inc     rsi
    jmp     .pn_multiply

.pn_K:
    ; K or KiB = 1024
    inc     rsi
    cmp     byte [rsi], 'i'
    jne     .pn_K_plain
    inc     rsi
    cmp     byte [rsi], 'B'
    jne     .pn_error
    inc     rsi
.pn_K_plain:
    mov     rcx, 1024
    jmp     .pn_multiply

.pn_k:
    ; kB = 1000
    inc     rsi
    cmp     byte [rsi], 'B'
    jne     .pn_error
    inc     rsi
    mov     rcx, 1000
    jmp     .pn_multiply

.pn_M:
    inc     rsi
    cmp     byte [rsi], 'B'
    je      .pn_MB
    cmp     byte [rsi], 'i'
    je      .pn_MiB
    ; M alone = 1024*1024
    mov     rcx, 1048576
    jmp     .pn_multiply
.pn_MB:
    inc     rsi
    mov     rcx, 1000000
    jmp     .pn_multiply
.pn_MiB:
    inc     rsi
    cmp     byte [rsi], 'B'
    jne     .pn_error
    inc     rsi
    mov     rcx, 1048576
    jmp     .pn_multiply

.pn_G:
    inc     rsi
    cmp     byte [rsi], 'B'
    je      .pn_GB
    cmp     byte [rsi], 'i'
    je      .pn_GiB
    mov     rcx, 1073741824
    jmp     .pn_multiply
.pn_GB:
    inc     rsi
    mov     rcx, 1000000000
    jmp     .pn_multiply
.pn_GiB:
    inc     rsi
    cmp     byte [rsi], 'B'
    jne     .pn_error
    inc     rsi
    mov     rcx, 1073741824
    jmp     .pn_multiply

.pn_T:
    inc     rsi
    cmp     byte [rsi], 'B'
    je      .pn_TB
    cmp     byte [rsi], 'i'
    je      .pn_TiB
    mov     rcx, 1099511627776
    jmp     .pn_multiply
.pn_TB:
    inc     rsi
    mov     rcx, 1000000000000
    jmp     .pn_multiply
.pn_TiB:
    inc     rsi
    cmp     byte [rsi], 'B'
    jne     .pn_error
    inc     rsi
    mov     rcx, 1099511627776
    jmp     .pn_multiply

.pn_P:
    inc     rsi
    cmp     byte [rsi], 'B'
    je      .pn_PB
    cmp     byte [rsi], 'i'
    je      .pn_PiB
    mov     rcx, 1125899906842624
    jmp     .pn_multiply
.pn_PB:
    inc     rsi
    mov     rcx, 1000000000000000
    jmp     .pn_multiply
.pn_PiB:
    inc     rsi
    cmp     byte [rsi], 'B'
    jne     .pn_error
    inc     rsi
    mov     rcx, 1125899906842624
    jmp     .pn_multiply

.pn_E:
    inc     rsi
    cmp     byte [rsi], 'B'
    je      .pn_EB
    cmp     byte [rsi], 'i'
    je      .pn_EiB
    mov     rcx, 1152921504606846976
    jmp     .pn_multiply
.pn_EB:
    inc     rsi
    mov     rcx, 1000000000000000000
    jmp     .pn_multiply
.pn_EiB:
    inc     rsi
    cmp     byte [rsi], 'B'
    jne     .pn_error
    inc     rsi
    mov     rcx, 1152921504606846976
    jmp     .pn_multiply

.pn_multiply:
    mov     rax, rbx
    imul    rax, rcx
    jo      .pn_overflow
    ; Check no trailing chars
    cmp     byte [rsi], 0
    jne     .pn_error

.pn_ok:
    xor     edx, edx                ; success
    pop     r8
    pop     rcx
    pop     rbx
    ret

.pn_overflow:
    ; Use max value on overflow
    mov     rax, -1                 ; u64 max
    xor     edx, edx
    pop     r8
    pop     rcx
    pop     rbx
    ret

.pn_error:
    xor     eax, eax
    mov     edx, 1                  ; error
    pop     r8
    pop     rcx
    pop     rbx
    ret


; ============================================================================
;                       FILE PROCESSING
; ============================================================================

; process_file: Handle one file
; Input: rdi = filename (pointer to string)
process_file:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, STAT_SIZE          ; stat buffer on stack

    mov     r12, rdi                ; r12 = filename

    ; ---- Open file first (before printing header) ----
    mov     rdi, r12
    lea     rsi, [rel str_stdin_marker]
    call    str_eq
    je      .pf_use_stdin

    ; Open the file
    mov     rdi, r12
    xor     esi, esi                ; O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .pf_open_error
    mov     r14, rax                ; r14 = fd
    jmp     .pf_opened

.pf_use_stdin:
    xor     r14d, r14d              ; fd = 0 (stdin)

.pf_opened:
    ; ---- Print header if needed (only after successful open) ----
    cmp     byte [rel show_hdr], 0
    je      .pf_no_header

    ; Blank line between files (not before first)
    cmp     byte [rel first_file], 1
    je      .pf_first_header
    mov     rdi, STDOUT
    lea     rsi, [rel str_newline]
    mov     rdx, 1
    call    asm_write_all
.pf_first_header:
    ; "==> FILENAME <==\n"
    mov     rdi, STDOUT
    lea     rsi, [rel str_hdr_prefix]
    mov     rdx, 4                  ; "==> "
    call    asm_write_all

    ; Display name: "-" becomes "standard input"
    mov     rdi, r12
    lea     rsi, [rel str_stdin_marker]
    call    str_eq
    je      .pf_hdr_stdin
    mov     r13, r12
    jmp     .pf_hdr_name
.pf_hdr_stdin:
    lea     r13, [rel str_standard_input]
.pf_hdr_name:
    mov     rdi, r13
    call    strlen
    mov     rdx, rax
    mov     rdi, STDOUT
    mov     rsi, r13
    call    asm_write_all

    mov     rdi, STDOUT
    lea     rsi, [rel str_hdr_suffix]
    mov     rdx, 5                  ; " <==\n"
    call    asm_write_all
.pf_no_header:
    mov     byte [rel first_file], 0

.pf_have_fd:
    ; ---- fstat to check if regular file ----
    mov     eax, SYS_FSTAT
    mov     rdi, r14
    mov     rsi, rsp                ; stat buffer
    syscall
    test    rax, rax
    js      .pf_not_seekable

    ; Check if regular file: (st_mode & S_IFMT) == S_IFREG
    mov     eax, [rsp + STAT_ST_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFREG
    jne     .pf_not_seekable

    ; Get file size
    mov     r15, [rsp + STAT_ST_SIZE]   ; r15 = file size

    ; ---- Seekable file path ----
    mov     rdi, r14                ; fd
    mov     rsi, r15                ; file_size
    mov     rdx, [rel count]        ; count
    movzx   ecx, byte [rel delimiter]

    cmp     qword [rel mode], MODE_LINES
    je      .pf_seekable_lines
    cmp     qword [rel mode], MODE_LINES_FROM
    je      .pf_seekable_lines_from
    cmp     qword [rel mode], MODE_BYTES
    je      .pf_seekable_bytes
    cmp     qword [rel mode], MODE_BYTES_FROM
    je      .pf_seekable_bytes_from
    jmp     .pf_close

.pf_seekable_lines:
    call    tail_seekable_lines
    jmp     .pf_close

.pf_seekable_lines_from:
    call    tail_seekable_lines_from
    jmp     .pf_close

.pf_seekable_bytes:
    call    tail_seekable_bytes
    jmp     .pf_close

.pf_seekable_bytes_from:
    call    tail_seekable_bytes_from
    jmp     .pf_close

.pf_not_seekable:
    ; ---- Non-seekable (stdin/pipe) path ----
    ; Read all input into memory, then process
    mov     rdi, r14
    call    read_all_input
    ; rax = buffer pointer, rdx = length
    test    rax, rax
    jz      .pf_close               ; read error or empty

    mov     r13, rax                ; r13 = buffer
    mov     r15, rdx                ; r15 = length

    ; Dispatch based on mode
    cmp     qword [rel mode], MODE_LINES
    je      .pf_buf_lines
    cmp     qword [rel mode], MODE_LINES_FROM
    je      .pf_buf_lines_from
    cmp     qword [rel mode], MODE_BYTES
    je      .pf_buf_bytes
    cmp     qword [rel mode], MODE_BYTES_FROM
    je      .pf_buf_bytes_from
    jmp     .pf_buf_done

.pf_buf_lines:
    ; Find start position for last N lines
    mov     rdi, r13                ; buffer
    mov     rsi, r15                ; length
    mov     rdx, [rel count]        ; N
    movzx   ecx, byte [rel delimiter]
    call    backward_scan
    ; rax = offset of start position
    lea     rsi, [r13 + rax]
    mov     rdx, r15
    sub     rdx, rax
    jmp     .pf_buf_write

.pf_buf_lines_from:
    mov     rdi, r13
    mov     rsi, r15
    mov     rdx, [rel count]
    movzx   ecx, byte [rel delimiter]
    call    forward_skip_lines
    ; rax = offset past N-1 delimiters
    lea     rsi, [r13 + rax]
    mov     rdx, r15
    sub     rdx, rax
    jmp     .pf_buf_write

.pf_buf_bytes:
    mov     rax, [rel count]
    cmp     rax, r15
    jae     .pf_buf_bytes_all
    ; Output last N bytes
    mov     rdx, rax
    lea     rsi, [r13 + r15]
    sub     rsi, rdx
    jmp     .pf_buf_write
.pf_buf_bytes_all:
    mov     rsi, r13
    mov     rdx, r15
    jmp     .pf_buf_write

.pf_buf_bytes_from:
    mov     rax, [rel count]
    test    rax, rax
    jz      .pf_buf_bytes_from_all
    dec     rax                     ; 1-indexed: byte N = offset N-1
    cmp     rax, r15
    jae     .pf_buf_done            ; past end
    lea     rsi, [r13 + rax]
    mov     rdx, r15
    sub     rdx, rax
    jmp     .pf_buf_write
.pf_buf_bytes_from_all:
    mov     rsi, r13
    mov     rdx, r15
    jmp     .pf_buf_write

.pf_buf_write:
    test    rdx, rdx
    jz      .pf_buf_done
    mov     rdi, STDOUT
    call    asm_write_all
    cmp     rax, -1
    je      .pf_write_err

.pf_buf_done:
    ; munmap the stdin buffer
    mov     rax, SYS_MUNMAP
    mov     rdi, r13
    mov     rsi, STDIN_ALLOC
    syscall
    jmp     .pf_close

.pf_open_error:
    ; "tail: cannot open 'FILE' for reading: ERROR"
    mov     byte [rel had_error], 1
    lea     rdi, [rel err_open_prefix]
    call    write_str_stderr
    mov     rdi, r12
    call    write_str_stderr
    lea     rdi, [rel err_open_suffix]
    call    write_str_stderr
    jmp     .pf_return

.pf_write_err:
    mov     byte [rel had_error], 1
    jmp     .pf_close

.pf_close:
    ; Close file if not stdin
    test    r14, r14
    jz      .pf_return
    mov     rdi, r14
    call    asm_close

.pf_return:
    add     rsp, STAT_SIZE
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;               SEEKABLE FILE TAIL OPERATIONS
; ============================================================================

; tail_seekable_lines: Output last N lines of a seekable file
; Input: rdi=fd, rsi=file_size, rdx=N, ecx=delimiter
tail_seekable_lines:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     rbx, rdi                ; fd
    mov     r12, rsi                ; file_size
    mov     r13, rdx                ; N (lines wanted)
    mov     r14d, ecx               ; delimiter

    ; If N == 0, output nothing
    test    r13, r13
    jz      .tsl_done

    ; If file is empty, output nothing
    test    r12, r12
    jz      .tsl_done

    ; Start scanning from end of file
    mov     r15, r12                ; r15 = current scan position
    xor     ebp, ebp                ; rbp = newlines found
    mov     byte [rel skip_trailing], 1  ; skip trailing delimiter

.tsl_chunk_loop:
    ; Calculate chunk: [chunk_start, r15)
    mov     rax, r15
    sub     rax, RDBUF_SZ
    jns     .tsl_chunk_start_ok
    xor     eax, eax                ; chunk_start = 0
.tsl_chunk_start_ok:
    mov     rcx, r15
    sub     rcx, rax                ; chunk_len = r15 - chunk_start
    test    rcx, rcx
    jz      .tsl_output_all

    push    rax                     ; save chunk_start
    push    rcx                     ; save chunk_len

    ; lseek(fd, chunk_start, SEEK_SET)
    mov     rdi, rbx
    mov     rsi, rax
    mov     edx, SEEK_SET
    mov     eax, SYS_LSEEK
    syscall

    ; read(fd, rdbuf, chunk_len)
    pop     rdx                     ; chunk_len
    push    rdx
    mov     rdi, rbx
    lea     rsi, [rel rdbuf]
    mov     eax, SYS_READ
    syscall

    pop     rcx                     ; chunk_len
    pop     r8                      ; chunk_start

    ; Scan backward through the chunk for delimiters
    lea     rdi, [rel rdbuf]
    ; Start from end of chunk
    mov     rsi, rcx                ; rsi = scan position (starts at end)

    ; If skip_trailing and this is the first chunk, skip last byte if delimiter
    cmp     byte [rel skip_trailing], 0
    je      .tsl_scan_loop
    mov     byte [rel skip_trailing], 0
    dec     rsi
    cmp     rsi, 0
    jl      .tsl_scan_chunk_done
    movzx   eax, byte [rdi + rsi]
    cmp     al, r14b
    jne     .tsl_scan_loop          ; last byte wasn't delimiter, continue
    ; Last byte was delimiter, we already decremented rsi

.tsl_scan_loop:
    test    rsi, rsi
    jz      .tsl_scan_chunk_done
    dec     rsi
    movzx   eax, byte [rdi + rsi]
    cmp     al, r14b
    jne     .tsl_scan_loop
    ; Found a delimiter
    inc     ebp                     ; newlines_found++
    cmp     rbp, r13
    jge     .tsl_found_position
    jmp     .tsl_scan_loop

.tsl_scan_chunk_done:
    mov     r15, r8                 ; r15 = chunk_start (move to previous chunk)
    test    r15, r15
    jnz     .tsl_chunk_loop

.tsl_output_all:
    ; Fewer than N lines in file → output entire file
    xor     r8d, r8d                ; output_start = 0
    jmp     .tsl_output

.tsl_found_position:
    ; The Nth delimiter is at chunk_start + rsi
    ; Output starts at chunk_start + rsi + 1
    lea     r8, [r8 + rsi + 1]     ; output_start

.tsl_output:
    ; lseek(fd, output_start, SEEK_SET)
    mov     rdi, rbx
    mov     rsi, r8
    mov     edx, SEEK_SET
    mov     eax, SYS_LSEEK
    syscall

    ; Copy from fd to stdout
    mov     rdi, rbx
    call    copy_fd_to_stdout

.tsl_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; tail_seekable_bytes: Output last N bytes of a seekable file
; Input: rdi=fd, rsi=file_size, rdx=N, ecx=delimiter(unused)
tail_seekable_bytes:
    push    rbx
    push    r12

    mov     rbx, rdi                ; fd
    mov     r12, rsi                ; file_size

    ; If N == 0, nothing
    test    rdx, rdx
    jz      .tsb_done

    ; offset = max(0, file_size - N)
    mov     rax, r12
    sub     rax, rdx
    jns     .tsb_seek
    xor     eax, eax                ; clamp to 0
.tsb_seek:
    mov     rdi, rbx
    mov     rsi, rax
    mov     edx, SEEK_SET
    mov     eax, SYS_LSEEK
    syscall

    mov     rdi, rbx
    call    copy_fd_to_stdout

.tsb_done:
    pop     r12
    pop     rbx
    ret


; tail_seekable_lines_from: Output from line N of a seekable file
; Input: rdi=fd, rsi=file_size, rdx=N, ecx=delimiter
tail_seekable_lines_from:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     rbx, rdi                ; fd
    mov     r12, rsi                ; file_size
    mov     r13, rdx                ; N
    mov     r14d, ecx               ; delimiter

    ; If N <= 1, output entire file
    cmp     r13, 1
    jbe     .tslf_all

    ; Need to skip N-1 delimiters from start
    dec     r13                     ; skip count = N-1

    ; lseek to start
    mov     rdi, rbx
    xor     esi, esi
    mov     edx, SEEK_SET
    mov     eax, SYS_LSEEK
    syscall

    xor     r15d, r15d              ; delimiters found

.tslf_read_loop:
    mov     rdi, rbx
    lea     rsi, [rel rdbuf]
    mov     edx, RDBUF_SZ
    call    asm_read
    test    rax, rax
    jle     .tslf_done              ; EOF or error

    ; Scan forward for delimiters
    lea     rdi, [rel rdbuf]
    xor     ecx, ecx                ; position in buffer

.tslf_scan:
    cmp     rcx, rax
    jge     .tslf_read_loop         ; consumed entire chunk
    movzx   edx, byte [rdi + rcx]
    inc     rcx
    cmp     dl, r14b
    jne     .tslf_scan
    ; Found delimiter
    inc     r15
    cmp     r15, r13
    jge     .tslf_found
    jmp     .tslf_scan

.tslf_found:
    ; Remaining data in buffer: [rcx..rax)
    mov     rdx, rax
    sub     rdx, rcx
    test    rdx, rdx
    jz      .tslf_copy_rest

    ; Write remaining buffer
    lea     rsi, [rel rdbuf]
    add     rsi, rcx
    mov     rdi, STDOUT
    call    asm_write_all

.tslf_copy_rest:
    ; Copy rest of file
    mov     rdi, rbx
    call    copy_fd_to_stdout
    jmp     .tslf_done

.tslf_all:
    ; Output entire file from beginning
    mov     rdi, rbx
    xor     esi, esi
    mov     edx, SEEK_SET
    mov     eax, SYS_LSEEK
    syscall
    mov     rdi, rbx
    call    copy_fd_to_stdout

.tslf_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; tail_seekable_bytes_from: Output from byte N of a seekable file
; Input: rdi=fd, rsi=file_size, rdx=N, ecx=delimiter(unused)
tail_seekable_bytes_from:
    push    rbx

    mov     rbx, rdi                ; fd

    ; offset = N-1, clamped to file_size
    mov     rax, rdx
    test    rax, rax
    jz      .tsbf_zero
    dec     rax
    cmp     rax, rsi
    jbe     .tsbf_seek
    ; Past end → nothing to output
    pop     rbx
    ret

.tsbf_zero:
    ; N=0 → from byte 0 (same as entire file)
    xor     eax, eax

.tsbf_seek:
    mov     rdi, rbx
    mov     rsi, rax
    mov     edx, SEEK_SET
    mov     eax, SYS_LSEEK
    syscall

    mov     rdi, rbx
    call    copy_fd_to_stdout

    pop     rbx
    ret


; ============================================================================
;               NON-SEEKABLE INPUT HANDLING
; ============================================================================

; read_all_input: Read all data from fd into mmap'd buffer
; Input: rdi = fd
; Output: rax = buffer pointer (or 0 on error), rdx = total bytes read
read_all_input:
    push    rbx
    push    r12
    push    r13

    mov     rbx, rdi                ; fd

    ; mmap anonymous memory
    mov     eax, SYS_MMAP
    xor     edi, edi                ; addr = NULL
    mov     esi, STDIN_ALLOC        ; 256MB
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8d, -1
    xor     r9d, r9d
    syscall
    cmp     rax, -1
    je      .rai_error
    mov     r12, rax                ; r12 = buffer base
    xor     r13d, r13d              ; r13 = total bytes read

.rai_loop:
    ; Check remaining space
    mov     rax, STDIN_ALLOC
    sub     rax, r13
    cmp     rax, RDBUF_SZ
    jl      .rai_small_read
    mov     edx, RDBUF_SZ
    jmp     .rai_do_read
.rai_small_read:
    test    rax, rax
    jz      .rai_done               ; buffer full
    mov     rdx, rax

.rai_do_read:
    mov     rdi, rbx
    lea     rsi, [r12 + r13]
    call    asm_read
    test    rax, rax
    jle     .rai_done               ; EOF or error
    add     r13, rax
    jmp     .rai_loop

.rai_done:
    mov     rax, r12
    mov     rdx, r13
    pop     r13
    pop     r12
    pop     rbx
    ret

.rai_error:
    xor     eax, eax
    xor     edx, edx
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;               BUFFER SCANNING FUNCTIONS
; ============================================================================

; backward_scan: Find start position for last N delimited lines in buffer
; Input: rdi=buf, rsi=length, rdx=N, ecx=delimiter
; Output: rax=offset where output should start
backward_scan:
    push    rbx
    push    r12
    push    r13

    mov     rbx, rdi                ; buf
    mov     r12, rsi                ; length
    mov     r13, rdx                ; N
    ; ecx = delimiter

    ; If N == 0, return length (output nothing)
    test    r13, r13
    jz      .bs_return_end

    ; If buffer empty, return 0
    test    r12, r12
    jz      .bs_return_start

    ; Start position = length
    mov     rsi, r12
    xor     edx, edx                ; count of delimiters found

    ; Skip trailing delimiter
    dec     rsi
    movzx   eax, byte [rbx + rsi]
    cmp     al, cl
    jne     .bs_scan_start          ; not a delimiter, don't skip
    ; Was a delimiter, we already decremented rsi

.bs_scan_start:
    ; ---- SSE2 optimized backward scan ----
    ; Fill xmm0 with delimiter byte
    movd    xmm0, ecx
    punpcklbw xmm0, xmm0
    punpcklwd xmm0, xmm0
    pshufd  xmm0, xmm0, 0          ; xmm0 = delimiter × 16

.bs_simd_loop:
    cmp     rsi, 16
    jl      .bs_scalar

    sub     rsi, 16
    movdqu  xmm1, [rbx + rsi]
    pcmpeqb xmm1, xmm0
    pmovmskb eax, xmm1

    test    eax, eax
    jz      .bs_simd_loop           ; no matches in this block

    ; Count matches using popcnt
    popcnt  r8d, eax
    add     edx, r8d
    cmp     edx, r13d
    jl      .bs_simd_loop           ; not enough yet

    ; The "excess" bits are at the LOW end of the mask (closest to
    ; start of file). Skip them, then the next lowest bit is the
    ; Nth delimiter from end of file.
    sub     edx, r13d               ; excess = total - N (skip from LOW end)
    mov     r8d, edx

.bs_find_bit:
    test    r8d, r8d
    jz      .bs_found_bit
    bsf     ecx, eax                ; find LOWEST set bit
    btr     eax, ecx                ; clear it
    dec     r8d
    jmp     .bs_find_bit

.bs_found_bit:
    bsf     ecx, eax                ; LOWEST remaining = Nth delimiter from end
    lea     rax, [rsi + rcx + 1]    ; output starts after this delimiter
    jmp     .bs_done

.bs_scalar:
    ; Scalar fallback for remaining bytes
    test    rsi, rsi
    jz      .bs_return_start

    dec     rsi
    movzx   eax, byte [rbx + rsi]
    movzx   r8d, byte [rel delimiter]   ; reload delimiter (ecx may be clobbered)
    cmp     al, r8b
    jne     .bs_scalar
    ; Found delimiter
    inc     edx
    cmp     edx, r13d
    jge     .bs_scalar_found
    jmp     .bs_scalar

.bs_scalar_found:
    ; Output starts at rsi + 1
    lea     rax, [rsi + 1]
    jmp     .bs_done

.bs_return_start:
    xor     eax, eax                ; output entire buffer
    jmp     .bs_done

.bs_return_end:
    mov     rax, r12                ; output nothing

.bs_done:
    pop     r13
    pop     r12
    pop     rbx
    ret


; forward_skip_lines: Skip N-1 delimiters from start, return offset
; Input: rdi=buf, rsi=length, rdx=N, ecx=delimiter
; Output: rax=offset past (N-1) delimiters
forward_skip_lines:
    push    rbx
    push    r12

    mov     rbx, rdi                ; buf
    mov     r12, rsi                ; length

    ; If N <= 1, return 0 (output from start)
    cmp     rdx, 1
    jbe     .fsl_start

    dec     rdx                     ; skip count = N-1
    xor     eax, eax                ; position

    ; SSE2 forward scan
    movd    xmm0, ecx
    punpcklbw xmm0, xmm0
    punpcklwd xmm0, xmm0
    pshufd  xmm0, xmm0, 0

.fsl_simd_loop:
    mov     rcx, r12
    sub     rcx, rax
    cmp     rcx, 16
    jl      .fsl_scalar

    movdqu  xmm1, [rbx + rax]
    pcmpeqb xmm1, xmm0
    pmovmskb ecx, xmm1

    test    ecx, ecx
    jz      .fsl_simd_advance       ; no matches

    ; Count matches
    popcnt  r8d, ecx
    cmp     r8, rdx
    jge     .fsl_simd_exact         ; found enough

    sub     rdx, r8
    add     rax, 16
    jmp     .fsl_simd_loop

.fsl_simd_advance:
    add     rax, 16
    jmp     .fsl_simd_loop

.fsl_simd_exact:
    ; Find the rdx-th lowest set bit in ecx (the mask).
    ; rdx = remaining delimiters to skip (1-indexed)
    mov     r9d, ecx                ; r9d = mask

.fsl_bit_loop:
    bsf     ecx, r9d               ; ecx = lowest set bit position
    dec     rdx
    jz      .fsl_bit_found
    btr     r9d, ecx               ; clear this bit
    jmp     .fsl_bit_loop

.fsl_bit_found:
    ; ecx = bit position of the delimiter we want
    ; Output starts at rax + ecx + 1
    add     rax, rcx
    inc     rax
    jmp     .fsl_done

.fsl_scalar:
    cmp     rax, r12
    jge     .fsl_past_end
    movzx   ecx, byte [rbx + rax]
    inc     rax
    movzx   r8d, byte [rel delimiter]
    cmp     cl, r8b
    jne     .fsl_scalar
    dec     rdx
    jz      .fsl_done
    jmp     .fsl_scalar

.fsl_past_end:
    mov     rax, r12                ; past end → output nothing

.fsl_done:
    pop     r12
    pop     rbx
    ret

.fsl_start:
    xor     eax, eax
    pop     r12
    pop     rbx
    ret


; ============================================================================
;                    UTILITY FUNCTIONS
; ============================================================================

; copy_fd_to_stdout: Read from fd and write to stdout until EOF
; Input: rdi = fd
copy_fd_to_stdout:
    push    rbx
    mov     rbx, rdi                ; fd

.cfs_loop:
    mov     rdi, rbx
    lea     rsi, [rel rdbuf]
    mov     edx, RDBUF_SZ
    call    asm_read
    test    rax, rax
    jle     .cfs_done               ; EOF or error

    mov     rdx, rax                ; bytes to write
    mov     rdi, STDOUT
    lea     rsi, [rel rdbuf]
    call    asm_write_all
    cmp     rax, -1
    je      .cfs_done               ; write error (EPIPE etc)
    jmp     .cfs_loop

.cfs_done:
    pop     rbx
    ret


; strlen: Get length of null-terminated string
; Input: rdi = string pointer
; Output: rax = length
strlen:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret


; write_str_stderr: Write null-terminated string to stderr
; Input: rdi = string pointer
write_str_stderr:
    push    rdi
    call    strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDERR
    call    asm_write_all
    ret


; ============================================================================
;                         DATA SECTION
; ============================================================================
section .rodata

str_stdin_marker:   db "-", 0
str_standard_input: db "standard input", 0
str_newline:        db 10
str_hdr_prefix:     db "==> ", 0
str_hdr_suffix:     db " <==", 10, 0

; Help text
help_text:
    db "Usage: tail [OPTION]... [FILE]...", 10
    db "Print the last 10 lines of each FILE to standard output.", 10
    db "With more than one FILE, precede each with a header giving the file name.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -c, --bytes=[+]NUM       output the last NUM bytes; or use -c +NUM to", 10
    db "                             output starting with byte NUM of each file", 10
    db "  -f, --follow[={name|descriptor}]", 10
    db "                           output appended data as the file grows;", 10
    db "                             an absent option argument means 'descriptor'", 10
    db "  -F                       same as --follow=name --retry", 10
    db "  -n, --lines=[+]NUM       output the last NUM lines, instead of the last 10;", 10
    db "                             or use -n +NUM to output starting with line NUM", 10
    db "      --max-unchanged-stats=N", 10
    db "                           with --follow=name, reopen a FILE which has not", 10
    db "                             changed size after N (default 5) iterations", 10
    db "      --pid=PID            with -f, terminate after process ID, PID dies", 10
    db "  -q, --quiet, --silent    never output headers giving file names", 10
    db "      --retry              keep trying to open a file if it is inaccessible", 10
    db "  -s, --sleep-interval=N   with -f, sleep for approximately N seconds", 10
    db "                             (default 1.0) between iterations", 10
    db "  -v, --verbose            always output headers giving file names", 10
    db "  -z, --zero-terminated    line delimiter is NUL, not newline", 10
    db "      --help               display this help and exit", 10
    db "      --version            output version information and exit", 10
    db 10
    db "NUM may have a multiplier suffix:", 10
    db "b 512, kB 1000, K 1024, MB 1000*1000, M 1024*1024,", 10
    db "GB 1000*1000*1000, G 1024*1024*1024, and so on for T, P, E, Z, Y.", 10
    db "Binary prefixes can be used, too: KiB=K, MiB=M, and so on.", 10
help_text_len equ $ - help_text

; Version text
version_text:
    db "tail (fcoreutils) 0.1.0", 10
version_text_len equ $ - version_text

; Long option strings for comparison
str_help_opt:       db "--help", 0
str_version_opt:    db "--version", 0
str_lines_prefix:   db "--lines", 0
str_bytes_prefix:   db "--bytes", 0
str_quiet_opt:      db "--quiet", 0
str_silent_opt:     db "--silent", 0
str_verbose_opt:    db "--verbose", 0
str_zero_opt:       db "--zero-terminated", 0
str_follow_prefix:  db "--follow=", 0
str_follow_opt:     db "--follow", 0
str_retry_opt:      db "--retry", 0
str_pid_prefix:     db "--pid=", 0
str_pid_opt:        db "--pid", 0
str_sleep_prefix:   db "--sleep-interval=", 0
str_sleep_opt:      db "--sleep-interval", 0
str_maxu_prefix:    db "--max-unchanged-stats=", 0
str_maxu_opt:       db "--max-unchanged-stats", 0

; Error messages
err_inval_prefix:   db "tail: invalid option -- '", 0
err_inval_suffix:   db "'", 10, "Try 'tail --help' for more information.", 10, 0
err_unrec_prefix:   db "tail: unrecognized option '", 0
err_unrec_suffix:   db "'", 10, "Try 'tail --help' for more information.", 10, 0
err_n_requires:     db "tail: option requires an argument -- 'n'", 10, 0
err_c_requires:     db "tail: option requires an argument -- 'c'", 10, 0
err_lines_requires: db "tail: option '--lines' requires an argument", 10, 0
err_bytes_requires: db "tail: option '--bytes' requires an argument", 10, 0
err_bad_lines_prefix: db "tail: invalid number of lines: '", 0
err_bad_lines_suffix: db "'", 10, 0
err_bad_bytes_prefix: db "tail: invalid number of bytes: '", 0
err_bad_bytes_suffix: db "'", 10, 0
err_open_prefix:    db "tail: cannot open '", 0
err_open_suffix:    db "' for reading: No such file or directory", 10, 0


; ============================================================================
;                         BSS SECTION
; ============================================================================
section .bss

; State variables
mode:           resq 1
count:          resq 1
delimiter:      resb 1
quiet:          resb 1
verbose:        resb 1
had_error:      resb 1
first_file:     resb 1
show_hdr:       resb 1
skip_trailing:  resb 1
            alignb 8
file_count:     resq 1
argc:           resq 1
argv_base:      resq 1
file_ptrs:      resq MAX_FILES

; Buffers
rdbuf:          resb RDBUF_SZ

section .note.GNU-stack noalloc noexec nowrite progbits
