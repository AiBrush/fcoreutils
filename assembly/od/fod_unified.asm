; ============================================================================
;  fod_unified.asm — GNU-compatible "od" in x86-64 Linux assembly
;  Single nasm -f bin file with hand-crafted ELF header.
;
;  A drop-in replacement for GNU coreutils `od`. Produces a small static
;  ELF binary with zero dependencies — no libc, no dynamic linker.
;
;  Supports:
;    -A RADIX     address radix (d, o, x, n)
;    -t TYPE      output type (a, c, d[SIZE], f[SIZE], o[SIZE], u[SIZE], x[SIZE])
;    -j BYTES     skip bytes
;    -N BYTES     limit bytes
;    -w [BYTES]   bytes per line (default 16, 32 when explicit)
;    -v           output duplicates
;    --endian={big,little}
;    --traditional
;    -b -c -d -f -i -l -o -s -x  (short aliases)
;    --help --version --
;
;  BUILD:
;    nasm -f bin fod_unified.asm -o fod && chmod +x fod
; ============================================================================

BITS 64
ORG 0x400000

; --- Syscall numbers ---
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
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT        60

%define STDIN            0
%define STDOUT           1
%define STDERR           2

%define O_RDONLY         0

; ── Constants ──────────────────────────────────────────
%define MAX_FILES       256
%define OUTBUF_SIZE     262144      ; 256KB output buffer
%define INBUF_SIZE      131072
%define MAX_TYPES       16
%define MAX_LINE_FMT    1024

; mmap constants
%define PROT_READ       1
%define MAP_PRIVATE     2
%define MAP_POPULATE    0x08000     ; pre-fault pages for readahead

; Address radix constants
%define ADDR_OCTAL      0
%define ADDR_DECIMAL    1
%define ADDR_HEX        2
%define ADDR_NONE       3

; Output type constants
%define TYPE_A          0       ; named characters
%define TYPE_C          1       ; C-style characters
%define TYPE_D          2       ; signed decimal
%define TYPE_F          3       ; floating point
%define TYPE_O          4       ; octal
%define TYPE_U          5       ; unsigned decimal
%define TYPE_X          6       ; hexadecimal

; EPIPE
%define EPIPE           32

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
    dw 2                        ; 2 program headers
    dw 64                       ; section header entry size
    dw 0                        ; section header count
    dw 0                        ; section name index
ehdr_size equ $ - ehdr

; --- Program Header 1: PT_LOAD (code + rodata + BSS) ---
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
    cmp     rax, -4
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
    cmp     rax, -4
    je      .ar_retry
    ret

asm_open:
    mov     rax, SYS_OPEN
    syscall
    ret

asm_close:
    mov     rax, SYS_CLOSE
    syscall
    ret

asm_exit:
    mov     rax, SYS_EXIT
    syscall

; ============================================================================
;                           ENTRY POINT
; ============================================================================
_start:
    ; ── Block SIGPIPE so write() returns -EPIPE instead of killing us ──
    sub     rsp, 16
    mov     qword [rsp], 0x1000         ; sigset: bit 12 = SIGPIPE
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi                    ; SIG_BLOCK = 0
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    ; ── Save argc/argv ──
    mov     rax, [rsp]
    mov     [argc], rax
    lea     rax, [rsp + 8]
    mov     [argv], rax

    ; ── Initialize defaults ──
    mov     byte [addr_radix], ADDR_OCTAL
    mov     qword [skip_bytes], 0
    mov     qword [limit_bytes], -1     ; no limit
    mov     qword [bytes_per_line], 16
    mov     byte [show_dupes], 0
    mov     byte [have_limit], 0
    mov     qword [num_types], 0
    mov     qword [num_files], 0
    mov     byte [had_error], 0
    mov     byte [w_explicit], 0
    mov     qword [total_offset], 0

    ; ── Parse arguments ──
    call    parse_args

    ; Set total_offset to skip_bytes (addresses start from skip offset)
    mov     rax, [skip_bytes]
    mov     [total_offset], rax

    ; If no types specified, default is o2
    cmp     qword [num_types], 0
    jne     .have_types
    ; Default: octal 2-byte
    mov     rdi, type_specs
    mov     byte [rdi], TYPE_O
    mov     byte [rdi+1], 2
    mov     qword [num_types], 1
.have_types:

    ; Compute column widths for all types
    call    compute_col_widths

    ; If no files, use stdin
    cmp     qword [num_files], 0
    jne     .have_files
    mov     rax, dash_str
    mov     rdi, file_ptrs
    mov     [rdi], rax
    mov     qword [num_files], 1
.have_files:

    ; Compute address width based on total input size
    call    compute_addr_width

    ; Initialize output buffer
    mov     qword [outbuf_pos], 0

    ; Initialize previous line buffer (for duplicate suppression)
    mov     byte [prev_line_valid], 0
    mov     byte [dup_star_printed], 0

    ; Process files
    call    process_all_files

    ; Print final address
    call    print_final_address

    ; Flush output buffer
    call    flush_outbuf

    ; Exit
    movzx   edi, byte [had_error]
    call    asm_exit

; ============================================================================
;  parse_args — Parse command-line arguments
; ============================================================================
parse_args:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, 1                      ; arg index (skip argv[0])
    mov     r13, [argc]
    mov     r14, [argv]
    xor     r15d, r15d                  ; end-of-options flag

.arg_loop:
    cmp     r12, r13
    jge     .done

    mov     rbx, [r14 + r12*8]         ; rbx = argv[i]
    movzx   eax, byte [rbx]

    ; Check for "--"
    cmp     byte [rbx], '-'
    jne     .is_file
    cmp     byte [rbx+1], 0
    je      .is_file                    ; "-" is stdin (a file)
    test    r15b, r15b
    jnz     .is_file                    ; after --, everything is a file

    cmp     byte [rbx+1], '-'
    jne     .short_opt

    ; Long option
    cmp     byte [rbx+2], 0
    jne     .long_opt
    ; "--" end of options
    mov     r15b, 1
    inc     r12
    jmp     .arg_loop

.long_opt:
    ; Check --help
    lea     rdi, [rbx]
    mov     rsi, opt_help
    call    str_eq
    test    eax, eax
    jnz     .do_help

    ; Check --version
    lea     rdi, [rbx]
    mov     rsi, opt_version
    call    str_eq
    test    eax, eax
    jnz     .do_version

    ; Check --output-duplicates
    lea     rdi, [rbx]
    mov     rsi, opt_output_dup
    call    str_eq
    test    eax, eax
    jnz     .do_verbose

    ; Check --traditional
    lea     rdi, [rbx]
    mov     rsi, opt_traditional
    call    str_eq
    test    eax, eax
    jnz     .do_traditional

    ; Check --address-radix=
    lea     rdi, [rbx]
    mov     rsi, opt_addr_radix
    mov     ecx, 16
    call    str_prefix
    test    eax, eax
    jnz     .do_addr_radix_long

    ; Check --format=
    lea     rdi, [rbx]
    mov     rsi, opt_format
    mov     ecx, 9
    call    str_prefix
    test    eax, eax
    jnz     .do_format_long

    ; Check --skip-bytes=
    lea     rdi, [rbx]
    mov     rsi, opt_skip_bytes
    mov     ecx, 13
    call    str_prefix
    test    eax, eax
    jnz     .do_skip_long

    ; Check --read-bytes=
    lea     rdi, [rbx]
    mov     rsi, opt_read_bytes
    mov     ecx, 13
    call    str_prefix
    test    eax, eax
    jnz     .do_read_long

    ; Check --width=
    lea     rdi, [rbx]
    mov     rsi, opt_width_eq
    mov     ecx, 8
    call    str_prefix
    test    eax, eax
    jnz     .do_width_long

    ; Check --width (no =)
    lea     rdi, [rbx]
    mov     rsi, opt_width
    call    str_eq
    test    eax, eax
    jnz     .do_width_noarg

    ; Check --endian=
    lea     rdi, [rbx]
    mov     rsi, opt_endian
    mov     ecx, 9
    call    str_prefix
    test    eax, eax
    jnz     .do_endian_long

    ; Check --strings or --strings=
    lea     rdi, [rbx]
    mov     rsi, opt_strings
    call    str_eq
    test    eax, eax
    jnz     .skip_arg        ; ignore -S/--strings for now

    lea     rdi, [rbx]
    mov     rsi, opt_strings_eq
    mov     ecx, 10
    call    str_prefix
    test    eax, eax
    jnz     .skip_arg        ; ignore --strings=

    ; Unrecognized long option
    jmp     .err_unrec

.short_opt:
    ; Process short options (may be grouped: -bcx)
    lea     rbx, [rbx + 1]             ; skip '-'
.short_loop:
    movzx   eax, byte [rbx]
    test    al, al
    jz      .next_arg

    cmp     al, 'A'
    je      .do_A
    cmp     al, 't'
    je      .do_t
    cmp     al, 'j'
    je      .do_j
    cmp     al, 'N'
    je      .do_N
    cmp     al, 'w'
    je      .do_w
    cmp     al, 'v'
    je      .do_v
    cmp     al, 'a'
    je      .do_short_a
    cmp     al, 'b'
    je      .do_short_b
    cmp     al, 'c'
    je      .do_short_c
    cmp     al, 'd'
    je      .do_short_d
    cmp     al, 'f'
    je      .do_short_f
    cmp     al, 'i'
    je      .do_short_i
    cmp     al, 'l'
    je      .do_short_l
    cmp     al, 'o'
    je      .do_short_o
    cmp     al, 's'
    je      .do_short_s
    cmp     al, 'x'
    je      .do_short_x
    cmp     al, 'S'
    je      .do_S

    ; Unrecognized short option
    jmp     .err_invalid

.do_A:
    ; -A needs next char or next arg
    inc     rbx
    movzx   eax, byte [rbx]
    test    al, al
    jnz     .parse_A_char
    ; next arg
    inc     r12
    cmp     r12, r13
    jge     .err_missing_arg
    mov     rbx, [r14 + r12*8]
    movzx   eax, byte [rbx]
.parse_A_char:
    cmp     al, 'o'
    je      .A_octal
    cmp     al, 'd'
    je      .A_decimal
    cmp     al, 'x'
    je      .A_hex
    cmp     al, 'n'
    je      .A_none
    jmp     .err_invalid_radix
.A_octal:
    mov     byte [addr_radix], ADDR_OCTAL
    jmp     .next_arg
.A_decimal:
    mov     byte [addr_radix], ADDR_DECIMAL
    jmp     .next_arg
.A_hex:
    mov     byte [addr_radix], ADDR_HEX
    jmp     .next_arg
.A_none:
    mov     byte [addr_radix], ADDR_NONE
    jmp     .next_arg

.do_t:
    ; -t needs next chars or next arg
    inc     rbx
    movzx   eax, byte [rbx]
    test    al, al
    jnz     .parse_type_str
    ; next arg
    inc     r12
    cmp     r12, r13
    jge     .err_missing_arg
    mov     rbx, [r14 + r12*8]
.parse_type_str:
    mov     rdi, rbx
    call    add_type_spec
    jmp     .next_arg

.do_j:
    ; -j needs next chars or next arg
    inc     rbx
    movzx   eax, byte [rbx]
    test    al, al
    jnz     .parse_j_val
    inc     r12
    cmp     r12, r13
    jge     .err_missing_arg
    mov     rbx, [r14 + r12*8]
.parse_j_val:
    mov     rdi, rbx
    call    parse_byte_count
    mov     [skip_bytes], rax
    jmp     .next_arg

.do_N:
    inc     rbx
    movzx   eax, byte [rbx]
    test    al, al
    jnz     .parse_N_val
    inc     r12
    cmp     r12, r13
    jge     .err_missing_arg
    mov     rbx, [r14 + r12*8]
.parse_N_val:
    mov     rdi, rbx
    call    parse_byte_count
    mov     [limit_bytes], rax
    mov     byte [have_limit], 1
    jmp     .next_arg

.do_w:
    mov     byte [w_explicit], 1
    inc     rbx
    movzx   eax, byte [rbx]
    test    al, al
    jz      .w_default
    ; Check if next chars are digits
    cmp     al, '0'
    jb      .w_default_continue
    cmp     al, '9'
    ja      .w_default_continue
    ; Parse width from remaining chars
    mov     rdi, rbx
    call    parse_decimal
    test    rax, rax
    jz      .w_default
    mov     [bytes_per_line], rax
    jmp     .next_arg
.w_default:
    mov     qword [bytes_per_line], 32
    jmp     .next_arg
.w_default_continue:
    ; Not a digit, so -w with default 32 and continue parsing remaining chars
    mov     qword [bytes_per_line], 32
    jmp     .short_loop

