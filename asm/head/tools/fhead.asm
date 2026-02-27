; ============================================================================
;  fhead.asm — GNU-compatible "head" in x86_64 Linux assembly
;
;  A drop-in replacement for GNU coreutils `head`. Produces a small static
;  ELF binary with zero dependencies — no libc, no dynamic linker.
;
;  Supports all GNU head flags:
;    -n NUM / --lines=NUM / --lines NUM   (first N lines, default 10)
;    -c NUM / --bytes=NUM / --bytes NUM   (first N bytes)
;    -n -NUM  (all but last N lines)
;    -c -NUM  (all but last N bytes)
;    -q / --quiet / --silent              (never print headers)
;    -v / --verbose                       (always print headers)
;    -z / --zero-terminated               (NUL delimiter instead of newline)
;    --help / --version / --
;    Legacy: head -5 means head -n 5
;    NUM suffixes: b, kB, K, MB, M, GB, G, TB, T, PB, P, EB, E
;
;  BUILD:
;    cd asm && make fhead
; ============================================================================

%include "include/linux.inc"
%include "include/macros.inc"

; External shared library functions
extern asm_write_all
extern asm_read
extern asm_open
extern asm_close
extern asm_exit

; ── Constants ──────────────────────────────────────────
%define IOBUF_SIZE      65536           ; 64KB I/O buffer
%define FROMBUF_SIZE    (4 * 1024 * 1024) ; 4MB buffer for "from end" modes

; Mode constants
%define MODE_LINES       0              ; -n N (default)
%define MODE_BYTES       1              ; -c N
%define MODE_LINES_END   2              ; -n -N
%define MODE_BYTES_END   3              ; -c -N

; mmap constants
%define PROT_READ        1
%define PROT_WRITE       2
%define MAP_PRIVATE      2
%define MAP_ANONYMOUS    0x20

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
    mov     rax, [rsp]                  ; argc (was pushed by kernel before sigprocmask)
    ; At this point rsp points to argc
    ; rsp+0 = argc, rsp+8 = argv[0], rsp+16 = argv[1], ...
    mov     [rel argc], rax
    lea     rax, [rsp + 8]
    mov     [rel argv], rax

    ; ── Initialize defaults ──
    mov     qword [rel mode], MODE_LINES
    mov     qword [rel count], 10       ; default: 10 lines
    mov     byte [rel quiet], 0
    mov     byte [rel verbose], 0
    mov     byte [rel zero_term], 0
    mov     qword [rel nfiles], 0

    ; ── Parse arguments ──
    call    parse_args

    ; ── If no files, use stdin ──
    cmp     qword [rel nfiles], 0
    jne     .have_files
    ; Set files[0] = dash_str ("-")
    lea     rax, [rel dash_str]
    mov     [rel files], rax
    mov     qword [rel nfiles], 1

.have_files:
    ; ── Determine whether to show headers ──
    ; quiet => never, verbose => always, else => nfiles > 1
    cmp     byte [rel quiet], 1
    je      .no_headers
    cmp     byte [rel verbose], 1
    je      .yes_headers
    cmp     qword [rel nfiles], 1
    jg      .yes_headers
.no_headers:
    mov     byte [rel show_headers], 0
    jmp     .process_files
.yes_headers:
    mov     byte [rel show_headers], 1

.process_files:
    mov     byte [rel had_error], 0
    mov     byte [rel first_file], 1
    xor     r12d, r12d                  ; file index

.file_loop:
    cmp     r12, [rel nfiles]
    jge     .done

    ; Get filename pointer
    lea     rax, [rel files]
    mov     rbx, [rax + r12*8]          ; rbx = files[file_index]

    ; ── For non-stdin files, try to open first before printing header ──
    mov     rdi, rbx
    lea     rsi, [rel dash_str]
    call    str_equal
    test    eax, eax
    jnz     .is_stdin_file

    ; Try to open the file
    mov     rdi, rbx
    xor     esi, esi                    ; O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .file_open_error
    mov     [rel cur_fd], rax           ; save fd

    ; File opened successfully — print header then process
    call    print_file_header
    test    rax, rax
    js      .write_error
    mov     byte [rel first_file], 0
    mov     rdi, [rel cur_fd]
    call    process_fd
    push    rax
    mov     rdi, [rel cur_fd]
    call    asm_close
    pop     rax
    test    rax, rax
    jns     .file_next
    ; Check for EPIPE
    cmp     rax, -EPIPE
    je      .epipe_exit
    ; Print read error: "head: error reading 'FILE': ERROR\n"
    push    rax
    mov     rdi, STDERR
    lea     rsi, [rel err_reading_pre]
    mov     rdx, err_reading_pre_len
    call    asm_write_all
    mov     rdi, rbx
    call    str_len
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel err_reading_mid]
    mov     rdx, err_reading_mid_len
    call    asm_write_all
    pop     rax
    neg     rax
    call    print_errno
    mov     rdi, STDERR
    lea     rsi, [rel newline_str]
    mov     rdx, 1
    call    asm_write_all
    mov     byte [rel had_error], 1
    jmp     .file_next

.is_stdin_file:
    ; stdin — print header then process fd 0
    call    print_file_header
    test    rax, rax
    js      .write_error
    mov     byte [rel first_file], 0
    xor     edi, edi                    ; fd = 0 (stdin)
    call    process_fd
    test    rax, rax
    jns     .file_next
    cmp     rax, -EPIPE
    je      .epipe_exit
    ; Print read error for stdin
    push    rax
    mov     rdi, STDERR
    lea     rsi, [rel err_reading_pre]
    mov     rdx, err_reading_pre_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel stdin_name]
    mov     rdx, 14
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel err_reading_mid]
    mov     rdx, err_reading_mid_len
    call    asm_write_all
    pop     rax
    neg     rax
    call    print_errno
    mov     rdi, STDERR
    lea     rsi, [rel newline_str]
    mov     rdx, 1
    call    asm_write_all
    mov     byte [rel had_error], 1
    jmp     .file_next

.file_open_error:
    ; Print error to stderr: "head: cannot open 'FILE' for reading: ERROR\n"
    push    rax                         ; save errno
    mov     rdi, STDERR
    lea     rsi, [rel err_cannot_open_pre]
    mov     rdx, err_cannot_open_pre_len
    call    asm_write_all
    mov     rdi, rbx
    call    str_len
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel err_for_reading]
    mov     rdx, err_for_reading_len
    call    asm_write_all
    pop     rax
    neg     rax
    call    print_errno
    mov     rdi, STDERR
    lea     rsi, [rel newline_str]
    mov     rdx, 1
    call    asm_write_all
    mov     byte [rel had_error], 1
    jmp     .file_next

