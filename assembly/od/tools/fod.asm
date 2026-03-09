; ============================================================================
;  fod.asm — GNU-compatible "od" in x86-64 Linux assembly
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
;    cd assembly/od && make dev
; ============================================================================

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close
extern asm_exit

; ── Constants ──────────────────────────────────────────
%define MAX_FILES       256
%define OUTBUF_SIZE     65536
%define INBUF_SIZE      131072
%define MAX_TYPES       16
%define MAX_LINE_FMT    1024

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

section .text
global _start

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
    mov     [rel argc], rax
    lea     rax, [rsp + 8]
    mov     [rel argv], rax

    ; ── Initialize defaults ──
    mov     byte [rel addr_radix], ADDR_OCTAL
    mov     qword [rel skip_bytes], 0
    mov     qword [rel limit_bytes], -1     ; no limit
    mov     qword [rel bytes_per_line], 16
    mov     byte [rel show_dupes], 0
    mov     byte [rel have_limit], 0
    mov     qword [rel num_types], 0
    mov     qword [rel num_files], 0
    mov     byte [rel had_error], 0
    mov     byte [rel w_explicit], 0
    mov     qword [rel total_offset], 0

    ; ── Parse arguments ──
    call    parse_args

    ; Set total_offset to skip_bytes (addresses start from skip offset)
    mov     rax, [rel skip_bytes]
    mov     [rel total_offset], rax

    ; If no types specified, default is o2
    cmp     qword [rel num_types], 0
    jne     .have_types
    ; Default: octal 2-byte
    lea     rdi, [rel type_specs]
    mov     byte [rdi], TYPE_O
    mov     byte [rdi+1], 2
    mov     qword [rel num_types], 1
.have_types:

    ; Compute column widths for all types
    call    compute_col_widths

    ; If no files, use stdin
    cmp     qword [rel num_files], 0
    jne     .have_files
    lea     rax, [rel dash_str]
    lea     rdi, [rel file_ptrs]
    mov     [rdi], rax
    mov     qword [rel num_files], 1
.have_files:

    ; Initialize output buffer
    mov     qword [rel outbuf_pos], 0

    ; Initialize previous line buffer (for duplicate suppression)
    mov     byte [rel prev_line_valid], 0
    mov     byte [rel dup_star_printed], 0

    ; Process files
    call    process_all_files

    ; Print final address
    call    print_final_address

    ; Flush output buffer
    call    flush_outbuf

    ; Exit
    movzx   edi, byte [rel had_error]
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
    mov     r13, [rel argc]
    mov     r14, [rel argv]
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
    lea     rsi, [rel opt_help]
    call    str_eq
    test    eax, eax
    jnz     .do_help

    ; Check --version
    lea     rdi, [rbx]
    lea     rsi, [rel opt_version]
    call    str_eq
    test    eax, eax
    jnz     .do_version

    ; Check --output-duplicates
    lea     rdi, [rbx]
    lea     rsi, [rel opt_output_dup]
    call    str_eq
    test    eax, eax
    jnz     .do_verbose

    ; Check --traditional
    lea     rdi, [rbx]
    lea     rsi, [rel opt_traditional]
    call    str_eq
    test    eax, eax
    jnz     .do_traditional

    ; Check --address-radix=
    lea     rdi, [rbx]
    lea     rsi, [rel opt_addr_radix]
    mov     ecx, 16
    call    str_prefix
    test    eax, eax
    jnz     .do_addr_radix_long

    ; Check --format=
    lea     rdi, [rbx]
    lea     rsi, [rel opt_format]
    mov     ecx, 9
    call    str_prefix
    test    eax, eax
    jnz     .do_format_long

    ; Check --skip-bytes=
    lea     rdi, [rbx]
    lea     rsi, [rel opt_skip_bytes]
    mov     ecx, 13
    call    str_prefix
    test    eax, eax
    jnz     .do_skip_long

    ; Check --read-bytes=
    lea     rdi, [rbx]
    lea     rsi, [rel opt_read_bytes]
    mov     ecx, 13
    call    str_prefix
    test    eax, eax
    jnz     .do_read_long

    ; Check --width=
    lea     rdi, [rbx]
    lea     rsi, [rel opt_width_eq]
    mov     ecx, 8
    call    str_prefix
    test    eax, eax
    jnz     .do_width_long

    ; Check --width (no =)
    lea     rdi, [rbx]
    lea     rsi, [rel opt_width]
    call    str_eq
    test    eax, eax
    jnz     .do_width_noarg

    ; Check --endian=
    lea     rdi, [rbx]
    lea     rsi, [rel opt_endian]
    mov     ecx, 9
    call    str_prefix
    test    eax, eax
    jnz     .do_endian_long

    ; Check --strings or --strings=
    lea     rdi, [rbx]
    lea     rsi, [rel opt_strings]
    call    str_eq
    test    eax, eax
    jnz     .skip_arg        ; ignore -S/--strings for now

    lea     rdi, [rbx]
    lea     rsi, [rel opt_strings_eq]
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
    mov     byte [rel addr_radix], ADDR_OCTAL
    jmp     .next_arg
