; ============================================================================
;  ffold.asm — GNU-compatible "fold" in x86_64 Linux assembly
;
;  A drop-in replacement for GNU coreutils `fold`. Pure x86-64 assembly,
;  no libc, no dynamic linker. Handles all flags:
;    -b (count bytes), -s (break at spaces), -w WIDTH (column width),
;    --width=WIDTH, --bytes, --spaces, --help, --version, --
;
;  On glibc systems, GNU fold does NOT do multibyte. Column counting:
;    tab -> next multiple of 8, backspace -> col-1 (min 0),
;    \r -> col=0, \n -> output + col=0, all others -> col+1.
;
;  Fold algorithm: when the NEXT byte would cause col > width, insert \n
;  BEFORE that byte. With -s: backtrack to last blank instead.
;
;  Register conventions (global state):
;    r12 = out_pos (bytes in output buffer)
;    ebp = had_error (0=ok, 1=error)
;
;  Build (modular):
;    nasm -f elf64 -I include/ tools/ffold.asm -o build/tools/ffold.o
;    nasm -f elf64 -I include/ lib/io.asm -o build/lib/io.o
;    ld --gc-sections -n build/tools/ffold.o build/lib/io.o -o ffold
; ============================================================================

%include "include/linux.inc"
%include "include/macros.inc"

default rel

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close

; ── Constants ──────────────────────────────────────────────
%define READ_BUF_SIZE   131072          ; 128KB input buffer
%define OUT_BUF_SIZE    524288          ; 512KB output buffer
%define FLUSH_THRESHOLD 262144          ; flush when output exceeds 256KB
%define MAX_FILES       256
%define DEFAULT_WIDTH   80

global _start

section .text

; ============================================================================
;  Entry Point
; ============================================================================
_start:
    BLOCK_SIGPIPE

    ; Parse argc/argv from stack
    mov     ecx, [rsp]                 ; argc
    lea     r14, [rsp + 8]             ; &argv[0]

    ; Initialize global state
    xor     ebp, ebp                    ; had_error = 0
    xor     r12d, r12d                  ; out_pos = 0
    mov     dword [width], DEFAULT_WIDTH
    mov     byte [flag_bytes], 0
    mov     byte [flag_spaces], 0
    mov     dword [num_files], 0

    ; Skip argv[0] (program name)
    lea     rbx, [r14 + 8]
    dec     ecx                         ; argc - 1
    mov     [argc_rem], ecx
    mov     byte [past_dashdash], 0

; ── Argument parsing ──────────────────────────────────────
.parse_loop:
    mov     ecx, [argc_rem]
    test    ecx, ecx
    jle     .parse_done
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .parse_done

    cmp     byte [past_dashdash], 1
    je      .add_file

    cmp     byte [rsi], '-'
    jne     .add_file
    cmp     byte [rsi + 1], 0
    je      .add_file                   ; bare "-" is stdin

    cmp     byte [rsi + 1], '-'
    je      .check_long

    ; Short option(s)
    inc     rsi
    call    parse_short_options
    jmp     .next_arg

.check_long:
    cmp     byte [rsi + 2], 0
    jne     .long_opt
    mov     byte [past_dashdash], 1
    jmp     .next_arg

.long_opt:
    call    parse_long_option
    jmp     .next_arg

.add_file:
    mov     eax, [num_files]
    cmp     eax, MAX_FILES
    jge     .next_arg
    lea     rdi, [files]
    mov     [rdi + rax*8], rsi
    inc     eax
    mov     [num_files], eax
    jmp     .next_arg

.next_arg:
    add     rbx, 8
    dec     dword [argc_rem]
    jmp     .parse_loop

.parse_done:
    mov     eax, [num_files]
    test    eax, eax
    jnz     .process_files

    ; No files: process stdin
    mov     edi, STDIN
    call    process_fd
    jmp     .final_flush

.process_files:
    xor     r13d, r13d                  ; file index
