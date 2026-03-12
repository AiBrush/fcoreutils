; fbase32_unified.asm — GNU-compatible base32 encode/decode in x86-64 Linux assembly
;
; Unified single-file build with hand-crafted ELF64 header.
; No linker needed — produces a standalone static binary.
;
; Build:
;   nasm -f bin fbase32_unified.asm -o fbase32 && chmod +x fbase32
;
; Flags: -d (decode), -i (ignore-garbage), -w COLS (wrap, default 76)
;        --help, --version, -- (end of options)
;
; RFC 4648 Base32: A-Z, 2-7 alphabet. 5 bytes -> 8 characters, padding with '='

BITS 64
org 0x400000

; Macro: inline wrap check after each encoded char
%macro WRAP_CHECK 0
    test    r13d, r13d
    jz      %%skip
    inc     r8d
    cmp     r8d, r13d
    jl      %%skip
    mov     byte [rdi], 10
    inc     rdi
    xor     r8d, r8d
%%skip:
%endmacro

; ── Syscall constants ──
%define SYS_READ          0
%define SYS_WRITE         1
%define SYS_OPEN          2
%define SYS_CLOSE         3
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT         60

%define STDIN              0
%define STDOUT             1
%define STDERR             2

%define O_RDONLY           0

; ── Buffer sizes ──
%define INBUF_SIZE   65536              ; 64KB read buffer
%define OUTBUF_SIZE  (65536+32768)      ; ~96KB output buffer (encode expands 8/5 + newlines)
%define WRAP_DEFAULT 76

; ── BSS addresses (at 0x600000, zero-initialized by kernel) ──
; Layout: inbuf(64KB) + outbuf(96KB) + filename_ptr(8) + leftover(8)
%define BSS_BASE      0x600000
%define inbuf         BSS_BASE                             ; 0x600000, 65536 bytes
%define outbuf        (BSS_BASE + INBUF_SIZE)              ; 0x610000, 98304 bytes
%define filename_ptr  (BSS_BASE + INBUF_SIZE + OUTBUF_SIZE) ; 0x628000, 8 bytes
%define BSS_SIZE      (INBUF_SIZE + OUTBUF_SIZE + 16)      ; total buffer space

; ======================== ELF Header ========================================
ehdr:
    db      0x7f, "ELF"            ; e_ident[0..3]: ELF magic number
    db      2, 1, 1, 0             ; 2=64-bit, 1=little-endian, 1=ELF v1, 0=SysV ABI
    dq      0                      ; e_ident padding (8 bytes)
    dw      2                      ; e_type:    ET_EXEC (executable)
    dw      0x3E                   ; e_machine: EM_X86_64
    dd      1                      ; e_version: EV_CURRENT
    dq      _start                 ; e_entry:   virtual address of entry point
    dq      phdr - ehdr            ; e_phoff:   program header table offset
    dq      0                      ; e_shoff:   no section headers
    dd      0                      ; e_flags:   no processor-specific flags
    dw      ehdr_end - ehdr        ; e_ehsize:  ELF header size (64 bytes)
    dw      phdr_size              ; e_phentsize: program header entry size (56 bytes)
    dw      3                      ; e_phnum:   3 program headers
    dw      0, 0, 0                ; e_shentsize, e_shnum, e_shstrndx: unused
ehdr_end:

; ======================== Program Headers ===================================
phdr:
    ; --- Segment 1: Code + Data (loaded from file) ---
    dd      1                       ; p_type:  PT_LOAD
    dd      5                       ; p_flags: PF_R(4) | PF_X(1) = read+execute
    dq      0                       ; p_offset: start of file
    dq      0x400000                ; p_vaddr:  virtual address
    dq      0x400000                ; p_paddr:  physical address (same)
    dq      file_end - ehdr         ; p_filesz: entire file
    dq      file_end - ehdr         ; p_memsz:  same as filesz
    dq      0x1000                  ; p_align:  page-aligned (4KB)
phdr_size equ $ - phdr              ; Size of one program header entry (56 bytes)

    ; --- Segment 2: BSS (runtime buffers, zero-initialized) ---
    dd      1                       ; p_type:  PT_LOAD
    dd      6                       ; p_flags: PF_R(4) | PF_W(2) = read+write
    dq      0                       ; p_offset: 0 (no file content)
    dq      BSS_BASE                ; p_vaddr:  buffer base address
    dq      BSS_BASE                ; p_paddr:  same
    dq      0                       ; p_filesz: 0 (nothing loaded from file)
    dq      BSS_SIZE                ; p_memsz:  total buffer space
    dq      0x1000                  ; p_align:  page-aligned

    ; --- Segment 3: GNU Stack (marks stack as non-executable) ---
    dd      0x6474E551              ; p_type:  PT_GNU_STACK
    dd      6                       ; p_flags: PF_R(4) | PF_W(2) = NX stack
    dq      0, 0, 0, 0, 0          ; p_offset, p_vaddr, p_paddr, p_filesz, p_memsz: unused
    dq      0x10                    ; p_align:  16-byte alignment

; ============================================================================
;                           CODE SECTION
; ============================================================================

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
    ; It's "--" -> set past-options flag
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
    ; "--wr" = 2D 2D 77 72 -> LE dword = 0x72772D2D
    cmp     dword [rsi], 0x72772D2D
    jne     .chk_long_wrap_space
    ; "ap=" = 61 70 3D -> check word "ap" then byte '='
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
    ; Positional argument = filename (only one allowed)
    test    r14, r14
    jnz     .err_extra_operand
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
    ;  ENCODE PATH — 5 bytes → 8 base32 characters
    ; ═════════════════════════════════════════════════════════════════════════
