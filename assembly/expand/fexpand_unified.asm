; ============================================================
; fexpand_unified.asm — GNU-compatible 'expand' command
; Single nasm -f bin file with hand-crafted ELF header.
;
; Converts tabs to spaces with SSE2 SIMD acceleration.
; Supports -i/--initial, -t/--tabs=N, -t/--tabs=LIST,
; /N and +N repeating, --help, --version, --, multiple files,
; - for stdin.
;
; BUILD:
;   nasm -f bin fexpand_unified.asm -o fexpand && chmod +x fexpand
; ============================================================

BITS 64
org 0x400000

; --- Syscall numbers ---
%define SYS_READ         0
%define SYS_WRITE        1
%define SYS_OPEN         2
%define SYS_CLOSE        3
%define SYS_EXIT        60
%define SYS_RT_SIGPROCMASK 14

%define STDIN            0
%define STDOUT           1
%define STDERR           2
%define O_RDONLY         0
%define EINTR            4
%define SIGPIPE         13
%define SIG_BLOCK        0

%define READ_BUF_SIZE  131072
%define OUT_BUF_SIZE   262144
%define FLUSH_THRESHOLD 131072
%define MAX_TAB_STOPS   256
%define MAX_FILES        256

; Macros to save/restore caller-saved registers around function calls
%macro SAVE_PTRS 0
    mov     [save_r8], r8
    mov     [save_r9], r9
    mov     [save_r10], r10
%endmacro

%macro RESTORE_PTRS 0
    mov     r8, [save_r8]
    mov     r9, [save_r9]
    mov     r10, [save_r10]
%endmacro

; --- ELF Header (64 bytes) ---
ehdr:
    db 0x7f, 'E','L','F'       ; magic
    db 2                        ; 64-bit
    db 1                        ; little endian
    db 1                        ; ELF version
    db 0                        ; OS/ABI: System V
    dq 0                        ; padding
    dw 2                        ; ET_EXEC
    dw 0x3e                     ; x86_64
    dd 1                        ; ELF version
    dq _start                   ; entry point
    dq phdr - $$                ; program header offset
    dq 0                        ; section header offset
    dd 0                        ; flags
    dw ehdr_size                ; ELF header size
    dw phdr_size                ; program header entry size
    dw 2                        ; 2 program headers (PT_LOAD + PT_GNU_STACK)
    dw 64                       ; section header entry size
    dw 0                        ; section header count
    dw 0                        ; section name index
ehdr_size equ $ - ehdr

; --- Program Header 1: PT_LOAD (code + data + bss) ---
phdr:
    dd 1                        ; PT_LOAD
    dd 7                        ; PF_R | PF_W | PF_X
    dq 0                        ; offset
    dq $$                       ; virtual address
    dq $$                       ; physical address
    dq file_size                ; file size
    dq mem_size                 ; memory size (includes BSS)
    dq 0x200000                 ; alignment
phdr_size equ $ - phdr

; --- Program Header 2: PT_GNU_STACK (non-executable stack) ---
    dd 0x6474E551               ; PT_GNU_STACK
    dd 6                        ; PF_R | PF_W
    dq 0, 0, 0, 0, 0
    dq 0x10

; ===============================================================
; CODE
; ===============================================================

; --- I/O routines (inlined from lib/io.asm) ---

asm_write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.awa_loop:
    test    r13, r13
    jle     .awa_ok
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -EINTR
    je      .awa_loop
    test    rax, rax
    js      .awa_err
    add     r12, rax
    sub     r13, rax
    jmp     .awa_loop
.awa_ok:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.awa_err:
    mov     rax, -1
    pop     r13
    pop     r12
    pop     rbx
    ret

asm_read:
.ar_retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, -EINTR
    je      .ar_retry
    ret

; --- Main entry point ---
_start:
    ; Block SIGPIPE
    sub     rsp, 16
    mov     qword [rsp], 0
    mov     qword [rsp+8], 0
    bts     qword [rsp], SIGPIPE
    mov     rax, SYS_RT_SIGPROCMASK
    mov     rdi, SIG_BLOCK
    mov     rsi, rsp
    xor     rdx, rdx
    mov     r10, 8
    syscall
    add     rsp, 16

    ; Parse argc/argv
    mov     r14, [rsp]
    lea     r15, [rsp + 8]
    dec     r14
    add     r15, 8

    ; Initialize state
    xor     ebp, ebp
    xor     r12d, r12d
    xor     r13d, r13d              ; processed_any

    mov     dword [tab_mode], 0
    mov     qword [uniform_tab], 8
    mov     dword [num_tab_stops], 0
    mov     byte [initial_only], 0
    mov     dword [num_files], 0
    mov     byte [seen_dashdash], 0
    mov     qword [repeat_interval], 0
    mov     byte [repeat_relative], 0

    ; If no args, read stdin
    test    r14, r14
    jz      .read_stdin

    ; Parse arguments
    xor     ebx, ebx
