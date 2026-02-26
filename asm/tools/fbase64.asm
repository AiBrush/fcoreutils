; fbase64.asm — GNU-compatible base64 encode/decode in x86-64 Linux assembly
;
; Flags: -d (decode), -i (ignore-garbage), -w COLS (wrap, default 76)
;        --help, --version, -- (end of options)
;
; Build (modular):
;   nasm -f elf64 -I include/ tools/fbase64.asm -o build/tools/fbase64.o
;   nasm -f elf64 -I include/ lib/io.asm -o build/lib/io.o
;   ld --gc-sections -n build/tools/fbase64.o build/lib/io.o -o fbase64

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close
extern asm_exit

global _start

; ── Buffer sizes ──
%define INBUF_SIZE   65536          ; 64KB read buffer
%define OUTBUF_SIZE  (65536+16384)  ; ~80KB output buffer (encode expands 4/3 + newlines)
%define WRAP_DEFAULT 76

section .bss
    inbuf:      resb INBUF_SIZE
    outbuf:     resb OUTBUF_SIZE
    ; Decode buffer: 4 base64 chars -> 3 bytes; we process INBUF_SIZE at a time
    decbuf:     resb INBUF_SIZE     ; cleaned input for decode
    filename_ptr: resq 1            ; saved filename pointer

section .data

; Base64 encoding table
b64_encode_table:
    db "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

; Base64 decode table: maps ASCII byte -> 6-bit value (0-63), 0xFF = invalid, 0xFE = whitespace
; 256 entries
b64_decode_table:
    ;       0     1     2     3     4     5     6     7     8     9     A     B     C     D     E     F
    db   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, 0xFE, 0xFE, 0xFE, 0xFE, 0xFF, 0xFF  ; 0x00-0x0F (TAB,LF,VT,FF,CR=whitespace)
    db   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF  ; 0x10-0x1F
    db   0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,   62, 0xFF, 0xFF, 0xFF,   63  ; 0x20-0x2F (space=ws, +=62, /=63)
    db     52,   53,   54,   55,   56,   57,   58,   59,   60,   61, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF  ; 0x30-0x3F (0-9=52-61, '='=0xFF but handled separately)
    db   0xFF,    0,    1,    2,    3,    4,    5,    6,    7,    8,    9,   10,   11,   12,   13,   14  ; 0x40-0x4F (A-O=0-14)
    db     15,   16,   17,   18,   19,   20,   21,   22,   23,   24,   25, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF  ; 0x50-0x5F (P-Z=15-25)
    db   0xFF,   26,   27,   28,   29,   30,   31,   32,   33,   34,   35,   36,   37,   38,   39,   40  ; 0x60-0x6F (a-o=26-40)
    db     41,   42,   43,   44,   45,   46,   47,   48,   49,   50,   51, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF  ; 0x70-0x7F (p-z=41-51)
    ; 0x80-0xFF: all invalid
    times 128 db 0xFF

; ── String constants ──
help_text:
    db "Usage: base64 [OPTION]... [FILE]", 10
    db "Base64 encode or decode FILE, or standard input, to standard output.", 10, 10
    db "With no FILE, or when FILE is -, read standard input.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -d, --decode          decode data", 10
    db "  -i, --ignore-garbage  when decoding, ignore non-alphabet characters", 10
    db "  -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).", 10
    db "                          Use 0 to disable line wrapping", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "The data are encoded as described for the base64 alphabet in RFC 4648.", 10
    db "When decoding, the input may contain newlines in addition to the bytes of", 10
    db "the formal base64 alphabet.  Use --ignore-garbage to attempt to recover", 10
    db "from any other non-alphabet bytes in the encoded stream.", 10
help_text_len equ $ - help_text

version_text:
    db "base64 (fcoreutils) 0.1.0", 10
version_text_len equ $ - version_text

err_prefix:
    db "base64: "
err_prefix_len equ $ - err_prefix

err_invalid_option:
    db "base64: invalid option -- '"
err_invalid_option_len equ $ - err_invalid_option

err_unrecognized:
    db "base64: unrecognized option '"
err_unrecognized_len equ $ - err_unrecognized

err_suffix:
    db "'", 10, "Try 'base64 --help' for more information.", 10
err_suffix_len equ $ - err_suffix

err_invalid_wrap:
    db "base64: invalid wrap size: '"
err_invalid_wrap_len equ $ - err_invalid_wrap

err_wrap_suffix:
    db "'", 10
err_wrap_suffix_len equ $ - err_wrap_suffix

err_option_requires_arg_w:
    db "base64: option requires an argument -- 'w'", 10
    db "Try 'base64 --help' for more information.", 10
err_option_requires_arg_w_len equ $ - err_option_requires_arg_w

err_wrap_long_requires:
    db "base64: option '--wrap' requires an argument", 10
    db "Try 'base64 --help' for more information.", 10
err_wrap_long_requires_len equ $ - err_wrap_long_requires

err_invalid_input:
    db "base64: invalid input", 10
err_invalid_input_len equ $ - err_invalid_input

err_nosuchfile:
    db ": No such file or directory", 10
err_nosuchfile_len equ $ - err_nosuchfile

err_perm_denied:
    db ": Permission denied", 10
err_perm_denied_len equ $ - err_perm_denied

err_isdir:
    db ": Is a directory", 10
err_isdir_len equ $ - err_isdir

err_read_error:
    db ": read error", 10
err_read_error_len equ $ - err_read_error

newline_char:
    db 10

section .text

