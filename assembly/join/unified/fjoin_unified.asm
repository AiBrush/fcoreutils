; fjoin_unified.asm
; Auto-merged from modular source — DO NOT EDIT
; Edit the modular files in tools/ and lib/ instead
; Source files: tools/fjoin.asm, lib/io.asm
;
; Build: nasm -f bin unified/fjoin_unified.asm -o fjoin_release && chmod +x fjoin_release
;
; GNU-compatible "join" in x86_64 Linux assembly.
; Sorted file merge with field extraction.
; mmap + SIMD comparison + 1MB output buffer.

BITS 64
org 0x400000

; ─── System Constants ────────────────────────────────────
%define SYS_READ         0
%define SYS_WRITE        1
%define SYS_OPEN         2
%define SYS_CLOSE        3
%define SYS_STAT         4
%define SYS_FSTAT        5
%define SYS_LSEEK        8
%define SYS_MMAP         9
%define SYS_MUNMAP      11
%define SYS_BRK         12
%define SYS_RT_SIGACTION 13
%define SYS_RT_SIGPROCMASK 14
%define SYS_IOCTL       16
%define SYS_ACCESS      21
%define SYS_PIPE        22
%define SYS_DUP2        33
%define SYS_NANOSLEEP   35
%define SYS_GETPID      39
%define SYS_FORK        57
%define SYS_EXECVE      59
%define SYS_EXIT        60
%define SYS_UNAME       63
%define SYS_GETCWD      79
%define SYS_GETUID     102
%define SYS_GETGID     104
%define SYS_GETEUID    107
%define SYS_GETEGID    108
%define SYS_SYNC       162
%define STDIN            0
%define STDOUT           1
%define STDERR           2
%define O_RDONLY         0
%define O_WRONLY         1
%define O_CREAT        64
%define O_TRUNC       512
%define EINTR            4
%define EPIPE           32
%define SIGPIPE         13
%define BUF_SIZE     65536

%define OUT_BUF_SIZE    1048576
%define FLUSH_THRESHOLD 786432
%define STDIN_BUF_SIZE  16777216
%define MAX_EMPTY_LEN   256
%define MAX_FMT_SPECS   64
%define MAX_LINE_PTRS   4194304

%define PROT_READ       1
%define MAP_PRIVATE     2
%define MAP_POPULATE    0x08000
%define MADV_SEQUENTIAL 2
%define SYS_MADVISE     28

%define ORDER_DEFAULT   0
%define ORDER_STRICT    1
%define ORDER_NONE      2

%define SPEC_JOIN_FIELD 0
%define SPEC_FILE_FIELD 1

; ─── ELF Header ──────────────────────────────────────────
ehdr:
    db 0x7F, "ELF"
    db 2, 1, 1, 0
    dq 0
    dw 2
    dw 0x3E
    dd 1
    dq _start
    dq phdr - ehdr
    dq 0
    dd 0
    dw ehdr_size
    dw phdr_size
    dw 3
    dw 0, 0, 0
ehdr_size equ $ - ehdr

; ─── Program Headers ─────────────────────────────────────
phdr:
    dd 1                    ; PT_LOAD
    dd 5                    ; PF_R | PF_X
    dq 0
    dq 0x400000
    dq 0x400000
    dq file_end - ehdr
    dq file_end - ehdr
    dq 0x1000
phdr_size equ $ - phdr

    ; PT_LOAD for BSS (read+write)
    dd 1                    ; PT_LOAD
    dd 6                    ; PF_R | PF_W
    dq bss_file_offset
    dq bss_start
    dq bss_start
    dq 0
    dq bss_end - bss_start
    dq 0x1000

    ; PT_GNU_STACK (NX)
    dd 0x6474E551           ; PT_GNU_STACK
    dd 6                    ; PF_R | PF_W (no exec)
    dq 0, 0, 0, 0, 0
    dq 0x10

; ─── Inlined I/O Library ─────────────────────────────────




; asm_write(rdi=fd, rsi=buf, rdx=len) -> rax=bytes_written
; Handles EINTR automatically
asm_write:
.retry:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4             ; EINTR
    je      .retry
    ret

; asm_write_all(rdi=fd, rsi=buf, rdx=len) -> rax=0 on success, -1 on error
; Handles partial writes + EINTR
asm_write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi            ; fd
    mov     r12, rsi            ; buf pointer
    mov     r13, rdx            ; remaining bytes
.loop:
    test    r13, r13
    jle     .success
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4             ; EINTR
    je      .loop
    test    rax, rax
    js      .error              ; negative = error
    add     r12, rax
    sub     r13, rax
    jmp     .loop
.success:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.error:
    mov     rax, -1
    pop     r13
    pop     r12
    pop     rbx
    ret

; asm_read(rdi=fd, rsi=buf, rdx=len) -> rax=bytes_read
; Handles EINTR automatically
asm_read:
.retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, -4             ; EINTR
    je      .retry
    ret

; asm_open(rdi=path, rsi=flags, rdx=mode) -> rax=fd
asm_open:
    mov     rax, SYS_OPEN
    syscall
    ret

; asm_close(rdi=fd) -> rax=0 or error
asm_close:
    mov     rax, SYS_CLOSE
    syscall
    ret

; asm_exit(rdi=code)
asm_exit:
    mov     rax, SYS_EXIT
    syscall


; ─── Code ───────────────────────────────────────────────


; ═══════════════════════════════════════════════════════════
;                       ENTRY POINT
; ═══════════════════════════════════════════════════════════

_start:
    ; Block SIGPIPE (SIG_IGN)
    mov     rax, SYS_RT_SIGACTION
    mov     rdi, SIGPIPE
    lea     rsi, [rel sigact_buf]
    xor     rdx, rdx
    mov     r10, 8
    syscall

    ; argc / argv
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Initialize options to defaults
    mov     qword [rel opt_field1], 0       ; 0-indexed
    mov     qword [rel opt_field2], 0
    mov     byte [rel opt_sep_set], 0
    mov     byte [rel opt_sep_char], 0
    mov     byte [rel opt_ignore_case], 0
    mov     byte [rel opt_zero_term], 0
    mov     byte [rel opt_header], 0
    mov     byte [rel opt_order_check], ORDER_DEFAULT
    mov     byte [rel opt_print_unpaired1], 0
    mov     byte [rel opt_print_unpaired2], 0
    mov     byte [rel opt_only_unpaired1], 0
    mov     byte [rel opt_only_unpaired2], 0
    mov     qword [rel opt_empty_len], 0
    mov     qword [rel opt_fmt_count], 0
    mov     byte [rel opt_auto_format], 0
    mov     qword [rel file1_path], 0
    mov     qword [rel file2_path], 0
    mov     byte [rel seen_dashdash], 0

    ; Parse arguments
    mov     rbx, 1              ; start at argv[1]

.parse_loop:
    cmp     rbx, r14
    jge     .parse_done
    mov     rsi, [r15 + rbx*8]

    ; If we've seen --, everything is an operand
    cmp     byte [rel seen_dashdash], 0
    jne     .is_operand

    ; Check if starts with -
    cmp     byte [rsi], '-'
    jne     .is_operand
    cmp     byte [rsi+1], 0
    je      .is_operand         ; lone "-" is an operand (stdin)

    ; Check for --
    cmp     byte [rsi+1], '-'
    je      .long_option

    ; Short option
    jmp     .parse_short

; ─── Short option parsing ────────────────────────────────

.parse_short:
    mov     rsi, [r15 + rbx*8]
    movzx   eax, byte [rsi+1]

    cmp     al, 'a'
    je      .short_a
    cmp     al, 'v'
    je      .short_v
    cmp     al, 'e'
    je      .short_e
    cmp     al, 'i'
    je      .short_i
    cmp     al, 'j'
    je      .short_j
    cmp     al, 'o'
    je      .short_o
    cmp     al, 't'
    je      .short_t
    cmp     al, 'z'
    je      .short_z
    cmp     al, '1'
    je      .short_1
    cmp     al, '2'
    je      .short_2

    ; Unknown short option
    push    rbx
    mov     rsi, [r15 + rbx*8]
    call    err_invalid_option
    pop     rbx
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

; -a FILENUM
.short_a:
    mov     rsi, [r15 + rbx*8]
    cmp     byte [rsi+2], 0
    jne     .short_a_attached
    ; Next argument
    inc     rbx
    cmp     rbx, r14
    jge     .err_opt_requires_arg_a
    mov     rsi, [r15 + rbx*8]
    jmp     .parse_a_value
.short_a_attached:
    lea     rsi, [rsi+2]
.parse_a_value:
    cmp     byte [rsi], '1'
    jne     .check_a_2
    cmp     byte [rsi+1], 0
    jne     .err_invalid_filenum
    mov     byte [rel opt_print_unpaired1], 1
    jmp     .parse_next
.check_a_2:
    cmp     byte [rsi], '2'
    jne     .err_invalid_filenum
    cmp     byte [rsi+1], 0
    jne     .err_invalid_filenum
    mov     byte [rel opt_print_unpaired2], 1
    jmp     .parse_next

; -v FILENUM
.short_v:
    mov     rsi, [r15 + rbx*8]
    cmp     byte [rsi+2], 0
    jne     .short_v_attached
    inc     rbx
    cmp     rbx, r14
    jge     .err_opt_requires_arg_v
    mov     rsi, [r15 + rbx*8]
    jmp     .parse_v_value
.short_v_attached:
    lea     rsi, [rsi+2]
.parse_v_value:
    cmp     byte [rsi], '1'
    jne     .check_v_2
    cmp     byte [rsi+1], 0
    jne     .err_invalid_filenum
    mov     byte [rel opt_only_unpaired1], 1
    jmp     .parse_next
.check_v_2:
    cmp     byte [rsi], '2'
    jne     .err_invalid_filenum
    cmp     byte [rsi+1], 0
    jne     .err_invalid_filenum
    mov     byte [rel opt_only_unpaired2], 1
    jmp     .parse_next

; -e STRING
.short_e:
    mov     rsi, [r15 + rbx*8]
    cmp     byte [rsi+2], 0
    jne     .short_e_attached
    inc     rbx
    cmp     rbx, r14
    jge     .err_opt_requires_arg_e
    mov     rsi, [r15 + rbx*8]
    jmp     .copy_empty_string
.short_e_attached:
    lea     rsi, [rsi+2]
.copy_empty_string:
    ; Copy string to opt_empty_buf
    mov     rdi, rsi
    call    strlen
    cmp     rax, MAX_EMPTY_LEN
    jbe     .empty_len_ok
    mov     rax, MAX_EMPTY_LEN
.empty_len_ok:
    mov     [rel opt_empty_len], rax
    mov     rcx, rax
    lea     rdi, [rel opt_empty_buf]
    rep movsb
    jmp     .parse_next

; -i
.short_i:
    mov     byte [rel opt_ignore_case], 1
    jmp     .parse_next

; -j FIELD
.short_j:
    mov     rsi, [r15 + rbx*8]
    cmp     byte [rsi+2], 0
    jne     .short_j_attached
    inc     rbx
    cmp     rbx, r14
    jge     .err_opt_requires_arg_j
    mov     rsi, [r15 + rbx*8]
    jmp     .parse_j_value
.short_j_attached:
    lea     rsi, [rsi+2]
.parse_j_value:
    mov     r12, rsi            ; parse_uint reads from r12
    call    parse_uint
    test    rax, rax
    jz      .err_invalid_field_j
    dec     rax                 ; Convert to 0-indexed
    mov     [rel opt_field1], rax
    mov     [rel opt_field2], rax
    jmp     .parse_next

; -o FORMAT
.short_o:
    mov     rsi, [r15 + rbx*8]
    cmp     byte [rsi+2], 0
    jne     .short_o_attached
    inc     rbx
    cmp     rbx, r14
    jge     .err_opt_requires_arg_o
    mov     rsi, [r15 + rbx*8]
    jmp     .parse_o_value
.short_o_attached:
    lea     rsi, [rsi+2]
.parse_o_value:
    ; Check for "auto"
    cmp     byte [rsi], 'a'
    jne     .parse_o_specs
    cmp     byte [rsi+1], 'u'
    jne     .parse_o_specs
    cmp     byte [rsi+2], 't'
    jne     .parse_o_specs
    cmp     byte [rsi+3], 'o'
    jne     .parse_o_specs
    cmp     byte [rsi+4], 0
    jne     .parse_o_specs
    mov     byte [rel opt_auto_format], 1
    jmp     .parse_next
.parse_o_specs:
    call    parse_format_string
    jmp     .parse_next

