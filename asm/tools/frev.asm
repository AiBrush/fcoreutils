; frev.asm — GNU-compatible "rev" in x86_64 Linux assembly
;
; Reverses each line of input characterwise.
; Reads from stdin or file arguments. Handles:
;   --help, --version, --, multiple files, - for stdin
;   Binary-safe (null bytes), SIGPIPE, EINTR, partial writes
;
; Register conventions (global state across function calls):
;   r12 = out_buf_used (bytes currently in output buffer)
;   r13 = processed_any flag (0=no file/stdin processed yet)
;   ebp = had_error flag (0=ok, 1=error occurred)
;
; Within process_fd:
;   r14 = line_buf base pointer
;   r15 = line_buf_used (current line length)
;   rbx = fd being read
;
; Build (modular):
;   nasm -f elf64 -I include/ tools/frev.asm -o build/tools/frev.o
;   nasm -f elf64 -I include/ lib/io.asm -o build/lib/io.o
;   ld --gc-sections -n build/tools/frev.o build/lib/io.o -o frev

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close

; ─── Constants ───────────────────────────────────────────
%define READ_BUF_SIZE   65536
; Out buffer must be >= LINE_BUF_SIZE + 1 to guarantee a full reversed
; line + newline fits after flushing (r12=0). Previous value of 131072
; caused buffer overflow on lines > 128KB.
%define OUT_BUF_SIZE    1114112     ; LINE_BUF_SIZE + FLUSH_THRESHOLD
; Line buffer for reversing a single line (supports lines up to 1MB)
%define LINE_BUF_SIZE   1048576
%define FLUSH_THRESHOLD 65536

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

    ; Skip argv[0] (program name)
    dec     r14                     ; argc - 1
    add     r15, 8                  ; &argv[1]

    ; Initialize global state
    xor     ebp, ebp                ; had_error = 0
    xor     r12d, r12d              ; out_buf_used = 0
    xor     r13d, r13d              ; processed_any = 0

    ; If no args, skip parse loop → done_files will read stdin
    test    r14, r14
    jz      .done_files

    ; Parse arguments
    xor     ebx, ebx                ; arg index = 0
    xor     ecx, ecx                ; seen_dashdash = 0

.parse_loop:
    cmp     rbx, r14
    jge     .done_files

    mov     rsi, [r15 + rbx*8]      ; argv[i]

    ; If we've seen --, treat everything as filename
    test    ecx, ecx
    jnz     .is_file

    ; Check for '-' prefix
    cmp     byte [rsi], '-'
    jne     .is_file
    cmp     byte [rsi+1], '-'
    jne     .check_dash_stdin

    ; Starts with "--"
    cmp     byte [rsi+2], 0
    je      .set_dashdash           ; exactly "--"

    ; Check --help
    push    rcx
    push    rbx
    lea     rdi, [rel str_help]
    call    strcmp
    pop     rbx
    pop     rcx
    test    eax, eax
    jz      .do_help

    ; Check --version
    mov     rsi, [r15 + rbx*8]
    push    rcx
    push    rbx
    lea     rdi, [rel str_version]
    call    strcmp
    pop     rbx
    pop     rcx
    test    eax, eax
    jz      .do_version

    ; Unknown --option: error
    push    rcx
    push    rbx
    mov     rsi, [r15 + rbx*8]
    call    err_unrecognized_option
    pop     rbx
    pop     rcx
    mov     ebp, 1
    ; Exit immediately with error (matching Rust behavior)
    movzx   rdi, bpl
    mov     rax, SYS_EXIT
    syscall

.check_dash_stdin:
    ; Single "-" means stdin
    cmp     byte [rsi+1], 0
    je      .is_stdin
    ; Check for -h (help)
    cmp     byte [rsi+1], 'h'
    jne     .check_V
    cmp     byte [rsi+2], 0
    je      .do_help
    jmp     .invalid_short_opt
.check_V:
    ; Check for -V (version)
    cmp     byte [rsi+1], 'V'
    jne     .invalid_short_opt
    cmp     byte [rsi+2], 0
    je      .do_version
.invalid_short_opt:
    ; Unknown short option (e.g., -z)
    push    rcx
    push    rbx
    mov     rsi, [r15 + rbx*8]
    call    err_invalid_option
    pop     rbx
    pop     rcx
    mov     ebp, 1
    movzx   rdi, bpl
    mov     rax, SYS_EXIT
    syscall