.file_next:
    inc     r12
    jmp     .file_loop

.done:
    ; Exit with appropriate code
    movzx   edi, byte [rel had_error]
    EXIT    rdi

.write_error:
    ; Check for EPIPE — exit 0 silently
    cmp     rax, -EPIPE
    je      .epipe_exit
    ; Other write error
    mov     byte [rel had_error], 1
    jmp     .done

.epipe_exit:
    EXIT    0

; ============================================================================
;  print_file_header — Print "==> filename <==" header if needed
;  Input: rbx = filename, first_file/show_headers globals
;  Output: rax = 0 on success, negative on error
; ============================================================================
print_file_header:
    cmp     byte [rel show_headers], 1
    jne     .pfh_ok

    ; If not first file, print blank line before header
    cmp     byte [rel first_file], 1
    je      .pfh_header
    mov     rdi, STDOUT
    lea     rsi, [rel newline_str]
    mov     rdx, 1
    call    asm_write_all
    test    rax, rax
    js      .pfh_ret

.pfh_header:
    ; Print "==> "
    mov     rdi, STDOUT
    lea     rsi, [rel header_prefix]
    mov     rdx, 4
    call    asm_write_all
    test    rax, rax
    js      .pfh_ret

    ; Print filename (or "standard input" for "-")
    mov     rdi, rbx
    lea     rsi, [rel dash_str]
    call    str_equal
    test    eax, eax
    jz      .pfh_filename
    mov     rdi, STDOUT
    lea     rsi, [rel stdin_name]
    mov     rdx, 14
    call    asm_write_all
    test    rax, rax
    js      .pfh_ret
    jmp     .pfh_suffix

.pfh_filename:
    mov     rdi, rbx
    call    str_len
    mov     rdx, rax
    mov     rdi, STDOUT
    mov     rsi, rbx
    call    asm_write_all
    test    rax, rax
    js      .pfh_ret

.pfh_suffix:
    mov     rdi, STDOUT
    lea     rsi, [rel header_suffix]
    mov     rdx, 5
    call    asm_write_all
    ret

.pfh_ok:
    xor     eax, eax
.pfh_ret:
    ret


; ============================================================================
;  process_fd — Process a single file descriptor
;  Input: rdi = fd (already opened)
;  Output: rax = 0 success, -EPIPE on broken pipe, -1 on other error
; ============================================================================
process_fd:
    push    r12
    push    r13

    mov     r12, rdi                    ; fd

    ; Dispatch based on mode
    mov     rax, [rel mode]
    cmp     rax, MODE_LINES
    je      .pfd_lines
    cmp     rax, MODE_BYTES
    je      .pfd_bytes
    cmp     rax, MODE_LINES_END
    je      .pfd_lines_end
    cmp     rax, MODE_BYTES_END
    je      .pfd_bytes_end
    jmp     .pfd_lines                  ; default

.pfd_lines:
    mov     rdi, r12
    mov     rsi, [rel count]
    call    head_lines
    jmp     .pfd_done

.pfd_bytes:
    mov     rdi, r12
    mov     rsi, [rel count]
    call    head_bytes
    jmp     .pfd_done

.pfd_lines_end:
    mov     rdi, r12
    mov     rsi, [rel count]
    call    head_lines_from_end
    jmp     .pfd_done

.pfd_bytes_end:
    mov     rdi, r12
    mov     rsi, [rel count]
    call    head_bytes_from_end

.pfd_done:
    pop     r13
    pop     r12
    ret


; ============================================================================
;  head_lines — Output first N lines from fd
;  Input: rdi = fd, rsi = n (line count)
;  Output: rax = 0 on success, -EPIPE on broken pipe, -1 on other error
; ============================================================================
head_lines:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, rdi                    ; fd
    mov     r13, rsi                    ; lines remaining
    test    r13, r13
    jz      .hl_done_ok

    ; Determine delimiter
    movzx   r15d, byte [rel zero_term]
    test    r15d, r15d
    jz      .hl_use_newline
    xor     r15d, r15d                  ; delimiter = 0 (NUL)
    jmp     .hl_read_loop
.hl_use_newline:
    mov     r15d, 10                    ; delimiter = '\n'

.hl_read_loop:
    ; Read a chunk
    mov     rdi, r12
    lea     rsi, [rel iobuf]
    mov     rdx, IOBUF_SIZE
    call    asm_read
    test    rax, rax
    jz      .hl_done_ok                 ; EOF
    js      .hl_read_error
    mov     r14, rax                    ; bytes_read

    ; Scan for delimiters in the chunk
    lea     rsi, [rel iobuf]            ; current position
    mov     rcx, r14                    ; remaining bytes in chunk

.hl_scan:
    test    rcx, rcx
    jz      .hl_write_chunk             ; no more bytes in chunk, write all

    ; Search for delimiter byte
    mov     rdi, rsi
    mov     al, r15b
    push    rcx
    repne   scasb                       ; scan for delimiter
    je      .hl_found_delim

    ; Not found in remaining bytes — write entire chunk
    pop     rcx                         ; restore original count (not needed but clean)
    jmp     .hl_write_chunk

.hl_found_delim:
    ; Found delimiter at rdi-1 (repne scasb advances past match)
    pop     rdx                         ; original rcx before repne
    ; Calculate bytes from current pos (rsi) to include delimiter
    mov     rax, rdi
    sub     rax, rsi                    ; bytes including delimiter

    dec     r13                         ; one more line done
    test    r13, r13
    jz      .hl_write_last              ; that was the last line

    ; Advance past this delimiter, continue scanning
    mov     rcx, rdx
    sub     rcx, rax                    ; remaining after delimiter
    mov     rsi, rdi                    ; advance past delimiter
    jmp     .hl_scan

.hl_write_last:
    ; Write from iobuf start up to (rdi - iobuf)
    mov     rdx, rdi
    lea     rsi, [rel iobuf]
    sub     rdx, rsi                    ; bytes to write
    mov     rdi, STDOUT
    call    asm_write_all
    test    rax, rax
    js      .hl_write_err
    jmp     .hl_done_ok

