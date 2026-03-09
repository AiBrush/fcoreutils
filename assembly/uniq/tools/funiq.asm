; funiq.asm — GNU-compatible "uniq" in x86_64 Linux assembly
;
; Filter adjacent matching lines from INPUT (or stdin), writing to OUTPUT (or stdout).
; Supports all GNU uniq flags:
;   -c / --count           prefix lines with count
;   -d / --repeated        only print duplicate lines (one each)
;   -D                     print all duplicate lines
;   --all-repeated[=METHOD]  like -D with grouping (none/prepend/separate)
;   -u / --unique          only print unique lines
;   -i / --ignore-case     case-insensitive compare
;   -f N / --skip-fields=N skip N fields before comparing
;   -s N / --skip-chars=N  skip N chars after field skipping
;   -w N / --check-chars=N compare at most N chars
;   --group[=METHOD]       show all items with group separators
;   -z / --zero-terminated NUL delimiter instead of newline
;   --help / --version
;
; Performance optimizations:
;   - mmap() for file input (zero-copy, no read syscalls)
;   - SSE2 SIMD newline scanning (16 bytes at a time)
;   - SSE2 SIMD line comparison (16 bytes at a time)
;   - Zero-copy output (write directly from mmap'd buffer)
;   - Large output buffer with threshold flushing
;
; Build (modular):
;   nasm -f elf64 -I include/ tools/funiq.asm -o build/tools/funiq.o
;   nasm -f elf64 -I include/ lib/io.asm -o build/lib/io.o
;   ld --gc-sections -n build/tools/funiq.o build/lib/io.o -o funiq

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close

; ─── Constants ───────────────────────────────────────────
%define READ_BUF_SIZE   131072          ; 128KB input buffer (stdin fallback)
%define OUT_BUF_SIZE    1048576         ; 1MB output buffer
%define LINE_BUF_SIZE   1048576         ; 1MB max line length (stdin fallback)
%define FLUSH_THRESHOLD 786432          ; Flush at 768KB

; mmap constants
%define PROT_READ       1
%define MAP_PRIVATE     2
%define MAP_POPULATE    0x08000         ; Populate page tables (prefault)
%define MADV_SEQUENTIAL 2
%define MADV_WILLNEED   3
%define SYS_MADVISE     28

; Mode constants
%define MODE_NORMAL      0              ; default: merge adjacent duplicates
%define MODE_COUNT       1              ; -c: prefix with count
%define MODE_REPEATED    2              ; -d: only duplicated lines (once each)
%define MODE_ALL_REPEAT  3              ; -D/--all-repeated: all duplicate lines
%define MODE_UNIQUE      4              ; -u: only unique lines
%define MODE_GROUP       5              ; --group: show all with separators

; --all-repeated method
%define ALLREP_NONE      0
%define ALLREP_PREPEND   1
%define ALLREP_SEPARATE  2

; --group method
%define GROUP_SEPARATE   0
%define GROUP_PREPEND    1
%define GROUP_APPEND     2
%define GROUP_BOTH       3

global _start

section .text

; ─── Entry Point ─────────────────────────────────────────
_start:
    ; Set up SIGPIPE to SIG_DFL (default = terminate)
    mov     rax, SYS_RT_SIGACTION
    mov     rdi, SIGPIPE
    lea     rsi, [rel sigact_buf]
    xor     rdx, rdx
    mov     r10, 8
    syscall

    ; Parse argc/argv from stack
    mov     r14, [rsp]              ; argc
    lea     r15, [rsp + 8]          ; argv[0]

    ; Initialize global state
    xor     ebp, ebp                ; had_error = 0
    xor     r12d, r12d              ; out_buf_used = 0

    ; Initialize options to defaults
    mov     byte [rel opt_mode], MODE_NORMAL
    mov     byte [rel opt_flag_d], 0
    mov     byte [rel opt_flag_u], 0
    mov     byte [rel opt_count], 0
    mov     byte [rel opt_case_insensitive], 0
    mov     byte [rel opt_zero_terminated], 0
    mov     qword [rel opt_skip_fields], 0
    mov     qword [rel opt_skip_chars], 0
    mov     qword [rel opt_check_chars], -1     ; -1 = unlimited
    mov     byte [rel opt_allrep_method], ALLREP_NONE
    mov     byte [rel opt_group_method], GROUP_SEPARATE
    mov     qword [rel input_file], 0
    mov     qword [rel output_file], 0
    mov     qword [rel mmap_addr], 0
    mov     qword [rel mmap_len], 0

    ; Parse arguments (skip argv[0])
    mov     rbx, 1                  ; arg index
    xor     ecx, ecx                ; seen_dashdash = 0

.parse_loop:
    cmp     rbx, r14
    jge     .parse_done

    mov     rsi, [r15 + rbx*8]      ; argv[i]

    ; If we've seen --, treat as operand
    test    ecx, ecx
    jnz     .is_operand

    ; Check for '-' prefix
    cmp     byte [rsi], '-'
    jne     .is_operand
    cmp     byte [rsi+1], 0
    je      .is_operand             ; bare "-" is operand (stdin)

    cmp     byte [rsi+1], '-'
    je      .long_option

    ; Short option(s): -c, -d, -D, -u, -i, -f, -s, -w, -z
    ; Can be combined: -ci, -du, etc.
    lea     rdi, [rsi + 1]          ; skip the '-'
    jmp     .parse_short_opts

.parse_short_opts:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .parse_next             ; end of short opts

    cmp     al, 'c'
    je      .short_c
    cmp     al, 'd'
    je      .short_d
    cmp     al, 'D'
    je      .short_D
    cmp     al, 'u'
    je      .short_u
    cmp     al, 'i'
    je      .short_i
    cmp     al, 'z'
    je      .short_z
    cmp     al, 'f'
    je      .short_f
    cmp     al, 's'
    je      .short_s
    cmp     al, 'w'
    je      .short_w

    ; Unknown short option
    push    rcx
    push    rbx
    mov     rsi, [r15 + rbx*8]
    call    err_invalid_option
    mov     ebp, 1
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.short_c:
    mov     byte [rel opt_count], 1
    inc     rdi
    jmp     .parse_short_opts

.short_d:
    mov     byte [rel opt_mode], MODE_REPEATED
    mov     byte [rel opt_flag_d], 1
    inc     rdi
    jmp     .parse_short_opts

.short_D:
    mov     byte [rel opt_mode], MODE_ALL_REPEAT
    mov     byte [rel opt_allrep_method], ALLREP_NONE
    inc     rdi
    jmp     .parse_short_opts

.short_u:
    mov     byte [rel opt_mode], MODE_UNIQUE
    mov     byte [rel opt_flag_u], 1
    inc     rdi
    jmp     .parse_short_opts

.short_i:
    mov     byte [rel opt_case_insensitive], 1
    inc     rdi
    jmp     .parse_short_opts

.short_z:
    mov     byte [rel opt_zero_terminated], 1
    inc     rdi
    jmp     .parse_short_opts

.short_f:
    ; -f N: next chars or next arg is N
    inc     rdi
    cmp     byte [rdi], 0
    jne     .short_f_inline
    ; Value is next arg
    inc     rbx
    cmp     rbx, r14
    jge     .err_missing_arg_f
    mov     rdi, [r15 + rbx*8]
.short_f_inline:
    call    parse_number
    test    rax, rax
    js      .err_invalid_number_f
    mov     [rel opt_skip_fields], rax
    jmp     .parse_next

.short_s:
    ; -s N
    inc     rdi
    cmp     byte [rdi], 0
    jne     .short_s_inline
    inc     rbx
    cmp     rbx, r14
    jge     .err_missing_arg_s
    mov     rdi, [r15 + rbx*8]
.short_s_inline:
    call    parse_number
    test    rax, rax
    js      .err_invalid_number_s
    mov     [rel opt_skip_chars], rax
    jmp     .parse_next

.short_w:
    ; -w N
    inc     rdi
    cmp     byte [rdi], 0
    jne     .short_w_inline
    inc     rbx
    cmp     rbx, r14
    jge     .err_missing_arg_w
    mov     rdi, [r15 + rbx*8]
.short_w_inline:
    call    parse_number
    test    rax, rax
    js      .err_invalid_number_w
    mov     [rel opt_check_chars], rax
    jmp     .parse_next

.long_option:
    ; Starts with "--"
    cmp     byte [rsi+2], 0
    je      .set_dashdash           ; exactly "--"

    ; Check long options
    push    rcx
    push    rbx

    ; --help
    lea     rdi, [rel str_help_opt]
    call    strcmp
    test    eax, eax
    jz      .do_help_pop

    ; --version
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_version_opt]
    call    strcmp
    test    eax, eax
    jz      .do_version_pop

    ; --count
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_count_opt]
    call    strcmp
    test    eax, eax
    jz      .long_count

    ; --repeated
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_repeated_opt]
    call    strcmp
    test    eax, eax
    jz      .long_repeated

    ; --all-repeated (with optional =METHOD)
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_allrep_prefix]
    mov     rcx, 14                 ; strlen("--all-repeated") = 14
    call    strncmp
    test    eax, eax
    jz      .long_allrep_check

    ; --unique
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_unique_opt]
    call    strcmp
    test    eax, eax
    jz      .long_unique

    ; --ignore-case
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_ignorecase_opt]
    call    strcmp
    test    eax, eax
    jz      .long_ignorecase

    ; --skip-fields=N
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_skipfields_prefix]
    mov     rcx, 14                 ; strlen("--skip-fields=") = 14
    call    strncmp
    test    eax, eax
    jz      .long_skipfields

    ; --skip-chars=N
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_skipchars_prefix]
    mov     rcx, 13                 ; strlen("--skip-chars=") = 13
    call    strncmp
    test    eax, eax
    jz      .long_skipchars

    ; --check-chars=N
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_checkchars_prefix]
    mov     rcx, 14                 ; strlen("--check-chars=") = 14
    call    strncmp
    test    eax, eax
    jz      .long_checkchars

    ; --zero-terminated
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_zeroterm_opt]
    call    strcmp
    test    eax, eax
    jz      .long_zeroterm

    ; --group (with optional =METHOD)
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_group_prefix]
    mov     rcx, 7                  ; strlen("--group")
    call    strncmp
    test    eax, eax
    jz      .long_group_check

    ; --skip-fields N (space-separated)
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_skipfields_opt]
    call    strcmp
    test    eax, eax
    jz      .long_skipfields_space

    ; --skip-chars N (space-separated)
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_skipchars_opt]
    call    strcmp
    test    eax, eax
    jz      .long_skipchars_space

    ; --check-chars N (space-separated)
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_checkchars_opt]
    call    strcmp
    test    eax, eax
    jz      .long_checkchars_space

    ; Unknown long option
    pop     rbx
    pop     rcx
    push    rcx
    push    rbx
    mov     rsi, [r15 + rbx*8]
    call    err_unrecognized_option
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.long_count:
    pop     rbx
    pop     rcx
    mov     byte [rel opt_count], 1
    jmp     .parse_next

.long_repeated:
    pop     rbx
    pop     rcx
    mov     byte [rel opt_mode], MODE_REPEATED
    mov     byte [rel opt_flag_d], 1
    jmp     .parse_next

.long_allrep_check:
    ; rsi points to argv[i]. Check if it's exactly "--all-repeated" or "--all-repeated=..."
    mov     rsi, [r15 + rbx*8]
    cmp     byte [rsi+14], 0        ; "--all-repeated" is 14 chars
    je      .long_allrep_none
    cmp     byte [rsi+14], '='
    jne     .long_allrep_unknown
    ; Parse method after '='
    lea     rdi, [rsi+15]
    ; Check "none"
    push    rdi
    lea     rsi, [rel str_method_none]
    mov     rdi, [rsp]
    xchg    rdi, rsi
    call    strcmp
    test    eax, eax
    pop     rdi
    jz      .long_allrep_none
    ; Check "prepend"
    push    rdi
    lea     rsi, [rel str_method_prepend]
    mov     rdi, [rsp]
    xchg    rdi, rsi
    call    strcmp
    test    eax, eax
    pop     rdi
    jz      .long_allrep_prepend
    ; Check "separate"
    push    rdi
    lea     rsi, [rel str_method_separate]
    mov     rdi, [rsp]
    xchg    rdi, rsi
    call    strcmp
    test    eax, eax
    pop     rdi
    jz      .long_allrep_separate
.long_allrep_unknown:
    ; Invalid method
    pop     rbx
    pop     rcx
    lea     rdi, [rel str_invalid_allrep]
    call    print_error_msg
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.long_allrep_none:
    pop     rbx
    pop     rcx
    mov     byte [rel opt_mode], MODE_ALL_REPEAT
    mov     byte [rel opt_allrep_method], ALLREP_NONE
    jmp     .parse_next

.long_allrep_prepend:
    pop     rbx
    pop     rcx
    mov     byte [rel opt_mode], MODE_ALL_REPEAT
    mov     byte [rel opt_allrep_method], ALLREP_PREPEND
    jmp     .parse_next

.long_allrep_separate:
    pop     rbx
    pop     rcx
    mov     byte [rel opt_mode], MODE_ALL_REPEAT
    mov     byte [rel opt_allrep_method], ALLREP_SEPARATE
    jmp     .parse_next

.long_unique:
    pop     rbx
    pop     rcx
    mov     byte [rel opt_mode], MODE_UNIQUE
    mov     byte [rel opt_flag_u], 1
    jmp     .parse_next

.long_ignorecase:
    pop     rbx
    pop     rcx
    mov     byte [rel opt_case_insensitive], 1
    jmp     .parse_next

.long_skipfields:
    ; "--skip-fields=N" - value starts at rsi+14
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rsi+14]
    call    parse_number
    test    rax, rax
    js      .long_skipfields_err
    mov     [rel opt_skip_fields], rax
    pop     rbx
    pop     rcx
    jmp     .parse_next
.long_skipfields_err:
    pop     rbx
    pop     rcx
    jmp     .err_invalid_number_f

.long_skipfields_space:
    ; "--skip-fields" N (next arg)
    pop     rbx
    pop     rcx
    inc     rbx
    cmp     rbx, r14
    jge     .err_missing_arg_f
    mov     rdi, [r15 + rbx*8]
    call    parse_number
    test    rax, rax
    js      .err_invalid_number_f
    mov     [rel opt_skip_fields], rax
    jmp     .parse_next

.long_skipchars:
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rsi+13]
    call    parse_number
    test    rax, rax
    js      .long_skipchars_err
    mov     [rel opt_skip_chars], rax
    pop     rbx
    pop     rcx
    jmp     .parse_next
.long_skipchars_err:
    pop     rbx
    pop     rcx
    jmp     .err_invalid_number_s

.long_skipchars_space:
    pop     rbx
    pop     rcx
    inc     rbx
    cmp     rbx, r14
    jge     .err_missing_arg_s
    mov     rdi, [r15 + rbx*8]
    call    parse_number
    test    rax, rax
    js      .err_invalid_number_s
    mov     [rel opt_skip_chars], rax
    jmp     .parse_next

.long_checkchars:
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rsi+14]
    call    parse_number
    test    rax, rax
    js      .long_checkchars_err
    mov     [rel opt_check_chars], rax
    pop     rbx
    pop     rcx
    jmp     .parse_next
.long_checkchars_err:
    pop     rbx
    pop     rcx
    jmp     .err_invalid_number_w

.long_checkchars_space:
    pop     rbx
    pop     rcx
    inc     rbx
    cmp     rbx, r14
    jge     .err_missing_arg_w
    mov     rdi, [r15 + rbx*8]
    call    parse_number
    test    rax, rax
    js      .err_invalid_number_w
    mov     [rel opt_check_chars], rax
    jmp     .parse_next

.long_zeroterm:
    pop     rbx
    pop     rcx
    mov     byte [rel opt_zero_terminated], 1
    jmp     .parse_next

.long_group_check:
    ; rsi = argv[i]. Check if exactly "--group" or "--group=..."
    mov     rsi, [r15 + rbx*8]
    cmp     byte [rsi+7], 0
    je      .long_group_default
    cmp     byte [rsi+7], '='
    jne     .long_group_unknown_opt
    ; Parse method after '='
    lea     rdi, [rsi+8]
    ; Check "separate"
    push    rdi
    lea     rsi, [rel str_method_separate]
    mov     rdi, [rsp]
    xchg    rdi, rsi
    call    strcmp
    test    eax, eax
    pop     rdi
    jz      .long_group_separate
    ; Check "prepend"
    push    rdi
    lea     rsi, [rel str_method_prepend]
    mov     rdi, [rsp]
    xchg    rdi, rsi
    call    strcmp
    test    eax, eax
    pop     rdi
    jz      .long_group_prepend
    ; Check "append"
    push    rdi
    lea     rsi, [rel str_method_append]
    mov     rdi, [rsp]
    xchg    rdi, rsi
    call    strcmp
    test    eax, eax
    pop     rdi
    jz      .long_group_append
    ; Check "both"
    push    rdi
    lea     rsi, [rel str_method_both]
    mov     rdi, [rsp]
    xchg    rdi, rsi
    call    strcmp
    test    eax, eax
    pop     rdi
    jz      .long_group_both
.long_group_unknown_opt:
    ; Invalid method or unknown option matching prefix
    pop     rbx
    pop     rcx
    ; Check if it's actually a different option that starts with --group
    mov     rsi, [r15 + rbx*8]
    call    err_unrecognized_option
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.long_group_default:
    pop     rbx
    pop     rcx
    mov     byte [rel opt_mode], MODE_GROUP
    mov     byte [rel opt_group_method], GROUP_SEPARATE
    jmp     .parse_next
.long_group_separate:
    pop     rbx
    pop     rcx
    mov     byte [rel opt_mode], MODE_GROUP
    mov     byte [rel opt_group_method], GROUP_SEPARATE
    jmp     .parse_next
.long_group_prepend:
    pop     rbx
    pop     rcx
    mov     byte [rel opt_mode], MODE_GROUP
    mov     byte [rel opt_group_method], GROUP_PREPEND
    jmp     .parse_next
.long_group_append:
    pop     rbx
    pop     rcx
    mov     byte [rel opt_mode], MODE_GROUP
    mov     byte [rel opt_group_method], GROUP_APPEND
    jmp     .parse_next
.long_group_both:
    pop     rbx
    pop     rcx
    mov     byte [rel opt_mode], MODE_GROUP
    mov     byte [rel opt_group_method], GROUP_BOTH
    jmp     .parse_next

.set_dashdash:
    mov     ecx, 1
    jmp     .parse_next

.is_operand:
    ; Positional argument: INPUT or OUTPUT
    cmp     qword [rel input_file], 0
    jne     .second_operand
    mov     [rel input_file], rsi
    jmp     .parse_next
.second_operand:
    cmp     qword [rel output_file], 0
    jne     .extra_operand
    mov     [rel output_file], rsi
    jmp     .parse_next
.extra_operand:
    push    rcx
    push    rbx
    mov     rdi, rsi
    call    err_extra_operand
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.parse_next:
    inc     rbx
    jmp     .parse_loop

; ─── Error exits for missing/invalid args ─────────────────
.err_missing_arg_f:
    lea     rdi, [rel str_missing_arg_f]
    call    print_error_msg
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall
.err_missing_arg_s:
    lea     rdi, [rel str_missing_arg_s]
    call    print_error_msg
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall
.err_missing_arg_w:
    lea     rdi, [rel str_missing_arg_w]
    call    print_error_msg
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall
.err_invalid_number_f:
    lea     rdi, [rel str_invalid_number]
    call    print_error_msg
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall
.err_invalid_number_s:
    lea     rdi, [rel str_invalid_number]
    call    print_error_msg
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall
.err_invalid_number_w:
    lea     rdi, [rel str_invalid_number]
    call    print_error_msg
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.do_help_pop:
    pop     rbx
    pop     rcx
    jmp     .do_help
.do_version_pop:
    pop     rbx
    pop     rcx
    jmp     .do_version

; ─── Done parsing ─────────────────────────────────────────
.parse_done:
    ; Validate: --group is mutually exclusive with -c/-d/-D/-u
    cmp     byte [rel opt_mode], MODE_GROUP
    jne     .no_group_conflict
    cmp     byte [rel opt_mode], MODE_REPEATED
    jne     .check_du_unique
    cmp     byte [rel opt_flag_u], 1
    jne     .no_group_conflict
    jmp     .no_group_conflict
.check_du_unique:
    cmp     byte [rel opt_mode], MODE_UNIQUE
    jne     .no_group_conflict
    cmp     byte [rel opt_flag_d], 1
    jne     .no_group_conflict

.no_group_conflict:

    ; Open input file
    mov     rdi, [rel input_file]
    test    rdi, rdi
    jz      .use_stdin
    ; Check for "-"
    cmp     byte [rdi], '-'
    jne     .open_input
    cmp     byte [rdi+1], 0
    je      .use_stdin

.open_input:
    xor     esi, esi                ; O_RDONLY
    xor     edx, edx
    mov     rax, SYS_OPEN
    syscall
    test    rax, rax
    js      .input_open_error
    mov     [rel input_fd], eax
    mov     byte [rel use_mmap], 1  ; Can use mmap for file input
    jmp     .open_output

.use_stdin:
    mov     dword [rel input_fd], STDIN
    mov     byte [rel use_mmap], 0  ; Cannot mmap stdin

.open_output:
    mov     rdi, [rel output_file]
    test    rdi, rdi
    jz      .use_stdout
    ; Check for "-"
    cmp     byte [rdi], '-'
    jne     .open_output_file
    cmp     byte [rdi+1], 0
    je      .use_stdout

.open_output_file:
    mov     esi, O_WRONLY | O_CREAT | O_TRUNC   ; 0x241
    mov     edx, 0o666             ; mode
    mov     rax, SYS_OPEN
    syscall
    test    rax, rax
    js      .output_open_error
    mov     [rel output_fd], eax
    jmp     .run_uniq

.use_stdout:
    mov     dword [rel output_fd], STDOUT

.run_uniq:
    ; Initialize delimiter before processing
    cmp     byte [rel opt_zero_terminated], 0
    jne     .run_uniq_use_nul
    mov     byte [rel delimiter], 10            ; newline
    jmp     .run_uniq_delim_done
.run_uniq_use_nul:
    mov     byte [rel delimiter], 0             ; NUL
.run_uniq_delim_done:

    ; Check if we can use the fast mmap path
    cmp     byte [rel use_mmap], 1
    jne     .run_uniq_slow

    ; Try to mmap the input file
    call    setup_mmap
    test    rax, rax
    jz      .run_uniq_mmap_ok

    ; mmap failed (empty file or error), use slow path
    ; For empty files, we need to produce no output, which is correct
    cmp     qword [rel mmap_len], 0
    je      .run_uniq_done          ; Empty file, nothing to do
    jmp     .run_uniq_slow

.run_uniq_mmap_ok:
    ; Check if we can use the ultra-fast path:
    ; MODE_NORMAL, no count, no skip_fields, no skip_chars, no check_chars limit,
    ; no case_insensitive, newline delimiter
    cmp     byte [rel opt_mode], MODE_NORMAL
    jne     .run_uniq_mmap_generic
    cmp     byte [rel opt_count], 0
    jne     .run_uniq_mmap_generic
    cmp     qword [rel opt_skip_fields], 0
    jne     .run_uniq_mmap_generic
    cmp     qword [rel opt_skip_chars], 0
    jne     .run_uniq_mmap_generic
    cmp     qword [rel opt_check_chars], -1
    jne     .run_uniq_mmap_generic
    cmp     byte [rel opt_case_insensitive], 0
    jne     .run_uniq_mmap_generic
    cmp     byte [rel opt_zero_terminated], 0
    jne     .run_uniq_mmap_generic

    call    process_uniq_mmap_fast
    call    cleanup_mmap
    jmp     .run_uniq_done

.run_uniq_mmap_generic:
    call    process_uniq_mmap
    call    cleanup_mmap
    jmp     .run_uniq_done

.run_uniq_slow:
    call    process_uniq_slow
    jmp     .run_uniq_done

.run_uniq_done:
    ; Flush output
    call    flush_output
    test    eax, eax
    jnz     .write_error_exit

    ; Close files if needed
    mov     eax, [rel input_fd]
    cmp     eax, STDIN
    je      .skip_close_input
    mov     edi, eax
    mov     rax, SYS_CLOSE
    syscall
.skip_close_input:
    mov     eax, [rel output_fd]
    cmp     eax, STDOUT
    je      .skip_close_output
    mov     edi, eax
    mov     rax, SYS_CLOSE
    syscall
.skip_close_output:

    ; Exit
    movzx   rdi, bpl
    mov     rax, SYS_EXIT
    syscall

.input_open_error:
    neg     rax
    mov     rdi, [rel input_file]
    mov     esi, eax
    call    err_file
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.output_open_error:
    neg     rax
    mov     rdi, [rel output_file]
    mov     esi, eax
    call    err_file
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.write_error_exit:
    lea     rdi, [rel str_write_error]
    call    print_error_simple
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

; ─── Help ────────────────────────────────────────────────
.do_help:
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [rel help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

; ─── Version ─────────────────────────────────────────────
.do_version:
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [rel version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

; ═══════════════════════════════════════════════════════════
;  setup_mmap — fstat + mmap the input file
;  Returns: rax=0 on success, -1 on failure
;  Sets: mmap_addr, mmap_len
; ═══════════════════════════════════════════════════════════
setup_mmap:
    push    rbx
    sub     rsp, 144                ; stat buffer on stack

    ; fstat(input_fd, &stat_buf)
    mov     eax, [rel input_fd]
    mov     edi, eax
    mov     rsi, rsp
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .sm_fail

    ; Get file size from stat buf (st_size is at offset 48)
    mov     rbx, [rsp + 48]
    mov     [rel mmap_len], rbx

    ; Check for empty file
    test    rbx, rbx
    jz      .sm_fail

    ; mmap(NULL, size, PROT_READ, MAP_PRIVATE|MAP_POPULATE, fd, 0)
    xor     edi, edi                ; addr = NULL
    mov     rsi, rbx                ; length
    mov     edx, PROT_READ          ; prot
    mov     r10d, MAP_PRIVATE | MAP_POPULATE ; flags
    mov     r8d, [rel input_fd]     ; fd
    xor     r9d, r9d                ; offset = 0
    mov     rax, SYS_MMAP
    syscall

    ; Check for MAP_FAILED (-1 page-aligned, or negative)
    cmp     rax, -4096
    ja      .sm_fail
    test    rax, rax
    jz      .sm_fail

    mov     [rel mmap_addr], rax

    ; madvise(addr, len, MADV_SEQUENTIAL)
    mov     rdi, rax
    mov     rsi, rbx
    mov     edx, MADV_SEQUENTIAL
    mov     rax, SYS_MADVISE
    syscall
    ; Ignore madvise errors

    xor     eax, eax
    add     rsp, 144
    pop     rbx
    ret

.sm_fail:
    mov     eax, -1
    add     rsp, 144
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  cleanup_mmap — munmap the input file
; ═══════════════════════════════════════════════════════════
cleanup_mmap:
    mov     rdi, [rel mmap_addr]
    test    rdi, rdi
    jz      .cm_done
    mov     rsi, [rel mmap_len]
    mov     rax, SYS_MUNMAP
    syscall
    mov     qword [rel mmap_addr], 0
.cm_done:
    ret

; ═══════════════════════════════════════════════════════════
;  process_uniq_mmap_fast — Ultra-fast zero-copy path for MODE_NORMAL
;
;  Conditions: MODE_NORMAL, no skip_fields, no skip_chars,
;  no check_chars limit, no case_insensitive, newline delimiter.
;
;  Strategy: Direct write from mmap buffer. Track contiguous
;  regions of unique lines and write them in bulk. When a
;  duplicate is found, flush the region before it, skip the
;  duplicate, and start a new region.
;
;  Uses a mask lookup table to avoid runtime shift computation
;  for the common short-line path.
;
;  Register usage:
;    r13 = current scan position in mmap buffer
;    r14 = safe end for 16-byte SIMD reads (end - 16)
;    r15 = previous line start pointer (-1 = no prev)
;    rbx = previous line masked qword (for short lines)
;    rbp = output_fd
;    r8  = write_start
;    r9  = absolute end of mmap buffer
;    r10 = previous line length
;    xmm15 = newline broadcast pattern
; ═══════════════════════════════════════════════════════════
process_uniq_mmap_fast:
    push    rbx
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 32                     ; local storage

    ; Load output fd into rbp for fast access
    mov     ebp, [rel output_fd]

    ; Initialize scan pointers
    mov     r13, [rel mmap_addr]        ; current pos
    mov     r9, r13
    add     r9, [rel mmap_len]          ; absolute end
    lea     r14, [r9 - 16]             ; safe end for SIMD

    ; No previous line yet
    mov     r15, -1

    ; write_start = beginning of mmap
    mov     r8, r13

    ; Set up SSE2 newline pattern
    mov     eax, 10
    movd    xmm15, eax
    punpcklbw xmm15, xmm15
    punpcklwd xmm15, xmm15
    pshufd  xmm15, xmm15, 0

    ; ─── Main loop ───
    ; Combined scan + compare approach:
    ; 1. SIMD scan to find newline, get line length
    ; 2. Compare with previous line using fastest method for given length
    ; Fast path (len 1-7): single qword compare with mask table
    ; The mask table lookup is faster than shift-based masking.

.pf_main_loop:
    cmp     r13, r9
    jge     .pf_handle_last

    mov     rdi, r13                    ; line start

    ; ─── Find newline ───
    cmp     r13, r14
    ja      .pf_scan_scalar

    movdqu  xmm0, [r13]
    pcmpeqb xmm0, xmm15
    pmovmskb eax, xmm0
    test    eax, eax
    jnz     .pf_found_nl
    add     r13, 16

.pf_scan16:
    cmp     r13, r14
    ja      .pf_scan_scalar
    movdqu  xmm0, [r13]
    pcmpeqb xmm0, xmm15
    pmovmskb eax, xmm0
    test    eax, eax
    jnz     .pf_found_nl
    add     r13, 16
    jmp     .pf_scan16

.pf_found_nl:
    bsf     ecx, eax
    add     r13, rcx                    ; r13 -> newline char
    mov     rcx, r13
    sub     rcx, rdi                    ; rcx = line length
    inc     r13                         ; advance past newline

    ; ─── Compare with prev ───
    cmp     r15, -1
    je      .pf_first_line

    ; Length differ => different lines (common case for sorted data)
    cmp     rcx, r10
    jne     .pf_update_prev

    ; Same length — compare content
    test    r10, r10
    jz      .pf_equal                   ; both empty

    ; Use qword compare for lines up to 7 bytes (covers ~95% of lines)
    cmp     r10, 8
    jge     .pf_cmp_long

    ; Short line (1-7): one qword load + mask + compare
    mov     rax, [rdi]
    and     rax, [rel mask_table + rcx*8]
    cmp     rax, rbx
    je      .pf_equal
    ; fall through to update_prev

.pf_update_prev:
    ; Lines differ — update prev, keep growing the output region
    mov     r15, rdi
    mov     r10, rcx
    cmp     rcx, 8
    jge     .pf_main_loop
    mov     rbx, [rdi]
    and     rbx, [rel mask_table + rcx*8]
    jmp     .pf_main_loop

.pf_cmp_long:
    ; Length >= 8: compare first 8 bytes (usually sufficient to distinguish)
    mov     rax, [r15]
    cmp     rax, [rdi]
    jne     .pf_update_prev

    ; First 8 bytes match — compare rest
    cmp     r10, 16
    jle     .pf_cmp_last8

    mov     rdx, 8
.pf_cmp16_loop:
    mov     rax, r10
    sub     rax, rdx
    cmp     rax, 16
    jl      .pf_cmp_tail8

    movdqu  xmm0, [r15 + rdx]
    movdqu  xmm1, [rdi + rdx]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0
    cmp     eax, 0xFFFF
    jne     .pf_update_prev
    add     rdx, 16
    jmp     .pf_cmp16_loop

.pf_cmp_tail8:
    mov     rax, [r15 + r10 - 8]
    cmp     rax, [rdi + r10 - 8]
    jne     .pf_update_prev
    jmp     .pf_equal

.pf_cmp_last8:
    mov     rax, [r15 + r10 - 8]
    cmp     rax, [rdi + r10 - 8]
    jne     .pf_update_prev
    ; fall through to equal

.pf_equal:
    ; Duplicate found. Buffer [write_start .. this line start) to output buf,
    ; then skip this duplicate line.
    mov     rdx, rdi
    sub     rdx, r8                     ; rdx = bytes to buffer
    jz      .pf_skip_dup

    ; Check if it fits in output buffer
    lea     rax, [r12 + rdx]
    cmp     rax, FLUSH_THRESHOLD
    jl      .pf_equal_copy_to_buf

    ; Flush output buffer first if non-empty
    test    r12, r12
    jz      .pf_equal_direct_write

    mov     [rsp], r8
    mov     [rsp+8], r13
    mov     [rsp+16], rcx
    mov     [rsp+24], rdi
    mov     edi, ebp
    lea     rsi, [rel out_buf]
    mov     rdx, r12
    call    asm_write_all
    xor     r12d, r12d
    mov     r8, [rsp]
    mov     r13, [rsp+8]
    mov     rcx, [rsp+16]
    mov     rdi, [rsp+24]
    ; Recompute region size
    mov     rdx, rdi
    sub     rdx, r8

    ; If region fits in buffer now, copy it
    lea     rax, [r12 + rdx]
    cmp     rax, FLUSH_THRESHOLD
    jl      .pf_equal_copy_to_buf

.pf_equal_direct_write:
    ; Region too large for buffer — write directly from mmap
    mov     [rsp], r8
    mov     [rsp+8], r13
    mov     [rsp+16], rcx
    mov     [rsp+24], rdi
    mov     edi, ebp
    mov     rsi, r8
    ; rdx = region size (already set)
    call    asm_write_all
    mov     r8, [rsp]
    mov     r13, [rsp+8]
    mov     rcx, [rsp+16]
    mov     rdi, [rsp+24]
    jmp     .pf_skip_dup

.pf_equal_copy_to_buf:
    ; Copy region [r8, r8+rdx) to output buffer using SIMD
    push    rdi
    push    rcx
    push    rdx
    lea     rdi, [rel out_buf]
    add     rdi, r12
    mov     rsi, r8                     ; src = write_start in mmap
    mov     rcx, rdx                    ; count remaining

.pf_ecopy32:
    cmp     rcx, 32
    jl      .pf_ecopy16
    movdqu  xmm0, [rsi]
    movdqu  xmm1, [rsi + 16]
    movdqu  [rdi], xmm0
    movdqu  [rdi + 16], xmm1
    add     rsi, 32
    add     rdi, 32
    sub     rcx, 32
    jmp     .pf_ecopy32

.pf_ecopy16:
    cmp     rcx, 16
    jl      .pf_ecopy8
    movdqu  xmm0, [rsi]
    movdqu  [rdi], xmm0
    add     rsi, 16
    add     rdi, 16
    sub     rcx, 16

.pf_ecopy8:
    cmp     rcx, 8
    jl      .pf_ecopy_tail
    mov     rax, [rsi]
    mov     [rdi], rax
    add     rsi, 8
    add     rdi, 8
    sub     rcx, 8

.pf_ecopy_tail:
    test    rcx, rcx
    jz      .pf_ecopy_done
.pf_ecopy_byte:
    movzx   eax, byte [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     rcx
    jnz     .pf_ecopy_byte

.pf_ecopy_done:
    pop     rdx
    pop     rcx
    pop     rdi
    add     r12, rdx                    ; update out_buf_used

.pf_skip_dup:
    ; Skip this duplicate: write_start = byte after this line's newline
    mov     r8, r13
    jmp     .pf_main_loop

.pf_first_line:
    mov     r15, rdi
    mov     r10, rcx
    cmp     rcx, 8
    jge     .pf_main_loop
    mov     rbx, [rdi]
    and     rbx, [rel mask_table + rcx*8]
    jmp     .pf_main_loop

    ; ─── Scalar newline scan (last <16 bytes of file) ───
.pf_scan_scalar:
    cmp     r13, r9
    jge     .pf_no_trailing_nl
    cmp     byte [r13], 10
    je      .pf_got_line_scalar
    inc     r13
    jmp     .pf_scan_scalar

.pf_got_line_scalar:
    ; r13 -> newline
    mov     rcx, r13
    sub     rcx, rdi
    inc     r13

    ; Same compare logic as above
    cmp     r15, -1
    je      .pf_first_line

    cmp     rcx, r10
    jne     .pf_update_prev

    test    r10, r10
    jz      .pf_equal

    cmp     r10, 8
    jge     .pf_cmp_long

    mov     rax, [rdi]
    and     rax, [rel mask_table + rcx*8]
    cmp     rax, rbx
    je      .pf_equal
    jmp     .pf_update_prev

.pf_no_trailing_nl:
    ; Partial line at end without newline
    mov     rcx, r13
    sub     rcx, rdi
    test    rcx, rcx
    jz      .pf_handle_last

    ; Compare this partial line with prev
    cmp     r15, -1
    je      .pf_partial_first

    cmp     rcx, r10
    jne     .pf_partial_diff

    test    r10, r10
    jz      .pf_partial_equal

    cmp     r10, 8
    jge     .pf_partial_cmp_long

    mov     rax, [rdi]
    and     rax, [rel mask_table + rcx*8]
    cmp     rax, rbx
    je      .pf_partial_equal
    jmp     .pf_partial_diff

.pf_partial_cmp_long:
    mov     rax, [r15]
    cmp     rax, [rdi]
    jne     .pf_partial_diff
    cmp     r10, 16
    jle     .pf_partial_cmp_last8
    mov     rdx, 8
.pf_partial_cmp16:
    mov     rax, r10
    sub     rax, rdx
    cmp     rax, 16
    jl      .pf_partial_cmp_t8
    movdqu  xmm0, [r15 + rdx]
    movdqu  xmm1, [rdi + rdx]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0
    cmp     eax, 0xFFFF
    jne     .pf_partial_diff
    add     rdx, 16
    jmp     .pf_partial_cmp16
.pf_partial_cmp_t8:
    mov     rax, [r15 + r10 - 8]
    cmp     rax, [rdi + r10 - 8]
    jne     .pf_partial_diff
    jmp     .pf_partial_equal
.pf_partial_cmp_last8:
    mov     rax, [r15 + r10 - 8]
    cmp     rax, [rdi + r10 - 8]
    jne     .pf_partial_diff
    ; fall through

.pf_partial_equal:
    ; Duplicate partial line: buffer region before it, skip it
    mov     rdx, rdi
    sub     rdx, r8
    jz      .pf_partial_skip

    ; Copy region to output buffer
    lea     rax, [r12 + rdx]
    cmp     rax, FLUSH_THRESHOLD
    jl      .pf_partial_copy

    ; Flush buffer first
    test    r12, r12
    jz      .pf_partial_direct
    mov     [rsp], r8
    mov     [rsp+8], rdi
    mov     [rsp+16], rdx
    mov     edi, ebp
    lea     rsi, [rel out_buf]
    mov     rdx, r12
    call    asm_write_all
    xor     r12d, r12d
    mov     r8, [rsp]
    mov     rdi, [rsp+8]
    mov     rdx, [rsp+16]

    lea     rax, [r12 + rdx]
    cmp     rax, FLUSH_THRESHOLD
    jl      .pf_partial_copy

.pf_partial_direct:
    mov     [rsp], r8
    mov     edi, ebp
    mov     rsi, r8
    call    asm_write_all
    mov     r8, [rsp]
    jmp     .pf_partial_skip

.pf_partial_copy:
    push    rdi
    push    rcx
    push    rdx
    lea     rdi, [rel out_buf]
    add     rdi, r12
    mov     rsi, r8
    mov     rcx, rdx
.pf_pcopy8:
    cmp     rcx, 8
    jl      .pf_pcopy_tail
    mov     rax, [rsi]
    mov     [rdi], rax
    add     rsi, 8
    add     rdi, 8
    sub     rcx, 8
    jmp     .pf_pcopy8
.pf_pcopy_tail:
    test    rcx, rcx
    jz      .pf_pcopy_done
    movzx   eax, byte [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     rcx
    jnz     .pf_pcopy_tail
.pf_pcopy_done:
    pop     rdx
    pop     rcx
    pop     rdi
    add     r12, rdx

.pf_partial_skip:
    mov     r8, r9
    jmp     .pf_handle_last

.pf_partial_diff:
    mov     r15, rdi
    mov     r10, rcx
    jmp     .pf_handle_last

.pf_partial_first:
    mov     r15, rdi
    mov     r10, rcx
    jmp     .pf_handle_last

    ; ─── Handle end of file ───
.pf_handle_last:
    cmp     r15, -1
    je      .pf_done

    ; First flush output buffer if non-empty
    test    r12, r12
    jz      .pf_last_no_buf

    mov     [rsp], r8
    mov     edi, ebp
    lea     rsi, [rel out_buf]
    mov     rdx, r12
    call    asm_write_all
    xor     r12d, r12d
    mov     r8, [rsp]

.pf_last_no_buf:
    ; Write remaining region [write_start .. end)
    mov     rdx, r9
    sub     rdx, r8
    jz      .pf_done_empty

    cmp     byte [r9 - 1], 10
    je      .pf_handle_last_write

    ; File doesn't end with newline: write region + newline
    mov     edi, ebp
    mov     rsi, r8
    call    asm_write_all
    mov     byte [rel out_buf], 10
    mov     edi, ebp
    lea     rsi, [rel out_buf]
    mov     edx, 1
    call    asm_write_all
    xor     r12d, r12d
    jmp     .pf_done

.pf_handle_last_write:
    mov     edi, ebp
    mov     rsi, r8
    call    asm_write_all
    xor     r12d, r12d
    jmp     .pf_done

.pf_done_empty:
    xor     r12d, r12d

.pf_done:
    add     rsp, 32
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  process_uniq_mmap — Generic mmap-based processing
;
;  Processes the mmap'd buffer directly. Lines are identified
;  by scanning for delimiters with SIMD. Lines are compared
;  using pointers into the mmap'd buffer (zero-copy).
;
;  Register usage in main loop:
;    r13 = current position in mmap buffer
;    r14 = end of mmap buffer
;    r15 = delimiter byte
;    rbx = previous line pointer (in mmap)
;    [prev_mmap_len] = previous line length
;    [count] = duplicate count
; ═══════════════════════════════════════════════════════════
process_uniq_mmap:
    push    rbx
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8                  ; Align stack to 16

    ; Initialize
    mov     r13, [rel mmap_addr]    ; current pos
    mov     r14, r13
    add     r14, [rel mmap_len]     ; end pos
    mov     qword [rel count], 0
    mov     byte [rel first_group], 1
    mov     qword [rel prev_mmap_ptr], 0    ; no prev line
    mov     qword [rel prev_mmap_len], -1   ; -1 = no prev line

    ; Determine delimiter
    cmp     byte [rel opt_zero_terminated], 0
    jne     .pm_use_nul
    mov     r15, 10                 ; newline
    jmp     .pm_setup_simd
.pm_use_nul:
    xor     r15d, r15d              ; NUL

.pm_setup_simd:
    ; Set up SSE2 pattern for delimiter search
    movd    xmm15, r15d
    punpcklbw xmm15, xmm15
    punpcklwd xmm15, xmm15
    pshufd  xmm15, xmm15, 0        ; broadcast delimiter

.pm_main_loop:
    ; Find next line: scan for delimiter starting at r13
    cmp     r13, r14
    jge     .pm_handle_eof

    ; r13 = start of current line
    mov     rdi, r13                ; line_start

    ; SIMD scan for delimiter
    mov     rsi, r13                ; scan pos
.pm_scan_16:
    lea     rax, [rsi + 16]
    cmp     rax, r14
    ja      .pm_scan_scalar         ; less than 16 bytes remaining

    movdqu  xmm0, [rsi]
    pcmpeqb xmm0, xmm15
    pmovmskb eax, xmm0
    test    eax, eax
    jnz     .pm_found_delim_simd
    add     rsi, 16
    jmp     .pm_scan_16

.pm_found_delim_simd:
    bsf     ecx, eax                ; position within 16-byte chunk
    add     rsi, rcx                ; rsi = pointer to delimiter
    jmp     .pm_got_line

.pm_scan_scalar:
    cmp     rsi, r14
    jge     .pm_no_trailing_delim

    movzx   eax, byte [rsi]
    cmp     al, r15b
    je      .pm_got_line
    inc     rsi
    jmp     .pm_scan_scalar

.pm_no_trailing_delim:
    ; No delimiter found — partial line at end of file
    ; rdi = line start, rsi = end of buffer
    ; Line length = rsi - rdi
    mov     rcx, rsi
    sub     rcx, rdi                ; line length
    test    rcx, rcx
    jz      .pm_handle_eof          ; empty, nothing to do

    ; Process this partial line
    mov     r13, rsi                ; advance past (to EOF)
    jmp     .pm_process_line

.pm_got_line:
    ; rdi = line start, rsi = pointer to delimiter
    ; Line length = rsi - rdi
    mov     rcx, rsi
    sub     rcx, rdi                ; line length (not including delimiter)

    lea     r13, [rsi + 1]          ; advance past delimiter

.pm_process_line:
    ; rdi = current line pointer, rcx = current line length
    ; Compare with previous line
    cmp     qword [rel prev_mmap_len], -1
    je      .pm_first_line

    ; Compare current (rdi, rcx) with prev (prev_mmap_ptr, prev_mmap_len)
    ; Save rdi, rcx across call
    push    rdi
    push    rcx

    ; rdi = cur_ptr, rsi = cur_len, rdx = prev_ptr, rcx = prev_len
    mov     rsi, rcx                ; cur_len
    mov     rdx, [rel prev_mmap_ptr]  ; prev_ptr
    mov     rcx, [rel prev_mmap_len]  ; prev_len
    call    compare_lines_mmap
    ; rax = 0 if equal, 1 if different

    pop     rcx                     ; restore cur_len
    pop     rdi                     ; restore cur_ptr

    test    eax, eax
    jz      .pm_lines_equal

    ; Lines are different — output previous group, start new
    push    rdi
    push    rcx
    call    output_group_mmap
    pop     rcx
    pop     rdi

    ; Set current as previous
    mov     [rel prev_mmap_ptr], rdi
    mov     [rel prev_mmap_len], rcx
    mov     qword [rel count], 1
    jmp     .pm_main_loop

.pm_first_line:
    ; First line
    mov     [rel prev_mmap_ptr], rdi
    mov     [rel prev_mmap_len], rcx
    mov     qword [rel count], 1

    ; For group mode, emit prepend/both separator before first group
    cmp     byte [rel opt_mode], MODE_GROUP
    jne     .pm_main_loop

    movzx   eax, byte [rel opt_group_method]
    cmp     al, GROUP_PREPEND
    je      .pm_first_group_sep
    cmp     al, GROUP_BOTH
    je      .pm_first_group_sep
    jmp     .pm_first_group_emit

.pm_first_group_sep:
    push    rdi
    push    rcx
    call    emit_empty_line
    pop     rcx
    pop     rdi

.pm_first_group_emit:
    mov     byte [rel first_group], 0
    ; Emit the first line
    push    rdi
    push    rcx
    ; rdi already = line ptr, rsi = len
    mov     rsi, rcx
    call    emit_line_direct
    pop     rcx
    pop     rdi
    jmp     .pm_main_loop

.pm_lines_equal:
    inc     qword [rel count]

    cmp     byte [rel opt_mode], MODE_ALL_REPEAT
    je      .pm_allrep_emit
    cmp     byte [rel opt_mode], MODE_GROUP
    je      .pm_group_emit
    jmp     .pm_main_loop

.pm_allrep_emit:
    cmp     qword [rel count], 2
    je      .pm_allrep_first_dup
    ; count > 2: just emit current line
    mov     rsi, rcx                ; len
    ; rdi = ptr
    push    rdi
    push    rcx
    call    emit_line_direct
    pop     rcx
    pop     rdi
    jmp     .pm_main_loop

.pm_allrep_first_dup:
    ; count == 2: emit prev and current
    cmp     byte [rel opt_allrep_method], ALLREP_PREPEND
    je      .pm_allrep_prepend_sep
    cmp     byte [rel opt_allrep_method], ALLREP_SEPARATE
    je      .pm_allrep_separate_sep
    jmp     .pm_allrep_emit_both

.pm_allrep_prepend_sep:
    push    rdi
    push    rcx
    call    emit_empty_line
    pop     rcx
    pop     rdi
    jmp     .pm_allrep_emit_both

.pm_allrep_separate_sep:
    cmp     byte [rel first_group], 1
    je      .pm_allrep_emit_both
    push    rdi
    push    rcx
    call    emit_empty_line
    pop     rcx
    pop     rdi

.pm_allrep_emit_both:
    mov     byte [rel first_group], 0
    ; Emit prev line
    push    rdi
    push    rcx
    mov     rdi, [rel prev_mmap_ptr]
    mov     rsi, [rel prev_mmap_len]
    call    emit_line_direct
    pop     rcx
    pop     rdi
    ; Emit current line
    push    rdi
    push    rcx
    mov     rsi, rcx
    call    emit_line_direct
    pop     rcx
    pop     rdi
    jmp     .pm_main_loop

.pm_group_emit:
    ; Group mode: equal line — just emit it
    push    rdi
    push    rcx
    mov     rsi, rcx
    call    emit_line_direct
    pop     rcx
    pop     rdi
    jmp     .pm_main_loop

.pm_handle_eof:
    ; Output the last group
    cmp     qword [rel prev_mmap_len], -1
    je      .pm_done                ; no lines at all
    call    output_group_final_mmap

.pm_done:
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  compare_lines_mmap — Compare two lines with skip/check/case options
;  rdi = cur_ptr, rsi = cur_len, rdx = prev_ptr, rcx = prev_len
;  Returns: rax = 0 if equal, 1 if different
; ═══════════════════════════════════════════════════════════
compare_lines_mmap:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; Save parameters
    mov     r8, rdx                 ; prev_ptr
    mov     r9, rcx                 ; prev_len
    mov     r10, rdi                ; cur_ptr
    mov     r11, rsi                ; cur_len

    ; Apply skip_fields to both
    mov     rcx, [rel opt_skip_fields]
    test    rcx, rcx
    jz      .clm_skip_chars

    ; Skip fields in prev line
    push    r8
    push    r9
    push    r10
    push    r11

    mov     rdi, r8
    mov     rsi, r9
    mov     rdx, rcx
    call    skip_fields_fn
    mov     r12, rax                ; prev offset

    ; Skip fields in cur line
    mov     rdi, [rsp + 8]          ; r10 = cur_ptr
    mov     rsi, [rsp]              ; r11 = cur_len
    mov     rdx, [rel opt_skip_fields]
    call    skip_fields_fn
    mov     r13, rax                ; cur offset

    pop     r11
    pop     r10
    pop     r9
    pop     r8
    jmp     .clm_apply_skip_chars

.clm_skip_chars:
    xor     r12d, r12d              ; prev offset = 0
    xor     r13d, r13d              ; cur offset = 0

.clm_apply_skip_chars:
    ; Apply skip_chars
    mov     rcx, [rel opt_skip_chars]
    add     r12, rcx
    add     r13, rcx

    ; Clamp offsets to line lengths
    cmp     r12, r9
    jle     .clm_prev_ok
    mov     r12, r9
.clm_prev_ok:
    cmp     r13, r11
    jle     .clm_cur_ok
    mov     r13, r11
.clm_cur_ok:

    ; Compute effective pointers and lengths
    lea     r14, [r8 + r12]         ; prev effective start
    mov     rbx, r9
    sub     rbx, r12                ; prev effective length

    lea     r15, [r10 + r13]        ; cur effective start
    mov     rcx, r11
    sub     rcx, r13                ; cur effective length

    ; Apply check_chars limit
    mov     rax, [rel opt_check_chars]
    cmp     rax, -1
    je      .clm_no_limit

    cmp     rbx, rax
    jle     .clm_prev_limited
    mov     rbx, rax
.clm_prev_limited:
    cmp     rcx, rax
    jle     .clm_cur_limited
    mov     rcx, rax
.clm_cur_limited:

.clm_no_limit:
    ; Now compare r14[0..rbx) with r15[0..rcx)
    cmp     rbx, rcx
    jne     .clm_different

    ; Same length — compare bytes
    test    rbx, rbx
    jz      .clm_equal

    cmp     byte [rel opt_case_insensitive], 0
    jne     .clm_case_insensitive

    ; === Fast case-sensitive SIMD comparison ===
    xor     ecx, ecx                ; offset = 0
.clm_simd_cmp:
    mov     rax, rbx
    sub     rax, rcx
    cmp     rax, 16
    jl      .clm_scalar_cmp

    movdqu  xmm0, [r14 + rcx]
    movdqu  xmm1, [r15 + rcx]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0
    cmp     eax, 0xFFFF
    jne     .clm_different
    add     rcx, 16
    jmp     .clm_simd_cmp

.clm_scalar_cmp:
    cmp     rcx, rbx
    jge     .clm_equal
    movzx   eax, byte [r14 + rcx]
    cmp     al, byte [r15 + rcx]
    jne     .clm_different
    inc     rcx
    jmp     .clm_scalar_cmp

.clm_case_insensitive:
    ; Case-insensitive byte-by-byte comparison
    xor     ecx, ecx
.clm_ci_loop:
    cmp     rcx, rbx
    jge     .clm_equal

    movzx   eax, byte [r14 + rcx]
    movzx   edx, byte [r15 + rcx]

    ; Convert to uppercase
    cmp     al, 'a'
    jb      .clm_ci_no1
    cmp     al, 'z'
    ja      .clm_ci_no1
    sub     al, 32
.clm_ci_no1:
    cmp     dl, 'a'
    jb      .clm_ci_no2
    cmp     dl, 'z'
    ja      .clm_ci_no2
    sub     dl, 32
.clm_ci_no2:
    cmp     al, dl
    jne     .clm_different
    inc     rcx
    jmp     .clm_ci_loop

.clm_equal:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.clm_different:
    mov     eax, 1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  output_group_mmap — Output the previous group (mmap version)
; ═══════════════════════════════════════════════════════════
output_group_mmap:
    push    rbx

    movzx   eax, byte [rel opt_mode]
    cmp     al, MODE_NORMAL
    je      .ogm_normal
    cmp     al, MODE_REPEATED
    je      .ogm_repeated
    cmp     al, MODE_ALL_REPEAT
    je      .ogm_allrepeat
    cmp     al, MODE_UNIQUE
    je      .ogm_unique
    cmp     al, MODE_GROUP
    je      .ogm_group

.ogm_normal:
    cmp     byte [rel opt_count], 1
    jne     .ogm_normal_noc
    mov     rdi, [rel count]
    call    emit_count_prefix
.ogm_normal_noc:
    mov     rdi, [rel prev_mmap_ptr]
    mov     rsi, [rel prev_mmap_len]
    call    emit_line_direct
    jmp     .ogm_done

.ogm_repeated:
    cmp     byte [rel opt_flag_u], 1
    je      .ogm_done
    cmp     qword [rel count], 1
    jle     .ogm_done
    cmp     byte [rel opt_count], 1
    jne     .ogm_repeated_noc
    mov     rdi, [rel count]
    call    emit_count_prefix
.ogm_repeated_noc:
    mov     rdi, [rel prev_mmap_ptr]
    mov     rsi, [rel prev_mmap_len]
    call    emit_line_direct
    jmp     .ogm_done

.ogm_allrepeat:
    jmp     .ogm_done

.ogm_unique:
    cmp     byte [rel opt_flag_d], 1
    je      .ogm_done
    cmp     qword [rel count], 1
    jne     .ogm_done
    cmp     byte [rel opt_count], 1
    jne     .ogm_unique_noc
    mov     rdi, [rel count]
    call    emit_count_prefix
.ogm_unique_noc:
    mov     rdi, [rel prev_mmap_ptr]
    mov     rsi, [rel prev_mmap_len]
    call    emit_line_direct
    jmp     .ogm_done

.ogm_group:
    ; Emit separator between groups
    call    emit_empty_line
    ; Emit first line of new group (current line is on the stack of caller)
    ; Actually, in the mmap loop, after output_group_mmap returns,
    ; the new prev is set. But we need to emit the CURRENT line,
    ; which is the new group's first line. The caller handles this
    ; by setting prev_mmap_ptr after this call. But we need to emit
    ; the current line here. Let's use cur_mmap_ptr/cur_mmap_len.
    ; However, we don't have those stored. Let's handle this differently.
    ; The mmap main loop sets prev after calling output_group_mmap,
    ; so we need to emit the NEW line. But we don't have it here.
    ; Instead, let the main loop handle group mode line emission.
    ; So for group mode in output_group_mmap, just emit the separator.
    jmp     .ogm_done

.ogm_done:
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  output_group_final_mmap — Output last group at EOF (mmap)
; ═══════════════════════════════════════════════════════════
output_group_final_mmap:
    push    rbx

    movzx   eax, byte [rel opt_mode]
    cmp     al, MODE_NORMAL
    je      .ogfm_normal
    cmp     al, MODE_REPEATED
    je      .ogfm_repeated
    cmp     al, MODE_ALL_REPEAT
    je      .ogfm_allrepeat
    cmp     al, MODE_UNIQUE
    je      .ogfm_unique
    cmp     al, MODE_GROUP
    je      .ogfm_group

.ogfm_normal:
    cmp     byte [rel opt_count], 1
    jne     .ogfm_normal_noc
    mov     rdi, [rel count]
    call    emit_count_prefix
.ogfm_normal_noc:
    mov     rdi, [rel prev_mmap_ptr]
    mov     rsi, [rel prev_mmap_len]
    call    emit_line_direct
    jmp     .ogfm_done

.ogfm_repeated:
    cmp     byte [rel opt_flag_u], 1
    je      .ogfm_done
    cmp     qword [rel count], 1
    jle     .ogfm_done
    cmp     byte [rel opt_count], 1
    jne     .ogfm_repeated_noc
    mov     rdi, [rel count]
    call    emit_count_prefix
.ogfm_repeated_noc:
    mov     rdi, [rel prev_mmap_ptr]
    mov     rsi, [rel prev_mmap_len]
    call    emit_line_direct
    jmp     .ogfm_done

.ogfm_allrepeat:
    jmp     .ogfm_done

.ogfm_unique:
    cmp     byte [rel opt_flag_d], 1
    je      .ogfm_done
    cmp     qword [rel count], 1
    jne     .ogfm_done
    cmp     byte [rel opt_count], 1
    jne     .ogfm_unique_noc
    mov     rdi, [rel count]
    call    emit_count_prefix
.ogfm_unique_noc:
    mov     rdi, [rel prev_mmap_ptr]
    mov     rsi, [rel prev_mmap_len]
    call    emit_line_direct
    jmp     .ogfm_done

.ogfm_group:
    ; Group mode final: emit trailing separator if append or both
    movzx   eax, byte [rel opt_group_method]
    cmp     al, GROUP_APPEND
    je      .ogfm_group_trailing
    cmp     al, GROUP_BOTH
    je      .ogfm_group_trailing
    jmp     .ogfm_done

.ogfm_group_trailing:
    call    emit_empty_line

.ogfm_done:
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  emit_line_direct(rdi=ptr, rsi=len) — Emit line + delimiter to output buffer
;  Zero-copy from mmap: copies to output buffer for batched writes
; ═══════════════════════════════════════════════════════════
emit_line_direct:
    push    rbx
    push    r13

    mov     rbx, rdi                ; ptr
    mov     r13, rsi                ; len

    ; Need len + 1 bytes in output buffer
    lea     rax, [r12 + r13 + 1]
    cmp     rax, OUT_BUF_SIZE
    jl      .eld_space_ok
    call    flush_output
    test    eax, eax
    jnz     .eld_error
    ; After flush, check if the line itself is bigger than buffer
    lea     rax, [r13 + 1]
    cmp     rax, OUT_BUF_SIZE
    jge     .eld_direct_write
.eld_space_ok:
    ; Copy line data to output buffer using rep movsb (fast on modern CPUs)
    lea     rdi, [rel out_buf]
    add     rdi, r12
    mov     rsi, rbx
    mov     rcx, r13
    ; Use SIMD for larger copies
    cmp     rcx, 64
    jge     .eld_simd_copy
    rep     movsb
    jmp     .eld_add_delim

.eld_simd_copy:
    ; Copy 16 bytes at a time
    push    rcx
    mov     rdx, rcx
    shr     rdx, 4                  ; rdx = count / 16
.eld_simd_loop:
    movdqu  xmm0, [rsi]
    movdqu  [rdi], xmm0
    add     rsi, 16
    add     rdi, 16
    dec     rdx
    jnz     .eld_simd_loop
    pop     rcx
    ; Copy remaining bytes
    and     rcx, 15                 ; remaining = len & 15
    rep     movsb

.eld_add_delim:
    ; Append delimiter
    lea     rdi, [rel out_buf]
    add     rdi, r12
    add     rdi, r13
    movzx   eax, byte [rel delimiter]
    mov     [rdi], al
    lea     rax, [r13 + 1]
    add     r12, rax

    ; Flush if above threshold
    cmp     r12, FLUSH_THRESHOLD
    jl      .eld_done
    call    flush_output
    test    eax, eax
    jnz     .eld_error

.eld_done:
    pop     r13
    pop     rbx
    ret

.eld_direct_write:
    ; Line too large for buffer — write directly
    ; First write the line data
    mov     edi, [rel output_fd]
    mov     rsi, rbx
    mov     rdx, r13
    call    asm_write_all
    test    eax, eax
    jnz     .eld_error
    ; Write delimiter
    movzx   eax, byte [rel delimiter]
    mov     [rel count_buf], al     ; reuse count_buf temporarily
    mov     edi, [rel output_fd]
    lea     rsi, [rel count_buf]
    mov     edx, 1
    call    asm_write_all
    test    eax, eax
    jnz     .eld_error
    jmp     .eld_done

.eld_error:
    mov     ebp, 1
    pop     r13
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  process_uniq_mmap group mode fix:
;  After output_group_mmap for GROUP mode, we need to emit
;  the current (new) line. This is handled by intercepting
;  the "lines different" path in the main loop.
;
;  The main loop code at .pm_lines_different already calls
;  output_group_mmap and then sets new prev. For GROUP mode,
;  we also need to emit the new line. Let me re-examine the
;  mmap main loop to handle this correctly.
;
;  Actually, looking at the original code, for GROUP mode
;  output_group emits the separator AND the new line.
;  Let's fix the mmap main loop to handle this.
; ═══════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════
;  process_uniq_slow — Fallback read-based processing for stdin
;  Uses read_buf and line buffers.
; ═══════════════════════════════════════════════════════════
process_uniq_slow:
    push    rbx
    push    r13
    push    r14
    push    r15

    ; Initialize state
    mov     qword [rel prev_line_len], -1       ; -1 = no previous line
    mov     qword [rel cur_line_len], 0
    mov     qword [rel count], 0
    mov     byte [rel first_group], 1
    mov     qword [rel read_buf_pos], 0
    mov     qword [rel read_buf_end], 0

    ; Determine delimiter
    cmp     byte [rel opt_zero_terminated], 0
    jne     .pus_use_nul
    mov     byte [rel delimiter], 10            ; newline
    jmp     .pus_main_loop
.pus_use_nul:
    mov     byte [rel delimiter], 0             ; NUL

.pus_main_loop:
    call    read_line
    cmp     rax, -1
    je      .pus_error
    cmp     rax, 1
    je      .pus_eof

    cmp     qword [rel prev_line_len], -1
    je      .pus_first_line

    call    compare_lines_slow
    test    eax, eax
    jz      .pus_lines_equal

    ; Lines are different
    call    output_group_slow
    call    swap_to_prev
    mov     qword [rel count], 1
    jmp     .pus_main_loop

.pus_first_line:
    call    swap_to_prev
    mov     qword [rel count], 1

    cmp     byte [rel opt_mode], MODE_GROUP
    jne     .pus_main_loop

    movzx   eax, byte [rel opt_group_method]
    cmp     al, GROUP_PREPEND
    je      .pus_first_group_sep
    cmp     al, GROUP_BOTH
    je      .pus_first_group_sep
    jmp     .pus_first_group_emit

.pus_first_group_sep:
    call    emit_empty_line

.pus_first_group_emit:
    mov     byte [rel first_group], 0
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line_direct
    jmp     .pus_main_loop

.pus_lines_equal:
    inc     qword [rel count]
    cmp     byte [rel opt_mode], MODE_ALL_REPEAT
    je      .pus_allrep_emit
    cmp     byte [rel opt_mode], MODE_GROUP
    je      .pus_group_emit
    jmp     .pus_main_loop

.pus_allrep_emit:
    cmp     qword [rel count], 2
    je      .pus_allrep_first_dup
    lea     rdi, [rel cur_line_buf]
    mov     rsi, [rel cur_line_len]
    call    emit_line_direct
    jmp     .pus_main_loop

.pus_allrep_first_dup:
    cmp     byte [rel opt_allrep_method], ALLREP_PREPEND
    je      .pus_allrep_prepend_sep
    cmp     byte [rel opt_allrep_method], ALLREP_SEPARATE
    je      .pus_allrep_separate_sep
    jmp     .pus_allrep_emit_both

.pus_allrep_prepend_sep:
    call    emit_empty_line
    jmp     .pus_allrep_emit_both

.pus_allrep_separate_sep:
    cmp     byte [rel first_group], 1
    je      .pus_allrep_emit_both
    call    emit_empty_line
    jmp     .pus_allrep_emit_both

.pus_allrep_emit_both:
    mov     byte [rel first_group], 0
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line_direct
    lea     rdi, [rel cur_line_buf]
    mov     rsi, [rel cur_line_len]
    call    emit_line_direct
    jmp     .pus_main_loop

.pus_group_emit:
    lea     rdi, [rel cur_line_buf]
    mov     rsi, [rel cur_line_len]
    call    emit_line_direct
    jmp     .pus_main_loop

.pus_eof:
    ; Check if there was a partial line
    cmp     qword [rel cur_line_len], 0
    je      .pus_eof_no_partial
    ; Partial line handling
    cmp     qword [rel prev_line_len], -1
    je      .pus_eof_first_partial

    call    compare_lines_slow
    test    eax, eax
    jz      .pus_eof_partial_equal

    call    output_group_slow
    call    swap_to_prev
    mov     qword [rel count], 1
    jmp     .pus_eof_final_group

.pus_eof_first_partial:
    call    swap_to_prev
    mov     qword [rel count], 1
    cmp     byte [rel opt_mode], MODE_GROUP
    jne     .pus_eof_final_group
    movzx   eax, byte [rel opt_group_method]
    cmp     al, GROUP_PREPEND
    je      .pus_eof_first_partial_sep
    cmp     al, GROUP_BOTH
    je      .pus_eof_first_partial_sep
    jmp     .pus_eof_first_partial_emit
.pus_eof_first_partial_sep:
    call    emit_empty_line
.pus_eof_first_partial_emit:
    mov     byte [rel first_group], 0
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line_direct
    jmp     .pus_eof_final_group

.pus_eof_partial_equal:
    inc     qword [rel count]
    cmp     byte [rel opt_mode], MODE_ALL_REPEAT
    je      .pus_eof_allrep_partial
    cmp     byte [rel opt_mode], MODE_GROUP
    je      .pus_eof_group_partial
    jmp     .pus_eof_final_group

.pus_eof_allrep_partial:
    cmp     qword [rel count], 2
    je      .pus_eof_allrep_first_dup
    lea     rdi, [rel cur_line_buf]
    mov     rsi, [rel cur_line_len]
    call    emit_line_direct
    jmp     .pus_eof_final_group
.pus_eof_allrep_first_dup:
    cmp     byte [rel opt_allrep_method], ALLREP_PREPEND
    je      .pus_eof_ar_prepend
    cmp     byte [rel opt_allrep_method], ALLREP_SEPARATE
    je      .pus_eof_ar_separate
    jmp     .pus_eof_ar_emit_both
.pus_eof_ar_prepend:
    call    emit_empty_line
    jmp     .pus_eof_ar_emit_both
.pus_eof_ar_separate:
    cmp     byte [rel first_group], 1
    je      .pus_eof_ar_emit_both
    call    emit_empty_line
.pus_eof_ar_emit_both:
    mov     byte [rel first_group], 0
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line_direct
    lea     rdi, [rel cur_line_buf]
    mov     rsi, [rel cur_line_len]
    call    emit_line_direct
    jmp     .pus_eof_final_group

.pus_eof_group_partial:
    lea     rdi, [rel cur_line_buf]
    mov     rsi, [rel cur_line_len]
    call    emit_line_direct
    jmp     .pus_eof_final_group

.pus_eof_no_partial:
.pus_eof_final_group:
    cmp     qword [rel prev_line_len], -1
    je      .pus_done
    call    output_group_final_slow

.pus_done:
.pus_error:
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  output_group_slow — Output group using line buffers (stdin path)
; ═══════════════════════════════════════════════════════════
output_group_slow:
    push    rbx

    movzx   eax, byte [rel opt_mode]
    cmp     al, MODE_NORMAL
    je      .ogs_normal
    cmp     al, MODE_REPEATED
    je      .ogs_repeated
    cmp     al, MODE_ALL_REPEAT
    je      .ogs_allrepeat
    cmp     al, MODE_UNIQUE
    je      .ogs_unique
    cmp     al, MODE_GROUP
    je      .ogs_group

.ogs_normal:
    cmp     byte [rel opt_count], 1
    jne     .ogs_normal_noc
    mov     rdi, [rel count]
    call    emit_count_prefix
.ogs_normal_noc:
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line_direct
    jmp     .ogs_done

.ogs_repeated:
    cmp     byte [rel opt_flag_u], 1
    je      .ogs_done
    cmp     qword [rel count], 1
    jle     .ogs_done
    cmp     byte [rel opt_count], 1
    jne     .ogs_repeated_noc
    mov     rdi, [rel count]
    call    emit_count_prefix
.ogs_repeated_noc:
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line_direct
    jmp     .ogs_done

.ogs_allrepeat:
    jmp     .ogs_done

.ogs_unique:
    cmp     byte [rel opt_flag_d], 1
    je      .ogs_done
    cmp     qword [rel count], 1
    jne     .ogs_done
    cmp     byte [rel opt_count], 1
    jne     .ogs_unique_noc
    mov     rdi, [rel count]
    call    emit_count_prefix
.ogs_unique_noc:
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line_direct
    jmp     .ogs_done

.ogs_group:
    call    emit_empty_line
    lea     rdi, [rel cur_line_buf]
    mov     rsi, [rel cur_line_len]
    call    emit_line_direct
    jmp     .ogs_done

.ogs_done:
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  output_group_final_slow — Output last group (stdin path)
; ═══════════════════════════════════════════════════════════
output_group_final_slow:
    push    rbx

    movzx   eax, byte [rel opt_mode]
    cmp     al, MODE_NORMAL
    je      .ogfs_normal
    cmp     al, MODE_REPEATED
    je      .ogfs_repeated
    cmp     al, MODE_ALL_REPEAT
    je      .ogfs_allrepeat
    cmp     al, MODE_UNIQUE
    je      .ogfs_unique
    cmp     al, MODE_GROUP
    je      .ogfs_group

.ogfs_normal:
    cmp     byte [rel opt_count], 1
    jne     .ogfs_normal_noc
    mov     rdi, [rel count]
    call    emit_count_prefix
.ogfs_normal_noc:
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line_direct
    jmp     .ogfs_done

.ogfs_repeated:
    cmp     byte [rel opt_flag_u], 1
    je      .ogfs_done
    cmp     qword [rel count], 1
    jle     .ogfs_done
    cmp     byte [rel opt_count], 1
    jne     .ogfs_repeated_noc
    mov     rdi, [rel count]
    call    emit_count_prefix
.ogfs_repeated_noc:
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line_direct
    jmp     .ogfs_done

.ogfs_allrepeat:
    jmp     .ogfs_done

.ogfs_unique:
    cmp     byte [rel opt_flag_d], 1
    je      .ogfs_done
    cmp     qword [rel count], 1
    jne     .ogfs_done
    cmp     byte [rel opt_count], 1
    jne     .ogfs_unique_noc
    mov     rdi, [rel count]
    call    emit_count_prefix
.ogfs_unique_noc:
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line_direct
    jmp     .ogfs_done

.ogfs_group:
    movzx   eax, byte [rel opt_group_method]
    cmp     al, GROUP_APPEND
    je      .ogfs_group_trailing
    cmp     al, GROUP_BOTH
    je      .ogfs_group_trailing
    jmp     .ogfs_done

.ogfs_group_trailing:
    call    emit_empty_line

.ogfs_done:
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  compare_lines_slow — Compare cur_line_buf vs prev_line_buf
;  (used for stdin path)
; ═══════════════════════════════════════════════════════════
compare_lines_slow:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    lea     r8, [rel prev_line_buf]
    mov     r9, [rel prev_line_len]
    lea     r10, [rel cur_line_buf]
    mov     r11, [rel cur_line_len]

    mov     rcx, [rel opt_skip_fields]
    test    rcx, rcx
    jz      .cls_skip_chars

    push    r8
    push    r9
    push    r10
    push    r11

    mov     rdi, r8
    mov     rsi, r9
    mov     rdx, rcx
    call    skip_fields_fn
    mov     r12, rax

    mov     rdi, [rsp + 8]
    mov     rsi, [rsp]
    mov     rdx, [rel opt_skip_fields]
    call    skip_fields_fn
    mov     r13, rax

    pop     r11
    pop     r10
    pop     r9
    pop     r8
    jmp     .cls_apply_skip_chars

.cls_skip_chars:
    xor     r12d, r12d
    xor     r13d, r13d

.cls_apply_skip_chars:
    mov     rcx, [rel opt_skip_chars]
    add     r12, rcx
    add     r13, rcx

    cmp     r12, r9
    jle     .cls_prev_ok
    mov     r12, r9
.cls_prev_ok:
    cmp     r13, r11
    jle     .cls_cur_ok
    mov     r13, r11
.cls_cur_ok:

    lea     r14, [r8 + r12]
    mov     rbx, r9
    sub     rbx, r12

    lea     r15, [r10 + r13]
    mov     rcx, r11
    sub     rcx, r13

    mov     rax, [rel opt_check_chars]
    cmp     rax, -1
    je      .cls_no_limit
    cmp     rbx, rax
    jle     .cls_prev_limited
    mov     rbx, rax
.cls_prev_limited:
    cmp     rcx, rax
    jle     .cls_cur_limited
    mov     rcx, rax
.cls_cur_limited:

.cls_no_limit:
    cmp     rbx, rcx
    jne     .cls_different

    test    rbx, rbx
    jz      .cls_equal

    cmp     byte [rel opt_case_insensitive], 0
    jne     .cls_case_insensitive

    ; SIMD comparison
    xor     ecx, ecx
.cls_simd_cmp:
    mov     rax, rbx
    sub     rax, rcx
    cmp     rax, 16
    jl      .cls_scalar_cmp
    movdqu  xmm0, [r14 + rcx]
    movdqu  xmm1, [r15 + rcx]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0
    cmp     eax, 0xFFFF
    jne     .cls_different
    add     rcx, 16
    jmp     .cls_simd_cmp

.cls_scalar_cmp:
    cmp     rcx, rbx
    jge     .cls_equal
    movzx   eax, byte [r14 + rcx]
    cmp     al, byte [r15 + rcx]
    jne     .cls_different
    inc     rcx
    jmp     .cls_scalar_cmp

.cls_case_insensitive:
    xor     ecx, ecx
.cls_ci_loop:
    cmp     rcx, rbx
    jge     .cls_equal
    movzx   eax, byte [r14 + rcx]
    movzx   edx, byte [r15 + rcx]
    cmp     al, 'a'
    jb      .cls_ci_no1
    cmp     al, 'z'
    ja      .cls_ci_no1
    sub     al, 32
.cls_ci_no1:
    cmp     dl, 'a'
    jb      .cls_ci_no2
    cmp     dl, 'z'
    ja      .cls_ci_no2
    sub     dl, 32
.cls_ci_no2:
    cmp     al, dl
    jne     .cls_different
    inc     rcx
    jmp     .cls_ci_loop

.cls_equal:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.cls_different:
    mov     eax, 1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  read_line — Read next line from input into cur_line_buf
;  Returns: rax = 0 (got line), 1 (EOF), -1 (error)
; ═══════════════════════════════════════════════════════════
read_line:
    push    rbx
    push    r14
    push    r15

    mov     qword [rel cur_line_len], 0
    movzx   r15d, byte [rel delimiter]

.rl_scan:
    mov     rax, [rel read_buf_pos]
    cmp     rax, [rel read_buf_end]
    jl      .rl_have_data

    mov     edi, [rel input_fd]
    lea     rsi, [rel read_buf]
    mov     edx, READ_BUF_SIZE
    call    asm_read
    test    rax, rax
    js      .rl_read_error
    jz      .rl_eof

    mov     qword [rel read_buf_pos], 0
    mov     [rel read_buf_end], rax

.rl_have_data:
    mov     r14, [rel read_buf_pos]
    mov     rbx, [rel read_buf_end]

    ; Set up SSE2 pattern
    movd    xmm1, r15d
    punpcklbw xmm1, xmm1
    punpcklwd xmm1, xmm1
    pshufd  xmm1, xmm1, 0

.rl_simd_scan:
    mov     rax, rbx
    sub     rax, r14
    cmp     rax, 16
    jl      .rl_scalar_scan

    lea     rdi, [rel read_buf]
    add     rdi, r14
    movdqu  xmm0, [rdi]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0

    test    eax, eax
    jnz     .rl_simd_found

    ; No delimiter — copy 16 bytes to cur_line_buf
    mov     rcx, [rel cur_line_len]
    lea     rdx, [rcx + 16]
    cmp     rdx, LINE_BUF_SIZE
    jge     .rl_line_overflow

    lea     rsi, [rel read_buf]
    add     rsi, r14
    lea     rdi, [rel cur_line_buf]
    add     rdi, rcx
    movdqu  xmm2, [rsi]
    movdqu  [rdi], xmm2
    add     qword [rel cur_line_len], 16
    add     r14, 16
    jmp     .rl_simd_scan

.rl_simd_found:
    bsf     ecx, eax

    test    ecx, ecx
    jz      .rl_found_at_pos

    mov     rax, [rel cur_line_len]
    lea     rdx, [rax + rcx]
    cmp     rdx, LINE_BUF_SIZE
    jge     .rl_line_overflow

    ; Copy ecx bytes
    push    rcx
    lea     rsi, [rel read_buf]
    add     rsi, r14
    lea     rdi, [rel cur_line_buf]
    add     rdi, rax
    mov     edx, ecx
    push    rcx
    mov     ecx, edx
    rep     movsb
    pop     rcx
    pop     rcx
    add     [rel cur_line_len], rcx

.rl_found_at_pos:
    add     r14, rcx
    inc     r14
    mov     [rel read_buf_pos], r14
    xor     eax, eax
    pop     r15
    pop     r14
    pop     rbx
    ret

.rl_scalar_scan:
    cmp     r14, rbx
    jge     .rl_need_more

    lea     rdi, [rel read_buf]
    movzx   eax, byte [rdi + r14]
    cmp     al, r15b
    je      .rl_scalar_found

    mov     rcx, [rel cur_line_len]
    cmp     rcx, LINE_BUF_SIZE
    jge     .rl_line_overflow_scalar
    lea     rdi, [rel cur_line_buf]
    mov     [rdi + rcx], al
    inc     qword [rel cur_line_len]
    inc     r14
    jmp     .rl_scalar_scan

.rl_scalar_found:
    inc     r14
    mov     [rel read_buf_pos], r14
    xor     eax, eax
    pop     r15
    pop     r14
    pop     rbx
    ret

.rl_need_more:
    mov     [rel read_buf_pos], rbx
    jmp     .rl_scan

.rl_eof:
    cmp     qword [rel cur_line_len], 0
    jg      .rl_eof_partial
    mov     eax, 1
    pop     r15
    pop     r14
    pop     rbx
    ret

.rl_eof_partial:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     rbx
    ret

.rl_read_error:
    mov     eax, -1
    pop     r15
    pop     r14
    pop     rbx
    ret

.rl_line_overflow:
    add     r14, 16
    mov     [rel read_buf_pos], r14
    xor     eax, eax
    pop     r15
    pop     r14
    pop     rbx
    ret

.rl_line_overflow_scalar:
    inc     r14
    mov     [rel read_buf_pos], r14
    xor     eax, eax
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  skip_fields_fn(rdi=line, rsi=len, rdx=nfields) -> rax=offset
; ═══════════════════════════════════════════════════════════
skip_fields_fn:
    push    rbx
    xor     eax, eax
    mov     rcx, rdx

.sf_loop:
    test    rcx, rcx
    jz      .sf_done

.sf_skip_blanks:
    cmp     rax, rsi
    jge     .sf_done
    movzx   edx, byte [rdi + rax]
    cmp     dl, ' '
    je      .sf_blank
    cmp     dl, 9
    je      .sf_blank
    jmp     .sf_skip_nonblanks
.sf_blank:
    inc     rax
    jmp     .sf_skip_blanks

.sf_skip_nonblanks:
    cmp     rax, rsi
    jge     .sf_done
    movzx   edx, byte [rdi + rax]
    cmp     dl, ' '
    je      .sf_field_done
    cmp     dl, 9
    je      .sf_field_done
    inc     rax
    jmp     .sf_skip_nonblanks

.sf_field_done:
    dec     rcx
    jmp     .sf_loop

.sf_done:
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  swap_to_prev — Copy cur_line_buf to prev_line_buf
; ═══════════════════════════════════════════════════════════
swap_to_prev:
    push    rcx
    push    rsi
    push    rdi

    mov     rcx, [rel cur_line_len]
    mov     [rel prev_line_len], rcx

    lea     rsi, [rel cur_line_buf]
    lea     rdi, [rel prev_line_buf]
    rep     movsb

    pop     rdi
    pop     rsi
    pop     rcx
    ret

; ═══════════════════════════════════════════════════════════
;  emit_empty_line — Emit just a delimiter
; ═══════════════════════════════════════════════════════════
emit_empty_line:
    lea     rax, [r12 + 1]
    cmp     rax, OUT_BUF_SIZE
    jl      .eel_ok
    call    flush_output
    test    eax, eax
    jnz     .eel_error
.eel_ok:
    lea     rdi, [rel out_buf]
    add     rdi, r12
    movzx   eax, byte [rel delimiter]
    mov     [rdi], al
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .eel_done
    call    flush_output
    test    eax, eax
    jnz     .eel_error
.eel_done:
    ret
.eel_error:
    mov     ebp, 1
    ret

; ═══════════════════════════════════════════════════════════
;  emit_count_prefix(rdi=count) — Emit "%7d " format
; ═══════════════════════════════════════════════════════════
emit_count_prefix:
    push    rbx
    push    r13

    mov     rbx, rdi

    ; Fast path for small counts (1-9)
    cmp     rbx, 10
    jge     .ecp_general

    ; Single digit: "      N " = 7 spaces + digit + space = 8 bytes
    lea     rax, [r12 + 8]
    cmp     rax, OUT_BUF_SIZE
    jl      .ecp_fast_ok
    call    flush_output
    test    eax, eax
    jnz     .ecp_error
.ecp_fast_ok:
    lea     rdi, [rel out_buf]
    add     rdi, r12
    ; Write 6 spaces
    mov     dword [rdi], '    '
    mov     word [rdi+4], '  '
    ; Write digit + space
    lea     eax, [ebx + '0']
    mov     [rdi+6], al
    mov     byte [rdi+7], ' '
    add     r12, 8
    jmp     .ecp_done

.ecp_general:
    ; Convert count to decimal string
    lea     rdi, [rel count_buf + 20]
    mov     rax, rbx
    xor     ecx, ecx

.ecp_digit_loop:
    xor     edx, edx
    mov     r13, 10
    div     r13
    add     dl, '0'
    dec     rdi
    mov     [rdi], dl
    inc     ecx
    test    rax, rax
    jnz     .ecp_digit_loop

    mov     r13, rcx                ; digit count

    ; Ensure space in output buffer
    mov     rax, 7
    cmp     r13, rax
    jg      .ecp_use_actual_width
    jmp     .ecp_pad
.ecp_use_actual_width:
    mov     rax, r13
.ecp_pad:
    inc     rax
    lea     rdx, [r12 + rax]
    cmp     rdx, OUT_BUF_SIZE
    jl      .ecp_space_ok
    push    rdi
    push    rcx
    push    rax
    call    flush_output
    pop     rax
    pop     rcx
    pop     rdi
    test    eax, eax
    jnz     .ecp_error
    mov     rax, 7
    cmp     r13, rax
    jle     .ecp_space_ok
    mov     rax, r13
    inc     rax
.ecp_space_ok:

    mov     rsi, rdi
    lea     rdi, [rel out_buf]
    add     rdi, r12

    cmp     r13, 7
    jge     .ecp_no_pad

    mov     rcx, 7
    sub     rcx, r13
.ecp_pad_loop:
    mov     byte [rdi], ' '
    inc     rdi
    dec     rcx
    jnz     .ecp_pad_loop
    mov     rcx, r13
    rep     movsb
    mov     byte [rdi], ' '
    lea     rax, [r12 + 7 + 1]
    mov     r12, rax
    jmp     .ecp_done

.ecp_no_pad:
    mov     rcx, r13
    rep     movsb
    mov     byte [rdi], ' '
    lea     rax, [r13 + 1]
    add     r12, rax
    jmp     .ecp_done

.ecp_done:
    pop     r13
    pop     rbx
    ret
.ecp_error:
    mov     ebp, 1
    pop     r13
    pop     rbx
    ret

; ─── flush_output() ──────────────────────────────────────
flush_output:
    test    r12, r12
    jz      .fo_nothing

    mov     edi, [rel output_fd]
    lea     rsi, [rel out_buf]
    mov     rdx, r12
    call    asm_write_all
    xor     r12d, r12d
    ret

.fo_nothing:
    xor     eax, eax
    ret

; ─── strcmp(rdi=str1, rsi=str2) → eax=0 if equal ────────
strcmp:
.sc_loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .sc_ne
    test    al, al
    jz      .sc_eq
    inc     rdi
    inc     rsi
    jmp     .sc_loop
.sc_eq:
    xor     eax, eax
    ret
.sc_ne:
    mov     eax, 1
    ret

; ─── strncmp(rdi=str1, rsi=str2, rcx=n) → eax=0 if first n bytes match ──
strncmp:
    test    rcx, rcx
    jz      .sn_eq
.sn_loop:
    movzx   eax, byte [rdi]
    movzx   edx, byte [rsi]
    cmp     al, dl
    jne     .sn_ne
    test    al, al
    jz      .sn_eq
    inc     rdi
    inc     rsi
    dec     rcx
    jnz     .sn_loop
.sn_eq:
    xor     eax, eax
    ret
.sn_ne:
    mov     eax, 1
    ret

; ─── strlen(rdi=str) → rax=length ───────────────────────
strlen:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; ─── parse_number(rdi=str) → rax=number, -1 on error ────
parse_number:
    xor     rax, rax
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .pn_error

.pn_loop:
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .pn_done
    sub     cl, '0'
    cmp     cl, 9
    ja      .pn_error
    imul    rax, 10
    movzx   ecx, cl
    add     rax, rcx
    inc     rdi
    jmp     .pn_loop

.pn_done:
    ret
.pn_error:
    mov     rax, -1
    ret

; ─── Error helpers ───────────────────────────────────────

print_error_simple:
    push    rbx
    mov     rbx, rdi

    mov     rdi, STDERR
    lea     rsi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all

    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_newline]
    mov     rdx, 1
    call    asm_write_all

    pop     rbx
    ret

print_error_msg:
    push    rbx
    mov     rbx, rdi

    call    print_error_simple

    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all

    pop     rbx
    ret

err_file:
    push    rbx
    push    r13
    mov     rbx, rdi
    mov     r13d, esi

    mov     rdi, STDERR
    lea     rsi, [rel str_prefix]
    mov     rdx, str_prefix_len
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

err_unrecognized_option:
    push    rbx
    mov     rbx, rsi

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

err_invalid_option:
    push    rbx
    mov     rbx, rsi

    mov     rdi, STDERR
    lea     rsi, [rel str_invalid_opt]
    mov     rdx, str_invalid_opt_len
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rbx + 1]
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

err_extra_operand:
    push    rbx
    mov     rbx, rdi

    mov     rdi, STDERR
    lea     rsi, [rel str_extra_operand]
    mov     rdx, str_extra_operand_len
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_quote_open]
    mov     rdx, 1
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

; Mask lookup table for short-line qword comparison (indexed by line length 0-7)
; mask_table[n] = (1 << (n*8)) - 1 = low n bytes set
align 64
mask_table:
    dq 0x0000000000000000              ; len=0: no bytes
    dq 0x00000000000000FF              ; len=1: low 1 byte
    dq 0x000000000000FFFF              ; len=2: low 2 bytes
    dq 0x0000000000FFFFFF              ; len=3: low 3 bytes
    dq 0x00000000FFFFFFFF              ; len=4: low 4 bytes
    dq 0x000000FFFFFFFFFF              ; len=5: low 5 bytes
    dq 0x0000FFFFFFFFFFFF              ; len=6: low 6 bytes
    dq 0x00FFFFFFFFFFFFFF              ; len=7: low 7 bytes

align 16
; sigaction for SIGPIPE: sa_handler=SIG_DFL, sa_flags=SA_RESTORER, sa_restorer=0
sigact_buf:
    dq 0            ; sa_handler = SIG_DFL
    dq 0x04000000   ; sa_flags = SA_RESTORER
    dq 0            ; sa_restorer
    dq 0            ; sa_mask

str_prefix:     db "uniq: "
str_prefix_len equ $ - str_prefix

str_newline:    db 10
str_colon_space: db ": "
str_quote_open: db "'"
str_quote_nl:   db "'", 10

str_help_opt:       db "--help", 0
str_version_opt:    db "--version", 0
str_count_opt:      db "--count", 0
str_repeated_opt:   db "--repeated", 0
str_unique_opt:     db "--unique", 0
str_ignorecase_opt: db "--ignore-case", 0
str_zeroterm_opt:   db "--zero-terminated", 0

; Prefixes for options with =value
str_allrep_prefix:  db "--all-repeated", 0
str_skipfields_prefix: db "--skip-fields=", 0
str_skipchars_prefix:  db "--skip-chars=", 0
str_checkchars_prefix: db "--check-chars=", 0
str_group_prefix:   db "--group", 0

; Space-separated long options
str_skipfields_opt: db "--skip-fields", 0
str_skipchars_opt:  db "--skip-chars", 0
str_checkchars_opt: db "--check-chars", 0

; Method strings
str_method_none:    db "none", 0
str_method_prepend: db "prepend", 0
str_method_separate: db "separate", 0
str_method_append:  db "append", 0
str_method_both:    db "both", 0

str_write_error:    db "write error", 0

str_unrecognized:   db "uniq: unrecognized option '", 0
str_unrecognized_len equ 27

str_try_help: db "Try 'uniq --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_invalid_opt: db "uniq: invalid option -- '"
str_invalid_opt_len equ $ - str_invalid_opt

str_extra_operand: db "uniq: extra operand "
str_extra_operand_len equ $ - str_extra_operand

str_missing_arg_f: db "option requires an argument -- 'f'", 0
str_missing_arg_s: db "option requires an argument -- 's'", 0
str_missing_arg_w: db "option requires an argument -- 'w'", 0
str_invalid_number: db "invalid number", 0
str_invalid_allrep: db "invalid argument for --all-repeated", 0

help_text:
    db "Usage: uniq [OPTION]... [INPUT [OUTPUT]]", 10
    db "Filter adjacent matching lines from INPUT (or standard input),", 10
    db "writing to OUTPUT (or standard output).", 10
    db 10
    db "With no options, matching lines are merged to the first occurrence.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -c, --count           prefix lines by the number of occurrences", 10
    db "  -d, --repeated        only print duplicate lines, one for each group", 10
    db "  -D                    print all duplicate lines", 10
    db "      --all-repeated[=METHOD]  like -D, but allow separating groups", 10
    db "                                 with an empty line;", 10
    db "                                 METHOD={none(default),prepend,separate}", 10
    db "  -f, --skip-fields=N   avoid comparing the first N fields", 10
    db "      --group[=METHOD]  show all items, separating groups with an empty line;", 10
    db "                          METHOD={separate(default),prepend,append,both}", 10
    db "  -i, --ignore-case     ignore differences in case when comparing", 10
    db "  -s, --skip-chars=N    avoid comparing the first N characters", 10
    db "  -u, --unique          only print unique lines", 10
    db "  -z, --zero-terminated     line delimiter is NUL, not newline", 10
    db "  -w, --check-chars=N   compare no more than N characters in lines", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "A field is a run of blanks (usually spaces and/or TABs), then non-blank", 10
    db "characters.  Fields are skipped before chars.", 10
help_text_len equ $ - help_text

version_text:
    db "uniq (fcoreutils) 0.1.0", 10
version_text_len equ $ - version_text

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

; Options
opt_mode:               resb 1
opt_flag_d:             resb 1
opt_flag_u:             resb 1
opt_count:              resb 1
opt_case_insensitive:   resb 1
opt_zero_terminated:    resb 1
opt_allrep_method:      resb 1
opt_group_method:       resb 1
delimiter:              resb 1
align 8
opt_skip_fields:        resq 1
opt_skip_chars:         resq 1
opt_check_chars:        resq 1
input_file:             resq 1
output_file:            resq 1
input_fd:               resd 1
output_fd:              resd 1
use_mmap:               resb 1

; mmap state
align 8
mmap_addr:              resq 1
mmap_len:               resq 1

; mmap processing state
prev_mmap_ptr:          resq 1
prev_mmap_len:          resq 1

; State (for slow path)
align 8
count:                  resq 1
first_group:            resb 1
align 8
read_buf_pos:           resq 1
read_buf_end:           resq 1
prev_line_len:          resq 1
cur_line_len:           resq 1

; Buffers
align 16
read_buf:               resb READ_BUF_SIZE
out_buf:                resb OUT_BUF_SIZE
prev_line_buf:          resb LINE_BUF_SIZE
cur_line_buf:           resb LINE_BUF_SIZE
count_buf:              resb 32

section .note.GNU-stack noalloc noexec nowrite progbits