.set_dashdash:
    mov     ecx, 1
    jmp     .parse_next

.is_stdin:
    push    rcx
    push    rbx
    mov     r13d, 1                 ; mark as processed
    mov     edi, STDIN
    call    process_fd
    pop     rbx
    pop     rcx
    jmp     .parse_next

.is_file:
    push    rcx
    push    rbx
    mov     r13d, 1                 ; mark as processed
    mov     rsi, [r15 + rbx*8]
    call    open_and_process
    pop     rbx
    pop     rcx
    jmp     .parse_next

.parse_next:
    inc     rbx
    jmp     .parse_loop

.done_files:
    ; If no files/stdin were processed, read stdin (handles `rev --` and no-args)
    test    r13, r13
    jnz     .final_flush
    mov     edi, STDIN
    call    process_fd

.final_flush:
    ; Flush remaining output buffer
    call    flush_output
    test    eax, eax
    jnz     .write_error_exit

    ; Exit with appropriate code
    movzx   rdi, bpl
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

; ─── open_and_process(rsi=filename) ──────────────────────
; Opens a file, processes it, closes it. Sets ebp on error.
; Does NOT clobber r12 (out_buf_used) or ebp (had_error) beyond intended side effects.
open_and_process:
    push    rbx
    mov     rbx, rsi                ; save filename

    ; Open file
    mov     rdi, rsi
    xor     esi, esi                ; O_RDONLY = 0
    xor     edx, edx                ; mode = 0
    mov     rax, SYS_OPEN
    syscall

    test    rax, rax
    js      .oap_open_error

    ; Save fd on stack, call process_fd
    push    rax                     ; save fd
    mov     edi, eax                ; fd argument
    call    process_fd
    pop     rdi                     ; recover fd for close

    ; Close file
    mov     rax, SYS_CLOSE
    syscall

    pop     rbx
    ret

.oap_open_error:
    neg     rax                     ; make positive errno
    mov     rdi, rbx                ; filename
    mov     esi, eax                ; errno
    call    err_file
    mov     ebp, 1
    pop     rbx
    ret

; ─── process_fd(edi=fd) ─────────────────────────────────
; Reads all data from fd, reverses each line, writes to stdout.
; Streaming: read into buffer, scan for newlines, reverse complete
; lines, carry over partial lines in line_buf.
;
; Local register usage:
;   rbx = fd
;   r14 = line_buf pointer
;   r15 = line_buf_used
;   (r12 = out_buf_used -- global, preserved/modified)
;   (ebp = had_error -- global, may be set)
process_fd:
    push    rbx
    push    r14
    push    r15

    mov     ebx, edi                ; fd to read from
    lea     r14, [rel line_buf]     ; line accumulation buffer
    xor     r15d, r15d              ; line_buf_used = 0

.pf_read_loop:
    ; Read a chunk
    mov     edi, ebx
    lea     rsi, [rel read_buf]
    mov     edx, READ_BUF_SIZE
    call    asm_read

    test    rax, rax
    js      .pf_read_error
    jz      .pf_read_eof

    ; rax = bytes read. Scan for newlines.
    ; We use r8 = current offset, r9 = total bytes read
    xor     r8d, r8d                ; offset = 0
    mov     r9, rax                 ; total bytes

    ; Load newline comparison pattern for SIMD
    movdqa  xmm1, [rel newline_pattern]

.pf_scan_simd:
    ; Check if we have 16+ bytes remaining
    mov     rax, r9
    sub     rax, r8                 ; remaining = total - offset
    cmp     rax, 16
    jl      .pf_scan_scalar_entry

    ; Load 16 bytes from read_buf + offset
    lea     rdi, [rel read_buf]
    add     rdi, r8
    movdqu  xmm0, [rdi]
    pcmpeqb xmm0, xmm1             ; compare each byte with 0x0A
    pmovmskb eax, xmm0             ; extract comparison mask

    test    eax, eax
    jnz     .pf_simd_found_nl

    ; No newline in these 16 bytes — copy all to line_buf
    lea     rcx, [r15 + 16]
    cmp     rcx, LINE_BUF_SIZE
    jge     .pf_line_overflow

    movdqu  xmm2, [rdi]
    movdqu  [r14 + r15], xmm2
    add     r15, 16
    add     r8, 16
    jmp     .pf_scan_simd