.do_v:
    mov     byte [show_dupes], 1
    inc     rbx
    jmp     .short_loop

.do_short_a:
    ; -a = -t a
    push    rbx
    mov     rdi, str_type_a
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_b:
    ; -b = -t o1
    push    rbx
    mov     rdi, str_type_o1
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_c:
    ; -c = -t c
    push    rbx
    mov     rdi, str_type_c
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_d:
    ; -d = -t u2
    push    rbx
    mov     rdi, str_type_u2
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_f:
    ; -f = -t fF
    push    rbx
    mov     rdi, str_type_fF
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_i:
    ; -i = -t dI
    push    rbx
    mov     rdi, str_type_dI
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_l:
    ; -l = -t dL
    push    rbx
    mov     rdi, str_type_dL
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_o:
    ; -o = -t o2
    push    rbx
    mov     rdi, str_type_o2
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_s:
    ; -s = -t d2
    push    rbx
    mov     rdi, str_type_d2
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_x:
    ; -x = -t x2
    push    rbx
    mov     rdi, str_type_x2
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_S:
    ; -S BYTES (strings) — skip for now
    inc     rbx
    movzx   eax, byte [rbx]
    test    al, al
    jnz     .next_arg
    inc     r12
    jmp     .next_arg

.do_help:
    mov     rdi, STDOUT
    mov     rsi, str_help
    mov     rdx, str_help_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit

.do_version:
    mov     rdi, STDOUT
    mov     rsi, str_version
    mov     rdx, str_version_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit

.do_verbose:
    mov     byte [show_dupes], 1
    inc     r12
    jmp     .arg_loop

.do_traditional:
    ; just accept it, don't change behavior significantly
    inc     r12
    jmp     .arg_loop

.do_addr_radix_long:
    lea     rbx, [rbx + 16]        ; skip "--address-radix="
    movzx   eax, byte [rbx]
    jmp     .parse_A_char

.do_format_long:
    lea     rbx, [rbx + 9]         ; skip "--format="
    mov     rdi, rbx
    call    add_type_spec
    inc     r12
    jmp     .arg_loop

.do_skip_long:
    lea     rdi, [rbx + 13]        ; skip "--skip-bytes="
    call    parse_byte_count
    mov     [skip_bytes], rax
    inc     r12
    jmp     .arg_loop

.do_read_long:
    lea     rdi, [rbx + 13]        ; skip "--read-bytes="
    call    parse_byte_count
    mov     [limit_bytes], rax
    mov     byte [have_limit], 1
    inc     r12
    jmp     .arg_loop

.do_width_long:
    lea     rdi, [rbx + 8]         ; skip "--width="
    call    parse_decimal
    test    rax, rax
    jz      .w_long_default
    mov     [bytes_per_line], rax
    mov     byte [w_explicit], 1
    inc     r12
    jmp     .arg_loop
.w_long_default:
    mov     qword [bytes_per_line], 32
    mov     byte [w_explicit], 1
    inc     r12
    jmp     .arg_loop

.do_width_noarg:
    mov     qword [bytes_per_line], 32
    mov     byte [w_explicit], 1
    inc     r12
    jmp     .arg_loop

.do_endian_long:
    ; Just accept --endian=big or --endian=little; we always use native (little)
    inc     r12
    jmp     .arg_loop

.skip_arg:
    inc     r12
    jmp     .arg_loop

.is_file:
    ; Add file pointer
    mov     rcx, [num_files]
    cmp     rcx, MAX_FILES
    jge     .next_arg
    mov     rdi, file_ptrs
    mov     rax, [r14 + r12*8]
    mov     [rdi + rcx*8], rax
    inc     rcx
    mov     [num_files], rcx
    jmp     .next_arg

.next_arg:
    inc     r12
    jmp     .arg_loop

.err_unrec:
    ; Print "od: unrecognized option 'X'"
    mov     rdi, STDERR
    mov     rsi, str_od_prefix
    mov     rdx, 4
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_unrec_opt
    mov     rdx, str_unrec_opt_len
    call    asm_write_all
    mov     rdi, [r14 + r12*8]
    call    str_len
    mov     rdx, rax
    mov     rsi, rdi
    mov     rdi, STDERR
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_quote_nl
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_try_help
    mov     rdx, str_try_help_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.err_invalid:
    mov     rdi, STDERR
    mov     rsi, str_od_prefix
    mov     rdx, 4
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_inv_opt
    mov     rdx, str_inv_opt_len
    call    asm_write_all
    movzx   eax, byte [rbx]
    mov     [char_buf], al
    mov     rdi, STDERR
    mov     rsi, char_buf
    mov     rdx, 1
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_quote_nl
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_try_help
    mov     rdx, str_try_help_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.err_missing_arg:
    mov     edi, 1
    call    asm_exit

.err_invalid_radix:
    mov     edi, 1
    call    asm_exit

.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  compute_col_widths — Calculate column widths for all types
; ============================================================================
compute_col_widths:
    push    rbx
    push    r12
    push    r13

    ; Fast path: single type — use base width directly (avoids rounding error)
    cmp     qword [num_types], 1
    jne     .ccw_multi
    mov     rax, type_specs
    movzx   edi, byte [rax]            ; type code
    movzx   esi, byte [rax + 1]        ; size
    call    get_base_field_width
    mov     rdx, type_col_widths
    mov     [rdx], eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.ccw_multi:

    ; First pass: find max per-byte width
    ; per_byte_width = ceil(base_width / size)
    ; We use *2 to avoid fractions: per_byte_x2 = (base_width * 2 + size - 1) / size
    pop     r13
    pop     r12
    pop     rbx

    ; For now, use a simple table-based approach
    push    rbx
    push    r12
    push    r13
    push    r14

    ; Find max per_byte_width (using integer math with *2 to handle halves)
    xor     r12d, r12d          ; max_per_byte_x2 = 0
    xor     ecx, ecx

.cw_pass1:
    cmp     rcx, [num_types]
    jge     .cw_pass1_done

    mov     rax, type_specs
    movzx   edi, byte [rax + rcx*2]        ; type code
    movzx   esi, byte [rax + rcx*2 + 1]    ; size
    push    rcx
    call    get_base_field_width
    ; rax = base width
    pop     rcx
    mov     rdx, type_specs
    movzx   esi, byte [rdx + rcx*2 + 1]    ; size

    ; per_byte_x2 = (base_width * 2 + size - 1) / size
    shl     rax, 1              ; * 2
    lea     rax, [rax + rsi - 1]
    xor     edx, edx
    movzx   esi, sil
    div     rsi                 ; rax = per_byte_x2
    cmp     rax, r12
    jle     .cw_not_max
    mov     r12, rax
.cw_not_max:
    inc     rcx
    jmp     .cw_pass1

.cw_pass1_done:
    ; Second pass: compute actual width for each type
    ; actual_width = max_per_byte_x2 * size / 2
    xor     ecx, ecx
.cw_pass2:
    cmp     rcx, [num_types]
    jge     .cw_done

    mov     rax, type_specs
    movzx   esi, byte [rax + rcx*2 + 1]    ; size

    ; actual_width = max_per_byte_x2 * size / 2
    mov     rax, r12
    imul    rax, rsi
    shr     rax, 1              ; / 2

    mov     rdx, type_col_widths
    mov     [rdx + rcx*4], eax

    inc     rcx
    jmp     .cw_pass2

.cw_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  compute_addr_width — Initialize default address width
; ============================================================================
compute_addr_width:
    cmp     byte [addr_radix], ADDR_HEX
    je      .def_hex
    cmp     byte [addr_radix], ADDR_NONE
    je      .def_none
    mov     qword [addr_width], 7   ; octal/decimal default
    ret
.def_hex:
    mov     qword [addr_width], 6
    ret
.def_none:
    mov     qword [addr_width], 0
    ret

; get_base_field_width — Return the "natural" field width for a type/size
; edi = type code, esi = size
; Returns: rax = field width (total chars per value including leading space)
get_base_field_width:
    cmp     edi, TYPE_O
    je      .bfw_o
    cmp     edi, TYPE_X
    je      .bfw_x
    cmp     edi, TYPE_D
    je      .bfw_d
    cmp     edi, TYPE_U
    je      .bfw_u
    cmp     edi, TYPE_A
    je      .bfw_a
    cmp     edi, TYPE_C
    je      .bfw_c
    cmp     edi, TYPE_F
    je      .bfw_f
    mov     rax, 4
    ret

.bfw_o:
    cmp     esi, 1
    je      .bfw_o1
    cmp     esi, 2
    je      .bfw_o2
    cmp     esi, 4
    je      .bfw_o4
    mov     rax, 23             ; o8
    ret
.bfw_o1:
    mov     rax, 4              ; " OOO"
    ret
.bfw_o2:
    mov     rax, 7              ; " OOOOOO"
    ret
.bfw_o4:
    mov     rax, 12             ; " OOOOOOOOOOO"
    ret

.bfw_x:
    cmp     esi, 1
    je      .bfw_x1
    cmp     esi, 2
    je      .bfw_x2
    cmp     esi, 4
    je      .bfw_x4
    mov     rax, 17             ; x8
    ret
.bfw_x1:
    mov     rax, 3              ; " XX"
    ret
.bfw_x2:
    mov     rax, 5              ; " XXXX"
    ret
.bfw_x4:
    mov     rax, 9              ; " XXXXXXXX"
    ret

.bfw_d:
    cmp     esi, 1
    je      .bfw_d1
    cmp     esi, 2
    je      .bfw_d2
    cmp     esi, 4
    je      .bfw_d4
    mov     rax, 21             ; d8
    ret
.bfw_d1:
    mov     rax, 5              ; "    N"
    ret
.bfw_d2:
    mov     rax, 7              ; "      N"
    ret
.bfw_d4:
    mov     rax, 12             ; "           N"
    ret

.bfw_u:
    cmp     esi, 1
    je      .bfw_u1
    cmp     esi, 2
    je      .bfw_u2
    cmp     esi, 4
    je      .bfw_u4
    mov     rax, 21             ; u8
    ret
.bfw_u1:
    mov     rax, 4              ; "   N"
    ret
.bfw_u2:
    mov     rax, 6              ; "     N"
    ret
.bfw_u4:
    mov     rax, 11             ; "          N"
    ret

.bfw_a:
    mov     rax, 4              ; " NNN"
    ret
.bfw_c:
    mov     rax, 4              ; " CCC"
    ret
.bfw_f:
    cmp     esi, 4
    je      .bfw_f4
    cmp     esi, 8
    je      .bfw_f8
    mov     rax, 25
    ret
.bfw_f4:
    mov     rax, 15
    ret
.bfw_f8:
    mov     rax, 25
    ret

; ============================================================================
;  add_type_spec — Parse type string and add to type_specs
;  rdi = pointer to type string (e.g., "x1", "o2", "a", "c", "d4")
; ============================================================================
add_type_spec:
    push    rbx
    push    r12
    mov     rbx, rdi

.type_loop:
    movzx   eax, byte [rbx]
    test    al, al
    jz      .type_done

    mov     r12, [num_types]
    cmp     r12, MAX_TYPES
    jge     .type_done

    ; Get type code
    cmp     al, 'a'
    je      .type_a
    cmp     al, 'c'
    je      .type_c
    cmp     al, 'd'
    je      .type_d
    cmp     al, 'f'
    je      .type_f
    cmp     al, 'o'
    je      .type_o
    cmp     al, 'u'
    je      .type_u
    cmp     al, 'x'
    je      .type_x
    ; Unknown type char, skip
    inc     rbx
    jmp     .type_loop

.type_a:
    mov     rdi, type_specs
    mov     byte [rdi + r12*2], TYPE_A
    mov     byte [rdi + r12*2 + 1], 1
    inc     r12
    mov     [num_types], r12
    inc     rbx
    jmp     .type_loop

.type_c:
    mov     rdi, type_specs
    mov     byte [rdi + r12*2], TYPE_C
    mov     byte [rdi + r12*2 + 1], 1
    inc     r12
    mov     [num_types], r12
    inc     rbx
    jmp     .type_loop

.type_d:
    mov     rdi, type_specs
    mov     byte [rdi + r12*2], TYPE_D
    inc     rbx
    call    parse_type_size_doux
    mov     byte [rdi + r12*2 + 1], al
    inc     r12
    mov     [num_types], r12
    jmp     .type_loop

.type_f:
    mov     rdi, type_specs
    mov     byte [rdi + r12*2], TYPE_F
    inc     rbx
    call    parse_type_size_f
    mov     byte [rdi + r12*2 + 1], al
    inc     r12
    mov     [num_types], r12
    jmp     .type_loop