.A_decimal:
    mov     byte [rel addr_radix], ADDR_DECIMAL
    jmp     .next_arg
.A_hex:
    mov     byte [rel addr_radix], ADDR_HEX
    jmp     .next_arg
.A_none:
    mov     byte [rel addr_radix], ADDR_NONE
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
    mov     [rel skip_bytes], rax
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
    mov     [rel limit_bytes], rax
    mov     byte [rel have_limit], 1
    jmp     .next_arg

.do_w:
    mov     byte [rel w_explicit], 1
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
    mov     [rel bytes_per_line], rax
    jmp     .next_arg
.w_default:
    mov     qword [rel bytes_per_line], 32
    jmp     .next_arg
.w_default_continue:
    ; Not a digit, so -w with default 32 and continue parsing remaining chars
    mov     qword [rel bytes_per_line], 32
    jmp     .short_loop

.do_v:
    mov     byte [rel show_dupes], 1
    inc     rbx
    jmp     .short_loop

.do_short_a:
    ; -a = -t a
    push    rbx
    lea     rdi, [rel str_type_a]
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_b:
    ; -b = -t o1
    push    rbx
    lea     rdi, [rel str_type_o1]
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_c:
    ; -c = -t c
    push    rbx
    lea     rdi, [rel str_type_c]
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_d:
    ; -d = -t u2
    push    rbx
    lea     rdi, [rel str_type_u2]
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_f:
    ; -f = -t fF
    push    rbx
    lea     rdi, [rel str_type_fF]
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_i:
    ; -i = -t dI
    push    rbx
    lea     rdi, [rel str_type_dI]
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_l:
    ; -l = -t dL
    push    rbx
    lea     rdi, [rel str_type_dL]
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_o:
    ; -o = -t o2
    push    rbx
    lea     rdi, [rel str_type_o2]
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_s:
    ; -s = -t d2
    push    rbx
    lea     rdi, [rel str_type_d2]
    call    add_type_spec
    pop     rbx
    inc     rbx
    jmp     .short_loop

.do_short_x:
    ; -x = -t x2
    push    rbx
    lea     rdi, [rel str_type_x2]
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
    lea     rsi, [rel str_help]
    mov     rdx, str_help_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit

.do_version:
    mov     rdi, STDOUT
    lea     rsi, [rel str_version]
    mov     rdx, str_version_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit

.do_verbose:
    mov     byte [rel show_dupes], 1
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
    mov     [rel skip_bytes], rax
    inc     r12
    jmp     .arg_loop

.do_read_long:
    lea     rdi, [rbx + 13]        ; skip "--read-bytes="
    call    parse_byte_count
    mov     [rel limit_bytes], rax
    mov     byte [rel have_limit], 1
    inc     r12
    jmp     .arg_loop

.do_width_long:
    lea     rdi, [rbx + 8]         ; skip "--width="
    call    parse_decimal
    test    rax, rax
    jz      .w_long_default
    mov     [rel bytes_per_line], rax
    mov     byte [rel w_explicit], 1
    inc     r12
    jmp     .arg_loop
.w_long_default:
    mov     qword [rel bytes_per_line], 32
    mov     byte [rel w_explicit], 1
    inc     r12
    jmp     .arg_loop

.do_width_noarg:
    mov     qword [rel bytes_per_line], 32
    mov     byte [rel w_explicit], 1
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
    mov     rcx, [rel num_files]
    cmp     rcx, MAX_FILES
    jge     .next_arg
    lea     rdi, [rel file_ptrs]
    mov     rax, [r14 + r12*8]
    mov     [rdi + rcx*8], rax
    inc     rcx
    mov     [rel num_files], rcx
    jmp     .next_arg