.parse_loop:
    cmp     rbx, r14
    jge     .done_args
    mov     rsi, [r15 + rbx*8]

    ; If we've seen --, treat as file
    cmp     byte [seen_dashdash], 1
    je      .is_file

    cmp     byte [rsi], '-'
    jne     .is_file
    cmp     byte [rsi+1], 0
    je      .is_stdin_arg
    cmp     byte [rsi+1], '-'
    jne     .check_short
    cmp     byte [rsi+2], 0
    je      .set_dd

    ; Long options: --help, --version, --initial, --tabs=
    push    rbx
    mov     rdi, str_help_opt
    call    u_strcmp
    pop     rbx
    test    eax, eax
    jz      .do_help

    mov     rsi, [r15 + rbx*8]
    push    rbx
    mov     rdi, str_version_opt
    call    u_strcmp
    pop     rbx
    test    eax, eax
    jz      .do_version

    mov     rsi, [r15 + rbx*8]
    push    rbx
    mov     rdi, str_initial_opt
    call    u_strcmp
    pop     rbx
    test    eax, eax
    jz      .set_initial

    ; Check --tabs=
    mov     rsi, [r15 + rbx*8]
    push    rbx
    mov     rdi, str_tabs_eq
    mov     ecx, 7                  ; strlen("--tabs=")
    call    u_strncmp
    pop     rbx
    test    eax, eax
    jz      .parse_tabs_eq

    ; Unknown --option: exit with error
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.set_initial:
    mov     byte [initial_only], 1
    jmp     .parse_next

.parse_tabs_eq:
    mov     rsi, [r15 + rbx*8]
    add     rsi, 7
    push    rbx
    call    parse_tab_spec
    pop     rbx
    test    eax, eax
    jnz     .tab_parse_error
    jmp     .parse_next

.check_short:
    cmp     byte [rsi+1], 0
    je      .is_stdin_arg

    inc     rsi                     ; skip the '-'
    call    parse_short_opts
    test    eax, eax
    jnz     .short_opt_error
    jmp     .parse_next

.short_opt_error:
    cmp     eax, -1
    jne     .tab_parse_error
    inc     rbx
    cmp     rbx, r14
    jge     .done_args
    mov     rsi, [r15 + rbx*8]
    push    rbx
    call    parse_tab_spec
    pop     rbx
    test    eax, eax
    jnz     .tab_parse_error
    jmp     .parse_next

.tab_parse_error:
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.set_dd:
    mov     byte [seen_dashdash], 1
    jmp     .parse_next

.is_stdin_arg:
    push    rbx
    mov     r13d, 1
    mov     edi, STDIN
    call    process_fd
    pop     rbx
    jmp     .parse_next

.is_file:
    push    rbx
    mov     r13d, 1
    mov     rdi, rsi
    xor     esi, esi
    xor     edx, edx
    mov     rax, SYS_OPEN
    syscall
    test    rax, rax
    js      .file_err
    push    rax
    mov     edi, eax
    call    process_fd
    pop     rdi
    mov     rax, SYS_CLOSE
    syscall
    pop     rbx
    jmp     .parse_next

.file_err:
    mov     ebp, 1
    pop     rbx
    jmp     .parse_next

.parse_next:
    inc     rbx
    jmp     .parse_loop

.done_args:
    test    r13, r13
    jnz     .final_flush

.read_stdin:
    mov     edi, STDIN
    call    process_fd

.final_flush:
    call    flush_output
    movzx   rdi, bpl
    mov     rax, SYS_EXIT
    syscall

.do_help:
    call    flush_output
    mov     rdi, STDOUT
    mov     rsi, help_text
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

.do_version:
    call    flush_output
    mov     rdi, STDOUT
    mov     rsi, version_text
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

; --- parse_short_opts(rsi=ptr past '-') ---
parse_short_opts:
    push    rbx
    mov     rbx, rsi

.pso_loop:
    movzx   eax, byte [rbx]
    test    al, al
    jz      .pso_ok

    cmp     al, 'i'
    je      .pso_initial
    cmp     al, 't'
    je      .pso_tab

    ; Unknown short option
    pop     rbx
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.pso_initial:
    mov     byte [initial_only], 1
    inc     rbx
    jmp     .pso_loop