.file_loop:
    cmp     r13d, [num_files]
    jge     .final_flush

    lea     rdi, [files]
    mov     rsi, [rdi + r13*8]

    cmp     byte [rsi], '-'
    jne     .open_file
    cmp     byte [rsi + 1], 0
    jne     .open_file
    push    r13
    mov     edi, STDIN
    call    process_fd
    pop     r13
    jmp     .next_file

.open_file:
    push    r13
    call    open_and_process
    pop     r13

.next_file:
    inc     r13d
    jmp     .file_loop

.final_flush:
    call    flush_output
    test    eax, eax
    jnz     .write_error_exit

    movzx   rdi, bpl
    EXIT    rdi

.write_error_exit:
    lea     rdi, [str_write_error]
    call    print_error_msg
    mov     rdi, 1
    EXIT    rdi

; ============================================================================
;  parse_short_options(rsi = first option char after '-')
; ============================================================================
parse_short_options:
    push    rbx

.pso_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .pso_done

    cmp     al, 'b'
    je      .pso_bytes
    cmp     al, 's'
    je      .pso_spaces
    cmp     al, 'w'
    je      .pso_width
    jmp     .pso_invalid

.pso_bytes:
    mov     byte [flag_bytes], 1
    inc     rsi
    jmp     .pso_loop

.pso_spaces:
    mov     byte [flag_spaces], 1
    inc     rsi
    jmp     .pso_loop

.pso_width:
    inc     rsi
    movzx   eax, byte [rsi]
    test    al, al
    jz      .pso_width_next_arg
    cmp     al, '0'
    jl      .pso_width_next_arg
    cmp     al, '9'
    jg      .pso_width_next_arg
    ; Digits follow: -w5 etc.
    push    rsi                         ; save for error reporting
    call    parse_number
    test    eax, eax
    js      .pso_invalid_width_inline
    mov     [width], eax
    add     rsp, 8                      ; discard saved rsi
    jmp     .pso_loop

.pso_invalid_width_inline:
    pop     rsi                         ; restore value pointer
    call    print_invalid_width
    mov     rdi, 1
    EXIT    rdi

.pso_width_next_arg:
    pop     rbx
    add     rbx, 8
    dec     dword [argc_rem]
    cmp     dword [argc_rem], 0
    jle     .pso_missing_width
    mov     rsi, [rbx]
    push    rsi                         ; save for error reporting
    push    rbx
    call    parse_number
    pop     rbx
    test    eax, eax
    js      .pso_invalid_width_nextarg
    mov     [width], eax
    add     rsp, 8                      ; discard saved rsi
    push    rbx
    jmp     .pso_done

.pso_invalid_width_nextarg:
    pop     rsi
    call    print_invalid_width
    mov     rdi, 1
    EXIT    rdi

.pso_missing_width:
    lea     rdi, [str_prefix]
    mov     edx, str_prefix_len
    call    write_stderr
    lea     rdi, [str_w_requires_arg]
    mov     edx, str_w_requires_arg_len
    call    write_stderr
    lea     rdi, [str_newline]
    mov     edx, 1
    call    write_stderr
    lea     rdi, [str_try_help]
    mov     edx, str_try_help_len
    call    write_stderr
    mov     rdi, 1
    EXIT    rdi

.pso_invalid:
    mov     [opt_char_buf], al
    lea     rdi, [str_invalid_opt]
    mov     edx, str_invalid_opt_len
    call    write_stderr
    lea     rdi, [opt_char_buf]
    mov     edx, 1
    call    write_stderr
    lea     rdi, [str_quote_nl]
    mov     edx, 2
    call    write_stderr
    lea     rdi, [str_try_help]
    mov     edx, str_try_help_len
    call    write_stderr
    mov     rdi, 1
    EXIT    rdi

.pso_done:
    pop     rbx
    ret