; -t CHAR
.short_t:
    mov     rsi, [r15 + rbx*8]
    cmp     byte [rsi+2], 0
    jne     .short_t_attached
    inc     rbx
    cmp     rbx, r14
    jge     .err_opt_requires_arg_t
    mov     rsi, [r15 + rbx*8]
    cmp     byte [rsi], 0
    je      .err_empty_separator
    movzx   eax, byte [rsi]
    mov     byte [rel opt_sep_char], al
    mov     byte [rel opt_sep_set], 1
    jmp     .parse_next
.short_t_attached:
    movzx   eax, byte [rsi+2]
    mov     byte [rel opt_sep_char], al
    mov     byte [rel opt_sep_set], 1
    jmp     .parse_next

; -z
.short_z:
    mov     byte [rel opt_zero_term], 1
    jmp     .parse_next

; -1 FIELD
.short_1:
    mov     rsi, [r15 + rbx*8]
    cmp     byte [rsi+2], 0
    jne     .short_1_attached
    inc     rbx
    cmp     rbx, r14
    jge     .err_opt_requires_arg_1
    mov     rsi, [r15 + rbx*8]
    jmp     .parse_1_value
.short_1_attached:
    lea     rsi, [rsi+2]
.parse_1_value:
    mov     r12, rsi
    call    parse_uint
    test    rax, rax
    jz      .err_invalid_field_1
    dec     rax
    mov     [rel opt_field1], rax
    jmp     .parse_next

; -2 FIELD
.short_2:
    mov     rsi, [r15 + rbx*8]
    cmp     byte [rsi+2], 0
    jne     .short_2_attached
    inc     rbx
    cmp     rbx, r14
    jge     .err_opt_requires_arg_2
    mov     rsi, [r15 + rbx*8]
    jmp     .parse_2_value
.short_2_attached:
    lea     rsi, [rsi+2]
.parse_2_value:
    mov     r12, rsi
    call    parse_uint
    test    rax, rax
    jz      .err_invalid_field_2
    dec     rax
    mov     [rel opt_field2], rax
    jmp     .parse_next

; ─── Long option parsing ─────────────────────────────────

.long_option:
    cmp     byte [rsi+2], 0
    je      .set_dashdash

    push    rbx
    lea     rdi, [rel str_help_opt]
    call    strcmp
    test    eax, eax
    jz      .do_help

    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_version_opt]
    call    strcmp
    test    eax, eax
    jz      .do_version

    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_check_order_opt]
    call    strcmp
    test    eax, eax
    jz      .long_check_order

    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_nocheck_order_opt]
    call    strcmp
    test    eax, eax
    jz      .long_nocheck_order

    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_header_opt]
    call    strcmp
    test    eax, eax
    jz      .long_header

    mov     rsi, [r15 + rbx*8]
    lea     rdi, [rel str_ignore_case_opt]
    call    strcmp
    test    eax, eax
    jz      .long_ignore_case

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
    mov     edi, 1
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

.long_header:
    pop     rbx
    mov     byte [rel opt_header], 1
    jmp     .parse_next

.long_ignore_case:
    pop     rbx
    mov     byte [rel opt_ignore_case], 1
    jmp     .parse_next

.long_zeroterm:
    pop     rbx
    mov     byte [rel opt_zero_term], 1
    jmp     .parse_next

.set_dashdash:
    mov     byte [rel seen_dashdash], 1
    jmp     .parse_next

; ─── Operand handling ────────────────────────────────────

.is_operand:
    cmp     qword [rel file1_path], 0
    je      .set_file1
    cmp     qword [rel file2_path], 0
    je      .set_file2
    ; Extra operand error
    push    rbx
    lea     rdi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    write_stderr
    lea     rdi, [rel str_extra_operand]
    mov     rdx, str_extra_operand_len
    call    write_stderr
    lea     rdi, [rel str_quote_open]
    mov     rdx, str_quote_open_len
    call    write_stderr
    mov     rsi, [r15 + rbx*8]
    mov     rdi, rsi
    call    strlen
    mov     rdx, rax
    mov     rdi, rsi
    call    write_stderr
    lea     rdi, [rel str_quote_nl]
    mov     rdx, str_quote_nl_len
    call    write_stderr
    lea     rdi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    write_stderr
    pop     rbx
    mov     edi, 1
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

; ─── Validation ──────────────────────────────────────────

.parse_done:
    cmp     qword [rel file1_path], 0
    je      .err_missing_operand
    cmp     qword [rel file2_path], 0
    je      .err_missing_operand_after

    ; Set line delimiter
    cmp     byte [rel opt_zero_term], 0
    jne     .use_nul_delim
    mov     byte [rel line_delim], 10
    jmp     .delim_done
.use_nul_delim:
    mov     byte [rel line_delim], 0
.delim_done:

    ; Set output separator
    cmp     byte [rel opt_sep_set], 0
    je      .use_space_sep
    movzx   eax, byte [rel opt_sep_char]
    mov     byte [rel out_sep], al
    jmp     .sep_done
.use_space_sep:
    mov     byte [rel out_sep], ' '
.sep_done:

    ; Compute print_paired flag
    ; print_paired = !only_unpaired1 && !only_unpaired2
    mov     byte [rel print_paired], 1
    cmp     byte [rel opt_only_unpaired1], 0
    jne     .not_paired
    cmp     byte [rel opt_only_unpaired2], 0
    je      .paired_done
.not_paired:
    mov     byte [rel print_paired], 0
.paired_done:

    ; show_unpaired1 = print_unpaired1 || only_unpaired1
    mov     byte [rel show_unpaired1], 0
    cmp     byte [rel opt_print_unpaired1], 0
    jne     .su1_set
    cmp     byte [rel opt_only_unpaired1], 0
    je      .su1_done
.su1_set:
    mov     byte [rel show_unpaired1], 1
.su1_done:

    ; show_unpaired2 = print_unpaired2 || only_unpaired2
    mov     byte [rel show_unpaired2], 0
    cmp     byte [rel opt_print_unpaired2], 0
    jne     .su2_set
    cmp     byte [rel opt_only_unpaired2], 0
    je      .su2_done
.su2_set:
    mov     byte [rel show_unpaired2], 1
.su2_done:

    ; ─── Open and mmap files ─────────────────────────────
    mov     rdi, [rel file1_path]
    call    open_and_mmap_file
    test    rax, rax
    js      .err_open_file1
    mov     [rel file1_addr], rax
    mov     [rel file1_len], rdx

    mov     rdi, [rel file2_path]
    call    open_and_mmap_file
    test    rax, rax
    js      .err_open_file2
    mov     [rel file2_addr], rax
    mov     [rel file2_len], rdx

    ; ─── Split files into lines ──────────────────────────
    mov     rdi, [rel file1_addr]
    mov     rsi, [rel file1_len]
    movzx   edx, byte [rel line_delim]
    lea     rcx, [rel lines1_ptrs]
    lea     r8, [rel lines1_lens]
    call    split_into_lines
    mov     [rel lines1_count], rax

    mov     rdi, [rel file2_addr]
    mov     rsi, [rel file2_len]
    movzx   edx, byte [rel line_delim]
    lea     rcx, [rel lines2_ptrs]
    lea     r8, [rel lines2_lens]
    call    split_into_lines
    mov     [rel lines2_count], rax

    ; ─── Pre-compute all join keys ──────────────────────
    call    precompute_keys

    ; ─── Build auto format specs if needed ───────────────
    cmp     byte [rel opt_auto_format], 0
    je      .no_auto_format

    ; Count fields in first line of each file
    mov     rax, [rel lines1_count]
    test    rax, rax
    jz      .auto_f1_one
    mov     rdi, [rel lines1_ptrs]      ; ptr to first line
    mov     rsi, [rel lines1_lens]      ; len of first line
    call    count_fields
    jmp     .auto_f1_done
.auto_f1_one:
    mov     rax, 1
.auto_f1_done:
    mov     [rel auto_fc1], rax

    mov     rax, [rel lines2_count]
    test    rax, rax
    jz      .auto_f2_one
    mov     rdi, [rel lines2_ptrs]
    mov     rsi, [rel lines2_lens]
    call    count_fields
    jmp     .auto_f2_done
.auto_f2_one:
    mov     rax, 1
.auto_f2_done:
    mov     [rel auto_fc2], rax

    ; Build specs: 0 (join field), then 1.N for non-join fields from f1,
    ; then 2.N for non-join fields from f2
    xor     ecx, ecx            ; spec index
    lea     r8, [rel fmt_spec_types]
    lea     r9, [rel fmt_spec_file]
    lea     r10, [rel fmt_spec_field]

    ; First: join field (type=0)
    mov     byte [r8 + rcx], SPEC_JOIN_FIELD
    inc     ecx

    ; File 1 fields (skip join field)
    xor     edx, edx            ; field index
.auto_f1_loop:
    cmp     rdx, [rel auto_fc1]
    jge     .auto_f2_start
    cmp     rdx, [rel opt_field1]
    je      .auto_f1_skip
    cmp     ecx, MAX_FMT_SPECS
    jge     .auto_f2_start
    mov     byte [r8 + rcx], SPEC_FILE_FIELD
    mov     byte [r9 + rcx], 0  ; file 1 (0-indexed)
    mov     [r10 + rcx*8], rdx
    inc     ecx
.auto_f1_skip:
    inc     rdx
    jmp     .auto_f1_loop

.auto_f2_start:
    xor     edx, edx
.auto_f2_loop:
    cmp     rdx, [rel auto_fc2]
    jge     .auto_done
    cmp     rdx, [rel opt_field2]
    je      .auto_f2_skip
    cmp     ecx, MAX_FMT_SPECS
    jge     .auto_done
    mov     byte [r8 + rcx], SPEC_FILE_FIELD
    mov     byte [r9 + rcx], 1  ; file 2 (0-indexed)
    mov     [r10 + rcx*8], rdx
    inc     ecx
.auto_f2_skip:
    inc     rdx
    jmp     .auto_f2_loop

.auto_done:
    mov     [rel opt_fmt_count], rcx
.no_auto_format:

    ; ─── Initialize merge state ──────────────────────────
    mov     qword [rel out_buf_used], 0
    mov     byte [rel had_order_error], 0
    mov     byte [rel warned1], 0
    mov     byte [rel warned2], 0

    ; i1, i2 = starting indices
    xor     eax, eax
    mov     [rel idx1], rax
    mov     [rel idx2], rax

    ; Handle --header
    cmp     byte [rel opt_header], 0
    je      .merge_start

    ; Print header line (pair first lines without sort check)
    mov     rax, [rel lines1_count]
    test    rax, rax
    jz      .header_skip_f1
    mov     rax, [rel lines2_count]
    test    rax, rax
    jz      .header_skip_f2

    ; Both files have at least one line — emit header pair
    ; Set cur_key1 for emit_paired_line (pre-computed key for line 0)
    mov     rax, [rel keys1_ptrs]
    mov     [rel cur_key1_ptr], rax
    mov     rax, [rel keys1_lens]
    mov     [rel cur_key1_len], rax
    mov     rdi, [rel lines1_ptrs]      ; line1 ptr
    mov     rsi, [rel lines1_lens]      ; line1 len
    mov     rdx, [rel lines2_ptrs]      ; line2 ptr
    mov     rcx, [rel lines2_lens]      ; line2 len
    call    emit_paired_line

    mov     qword [rel idx1], 1
    mov     qword [rel idx2], 1
    jmp     .merge_start

.header_skip_f1:
    mov     rax, [rel lines1_count]
    test    rax, rax
    jz      .header_skip_f2
    mov     qword [rel idx1], 1
.header_skip_f2:
    mov     rax, [rel lines2_count]
    test    rax, rax
    jz      .merge_start
    mov     qword [rel idx2], 1

; ═══════════════════════════════════════════════════════════
;                       MERGE LOOP
; ═══════════════════════════════════════════════════════════

.merge_start:
.merge_loop:
    mov     rax, [rel idx1]
    cmp     rax, [rel lines1_count]
    jge     .drain_file2

    mov     rax, [rel idx2]
    cmp     rax, [rel lines2_count]
    jge     .drain_file1

    ; Lookup pre-computed keys (O(1) array access)
    mov     rax, [rel idx1]
    lea     rcx, [rel keys1_ptrs]
    mov     rdi, [rcx + rax*8]
    lea     rcx, [rel keys1_lens]
    mov     rsi, [rcx + rax*8]
    mov     [rel cur_key1_ptr], rdi
    mov     [rel cur_key1_len], rsi

    mov     rax, [rel idx2]
    lea     rcx, [rel keys2_ptrs]
    mov     rdx, [rcx + rax*8]
    lea     rcx, [rel keys2_lens]
    mov     rcx, [rcx + rax*8]
    mov     [rel cur_key2_ptr], rdx
    mov     [rel cur_key2_len], rcx

    ; Order checks
    call    check_order_both
    test    rax, rax
    jnz     .early_exit_order

    ; Inline fast compare keys (avoids function call overhead)
    mov     rdi, [rel cur_key1_ptr]
    mov     rsi, [rel cur_key1_len]
    mov     rdx, [rel cur_key2_ptr]
    mov     rcx, [rel cur_key2_len]
    call    compare_keys

    test    rax, rax
    js      .key1_less
    jz      .keys_equal
    jmp     .key1_greater