.pso_tab:
    inc     rbx
    cmp     byte [rbx], 0
    je      .pso_need_next_arg

    mov     rsi, rbx
    push    rbx
    call    parse_tab_spec
    pop     rbx
    pop     rbx
    ret

.pso_need_next_arg:
    mov     eax, -1
    pop     rbx
    ret

.pso_ok:
    xor     eax, eax
    pop     rbx
    ret

; --- parse_tab_spec(rsi=string) ---
parse_tab_spec:
    push    rbx
    push    r13
    push    r14
    push    r15
    mov     rbx, rsi

    mov     rdi, rbx
    call    has_separator
    test    eax, eax
    jnz     .pts_list_mode

    movzx   eax, byte [rbx]
    cmp     al, '/'
    je      .pts_uniform_repeat
    cmp     al, '+'
    je      .pts_uniform_repeat

    mov     rsi, rbx
    call    parse_number
    test    rax, rax
    js      .pts_error
    test    rax, rax
    jz      .pts_zero_error
    mov     [uniform_tab], rax
    mov     dword [tab_mode], 0
    jmp     .pts_ok

.pts_uniform_repeat:
    inc     rbx
    mov     rsi, rbx
    call    parse_number
    test    rax, rax
    js      .pts_error
    test    rax, rax
    jz      .pts_zero_error
    mov     [uniform_tab], rax
    mov     dword [tab_mode], 0
    jmp     .pts_ok

.pts_list_mode:
    mov     dword [tab_mode], 1
    mov     dword [num_tab_stops], 0
    mov     qword [repeat_interval], 0
    mov     byte [repeat_relative], 0
    mov     r14, rbx

.pts_list_next:
    movzx   eax, byte [r14]
    test    al, al
    jz      .pts_list_done
    cmp     al, ','
    je      .pts_skip_sep
    cmp     al, ' '
    je      .pts_skip_sep
    jmp     .pts_list_parse_num

.pts_skip_sep:
    inc     r14
    jmp     .pts_list_next

.pts_list_parse_num:
    movzx   eax, byte [r14]
    cmp     al, '/'
    je      .pts_list_repeat
    cmp     al, '+'
    je      .pts_list_repeat_relative

    mov     rsi, r14
    call    parse_number
    test    rax, rax
    js      .pts_error
    test    rax, rax
    jz      .pts_zero_error

    mov     ecx, [num_tab_stops]
    cmp     ecx, MAX_TAB_STOPS
    jge     .pts_error

    test    ecx, ecx
    jz      .pts_list_store
    lea     rdi, [tab_stops]
    mov     rdx, [rdi + (rcx-1)*8]
    cmp     rax, rdx
    jle     .pts_not_ascending

.pts_list_store:
    lea     rdi, [tab_stops]
    mov     [rdi + rcx*8], rax
    inc     ecx
    mov     [num_tab_stops], ecx

    mov     rsi, r14
    call    skip_number
    mov     r14, rax
    jmp     .pts_list_next

.pts_list_repeat:
    inc     r14
    mov     rsi, r14
    call    parse_number
    test    rax, rax
    js      .pts_error
    test    rax, rax
    jz      .pts_zero_error
    mov     [repeat_interval], rax
    mov     byte [repeat_relative], 0
    mov     rsi, r14
    call    skip_number
    mov     r14, rax
    jmp     .pts_list_done

.pts_list_repeat_relative:
    inc     r14
    mov     rsi, r14
    call    parse_number
    test    rax, rax
    js      .pts_error
    test    rax, rax
    jz      .pts_zero_error
    mov     [repeat_interval], rax
    mov     byte [repeat_relative], 1
    mov     rsi, r14
    call    skip_number
    mov     r14, rax
    jmp     .pts_list_done

.pts_list_done:
    jmp     .pts_ok

.pts_not_ascending:
    mov     rdi, STDERR
    mov     rsi, str_prefix
    mov     rdx, str_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_not_ascending
    mov     rdx, str_not_ascending_len
    call    asm_write_all
    jmp     .pts_error

.pts_zero_error:
    mov     rdi, STDERR
    mov     rsi, str_prefix
    mov     rdx, str_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_zero_tab
    mov     rdx, str_zero_tab_len
    call    asm_write_all
    jmp     .pts_error

.pts_error:
    mov     eax, 1
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

.pts_ok:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; --- has_separator(rdi=str) -> eax=1 if comma or space found ---
has_separator:
    xor     eax, eax
.hs_loop:
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .hs_done
    cmp     cl, ','
    je      .hs_found
    cmp     cl, ' '
    je      .hs_found
    inc     rdi
    jmp     .hs_loop