; ============================================================================
;  parse_long_option(rsi = "--xxx..." string)
; ============================================================================
parse_long_option:
    push    rbx

    lea     rdi, [str_dashdash_help]
    call    strcmp
    test    eax, eax
    jz      .plo_help

    mov     rsi, [rbx]
    lea     rdi, [str_dashdash_version]
    call    strcmp
    test    eax, eax
    jz      .plo_version

    mov     rsi, [rbx]
    lea     rdi, [str_dashdash_bytes]
    call    strcmp
    test    eax, eax
    jz      .plo_bytes

    mov     rsi, [rbx]
    lea     rdi, [str_dashdash_spaces]
    call    strcmp
    test    eax, eax
    jz      .plo_spaces

    ; --width=VALUE
    mov     rsi, [rbx]
    lea     rdi, [str_dashdash_width_eq]
    mov     ecx, 8
    call    strncmp
    test    eax, eax
    jz      .plo_width_eq

    ; --width VALUE
    mov     rsi, [rbx]
    lea     rdi, [str_dashdash_width]
    call    strcmp
    test    eax, eax
    jz      .plo_width_sep

    ; Unrecognized
    mov     rsi, [rbx]
    jmp     .plo_unrecognized

.plo_help:
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    EXIT    rdi

.plo_version:
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    EXIT    rdi

.plo_bytes:
    mov     byte [flag_bytes], 1
    pop     rbx
    ret

.plo_spaces:
    mov     byte [flag_spaces], 1
    pop     rbx
    ret

.plo_width_eq:
    mov     rsi, [rbx]
    add     rsi, 8
    cmp     byte [rsi], 0
    je      .plo_width_invalid
    push    rsi
    call    parse_number
    test    eax, eax
    js      .plo_width_invalid_pop
    mov     [width], eax
    add     rsp, 8
    pop     rbx
    ret

.plo_width_invalid_pop:
    pop     rsi
.plo_width_invalid:
    call    print_invalid_width
    mov     rdi, 1
    EXIT    rdi

.plo_width_sep:
    pop     rbx
    add     rbx, 8
    dec     dword [argc_rem]
    cmp     dword [argc_rem], 0
    jle     .plo_width_missing
    mov     rsi, [rbx]
    push    rsi
    push    rbx
    call    parse_number
    pop     rbx
    test    eax, eax
    js      .plo_width_sep_invalid
    mov     [width], eax
    add     rsp, 8
    push    rbx
    pop     rbx
    ret

.plo_width_sep_invalid:
    pop     rsi
    call    print_invalid_width
    mov     rdi, 1
    EXIT    rdi

.plo_width_missing:
    lea     rdi, [str_prefix]
    mov     edx, str_prefix_len
    call    write_stderr
    lea     rdi, [str_width_requires_arg]
    mov     edx, str_width_requires_arg_len
    call    write_stderr
    lea     rdi, [str_newline]
    mov     edx, 1
    call    write_stderr
    lea     rdi, [str_try_help]
    mov     edx, str_try_help_len
    call    write_stderr
    mov     rdi, 1
    EXIT    rdi

.plo_unrecognized:
    lea     rdi, [str_unrecognized]
    mov     edx, str_unrecognized_len
    call    write_stderr
    mov     rsi, [rbx]
    push    rsi
    mov     rdi, rsi
    call    strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, rsi
    call    write_stderr_buf
    lea     rdi, [str_quote_nl]
    mov     edx, 2
    call    write_stderr
    lea     rdi, [str_try_help]
    mov     edx, str_try_help_len
    call    write_stderr
    mov     rdi, 1
    EXIT    rdi

; ============================================================================
;  parse_number(rsi = decimal string) -> eax = number, rsi advanced
;  Returns -1 if invalid. Width of 0 is invalid.
; ============================================================================
parse_number:
    xor     eax, eax
    movzx   edx, byte [rsi]
    cmp     dl, '0'
    jl      .pn_bad
    cmp     dl, '9'
    jg      .pn_bad
.pn_loop:
    movzx   edx, byte [rsi]
    cmp     dl, '0'
    jl      .pn_check
    cmp     dl, '9'
    jg      .pn_check
    imul    eax, 10
    jo      .pn_bad
    sub     edx, '0'
    add     eax, edx
    jo      .pn_bad
    inc     rsi
    jmp     .pn_loop
.pn_check:
    test    dl, dl
    jnz     .pn_bad
    test    eax, eax
    jz      .pn_bad
    ret
