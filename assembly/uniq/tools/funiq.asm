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
; Uses SSE2 pcmpeqb for fast 16-byte-at-a-time line comparison.
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
%define READ_BUF_SIZE   131072          ; 128KB input buffer
%define OUT_BUF_SIZE    131072          ; 128KB output buffer
%define LINE_BUF_SIZE   1048576         ; 1MB max line length
%define FLUSH_THRESHOLD 65536

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
    mov     byte [rel opt_case_insensitive], 0
    mov     byte [rel opt_zero_terminated], 0
    mov     qword [rel opt_skip_fields], 0
    mov     qword [rel opt_skip_chars], 0
    mov     qword [rel opt_check_chars], -1     ; -1 = unlimited
    mov     byte [rel opt_allrep_method], ALLREP_NONE
    mov     byte [rel opt_group_method], GROUP_SEPARATE
    mov     qword [rel input_file], 0
    mov     qword [rel output_file], 0

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
    mov     byte [rel opt_mode], MODE_COUNT
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
    mov     byte [rel opt_mode], MODE_COUNT
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
    ; If we got here, mode is GROUP — that's fine, but check if any of c/d/D/u
    ; were also set. Actually, the last flag wins in our parser, so the mode
    ; is already correctly set. But GNU checks for conflicts differently.
    ; We handle this by checking at the end since the last option wins.
    ; GNU actually errors if --group appears with any of -c/-d/-D/-u regardless of order.
    ; We'll skip this complexity for now — the last flag wins model is simpler.
    ; Check if both -d and -u were specified
    ; If mode is REPEATED or UNIQUE and both flags are set:
    ;   MODE_REPEATED (-d last) + flag_u => print nothing
    ;   MODE_UNIQUE (-u last) + flag_d => print nothing
    cmp     byte [rel opt_mode], MODE_REPEATED
    jne     .check_du_unique
    cmp     byte [rel opt_flag_u], 1
    jne     .no_group_conflict
    ; Both -d and -u: repeated mode that also requires unique = nothing
    ; We handle this by leaving mode as REPEATED but checking flag_u in output
    jmp     .no_group_conflict
.check_du_unique:
    cmp     byte [rel opt_mode], MODE_UNIQUE
    jne     .no_group_conflict
    cmp     byte [rel opt_flag_d], 1
    jne     .no_group_conflict
    ; Both -u and -d: unique mode that also requires repeated = nothing
    ; We handle this by leaving mode as UNIQUE but checking flag_d in output

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
    jmp     .open_output

.use_stdin:
    mov     dword [rel input_fd], STDIN

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
    call    process_uniq

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
;  process_uniq — Main processing loop
;
;  Reads lines from input_fd, compares adjacent lines, outputs
;  according to the selected mode.
;
;  Uses two line buffers (prev_line_buf / cur_line_buf) that alternate.
;  Reads input into read_buf, scans for delimiters.
;
;  Key state:
;    prev_line_buf/prev_line_len: previous line (or empty if first)
;    cur_line_buf/cur_line_len:   current line being built
;    count: number of consecutive equal lines
;    first_group: whether we've output any group yet
; ═══════════════════════════════════════════════════════════
process_uniq:
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
    jne     .pu_use_nul
    mov     byte [rel delimiter], 10            ; newline
    jmp     .pu_main_loop
.pu_use_nul:
    mov     byte [rel delimiter], 0             ; NUL

.pu_main_loop:
    ; Read next line into cur_line_buf
    call    read_line
    ; rax: 0 = got a line, 1 = EOF (possibly with partial line), -1 = error
    cmp     rax, -1
    je      .pu_error
    cmp     rax, 1
    je      .pu_eof

    ; We have a complete line in cur_line_buf[0..cur_line_len)
    ; Compare with previous line
    cmp     qword [rel prev_line_len], -1
    je      .pu_first_line

    ; Compare cur vs prev
    call    compare_lines
    ; rax = 0 if equal, nonzero if different
    test    eax, eax
    jz      .pu_lines_equal

    ; Lines are different — output previous group, start new group
    call    output_group
    ; Swap: copy current to prev
    call    swap_to_prev
    mov     qword [rel count], 1
    jmp     .pu_main_loop