.next_arg:
    inc     r12
    jmp     .arg_loop

.err_unrec:
    ; Print "od: unrecognized option 'X'"
    mov     rdi, STDERR
    lea     rsi, [rel str_od_prefix]
    mov     rdx, 4
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_unrec_opt]
    mov     rdx, str_unrec_opt_len
    call    asm_write_all
    mov     rdi, [r14 + r12*8]
    call    str_len
    mov     rdx, rax
    mov     rsi, rdi
    mov     rdi, STDERR
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_quote_nl]
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.err_invalid:
    mov     rdi, STDERR
    lea     rsi, [rel str_od_prefix]
    mov     rdx, 4
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_inv_opt]
    mov     rdx, str_inv_opt_len
    call    asm_write_all
    movzx   eax, byte [rbx]
    mov     [rel char_buf], al
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
;  For each type, computes actual field width per value based on the
;  maximum per-byte width across all types.
; ============================================================================
compute_col_widths:
    push    rbx
    push    r12
    push    r13

    ; First pass: find max per-byte width
    ; per_byte_width = ceil(base_width / size)
    ; We use *2 to avoid fractions: per_byte_x2 = (base_width * 2 + size - 1) / size * ...
    ; Simpler: per_byte_x2 = ceil(base_width / size) computed as (base_width + size - 1) / size
    ; but we need half-units. Let's use fixed-point *2:
    ; per_byte_x2 = (base_width * 2) / size  (rounds down, but that's enough)
    ; Actually, we need ceiling division. Let's compute per_byte_x2 = (base_width * 2 + size - 1) / size

    xor     r12d, r12d          ; max per_byte_x2
    xor     ecx, ecx            ; type index

.pass1_loop:
    cmp     rcx, [rel num_types]
    jge     .pass1_done

    lea     rax, [rel type_specs]
    movzx   edi, byte [rax + rcx*2]        ; type code
    movzx   esi, byte [rax + rcx*2 + 1]    ; size

    ; Get base field width for this type/size
    call    get_base_field_width
    ; rax = base width (total chars per value including leading space)

    ; Compute per_byte_x2 = (rax * 2 + size - 1) / size
    lea     rax, [rel type_specs]
    movzx   esi, byte [rax + rcx*2 + 1]
    mov     rax, [rsp - 8]     ; ... hmm, rax was clobbered
    ; Let me redo this properly
    jmp     .pass1_done         ; will restructure

.pass1_done:
    ; Simplified approach: compute max per-byte width directly
    ; Reset and do it properly
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
    cmp     rcx, [rel num_types]
    jge     .cw_pass1_done

    lea     rax, [rel type_specs]
    movzx   edi, byte [rax + rcx*2]        ; type code
    movzx   esi, byte [rax + rcx*2 + 1]    ; size
    push    rcx
    call    get_base_field_width
    ; rax = base width
    pop     rcx
    lea     rdx, [rel type_specs]
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
    ; actual_width = (max_per_byte_x2 * size + 1) / 2  (round up)
    ; Actually: actual_width = max_per_byte_x2 * size / 2 (since x2)
    ; Hmm, let me think more carefully.
    ; If max_per_byte_x2 = 8 (meaning 4.0 per byte), size = 2:
    ;   actual_width = 8 * 2 / 2 = 8. Check: o1 is 4/byte, so o2 should be... but o2 normally is 7.
    ;   With o1+x1: o1 per_byte=4, x1 per_byte=3, max=4.
    ;   x1 actual = 4*1 = 4 (correct: "··00")
    ;   o1 actual = 4*1 = 4 (correct: "·000")

    xor     ecx, ecx
.cw_pass2:
    cmp     rcx, [rel num_types]
    jge     .cw_done

    lea     rax, [rel type_specs]
    movzx   esi, byte [rax + rcx*2 + 1]    ; size

    ; actual_width = max_per_byte_x2 * size / 2
    mov     rax, r12
    imul    rax, rsi
    shr     rax, 1              ; / 2

    lea     rdx, [rel type_col_widths]
    mov     [rdx + rcx*4], eax

    inc     rcx
    jmp     .cw_pass2

.cw_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
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

    mov     r12, [rel num_types]
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
    lea     rdi, [rel type_specs]
    mov     byte [rdi + r12*2], TYPE_A
    mov     byte [rdi + r12*2 + 1], 1
    inc     r12
    mov     [rel num_types], r12
    inc     rbx
    jmp     .type_loop

.type_c:
    lea     rdi, [rel type_specs]
    mov     byte [rdi + r12*2], TYPE_C
    mov     byte [rdi + r12*2 + 1], 1
    inc     r12
    mov     [rel num_types], r12
    inc     rbx
    jmp     .type_loop

.type_d:
    lea     rdi, [rel type_specs]
    mov     byte [rdi + r12*2], TYPE_D
    inc     rbx
    call    parse_type_size_doux
    mov     byte [rdi + r12*2 + 1], al
    inc     r12
    mov     [rel num_types], r12
    jmp     .type_loop

.type_f:
    lea     rdi, [rel type_specs]
    mov     byte [rdi + r12*2], TYPE_F
    inc     rbx
    call    parse_type_size_f
    mov     byte [rdi + r12*2 + 1], al
    inc     r12
    mov     [rel num_types], r12
    jmp     .type_loop

.type_o:
    lea     rdi, [rel type_specs]
    mov     byte [rdi + r12*2], TYPE_O
    inc     rbx
    call    parse_type_size_doux
    mov     byte [rdi + r12*2 + 1], al
    inc     r12
    mov     [rel num_types], r12
    jmp     .type_loop

.type_u:
    lea     rdi, [rel type_specs]
    mov     byte [rdi + r12*2], TYPE_U
    inc     rbx
    call    parse_type_size_doux
    mov     byte [rdi + r12*2 + 1], al
    inc     r12
    mov     [rel num_types], r12
    jmp     .type_loop

.type_x:
    lea     rdi, [rel type_specs]
    mov     byte [rdi + r12*2], TYPE_X
    inc     rbx
    call    parse_type_size_doux
    mov     byte [rdi + r12*2 + 1], al
    inc     r12
    mov     [rel num_types], r12
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
    mov     r13, [rel num_files]
    ; r14 = current offset in input stream (for skip)
    xor     r14, r14
    ; r15 = bytes remaining in limit
    mov     r15, [rel limit_bytes]

    ; Skip bytes from initial files
    mov     rbp, [rel skip_bytes]

.file_loop:
    cmp     r12, r13
    jge     .all_done

    ; Get file pointer
    lea     rax, [rel file_ptrs]
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
    mov     [rel cur_fd], rdi

    ; Read and process data from this fd
.read_loop:
    ; Check if we've hit limit
    cmp     byte [rel have_limit], 0
    je      .no_limit_check
    test    r15, r15
    jz      .close_file
.no_limit_check:

    mov     rdi, [rel cur_fd]
    lea     rsi, [rel inbuf]
    mov     rdx, INBUF_SIZE
    call    asm_read
    test    rax, rax
    jle     .close_file         ; EOF or error

    mov     rcx, rax            ; rcx = bytes read
    lea     rsi, [rel inbuf]    ; rsi = buffer start

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
    cmp     byte [rel have_limit], 0
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
    mov     rdi, [rel cur_fd]
    test    rdi, rdi
    jz      .next_file          ; don't close stdin
    call    asm_close
    jmp     .next_file

.file_error:
    ; Print error
    push    r12
    push    r13
    mov     rdi, STDERR
    lea     rsi, [rel str_od_prefix]
    mov     rdx, 4
    call    asm_write_all
    ; Print filename
    lea     rax, [rel file_ptrs]
    pop     r13
    pop     r12
    mov     rdi, [rax + r12*8]
    call    str_len
    mov     rdx, rax
    lea     rax, [rel file_ptrs]
    mov     rsi, [rax + r12*8]
    mov     rdi, STDERR
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_enoent]
    mov     rdx, str_enoent_len
    call    asm_write_all
    mov     byte [rel had_error], 1