.pn_bad:
    mov     eax, -1
    ret

; ============================================================================
;  print_invalid_width(rsi = value string)
;  "fold: invalid number of columns: 'VALUE': Numerical result out of range\n"
; ============================================================================
print_invalid_width:
    push    rbx
    mov     rbx, rsi

    lea     rdi, [str_prefix]
    mov     edx, str_prefix_len
    call    write_stderr

    lea     rdi, [str_invalid_width_pre]
    mov     edx, str_invalid_width_pre_len
    call    write_stderr

    mov     rdi, rbx
    call    strlen
    mov     edx, eax
    mov     rdi, rbx
    call    write_stderr

    lea     rdi, [str_invalid_width_suf]
    mov     edx, str_invalid_width_suf_len
    call    write_stderr

    pop     rbx
    ret

; ============================================================================
;  open_and_process(rsi = filename)
; ============================================================================
open_and_process:
    push    rbx
    mov     rbx, rsi

    mov     rdi, rsi
    xor     esi, esi
    xor     edx, edx
    mov     rax, SYS_OPEN
    syscall
    test    rax, rax
    js      .oap_error

    push    rax
    mov     edi, eax
    call    process_fd
    pop     rdi
    mov     rax, SYS_CLOSE
    syscall
    pop     rbx
    ret

.oap_error:
    neg     rax
    mov     edi, eax
    mov     rsi, rbx
    call    err_open_file
    mov     ebp, 1
    pop     rbx
    ret

; ============================================================================
;  process_fd(edi = fd)
;
;  Core fold algorithm. For each byte of input:
;    - In column mode: track column position with tab/bs/cr handling
;    - In byte mode: just count bytes
;    - When the NEXT character would exceed width, insert \n first
;    - With -s: backtrack to last blank (space or tab) instead of hard break
;
;  Register usage inside process_fd:
;    rbx = fd
;    r14 = column/byte count
;    r15 = last_blank_out_pos (-1 = none) for -s
;    r13 = last_blank_col (col value AT the blank, used for col restore)
;    [r12 = out_pos, global]
;    [ebp = had_error, global]
; ============================================================================
process_fd:
    push    rbx
    push    r14
    push    r15
    push    r13

    mov     ebx, edi
    xor     r14d, r14d                  ; col = 0
    mov     r15, -1                     ; no blank tracked
    xor     r13d, r13d                  ; last_blank_col = 0

.pf_read_loop:
    mov     edi, ebx
    lea     rsi, [read_buf]
    mov     edx, READ_BUF_SIZE
    call    asm_read
    test    rax, rax
    js      .pf_read_error
    jz      .pf_done

    xor     r8d, r8d                    ; offset = 0
    mov     r9, rax                     ; bytes read

    cmp     byte [flag_bytes], 0
    jne     .pf_byte_loop

; ── Column mode loop ──────────────────────────────────────
; Algorithm: for each byte, compute what the new column would be.
; If new_col > width, fold first (insert \n), then emit the byte.
; Special: \n always emitted, resets col. \b, \r never trigger fold.
.pf_col_loop:
    cmp     r8, r9
    jge     .pf_read_loop

    movzx   eax, byte [read_buf + r8]

    cmp     al, 10
    je      .pf_col_newline
    cmp     al, 8
    je      .pf_col_backspace
    cmp     al, 13
    je      .pf_col_cr
    cmp     al, 9
    je      .pf_col_tab

    ; Regular byte: new_col = col + 1
    lea     edx, [r14d + 1]            ; proposed new column
    mov     ecx, [width]
    cmp     edx, ecx
    jle     .pf_col_regular_ok

    ; Would exceed width: fold first
    ; fold_line sets r14d to base count (0 for hard, remaining for -s)
    call    fold_line

.pf_col_regular_ok:
    inc     r14d                        ; col += 1 (for this byte)

    ; Track blank for -s
    cmp     byte [flag_spaces], 0
    je      .pf_col_regular_emit
    cmp     byte [read_buf + r8], ' '
    jne     .pf_col_regular_emit
    ; Record this space: break point is after writing it
    ; out_pos+1 will be where \n goes; r14 is col after space
    lea     rax, [r12 + 1]
    mov     r15, rax                    ; blank_out_pos
    mov     r13d, r14d                  ; blank_col