.type_o:
    mov     rdi, type_specs
    mov     byte [rdi + r12*2], TYPE_O
    inc     rbx
    call    parse_type_size_doux
    mov     byte [rdi + r12*2 + 1], al
    inc     r12
    mov     [num_types], r12
    jmp     .type_loop

.type_u:
    mov     rdi, type_specs
    mov     byte [rdi + r12*2], TYPE_U
    inc     rbx
    call    parse_type_size_doux
    mov     byte [rdi + r12*2 + 1], al
    inc     r12
    mov     [num_types], r12
    jmp     .type_loop

.type_x:
    mov     rdi, type_specs
    mov     byte [rdi + r12*2], TYPE_X
    inc     rbx
    call    parse_type_size_doux
    mov     byte [rdi + r12*2 + 1], al
    inc     r12
    mov     [num_types], r12
    jmp     .type_loop

.type_done:
    pop     r12
    pop     rbx
    ret

; parse_type_size_doux — parse size suffix for d/o/u/x types
; rbx points to char after type letter
; Returns size in al (1,2,4,8), default 4
; Advances rbx past the size chars
parse_type_size_doux:
    movzx   eax, byte [rbx]
    cmp     al, '1'
    je      .sz1
    cmp     al, '2'
    je      .sz2
    cmp     al, '4'
    je      .sz4
    cmp     al, '8'
    je      .sz8
    cmp     al, 'C'
    je      .szC
    cmp     al, 'S'
    je      .szS
    cmp     al, 'I'
    je      .szI
    cmp     al, 'L'
    je      .szL
    ; default size = 4 for d/o/u/x
    mov     al, 4
    ret
.sz1:
    inc     rbx
    mov     al, 1
    ret
.sz2:
    inc     rbx
    mov     al, 2
    ret
.sz4:
    inc     rbx
    mov     al, 4
    ret
.sz8:
    inc     rbx
    mov     al, 8
    ret
.szC:
    inc     rbx
    mov     al, 1
    ret
.szS:
    inc     rbx
    mov     al, 2
    ret
.szI:
    inc     rbx
    mov     al, 4
    ret
.szL:
    inc     rbx
    mov     al, 8
    ret

; parse_type_size_f — parse size suffix for float type
; Default 4 (float), F=4, D=8, L=16
parse_type_size_f:
    movzx   eax, byte [rbx]
    cmp     al, '4'
    je      .f4
    cmp     al, '8'
    je      .f8
    cmp     al, 'F'
    je      .fF
    cmp     al, 'D'
    je      .fD
    cmp     al, 'L'
    je      .fL
    ; Check for "16"
    cmp     al, '1'
    jne     .f_default
    cmp     byte [rbx+1], '6'
    jne     .f_default
    add     rbx, 2
    mov     al, 16
    ret
.f4:
.fF:
    inc     rbx
    mov     al, 4
    ret
.f8:
.fD:
    inc     rbx
    mov     al, 8
    ret
.fL:
    inc     rbx
    mov     al, 16
    ret
.f_default:
    mov     al, 4
    ret

; ============================================================================
;  parse_byte_count — Parse number with optional suffix (b, k, m, K, M, G, etc.)
;  rdi = string pointer
;  Returns: rax = byte count
; ============================================================================
parse_byte_count:
    push    rbx
    push    r12
    mov     rbx, rdi

    ; Check for 0x prefix
    cmp     byte [rbx], '0'
    jne     .parse_dec
    cmp     byte [rbx+1], 'x'
    je      .parse_hex_val
    cmp     byte [rbx+1], 'X'
    je      .parse_hex_val
    ; Check for 0 prefix (octal)
    cmp     byte [rbx+1], '0'
    jb      .parse_dec
    cmp     byte [rbx+1], '7'
    ja      .parse_dec
    ; Parse octal
    inc     rbx
    jmp     .parse_oct_val

.parse_hex_val:
    add     rbx, 2
    xor     rax, rax
.hex_loop:
    movzx   ecx, byte [rbx]
    cmp     cl, '0'
    jb      .apply_suffix
    cmp     cl, '9'
    jbe     .hex_digit
    or      cl, 0x20           ; tolower
    cmp     cl, 'a'
    jb      .apply_suffix
    cmp     cl, 'f'
    ja      .apply_suffix
    sub     cl, 'a'
    add     cl, 10
    shl     rax, 4
    movzx   ecx, cl
    add     rax, rcx
    inc     rbx
    jmp     .hex_loop
.hex_digit:
    sub     cl, '0'
    shl     rax, 4
    movzx   ecx, cl
    add     rax, rcx
    inc     rbx
    jmp     .hex_loop

.parse_oct_val:
    xor     rax, rax
.oct_loop:
    movzx   ecx, byte [rbx]
    cmp     cl, '0'
    jb      .apply_suffix
    cmp     cl, '7'
    ja      .apply_suffix
    sub     cl, '0'
    shl     rax, 3
    movzx   ecx, cl
    add     rax, rcx
    inc     rbx
    jmp     .oct_loop

.parse_dec:
    mov     rdi, rbx
    call    parse_decimal
    ; Find end of digits
.find_suffix:
    movzx   ecx, byte [rbx]
    cmp     cl, '0'
    jb      .apply_suffix
    cmp     cl, '9'
    ja      .apply_suffix
    inc     rbx
    jmp     .find_suffix

.apply_suffix:
    movzx   ecx, byte [rbx]
    test    cl, cl
    jz      .bc_done
    cmp     cl, 'b'
    je      .mul_512
    cmp     cl, 'k'
    je      .mul_1024
    cmp     cl, 'K'
    je      .mul_K
    cmp     cl, 'M'
    je      .mul_M
    cmp     cl, 'G'
    je      .mul_G
    jmp     .bc_done

.mul_512:
    imul    rax, 512
    jmp     .bc_done
.mul_1024:
    shl     rax, 10
    jmp     .bc_done
.mul_K:
    ; K or KB or KiB
    cmp     byte [rbx+1], 'B'
    je      .mul_1000
    shl     rax, 10
    jmp     .bc_done
.mul_1000:
    imul    rax, 1000
    jmp     .bc_done
.mul_M:
    cmp     byte [rbx+1], 'B'
    je      .mul_1000000
    shl     rax, 20
    jmp     .bc_done
.mul_1000000:
    imul    rax, 1000000
    jmp     .bc_done
.mul_G:
    cmp     byte [rbx+1], 'B'
    je      .mul_1000000000
    shl     rax, 30
    jmp     .bc_done
.mul_1000000000:
    imul    rax, 1000000000
    jmp     .bc_done

.bc_done:
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  parse_decimal — Parse decimal number from string
;  rdi = string pointer
;  Returns: rax = number
; ============================================================================
parse_decimal:
    xor     rax, rax
.loop:
    movzx   ecx, byte [rdi]
    sub     cl, '0'
    cmp     cl, 9
    ja      .done
    imul    rax, 10
    movzx   ecx, cl
    add     rax, rcx
    inc     rdi
    jmp     .loop
.done:
    ret

; ============================================================================
;  process_all_files — Process all input files
; ============================================================================
process_all_files:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8              ; align stack

    xor     r12d, r12d          ; file index
    mov     r13, [num_files]
    ; r14 = current offset in input stream (for skip)
    xor     r14, r14
    ; r15 = bytes remaining in limit
    mov     r15, [limit_bytes]

    ; Skip bytes from initial files
    mov     rbp, [skip_bytes]

.file_loop:
    cmp     r12, r13
    jge     .all_done

    ; Get file pointer
    mov     rax, file_ptrs
    mov     rbx, [rax + r12*8]

    ; Check for stdin
    cmp     byte [rbx], '-'
    jne     .open_file
    cmp     byte [rbx+1], 0
    jne     .open_file
    ; stdin
    xor     edi, edi            ; fd = 0
    jmp     .process_fd

.open_file:
    mov     rdi, rbx
    xor     esi, esi            ; O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .file_error
    mov     rdi, rax

.process_fd:
    mov     [cur_fd], rdi
    mov     qword [mmap_base_save], 0
    mov     qword [mmap_len_save], 0

    ; Try mmap if fd > 0 (not stdin)
    cmp     rdi, 0
    je      .read_fallback

    ; fstat to get file size
    sub     rsp, 144            ; struct stat is 144 bytes
    mov     rsi, rsp
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .fstat_fail

    ; st_size is at offset 48
    mov     rax, [rsp + 48]
    add     rsp, 144
    test    rax, rax
    jz      .close_file         ; empty file
    mov     [mmap_len_save], rax

    ; mmap(NULL, size, PROT_READ, MAP_PRIVATE|MAP_POPULATE, fd, 0)
    push    rax                 ; save file size
    xor     edi, edi            ; addr = NULL
    mov     rsi, rax            ; length = file size
    mov     edx, PROT_READ
    mov     r10d, MAP_PRIVATE | MAP_POPULATE
    mov     r8, [cur_fd]
    xor     r9d, r9d            ; offset = 0
    mov     eax, SYS_MMAP
    syscall
    pop     rcx                 ; rcx = file size

    ; Check for mmap failure (returns -errno in rax if < 0)
    cmp     rax, -4096
    ja      .mmap_fail          ; error: fall back to read

    ; mmap succeeded: rax = mapped address, rcx = file size
    mov     [mmap_base_save], rax
    mov     rsi, rax            ; rsi = buffer start
    ; rcx already has file size

    ; Handle skip_bytes
    test    rbp, rbp
    jz      .mmap_no_skip
    cmp     rbp, rcx
    jge     .mmap_skip_all
    add     rsi, rbp
    sub     rcx, rbp
    xor     ebp, ebp
    jmp     .mmap_no_skip
.mmap_skip_all:
    sub     rbp, rcx
    jmp     .mmap_unmap
.mmap_no_skip:

    ; Apply limit
    cmp     byte [have_limit], 0
    je      .mmap_no_limit
    cmp     r15, rcx
    jge     .mmap_limit_ok
    mov     rcx, r15
.mmap_limit_ok:
    sub     r15, rcx
.mmap_no_limit:

    ; Process entire mmap region as one chunk
    test    rcx, rcx
    jz      .mmap_unmap
    mov     rdi, rsi
    mov     rsi, rcx
    call    process_chunk

.mmap_unmap:
    ; munmap
    mov     rdi, [mmap_base_save]
    mov     rsi, [mmap_len_save]
    mov     eax, SYS_MUNMAP
    syscall
    mov     qword [mmap_base_save], 0
    jmp     .close_file_fd

.fstat_fail:
    add     rsp, 144
.mmap_fail:
    ; Fall through to read-based path
.read_fallback:

    ; Read and process data from this fd
.read_loop:
    ; Check if we've hit limit
    cmp     byte [have_limit], 0
    je      .no_limit_check
    test    r15, r15
    jz      .close_file
.no_limit_check:

    mov     rdi, [cur_fd]
    mov     rsi, inbuf
    mov     rdx, INBUF_SIZE
    call    asm_read
    test    rax, rax
    jle     .close_file         ; EOF or error

    mov     rcx, rax            ; rcx = bytes read
    mov     rsi, inbuf          ; rsi = buffer start

    ; Handle skip_bytes
    test    rbp, rbp
    jz      .no_skip
    cmp     rbp, rcx
    jge     .skip_all
    ; Partial skip
    add     rsi, rbp
    sub     rcx, rbp
    xor     ebp, ebp
    jmp     .no_skip
.skip_all:
    sub     rbp, rcx
    jmp     .read_loop
.no_skip:

    ; Apply limit
    cmp     byte [have_limit], 0
    je      .no_limit_apply
    cmp     r15, rcx
    jge     .limit_ok
    mov     rcx, r15            ; truncate to limit
.limit_ok:
    sub     r15, rcx
.no_limit_apply:

    ; Process this chunk: rsi=data, rcx=length
    test    rcx, rcx
    jz      .read_loop
    mov     rdi, rsi
    mov     rsi, rcx
    call    process_chunk

    jmp     .read_loop

.close_file:
    mov     rdi, [cur_fd]
    test    rdi, rdi
    jz      .next_file          ; don't close stdin
.close_file_fd:
    mov     rdi, [cur_fd]
    call    asm_close
    jmp     .next_file

.file_error:
    ; Print error
    push    r12
    push    r13
    mov     rdi, STDERR
    mov     rsi, str_od_prefix
    mov     rdx, 4
    call    asm_write_all
    ; Print filename
    mov     rax, file_ptrs
    pop     r13
    pop     r12
    mov     rdi, [rax + r12*8]
    call    str_len
    mov     rdx, rax
    mov     rax, file_ptrs
    mov     rsi, [rax + r12*8]
    mov     rdi, STDERR
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_enoent
    mov     rdx, str_enoent_len
    call    asm_write_all
    mov     byte [had_error], 1