.do_encode:
    ; r13d = wrap column, ebp = input fd
    ; r8 = current column position (for wrapping)
    ; r9 = leftover bytes from previous read (0, 1, 2, 3, or 4)
    xor     r8d, r8d               ; column = 0
    xor     r9d, r9d               ; leftover = 0
    sub     rsp, 16                ; local storage for leftover bytes
    ; [rsp] = leftover byte 0, [rsp+1] = byte 1, [rsp+2] = byte 2, [rsp+3] = byte 3

.encode_read_loop:
    mov     edi, ebp               ; fd
    mov     rsi, inbuf
    mov     edx, INBUF_SIZE
    call    asm_read
    test    rax, rax
    js      .err_read
    jz      .encode_flush_final

    mov     rcx, rax               ; rcx = bytes read
    mov     rsi, inbuf             ; rsi = input pointer
    mov     rdi, outbuf            ; rdi = output pointer

    ; Handle leftover from previous read
    test    r9d, r9d
    jz      .encode_main_loop

    ; We have r9d leftover bytes in [rsp..rsp+r9d-1]
    ; Need (5 - r9d) more bytes to complete a group
    mov     eax, 5
    sub     eax, r9d               ; eax = bytes needed
    cmp     rcx, rax
    jl      .encode_merge_not_enough

    ; We have enough bytes to complete the group
    ; Build 5-byte group from leftover + new data
    ; Load leftover bytes into temporary variables on stack
    ; Use a simple approach: copy new bytes into leftover buffer, then encode
    lea     r10, [rsp]             ; leftover buffer
    movzx   r11d, r9b              ; offset into leftover buffer
    lea     r10, [rsp + r11]       ; point past existing leftover bytes
    ; Copy needed bytes from input
    xor     edx, edx
.encode_merge_copy:
    cmp     edx, eax
    jge     .encode_merge_ready
    movzx   r11d, byte [rsi + rdx]
    mov     [r10 + rdx], r11b
    inc     edx
    jmp     .encode_merge_copy

.encode_merge_ready:
    ; Advance input pointer by bytes consumed
    add     rsi, rax
    sub     rcx, rax
    ; Now [rsp..rsp+4] has the 5-byte group
    movzx   eax, byte [rsp]
    movzx   edx, byte [rsp+1]
    movzx   r10d, byte [rsp+2]
    movzx   r11d, byte [rsp+3]
    push    rcx
    push    rsi
    movzx   ecx, byte [rsp+16+4]  ; rsp+16 because we pushed 2*8 bytes; +4 is the 5th byte
    ; Encode 5 bytes → 8 base32 chars
    call    .encode_5bytes_slow
    pop     rsi
    pop     rcx
    xor     r9d, r9d               ; leftover = 0
    jmp     .encode_main_loop

.encode_merge_not_enough:
    ; Not enough new bytes to complete the group; add to leftover
    test    ecx, ecx
    jz      .encode_read_loop
    lea     r10, [rsp]
    movzx   r11d, r9b
    lea     r10, [rsp + r11]
    xor     edx, edx
.encode_merge_save:
    cmp     edx, ecx
    jge     .encode_merge_save_done
    movzx   r11d, byte [rsi + rdx]
    mov     [r10 + rdx], r11b
    inc     edx
    jmp     .encode_merge_save
.encode_merge_save_done:
    add     r9d, ecx
    jmp     .encode_read_loop

.encode_main_loop:
    ; Process input in groups of 5
    cmp     rcx, 5
    jl      .encode_save_leftover

    ; Use fast 40-bit encode for wrap=0 or wrap>=8
    ; For wrap < 8, use slow per-char path
    test    r13d, r13d
    jz      .encode_fast_5bytes    ; wrap=0
    cmp     r13d, 8
    jl      .encode_slow_5bytes    ; wrap < 8: slow path

.encode_fast_5bytes:
    mov     r15, b32_encode_table

    ; Build 40-bit value in rax
    movzx   eax, byte [rsi]
    shl     rax, 8
    movzx   edx, byte [rsi+1]
    or      eax, edx
    shl     rax, 8
    movzx   edx, byte [rsi+2]
    or      eax, edx
    shl     rax, 8
    movzx   edx, byte [rsi+3]
    or      eax, edx
    shl     rax, 8
    movzx   edx, byte [rsi+4]
    or      rax, rdx

    ; Extract 8 x 5-bit groups directly to output
    mov     rdx, rax
    shr     rdx, 35
    and     edx, 0x1F
    movzx   edx, byte [r15 + rdx]
    mov     [rdi], dl

    mov     rdx, rax
    shr     rdx, 30
    and     edx, 0x1F
    movzx   edx, byte [r15 + rdx]
    mov     [rdi+1], dl

    mov     rdx, rax
    shr     rdx, 25
    and     edx, 0x1F
    movzx   edx, byte [r15 + rdx]
    mov     [rdi+2], dl

    mov     rdx, rax
    shr     rdx, 20
    and     edx, 0x1F
    movzx   edx, byte [r15 + rdx]
    mov     [rdi+3], dl

    mov     rdx, rax
    shr     rdx, 15
    and     edx, 0x1F
    movzx   edx, byte [r15 + rdx]
    mov     [rdi+4], dl

    mov     rdx, rax
    shr     rdx, 10
    and     edx, 0x1F
    movzx   edx, byte [r15 + rdx]
    mov     [rdi+5], dl

    mov     rdx, rax
    shr     rdx, 5
    and     edx, 0x1F
    movzx   edx, byte [r15 + rdx]
    mov     [rdi+6], dl

    and     eax, 0x1F
    movzx   eax, byte [r15 + rax]
    mov     [rdi+7], al

    add     rsi, 5
    sub     rcx, 5
    add     rdi, 8

    ; Handle wrapping (only for wrap >= 8)
    test    r13d, r13d
    jz      .encode_no_wrap_check  ; wrap=0: skip

    add     r8d, 8
    cmp     r8d, r13d
    jl      .encode_no_wrap_check  ; still within wrap width
    je      .encode_wrap_exact     ; column == wrap exactly

    ; column > wrap: need to split the 8-char block with a newline
    ; Since wrap >= 8, at most 1 newline per 8-char block
    mov     eax, r8d
    sub     eax, r13d              ; eax = overflow char count (1..7)
    ; The 8 chars are at [rdi-8..rdi-1]
    ; We need newline after char at index (8-overflow-1) from rdi-8
    ; Shift overflow chars right by 1 to make room for newline
    mov     r10d, eax              ; save overflow count
    lea     r11, [rdi - 1]         ; last char position