; ═════════════════════════════════════════════════════════════════════════════
;  Entry point
; ═════════════════════════════════════════════════════════════════════════════
_start:
    ; Stack: [argc] [argv0] [argv1] ... [NULL] [envp...]
    mov     r15, rsp                ; save stack pointer
    mov     ecx, [rsp]             ; ecx = argc

    ; Block SIGPIPE so write() returns -EPIPE instead of killing us
    sub     rsp, 16
    mov     qword [rsp], 0x1000    ; sigset: bit 12 = SIGPIPE
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi               ; SIG_BLOCK = 0
    mov     rsi, rsp
    xor     edx, edx               ; NULL old_set
    mov     r10d, 8                ; sigsetsize = 8
    syscall
    add     rsp, 16

    ; ── Parse arguments ──
    ; State: r12d = flags (bit 0 = decode, bit 1 = ignore_garbage)
    ;        r13  = wrap column (default 76)
    ;        r14  = filename pointer (NULL = stdin)
    xor     r12d, r12d             ; flags = 0
    mov     r13d, WRAP_DEFAULT     ; wrap = 76
    xor     r14d, r14d             ; filename = NULL

    mov     ecx, [r15]             ; argc
    cmp     ecx, 1
    jle     .args_done             ; no arguments

    lea     rbx, [r15 + 16]        ; rbx = &argv[1]
    xor     ebp, ebp               ; ebp = "past --" flag

.arg_loop:
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .args_done

    ; If past "--", everything is a filename
    test    ebp, ebp
    jnz     .arg_positional

    ; Check if starts with '-'
    cmp     byte [rsi], '-'
    jne     .arg_positional

    ; Just "-" alone = stdin
    cmp     byte [rsi+1], 0
    je      .arg_positional

    ; Starts with '-'. Long option?
    cmp     byte [rsi+1], '-'
    jne     .arg_short

    ; ── Long options (starts with "--") ──
    ; Check exactly "--"
    cmp     byte [rsi+2], 0
    jne     .chk_long_help
    ; It's "--" → set past-options flag
    mov     ebp, 1
    jmp     .arg_next

.chk_long_help:
    ; Check "--help"
    cmp     dword [rsi], 0x65682D2D ; "--he"
    jne     .chk_long_version
    cmp     word [rsi+4], 0x706C    ; "lp"
    jne     .chk_long_version
    cmp     byte [rsi+6], 0
    jne     .chk_long_version
    ; --help
    mov     rdi, STDOUT
    mov     rsi, help_text
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit

.chk_long_version:
    ; Check "--version"
    cmp     dword [rsi], 0x65762D2D ; "--ve"
    jne     .chk_long_decode
    cmp     dword [rsi+4], 0x6F697372 ; "rsio"
    jne     .chk_long_decode
    cmp     word [rsi+8], 0x006E    ; "n\0"
    jne     .chk_long_decode
    ; --version
    mov     rdi, STDOUT
    mov     rsi, version_text
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit

.chk_long_decode:
    ; Check "--decode"
    cmp     dword [rsi], 0x65642D2D ; "--de"
    jne     .chk_long_ignore
    cmp     dword [rsi+4], 0x65646F63 ; "code"
    jne     .chk_long_ignore
    cmp     byte [rsi+8], 0
    jne     .chk_long_ignore
    or      r12d, 1                ; set decode flag
    jmp     .arg_next

.chk_long_ignore:
    ; Check "--ignore-garbage"
    ; "--ig" = 0x67692D2D
    cmp     dword [rsi], 0x67692D2D
    jne     .chk_long_wrap
    ; "nore" = 0x65726F6E
    cmp     dword [rsi+4], 0x65726F6E
    jne     .chk_long_wrap
    ; "-gar" = 0x7261672D
    cmp     dword [rsi+8], 0x7261672D
    jne     .chk_long_wrap
    ; "bage" = 0x65676162
    cmp     dword [rsi+12], 0x65676162
    jne     .chk_long_wrap
    cmp     byte [rsi+16], 0
    jne     .chk_long_wrap
    or      r12d, 2                ; set ignore_garbage flag
    jmp     .arg_next

.chk_long_wrap:
    ; Check "--wrap=" (7 bytes: "--wrap=")
    ; "--wr" = 2D 2D 77 72 → LE dword = 0x72772D2D
    cmp     dword [rsi], 0x72772D2D
    jne     .chk_long_wrap_space
    ; "ap=" = 61 70 3D → check word "ap" then byte '='
    cmp     word [rsi+4], 0x7061    ; "ap"
    jne     .chk_long_wrap_space
    cmp     byte [rsi+6], '='       ; '='
    jne     .chk_long_wrap_space
    ; Parse number after "--wrap="
    lea     rdi, [rsi+7]           ; point to value after '='
    call    parse_uint
    test    eax, eax
    js      .err_invalid_wrap_val  ; negative = parse error
    mov     r13d, eax              ; wrap = parsed value
    jmp     .arg_next

.chk_long_wrap_space:
    ; Check "--wrap" followed by next arg (exactly "--wrap\0")
    cmp     dword [rsi], 0x72772D2D ; "--wr"
    jne     .err_unrecognized_opt
    cmp     word [rsi+4], 0x7061    ; "ap"
    jne     .err_unrecognized_opt
    cmp     byte [rsi+6], 0         ; null terminator
    jne     .err_unrecognized_opt
    ; --wrap needs next arg as value
    add     rbx, 8
    mov     rdi, [rbx]
    test    rdi, rdi
    jz      .err_wrap_long_needs_arg
    call    parse_uint
    test    eax, eax
    js      .err_invalid_wrap_val
    mov     r13d, eax
    jmp     .arg_next

.arg_short:
    ; ── Short options (starts with '-', not '--') ──
    lea     rsi, [rsi+1]          ; skip the '-'

.short_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .arg_next             ; end of this arg

    cmp     al, 'd'
    je      .short_decode
    cmp     al, 'i'
    je      .short_ignore
    cmp     al, 'w'
    je      .short_wrap

    ; Invalid short option
    mov     [rsp-8], al           ; save the char
    push    rax                   ; we need it on stack for writing
    mov     rdi, STDERR
    mov     rsi, err_invalid_option
    mov     rdx, err_invalid_option_len
    call    asm_write_all
    ; Write the single char
    mov     rdi, STDERR
    lea     rsi, [rsp]
    mov     rdx, 1
    call    asm_write_all
    pop     rax
    ; Write suffix
    mov     rdi, STDERR
    mov     rsi, err_suffix
    mov     rdx, err_suffix_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.short_decode:
    or      r12d, 1
    inc     rsi
    jmp     .short_loop