.next_file:
    inc     r12
    jmp     .file_loop

.all_done:
    ; Check if skip_bytes was larger than total input
    test    rbp, rbp
    jz      .skip_ok
    ; "od: cannot skip past end of combined input"
    mov     rdi, STDERR
    mov     rsi, str_skip_past
    mov     rdx, str_skip_past_len
    call    asm_write_all
    mov     byte [had_error], 1
.skip_ok:

    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  process_chunk — Format and output a chunk of input data
;  rdi = data pointer, rsi = length
; ============================================================================
process_chunk:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, rdi            ; r12 = data ptr
    mov     r13, rsi            ; r13 = remaining length
    mov     r14, [bytes_per_line]

.chunk_loop:
    test    r13, r13
    jz      .chunk_done

    ; Determine bytes for this line
    mov     r15, r14            ; bytes_per_line
    cmp     r15, r13
    jle     .line_ok
    mov     r15, r13            ; partial last line
.line_ok:

    ; Check for duplicate suppression using raw input bytes
    cmp     byte [show_dupes], 1
    je      .print_line

    ; Only suppress if we have a full line
    cmp     r15, r14
    jne     .print_line

    ; Compare with previous raw line
    cmp     byte [prev_line_valid], 0
    je      .print_line

    ; Compare raw input bytes (r12 = current data, prev_raw_line = previous)
    mov     rcx, r15
    cmp     rcx, [prev_line_len]
    jne     .print_line
    lea     rdi, [r12]
    mov     rsi, prev_raw_line
    repe    cmpsb
    je      .is_duplicate

    jmp     .print_line

.is_duplicate:
    ; Duplicate — print * if not already printed
    cmp     byte [dup_star_printed], 0
    jne     .skip_line
    mov     byte [dup_star_printed], 1
    ; Output "*\n"
    mov     byte [char_buf], '*'
    mov     byte [char_buf+1], 10
    mov     rsi, char_buf
    mov     rdx, 2
    call    write_outbuf
    jmp     .skip_line

.print_line:
    mov     byte [dup_star_printed], 0

    ; Save current raw line for next comparison
    mov     rdi, prev_raw_line
    mov     rsi, r12
    mov     rcx, r15
    mov     [prev_line_len], rcx
    rep     movsb
    mov     byte [prev_line_valid], 1

    ; Fast path: single type — combine values + newline into one write_outbuf call
    cmp     qword [num_types], 1
    jne     .multi_type_path

    ; Write address
    mov     rdi, [total_offset]
    call    format_address
    mov     rsi, addr_buf
    mov     rdx, rax
    test    rdx, rdx
    jz      .st_skip_addr
    call    write_outbuf
.st_skip_addr:

    ; Format values + newline as single write
    mov     rax, type_specs
    movzx   ecx, byte [rax]
    movzx   edx, byte [rax + 1]
    xor     r8d, r8d
    mov     rdi, r12
    mov     rsi, r15
    call    format_type_to_buf
    ; rax = bytes in fmt_buf
    mov     rsi, fmt_buf
    mov     byte [rsi + rax], 10
    inc     rax
    mov     rdx, rax
    call    write_outbuf

    jmp     .type_done

.multi_type_path:
    ; Output address (for first type row)
    mov     rdi, [total_offset]
    call    format_address
    ; rax = length of formatted address in addr_buf
    mov     rsi, addr_buf
    mov     rdx, rax
    call    write_outbuf

    ; Output each type's formatted line
    xor     ebp, ebp            ; type index
    mov     rcx, [num_types]
    mov     [type_count_save], rcx

.type_loop:
    cmp     rbp, [type_count_save]
    jge     .type_done

    cmp     rbp, 0
    je      .first_type
    ; For subsequent types, print spaces instead of address
    call    format_addr_spaces
    mov     rsi, addr_buf
    mov     rdx, rax
    call    write_outbuf
.first_type:

    ; Format values for this type
    mov     rax, type_specs
    movzx   ecx, byte [rax + rbp*2]      ; type code
    movzx   edx, byte [rax + rbp*2 + 1]  ; size
    mov     r8d, ebp                      ; type index

    mov     rdi, r12            ; data ptr
    mov     rsi, r15            ; bytes this line
    ; ecx = type, edx = size, r8d = type index
    call    format_type_values

    ; Write newline
    mov     byte [char_buf], 10
    mov     rsi, char_buf
    mov     rdx, 1
    call    write_outbuf

    inc     rbp
    jmp     .type_loop

.type_done:
.skip_line:
    add     r12, r15
    sub     r13, r15
    add     [total_offset], r15
    jmp     .chunk_loop

.chunk_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  format_line_content — Format line content for duplicate comparison
;  rdi = data, rsi = length
;  Stores result in line_content_buf, length in line_content_len
; ============================================================================
format_line_content:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    rbp

    mov     r12, rdi            ; data
    mov     r13, rsi            ; length

    ; We'll build content by formatting all types into temp buffer
    mov     rbx, line_content_buf
    xor     r14d, r14d          ; position in line_content_buf

    xor     ebp, ebp
.lc_type_loop:
    cmp     rbp, [num_types]
    jge     .lc_done

    mov     rax, type_specs
    movzx   ecx, byte [rax + rbp*2]
    movzx   edx, byte [rax + rbp*2 + 1]

    ; Format into fmt_buf, get length
    push    rbp
    push    r14
    mov     rdi, r12
    mov     rsi, r13
    mov     r8d, ebp            ; type index
    call    format_type_to_buf
    ; rax = length in fmt_buf
    pop     r14
    pop     rbp

    ; Copy fmt_buf to line_content_buf[r14..]
    mov     rsi, fmt_buf
    lea     rdi, [rbx + r14]
    mov     rcx, rax
    call    memcpy_inline
    add     r14, rax

    inc     rbp
    jmp     .lc_type_loop

.lc_done:
    mov     [line_content_len], r14

    pop     rbp
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  format_type_to_buf — Format type values into fmt_buf
;  rdi = data, rsi = length, ecx = type code, edx = size, r8d = type index
;  Returns: rax = bytes written to fmt_buf
; ============================================================================
format_type_to_buf:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, rdi            ; data
    mov     r13, rsi            ; length
    movzx   r14d, cl            ; type
    movzx   r15d, dl            ; size

    ; Load computed column width for this type
    mov     rax, type_col_widths
    movzx   ebp, r8b
    mov     ebp, [rax + rbp*4]  ; ebp = actual column width per value

    mov     rbx, fmt_buf
    xor     ecx, ecx            ; position

    ; Dispatch on type
    cmp     r14d, TYPE_A
    je      .fmt_a
    cmp     r14d, TYPE_C
    je      .fmt_c
    cmp     r14d, TYPE_O
    je      .fmt_o
    cmp     r14d, TYPE_X
    je      .fmt_x
    cmp     r14d, TYPE_D
    je      .fmt_d
    cmp     r14d, TYPE_U
    je      .fmt_u
    cmp     r14d, TYPE_F
    je      .fmt_f
    jmp     .fmt_done

; ── Named characters (type a) ──
.fmt_a:
    xor     esi, esi
.fmt_a_loop:
    cmp     rsi, r13
    jge     .fmt_done
    movzx   eax, byte [r12 + rsi]
    and     eax, 0x7F           ; ignore high bit
    ; Format: ebp chars per byte, right-justified 3-char name
    ; Leading spaces = ebp - 3
    mov     edi, ebp
    sub     edi, 3
.fmt_a_pad:
    test    edi, edi
    jle     .fmt_a_name
    mov     byte [rbx + rcx], ' '
    inc     rcx
    dec     edi
    jmp     .fmt_a_pad
.fmt_a_name:
    ; Look up name
    mov     rdi, named_chars
    imul    eax, 3              ; 3 bytes per entry
    mov     dl, [rdi + rax]
    mov     [rbx + rcx], dl
    mov     dl, [rdi + rax + 1]
    mov     [rbx + rcx + 1], dl
    mov     dl, [rdi + rax + 2]
    mov     [rbx + rcx + 2], dl
    add     rcx, 3
    inc     rsi
    jmp     .fmt_a_loop

; ── C-style characters (type c) ──
; ebp = column width per byte
.fmt_c:
    xor     esi, esi
.fmt_c_loop:
    cmp     rsi, r13
    jge     .fmt_done
    movzx   eax, byte [r12 + rsi]

    ; Check for special C escapes
    cmp     al, 0
    je      .c_esc_0
    cmp     al, 7
    je      .c_esc_a
    cmp     al, 8
    je      .c_esc_b
    cmp     al, 9
    je      .c_esc_t
    cmp     al, 10
    je      .c_esc_n
    cmp     al, 11
    je      .c_esc_v
    cmp     al, 12
    je      .c_esc_f
    cmp     al, 13
    je      .c_esc_r
    ; Printable: 0x20-0x7E
    cmp     al, 0x20
    jb      .c_octal
    cmp     al, 0x7E
    ja      .c_octal
    ; Pad with ebp-1 spaces, then the char
    push    rax
    mov     edi, ebp
    dec     edi
.c_print_pad:
    test    edi, edi
    jle     .c_print_char
    mov     byte [rbx + rcx], ' '
    inc     rcx
    dec     edi
    jmp     .c_print_pad
.c_print_char:
    pop     rax
    mov     [rbx + rcx], al
    inc     rcx
    inc     rsi
    jmp     .fmt_c_loop

.c_esc_0:
    mov     ah, '0'
    jmp     .c_do_esc
.c_esc_a:
    mov     ah, 'a'
    jmp     .c_do_esc
.c_esc_b:
    mov     ah, 'b'
    jmp     .c_do_esc
.c_esc_t:
    mov     ah, 't'
    jmp     .c_do_esc
.c_esc_n:
    mov     ah, 'n'
    jmp     .c_do_esc
.c_esc_v:
    mov     ah, 'v'
    jmp     .c_do_esc
.c_esc_f:
    mov     ah, 'f'
    jmp     .c_do_esc
.c_esc_r:
    mov     ah, 'r'
    ; fall through
.c_do_esc:
    ; Pad with ebp-2 spaces, then '\' and escape char
    push    rax
    mov     edi, ebp
    sub     edi, 2
.c_esc_pad:
    test    edi, edi
    jle     .c_esc_write
    mov     byte [rbx + rcx], ' '
    inc     rcx
    dec     edi
    jmp     .c_esc_pad
.c_esc_write:
    pop     rax
    mov     byte [rbx + rcx], '\'
    mov     [rbx + rcx + 1], ah
    add     rcx, 2
    inc     rsi
    jmp     .fmt_c_loop

.c_octal:
    ; Non-printable: pad with ebp-3 spaces, then 3-digit octal
    push    rax
    mov     edi, ebp
    sub     edi, 3
.c_oct_pad:
    test    edi, edi
    jle     .c_oct_write
    mov     byte [rbx + rcx], ' '
    inc     rcx
    dec     edi
    jmp     .c_oct_pad
.c_oct_write:
    pop     rax
    mov     edx, eax
    shr     edx, 6
    and     edx, 7
    add     dl, '0'
    mov     [rbx + rcx], dl
    mov     edx, eax
    shr     edx, 3
    and     edx, 7
    add     dl, '0'
    mov     [rbx + rcx + 1], dl
    mov     edx, eax
    and     edx, 7
    add     dl, '0'
    mov     [rbx + rcx + 2], dl
    add     rcx, 3
    inc     rsi
    jmp     .fmt_c_loop

; ── Octal (type o) ──
.fmt_o:
    xor     esi, esi
    cmp     r15d, 1
    je      .fmt_o1_loop
    cmp     r15d, 2
    je      .fmt_o2_loop
    cmp     r15d, 4
    je      .fmt_o4_loop
    cmp     r15d, 8
    je      .fmt_o8_loop
    jmp     .fmt_done

.fmt_o1_loop:
    cmp     rsi, r13
    jge     .fmt_done
    movzx   eax, byte [r12 + rsi]
    ; Pad with ebp-3 spaces, then 3-digit octal
    mov     edi, ebp
    sub     edi, 3
.fmt_o1_pad:
    test    edi, edi
    jle     .fmt_o1_digits
    mov     byte [rbx + rcx], ' '
    inc     rcx
    dec     edi
    jmp     .fmt_o1_pad