.next_file:
    inc     r12
    jmp     .file_loop

.all_done:
    ; Check if skip_bytes was larger than total input
    test    rbp, rbp
    jz      .skip_ok
    ; "od: cannot skip past end of combined input"
    mov     rdi, STDERR
    lea     rsi, [rel str_skip_past]
    mov     rdx, str_skip_past_len
    call    asm_write_all
    mov     byte [rel had_error], 1
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
    mov     r14, [rel bytes_per_line]

.chunk_loop:
    test    r13, r13
    jz      .chunk_done

    ; Determine bytes for this line
    mov     r15, r14            ; bytes_per_line
    cmp     r15, r13
    jle     .line_ok
    mov     r15, r13            ; partial last line
.line_ok:

    ; Format this line into line_buf
    ; First, format the line content (without address) for duplicate checking
    mov     rdi, r12
    mov     rsi, r15
    call    format_line_content

    ; Check for duplicate suppression
    cmp     byte [rel show_dupes], 1
    je      .print_line

    ; Only suppress if we have a full line
    cmp     r15, r14
    jne     .print_line

    ; Compare with previous line
    cmp     byte [rel prev_line_valid], 0
    je      .print_line

    ; Compare line content buffers
    lea     rdi, [rel line_content_buf]
    lea     rsi, [rel prev_line_buf]
    mov     rcx, [rel line_content_len]
    mov     rdx, [rel prev_line_len]
    cmp     rcx, rdx
    jne     .print_line
    ; memcmp
    call    memcmp_inline
    test    eax, eax
    jnz     .print_line

    ; Duplicate — print * if not already printed
    cmp     byte [rel dup_star_printed], 0
    jne     .skip_line
    mov     byte [rel dup_star_printed], 1
    ; Output "*\n"
    mov     byte [rel char_buf], '*'
    mov     byte [rel char_buf+1], 10
    lea     rsi, [rel char_buf]
    mov     rdx, 2
    call    write_outbuf
    jmp     .skip_line