.encode_shift_right:
    test    eax, eax
    jz      .encode_shift_done
    movzx   edx, byte [r11]
    mov     [r11+1], dl
    dec     r11
    dec     eax
    jmp     .encode_shift_right
.encode_shift_done:
    mov     byte [r11+1], 10       ; insert newline
    inc     rdi                    ; output grew by 1
    mov     r8d, r10d              ; column = overflow

.encode_no_wrap_check:
    ; Check if output buffer is getting full
    mov     rax, outbuf
    mov     r10, rdi
    sub     r10, rax
    cmp     r10, OUTBUF_SIZE - 512
    jl      .encode_main_loop

    ; Flush output buffer
    push    rcx
    push    rsi
    mov     rdx, r10
    mov     rsi, outbuf
    mov     rdi, STDOUT
    call    asm_write_all
    test    eax, eax
    js      .encode_write_error_pop
    pop     rsi
    pop     rcx
    mov     rdi, outbuf
    jmp     .encode_main_loop

.encode_wrap_exact:
    ; column == wrap exactly: just insert newline
    mov     byte [rdi], 10
    inc     rdi
    xor     r8d, r8d
    jmp     .encode_no_wrap_check

; Slow path for small wrap values (< 8)
.encode_slow_5bytes:
    cmp     rcx, 5
    jl      .encode_save_leftover
    movzx   eax, byte [rsi]
    movzx   edx, byte [rsi+1]
    movzx   r10d, byte [rsi+2]
    movzx   r11d, byte [rsi+3]
    push    rcx
    movzx   ecx, byte [rsi+4]
    add     rsi, 5
    call    .encode_5bytes_slow
    pop     rcx
    sub     rcx, 5
    ; Check if output buffer is getting full
    mov     rax, outbuf
    mov     r10, rdi
    sub     r10, rax
    cmp     r10, OUTBUF_SIZE - 512
    jl      .encode_slow_5bytes
    push    rcx
    push    rsi
    mov     rdx, r10
    mov     rsi, outbuf
    mov     rdi, STDOUT
    call    asm_write_all
    test    eax, eax
    js      .encode_write_error_pop
    pop     rsi
    pop     rcx
    mov     rdi, outbuf
    jmp     .encode_slow_5bytes

.encode_save_leftover:
    mov     r9d, ecx
    test    ecx, ecx
    jz      .encode_flush_and_continue
    ; Copy leftover bytes
    xor     edx, edx
.encode_save_loop:
    cmp     edx, ecx
    jge     .encode_flush_and_continue
    movzx   eax, byte [rsi + rdx]
    mov     [rsp + rdx], al
    inc     edx
    jmp     .encode_save_loop

.encode_flush_and_continue:
    mov     rax, outbuf
    mov     rdx, rdi
    sub     rdx, rax
    test    rdx, rdx
    jz      .encode_read_loop
    push    r9
    push    r9                         ; align stack to 16 bytes
    mov     rsi, outbuf
    mov     rdi, STDOUT
    call    asm_write_all
    test    eax, eax
    pop     r9                         ; remove alignment padding
    pop     r9
    js      .handle_write_error
    jmp     .encode_read_loop

.encode_flush_final:
    mov     rdi, outbuf

    cmp     r9d, 0
    je      .encode_final_newline

    ; Handle leftover bytes with padding
    ; r9d = number of leftover bytes (1, 2, 3, or 4)
    movzx   eax, byte [rsp]        ; b0 (always present)
    xor     edx, edx               ; b1 = 0
    xor     r10d, r10d             ; b2 = 0
    xor     r11d, r11d             ; b3 = 0
    xor     ecx, ecx               ; b4 = 0 (use ecx temporarily)

    cmp     r9d, 1
    je      .encode_pad_ready
    movzx   edx, byte [rsp+1]      ; b1
    cmp     r9d, 2
    je      .encode_pad_ready
    movzx   r10d, byte [rsp+2]     ; b2
    cmp     r9d, 3
    je      .encode_pad_ready
    movzx   r11d, byte [rsp+3]     ; b3

