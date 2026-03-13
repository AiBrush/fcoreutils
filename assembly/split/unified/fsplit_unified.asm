; fsplit_unified.asm
; Hand-crafted minimal ELF binary for fsplit
; Fully self-contained — no libc, no linker needed
; Build: nasm -f bin unified/fsplit_unified.asm -o fsplit && chmod +x fsplit

BITS 64
org 0x400000

; ── System constants ──
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXIT       60
%define SYS_RT_SIGPROCMASK 14

%define STDIN           0
%define STDOUT          1
%define STDERR          2
%define O_RDONLY        0
%define O_WRONLY        1
%define O_CREAT         64
%define O_TRUNC         512
%define O_WRONLY_CREAT_TRUNC (O_WRONLY | O_CREAT | O_TRUNC)
%define FILE_MODE       0o644
%define EINTR           4
%define IO_SIZE     65536

; ── Macros ──
%macro WRITE 3
    mov rax, SYS_WRITE
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    syscall
%endmacro

%macro EXIT 1
    mov rax, SYS_EXIT
    mov rdi, %1
    syscall
%endmacro

; BSS layout constants
%define BSS_BASE     0x500000
%define io_buf       BSS_BASE
%define fname_buf    (BSS_BASE + IO_SIZE)
%define num_buf      (fname_buf + 4096)
%define verbose_buf  (num_buf + 64)
%define argc_save    (verbose_buf + 512)
%define argv_save    (argc_save + 8)
%define input_file   (argv_save + 8)
%define prefix_ptr   (input_file + 8)
%define suffix_len   (prefix_ptr + 8)
%define split_lines  (suffix_len + 8)
%define split_bytes  (split_lines + 8)
%define flag_numeric (split_bytes + 8)
%define flag_verbose (flag_numeric + 1)
%define flag_elide   (flag_verbose + 1)
%define add_suffix   (flag_elide + 1)
%define add_suffix_len (add_suffix + 256)
%define file_index   (add_suffix_len + 8)
%define cur_count    (file_index + 8)
%define out_fd       (cur_count + 8)
%define input_fd     (out_fd + 8)
%define had_error    (input_fd + 8)
%define mode_bytes   (had_error + 4)
%define prefix_len   (mode_bytes + 4)
%define BSS_END      (prefix_len + 8)
%define BSS_SIZE     (BSS_END - BSS_BASE)

; ── ELF Header ──
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
    dw ehdr_end - ehdr
    dw phdr_size
    dw 3
    dw 0, 0, 0
ehdr_end:

; ── Program Headers ──
phdr:
    ; PT_LOAD: code + data (R+X)
    dd 1
    dd 5
    dq 0
    dq 0x400000
    dq 0x400000
    dq file_end - ehdr
    dq file_end - ehdr
    dq 0x1000
phdr_size equ $ - phdr

    ; PT_LOAD: BSS (R+W)
    dd 1
    dd 6
    dq 0
    dq BSS_BASE
    dq BSS_BASE
    dq 0
    dq BSS_SIZE
    dq 0x1000

    ; PT_GNU_STACK (NX)
    dd 0x6474E551
    dd 6
    dq 0, 0, 0, 0, 0
    dq 0x10

; ════════════════════════════════════════════════════════════════
; CODE
; ════════════════════════════════════════════════════════════════

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
    mov     eax, [rsp]
    mov     [argc_save], eax
    lea     rax, [rsp + 8]
    mov     [argv_save], rax

    ; Set defaults
    mov     qword [split_lines], 1000
    mov     qword [split_bytes], 0
    mov     qword [suffix_len], 2
    mov     byte [flag_numeric], 0
    mov     byte [flag_verbose], 0
    mov     byte [flag_elide], 0
    mov     byte [add_suffix], 0
    mov     qword [add_suffix_len], 0
    mov     qword [input_file], 0
    mov     qword [prefix_ptr], str_default_prefix
    mov     dword [had_error], 0
    mov     dword [mode_bytes], 0
    mov     qword [file_index], 0
    mov     qword [cur_count], 0
    mov     qword [out_fd], -1
    mov     qword [input_fd], -1

    call    parse_args

    ; Compute prefix length
    mov     rdi, [prefix_ptr]
    call    strlen
    mov     [prefix_len], rax

    ; Open input file (or use stdin)
    mov     rax, [input_file]
    test    rax, rax
    jz      .use_stdin
    cmp     byte [rax], '-'
    jne     .open_input
    cmp     byte [rax+1], 0
    je      .use_stdin