.key1_less:
    ; Unpairable from file 1
    cmp     byte [rel show_unpaired1], 0
    je      .skip_unpaired1
    mov     rax, [rel idx1]
    mov     rdi, 0              ; file_num = 0 (file 1)
    call    emit_unpaired_line
.skip_unpaired1:
    inc     qword [rel idx1]
    jmp     .merge_check_flush

.key1_greater:
    ; Unpairable from file 2
    cmp     byte [rel show_unpaired2], 0
    je      .skip_unpaired2
    mov     rax, [rel idx2]
    mov     rdi, 1              ; file_num = 1 (file 2)
    call    emit_unpaired_line
.skip_unpaired2:
    inc     qword [rel idx2]
    jmp     .merge_check_flush

.keys_equal:
    ; Find all consecutive file2 lines with same key
    mov     rax, [rel idx2]
    mov     [rel group2_start], rax

    ; Save current key
    mov     rax, [rel cur_key2_ptr]
    mov     [rel group_key_ptr], rax
    mov     rax, [rel cur_key2_len]
    mov     [rel group_key_len], rax

    inc     qword [rel idx2]

.find_group2_end:
    mov     rax, [rel idx2]
    cmp     rax, [rel lines2_count]
    jge     .group2_found

    ; Direct key lookup (no function call)
    lea     rcx, [rel keys2_ptrs]
    mov     rdx, [rcx + rax*8]
    lea     rcx, [rel keys2_lens]
    mov     rcx, [rcx + rax*8]
    ; compare_keys(group_key, next_key)
    mov     rdi, [rel group_key_ptr]
    mov     rsi, [rel group_key_len]
    ; rdx = next key ptr, rcx = next key len (already set)
    call    compare_keys
    test    rax, rax
    jnz     .group2_found
    inc     qword [rel idx2]
    jmp     .find_group2_end

.group2_found:
    ; Cross-product: for each file1 line with same key × file2 group

.cross_product_loop:
    ; Set cur_key1 from the current file1 line's pre-computed key
    ; (Must use file1 key, not group_key, for correct -i output)
    mov     rax, [rel idx1]
    lea     rcx, [rel keys1_ptrs]
    mov     rdx, [rcx + rax*8]
    mov     [rel cur_key1_ptr], rdx
    lea     rcx, [rel keys1_lens]
    mov     rdx, [rcx + rax*8]
    mov     [rel cur_key1_len], rdx

    cmp     byte [rel print_paired], 0
    je      .cross_skip_paired

    ; Emit paired lines for current i1 × file2 group
    mov     rax, [rel group2_start]
    mov     [rel cross_j], rax

.cross_inner:
    mov     rax, [rel cross_j]
    cmp     rax, [rel idx2]
    jge     .cross_inner_done

    ; Get line1[idx1] and line2[cross_j]
    mov     rax, [rel idx1]
    shl     rax, 3
    lea     rdi, [rel lines1_ptrs]
    mov     rdi, [rdi + rax]
    lea     rsi, [rel lines1_lens]
    mov     rax, [rel idx1]
    mov     rsi, [rsi + rax*8]

    mov     rax, [rel cross_j]
    shl     rax, 3
    lea     rdx, [rel lines2_ptrs]
    mov     rdx, [rdx + rax]
    lea     rcx, [rel lines2_lens]
    mov     rax, [rel cross_j]
    mov     rcx, [rcx + rax*8]

    call    emit_paired_line

    ; Flush check inside inner loop
    mov     rax, [rel out_buf_used]
    cmp     rax, FLUSH_THRESHOLD
    jb      .cross_no_flush
    call    flush_outbuf
.cross_no_flush:

    inc     qword [rel cross_j]
    jmp     .cross_inner

.cross_inner_done:
.cross_skip_paired:

    ; Advance file1, check if next line has same key
    inc     qword [rel idx1]
    mov     rax, [rel idx1]
    cmp     rax, [rel lines1_count]
    jge     .cross_product_done

    ; Get next key from file1 (direct lookup)
    lea     rcx, [rel keys1_ptrs]
    mov     rdx, [rcx + rax*8]
    lea     rcx, [rel keys1_lens]
    mov     rcx, [rcx + rax*8]

    ; compare_keys(group_key, next_key)
    mov     rdi, [rel group_key_ptr]
    mov     rsi, [rel group_key_len]
    ; rdx = next key ptr, rcx = next key len
    call    compare_keys
    test    rax, rax
    jz      .cross_product_loop

    ; Key differs — check order
    ; compare_keys(group_key, next_key) was called
    ; If result > 0: group_key > next_key => next_key < group_key => out of order
    ; If result < 0: group_key < next_key => correct order
    cmp     byte [rel opt_order_check], ORDER_NONE
    je      .cross_product_done
    cmp     byte [rel warned1], 0
    jne     .cross_product_done
    ; rax = compare_keys(group, next): positive means group > next = out of order
    cmp     rax, 0
    jle     .cross_product_done
    ; Out of order!
    mov     byte [rel had_order_error], 1
    mov     byte [rel warned1], 1
    ; Print error
    mov     rax, [rel idx1]
    call    print_sort_error_f1
    cmp     byte [rel opt_order_check], ORDER_STRICT
    je      .early_exit_order

.cross_product_done:
    jmp     .merge_check_flush

.merge_check_flush:
    mov     rax, [rel out_buf_used]
    cmp     rax, FLUSH_THRESHOLD
    jb      .merge_loop
    call    flush_outbuf
    jmp     .merge_loop

; ─── Drain remaining file 1 ─────────────────────────────

.drain_file1:
    mov     rax, [rel idx1]
    cmp     rax, [rel lines1_count]
    jge     .after_drain

    ; Order check
    cmp     byte [rel opt_order_check], ORDER_NONE
    je      .drain1_no_order
    cmp     byte [rel warned1], 0
    jne     .drain1_no_order
    call    check_order_f1_drain
    test    rax, rax
    jnz     .early_exit_order
.drain1_no_order:

    cmp     byte [rel show_unpaired1], 0
    je      .drain1_skip_output
    mov     rax, [rel idx1]
    mov     rdi, 0
    call    emit_unpaired_line
.drain1_skip_output:
    inc     qword [rel idx1]

    mov     rax, [rel out_buf_used]
    cmp     rax, FLUSH_THRESHOLD
    jb      .drain_file1
    call    flush_outbuf
    jmp     .drain_file1

; ─── Drain remaining file 2 ─────────────────────────────

.drain_file2:
    mov     rax, [rel idx2]
    cmp     rax, [rel lines2_count]
    jge     .after_drain

    ; Order check
    cmp     byte [rel opt_order_check], ORDER_NONE
    je      .drain2_no_order
    cmp     byte [rel warned2], 0
    jne     .drain2_no_order
    call    check_order_f2_drain
    test    rax, rax
    jnz     .early_exit_order
.drain2_no_order:

    cmp     byte [rel show_unpaired2], 0
    je      .drain2_skip_output
    mov     rax, [rel idx2]
    mov     rdi, 1
    call    emit_unpaired_line
.drain2_skip_output:
    inc     qword [rel idx2]

    mov     rax, [rel out_buf_used]
    cmp     rax, FLUSH_THRESHOLD
    jb      .drain_file2
    call    flush_outbuf
    jmp     .drain_file2

; ─── Final flush and exit ────────────────────────────────

.after_drain:
    call    flush_outbuf

    ; Check order summary for default mode
    cmp     byte [rel had_order_error], 0
    je      .no_order_summary
    cmp     byte [rel opt_order_check], ORDER_DEFAULT
    jne     .no_order_summary
    lea     rdi, [rel str_input_not_sorted]
    mov     rdx, str_input_not_sorted_len
    call    write_stderr
.no_order_summary:

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
    call    flush_outbuf
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

; ═══════════════════════════════════════════════════════════
;                    ERROR HANDLERS
; ═══════════════════════════════════════════════════════════

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
    mov     rdx, str_quote_open_len
    call    write_stderr
    mov     rdi, [rel file1_path]
    mov     rsi, rdi
    call    strlen
    mov     rdx, rax
    mov     rdi, rsi
    call    write_stderr
    lea     rdi, [rel str_quote_nl]
    mov     rdx, str_quote_nl_len
    call    write_stderr
    lea     rdi, [rel str_try_help]
    mov     rdx, str_try_help_len
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

.err_opt_requires_arg_a:
    lea     rdi, [rel str_opt_req_arg_a]
    mov     rdx, str_opt_req_arg_a_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_opt_requires_arg_v:
    lea     rdi, [rel str_opt_req_arg_v]
    mov     rdx, str_opt_req_arg_v_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_opt_requires_arg_e:
    lea     rdi, [rel str_opt_req_arg_e]
    mov     rdx, str_opt_req_arg_e_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_opt_requires_arg_j:
    lea     rdi, [rel str_opt_req_arg_j]
    mov     rdx, str_opt_req_arg_j_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_opt_requires_arg_o:
    lea     rdi, [rel str_opt_req_arg_o]
    mov     rdx, str_opt_req_arg_o_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_opt_requires_arg_t:
    lea     rdi, [rel str_opt_req_arg_t]
    mov     rdx, str_opt_req_arg_t_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_opt_requires_arg_1:
    lea     rdi, [rel str_opt_req_arg_1]
    mov     rdx, str_opt_req_arg_1_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_opt_requires_arg_2:
    lea     rdi, [rel str_opt_req_arg_2]
    mov     rdx, str_opt_req_arg_2_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_invalid_filenum:
    push    rsi
    lea     rdi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    write_stderr
    lea     rdi, [rel str_invalid_filenum]
    mov     rdx, str_invalid_filenum_len
    call    write_stderr
    lea     rdi, [rel str_quote_open]
    mov     rdx, str_quote_open_len
    call    write_stderr
    pop     rsi
    mov     rdi, rsi
    call    strlen
    mov     rdx, rax
    mov     rdi, rsi
    call    write_stderr
    lea     rdi, [rel str_quote_nl]
    mov     rdx, str_quote_nl_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_invalid_field_j:
.err_invalid_field_1:
.err_invalid_field_2:
    lea     rdi, [rel str_invalid_field]
    mov     rdx, str_invalid_field_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.err_empty_separator:
    lea     rdi, [rel str_empty_sep]
    mov     rdx, str_empty_sep_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

; ═══════════════════════════════════════════════════════════
;                     SUBROUTINES
; ═══════════════════════════════════════════════════════════

; ─── precompute_keys: extract join keys for all lines into arrays ──
;     This avoids extract_field in the hot merge loop.
precompute_keys:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; Pre-compute keys for file 1
    mov     r14, [rel lines1_count]
    xor     r15d, r15d          ; index
.pk_f1_loop:
    cmp     r15, r14
    jge     .pk_f1_done
    lea     rax, [rel lines1_ptrs]
    mov     rdi, [rax + r15*8]
    lea     rax, [rel lines1_lens]
    mov     rsi, [rax + r15*8]
    mov     rdx, [rel opt_field1]
    call    extract_field
    lea     rcx, [rel keys1_ptrs]
    mov     [rcx + r15*8], rax
    lea     rcx, [rel keys1_lens]
    mov     [rcx + r15*8], rdx
    inc     r15
    jmp     .pk_f1_loop
.pk_f1_done:

    ; Pre-compute keys for file 2
    mov     r14, [rel lines2_count]
    xor     r15d, r15d
.pk_f2_loop:
    cmp     r15, r14
    jge     .pk_f2_done
    lea     rax, [rel lines2_ptrs]
    mov     rdi, [rax + r15*8]
    lea     rax, [rel lines2_lens]
    mov     rsi, [rax + r15*8]
    mov     rdx, [rel opt_field2]
    call    extract_field
    lea     rcx, [rel keys2_ptrs]
    mov     [rcx + r15*8], rax
    lea     rcx, [rel keys2_lens]
    mov     [rcx + r15*8], rdx
    inc     r15
    jmp     .pk_f2_loop