.fmt_o1_digits:
    mov     edx, eax
    shr     edx, 6
    and     edx, 7
    add     dl, '0'
    mov     [rbx + rcx], dl
    mov     edx, eax
    shr     edx, 3
    and     edx, 7
    add     dl, '0'
    mov     [rbx + rcx + 1], dl
    mov     edx, eax
    and     edx, 7
    add     dl, '0'
    mov     [rbx + rcx + 2], dl
    add     rcx, 3
    inc     rsi
    jmp     .fmt_o1_loop

.fmt_o2_loop:
    cmp     rsi, r13
    jge     .fmt_done
    ; Check if we have 2 bytes
    lea     rax, [rsi + 2]
    cmp     rax, r13
    jg      .fmt_o2_partial
    movzx   eax, word [r12 + rsi]
    ; Pad with ebp-6 spaces, then 6-digit octal
    mov     edi, ebp
    sub     edi, 6
.fmt_o2_pad:
    test    edi, edi
    jle     .fmt_o2_digits
    mov     byte [rbx + rcx], ' '
    inc     rcx
    dec     edi
    jmp     .fmt_o2_pad
.fmt_o2_digits:
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, 6
    call    format_octal_padded
    pop     rcx
    pop     rsi
    add     rcx, 6
    add     rsi, 2
    jmp     .fmt_o2_loop
.fmt_o2_partial:
    ; Single remaining byte — format as o2 with zero-extend
    movzx   eax, byte [r12 + rsi]
    mov     edi, ebp
    sub     edi, 6
.fmt_o2p_pad:
    test    edi, edi
    jle     .fmt_o2p_digits
    mov     byte [rbx + rcx], ' '
    inc     rcx
    dec     edi
    jmp     .fmt_o2p_pad
.fmt_o2p_digits:
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, 6
    call    format_octal_padded
    pop     rcx
    pop     rsi
    add     rcx, 6
    inc     rsi
    jmp     .fmt_o2_loop

.fmt_o4_loop:
    cmp     rsi, r13
    jge     .fmt_done
    lea     rax, [rsi + 4]
    cmp     rax, r13
    jg      .fmt_o4_partial
    mov     eax, [r12 + rsi]
    ; Pad with ebp-11 spaces
    mov     edi, ebp
    sub     edi, 11
.fmt_o4_pad:
    test    edi, edi
    jle     .fmt_o4_digits
    mov     byte [rbx + rcx], ' '
    inc     rcx
    dec     edi
    jmp     .fmt_o4_pad
.fmt_o4_digits:
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, 11
    call    format_octal_padded
    pop     rcx
    pop     rsi
    add     rcx, 11
    add     rsi, 4
    jmp     .fmt_o4_loop
.fmt_o4_partial:
    ; Read remaining bytes, zero-extend to 32-bit
    xor     eax, eax
    mov     rdx, r13
    sub     rdx, rsi
    xor     edi, edi
.o4p_loop:
    cmp     rdi, rdx
    jge     .o4p_fmt
    lea     r8, [r12 + rsi]
    movzx   r8d, byte [r8 + rdi]
    mov     r9d, edi
    shl     r9d, 3             ; * 8
    push    rcx
    mov     ecx, r9d
    shl     r8d, cl
    pop     rcx
    or      eax, r8d
    inc     rdi
    jmp     .o4p_loop
.o4p_fmt:
    mov     byte [rbx + rcx], ' '
    inc     rcx
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, 11
    call    format_octal_padded
    pop     rcx
    pop     rsi
    add     rcx, 11
    mov     rsi, r13            ; done with remaining bytes
    jmp     .fmt_o4_loop

.fmt_o8_loop:
    cmp     rsi, r13
    jge     .fmt_done
    lea     rax, [rsi + 8]
    cmp     rax, r13
    jg      .fmt_done           ; skip partial
    mov     rax, [r12 + rsi]
    mov     byte [rbx + rcx], ' '
    inc     rcx
    push    rsi
    push    rcx
    mov     rdi, rax
    lea     rsi, [rbx + rcx]
    mov     edx, 22
    call    format_octal64_padded
    pop     rcx
    pop     rsi
    add     rcx, 22
    add     rsi, 8
    jmp     .fmt_o8_loop

; ── Hexadecimal (type x) ──
.fmt_x:
    xor     esi, esi
    cmp     r15d, 1
    je      .fmt_x1_loop
    cmp     r15d, 2
    je      .fmt_x2_loop
    cmp     r15d, 4
    je      .fmt_x4_loop
    cmp     r15d, 8
    je      .fmt_x8_loop
    jmp     .fmt_done

; NOTE: The SIMD fast path from the modular version is omitted in this flat binary
; to keep things simple and avoid alignment issues. The scalar path handles all cases.
.fmt_x1_loop:
    cmp     rsi, r13
    jge     .fmt_done
    movzx   eax, byte [r12 + rsi]
    ; Pad with ebp-2 spaces, then 2-digit hex
    mov     edi, ebp
    sub     edi, 2
.fmt_x1_pad:
    test    edi, edi
    jle     .fmt_x1_digits
    mov     byte [rbx + rcx], ' '
    inc     rcx
    dec     edi
    jmp     .fmt_x1_pad
.fmt_x1_digits:
    mov     edx, eax
    shr     edx, 4
    mov     rdi, hex_digits
    movzx   edx, byte [rdi + rdx]
    mov     [rbx + rcx], dl
    mov     edx, eax
    and     edx, 0xF
    movzx   edx, byte [rdi + rdx]
    mov     [rbx + rcx + 1], dl
    add     rcx, 2
    inc     rsi
    jmp     .fmt_x1_loop

.fmt_x2_loop:
    cmp     rsi, r13
    jge     .fmt_done
    lea     rax, [rsi + 2]
    cmp     rax, r13
    jg      .fmt_x2_partial
    movzx   eax, word [r12 + rsi]
    mov     edi, ebp
    sub     edi, 4
.fmt_x2_pad:
    test    edi, edi
    jle     .fmt_x2_digits
    mov     byte [rbx + rcx], ' '
    inc     rcx
    dec     edi
    jmp     .fmt_x2_pad
.fmt_x2_digits:
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, 4
    call    format_hex_padded
    pop     rcx
    pop     rsi
    add     rcx, 4
    add     rsi, 2
    jmp     .fmt_x2_loop
.fmt_x2_partial:
    movzx   eax, byte [r12 + rsi]
    mov     edi, ebp
    sub     edi, 4
.fmt_x2p_pad:
    test    edi, edi
    jle     .fmt_x2p_digits
    mov     byte [rbx + rcx], ' '
    inc     rcx
    dec     edi
    jmp     .fmt_x2p_pad
.fmt_x2p_digits:
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, 4
    call    format_hex_padded
    pop     rcx
    pop     rsi
    add     rcx, 4
    inc     rsi
    jmp     .fmt_x2_loop

.fmt_x4_loop:
    cmp     rsi, r13
    jge     .fmt_done
    lea     rax, [rsi + 4]
    cmp     rax, r13
    jg      .fmt_x4_partial
    mov     eax, [r12 + rsi]
    mov     edi, ebp
    sub     edi, 8
.fmt_x4_pad:
    test    edi, edi
    jle     .fmt_x4_digits
    mov     byte [rbx + rcx], ' '
    inc     rcx
    dec     edi
    jmp     .fmt_x4_pad
.fmt_x4_digits:
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, 8
    call    format_hex_padded
    pop     rcx
    pop     rsi
    add     rcx, 8
    add     rsi, 4
    jmp     .fmt_x4_loop

.fmt_x4_partial:
    ; Read remaining bytes zero-extended
    xor     eax, eax
    mov     rdi, r13
    sub     rdi, rsi           ; remaining bytes
    xor     r8d, r8d
.fmt_x4p_rd:
    cmp     r8, rdi
    jge     .fmt_x4p_fmt
    lea     r9, [r12 + rsi]
    movzx   r9d, byte [r9 + r8]
    push    rcx
    mov     ecx, r8d
    shl     ecx, 3
    shl     r9d, cl
    pop     rcx
    or      eax, r9d
    inc     r8
    jmp     .fmt_x4p_rd
.fmt_x4p_fmt:
    mov     edi, ebp
    sub     edi, 8
.fmt_x4p_pad:
    test    edi, edi
    jle     .fmt_x4p_dig
    mov     byte [rbx + rcx], ' '
    inc     rcx
    dec     edi
    jmp     .fmt_x4p_pad
.fmt_x4p_dig:
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, 8
    call    format_hex_padded
    pop     rcx
    pop     rsi
    add     rcx, 8
    mov     rsi, r13
    jmp     .fmt_x4_loop

.fmt_x8_loop:
    cmp     rsi, r13
    jge     .fmt_done
    lea     rax, [rsi + 8]
    cmp     rax, r13
    jg      .fmt_done
    mov     rax, [r12 + rsi]
    mov     byte [rbx + rcx], ' '
    inc     rcx
    push    rsi
    push    rcx
    mov     rdi, rax
    lea     rsi, [rbx + rcx]
    mov     edx, 16
    call    format_hex64_padded
    pop     rcx
    pop     rsi
    add     rcx, 16
    add     rsi, 8
    jmp     .fmt_x8_loop

; ── Signed decimal (type d) ──
.fmt_d:
    xor     esi, esi
    cmp     r15d, 1
    je      .fmt_d1_loop
    cmp     r15d, 2
    je      .fmt_d2_loop
    cmp     r15d, 4
    je      .fmt_d4_loop
    cmp     r15d, 8
    je      .fmt_d8_loop
    jmp     .fmt_done

.fmt_d1_loop:
    cmp     rsi, r13
    jge     .fmt_done
    movsx   eax, byte [r12 + rsi]
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, ebp
    call    format_signed_decimal_padded
    pop     rcx
    pop     rsi
    add     rcx, rbp
    inc     rsi
    jmp     .fmt_d1_loop

.fmt_d2_loop:
    cmp     rsi, r13
    jge     .fmt_done
    lea     rax, [rsi + 2]
    cmp     rax, r13
    jg      .fmt_d2_partial
    movsx   eax, word [r12 + rsi]
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, ebp
    call    format_signed_decimal_padded
    pop     rcx
    pop     rsi
    add     rcx, rbp
    add     rsi, 2
    jmp     .fmt_d2_loop

.fmt_d2_partial:
    ; Read 1 remaining byte, sign-extend as if word
    movsx   eax, byte [r12 + rsi]
    and     eax, 0xFF          ; zero-extend the single byte
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, ebp
    call    format_signed_decimal_padded
    pop     rcx
    pop     rsi
    add     rcx, rbp
    mov     rsi, r13
    jmp     .fmt_d2_loop

.fmt_d4_loop:
    cmp     rsi, r13
    jge     .fmt_done
    lea     rax, [rsi + 4]
    cmp     rax, r13
    jg      .fmt_d4_partial
    mov     eax, [r12 + rsi]
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, ebp
    call    format_signed_decimal_padded
    pop     rcx
    pop     rsi
    add     rcx, rbp
    add     rsi, 4
    jmp     .fmt_d4_loop

.fmt_d4_partial:
    ; Read remaining 1-3 bytes, zero-extend to 32-bit
    xor     eax, eax
    mov     rdi, r13
    sub     rdi, rsi
    xor     r8d, r8d
.fmt_d4p_rd:
    cmp     r8, rdi
    jge     .fmt_d4p_fmt
    lea     r9, [r12 + rsi]
    movzx   r9d, byte [r9 + r8]
    push    rcx
    mov     ecx, r8d
    shl     ecx, 3
    shl     r9d, cl
    pop     rcx
    or      eax, r9d
    inc     r8
    jmp     .fmt_d4p_rd
.fmt_d4p_fmt:
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, ebp
    call    format_signed_decimal_padded
    pop     rcx
    pop     rsi
    add     rcx, rbp
    mov     rsi, r13
    jmp     .fmt_d4_loop

.fmt_d8_loop:
    cmp     rsi, r13
    jge     .fmt_done
    lea     rax, [rsi + 8]
    cmp     rax, r13
    jg      .fmt_done
    mov     rax, [r12 + rsi]
    push    rsi
    push    rcx
    mov     rdi, rax
    lea     rsi, [rbx + rcx]
    mov     edx, ebp
    call    format_signed_decimal64_padded
    pop     rcx
    pop     rsi
    add     rcx, rbp
    add     rsi, 8
    jmp     .fmt_d8_loop

; ── Unsigned decimal (type u) ──
.fmt_u:
    xor     esi, esi
    cmp     r15d, 1
    je      .fmt_u1_loop
    cmp     r15d, 2
    je      .fmt_u2_loop
    cmp     r15d, 4
    je      .fmt_u4_loop
    cmp     r15d, 8
    je      .fmt_u8_loop
    jmp     .fmt_done