.open_input:
    mov     rdi, rax
    mov     eax, SYS_OPEN
    xor     esi, esi        ; O_RDONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .open_error
    mov     [input_fd], rax
    jmp     .do_split
.use_stdin:
    mov     qword [input_fd], STDIN
.do_split:
    cmp     dword [mode_bytes], 0
    jne     do_split_bytes
    jmp     do_split_lines

.open_error:
    WRITE   STDERR, err_prefix, err_prefix_len
    mov     rdi, [input_file]
    call    strlen
    mov     rdx, rax
    WRITE   STDERR, [input_file], rdx
    WRITE   STDERR, err_open, err_open_len
    EXIT    1

; ── Argument parser ──
parse_args:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12, [argv_save]
    mov     r13d, [argc_save]
    xor     ebx, ebx
    inc     ebx             ; skip argv[0]
    xor     r14d, r14d      ; end-of-options flag
.arg_loop:
    cmp     ebx, r13d
    jge     .arg_done
    mov     rsi, [r12 + rbx*8]
    test    r14d, r14d
    jnz     .positional
    ; Check for "--"
    cmp     word [rsi], 0x2D2D
    jne     .not_dd
    cmp     byte [rsi+2], 0
    jne     .not_dd
    mov     r14d, 1
    inc     ebx
    jmp     .arg_loop
.not_dd:
    cmp     byte [rsi], '-'
    jne     .positional
    cmp     byte [rsi+1], 0
    je      .positional     ; "-" alone is stdin
    cmp     byte [rsi+1], '-'
    je      .long_opt
    ; Short options
    inc     rsi
.short_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .next_arg
    cmp     al, 'l'
    je      .opt_l
    cmp     al, 'b'
    je      .opt_b
    cmp     al, 'a'
    je      .opt_a
    cmp     al, 'd'
    je      .opt_d
    cmp     al, 'e'
    je      .opt_e
    ; Check for -l<N> / -b<N> / -a<N> inline (e.g. -l100)
    jmp     .bad_opt
.opt_l:
    inc     rsi
    cmp     byte [rsi], 0
    jne     .opt_l_inline
    ; Next arg is the value
    inc     ebx
    cmp     ebx, r13d
    jge     .missing_arg
    mov     rsi, [r12 + rbx*8]
.opt_l_inline:
    mov     rdi, rsi
    call    parse_number
    mov     [split_lines], rax
    mov     dword [mode_bytes], 0
    jmp     .next_arg
.opt_b:
    inc     rsi
    cmp     byte [rsi], 0
    jne     .opt_b_inline
    inc     ebx
    cmp     ebx, r13d
    jge     .missing_arg
    mov     rsi, [r12 + rbx*8]
.opt_b_inline:
    mov     rdi, rsi
    call    parse_size
    mov     [split_bytes], rax
    mov     dword [mode_bytes], 1
    jmp     .next_arg
.opt_a:
    inc     rsi
    cmp     byte [rsi], 0
    jne     .opt_a_inline
    inc     ebx
    cmp     ebx, r13d
    jge     .missing_arg
    mov     rsi, [r12 + rbx*8]
.opt_a_inline:
    mov     rdi, rsi
    call    parse_number
    mov     [suffix_len], rax
    jmp     .next_arg
.opt_d:
    mov     byte [flag_numeric], 1
    inc     rsi
    jmp     .short_loop
.opt_e:
    mov     byte [flag_elide], 1
    inc     rsi
    jmp     .short_loop
.bad_opt:
    WRITE   STDERR, err_prefix, err_prefix_len
    WRITE   STDERR, err_invalid_opt, err_invalid_opt_len
    sub     rsp, 8
    mov     [rsp], al
    WRITE   STDERR, rsp, 1
    add     rsp, 8
    WRITE   STDERR, err_quote_nl, err_quote_nl_len
    EXIT    1
