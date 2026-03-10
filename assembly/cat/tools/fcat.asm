; fcat.asm — GNU-compatible "cat" in x86_64 Linux assembly
;
; Supports: -n, -b, -s, -E, -T, -v, -A (= -vET), -e (= -vE), -t (= -vT),
;           -u (ignored), -- (end of options), - (stdin), multiple files
;
; Zero-copy fast path: sendfile() for regular files when no flags active
; Pipe/special fallback: read/write loop with 128KB buffer
; Flagged path: buffered transform with 128KB read / 256KB output buffer
;
; SIGPIPE: blocked via rt_sigprocmask, check for -EPIPE on writes
; EINTR: retried on all blocking syscalls
; Partial writes: handled in asm_write_all
;
; Build (modular):
;   nasm -f elf64 -I ./ tools/fcat.asm -o build/fcat.o
;   nasm -f elf64 -I ./ lib/io.asm -o build/io.o
;   ld --gc-sections build/fcat.o build/io.o -o fcat

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close

; ─── Constants ───────────────────────────────────────────
%define MAX_FILES       4096

; Flag bits stored in [flags]
%define FLAG_N          0x01    ; -n: number all lines
%define FLAG_B          0x02    ; -b: number non-blank lines
%define FLAG_S          0x04    ; -s: squeeze blank lines
%define FLAG_E          0x08    ; -E: show ends ($)
%define FLAG_T          0x10    ; -T: show tabs (^I)
%define FLAG_V          0x20    ; -v: show non-printing

; Sendfile max transfer per call (limited by ssize_t)
%define SENDFILE_CHUNK  0x7FFFF000

global _start

section .text

; ============================================================================
;                           ENTRY POINT
; ============================================================================
_start:
    ; ── Block SIGPIPE so write() returns -EPIPE instead of killing us ──
    sub     rsp, 16
    mov     qword [rsp], 0x1000         ; sigset: bit 12 = SIGPIPE (signal 13)
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi                    ; SIG_BLOCK = 0
    mov     rsi, rsp
    xor     edx, edx                    ; old_set = NULL
    mov     r10d, 8                     ; sizeof(sigset_t) for kernel
    syscall
    add     rsp, 16

    ; ── Save argc/argv ──
    mov     rax, [rsp]                  ; argc
    mov     [rel argc], rax
    lea     rax, [rsp + 8]
    mov     [rel argv], rax

    ; ── Initialize state ──
    mov     byte [rel flags], 0
    mov     byte [rel had_error], 0
    mov     qword [rel nfiles], 0
    mov     qword [rel line_number], 1
    mov     byte [rel at_line_start], 1
    mov     byte [rel blank_count], 0
    xor     r12d, r12d                  ; out_buf_used = 0

    ; ── Parse arguments ──
    call    parse_args

    ; ── If no files, use stdin ──
    cmp     qword [rel nfiles], 0
    jne     .have_files
    lea     rax, [rel dash_str]
    mov     [rel file_ptrs], rax
    mov     qword [rel nfiles], 1

.have_files:
    ; ── Process each file ──
    xor     ebx, ebx                    ; file index = 0

.file_loop:
    cmp     rbx, [rel nfiles]
    jge     .all_done

    lea     rdi, [rel file_ptrs]
    mov     rsi, [rdi + rbx*8]

    ; Check if filename is "-" (stdin)
    cmp     byte [rsi], '-'
    jne     .open_file
    cmp     byte [rsi+1], 0
    jne     .open_file

    ; Stdin
    push    rbx
    mov     edi, STDIN
    call    process_fd
    pop     rbx
    jmp     .file_next

.open_file:
    push    rbx
    push    rsi                         ; save filename
    mov     rdi, rsi
    xor     esi, esi                    ; O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .open_error

    ; Save fd, process it
    mov     r14, rax                    ; fd
    mov     edi, r14d
    call    process_fd

    ; Close file
    mov     rdi, r14
    call    asm_close

    pop     rsi                         ; discard saved filename
    pop     rbx
    jmp     .file_next