.pf_col_regular_emit:
    ; Emit the byte
    mov     al, [read_buf + r8]
    mov     [out_buf + r12], al
    inc     r12

    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_col_next
    call    flush_output_safe
    jmp     .pf_col_next

.pf_col_next:
    inc     r8
    jmp     .pf_col_loop

.pf_col_newline:
    ; Output \n, reset everything
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1

    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_col_nl_next
    call    flush_output_safe
.pf_col_nl_next:
    inc     r8
    jmp     .pf_col_loop

.pf_col_backspace:
    ; col = max(0, col-1); emit byte
    test    r14d, r14d
    jz      .pf_col_bs_emit
    dec     r14d
.pf_col_bs_emit:
    mov     byte [out_buf + r12], 8
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_col_bs_next
    call    flush_output_safe
.pf_col_bs_next:
    inc     r8
    jmp     .pf_col_loop

.pf_col_cr:
    ; col = 0; emit byte
    xor     r14d, r14d
    mov     byte [out_buf + r12], 13
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_col_cr_next
    call    flush_output_safe
.pf_col_cr_next:
    inc     r8
    jmp     .pf_col_loop

.pf_col_tab:
    ; new_col = (col + 8) & ~7
    mov     eax, r14d
    add     eax, 8
    and     eax, ~7                     ; proposed new column

    ; If tab would push past width AND col > 0: fold BEFORE the tab
    mov     ecx, [width]
    cmp     eax, ecx
    jle     .pf_col_tab_no_prefold
    test    r14d, r14d
    jz      .pf_col_tab_no_prefold

    ; Fold before tab: insert \n, reset col, recompute tab col
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1
    ; Recompute: tab from col 0 goes to 8
    mov     eax, 8                      ; (0 + 8) & ~7 = 8

.pf_col_tab_no_prefold:
    mov     r14d, eax                   ; col = new_col

    ; Track tab as blank for -s
    cmp     byte [flag_spaces], 0
    je      .pf_col_tab_emit
    lea     rax, [r12 + 1]
    mov     r15, rax
    mov     r13d, r14d

.pf_col_tab_emit:
    mov     byte [out_buf + r12], 9
    inc     r12

    ; If col > width after tab (e.g., tab from col 0 goes to 8, width < 8),
    ; fold after the tab
    mov     ecx, [width]
    cmp     r14d, ecx
    jle     .pf_col_tab_no_fold

    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1

.pf_col_tab_no_fold:
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_col_tab_next
    call    flush_output_safe
.pf_col_tab_next:
    inc     r8
    jmp     .pf_col_loop

; ── Byte mode loop ────────────────────────────────────────
; Count bytes. When count would exceed width, fold. \n resets.
.pf_byte_loop:
    cmp     r8, r9
    jge     .pf_read_loop

    movzx   eax, byte [read_buf + r8]

    cmp     al, 10
    je      .pf_byte_newline

    ; Check if count+1 > width
    lea     edx, [r14d + 1]
    mov     ecx, [width]
    cmp     edx, ecx
    jle     .pf_byte_ok

    ; Would exceed: fold first
    ; fold_line sets r14d to base count (0 for hard, remaining for -s)
    call    fold_line

.pf_byte_ok:
    inc     r14d                        ; count += 1 (for this byte)

    ; Track blank for -s
    cmp     byte [flag_spaces], 0
    je      .pf_byte_emit
    movzx   eax, byte [read_buf + r8]
    cmp     al, ' '
    je      .pf_byte_mark_blank
    cmp     al, 9
    je      .pf_byte_mark_blank
    jmp     .pf_byte_emit

.pf_byte_mark_blank:
    lea     rax, [r12 + 1]
    mov     r15, rax
    mov     r13d, r14d

.pf_byte_emit:
    mov     al, [read_buf + r8]
    mov     [out_buf + r12], al
    inc     r12

    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_byte_next
    call    flush_output_safe