.pk_f2_done:

    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ─── get_key1(rax=line_index) -> rax=key_ptr, rdx=key_len ──
;     Now just looks up pre-computed key (O(1))
get_key1:
    lea     rdx, [rel keys1_lens]
    mov     rdx, [rdx + rax*8]
    lea     rcx, [rel keys1_ptrs]
    mov     rax, [rcx + rax*8]
    ret

; ─── get_key2(rax=line_index) -> rax=key_ptr, rdx=key_len ──
;     Now just looks up pre-computed key (O(1))
get_key2:
    lea     rdx, [rel keys2_lens]
    mov     rdx, [rdx + rax*8]
    lea     rcx, [rel keys2_ptrs]
    mov     rax, [rcx + rax*8]
    ret

; ─── extract_field(rdi=line_ptr, rsi=line_len, rdx=field_index) ──
;     -> rax=field_ptr, rdx=field_len
;     Optimized with fast paths for field 0 and SSE2 separator scanning
extract_field:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi            ; line ptr
    mov     r13, rsi            ; line len
    mov     r14, rdx            ; target field index
    cmp     byte [rel opt_sep_set], 0
    je      .ef_whitespace

    ; === Character-separated field extraction ===
    movzx   eax, byte [rel opt_sep_char]

    ; Fast path: field 0 with SSE2 separator scan
    test    r14, r14
    jnz     .ef_char_general

    ; Field 0: find first separator using SSE2
    mov     rbx, r12            ; scan ptr
    mov     r15, r12
    add     r15, r13            ; end ptr
    ; Broadcast separator to xmm0
    movd    xmm0, eax
    punpcklbw xmm0, xmm0
    punpcklwd xmm0, xmm0
    pshufd  xmm0, xmm0, 0
    mov     rcx, r13            ; remaining bytes
.ef_f0_sse:
    cmp     rcx, 16
    jb      .ef_f0_byte
    movdqu  xmm1, [rbx]
    pcmpeqb xmm1, xmm0
    pmovmskb edx, xmm1
    test    edx, edx
    jnz     .ef_f0_sse_found
    add     rbx, 16
    sub     rcx, 16
    jmp     .ef_f0_sse
.ef_f0_sse_found:
    bsf     edx, edx
    add     rbx, rdx
    ; Field 0 = r12 to rbx
    mov     rax, r12
    mov     rdx, rbx
    sub     rdx, r12
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.ef_f0_byte:
    test    rcx, rcx
    jz      .ef_f0_whole_line
    cmp     byte [rbx], al
    je      .ef_f0_byte_found
    inc     rbx
    dec     rcx
    jmp     .ef_f0_byte
.ef_f0_byte_found:
    mov     rax, r12
    mov     rdx, rbx
    sub     rdx, r12
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.ef_f0_whole_line:
    ; No separator found - whole line is field 0
    mov     rax, r12
    mov     rdx, r13
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

    ; General case: field N with character separator
.ef_char_general:
    xor     ecx, ecx            ; current field
    mov     rbx, r12            ; scan ptr
    mov     r15, r12
    add     r15, r13            ; end
    mov     rdi, r12            ; field start
.ef_cg_loop:
    cmp     rbx, r15
    jge     .ef_cg_end_field
    cmp     byte [rbx], al
    je      .ef_cg_sep
    inc     rbx
    jmp     .ef_cg_loop
.ef_cg_sep:
    cmp     rcx, r14
    je      .ef_cg_match
    inc     rcx
    inc     rbx
    mov     rdi, rbx            ; new field start
    jmp     .ef_cg_loop
.ef_cg_match:
    mov     rax, rdi
    mov     rdx, rbx
    sub     rdx, rdi
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.ef_cg_end_field:
    cmp     rcx, r14
    je      .ef_cg_end_match
    ; Field not found
    mov     rax, r12
    xor     edx, edx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.ef_cg_end_match:
    mov     rax, rdi
    mov     rdx, r15
    sub     rdx, rdi
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

    ; === Whitespace-separated field extraction ===
.ef_whitespace:
    xor     ecx, ecx            ; current field index
    xor     ebx, ebx            ; position in line
.ef_ws_skip:
    cmp     rbx, r13
    jge     .ef_ws_not_found
    movzx   eax, byte [r12 + rbx]
    cmp     al, ' '
    je      .ef_ws_skip_next
    cmp     al, 9               ; tab
    je      .ef_ws_skip_next
    jmp     .ef_ws_field_start
.ef_ws_skip_next:
    inc     rbx
    jmp     .ef_ws_skip
.ef_ws_field_start:
    mov     r15, rbx            ; field start offset
.ef_ws_scan:
    cmp     rbx, r13
    jge     .ef_ws_field_end
    movzx   eax, byte [r12 + rbx]
    cmp     al, ' '
    je      .ef_ws_field_end
    cmp     al, 9
    je      .ef_ws_field_end
    inc     rbx
    jmp     .ef_ws_scan
.ef_ws_field_end:
    cmp     rcx, r14
    je      .ef_ws_found
    inc     rcx
    jmp     .ef_ws_skip
.ef_ws_found:
    lea     rax, [r12 + r15]
    mov     rdx, rbx
    sub     rdx, r15
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.ef_ws_not_found:
    mov     rax, r12
    xor     edx, edx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ─── count_fields(rdi=line_ptr, rsi=line_len) -> rax=count ──
count_fields:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi

    cmp     byte [rel opt_sep_set], 0
    je      .cf_whitespace

    ; Char-separated: count = 1 + number of separators
    movzx   eax, byte [rel opt_sep_char]
    xor     ecx, ecx            ; sep count
    xor     edx, edx            ; position
.cf_char_loop:
    cmp     rdx, r13
    jge     .cf_char_done
    cmp     byte [r12 + rdx], al
    jne     .cf_char_next
    inc     ecx
.cf_char_next:
    inc     rdx
    jmp     .cf_char_loop
.cf_char_done:
    lea     rax, [rcx + 1]
    pop     r13
    pop     r12
    pop     rbx
    ret

.cf_whitespace:
    xor     ecx, ecx            ; field count
    xor     edx, edx            ; position
.cf_ws_skip:
    cmp     rdx, r13
    jge     .cf_ws_done
    movzx   eax, byte [r12 + rdx]
    cmp     al, ' '
    je      .cf_ws_skip_next
    cmp     al, 9
    je      .cf_ws_skip_next
    jmp     .cf_ws_field
.cf_ws_skip_next:
    inc     rdx
    jmp     .cf_ws_skip
.cf_ws_field:
    inc     ecx
.cf_ws_scan:
    cmp     rdx, r13
    jge     .cf_ws_done
    movzx   eax, byte [r12 + rdx]
    cmp     al, ' '
    je      .cf_ws_skip2
    cmp     al, 9
    je      .cf_ws_skip2
    inc     rdx
    jmp     .cf_ws_scan
.cf_ws_skip2:
    inc     rdx
    jmp     .cf_ws_skip
.cf_ws_done:
    mov     rax, rcx
    pop     r13
    pop     r12
    pop     rbx
    ret

; ─── compare_keys(rdi=k1_ptr, rsi=k1_len, rdx=k2_ptr, rcx=k2_len) ──
;     -> rax: -1 if k1<k2, 0 if equal, 1 if k1>k2
;     Optimized: uses 8-byte comparison for short keys, SSE2 for longer
compare_keys:
    ; Fast path for case-sensitive (most common)
    cmp     byte [rel opt_ignore_case], 0
    jne     .ck_case_insensitive

    ; min length
    mov     rax, rsi
    cmp     rax, rcx
    jbe     .ck_min_set
    mov     rax, rcx
.ck_min_set:

    ; For keys <= 8 bytes, use single qword comparison
    cmp     rax, 8
    ja      .ck_long
    ; Quick: compare first min(len,8) bytes as qwords (with masking)
    test    rax, rax
    jz      .ck_compare_lengths

.ck_byte_loop:
    movzx   r8d, byte [rdi]
    movzx   r9d, byte [rdx]
    cmp     r8d, r9d
    jb      .ck_less
    ja      .ck_greater
    inc     rdi
    inc     rdx
    dec     rax
    jnz     .ck_byte_loop
    jmp     .ck_compare_lengths

.ck_long:
    ; SSE2 comparison for longer keys
    mov     r8, rax             ; min length
.ck_sse_loop:
    cmp     r8, 16
    jb      .ck_long_byte
    movdqu  xmm0, [rdi]
    movdqu  xmm1, [rdx]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0
    xor     eax, 0xFFFF
    test    eax, eax
    jnz     .ck_found_diff_sse
    add     rdi, 16
    add     rdx, 16
    sub     r8, 16
    jmp     .ck_sse_loop
.ck_found_diff_sse:
    bsf     eax, eax
    movzx   r8d, byte [rdi + rax]
    movzx   r9d, byte [rdx + rax]
    cmp     r8d, r9d
    jb      .ck_less
    jmp     .ck_greater
.ck_long_byte:
    test    r8, r8
    jz      .ck_compare_lengths
    movzx   eax, byte [rdi]
    movzx   r9d, byte [rdx]
    cmp     eax, r9d
    jb      .ck_less
    ja      .ck_greater
    inc     rdi
    inc     rdx
    dec     r8
    jmp     .ck_long_byte

.ck_compare_lengths:
    cmp     rsi, rcx
    jb      .ck_less
    ja      .ck_greater
    xor     eax, eax
    ret
.ck_less:
    mov     rax, -1
    ret
.ck_greater:
    mov     rax, 1
    ret

    ; Case-insensitive comparison (byte-by-byte with tolower)
.ck_case_insensitive:
    push    rbx
    push    r12
    push    r13
    ; min length
    mov     rbx, rsi
    cmp     rbx, rcx
    jbe     .ck_ci_min_set
    mov     rbx, rcx
.ck_ci_min_set:
    mov     r12, rsi            ; save k1_len
    mov     r13, rcx            ; save k2_len
.ck_ci_loop:
    test    rbx, rbx
    jz      .ck_ci_lengths
    movzx   eax, byte [rdi]
    movzx   r8d, byte [rdx]
    ; tolower both
    cmp     al, 'A'
    jb      .ck_ci_no_lower1
    cmp     al, 'Z'
    ja      .ck_ci_no_lower1
    or      al, 0x20
.ck_ci_no_lower1:
    cmp     r8b, 'A'
    jb      .ck_ci_no_lower2
    cmp     r8b, 'Z'
    ja      .ck_ci_no_lower2
    or      r8b, 0x20
.ck_ci_no_lower2:
    cmp     al, r8b
    jb      .ck_ci_less
    ja      .ck_ci_greater
    inc     rdi
    inc     rdx
    dec     rbx
    jmp     .ck_ci_loop

.ck_ci_lengths:
    cmp     r12, r13
    jb      .ck_ci_less
    ja      .ck_ci_greater
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.ck_ci_less:
    mov     rax, -1
    pop     r13
    pop     r12
    pop     rbx
    ret
.ck_ci_greater:
    mov     rax, 1
    pop     r13
    pop     r12
    pop     rbx
    ret

; ─── emit_paired_line(rdi=line1_ptr, rsi=line1_len, rdx=line2_ptr, rcx=line2_len) ──
;     Also uses: cur_key1_ptr/cur_key1_len for pre-computed key of file1 line
;     Optimized: builds output directly in buffer when possible
emit_paired_line:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32             ; local storage
    mov     [rsp], rdi          ; line1_ptr
    mov     [rsp+8], rsi        ; line1_len
    mov     [rsp+16], rdx       ; line2_ptr
    mov     [rsp+24], rcx       ; line2_len

    ; Check if using -o format
    cmp     qword [rel opt_fmt_count], 0
    jne     .epl_format

    ; Default format: join_key + other_fields_from_file1 + other_fields_from_file2
    ; Estimate output size: line1_len + line2_len + 4 (conservative)
    mov     rax, [rsp+8]
    add     rax, [rsp+24]
    add     rax, 4
    ; Ensure buffer has enough space
    mov     rcx, [rel out_buf_used]
    lea     rdx, [rcx + rax]
    cmp     rdx, OUT_BUF_SIZE
    jb      .epl_default_fast
    ; Flush first
    push    rax
    call    flush_outbuf
    pop     rax
    mov     rcx, [rel out_buf_used]

.epl_default_fast:
    ; rcx = current buf position. Build output directly in buffer.
    lea     rdi, [rel out_buf]
    add     rdi, rcx            ; rdi = write cursor
    mov     r12, rdi            ; save start for length calculation

    ; 1. Copy join key
    mov     rsi, [rel cur_key1_ptr]
    mov     rcx, [rel cur_key1_len]
    ; Inline copy
    mov     rax, rcx
    shr     rcx, 3
    jz      .epl_key_tail
    rep movsq