.open_error:
    neg     rax                         ; positive errno
    mov     r13d, eax                   ; save errno
    pop     rsi                         ; filename
    pop     rbx
    push    rbx
    push    rsi
    mov     rdi, rsi
    mov     esi, r13d
    call    err_file
    pop     rsi
    pop     rbx
    mov     byte [rel had_error], 1

.file_next:
    inc     rbx
    jmp     .file_loop

.all_done:
    ; Flush remaining output buffer
    call    flush_output
    test    rax, rax
    js      .final_write_error

    ; Exit with appropriate code
    movzx   edi, byte [rel had_error]
    mov     eax, SYS_EXIT
    syscall

.final_write_error:
    cmp     rax, -EPIPE
    je      .epipe_exit
    lea     rdi, [rel str_write_error]
    call    print_error_simple
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.epipe_exit:
    ; EPIPE: flush stderr error msg, exit 1
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

; ============================================================================
;                        ARGUMENT PARSING
; ============================================================================
parse_args:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, [rel argc]
    mov     r13, [rel argv]
    mov     rbx, 1                      ; start at argv[1]
    xor     r14d, r14d                  ; seen_dashdash = 0

.pa_loop:
    cmp     rbx, r12
    jge     .pa_done

    mov     rsi, [r13 + rbx*8]

    ; If seen --, treat everything as filename
    test    r14d, r14d
    jnz     .pa_is_file

    ; Check if starts with '-'
    cmp     byte [rsi], '-'
    jne     .pa_is_file
    cmp     byte [rsi+1], 0
    je      .pa_is_file                 ; bare "-" is a file (stdin)

    ; Check for "--"
    cmp     byte [rsi+1], '-'
    jne     .pa_short_opts

    ; Starts with "--"
    cmp     byte [rsi+2], 0
    je      .pa_dashdash                ; exactly "--"

    ; Check --help
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rdi, rsi
    lea     rsi, [rel str_help_opt]
    call    str_eq_cat
    test    eax, eax
    jnz     .pa_do_help

    ; Check --version
    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [rel str_version_opt]
    call    str_eq_cat
    test    eax, eax
    jnz     .pa_do_version

    ; Unknown --option: error and exit
    mov     rdi, [r13 + rbx*8]
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    call    err_unrecognized_option
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.pa_do_help:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ; Print help to stdout and exit 0
    mov     rdi, STDOUT
    lea     rsi, [rel help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.pa_do_version:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ; Print version to stdout and exit 0
    mov     rdi, STDOUT
    lea     rsi, [rel version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.pa_dashdash:
    mov     r14d, 1
    jmp     .pa_next

.pa_short_opts:
    ; Parse combined short options: -abc means -a -b -c
    mov     rcx, 1                      ; start at char index 1 (skip '-')

.pa_short_loop:
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .pa_next                    ; end of string

    cmp     al, 'n'
    je      .pa_flag_n
    cmp     al, 'b'
    je      .pa_flag_b
    cmp     al, 's'
    je      .pa_flag_s
    cmp     al, 'E'
    je      .pa_flag_E
    cmp     al, 'T'
    je      .pa_flag_T
    cmp     al, 'v'
    je      .pa_flag_v
    cmp     al, 'A'
    je      .pa_flag_A
    cmp     al, 'e'
    je      .pa_flag_e
    cmp     al, 't'
    je      .pa_flag_t
    cmp     al, 'u'
    je      .pa_flag_u

    ; Unknown short option
    push    rsi
    push    rcx
    mov     rdi, rsi
    movzx   esi, al
    call    err_invalid_option
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.pa_flag_n:
    or      byte [rel flags], FLAG_N
    jmp     .pa_short_next
.pa_flag_b:
    or      byte [rel flags], FLAG_B
    jmp     .pa_short_next
.pa_flag_s:
    or      byte [rel flags], FLAG_S
    jmp     .pa_short_next
.pa_flag_E:
    or      byte [rel flags], FLAG_E
    jmp     .pa_short_next
.pa_flag_T:
    or      byte [rel flags], FLAG_T
    jmp     .pa_short_next
.pa_flag_v:
    or      byte [rel flags], FLAG_V
    jmp     .pa_short_next
.pa_flag_A:
    or      byte [rel flags], FLAG_V | FLAG_E | FLAG_T
    jmp     .pa_short_next
.pa_flag_e:
    or      byte [rel flags], FLAG_V | FLAG_E
    jmp     .pa_short_next
.pa_flag_t:
    or      byte [rel flags], FLAG_V | FLAG_T
    jmp     .pa_short_next
.pa_flag_u:
    ; -u is ignored (unbuffered — we're already unbuffered enough)
    jmp     .pa_short_next

.pa_short_next:
    inc     rcx
    jmp     .pa_short_loop

.pa_is_file:
    ; Store file pointer
    mov     rax, [rel nfiles]
    cmp     rax, MAX_FILES
    jge     .pa_next                    ; silently drop excess files
    lea     rcx, [rel file_ptrs]
    mov     [rcx + rax*8], rsi
    inc     qword [rel nfiles]

.pa_next:
    inc     rbx
    jmp     .pa_loop

.pa_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  process_fd(edi=fd) — Process one file descriptor
;  Chooses between zero-copy sendfile path (no flags) and flagged path.
; ============================================================================
process_fd:
    push    rbx
    push    r14
    push    r15
    mov     ebx, edi                    ; save fd

    ; Check if any flags are active
    movzx   eax, byte [rel flags]
    test    al, al
    jnz     .pf_flagged_path

    ; ── Zero-copy path: no flags active ──
    ; fstat to check if regular file
    lea     rsi, [rel stat_buf]
    mov     edi, ebx
    FSTAT   rdi, rsi
    test    rax, rax
    js      .pf_readwrite               ; fstat failed, use read/write

    ; Check if regular file
    mov     eax, [rel stat_buf + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFREG
    jne     .pf_readwrite               ; not regular file, use read/write

    ; Get file size
    mov     r14, [rel stat_buf + STAT_SIZE]
    test    r14, r14
    jz      .pf_done                    ; empty file, nothing to do

    ; ── sendfile loop ──
    ; sendfile(out_fd=STDOUT, in_fd=fd, offset=NULL, count)
    mov     r15, r14                    ; remaining bytes
.pf_sendfile_loop:
    test    r15, r15
    jle     .pf_done

    mov     eax, SYS_SENDFILE
    mov     edi, STDOUT
    mov     esi, ebx                    ; in_fd
    xor     edx, edx                    ; offset = NULL
    mov     r10, r15
    cmp     r10, SENDFILE_CHUNK
    jle     .pf_sf_count_ok
    mov     r10, SENDFILE_CHUNK
.pf_sf_count_ok:
    syscall

    cmp     rax, -EINTR
    je      .pf_sendfile_loop           ; EINTR, retry

    test    rax, rax
    js      .pf_sendfile_error          ; error
    jz      .pf_done                    ; EOF (shouldn't happen for regular files)

    sub     r15, rax
    jmp     .pf_sendfile_loop

.pf_sendfile_error:
    cmp     rax, -EPIPE
    je      .pf_epipe
    ; sendfile failed (e.g., incompatible fd types) — fall back to read/write
    jmp     .pf_readwrite

    ; ── Read/write fallback for non-regular files (no flags) ──
.pf_readwrite:
    mov     edi, ebx
    lea     rsi, [rel read_buf]
    mov     edx, READ_BUF_SIZE
    call    asm_read

    test    rax, rax
    js      .pf_read_error
    jz      .pf_done                    ; EOF

    ; Write what we read directly to stdout
    mov     rdi, STDOUT
    lea     rsi, [rel read_buf]
    mov     rdx, rax
    call    asm_write_all
    test    rax, rax
    js      .pf_write_error

    jmp     .pf_readwrite

    ; ── Flagged path ──
.pf_flagged_path:
    call    process_fd_flagged

.pf_done:
    pop     r15
    pop     r14
    pop     rbx
    ret

.pf_read_error:
    mov     byte [rel had_error], 1
    jmp     .pf_done

.pf_write_error:
    cmp     rax, -EPIPE
    je      .pf_epipe
    mov     byte [rel had_error], 1
    jmp     .pf_done

.pf_epipe:
    ; On EPIPE, exit immediately with code 1 (after flushing)
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

; ============================================================================
;  process_fd_flagged() — Process fd with flags active
;  Uses: rbx = fd (already saved by caller)
;  Modifies: r12 (out_buf_used), line_number, at_line_start, blank_count
;
;  Optimized: inline output buffer writes to avoid call/push/pop overhead.
;  r13 = pointer to out_buf base (cached for speed)
; ============================================================================
process_fd_flagged:
    push    r13
    push    r14
    push    r15

    lea     r13, [rel out_buf]          ; cache out_buf pointer

.pff_read_loop:
    mov     edi, ebx
    lea     rsi, [rel read_buf]
    mov     edx, READ_BUF_SIZE
    call    asm_read

    test    rax, rax
    js      .pff_read_error
    jz      .pff_done                   ; EOF

    ; Process bytes: rax = bytes read
    xor     r14d, r14d                  ; offset = 0
    mov     r15, rax                    ; total bytes read

.pff_byte_loop:
    cmp     r14, r15
    jge     .pff_flush_check            ; done with this chunk

    lea     rsi, [rel read_buf]
    movzx   eax, byte [rsi + r14]       ; current byte

    ; ── Handle newline ──
    cmp     al, 10
    je      .pff_newline

    ; ── Handle non-newline byte ──

    ; Non-newline byte: reset blank_count
    mov     byte [rel blank_count], 0

    ; If at line start, maybe print line number
    cmp     byte [rel at_line_start], 0
    je      .pff_after_linenum

    ; At line start with non-newline char: print line number if -n or -b
    movzx   ecx, byte [rel flags]

    ; -b wins over -n: number non-blank lines
    test    cl, FLAG_B
    jnz     .pff_print_linenum
    test    cl, FLAG_N
    jnz     .pff_print_linenum
    jmp     .pff_clear_start

.pff_print_linenum:
    push    rax
    call    emit_line_number
    pop     rax

.pff_clear_start:
    mov     byte [rel at_line_start], 0

.pff_after_linenum:
    ; ── Fast bulk copy check ──
    ; If only simple flags active (no -v, -E, -T), we can bulk-copy until newline
    movzx   ecx, byte [rel flags]
    test    cl, FLAG_V | FLAG_E | FLAG_T
    jnz     .pff_slow_char              ; need per-byte transforms

    ; ── Bulk copy path: scan for next newline, copy run of bytes ──
    ; Current byte in al, offset in r14, total in r15
    ; Find distance to next newline from current position
    lea     rsi, [rel read_buf]
    mov     rdi, r14                    ; current offset (already loaded al from here)

.pff_bulk_scan:
    cmp     rdi, r15
    jge     .pff_bulk_copy_run          ; no newline found, copy all remaining

    cmp     byte [rsi + rdi], 10
    je      .pff_bulk_found_nl

    inc     rdi
    jmp     .pff_bulk_scan

.pff_bulk_found_nl:
    ; Found newline at position rdi. Copy [r14..rdi) to output, then handle newline.
    ; Bytes to copy = rdi - r14
    mov     rcx, rdi
    sub     rcx, r14
    jz      .pff_bulk_nl_only           ; newline is the current byte (already consumed)

    ; Ensure output buffer has space: rcx + 2 (for possible $ and \n)
    lea     rax, [r12 + rcx + 2]
    cmp     rax, OUT_BUF_SIZE
    jge     .pff_bulk_flush_first

.pff_bulk_do_copy:
    ; Copy bytes from read_buf+r14 to out_buf+r12
    lea     rsi, [rel read_buf]
    add     rsi, r14
    lea     rdx, [r13 + r12]
    ; Fast copy loop
    mov     rax, rcx
    shr     rax, 3                      ; 8-byte chunks
    jz      .pff_bulk_copy_tail

.pff_bulk_copy8:
    mov     r8, [rsi]
    mov     [rdx], r8
    add     rsi, 8
    add     rdx, 8
    dec     rax
    jnz     .pff_bulk_copy8

.pff_bulk_copy_tail:
    mov     rax, rcx
    and     rax, 7                      ; remaining bytes
    jz      .pff_bulk_copy_done

.pff_bulk_copy1:
    movzx   r8d, byte [rsi]
    mov     [rdx], r8b
    inc     rsi
    inc     rdx
    dec     rax
    jnz     .pff_bulk_copy1

.pff_bulk_copy_done:
    add     r12, rcx
    mov     r14, rdi                    ; advance offset to newline position

.pff_bulk_nl_only:
    ; Now handle the newline at r14
    ; -s squeeze check
    ; Note: at_line_start is 0 here (we just had content), so no squeeze needed
    ; and we don't need to number this newline (it's end of a content line)
    ; Just emit the newline
    mov     byte [r13 + r12], 10
    inc     r12
    mov     byte [rel at_line_start], 1
    inc     r14

    ; Flush check
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_bulk_copy_run:
    ; No newline in remaining buffer, copy everything
    mov     rcx, r15
    sub     rcx, r14
    jz      .pff_flush_check            ; nothing to copy

    lea     rax, [r12 + rcx]
    cmp     rax, OUT_BUF_SIZE
    jge     .pff_bulk_flush_first2

.pff_bulk_do_copy2:
    lea     rsi, [rel read_buf]
    add     rsi, r14
    lea     rdx, [r13 + r12]
    mov     rax, rcx
    shr     rax, 3
    jz      .pff_bulk_copy_tail2

.pff_bulk_copy8_2:
    mov     r8, [rsi]
    mov     [rdx], r8
    add     rsi, 8
    add     rdx, 8
    dec     rax
    jnz     .pff_bulk_copy8_2

.pff_bulk_copy_tail2:
    mov     rax, rcx
    and     rax, 7
    jz      .pff_bulk_copy_done2

.pff_bulk_copy1_2:
    movzx   r8d, byte [rsi]
    mov     [rdx], r8b
    inc     rsi
    inc     rdx
    dec     rax
    jnz     .pff_bulk_copy1_2

.pff_bulk_copy_done2:
    add     r12, rcx
    mov     r14, r15                    ; consumed everything
    jmp     .pff_flush_check

.pff_bulk_flush_first:
    ; Need to flush before copying
    push    rcx
    push    rdi
    call    flush_output
    pop     rdi
    pop     rcx
    test    rax, rax
    js      .pff_write_error
    jmp     .pff_bulk_do_copy

.pff_bulk_flush_first2:
    push    rcx
    call    flush_output
    pop     rcx
    test    rax, rax
    js      .pff_write_error
    jmp     .pff_bulk_do_copy2

    ; ── Slow per-byte character transform path ──
.pff_slow_char:
    ; Check for tab
    cmp     al, 9
    je      .pff_check_tab

    ; Check for -v (non-printing)
    test    cl, FLAG_V
    jz      .pff_emit_byte_inline

    ; -v mode: handle non-printing characters
    cmp     al, 0x20
    jb      .pff_v_ctrl
    cmp     al, 0x7F
    je      .pff_v_del
    cmp     al, 0x80
    jb      .pff_emit_byte_inline
    jmp     .pff_v_high

.pff_check_tab:
    test    cl, FLAG_T
    jz      .pff_emit_byte_inline     ; no -T, pass tab through
    ; -T: emit "^I" inline
    mov     byte [r13 + r12], '^'
    inc     r12
    mov     byte [r13 + r12], 'I'
    inc     r12
    inc     r14
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_v_ctrl:
    ; 0x00-0x1F except \t and \n: '^' + (char + '@')
    mov     byte [r13 + r12], '^'
    inc     r12
    add     al, '@'
    mov     [r13 + r12], al
    inc     r12
    inc     r14
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_v_del:
    ; 0x7F: '^?'
    mov     byte [r13 + r12], '^'
    inc     r12
    mov     byte [r13 + r12], '?'
    inc     r12
    inc     r14
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_v_high:
    ; 0x80-0xFF
    cmp     al, 0x9F
    jbe     .pff_v_high_ctrl
    cmp     al, 0xFF
    je      .pff_v_high_del

    ; 0xA0-0xFE: 'M-' + (char - 0x80)
    mov     byte [r13 + r12], 'M'
    inc     r12
    mov     byte [r13 + r12], '-'
    inc     r12
    sub     al, 0x80
    mov     [r13 + r12], al
    inc     r12
    inc     r14
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_v_high_ctrl:
    ; 0x80-0x9F: 'M-^' + (char - 0x80 + '@')
    mov     byte [r13 + r12], 'M'
    inc     r12
    mov     byte [r13 + r12], '-'
    inc     r12
    mov     byte [r13 + r12], '^'
    inc     r12
    sub     al, 0x80
    add     al, '@'
    mov     [r13 + r12], al
    inc     r12
    inc     r14
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_v_high_del:
    ; 0xFF: 'M-^?'
    mov     byte [r13 + r12], 'M'
    inc     r12
    mov     byte [r13 + r12], '-'
    inc     r12
    mov     byte [r13 + r12], '^'
    inc     r12
    mov     byte [r13 + r12], '?'
    inc     r12
    inc     r14
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_emit_byte_inline:
    ; Emit the byte directly to output buffer
    mov     [r13 + r12], al
    inc     r12
    inc     r14
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

    ; ── Flush needed in middle of processing ──
.pff_need_flush:
    call    flush_output
    test    rax, rax
    js      .pff_write_error
    jmp     .pff_byte_loop

    ; ── Flush check between read chunks ──
.pff_flush_check:
    cmp     r12, FLUSH_THRESHOLD
    jl      .pff_read_loop
    call    flush_output
    test    rax, rax
    js      .pff_write_error
    jmp     .pff_read_loop

    ; ── Newline handling ──
.pff_newline:
    ; Check -s (squeeze blank lines)
    movzx   ecx, byte [rel flags]
    test    cl, FLAG_S
    jz      .pff_nl_no_squeeze

    ; -s active: check if this is a blank line
    cmp     byte [rel at_line_start], 1
    jne     .pff_nl_no_squeeze

    ; This is a blank line
    movzx   edx, byte [rel blank_count]
    cmp     dl, 1
    jge     .pff_nl_suppress
    inc     byte [rel blank_count]
    jmp     .pff_nl_no_squeeze

.pff_nl_suppress:
    inc     r14
    jmp     .pff_byte_loop

.pff_nl_no_squeeze:
    ; If at line start: this is a blank line
    cmp     byte [rel at_line_start], 0
    je      .pff_nl_after_linenum

    ; Blank line: number it with -n but not with -b
    movzx   ecx, byte [rel flags]
    test    cl, FLAG_B
    jnz     .pff_nl_after_linenum

    test    cl, FLAG_N
    jz      .pff_nl_after_linenum

    ; -n: number this blank line
    call    emit_line_number

.pff_nl_after_linenum:
    ; If -E: emit '$' before newline
    movzx   ecx, byte [rel flags]
    test    cl, FLAG_E
    jz      .pff_nl_emit

    mov     byte [r13 + r12], '$'
    inc     r12

.pff_nl_emit:
    ; Emit the newline
    mov     byte [r13 + r12], 10
    inc     r12

    mov     byte [rel at_line_start], 1
    inc     r14

    ; Check if we need to flush
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_read_error:
    mov     byte [rel had_error], 1
    jmp     .pff_done

.pff_write_error:
    cmp     rax, -EPIPE
    je      .pff_epipe
    mov     byte [rel had_error], 1
    jmp     .pff_done

.pff_epipe:
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.pff_done:
    pop     r15
    pop     r14
    pop     r13
    ret

; ============================================================================
;  emit_byte(al=byte) — Append byte to output buffer, flush if needed
;  Clobbers: rdi, rsi, rdx (if flushing)
; ============================================================================
emit_byte:
    lea     rdi, [rel out_buf]
    mov     [rdi + r12], al
    inc     r12

    cmp     r12, FLUSH_THRESHOLD
    jl      .eb_done

    ; Flush
    call    flush_output
    test    rax, rax
    js      .eb_write_error

.eb_done:
    ret

.eb_write_error:
    cmp     rax, -EPIPE
    je      .eb_epipe
    mov     byte [rel had_error], 1
    ret

.eb_epipe:
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

; ============================================================================
;  emit_line_number() — Write "%6d\t" line number to output buffer
;  Increments line_number.
;  Uses r13 = out_buf base pointer (from caller), r12 = out_buf_used
;  Clobbers: rax, rcx, rdi, rdx
; ============================================================================
emit_line_number:
    push    rbx

    mov     rax, [rel line_number]
    inc     qword [rel line_number]

    ; Convert number to decimal string (reversed into itoa_buf)
    lea     rdi, [rel itoa_buf]
    add     rdi, 23                     ; end of buffer
    mov     byte [rdi], 0              ; null terminate (not needed but safe)
    mov     rcx, 10
    xor     ebx, ebx                    ; digit count

.eln_div_loop:
    xor     edx, edx
    div     rcx                         ; rax = quotient, rdx = remainder
    add     dl, '0'
    dec     rdi
    mov     [rdi], dl
    inc     ebx
    test    rax, rax
    jnz     .eln_div_loop

    ; rdi now points to first digit, ebx = digit count
    ; We need: 6 chars total, right-justified, then \t
    ; Write directly to output buffer inline
    mov     ecx, 6
    sub     ecx, ebx                    ; spaces needed
    jle     .eln_emit_digits            ; number >= 6 digits, no padding

    ; Emit spaces directly
.eln_space_loop:
    mov     byte [r13 + r12], ' '
    inc     r12
    dec     ecx
    jnz     .eln_space_loop

.eln_emit_digits:
    ; Emit digits directly
    mov     ecx, ebx
.eln_digit_loop:
    movzx   eax, byte [rdi]
    mov     [r13 + r12], al
    inc     r12
    inc     rdi
    dec     ecx
    jnz     .eln_digit_loop

    ; Emit tab
    mov     byte [r13 + r12], 9
    inc     r12

    ; Check if flush needed (line number is at most ~20 chars, but check anyway)
    cmp     r12, FLUSH_THRESHOLD
    jl      .eln_done
    call    flush_output

.eln_done:
    pop     rbx
    ret

; ============================================================================
;  flush_output() — Write out_buf[0..r12) to stdout
;  Returns rax = 0 on success, negative error on failure
;  Resets r12 = 0 on success
; ============================================================================
flush_output:
    test    r12, r12
    jz      .fo_nothing

    mov     rdi, STDOUT
    lea     rsi, [rel out_buf]
    mov     rdx, r12
    call    asm_write_all
    xor     r12d, r12d                  ; reset buffer
    ret                                 ; rax from asm_write_all

.fo_nothing:
    xor     eax, eax
    ret

; ============================================================================
;  Error helpers
; ============================================================================

; strlen(rdi=str) -> rax=length
strlen:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; print_error_simple(rdi=message) — prints "cat: {message}\n" to stderr
print_error_simple:
    push    rbx
    mov     rbx, rdi

    mov     rdi, STDERR
    lea     rsi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all

    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_newline]
    mov     rdx, 1
    call    asm_write_all

    pop     rbx
    ret

; err_file(rdi=filename, esi=errno) — "cat: {filename}: {strerror}\n" to stderr
err_file:
    push    rbx
    push    r13
    mov     rbx, rdi
    mov     r13d, esi

    ; "cat: "
    mov     rdi, STDERR
    lea     rsi, [rel str_prefix]
    mov     rdx, str_prefix_len
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
    mov     rbx, rax
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

; err_unrecognized_option(rdi=option_string)
err_unrecognized_option:
    push    rbx
    mov     rbx, rdi

    ; "cat: unrecognized option '"
    mov     rdi, STDERR
    lea     rsi, [rel str_unrecognized]
    mov     rdx, str_unrecognized_len
    call    asm_write_all

    ; option string
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

    ; "Try 'cat --help' for more information.\n"
    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all

    pop     rbx
    ret

; err_invalid_option(rdi=full_arg_string, sil=bad_char_byte)
; Prints: "cat: invalid option -- 'X'\nTry..."
err_invalid_option:
    push    rbx
    push    r13
    mov     r13d, esi                   ; save bad char

    ; "cat: invalid option -- '"
    mov     rdi, STDERR
    lea     rsi, [rel str_invalid_opt]
    mov     rdx, str_invalid_opt_len
    call    asm_write_all

    ; The bad character
    mov     [rel char_buf], r13b
    mov     rdi, STDERR
    lea     rsi, [rel char_buf]
    mov     rdx, 1
    call    asm_write_all

    ; "'\n"
    mov     rdi, STDERR
    lea     rsi, [rel str_quote_nl]
    mov     rdx, 2
    call    asm_write_all

    ; "Try 'cat --help' for more information.\n"
    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all

    pop     r13
    pop     rbx
    ret

; strerror(edi=errno) -> rax=string pointer
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

; str_eq_cat(rdi=s1, rsi=s2) -> eax=1 if equal, 0 if not
str_eq_cat:
.sec_loop:
    mov     al, [rdi]
    mov     cl, [rsi]
    cmp     al, cl
    jne     .sec_ne
    test    al, al
    jz      .sec_equal
    inc     rdi
    inc     rsi
    jmp     .sec_loop
.sec_equal:
    mov     eax, 1
    ret
.sec_ne:
    xor     eax, eax
    ret

; ─── Data Section ────────────────────────────────────────
section .data

str_prefix:     db "cat: "
str_prefix_len  equ $ - str_prefix

str_newline:    db 10
str_colon_space: db ": "

str_unrecognized: db "cat: unrecognized option '"
str_unrecognized_len equ $ - str_unrecognized

str_quote_nl:   db "'", 10

str_try_help:   db "Try 'cat --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_invalid_opt: db "cat: invalid option -- '"
str_invalid_opt_len equ $ - str_invalid_opt

str_write_error: db "write error", 0

str_help_opt:   db "--help", 0
str_version_opt: db "--version", 0

help_text:
    db "Usage: cat [OPTION]... [FILE]...", 10
    db "Concatenate FILE(s) to standard output.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "  -A, --show-all           equivalent to -vET", 10
    db "  -b, --number-nonblank    number nonempty output lines, overrides -n", 10
    db "  -e                       equivalent to -vE", 10
    db "  -E, --show-ends          display $ at end of each line", 10
    db "  -n, --number             number all output lines", 10
    db "  -s, --squeeze-blank      suppress repeated empty output lines", 10
    db "  -t                       equivalent to -vT", 10
    db "  -T, --show-tabs          display TAB characters as ^I", 10
    db "  -u                       (ignored)", 10
    db "  -v, --show-nonprinting   use ^ and M- notation, except for LFD and TAB", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "Examples:", 10
    db "  cat f - g  Output f's contents, then standard input, then g's contents.", 10
    db "  cat        Copy standard input to standard output.", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/cat>", 10
    db "or available locally via: info '(coreutils) cat invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "cat (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Torbjorn Granlund and Richard M. Stallman.", 10
version_text_len equ $ - version_text

dash_str:       db "-", 0

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

argc:           resq 1
argv:           resq 1
flags:          resb 1
had_error:      resb 1
nfiles:         resq 1
file_ptrs:      resq MAX_FILES
line_number:    resq 1
at_line_start:  resb 1
blank_count:    resb 1
char_buf:       resb 1
itoa_buf:       resb 24
stat_buf:       resb STAT_STRUCT_SIZE
read_buf:       resb READ_BUF_SIZE
out_buf:        resb OUT_BUF_SIZE

section .note.GNU-stack noalloc noexec nowrite progbits
