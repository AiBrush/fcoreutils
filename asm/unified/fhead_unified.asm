; ============================================================================
;  fhead_unified.asm — Unified single-file "head" binary (auto-merged)
;
;  This file was created by merging:
;    - asm/tools/fhead.asm       (main head implementation)
;    - asm/lib/io.asm            (shared I/O routines)
;    - asm/include/linux.inc     (syscall constants, inlined)
;    - asm/include/macros.inc    (macros, expanded inline)
;
;  It produces a single static ELF binary via:
;    nasm -f bin fhead_unified.asm -o fhead && chmod +x fhead
;
;  Hand-crafted ELF64 header, no linker, no libc, no dynamic dependencies.
;  Three program headers: code+data (RX), BSS (RW), GNU_STACK (NX).
; ============================================================================

BITS 64
org 0x400000

; ── Inlined constants from linux.inc ─────────────────────────────────────────
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_RT_SIGPROCMASK  14
%define SYS_EXIT            60

%define STDIN               0
%define STDOUT              1
%define STDERR              2

%define O_RDONLY            0

%define EINTR               4
%define EPIPE               32

; ── fhead-specific constants ─────────────────────────────────────────────────
%define IOBUF_SIZE          65536               ; 64KB I/O buffer
%define FROMBUF_SIZE        (4 * 1024 * 1024)   ; 4MB buffer for "from end" modes

; Mode constants
%define MODE_LINES          0                   ; -n N (default)
%define MODE_BYTES          1                   ; -c N
%define MODE_LINES_END      2                   ; -n -N
%define MODE_BYTES_END      3                   ; -c -N

; ── BSS Layout (absolute addresses at 0x500000) ─────────────────────────────
;
; All BSS variables are at fixed absolute addresses in the RW segment.
; The kernel zero-fills this memory on exec (PT_LOAD with filesz=0).
;
;  Offset  Size   Name
;  ------  ----   ----
;  0x0000     8   argc
;  0x0008     8   argv
;  0x0010     8   mode
;  0x0018     8   count
;  0x0020     1   quiet
;  0x0021     1   verbose
;  0x0022     1   zero_term
;  0x0023     1   show_headers
;  0x0024     1   had_error
;  0x0025     1   first_file
;  0x0026     2   (padding to align nfiles)
;  0x0028     8   nfiles
;  0x0030     8   cur_fd
;  0x0038  2048   files (256 * 8)
;  0x0838 65536   iobuf (64KB)
; 0x10838  4MB    frombuf (4194304 bytes)
; 0x410838        end of BSS
;
; Total BSS size = 0x410838 = 4261944 bytes

%define BSS_BASE        0x500000

%define argc            (BSS_BASE + 0x0000)
%define argv            (BSS_BASE + 0x0008)
%define mode            (BSS_BASE + 0x0010)
%define count           (BSS_BASE + 0x0018)
%define quiet           (BSS_BASE + 0x0020)
%define verbose         (BSS_BASE + 0x0021)
%define zero_term       (BSS_BASE + 0x0022)
%define show_headers    (BSS_BASE + 0x0023)
%define had_error       (BSS_BASE + 0x0024)
%define first_file      (BSS_BASE + 0x0025)
%define nfiles          (BSS_BASE + 0x0028)
%define cur_fd          (BSS_BASE + 0x0030)
%define files           (BSS_BASE + 0x0038)
%define iobuf           (BSS_BASE + 0x0838)
%define frombuf         (BSS_BASE + 0x10838)

%define bss_size        (0x0038 + 256*8 + IOBUF_SIZE + FROMBUF_SIZE)
; bss_size = 0x38 + 2048 + 65536 + 4194304 = 4261944

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
    ; --- Segment 1: Code + Data (loaded from file, RX) ---
    dd      1                       ; p_type:  PT_LOAD
    dd      5                       ; p_flags: PF_R(4) | PF_X(1) = read+execute
    dq      0                       ; p_offset: start of file
    dq      0x400000                ; p_vaddr:  virtual address
    dq      0x400000                ; p_paddr:  physical address (same)
    dq      file_size               ; p_filesz: entire file
    dq      file_size               ; p_memsz:  same as filesz
    dq      0x1000                  ; p_align:  page-aligned (4KB)