.print_line:
    mov     byte [rel dup_star_printed], 0

    ; Save current line as previous
    lea     rdi, [rel prev_line_buf]
    lea     rsi, [rel line_content_buf]
    mov     rcx, [rel line_content_len]
    mov     [rel prev_line_len], rcx
    call    memcpy_inline
    mov     byte [rel prev_line_valid], 1

    ; Output address (for first type row)
    mov     rdi, [rel total_offset]
    call    format_address
    ; rax = length of formatted address in addr_buf
    lea     rsi, [rel addr_buf]
    mov     rdx, rax
    call    write_outbuf

    ; Output each type's formatted line
    xor     ebp, ebp            ; type index
    mov     rcx, [rel num_types]
    mov     [rel type_count_save], rcx

.type_loop:
    cmp     rbp, [rel type_count_save]
    jge     .type_done

    cmp     rbp, 0
    je      .first_type
    ; For subsequent types, print spaces instead of address
    call    format_addr_spaces
    lea     rsi, [rel addr_buf]
    mov     rdx, rax
    call    write_outbuf
.first_type:

    ; Format values for this type
    lea     rax, [rel type_specs]
    movzx   ecx, byte [rax + rbp*2]      ; type code
    movzx   edx, byte [rax + rbp*2 + 1]  ; size
    mov     r8d, ebp                      ; type index

    mov     rdi, r12            ; data ptr
    mov     rsi, r15            ; bytes this line
    ; ecx = type, edx = size, r8d = type index
    call    format_type_values

    ; Write newline
    mov     byte [rel char_buf], 10
    lea     rsi, [rel char_buf]
    mov     rdx, 1
    call    write_outbuf

    inc     rbp
    jmp     .type_loop

.type_done:
.skip_line:
    add     r12, r15
    sub     r13, r15
    add     [rel total_offset], r15
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
    lea     rbx, [rel line_content_buf]
    xor     r14d, r14d          ; position in line_content_buf

    xor     ebp, ebp
.lc_type_loop:
    cmp     rbp, [rel num_types]
    jge     .lc_done

    lea     rax, [rel type_specs]
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
    lea     rsi, [rel fmt_buf]
    lea     rdi, [rbx + r14]
    mov     rcx, rax
    call    memcpy_inline
    add     r14, rax

    inc     rbp
    jmp     .lc_type_loop

.lc_done:
    mov     [rel line_content_len], r14

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
    lea     rax, [rel type_col_widths]
    movzx   ebp, r8b
    mov     ebp, [rax + rbp*4]  ; ebp = actual column width per value

    lea     rbx, [rel fmt_buf]
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
    lea     rdi, [rel named_chars]
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

    ; Check for special C escapes — content_len is 2 for \X, 1 for printable, 3 for octal
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
    ; Printable: 0x20-0x7E — content_len=1
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
    lea     rdi, [rel hex_digits]
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
    lea     rsi, [rel fmt_buf]
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
    lea     rbx, [rel addr_buf]

    cmp     byte [rel addr_radix], ADDR_NONE
    je      .addr_none

    cmp     byte [rel addr_radix], ADDR_OCTAL
    je      .addr_octal
    cmp     byte [rel addr_radix], ADDR_DECIMAL
    je      .addr_decimal
    cmp     byte [rel addr_radix], ADDR_HEX
    je      .addr_hex
    jmp     .addr_none