.pf_simd_found_nl:
    ; eax has bitmask. Find first newline position.
    bsf     ecx, eax                ; ecx = position of first \n in 16-byte window

    ; Copy bytes before the newline to line_buf
    test    ecx, ecx
    jz      .pf_simd_emit           ; newline at position 0, emit immediately

    ; Bounds check for line_buf
    lea     rdx, [r15 + rcx]
    cmp     rdx, LINE_BUF_SIZE
    jge     .pf_line_overflow

    ; Copy ecx bytes from read_buf+r8 to line_buf+r15
    ; Use rep movsb for simplicity and correctness
    lea     rsi, [rel read_buf]
    add     rsi, r8
    lea     rdi, [r14 + r15]
    push    rcx                     ; save newline position
    rep     movsb                   ; copy ecx bytes
    pop     rcx                     ; restore newline position
    add     r15, rcx                ; line_buf_used += ecx

.pf_simd_emit:
    ; Save state that reverse_and_emit_line will clobber
    push    r8
    push    r9
    push    rcx                     ; newline position within block

    call    reverse_and_emit_line   ; uses r12, r14, r15 as globals

    pop     rcx                     ; restore newline position
    pop     r9
    pop     r8

    ; Advance past the bytes before newline + the newline itself
    add     r8, rcx
    inc     r8                      ; skip the \n
    xor     r15d, r15d              ; reset line buffer
    jmp     .pf_scan_simd

.pf_scan_scalar_entry:
    ; Fewer than 16 bytes remain — process one byte at a time
.pf_scan_scalar:
    cmp     r8, r9
    jge     .pf_read_loop           ; done with this chunk, read more

    lea     rsi, [rel read_buf]
    movzx   eax, byte [rsi + r8]
    cmp     al, 10                  ; newline?
    je      .pf_scalar_found_nl

    ; Append byte to line buffer
    cmp     r15, LINE_BUF_SIZE
    jge     .pf_line_overflow
    mov     [r14 + r15], al
    inc     r15
    inc     r8
    jmp     .pf_scan_scalar

.pf_scalar_found_nl:
    ; Save r8, r9 across call to reverse_and_emit_line
    push    r8
    push    r9
    call    reverse_and_emit_line
    pop     r9
    pop     r8

    inc     r8                      ; skip the \n
    xor     r15d, r15d              ; reset line buffer
    jmp     .pf_scan_scalar

.pf_read_eof:
    ; Handle remaining data in line buffer (no trailing newline)
    test    r15, r15
    jz      .pf_done
    call    reverse_and_emit_nolf

.pf_done:
    pop     r15
    pop     r14
    pop     rbx
    ret

.pf_read_error:
    mov     ebp, 1
    jmp     .pf_done

.pf_line_overflow:
    ; Line exceeds 1MB buffer — emit what we have and continue
    push    r8
    push    r9
    call    reverse_and_emit_line
    pop     r9
    pop     r8
    xor     r15d, r15d
    jmp     .pf_scan_scalar

; ─── reverse_and_emit_line() ─────────────────────────────
; Reverses line_buf[0..r15) and appends the reversed data + \n to out_buf.
; Uses SSSE3 pshufb for 16-byte-at-a-time reversal.
; Modifies: r12 (out_buf_used). Clobbers: rax, rcx, rdi, rsi, xmm0, xmm3.
reverse_and_emit_line:
    ; If empty line, just emit newline
    test    r15, r15
    jz      .rel_just_newline

    ; Ensure space: need r15+1 bytes in out_buf
    lea     rax, [r12 + r15 + 1]
    cmp     rax, OUT_BUF_SIZE
    jl      .rel_space_ok
    call    flush_output
    test    eax, eax
    jnz     .rel_write_error
.rel_space_ok:

    ; Set up pointers for reversal
    ; Dest: out_buf + r12 (write forward)
    ; Source: line_buf, read from end going backward
    lea     rdi, [rel out_buf]
    add     rdi, r12                ; dest pointer
    mov     rcx, r15                ; bytes to reverse

    cmp     rcx, 16
    jl      .rel_scalar

    ; SSSE3 path: process 16 bytes at a time
    ; Read 16 bytes from end of line, pshufb to reverse, write to dest
    movdqa  xmm3, [rel reverse_mask]
    lea     rsi, [r14 + r15]        ; rsi = end of line_buf data