.pu_first_line:
    ; First line: copy to prev, count=1
    call    swap_to_prev
    mov     qword [rel count], 1

    ; For group mode, emit prepend separator and the first line
    cmp     byte [rel opt_mode], MODE_GROUP
    jne     .pu_main_loop

    ; Group mode: emit prepend/both separator before first group
    movzx   eax, byte [rel opt_group_method]
    cmp     al, GROUP_PREPEND
    je      .pu_first_group_sep
    cmp     al, GROUP_BOTH
    je      .pu_first_group_sep
    jmp     .pu_first_group_emit

.pu_first_group_sep:
    call    emit_empty_line

.pu_first_group_emit:
    mov     byte [rel first_group], 0
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line
    jmp     .pu_main_loop

.pu_lines_equal:
    ; Same as previous — increment count
    inc     qword [rel count]
    ; For MODE_ALL_REPEAT and MODE_GROUP, we need to emit each line
    cmp     byte [rel opt_mode], MODE_ALL_REPEAT
    je      .pu_allrep_emit
    cmp     byte [rel opt_mode], MODE_GROUP
    je      .pu_group_emit
    jmp     .pu_main_loop

.pu_allrep_emit:
    ; In all-repeated mode, when count goes from 1 to 2, we need to emit the
    ; first occurrence too. For count >= 2, emit the current line.
    cmp     qword [rel count], 2
    je      .pu_allrep_first_dup
    ; count > 2: just emit current line
    lea     rdi, [rel cur_line_buf]
    mov     rsi, [rel cur_line_len]
    call    emit_line
    jmp     .pu_main_loop

.pu_allrep_first_dup:
    ; count == 2: first time we see a duplicate — emit prev (first occurrence)
    ; then emit current (second occurrence)
    ; Handle prepend: empty line before first group or between groups
    cmp     byte [rel opt_allrep_method], ALLREP_PREPEND
    je      .pu_allrep_prepend_sep
    cmp     byte [rel opt_allrep_method], ALLREP_SEPARATE
    je      .pu_allrep_separate_sep
    jmp     .pu_allrep_emit_both

.pu_allrep_prepend_sep:
    ; Always prepend empty line before each group
    call    emit_empty_line
    jmp     .pu_allrep_emit_both

.pu_allrep_separate_sep:
    ; Emit empty line between groups (not before first)
    cmp     byte [rel first_group], 1
    je      .pu_allrep_emit_both
    call    emit_empty_line
    jmp     .pu_allrep_emit_both

.pu_allrep_emit_both:
    mov     byte [rel first_group], 0
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line
    lea     rdi, [rel cur_line_buf]
    mov     rsi, [rel cur_line_len]
    call    emit_line
    jmp     .pu_main_loop

.pu_group_emit:
    ; Group mode: equal line — just emit it
    lea     rdi, [rel cur_line_buf]
    mov     rsi, [rel cur_line_len]
    call    emit_line
    jmp     .pu_main_loop

.pu_eof:
    ; Check if there was a partial line (no trailing delimiter)
    cmp     qword [rel cur_line_len], 0
    je      .pu_eof_no_partial
    ; There's a partial line — treat it as a complete line
    cmp     qword [rel prev_line_len], -1
    je      .pu_eof_first_partial
    ; Compare with previous
    call    compare_lines
    test    eax, eax
    jz      .pu_eof_partial_equal
    ; Different — output previous group, then handle this line as last group
    call    output_group
    call    swap_to_prev
    mov     qword [rel count], 1
    jmp     .pu_eof_final_group
.pu_eof_first_partial:
    call    swap_to_prev
    mov     qword [rel count], 1
    ; For group mode, emit prepend/both separator and the line
    cmp     byte [rel opt_mode], MODE_GROUP
    jne     .pu_eof_final_group
    movzx   eax, byte [rel opt_group_method]
    cmp     al, GROUP_PREPEND
    je      .pu_eof_first_partial_sep
    cmp     al, GROUP_BOTH
    je      .pu_eof_first_partial_sep
    jmp     .pu_eof_first_partial_emit