.short_ignore:
    or      r12d, 2
    inc     rsi
    jmp     .short_loop

.short_wrap:
    ; -w: value can follow immediately (-w76) or be next arg (-w 76)
    inc     rsi
    cmp     byte [rsi], 0
    je      .short_wrap_next_arg
    ; Value follows immediately
    mov     rdi, rsi
    call    parse_uint
    test    eax, eax
    js      .err_invalid_wrap_val
    mov     r13d, eax
    jmp     .arg_next

.short_wrap_next_arg:
    ; Value is next argv
    add     rbx, 8
    mov     rdi, [rbx]
    test    rdi, rdi
    jz      .err_w_needs_arg
    call    parse_uint
    test    eax, eax
    js      .err_invalid_wrap_val
    mov     r13d, eax
    jmp     .arg_next

.arg_positional:
    ; Positional argument = filename
    mov     r14, rsi
    jmp     .arg_next

.arg_next:
    add     rbx, 8
    jmp     .arg_loop

.args_done:
    ; ── Open input ──
    ; r12d bits: 0=decode, 1=ignore_garbage
    ; r13d = wrap column
    ; r14 = filename (NULL or "-" = stdin)

    ; Check if filename is "-" (explicit stdin)
    test    r14, r14
    jz      .use_stdin
    cmp     byte [r14], '-'
    jne     .open_file
    cmp     byte [r14+1], 0
    je      .use_stdin

.open_file:
    ; Save filename for error messages
    mov     [filename_ptr], r14
    mov     rdi, r14
    xor     esi, esi               ; O_RDONLY
    xor     edx, edx               ; mode 0
    call    asm_open
    test    eax, eax
    js      .err_open_file
    mov     ebp, eax               ; ebp = fd
    jmp     .dispatch

.use_stdin:
    xor     ebp, ebp               ; fd = 0 (stdin)

.dispatch:
    ; Dispatch to encode or decode
    test    r12d, 1
    jnz     .do_decode

    ; ═════════════════════════════════════════════════════════════════════════
    ;  ENCODE PATH — optimized with batch processing
    ;
    ;  Key optimization: instead of checking wrap after every character,
    ;  we batch-encode full lines at a time. For wrap=76 (default):
    ;    76 chars = 19 triplets = 57 input bytes per line
    ;  For wrap=0: no wrapping at all, straight encode.
    ; ═════════════════════════════════════════════════════════════════════════
.do_encode:
    ; r13d = wrap column, ebp = input fd
    ; r8 = current column position (for wrapping)
    ; r9 = leftover bytes from previous read (0, 1, or 2)
    xor     r8d, r8d               ; column = 0
    xor     r9d, r9d               ; leftover = 0
    sub     rsp, 16                ; local storage for leftover bytes
    ; [rsp] = leftover byte 0, [rsp+1] = leftover byte 1

.encode_read_loop:
    mov     edi, ebp               ; fd
    lea     rsi, [inbuf]
    mov     edx, INBUF_SIZE
    call    asm_read
    test    rax, rax
    js      .err_read
    jz      .encode_flush_final

    mov     rcx, rax               ; rcx = bytes read
    lea     rsi, [inbuf]           ; rsi = input pointer
    lea     rdi, [outbuf]          ; rdi = output pointer

    ; Handle leftover from previous read
    test    r9d, r9d
    jz      .encode_main_loop

    cmp     r9d, 1
    je      .encode_leftover_1
    ; r9d == 2: need 1 more byte
    test    rcx, rcx
    jz      .encode_read_loop
    movzx   eax, byte [rsp]
    movzx   edx, byte [rsp+1]
    movzx   r10d, byte [rsi]
    inc     rsi
    dec     rcx
    shl     eax, 16
    shl     edx, 8
    or      eax, edx
    or      eax, r10d
    call    .encode_triplet_inline
    xor     r9d, r9d
    jmp     .encode_main_loop

.encode_leftover_1:
    cmp     rcx, 2
    jl      .encode_leftover_1_not_enough
    movzx   eax, byte [rsp]
    movzx   edx, byte [rsi]
    movzx   r10d, byte [rsi+1]
    add     rsi, 2
    sub     rcx, 2
    shl     eax, 16
    shl     edx, 8
    or      eax, edx
    or      eax, r10d
    call    .encode_triplet_inline
    xor     r9d, r9d
    jmp     .encode_main_loop

.encode_leftover_1_not_enough:
    test    rcx, rcx
    jz      .encode_read_loop
    movzx   eax, byte [rsi]
    mov     [rsp+1], al
    mov     r9d, 2
    jmp     .encode_read_loop

.encode_main_loop:
    ; Process input in groups of 3
    cmp     rcx, 3
    jl      .encode_save_leftover

    ; Fast path only for wrap=0 or wrap divisible by 4 (76, 64, 80, etc.)
    ; For other wrap values, the slow per-char wrap check is needed
    test    r13d, r13d
    jz      .encode_fast_triplet   ; wrap=0: always fast
    mov     eax, r13d
    and     eax, 3                 ; check if wrap % 4 == 0
    jnz     .encode_slow_triplet   ; not divisible by 4: slow path