.rel_simd_loop:
    cmp     rcx, 16
    jl      .rel_simd_tail

    sub     rsi, 16                 ; back up 16 bytes
    movdqu  xmm0, [rsi]            ; load from end
    pshufb  xmm0, xmm3             ; reverse 16 bytes
    movdqu  [rdi], xmm0            ; write to dest
    add     rdi, 16
    sub     rcx, 16
    jmp     .rel_simd_loop

.rel_simd_tail:
    ; Remaining bytes (0..15) at line_buf[0..rcx)
    test    rcx, rcx
    jz      .rel_append_nl
    ; Reverse remaining bytes with scalar
    lea     rsi, [r14 + rcx - 1]   ; last byte of remaining
    jmp     .rel_scalar_loop

.rel_scalar:
    ; Pure scalar reversal for lines < 16 bytes
    lea     rsi, [r14 + rcx - 1]   ; last byte of source

.rel_scalar_loop:
    test    rcx, rcx
    jz      .rel_append_nl
    movzx   eax, byte [rsi]
    mov     [rdi], al
    dec     rsi
    inc     rdi
    dec     rcx
    jmp     .rel_scalar_loop

.rel_append_nl:
    ; Append \n after the reversed data
    lea     rdi, [rel out_buf]
    add     rdi, r12
    add     rdi, r15
    mov     byte [rdi], 10
    lea     rax, [r15 + 1]
    add     r12, rax                ; out_buf_used += len + 1

    ; Flush if buffer is getting full
    cmp     r12, FLUSH_THRESHOLD
    jl      .rel_done
    call    flush_output
    test    eax, eax
    jnz     .rel_write_error

.rel_done:
    ret

.rel_just_newline:
    ; Empty line: just append \n
    ; Ensure space for 1 byte
    lea     rax, [r12 + 1]
    cmp     rax, OUT_BUF_SIZE
    jl      .rel_jnl_ok
    call    flush_output
    test    eax, eax
    jnz     .rel_write_error
.rel_jnl_ok:
    lea     rdi, [rel out_buf]
    add     rdi, r12
    mov     byte [rdi], 10
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .rel_done
    call    flush_output
    test    eax, eax
    jnz     .rel_write_error
    ret

.rel_write_error:
    mov     ebp, 1
    ret

; ─── reverse_and_emit_nolf() ─────────────────────────────
; Same as reverse_and_emit_line but no trailing newline.
reverse_and_emit_nolf:
    test    r15, r15
    jz      .ren_done

    ; Ensure space
    lea     rax, [r12 + r15]
    cmp     rax, OUT_BUF_SIZE
    jl      .ren_space_ok
    call    flush_output
    test    eax, eax
    jnz     .ren_error
.ren_space_ok:

    lea     rdi, [rel out_buf]
    add     rdi, r12
    mov     rcx, r15

    cmp     rcx, 16
    jl      .ren_scalar

    movdqa  xmm3, [rel reverse_mask]
    lea     rsi, [r14 + r15]

.ren_simd_loop:
    cmp     rcx, 16
    jl      .ren_simd_tail
    sub     rsi, 16
    movdqu  xmm0, [rsi]
    pshufb  xmm0, xmm3
    movdqu  [rdi], xmm0
    add     rdi, 16
    sub     rcx, 16
    jmp     .ren_simd_loop

.ren_simd_tail:
    test    rcx, rcx
    jz      .ren_update
    lea     rsi, [r14 + rcx - 1]
    jmp     .ren_scalar_loop

.ren_scalar:
    lea     rsi, [r14 + rcx - 1]

.ren_scalar_loop:
    test    rcx, rcx
    jz      .ren_update
    movzx   eax, byte [rsi]
    mov     [rdi], al
    dec     rsi
    inc     rdi
    dec     rcx
    jmp     .ren_scalar_loop

.ren_update:
    add     r12, r15

.ren_done:
    ret

.ren_error:
    mov     ebp, 1
    ret

; ─── flush_output() ──────────────────────────────────────
; Writes out_buf[0..r12) to stdout. Returns 0 on success, -1 on error.
; Preserves all callee-saved registers. Resets r12 to 0 on success.
flush_output:
    test    r12, r12
    jz      .fo_nothing

    mov     rdi, STDOUT
    lea     rsi, [rel out_buf]
    mov     rdx, r12
    call    asm_write_all
    xor     r12d, r12d              ; reset buffer
    ret                             ; rax = 0 (success) or -1 (error) from asm_write_all

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