.hl_write_chunk:
    ; Write the entire chunk
    mov     rdi, STDOUT
    lea     rsi, [rel iobuf]
    mov     rdx, r14
    call    asm_write_all
    test    rax, rax
    js      .hl_write_err
    jmp     .hl_read_loop

.hl_done_ok:
    xor     eax, eax
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

.hl_read_error:
    ; rax already has the negative errno from asm_read
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

.hl_write_err:
    ; rax already has the error code
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret


; ============================================================================
;  head_bytes — Output first N bytes from fd
;  Input: rdi = fd, rsi = n (byte count)
;  Output: rax = 0 on success, negative on error
; ============================================================================
head_bytes:
    push    r12
    push    r13
    push    r14
    push    rbp

    mov     r12, rdi                    ; fd
    mov     r13, rsi                    ; bytes remaining
    test    r13, r13
    jz      .hb_done_ok

.hb_read_loop:
    ; Read min(remaining, IOBUF_SIZE)
    mov     rdx, IOBUF_SIZE
    cmp     r13, rdx
    cmovb   rdx, r13                    ; rdx = min(remaining, IOBUF_SIZE)
    mov     rdi, r12
    lea     rsi, [rel iobuf]
    call    asm_read
    test    rax, rax
    jz      .hb_done_ok                 ; EOF
    js      .hb_read_error
    mov     r14, rax                    ; bytes_read

    ; Clamp to remaining
    cmp     r14, r13
    cmova   r14, r13

    ; Write
    mov     rdi, STDOUT
    lea     rsi, [rel iobuf]
    mov     rdx, r14
    call    asm_write_all
    test    rax, rax
    js      .hb_write_err

    sub     r13, r14
    jz      .hb_done_ok
    jmp     .hb_read_loop

.hb_done_ok:
    xor     eax, eax
    pop     rbp
    pop     r14
    pop     r13
    pop     r12
    ret

.hb_read_error:
    ; rax already has the negative errno from asm_read
    pop     rbp
    pop     r14
    pop     r13
    pop     r12
    ret

.hb_write_err:
    pop     rbp
    pop     r14
    pop     r13
    pop     r12
    ret


; ============================================================================
;  read_all_dynamic — Read entire fd into a dynamically-growing buffer
;  Starts with frombuf (4MB BSS), grows via mmap if needed.
;  Input: rdi = fd
;  Output: rax = buf pointer, rdx = total bytes read, rcx = buf capacity
;          rax = negative errno on error
;  Caller must call free_dynamic_buf after use if buf != frombuf.
; ============================================================================
read_all_dynamic:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, rdi                    ; fd
    lea     r13, [rel frombuf]          ; current buffer pointer
    mov     r14, FROMBUF_SIZE           ; current capacity
    xor     r15d, r15d                  ; total bytes read

.rad_read_loop:
    mov     rdx, r14
    sub     rdx, r15
    jz      .rad_grow                   ; buffer full, need to grow
    mov     rdi, r12
    mov     rsi, r13
    add     rsi, r15
    call    asm_read
    test    rax, rax
    jz      .rad_done                   ; EOF
    js      .rad_error
    add     r15, rax
    jmp     .rad_read_loop