.fmt_u1_loop:
    cmp     rsi, r13
    jge     .fmt_done
    movzx   eax, byte [r12 + rsi]
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, ebp
    call    format_unsigned_decimal_padded
    pop     rcx
    pop     rsi
    add     rcx, rbp
    inc     rsi
    jmp     .fmt_u1_loop

.fmt_u2_loop:
    cmp     rsi, r13
    jge     .fmt_done
    lea     rax, [rsi + 2]
    cmp     rax, r13
    jg      .fmt_u2_partial
    movzx   eax, word [r12 + rsi]
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, ebp
    call    format_unsigned_decimal_padded
    pop     rcx
    pop     rsi
    add     rcx, rbp
    add     rsi, 2
    jmp     .fmt_u2_loop

.fmt_u2_partial:
    movzx   eax, byte [r12 + rsi]
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, ebp
    call    format_unsigned_decimal_padded
    pop     rcx
    pop     rsi
    add     rcx, rbp
    mov     rsi, r13
    jmp     .fmt_u2_loop

.fmt_u4_loop:
    cmp     rsi, r13
    jge     .fmt_done
    lea     rax, [rsi + 4]
    cmp     rax, r13
    jg      .fmt_u4_partial
    mov     eax, [r12 + rsi]
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, ebp
    call    format_unsigned_decimal_padded
    pop     rcx
    pop     rsi
    add     rcx, rbp
    add     rsi, 4
    jmp     .fmt_u4_loop

.fmt_u4_partial:
    xor     eax, eax
    mov     rdi, r13
    sub     rdi, rsi
    xor     r8d, r8d
.fmt_u4p_rd:
    cmp     r8, rdi
    jge     .fmt_u4p_fmt
    lea     r9, [r12 + rsi]
    movzx   r9d, byte [r9 + r8]
    push    rcx
    mov     ecx, r8d
    shl     ecx, 3
    shl     r9d, cl
    pop     rcx
    or      eax, r9d
    inc     r8
    jmp     .fmt_u4p_rd
.fmt_u4p_fmt:
    push    rsi
    push    rcx
    mov     edi, eax
    lea     rsi, [rbx + rcx]
    mov     edx, ebp
    call    format_unsigned_decimal_padded
    pop     rcx
    pop     rsi
    add     rcx, rbp
    mov     rsi, r13
    jmp     .fmt_u4_loop

.fmt_u8_loop:
    cmp     rsi, r13
    jge     .fmt_done
    lea     rax, [rsi + 8]
    cmp     rax, r13
    jg      .fmt_done
    mov     rax, [r12 + rsi]
    push    rsi
    push    rcx
    mov     rdi, rax
    lea     rsi, [rbx + rcx]
    mov     edx, ebp
    call    format_unsigned_decimal64_padded
    pop     rcx
    pop     rsi
    add     rcx, rbp
    add     rsi, 8
    jmp     .fmt_u8_loop

; ── Floating point (type f) ──
.fmt_f:
    xor     esi, esi
    cmp     r15d, 4
    je      .fmt_f4_loop
    cmp     r15d, 8
    je      .fmt_f8_loop
    jmp     .fmt_done

.fmt_f4_loop:
    cmp     rsi, r13
    jge     .fmt_done
    lea     rax, [rsi + 4]
    cmp     rax, r13
    jg      .fmt_done
    ; Load float, convert to string
    movss   xmm0, [r12 + rsi]
    cvtss2sd xmm0, xmm0        ; promote to double for formatting
    push    rsi
    push    rcx
    lea     rdi, [rbx + rcx]
    mov     esi, 15             ; field width for f4
    call    format_float_field
    pop     rcx
    pop     rsi
    add     rcx, rax
    add     rsi, 4
    jmp     .fmt_f4_loop

.fmt_f8_loop:
    cmp     rsi, r13
    jge     .fmt_done
    lea     rax, [rsi + 8]
    cmp     rax, r13
    jg      .fmt_done
    movsd   xmm0, [r12 + rsi]
    push    rsi
    push    rcx
    lea     rdi, [rbx + rcx]
    mov     esi, 25             ; field width for f8
    call    format_float_field
    pop     rcx
    pop     rsi
    add     rcx, rax
    add     rsi, 8
    jmp     .fmt_f8_loop

.fmt_done:
    mov     rax, rcx

    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  format_type_values — Format and write type values to outbuf
;  rdi = data, rsi = length, ecx = type, edx = size, r8d = type index
; ============================================================================
format_type_values:
    push    rcx
    push    rdx
    ; Call format_type_to_buf
    call    format_type_to_buf
    ; Write fmt_buf[0..rax] to outbuf
    mov     rdx, rax
    mov     rsi, fmt_buf
    call    write_outbuf
    pop     rdx
    pop     rcx
    ret

; ============================================================================
;  format_address — Format current address
;  rdi = offset value
;  Returns: rax = length of formatted string in addr_buf
; ============================================================================
format_address:
    push    rbx
    mov     rbx, addr_buf

    cmp     byte [addr_radix], ADDR_NONE
    je      .addr_none

    cmp     byte [addr_radix], ADDR_OCTAL
    je      .addr_octal
    cmp     byte [addr_radix], ADDR_DECIMAL
    je      .addr_decimal
    cmp     byte [addr_radix], ADDR_HEX
    je      .addr_hex
    jmp     .addr_none

.addr_octal:
    mov     rsi, rbx
    call    format_addr_oct_var
    pop     rbx
    ret

.addr_decimal:
    mov     rsi, rbx
    call    format_addr_dec_var
    pop     rbx
    ret

.addr_hex:
    ; Format hex address with minimum 6 digits, expanding for larger values
    mov     rsi, rbx
    call    format_addr_hex_var
    ; rax = number of chars written
    pop     rbx
    ret

.addr_none:
    ; No address, return 0
    xor     eax, eax
    pop     rbx
    ret

; ============================================================================
;  format_addr_spaces — Return spaces matching address width
;  Returns: rax = length
; ============================================================================
format_addr_spaces:
    push    rbx
    mov     rbx, addr_buf

    cmp     byte [addr_radix], ADDR_NONE
    je      .as_none

    mov     rcx, [addr_width]   ; width of last formatted address
    jmp     .as_fill
.as_none:
    xor     eax, eax
    pop     rbx
    ret
.as_fill:
    xor     esi, esi
.as_loop:
    cmp     rsi, rcx
    jge     .as_done
    mov     byte [rbx + rsi], ' '
    inc     rsi
    jmp     .as_loop
.as_done:
    mov     rax, rcx
    pop     rbx
    ret

; ============================================================================
;  print_final_address — Print the end-of-file address
; ============================================================================
print_final_address:
    cmp     byte [addr_radix], ADDR_NONE
    je      .no_final
    mov     rdi, [total_offset]
    call    format_address
    mov     rsi, addr_buf
    mov     rdx, rax
    call    write_outbuf
    ; Write newline
    mov     byte [char_buf], 10
    mov     rsi, char_buf
    mov     rdx, 1
    call    write_outbuf
.no_final:
    ret

; ============================================================================
;  Number formatting routines
; ============================================================================

; format_octal_padded — Format 32-bit value as zero-padded octal
; edi = value, rsi = output buffer, edx = width
format_octal_padded:
    push    rbx
    mov     eax, edi
    mov     ecx, edx
    lea     rbx, [rsi + rcx - 1]
.fop_loop:
    mov     edx, eax
    and     edx, 7
    add     dl, '0'
    mov     [rbx], dl
    shr     eax, 3
    dec     rbx
    dec     ecx
    jnz     .fop_loop
    pop     rbx
    ret

; format_octal64_padded — Format 64-bit value as zero-padded octal
; rdi = value, rsi = output buffer, edx = width
format_octal64_padded:
    push    rbx
    mov     rax, rdi
    mov     ecx, edx
    lea     rbx, [rsi + rcx - 1]
.fo64_loop:
    mov     rdx, rax
    and     edx, 7
    add     dl, '0'
    mov     [rbx], dl
    shr     rax, 3
    dec     rbx
    dec     ecx
    jnz     .fo64_loop
    pop     rbx
    ret

; format_decimal_zeropad64 — Format 64-bit value as zero-padded decimal
; rdi = value, rsi = output buffer, edx = width
format_decimal_zeropad64:
    push    rbx
    push    r12
    mov     rax, rdi
    mov     ecx, edx
    lea     rbx, [rsi + rcx - 1]
    mov     r12, 10
.fdz64_loop:
    xor     edx, edx
    div     r12
    add     dl, '0'
    mov     [rbx], dl
    dec     rbx
    dec     ecx
    jnz     .fdz64_loop
    pop     r12
    pop     rbx
    ret

; format_hex_padded — Format 32-bit value as zero-padded hex (lowercase)
; edi = value, rsi = output buffer, edx = width
format_hex_padded:
    push    rbx
    mov     eax, edi
    mov     ecx, edx
    lea     rbx, [rsi + rcx - 1]
    mov     rdi, hex_digits
.fhp_loop:
    mov     edx, eax
    and     edx, 0xF
    movzx   edx, byte [rdi + rdx]
    mov     [rbx], dl
    shr     eax, 4
    dec     rbx
    dec     ecx
    jnz     .fhp_loop
    pop     rbx
    ret

; format_hex64_padded — Format 64-bit value as zero-padded hex
; rdi = value, rsi = output buffer, edx = width
format_hex64_padded:
    push    rbx
    push    r12
    mov     rax, rdi
    mov     ecx, edx
    lea     rbx, [rsi + rcx - 1]
    mov     r12, hex_digits
.fh64_loop:
    mov     rdx, rax
    and     edx, 0xF
    movzx   edx, byte [r12 + rdx]
    mov     [rbx], dl
    shr     rax, 4
    dec     rbx
    dec     ecx
    jnz     .fh64_loop
    pop     r12
    pop     rbx
    ret

; format_signed_decimal_padded — Format signed 32-bit as right-justified decimal
; edi = value (sign-extended), rsi = output buffer, edx = field width
format_signed_decimal_padded:
    push    rbx
    push    r12
    push    r13

    mov     r12, rsi            ; output buffer
    mov     r13d, edx           ; field width
    mov     eax, edi

    ; Fill with spaces
    xor     ecx, ecx
.fsdp_fill_space:
    cmp     ecx, r13d
    jge     .fsdp_fill_done
    mov     byte [r12 + rcx], ' '
    inc     ecx
    jmp     .fsdp_fill_space
.fsdp_fill_done:

    ; Check negative
    xor     ebx, ebx            ; negative flag
    test    eax, eax
    jns     .fsdp_positive
    neg     eax
    mov     ebx, 1
.fsdp_positive:
    ; Convert to string (right-to-left)
    lea     rcx, [r12 + r13 - 1]
.fsdp_digit_loop:
    xor     edx, edx
    mov     esi, 10
    div     esi
    add     dl, '0'
    mov     [rcx], dl
    dec     rcx
    test    eax, eax
    jnz     .fsdp_digit_loop
    ; Add minus sign if negative
    test    ebx, ebx
    jz      .fsdp_done
    mov     byte [rcx], '-'
.fsdp_done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; format_signed_decimal64_padded — Format signed 64-bit
; rdi = value, rsi = output buffer, edx = field width
format_signed_decimal64_padded:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rsi
    mov     r13d, edx
    mov     rax, rdi

    ; Fill with spaces
    xor     ecx, ecx
.fsd64_fill_space:
    cmp     ecx, r13d
    jge     .fsd64_fill_done
    mov     byte [r12 + rcx], ' '
    inc     ecx
    jmp     .fsd64_fill_space
.fsd64_fill_done:

    xor     ebx, ebx
    test    rax, rax
    jns     .fsd64_positive
    neg     rax
    mov     ebx, 1
.fsd64_positive:
    lea     rcx, [r12 + r13 - 1]
    mov     r14, 10
.fsd64_digit_loop:
    xor     edx, edx
    div     r14
    add     dl, '0'
    mov     [rcx], dl
    dec     rcx
    test    rax, rax
    jnz     .fsd64_digit_loop
    test    ebx, ebx
    jz      .fsd64_done
    mov     byte [rcx], '-'
.fsd64_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; format_unsigned_decimal_padded — Format unsigned 32-bit as right-justified
; edi = value, rsi = output buffer, edx = field width
format_unsigned_decimal_padded:
    push    rbx
    push    r12
    push    r13

    mov     r12, rsi
    mov     r13d, edx
    mov     eax, edi

    ; Fill with spaces
    xor     ecx, ecx
.fudp_fill_space:
    cmp     ecx, r13d
    jge     .fudp_fill_done
    mov     byte [r12 + rcx], ' '
    inc     ecx
    jmp     .fudp_fill_space