; ─── Error helpers ───────────────────────────────────────

; print_error_simple(rdi=message) — prints "rev: {message}\n" to stderr
print_error_simple:
    push    rbx
    mov     rbx, rdi                ; save message

    ; "rev: "
    mov     rdi, STDERR
    lea     rsi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all

    ; message
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    ; "\n"
    mov     rdi, STDERR
    lea     rsi, [rel str_newline]
    mov     rdx, 1
    call    asm_write_all

    pop     rbx
    ret

; err_file(rdi=filename, esi=errno) — "rev: cannot open {filename}: {strerror}\n" to stderr
err_file:
    push    rbx
    push    r13
    mov     rbx, rdi                ; filename
    mov     r13d, esi               ; errno

    ; "rev: cannot open "
    mov     rdi, STDERR
    lea     rsi, [rel str_cannot_open]
    mov     rdx, str_cannot_open_len
    call    asm_write_all

    ; filename
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    ; ": "
    mov     rdi, STDERR
    lea     rsi, [rel str_colon_space]
    mov     rdx, 2
    call    asm_write_all

    ; strerror
    mov     edi, r13d
    call    strerror
    mov     rbx, rax                ; save string ptr
    mov     rdi, rax
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    ; "\n"
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

    ; "rev: unrecognized option '"
    mov     rdi, STDERR
    lea     rsi, [rel str_unrecognized]
    mov     rdx, str_unrecognized_len
    call    asm_write_all

    ; option
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    ; "'\n"
    mov     rdi, STDERR
    lea     rsi, [rel str_quote_nl]
    mov     rdx, 2
    call    asm_write_all

    ; "Try 'rev --help' for more information.\n"
    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all

    pop     rbx
    ret

; err_invalid_option(rsi=option_string) — prints "rev: invalid option -- 'X'\nTry..."
; Extracts the character at rsi[1] for the error message.
err_invalid_option:
    push    rbx
    mov     rbx, rsi

    ; "rev: invalid option -- '"
    mov     rdi, STDERR
    lea     rsi, [rel str_invalid_opt]
    mov     rdx, str_invalid_opt_len
    call    asm_write_all

    ; The option character (byte at rbx+1)
    mov     rdi, STDERR
    lea     rsi, [rbx + 1]
    mov     rdx, 1
    call    asm_write_all

    ; "'\n"
    mov     rdi, STDERR
    lea     rsi, [rel str_quote_nl]
    mov     rdx, 2
    call    asm_write_all

    ; "Try 'rev --help' for more information.\n"
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
reverse_mask:
    db 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0

align 16
newline_pattern:
    times 16 db 10

; sigaction for SIGPIPE: sa_handler=SIG_DFL, sa_flags=SA_RESTORER, sa_restorer=0
sigact_buf:
    dq 0            ; sa_handler = SIG_DFL
    dq 0x04000000   ; sa_flags = SA_RESTORER
    dq 0            ; sa_restorer
    dq 0            ; sa_mask

str_prefix:     db "rev: "
str_prefix_len equ $ - str_prefix

str_cannot_open: db "rev: cannot open "
str_cannot_open_len equ $ - str_cannot_open

str_newline:    db 10
str_colon_space: db ": "

str_help:       db "--help", 0
str_version:    db "--version", 0

str_unrecognized: db "rev: unrecognized option '"
str_unrecognized_len equ $ - str_unrecognized

str_quote_nl:   db "'", 10

str_write_error: db "write error", 0

str_try_help: db "Try 'rev --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_invalid_opt: db "rev: invalid option -- '"
str_invalid_opt_len equ $ - str_invalid_opt

help_text:
    db "Usage: rev [OPTION]... [FILE]...", 10
    db "Reverse lines characterwise.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "      --help     display this help and exit", 10
    db "      --version  output version information and exit", 10
help_text_len equ $ - help_text

version_text:
    db "rev (fcoreutils) 0.1.0", 10
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

read_buf:   resb READ_BUF_SIZE
out_buf:    resb OUT_BUF_SIZE
line_buf:   resb LINE_BUF_SIZE

section .note.GNU-stack noalloc noexec nowrite progbits