.rad_grow:
    ; Double the capacity via mmap
    mov     rbp, r14                    ; old capacity
    shl     r14, 1                      ; new capacity = 2x

    ; mmap(NULL, new_cap, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
    mov     rax, SYS_MMAP
    xor     edi, edi                    ; addr = NULL
    mov     rsi, r14                    ; length = new capacity
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1                      ; fd = -1
    xor     r9d, r9d                    ; offset = 0
    syscall
    test    rax, rax
    js      .rad_error                  ; mmap failed

    ; Copy old data to new buffer
    push    rax                         ; save new buffer ptr
    mov     rdi, rax                    ; dst = new buffer
    mov     rsi, r13                    ; src = old buffer
    mov     rcx, r15                    ; count = bytes read so far
    rep     movsb
    pop     rax

    ; Free old buffer if it was mmap'd (not the static frombuf)
    push    rax                         ; save new buffer ptr
    lea     rdx, [rel frombuf]
    cmp     r13, rdx
    je      .rad_skip_munmap
    ; munmap(old_buf, old_cap)
    mov     rdi, r13
    mov     rsi, rbp                    ; old capacity
    push    rax
    mov     rax, SYS_MUNMAP
    syscall
    pop     rax
.rad_skip_munmap:
    pop     r13                         ; r13 = new buffer pointer (was rax)
    jmp     .rad_read_loop

.rad_done:
    mov     rax, r13                    ; buffer pointer
    mov     rdx, r15                    ; total bytes
    mov     rcx, r14                    ; capacity
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

.rad_error:
    ; rax has the negative errno; clean up mmap'd buffer if needed
    push    rax
    lea     rdx, [rel frombuf]
    cmp     r13, rdx
    je      .rad_err_done
    mov     rdi, r13
    mov     rsi, r14
    mov     rax, SYS_MUNMAP
    syscall
.rad_err_done:
    pop     rax
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret


; ============================================================================
;  free_dynamic_buf — Free buffer if it was mmap'd (not frombuf)
;  Input: rdi = buf pointer, rsi = capacity
; ============================================================================
free_dynamic_buf:
    lea     rax, [rel frombuf]
    cmp     rdi, rax
    je      .fdb_noop
    ; munmap
    mov     rax, SYS_MUNMAP
    ; rdi = addr (already set), rsi = len (already set)
    syscall
.fdb_noop:
    ret


; ============================================================================
;  head_lines_from_end — Output all but last N lines from fd
;  Reads entire input via dynamic buffer, then scans backward
;  Input: rdi = fd, rsi = n
;  Output: rax = 0 on success, negative on error
; ============================================================================
head_lines_from_end:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, rdi                    ; fd
    mov     r13, rsi                    ; N lines to skip from end
    test    r13, r13
    jz      .hlfe_output_all            ; -n -0 means output everything

    ; Read entire input into dynamic buffer
    mov     rdi, r12
    call    read_all_dynamic
    test    rax, rax
    js      .hlfe_read_error            ; rax = negative errno
    mov     rbp, rax                    ; buf pointer
    mov     r14, rdx                    ; total bytes
    mov     r15, rcx                    ; buf capacity (for cleanup)

    ; r14 = total bytes in buffer
    test    r14, r14
    jz      .hlfe_done_ok_cleanup       ; empty input

    ; Determine delimiter
    movzx   ecx, byte [rel zero_term]
    test    cl, cl
    jz      .hlfe_delim_nl
    xor     ecx, ecx                    ; NUL
    jmp     .hlfe_scan_back
.hlfe_delim_nl:
    mov     cl, 10                      ; newline

.hlfe_scan_back:
    ; Scan backward from end, skip N delimiters
    mov     rsi, rbp                    ; buffer start
    mov     r12, r14                    ; working offset = total length
    xor     edx, edx                    ; delimiter count

    ; Check if last byte is the delimiter
    cmp     byte [rsi + r12 - 1], cl
    je      .hlfe_back_loop
    inc     edx                         ; trailing content counts as 1 line

.hlfe_back_loop:
    dec     r12
    js      .hlfe_nothing               ; went past beginning
    cmp     byte [rsi + r12], cl
    jne     .hlfe_back_loop
    inc     edx
    cmp     rdx, r13
    jbe     .hlfe_back_loop
    ; Found the (N+1)th delimiter from end; output up to and including it
    inc     r12
    mov     rdx, r12
    mov     rdi, STDOUT
    mov     rsi, rbp
    call    asm_write_all
    test    rax, rax
    js      .hlfe_write_err
    jmp     .hlfe_done_ok_cleanup

.hlfe_nothing:
    ; Fewer than N+1 delimiters → N >= total lines → output nothing
    jmp     .hlfe_done_ok_cleanup

.hlfe_output_all:
    ; -n -0: output entire file by streaming
    mov     rdi, r12
    mov     rsi, 0x7FFFFFFFFFFFFFFF     ; effectively unlimited
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    jmp     head_lines                  ; tail call

.hlfe_done_ok_cleanup:
    ; Free dynamic buffer if needed
    mov     rdi, rbp
    mov     rsi, r15
    call    free_dynamic_buf
    xor     eax, eax
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

.hlfe_read_error:
    ; rax already has the negative errno
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

.hlfe_write_err:
    ; Free dynamic buffer then return error
    push    rax
    mov     rdi, rbp
    mov     rsi, r15
    call    free_dynamic_buf
    pop     rax
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret


; ============================================================================
;  head_bytes_from_end — Output all but last N bytes from fd
;  Reads entire input via dynamic buffer, outputs data[:len-N]
;  Input: rdi = fd, rsi = n
;  Output: rax = 0 on success, negative on error
; ============================================================================
head_bytes_from_end:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, rdi                    ; fd
    mov     r13, rsi                    ; N bytes to skip from end
    test    r13, r13
    jz      .hbfe_output_all            ; -c -0 means output everything

    ; Read entire input into dynamic buffer
    mov     rdi, r12
    call    read_all_dynamic
    test    rax, rax
    js      .hbfe_read_error            ; rax = negative errno
    mov     rbp, rax                    ; buf pointer
    mov     r14, rdx                    ; total bytes
    mov     r15, rcx                    ; buf capacity (for cleanup)

    ; Output data[0..len-N]
    mov     rax, r14
    sub     rax, r13
    jle     .hbfe_done_ok_cleanup       ; N >= len, output nothing
    mov     rdx, rax                    ; bytes to write
    mov     rdi, STDOUT
    mov     rsi, rbp
    call    asm_write_all
    test    rax, rax
    js      .hbfe_write_err
    jmp     .hbfe_done_ok_cleanup

.hbfe_output_all:
    ; -c -0: output everything by streaming
    mov     rdi, r12
    mov     rsi, 0x7FFFFFFFFFFFFFFF
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    jmp     head_bytes                  ; tail call

.hbfe_done_ok_cleanup:
    mov     rdi, rbp
    mov     rsi, r15
    call    free_dynamic_buf
    xor     eax, eax
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

.hbfe_read_error:
    ; rax already has the negative errno
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

.hbfe_write_err:
    push    rax
    mov     rdi, rbp
    mov     rsi, r15
    call    free_dynamic_buf
    pop     rax
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret


; ============================================================================
;  parse_args — Parse command-line arguments
;  Reads from [argc]/[argv] globals, sets mode/count/quiet/verbose/zero_term/files/nfiles
; ============================================================================
parse_args:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbx
    push    rbp

    mov     r12, [rel argv]             ; argv base
    mov     r13, [rel argc]             ; argc
    mov     r14, 1                      ; current arg index (skip argv[0])

.pa_loop:
    cmp     r14, r13
    jge     .pa_done

    mov     rbx, [r12 + r14*8]         ; current arg string

    ; Check for "--"
    cmp     word [rbx], 0x2D2D         ; "--"
    jne     .pa_not_dashdash
    cmp     byte [rbx+2], 0
    jne     .pa_not_dashdash
    ; It's "--" — all remaining args are filenames
    inc     r14
.pa_dashdash_loop:
    cmp     r14, r13
    jge     .pa_done
    mov     rax, [r12 + r14*8]
    lea     rcx, [rel files]
    mov     rdx, [rel nfiles]
    mov     [rcx + rdx*8], rax
    inc     qword [rel nfiles]
    inc     r14
    jmp     .pa_dashdash_loop

.pa_not_dashdash:
    ; Check for long options (--xxx)
    cmp     byte [rbx], '-'
    jne     .pa_file
    cmp     byte [rbx+1], 0
    je      .pa_file                    ; "-" alone is a filename
    cmp     byte [rbx+1], '-'
    je      .pa_long_opt

    ; Short option(s): -n, -c, -q, -v, -z, or -NUM (legacy)
    lea     rsi, [rbx + 1]             ; skip leading '-'
.pa_short_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .pa_next

    cmp     al, 'n'
    je      .pa_short_n
    cmp     al, 'c'
    je      .pa_short_c
    cmp     al, 'q'
    je      .pa_short_q
    cmp     al, 'v'
    je      .pa_short_v
    cmp     al, 'z'
    je      .pa_short_z
    ; Check for digit (legacy -NUM)
    cmp     al, '0'
    jb      .pa_invalid_short
    cmp     al, '9'
    ja      .pa_invalid_short

    ; Legacy: -NUM
    mov     rdi, rsi                    ; parse from current pos
    mov     [rel parse_val_ptr], rdi    ; save for error messages
    call    parse_number_with_suffix
    test    rax, rax
    js      .pa_invalid_lines_num
    mov     [rel count], rax
    mov     qword [rel mode], MODE_LINES
    jmp     .pa_next

.pa_short_n:
    inc     rsi
    cmp     byte [rsi], 0
    jne     .pa_short_n_inline
    ; Value is next arg
    inc     r14
    cmp     r14, r13
    jge     .pa_missing_arg_n
    mov     rdi, [r12 + r14*8]
    jmp     .pa_parse_lines_val

.pa_short_n_inline:
    mov     rdi, rsi                    ; rest of current arg is the value
.pa_parse_lines_val:
    ; Check for leading '-'
    cmp     byte [rdi], '-'
    jne     .pa_lines_check_plus
    inc     rdi
    mov     [rel parse_val_ptr], rdi    ; save value (after '-') for error messages
    call    parse_number_with_suffix
    test    rax, rax
    js      .pa_invalid_lines
    mov     [rel count], rax
    mov     qword [rel mode], MODE_LINES_END
    jmp     .pa_next

.pa_lines_check_plus:
    ; Check for leading '+' (GNU treats +N same as N)
    cmp     byte [rdi], '+'
    jne     .pa_lines_positive
    inc     rdi
.pa_lines_positive:
    mov     [rel parse_val_ptr], rdi    ; save value for error messages
    call    parse_number_with_suffix
    test    rax, rax
    js      .pa_invalid_lines
    mov     [rel count], rax
    mov     qword [rel mode], MODE_LINES
    jmp     .pa_next

.pa_short_c:
    inc     rsi
    cmp     byte [rsi], 0
    jne     .pa_short_c_inline
    inc     r14
    cmp     r14, r13
    jge     .pa_missing_arg_c
    mov     rdi, [r12 + r14*8]
    jmp     .pa_parse_bytes_val

.pa_short_c_inline:
    mov     rdi, rsi
.pa_parse_bytes_val:
    cmp     byte [rdi], '-'
    jne     .pa_bytes_check_plus
    inc     rdi
    mov     [rel parse_val_ptr], rdi    ; save value (after '-') for error messages
    call    parse_number_with_suffix
    test    rax, rax
    js      .pa_invalid_bytes
    mov     [rel count], rax
    mov     qword [rel mode], MODE_BYTES_END
    jmp     .pa_next

.pa_bytes_check_plus:
    ; Check for leading '+' (GNU treats +N same as N)
    cmp     byte [rdi], '+'
    jne     .pa_bytes_positive
    inc     rdi
.pa_bytes_positive:
    mov     [rel parse_val_ptr], rdi    ; save value for error messages
    call    parse_number_with_suffix
    test    rax, rax
    js      .pa_invalid_bytes
    mov     [rel count], rax
    mov     qword [rel mode], MODE_BYTES
    jmp     .pa_next

.pa_short_q:
    mov     byte [rel quiet], 1
    inc     rsi
    jmp     .pa_short_loop

.pa_short_v:
    mov     byte [rel verbose], 1
    inc     rsi
    jmp     .pa_short_loop

.pa_short_z:
    mov     byte [rel zero_term], 1
    inc     rsi
    jmp     .pa_short_loop

.pa_long_opt:
    ; Long options: --lines=, --bytes=, --lines, --bytes, --quiet, --silent, --verbose, --zero-terminated, --help, --version
    lea     rdi, [rbx + 2]             ; skip "--"

    ; --help
    lea     rsi, [rel str_help]
    call    str_equal
    test    eax, eax
    jnz     .pa_help

    ; --version
    lea     rsi, [rel str_version]
    call    str_equal
    test    eax, eax
    jnz     .pa_version

    ; --quiet
    lea     rdi, [rbx + 2]
    lea     rsi, [rel str_quiet]
    call    str_equal
    test    eax, eax
    jnz     .pa_long_quiet

    ; --silent
    lea     rdi, [rbx + 2]
    lea     rsi, [rel str_silent]
    call    str_equal
    test    eax, eax
    jnz     .pa_long_quiet

    ; --verbose
    lea     rdi, [rbx + 2]
    lea     rsi, [rel str_verbose]
    call    str_equal
    test    eax, eax
    jnz     .pa_long_verbose

    ; --zero-terminated
    lea     rdi, [rbx + 2]
    lea     rsi, [rel str_zerot]
    call    str_equal
    test    eax, eax
    jnz     .pa_long_zerot

    ; --lines=VALUE
    lea     rdi, [rbx + 2]
    lea     rsi, [rel str_lines_eq]
    mov     rdx, 6                      ; len("lines=")
    call    str_prefix
    test    eax, eax
    jnz     .pa_long_lines_eq

    ; --bytes=VALUE
    lea     rdi, [rbx + 2]
    lea     rsi, [rel str_bytes_eq]
    mov     rdx, 6                      ; len("bytes=")
    call    str_prefix
    test    eax, eax
    jnz     .pa_long_bytes_eq

    ; --lines (next arg is value)
    lea     rdi, [rbx + 2]
    lea     rsi, [rel str_lines]
    call    str_equal
    test    eax, eax
    jnz     .pa_long_lines

    ; --bytes (next arg is value)
    lea     rdi, [rbx + 2]
    lea     rsi, [rel str_bytes]
    call    str_equal
    test    eax, eax
    jnz     .pa_long_bytes

    ; Unrecognized long option
    jmp     .pa_unrec_long

.pa_long_quiet:
    mov     byte [rel quiet], 1
    jmp     .pa_next

.pa_long_verbose:
    mov     byte [rel verbose], 1
    jmp     .pa_next

.pa_long_zerot:
    mov     byte [rel zero_term], 1
    jmp     .pa_next

.pa_long_lines_eq:
    lea     rdi, [rbx + 8]             ; "--lines=" is 8 chars
    jmp     .pa_parse_lines_val

.pa_long_bytes_eq:
    lea     rdi, [rbx + 8]             ; "--bytes=" is 8 chars
    jmp     .pa_parse_bytes_val

.pa_long_lines:
    inc     r14
    cmp     r14, r13
    jge     .pa_missing_arg_long_lines
    mov     rdi, [r12 + r14*8]
    jmp     .pa_parse_lines_val

.pa_long_bytes:
    inc     r14
    cmp     r14, r13
    jge     .pa_missing_arg_long_bytes
    mov     rdi, [r12 + r14*8]
    jmp     .pa_parse_bytes_val

.pa_help:
    call    print_help
    EXIT    0

.pa_version:
    call    print_version
    EXIT    0

.pa_file:
    ; Add to files list
    lea     rcx, [rel files]
    mov     rdx, [rel nfiles]
    mov     [rcx + rdx*8], rbx
    inc     qword [rel nfiles]

.pa_next:
    inc     r14
    jmp     .pa_loop

.pa_done:
    pop     rbp
    pop     rbx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

; ── Error handlers for parse_args ──

.pa_invalid_short:
    ; "head: invalid option -- 'X'\nTry 'head --help' for more information.\n"
    mov     r15b, al                    ; save char
    mov     rdi, STDERR
    lea     rsi, [rel err_invalid_opt_pre]
    mov     rdx, err_invalid_opt_pre_len
    call    asm_write_all
    ; Write the char
    push    r15
    mov     rdi, STDERR
    mov     rsi, rsp
    mov     rdx, 1
    call    asm_write_all
    pop     r15
    ; Write suffix
    mov     rdi, STDERR
    lea     rsi, [rel err_opt_suffix]
    mov     rdx, err_opt_suffix_len
    call    asm_write_all
    EXIT    1

.pa_unrec_long:
    ; "head: unrecognized option 'XXXX'\nTry ..."
    mov     rdi, STDERR
    lea     rsi, [rel err_unrec_pre]
    mov     rdx, err_unrec_pre_len
    call    asm_write_all
    ; Write the option string
    mov     rdi, rbx
    call    str_len
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    ; Write suffix
    mov     rdi, STDERR
    lea     rsi, [rel err_opt_suffix]
    mov     rdx, err_opt_suffix_len
    call    asm_write_all
    EXIT    1

.pa_missing_arg_n:
    mov     rdi, STDERR
    lea     rsi, [rel err_missing_n]
    mov     rdx, err_missing_n_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel err_try_help]
    mov     rdx, err_try_help_len
    call    asm_write_all
    EXIT    1