phdr_size equ $ - phdr              ; Size of one program header entry (56 bytes)

    ; --- Segment 2: BSS (runtime buffers, zero-initialized, RW) ---
    dd      1                       ; p_type:  PT_LOAD
    dd      6                       ; p_flags: PF_R(4) | PF_W(2) = read+write
    dq      0                       ; p_offset: 0 (no file content)
    dq      BSS_BASE                ; p_vaddr:  buffer base address
    dq      BSS_BASE                ; p_paddr:  same
    dq      0                       ; p_filesz: 0 (nothing loaded from file)
    dq      bss_size                ; p_memsz:  total BSS space
    dq      0x1000                  ; p_align:  page-aligned

    ; --- Segment 3: GNU Stack (marks stack as non-executable) ---
    dd      0x6474E551              ; p_type:  PT_GNU_STACK
    dd      6                       ; p_flags: PF_R(4) | PF_W(2) = NX stack
    dq      0, 0, 0, 0, 0          ; p_offset, p_vaddr, p_paddr, p_filesz, p_memsz: unused
    dq      0x10                    ; p_align:  16-byte alignment


; ############################################################################
;                           CODE SECTION
; ############################################################################

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
    mov     rax, [rsp]                  ; argc
    mov     [argc], rax
    lea     rax, [rsp + 8]
    mov     [argv], rax

    ; ── Initialize defaults ──
    mov     qword [mode], MODE_LINES
    mov     qword [count], 10           ; default: 10 lines
    mov     byte [quiet], 0
    mov     byte [verbose], 0
    mov     byte [zero_term], 0
    mov     qword [nfiles], 0

    ; ── Parse arguments ──
    call    parse_args

    ; ── If no files, use stdin ──
    cmp     qword [nfiles], 0
    jne     .have_files
    ; Set files[0] = dash_str ("-")
    mov     rax, dash_str
    mov     [files], rax
    mov     qword [nfiles], 1

.have_files:
    ; ── Determine whether to show headers ──
    ; quiet => never, verbose => always, else => nfiles > 1
    cmp     byte [quiet], 1
    je      .no_headers
    cmp     byte [verbose], 1
    je      .yes_headers
    cmp     qword [nfiles], 1
    jg      .yes_headers
.no_headers:
    mov     byte [show_headers], 0
    jmp     .process_files
.yes_headers:
    mov     byte [show_headers], 1

.process_files:
    mov     byte [had_error], 0
    mov     byte [first_file], 1
    xor     r12d, r12d                  ; file index

.file_loop:
    cmp     r12, [nfiles]
    jge     .done

    ; Get filename pointer
    mov     rbx, [files + r12*8]        ; rbx = files[file_index]

    ; ── For non-stdin files, try to open first before printing header ──
    mov     rdi, rbx
    mov     rsi, dash_str
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
    mov     [cur_fd], rax               ; save fd

    ; File opened successfully — print header then process
    call    print_file_header
    test    rax, rax
    js      .write_error
    mov     byte [first_file], 0
    mov     rdi, [cur_fd]
    call    process_fd
    push    rax
    mov     rdi, [cur_fd]
    call    asm_close
    pop     rax
    test    rax, rax
    jns     .file_next
    ; Check for EPIPE
    cmp     rax, -EPIPE
    je      .epipe_exit
    mov     byte [had_error], 1
    jmp     .file_next

.is_stdin_file:
    ; stdin — print header then process fd 0
    call    print_file_header
    test    rax, rax
    js      .write_error
    mov     byte [first_file], 0
    xor     edi, edi                    ; fd = 0 (stdin)
    call    process_fd
    test    rax, rax
    jns     .file_next
    cmp     rax, -EPIPE
    je      .epipe_exit
    mov     byte [had_error], 1
    jmp     .file_next

.file_open_error:
    ; Print error to stderr: "head: cannot open 'FILE' for reading: ERROR\n"
    push    rax                         ; save errno
    mov     rdi, STDERR
    mov     rsi, err_cannot_open_pre
    mov     rdx, err_cannot_open_pre_len
    call    asm_write_all
    mov     rdi, rbx
    call    str_len
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, err_for_reading
    mov     rdx, err_for_reading_len
    call    asm_write_all
    pop     rax
    neg     rax
    call    print_errno
    mov     rdi, STDERR
    mov     rsi, newline_str
    mov     rdx, 1
    call    asm_write_all
    mov     byte [had_error], 1
    jmp     .file_next