.encode_pad_ready:
    ; Encode with padding based on r9d (leftover count)
    ; Always emit chars 0 and 1
    mov     r15, b32_encode_table
    push    rax

    ; Char 0: b0 >> 3
    mov     r10d, eax  ; save b0, use local copy
    ; (We need to be more careful here — let's use a cleaner approach)
    pop     rax
    ; Reload all values fresh
    movzx   eax, byte [rsp]
    push    rax                    ; save b0

    ; Char 0: b0 >> 3
    shr     al, 3
    movzx   eax, byte [r15 + rax]
    mov     [rdi], al

    ; Char 1: ((b0 & 0x07) << 2) | (b1 >> 6)
    pop     rax                    ; b0
    and     al, 0x07
    shl     al, 2
    cmp     r9d, 1
    je      .encode_pad_c1_no_b1
    movzx   edx, byte [rsp+1]
    push    rdx
    shr     dl, 6
    or      al, dl
    pop     rdx
.encode_pad_c1_no_b1:
    movzx   eax, byte [r15 + rax]
    mov     [rdi+1], al

    cmp     r9d, 1
    je      .encode_pad_1

    ; Char 2: (b1 >> 1) & 0x1F
    movzx   edx, byte [rsp+1]
    push    rdx
    shr     dl, 1
    and     dl, 0x1F
    movzx   eax, byte [r15 + rdx]
    mov     [rdi+2], al
    pop     rdx

    ; Char 3: ((b1 & 0x01) << 4) | (b2 >> 4)
    movzx   edx, byte [rsp+1]
    and     dl, 0x01
    shl     dl, 4
    cmp     r9d, 2
    je      .encode_pad_c3_no_b2
    movzx   r10d, byte [rsp+2]
    push    r10
    shr     r10b, 4
    or      dl, r10b
    pop     r10
.encode_pad_c3_no_b2:
    movzx   eax, byte [r15 + rdx]
    mov     [rdi+3], al

    cmp     r9d, 2
    je      .encode_pad_2

    ; Char 4: ((b2 & 0x0F) << 1) | (b3 >> 7)
    movzx   r10d, byte [rsp+2]
    and     r10b, 0x0F
    shl     r10b, 1
    cmp     r9d, 3
    je      .encode_pad_c4_no_b3
    movzx   r11d, byte [rsp+3]
    push    r11
    shr     r11b, 7
    or      r10b, r11b
    pop     r11
.encode_pad_c4_no_b3:
    movzx   eax, byte [r15 + r10]
    mov     [rdi+4], al

    cmp     r9d, 3
    je      .encode_pad_3

    ; r9d == 4
    ; Char 5: (b3 >> 2) & 0x1F
    movzx   r11d, byte [rsp+3]
    push    r11
    shr     r11b, 2
    and     r11b, 0x1F
    movzx   eax, byte [r15 + r11]
    mov     [rdi+5], al
    pop     r11

    ; Char 6: ((b3 & 0x03) << 3)  (b4=0 so no |)
    movzx   r11d, byte [rsp+3]
    and     r11b, 0x03
    shl     r11b, 3
    movzx   eax, byte [r15 + r11]
    mov     [rdi+6], al

    ; Char 7: padding '='
    mov     byte [rdi+7], '='
    add     rdi, 8
    add     r8d, 8
    jmp     .encode_pad_wrap_check

.encode_pad_3:
    ; 3 leftover: 5 data chars + 3 padding
    mov     byte [rdi+5], '='
    mov     byte [rdi+6], '='
    mov     byte [rdi+7], '='
    add     rdi, 8
    add     r8d, 8
    jmp     .encode_pad_wrap_check

.encode_pad_2:
    ; 2 leftover: 4 data chars + 4 padding
    mov     byte [rdi+4], '='
    mov     byte [rdi+5], '='
    mov     byte [rdi+6], '='
    mov     byte [rdi+7], '='
    add     rdi, 8
    add     r8d, 8
    jmp     .encode_pad_wrap_check

.encode_pad_1:
    ; 1 leftover: 2 data chars + 6 padding
    mov     byte [rdi+2], '='
    mov     byte [rdi+3], '='
    mov     byte [rdi+4], '='
    mov     byte [rdi+5], '='
    mov     byte [rdi+6], '='
    mov     byte [rdi+7], '='
    add     rdi, 8
    add     r8d, 8

.encode_pad_wrap_check:
    ; Check if wrap needed for the padding block
    test    r13d, r13d
    jz      .encode_final_newline
    ; Since we already emitted 8 chars, check if we overshot wrap
    cmp     r8d, r13d
    jl      .encode_final_newline
    ; We need to go back and re-emit with char-by-char wrapping
    ; Copy the 8 encoded chars to stack temp buffer
    sub     rdi, 8
    sub     r8d, 8
    ; Save the 8 chars to stack
    sub     rsp, 16
    mov     rax, [rdi]             ; load 8 bytes at once
    mov     [rsp], rax
    ; Re-emit char by char with wrap checks
    xor     ecx, ecx               ; counter
.encode_pad_rewrap:
    cmp     ecx, 8
    jge     .encode_pad_rewrap_done
    movzx   eax, byte [rsp + rcx]  ; read from temp buffer (rcx is 64-bit)
    mov     [rdi], al
    inc     rdi
    inc     ecx
    push    rcx
    call    .encode_wrap_check_inline
    pop     rcx
    jmp     .encode_pad_rewrap
.encode_pad_rewrap_done:
    add     rsp, 16

.encode_final_newline:
    test    r13d, r13d
    jz      .encode_final_flush
    test    r8d, r8d
    jz      .encode_final_flush
    mov     byte [rdi], 10
    inc     rdi

.encode_final_flush:
    mov     rsi, outbuf
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

; ── encode_5bytes_slow: encode 5 bytes with per-char wrap check ──
; Input: al=b0, dl=b1, r10b=b2, r11b=b3, cl=b4
; Uses: rdi (output), r8d (column), r13d (wrap), r15 (table)
.encode_5bytes_slow:
    mov     r15, b32_encode_table
    ; Save all input bytes
    push    rax                    ; b0
    push    rdx                    ; b1
    push    r10                    ; b2
    push    r11                    ; b3
    push    rcx                    ; b4

    ; Char 0: b0 >> 3
    mov     al, [rsp+32]          ; b0 (pushed first = highest offset)
    shr     al, 3
    movzx   eax, byte [r15 + rax]
    mov     [rdi], al
    inc     rdi
    WRAP_CHECK

    ; Char 1: ((b0 & 0x07) << 2) | (b1 >> 6)
    movzx   eax, byte [rsp+32]    ; b0
    and     al, 0x07
    shl     al, 2
    movzx   edx, byte [rsp+24]    ; b1
    shr     dl, 6
    or      al, dl
    movzx   eax, byte [r15 + rax]
    mov     [rdi], al
    inc     rdi
    WRAP_CHECK

    ; Char 2: (b1 >> 1) & 0x1F
    movzx   eax, byte [rsp+24]    ; b1
    shr     al, 1
    and     al, 0x1F
    movzx   eax, byte [r15 + rax]
    mov     [rdi], al
    inc     rdi
    WRAP_CHECK

    ; Char 3: ((b1 & 0x01) << 4) | (b2 >> 4)
    movzx   eax, byte [rsp+24]    ; b1
    and     al, 0x01
    shl     al, 4
    movzx   edx, byte [rsp+16]    ; b2
    shr     dl, 4
    or      al, dl
    movzx   eax, byte [r15 + rax]
    mov     [rdi], al
    inc     rdi
    WRAP_CHECK

    ; Char 4: ((b2 & 0x0F) << 1) | (b3 >> 7)
    movzx   eax, byte [rsp+16]    ; b2
    and     al, 0x0F
    shl     al, 1
    movzx   edx, byte [rsp+8]     ; b3
    shr     dl, 7
    or      al, dl
    movzx   eax, byte [r15 + rax]
    mov     [rdi], al
    inc     rdi
    WRAP_CHECK

    ; Char 5: (b3 >> 2) & 0x1F
    movzx   eax, byte [rsp+8]     ; b3
    shr     al, 2
    and     al, 0x1F
    movzx   eax, byte [r15 + rax]
    mov     [rdi], al
    inc     rdi
    WRAP_CHECK

    ; Char 6: ((b3 & 0x03) << 3) | (b4 >> 5)
    movzx   eax, byte [rsp+8]     ; b3
    and     al, 0x03
    shl     al, 3
    movzx   edx, byte [rsp]       ; b4
    shr     dl, 5
    or      al, dl
    movzx   eax, byte [r15 + rax]
    mov     [rdi], al
    inc     rdi
    WRAP_CHECK

    ; Char 7: b4 & 0x1F
    movzx   eax, byte [rsp]       ; b4
    and     al, 0x1F
    movzx   eax, byte [r15 + rax]
    mov     [rdi], al
    inc     rdi
    WRAP_CHECK

    pop     rcx
    pop     r11
    pop     r10
    pop     rdx
    pop     rax
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
    ;  DECODE PATH — 8 base32 characters → 5 bytes
    ; ═════════════════════════════════════════════════════════════════════════
.do_decode:
    ; r12d bit 1 = ignore_garbage, ebp = input fd
    xor     r8d, r8d               ; number of valid chars accumulated in group
    xor     r9d, r9d               ; position in group (including padding)
    sub     rsp, 16                ; local storage: [rsp..rsp+7] = vals buffer
    mov     r14, outbuf            ; output write pointer

.decode_read_loop:
    mov     edi, ebp               ; fd
    mov     rsi, inbuf
    mov     edx, INBUF_SIZE
    call    asm_read
    test    rax, rax
    js      .decode_read_error
    jz      .decode_eof

    mov     rcx, rax               ; rcx = bytes read
    mov     rsi, inbuf             ; input pointer

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
    mov     r10, b32_decode_table
    movzx   edx, byte [r10 + rax]

    cmp     dl, 0xFE
    je      .decode_byte_loop      ; whitespace -> skip
    cmp     dl, 0xFF
    je      .decode_invalid_or_garbage

    ; Valid base32 character (value in dl, 0-31)
    ; Store in vals buffer
    lea     r10, [rsp]
    mov     [r10 + r9], dl
    inc     r8d                    ; valid char count
    inc     r9d                    ; position in group
    cmp     r9d, 8
    jl      .decode_byte_loop

    ; Have 8 chars -> output 5 bytes
    ; vals[0..7] contain 5-bit values
    movzx   eax, byte [rsp]       ; v0
    movzx   edx, byte [rsp+1]     ; v1
    shl     al, 3
    shr     dl, 2
    or      al, dl
    mov     [r14], al              ; byte 0: (v0<<3)|(v1>>2)

    movzx   eax, byte [rsp+1]     ; v1
    movzx   edx, byte [rsp+2]     ; v2
    movzx   r10d, byte [rsp+3]    ; v3
    shl     al, 6
    shl     dl, 1
    or      al, dl
    shr     r10b, 4
    or      al, r10b
    mov     [r14+1], al            ; byte 1: (v1<<6)|(v2<<1)|(v3>>4)

    movzx   eax, byte [rsp+3]     ; v3
    movzx   edx, byte [rsp+4]     ; v4
    shl     al, 4
    shr     dl, 1
    or      al, dl
    mov     [r14+2], al            ; byte 2: (v3<<4)|(v4>>1)

    movzx   eax, byte [rsp+4]     ; v4
    movzx   edx, byte [rsp+5]     ; v5
    movzx   r10d, byte [rsp+6]    ; v6
    shl     al, 7
    shl     dl, 2
    or      al, dl
    shr     r10b, 3
    or      al, r10b
    mov     [r14+3], al            ; byte 3: (v4<<7)|(v5<<2)|(v6>>3)

    movzx   eax, byte [rsp+6]     ; v6
    movzx   edx, byte [rsp+7]     ; v7
    shl     al, 5
    or      al, dl
    mov     [r14+4], al            ; byte 4: (v6<<5)|v7

    add     r14, 5
    xor     r8d, r8d
    xor     r9d, r9d

    ; Check if output buffer is getting full
    mov     rax, outbuf
    mov     rdx, r14
    sub     rdx, rax
    cmp     rdx, OUTBUF_SIZE - 512
    jl      .decode_byte_loop

    ; Flush output buffer
    push    rcx
    push    rsi
    mov     rsi, outbuf
    mov     rdi, STDOUT
    call    asm_write_all
    test    eax, eax
    js      .decode_write_error_pop
    pop     rsi
    pop     rcx
    mov     r14, outbuf
    jmp     .decode_byte_loop

.decode_invalid_or_garbage:
    ; If ignore_garbage flag is set, skip this byte
    test    r12d, 2
    jnz     .decode_byte_loop
    ; Otherwise, error
    jmp     .err_invalid_input

.decode_padding:
    ; '=' encountered — increment position but not valid char count
    inc     r9d
    cmp     r9d, 8
    jl      .decode_byte_loop

    ; Group complete with padding. Output based on valid char count (r8d)
    ; 2 valid -> 1 byte, 4 valid -> 2 bytes, 5 valid -> 3 bytes, 7 valid -> 4 bytes
    cmp     r8d, 2
    je      .decode_pad_1byte
    cmp     r8d, 4
    je      .decode_pad_2bytes
    cmp     r8d, 5
    je      .decode_pad_3bytes
    cmp     r8d, 7
    je      .decode_pad_4bytes
    ; Invalid padding pattern
    jmp     .err_invalid_input

.decode_pad_1byte:
    ; 2 valid chars -> 1 output byte
    movzx   eax, byte [rsp]       ; v0
    movzx   edx, byte [rsp+1]     ; v1
    shl     al, 3
    shr     dl, 2
    or      al, dl
    mov     [r14], al
    inc     r14
    xor     r8d, r8d
    xor     r9d, r9d
    jmp     .decode_byte_loop

.decode_pad_2bytes:
    ; 4 valid chars -> 2 output bytes
    movzx   eax, byte [rsp]       ; v0
    movzx   edx, byte [rsp+1]     ; v1
    shl     al, 3
    shr     dl, 2
    or      al, dl
    mov     [r14], al

    movzx   eax, byte [rsp+1]     ; v1
    movzx   edx, byte [rsp+2]     ; v2
    movzx   r10d, byte [rsp+3]    ; v3
    shl     al, 6
    shl     dl, 1
    or      al, dl
    shr     r10b, 4
    or      al, r10b
    mov     [r14+1], al

    add     r14, 2
    xor     r8d, r8d
    xor     r9d, r9d
    jmp     .decode_byte_loop

.decode_pad_3bytes:
    ; 5 valid chars -> 3 output bytes
    movzx   eax, byte [rsp]
    movzx   edx, byte [rsp+1]
    shl     al, 3
    shr     dl, 2
    or      al, dl
    mov     [r14], al

    movzx   eax, byte [rsp+1]
    movzx   edx, byte [rsp+2]
    movzx   r10d, byte [rsp+3]
    shl     al, 6
    shl     dl, 1
    or      al, dl
    shr     r10b, 4
    or      al, r10b
    mov     [r14+1], al

    movzx   eax, byte [rsp+3]
    movzx   edx, byte [rsp+4]
    shl     al, 4
    shr     dl, 1
    or      al, dl
    mov     [r14+2], al

    add     r14, 3
    xor     r8d, r8d
    xor     r9d, r9d
    jmp     .decode_byte_loop

.decode_pad_4bytes:
    ; 7 valid chars -> 4 output bytes
    movzx   eax, byte [rsp]
    movzx   edx, byte [rsp+1]
    shl     al, 3
    shr     dl, 2
    or      al, dl
    mov     [r14], al

    movzx   eax, byte [rsp+1]
    movzx   edx, byte [rsp+2]
    movzx   r10d, byte [rsp+3]
    shl     al, 6
    shl     dl, 1
    or      al, dl
    shr     r10b, 4
    or      al, r10b
    mov     [r14+1], al

    movzx   eax, byte [rsp+3]
    movzx   edx, byte [rsp+4]
    shl     al, 4
    shr     dl, 1
    or      al, dl
    mov     [r14+2], al

    movzx   eax, byte [rsp+4]
    movzx   edx, byte [rsp+5]
    movzx   r10d, byte [rsp+6]
    shl     al, 7
    shl     dl, 2
    or      al, dl
    shr     r10b, 3
    or      al, r10b
    mov     [r14+3], al

    add     r14, 4
    xor     r8d, r8d
    xor     r9d, r9d
    jmp     .decode_byte_loop

.decode_flush_and_read:
    ; Flush output and read more input
    mov     rax, outbuf
    mov     rdx, r14
    sub     rdx, rax
    test    rdx, rdx
    jz      .decode_read_loop
    push    r8
    push    r9
    mov     rsi, outbuf
    mov     rdi, STDOUT
    call    asm_write_all
    test    eax, eax
    pop     r9
    pop     r8
    js      .handle_write_error
    mov     r14, outbuf
    jmp     .decode_read_loop

.decode_eof:
    ; Check for incomplete group
    test    r8d, r8d
    jnz     .decode_eof_incomplete

    ; Flush remaining output
    mov     rsi, outbuf
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
    ; GNU behavior at EOF with incomplete group:
    ;   Valid counts (2,4,5,7): decode bytes, check trailing bits, exit 0 if clean
    ;   Invalid counts (1,3,6): decode what we can, exit 1
    cmp     r8d, 1
    je      .decode_eof_flush_and_error
    cmp     r8d, 2
    je      .decode_eof_partial_1byte
    cmp     r8d, 3
    je      .decode_eof_flush_and_error
    cmp     r8d, 4
    je      .decode_eof_partial_2bytes
    cmp     r8d, 5
    je      .decode_eof_partial_3bytes
    cmp     r8d, 6
    je      .decode_eof_flush_and_error
    cmp     r8d, 7
    je      .decode_eof_partial_4bytes
    jmp     .decode_eof_flush_and_error

.decode_eof_partial_1byte:
    ; 2 valid chars -> 1 byte, exit 0
    movzx   eax, byte [rsp]
    movzx   edx, byte [rsp+1]
    shl     al, 3
    shr     dl, 2
    or      al, dl
    mov     [r14], al
    inc     r14
    jmp     .decode_eof_flush_ok

.decode_eof_partial_2bytes:
    ; 4 valid chars -> 2 bytes, exit 0
    movzx   eax, byte [rsp]
    movzx   edx, byte [rsp+1]
    shl     al, 3
    shr     dl, 2
    or      al, dl
    mov     [r14], al

    movzx   eax, byte [rsp+1]
    movzx   edx, byte [rsp+2]
    movzx   r10d, byte [rsp+3]
    shl     al, 6
    shl     dl, 1
    or      al, dl
    shr     r10b, 4
    or      al, r10b
    mov     [r14+1], al

    add     r14, 2
    jmp     .decode_eof_flush_ok

.decode_eof_partial_3bytes:
    ; 5 valid chars -> 3 bytes
    movzx   eax, byte [rsp]
    movzx   edx, byte [rsp+1]
    shl     al, 3
    shr     dl, 2
    or      al, dl
    mov     [r14], al

    movzx   eax, byte [rsp+1]
    movzx   edx, byte [rsp+2]
    movzx   r10d, byte [rsp+3]
    shl     al, 6
    shl     dl, 1
    or      al, dl
    shr     r10b, 4
    or      al, r10b
    mov     [r14+1], al

    movzx   eax, byte [rsp+3]
    movzx   edx, byte [rsp+4]
    shl     al, 4
    shr     dl, 1
    or      al, dl
    mov     [r14+2], al

    add     r14, 3
    jmp     .decode_eof_flush_ok

.decode_eof_partial_4bytes:
    ; 7 valid chars -> 4 bytes
    movzx   eax, byte [rsp]
    movzx   edx, byte [rsp+1]
    shl     al, 3
    shr     dl, 2
    or      al, dl
    mov     [r14], al

    movzx   eax, byte [rsp+1]
    movzx   edx, byte [rsp+2]
    movzx   r10d, byte [rsp+3]
    shl     al, 6
    shl     dl, 1
    or      al, dl
    shr     r10b, 4
    or      al, r10b
    mov     [r14+1], al

    movzx   eax, byte [rsp+3]
    movzx   edx, byte [rsp+4]
    shl     al, 4
    shr     dl, 1
    or      al, dl
    mov     [r14+2], al

    movzx   eax, byte [rsp+4]
    movzx   edx, byte [rsp+5]
    movzx   r10d, byte [rsp+6]
    shl     al, 7
    shl     dl, 2
    or      al, dl
    shr     r10b, 3
    or      al, r10b
    mov     [r14+3], al

    add     r14, 4
    jmp     .decode_eof_flush_ok

.decode_eof_flush_ok:
    ; Flush output and exit 0 (valid incomplete group)
    mov     rsi, outbuf
    mov     rdx, r14
    sub     rdx, rsi
    test    rdx, rdx
    jz      .decode_done
    mov     rdi, STDOUT
    call    asm_write_all
    test    eax, eax
    js      .handle_write_error
    jmp     .decode_done

.decode_eof_flush_and_error:
    ; Flush output then report error
    mov     rsi, outbuf
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

.err_extra_operand:
    ; rsi points to the extra operand string
    push    rsi
    mov     rdi, STDERR
    mov     rsi, err_extra_operand
    mov     rdx, err_extra_operand_len
    call    asm_write_all
    pop     rsi
    ; Write the operand string
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
    ; Print "base32: "
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
    mov     rsi, outbuf
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
    ; Print "base32: " + filename + ": read error\n"
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
    ; Check for EPIPE -> exit 0
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
    jo      .parse_uint_err        ; overflow check
    movzx   ecx, cl
    add     eax, ecx
    jo      .parse_uint_err        ; overflow check
    inc     rdi
    jmp     .parse_uint_loop

.parse_uint_done:
    pop     rdi                    ; restore original pointer
    ret

.parse_uint_err:
    pop     rdi                    ; restore original pointer
    mov     eax, -1
    ret

; ═════════════════════════════════════════════════════════════════════════════
;  INLINED IO FUNCTIONS
; ═════════════════════════════════════════════════════════════════════════════

; asm_write_all(rdi=fd, rsi=buf, rdx=len) -> rax=0 on success, -1 on error
asm_write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi            ; fd
    mov     r12, rsi            ; buf
    mov     r13, rdx            ; remaining
.wa_loop:
    test    r13, r13
    jle     .wa_success
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      .wa_loop            ; EINTR -- retry
    test    rax, rax
    js      .wa_error           ; negative = error
    add     r12, rax
    sub     r13, rax
    jmp     .wa_loop
.wa_success:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.wa_error:
    mov     rax, -1
    pop     r13
    pop     r12
    pop     rbx
    ret

; asm_read(rdi=fd, rsi=buf, rdx=len) -> rax=bytes_read
asm_read:
.ar_retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, -4
    je      .ar_retry
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

; ############################################################################
;                           DATA SECTION
; ############################################################################

; Base32 encoding table (RFC 4648)
b32_encode_table:
    db "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

; Base32 decode table: maps ASCII byte -> 5-bit value (0-31), 0xFF = invalid, 0xFE = whitespace
; 256 entries
b32_decode_table:
    ;       0     1     2     3     4     5     6     7     8     9     A     B     C     D     E     F
    db   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, 0xFE, 0xFE, 0xFE, 0xFE, 0xFF, 0xFF  ; 0x00-0x0F (TAB,LF,VT,FF,CR=whitespace)
    db   0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF  ; 0x10-0x1F
    db   0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF  ; 0x20-0x2F (space=ws)
    db   0xFF, 0xFF,   26,   27,   28,   29,   30,   31, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF  ; 0x30-0x3F (2=26,3=27,4=28,5=29,6=30,7=31)
    db   0xFF,    0,    1,    2,    3,    4,    5,    6,    7,    8,    9,   10,   11,   12,   13,   14  ; 0x40-0x4F (A-O=0-14)
    db     15,   16,   17,   18,   19,   20,   21,   22,   23,   24,   25, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF  ; 0x50-0x5F (P-Z=15-25)
    db   0xFF,    0,    1,    2,    3,    4,    5,    6,    7,    8,    9,   10,   11,   12,   13,   14  ; 0x60-0x6F (a-o=0-14, lowercase accepted)
    db     15,   16,   17,   18,   19,   20,   21,   22,   23,   24,   25, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF  ; 0x70-0x7F (p-z=15-25, lowercase accepted)
    ; 0x80-0xFF: all invalid
    times 128 db 0xFF

; ── String constants ──
help_text:
    db "Usage: base32 [OPTION]... [FILE]", 10
    db "Base32 encode or decode FILE, or standard input, to standard output.", 10, 10
    db "With no FILE, or when FILE is -, read standard input.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -d, --decode          decode data", 10
    db "  -i, --ignore-garbage  when decoding, ignore non-alphabet characters", 10
    db "  -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).", 10
    db "                          Use 0 to disable line wrapping", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "The data are encoded as described for the base32 alphabet in RFC 4648.", 10
    db "When decoding, the input may contain newlines in addition to the bytes of", 10
    db "the formal base32 alphabet.  Use --ignore-garbage to attempt to recover", 10
    db "from any other non-alphabet bytes in the encoded stream.", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/base32>", 10
    db "or available locally via: info '(coreutils) base32 invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "base32 (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Simon Josefsson.", 10
version_text_len equ $ - version_text

err_prefix:
    db "base32: "
err_prefix_len equ $ - err_prefix

err_invalid_option:
    db "base32: invalid option -- '"
err_invalid_option_len equ $ - err_invalid_option

err_unrecognized:
    db "base32: unrecognized option '"
err_unrecognized_len equ $ - err_unrecognized

err_suffix:
    db "'", 10, "Try 'base32 --help' for more information.", 10
err_suffix_len equ $ - err_suffix

err_invalid_wrap:
    db "base32: invalid wrap size: '"
err_invalid_wrap_len equ $ - err_invalid_wrap

err_wrap_suffix:
    db "'", 10
err_wrap_suffix_len equ $ - err_wrap_suffix

err_option_requires_arg_w:
    db "base32: option requires an argument -- 'w'", 10
    db "Try 'base32 --help' for more information.", 10
err_option_requires_arg_w_len equ $ - err_option_requires_arg_w

err_wrap_long_requires:
    db "base32: option '--wrap' requires an argument", 10
    db "Try 'base32 --help' for more information.", 10
err_wrap_long_requires_len equ $ - err_wrap_long_requires

err_invalid_input:
    db "base32: invalid input", 10
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

err_extra_operand:
    db "base32: extra operand ", 0xE2, 0x80, 0x98
err_extra_operand_len equ $ - err_extra_operand

newline_char:
    db 10

; ============================================================================
;  End of file content
; ============================================================================
file_end:
