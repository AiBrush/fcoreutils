; ============================================================================
;  fsort_unified.asm — Unified flat-binary build of fsort
;  Self-contained: includes ELF headers, all code, and BSS definitions.
;  Build: nasm -f bin fsort_unified.asm -o fsort_release && chmod +x fsort_release
; ============================================================================

BITS 64
org 0x400000

; ── Syscall numbers ──
%define SYS_READ         0
%define SYS_WRITE        1
%define SYS_OPEN         2
%define SYS_CLOSE        3
%define SYS_FSTAT        5
%define SYS_MMAP         9
%define SYS_MUNMAP      11
%define SYS_RT_SIGPROCMASK 14
%define SYS_MREMAP      25
%define SYS_EXIT        60

%define STDIN            0
%define STDOUT           1
%define STDERR           2
%define O_RDONLY         0
%define O_WRONLY         1
%define O_CREAT        0x40
%define O_TRUNC       0x200
%define EINTR            4
%define SIGPIPE         13

%define PROT_READ        1
%define PROT_WRITE       2
%define MAP_PRIVATE      2
%define MAP_ANONYMOUS   0x20
%define MREMAP_MAYMOVE   1

%define STAT_SIZE       48
%define STAT_STRUCT_SIZE 144

%define MAX_FILES       256
%define MAX_KEYS        32
%define OUTBUF_SIZE     131072
%define INITIAL_BUF     (4*1024*1024)
%define INITIAL_LINES   (256*1024)
%define LINE_ENTRY_SIZE 16
%define KEY_STRUCT_SIZE  40

; Option flags
%define FLAG_REVERSE    0x0001
%define FLAG_UNIQUE     0x0002
%define FLAG_NUMERIC    0x0004
%define FLAG_STABLE     0x0008
%define FLAG_CHECK      0x0010
%define FLAG_CHECK_Q    0x0020
%define FLAG_FOLD_CASE  0x0040
%define FLAG_DICT       0x0080
%define FLAG_IGNORE_NP  0x0100
%define FLAG_BLANKS     0x0200
%define FLAG_MERGE      0x0400
%define FLAG_ZERO_TERM  0x0800
%define FLAG_GEN_NUM    0x1000
%define FLAG_MONTH      0x2000
%define FLAG_HUMAN      0x4000
%define FLAG_VERSION    0x8000

; Key flags = same as FLAG_ values
%define KEY_REVERSE     FLAG_REVERSE
%define KEY_NUMERIC     FLAG_NUMERIC
%define KEY_FOLD_CASE   FLAG_FOLD_CASE
%define KEY_DICT        FLAG_DICT
%define KEY_IGNORE_NP   FLAG_IGNORE_NP
%define KEY_BLANKS      FLAG_BLANKS
%define KEY_GEN_NUM     FLAG_GEN_NUM
%define KEY_MONTH       FLAG_MONTH
%define KEY_HUMAN       FLAG_HUMAN
%define KEY_VERSION     FLAG_VERSION

; ── ELF Header ──
ehdr:
    db      0x7f, "ELF"
    db      2, 1, 1, 0
    dq      0
    dw      2
    dw      0x3E
    dd      1
    dq      _start
    dq      phdr - ehdr
    dq      0
    dd      0
    dw      ehdr_end - ehdr
    dw      phdr_size
    dw      3
    dw      0, 0, 0
ehdr_end:

; ── Program Headers ──
phdr:
    ; Code + Data (R+X)
    dd      1
    dd      5
    dq      0
    dq      0x400000
    dq      0x400000
    dq      file_end - ehdr
    dq      file_end - ehdr
    dq      0x1000
phdr_size equ $ - phdr

    ; BSS (R+W)
    dd      1
    dd      6
    dq      0
    dq      bss_start
    dq      bss_start
    dq      0
    dq      bss_size
    dq      0x1000

    ; GNU_STACK (NX)
    dd      0x6474E551
    dd      6
    dq      0, 0, 0, 0, 0
    dq      0x10

; ============================================================================
;                           ENTRY POINT
; ============================================================================
_start:
    ; Block SIGPIPE
    sub     rsp, 16
    mov     qword [rsp], 0x1000
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    ; Save argc/argv
    mov     rax, [rsp]
    mov     [argc], rax
    lea     rax, [rsp + 8]
    mov     [argv], rax

    ; Initialize defaults
    mov     qword [flag_bits], 0
    mov     qword [nfiles], 0
    mov     qword [output_file], 0
    mov     qword [output_fd], STDOUT
    mov     byte [has_separator], 0
    mov     byte [line_delim], 10
    mov     qword [nkeys], 0
    mov     qword [outbuf_pos], 0

    ; Parse arguments
    call    parse_args

    ; If -z, change delimiter
    test    qword [flag_bits], FLAG_ZERO_TERM
    jz      .no_zero
    mov     byte [line_delim], 0
.no_zero:

    ; If no files, use stdin
    cmp     qword [nfiles], 0
    jne     .have_files
    lea     rax, [str_dash]
    mov     [files], rax
    mov     qword [nfiles], 1
.have_files:

    ; Open output file if specified
    cmp     qword [output_file], 0
    je      .no_output_file
    mov     rdi, [output_file]
    mov     esi, O_WRONLY | O_CREAT | O_TRUNC
    mov     edx, 0o666
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .output_open_error
    mov     [output_fd], rax
.no_output_file:

    ; Check mode?
    mov     rax, [flag_bits]
    test    rax, FLAG_CHECK | FLAG_CHECK_Q
    jnz     .do_check

    ; Merge mode?
    test    rax, FLAG_MERGE
    jnz     .do_merge

    ; Normal sort
    call    read_all_input
    test    rax, rax
    js      .read_error
    call    scan_lines

    ; Determine fast comparison mode
    mov     byte [fast_cmp_mode], 0
    cmp     qword [nkeys], 0
    jne     .no_fast_cmp
    mov     rax, [flag_bits]
    test    rax, FLAG_NUMERIC | FLAG_FOLD_CASE | FLAG_DICT | FLAG_IGNORE_NP | FLAG_BLANKS | FLAG_GEN_NUM | FLAG_MONTH | FLAG_HUMAN | FLAG_VERSION
    jnz     .no_fast_cmp
    mov     byte [fast_cmp_mode], 1
.no_fast_cmp:

    call    sort_lines
    call    write_output
    jmp     .exit_success

.do_check:
    call    check_sorted
    jmp     .exit_success

.do_merge:
    call    read_all_input
    test    rax, rax
    js      .read_error
    call    scan_lines
    mov     byte [fast_cmp_mode], 0
    cmp     qword [nkeys], 0
    jne     .dm_no_fast
    mov     rax, [flag_bits]
    test    rax, FLAG_NUMERIC | FLAG_FOLD_CASE | FLAG_DICT | FLAG_IGNORE_NP | FLAG_BLANKS | FLAG_GEN_NUM | FLAG_MONTH | FLAG_HUMAN | FLAG_VERSION
    jnz     .dm_no_fast
    mov     byte [fast_cmp_mode], 1
.dm_no_fast:
    call    sort_lines
    call    write_output
    jmp     .exit_success

.read_error:
    mov     edi, 2
    jmp     do_exit

.output_open_error:
    mov     edi, 2
    jmp     do_exit

.exit_success:
    call    flush_outbuf
    cmp     qword [output_fd], STDOUT
    je      .skip_close
    mov     rdi, [output_fd]
    mov     eax, SYS_CLOSE
    syscall
.skip_close:
    xor     edi, edi
    jmp     do_exit

; ── Shared library functions (inlined) ──
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
    mov     eax, SYS_WRITE
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
    mov     eax, SYS_READ
    syscall
    cmp     rax, -EINTR
    je      .ar_retry
    ret

asm_open:
    mov     eax, SYS_OPEN
    syscall
    ret

asm_close:
    mov     eax, SYS_CLOSE
    syscall
    ret

do_exit:
    mov     eax, SYS_EXIT
    syscall

asm_strlen:
    xor     eax, eax
.asl_loop:
    cmp     byte [rdi + rax], 0
    je      .asl_done
    inc     rax
    jmp     .asl_loop
.asl_done:
    ret

asm_memcpy:
    mov     rax, rdi
    mov     rcx, rdx
    rep movsb
    ret

; ============================================================================
;  parse_args — same as modular but with absolute addressing
; ============================================================================
parse_args:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, [argv]
    mov     r13, [argc]
    mov     r14, 1
    xor     r15d, r15d

.arg_loop:
    cmp     r14, r13
    jge     .pa_done
    mov     rbx, [r12 + r14*8]
    test    r15d, r15d
    jnz     .is_file
    cmp     byte [rbx], '-'
    jne     .is_file
    cmp     byte [rbx+1], 0
    je      .is_file
    cmp     byte [rbx+1], '-'
    jne     .short_opts
    cmp     byte [rbx+2], 0
    jne     .long_opt
    mov     r15d, 1
    jmp     .next_arg

.long_opt:
    mov     rdi, rbx
    lea     rsi, [opt_help]
    call    str_equal
    test    eax, eax
    jnz     .do_help
    mov     rdi, rbx
    lea     rsi, [opt_version]
    call    str_equal
    test    eax, eax
    jnz     .do_version
    mov     rdi, rbx
    lea     rsi, [opt_reverse]
    call    str_equal
    test    eax, eax
    jnz     .set_reverse
    mov     rdi, rbx
    lea     rsi, [opt_unique]
    call    str_equal
    test    eax, eax
    jnz     .set_unique
    mov     rdi, rbx
    lea     rsi, [opt_numeric]
    call    str_equal
    test    eax, eax
    jnz     .set_numeric
    mov     rdi, rbx
    lea     rsi, [opt_stable]
    call    str_equal
    test    eax, eax
    jnz     .set_stable
    mov     rdi, rbx
    lea     rsi, [opt_check]
    call    str_equal
    test    eax, eax
    jnz     .set_check
    mov     rdi, rbx
    lea     rsi, [opt_ignore_case]
    call    str_equal
    test    eax, eax
    jnz     .set_fold_case
    mov     rdi, rbx
    lea     rsi, [opt_dictionary]
    call    str_equal
    test    eax, eax
    jnz     .set_dict
    mov     rdi, rbx
    lea     rsi, [opt_ignore_np]
    call    str_equal
    test    eax, eax
    jnz     .set_ignore_np
    mov     rdi, rbx
    lea     rsi, [opt_ignore_blanks]
    call    str_equal
    test    eax, eax
    jnz     .set_blanks
    mov     rdi, rbx
    lea     rsi, [opt_merge]
    call    str_equal
    test    eax, eax
    jnz     .set_merge
    mov     rdi, rbx
    lea     rsi, [opt_zero_terminated]
    call    str_equal
    test    eax, eax
    jnz     .set_zero_term
    mov     rdi, rbx
    lea     rsi, [opt_output_eq]
    call    str_starts_with
    test    eax, eax
    jnz     .parse_output_eq
    mov     rdi, rbx
    lea     rsi, [opt_output]
    call    str_equal
    test    eax, eax
    jnz     .parse_output_next
    mov     rdi, rbx
    lea     rsi, [opt_key_eq]
    call    str_starts_with
    test    eax, eax
    jnz     .parse_key_eq
    mov     rdi, rbx
    lea     rsi, [opt_key]
    call    str_equal
    test    eax, eax
    jnz     .parse_key_next
    mov     rdi, rbx
    lea     rsi, [opt_field_sep_eq]
    call    str_starts_with
    test    eax, eax
    jnz     .parse_sep_eq
    mov     rdi, rbx
    lea     rsi, [opt_field_sep]
    call    str_equal
    test    eax, eax
    jnz     .parse_sep_next
    mov     rdi, rbx
    lea     rsi, [opt_gen_numeric]
    call    str_equal
    test    eax, eax
    jnz     .set_gen_numeric
    mov     rdi, rbx
    lea     rsi, [opt_month_sort]
    call    str_equal
    test    eax, eax
    jnz     .set_month
    mov     rdi, rbx
    lea     rsi, [opt_human_sort]
    call    str_equal
    test    eax, eax
    jnz     .set_human
    mov     rdi, rbx
    lea     rsi, [opt_version_sort]
    call    str_equal
    test    eax, eax
    jnz     .set_version_sort
    mov     rdi, rbx
    lea     rsi, [opt_check_eq]
    call    str_starts_with
    test    eax, eax
    jnz     .parse_check_eq
    ; Unrecognized
    jmp     .error_unrec

.short_opts:
    lea     rbx, [rbx + 1]
.short_loop:
    movzx   eax, byte [rbx]
    test    al, al
    jz      .next_arg
    cmp     al, 'b'
    je      .sb
    cmp     al, 'c'
    je      .sc
    cmp     al, 'C'
    je      .sC
    cmp     al, 'd'
    je      .sd
    cmp     al, 'f'
    je      .sf
    cmp     al, 'g'
    je      .sg
    cmp     al, 'h'
    je      .sh
    cmp     al, 'i'
    je      .si
    cmp     al, 'k'
    je      .sk
    cmp     al, 'm'
    je      .sm
    cmp     al, 'M'
    je      .sM
    cmp     al, 'n'
    je      .sn
    cmp     al, 'o'
    je      .s_o
    cmp     al, 'r'
    je      .sr
    cmp     al, 's'
    je      .ss
    cmp     al, 't'
    je      .st_sep
    cmp     al, 'u'
    je      .su
    cmp     al, 'V'
    je      .sV
    cmp     al, 'z'
    je      .sz
    jmp     .error_inval

.sb: or qword [flag_bits], FLAG_BLANKS
     inc rbx
     jmp .short_loop
.sc: or qword [flag_bits], FLAG_CHECK
     inc rbx
     jmp .short_loop
.sC: or qword [flag_bits], FLAG_CHECK_Q
     inc rbx
     jmp .short_loop
.sd: or qword [flag_bits], FLAG_DICT
     inc rbx
     jmp .short_loop
.sf: or qword [flag_bits], FLAG_FOLD_CASE
     inc rbx
     jmp .short_loop
.sg: or qword [flag_bits], FLAG_GEN_NUM
     inc rbx
     jmp .short_loop
.sh: or qword [flag_bits], FLAG_HUMAN
     inc rbx
     jmp .short_loop
.si: or qword [flag_bits], FLAG_IGNORE_NP
     inc rbx
     jmp .short_loop
.sM: or qword [flag_bits], FLAG_MONTH
     inc rbx
     jmp .short_loop
.sn: or qword [flag_bits], FLAG_NUMERIC
     inc rbx
     jmp .short_loop
.sr: or qword [flag_bits], FLAG_REVERSE
     inc rbx
     jmp .short_loop
.ss: or qword [flag_bits], FLAG_STABLE
     inc rbx
     jmp .short_loop
.su: or qword [flag_bits], FLAG_UNIQUE
     inc rbx
     jmp .short_loop
.sz: or qword [flag_bits], FLAG_ZERO_TERM
     inc rbx
     jmp .short_loop
.sm: or qword [flag_bits], FLAG_MERGE
     inc rbx
     jmp .short_loop
.sV: or qword [flag_bits], FLAG_VERSION
     inc rbx
     jmp .short_loop
.sk:
    inc rbx
    cmp byte [rbx], 0
    jne .sk_inline
    inc r14
    cmp r14, r13
    jge .error_missing_k
    mov rbx, [r12 + r14*8]
.sk_inline:
    mov rdi, rbx
    call parse_key
    jmp .next_arg
.s_o:
    inc rbx
    cmp byte [rbx], 0
    jne .s_o_inline
    inc r14
    cmp r14, r13
    jge .error_missing_o
    mov rbx, [r12 + r14*8]
.s_o_inline:
    mov [output_file], rbx
    jmp .next_arg
.st_sep:
    inc rbx
    cmp byte [rbx], 0
    jne .st_inline
    inc r14
    cmp r14, r13
    jge .error_missing_t
    mov rbx, [r12 + r14*8]
.st_inline:
    movzx eax, byte [rbx]
    mov [separator], al
    mov byte [has_separator], 1
    jmp .next_arg

.set_reverse: or qword [flag_bits], FLAG_REVERSE
    jmp .next_arg
.set_unique: or qword [flag_bits], FLAG_UNIQUE
    jmp .next_arg
.set_numeric: or qword [flag_bits], FLAG_NUMERIC
    jmp .next_arg
.set_stable: or qword [flag_bits], FLAG_STABLE
    jmp .next_arg
.set_check: or qword [flag_bits], FLAG_CHECK
    jmp .next_arg