.file_next:
    inc     r12
    jmp     .file_loop

.done:
    ; Exit with appropriate code
    movzx   edi, byte [had_error]
    mov     rax, SYS_EXIT
    syscall

.write_error:
    ; Check for EPIPE — exit 0 silently
    cmp     rax, -EPIPE
    je      .epipe_exit
    ; Other write error
    mov     byte [had_error], 1
    jmp     .done

.epipe_exit:
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

; ============================================================================
;  print_file_header — Print "==> filename <==" header if needed
;  Input: rbx = filename, first_file/show_headers globals
;  Output: rax = 0 on success, negative on error
; ============================================================================
print_file_header:
    cmp     byte [show_headers], 1
    jne     .pfh_ok

    ; If not first file, print blank line before header
    cmp     byte [first_file], 1
    je      .pfh_header
    mov     rdi, STDOUT
    mov     rsi, newline_str
    mov     rdx, 1
    call    asm_write_all
    test    rax, rax
    js      .pfh_ret

.pfh_header:
    ; Print "==> "
    mov     rdi, STDOUT
    mov     rsi, header_prefix
    mov     rdx, 4
    call    asm_write_all
    test    rax, rax
    js      .pfh_ret

    ; Print filename (or "standard input" for "-")
    mov     rdi, rbx
    mov     rsi, dash_str
    call    str_equal
    test    eax, eax
    jz      .pfh_filename
    mov     rdi, STDOUT
    mov     rsi, stdin_name
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
    mov     rsi, header_suffix
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
    mov     rax, [mode]
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
    mov     rsi, [count]
    call    head_lines
    jmp     .pfd_done

.pfd_bytes:
    mov     rdi, r12
    mov     rsi, [count]
    call    head_bytes
    jmp     .pfd_done

.pfd_lines_end:
    mov     rdi, r12
    mov     rsi, [count]
    call    head_lines_from_end
    jmp     .pfd_done

.pfd_bytes_end:
    mov     rdi, r12
    mov     rsi, [count]
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
    movzx   r15d, byte [zero_term]
    test    r15d, r15d
    jz      .hl_use_newline
    xor     r15d, r15d                  ; delimiter = 0 (NUL)
    jmp     .hl_read_loop
.hl_use_newline:
    mov     r15d, 10                    ; delimiter = '\n'

.hl_read_loop:
    ; Read a chunk
    mov     rdi, r12
    mov     rsi, iobuf
    mov     rdx, IOBUF_SIZE
    call    asm_read
    test    rax, rax
    jz      .hl_done_ok                 ; EOF
    js      .hl_read_error
    mov     r14, rax                    ; bytes_read

    ; Scan for delimiters in the chunk
    mov     rsi, iobuf                  ; current position
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
    pop     rcx
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
    mov     rsi, iobuf
    sub     rdx, rsi                    ; bytes to write
    mov     rdi, STDOUT
    call    asm_write_all
    test    rax, rax
    js      .hl_write_err
    jmp     .hl_done_ok

.hl_write_chunk:
    ; Write the entire chunk
    mov     rdi, STDOUT
    mov     rsi, iobuf
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
    mov     rax, -1
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
    mov     rsi, iobuf
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
    mov     rsi, iobuf
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
    mov     rax, -1
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
;  head_lines_from_end — Output all but last N lines from fd
;  Reads entire input into frombuf, then scans backward
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

    ; Read entire input into frombuf
    xor     r14d, r14d                  ; total bytes read
.hlfe_read_loop:
    mov     rdx, FROMBUF_SIZE
    sub     rdx, r14
    jz      .hlfe_read_done             ; buffer full
    mov     rdi, r12
    mov     rsi, frombuf
    add     rsi, r14
    call    asm_read
    test    rax, rax
    jz      .hlfe_read_done             ; EOF
    js      .hlfe_read_error
    add     r14, rax
    jmp     .hlfe_read_loop