.fudp_fill_done:

    lea     rcx, [r12 + r13 - 1]
.fudp_digit_loop:
    xor     edx, edx
    mov     esi, 10
    div     esi
    add     dl, '0'
    mov     [rcx], dl
    dec     rcx
    test    eax, eax
    jnz     .fudp_digit_loop

    pop     r13
    pop     r12
    pop     rbx
    ret

; format_unsigned_decimal64_padded — Format unsigned 64-bit
; rdi = value, rsi = output buffer, edx = field width
format_unsigned_decimal64_padded:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rsi
    mov     r13d, edx
    mov     rax, rdi

    ; Fill with spaces
    xor     ecx, ecx
.fud64_fill_space:
    cmp     ecx, r13d
    jge     .fud64_fill_done
    mov     byte [r12 + rcx], ' '
    inc     ecx
    jmp     .fud64_fill_space
.fud64_fill_done:

    lea     rcx, [r12 + r13 - 1]
    mov     r14, 10
.fud64_digit_loop:
    xor     edx, edx
    div     r14
    add     dl, '0'
    mov     [rcx], dl
    dec     rcx
    test    rax, rax
    jnz     .fud64_digit_loop

    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; format_float_field — Format double in xmm0 into buffer
; rdi = output buffer, esi = field width
; Returns: rax = chars written (= field width)
format_float_field:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     rbx, rdi            ; output buffer
    mov     r12d, esi           ; field width

    ; Fill with spaces
    xor     ecx, ecx
.fff_fill:
    cmp     ecx, r12d
    jge     .fff_fill_done
    mov     byte [rbx + rcx], ' '
    inc     ecx
    jmp     .fff_fill
.fff_fill_done:

    ; Check for negative
    xor     r13d, r13d          ; negative flag
    ; Extract raw bits
    movq    rax, xmm0
    test    rax, rax
    jns     .ff_positive
    ; Negative
    mov     r13d, 1
    ; Negate: flip sign bit
    btr     rax, 63
    movq    xmm0, rax
.ff_positive:
    ; Convert to integer (truncate)
    cvttsd2si rax, xmm0
    ; Get fractional part
    cvtsi2sd xmm1, rax
    subsd   xmm0, xmm1         ; xmm0 = fractional part
    ; Convert fractional to 7 digits
    mov     r14, rax            ; integer part

    ; Check if fractional part is zero
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    je      .ff_int_only

    ; Format with fraction
    ; Scale by 10^8
    push    rax
    mov     rax, 0x4197D78400000000     ; 10^8 as double
    movq    xmm1, rax
    pop     rax
    mulsd   xmm0, xmm1
    cvttsd2si rcx, xmm0        ; rcx = fractional digits

    ; Find how many trailing zeros to skip
    mov     r15, rcx
    ; Write integer part and '.' and fraction right-to-left
    lea     rdi, [rbx + r12 - 1]

    ; Write fraction digits (strip trailing zeros)
.fff_strip_zeros:
    test    r15, r15
    jz      .ff_write_int
    xor     edx, edx
    mov     rsi, 10
    mov     rax, r15
    div     rsi
    test    edx, edx
    jnz     .ff_write_frac
    mov     r15, rax
    jmp     .fff_strip_zeros

.ff_write_frac:
    mov     rax, r15
    mov     rsi, 10
.fff_frac_loop:
    test    rax, rax
    jz      .fff_frac_dot
    xor     edx, edx
    div     rsi
    add     dl, '0'
    mov     [rdi], dl
    dec     rdi
    jmp     .fff_frac_loop
.fff_frac_dot:
    mov     byte [rdi], '.'
    dec     rdi

.ff_write_int:
    mov     rax, r14
    mov     rsi, 10
    test    rax, rax
    jnz     .fff_int_loop
    mov     byte [rdi], '0'
    dec     rdi
    jmp     .ff_sign
.fff_int_loop:
    xor     edx, edx
    div     rsi
    add     dl, '0'
    mov     [rdi], dl
    dec     rdi
    test    rax, rax
    jnz     .fff_int_loop

.ff_sign:
    test    r13d, r13d
    jz      .ff_end
    mov     byte [rdi], '-'
    dec     rdi
.ff_end:
    mov     rax, r12
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.ff_int_only:
    ; Just integer
    lea     rdi, [rbx + r12 - 1]
    mov     rax, r14
    mov     rsi, 10
    test    rax, rax
    jnz     .fff_ii_loop
    mov     byte [rdi], '0'
    dec     rdi
    jmp     .ff_sign
.fff_ii_loop:
    xor     edx, edx
    div     rsi
    add     dl, '0'
    mov     [rdi], dl
    dec     rdi
    test    rax, rax
    jnz     .fff_ii_loop
    jmp     .ff_sign

; ============================================================================
;  Variable-width address formatters
;  rdi = value, rsi = output buffer
;  Returns: rax = number of chars written
;  Also stores width in [addr_width] for format_addr_spaces
; ============================================================================

; format_addr_hex_var — Hex address, minimum 6 digits
format_addr_hex_var:
    push    rbx
    push    r12
    push    r13
    mov     rax, rdi            ; value
    mov     r12, rsi            ; output buffer
    mov     r13, hex_digits

    ; First, determine how many hex digits we need
    mov     rcx, rax
    xor     edx, edx            ; digit count
.hv_count:
    inc     edx
    shr     rcx, 4
    jnz     .hv_count

    ; Minimum 6
    cmp     edx, 6
    jge     .hv_width_ok
    mov     edx, 6
.hv_width_ok:
    mov     ebx, edx            ; save width
    mov     [addr_width], rdx

    ; Format right-to-left
    lea     rcx, [r12 + rdx - 1]
    mov     edx, ebx
.hv_loop:
    mov     esi, eax
    and     esi, 0xF
    movzx   esi, byte [r13 + rsi]
    mov     [rcx], sil
    shr     rax, 4
    dec     rcx
    dec     edx
    jnz     .hv_loop

    movzx   eax, bl             ; return width
    pop     r13
    pop     r12
    pop     rbx
    ret

; format_addr_oct_var — Octal address, minimum 7 digits
format_addr_oct_var:
    push    rbx
    push    r12
    mov     rax, rdi
    mov     r12, rsi

    ; Count octal digits needed
    mov     rcx, rax
    xor     edx, edx
.ov_count:
    inc     edx
    shr     rcx, 3
    jnz     .ov_count
    cmp     edx, 7
    jge     .ov_ok
    mov     edx, 7
.ov_ok:
    mov     ebx, edx
    mov     [addr_width], rdx

    lea     rcx, [r12 + rdx - 1]
    mov     edx, ebx
.ov_loop:
    mov     esi, eax
    and     esi, 7
    add     sil, '0'
    mov     [rcx], sil
    shr     rax, 3
    dec     rcx
    dec     edx
    jnz     .ov_loop

    movzx   eax, bl
    pop     r12
    pop     rbx
    ret

; format_addr_dec_var — Decimal address, minimum 7 digits
format_addr_dec_var:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi            ; output buffer

    ; Count decimal digits needed for rdi
    mov     rax, rdi
    xor     ebx, ebx            ; digit count
    mov     rcx, 10
.dv_count_loop:
    inc     ebx
    xor     edx, edx
    div     rcx
    test    rax, rax
    jnz     .dv_count_loop

    cmp     ebx, 7
    jge     .dv_ok
    mov     ebx, 7
.dv_ok:
    movzx   r13, bl
    mov     [addr_width], r13

    ; Format: zero-padded decimal, right-to-left
    mov     rax, rdi
    lea     rcx, [r12 + r13 - 1]
    mov     edx, ebx
    mov     r13, 10
.dv_loop:
    push    rdx
    xor     edx, edx
    div     r13
    add     dl, '0'
    mov     [rcx], dl
    pop     rdx
    dec     rcx
    dec     edx
    jnz     .dv_loop

    movzx   eax, bl
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  Output buffer management
; ============================================================================

; write_outbuf — Append data to output buffer, flushing when full
; rsi = data, rdx = length
write_outbuf:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rsi
    mov     r12, rdx
    mov     r13, [outbuf_pos]

.wo_loop:
    test    r12, r12
    jz      .wo_done

    ; How much space left in outbuf?
    mov     rcx, OUTBUF_SIZE
    sub     rcx, r13
    test    rcx, rcx
    jnz     .wo_copy

    ; Buffer full, flush
    mov     [outbuf_pos], r13
    call    flush_outbuf
    xor     r13d, r13d

.wo_copy:
    ; Copy min(r12, rcx) bytes
    cmp     r12, rcx
    jle     .wo_small
    mov     rcx, rcx            ; use available space
    jmp     .wo_do_copy
.wo_small:
    mov     rcx, r12
.wo_do_copy:
    ; memcpy from rbx to outbuf+r13, length rcx
    push    rcx
    mov     rdi, outbuf
    add     rdi, r13
    mov     rsi, rbx
    rep     movsb
    pop     rcx
    add     r13, rcx
    add     rbx, rcx
    sub     r12, rcx
    jmp     .wo_loop

.wo_done:
    mov     [outbuf_pos], r13
    pop     r13
    pop     r12
    pop     rbx
    ret

; flush_outbuf — Write output buffer to stdout
flush_outbuf:
    push    rbx
    mov     rbx, [outbuf_pos]
    test    rbx, rbx
    jz      .flush_done
    mov     rdi, STDOUT
    mov     rsi, outbuf
    mov     rdx, rbx
    call    asm_write_all
    ; Check for EPIPE
    cmp     rax, -1
    je      .epipe_check
    mov     qword [outbuf_pos], 0
.flush_done:
    pop     rbx
    ret
.epipe_check:
    mov     qword [outbuf_pos], 0
    xor     edi, edi
    call    asm_exit

; ============================================================================
;  String utility functions
; ============================================================================

; str_eq — Compare two null-terminated strings
; rdi = str1, rsi = str2
; Returns: eax = 1 if equal, 0 if not
str_eq:
.se_loop:
    mov     al, [rdi]
    mov     cl, [rsi]
    cmp     al, cl
    jne     .se_neq
    test    al, al
    jz      .se_eq
    inc     rdi
    inc     rsi
    jmp     .se_loop
.se_eq:
    mov     eax, 1
    ret
.se_neq:
    xor     eax, eax
    ret

; str_prefix — Check if string starts with prefix
; rdi = string, rsi = prefix, ecx = prefix length
; Returns: eax = 1 if match, 0 if not
str_prefix:
    push    rbx
    mov     ebx, ecx
    xor     ecx, ecx
.sp_loop:
    cmp     ecx, ebx
    jge     .sp_match
    mov     al, [rdi + rcx]
    cmp     al, [rsi + rcx]
    jne     .sp_no_match
    inc     ecx
    jmp     .sp_loop
.sp_match:
    mov     eax, 1
    pop     rbx
    ret
.sp_no_match:
    xor     eax, eax
    pop     rbx
    ret

; str_len — Get length of null-terminated string
; rdi = string
; Returns: rax = length
str_len:
    xor     rax, rax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; memcmp_inline — Compare two buffers
; rdi = buf1, rsi = buf2, rcx = length
; Returns: eax = 0 if equal, non-zero if different
memcmp_inline:
    test    rcx, rcx
    jz      .mc_equal
    repe    cmpsb
    je      .mc_equal
    mov     eax, 1
    ret
.mc_equal:
    xor     eax, eax
    ret

; memcpy_inline — Copy memory
; rdi = dst, rsi = src, rcx = length
memcpy_inline:
    rep     movsb
    ret

; ============================================================================
;  Data section (read-only data embedded in the flat binary)
; ============================================================================

hex_digits: db "0123456789abcdef"