.epl_key_tail:
    mov     rcx, rax
    and     rcx, 7
    jz      .epl_key_done
    rep movsb
.epl_key_done:

    ; 2. Write other fields from file1 (inline)
    mov     r13, [rsp]          ; line1_ptr
    mov     r14, [rsp+8]        ; line1_len
    mov     r15, [rel opt_field1] ; skip_field
    call    .inline_write_other_fields

    ; 3. Write other fields from file2 (inline)
    mov     r13, [rsp+16]       ; line2_ptr
    mov     r14, [rsp+24]       ; line2_len
    mov     r15, [rel opt_field2]
    call    .inline_write_other_fields

    ; 4. Append line delimiter
    movzx   eax, byte [rel line_delim]
    mov     [rdi], al
    inc     rdi

    ; Update out_buf_used
    mov     rax, rdi
    sub     rax, r12
    add     [rel out_buf_used], rax

    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; Inline helper: write out_sep + each field except r15 from line at r13 (len r14)
; rdi = write cursor (updated in place)
.inline_write_other_fields:
    cmp     byte [rel opt_sep_set], 0
    je      .iwof_whitespace

    ; Character-separated inline write
    ; Fast path: field 0 skip — just copy from first separator to end (includes seps)
    ; Since out_sep == sep_char in -t mode, the raw suffix is correct
    test    r15, r15
    jnz     .iwof_char_general

    ; Field 0 fast path: find first separator, copy sep+rest as single block
    movzx   eax, byte [rel opt_sep_char]
    mov     rsi, r13            ; scan ptr
    lea     r8, [r13 + r14]     ; end ptr
    ; Use SSE2 to find first separator
    movd    xmm0, eax
    punpcklbw xmm0, xmm0
    punpcklwd xmm0, xmm0
    pshufd  xmm0, xmm0, 0
    mov     rcx, r14            ; remaining
.iwof_f0_sse:
    cmp     rcx, 16
    jb      .iwof_f0_byte
    movdqu  xmm1, [rsi]
    pcmpeqb xmm1, xmm0
    pmovmskb edx, xmm1
    test    edx, edx
    jnz     .iwof_f0_sse_found
    add     rsi, 16
    sub     rcx, 16
    jmp     .iwof_f0_sse
.iwof_f0_sse_found:
    bsf     edx, edx
    add     rsi, rdx            ; rsi -> first separator
    jmp     .iwof_f0_copy_suffix
.iwof_f0_byte:
    test    rcx, rcx
    jz      .iwof_done          ; no separator, no other fields
    cmp     byte [rsi], al
    je      .iwof_f0_copy_suffix
    inc     rsi
    dec     rcx
    jmp     .iwof_f0_byte

.iwof_f0_copy_suffix:
    ; Replace first sep with out_sep and copy rest verbatim
    movzx   eax, byte [rel out_sep]
    mov     [rdi], al
    inc     rdi
    inc     rsi                 ; skip separator char
    ; Copy rsi to r8
    mov     rcx, r8
    sub     rcx, rsi
    jle     .iwof_done
    mov     rax, rcx
    shr     rcx, 3
    jz      .iwof_f0s_tail
    rep movsq
.iwof_f0s_tail:
    mov     rcx, rax
    and     rcx, 7
    jz      .iwof_done
    rep movsb
    jmp     .iwof_done

    ; General case: field N>0 with character separator
.iwof_char_general:
    movzx   eax, byte [rel opt_sep_char]
    movzx   ebx, byte [rel out_sep]
    xor     ecx, ecx            ; field index
    mov     rsi, r13            ; scan ptr
    lea     r8, [r13 + r14]     ; end ptr
    mov     r9, r13             ; field start

.iwof_char_scan:
    cmp     rsi, r8
    jge     .iwof_char_last
    cmp     byte [rsi], al
    je      .iwof_char_sep
    inc     rsi
    jmp     .iwof_char_scan

.iwof_char_sep:
    ; Field from r9 to rsi
    cmp     rcx, r15
    je      .iwof_char_skip
    ; Write out_sep + field
    mov     [rdi], bl
    inc     rdi
    ; Copy field bytes
    push    rsi
    push    rcx
    mov     rcx, rsi
    sub     rcx, r9
    mov     rsi, r9
    ; Inline copy
    push    rax
    mov     rax, rcx
    shr     rcx, 3
    jz      .iwof_cs_tail
    rep movsq
.iwof_cs_tail:
    mov     rcx, rax
    and     rcx, 7
    jz      .iwof_cs_done
    rep movsb
.iwof_cs_done:
    pop     rax
    pop     rcx
    pop     rsi
.iwof_char_skip:
    inc     rcx
    inc     rsi
    mov     r9, rsi             ; next field start
    jmp     .iwof_char_scan

.iwof_char_last:
    cmp     rcx, r15
    je      .iwof_done
    ; Write out_sep + last field (r9 to r8)
    mov     [rdi], bl
    inc     rdi
    mov     rcx, r8
    sub     rcx, r9
    mov     rsi, r9
    mov     rax, rcx
    shr     rcx, 3
    jz      .iwof_cl_tail
    rep movsq
.iwof_cl_tail:
    mov     rcx, rax
    and     rcx, 7
    jz      .iwof_done
    rep movsb
    jmp     .iwof_done

    ; Whitespace-separated inline write
.iwof_whitespace:
    movzx   ebx, byte [rel out_sep]

    ; Fast path: field 0 skip — jump directly past the first field
    test    r15, r15
    jnz     .iwof_ws_general

    ; Field 0 fast path: skip leading ws, skip non-ws (field 0),
    ; then output remaining fields
    xor     r8d, r8d
    ; Skip leading whitespace
.iwof_f0_ws_lead:
    cmp     r8, r14
    jge     .iwof_done
    movzx   eax, byte [r13 + r8]
    cmp     al, ' '
    je      .iwof_f0_ws_lead_n
    cmp     al, 9
    je      .iwof_f0_ws_lead_n
    jmp     .iwof_f0_ws_skip_key
.iwof_f0_ws_lead_n:
    inc     r8
    jmp     .iwof_f0_ws_lead
    ; Skip field 0 (non-whitespace)
.iwof_f0_ws_skip_key:
    cmp     r8, r14
    jge     .iwof_done
    movzx   eax, byte [r13 + r8]
    cmp     al, ' '
    je      .iwof_f0_ws_after_key
    cmp     al, 9
    je      .iwof_f0_ws_after_key
    inc     r8
    jmp     .iwof_f0_ws_skip_key
.iwof_f0_ws_after_key:
    ; r8 now points to whitespace after field 0
    ; Output remaining fields (start from r8)
    jmp     .iwof_f0_ws_skip_ws

.iwof_f0_ws_skip_ws:
    cmp     r8, r14
    jge     .iwof_done
    movzx   eax, byte [r13 + r8]
    cmp     al, ' '
    je      .iwof_f0_ws_skip_ws_n
    cmp     al, 9
    je      .iwof_f0_ws_skip_ws_n
    jmp     .iwof_f0_ws_emit_field
.iwof_f0_ws_skip_ws_n:
    inc     r8
    jmp     .iwof_f0_ws_skip_ws

.iwof_f0_ws_emit_field:
    ; Write out_sep
    mov     [rdi], bl
    inc     rdi
    ; Find end of field and copy
    mov     r9, r8
.iwof_f0_ws_scan_field:
    cmp     r8, r14
    jge     .iwof_f0_ws_copy_field
    movzx   eax, byte [r13 + r8]
    cmp     al, ' '
    je      .iwof_f0_ws_copy_field
    cmp     al, 9
    je      .iwof_f0_ws_copy_field
    inc     r8
    jmp     .iwof_f0_ws_scan_field
.iwof_f0_ws_copy_field:
    ; Copy field (r13+r9 to r13+r8)
    lea     rsi, [r13 + r9]
    mov     rcx, r8
    sub     rcx, r9
    mov     rax, rcx
    shr     rcx, 3
    jz      .iwof_f0_ws_ct
    rep movsq
.iwof_f0_ws_ct:
    mov     rcx, rax
    and     rcx, 7
    jz      .iwof_f0_ws_skip_ws
    rep movsb
    jmp     .iwof_f0_ws_skip_ws

    ; General case: field N>0 with whitespace separator
.iwof_ws_general:
    xor     ecx, ecx            ; field index
    xor     r8d, r8d            ; position

.iwof_ws_skip:
    cmp     r8, r14
    jge     .iwof_done
    movzx   eax, byte [r13 + r8]
    cmp     al, ' '
    je      .iwof_ws_skip_next
    cmp     al, 9
    je      .iwof_ws_skip_next
    jmp     .iwof_ws_field_start
.iwof_ws_skip_next:
    inc     r8
    jmp     .iwof_ws_skip

.iwof_ws_field_start:
    mov     r9, r8              ; field start
.iwof_ws_scan:
    cmp     r8, r14
    jge     .iwof_ws_field_end
    movzx   eax, byte [r13 + r8]
    cmp     al, ' '
    je      .iwof_ws_field_end
    cmp     al, 9
    je      .iwof_ws_field_end
    inc     r8
    jmp     .iwof_ws_scan

.iwof_ws_field_end:
    cmp     rcx, r15
    je      .iwof_ws_skip_field
    ; Write out_sep + field
    mov     [rdi], bl
    inc     rdi
    ; Copy field (r13+r9 to r13+r8)
    push    rcx
    push    r8
    lea     rsi, [r13 + r9]
    mov     rcx, r8
    sub     rcx, r9
    mov     rax, rcx
    shr     rcx, 3
    jz      .iwof_ws_tail
    rep movsq
.iwof_ws_tail:
    mov     rcx, rax
    and     rcx, 7
    jz      .iwof_ws_copy_done
    rep movsb
.iwof_ws_copy_done:
    pop     r8
    pop     rcx
.iwof_ws_skip_field:
    inc     rcx
    jmp     .iwof_ws_skip

.iwof_done:
    ret

.epl_format:
    ; -o format output
    ; Use pre-computed key
    mov     rax, [rel cur_key1_ptr]
    mov     [rel tmp_key_ptr], rax
    mov     rax, [rel cur_key1_len]
    mov     [rel tmp_key_len], rax

    xor     r14d, r14d          ; spec index

.epl_fmt_loop:
    cmp     r14, [rel opt_fmt_count]
    jge     .epl_fmt_done

    ; Insert separator between fields
    test    r14, r14
    jz      .epl_fmt_no_sep
    lea     rsi, [rel out_sep]
    mov     rdx, 1
    call    append_to_outbuf
.epl_fmt_no_sep:

    lea     rax, [rel fmt_spec_types]
    movzx   eax, byte [rax + r14]
    cmp     al, SPEC_JOIN_FIELD
    je      .epl_fmt_join
    ; SPEC_FILE_FIELD
    lea     rax, [rel fmt_spec_file]
    movzx   eax, byte [rax + r14]
    test    al, al
    jnz     .epl_fmt_f2
    ; File 1
    lea     rax, [rel fmt_spec_field]
    mov     rax, [rax + r14*8]
    mov     rdi, [rsp]
    mov     rsi, [rsp+8]
    mov     rdx, rax
    call    extract_field
    ; If field not found (len=0 and field index was valid), check -e
    test    rdx, rdx
    jnz     .epl_fmt_write_field
    jmp     .epl_fmt_maybe_empty
.epl_fmt_f2:
    lea     rax, [rel fmt_spec_field]
    mov     rax, [rax + r14*8]
    mov     rdi, [rsp+16]
    mov     rsi, [rsp+24]
    mov     rdx, rax
    call    extract_field
    test    rdx, rdx
    jnz     .epl_fmt_write_field
.epl_fmt_maybe_empty:
    ; Use -e string if set, otherwise empty
    mov     rsi, [rel opt_empty_len]
    test    rsi, rsi
    jz      .epl_fmt_next
    lea     rsi, [rel opt_empty_buf]
    mov     rdx, [rel opt_empty_len]
    call    append_to_outbuf
    jmp     .epl_fmt_next
.epl_fmt_join:
    mov     rsi, [rel tmp_key_ptr]
    mov     rdx, [rel tmp_key_len]
    call    append_to_outbuf
    jmp     .epl_fmt_next
.epl_fmt_write_field:
    mov     rsi, rax
    ; rdx already has length
    call    append_to_outbuf