.hlfe_read_done:
    ; r14 = total bytes in frombuf
    test    r14, r14
    jz      .hlfe_done_ok               ; empty input

    ; Determine delimiter
    movzx   r15d, byte [zero_term]
    test    r15d, r15d
    jz      .hlfe_delim_nl
    xor     r15d, r15d                  ; NUL
    jmp     .hlfe_scan_back
.hlfe_delim_nl:
    mov     r15d, 10                    ; newline

.hlfe_scan_back:
    ; Scan backward from end, skip N delimiters
    mov     rsi, frombuf
    mov     rcx, r14                    ; total length
    xor     edx, edx                    ; delimiter count

    ; Check if last byte is the delimiter
    cmp     byte [rsi + rcx - 1], r15b
    je      .hlfe_back_loop
    ; Last byte is NOT delimiter — trailing content counts as 1 line
    inc     edx                         ; start count at 1

.hlfe_back_loop:
    dec     rcx
    js      .hlfe_nothing               ; went past beginning
    cmp     byte [rsi + rcx], r15b
    jne     .hlfe_back_loop
    inc     edx
    cmp     rdx, r13
    jbe     .hlfe_back_loop
    ; Found the (N+1)th delimiter from end; output up to and including it
    inc     rcx                         ; include the delimiter
    mov     rdx, rcx
    mov     rdi, STDOUT
    mov     rsi, frombuf
    call    asm_write_all
    test    rax, rax
    js      .hlfe_write_err
    jmp     .hlfe_done_ok

.hlfe_nothing:
    ; Fewer than N+1 delimiters — N >= total lines — output nothing
    jmp     .hlfe_done_ok

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

.hlfe_done_ok:
    xor     eax, eax
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

.hlfe_read_error:
    mov     rax, -1
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

.hlfe_write_err:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret


; ============================================================================
;  head_bytes_from_end — Output all but last N bytes from fd
;  Reads entire input into frombuf, outputs data[:len-N]
;  Input: rdi = fd, rsi = n
;  Output: rax = 0 on success, negative on error
; ============================================================================
head_bytes_from_end:
    push    r12
    push    r13
    push    r14
    push    rbp

    mov     r12, rdi                    ; fd
    mov     r13, rsi                    ; N bytes to skip from end
    test    r13, r13
    jz      .hbfe_output_all            ; -c -0 means output everything

    ; Read entire input into frombuf
    xor     r14d, r14d                  ; total bytes
.hbfe_read_loop:
    mov     rdx, FROMBUF_SIZE
    sub     rdx, r14
    jz      .hbfe_read_done
    mov     rdi, r12
    mov     rsi, frombuf
    add     rsi, r14
    call    asm_read
    test    rax, rax
    jz      .hbfe_read_done
    js      .hbfe_read_error
    add     r14, rax
    jmp     .hbfe_read_loop

.hbfe_read_done:
    ; Output data[0..len-N]
    mov     rax, r14
    sub     rax, r13
    jle     .hbfe_done_ok               ; N >= len, output nothing
    mov     rdx, rax                    ; bytes to write
    mov     rdi, STDOUT
    mov     rsi, frombuf
    call    asm_write_all
    test    rax, rax
    js      .hbfe_write_err
    jmp     .hbfe_done_ok

.hbfe_output_all:
    ; -c -0: output everything by streaming
    mov     rdi, r12
    mov     rsi, 0x7FFFFFFFFFFFFFFF
    pop     rbp
    pop     r14
    pop     r13
    pop     r12
    jmp     head_bytes                  ; tail call

.hbfe_done_ok:
    xor     eax, eax
    pop     rbp
    pop     r14
    pop     r13
    pop     r12
    ret

.hbfe_read_error:
    mov     rax, -1
    pop     rbp
    pop     r14
    pop     r13
    pop     r12
    ret

.hbfe_write_err:
    pop     rbp
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

    mov     r12, [argv]                 ; argv base
    mov     r13, [argc]                 ; argc
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
    mov     rcx, files
    mov     rdx, [nfiles]
    mov     [rcx + rdx*8], rax
    inc     qword [nfiles]
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
    call    parse_number_with_suffix
    test    rax, rax
    js      .pa_invalid_lines_num
    mov     [count], rax
    mov     qword [mode], MODE_LINES
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
    jne     .pa_lines_positive
    inc     rdi
    call    parse_number_with_suffix
    test    rax, rax
    js      .pa_invalid_lines
    mov     [count], rax
    mov     qword [mode], MODE_LINES_END
    jmp     .pa_next