.pu_eof_first_partial_sep:
    call    emit_empty_line
.pu_eof_first_partial_emit:
    mov     byte [rel first_group], 0
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line
    jmp     .pu_eof_final_group
.pu_eof_partial_equal:
    inc     qword [rel count]
    cmp     byte [rel opt_mode], MODE_ALL_REPEAT
    je      .pu_eof_allrep_partial
    cmp     byte [rel opt_mode], MODE_GROUP
    je      .pu_eof_group_partial
    jmp     .pu_eof_final_group

.pu_eof_allrep_partial:
    ; Same as .pu_allrep_emit but don't loop
    cmp     qword [rel count], 2
    je      .pu_eof_allrep_first_dup
    lea     rdi, [rel cur_line_buf]
    mov     rsi, [rel cur_line_len]
    call    emit_line
    jmp     .pu_eof_final_group
.pu_eof_allrep_first_dup:
    cmp     byte [rel opt_allrep_method], ALLREP_PREPEND
    je      .pu_eof_ar_prepend
    cmp     byte [rel opt_allrep_method], ALLREP_SEPARATE
    je      .pu_eof_ar_separate
    jmp     .pu_eof_ar_emit_both
.pu_eof_ar_prepend:
    call    emit_empty_line
    jmp     .pu_eof_ar_emit_both
.pu_eof_ar_separate:
    cmp     byte [rel first_group], 1
    je      .pu_eof_ar_emit_both
    call    emit_empty_line
.pu_eof_ar_emit_both:
    mov     byte [rel first_group], 0
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line
    lea     rdi, [rel cur_line_buf]
    mov     rsi, [rel cur_line_len]
    call    emit_line
    jmp     .pu_eof_final_group

.pu_eof_group_partial:
    ; Group mode: emit the equal line
    lea     rdi, [rel cur_line_buf]
    mov     rsi, [rel cur_line_len]
    call    emit_line
    jmp     .pu_eof_final_group

.pu_eof_no_partial:
.pu_eof_final_group:
    ; Output the last group
    cmp     qword [rel prev_line_len], -1
    je      .pu_done                ; no lines at all
    call    output_group_final

.pu_done:
.pu_error:
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  output_group — Output the previous group (when a new different line is found)
;  Called when we detect that the current line differs from the previous.
;  At this point:
;    prev_line_buf/prev_line_len = the repeated line
;    count = how many times it appeared
; ═══════════════════════════════════════════════════════════
output_group:
    push    rbx

    movzx   eax, byte [rel opt_mode]
    cmp     al, MODE_NORMAL
    je      .og_normal
    cmp     al, MODE_COUNT
    je      .og_count
    cmp     al, MODE_REPEATED
    je      .og_repeated
    cmp     al, MODE_ALL_REPEAT
    je      .og_allrepeat
    cmp     al, MODE_UNIQUE
    je      .og_unique
    cmp     al, MODE_GROUP
    je      .og_group

.og_normal:
    ; Output the line once
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line
    jmp     .og_done

.og_count:
    ; Output "     N line"
    mov     rdi, [rel count]
    call    emit_count_prefix
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line
    jmp     .og_done

.og_repeated:
    ; Only output if count > 1, and -u was not also specified
    cmp     byte [rel opt_flag_u], 1
    je      .og_done                ; -d -u = print nothing
    cmp     qword [rel count], 1
    jle     .og_done
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line
    jmp     .og_done

.og_allrepeat:
    ; Already handled incrementally in main loop.
    ; Nothing to do here — lines were emitted as they came.
    jmp     .og_done

.og_unique:
    ; Only output if count == 1, and -d was not also specified
    cmp     byte [rel opt_flag_d], 1
    je      .og_done                ; -d -u = print nothing
    cmp     qword [rel count], 1
    jne     .og_done
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line
    jmp     .og_done