.hs_found:
    mov     eax, 1
.hs_done:
    ret

; --- parse_number(rsi=str) -> rax=value, -1 if invalid ---
parse_number:
    xor     rax, rax
    movzx   ecx, byte [rsi]
    sub     cl, '0'
    cmp     cl, 9
    ja      .pn_invalid
.pn_loop:
    movzx   ecx, byte [rsi]
    sub     cl, '0'
    cmp     cl, 9
    ja      .pn_done
    imul    rax, 10
    movzx   ecx, byte [rsi]
    sub     cl, '0'
    add     rax, rcx
    inc     rsi
    jmp     .pn_loop
.pn_done:
    movzx   ecx, byte [rsi]
    test    cl, cl
    jz      .pn_ok
    cmp     cl, ','
    je      .pn_ok
    cmp     cl, ' '
    je      .pn_ok
.pn_invalid:
    mov     rax, -1
.pn_ok:
    ret

; --- skip_number(rsi=str) -> rax=ptr past digits ---
skip_number:
    mov     rax, rsi
.sn_loop:
    movzx   ecx, byte [rax]
    sub     cl, '0'
    cmp     cl, 9
    ja      .sn_done
    inc     rax
    jmp     .sn_loop
.sn_done:
    ret

; --- process_fd(edi=fd) ---
process_fd:
    push    rbx
    push    r13
    push    r14
    push    r15

    mov     ebx, edi
    xor     r14d, r14d              ; column = 0

    mov     r13, [uniform_tab]
    mov     rax, r13
    dec     rax
    test    rax, r13
    jnz     .pf_not_pow2
    mov     r15, rax
    jmp     .pf_setup_done
.pf_not_pow2:
    xor     r15d, r15d
.pf_setup_done:
    mov     byte [init_done_flag], 0

.pf_read_loop:
    mov     edi, ebx
    mov     rsi, read_buf
    mov     edx, READ_BUF_SIZE
    call    asm_read
    test    rax, rax
    js      .pf_read_err
    jz      .pf_done

    mov     r8, read_buf
    lea     r9, [r8 + rax]
    mov     r10, out_buf
    add     r10, r12

    cmp     byte [initial_only], 1
    je      .pf_initial_mode

    cmp     dword [tab_mode], 1
    je      .pf_list_mode

    ; === FAST PATH: uniform tabs, no -i ===
    movdqa  xmm1, [tab_pattern]
    movdqa  xmm2, [newline_pattern]
    movdqa  xmm3, [backspace_pattern]

.pf_fast_simd:
    lea     rax, [out_buf + FLUSH_THRESHOLD]
    cmp     r10, rax
    jl      .pf_fast_simd_scan
    mov     rax, out_buf
    sub     r10, rax
    mov     r12, r10
    SAVE_PTRS
    call    flush_output
    RESTORE_PTRS
    mov     r10, out_buf
    movdqa  xmm1, [tab_pattern]
    movdqa  xmm2, [newline_pattern]
    movdqa  xmm3, [backspace_pattern]

.pf_fast_simd_scan:
    mov     rax, r9
    sub     rax, r8
    cmp     rax, 16
    jl      .pf_fast_scalar

    movdqu  xmm0, [r8]
    movdqa  xmm4, xmm0
    pcmpeqb xmm4, xmm1
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, xmm2
    por     xmm4, xmm5
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, xmm3
    por     xmm4, xmm5
    pmovmskb eax, xmm4
    test    eax, eax
    jnz     .pf_fast_simd_special

    movdqu  xmm0, [r8]
    movdqu  [r10], xmm0
    add     r8, 16
    add     r10, 16
    add     r14, 16
    jmp     .pf_fast_simd

.pf_fast_simd_special:
    bsf     ecx, eax
    test    ecx, ecx
    jz      .pf_fast_scalar

    movzx   edx, cl
    add     r14, rdx
    push    rsi
    push    rdi
    mov     rsi, r8
    mov     rdi, r10
    mov     ecx, edx
    rep movsb
    pop     rdi
    pop     rsi
    add     r8, rdx
    add     r10, rdx

.pf_fast_scalar:
    cmp     r8, r9
    jge     .pf_fast_done
    movzx   eax, byte [r8]
    cmp     al, 9
    je      .pf_fast_tab
    cmp     al, 10
    je      .pf_fast_newline
    cmp     al, 8
    je      .pf_fast_backspace
    mov     [r10], al
    inc     r10
    inc     r14
    inc     r8
    jmp     .pf_fast_simd

.pf_fast_tab:
    test    r15, r15
    jz      .pf_fast_tab_div
    mov     eax, r14d
    and     eax, r15d
    mov     ecx, r13d
    sub     ecx, eax
    jmp     .pf_fast_fill_spaces
.pf_fast_tab_div:
    mov     rax, r14
    xor     edx, edx
    div     r13
    mov     ecx, r13d
    sub     ecx, edx

.pf_fast_fill_spaces:
    add     r14, rcx
    cmp     ecx, 16
    ja      .pf_fast_fill_large
    movdqu  xmm7, [space_pattern]
    movdqu  [r10], xmm7
    add     r10, rcx
    inc     r8
    jmp     .pf_fast_simd
.pf_fast_fill_large:
    push    rdi
    mov     rdi, r10
    mov     al, ' '
    rep stosb
    mov     r10, rdi
    pop     rdi
    inc     r8
    jmp     .pf_fast_simd

.pf_fast_newline:
    mov     byte [r10], 10
    inc     r10
    inc     r8
    xor     r14d, r14d
    jmp     .pf_fast_simd

.pf_fast_backspace:
    mov     byte [r10], 8
    inc     r10
    inc     r8
    test    r14, r14
    jz      .pf_fast_simd
    dec     r14
    jmp     .pf_fast_simd

.pf_fast_done:
    mov     rax, out_buf
    sub     r10, rax
    mov     r12, r10
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_read_loop
    call    flush_output
    jmp     .pf_read_loop

    ; === LIST MODE ===
.pf_list_mode:
    movdqa  xmm1, [tab_pattern]
    movdqa  xmm2, [newline_pattern]
    movdqa  xmm3, [backspace_pattern]

.pf_list_simd:
    lea     rax, [out_buf + FLUSH_THRESHOLD]
    cmp     r10, rax
    jl      .pf_list_simd_scan
    mov     rax, out_buf
    sub     r10, rax
    mov     r12, r10
    SAVE_PTRS
    call    flush_output
    RESTORE_PTRS
    mov     r10, out_buf
    movdqa  xmm1, [tab_pattern]
    movdqa  xmm2, [newline_pattern]
    movdqa  xmm3, [backspace_pattern]

.pf_list_simd_scan:
    mov     rax, r9
    sub     rax, r8
    cmp     rax, 16
    jl      .pf_list_scalar

    movdqu  xmm0, [r8]
    movdqa  xmm4, xmm0
    pcmpeqb xmm4, xmm1
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, xmm2
    por     xmm4, xmm5
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, xmm3
    por     xmm4, xmm5
    pmovmskb eax, xmm4
    test    eax, eax
    jnz     .pf_list_simd_special

    movdqu  xmm0, [r8]
    movdqu  [r10], xmm0
    add     r8, 16
    add     r10, 16
    add     r14, 16
    jmp     .pf_list_simd

.pf_list_simd_special:
    bsf     ecx, eax
    test    ecx, ecx
    jz      .pf_list_scalar

    movzx   edx, cl
    add     r14, rdx
    push    rsi
    push    rdi
    mov     rsi, r8
    mov     rdi, r10
    mov     ecx, edx
    rep movsb
    pop     rdi
    pop     rsi
    add     r8, rdx
    add     r10, rdx

.pf_list_scalar:
    cmp     r8, r9
    jge     .pf_list_done
    movzx   eax, byte [r8]
    cmp     al, 9
    je      .pf_list_tab
    cmp     al, 10
    je      .pf_list_newline
    cmp     al, 8
    je      .pf_list_backspace
    mov     [r10], al
    inc     r10
    inc     r14
    inc     r8
    jmp     .pf_list_simd

.pf_list_tab:
    mov     rax, out_buf
    sub     r10, rax
    mov     r12, r10
    SAVE_PTRS
    call    calc_tab_spaces
    RESTORE_PTRS
    mov     r10, out_buf
    add     r10, r12

    mov     ecx, eax
    test    ecx, ecx
    jz      .pf_list_tab_done
    add     r14, rcx
    cmp     ecx, 16
    ja      .pf_list_fill_large
    movdqu  xmm7, [space_pattern]
    movdqu  [r10], xmm7
    add     r10, rcx
    jmp     .pf_list_tab_done
.pf_list_fill_large:
    push    rdi
    mov     rdi, r10
    mov     al, ' '
    rep stosb
    mov     r10, rdi
    pop     rdi
.pf_list_tab_done:
    inc     r8
    jmp     .pf_list_simd

.pf_list_newline:
    mov     byte [r10], 10
    inc     r10
    inc     r8
    xor     r14d, r14d
    jmp     .pf_list_simd

.pf_list_backspace:
    mov     byte [r10], 8
    inc     r10
    inc     r8
    test    r14, r14
    jz      .pf_list_simd
    dec     r14
    jmp     .pf_list_simd

.pf_list_done:
    mov     rax, out_buf
    sub     r10, rax
    mov     r12, r10
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_read_loop
    call    flush_output
    jmp     .pf_read_loop

    ; === INITIAL MODE (-i flag) ===
.pf_initial_mode:
    movdqa  xmm1, [tab_pattern]
    movdqa  xmm2, [newline_pattern]
    movdqa  xmm3, [backspace_pattern]
    movdqa  xmm6, [space_pattern]

.pf_init_simd:
    lea     rax, [out_buf + FLUSH_THRESHOLD]
    cmp     r10, rax
    jl      .pf_init_simd_scan
    mov     rax, out_buf
    sub     r10, rax
    mov     r12, r10
    SAVE_PTRS
    call    flush_output
    RESTORE_PTRS
    mov     r10, out_buf
    movdqa  xmm1, [tab_pattern]
    movdqa  xmm2, [newline_pattern]
    movdqa  xmm3, [backspace_pattern]
    movdqa  xmm6, [space_pattern]

.pf_init_simd_scan:
    mov     rax, r9
    sub     rax, r8
    cmp     rax, 16
    jl      .pf_init_scalar

    cmp     byte [init_done_flag], 1
    je      .pf_init_passthrough_simd

    movdqu  xmm0, [r8]
    movdqa  xmm4, xmm0
    pcmpeqb xmm4, xmm1
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, xmm2
    por     xmm4, xmm5
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, xmm3
    por     xmm4, xmm5
    pmovmskb eax, xmm4
    test    eax, eax
    jnz     .pf_init_simd_special

    movdqu  xmm0, [r8]
    movdqu  [r10], xmm0
    movdqu  xmm5, [r8]
    pcmpeqb xmm5, xmm6
    pmovmskb ecx, xmm5
    cmp     ecx, 0xFFFF
    je      .pf_init_all_spaces
    mov     byte [init_done_flag], 1
.pf_init_all_spaces:
    add     r8, 16
    add     r10, 16
    add     r14, 16
    jmp     .pf_init_simd

.pf_init_simd_special:
    bsf     ecx, eax
    test    ecx, ecx
    jz      .pf_init_scalar

    movzx   edx, cl
    add     r14, rdx
    push    rdx
    xor     ecx, ecx
.pf_init_pre_check:
    cmp     ecx, edx
    jge     .pf_init_pre_done
    cmp     byte [r8 + rcx], ' '
    jne     .pf_init_pre_nonblank
    inc     ecx
    jmp     .pf_init_pre_check
.pf_init_pre_nonblank:
    mov     byte [init_done_flag], 1
.pf_init_pre_done:
    pop     rdx
    push    rsi
    push    rdi
    mov     rsi, r8
    mov     rdi, r10
    mov     ecx, edx
    rep movsb
    pop     rdi
    pop     rsi
    add     r8, rdx
    add     r10, rdx

.pf_init_scalar:
    cmp     r8, r9
    jge     .pf_init_done
    movzx   eax, byte [r8]
    cmp     al, 9
    je      .pf_init_tab
    cmp     al, 10
    je      .pf_init_newline
    cmp     al, 8
    je      .pf_init_backspace
    mov     [r10], al
    inc     r10
    inc     r14
    inc     r8
    cmp     al, ' '
    je      .pf_init_simd
    mov     byte [init_done_flag], 1
    jmp     .pf_init_simd

.pf_init_tab:
    cmp     byte [init_done_flag], 1
    je      .pf_init_tab_pass

    cmp     dword [tab_mode], 1
    je      .pf_init_tab_list

    test    r15, r15
    jz      .pf_init_tab_div
    mov     eax, r14d
    and     eax, r15d
    mov     ecx, r13d
    sub     ecx, eax
    jmp     .pf_init_tab_fill
.pf_init_tab_div:
    mov     rax, r14
    xor     edx, edx
    div     r13
    mov     ecx, r13d
    sub     ecx, edx
    jmp     .pf_init_tab_fill

.pf_init_tab_list:
    mov     rax, out_buf
    sub     r10, rax
    mov     r12, r10
    SAVE_PTRS
    call    calc_tab_spaces
    RESTORE_PTRS
    mov     r10, out_buf
    add     r10, r12
    mov     ecx, eax

.pf_init_tab_fill:
    test    ecx, ecx
    jz      .pf_init_tab_done
    add     r14, rcx
    cmp     ecx, 16
    ja      .pf_init_fill_large
    movdqu  xmm7, [space_pattern]
    movdqu  [r10], xmm7
    add     r10, rcx
    jmp     .pf_init_tab_done
.pf_init_fill_large:
    push    rdi
    mov     rdi, r10
    mov     al, ' '
    rep stosb
    mov     r10, rdi
    pop     rdi
.pf_init_tab_done:
    inc     r8
    jmp     .pf_init_simd

.pf_init_tab_pass:
    mov     byte [r10], 9
    inc     r10
    inc     r14
    inc     r8
    jmp     .pf_init_simd

.pf_init_newline:
    mov     byte [r10], 10
    inc     r10
    inc     r8
    xor     r14d, r14d
    mov     byte [init_done_flag], 0
    jmp     .pf_init_simd

.pf_init_backspace:
    mov     byte [r10], 8
    inc     r10
    inc     r8
    test    r14, r14
    jz      .pf_init_simd
    dec     r14
    jmp     .pf_init_simd

.pf_init_passthrough_simd:
    movdqu  xmm0, [r8]
    movdqa  xmm4, xmm0
    pcmpeqb xmm4, xmm2
    pmovmskb eax, xmm4
    test    eax, eax
    jnz     .pf_init_pt_has_nl

    movdqu  [r10], xmm0
    add     r8, 16
    add     r10, 16
    add     r14, 16
    jmp     .pf_init_simd

.pf_init_pt_has_nl:
    bsf     ecx, eax
    test    ecx, ecx
    jz      .pf_init_pt_nl_emit

    movzx   edx, cl
    push    rsi
    push    rdi
    mov     rsi, r8
    mov     rdi, r10
    mov     ecx, edx
    rep movsb
    pop     rdi
    pop     rsi
    add     r8, rdx
    add     r10, rdx
    add     r14, rdx

.pf_init_pt_nl_emit:
    mov     byte [r10], 10
    inc     r10
    inc     r8
    xor     r14d, r14d
    mov     byte [init_done_flag], 0
    jmp     .pf_init_simd

.pf_init_done:
    mov     rax, out_buf
    sub     r10, rax
    mov     r12, r10
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_read_loop
    call    flush_output
    jmp     .pf_read_loop

.pf_done:
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

.pf_read_err:
    mov     ebp, 1
    jmp     .pf_done

; --- calc_tab_spaces(r14=column) -> eax=num_spaces ---
calc_tab_spaces:
    cmp     dword [tab_mode], 1
    je      .cts_list

    mov     rax, r14
    xor     edx, edx
    mov     rcx, [uniform_tab]
    div     rcx
    mov     rax, rcx
    sub     rax, rdx
    ret

.cts_list:
    mov     ecx, [num_tab_stops]
    test    ecx, ecx
    jz      .cts_list_single_space

    lea     rdi, [tab_stops]
    xor     edx, edx

.cts_list_search:
    cmp     edx, ecx
    jge     .cts_list_past_end
    mov     rax, [rdi + rdx*8]
    cmp     rax, r14
    ja      .cts_list_found
    inc     edx
    jmp     .cts_list_search

.cts_list_found:
    sub     rax, r14
    ret

.cts_list_past_end:
    mov     rax, [repeat_interval]
    test    rax, rax
    jz      .cts_list_single_space

    mov     rdx, [rdi + (rcx-1)*8]

    cmp     byte [repeat_relative], 1
    je      .cts_list_repeat_relative

    mov     rcx, rax
    mov     rax, r14
    xor     edx, edx
    div     rcx
    inc     rax
    imul    rax, rcx
    sub     rax, r14
    ret

.cts_list_repeat_relative:
    mov     rcx, rax
    push    rdx
    mov     rax, r14
    sub     rax, rdx
    xor     edx, edx
    div     rcx
    inc     rax
    imul    rax, rcx
    pop     rdx
    add     rax, rdx
    sub     rax, r14
    ret

.cts_list_single_space:
    mov     eax, 1
    ret

; --- flush_output ---
flush_output:
    test    r12, r12
    jz      .fo_nop
    mov     rdi, STDOUT
    mov     rsi, out_buf
    mov     rdx, r12
    call    asm_write_all
    test    eax, eax
    jnz     .fo_err
    xor     r12d, r12d
    xor     eax, eax
    ret
.fo_err:
    mov     ebp, 1
    xor     r12d, r12d
    mov     eax, -1
    ret
.fo_nop:
    xor     eax, eax
    ret

; --- u_strcmp(rdi=str1, rsi=str2) ---
u_strcmp:
.usc_loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .usc_ne
    test    al, al
    jz      .usc_eq
    inc     rdi
    inc     rsi
    jmp     .usc_loop
.usc_eq:
    xor     eax, eax
    ret
.usc_ne:
    mov     eax, 1
    ret

; --- u_strncmp(rdi=str1, rsi=str2, ecx=n) -> eax=0 if equal ---
u_strncmp:
    test    ecx, ecx
    jz      .usnc_eq
.usnc_loop:
    movzx   eax, byte [rdi]
    movzx   edx, byte [rsi]
    cmp     al, dl
    jne     .usnc_ne
    test    al, al
    jz      .usnc_eq
    inc     rdi
    inc     rsi
    dec     ecx
    jnz     .usnc_loop
.usnc_eq:
    xor     eax, eax
    ret
.usnc_ne:
    mov     eax, 1
    ret

; ===============================================================
; DATA
; ===============================================================

align 16
tab_pattern:
    times 16 db 9
align 16
newline_pattern:
    times 16 db 10
align 16
backspace_pattern:
    times 16 db 8
align 16
space_pattern:
    times 16 db 32

str_help_opt:       db "--help", 0
str_version_opt:    db "--version", 0
str_initial_opt:    db "--initial", 0
str_tabs_eq:        db "--tabs=", 0

str_prefix:         db "expand: "
str_prefix_len equ $ - str_prefix

str_zero_tab:       db "tab size cannot be 0", 10
str_zero_tab_len equ $ - str_zero_tab

str_not_ascending:  db "tab sizes must be ascending", 10
str_not_ascending_len equ $ - str_not_ascending

help_text:
    db "Usage: expand [OPTION]... [FILE]...", 10
    db "Convert tabs in each FILE to spaces, writing to standard output.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -i, --initial    do not convert tabs after non blanks", 10
    db "  -t, --tabs=N     have tabs N characters apart, not 8", 10
    db "  -t, --tabs=LIST  use comma separated list of tab positions.", 10
    db "                     The last specified position can be prefixed with '/'", 10
    db "                     to specify a tab size to use after the last", 10
    db "                     explicitly specified tab stop.  Also a prefix of '+'", 10
    db "                     can be used to align remaining tab stops relative to", 10
    db "                     the last specified tab stop instead of the first column", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
help_text_len equ $ - help_text

version_text:
    db "expand (fcoreutils) 0.1.0", 10
version_text_len equ $ - version_text

; ===============================================================
; BSS (uninitialized data — zero-filled by ELF loader)
; ===============================================================
file_size equ $ - $$

bss_base        equ $$ + file_size

tab_mode        equ bss_base + 0                    ; 4
_pad0           equ tab_mode + 4                    ; 4 (padding)
uniform_tab     equ _pad0 + 4                       ; 8
num_tab_stops   equ uniform_tab + 8                 ; 4
_pad1           equ num_tab_stops + 4               ; 4 (padding)
tab_stops       equ _pad1 + 4                       ; MAX_TAB_STOPS * 8 = 2048
repeat_interval equ tab_stops + MAX_TAB_STOPS * 8   ; 8
repeat_relative equ repeat_interval + 8             ; 1
initial_only    equ repeat_relative + 1             ; 1
seen_dashdash   equ initial_only + 1                ; 1
init_done_flag  equ seen_dashdash + 1               ; 1
_pad2           equ init_done_flag + 1              ; 4 (padding)
num_files       equ _pad2 + 4                       ; 4
_pad3           equ num_files + 4                   ; 4 (padding)
files           equ _pad3 + 4                       ; MAX_FILES * 8 = 2048

save_r8         equ files + MAX_FILES * 8           ; 8
save_r9         equ save_r8 + 8                     ; 8
save_r10        equ save_r9 + 8                     ; 8

; 16-byte alignment for SIMD: save_r10+8 is at a known offset from bss_base.
; bss_base is page-aligned (it follows file_size which is the binary image).
; The total offset from bss_base to save_r10+8 is deterministic — pad to 16.
_pre_buf        equ save_r10 + 8
_pre_buf_pad    equ 16 - (_pre_buf - bss_base) % 16
read_buf        equ _pre_buf + _pre_buf_pad         ; READ_BUF_SIZE = 131072
; out_buf also 16-byte aligned since READ_BUF_SIZE is a multiple of 16
out_buf         equ read_buf + READ_BUF_SIZE        ; OUT_BUF_SIZE = 262144

bss_end         equ out_buf + OUT_BUF_SIZE
mem_size        equ bss_end - $$