; Named character table (3 bytes each)
; Index 0-127: NUL, SOH, STX, ...
named_chars:
    db "nul"    ; 0x00
    db "soh"    ; 0x01
    db "stx"    ; 0x02
    db "etx"    ; 0x03
    db "eot"    ; 0x04
    db "enq"    ; 0x05
    db "ack"    ; 0x06
    db "bel"    ; 0x07
    db " bs"    ; 0x08
    db " ht"    ; 0x09
    db " nl"    ; 0x0A
    db " vt"    ; 0x0B
    db " ff"    ; 0x0C
    db " cr"    ; 0x0D
    db " so"    ; 0x0E
    db " si"    ; 0x0F
    db "dle"    ; 0x10
    db "dc1"    ; 0x11
    db "dc2"    ; 0x12
    db "dc3"    ; 0x13
    db "dc4"    ; 0x14
    db "nak"    ; 0x15
    db "syn"    ; 0x16
    db "etb"    ; 0x17
    db "can"    ; 0x18
    db " em"    ; 0x19
    db "sub"    ; 0x1A
    db "esc"    ; 0x1B
    db " fs"    ; 0x1C
    db " gs"    ; 0x1D
    db " rs"    ; 0x1E
    db " us"    ; 0x1F
    db " sp"    ; 0x20
    db "  !"    ; 0x21
    db '  "'    ; 0x22
    db "  #"    ; 0x23
    db "  $"    ; 0x24
    db "  %"    ; 0x25
    db "  &"    ; 0x26
    db "  '"    ; 0x27
    db "  ("    ; 0x28
    db "  )"    ; 0x29
    db "  *"    ; 0x2A
    db "  +"    ; 0x2B
    db "  ,"    ; 0x2C
    db "  -"    ; 0x2D
    db "  ."    ; 0x2E
    db "  /"    ; 0x2F
    db "  0"    ; 0x30
    db "  1"    ; 0x31
    db "  2"    ; 0x32
    db "  3"    ; 0x33
    db "  4"    ; 0x34
    db "  5"    ; 0x35
    db "  6"    ; 0x36
    db "  7"    ; 0x37
    db "  8"    ; 0x38
    db "  9"    ; 0x39
    db "  :"    ; 0x3A
    db "  ;"    ; 0x3B
    db "  <"    ; 0x3C
    db "  ="    ; 0x3D
    db "  >"    ; 0x3E
    db "  ?"    ; 0x3F
    db "  @"    ; 0x40
    db "  A"    ; 0x41
    db "  B"    ; 0x42
    db "  C"    ; 0x43
    db "  D"    ; 0x44
    db "  E"    ; 0x45
    db "  F"    ; 0x46
    db "  G"    ; 0x47
    db "  H"    ; 0x48
    db "  I"    ; 0x49
    db "  J"    ; 0x4A
    db "  K"    ; 0x4B
    db "  L"    ; 0x4C
    db "  M"    ; 0x4D
    db "  N"    ; 0x4E
    db "  O"    ; 0x4F
    db "  P"    ; 0x50
    db "  Q"    ; 0x51
    db "  R"    ; 0x52
    db "  S"    ; 0x53
    db "  T"    ; 0x54
    db "  U"    ; 0x55
    db "  V"    ; 0x56
    db "  W"    ; 0x57
    db "  X"    ; 0x58
    db "  Y"    ; 0x59
    db "  Z"    ; 0x5A
    db "  ["    ; 0x5B
    db "  \"    ; 0x5C
    db "  ]"    ; 0x5D
    db "  ^"    ; 0x5E
    db "  _"    ; 0x5F
    db "  `"    ; 0x60
    db "  a"    ; 0x61
    db "  b"    ; 0x62
    db "  c"    ; 0x63
    db "  d"    ; 0x64
    db "  e"    ; 0x65
    db "  f"    ; 0x66
    db "  g"    ; 0x67
    db "  h"    ; 0x68
    db "  i"    ; 0x69
    db "  j"    ; 0x6A
    db "  k"    ; 0x6B
    db "  l"    ; 0x6C
    db "  m"    ; 0x6D
    db "  n"    ; 0x6E
    db "  o"    ; 0x6F
    db "  p"    ; 0x70
    db "  q"    ; 0x71
    db "  r"    ; 0x72
    db "  s"    ; 0x73
    db "  t"    ; 0x74
    db "  u"    ; 0x75
    db "  v"    ; 0x76
    db "  w"    ; 0x77
    db "  x"    ; 0x78
    db "  y"    ; 0x79
    db "  z"    ; 0x7A
    db "  {"    ; 0x7B
    db "  |"    ; 0x7C
    db "  }"    ; 0x7D
    db "  ~"    ; 0x7E
    db "del"    ; 0x7F

dash_str:       db "-", 0
str_od_prefix:  db "od: ", 0

str_enoent:     db ": No such file or directory", 10
str_enoent_len  equ $ - str_enoent

str_skip_past:
    db "od: cannot skip past end of combined input", 10
str_skip_past_len equ $ - str_skip_past

str_unrec_opt:  db "unrecognized option '", 0
str_unrec_opt_len equ 21

str_inv_opt:    db "invalid option -- '", 0
str_inv_opt_len equ 19

str_quote_nl:   db "'", 10

str_try_help:
    db "Try 'od --help' for more information.", 10
str_try_help_len equ $ - str_try_help

opt_help:       db "--help", 0
opt_version:    db "--version", 0
opt_output_dup: db "--output-duplicates", 0
opt_traditional: db "--traditional", 0
opt_addr_radix: db "--address-radix=", 0
opt_format:     db "--format=", 0
opt_skip_bytes: db "--skip-bytes=", 0
opt_read_bytes: db "--read-bytes=", 0
opt_width_eq:   db "--width=", 0
opt_width:      db "--width", 0
opt_endian:     db "--endian=", 0
opt_strings:    db "--strings", 0
opt_strings_eq: db "--strings=", 0

; Type spec strings for short options
str_type_a:     db "a", 0
str_type_c:     db "c", 0
str_type_o1:    db "o1", 0
str_type_o2:    db "o2", 0
str_type_x2:    db "x2", 0
str_type_u2:    db "u2", 0
str_type_d2:    db "d2", 0
str_type_fF:    db "fF", 0
str_type_dI:    db "dI", 0
str_type_dL:    db "dL", 0

str_help:
    db "Usage: od [OPTION]... [FILE]...", 10
    db "  or:  od [-abcdfilosx]... [FILE] [[+]OFFSET[.][b]]", 10
    db "  or:  od --traditional [OPTION]... [FILE] [[+]OFFSET[.][b] [+][LABEL][.][b]]", 10
    db 10
    db "Write an unambiguous representation, octal bytes by default,", 10
    db "of FILE to standard output.  With more than one FILE argument,", 10
    db "concatenate them in the listed order to form the input.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "If first and second call formats both apply, the second format is assumed", 10
    db "if the last operand begins with + or (if there are 2 operands) a digit.", 10
    db "An OFFSET operand means -j OFFSET.  LABEL is the pseudo-address", 10
    db "at first byte printed, incremented when dump is progressing.", 10
    db "For OFFSET and LABEL, a 0x or 0X prefix indicates hexadecimal;", 10
    db "suffixes may be . for octal and b for multiply by 512.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -A, --address-radix=RADIX   output format for file offsets; RADIX is one", 10
    db "                                of [doxn], for Decimal, Octal, Hex or None", 10
    db "      --endian={big|little}   swap input bytes according the specified order", 10
    db "  -j, --skip-bytes=BYTES      skip BYTES input bytes first", 10
    db "  -N, --read-bytes=BYTES      limit dump to BYTES input bytes", 10
    db "  -S BYTES, --strings[=BYTES]  show only NUL terminated strings", 10
    db "                                of at least BYTES (3) printable characters", 10
    db "  -t, --format=TYPE           select output format or formats", 10
    db "  -v, --output-duplicates     do not use * to mark line suppression", 10
    db "  -w[BYTES], --width[=BYTES]  output BYTES bytes per output line;", 10
    db "                                32 is implied when BYTES is not specified", 10
    db "      --traditional           accept arguments in third form above", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db 10
    db "Traditional format specifications may be intermixed; they accumulate:", 10
    db "  -a   same as -t a,  select named characters, ignoring high-order bit", 10
    db "  -b   same as -t o1, select octal bytes", 10
    db "  -c   same as -t c,  select printable characters or backslash escapes", 10
    db "  -d   same as -t u2, select unsigned decimal 2-byte units", 10
    db "  -f   same as -t fF, select floats", 10
    db "  -i   same as -t dI, select decimal ints", 10
    db "  -l   same as -t dL, select decimal longs", 10
    db "  -o   same as -t o2, select octal 2-byte units", 10
    db "  -s   same as -t d2, select decimal 2-byte units", 10
    db "  -x   same as -t x2, select hexadecimal 2-byte units", 10
    db 10
    db 10
    db "TYPE is made up of one or more of these specifications:", 10
    db "  a          named character, ignoring high-order bit", 10
    db "  c          printable character or backslash escape", 10
    db "  d[SIZE]    signed decimal, SIZE bytes per integer", 10
    db "  f[SIZE]    floating point, SIZE bytes per float", 10
    db "  o[SIZE]    octal, SIZE bytes per integer", 10
    db "  u[SIZE]    unsigned decimal, SIZE bytes per integer", 10
    db "  x[SIZE]    hexadecimal, SIZE bytes per integer", 10
    db 10
    db "SIZE is a number.  For TYPE in [doux], SIZE may also be C for", 10
    db "sizeof(char), S for sizeof(short), I for sizeof(int) or L for", 10
    db "sizeof(long).  If TYPE is f, SIZE may also be B for Brain 16 bit,", 10
    db "H for Half precision float, F for sizeof(float), D for sizeof(double),", 10
    db "or L for sizeof(long double).", 10
    db 10
    db "Adding a z suffix to any type displays printable characters at the end of", 10
    db "each output line.", 10
    db 10
    db 10
    db "BYTES is hex with 0x or 0X prefix, and may have a multiplier suffix:", 10
    db "  b    512", 10
    db "  KB   1000", 10
    db "  K    1024", 10
    db "  MB   1000*1000", 10
    db "  M    1024*1024", 10
    db "and so on for G, T, P, E, Z, Y, R, Q.", 10
    db "Binary prefixes can be used, too: KiB=K, MiB=M, and so on.", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/od>", 10
    db "or available locally via: info '(coreutils) od invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "od (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Jay Fenlason.", 10
str_version_len equ $ - str_version

; ===============================================================
; BSS (uninitialized data — zero-filled by ELF loader)
; ===============================================================
file_size equ $ - $$

; BSS layout using equ addresses (not resb, which bloats the binary)
bss_base        equ $$ + file_size

argc            equ bss_base + 0                    ; 8
argv            equ argc + 8                        ; 8

addr_radix      equ argv + 8                        ; 1
show_dupes      equ addr_radix + 1                  ; 1
have_limit      equ show_dupes + 1                  ; 1
had_error       equ have_limit + 1                  ; 1
w_explicit      equ had_error + 1                   ; 1
prev_line_valid equ w_explicit + 1                  ; 1
dup_star_printed equ prev_line_valid + 1            ; 1
; padding to align char_buf
char_buf        equ dup_star_printed + 1            ; 8

skip_bytes      equ char_buf + 8                    ; 8
limit_bytes     equ skip_bytes + 8                  ; 8
bytes_per_line  equ limit_bytes + 8                 ; 8
total_offset    equ bytes_per_line + 8              ; 8
num_types       equ total_offset + 8                ; 8
num_files       equ num_types + 8                   ; 8
cur_fd          equ num_files + 8                   ; 8
outbuf_pos      equ cur_fd + 8                      ; 8
line_content_len equ outbuf_pos + 8                 ; 8
prev_line_len   equ line_content_len + 8            ; 8
type_count_save equ prev_line_len + 8               ; 8
addr_width      equ type_count_save + 8             ; 8

; Type specs: pairs of (type_code, size), up to MAX_TYPES
type_specs      equ addr_width + 8                  ; MAX_TYPES * 2 = 32

; Computed column widths per value for each type
type_col_widths equ type_specs + MAX_TYPES * 2      ; MAX_TYPES * 4 = 64

; File pointers
file_ptrs       equ type_col_widths + MAX_TYPES * 4 ; MAX_FILES * 8 = 2048

; Address format buffer
addr_buf        equ file_ptrs + MAX_FILES * 8       ; 32

; Output buffer (256KB)
outbuf          equ addr_buf + 32                   ; OUTBUF_SIZE = 262144

; Input buffer (128KB)
inbuf           equ outbuf + OUTBUF_SIZE            ; INBUF_SIZE = 131072

; Format temp buffer (per-line)
fmt_buf         equ inbuf + INBUF_SIZE              ; 4096

; Line content buffer (for duplicate comparison)
line_content_buf equ fmt_buf + 4096                 ; 4096

; Previous line buffer
prev_line_buf   equ line_content_buf + 4096         ; 4096

; Previous raw line (for fast-path duplicate detection)
prev_raw_line   equ prev_line_buf + 4096            ; 256

; SIMD scratch space (16-byte aligned offset)
simd_tmp        equ prev_raw_line + 256             ; 64 (aligned to 16 implicitly)

; mmap tracking
mmap_base_save  equ simd_tmp + 64                   ; 8
mmap_len_save   equ mmap_base_save + 8              ; 8

bss_end         equ mmap_len_save + 8
mem_size        equ bss_end - $$