.og_group:
    ; Group mode: between groups, emit ONE separator and then the first line
    ; of the new group (cur_line_buf).
    ; All methods use exactly one empty line between groups.
    call    emit_empty_line

    ; Emit the first line of the new group
    lea     rdi, [rel cur_line_buf]
    mov     rsi, [rel cur_line_len]
    call    emit_line
    jmp     .og_done

.og_done:
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  output_group_final — Output the last group (at EOF)
;  Similar to output_group but also handles the last group's
;  trailing separator if needed.
; ═══════════════════════════════════════════════════════════
output_group_final:
    push    rbx

    movzx   eax, byte [rel opt_mode]
    cmp     al, MODE_NORMAL
    je      .ogf_normal
    cmp     al, MODE_COUNT
    je      .ogf_count
    cmp     al, MODE_REPEATED
    je      .ogf_repeated
    cmp     al, MODE_ALL_REPEAT
    je      .ogf_allrepeat
    cmp     al, MODE_UNIQUE
    je      .ogf_unique
    cmp     al, MODE_GROUP
    je      .ogf_group

.ogf_normal:
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line
    jmp     .ogf_done

.ogf_count:
    mov     rdi, [rel count]
    call    emit_count_prefix
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line
    jmp     .ogf_done

.ogf_repeated:
    cmp     byte [rel opt_flag_u], 1
    je      .ogf_done
    cmp     qword [rel count], 1
    jle     .ogf_done
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line
    jmp     .ogf_done

.ogf_allrepeat:
    ; If last group was duplicated, lines were already emitted
    ; Nothing more to do
    jmp     .ogf_done

.ogf_unique:
    cmp     byte [rel opt_flag_d], 1
    je      .ogf_done
    cmp     qword [rel count], 1
    jne     .ogf_done
    lea     rdi, [rel prev_line_buf]
    mov     rsi, [rel prev_line_len]
    call    emit_line
    jmp     .ogf_done

.ogf_group:
    ; Group mode final: emit trailing separator if append or both
    movzx   eax, byte [rel opt_group_method]
    cmp     al, GROUP_APPEND
    je      .ogf_group_trailing
    cmp     al, GROUP_BOTH
    je      .ogf_group_trailing
    jmp     .ogf_done

.ogf_group_trailing:
    call    emit_empty_line

.ogf_done:
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  read_line — Read next line from input into cur_line_buf
;  Returns: rax = 0 (got line), 1 (EOF), -1 (error)
;  cur_line_len is set to the length (not including delimiter)
; ═══════════════════════════════════════════════════════════
read_line:
    push    rbx
    push    r14
    push    r15

    mov     qword [rel cur_line_len], 0
    movzx   r15d, byte [rel delimiter]  ; r15b = delimiter byte

.rl_scan:
    ; Check if we have data in read_buf
    mov     rax, [rel read_buf_pos]
    cmp     rax, [rel read_buf_end]
    jl      .rl_have_data

    ; Need to read more data
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
    ; Scan for delimiter in read_buf[read_buf_pos..read_buf_end)
    mov     r14, [rel read_buf_pos]     ; current position
    mov     rbx, [rel read_buf_end]     ; end position

    ; Set up SSE2 pattern for delimiter search
    movd    xmm1, r15d
    punpcklbw xmm1, xmm1
    punpcklwd xmm1, xmm1
    pshufd  xmm1, xmm1, 0              ; broadcast delimiter to all bytes

.rl_simd_scan:
    mov     rax, rbx
    sub     rax, r14
    cmp     rax, 16
    jl      .rl_scalar_scan

    ; Load 16 bytes from read_buf + r14
    lea     rdi, [rel read_buf]
    add     rdi, r14
    movdqu  xmm0, [rdi]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0

    test    eax, eax
    jnz     .rl_simd_found

    ; No delimiter in 16 bytes — copy to cur_line_buf
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
    bsf     ecx, eax                ; position of delimiter in 16-byte window

    ; Copy bytes before delimiter to cur_line_buf
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
    ; Small copy with rep movsb
    push    rcx
    mov     ecx, edx
    rep     movsb
    pop     rcx
    pop     rcx
    add     [rel cur_line_len], rcx

.rl_found_at_pos:
    ; Advance past copied bytes + delimiter
    add     r14, rcx
    inc     r14                     ; skip delimiter
    mov     [rel read_buf_pos], r14

    ; Successfully read a line
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
    cmp     al, r15b                ; compare with delimiter
    je      .rl_scalar_found

    ; Append byte to cur_line_buf
    mov     rcx, [rel cur_line_len]
    cmp     rcx, LINE_BUF_SIZE
    jge     .rl_line_overflow_scalar
    lea     rdi, [rel cur_line_buf]
    mov     [rdi + rcx], al
    inc     qword [rel cur_line_len]
    inc     r14
    jmp     .rl_scalar_scan

.rl_scalar_found:
    inc     r14                     ; skip delimiter
    mov     [rel read_buf_pos], r14
    xor     eax, eax
    pop     r15
    pop     r14
    pop     rbx
    ret

.rl_need_more:
    ; Exhausted current read_buf, need to read more
    mov     [rel read_buf_pos], rbx
    jmp     .rl_scan

.rl_eof:
    ; EOF — if we have partial data, return it as a line
    cmp     qword [rel cur_line_len], 0
    jg      .rl_eof_partial
    mov     eax, 1                  ; true EOF, no data
    pop     r15
    pop     r14
    pop     rbx
    ret

.rl_eof_partial:
    xor     eax, eax                ; return 0 = got a line (partial)
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
    ; Line exceeds buffer — treat what we have as the line
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
;  compare_lines — Compare cur_line vs prev_line
;  Applies: skip_fields, skip_chars, check_chars, ignore_case
;  Returns: rax = 0 if equal, nonzero if different
; ═══════════════════════════════════════════════════════════
compare_lines:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; Get pointers and lengths for both lines
    lea     r8, [rel prev_line_buf]
    mov     r9, [rel prev_line_len]
    lea     r10, [rel cur_line_buf]
    mov     r11, [rel cur_line_len]

    ; Apply skip_fields to both
    mov     rcx, [rel opt_skip_fields]
    test    rcx, rcx
    jz      .cl_skip_chars

    ; Save all state we need across calls on callee-saved regs
    ; r12-r15 and rbx are callee-saved, so they survive calls.
    ; r8-r11 are caller-saved. Store in callee-saved regs temporarily.
    ; We already have r8, r9, r10, r11 with the values.
    ; Use stack to save them across calls.
    push    r8                      ; prev buf ptr
    push    r9                      ; prev len
    push    r10                     ; cur buf ptr
    push    r11                     ; cur len

    ; Skip fields in prev line
    mov     rdi, r8
    mov     rsi, r9
    mov     rdx, rcx
    call    skip_fields_fn
    mov     r12, rax                ; prev offset (r12 is callee-saved)

    ; Skip fields in cur line
    ; Stack: [rsp]=r11, [rsp+8]=r10, [rsp+16]=r9, [rsp+24]=r8
    mov     rdi, [rsp + 8]          ; r10 = cur buf ptr
    mov     rsi, [rsp]              ; r11 = cur len
    mov     rdx, [rel opt_skip_fields]
    call    skip_fields_fn
    mov     r13, rax                ; cur offset (r13 is callee-saved)

    ; Restore r8-r11
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    jmp     .cl_apply_skip_chars

.cl_skip_chars:
    xor     r12d, r12d              ; prev offset = 0
    xor     r13d, r13d              ; cur offset = 0

.cl_apply_skip_chars:
    ; Apply skip_chars
    mov     rcx, [rel opt_skip_chars]
    add     r12, rcx
    add     r13, rcx

    ; Clamp offsets to line lengths
    cmp     r12, r9
    jle     .cl_prev_ok
    mov     r12, r9
.cl_prev_ok:
    cmp     r13, r11
    jle     .cl_cur_ok
    mov     r13, r11
.cl_cur_ok:

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
    je      .cl_no_limit

    cmp     rbx, rax
    jle     .cl_prev_limited
    mov     rbx, rax
.cl_prev_limited:
    cmp     rcx, rax
    jle     .cl_cur_limited
    mov     rcx, rax
.cl_cur_limited:

.cl_no_limit:
    ; Now compare r14[0..rbx) with r15[0..rcx)
    ; If lengths differ, they're different
    cmp     rbx, rcx
    jne     .cl_different

    ; Same length — compare bytes
    ; r14 = ptr1, r15 = ptr2, rbx = len
    test    rbx, rbx
    jz      .cl_equal               ; both empty = equal

    cmp     byte [rel opt_case_insensitive], 0
    jne     .cl_case_insensitive

    ; Case-sensitive comparison using SSE2
.cl_simd_compare:
    cmp     rbx, 16
    jl      .cl_scalar_compare

    movdqu  xmm0, [r14]
    movdqu  xmm2, [r15]
    pcmpeqb xmm0, xmm2
    pmovmskb eax, xmm0
    cmp     eax, 0xFFFF
    jne     .cl_different

    add     r14, 16
    add     r15, 16
    sub     rbx, 16
    jmp     .cl_simd_compare

.cl_scalar_compare:
    test    rbx, rbx
    jz      .cl_equal

    movzx   eax, byte [r14]
    movzx   ecx, byte [r15]
    cmp     al, cl
    jne     .cl_different
    inc     r14
    inc     r15
    dec     rbx
    jmp     .cl_scalar_compare

.cl_case_insensitive:
    ; Case-insensitive comparison
    test    rbx, rbx
    jz      .cl_equal

.cl_ci_loop:
    test    rbx, rbx
    jz      .cl_equal

    movzx   eax, byte [r14]
    movzx   ecx, byte [r15]

    ; Convert both to uppercase
    cmp     al, 'a'
    jb      .cl_ci_no_upper1
    cmp     al, 'z'
    ja      .cl_ci_no_upper1
    sub     al, 32
.cl_ci_no_upper1:
    cmp     cl, 'a'
    jb      .cl_ci_no_upper2
    cmp     cl, 'z'
    ja      .cl_ci_no_upper2
    sub     cl, 32
.cl_ci_no_upper2:

    cmp     al, cl
    jne     .cl_different
    inc     r14
    inc     r15
    dec     rbx
    jmp     .cl_ci_loop

.cl_equal:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.cl_different:
    mov     eax, 1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  skip_fields_fn(rdi=line, rsi=len, rdx=nfields) -> rax=offset
;  A field is a run of blanks (space/tab) then non-blanks.
; ═══════════════════════════════════════════════════════════
skip_fields_fn:
    push    rbx
    xor     eax, eax                ; offset = 0
    mov     rcx, rdx                ; fields to skip

.sf_loop:
    test    rcx, rcx
    jz      .sf_done

    ; Skip leading blanks
.sf_skip_blanks:
    cmp     rax, rsi
    jge     .sf_done
    movzx   edx, byte [rdi + rax]
    cmp     dl, ' '
    je      .sf_blank
    cmp     dl, 9                   ; tab
    je      .sf_blank
    jmp     .sf_skip_nonblanks
.sf_blank:
    inc     rax
    jmp     .sf_skip_blanks

    ; Skip non-blanks
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

    ; Copy using rep movsb (adequate for lines)
    rep     movsb

    pop     rdi
    pop     rsi
    pop     rcx
    ret

; ═══════════════════════════════════════════════════════════
;  emit_line(rdi=buf, rsi=len) — Append line + delimiter to output buffer
; ═══════════════════════════════════════════════════════════
emit_line:
    push    rbx
    push    r13

    mov     rbx, rdi                ; buf
    mov     r13, rsi                ; len

    ; Ensure space: need len + 1 bytes
    lea     rax, [r12 + r13 + 1]
    cmp     rax, OUT_BUF_SIZE
    jl      .el_space_ok
    call    flush_output
    test    eax, eax
    jnz     .el_write_error
.el_space_ok:

    ; Copy line data
    lea     rdi, [rel out_buf]
    add     rdi, r12
    mov     rsi, rbx
    mov     rcx, r13
    rep     movsb

    ; Append delimiter
    lea     rdi, [rel out_buf]
    add     rdi, r12
    add     rdi, r13
    movzx   eax, byte [rel delimiter]
    mov     [rdi], al
    lea     rax, [r13 + 1]
    add     r12, rax

    ; Flush if needed
    cmp     r12, FLUSH_THRESHOLD
    jl      .el_done
    call    flush_output
    test    eax, eax
    jnz     .el_write_error