.long_opt:
    push    rcx
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    ; --help
    lea     rsi, [s_help]
    call    strcmp
    test    eax, eax
    jz      .lo_help
    ; --version
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_version]
    call    strcmp
    test    eax, eax
    jz      .lo_version
    ; --verbose
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_verbose]
    call    strcmp
    test    eax, eax
    jz      .lo_verbose
    ; --numeric-suffixes
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_numeric]
    call    strcmp
    test    eax, eax
    jz      .lo_numeric
    ; --elide-empty-files
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_elide]
    call    strcmp
    test    eax, eax
    jz      .lo_elide
    ; --lines=N
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_lines_eq]
    mov     ecx, 6          ; "lines="
    call    strncmp
    test    eax, eax
    jz      .lo_lines_eq
    ; --bytes=N
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_bytes_eq]
    mov     ecx, 6          ; "bytes="
    call    strncmp
    test    eax, eax
    jz      .lo_bytes_eq
    ; --suffix-length=N
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_suffix_length_eq]
    mov     ecx, 14         ; "suffix-length="
    call    strncmp
    test    eax, eax
    jz      .lo_suffix_length_eq
    ; --additional-suffix=SUFFIX
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_additional_suffix_eq]
    mov     ecx, 18         ; "additional-suffix="
    call    strncmp
    test    eax, eax
    jz      .lo_additional_suffix_eq
    ; --lines N (without =)
    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [s_lines]
    call    strcmp
    test    eax, eax
    jz      .lo_lines
    ; Unknown
    pop     rcx
    WRITE   STDERR, err_prefix, err_prefix_len
    WRITE   STDERR, err_unrec, err_unrec_len
    mov     rdi, [r12 + rbx*8]
    call    strlen
    mov     rdx, rax
    WRITE   STDERR, [r12 + rbx*8], rdx
    WRITE   STDERR, err_quote_nl, err_quote_nl_len
    EXIT    1
.lo_help:
    pop     rcx
    WRITE   STDOUT, str_help, str_help_len
    EXIT    0
.lo_version:
    pop     rcx
    WRITE   STDOUT, str_version, str_version_len
    EXIT    0
.lo_verbose:
    pop     rcx
    mov     byte [flag_verbose], 1
    jmp     .next_arg
.lo_numeric:
    pop     rcx
    mov     byte [flag_numeric], 1
    jmp     .next_arg
.lo_elide:
    pop     rcx
    mov     byte [flag_elide], 1
    jmp     .next_arg
.lo_lines:
    pop     rcx
    inc     ebx
    cmp     ebx, r13d
    jge     .missing_arg
    mov     rdi, [r12 + rbx*8]
    call    parse_number
    mov     [split_lines], rax
    mov     dword [mode_bytes], 0
    jmp     .next_arg
.lo_lines_eq:
    pop     rcx
    mov     rdi, [r12 + rbx*8]
    add     rdi, 8          ; skip "--lines="
    call    parse_number
    mov     [split_lines], rax
    mov     dword [mode_bytes], 0
    jmp     .next_arg
.lo_bytes_eq:
    pop     rcx
    mov     rdi, [r12 + rbx*8]
    add     rdi, 8          ; skip "--bytes="
    call    parse_size
    mov     [split_bytes], rax
    mov     dword [mode_bytes], 1
    jmp     .next_arg
.lo_suffix_length_eq:
    pop     rcx
    mov     rdi, [r12 + rbx*8]
    add     rdi, 16         ; skip "--suffix-length="
    call    parse_number
    mov     [suffix_len], rax
    jmp     .next_arg
.lo_additional_suffix_eq:
    pop     rcx
    mov     rdi, [r12 + rbx*8]
    add     rdi, 20         ; skip "--additional-suffix="
    ; Copy suffix to add_suffix buffer
    mov     rsi, rdi
    mov     rdi, add_suffix
    xor     ecx, ecx
.copy_suffix:
    movzx   eax, byte [rsi + rcx]
    mov     [rdi + rcx], al
    test    al, al
    jz      .suffix_copied
    inc     ecx
    cmp     ecx, 255
    jl      .copy_suffix
    mov     byte [rdi + rcx], 0
.suffix_copied:
    mov     [add_suffix_len], rcx
    jmp     .next_arg
.positional:
    ; First positional = input file, second = prefix
    cmp     qword [input_file], 0
    jne     .set_prefix
    ; Check if it's "-" (stdin)
    cmp     byte [rsi], '-'
    jne     .set_input
    cmp     byte [rsi+1], 0
    jne     .set_input