.pa_missing_arg_c:
    mov     rdi, STDERR
    lea     rsi, [rel err_missing_c]
    mov     rdx, err_missing_c_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel err_try_help]
    mov     rdx, err_try_help_len
    call    asm_write_all
    EXIT    1

.pa_missing_arg_long_lines:
    mov     rdi, STDERR
    lea     rsi, [rel err_missing_long_lines]
    mov     rdx, err_missing_long_lines_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel err_try_help]
    mov     rdx, err_try_help_len
    call    asm_write_all
    EXIT    1

.pa_missing_arg_long_bytes:
    mov     rdi, STDERR
    lea     rsi, [rel err_missing_long_bytes]
    mov     rdx, err_missing_long_bytes_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel err_try_help]
    mov     rdx, err_try_help_len
    call    asm_write_all
    EXIT    1

.pa_invalid_lines:
    ; Save the original argument for error message
    ; "head: invalid number of lines: 'VALUE'\n"
    ; We need the original value including the potential leading '-'
    ; The rdi we passed to parse was already past the '-', but the error
    ; needs the full value. We'll use rbx or reconstruct.
    mov     rdi, STDERR
    lea     rsi, [rel err_invalid_lines_pre]
    mov     rdx, err_invalid_lines_pre_len
    call    asm_write_all
    jmp     .pa_invalid_num_finish