.epl_fmt_next:
    inc     r14
    jmp     .epl_fmt_loop

.epl_fmt_done:
    lea     rsi, [rel line_delim]
    mov     rdx, 1
    call    append_to_outbuf
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ─── emit_unpaired_line(rax=line_index, rdi=file_num 0 or 1) ──
emit_unpaired_line:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     [rsp], rdi          ; file_num
    mov     rbx, rax            ; line index

    ; Get line ptr/len
    cmp     rdi, 0
    jne     .eul_f2
    shl     rax, 3
    lea     r12, [rel lines1_ptrs]
    mov     r12, [r12 + rax]
    lea     r13, [rel lines1_lens]
    mov     r13, [r13 + rbx*8]
    mov     r14, [rel opt_field1]
    jmp     .eul_have_line
.eul_f2:
    shl     rax, 3
    lea     r12, [rel lines2_ptrs]
    mov     r12, [r12 + rax]
    lea     r13, [rel lines2_lens]
    mov     r13, [r13 + rbx*8]
    mov     r14, [rel opt_field2]
.eul_have_line:
    ; r12 = line ptr, r13 = line len, r14 = join field index

    ; Check if using -o format
    cmp     qword [rel opt_fmt_count], 0
    jne     .eul_format

    ; Default format: key + other fields
    mov     rdi, r12
    mov     rsi, r13
    mov     rdx, r14
    call    extract_field
    mov     rsi, rax
    mov     rdx, rdx
    call    append_to_outbuf

    ; Other fields
    mov     rdi, r12
    mov     rsi, r13
    mov     rdx, r14
    call    write_other_fields_to_buf

    ; Line delimiter
    lea     rsi, [rel line_delim]
    mov     rdx, 1
    call    append_to_outbuf
    jmp     .eul_done

.eul_format:
    ; -o format for unpaired line
    ; Extract join key
    mov     rdi, r12
    mov     rsi, r13
    mov     rdx, r14
    call    extract_field
    mov     [rel tmp_key_ptr], rax
    mov     [rel tmp_key_len], rdx

    xor     r15d, r15d          ; spec index

.eul_fmt_loop:
    cmp     r15, [rel opt_fmt_count]
    jge     .eul_fmt_done

    test    r15, r15
    jz      .eul_fmt_no_sep
    lea     rsi, [rel out_sep]
    mov     rdx, 1
    call    append_to_outbuf
.eul_fmt_no_sep:

    lea     rax, [rel fmt_spec_types]
    movzx   eax, byte [rax + r15]
    cmp     al, SPEC_JOIN_FIELD
    je      .eul_fmt_join

    ; SPEC_FILE_FIELD: check if this file matches
    lea     rax, [rel fmt_spec_file]
    movzx   eax, byte [rax + r15]
    cmp     rax, [rsp]          ; file_num
    jne     .eul_fmt_empty      ; Wrong file — use -e or empty

    ; Same file — extract field
    lea     rax, [rel fmt_spec_field]
    mov     rax, [rax + r15*8]
    mov     rdi, r12
    mov     rsi, r13
    mov     rdx, rax
    call    extract_field
    test    rdx, rdx
    jnz     .eul_fmt_write_field
    ; Field not found
    jmp     .eul_fmt_empty

.eul_fmt_join:
    mov     rsi, [rel tmp_key_ptr]
    mov     rdx, [rel tmp_key_len]
    call    append_to_outbuf
    jmp     .eul_fmt_next

.eul_fmt_empty:
    mov     rax, [rel opt_empty_len]
    test    rax, rax
    jz      .eul_fmt_next
    lea     rsi, [rel opt_empty_buf]
    mov     rdx, rax
    call    append_to_outbuf
    jmp     .eul_fmt_next

.eul_fmt_write_field:
    mov     rsi, rax
    call    append_to_outbuf

.eul_fmt_next:
    inc     r15
    jmp     .eul_fmt_loop

.eul_fmt_done:
    lea     rsi, [rel line_delim]
    mov     rdx, 1
    call    append_to_outbuf

.eul_done:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ─── write_other_fields_to_buf(rdi=line_ptr, rsi=line_len, rdx=skip_field) ──
;     Write out_sep + each field except skip_field
write_other_fields_to_buf:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi            ; line ptr
    mov     r13, rsi            ; line len
    mov     r14, rdx            ; skip field index

    cmp     byte [rel opt_sep_set], 0
    je      .wof_whitespace

    ; Character-separated
    movzx   eax, byte [rel opt_sep_char]
    xor     ecx, ecx            ; field index
    xor     ebx, ebx            ; start position
    mov     r15, r12
    add     r15, r13            ; end ptr
    mov     rdi, r12            ; scan ptr

.wof_char_scan:
    cmp     rdi, r15
    jge     .wof_char_last_field
    cmp     byte [rdi], al
    je      .wof_char_sep_found
    inc     rdi
    jmp     .wof_char_scan

.wof_char_sep_found:
    cmp     rcx, r14
    je      .wof_char_skip
    ; Write separator + field
    push    rax
    push    rcx
    push    rdi
    lea     rsi, [rel out_sep]
    mov     rdx, 1
    call    append_to_outbuf
    pop     rdi
    pop     rcx
    pop     rax
    ; Write field content from r12+rbx to rdi
    push    rax
    push    rcx
    push    rdi
    lea     rsi, [r12 + rbx]
    mov     rdx, rdi
    sub     rdx, rsi
    call    append_to_outbuf
    pop     rdi
    pop     rcx
    pop     rax
.wof_char_skip:
    inc     rcx
    inc     rdi
    mov     rbx, rdi
    sub     rbx, r12            ; start = rdi - r12 (offset from line start)
    jmp     .wof_char_scan

.wof_char_last_field:
    cmp     rcx, r14
    je      .wof_done
    ; Write separator + last field
    lea     rsi, [rel out_sep]
    mov     rdx, 1
    call    append_to_outbuf
    lea     rsi, [r12 + rbx]
    mov     rdx, r15
    sub     rdx, rsi
    call    append_to_outbuf
    jmp     .wof_done

    ; Whitespace-separated
.wof_whitespace:
    xor     ecx, ecx            ; field index
    xor     ebx, ebx            ; position

.wof_ws_skip:
    cmp     rbx, r13
    jge     .wof_done
    movzx   eax, byte [r12 + rbx]
    cmp     al, ' '
    je      .wof_ws_skip_next
    cmp     al, 9
    je      .wof_ws_skip_next
    jmp     .wof_ws_field_start
.wof_ws_skip_next:
    inc     rbx
    jmp     .wof_ws_skip

.wof_ws_field_start:
    mov     r15, rbx            ; field start offset
.wof_ws_scan:
    cmp     rbx, r13
    jge     .wof_ws_field_end
    movzx   eax, byte [r12 + rbx]
    cmp     al, ' '
    je      .wof_ws_field_end
    cmp     al, 9
    je      .wof_ws_field_end
    inc     rbx
    jmp     .wof_ws_scan

.wof_ws_field_end:
    cmp     rcx, r14
    je      .wof_ws_skip_field
    ; Write separator + field
    push    rcx
    push    rbx
    lea     rsi, [rel out_sep]
    mov     rdx, 1
    call    append_to_outbuf
    pop     rbx
    pop     rcx
    push    rcx
    push    rbx
    lea     rsi, [r12 + r15]
    mov     rdx, rbx
    sub     rdx, r15
    call    append_to_outbuf
    pop     rbx
    pop     rcx
.wof_ws_skip_field:
    inc     rcx
    jmp     .wof_ws_skip

.wof_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ─── check_order_both: check order of both files ──
;     -> rax = 0 ok, 1 = fatal order error
;     Optimized: uses pre-computed keys, quick first-byte check to skip full compare
check_order_both:
    cmp     byte [rel opt_order_check], ORDER_NONE
    je      .cob_ok

    ; Check file 1
    cmp     byte [rel warned1], 0
    jne     .cob_check2
    mov     rax, [rel idx1]
    movzx   ecx, byte [rel opt_header]
    cmp     rax, rcx
    jle     .cob_check2

    ; Quick first-byte check: if cur[0] >= prev[0], very likely in order
    mov     rax, [rel idx1]
    lea     rcx, [rel keys1_ptrs]
    mov     rdi, [rcx + rax*8]          ; current key ptr
    lea     rcx, [rel keys1_lens]
    mov     rsi, [rcx + rax*8]          ; current key len
    dec     rax
    lea     rcx, [rel keys1_ptrs]
    mov     rdx, [rcx + rax*8]          ; prev key ptr
    lea     rcx, [rel keys1_lens]
    mov     rcx, [rcx + rax*8]          ; prev key len
    ; Quick check: if first bytes differ and cur >= prev, skip full compare
    test    rsi, rsi
    jz      .cob_f1_full                ; empty current = might be out of order
    test    rcx, rcx
    jz      .cob_check2                 ; empty prev = always in order
    movzx   r8d, byte [rdi]
    movzx   r9d, byte [rdx]
    cmp     r8d, r9d
    ja      .cob_check2                 ; first byte strictly greater = in order
    jb      .cob_f1_full                ; first byte less = out of order likely
    ; First bytes equal - need full compare
.cob_f1_full:
    ; compare_keys(current, prev)
    call    compare_keys
    test    rax, rax
    jns     .cob_check2
    ; Out of order
    mov     byte [rel had_order_error], 1
    mov     byte [rel warned1], 1
    mov     rax, [rel idx1]
    call    print_sort_error_f1
    cmp     byte [rel opt_order_check], ORDER_STRICT
    je      .cob_fatal

.cob_check2:
    cmp     byte [rel warned2], 0
    jne     .cob_ok
    mov     rax, [rel idx2]
    movzx   ecx, byte [rel opt_header]
    cmp     rax, rcx
    jle     .cob_ok

    ; Quick first-byte check for file 2
    mov     rax, [rel idx2]
    lea     rcx, [rel keys2_ptrs]
    mov     rdi, [rcx + rax*8]
    lea     rcx, [rel keys2_lens]
    mov     rsi, [rcx + rax*8]
    dec     rax
    lea     rcx, [rel keys2_ptrs]
    mov     rdx, [rcx + rax*8]
    lea     rcx, [rel keys2_lens]
    mov     rcx, [rcx + rax*8]
    test    rsi, rsi
    jz      .cob_f2_full
    test    rcx, rcx
    jz      .cob_ok
    movzx   r8d, byte [rdi]
    movzx   r9d, byte [rdx]
    cmp     r8d, r9d
    ja      .cob_ok
    jb      .cob_f2_full
.cob_f2_full:
    call    compare_keys
    test    rax, rax
    jns     .cob_ok
    mov     byte [rel had_order_error], 1
    mov     byte [rel warned2], 1
    mov     rax, [rel idx2]
    call    print_sort_error_f2
    cmp     byte [rel opt_order_check], ORDER_STRICT
    je      .cob_fatal

.cob_ok:
    xor     eax, eax
    ret
.cob_fatal:
    mov     eax, 1
    ret

; ─── check_order_f1_drain -> rax=0 ok, 1=fatal ──
check_order_f1_drain:
    push    rbx
    cmp     byte [rel warned1], 0
    jne     .cofd1_ok
    mov     rax, [rel idx1]
    movzx   ecx, byte [rel opt_header]
    cmp     rax, rcx
    jle     .cofd1_ok

    ; Get prev key1
    mov     rax, [rel idx1]
    dec     rax
    call    get_key1
    mov     [rel tmp_prev_key_ptr], rax
    mov     [rel tmp_prev_key_len], rdx

    ; Get current key1
    mov     rax, [rel idx1]
    call    get_key1
    mov     rdi, rax
    mov     rsi, rdx
    mov     rdx, [rel tmp_prev_key_ptr]
    mov     rcx, [rel tmp_prev_key_len]
    call    compare_keys
    test    rax, rax
    jns     .cofd1_ok
    mov     byte [rel had_order_error], 1
    mov     byte [rel warned1], 1
    mov     rax, [rel idx1]
    call    print_sort_error_f1
    cmp     byte [rel opt_order_check], ORDER_STRICT
    je      .cofd1_fatal
.cofd1_ok:
    xor     eax, eax
    pop     rbx
    ret
.cofd1_fatal:
    mov     eax, 1
    pop     rbx
    ret