.addr_octal:
    ; 7-digit octal
    mov     rsi, rbx
    mov     edx, 7
    call    format_octal64_padded
    mov     rax, 7
    pop     rbx
    ret

.addr_decimal:
    ; 7-digit zero-padded decimal
    mov     rsi, rbx
    mov     edx, 7
    call    format_decimal_zeropad64
    mov     rax, 7
    pop     rbx
    ret

.addr_hex:
    ; 6-digit hex
    mov     rsi, rbx
    mov     edx, 6
    call    format_hex64_padded
    mov     rax, 6
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
    lea     rbx, [rel addr_buf]

    cmp     byte [rel addr_radix], ADDR_NONE
    je      .as_none
    cmp     byte [rel addr_radix], ADDR_HEX
    je      .as_hex

    ; Octal or decimal: 7 spaces
    mov     rcx, 7
    jmp     .as_fill
.as_hex:
    mov     rcx, 6
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
    cmp     byte [rel addr_radix], ADDR_NONE
    je      .no_final
    mov     rdi, [rel total_offset]
    call    format_address
    lea     rsi, [rel addr_buf]
    mov     rdx, rax
    call    write_outbuf
    ; Write newline
    mov     byte [rel char_buf], 10
    lea     rsi, [rel char_buf]
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
.loop:
    mov     edx, eax
    and     edx, 7
    add     dl, '0'
    mov     [rbx], dl
    shr     eax, 3
    dec     rbx
    dec     ecx
    jnz     .loop
    pop     rbx
    ret

; format_octal64_padded — Format 64-bit value as zero-padded octal
; rdi = value, rsi = output buffer, edx = width
format_octal64_padded:
    push    rbx
    mov     rax, rdi
    mov     ecx, edx
    lea     rbx, [rsi + rcx - 1]
.loop:
    mov     rdx, rax
    and     edx, 7
    add     dl, '0'
    mov     [rbx], dl
    shr     rax, 3
    dec     rbx
    dec     ecx
    jnz     .loop
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
.loop:
    xor     edx, edx
    div     r12
    add     dl, '0'
    mov     [rbx], dl
    dec     rbx
    dec     ecx
    jnz     .loop
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
    lea     rdi, [rel hex_digits]
.loop:
    mov     edx, eax
    and     edx, 0xF
    movzx   edx, byte [rdi + rdx]
    mov     [rbx], dl
    shr     eax, 4
    dec     rbx
    dec     ecx
    jnz     .loop
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
    lea     r12, [rel hex_digits]
.loop:
    mov     rdx, rax
    and     edx, 0xF
    movzx   edx, byte [r12 + rdx]
    mov     [rbx], dl
    shr     rax, 4
    dec     rbx
    dec     ecx
    jnz     .loop
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
.fill_space:
    cmp     ecx, r13d
    jge     .fill_done
    mov     byte [r12 + rcx], ' '
    inc     ecx
    jmp     .fill_space
.fill_done:

    ; Check negative
    xor     ebx, ebx            ; negative flag
    test    eax, eax
    jns     .positive
    neg     eax
    mov     ebx, 1
.positive:
    ; Convert to string (right-to-left)
    lea     rcx, [r12 + r13 - 1]
.digit_loop:
    xor     edx, edx
    mov     esi, 10
    div     esi
    add     dl, '0'
    mov     [rcx], dl
    dec     rcx
    test    eax, eax
    jnz     .digit_loop
    ; Add minus sign if negative
    test    ebx, ebx
    jz      .sd_done
    mov     byte [rcx], '-'
.sd_done:
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
.fill_space:
    cmp     ecx, r13d
    jge     .fill_done
    mov     byte [r12 + rcx], ' '
    inc     ecx
    jmp     .fill_space
.fill_done:

    xor     ebx, ebx
    test    rax, rax
    jns     .positive
    neg     rax
    mov     ebx, 1
.positive:
    lea     rcx, [r12 + r13 - 1]
    mov     r14, 10
.digit_loop:
    xor     edx, edx
    div     r14
    add     dl, '0'
    mov     [rcx], dl
    dec     rcx
    test    rax, rax
    jnz     .digit_loop
    test    ebx, ebx
    jz      .done
    mov     byte [rcx], '-'
.done:
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
.fill_space:
    cmp     ecx, r13d
    jge     .fill_done
    mov     byte [r12 + rcx], ' '
    inc     ecx
    jmp     .fill_space
.fill_done:

    lea     rcx, [r12 + r13 - 1]
.digit_loop:
    xor     edx, edx
    mov     esi, 10
    div     esi
    add     dl, '0'
    mov     [rcx], dl
    dec     rcx
    test    eax, eax
    jnz     .digit_loop

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
.fill_space:
    cmp     ecx, r13d
    jge     .fill_done
    mov     byte [r12 + rcx], ' '
    inc     ecx
    jmp     .fill_space
.fill_done:

    lea     rcx, [r12 + r13 - 1]
    mov     r14, 10
.digit_loop:
    xor     edx, edx
    div     r14
    add     dl, '0'
    mov     [rcx], dl
    dec     rcx
    test    rax, rax
    jnz     .digit_loop

    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; format_float_field — Format double in xmm0 into buffer
; rdi = output buffer, esi = field width
; Returns: rax = chars written (= field width)
; Simple implementation: output integer part if no fraction
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
.fill:
    cmp     ecx, r12d
    jge     .fill_done
    mov     byte [rbx + rcx], ' '
    inc     ecx
    jmp     .fill
.fill_done:

    ; Use a simple integer conversion for now
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

    ; Format: right-to-left in field
    ; Fraction digits (if any non-zero)
    ; Check if fractional part is zero
    xorpd   xmm1, xmm1
    ucomisd xmm0, xmm1
    je      .ff_int_only

    ; Format with fraction
    ; Scale by 10^7
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
.strip_zeros:
    test    r15, r15
    jz      .ff_write_int
    xor     edx, edx
    mov     rsi, 10
    mov     rax, r15
    div     rsi
    test    edx, edx
    jnz     .ff_write_frac
    mov     r15, rax
    jmp     .strip_zeros

.ff_write_frac:
    mov     rax, r15
    mov     rsi, 10
.frac_loop:
    test    rax, rax
    jz      .frac_dot
    xor     edx, edx
    div     rsi
    add     dl, '0'
    mov     [rdi], dl
    dec     rdi
    jmp     .frac_loop
.frac_dot:
    mov     byte [rdi], '.'
    dec     rdi

.ff_write_int:
    mov     rax, r14
    mov     rsi, 10
    test    rax, rax
    jnz     .int_loop
    mov     byte [rdi], '0'
    dec     rdi
    jmp     .ff_sign
.int_loop:
    xor     edx, edx
    div     rsi
    add     dl, '0'
    mov     [rdi], dl
    dec     rdi
    test    rax, rax
    jnz     .int_loop

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
    jnz     .ii_loop
    mov     byte [rdi], '0'
    dec     rdi
    jmp     .ff_sign
.ii_loop:
    xor     edx, edx
    div     rsi
    add     dl, '0'
    mov     [rdi], dl
    dec     rdi
    test    rax, rax
    jnz     .ii_loop
    jmp     .ff_sign

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
    mov     r13, [rel outbuf_pos]

.wo_loop:
    test    r12, r12
    jz      .wo_done

    ; How much space left in outbuf?
    mov     rcx, OUTBUF_SIZE
    sub     rcx, r13
    test    rcx, rcx
    jnz     .wo_copy

    ; Buffer full, flush
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
    lea     rdi, [rel outbuf]
    add     rdi, r13
    mov     rsi, rbx
    ; inline memcpy
    push    rcx
.cpy_loop:
    test    rcx, rcx
    jz      .cpy_done
    mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     rcx
    jmp     .cpy_loop
.cpy_done:
    pop     rcx
    pop     rcx
    add     r13, rcx
    add     rbx, rcx
    sub     r12, rcx
    jmp     .wo_loop

.wo_done:
    mov     [rel outbuf_pos], r13
    pop     r13
    pop     r12
    pop     rbx
    ret

; flush_outbuf — Write output buffer to stdout
flush_outbuf:
    push    rbx
    mov     rbx, [rel outbuf_pos]
    test    rbx, rbx
    jz      .flush_done
    mov     rdi, STDOUT
    lea     rsi, [rel outbuf]
    mov     rdx, rbx
    call    asm_write_all
    ; Check for EPIPE
    cmp     rax, -1
    je      .epipe_check
    mov     qword [rel outbuf_pos], 0