.pa_lines_positive:
    call    parse_number_with_suffix
    test    rax, rax
    js      .pa_invalid_lines
    mov     [count], rax
    mov     qword [mode], MODE_LINES
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
    jne     .pa_bytes_positive
    inc     rdi
    call    parse_number_with_suffix
    test    rax, rax
    js      .pa_invalid_bytes
    mov     [count], rax
    mov     qword [mode], MODE_BYTES_END
    jmp     .pa_next

.pa_bytes_positive:
    call    parse_number_with_suffix
    test    rax, rax
    js      .pa_invalid_bytes
    mov     [count], rax
    mov     qword [mode], MODE_BYTES
    jmp     .pa_next

.pa_short_q:
    mov     byte [quiet], 1
    inc     rsi
    jmp     .pa_short_loop

.pa_short_v:
    mov     byte [verbose], 1
    inc     rsi
    jmp     .pa_short_loop

.pa_short_z:
    mov     byte [zero_term], 1
    inc     rsi
    jmp     .pa_short_loop

.pa_long_opt:
    ; Long options: --lines=, --bytes=, --lines, --bytes, --quiet, --silent,
    ; --verbose, --zero-terminated, --help, --version
    lea     rdi, [rbx + 2]             ; skip "--"

    ; --help
    mov     rsi, str_help
    call    str_equal
    test    eax, eax
    jnz     .pa_help

    ; --version
    lea     rdi, [rbx + 2]
    mov     rsi, str_version
    call    str_equal
    test    eax, eax
    jnz     .pa_version

    ; --quiet
    lea     rdi, [rbx + 2]
    mov     rsi, str_quiet
    call    str_equal
    test    eax, eax
    jnz     .pa_long_quiet

    ; --silent
    lea     rdi, [rbx + 2]
    mov     rsi, str_silent
    call    str_equal
    test    eax, eax
    jnz     .pa_long_quiet

    ; --verbose
    lea     rdi, [rbx + 2]
    mov     rsi, str_verbose
    call    str_equal
    test    eax, eax
    jnz     .pa_long_verbose

    ; --zero-terminated
    lea     rdi, [rbx + 2]
    mov     rsi, str_zerot
    call    str_equal
    test    eax, eax
    jnz     .pa_long_zerot

    ; --lines=VALUE
    lea     rdi, [rbx + 2]
    mov     rsi, str_lines_eq
    mov     rdx, 6                      ; len("lines=")
    call    str_prefix
    test    eax, eax
    jnz     .pa_long_lines_eq

    ; --bytes=VALUE
    lea     rdi, [rbx + 2]
    mov     rsi, str_bytes_eq
    mov     rdx, 6                      ; len("bytes=")
    call    str_prefix
    test    eax, eax
    jnz     .pa_long_bytes_eq

    ; --lines (next arg is value)
    lea     rdi, [rbx + 2]
    mov     rsi, str_lines
    call    str_equal
    test    eax, eax
    jnz     .pa_long_lines

    ; --bytes (next arg is value)
    lea     rdi, [rbx + 2]
    mov     rsi, str_bytes
    call    str_equal
    test    eax, eax
    jnz     .pa_long_bytes

    ; Unrecognized long option
    jmp     .pa_unrec_long

.pa_long_quiet:
    mov     byte [quiet], 1
    jmp     .pa_next

.pa_long_verbose:
    mov     byte [verbose], 1
    jmp     .pa_next

.pa_long_zerot:
    mov     byte [zero_term], 1
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
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

.pa_version:
    call    print_version
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

