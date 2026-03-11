; fcomm.asm — GNU-compatible "comm" in x86_64 Linux assembly
;
; Compare two sorted files line by line. Produces 3-column output:
;   Column 1: lines only in file1
;   Column 2: lines only in file2 (tab-indented)
;   Column 3: common lines (two tabs indented)
;
; Supported flags:
;   -1                suppress column 1
;   -2                suppress column 2
;   -3                suppress column 3
;   --check-order     check sort order strictly (stop on error)
;   --nocheck-order   disable sort order checking
;   --output-delimiter=STR  use STR instead of TAB
;   --total           output a summary line
;   -z / --zero-terminated  use NUL as line delimiter
;   --help / --version
;
; Performance optimizations:
;   - mmap() both input files (zero-copy, no read syscalls)
;   - SSE2 SIMD line comparison (pcmpeqb + pmovmskb)
;   - Large 1MB output buffer with threshold flushing
;   - For stdin (-), dynamically growing buffer via mmap/mremap
;
; Build (modular):
;   nasm -f elf64 -I include/ tools/fcomm.asm -o build/fcomm.o
;   nasm -f elf64 -I include/ lib/io.asm -o build/io.o
;   ld --gc-sections build/fcomm.o build/io.o -o fcomm

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close

; ─── Constants ───────────────────────────────────────────
%define OUT_BUF_SIZE    1048576         ; 1MB output buffer
%define FLUSH_THRESHOLD 786432          ; Flush at 768KB
%define STDIN_BUF_SIZE  16777216        ; 16MB stdin buffer
%define MAX_DELIM_LEN   256             ; max output delimiter length

; mmap constants
%define PROT_READ       1
%define MAP_PRIVATE     2
%define MAP_POPULATE    0x08000
%define MADV_SEQUENTIAL 2
%define SYS_MADVISE     28

; Order check modes
%define ORDER_DEFAULT   0               ; warn once per file, continue, exit 1
%define ORDER_STRICT    1               ; error, stop immediately
%define ORDER_NONE      2               ; no checking

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

    ; Initialize options to defaults
    mov     byte [rel opt_suppress1], 0
    mov     byte [rel opt_suppress2], 0
    mov     byte [rel opt_suppress3], 0
    mov     byte [rel opt_order_check], ORDER_DEFAULT
    mov     byte [rel opt_total], 0
    mov     byte [rel opt_zero_terminated], 0
    mov     qword [rel opt_delim_len], 0   ; 0 = use default tab
    mov     byte [rel opt_delim_set], 0    ; not explicitly set
    mov     qword [rel file1_path], 0
    mov     qword [rel file2_path], 0

    ; Parse arguments (skip argv[0])
    mov     rbx, 1                  ; arg index
    xor     ecx, ecx                ; seen_dashdash = 0
    mov     [rel seen_dashdash], cl

.parse_loop:
    cmp     rbx, r14
    jge     .parse_done

    mov     rsi, [r15 + rbx*8]      ; argv[i]

    ; If we've seen --, treat as operand
    cmp     byte [rel seen_dashdash], 0
    jne     .is_operand

    ; Check for '-' prefix
    cmp     byte [rsi], '-'
    jne     .is_operand
    cmp     byte [rsi+1], 0
    je      .is_operand             ; bare "-" is operand (stdin)

    cmp     byte [rsi+1], '-'
    je      .long_option

    ; Short option(s): -1, -2, -3, -z (can be combined)
    lea     rdi, [rsi + 1]          ; skip the '-'
    jmp     .parse_short_opts

.parse_short_opts:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .parse_next             ; end of short opts

    cmp     al, '1'
    je      .short_1
    cmp     al, '2'
    je      .short_2
    cmp     al, '3'
    je      .short_3
    cmp     al, 'z'
    je      .short_z

    ; Unknown short option
    push    rdi
    mov     rsi, [r15 + rbx*8]
    call    err_invalid_option
    pop     rdi
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.short_1:
    mov     byte [rel opt_suppress1], 1
    inc     rdi
    jmp     .parse_short_opts

.short_2:
    mov     byte [rel opt_suppress2], 1
    inc     rdi
    jmp     .parse_short_opts

.short_3:
    mov     byte [rel opt_suppress3], 1
    inc     rdi
    jmp     .parse_short_opts

.short_z:
    mov     byte [rel opt_zero_terminated], 1
    inc     rdi
    jmp     .parse_short_opts