.set_input:
    mov     [input_file], rsi
    jmp     .next_arg
.set_prefix:
    mov     [prefix_ptr], rsi
    jmp     .next_arg
.missing_arg:
    WRITE   STDERR, err_prefix, err_prefix_len
    WRITE   STDERR, err_missing, err_missing_len
    EXIT    1
.next_arg:
    inc     ebx
    jmp     .arg_loop
.arg_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── Split by lines ──
do_split_lines:
    ; r12 = line counter for current file
    ; r13 = lines per file
    ; r14 = bytes written to current file (for elide check)
    xor     r12d, r12d
    xor     r14d, r14d
    mov     r13, [split_lines]
    ; NOTE: do NOT open output file here; lazy-open on first write
.read_loop:
    mov     rax, SYS_READ
    mov     rdi, [input_fd]
    mov     rsi, io_buf
    mov     edx, IO_SIZE
    syscall
    cmp     rax, -EINTR
    je      .read_loop
    test    rax, rax
    js      .read_error
    jz      .read_done
    ; Process buffer: scan for newlines, write chunks
    ; rbx = bytes remaining, r15 = current position
    mov     rbx, rax        ; bytes remaining
    lea     r15, [io_buf]   ; current scan position
    ; r8 = chunk start
    mov     r8, r15
.scan_loop:
    test    rbx, rbx
    jz      .flush_chunk    ; end of buffer, flush remaining
    cmp     byte [r15], 10
    je      .found_newline
    inc     r15
    dec     rbx
    jmp     .scan_loop
.found_newline:
    inc     r15             ; include the newline
    dec     rbx
    inc     r12             ; line count++
    cmp     r12, r13
    jl      .scan_loop      ; not at threshold yet
    ; Write chunk from r8 to r15
    ; Lazy-open output file if not yet open
    push    rbx
    push    r15
    push    r8
    cmp     qword [out_fd], -1
    jne     .fn_write
    call    open_next_output