.set_fold_case: or qword [flag_bits], FLAG_FOLD_CASE
    jmp .next_arg
.set_dict: or qword [flag_bits], FLAG_DICT
    jmp .next_arg
.set_ignore_np: or qword [flag_bits], FLAG_IGNORE_NP
    jmp .next_arg
.set_blanks: or qword [flag_bits], FLAG_BLANKS
    jmp .next_arg
.set_merge: or qword [flag_bits], FLAG_MERGE
    jmp .next_arg
.set_zero_term: or qword [flag_bits], FLAG_ZERO_TERM
    jmp .next_arg
.set_gen_numeric: or qword [flag_bits], FLAG_GEN_NUM
    jmp .next_arg
.set_month: or qword [flag_bits], FLAG_MONTH
    jmp .next_arg
.set_human: or qword [flag_bits], FLAG_HUMAN
    jmp .next_arg
.set_version_sort: or qword [flag_bits], FLAG_VERSION
    jmp .next_arg

.parse_check_eq:
    lea rdi, [rbx + 8]
    lea rsi, [opt_check_quiet]
    call str_equal
    test eax, eax
    jnz .set_check_q
    lea rdi, [rbx + 8]
    lea rsi, [opt_check_silent]
    call str_equal
    test eax, eax
    jnz .set_check_q
    jmp .set_check
.set_check_q:
    or qword [flag_bits], FLAG_CHECK_Q
    jmp .next_arg

.parse_output_eq:
    lea rax, [rbx + 9]
    mov [output_file], rax
    jmp .next_arg
.parse_output_next:
    inc r14
    cmp r14, r13
    jge .error_missing_o
    mov rax, [r12 + r14*8]
    mov [output_file], rax
    jmp .next_arg
.parse_key_eq:
    lea rdi, [rbx + 6]
    call parse_key
    jmp .next_arg
.parse_key_next:
    inc r14
    cmp r14, r13
    jge .error_missing_k
    mov rdi, [r12 + r14*8]
    call parse_key
    jmp .next_arg
.parse_sep_eq:
    lea rax, [rbx + 18]
    movzx eax, byte [rax]
    mov [separator], al
    mov byte [has_separator], 1
    jmp .next_arg
.parse_sep_next:
    inc r14
    cmp r14, r13
    jge .error_missing_t
    mov rax, [r12 + r14*8]
    movzx eax, byte [rax]
    mov [separator], al
    mov byte [has_separator], 1
    jmp .next_arg

.is_file:
    mov rcx, [nfiles]
    cmp rcx, MAX_FILES
    jge .next_arg
    lea rax, [files]
    mov [rax + rcx*8], rbx
    inc qword [nfiles]
    jmp .next_arg

.next_arg:
    inc r14
    jmp .arg_loop

.pa_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.do_help:
    mov rdi, STDOUT
    lea rsi, [str_help]
    mov edx, str_help_len
    call asm_write_all
    xor edi, edi
    jmp do_exit

.do_version:
    mov rdi, STDOUT
    lea rsi, [str_version]
    mov edx, str_version_len
    call asm_write_all
    xor edi, edi
    jmp do_exit

.error_inval:
    mov edi, 2
    jmp do_exit
.error_unrec:
    mov edi, 2
    jmp do_exit
.error_missing_k:
    mov edi, 2
    jmp do_exit
.error_missing_o:
    mov edi, 2
    jmp do_exit
.error_missing_t:
    mov edi, 2
    jmp do_exit

; ============================================================================
;  parse_key
; ============================================================================
parse_key:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, [nkeys]
    cmp r13, MAX_KEYS
    jge .pk_done
    imul r14, r13, KEY_STRUCT_SIZE
    lea r15, [keys]
    add r15, r14
    mov qword [r15], 0
    mov qword [r15+8], 0
    mov qword [r15+16], 0
    mov qword [r15+24], 0
    mov qword [r15+32], 0
    mov rdi, r12
    call parse_number
    mov [r15], rax
    mov r12, rdi
    cmp byte [r12], '.'
    jne .pk_so
    inc r12
    mov rdi, r12
    call parse_number
    mov [r15+8], rax
    mov r12, rdi
.pk_so:
    mov rdi, r12
    lea rsi, [r15+32]
    call parse_key_opts
    mov r12, rdi
    cmp byte [r12], ','
    jne .pk_ne
    inc r12
    mov rdi, r12
    call parse_number
    mov [r15+16], rax
    mov r12, rdi
    cmp byte [r12], '.'
    jne .pk_eo
    inc r12
    mov rdi, r12
    call parse_number
    mov [r15+24], rax
    mov r12, rdi
.pk_eo:
    mov rdi, r12
    lea rsi, [r15+32]
    call parse_key_opts
.pk_ne:
    inc qword [nkeys]
.pk_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

parse_number:
    xor eax, eax
    xor ecx, ecx
.pn_loop:
    movzx ecx, byte [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja .pn_done
    imul rax, 10
    add rax, rcx
    inc rdi
    jmp .pn_loop
.pn_done:
    ret

parse_key_opts:
.pko_loop:
    movzx eax, byte [rdi]
    cmp al, 'b'
    je .pko_b
    cmp al, 'd'
    je .pko_d
    cmp al, 'f'
    je .pko_f
    cmp al, 'g'
    je .pko_g
    cmp al, 'h'
    je .pko_h
    cmp al, 'i'
    je .pko_i
    cmp al, 'M'
    je .pko_M
    cmp al, 'n'
    je .pko_n
    cmp al, 'r'
    je .pko_r
    cmp al, 'V'
    je .pko_V
    ret
.pko_b: or qword [rsi], KEY_BLANKS
    inc rdi
    jmp .pko_loop
.pko_d: or qword [rsi], KEY_DICT
    inc rdi
    jmp .pko_loop
.pko_f: or qword [rsi], KEY_FOLD_CASE
    inc rdi
    jmp .pko_loop
.pko_g: or qword [rsi], KEY_GEN_NUM
    inc rdi
    jmp .pko_loop
.pko_h: or qword [rsi], KEY_HUMAN
    inc rdi
    jmp .pko_loop
.pko_i: or qword [rsi], KEY_IGNORE_NP
    inc rdi
    jmp .pko_loop
.pko_M: or qword [rsi], KEY_MONTH
    inc rdi
    jmp .pko_loop
.pko_n: or qword [rsi], KEY_NUMERIC
    inc rdi
    jmp .pko_loop
.pko_r: or qword [rsi], KEY_REVERSE
    inc rdi
    jmp .pko_loop
.pko_V: or qword [rsi], KEY_VERSION
    inc rdi
    jmp .pko_loop

; ============================================================================
;  read_all_input
; ============================================================================
read_all_input:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor edi, edi
    mov rsi, INITIAL_BUF
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    mov eax, SYS_MMAP
    syscall
    test rax, rax
    js .rai_error
    mov [input_buf], rax
    mov qword [input_size], 0
    mov qword [input_cap], INITIAL_BUF
    xor r12d, r12d
.rai_file_loop:
    cmp r12, [nfiles]
    jge .rai_done
    lea rax, [files]
    mov rbx, [rax + r12*8]
    cmp byte [rbx], '-'
    jne .rai_open
    cmp byte [rbx+1], 0
    jne .rai_open
    xor r13d, r13d
    jmp .rai_read_fd
.rai_open:
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    call asm_open
    test rax, rax
    js .rai_file_err
    mov r13, rax
.rai_read_fd:
.rai_rl:
    mov rax, [input_size]
    mov rcx, [input_cap]
    sub rcx, rax
    cmp rcx, 65536
    jge .rai_dr
    push r13
    call grow_input_buffer
    pop r13
    mov rax, [input_size]
    mov rcx, [input_cap]
    sub rcx, rax
.rai_dr:
    mov rdi, r13
    mov rsi, [input_buf]
    add rsi, rax
    mov rdx, rcx
    cmp rdx, 1048576
    jbe .rai_rok
    mov rdx, 1048576
.rai_rok:
    call asm_read
    test rax, rax
    js .rai_error
    jz .rai_eof
    add [input_size], rax
    jmp .rai_rl
.rai_eof:
    test r13, r13
    jz .rai_nf
    mov rdi, r13
    call asm_close
.rai_nf:
    inc r12
    jmp .rai_file_loop
.rai_file_err:
    inc r12
    jmp .rai_file_loop
.rai_done:
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.rai_error:
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

grow_input_buffer:
    mov rdi, [input_buf]
    mov rsi, [input_cap]
    mov rdx, rsi
    shl rdx, 1
    mov r10d, MREMAP_MAYMOVE
    mov eax, SYS_MREMAP
    syscall
    test rax, rax
    js .gib_fail
    mov [input_buf], rax
    shl qword [input_cap], 1
    ret
.gib_fail:
    mov edi, 2
    jmp do_exit

; ============================================================================
;  scan_lines
; ============================================================================
scan_lines:
    push rbx
    push r12
    push r13
    push r14
    mov rsi, INITIAL_LINES * LINE_ENTRY_SIZE
    xor edi, edi
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    mov eax, SYS_MMAP
    syscall
    test rax, rax
    js .sl_fail
    mov [line_array], rax
    mov qword [line_count], 0
    mov qword [line_cap], INITIAL_LINES
    mov r12, [input_buf]
    mov r13, r12
    add r13, [input_size]
    movzx r14d, byte [line_delim]
    cmp r12, r13
    je .sl_done
.sl_ll:
    cmp r12, r13
    jge .sl_done
    mov rbx, r12
.sl_scan:
    cmp r12, r13
    jge .sl_fe
    movzx eax, byte [r12]
    cmp eax, r14d
    je .sl_fd
    inc r12
    jmp .sl_scan
.sl_fd:
    mov rdi, rbx
    mov rsi, r12
    sub rsi, rbx
    call add_line
    inc r12
    jmp .sl_ll
.sl_fe:
    cmp rbx, r13
    je .sl_done
    mov rdi, rbx
    mov rsi, r13
    sub rsi, rbx
    call add_line
.sl_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.sl_fail:
    mov edi, 2
    jmp do_exit

add_line:
    push rbx
    mov rcx, [line_count]
    cmp rcx, [line_cap]
    jb .al_ok
    push rdi
    push rsi
    mov rdi, [line_array]
    mov rsi, [line_cap]
    imul rsi, LINE_ENTRY_SIZE
    mov rdx, rsi
    shl rdx, 1
    mov r10d, MREMAP_MAYMOVE
    mov eax, SYS_MREMAP
    syscall
    test rax, rax
    js .al_fail
    mov [line_array], rax
    shl qword [line_cap], 1
    pop rsi
    pop rdi
    mov rcx, [line_count]
.al_ok:
    mov rax, [line_array]
    mov r10, rcx
    shl r10, 4
    mov [rax + r10], rdi
    mov [rax + r10 + 8], rsi
    inc qword [line_count]
    pop rbx
    ret
.al_fail:
    mov edi, 2
    jmp do_exit

; ============================================================================
;  sort_lines
; ============================================================================
sort_lines:
    push rbx
    push r12
    mov rcx, [line_count]
    cmp rcx, 2
    jl .srt_done
    mov rsi, rcx
    imul rsi, LINE_ENTRY_SIZE
    xor edi, edi
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    mov eax, SYS_MMAP
    syscall
    test rax, rax
    js .srt_fail
    mov [merge_temp], rax
    mov rdi, [line_array]
    mov rsi, [merge_temp]
    xor edx, edx
    mov rcx, [line_count]
    call merge_sort
    mov rdi, [merge_temp]
    mov rsi, [line_count]
    imul rsi, LINE_ENTRY_SIZE
    mov eax, SYS_MUNMAP
    syscall
.srt_done:
    pop r12
    pop rbx
    ret
.srt_fail:
    mov edi, 2
    jmp do_exit

; ============================================================================
;  merge_sort
; ============================================================================
merge_sort:
    mov eax, ecx
    sub eax, edx
    cmp eax, 2
    jl .ms_ret
    cmp eax, 2
    jne .ms_recurse
    push rdi
    push rsi
    push rdx
    push rcx
    mov r8, rdx
    imul r8, LINE_ENTRY_SIZE
    add r8, rdi
    mov r9, r8
    add r9, LINE_ENTRY_SIZE
    push r8
    push r9
    sub rsp, 8
    mov rdi, [r8]
    mov rsi, [r8+8]
    mov rdx, [r9]
    mov rcx, [r9+8]
    call compare_lines
    add rsp, 8
    pop r9
    pop r8
    test eax, eax
    jle .ms_2_ok
    mov rax, [r8]
    mov rbx, [r8+8]
    mov rcx, [r9]
    mov rdx, [r9+8]
    mov [r8], rcx
    mov [r8+8], rdx
    mov [r9], rax
    mov [r9+8], rbx
.ms_2_ok:
    pop rcx
    pop rdx
    pop rsi
    pop rdi
.ms_ret:
    ret
.ms_recurse:
    push rbp
    mov rbp, rsp
    push rdi
    push rsi
    push rdx
    push rcx
    mov eax, edx
    add eax, ecx
    shr eax, 1
    push rax
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov edx, [rbp-24]
    mov ecx, eax
    call merge_sort
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov edx, [rbp-40]
    mov ecx, [rbp-32]
    call merge_sort
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov edx, [rbp-24]
    mov ecx, [rbp-40]
    mov r8d, [rbp-32]
    call merge_func
    add rsp, 8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rbp
    ret

; ============================================================================
;  merge_func
; ============================================================================
merge_func:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    mov r12, rdi
    mov r13, rsi
    mov [rbp-48], edx
    mov [rbp-52], ecx
    mov [rbp-56], r8d
    mov eax, r8d
    sub eax, edx
    mov r14d, eax
    push rdx
    push rcx
    push r8
    movsxd rax, edx
    imul rax, LINE_ENTRY_SIZE
    lea rdi, [r13 + rax]
    lea rsi, [r12 + rax]
    movsxd rdx, r14d
    imul rdx, LINE_ENTRY_SIZE
    mov rcx, rdx
    rep movsb
    pop r8
    pop rcx
    pop rdx
    movsxd r14, dword [rbp-48]
    movsxd r15, dword [rbp-52]
    movsxd rbx, dword [rbp-48]
    movsxd r8, dword [rbp-52]
    movsxd r9, dword [rbp-56]
.ml:
    cmp r14, r8
    jge .mcr
    cmp r15, r9
    jge .mcl
    push r8
    push r9
    push rbx
    mov rax, r14
    shl rax, 4
    mov rdi, [r13 + rax]
    mov rsi, [r13 + rax + 8]
    mov rax, r15
    shl rax, 4
    mov rdx, [r13 + rax]
    mov rcx, [r13 + rax + 8]
    call compare_lines
    pop rbx
    pop r9
    pop r8
    test eax, eax
    jg .mtr
    mov rax, r14
    shl rax, 4
    mov rcx, [r13 + rax]
    mov rdx, [r13 + rax + 8]
    mov rax, rbx
    shl rax, 4
    mov [r12 + rax], rcx
    mov [r12 + rax + 8], rdx
    inc r14
    inc rbx
    jmp .ml
.mtr:
    mov rax, r15
    shl rax, 4
    mov rcx, [r13 + rax]
    mov rdx, [r13 + rax + 8]
    mov rax, rbx
    shl rax, 4
    mov [r12 + rax], rcx
    mov [r12 + rax + 8], rdx
    inc r15
    inc rbx
    jmp .ml
.mcl:
    cmp r14, r8
    jge .md
    mov rax, r14
    shl rax, 4
    mov rcx, [r13 + rax]
    mov rdx, [r13 + rax + 8]
    mov rax, rbx
    shl rax, 4
    mov [r12 + rax], rcx
    mov [r12 + rax + 8], rdx
    inc r14
    inc rbx
    jmp .mcl
.mcr:
    cmp r15, r9
    jge .md
    mov rax, r15
    shl rax, 4
    mov rcx, [r13 + rax]
    mov rdx, [r13 + rax + 8]
    mov rax, rbx
    shl rax, 4
    mov [r12 + rax], rcx
    mov [r12 + rax + 8], rdx
    inc r15
    inc rbx
    jmp .mcr
.md:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
;  compare_lines — with fast path
; ============================================================================
compare_lines:
    cmp byte [fast_cmp_mode], 1
    jne .cl_slow
    ; Fast inline memcmp
    push r12
    push r13
    mov r12, rsi
    mov r13, rcx
    mov rcx, r12
    cmp rcx, r13
    jbe .clf_ok
    mov rcx, r13
.clf_ok:
.clf_8:
    cmp rcx, 8
    jb .clf_1
    mov rax, [rdi]
    cmp rax, [rdx]
    jne .clf_1
    add rdi, 8
    add rdx, 8
    sub rcx, 8
    jmp .clf_8
.clf_1:
    test rcx, rcx
    jz .clf_len
    movzx eax, byte [rdi]
    movzx r8d, byte [rdx]
    sub eax, r8d
    jnz .clf_res
    inc rdi
    inc rdx
    dec rcx
    jmp .clf_1
.clf_len:
    mov rax, r12
    sub rax, r13
    test rax, rax
    jz .clf_zero
    js .clf_neg
    mov eax, 1
    jmp .clf_res
.clf_neg:
    mov eax, -1
.clf_res:
    test qword [flag_bits], FLAG_REVERSE
    jz .clf_done
    neg eax
.clf_done:
    pop r13
    pop r12
    ret
.clf_zero:
    xor eax, eax
    pop r13
    pop r12
    ret

.cl_slow:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov rbp, rsp
    sub rsp, 64
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx
    cmp qword [nkeys], 0
    jne .cl_wk
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    mov rcx, [rbp-32]
    mov r8, [flag_bits]
    call compare_fields
    test qword [flag_bits], FLAG_REVERSE
    jz .cl_done
    neg eax
    jmp .cl_done
.cl_wk:
    xor r12d, r12d
.cl_kl:
    cmp r12, [nkeys]
    jge .cl_keq
    imul r14, r12, KEY_STRUCT_SIZE
    lea r15, [keys]
    add r15, r14
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, [r15]
    mov rcx, [r15+8]
    mov r8, [r15+16]
    mov r9, [r15+24]
    call extract_key
    mov [rbp-40], rax
    mov [rbp-48], rdx
    mov rdi, [rbp-24]
    mov rsi, [rbp-32]
    mov rdx, [r15]
    mov rcx, [r15+8]
    mov r8, [r15+16]
    mov r9, [r15+24]
    call extract_key
    mov rdi, [rbp-40]
    mov rsi, [rbp-48]
    mov rcx, rdx
    mov rdx, rax
    mov r8, [r15+32]
    test r8, r8
    jnz .cl_ukf
    mov r8, [flag_bits]
.cl_ukf:
    call compare_fields
    test eax, eax
    jnz .cl_kd
    inc r12
    jmp .cl_kl
.cl_kd:
    mov r8, [r15+32]
    test r8, r8
    jnz .cl_ckr
    mov r8, [flag_bits]
.cl_ckr:
    test r8, KEY_REVERSE
    jz .cl_done
    neg eax
    jmp .cl_done
.cl_keq:
    test qword [flag_bits], FLAG_STABLE
    jnz .cl_rz
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    mov rcx, [rbp-32]
    xor r8d, r8d
    call compare_fields
    test qword [flag_bits], FLAG_REVERSE
    jz .cl_done
    neg eax
    jmp .cl_done
.cl_rz:
    xor eax, eax
.cl_done:
    add rsp, 64
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
;  compare_fields
; ============================================================================
compare_fields:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rbx, r8
    test rbx, FLAG_BLANKS | KEY_BLANKS
    jz .cf_nb
.cf_sb1:
    test r13, r13
    jz .cf_nb
    cmp byte [r12], ' '
    je .cf_sb1s
    cmp byte [r12], 9
    je .cf_sb1s
    jmp .cf_sb2
.cf_sb1s:
    inc r12
    dec r13
    jmp .cf_sb1
.cf_sb2:
    test r15, r15
    jz .cf_nb
    cmp byte [r14], ' '
    je .cf_sb2s
    cmp byte [r14], 9
    je .cf_sb2s
    jmp .cf_nb
.cf_sb2s:
    inc r14
    dec r15
    jmp .cf_sb2
.cf_nb:
    test rbx, FLAG_NUMERIC | KEY_NUMERIC
    jnz .cf_numeric
    test rbx, FLAG_GEN_NUM | KEY_GEN_NUM
    jnz .cf_numeric
    test rbx, FLAG_MONTH | KEY_MONTH
    jnz .cf_month
    test rbx, FLAG_HUMAN | KEY_HUMAN
    jnz .cf_numeric
    test rbx, FLAG_VERSION | KEY_VERSION
    jnz .cf_version
    test rbx, FLAG_FOLD_CASE | KEY_FOLD_CASE | FLAG_DICT | KEY_DICT | FLAG_IGNORE_NP | KEY_IGNORE_NP
    jnz .cf_filt
    ; Simple memcmp
    mov rcx, r13
    cmp rcx, r15
    jbe .cf_mo
    mov rcx, r15
.cf_mo:
    xor eax, eax
    test rcx, rcx
    jz .cf_ld
.cf_fl:
    cmp rcx, 8
    jb .cf_bl
    mov rax, [r12]
    cmp rax, [r14]
    jne .cf_bl
    add r12, 8
    add r14, 8
    sub rcx, 8
    jmp .cf_fl
.cf_bl:
    test rcx, rcx
    jz .cf_ld
    movzx eax, byte [r12]
    movzx edx, byte [r14]
    sub eax, edx
    jnz .cf_ret
    inc r12
    inc r14
    dec rcx
    jmp .cf_bl
.cf_ld:
    mov rax, r13
    sub rax, r15
    test rax, rax
    jz .cf_rz
    js .cf_rn
    mov eax, 1
    jmp .cf_ret
.cf_rn:
    mov eax, -1
    jmp .cf_ret
.cf_rz:
    xor eax, eax
.cf_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; Filtered comparison
.cf_filt:
    xor r8d, r8d
    xor r9d, r9d
.cf_fl_loop:
.cf_gc1:
    cmp r8, r13
    jge .cf_s1e
    movzx eax, byte [r12 + r8]
    inc r8
    test rbx, FLAG_DICT | KEY_DICT
    jz .cf_nod1
    call is_dict_char
    test eax, eax
    jz .cf_gc1
    movzx eax, byte [r12 + r8 - 1]
.cf_nod1:
    test rbx, FLAG_IGNORE_NP | KEY_IGNORE_NP
    jz .cf_noi1
    cmp al, 0x20
    jb .cf_gc1
    cmp al, 0x7E
    ja .cf_gc1
.cf_noi1:
    test rbx, FLAG_FOLD_CASE | KEY_FOLD_CASE
    jz .cf_nof1
    cmp al, 'a'
    jb .cf_nof1
    cmp al, 'z'
    ja .cf_nof1
    sub al, 32
.cf_nof1:
    mov cl, al
.cf_gc2:
    cmp r9, r15
    jge .cf_s2ewc1
    movzx eax, byte [r14 + r9]
    inc r9
    test rbx, FLAG_DICT | KEY_DICT
    jz .cf_nod2
    call is_dict_char
    test eax, eax
    jz .cf_gc2
    movzx eax, byte [r14 + r9 - 1]
.cf_nod2:
    test rbx, FLAG_IGNORE_NP | KEY_IGNORE_NP
    jz .cf_noi2
    cmp al, 0x20
    jb .cf_gc2
    cmp al, 0x7E
    ja .cf_gc2
.cf_noi2:
    test rbx, FLAG_FOLD_CASE | KEY_FOLD_CASE
    jz .cf_nof2
    cmp al, 'a'
    jb .cf_nof2
    cmp al, 'z'
    ja .cf_nof2
    sub al, 32
.cf_nof2:
    cmp cl, al
    jb .cf_fl_less
    ja .cf_fl_greater
    jmp .cf_fl_loop
.cf_s1e:
    cmp r9, r15
    jge .cf_rz
    jmp .cf_fl_less
.cf_s2ewc1:
    mov eax, 1
    jmp .cf_ret
.cf_fl_less:
    mov eax, -1
    jmp .cf_ret
.cf_fl_greater:
    mov eax, 1
    jmp .cf_ret

; Numeric comparison
.cf_numeric:
    mov rdi, r12
    mov rsi, r13
    call parse_sort_number
    push rax
    push rdx
    mov rdi, r14
    mov rsi, r15
    call parse_sort_number
    pop rcx
    pop r8
    cmp r8, rax
    jl .cf_nl
    jg .cf_ng
    cmp rcx, rdx
    jl .cf_nl
    jg .cf_ng
    xor eax, eax
    jmp .cf_ret
.cf_nl:
    mov eax, -1
    jmp .cf_ret
.cf_ng:
    mov eax, 1
    jmp .cf_ret

; Month comparison
.cf_month:
    mov rdi, r12
    mov rsi, r13
    call parse_month
    push rax
    mov rdi, r14
    mov rsi, r15
    call parse_month
    pop r8
    cmp r8d, eax
    jl .cf_nl
    jg .cf_ng
    xor eax, eax
    jmp .cf_ret

; Version sort
.cf_version:
    xor r8d, r8d
    xor r9d, r9d
.cf_vl:
    cmp r8, r13
    jge .cf_v_s1e
    cmp r9, r15
    jge .cf_v_s2e
    movzx eax, byte [r12 + r8]
    movzx ecx, byte [r14 + r9]
    sub eax, '0'
    cmp eax, 9
    ja .cf_v_nd1
    sub ecx, '0'
    cmp ecx, 9
    ja .cf_v_mix
    ; Both digits
    push r8
    push r9
.cf_v_sk01:
    cmp r8, r13
    jge .cf_v_nc
    cmp byte [r12 + r8], '0'
    jne .cf_v_nc
    inc r8
    jmp .cf_v_sk01
.cf_v_nc:
    mov rax, r8
.cf_v_c1:
    cmp rax, r13
    jge .cf_v_c1d
    movzx ecx, byte [r12 + rax]
    sub ecx, '0'
    cmp ecx, 9
    ja .cf_v_c1d
    inc rax
    jmp .cf_v_c1
.cf_v_c1d:
    mov r10, rax
    sub r10, r8
    pop r9
    push r9
.cf_v_sk02:
    cmp r9, r15
    jge .cf_v_c2
    cmp byte [r14 + r9], '0'
    jne .cf_v_c2
    inc r9
    jmp .cf_v_sk02
.cf_v_c2:
    mov rax, r9
.cf_v_c2l:
    cmp rax, r15
    jge .cf_v_c2d
    movzx ecx, byte [r14 + rax]
    sub ecx, '0'
    cmp ecx, 9
    ja .cf_v_c2d
    inc rax
    jmp .cf_v_c2l
.cf_v_c2d:
    mov r11, rax
    sub r11, r9
    cmp r10, r11
    jg .cf_v_pg
    jl .cf_v_pl
.cf_v_dcmp:
    test r10, r10
    jz .cf_v_deq
    movzx eax, byte [r12 + r8]
    movzx ecx, byte [r14 + r9]
    cmp eax, ecx
    jg .cf_v_pg
    jl .cf_v_pl
    inc r8
    inc r9
    dec r10
    jmp .cf_v_dcmp
.cf_v_deq:
    pop r9
    pop r8
.cf_v_a1:
    cmp r8, r13
    jge .cf_v_a2
    movzx eax, byte [r12 + r8]
    sub eax, '0'
    cmp eax, 9
    ja .cf_v_a2
    inc r8
    jmp .cf_v_a1
.cf_v_a2:
    cmp r9, r15
    jge .cf_vl
    movzx eax, byte [r14 + r9]
    sub eax, '0'
    cmp eax, 9
    ja .cf_vl
    inc r9
    jmp .cf_v_a2
.cf_v_pg:
    pop r9
    pop r8
    mov eax, 1
    jmp .cf_ret
.cf_v_pl:
    pop r9
    pop r8
    mov eax, -1
    jmp .cf_ret
.cf_v_nd1:
    add eax, '0'
    cmp al, cl
    jb .cf_fl_less
    ja .cf_fl_greater
    inc r8
    inc r9
    jmp .cf_vl
.cf_v_mix:
    add ecx, '0'
    add eax, '0'
    cmp al, cl
    jb .cf_fl_less
    ja .cf_fl_greater
    inc r8
    inc r9
    jmp .cf_vl
.cf_v_s1e:
    cmp r9, r15
    jge .cf_rz
    mov eax, -1
    jmp .cf_ret
.cf_v_s2e:
    mov eax, 1
    jmp .cf_ret

; ============================================================================
;  parse_sort_number
; ============================================================================
parse_sort_number:
    push rbx
    push r12
    mov r12, rdi
    mov rbx, rsi
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
.psn_ws:
    test rbx, rbx
    jz .psn_done
    cmp byte [r12], ' '
    je .psn_sk
    cmp byte [r12], 9
    je .psn_sk
    jmp .psn_sign
.psn_sk:
    inc r12
    dec rbx
    jmp .psn_ws
.psn_sign:
    test rbx, rbx
    jz .psn_done
    cmp byte [r12], '-'
    je .psn_neg
    cmp byte [r12], '+'
    je .psn_pos
    jmp .psn_dig
.psn_neg:
    mov ecx, 1
    inc r12
    dec rbx
    jmp .psn_dig
.psn_pos:
    inc r12
    dec rbx
.psn_dig:
    test rbx, rbx
    jz .psn_as
    movzx r8d, byte [r12]
    sub r8d, '0'
    cmp r8d, 9
    ja .psn_as
    imul rax, 10
    add rax, r8
    inc r12
    dec rbx
    jmp .psn_dig
.psn_as:
    test ecx, ecx
    jz .psn_done
    neg rax
    neg rdx
.psn_done:
    pop r12
    pop rbx
    ret

; ============================================================================
;  parse_month
; ============================================================================
parse_month:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
.pm_sk:
    test r13, r13
    jz .pm_unk
    cmp byte [r12], ' '
    je .pm_sn
    cmp byte [r12], 9
    je .pm_sn
    jmp .pm_chk
.pm_sn:
    inc r12
    dec r13
    jmp .pm_sk
.pm_chk:
    cmp r13, 3
    jb .pm_unk
    movzx eax, byte [r12]
    call to_upper_al
    mov bl, al
    movzx eax, byte [r12+1]
    call to_upper_al
    mov bh, al
    movzx eax, byte [r12+2]
    call to_upper_al
    mov cl, al
    lea rdx, [month_names]
    mov r8d, 1
.pm_cl:
    cmp r8d, 13
    jge .pm_unk
    cmp bl, [rdx]
    jne .pm_nx
    cmp bh, [rdx+1]
    jne .pm_nx
    cmp cl, [rdx+2]
    jne .pm_nx
    mov eax, r8d
    pop r13
    pop r12
    pop rbx
    ret
.pm_nx:
    add rdx, 4
    inc r8d
    jmp .pm_cl
.pm_unk:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

to_upper_al:
    cmp al, 'a'
    jb .tu_d
    cmp al, 'z'
    ja .tu_d
    sub al, 32
.tu_d:
    ret

is_dict_char:
    cmp al, ' '
    je .idc_y
    cmp al, 9
    je .idc_y
    cmp al, '0'
    jb .idc_n
    cmp al, '9'
    jbe .idc_y
    cmp al, 'A'
    jb .idc_n
    cmp al, 'Z'
    jbe .idc_y
    cmp al, 'a'
    jb .idc_n
    cmp al, 'z'
    jbe .idc_y
.idc_n:
    xor eax, eax
    ret
.idc_y:
    mov eax, 1
    ret

; ============================================================================
;  extract_key
; ============================================================================
extract_key:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    test r14, r14
    jz .ek_wl
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call find_field_start
    mov rbx, rax
    test r15, r15
    jz .ek_nsc
    dec r15
    add rbx, r15
    cmp rbx, r13
    jbe .ek_nsc
    mov rbx, r13
.ek_nsc:
    cmp r8, 0
    je .ek_eol
    mov rdi, r12
    mov rsi, r13
    mov rdx, r8
    call find_field_end
    mov rcx, rax
    test r9, r9
    jz .ek_eok
    mov rdi, r12
    mov rsi, r13
    mov rdx, r8
    call find_field_start
    add rax, r9
    cmp rax, r13
    jbe .ek_uec
    mov rax, r13
.ek_uec:
    mov rcx, rax
.ek_eok:
    cmp rbx, rcx
    jge .ek_emp
    lea rax, [r12 + rbx]
    mov rdx, rcx
    sub rdx, rbx
    jmp .ek_done
.ek_eol:
    lea rax, [r12 + rbx]
    mov rdx, r13
    sub rdx, rbx
    cmp rdx, 0
    jge .ek_done
    xor edx, edx
    jmp .ek_done
.ek_wl:
    mov rax, r12
    mov rdx, r13
    jmp .ek_done
.ek_emp:
    lea rax, [r12 + r13]
    xor edx, edx
.ek_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

find_field_start:
    push rbx
    push r12
    mov r12, rdx
    xor eax, eax
    mov rbx, 1
    cmp r12, 1
    jle .ffs_done
    cmp byte [has_separator], 1
    je .ffs_sl
.ffs_sc:
    cmp rax, rsi
    jge .ffs_done
    cmp byte [rdi + rax], ' '
    je .ffs_ib
    cmp byte [rdi + rax], 9
    je .ffs_ib
    inc rax
    jmp .ffs_sc
.ffs_ib:
    cmp rax, rsi
    jge .ffs_done
    cmp byte [rdi + rax], ' '
    je .ffs_ibs
    cmp byte [rdi + rax], 9
    je .ffs_ibs
    jmp .ffs_nf
.ffs_ibs:
    inc rax
    jmp .ffs_ib
.ffs_nf:
    inc rbx
    cmp rbx, r12
    jge .ffs_done
    jmp .ffs_sc
.ffs_sl:
    movzx ecx, byte [separator]
.ffs_ss:
    cmp rax, rsi
    jge .ffs_done
    cmp byte [rdi + rax], cl
    je .ffs_sf
    inc rax
    jmp .ffs_ss
.ffs_sf:
    inc rax
    inc rbx
    cmp rbx, r12
    jge .ffs_done
    jmp .ffs_ss
.ffs_done:
    pop r12
    pop rbx
    ret

find_field_end:
    push rbx
    push r12
    mov r12, rdx
    call find_field_start
    cmp byte [has_separator], 1
    je .ffe_sep
.ffe_be:
    cmp rax, rsi
    jge .ffe_done
    cmp byte [rdi + rax], ' '
    je .ffe_done
    cmp byte [rdi + rax], 9
    je .ffe_done
    inc rax
    jmp .ffe_be
.ffe_sep:
    movzx ecx, byte [separator]
.ffe_ss:
    cmp rax, rsi
    jge .ffe_done
    cmp byte [rdi + rax], cl
    je .ffe_done
    inc rax
    jmp .ffe_ss
.ffe_done:
    pop r12
    pop rbx
    ret

; ============================================================================
;  write_output
; ============================================================================
write_output:
    push rbx
    push r12
    push r13
    push r14
    mov r12, [line_array]
    mov r13, [line_count]
    xor r14d, r14d
    movzx ebx, byte [line_delim]
    test r13, r13
    jz .wo_done
    test qword [flag_bits], FLAG_UNIQUE
    jnz .wo_ul
.wo_loop:
    cmp r14, r13
    jge .wo_done
    mov rax, r14
    shl rax, 4
    mov rdi, [r12 + rax]
    mov rsi, [r12 + rax + 8]
    call outbuf_write
    lea rdi, [line_delim]
    mov rsi, 1
    call outbuf_write
    inc r14
    jmp .wo_loop
.wo_ul:
    cmp r14, r13
    jge .wo_done
    mov rax, r14
    shl rax, 4
    mov rdi, [r12 + rax]
    mov rsi, [r12 + rax + 8]
    call outbuf_write
    lea rdi, [line_delim]
    mov rsi, 1
    call outbuf_write
.wo_sd:
    mov rax, r14
    inc rax
    cmp rax, r13
    jge .wo_un
    push rax
    mov rcx, r14
    shl rcx, 4
    mov rdi, [r12 + rcx]
    mov rsi, [r12 + rcx + 8]
    mov rcx, rax
    shl rcx, 4
    mov rdx, [r12 + rcx]
    mov rcx, [r12 + rcx + 8]
    call compare_lines
    mov ecx, eax
    pop rax
    test ecx, ecx
    jnz .wo_un
    mov r14, rax
    jmp .wo_sd
.wo_un:
    mov r14, rax
    cmp r14, r13
    jl .wo_ul
.wo_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

outbuf_write:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
.obw_l:
    test r12, r12
    jz .obw_d
    mov rax, [outbuf_pos]
    mov rcx, OUTBUF_SIZE
    sub rcx, rax
    mov rdx, r12
    cmp rdx, rcx
    jbe .obw_c
    mov rdx, rcx
.obw_c:
    push rdx
    lea rdi, [outbuf]
    add rdi, [outbuf_pos]
    mov rsi, rbx
    mov rcx, rdx
    rep movsb
    pop rdx
    add [outbuf_pos], rdx
    add rbx, rdx
    sub r12, rdx
    cmp qword [outbuf_pos], OUTBUF_SIZE
    jb .obw_l
    call flush_outbuf
    jmp .obw_l
.obw_d:
    pop r12
    pop rbx
    ret

flush_outbuf:
    mov rdx, [outbuf_pos]
    test rdx, rdx
    jz .fob_d
    mov rdi, [output_fd]
    lea rsi, [outbuf]
    call asm_write_all
    test rax, rax
    js .fob_e
    mov qword [outbuf_pos], 0
.fob_d:
    ret
.fob_e:
    mov edi, 2
    jmp do_exit

; ============================================================================
;  check_sorted
; ============================================================================
check_sorted:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call read_all_input
    test rax, rax
    js .cs_err
    call scan_lines
    ; Set fast_cmp_mode
    mov byte [fast_cmp_mode], 0
    cmp qword [nkeys], 0
    jne .cs_nf
    mov rax, [flag_bits]
    test rax, FLAG_NUMERIC | FLAG_FOLD_CASE | FLAG_DICT | FLAG_IGNORE_NP | FLAG_BLANKS | FLAG_GEN_NUM | FLAG_MONTH | FLAG_HUMAN | FLAG_VERSION
    jnz .cs_nf
    mov byte [fast_cmp_mode], 1
.cs_nf:
    mov r12, [line_array]
    mov r13, [line_count]
    cmp r13, 2
    jl .cs_sorted
    mov r14, 1
.cs_loop:
    cmp r14, r13
    jge .cs_sorted
    mov rax, r14
    dec rax
    shl rax, 4
    mov rdi, [r12 + rax]
    mov rsi, [r12 + rax + 8]
    mov rax, r14
    shl rax, 4
    mov rdx, [r12 + rax]
    mov rcx, [r12 + rax + 8]
    call compare_lines
    test qword [flag_bits], FLAG_UNIQUE
    jnz .cs_strict
    test eax, eax
    jg .cs_unsorted
    jmp .cs_next
.cs_strict:
    test eax, eax
    jge .cs_unsorted
.cs_next:
    inc r14
    jmp .cs_loop
.cs_sorted:
    xor edi, edi
    jmp do_exit
.cs_unsorted:
    test qword [flag_bits], FLAG_CHECK_Q
    jnz .cs_uexit
    ; Print disorder message
    mov rdi, STDERR
    lea rsi, [str_sort_prefix]
    mov edx, str_sort_prefix_len
    call asm_write_all
    lea rax, [files]
    mov rdi, [rax]
    call asm_strlen
    mov rdx, rax
    lea rax, [files]
    mov rsi, [rax]
    mov rdi, STDERR
    call asm_write_all
    mov rdi, STDERR
    lea rsi, [str_colon]
    mov edx, 1
    call asm_write_all
    lea rdi, [r14 + 1]
    lea rsi, [errbuf]
    call asm_itoa_local
    mov rdx, rax
    mov rdi, STDERR
    lea rsi, [errbuf]
    call asm_write_all
    mov rdi, STDERR
    lea rsi, [str_disorder_sep]
    mov edx, str_disorder_sep_len
    call asm_write_all
    mov rdi, STDERR
    mov rax, r14
    shl rax, 4
    mov rsi, [r12 + rax]
    mov rdx, [r12 + rax + 8]
    call asm_write_all
    mov rdi, STDERR
    lea rsi, [str_newline]
    mov edx, 1
    call asm_write_all
.cs_uexit:
    mov edi, 1
    jmp do_exit
.cs_err:
    mov edi, 2
    jmp do_exit

asm_itoa_local:
    push rbx
    mov rax, rdi
    mov rbx, rsi
    test rax, rax
    jnz .ail_c
    mov byte [rsi], '0'
    mov rax, 1
    pop rbx
    ret
.ail_c:
    mov r8, rsi
.ail_d:
    xor edx, edx
    mov rcx, 10
    div rcx
    add dl, '0'
    mov [rsi], dl
    inc rsi
    test rax, rax
    jnz .ail_d
    mov rax, rsi
    sub rax, r8
    dec rsi
    mov rdi, r8
.ail_r:
    cmp rdi, rsi
    jge .ail_dn
    mov cl, [rdi]
    mov ch, [rsi]
    mov [rdi], ch
    mov [rsi], cl
    inc rdi
    dec rsi
    jmp .ail_r
.ail_dn:
    pop rbx
    ret

str_equal:
.se_l:
    movzx eax, byte [rdi]
    movzx ecx, byte [rsi]
    cmp al, cl
    jne .se_ne
    test al, al
    jz .se_eq
    inc rdi
    inc rsi
    jmp .se_l
.se_eq:
    mov eax, 1
    ret
.se_ne:
    xor eax, eax
    ret

str_starts_with:
.ssw_l:
    movzx ecx, byte [rsi]
    test cl, cl
    jz .ssw_y
    movzx eax, byte [rdi]
    cmp al, cl
    jne .ssw_n
    inc rdi
    inc rsi
    jmp .ssw_l
.ssw_y:
    mov eax, 1
    ret
.ssw_n:
    xor eax, eax
    ret

; ============================================================================
;                           DATA SECTION
; ============================================================================

; @@DATA_START@@
str_help:
    db "Usage: sort [OPTION]... [FILE]...", 10
    db "  or:  sort [OPTION]... --files0-from=F", 10
    db "Write sorted concatenation of all FILE(s) to standard output.", 10, 10
    db "With no FILE, or when FILE is -, read standard input.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "Ordering options:", 10, 10
    db "  -b, --ignore-leading-blanks  ignore leading blanks", 10
    db "  -d, --dictionary-order       consider only blanks and alphanumeric characters", 10
    db "  -f, --ignore-case            fold lower case to upper case characters", 10
    db "  -g, --general-numeric-sort   compare according to general numerical value", 10
    db "  -i, --ignore-nonprinting     consider only printable characters", 10
    db "  -M, --month-sort             compare (unknown) < 'JAN' < ... < 'DEC'", 10
    db "  -h, --human-numeric-sort     compare human readable numbers (e.g., 2K 1G)", 10
    db "  -n, --numeric-sort           compare according to string numerical value", 10
    db "  -R, --random-sort            shuffle, but group identical keys.  See shuf(1)", 10
    db "      --random-source=FILE     get random bytes from FILE", 10
    db "  -r, --reverse                reverse the result of comparisons", 10
    db "  -V, --version-sort           natural sort of (version) numbers within text", 10, 10
    db "Other options:", 10, 10
    db "      --batch-size=NMERGE   use at most NMERGE inputs at once; for more use temp files", 10
    db "  -c, --check, --check=diagnose-first  check for sorted input; do not sort", 10
    db "  -C, --check=quiet, --check=silent  like -c, but do not report first bad line", 10
    db "      --compress-program=PROG  compress temporaries with PROG;", 10
    db "                              decompress them with PROG -d", 10
    db "      --debug                  annotate the part of the line used to sort,", 10
    db "                              and warn about questionable usage to stderr", 10
    db "      --files0-from=F          read input from the files specified by", 10
    db "                              NUL-terminated names in file F;", 10
    db "                              If F is - then read names from standard input", 10
    db "  -k, --key=KEYDEF            sort via a key; KEYDEF gives location and type", 10
    db "  -m, --merge                  merge already sorted files; do not sort", 10
    db "  -o, --output=FILE            write result to FILE instead of standard output", 10
    db "  -s, --stable                 stabilize sort by disabling last-resort comparison", 10
    db "  -S, --buffer-size=SIZE       use SIZE for main memory buffer", 10
    db "  -t, --field-separator=SEP    use SEP instead of non-blank to blank transition", 10
    db "  -T, --temporary-directory=DIR  use DIR for temporaries, not $TMPDIR or default;", 10
    db "                              multiple options specify multiple directories", 10
    db "      --parallel=N             change the number of sorts run concurrently to N", 10
    db "  -u, --unique                 with -c, check for strict ordering;", 10
    db "                              without -c, output only the first of an equal run", 10
    db "  -z, --zero-terminated        line delimiter is NUL, not newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "KEYDEF is F[.C][OPTS][,F[.C][OPTS]] for start and stop position, where F is a", 10
    db "field number and C a character position (counted from 1 in the respective field);", 10
    db "both are origin 1.  If neither -t nor -b is in effect, characters in a field are", 10
    db "counted from the beginning of the preceding whitespace.  OPTS is one or more", 10
    db "single-letter ordering options [bdfgiMhnRrV], which override global ordering", 10
    db "options for that key.  If no key is given, use the entire line as the key.", 10
    db "Use --debug to diagnose incorrect key usage.", 10, 10
    db "SIZE may be followed by the following multiplicative suffixes:", 10
    db "% 1% of memory, b 1, K 1024 (default), and so on for M, G, T, P, E, Z, Y, R, Q.", 10, 10
    db "*** WARNING ***", 10
    db "The locale specified by the environment affects sort order.", 10
    db "Set LC_ALL=C to get the traditional sort order that uses", 10
    db "native byte values.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/sort>", 10
    db "or available locally via: info '(coreutils) sort invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "sort (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Mike Haertel and Paul Eggert.", 10
str_version_len equ $ - str_version
; @@DATA_END@@

str_sort_prefix: db "sort: ", 0
str_sort_prefix_len equ 6
str_dash: db "-", 0
str_colon: db ":", 0
str_newline: db 10, 0
str_disorder_sep: db ": disorder: "
str_disorder_sep_len equ $ - str_disorder_sep

opt_help: db "--help", 0
opt_version: db "--version", 0
opt_reverse: db "--reverse", 0
opt_unique: db "--unique", 0
opt_numeric: db "--numeric-sort", 0
opt_stable: db "--stable", 0
opt_check: db "--check", 0
opt_check_eq: db "--check=", 0
opt_check_quiet: db "quiet", 0
opt_check_silent: db "silent", 0
opt_ignore_case: db "--ignore-case", 0
opt_dictionary: db "--dictionary-order", 0
opt_ignore_np: db "--ignore-nonprinting", 0
opt_ignore_blanks: db "--ignore-leading-blanks", 0
opt_merge: db "--merge", 0
opt_zero_terminated: db "--zero-terminated", 0
opt_output: db "--output", 0
opt_output_eq: db "--output=", 0
opt_key: db "--key", 0
opt_key_eq: db "--key=", 0
opt_field_sep: db "--field-separator", 0
opt_field_sep_eq: db "--field-separator=", 0
opt_gen_numeric: db "--general-numeric-sort", 0
opt_month_sort: db "--month-sort", 0
opt_human_sort: db "--human-numeric-sort", 0
opt_version_sort: db "--version-sort", 0

month_names:
    db "JAN", 0
    db "FEB", 0
    db "MAR", 0
    db "APR", 0
    db "MAY", 0
    db "JUN", 0
    db "JUL", 0
    db "AUG", 0
    db "SEP", 0
    db "OCT", 0
    db "NOV", 0
    db "DEC", 0

file_end:

; ============================================================================
;                           BSS — computed addresses
; ============================================================================
bss_start equ (file_end - ehdr + 0x400000 + 0xFFF) & ~0xFFF

argc          equ bss_start + 0
argv          equ bss_start + 8
flag_bits     equ bss_start + 16
nfiles        equ bss_start + 24
files         equ bss_start + 32
output_file   equ bss_start + 32 + MAX_FILES * 8
output_fd     equ output_file + 8
separator     equ output_fd + 8
has_separator equ separator + 2
line_delim    equ has_separator + 1
nkeys         equ line_delim + 8         ; align
keys          equ nkeys + 8
input_buf     equ keys + MAX_KEYS * KEY_STRUCT_SIZE
input_size    equ input_buf + 8
input_cap     equ input_size + 8
line_array    equ input_cap + 8
line_count    equ line_array + 8
line_cap      equ line_count + 8
outbuf        equ line_cap + 8
outbuf_pos    equ outbuf + OUTBUF_SIZE
merge_temp    equ outbuf_pos + 8
fast_cmp_mode equ merge_temp + 8
stat_buf      equ fast_cmp_mode + 8
errbuf        equ stat_buf + STAT_STRUCT_SIZE

bss_size equ errbuf + 512 - bss_start