.pa_file:
    ; Add to files list
    mov     rcx, files
    mov     rdx, [nfiles]
    mov     [rcx + rdx*8], rbx
    inc     qword [nfiles]

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
    mov     rsi, err_invalid_opt_pre
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
    mov     rsi, err_opt_suffix
    mov     rdx, err_opt_suffix_len
    call    asm_write_all
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.pa_unrec_long:
    ; "head: unrecognized option 'XXXX'\nTry ..."
    mov     rdi, STDERR
    mov     rsi, err_unrec_pre
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
    mov     rsi, err_opt_suffix
    mov     rdx, err_opt_suffix_len
    call    asm_write_all
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.pa_missing_arg_n:
    mov     rdi, STDERR
    mov     rsi, err_missing_n
    mov     rdx, err_missing_n_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, err_try_help
    mov     rdx, err_try_help_len
    call    asm_write_all
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.pa_missing_arg_c:
    mov     rdi, STDERR
    mov     rsi, err_missing_c
    mov     rdx, err_missing_c_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, err_try_help
    mov     rdx, err_try_help_len
    call    asm_write_all
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.pa_missing_arg_long_lines:
    mov     rdi, STDERR
    mov     rsi, err_missing_long_lines
    mov     rdx, err_missing_long_lines_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, err_try_help
    mov     rdx, err_try_help_len
    call    asm_write_all
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.pa_missing_arg_long_bytes:
    mov     rdi, STDERR
    mov     rsi, err_missing_long_bytes
    mov     rdx, err_missing_long_bytes_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, err_try_help
    mov     rdx, err_try_help_len
    call    asm_write_all
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

.pa_invalid_lines:
    mov     rdi, STDERR
    mov     rsi, err_invalid_lines_pre
    mov     rdx, err_invalid_lines_pre_len
    call    asm_write_all
    jmp     .pa_invalid_num_finish

.pa_invalid_lines_num:
    mov     rdi, STDERR
    mov     rsi, err_invalid_lines_pre
    mov     rdx, err_invalid_lines_pre_len
    call    asm_write_all
    jmp     .pa_invalid_num_finish

.pa_invalid_bytes:
    mov     rdi, STDERR
    mov     rsi, err_invalid_bytes_pre
    mov     rdx, err_invalid_bytes_pre_len
    call    asm_write_all

.pa_invalid_num_finish:
    mov     rdi, STDERR
    mov     rsi, err_quote_nl
    mov     rdx, 2                      ; "'\n"
    call    asm_write_all
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall


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
    ; acc = acc * 10 + digit
    imul    rax, 10
    movzx   edx, byte [rsi]
    sub     edx, '0'
    add     rax, rdx
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
    mov     rsi, err_io
    mov     rdx, err_io_len
    jmp     asm_write_all
.pe_noent:
    mov     rdi, STDERR
    mov     rsi, err_noent
    mov     rdx, err_noent_len
    jmp     asm_write_all
.pe_perm:
    mov     rdi, STDERR
    mov     rsi, err_perm
    mov     rdx, err_perm_len
    jmp     asm_write_all
.pe_isdir:
    mov     rdi, STDERR
    mov     rsi, err_isdir
    mov     rdx, err_isdir_len
    jmp     asm_write_all
.pe_notdir:
    mov     rdi, STDERR
    mov     rsi, err_notdir
    mov     rdx, err_notdir_len
    jmp     asm_write_all

; print_help — print help text to stdout
print_help:
    mov     rdi, STDOUT
    mov     rsi, help_text
    mov     rdx, help_text_len
    jmp     asm_write_all

; print_version — print version text to stdout
print_version:
    mov     rdi, STDOUT
    mov     rsi, version_text
    mov     rdx, version_text_len
    jmp     asm_write_all


; ############################################################################
;  Inlined I/O routines (from lib/io.asm)
; ############################################################################

; asm_write(rdi=fd, rsi=buf, rdx=len) -> rax=bytes_written
; Handles EINTR automatically
asm_write:
.aw_retry:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -EINTR
    je      .aw_retry
    ret

; asm_write_all(rdi=fd, rsi=buf, rdx=len) -> rax=0 on success, -1 on error
; Handles partial writes + EINTR
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
    cmp     rax, -EINTR
    je      .wa_loop            ; EINTR — retry
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
; Handles EINTR automatically
asm_read:
.ar_retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, -EINTR
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
;  Inline data placed directly after code. Part of the RX PT_LOAD segment.
; ############################################################################

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
err_cannot_open_pre:
    db "head: cannot open '"
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
;  End of file. file_size marks the total binary size.
; ============================================================================
file_size equ $ - ehdr