; ─── check_order_f2_drain -> rax=0 ok, 1=fatal ──
check_order_f2_drain:
    push    rbx
    cmp     byte [rel warned2], 0
    jne     .cofd2_ok
    mov     rax, [rel idx2]
    movzx   ecx, byte [rel opt_header]
    cmp     rax, rcx
    jle     .cofd2_ok

    ; Get prev key2
    mov     rax, [rel idx2]
    dec     rax
    call    get_key2
    mov     [rel tmp_prev_key_ptr], rax
    mov     [rel tmp_prev_key_len], rdx

    ; Get current key2
    mov     rax, [rel idx2]
    call    get_key2
    mov     rdi, rax
    mov     rsi, rdx
    mov     rdx, [rel tmp_prev_key_ptr]
    mov     rcx, [rel tmp_prev_key_len]
    call    compare_keys
    test    rax, rax
    jns     .cofd2_ok
    mov     byte [rel had_order_error], 1
    mov     byte [rel warned2], 1
    mov     rax, [rel idx2]
    call    print_sort_error_f2
    cmp     byte [rel opt_order_check], ORDER_STRICT
    je      .cofd2_fatal
.cofd2_ok:
    xor     eax, eax
    pop     rbx
    ret
.cofd2_fatal:
    mov     eax, 1
    pop     rbx
    ret

; ─── print_sort_error_f1(rax=line_index) ──
print_sort_error_f1:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rax            ; line index

    lea     rdi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    write_stderr

    ; Print file name
    mov     rdi, [rel file1_path]
    mov     rsi, rdi
    call    strlen
    mov     rdx, rax
    mov     rdi, rsi
    call    write_stderr

    ; Print ":"
    lea     rdi, [rel str_colon]
    mov     rdx, 1
    call    write_stderr

    ; Print line number (1-indexed)
    lea     rdi, [rel itoa_buf]
    lea     rsi, [r12 + 1]
    call    itoa_u64
    lea     rsi, [rel itoa_buf]
    mov     rdx, rax
    mov     rdi, rsi
    call    write_stderr

    ; Print ": is not sorted: "
    lea     rdi, [rel str_not_sorted]
    mov     rdx, str_not_sorted_len
    call    write_stderr

    ; Print the line content
    mov     rax, r12
    shl     rax, 3
    lea     rdi, [rel lines1_ptrs]
    mov     rdi, [rdi + rax]
    lea     rsi, [rel lines1_lens]
    mov     rsi, [rsi + r12*8]
    mov     rdx, rsi
    mov     rsi, rdi
    mov     rdi, rsi
    call    write_stderr

    lea     rdi, [rel str_newline]
    mov     rdx, 1
    call    write_stderr

    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ─── print_sort_error_f2(rax=line_index) ──
print_sort_error_f2:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rax

    lea     rdi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    write_stderr

    mov     rdi, [rel file2_path]
    mov     rsi, rdi
    call    strlen
    mov     rdx, rax
    mov     rdi, rsi
    call    write_stderr

    lea     rdi, [rel str_colon]
    mov     rdx, 1
    call    write_stderr

    lea     rdi, [rel itoa_buf]
    lea     rsi, [r12 + 1]
    call    itoa_u64
    lea     rsi, [rel itoa_buf]
    mov     rdx, rax
    mov     rdi, rsi
    call    write_stderr

    lea     rdi, [rel str_not_sorted]
    mov     rdx, str_not_sorted_len
    call    write_stderr

    mov     rax, r12
    shl     rax, 3
    lea     rdi, [rel lines2_ptrs]
    mov     rdi, [rdi + rax]
    lea     rsi, [rel lines2_lens]
    mov     rsi, [rsi + r12*8]
    mov     rdx, rsi
    mov     rsi, rdi
    mov     rdi, rsi
    call    write_stderr

    lea     rdi, [rel str_newline]
    mov     rdx, 1
    call    write_stderr

    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ─── split_into_lines(rdi=data, rsi=len, edx=delim, rcx=ptrs_array, r8=lens_array) ──
;     -> rax = number of lines
split_into_lines:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi            ; data
    mov     r13, rsi            ; total len
    mov     r14b, dl            ; delimiter
    mov     r15, rcx            ; ptrs array
    mov     rbx, r8             ; lens array

    test    r13, r13
    jz      .sil_empty

    xor     ecx, ecx            ; line count
    xor     esi, esi            ; current pos (start of line)

.sil_scan:
    cmp     rsi, r13
    jge     .sil_last

    ; Find next delimiter using SSE2
    mov     rdi, r12
    add     rdi, rsi            ; scan start
    mov     rdx, r13
    sub     rdx, rsi            ; remaining

    ; Broadcast delimiter
    movzx   eax, r14b
    movd    xmm0, eax
    punpcklbw xmm0, xmm0
    punpcklwd xmm0, xmm0
    pshufd  xmm0, xmm0, 0

.sil_sse:
    cmp     rdx, 16
    jb      .sil_byte_scan
    movdqu  xmm1, [rdi]
    pcmpeqb xmm1, xmm0
    pmovmskb eax, xmm1
    test    eax, eax
    jnz     .sil_found_sse
    add     rdi, 16
    sub     rdx, 16
    jmp     .sil_sse

.sil_found_sse:
    bsf     eax, eax
    add     rdi, rax            ; rdi points to delimiter

    ; Record line: ptr = r12+rsi, len = rdi - (r12+rsi)
    lea     rax, [r12 + rsi]
    mov     [r15 + rcx*8], rax
    mov     rax, rdi
    sub     rax, r12
    sub     rax, rsi
    mov     [rbx + rcx*8], rax
    inc     ecx
    cmp     ecx, MAX_LINE_PTRS
    jge     .sil_done

    ; Advance past delimiter
    sub     rdi, r12
    lea     rsi, [rdi + 1]
    jmp     .sil_scan

.sil_byte_scan:
    test    rdx, rdx
    jz      .sil_last
.sil_byte_loop:
    cmp     byte [rdi], r14b
    je      .sil_found_byte
    inc     rdi
    dec     rdx
    jnz     .sil_byte_loop
    jmp     .sil_last

.sil_found_byte:
    lea     rax, [r12 + rsi]
    mov     [r15 + rcx*8], rax
    mov     rax, rdi
    sub     rax, r12
    sub     rax, rsi
    mov     [rbx + rcx*8], rax
    inc     ecx
    cmp     ecx, MAX_LINE_PTRS
    jge     .sil_done

    sub     rdi, r12
    lea     rsi, [rdi + 1]
    jmp     .sil_scan

.sil_last:
    ; If remaining data after last delimiter
    cmp     rsi, r13
    jge     .sil_done
    lea     rax, [r12 + rsi]
    mov     [r15 + rcx*8], rax
    mov     rax, r13
    sub     rax, rsi
    mov     [rbx + rcx*8], rax
    inc     ecx

.sil_done:
    mov     eax, ecx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.sil_empty:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ─── parse_format_string(rsi=format_str) ──
;     Parses "0,1.2,2.3" etc, appends to fmt_spec arrays
parse_format_string:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rsi            ; format string

.pfs_token:
    ; Skip commas and spaces
    movzx   eax, byte [r12]
    test    al, al
    jz      .pfs_done
    cmp     al, ','
    je      .pfs_skip
    cmp     al, ' '
    je      .pfs_skip
    jmp     .pfs_parse_token
.pfs_skip:
    inc     r12
    jmp     .pfs_token

.pfs_parse_token:
    ; Check for "0" (join field)
    cmp     byte [r12], '0'
    jne     .pfs_file_field
    ; Could be just "0" or "0" followed by , or end
    movzx   eax, byte [r12+1]
    test    al, al
    jz      .pfs_join_field
    cmp     al, ','
    je      .pfs_join_field
    cmp     al, ' '
    je      .pfs_join_field
    ; "0." would be weird but check for it
    cmp     al, '.'
    je      .pfs_file_field     ; handle like N.M
    jmp     .pfs_file_field

.pfs_join_field:
    mov     rcx, [rel opt_fmt_count]
    cmp     rcx, MAX_FMT_SPECS
    jge     .pfs_advance
    lea     rax, [rel fmt_spec_types]
    mov     byte [rax + rcx], SPEC_JOIN_FIELD
    inc     qword [rel opt_fmt_count]
    inc     r12
    jmp     .pfs_token

.pfs_file_field:
    ; Parse N.M
    mov     rsi, r12
    call    parse_uint
    test    rax, rax
    jz      .pfs_error          ; invalid
    mov     r13, rax            ; file number (1 or 2)

    ; Expect '.'
    cmp     byte [r12], '.'
    jne     .pfs_error
    inc     r12

    mov     rsi, r12
    call    parse_uint_allow_zero
    ; r14 = field number
    mov     r14, rax

    ; Validate file number
    cmp     r13, 1
    je      .pfs_file_ok
    cmp     r13, 2
    je      .pfs_file_ok
    jmp     .pfs_error

.pfs_file_ok:
    ; Field 0 is invalid for N.M format (only bare "0" means join field)
    test    r14, r14
    jz      .pfs_invalid_field_zero

    mov     rcx, [rel opt_fmt_count]
    cmp     rcx, MAX_FMT_SPECS
    jge     .pfs_advance
    lea     rax, [rel fmt_spec_types]
    mov     byte [rax + rcx], SPEC_FILE_FIELD
    lea     rax, [rel fmt_spec_file]
    dec     r13                 ; 0-indexed
    mov     byte [rax + rcx], r13b
    lea     rax, [rel fmt_spec_field]
    dec     r14                 ; 0-indexed
    mov     [rax + rcx*8], r14
    inc     qword [rel opt_fmt_count]
    jmp     .pfs_token

.pfs_invalid_field_zero:
    ; N.0 is invalid in GNU join
    lea     rdi, [rel str_invalid_field_zero]
    mov     rdx, str_invalid_field_zero_len
    call    write_stderr
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.pfs_advance:
    ; Skip to next comma or end
    movzx   eax, byte [r12]
    test    al, al
    jz      .pfs_done
    cmp     al, ','
    je      .pfs_token
    cmp     al, ' '
    je      .pfs_token
    inc     r12
    jmp     .pfs_advance

.pfs_error:
    ; Skip invalid token
    jmp     .pfs_advance

.pfs_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ─── parse_uint(rsi=str) -> rax=value, advances r12 ──
;     Returns 0 if not a number. Does not accept 0 as first digit for field nums.
parse_uint:
    xor     eax, eax
    movzx   ecx, byte [r12]
    cmp     cl, '1'
    jb      .pu_fail
    cmp     cl, '9'
    ja      .pu_fail
.pu_loop:
    movzx   ecx, byte [r12]
    cmp     cl, '0'
    jb      .pu_done
    cmp     cl, '9'
    ja      .pu_done
    imul    rax, 10
    sub     cl, '0'
    movzx   ecx, cl
    add     rax, rcx
    inc     r12
    jmp     .pu_loop
.pu_done:
    ret
.pu_fail:
    xor     eax, eax
    ret

; ─── parse_uint_allow_zero -> rax=value ──
parse_uint_allow_zero:
    xor     eax, eax
    movzx   ecx, byte [r12]
    cmp     cl, '0'
    jb      .puz_fail
    cmp     cl, '9'
    ja      .puz_fail
.puz_loop:
    movzx   ecx, byte [r12]
    cmp     cl, '0'
    jb      .puz_done
    cmp     cl, '9'
    ja      .puz_done
    imul    rax, 10
    sub     cl, '0'
    movzx   ecx, cl
    add     rax, rcx
    inc     r12
    jmp     .puz_loop
.puz_done:
    ret
.puz_fail:
    xor     eax, eax
    ret

; ─── open_and_mmap_file(rdi=path) -> rax=addr, rdx=len ──
open_and_mmap_file:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi

    ; Check for stdin ("-")
    cmp     byte [rdi], '-'
    jne     .omf_not_stdin
    cmp     byte [rdi+1], 0
    jne     .omf_not_stdin

    ; Read stdin into brk buffer
    mov     rax, SYS_BRK
    xor     edi, edi
    syscall
    mov     r12, rax
    lea     rdi, [rax + STDIN_BUF_SIZE]
    mov     rax, SYS_BRK
    syscall
    cmp     rax, r12
    je      .omf_brk_fail

    xor     r13d, r13d
.omf_stdin_loop:
    mov     rdi, STDIN
    lea     rsi, [r12 + r13]
    mov     rdx, STDIN_BUF_SIZE
    sub     rdx, r13
    jle     .omf_stdin_done
    call    asm_read
    test    rax, rax
    jle     .omf_stdin_done
    add     r13, rax
    jmp     .omf_stdin_loop
.omf_stdin_done:
    mov     rax, r12
    mov     rdx, r13
    pop     r13
    pop     r12
    pop     rbx
    ret
.omf_brk_fail:
    mov     rax, -1
    xor     edx, edx
    pop     r13
    pop     r12
    pop     rbx
    ret

.omf_not_stdin:
    ; Open file
    mov     rdi, rbx
    xor     esi, esi
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .omf_open_fail
    mov     r12, rax            ; fd

    ; fstat
    mov     rdi, r12
    lea     rsi, [rel stat_buf]
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .omf_fstat_fail

    mov     r13, [rel stat_buf + 48]  ; st_size
    test    r13, r13
    jz      .omf_empty_file

    ; mmap
    xor     edi, edi
    mov     rsi, r13
    mov     edx, PROT_READ
    mov     r10d, MAP_PRIVATE
    or      r10d, MAP_POPULATE
    mov     r8, r12
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .omf_mmap_fail

    ; madvise sequential
    push    rax
    mov     rdi, rax
    mov     rsi, r13
    mov     edx, MADV_SEQUENTIAL
    mov     rax, SYS_MADVISE
    syscall

    ; close fd
    mov     rdi, r12
    call    asm_close

    pop     rax
    mov     rdx, r13
    pop     r13
    pop     r12
    pop     rbx
    ret

.omf_empty_file:
    mov     rdi, r12
    call    asm_close
    lea     rax, [rel stat_buf]  ; return any valid non-negative addr
    xor     edx, edx
    pop     r13
    pop     r12
    pop     rbx
    ret

.omf_open_fail:
.omf_fstat_fail:
.omf_mmap_fail:
    mov     rax, -1
    xor     edx, edx
    pop     r13
    pop     r12
    pop     rbx
    ret

; ─── append_to_outbuf(rsi=data, rdx=len) ──
;     Optimized: uses 8-byte copies for bulk, byte tail for remainder
append_to_outbuf:
    test    rdx, rdx
    jz      .atob_done
    mov     rcx, [rel out_buf_used]
    ; Check if we need to flush first
    lea     rax, [rcx + rdx]
    cmp     rax, OUT_BUF_SIZE
    jb      .atob_copy
    ; Flush before copy
    push    rsi
    push    rdx
    call    flush_outbuf
    pop     rdx
    pop     rsi
    mov     rcx, [rel out_buf_used]
.atob_copy:
    lea     rdi, [rel out_buf]
    add     rdi, rcx
    add     [rel out_buf_used], rdx
    ; Use rep movsq for 8+ bytes, then rep movsb for remainder
    mov     rcx, rdx
    shr     rcx, 3              ; count of 8-byte chunks
    jz      .atob_tail
    rep movsq
.atob_tail:
    mov     rcx, rdx
    and     rcx, 7              ; remaining bytes
    jz      .atob_done
    rep movsb
.atob_done:
    ret

; ─── flush_outbuf ──
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
    ; Silently exit on EPIPE (SIGPIPE equivalent)
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

; ─── Utility subroutines ─────────────────────────────────

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

itoa_u64:
    push    rbx
    push    r12
    mov     r12, rdi
    mov     rax, rsi
    test    rax, rax
    jnz     .itoa_nonzero
    mov     byte [r12], '0'
    mov     rax, 1
    pop     r12
    pop     rbx
    ret
.itoa_nonzero:
    lea     rbx, [rel itoa_tmp]
    xor     ecx, ecx
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
    pop     r12
    pop     rbx
    ret

err_invalid_option:
    push    rsi
    lea     rdi, [rel str_invalid_opt_prefix]
    mov     rdx, str_invalid_opt_prefix_len
    call    write_stderr
    pop     rsi
    mov     rdi, rsi
    push    rdi
    call    strlen
    pop     rdi
    mov     rdx, rax
    call    write_stderr
    lea     rdi, [rel str_quote_nl]
    mov     rdx, str_quote_nl_len
    call    write_stderr
    lea     rdi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    write_stderr
    ret

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
    mov     rdx, str_quote_nl_len
    call    write_stderr
    lea     rdi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    write_stderr
    ret

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

; ═══════════════════════════════════════════════════════════
;                      DATA SECTION
; ═══════════════════════════════════════════════════════════


; ─── Data ────────────────────────────────────────────────

align 16
sigact_buf:
    dq 0                        ; sa_handler = SIG_DFL (we just block)
    dq 0x04000000               ; SA_RESTORER
    dq 0
    dq 0

str_prefix:     db "join: "
str_prefix_len equ $ - str_prefix

str_newline:    db 10
str_colon:      db ":"
str_colon_space: db ": "
str_quote_open: db 0x27         ; single quote
str_quote_open_len equ 1
str_quote_nl:   db 0x27, 10
str_quote_nl_len equ 2

str_help_opt:           db "--help", 0
str_version_opt:        db "--version", 0
str_check_order_opt:    db "--check-order", 0
str_nocheck_order_opt:  db "--nocheck-order", 0
str_header_opt:         db "--header", 0
str_ignore_case_opt:    db "--ignore-case", 0
str_zeroterm_opt:       db "--zero-terminated", 0

str_missing_operand:    db "join: missing operand", 10
str_missing_operand_len equ $ - str_missing_operand

str_missing_after:      db "missing operand after "
str_missing_after_len equ $ - str_missing_after

str_extra_operand:      db "extra operand "
str_extra_operand_len equ $ - str_extra_operand

str_not_sorted:         db ": is not sorted: "
str_not_sorted_len equ $ - str_not_sorted

str_input_not_sorted:   db "join: input is not in sorted order", 10
str_input_not_sorted_len equ $ - str_input_not_sorted

str_unrecognized:       db "join: unrecognized option ", 0x27
str_unrecognized_len equ $ - str_unrecognized

str_invalid_opt_prefix: db "join: invalid option -- ", 0x27
str_invalid_opt_prefix_len equ $ - str_invalid_opt_prefix

str_try_help: db "Try 'join --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_enoent: db "No such file or directory"
str_enoent_len equ $ - str_enoent

str_invalid_filenum: db "invalid file number: "
str_invalid_filenum_len equ $ - str_invalid_filenum

str_invalid_field: db "join: invalid field number", 10
str_invalid_field_len equ $ - str_invalid_field

str_empty_sep: db "join: empty separator", 10
str_empty_sep_len equ $ - str_empty_sep

str_invalid_field_zero: db "join: invalid field number: ", 0x27, "0", 0x27, 10
str_invalid_field_zero_len equ $ - str_invalid_field_zero

str_opt_req_arg_a: db "join: option requires an argument -- 'a'", 10
str_opt_req_arg_a_len equ $ - str_opt_req_arg_a

str_opt_req_arg_v: db "join: option requires an argument -- 'v'", 10
str_opt_req_arg_v_len equ $ - str_opt_req_arg_v

str_opt_req_arg_e: db "join: option requires an argument -- 'e'", 10
str_opt_req_arg_e_len equ $ - str_opt_req_arg_e

str_opt_req_arg_j: db "join: option requires an argument -- 'j'", 10
str_opt_req_arg_j_len equ $ - str_opt_req_arg_j

str_opt_req_arg_o: db "join: option requires an argument -- 'o'", 10
str_opt_req_arg_o_len equ $ - str_opt_req_arg_o

str_opt_req_arg_t: db "join: option requires an argument -- 't'", 10
str_opt_req_arg_t_len equ $ - str_opt_req_arg_t

str_opt_req_arg_1: db "join: option requires an argument -- '1'", 10
str_opt_req_arg_1_len equ $ - str_opt_req_arg_1

str_opt_req_arg_2: db "join: option requires an argument -- '2'", 10
str_opt_req_arg_2_len equ $ - str_opt_req_arg_2

str_write_error_msg: db "join: write error", 10
str_write_error_msg_len equ $ - str_write_error_msg

help_text:
    db "Usage: join [OPTION]... FILE1 FILE2", 10
    db "For each pair of input lines with identical join fields, write a line to", 10
    db "standard output.  The default join field is the first, delimited by blanks.", 10
    db 10
    db "When FILE1 or FILE2 (not both) is -, read standard input.", 10
    db 10
    db "  -a FILENUM        also print unpairable lines from file FILENUM, where", 10
    db "                      FILENUM is 1 or 2, corresponding to FILE1 or FILE2", 10
    db "  -e EMPTY          replace missing input fields with EMPTY", 10
    db "  -i, --ignore-case  ignore differences in case when comparing fields", 10
    db "  -j FIELD          equivalent to '-1 FIELD -2 FIELD'", 10
    db "  -o FORMAT         obey FORMAT while constructing output line", 10
    db "  -t CHAR           use CHAR as input and output field separator", 10
    db "  -v FILENUM        like -a FILENUM, but suppress joined output lines", 10
    db "  -1 FIELD          join on this FIELD of file 1", 10
    db "  -2 FIELD          join on this FIELD of file 2", 10
    db "      --check-order     check that the input is correctly sorted, even", 10
    db "                          if all input lines are pairable", 10
    db "      --nocheck-order   do not check that the input is correctly sorted", 10
    db "      --header          treat the first line in each file as field headers,", 10
    db "                          print them without trying to pair them", 10
    db "  -z, --zero-terminated  line delimiter is NUL, not newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
help_text_len equ $ - help_text

version_text:
    db "join (fcoreutils) 0.1.0", 10
version_text_len equ $ - version_text

; ═══════════════════════════════════════════════════════════
;                      BSS SECTION
; ═══════════════════════════════════════════════════════════


file_end equ $
bss_file_offset equ file_end - ehdr

; ─── BSS (virtual memory, mapped by PT_LOAD with memsz > filesz) ─
; Use absolute section so no bytes are emitted in the binary file.

bss_start equ 0x500000

%assign BSS_OFF 0


; Options
opt_field1 equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
opt_field2 equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
opt_sep_set equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
opt_sep_char equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
opt_ignore_case equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
opt_zero_term equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
opt_header equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
opt_order_check equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
opt_print_unpaired1 equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
opt_print_unpaired2 equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
opt_only_unpaired1 equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
opt_only_unpaired2 equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
opt_auto_format equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
seen_dashdash equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1

%assign BSS_OFF ((BSS_OFF + 7) / 8) * 8
opt_empty_len equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
opt_empty_buf equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 256

%assign BSS_OFF ((BSS_OFF + 7) / 8) * 8
opt_fmt_count equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
fmt_spec_types equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 64
fmt_spec_file equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 64
%assign BSS_OFF ((BSS_OFF + 7) / 8) * 8
fmt_spec_field equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 512

; Computed flags
print_paired equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
show_unpaired1 equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
show_unpaired2 equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
out_sep equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
line_delim equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1

; File state
%assign BSS_OFF ((BSS_OFF + 7) / 8) * 8
file1_path equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
file2_path equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
file1_addr equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
file1_len equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
file2_addr equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
file2_len equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8

; Line arrays (ptrs + lens for each file)
%assign BSS_OFF ((BSS_OFF + 7) / 8) * 8
lines1_count equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
lines2_count equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8

%assign BSS_OFF ((BSS_OFF + 7) / 8) * 8
lines1_ptrs equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 33554432
lines1_lens equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 33554432
lines2_ptrs equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 33554432
lines2_lens equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 33554432

; Pre-computed join key arrays
%assign BSS_OFF ((BSS_OFF + 7) / 8) * 8
keys1_ptrs equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 33554432
keys1_lens equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 33554432
keys2_ptrs equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 33554432
keys2_lens equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 33554432

; Auto format temps
%assign BSS_OFF ((BSS_OFF + 7) / 8) * 8
auto_fc1 equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
auto_fc2 equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8

; Merge state
%assign BSS_OFF ((BSS_OFF + 7) / 8) * 8
idx1 equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
idx2 equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
cur_key1_ptr equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
cur_key1_len equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
cur_key2_ptr equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
cur_key2_len equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
group2_start equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
group_key_ptr equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
group_key_len equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
cross_j equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8

; Temporary storage
tmp_key_ptr equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
tmp_key_len equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
tmp_prev_key_ptr equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8
tmp_prev_key_len equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8

; Order check state
had_order_error equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
warned1 equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1
warned2 equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1

; Misc
%assign BSS_OFF ((BSS_OFF + 7) / 8) * 8
stat_buf equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 144
itoa_buf equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 32
itoa_tmp equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 32

; Output buffer
%assign BSS_OFF ((BSS_OFF + 7) / 8) * 8
out_buf_used equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 8

%assign BSS_OFF ((BSS_OFF + 15) / 16) * 16
out_buf equ bss_start + BSS_OFF
%assign BSS_OFF BSS_OFF + 1048576


bss_end equ bss_start + BSS_OFF