.long_option:
    ; Starts with "--"
    cmp     byte [rsi+2], 0
    je      .set_dashdash           ; exactly "--"

    ; --help
    push    rbx
    lea     rdi, [rel str_help_opt]
    call    strcmp
    test    eax, eax
    jz      .do_help

    ; --version
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_version_opt]
    call    strcmp
    test    eax, eax
    jz      .do_version

    ; --check-order
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_check_order_opt]
    call    strcmp
    test    eax, eax
    jz      .long_check_order

    ; --nocheck-order
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_nocheck_order_opt]
    call    strcmp
    test    eax, eax
    jz      .long_nocheck_order

    ; --output-delimiter=STR (prefix match)
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_outdelim_prefix]
    mov     rcx, 19                 ; strlen("--output-delimiter=") = 19
    call    strncmp
    test    eax, eax
    jz      .long_outdelim

    ; --output-delimiter STR (space-separated)
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_outdelim_opt]
    call    strcmp
    test    eax, eax
    jz      .long_outdelim_space

    ; --total
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_total_opt]
    call    strcmp
    test    eax, eax
    jz      .long_total

    ; --zero-terminated
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_zeroterm_opt]
    call    strcmp
    test    eax, eax
    jz      .long_zeroterm

    ; Unknown long option
    pop     rbx
    push    rbx
    mov     rsi, [r15 + rbx*8]
    call    err_unrecognized_option
    pop     rbx
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.do_help:
    pop     rbx
    mov     rdi, STDOUT
    lea     rsi, [rel help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

.do_version:
    pop     rbx
    mov     rdi, STDOUT
    lea     rsi, [rel version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

.long_check_order:
    pop     rbx
    mov     byte [rel opt_order_check], ORDER_STRICT
    jmp     .parse_next

.long_nocheck_order:
    pop     rbx
    mov     byte [rel opt_order_check], ORDER_NONE
    jmp     .parse_next

.long_outdelim:
    ; "--output-delimiter=STR" - value starts at rsi+19
    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rsi+19]
    ; Copy delimiter string
    call    copy_output_delimiter
    mov     byte [rel opt_delim_set], 1
    pop     rbx
    jmp     .parse_next

.long_outdelim_space:
    ; "--output-delimiter" STR (next arg)
    pop     rbx
    inc     rbx
    cmp     rbx, r14
    jge     .err_missing_delim_arg
    mov     rdi, [r15 + rbx*8]
    call    copy_output_delimiter
    mov     byte [rel opt_delim_set], 1
    jmp     .parse_next

.long_total:
    pop     rbx
    mov     byte [rel opt_total], 1
    jmp     .parse_next

.long_zeroterm:
    pop     rbx
    mov     byte [rel opt_zero_terminated], 1
    jmp     .parse_next

.set_dashdash:
    mov     byte [rel seen_dashdash], 1
    jmp     .parse_next

.is_operand:
    ; Assign to file1 or file2
    cmp     qword [rel file1_path], 0
    je      .set_file1
    cmp     qword [rel file2_path], 0
    je      .set_file2
    ; Extra operand
    push    rbx
    lea     rdi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    write_stderr
    lea     rdi, [rel str_extra_operand]
    mov     rdx, str_extra_operand_len
    call    write_stderr
    lea     rdi, [rel str_quote_open]
    mov     rdx, 1
    call    write_stderr
    mov     rsi, [r15 + rbx*8]
    mov     rdi, rsi
    call    strlen
    mov     rdx, rax
    mov     rdi, rsi
    call    write_stderr
    lea     rdi, [rel str_quote_nl]
    mov     rdx, 2
    call    write_stderr
    lea     rdi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    write_stderr
    pop     rbx
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.set_file1:
    mov     rax, [r15 + rbx*8]
    mov     [rel file1_path], rax
    jmp     .parse_next

.set_file2:
    mov     rax, [r15 + rbx*8]
    mov     [rel file2_path], rax
    jmp     .parse_next

.parse_next:
    inc     rbx
    jmp     .parse_loop

.parse_done:
    ; Validate we have exactly 2 files
    cmp     qword [rel file1_path], 0
    je      .err_missing_operand

    cmp     qword [rel file2_path], 0
    je      .err_missing_operand_after

    ; ─── Open and mmap both files ─────────────────────────────
    ; Determine line delimiter
    cmp     byte [rel opt_zero_terminated], 0
    jne     .use_nul_delim
    mov     byte [rel line_delim], 10       ; newline
    jmp     .setup_delim_done
.use_nul_delim:
    mov     byte [rel line_delim], 0        ; NUL
.setup_delim_done:

    ; Setup output delimiter: if not explicitly set, use tab
    cmp     byte [rel opt_delim_set], 0
    jne     .delim_already_set
    mov     byte [rel opt_delim_buf], 9     ; tab
    mov     qword [rel opt_delim_len], 1
.delim_already_set:

    ; Open file1
    mov     rdi, [rel file1_path]
    call    open_and_mmap_file
    test    rax, rax
    js      .err_open_file1
    mov     [rel file1_addr], rax
    mov     [rel file1_len], rdx

    ; Open file2
    mov     rdi, [rel file2_path]
    call    open_and_mmap_file
    test    rax, rax
    js      .err_open_file2
    mov     [rel file2_addr], rax
    mov     [rel file2_len], rdx

    ; Initialize counters
    mov     qword [rel count1], 0
    mov     qword [rel count2], 0
    mov     qword [rel count3], 0
    mov     byte [rel had_order_error], 0
    mov     byte [rel warned1], 0
    mov     byte [rel warned2], 0
    mov     qword [rel out_buf_used], 0

    ; ─── Main merge loop ───────────────────────────────────────
    ; r12 = pos1 (current position in file1)
    ; r13 = pos2 (current position in file2)
    ; r14 = len1
    ; r15 = len2
    ; We'll store file addresses on the stack/bss and use registers for hot loop
    mov     rax, [rel file1_addr]
    mov     [rel f1_base], rax
    mov     rax, [rel file2_addr]
    mov     [rel f2_base], rax

    xor     r12d, r12d              ; pos1 = 0
    xor     r13d, r13d              ; pos2 = 0
    mov     r14, [rel file1_len]
    mov     r15, [rel file2_len]

    ; Strip trailing delimiter from both files
    test    r14, r14
    jz      .no_strip1
    mov     rax, [rel f1_base]
    movzx   ecx, byte [rel line_delim]
    cmp     byte [rax + r14 - 1], cl
    jne     .no_strip1
    dec     r14
.no_strip1:
    test    r15, r15
    jz      .no_strip2
    mov     rax, [rel f2_base]
    movzx   ecx, byte [rel line_delim]
    cmp     byte [rax + r15 - 1], cl
    jne     .no_strip2
    dec     r15
.no_strip2:

    ; Store prev line pointers for order checking
    mov     qword [rel prev1_ptr], 0
    mov     qword [rel prev1_len], 0
    mov     qword [rel prev2_ptr], 0
    mov     qword [rel prev2_len], 0
    mov     byte [rel has_prev1], 0
    mov     byte [rel has_prev2], 0

.merge_loop:
    ; Check if both files still have data
    cmp     r12, r14
    jge     .drain_file2
    cmp     r13, r15
    jge     .drain_file1

    ; Find end of current line in file1
    mov     rax, [rel f1_base]
    lea     rdi, [rax + r12]        ; line1 start
    mov     [rel cur_line1_ptr], rdi
    mov     rsi, r14
    sub     rsi, r12                ; remaining bytes in file1
    movzx   edx, byte [rel line_delim]
    call    find_delim
    ; rax = offset of delimiter from rdi, or rsi if not found
    mov     [rel cur_line1_len], rax

    ; Find end of current line in file2
    mov     rax, [rel f2_base]
    lea     rdi, [rax + r13]        ; line2 start
    mov     [rel cur_line2_ptr], rdi
    mov     rsi, r15
    sub     rsi, r13                ; remaining bytes in file2
    movzx   edx, byte [rel line_delim]
    call    find_delim
    mov     [rel cur_line2_len], rax

    ; Compare lines using SIMD
    mov     rdi, [rel cur_line1_ptr]
    mov     rsi, [rel cur_line1_len]
    mov     rdx, [rel cur_line2_ptr]
    mov     rcx, [rel cur_line2_len]
    call    compare_lines
    ; rax: -1 = line1 < line2, 0 = equal, 1 = line1 > line2

    test    rax, rax
    js      .line1_less
    jz      .lines_equal
    jmp     .line1_greater

.line1_less:
    ; line1 < line2 → column 1 (only in file1)
    ; Check order of file1
    call    check_order_file1
    test    rax, rax
    jnz     .early_exit_order       ; strict mode: stop

    ; Output column 1 if not suppressed
    cmp     byte [rel opt_suppress1], 0
    jne     .skip_col1_output

    ; Write line to output buffer (no prefix for col1)
    mov     rdi, [rel cur_line1_ptr]
    mov     rsi, [rel cur_line1_len]
    xor     edx, edx                ; prefix_tabs = 0
    call    output_line

.skip_col1_output:
    inc     qword [rel count1]

    ; Update prev1
    mov     rax, [rel cur_line1_ptr]
    mov     [rel prev1_ptr], rax
    mov     rax, [rel cur_line1_len]
    mov     [rel prev1_len], rax
    mov     byte [rel has_prev1], 1

    ; Advance pos1
    add     r12, [rel cur_line1_len]
    cmp     r12, r14
    jge     .merge_loop             ; at end
    inc     r12                     ; skip delimiter
    jmp     .merge_loop

.line1_greater:
    ; line1 > line2 → column 2 (only in file2)
    ; Check order of file2
    call    check_order_file2
    test    rax, rax
    jnz     .early_exit_order

    ; Output column 2 if not suppressed
    cmp     byte [rel opt_suppress2], 0
    jne     .skip_col2_output

    ; Column 2 prefix: 1 delimiter if col1 not suppressed, else 0
    cmp     byte [rel opt_suppress1], 0
    jne     .col2_no_prefix
    mov     edx, 1                  ; 1 delimiter prefix
    jmp     .col2_write
.col2_no_prefix:
    xor     edx, edx                ; 0 prefix
.col2_write:
    mov     rdi, [rel cur_line2_ptr]
    mov     rsi, [rel cur_line2_len]
    call    output_line

.skip_col2_output:
    inc     qword [rel count2]

    ; Update prev2
    mov     rax, [rel cur_line2_ptr]
    mov     [rel prev2_ptr], rax
    mov     rax, [rel cur_line2_len]
    mov     [rel prev2_len], rax
    mov     byte [rel has_prev2], 1

    ; Advance pos2
    add     r13, [rel cur_line2_len]
    cmp     r13, r15
    jge     .merge_loop
    inc     r13
    jmp     .merge_loop

.lines_equal:
    ; Both lines match → column 3 (common)
    ; Output column 3 if not suppressed
    cmp     byte [rel opt_suppress3], 0
    jne     .skip_col3_output

    ; Column 3 prefix: count active (non-suppressed) columns before col3
    xor     edx, edx
    cmp     byte [rel opt_suppress1], 0
    jne     .col3_check2
    inc     edx
.col3_check2:
    cmp     byte [rel opt_suppress2], 0
    jne     .col3_write
    inc     edx
.col3_write:
    mov     rdi, [rel cur_line1_ptr]
    mov     rsi, [rel cur_line1_len]
    call    output_line

.skip_col3_output:
    inc     qword [rel count3]

    ; Update both prev
    mov     rax, [rel cur_line1_ptr]
    mov     [rel prev1_ptr], rax
    mov     rax, [rel cur_line1_len]
    mov     [rel prev1_len], rax
    mov     byte [rel has_prev1], 1

    mov     rax, [rel cur_line2_ptr]
    mov     [rel prev2_ptr], rax
    mov     rax, [rel cur_line2_len]
    mov     [rel prev2_len], rax
    mov     byte [rel has_prev2], 1

    ; Advance both
    add     r12, [rel cur_line1_len]
    cmp     r12, r14
    jge     .adv_pos2_equal
    inc     r12
.adv_pos2_equal:
    add     r13, [rel cur_line2_len]
    cmp     r13, r15
    jge     .merge_loop
    inc     r13
    jmp     .merge_loop

; ─── Drain remaining file1 lines ──────────────────────────
.drain_file1:
    cmp     r12, r14
    jge     .after_drain

    ; Find end of line
    mov     rax, [rel f1_base]
    lea     rdi, [rax + r12]
    mov     [rel cur_line1_ptr], rdi
    mov     rsi, r14
    sub     rsi, r12
    movzx   edx, byte [rel line_delim]
    call    find_delim
    mov     [rel cur_line1_len], rax

    ; Check order
    call    check_order_file1
    test    rax, rax
    jnz     .early_exit_order

    ; Output col1
    cmp     byte [rel opt_suppress1], 0
    jne     .skip_drain1_output
    mov     rdi, [rel cur_line1_ptr]
    mov     rsi, [rel cur_line1_len]
    xor     edx, edx
    call    output_line
.skip_drain1_output:
    inc     qword [rel count1]

    mov     rax, [rel cur_line1_ptr]
    mov     [rel prev1_ptr], rax
    mov     rax, [rel cur_line1_len]
    mov     [rel prev1_len], rax
    mov     byte [rel has_prev1], 1

    add     r12, [rel cur_line1_len]
    cmp     r12, r14
    jge     .after_drain
    inc     r12
    jmp     .drain_file1

; ─── Drain remaining file2 lines ──────────────────────────
.drain_file2:
    cmp     r13, r15
    jge     .after_drain

    ; Find end of line
    mov     rax, [rel f2_base]
    lea     rdi, [rax + r13]
    mov     [rel cur_line2_ptr], rdi
    mov     rsi, r15
    sub     rsi, r13
    movzx   edx, byte [rel line_delim]
    call    find_delim
    mov     [rel cur_line2_len], rax

    ; Check order
    call    check_order_file2
    test    rax, rax
    jnz     .early_exit_order

    ; Output col2
    cmp     byte [rel opt_suppress2], 0
    jne     .skip_drain2_output
    cmp     byte [rel opt_suppress1], 0
    jne     .drain2_no_prefix
    mov     edx, 1
    jmp     .drain2_write
.drain2_no_prefix:
    xor     edx, edx
.drain2_write:
    mov     rdi, [rel cur_line2_ptr]
    mov     rsi, [rel cur_line2_len]
    call    output_line
.skip_drain2_output:
    inc     qword [rel count2]

    mov     rax, [rel cur_line2_ptr]
    mov     [rel prev2_ptr], rax
    mov     rax, [rel cur_line2_len]
    mov     [rel prev2_len], rax
    mov     byte [rel has_prev2], 1

    add     r13, [rel cur_line2_len]
    cmp     r13, r15
    jge     .after_drain
    inc     r13
    jmp     .drain_file2

.after_drain:
    ; Write --total summary if requested
    cmp     byte [rel opt_total], 0
    je      .skip_total

    ; Format: count1 SEP count2 SEP count3 SEP "total" DELIM
    lea     rdi, [rel itoa_buf]
    mov     rsi, [rel count1]
    call    itoa_u64
    ; rax = length of number string
    lea     rsi, [rel itoa_buf]
    mov     rdx, rax
    call    append_to_outbuf

    ; separator
    lea     rsi, [rel opt_delim_buf]
    mov     rdx, [rel opt_delim_len]
    call    append_to_outbuf

    ; count2
    lea     rdi, [rel itoa_buf]
    mov     rsi, [rel count2]
    call    itoa_u64
    lea     rsi, [rel itoa_buf]
    mov     rdx, rax
    call    append_to_outbuf

    lea     rsi, [rel opt_delim_buf]
    mov     rdx, [rel opt_delim_len]
    call    append_to_outbuf

    ; count3
    lea     rdi, [rel itoa_buf]
    mov     rsi, [rel count3]
    call    itoa_u64
    lea     rsi, [rel itoa_buf]
    mov     rdx, rax
    call    append_to_outbuf

    lea     rsi, [rel opt_delim_buf]
    mov     rdx, [rel opt_delim_len]
    call    append_to_outbuf

    ; "total"
    lea     rsi, [rel str_total_word]
    mov     rdx, 5
    call    append_to_outbuf

    ; line delimiter
    lea     rsi, [rel line_delim]
    mov     rdx, 1
    call    append_to_outbuf

.skip_total:
    ; Flush remaining output
    call    flush_outbuf

    ; Print order error summary if default mode had errors
    cmp     byte [rel had_order_error], 0
    je      .no_order_summary
    cmp     byte [rel opt_order_check], ORDER_DEFAULT
    jne     .no_order_summary
    ; "comm: input is not in sorted order\n"
    lea     rdi, [rel str_input_not_sorted]
    mov     rdx, str_input_not_sorted_len
    call    write_stderr
.no_order_summary:

    ; Exit with status
    cmp     byte [rel had_order_error], 0
    jne     .exit_1
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

.exit_1:
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.early_exit_order:
    ; Flush output buffer first
    call    flush_outbuf
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

; ─── Error handlers ───────────────────────────────────────

.err_missing_operand:
    lea     rdi, [rel str_missing_operand]
    mov     rdx, str_missing_operand_len
    call    write_stderr
    lea     rdi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_missing_operand_after:
    lea     rdi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    write_stderr
    lea     rdi, [rel str_missing_after]
    mov     rdx, str_missing_after_len
    call    write_stderr
    lea     rdi, [rel str_quote_open]
    mov     rdx, 1
    call    write_stderr
    mov     rdi, [rel file1_path]
    mov     rsi, rdi
    call    strlen
    mov     rdx, rax
    mov     rdi, rsi
    call    write_stderr
    lea     rdi, [rel str_quote_nl]
    mov     rdx, 2
    call    write_stderr
    lea     rdi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_missing_delim_arg:
    lea     rdi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    write_stderr
    lea     rdi, [rel str_delim_requires_arg]
    mov     rdx, str_delim_requires_arg_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_open_file1:
    mov     rdi, [rel file1_path]
    call    err_open_file
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_open_file2:
    mov     rdi, [rel file2_path]
    call    err_open_file
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

; ─── Subroutines ──────────────────────────────────────────

; open_and_mmap_file: open a file and mmap it
; Input: rdi = path (null-terminated string, or "-" for stdin)
; Output: rax = address of mapped data (negative on error), rdx = length
open_and_mmap_file:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     rbx, rdi                ; save path

    ; Check for "-" (stdin)
    cmp     byte [rdi], '-'
    jne     .omf_not_stdin
    cmp     byte [rdi+1], 0
    jne     .omf_not_stdin

    ; Allocate initial buffer via mmap (anonymous, read+write)
    mov     r12, STDIN_BUF_SIZE     ; current capacity
    xor     edi, edi
    mov     rsi, r12
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8d, -1
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .omf_mmap_stdin_fail
    mov     r14, rax                ; buffer ptr
    xor     r13d, r13d              ; total bytes read

.omf_stdin_loop:
    mov     rdi, STDIN
    lea     rsi, [r14 + r13]
    mov     rdx, r12
    sub     rdx, r13
    cmp     rdx, STDIN_BUF_SIZE
    jbe     .omf_stdin_read_ok
    mov     rdx, STDIN_BUF_SIZE     ; cap read size
.omf_stdin_read_ok:
    test    rdx, rdx
    jz      .omf_stdin_grow         ; no space left, grow first
    call    asm_read
    test    rax, rax
    jle     .omf_stdin_done         ; EOF or error
    add     r13, rax

    ; Check if buffer needs growing (less than 4KB remaining)
    mov     rax, r12
    sub     rax, r13
    cmp     rax, 4096
    jge     .omf_stdin_loop

.omf_stdin_grow:
    ; Grow buffer via mremap (double the size)
    mov     rdi, r14
    mov     rsi, r12
    lea     rdx, [r12 * 2]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .omf_mmap_stdin_fail
    mov     r14, rax                ; update buffer ptr (may have moved)
    shl     r12, 1                  ; double capacity
    jmp     .omf_stdin_loop

.omf_stdin_done:
    mov     rax, r14                ; address
    mov     rdx, r13                ; length
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.omf_mmap_stdin_fail:
    mov     rax, -1
    xor     edx, edx
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.omf_not_stdin:
    ; Open file
    mov     rdi, rbx
    xor     esi, esi                ; O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .omf_open_fail
    mov     r12, rax                ; fd

    ; fstat to get file size
    mov     rdi, r12
    lea     rsi, [rel stat_buf]
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .omf_fstat_fail

    ; Get file size from stat_buf (offset 48 = st_size)
    mov     r13, [rel stat_buf + 48]

    ; If file is empty, close and return empty
    test    r13, r13
    jz      .omf_empty_file

    ; mmap the file
    xor     edi, edi                ; addr = NULL
    mov     rsi, r13                ; length
    mov     edx, PROT_READ          ; prot = PROT_READ
    mov     r10d, MAP_PRIVATE       ; flags = MAP_PRIVATE
    or      r10d, MAP_POPULATE      ; | MAP_POPULATE
    mov     r8, r12                 ; fd
    xor     r9d, r9d                ; offset = 0
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .omf_mmap_fail

    push    rax                     ; save mmap address

    ; madvise SEQUENTIAL
    mov     rdi, rax
    mov     rsi, r13
    mov     edx, MADV_SEQUENTIAL
    mov     rax, SYS_MADVISE
    syscall

    ; Close the fd (we have the mmap)
    mov     rdi, r12
    call    asm_close

    pop     rax                     ; mmap address
    mov     rdx, r13                ; length
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.omf_empty_file:
    mov     rdi, r12
    call    asm_close
    ; Return a valid non-negative address with length 0
    ; Use the stat_buf address as a dummy
    lea     rax, [rel stat_buf]
    xor     edx, edx
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.omf_open_fail:
.omf_fstat_fail:
.omf_mmap_fail:
    mov     rax, -1
    xor     edx, edx
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; find_delim: find delimiter byte in buffer
; Input: rdi = buffer, rsi = length, edx = delimiter byte
; Output: rax = offset of delimiter (or rsi if not found)
find_delim:
    push    rbx
    mov     rbx, rdi                ; save start
    mov     rcx, rsi                ; length
    mov     al, dl                  ; delimiter

    ; Use SSE2 for fast scanning
    movd    xmm0, edx
    punpcklbw xmm0, xmm0
    punpcklwd xmm0, xmm0
    pshufd  xmm0, xmm0, 0          ; broadcast delimiter to all 16 bytes

    ; Handle short buffers
    cmp     rcx, 16
    jb      .fd_byte_scan

.fd_sse_loop:
    cmp     rcx, 16
    jb      .fd_byte_scan
    movdqu  xmm1, [rdi]
    pcmpeqb xmm1, xmm0
    pmovmskb eax, xmm1
    test    eax, eax
    jnz     .fd_found_sse
    add     rdi, 16
    sub     rcx, 16
    jmp     .fd_sse_loop

.fd_found_sse:
    bsf     eax, eax
    add     rdi, rax
    sub     rdi, rbx
    mov     rax, rdi
    pop     rbx
    ret

.fd_byte_scan:
    test    rcx, rcx
    jz      .fd_not_found
    movzx   edx, byte [rel line_delim]
.fd_byte_loop:
    cmp     byte [rdi], dl
    je      .fd_found_byte
    inc     rdi
    dec     rcx
    jnz     .fd_byte_loop
.fd_not_found:
    mov     rax, rsi                ; return length (not found)
    pop     rbx
    ret

.fd_found_byte:
    sub     rdi, rbx
    mov     rax, rdi
    pop     rbx
    ret

; compare_lines: compare two lines using SIMD
; Input: rdi = line1 ptr, rsi = line1 len, rdx = line2 ptr, rcx = line2 len
; Output: rax = -1 (less), 0 (equal), 1 (greater)
compare_lines:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi                ; line1 ptr
    mov     r13, rsi                ; line1 len
    mov     r14, rdx                ; line2 ptr
    mov     r15, rcx                ; line2 len

    ; Compare min(len1, len2) bytes
    mov     rbx, r13
    cmp     rbx, r15
    jbe     .cl_min_set
    mov     rbx, r15                ; rbx = min length
.cl_min_set:

    ; If min length is 0, compare by length
    test    rbx, rbx
    jz      .cl_compare_lengths

    ; Fast SIMD comparison: 16 bytes at a time
    mov     rdi, r12
    mov     rsi, r14
    mov     rcx, rbx

.cl_sse_loop:
    cmp     rcx, 16
    jb      .cl_byte_loop

    movdqu  xmm0, [rdi]
    movdqu  xmm1, [rsi]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0
    xor     eax, 0xFFFF             ; invert: 1 = different
    test    eax, eax
    jnz     .cl_found_diff_sse

    add     rdi, 16
    add     rsi, 16
    sub     rcx, 16
    jmp     .cl_sse_loop

.cl_found_diff_sse:
    bsf     eax, eax                ; find first differing byte
    movzx   edx, byte [rdi + rax]
    movzx   ecx, byte [rsi + rax]
    cmp     edx, ecx
    jb      .cl_less
    jmp     .cl_greater

.cl_byte_loop:
    test    rcx, rcx
    jz      .cl_compare_lengths
    movzx   eax, byte [rdi]
    movzx   edx, byte [rsi]
    cmp     eax, edx
    jb      .cl_less
    ja      .cl_greater
    inc     rdi
    inc     rsi
    dec     rcx
    jmp     .cl_byte_loop

.cl_compare_lengths:
    cmp     r13, r15
    jb      .cl_less
    ja      .cl_greater
    ; Equal
    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.cl_less:
    mov     rax, -1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.cl_greater:
    mov     rax, 1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; output_line: write prefix + line + delimiter to output buffer
; Input: rdi = line ptr, rsi = line len, edx = number of delimiter prefixes (0, 1, or 2)
output_line:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rdi                ; line ptr
    mov     r13, rsi                ; line len
    mov     r14d, edx               ; prefix count

    ; Calculate total needed space
    ; prefix_count * delim_len + line_len + 1 (for line delimiter)
    movzx   eax, r14b
    imul    rax, [rel opt_delim_len]
    add     rax, r13
    inc     rax                     ; for line delimiter
    mov     rbx, rax                ; total needed

    ; Check if we need to flush
    mov     rcx, [rel out_buf_used]
    add     rcx, rbx
    cmp     rcx, OUT_BUF_SIZE
    jb      .ol_no_flush
    call    flush_outbuf
.ol_no_flush:

    ; Also check flush threshold for large buffers
    mov     rcx, [rel out_buf_used]
    cmp     rcx, FLUSH_THRESHOLD
    jb      .ol_write_prefix
    call    flush_outbuf

.ol_write_prefix:
    ; Write prefix delimiters
    test    r14d, r14d
    jz      .ol_write_line

    lea     rsi, [rel opt_delim_buf]
    mov     rdx, [rel opt_delim_len]

.ol_prefix_loop:
    test    r14d, r14d
    jz      .ol_write_line
    call    append_to_outbuf
    dec     r14d
    jmp     .ol_prefix_loop

.ol_write_line:
    ; Write line content
    mov     rsi, r12
    mov     rdx, r13
    test    rdx, rdx
    jz      .ol_write_delim
    call    append_to_outbuf

.ol_write_delim:
    ; Write line delimiter
    lea     rsi, [rel line_delim]
    mov     rdx, 1
    call    append_to_outbuf

    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; append_to_outbuf: append bytes to output buffer
; Input: rsi = source, rdx = length
; Clobbers: rax, rcx, rdi
append_to_outbuf:
    test    rdx, rdx
    jz      .atob_done
    mov     rcx, [rel out_buf_used]
    lea     rdi, [rel out_buf]
    add     rdi, rcx
    ; Copy bytes
    push    rsi
    push    rdx
    mov     rcx, rdx
    rep movsb
    pop     rdx
    pop     rsi
    add     [rel out_buf_used], rdx
.atob_done:
    ret

; flush_outbuf: flush output buffer to stdout
flush_outbuf:
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rax, [rel out_buf_used]
    test    rax, rax
    jz      .fob_done
    mov     rdi, STDOUT
    lea     rsi, [rel out_buf]
    mov     rdx, rax
    call    asm_write_all
    test    rax, rax
    js      .fob_write_error
    mov     qword [rel out_buf_used], 0
.fob_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

.fob_write_error:
    ; Write error - exit with status 1
    lea     rdi, [rel str_write_error_msg]
    mov     rdx, str_write_error_msg_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

; check_order_file1: check sort order for file1
; Uses cur_line1_ptr/len vs prev1_ptr/len
; Returns: rax = 0 (ok/continue), 1 (strict mode stop)
check_order_file1:
    push    rbx

    cmp     byte [rel opt_order_check], ORDER_NONE
    je      .cof1_ok
    cmp     byte [rel warned1], 0
    jne     .cof1_ok
    cmp     byte [rel has_prev1], 0
    je      .cof1_ok

    ; Compare current with previous
    mov     rdi, [rel cur_line1_ptr]
    mov     rsi, [rel cur_line1_len]
    mov     rdx, [rel prev1_ptr]
    mov     rcx, [rel prev1_len]
    call    compare_lines
    ; If current < prev, out of order
    test    rax, rax
    jns     .cof1_ok

    ; Out of order detected
    mov     byte [rel had_order_error], 1
    mov     byte [rel warned1], 1

    ; Print error: "comm: file 1 is not in sorted order\n"
    push    r12
    push    r13
    push    r14
    push    r15
    lea     rdi, [rel str_file1_not_sorted]
    mov     rdx, str_file1_not_sorted_len
    call    write_stderr
    pop     r15
    pop     r14
    pop     r13
    pop     r12

    ; If strict mode, signal stop
    cmp     byte [rel opt_order_check], ORDER_STRICT
    je      .cof1_stop

.cof1_ok:
    xor     eax, eax
    pop     rbx
    ret

.cof1_stop:
    mov     eax, 1
    pop     rbx
    ret

; check_order_file2: check sort order for file2
check_order_file2:
    push    rbx

    cmp     byte [rel opt_order_check], ORDER_NONE
    je      .cof2_ok
    cmp     byte [rel warned2], 0
    jne     .cof2_ok
    cmp     byte [rel has_prev2], 0
    je      .cof2_ok

    mov     rdi, [rel cur_line2_ptr]
    mov     rsi, [rel cur_line2_len]
    mov     rdx, [rel prev2_ptr]
    mov     rcx, [rel prev2_len]
    call    compare_lines
    test    rax, rax
    jns     .cof2_ok

    mov     byte [rel had_order_error], 1
    mov     byte [rel warned2], 1

    push    r12
    push    r13
    push    r14
    push    r15
    lea     rdi, [rel str_file2_not_sorted]
    mov     rdx, str_file2_not_sorted_len
    call    write_stderr
    pop     r15
    pop     r14
    pop     r13
    pop     r12

    cmp     byte [rel opt_order_check], ORDER_STRICT
    je      .cof2_stop

.cof2_ok:
    xor     eax, eax
    pop     rbx
    ret

.cof2_stop:
    mov     eax, 1
    pop     rbx
    ret

; copy_output_delimiter: copy delimiter string from rdi into opt_delim_buf
; Input: rdi = null-terminated string
copy_output_delimiter:
    push    rbx
    mov     rsi, rdi
    call    strlen
    ; rax = length
    cmp     rax, MAX_DELIM_LEN
    jbe     .cod_len_ok
    mov     rax, MAX_DELIM_LEN
.cod_len_ok:
    mov     [rel opt_delim_len], rax
    mov     rcx, rax
    mov     rdi, rsi                ; source
    lea     rsi, [rel opt_delim_buf]; dest
    ; Copy
    push    rdi
    mov     rdi, rsi
    pop     rsi
    rep movsb
    pop     rbx
    ret

; itoa_u64: convert unsigned 64-bit integer to decimal string
; Input: rdi = output buffer, rsi = value
; Output: rax = length of string
itoa_u64:
    push    rbx
    push    r12
    mov     r12, rdi                ; output buffer
    mov     rax, rsi                ; value

    ; Handle 0 specially
    test    rax, rax
    jnz     .itoa_nonzero
    mov     byte [r12], '0'
    mov     rax, 1
    pop     r12
    pop     rbx
    ret

.itoa_nonzero:
    ; Convert digits in reverse, then reverse
    lea     rbx, [rel itoa_tmp]
    xor     ecx, ecx                ; digit count

.itoa_loop:
    test    rax, rax
    jz      .itoa_reverse
    xor     edx, edx
    mov     r8, 10
    div     r8
    add     dl, '0'
    mov     [rbx + rcx], dl
    inc     ecx
    jmp     .itoa_loop

.itoa_reverse:
    ; Copy digits in reverse order to output
    mov     eax, ecx
    dec     ecx
.itoa_rev_loop:
    test    ecx, ecx
    js      .itoa_done
    movzx   edx, byte [rbx + rcx]
    mov     [r12], dl
    inc     r12
    dec     ecx
    jmp     .itoa_rev_loop

.itoa_done:
    ; rax already has length
    pop     r12
    pop     rbx
    ret

; strcmp: compare null-terminated strings
; Input: rdi = str1, rsi = str2
; Output: eax = 0 if equal, nonzero otherwise
strcmp:
.loop:
    movzx   eax, byte [rdi]
    movzx   edx, byte [rsi]
    cmp     al, dl
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
    sub     eax, edx
    ret

; strncmp: compare first rcx bytes of rdi and rsi
; Input: rdi = str1, rsi = str2, rcx = length
; Output: eax = 0 if equal
strncmp:
    test    rcx, rcx
    jz      .sn_eq
.sn_loop:
    movzx   eax, byte [rdi]
    movzx   edx, byte [rsi]
    cmp     al, dl
    jne     .sn_ne
    inc     rdi
    inc     rsi
    dec     rcx
    jnz     .sn_loop
.sn_eq:
    xor     eax, eax
    ret
.sn_ne:
    sub     eax, edx
    ret

; strlen: get length of null-terminated string
; Input: rdi = string
; Output: rax = length
strlen:
    mov     rsi, rdi
.sl_loop:
    cmp     byte [rdi], 0
    je      .sl_done
    inc     rdi
    jmp     .sl_loop
.sl_done:
    mov     rax, rdi
    sub     rax, rsi
    ret

; write_stderr: write buffer to stderr
; Input: rdi = buffer, rdx = length
write_stderr:
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rsi, rdi
    mov     rdi, STDERR
    call    asm_write_all
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

; err_invalid_option: print "comm: invalid option -- 'X'"
; Input: rsi = the argv string (e.g., "-x")
err_invalid_option:
    push    rsi
    lea     rdi, [rel str_invalid_opt]
    mov     rdx, str_invalid_opt_len
    call    write_stderr
    pop     rsi
    ; Print the option string
    mov     rdi, rsi
    push    rdi
    call    strlen
    pop     rdi
    mov     rdx, rax
    call    write_stderr
    lea     rdi, [rel str_quote_nl]
    mov     rdx, 2
    call    write_stderr
    lea     rdi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    write_stderr
    ret

; err_unrecognized_option: print "comm: unrecognized option 'X'"
err_unrecognized_option:
    push    rsi
    lea     rdi, [rel str_unrecognized]
    mov     rdx, str_unrecognized_len
    call    write_stderr
    pop     rsi
    mov     rdi, rsi
    push    rdi
    call    strlen
    pop     rdi
    mov     rdx, rax
    call    write_stderr
    lea     rdi, [rel str_quote_nl]
    mov     rdx, 2
    call    write_stderr
    lea     rdi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    write_stderr
    ret

; err_open_file: print "comm: FILE: No such file or directory"
err_open_file:
    push    rdi
    lea     rdi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    write_stderr
    pop     rdi
    push    rdi
    mov     rsi, rdi
    call    strlen
    pop     rdi
    mov     rdx, rax
    call    write_stderr
    lea     rdi, [rel str_colon_space]
    mov     rdx, 2
    call    write_stderr
    lea     rdi, [rel str_enoent]
    mov     rdx, str_enoent_len
    call    write_stderr
    lea     rdi, [rel str_newline]
    mov     rdx, 1
    call    write_stderr
    ret

; ─── Data Section ─────────────────────────────────────────
section .data

align 16
sigact_buf:
    dq 0            ; sa_handler = SIG_DFL
    dq 0x04000000   ; sa_flags = SA_RESTORER
    dq 0            ; sa_restorer
    dq 0            ; sa_mask

str_prefix:     db "comm: "
str_prefix_len equ $ - str_prefix

str_newline:    db 10
str_colon_space: db ": "
str_quote_open: db 27h              ; single quote
str_quote_nl:   db 27h, 10          ; quote + newline

str_help_opt:       db "--help", 0
str_version_opt:    db "--version", 0
str_check_order_opt: db "--check-order", 0
str_nocheck_order_opt: db "--nocheck-order", 0
str_outdelim_prefix: db "--output-delimiter=", 0
str_outdelim_opt:   db "--output-delimiter", 0
str_total_opt:      db "--total", 0
str_zeroterm_opt:   db "--zero-terminated", 0

str_total_word:     db "total"

str_missing_operand: db "comm: missing operand", 10
str_missing_operand_len equ $ - str_missing_operand

str_missing_after:  db "missing operand after "
str_missing_after_len equ $ - str_missing_after

str_extra_operand:  db "extra operand "
str_extra_operand_len equ $ - str_extra_operand

str_delim_requires_arg: db "option '--output-delimiter' requires an argument", 10
str_delim_requires_arg_len equ $ - str_delim_requires_arg

str_write_error_msg: db "comm: write error", 10
str_write_error_msg_len equ $ - str_write_error_msg

str_file1_not_sorted: db "comm: file 1 is not in sorted order", 10
str_file1_not_sorted_len equ $ - str_file1_not_sorted

str_file2_not_sorted: db "comm: file 2 is not in sorted order", 10
str_file2_not_sorted_len equ $ - str_file2_not_sorted

str_input_not_sorted: db "comm: input is not in sorted order", 10
str_input_not_sorted_len equ $ - str_input_not_sorted

str_unrecognized:   db "comm: unrecognized option ", 27h
str_unrecognized_len equ $ - str_unrecognized

str_try_help: db "Try 'comm --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_invalid_opt: db "comm: invalid option -- ", 27h
str_invalid_opt_len equ $ - str_invalid_opt

str_enoent: db "No such file or directory"
str_enoent_len equ $ - str_enoent

help_text:
    db "Usage: comm [OPTION]... FILE1 FILE2", 10
    db "Compare sorted files FILE1 and FILE2 line by line.", 10
    db 10
    db "When FILE1 or FILE2 (not both) is -, read standard input.", 10
    db 10
    db "With no options, produce three-column output.  Column one contains", 10
    db "lines unique to FILE1, column two contains lines unique to FILE2,", 10
    db "and column three contains lines common to both files.", 10
    db 10
    db "  -1                      suppress column 1 (lines unique to FILE1)", 10
    db "  -2                      suppress column 2 (lines unique to FILE2)", 10
    db "  -3                      suppress column 3 (lines that appear in both files)", 10
    db 10
    db "      --check-order       check that the input is correctly sorted, even", 10
    db "                            if all input lines are pairable", 10
    db "      --nocheck-order     do not check that the input is correctly sorted", 10
    db "      --output-delimiter=STR  separate columns with STR", 10
    db "      --total             output a summary", 10
    db "  -z, --zero-terminated   line delimiter is NUL, not newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
help_text_len equ $ - help_text

version_text:
    db "comm (fcoreutils) 0.1.0", 10
version_text_len equ $ - version_text

; ─── BSS Section ─────────────────────────────────────────
section .bss

; Options
opt_suppress1:          resb 1
opt_suppress2:          resb 1
opt_suppress3:          resb 1
opt_order_check:        resb 1
opt_total:              resb 1
opt_zero_terminated:    resb 1
opt_delim_set:          resb 1
seen_dashdash:          resb 1
line_delim:             resb 1

align 8
opt_delim_len:          resq 1
opt_delim_buf:          resb MAX_DELIM_LEN

align 8
file1_path:             resq 1
file2_path:             resq 1
file1_addr:             resq 1
file1_len:              resq 1
file2_addr:             resq 1
file2_len:              resq 1

; Working base pointers
f1_base:                resq 1
f2_base:                resq 1

; Current line pointers
cur_line1_ptr:          resq 1
cur_line1_len:          resq 1
cur_line2_ptr:          resq 1
cur_line2_len:          resq 1

; Previous line pointers (for order checking)
prev1_ptr:              resq 1
prev1_len:              resq 1
prev2_ptr:              resq 1
prev2_len:              resq 1
has_prev1:              resb 1
has_prev2:              resb 1
warned1:                resb 1
warned2:                resb 1
had_order_error:        resb 1

align 8
; Counters
count1:                 resq 1
count2:                 resq 1
count3:                 resq 1

; Output buffer
align 8
out_buf_used:           resq 1

; stat buffer (144 bytes for struct stat)
align 8
stat_buf:               resb 144

; itoa buffers
itoa_buf:               resb 32
itoa_tmp:               resb 32

; Output buffer (1MB)
align 16
out_buf:                resb OUT_BUF_SIZE

section .note.GNU-stack noalloc noexec nowrite progbits