.pf_byte_next:
    inc     r8
    jmp     .pf_byte_loop

.pf_byte_newline:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1

    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_byte_nl_next
    call    flush_output_safe
.pf_byte_nl_next:
    inc     r8
    jmp     .pf_byte_loop

.pf_read_error:
    mov     ebp, 1
.pf_done:
    pop     r13
    pop     r15
    pop     r14
    pop     rbx
    ret

; ============================================================================
;  fold_line()
;  Insert fold point. If -s and blank tracked, break at blank. Else hard break.
;  Resets r14 (col), r15 (blank tracking).
;  Preserves r8, r9 (loop state).
; ============================================================================
fold_line:
    cmp     byte [flag_spaces], 0
    je      .fl_hard
    cmp     r15, -1
    je      .fl_hard

    ; -s mode: insert \n at last_blank_out_pos
    ; Shift bytes [blank_out_pos .. r12) right by 1, insert \n at blank_out_pos
    mov     rax, r12
    sub     rax, r15                    ; bytes to shift

    ; Ensure buffer space
    lea     rdx, [r12 + 1]
    cmp     rdx, OUT_BUF_SIZE
    jge     .fl_hard                    ; buffer full, fall back to hard break

    ; Shift bytes right by 1 (backwards copy for overlap safety)
    test    rax, rax
    jz      .fl_space_insert

    lea     rdi, [out_buf + r12]
    lea     rsi, [out_buf + r12 - 1]
    mov     rcx, rax
.fl_shift:
    mov     dl, [rsi]
    mov     [rdi], dl
    dec     rsi
    dec     rdi
    dec     rcx
    jnz     .fl_shift

.fl_space_insert:
    mov     byte [out_buf + r15], 10
    inc     r12

    ; Reset col: col = (current_col - blank_col)
    ; The bytes after the blank had columns counted from blank_col
    sub     r14d, r13d
    mov     r15, -1
    ret

.fl_hard:
    ; Insert \n at current position
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1
    ret

; ============================================================================
;  flush_output_safe()
;  Flushes output buffer. Invalidates blank tracking (r15 = -1).
; ============================================================================
flush_output_safe:
    call    flush_output
    test    eax, eax
    jnz     .fos_error
    mov     r15, -1
    ret
.fos_error:
    mov     ebp, 1
    mov     r15, -1
    ret

; ============================================================================
;  flush_output() -> rax = 0 success, -1 error. Resets r12.
; ============================================================================
flush_output:
    test    r12, r12
    jz      .fo_nothing
    mov     rdi, STDOUT
    lea     rsi, [out_buf]
    mov     rdx, r12
    call    asm_write_all
    xor     r12d, r12d
    ret
.fo_nothing:
    xor     eax, eax
    ret

; ============================================================================
;  String helpers
; ============================================================================
strcmp:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .sc_ne
    test    al, al
    jz      .sc_eq
    inc     rdi
    inc     rsi
    jmp     strcmp
.sc_eq:
    xor     eax, eax
    ret
.sc_ne:
    mov     eax, 1
    ret

strncmp:
    test    ecx, ecx
    jz      .sn_eq
.sn_loop:
    movzx   eax, byte [rdi]
    movzx   edx, byte [rsi]
    cmp     al, dl
    jne     .sn_ne
    inc     rdi
    inc     rsi
    dec     ecx
    jnz     .sn_loop
.sn_eq:
    xor     eax, eax
    ret
.sn_ne:
    mov     eax, 1
    ret

strlen:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; ============================================================================
;  Error output helpers
; ============================================================================
write_stderr:
    mov     rsi, rdi
    mov     rdi, STDERR
    mov     edx, edx                    ; zero-extend
    call    asm_write_all
    ret

write_stderr_buf:
    mov     rsi, rdi
    mov     rdi, STDERR
    call    asm_write_all
    ret

print_error_msg:
    push    rbx
    mov     rbx, rdi
    lea     rdi, [str_prefix]
    mov     edx, str_prefix_len
    call    write_stderr
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, rbx
    call    write_stderr_buf
    lea     rdi, [str_newline]
    mov     edx, 1
    call    write_stderr
    pop     rbx
    ret