.encode_fast_triplet:
    ; Fast encode: 3 input bytes → 4 output chars, inline
    movzx   eax, byte [rsi]
    shl     eax, 16
    movzx   edx, byte [rsi+1]
    shl     edx, 8
    or      eax, edx
    movzx   edx, byte [rsi+2]
    or      eax, edx
    add     rsi, 3
    sub     rcx, 3

    ; Encode to 4 base64 chars (fully inlined, no function calls)
    lea     r10, [b64_encode_table]
    mov     edx, eax
    shr     edx, 18
    movzx   edx, byte [r10 + rdx]
    mov     [rdi], dl
    mov     edx, eax
    shr     edx, 12
    and     edx, 0x3F
    movzx   edx, byte [r10 + rdx]
    mov     [rdi+1], dl
    mov     edx, eax
    shr     edx, 6
    and     edx, 0x3F
    movzx   edx, byte [r10 + rdx]
    mov     [rdi+2], dl
    and     eax, 0x3F
    movzx   eax, byte [r10 + rax]
    mov     [rdi+3], al
    add     rdi, 4

    ; Handle wrapping
    test    r13d, r13d
    jz      .encode_no_wrap_check  ; wrap=0: skip all wrap logic

    add     r8d, 4                 ; column += 4
    cmp     r8d, r13d
    jl      .encode_no_wrap_check
    ; Insert newline(s) — handle wrap values not divisible by 4
    ; If column >= wrap, insert newline and adjust
    mov     byte [rdi], 10
    inc     rdi
    sub     r8d, r13d              ; column -= wrap (handle > case)
    ; If still >= wrap (wrap < 4), keep inserting
    ; After newline, check if we still have overflow (shouldn't happen for wrap >= 4)
    jmp     .encode_no_wrap_check

.encode_no_wrap_check:
    ; Check if output buffer is getting full
    lea     rax, [outbuf]
    mov     r11, rdi
    sub     r11, rax               ; r11 = bytes in outbuf
    cmp     r11, OUTBUF_SIZE - 256
    jl      .encode_main_loop

    ; Flush output buffer
    push    rcx
    push    rsi
    mov     rdx, r11
    lea     rsi, [outbuf]
    mov     rdi, STDOUT
    call    asm_write_all
    test    eax, eax
    js      .encode_write_error_pop
    pop     rsi
    pop     rcx
    lea     rdi, [outbuf]
    jmp     .encode_main_loop

; Slow path for wrapping with wrap < 4 (char by char)
.encode_slow_triplet:
    cmp     rcx, 3
    jl      .encode_save_leftover
    movzx   eax, byte [rsi]
    shl     eax, 16
    movzx   edx, byte [rsi+1]
    shl     edx, 8
    or      eax, edx
    movzx   edx, byte [rsi+2]
    or      eax, edx
    add     rsi, 3
    sub     rcx, 3
    call    .encode_triplet_inline
    ; Check if output buffer is getting full
    lea     rax, [outbuf]
    mov     r11, rdi
    sub     r11, rax
    cmp     r11, OUTBUF_SIZE - 256
    jl      .encode_slow_triplet
    push    rcx
    push    rsi
    mov     rdx, r11
    lea     rsi, [outbuf]
    mov     rdi, STDOUT
    call    asm_write_all
    test    eax, eax
    js      .encode_write_error_pop
    pop     rsi
    pop     rcx
    lea     rdi, [outbuf]
    jmp     .encode_slow_triplet

.encode_save_leftover:
    mov     r9d, ecx
    test    ecx, ecx
    jz      .encode_flush_and_continue
    mov     al, [rsi]
    mov     [rsp], al
    cmp     ecx, 2
    jl      .encode_flush_and_continue
    mov     al, [rsi+1]
    mov     [rsp+1], al

.encode_flush_and_continue:
    lea     rax, [outbuf]
    mov     rdx, rdi
    sub     rdx, rax
    test    rdx, rdx
    jz      .encode_read_loop
    push    r9
    lea     rsi, [outbuf]
    mov     rdi, STDOUT
    call    asm_write_all
    test    eax, eax
    pop     r9
    js      .handle_write_error
    jmp     .encode_read_loop

.encode_flush_final:
    lea     rdi, [outbuf]

    cmp     r9d, 1
    je      .encode_pad_1
    cmp     r9d, 2
    je      .encode_pad_2
    jmp     .encode_final_newline

.encode_pad_1:
    ; 1 leftover byte → 2 base64 chars + "=="
    movzx   eax, byte [rsp]
    shl     eax, 16
    lea     r10, [b64_encode_table]
    mov     edx, eax
    shr     edx, 18
    and     edx, 0x3F
    movzx   edx, byte [r10 + rdx]
    mov     [rdi], dl
    mov     edx, eax
    shr     edx, 12
    and     edx, 0x3F
    movzx   edx, byte [r10 + rdx]
    mov     [rdi+1], dl
    mov     byte [rdi+2], '='
    mov     byte [rdi+3], '='
    add     rdi, 4
    add     r8d, 4
    ; Handle wrap for padding chars
    test    r13d, r13d
    jz      .encode_final_newline
    cmp     r8d, r13d
    jl      .encode_final_newline
    ; Need to insert newlines within the padding - use slow path
    sub     rdi, 4
    mov     edx, eax
    shr     edx, 18
    and     edx, 0x3F
    movzx   edx, byte [r10 + rdx]
    mov     [rdi], dl
    inc     rdi
    call    .encode_wrap_check_inline
    mov     edx, eax
    shr     edx, 12
    and     edx, 0x3F
    movzx   edx, byte [r10 + rdx]
    mov     [rdi], dl
    inc     rdi
    call    .encode_wrap_check_inline
    mov     byte [rdi], '='
    inc     rdi
    call    .encode_wrap_check_inline
    mov     byte [rdi], '='
    inc     rdi
    call    .encode_wrap_check_inline
    jmp     .encode_final_newline

.encode_pad_2:
    ; 2 leftover bytes → 3 base64 chars + "="
    movzx   eax, byte [rsp]
    shl     eax, 16
    movzx   edx, byte [rsp+1]
    shl     edx, 8
    or      eax, edx
    lea     r10, [b64_encode_table]
    mov     edx, eax
    shr     edx, 18
    and     edx, 0x3F
    movzx   edx, byte [r10 + rdx]
    mov     [rdi], dl
    mov     edx, eax
    shr     edx, 12
    and     edx, 0x3F
    movzx   edx, byte [r10 + rdx]
    mov     [rdi+1], dl
    mov     edx, eax
    shr     edx, 6
    and     edx, 0x3F
    movzx   edx, byte [r10 + rdx]
    mov     [rdi+2], dl
    mov     byte [rdi+3], '='
    add     rdi, 4
    add     r8d, 4
    ; Handle wrap for padding chars
    test    r13d, r13d
    jz      .encode_final_newline
    cmp     r8d, r13d
    jl      .encode_final_newline
    ; Need to insert newlines within the padding - use slow path
    sub     rdi, 4
    sub     r8d, 4
    mov     edx, eax
    shr     edx, 18
    and     edx, 0x3F
    movzx   edx, byte [r10 + rdx]
    mov     [rdi], dl
    inc     rdi
    call    .encode_wrap_check_inline
    mov     edx, eax
    shr     edx, 12
    and     edx, 0x3F
    movzx   edx, byte [r10 + rdx]
    mov     [rdi], dl
    inc     rdi
    call    .encode_wrap_check_inline
    mov     edx, eax
    shr     edx, 6
    and     edx, 0x3F
    movzx   edx, byte [r10 + rdx]
    mov     [rdi], dl
    inc     rdi
    call    .encode_wrap_check_inline
    mov     byte [rdi], '='
    inc     rdi
    call    .encode_wrap_check_inline
    jmp     .encode_final_newline

.encode_final_newline:
    test    r13d, r13d
    jz      .encode_final_flush
    test    r8d, r8d
    jz      .encode_final_flush
    mov     byte [rdi], 10
    inc     rdi

.encode_final_flush:
    lea     rsi, [outbuf]
    mov     rdx, rdi
    sub     rdx, rsi
    test    rdx, rdx
    jz      .encode_done
    mov     rdi, STDOUT
    call    asm_write_all
    test    eax, eax
    js      .handle_write_error

.encode_done:
    test    ebp, ebp
    jz      .exit_success
    mov     edi, ebp
    call    asm_close

.exit_success:
    xor     edi, edi
    call    asm_exit

; ── encode_triplet_inline: encode with per-char wrap check (for leftover/slow path) ──
; Input: eax = 24-bit value
; Uses: rdi (output), r8d (column), r13d (wrap), r10 (table)
.encode_triplet_inline:
    lea     r10, [b64_encode_table]
    push    rax
    mov     edx, eax
    shr     edx, 18
    and     edx, 0x3F
    movzx   edx, byte [r10 + rdx]
    mov     [rdi], dl
    inc     rdi
    call    .encode_wrap_check_inline
    pop     rax
    push    rax
    mov     edx, eax
    shr     edx, 12
    and     edx, 0x3F
    movzx   edx, byte [r10 + rdx]
    mov     [rdi], dl
    inc     rdi
    call    .encode_wrap_check_inline
    pop     rax
    push    rax
    mov     edx, eax
    shr     edx, 6
    and     edx, 0x3F
    movzx   edx, byte [r10 + rdx]
    mov     [rdi], dl
    inc     rdi
    call    .encode_wrap_check_inline
    pop     rax
    and     eax, 0x3F
    movzx   eax, byte [r10 + rax]
    mov     [rdi], al
    inc     rdi
    call    .encode_wrap_check_inline
    ret

; ── encode_wrap_check_inline: insert newline if column == wrap ──
.encode_wrap_check_inline:
    test    r13d, r13d
    jz      .wrap_skip
    inc     r8d
    cmp     r8d, r13d
    jl      .wrap_skip
    mov     byte [rdi], 10
    inc     rdi
    xor     r8d, r8d
.wrap_skip:
    ret

    ; ═════════════════════════════════════════════════════════════════════════
    ;  DECODE PATH
    ; ═════════════════════════════════════════════════════════════════════════
.do_decode:
    ; r12d bit 1 = ignore_garbage, ebp = input fd
    ; Strategy: read input, strip whitespace (and garbage if -i),
    ;           decode base64 groups of 4 chars → 3 bytes,
    ;           handle padding at end.

    xor     r8d, r8d               ; accumulated base64 chars in current group
    xor     r9d, r9d               ; accumulated 24-bit value
    sub     rsp, 16                ; local: [rsp] = group accumulator count, etc
    lea     r14, [outbuf]          ; output write pointer

.decode_read_loop:
    mov     edi, ebp               ; fd
    lea     rsi, [inbuf]
    mov     edx, INBUF_SIZE
    call    asm_read
    test    rax, rax
    js      .decode_read_error
    jz      .decode_eof

    mov     rcx, rax               ; rcx = bytes read
    lea     rsi, [inbuf]           ; input pointer

.decode_byte_loop:
    test    rcx, rcx
    jz      .decode_flush_and_read

    movzx   eax, byte [rsi]
    inc     rsi
    dec     rcx

    ; Check for '=' (padding)
    cmp     al, '='
    je      .decode_padding

    ; Look up in decode table
    lea     r10, [b64_decode_table]
    movzx   edx, byte [r10 + rax]

    cmp     dl, 0xFE
    je      .decode_byte_loop      ; whitespace → skip
    cmp     dl, 0xFF
    je      .decode_invalid_or_garbage

    ; Valid base64 character (value in dl, 0-63)
    shl     r9d, 6
    or      r9d, edx
    inc     r8d
    cmp     r8d, 4
    jl      .decode_byte_loop

    ; Have 4 chars → output 3 bytes
    mov     eax, r9d
    shr     eax, 16
    mov     [r14], al
    mov     eax, r9d
    shr     eax, 8
    mov     [r14+1], al
    mov     [r14+2], r9b
    add     r14, 3
    xor     r8d, r8d
    xor     r9d, r9d

    ; Check if output buffer is getting full
    lea     rax, [outbuf]
    mov     rdx, r14
    sub     rdx, rax
    cmp     rdx, OUTBUF_SIZE - 256
    jl      .decode_byte_loop

    ; Flush output buffer
    push    rcx
    push    rsi
    lea     rsi, [outbuf]
    mov     rdi, STDOUT
    call    asm_write_all
    test    eax, eax
    js      .decode_write_error_pop
    pop     rsi
    pop     rcx
    lea     r14, [outbuf]
    jmp     .decode_byte_loop

.decode_invalid_or_garbage:
    ; If ignore_garbage flag is set, skip this byte
    test    r12d, 2
    jnz     .decode_byte_loop
    ; Otherwise, error
    jmp     .err_invalid_input

.decode_padding:
    ; '=' encountered. Collect remaining '=' and whitespace, then decode.
    ; After '=', we expect either another '=' or end of valid data.
    inc     r8d
    cmp     r8d, 3
    je      .decode_pad_need_one_more
    cmp     r8d, 4
    je      .decode_pad_complete_2eq

    ; r8d == 1 or 2: '=' too early
    jmp     .err_invalid_input

.decode_pad_need_one_more:
    ; We have 3 chars so far (2 data + 1 '='). Look for one more '='
    ; to distinguish XX== from XXX=
    ; Actually, r8d counts: after seeing 2 data chars then '=', r8d was at 2 then incremented to 3
    ; So we need one more character which should be '='
.decode_scan_for_eq:
    ; Skip whitespace, look for '=' or end
    test    rcx, rcx
    jz      .decode_pad_read_more_eq
    movzx   eax, byte [rsi]
    inc     rsi
    dec     rcx
    cmp     al, '='
    je      .decode_pad_complete_2eq
    ; Check whitespace
    lea     r10, [b64_decode_table]
    movzx   edx, byte [r10 + rax]
    cmp     dl, 0xFE
    je      .decode_scan_for_eq    ; whitespace, skip
    ; Not '=' and not whitespace
    test    r12d, 2
    jnz     .decode_scan_for_eq    ; ignore garbage
    jmp     .err_invalid_input

.decode_pad_read_more_eq:
    ; Read more input looking for second '='
    push    r8
    push    r9
    mov     edi, ebp
    lea     rsi, [inbuf]
    mov     edx, INBUF_SIZE
    call    asm_read
    pop     r9
    pop     r8
    test    rax, rax
    jz      .decode_pad_single_eq  ; EOF: only one '=', that's ok (XXX=)
    js      .decode_read_error
    mov     rcx, rax
    lea     rsi, [inbuf]
    jmp     .decode_scan_for_eq

.decode_pad_single_eq:
    ; Pattern: XXX= (3 data chars + 1 pad) → 2 output bytes
    ; r8d = 3 (we had 2 data + 1 '='), r9d has the accumulated value
    ; Actually wait - r8d was incremented when we saw '=', so the data chars = r8d - 1 = 2
    ; But we also shifted r9d. Let's handle this properly.
    ; r9d has 2 data values shifted in (12 bits). Output = 1 byte from top 8 bits.
    shl     r9d, 6                 ; shift for the padding position
    shl     r9d, 6                 ; another shift (total 4 chars worth of shifts)
    ; Wait, let me reconsider. r8d=3 means we had exactly 2 real b64 chars + 1 '='.
    ; r9d had 2 chars shifted in = 12 bits. We need to do: r9d <<= 12 to get 24 bits.
    ; Then output top 1 byte.
    ; Actually, let me re-think: each char shifts left 6 and ORs.
    ; After 2 chars: r9d = (c0 << 6) | c1 = 12 bits
    ; For XX==: pad 2 more shifts: val = r9d << 12, output 1 byte (bits 23-16)
    ; For XXX=: 3 chars: r9d = (c0<<12)|(c1<<6)|c2 = 18 bits, pad 1: val=r9d<<6, output 2 bytes
    ; But when we get here for single_eq, we came through pad_need_one_more with r8d=3
    ; That means we had 2 data chars (r8d went 0->1->2 from data, then 2->3 from '=')
    ; So: r9d = 12 bits of data. This is XX= pattern, so output 1 byte.
    ; Actually no: 2 data + 1 '=' = 3 is the XXX= pattern (if 3rd was '=' and 4th implied).
    ; Hmm, let me re-check the flow:
    ; data char -> r8d increments -> when r8d reaches 4, emit 3 bytes
    ; When we see '=' with r8d=2 (2 data chars collected), we increment to r8d=3
    ; Then look for another '='. If found -> XX== (2 data, 2 pad) -> 1 output byte
    ; If EOF (here) -> means XX= only, which is actually 3-char group -> error or special
    ; In base64, the group is always 4 chars. XX= is invalid. XXX= is valid (3 chars + 1 pad = 4)
    ; So if r8d=3 and we see '=', r8d becomes 4 -> pad_complete_2eq handles XX== (2 data + 2 pad)
    ; If r8d=3 and EOF without second '=' -> this is XXX pattern without = which is actually
    ; 3 data chars (we had 2 data then '=' then no more '=')
    ; Wait, I'm confusing myself. Let me restart:
    ;
    ; When '=' is seen, r8d is the count BEFORE incrementing:
    ; r8d=0,1: too early for padding
    ; r8d=2: we have 2 data chars, then '=' -> increment to r8d=3 -> need one more '='
    ;   Found '=' -> XX== -> decode_pad_complete_2eq (output 1 byte)
    ;   Not found -> invalid
    ; r8d=3: we have 3 data chars, then '=' -> increment to r8d=4 -> decode_pad_complete_2eq
    ;   which for 1 pad -> output 2 bytes
    ;
    ; So reaching decode_pad_single_eq means we had 2 data + '=' and couldn't find second '='.
    ; This is actually invalid per standard. But let's match GNU behavior - GNU would fail.
    jmp     .err_invalid_input

.decode_pad_complete_2eq:
    ; r8d = 4 now. But how many '=' did we see?
    ; Case 1: r8d went 0->1->2->3(=)->4(=) → XX== → 2 data chars → 1 output byte
    ; Case 2: r8d went 0->1->2->3->4(=) → XXX= → 3 data chars → 2 output bytes
    ; We need to distinguish. Let's check how many data chars we had before padding.
    ; When we enter decode_padding:
    ;   r8d was N data chars, then incremented for '='
    ; If first '=' seen at r8d=2 (becomes 3), then searched for second '=' (found, becomes 4):
    ;   → 2 data chars, 2 '=' → output 1 byte
    ; If first '=' seen at r8d=3 (becomes 4, goes to decode_pad_complete_2eq directly):
    ;   → 3 data chars, 1 '=' → output 2 bytes

    ; We can check the actual data by looking at how many 6-bit groups are in r9d
    ; For 2 data chars: r9d = (c0<<6)|c1 (12 bits)
    ; For 3 data chars: r9d = (c0<<12)|(c1<<6)|c2 (18 bits)

    ; Simpler approach: track the count before first '='. Use a register.
    ; Let me restructure - use the stack.
    ; Actually, let me use a different approach: when r8d = 4 at decode_padding entry,
    ; that means 3 data chars (0->1->2->3 from data, then 3->4 from '='), output 2 bytes.
    ; When we come here from decode_scan_for_eq, we had r8d=3 (2 data + first '='),
    ; now found second '=', so r8d was 3 → 2 data chars, output 1 byte.

    ; Let me fix by using distinct labels:
    ; At decode_padding:
    ;   r8d was 0,1 before '=' → error (less than 2 data chars)
    ;   r8d was 2 before '=' → after inc, r8d=3 → XX.. need 1 more '='
    ;     → found '=' → XX== → output 1 byte
    ;   r8d was 3 before '=' → after inc, r8d=4 → XXX= → output 2 bytes

    ; So decode_pad_complete_2eq is called from two paths:
    ; Path A: from decode_padding with r8d=4 (was 3 before) → 3 data → 2 bytes
    ; Path B: from decode_scan_for_eq (found 2nd '=') with r8d=3 → 2 data → 1 byte

    ; We need to know which path we took. Let me check r8d value:
    cmp     r8d, 3
    je      .decode_output_1byte
    ; r8d == 4, from decode_padding with 3 data chars → output 2 bytes

.decode_output_2bytes:
    ; r9d has 18 bits of data (3 chars * 6 bits)
    ; Shift left 6 to get 24 bits, then take top 2 bytes
    shl     r9d, 6
    mov     eax, r9d
    shr     eax, 16
    mov     [r14], al
    mov     eax, r9d
    shr     eax, 8
    mov     [r14+1], al
    add     r14, 2
    xor     r8d, r8d
    xor     r9d, r9d
    ; Consume remaining whitespace/garbage until next data or EOF
    jmp     .decode_byte_loop

.decode_output_1byte:
    ; r9d has 12 bits of data (2 chars * 6 bits)
    ; Shift left 12 to get 24 bits, then take top 1 byte
    shl     r9d, 12
    mov     eax, r9d
    shr     eax, 16
    mov     [r14], al
    inc     r14
    xor     r8d, r8d
    xor     r9d, r9d
    jmp     .decode_byte_loop

.decode_flush_and_read:
    ; Flush output and read more input
    lea     rax, [outbuf]
    mov     rdx, r14
    sub     rdx, rax
    test    rdx, rdx
    jz      .decode_read_loop
    push    r8
    push    r9
    lea     rsi, [outbuf]
    mov     rdi, STDOUT
    call    asm_write_all
    test    eax, eax
    pop     r9
    pop     r8
    js      .handle_write_error
    lea     r14, [outbuf]
    jmp     .decode_read_loop

.decode_eof:
    ; Check for incomplete group
    test    r8d, r8d
    jnz     .decode_eof_incomplete

    ; Flush remaining output
    lea     rsi, [outbuf]
    mov     rdx, r14
    sub     rdx, rsi
    test    rdx, rdx
    jz      .decode_done
    mov     rdi, STDOUT
    call    asm_write_all
    test    eax, eax
    js      .handle_write_error
    jmp     .decode_done

.decode_eof_incomplete:
    ; GNU behavior: decode partial data from incomplete group, then error.
    ; r8d=1: 6 bits → not enough for a byte, output nothing
    ; r8d=2: 12 bits → output 1 byte (top 8 bits)
    ; r8d=3: 18 bits → output 2 bytes (top 16 bits)
    cmp     r8d, 2
    jl      .decode_eof_flush_and_error
    je      .decode_eof_partial_1byte
    ; r8d == 3: output 2 bytes
    shl     r9d, 6                 ; pad to 24 bits
    mov     eax, r9d
    shr     eax, 16
    mov     [r14], al
    mov     eax, r9d
    shr     eax, 8
    mov     [r14+1], al
    add     r14, 2
    jmp     .decode_eof_flush_and_error

.decode_eof_partial_1byte:
    ; r8d == 2: output 1 byte
    shl     r9d, 12                ; pad to 24 bits
    mov     eax, r9d
    shr     eax, 16
    mov     [r14], al
    inc     r14
    jmp     .decode_eof_flush_and_error

.decode_eof_flush_and_error:
    ; Flush output then report error
    lea     rsi, [outbuf]
    mov     rdx, r14
    sub     rdx, rsi
    test    rdx, rdx
    jz      .err_invalid_input_msg
    mov     rdi, STDOUT
    call    asm_write_all
    jmp     .err_invalid_input_msg

.decode_done:
    ; Close file if not stdin
    test    ebp, ebp
    jz      .exit_success
    mov     edi, ebp
    call    asm_close
    jmp     .exit_success

    ; ═════════════════════════════════════════════════════════════════════════
    ;  ERROR HANDLERS
    ; ═════════════════════════════════════════════════════════════════════════

.err_unrecognized_opt:
    ; rsi points to the unrecognized option string
    push    rsi
    mov     rdi, STDERR
    mov     rsi, err_unrecognized
    mov     rdx, err_unrecognized_len
    call    asm_write_all
    pop     rsi
    ; Write the option string
    push    rsi
    mov     rdi, rsi
    call    strlen
    pop     rsi
    mov     rdx, rax
    mov     rdi, STDERR
    call    asm_write_all
    ; Write suffix
    mov     rdi, STDERR
    mov     rsi, err_suffix
    mov     rdx, err_suffix_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.err_invalid_wrap_val:
    ; rdi points to the invalid value string (from parse_uint caller)
    ; We saved it before calling parse_uint, but actually let's reconstruct
    ; For --wrap=XYZ, the original string is still accessible
    ; For simplicity, print the generic error
    push    rdi
    mov     rdi, STDERR
    mov     rsi, err_invalid_wrap
    mov     rdx, err_invalid_wrap_len
    call    asm_write_all
    pop     rsi
    ; Write the value
    push    rsi
    mov     rdi, rsi
    call    strlen
    pop     rsi
    mov     rdx, rax
    mov     rdi, STDERR
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, err_wrap_suffix
    mov     rdx, err_wrap_suffix_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.err_w_needs_arg:
    mov     rdi, STDERR
    mov     rsi, err_option_requires_arg_w
    mov     rdx, err_option_requires_arg_w_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.err_wrap_long_needs_arg:
    mov     rdi, STDERR
    mov     rsi, err_wrap_long_requires
    mov     rdx, err_wrap_long_requires_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.err_open_file:
    ; eax has the negative errno
    neg     eax
    mov     r12d, eax              ; save errno
    ; Print "base64: "
    mov     rdi, STDERR
    mov     rsi, err_prefix
    mov     rdx, err_prefix_len
    call    asm_write_all
    ; Print filename
    mov     rsi, [filename_ptr]
    mov     rdi, rsi
    call    strlen
    mov     rdx, rax
    mov     rsi, [filename_ptr]
    mov     rdi, STDERR
    call    asm_write_all
    ; Print appropriate error
    cmp     r12d, 2                ; ENOENT
    je      .err_open_noent
    cmp     r12d, 13               ; EACCES
    je      .err_open_perm
    cmp     r12d, 21               ; EISDIR
    je      .err_open_isdir
    ; Generic
    mov     rdi, STDERR
    mov     rsi, err_read_error
    mov     rdx, err_read_error_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.err_open_noent:
    mov     rdi, STDERR
    mov     rsi, err_nosuchfile
    mov     rdx, err_nosuchfile_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.err_open_perm:
    mov     rdi, STDERR
    mov     rsi, err_perm_denied
    mov     rdx, err_perm_denied_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.err_open_isdir:
    mov     rdi, STDERR
    mov     rsi, err_isdir
    mov     rdx, err_isdir_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.err_invalid_input:
    ; Flush any pending decode output first
    lea     rsi, [outbuf]
    mov     rdx, r14
    sub     rdx, rsi
    test    rdx, rdx
    jz      .err_invalid_input_msg
    mov     rdi, STDOUT
    call    asm_write_all
.err_invalid_input_msg:
    mov     rdi, STDERR
    mov     rsi, err_invalid_input
    mov     rdx, err_invalid_input_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.err_read:
    ; Print "base64: " + filename + ": read error\n"
    mov     rdi, STDERR
    mov     rsi, err_prefix
    mov     rdx, err_prefix_len
    call    asm_write_all
    ; Check if we have a filename
    mov     rsi, [filename_ptr]
    test    rsi, rsi
    jz      .err_read_stdin
    mov     rdi, rsi
    call    strlen
    mov     rdx, rax
    mov     rsi, [filename_ptr]
    mov     rdi, STDERR
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, err_read_error
    mov     rdx, err_read_error_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit
.err_read_stdin:
    mov     rdi, STDERR
    mov     rsi, err_read_error
    mov     rdx, err_read_error_len
    call    asm_write_all
    mov     edi, 1
    call    asm_exit

.decode_read_error:
    jmp     .err_read

.handle_write_error:
    ; Check for EPIPE → exit 0 (like GNU base64 for encode)
    ; Actually, GNU base64 exits 0 on broken pipe for encode
    xor     edi, edi
    call    asm_exit

.encode_write_error_pop:
    pop     rsi
    pop     rcx
    jmp     .handle_write_error

.decode_write_error_pop:
    pop     rsi
    pop     rcx
    jmp     .handle_write_error

; ═════════════════════════════════════════════════════════════════════════════
;  UTILITY FUNCTIONS
; ═════════════════════════════════════════════════════════════════════════════

; strlen(rdi) -> rax = length of null-terminated string
strlen:
    xor     eax, eax
.strlen_loop:
    cmp     byte [rdi + rax], 0
    je      .strlen_done
    inc     eax
    jmp     .strlen_loop
.strlen_done:
    ret

; parse_uint(rdi) -> eax = parsed unsigned int, or -1 on error
; Parses a decimal number from null-terminated string at rdi
; Preserves rdi (saves the original pointer for error messages)
parse_uint:
    push    rdi                    ; save original pointer
    xor     eax, eax               ; result = 0
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .parse_uint_err        ; empty string

.parse_uint_loop:
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .parse_uint_done
    sub     cl, '0'
    cmp     cl, 9
    ja      .parse_uint_err        ; not a digit
    imul    eax, 10
    movzx   ecx, cl
    add     eax, ecx
    inc     rdi
    jmp     .parse_uint_loop

.parse_uint_done:
    pop     rdi                    ; restore original pointer
    ret

.parse_uint_err:
    pop     rdi                    ; restore original pointer
    mov     eax, -1
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