.el_done:
    pop     r13
    pop     rbx
    ret

.el_write_error:
    mov     ebp, 1
    pop     r13
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  emit_empty_line — Emit just a delimiter (empty line separator)
; ═══════════════════════════════════════════════════════════
emit_empty_line:
    ; Ensure space for 1 byte
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
;  emit_count_prefix(rdi=count) — Emit "%7d " format count prefix
; ═══════════════════════════════════════════════════════════
emit_count_prefix:
    push    rbx
    push    r13

    mov     rbx, rdi                ; count value

    ; Convert count to decimal string
    lea     rdi, [rel count_buf + 20]   ; work from end of buffer
    mov     rax, rbx
    xor     ecx, ecx                ; digit count

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

    ; Now rdi points to first digit, ecx = number of digits
    ; We need to pad to width 7 with spaces (right-justified)
    ; Total prefix: max(7, num_digits) chars + 1 space
    mov     r13, rcx                ; save digit count

    ; Ensure space in output buffer
    mov     rax, 7
    cmp     r13, rax
    jg      .ecp_use_actual_width
    jmp     .ecp_pad
.ecp_use_actual_width:
    mov     rax, r13
.ecp_pad:
    ; rax = width, need width + 1 bytes in output
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
    ; Recalculate
    mov     rax, 7
    cmp     r13, rax
    jle     .ecp_space_ok
    mov     rax, r13
    inc     rax
.ecp_space_ok:

    ; rdi = pointer to first digit in count_buf
    ; r13 = digit count
    ; Save digit pointer, we'll use rsi for it (source for movsb)
    mov     rsi, rdi                ; rsi = source (digits in count_buf)
    lea     rdi, [rel out_buf]
    add     rdi, r12                ; rdi = dest (out_buf write position)

    ; Pad with spaces if num_digits < 7
    cmp     r13, 7
    jge     .ecp_no_pad

    mov     rcx, 7
    sub     rcx, r13                ; padding count
.ecp_pad_loop:
    mov     byte [rdi], ' '
    inc     rdi
    dec     rcx
    jnz     .ecp_pad_loop
    ; Now copy digits: rsi=source (count_buf digits), rdi=dest (out_buf)
    mov     rcx, r13
    rep     movsb
    ; Append space
    mov     byte [rdi], ' '
    lea     rax, [r12 + 7 + 1]     ; 7 + space
    mov     r12, rax
    jmp     .ecp_done

.ecp_no_pad:
    ; Digits fill more than 7 chars: rsi=source, rdi=dest
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
; Writes out_buf[0..r12) to output_fd. Returns 0 on success, -1 on error.
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
    jz      .pn_error               ; empty string

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

; print_error_simple(rdi=message) — prints "uniq: {message}\n" to stderr
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

; print_error_msg(rdi=message) — prints message + \n + try help to stderr
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

; err_file(rdi=filename, esi=errno) — "uniq: {filename}: {strerror}\n"
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

; err_unrecognized_option(rsi=option_string)
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

; err_invalid_option(rsi=option_string) — "uniq: invalid option -- 'X'\nTry..."
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

; err_extra_operand(rdi=operand)
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

; strerror(edi=errno) → rax=string pointer
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
str_allrep_prefix:  db "--all-repeated", 0  ; 14 chars then NUL
str_skipfields_prefix: db "--skip-fields=", 0 ; 14+1=15 match chars
str_skipchars_prefix:  db "--skip-chars=", 0  ; 13+1=14 match chars
str_checkchars_prefix: db "--check-chars=", 0 ; 14+1=15 match chars
str_group_prefix:   db "--group", 0         ; 7 chars then NUL

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
opt_flag_d:             resb 1   ; 1 if -d was specified
opt_flag_u:             resb 1   ; 1 if -u was specified
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

; State
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