err_open_file:
    push    rbx
    push    r13
    mov     r13d, edi
    mov     rbx, rsi

    lea     rdi, [str_prefix]
    mov     edx, str_prefix_len
    call    write_stderr

    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, rbx
    call    write_stderr_buf

    lea     rdi, [str_colon_space]
    mov     edx, 2
    call    write_stderr

    mov     edi, r13d
    call    strerror
    mov     rbx, rax
    mov     rdi, rax
    call    strlen
    mov     rdx, rax
    mov     rdi, rbx
    call    write_stderr_buf

    lea     rdi, [str_newline]
    mov     edx, 1
    call    write_stderr

    pop     r13
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
    lea     rax, [str_eunknown]
    ret
.se_eperm:
    lea     rax, [str_eperm]
    ret
.se_enoent:
    lea     rax, [str_enoent]
    ret
.se_eio:
    lea     rax, [str_eio]
    ret
.se_ebadf:
    lea     rax, [str_ebadf]
    ret
.se_enomem:
    lea     rax, [str_enomem]
    ret
.se_eacces:
    lea     rax, [str_eacces]
    ret
.se_enotdir:
    lea     rax, [str_enotdir]
    ret
.se_eisdir:
    lea     rax, [str_eisdir]
    ret
.se_einval:
    lea     rax, [str_einval]
    ret
.se_emfile:
    lea     rax, [str_emfile]
    ret
.se_enametoolong:
    lea     rax, [str_enametoolong]
    ret

; ============================================================================
;  Data Section
; ============================================================================
section .data

str_prefix:             db "fold: "
str_prefix_len equ $ - str_prefix

str_newline:            db 10
str_colon_space:        db ": "

str_dashdash_help:      db "--help", 0
str_dashdash_version:   db "--version", 0
str_dashdash_bytes:     db "--bytes", 0
str_dashdash_spaces:    db "--spaces", 0
str_dashdash_width:     db "--width", 0
str_dashdash_width_eq:  db "--width=", 0

str_unrecognized:       db "fold: unrecognized option '", 0
str_unrecognized_len equ $ - str_unrecognized - 1

str_invalid_opt:        db "fold: invalid option -- '", 0
str_invalid_opt_len equ $ - str_invalid_opt - 1

str_quote_nl:           db "'", 10

str_try_help:           db "Try 'fold --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_w_requires_arg:     db "option requires an argument -- 'w'"
str_w_requires_arg_len equ $ - str_w_requires_arg

str_width_requires_arg: db "option '--width' requires an argument"
str_width_requires_arg_len equ $ - str_width_requires_arg

str_invalid_width_pre:  db "invalid number of columns: '", 0
str_invalid_width_pre_len equ $ - str_invalid_width_pre - 1

str_invalid_width_suf:  db "': Numerical result out of range", 10
str_invalid_width_suf_len equ $ - str_invalid_width_suf

str_write_error:        db "write error", 0

; @@DATA_START@@
help_text:
    db "Usage: fold [OPTION]... [FILE]...", 10
    db "Wrap input lines in each FILE, writing to standard output.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -b, --bytes         count bytes rather than columns", 10
    db "  -s, --spaces        break at spaces", 10
    db "  -w, --width=WIDTH   use WIDTH columns instead of 80", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/fold>", 10
    db "or available locally via: info '(coreutils) fold invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "fold (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by David MacKenzie.", 10
version_text_len equ $ - version_text
; @@DATA_END@@

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

; ============================================================================
;  BSS Section
; ============================================================================
section .bss

width:              resd 1
argc_rem:           resd 1
flag_bytes:         resb 1
flag_spaces:        resb 1
past_dashdash:      resb 1
opt_char_buf:       resb 2

num_files:          resd 1
files:              resq MAX_FILES

read_buf:           resb READ_BUF_SIZE
out_buf:            resb OUT_BUF_SIZE

section .note.GNU-stack noalloc noexec nowrite progbits