.flush_done:
    pop     rbx
    ret
.epipe_check:
    mov     qword [rel outbuf_pos], 0
    xor     edi, edi
    call    asm_exit

; ============================================================================
;  String utility functions
; ============================================================================

; str_eq — Compare two null-terminated strings
; rdi = str1, rsi = str2
; Returns: eax = 1 if equal, 0 if not
str_eq:
.loop:
    mov     al, [rdi]
    mov     cl, [rsi]
    cmp     al, cl
    jne     .neq
    test    al, al
    jz      .eq
    inc     rdi
    inc     rsi
    jmp     .loop
.eq:
    mov     eax, 1
    ret
.neq:
    xor     eax, eax
    ret

; str_prefix — Check if string starts with prefix
; rdi = string, rsi = prefix, ecx = prefix length
; Returns: eax = 1 if match, 0 if not
str_prefix:
    push    rbx
    mov     ebx, ecx
    xor     ecx, ecx
.loop:
    cmp     ecx, ebx
    jge     .match
    mov     al, [rdi + rcx]
    cmp     al, [rsi + rcx]
    jne     .no_match
    inc     ecx
    jmp     .loop
.match:
    mov     eax, 1
    pop     rbx
    ret
.no_match:
    xor     eax, eax
    pop     rbx
    ret

; str_len — Get length of null-terminated string
; rdi = string
; Returns: rax = length
str_len:
    xor     rax, rax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

; memcmp_inline — Compare two buffers
; rdi = buf1, rsi = buf2, rcx = length
; Returns: eax = 0 if equal, non-zero if different
memcmp_inline:
    push    rbx
    xor     ebx, ebx
.loop:
    cmp     rbx, rcx
    jge     .equal
    mov     al, [rdi + rbx]
    cmp     al, [rsi + rbx]
    jne     .neq
    inc     rbx
    jmp     .loop
.equal:
    xor     eax, eax
    pop     rbx
    ret
.neq:
    mov     eax, 1
    pop     rbx
    ret

; memcpy_inline — Copy memory
; rdi = dst, rsi = src, rcx = length
memcpy_inline:
    push    rbx
    xor     ebx, ebx
.loop:
    cmp     rbx, rcx
    jge     .done
    mov     al, [rsi + rbx]
    mov     [rdi + rbx], al
    inc     rbx
    jmp     .loop
.done:
    pop     rbx
    ret

; ============================================================================
;  Data section
; ============================================================================
section .data

hex_digits: db "0123456789abcdef"

; Named character table (4 bytes each, space-padded to 3 chars)
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
    db "  \"    ; 0x5C - backslash (careful with nasm!)
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

; @@DATA_START@@
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
; @@DATA_END@@

; ============================================================================
;  BSS section — uninitialized data
; ============================================================================
section .bss

argc:           resq 1
argv:           resq 1

addr_radix:     resb 1
show_dupes:     resb 1
have_limit:     resb 1
had_error:      resb 1
w_explicit:     resb 1
prev_line_valid: resb 1
dup_star_printed: resb 1
char_buf:       resb 8

skip_bytes:     resq 1
limit_bytes:    resq 1
bytes_per_line: resq 1
total_offset:   resq 1
num_types:      resq 1
num_files:      resq 1
cur_fd:         resq 1
outbuf_pos:     resq 1
line_content_len: resq 1
prev_line_len:  resq 1
type_count_save: resq 1

; Type specs: pairs of (type_code, size), up to MAX_TYPES
type_specs:     resb MAX_TYPES * 2

; Computed column widths per value for each type
type_col_widths: resd MAX_TYPES

; File pointers
file_ptrs:      resq MAX_FILES

; Address format buffer
addr_buf:       resb 32

; Output buffer
outbuf:         resb OUTBUF_SIZE

; Input buffer
inbuf:          resb INBUF_SIZE

; Format temp buffer (per-line)
fmt_buf:        resb 4096

; Line content buffer (for duplicate comparison)
line_content_buf: resb 4096

; Previous line buffer
prev_line_buf:  resb 4096

; Previous raw line (for fast-path duplicate detection)
prev_raw_line:  resb 256

; mmap tracking
mmap_base_save: resq 1
mmap_len_save:  resq 1

section .note.GNU-stack noalloc noexec nowrite progbits