.pa_invalid_lines_num:
    ; Same as above but for legacy -NUM format
    mov     rdi, STDERR
    lea     rsi, [rel err_invalid_lines_pre]
    mov     rdx, err_invalid_lines_pre_len
    call    asm_write_all
    jmp     .pa_invalid_num_finish

.pa_invalid_bytes:
    mov     rdi, STDERR
    lea     rsi, [rel err_invalid_bytes_pre]
    mov     rdx, err_invalid_bytes_pre_len
    call    asm_write_all

.pa_invalid_num_finish:
    ; Print the problematic value from parse_val_ptr
    mov     rdi, [rel parse_val_ptr]
    call    str_len
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, [rel parse_val_ptr]
    call    asm_write_all
    ; Print closing "'\n"
    mov     rdi, STDERR
    lea     rsi, [rel err_quote_nl]
    mov     rdx, 2                      ; "'\n"
    call    asm_write_all
    EXIT    1


; ============================================================================
;  parse_number_with_suffix — Parse "123", "5K", "2M", etc.
;  Input: rdi = string pointer
;  Output: rax = parsed number (>= 0), or -1 on error
; ============================================================================
parse_number_with_suffix:
    push    rbx
    push    rcx
    push    rdx

    mov     rsi, rdi
    xor     rax, rax                    ; accumulator
    xor     ecx, ecx                    ; digit count

.pns_digit:
    movzx   edx, byte [rsi]
    sub     dl, '0'
    cmp     dl, 9
    ja      .pns_suffix                 ; not a digit
    ; acc = acc * 10 + digit (with overflow check)
    imul    rax, 10
    jo      .pns_error                  ; overflow
    movzx   edx, byte [rsi]
    sub     edx, '0'
    add     rax, rdx
    jo      .pns_error                  ; overflow
    js      .pns_error                  ; wrapped negative
    inc     rsi
    inc     ecx
    jmp     .pns_digit

.pns_suffix:
    test    ecx, ecx
    jz      .pns_error                  ; no digits at all

    ; Check suffix
    movzx   edx, byte [rsi]
    test    dl, dl
    jz      .pns_done                   ; no suffix

    mov     rbx, rax                    ; save number

    cmp     dl, 'b'
    je      .pns_b
    cmp     dl, 'K'
    je      .pns_K
    cmp     dl, 'M'
    je      .pns_M
    cmp     dl, 'G'
    je      .pns_G
    cmp     dl, 'T'
    je      .pns_T
    cmp     dl, 'P'
    je      .pns_P
    cmp     dl, 'E'
    je      .pns_E
    cmp     dl, 'k'
    je      .pns_k_lower
    ; Unknown suffix
    jmp     .pns_error

.pns_b:
    cmp     byte [rsi+1], 0
    jne     .pns_error
    imul    rax, rbx, 512
    jmp     .pns_done

.pns_K:
    cmp     byte [rsi+1], 0
    je      .pns_K_1024
    cmp     byte [rsi+1], 'i'
    je      .pns_K_check_iB
    jmp     .pns_error
.pns_K_1024:
    imul    rax, rbx, 1024
    jmp     .pns_done
.pns_K_check_iB:
    cmp     byte [rsi+2], 'B'
    jne     .pns_error
    cmp     byte [rsi+3], 0
    jne     .pns_error
    imul    rax, rbx, 1024
    jmp     .pns_done

.pns_k_lower:
    ; kB = 1000
    cmp     byte [rsi+1], 'B'
    jne     .pns_error
    cmp     byte [rsi+2], 0
    jne     .pns_error
    imul    rax, rbx, 1000
    jmp     .pns_done

.pns_M:
    cmp     byte [rsi+1], 0
    je      .pns_M_1048576
    cmp     byte [rsi+1], 'B'
    je      .pns_MB
    cmp     byte [rsi+1], 'i'
    je      .pns_M_check_iB
    jmp     .pns_error
.pns_M_1048576:
    imul    rax, rbx, 1048576
    jmp     .pns_done
.pns_MB:
    cmp     byte [rsi+2], 0
    jne     .pns_error
    imul    rax, rbx, 1000000
    jmp     .pns_done
.pns_M_check_iB:
    cmp     byte [rsi+2], 'B'
    jne     .pns_error
    cmp     byte [rsi+3], 0
    jne     .pns_error
    imul    rax, rbx, 1048576
    jmp     .pns_done

.pns_G:
    cmp     byte [rsi+1], 0
    je      .pns_G_1073741824
    cmp     byte [rsi+1], 'B'
    je      .pns_GB
    cmp     byte [rsi+1], 'i'
    je      .pns_G_check_iB
    jmp     .pns_error
.pns_G_1073741824:
    imul    rax, rbx, 1073741824
    jmp     .pns_done
.pns_GB:
    cmp     byte [rsi+2], 0
    jne     .pns_error
    imul    rax, rbx, 1000000000
    jmp     .pns_done
.pns_G_check_iB:
    cmp     byte [rsi+2], 'B'
    jne     .pns_error
    cmp     byte [rsi+3], 0
    jne     .pns_error
    imul    rax, rbx, 1073741824
    jmp     .pns_done

.pns_T:
    cmp     byte [rsi+1], 0
    je      .pns_T_binary
    cmp     byte [rsi+1], 'B'
    je      .pns_TB
    cmp     byte [rsi+1], 'i'
    je      .pns_T_check_iB
    jmp     .pns_error
.pns_T_binary:
    mov     rax, 1099511627776
    imul    rax, rbx
    jmp     .pns_done
.pns_TB:
    cmp     byte [rsi+2], 0
    jne     .pns_error
    mov     rax, 1000000000000
    imul    rax, rbx
    jmp     .pns_done
.pns_T_check_iB:
    cmp     byte [rsi+2], 'B'
    jne     .pns_error
    cmp     byte [rsi+3], 0
    jne     .pns_error
    mov     rax, 1099511627776
    imul    rax, rbx
    jmp     .pns_done

.pns_P:
    cmp     byte [rsi+1], 0
    je      .pns_P_binary
    cmp     byte [rsi+1], 'B'
    je      .pns_PB
    cmp     byte [rsi+1], 'i'
    je      .pns_P_check_iB
    jmp     .pns_error
.pns_P_binary:
    mov     rax, 1125899906842624
    imul    rax, rbx
    jmp     .pns_done
.pns_PB:
    cmp     byte [rsi+2], 0
    jne     .pns_error
    mov     rax, 1000000000000000
    imul    rax, rbx
    jmp     .pns_done
.pns_P_check_iB:
    cmp     byte [rsi+2], 'B'
    jne     .pns_error
    cmp     byte [rsi+3], 0
    jne     .pns_error
    mov     rax, 1125899906842624
    imul    rax, rbx
    jmp     .pns_done

.pns_E:
    cmp     byte [rsi+1], 0
    je      .pns_E_binary
    cmp     byte [rsi+1], 'B'
    je      .pns_EB
    cmp     byte [rsi+1], 'i'
    je      .pns_E_check_iB
    jmp     .pns_error
.pns_E_binary:
    mov     rax, 1152921504606846976
    imul    rax, rbx
    jmp     .pns_done
.pns_EB:
    cmp     byte [rsi+2], 0
    jne     .pns_error
    mov     rax, 1000000000000000000
    imul    rax, rbx
    jmp     .pns_done
.pns_E_check_iB:
    cmp     byte [rsi+2], 'B'
    jne     .pns_error
    cmp     byte [rsi+3], 0
    jne     .pns_error
    mov     rax, 1152921504606846976
    imul    rax, rbx
    jmp     .pns_done

.pns_done:
    pop     rdx
    pop     rcx
    pop     rbx
    ret

.pns_error:
    mov     rax, -1
    pop     rdx
    pop     rcx
    pop     rbx
    ret


; ============================================================================
;  Utility functions
; ============================================================================

; str_len(rdi) -> rax = length
str_len:
    push    rcx
    push    rdi
    xor     rcx, rcx
    dec     rcx                         ; rcx = -1 (max count)
    xor     al, al
    repne   scasb
    not     rcx
    dec     rcx
    mov     rax, rcx
    pop     rdi
    pop     rcx
    ret

; str_equal(rdi, rsi) -> eax = 1 if equal, 0 if not
str_equal:
    push    rdi
    push    rsi
.se_loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .se_not_equal
    test    al, al
    jz      .se_equal
    inc     rdi
    inc     rsi
    jmp     .se_loop
.se_equal:
    mov     eax, 1
    pop     rsi
    pop     rdi
    ret
.se_not_equal:
    xor     eax, eax
    pop     rsi
    pop     rdi
    ret

; str_prefix(rdi=str, rsi=prefix, rdx=prefix_len) -> eax = 1 if str starts with prefix
str_prefix:
    push    rdi
    push    rsi
    push    rcx
    mov     rcx, rdx
.sp_loop:
    test    rcx, rcx
    jz      .sp_match
    movzx   eax, byte [rdi]
    cmp     al, [rsi]
    jne     .sp_no
    inc     rdi
    inc     rsi
    dec     rcx
    jmp     .sp_loop
.sp_match:
    mov     eax, 1
    pop     rcx
    pop     rsi
    pop     rdi
    ret
.sp_no:
    xor     eax, eax
    pop     rcx
    pop     rsi
    pop     rdi
    ret

; print_errno(eax = errno number) — prints human-readable error to stderr
print_errno:
    cmp     eax, 2
    je      .pe_noent
    cmp     eax, 13
    je      .pe_perm
    cmp     eax, 21
    je      .pe_isdir
    cmp     eax, 20
    je      .pe_notdir
    ; Default: "Input/output error"
    mov     rdi, STDERR
    lea     rsi, [rel err_io]
    mov     rdx, err_io_len
    jmp     asm_write_all
.pe_noent:
    mov     rdi, STDERR
    lea     rsi, [rel err_noent]
    mov     rdx, err_noent_len
    jmp     asm_write_all
.pe_perm:
    mov     rdi, STDERR
    lea     rsi, [rel err_perm]
    mov     rdx, err_perm_len
    jmp     asm_write_all
.pe_isdir:
    mov     rdi, STDERR
    lea     rsi, [rel err_isdir]
    mov     rdx, err_isdir_len
    jmp     asm_write_all
.pe_notdir:
    mov     rdi, STDERR
    lea     rsi, [rel err_notdir]
    mov     rdx, err_notdir_len
    jmp     asm_write_all

; print_help — print help text to stdout
print_help:
    mov     rdi, STDOUT
    lea     rsi, [rel help_text]
    mov     rdx, help_text_len
    jmp     asm_write_all

; print_version — print version text to stdout
print_version:
    mov     rdi, STDOUT
    lea     rsi, [rel version_text]
    mov     rdx, version_text_len
    jmp     asm_write_all


; ============================================================================
;                        DATA SECTION
; ============================================================================
section .data

dash_str:       db "-", 0
newline_str:    db 10
header_prefix:  db "==> "
header_suffix:  db " <==", 10
stdin_name:     db "standard input"

; Option strings for comparison
str_help:       db "help", 0
str_version:    db "version", 0
str_quiet:      db "quiet", 0
str_silent:     db "silent", 0
str_verbose:    db "verbose", 0
str_zerot:      db "zero-terminated", 0
str_lines_eq:   db "lines="
str_bytes_eq:   db "bytes="
str_lines:      db "lines", 0
str_bytes:      db "bytes", 0

; Help text (matching GNU format closely but branded as fhead)
help_text:
    db "Usage: head [OPTION]... [FILE]...", 10
    db "Print the first 10 lines of each FILE to standard output.", 10
    db "With more than one FILE, precede each with a header giving the file name.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -c, --bytes=[-]NUM       print the first NUM bytes of each file;", 10
    db "                             with the leading '-', print all but the last", 10
    db "                             NUM bytes of each file", 10
    db "  -n, --lines=[-]NUM       print the first NUM lines instead of the first 10;", 10
    db "                             with the leading '-', print all but the last", 10
    db "                             NUM lines of each file", 10
    db "  -q, --quiet, --silent    never print headers giving file names", 10
    db "  -v, --verbose            always print headers giving file names", 10
    db "  -z, --zero-terminated    line delimiter is NUL, not newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "NUM may have a multiplier suffix:", 10
    db "b 512, kB 1000, K 1024, MB 1000*1000, M 1024*1024,", 10
    db "GB 1000*1000*1000, G 1024*1024*1024, and so on for T, P, E, Z, Y, R, Q.", 10
    db "Binary prefixes can be used, too: KiB=K, MiB=M, and so on.", 10
help_text_len equ $ - help_text

version_text:
    db "head (fhead) 0.1.0", 10
version_text_len equ $ - version_text

; Error message fragments
err_reading_pre:
    db "head: error reading '"
err_reading_pre_len equ $ - err_reading_pre

err_reading_mid:
    db "': "
err_reading_mid_len equ $ - err_reading_mid

err_cannot_open_pre:
    db "head: cannot open '",
err_cannot_open_pre_len equ $ - err_cannot_open_pre

err_for_reading:
    db "' for reading: "
err_for_reading_len equ $ - err_for_reading

err_invalid_opt_pre:
    db "head: invalid option -- '"
err_invalid_opt_pre_len equ $ - err_invalid_opt_pre

err_unrec_pre:
    db "head: unrecognized option '"
err_unrec_pre_len equ $ - err_unrec_pre

err_opt_suffix:
    db "'", 10
    db "Try 'head --help' for more information.", 10
err_opt_suffix_len equ $ - err_opt_suffix

err_try_help:
    db "Try 'head --help' for more information.", 10
err_try_help_len equ $ - err_try_help

err_missing_n:
    db "head: option requires an argument -- 'n'", 10
err_missing_n_len equ $ - err_missing_n

err_missing_c:
    db "head: option requires an argument -- 'c'", 10
err_missing_c_len equ $ - err_missing_c

err_missing_long_lines:
    db "head: option '--lines' requires an argument", 10
err_missing_long_lines_len equ $ - err_missing_long_lines

err_missing_long_bytes:
    db "head: option '--bytes' requires an argument", 10
err_missing_long_bytes_len equ $ - err_missing_long_bytes

err_invalid_lines_pre:
    db "head: invalid number of lines: '"
err_invalid_lines_pre_len equ $ - err_invalid_lines_pre

err_invalid_bytes_pre:
    db "head: invalid number of bytes: '"
err_invalid_bytes_pre_len equ $ - err_invalid_bytes_pre

err_quote_nl:
    db "'", 10

; Errno messages
err_noent:      db "No such file or directory"
err_noent_len equ $ - err_noent

err_perm:       db "Permission denied"
err_perm_len equ $ - err_perm

err_isdir:      db "Is a directory"
err_isdir_len equ $ - err_isdir

err_notdir:     db "Not a directory"
err_notdir_len equ $ - err_notdir

err_io:         db "Input/output error"
err_io_len equ $ - err_io

; ============================================================================
;                        BSS SECTION
; ============================================================================
section .bss

argc:           resq    1
argv:           resq    1
mode:           resq    1
count:          resq    1
quiet:          resb    1
verbose:        resb    1
zero_term:      resb    1
show_headers:   resb    1
had_error:      resb    1
first_file:     resb    1
nfiles:         resq    1
cur_fd:         resq    1
parse_val_ptr:  resq    1               ; saved pointer for error messages
files:          resq    256             ; max 256 file arguments

iobuf:          resb    IOBUF_SIZE      ; 64KB I/O buffer
frombuf:        resb    FROMBUF_SIZE    ; 4MB buffer for "from end" modes

section .note.GNU-stack noalloc noexec nowrite progbits