.fn_write:
    mov     rdx, r15
    sub     rdx, r8         ; length (r15/r8 from stack not yet popped, but still in regs)
    ; Recalculate from stack since open_next_output may clobber regs
    pop     r8
    pop     r15
    push    r15
    push    r8
    mov     rdx, r15
    sub     rdx, r8
    mov     rsi, r8         ; buffer start
    mov     rdi, [out_fd]
    call    write_all
    pop     r8
    pop     r15
    pop     rbx
    add     r14, 1          ; mark that we wrote something
    ; Reset line counter, close file (lazy: don't open next yet)
    xor     r12d, r12d
    xor     r14d, r14d
    push    rbx
    push    r15
    call    close_output
    pop     r15
    pop     rbx
    ; New chunk starts at current position
    mov     r8, r15
    jmp     .scan_loop
.flush_chunk:
    ; Write any remaining data from r8 to r15
    mov     rdx, r15
    sub     rdx, r8
    test    rdx, rdx
    jz      .read_loop      ; nothing to flush
    ; Lazy-open output file if not yet open
    push    r8
    push    rdx
    cmp     qword [out_fd], -1
    jne     .fl_write
    call    open_next_output
.fl_write:
    pop     rdx
    pop     r8
    ; Recalculate rdx since r15 is still valid
    mov     rdx, r15
    sub     rdx, r8
    mov     rsi, r8
    mov     rdi, [out_fd]
    call    write_all
    add     r14, 1
    jmp     .read_loop
.read_done:
    ; If no file was ever opened (empty input), just exit
    cmp     qword [out_fd], -1
    je      .exit_ok
    ; Check if we need to elide empty last file
    cmp     byte [flag_elide], 0
    je      .close_last
    test    r14, r14
    jnz     .close_last
    test    r12, r12
    jnz     .close_last
    ; Empty file, unlink it
    call    close_output
    call    build_filename_for_current
    mov     rax, 87         ; SYS_UNLINK
    mov     rdi, fname_buf
    syscall
    jmp     .exit_ok
.close_last:
    call    close_output
.exit_ok:
    mov     rdi, [input_fd]
    test    rdi, rdi
    jz      .exit_done
    cmp     rdi, STDIN
    je      .exit_done
    mov     rax, SYS_CLOSE
    syscall
.exit_done:
    movzx   edi, byte [had_error]
    EXIT    rdi
.read_error:
    WRITE   STDERR, err_prefix, err_prefix_len
    WRITE   STDERR, err_read, err_read_len
    mov     dword [had_error], 1
    jmp     .close_last

; ── Split by bytes ──
do_split_bytes:
    ; r12 = bytes written to current file
    ; r13 = bytes per file
    xor     r12d, r12d
    mov     r13, [split_bytes]
    ; NOTE: do NOT open output file here; lazy-open on first write
.read_loop:
    mov     rax, SYS_READ
    mov     rdi, [input_fd]
    mov     rsi, io_buf
    mov     edx, IO_SIZE
    syscall
    cmp     rax, -EINTR
    je      .read_loop
    test    rax, rax
    js      .read_error
    jz      .read_done
    ; Process buffer
    mov     rcx, rax        ; bytes read
    mov     rsi, io_buf     ; buffer start
.write_loop:
    test    rcx, rcx
    jz      .read_loop
    ; Lazy-open output file if not yet open
    cmp     qword [out_fd], -1
    jne     .have_fd
    push    rcx
    push    rsi
    call    open_next_output
    pop     rsi
    pop     rcx
.have_fd:
    ; How many bytes can we write to current file?
    mov     rax, r13
    sub     rax, r12        ; remaining capacity
    cmp     rax, rcx
    jle     .write_partial
    ; Write all remaining bytes using write_all for EINTR safety
    push    rcx
    push    rsi
    mov     rdi, [out_fd]
    mov     rdx, rcx
    call    write_all
    pop     rsi
    pop     rcx
    add     r12, rcx
    jmp     .read_loop
.write_partial:
    ; Write 'rax' bytes, then rotate
    mov     rdx, rax
    push    rcx
    push    rsi
    push    rdx
    mov     rdi, [out_fd]
    call    write_all
    pop     rdx
    pop     rsi
    pop     rcx
    add     rsi, rdx
    sub     rcx, rdx
    add     r12, rdx
    ; Close current file (don't open next yet - lazy open)
    push    rcx
    push    rsi
    call    close_output
    pop     rsi
    pop     rcx
    xor     r12d, r12d
    jmp     .write_loop
.read_done:
    ; If no file was ever opened (empty input), just exit
    cmp     qword [out_fd], -1
    je      .exit_ok
    ; Check elide
    cmp     byte [flag_elide], 0
    je      .close_last
    cmp     r12, 0
    jne     .close_last
    call    close_output
    call    build_filename_for_current
    mov     rax, 87         ; SYS_UNLINK
    mov     rdi, fname_buf
    syscall
    jmp     .exit_ok
.close_last:
    call    close_output
.exit_ok:
    mov     rdi, [input_fd]
    test    rdi, rdi
    jz      .exit_done
    cmp     rdi, STDIN
    je      .exit_done
    mov     rax, SYS_CLOSE
    syscall
.exit_done:
    movzx   edi, byte [had_error]
    EXIT    rdi
.read_error:
    WRITE   STDERR, err_prefix, err_prefix_len
    WRITE   STDERR, err_read, err_read_len
    mov     dword [had_error], 1
    jmp     .close_last

; ── Open next output file ──
open_next_output:
    push    rbx
    ; Build filename
    call    build_filename
    ; Open file
    mov     rax, SYS_OPEN
    mov     rdi, fname_buf
    mov     esi, O_WRONLY_CREAT_TRUNC
    mov     edx, FILE_MODE
    syscall
    test    rax, rax
    js      .open_err
    mov     [out_fd], rax
    ; Print verbose message if needed
    cmp     byte [flag_verbose], 0
    je      .no_verbose
    call    print_verbose
.no_verbose:
    ; Increment file index
    inc     qword [file_index]
    pop     rbx
    ret
.open_err:
    WRITE   STDERR, err_prefix, err_prefix_len
    WRITE   STDERR, err_create, err_create_len
    mov     rdi, fname_buf
    call    strlen
    mov     rdx, rax
    WRITE   STDERR, fname_buf, rdx
    WRITE   STDERR, str_nl, 1
    EXIT    1

; ── Close current output file ──
close_output:
    mov     rdi, [out_fd]
    cmp     rdi, -1
    je      .skip
    mov     rax, SYS_CLOSE
    syscall
    mov     qword [out_fd], -1
.skip:
    ret

; ── Build filename for current file_index ──
build_filename:
    push    rbx
    push    r12
    push    r13
    ; Copy prefix to fname_buf
    mov     rdi, fname_buf
    mov     rsi, [prefix_ptr]
    mov     rcx, [prefix_len]
    rep     movsb
    ; Generate suffix based on file_index
    mov     rax, [file_index]
    mov     rcx, [suffix_len]
    cmp     byte [flag_numeric], 0
    jne     .numeric_suffix
    ; Alpha suffix: base-26 (aa, ab, ..., az, ba, ...)
    ; We generate rcx characters
    ; Use num_buf as temp, then copy reversed
    push    rdi
    mov     r12, rcx        ; suffix length
    lea     r13, [num_buf]
    mov     rbx, rax
    mov     rcx, r12
.alpha_loop:
    test    rcx, rcx
    jz      .alpha_done
    dec     rcx
    xor     edx, edx
    mov     r8, 26
    div     r8
    add     dl, 'a'
    mov     [r13 + rcx], dl
    mov     rbx, rax
    jmp     .alpha_loop
.alpha_done:
    pop     rdi
    mov     rsi, r13
    mov     rcx, r12
    rep     movsb
    jmp     .add_additional
.numeric_suffix:
    ; Numeric suffix: base-10 (00, 01, ...)
    push    rdi
    mov     r12, rcx        ; suffix length
    lea     r13, [num_buf]
    mov     rbx, rax
    mov     rcx, r12
.num_loop:
    test    rcx, rcx
    jz      .num_done
    dec     rcx
    xor     edx, edx
    mov     r8, 10
    div     r8
    add     dl, '0'
    mov     [r13 + rcx], dl
    mov     rbx, rax
    jmp     .num_loop
.num_done:
    pop     rdi
    mov     rsi, r13
    mov     rcx, r12
    rep     movsb
.add_additional:
    ; Append additional suffix if set
    cmp     qword [add_suffix_len], 0
    je      .null_term
    mov     rsi, add_suffix
    mov     rcx, [add_suffix_len]
    rep     movsb
.null_term:
    mov     byte [rdi], 0
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── Build filename for the *current* file_index (for unlink after increment) ──
build_filename_for_current:
    ; file_index was already incremented, so we need file_index - 1
    ; But actually at this point file_index points to next file
    ; We decrement, build, then re-increment
    dec     qword [file_index]
    call    build_filename
    inc     qword [file_index]
    ret

; ── Print verbose message ──
print_verbose:
    push    rbx
    ; "creating file 'FILENAME'\n"
    mov     rdi, verbose_buf
    mov     rsi, str_creating
    mov     ecx, str_creating_len
    rep     movsb
    ; Copy filename
    mov     rsi, fname_buf
.copy_fn:
    lodsb
    test    al, al
    jz      .fn_done
    stosb
    jmp     .copy_fn
.fn_done:
    mov     byte [rdi], 0x27    ; closing quote
    inc     rdi
    mov     byte [rdi], 10      ; newline
    inc     rdi
    ; Write to stderr
    mov     rsi, verbose_buf
    mov     rdx, rdi
    sub     rdx, rsi
    mov     rdi, STDERR
    mov     rax, SYS_WRITE
    syscall
    pop     rbx
    ret

; ── String comparison ──
strcmp:
.loop:
    movzx eax, byte [rdi]
    movzx ecx, byte [rsi]
    cmp al, cl
    jne .diff
    test al, al
    jz .eq
    inc rdi
    inc rsi
    jmp .loop
.eq: xor eax, eax
    ret
.diff: mov eax, 1
    ret

; ── String comparison (first n chars) ──
strncmp:
    ; rdi = str1, rsi = str2, ecx = n
    push    rbx
    mov     ebx, ecx
.loop:
    test    ebx, ebx
    jz      .eq
    movzx   eax, byte [rdi]
    movzx   edx, byte [rsi]
    cmp     al, dl
    jne     .diff
    inc     rdi
    inc     rsi
    dec     ebx
    jmp     .loop
.eq:
    xor     eax, eax
    pop     rbx
    ret
.diff:
    mov     eax, 1
    pop     rbx
    ret

; ── String length ──
strlen:
    xor eax, eax
.loop:
    cmp byte [rdi + rax], 0
    je .done
    inc rax
    jmp .loop
.done: ret

; ── Parse decimal number ──
parse_number:
    ; rdi = string
    ; returns rax = number
    xor     rax, rax
.loop:
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .done
    cmp     cl, '0'
    jl      .done
    cmp     cl, '9'
    jg      .done
    imul    rax, 10
    sub     cl, '0'
    movzx   ecx, cl
    add     rax, rcx
    inc     rdi
    jmp     .loop
.done:
    ret

; ── Parse size with suffix (K, M, G, KB, MB, GB) ──
parse_size:
    ; rdi = string like "100", "1K", "10M", "1G"
    call    parse_number
    ; Check suffix
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .done
    cmp     cl, 'K'
    je      .kilo
    cmp     cl, 'k'
    je      .kilo
    cmp     cl, 'M'
    je      .mega
    cmp     cl, 'm'
    je      .mega
    cmp     cl, 'G'
    je      .giga
    cmp     cl, 'g'
    je      .giga
    jmp     .done
.kilo:
    shl     rax, 10         ; * 1024
    jmp     .done
.mega:
    shl     rax, 20         ; * 1048576
    jmp     .done
.giga:
    shl     rax, 30         ; * 1073741824
.done:
    ret

; ── Write all bytes (EINTR-safe) ──
write_all:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
.loop:
    test r13, r13
    jle .done
    mov rax, SYS_WRITE
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    syscall
    cmp rax, -EINTR
    je .loop
    test rax, rax
    js .done
    add r12, rax
    sub r13, rax
    jmp .loop
.done:
    pop r13
    pop r12
    pop rbx
    ret

; ════════════════════════════════════════════════════════════════
; DATA SECTION
; ════════════════════════════════════════════════════════════════

str_default_prefix: db "x", 0
str_nl: db 10

s_help: db "help", 0
s_version: db "version", 0
s_verbose: db "verbose", 0
s_numeric: db "numeric-suffixes", 0
s_elide: db "elide-empty-files", 0
s_lines: db "lines", 0
s_lines_eq: db "lines=", 0
s_bytes_eq: db "bytes=", 0
s_suffix_length_eq: db "suffix-length=", 0
s_additional_suffix_eq: db "additional-suffix=", 0

str_creating: db "creating file '", 0
str_creating_len equ $ - str_creating - 1

err_prefix: db "split: "
err_prefix_len equ $ - err_prefix
err_open: db ": cannot open for reading: No such file or directory", 10
err_open_len equ $ - err_open
err_create: db "cannot open '"
err_create_len equ $ - err_create
err_read: db "read error", 10
err_read_len equ $ - err_read
err_invalid_opt: db "invalid option -- '"
err_invalid_opt_len equ $ - err_invalid_opt
err_unrec: db "unrecognized option '"
err_unrec_len equ $ - err_unrec
err_quote_nl: db 0x27, 10
err_quote_nl_len equ $ - err_quote_nl
err_missing: db "option requires an argument", 10
err_missing_len equ $ - err_missing

; @@DATA_START@@
str_help:
    db "Usage: split [OPTION]... [FILE [PREFIX]]", 10
    db "Output pieces of FILE to PREFIXaa, PREFIXab, ...;", 10
    db "default size is 1000 lines, and default PREFIX is 'x'.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -a, --suffix-length=N   generate suffixes of length N (default 2)", 10
    db "  -b, --bytes=SIZE        put SIZE bytes per output file", 10
    db "  -d                      use numeric suffixes starting at 0, not alphabetic", 10
    db "      --numeric-suffixes[=FROM]  same as -d, but allow setting the start value", 10
    db "  -e, --elide-empty-files  do not generate empty output files with '-n'", 10
    db "  -l, --lines=NUMBER      put NUMBER lines/records per output file", 10
    db "      --additional-suffix=SUFFIX  append an additional SUFFIX to file names", 10
    db "      --verbose           print a diagnostic just before each", 10
    db "                            output file is opened", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "The SIZE argument is an integer and optional unit (example: 10K is 10*1024).", 10
    db "Units are K,M,G,T,P,E,Z,Y,R,Q (powers of 1024).", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/split>", 10
    db "or available locally via: info '(coreutils) split invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "split (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Torbjorn Granlund and Richard M. Stallman.", 10
str_version_len equ $ - str_version
; @@DATA_END@@

file_end:
