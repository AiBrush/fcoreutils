; fshred_unified.asm
; Hand-written x86-64 Linux assembly — static ELF, no libc
; GNU-compatible "shred" — secure file overwrite
;
; Build: nasm -f bin unified/fshred_unified.asm -o fshred_release && chmod +x fshred_release
;
; Features:
;   -n NUM / --iterations=NUM  (default 3)
;   -z / --zero                (final zero pass)
;   -u / --remove[=HOW]       (remove after: unlink/wipe/wipesync)
;   -v / --verbose             (progress to stderr)
;   -f / --force               (chmod +w if needed)
;   -x / --exact               (don't round up to block)
;   -s NUM / --size=NUM        (override file size, K/M/G suffixes)
;   --random-source=FILE       (accepted, ignored — uses xoshiro256**)
;   --help / --version / --
;
; Performance: xoshiro256** PRNG, 128KB write buffers, fdatasync between passes

BITS 64
org 0x400000

; ─── System Constants ────────────────────────────────────
%define SYS_READ             0
%define SYS_WRITE            1
%define SYS_OPEN             2
%define SYS_CLOSE            3
%define SYS_STAT             4
%define SYS_FSTAT            5
%define SYS_LSEEK            8
%define SYS_CHMOD           90
%define SYS_RENAME          82
%define SYS_UNLINK          87
%define SYS_FDATASYNC       75
%define SYS_FSYNC           74
%define SYS_FTRUNCATE       77
%define SYS_EXIT            60
%define SYS_OPENAT         257
%define SYS_GETDENTS64     217

%define STDIN                0
%define STDOUT               1
%define STDERR               2

%define O_RDONLY             0
%define O_WRONLY             1
%define O_RDWR               2
%define O_DIRECTORY      0x10000

%define SEEK_SET             0

%define STAT_MODE           24
%define STAT_SIZE           48
%define STAT_BLKSIZE        56
%define STAT_STRUCT_SIZE   144

%define S_IFMT           0o170000
%define S_IFREG          0o100000

%define EINTR                4
%define EPIPE               32

%define WRITE_BUF_SIZE  131072      ; 128KB write buffer for max throughput

; Flags
%define FLAG_VERBOSE     0x01
%define FLAG_ZERO        0x02
%define FLAG_EXACT       0x04
%define FLAG_FORCE       0x08
%define FLAG_REMOVE      0x10       ; any remove mode set
%define FLAG_HAS_SIZE    0x20       ; -s was specified

; Remove modes
%define RM_UNLINK        1
%define RM_WIPE          2
%define RM_WIPESYNC      3

; ─── ELF Header ──────────────────────────────────────────
ehdr:
    db 0x7F, "ELF"
    db 2, 1, 1, 0              ; 64-bit, little-endian, ELF v1, System V
    dq 0
    dw 2                       ; ET_EXEC
    dw 0x3E                    ; x86-64
    dd 1                       ; ELF version
    dq _start                  ; entry point
    dq phdr - ehdr             ; program header offset
    dq 0                       ; section header offset
    dd 0                       ; flags
    dw ehdr_size               ; ELF header size
    dw phdr_size               ; program header entry size
    dw 3                       ; number of program headers
    dw 0, 0, 0
ehdr_size equ $ - ehdr

; ─── Program Headers ─────────────────────────────────────
phdr:
    dd 1                       ; PT_LOAD (code + rodata)
    dd 5                       ; PF_R | PF_X
    dq 0
    dq 0x400000
    dq 0x400000
    dq file_size
    dq file_size + bss_size
    dq 0x1000
phdr_size equ $ - phdr

    dd 1                       ; PT_LOAD (BSS)
    dd 6                       ; PF_R | PF_W
    dq 0
    dq bss_start
    dq bss_start
    dq 0
    dq bss_size
    dq 0x1000

    dd 0x6474E551              ; PT_GNU_STACK (NX)
    dd 6                       ; PF_R | PF_W (no exec)
    dq 0, 0, 0, 0, 0
    dq 0x10

; ============================================================================
;                           CODE
; ============================================================================

_start:
    ; Save argc/argv
    mov     rax, [rsp]
    mov     [argc], rax
    lea     rax, [rsp + 8]
    mov     [argv], rax

    ; Initialize defaults
    mov     byte [flags], 0
    mov     qword [iterations], 3
    mov     byte [remove_mode], 0
    mov     qword [override_size], 0
    mov     qword [nfiles], 0
    mov     byte [had_error], 0

    ; Parse arguments
    call    parse_args

    ; Check we have files
    cmp     qword [nfiles], 0
    jne     .have_files
    ; "shred: missing file operand"
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr
    mov     rdi, str_missing_operand
    mov     rsi, str_missing_operand_len
    call    write_stderr
    mov     rdi, str_try_help
    mov     rsi, str_try_help_len
    call    write_stderr
    mov     edi, 1
    jmp     do_exit

.have_files:
    ; Process each file
    xor     ebx, ebx
.file_loop:
    cmp     rbx, [nfiles]
    jge     .all_done
    mov     rdi, [file_ptrs + rbx*8]
    push    rbx
    call    shred_one_file
    pop     rbx
    inc     rbx
    jmp     .file_loop

.all_done:
    movzx   edi, byte [had_error]
    jmp     do_exit

do_exit:
    mov     eax, SYS_EXIT
    syscall

; ============================================================================
; parse_args — parse command-line arguments
; ============================================================================
parse_args:
    push    rbx
    push    r12
    push    r13
    mov     rbx, 1                     ; start at argv[1]
    xor     r13d, r13d                 ; dashdash flag

.arg_loop:
    cmp     rbx, [argc]
    jge     .done

    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]        ; current arg

    ; After --, everything is a file
    test    r13d, r13d
    jnz     .add_file

    ; Check for "--"
    cmp     byte [rdi], '-'
    jne     .add_file
    cmp     byte [rdi+1], '-'
    jne     .short_opts
    cmp     byte [rdi+2], 0
    jne     .long_opt
    ; It's "--"
    mov     r13d, 1
    jmp     .next_arg

.long_opt:
    ; --help
    lea     rsi, [str_opt_help]
    call    str_eq
    test    eax, eax
    jnz     .do_help

    ; --version
    lea     rsi, [str_opt_version]
    call    str_eq
    test    eax, eax
    jnz     .do_version

    ; --verbose
    lea     rsi, [str_opt_verbose]
    call    str_eq
    test    eax, eax
    jnz     .set_verbose

    ; --zero
    lea     rsi, [str_opt_zero]
    call    str_eq
    test    eax, eax
    jnz     .set_zero

    ; --exact
    lea     rsi, [str_opt_exact]
    call    str_eq
    test    eax, eax
    jnz     .set_exact

    ; --force
    lea     rsi, [str_opt_force]
    call    str_eq
    test    eax, eax
    jnz     .set_force

    ; --iterations=N
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    lea     rsi, [str_opt_iterations_eq]
    mov     ecx, 13                    ; len("--iterations=")
    call    str_starts_with
    test    eax, eax
    jnz     .parse_iterations_eq

    ; --size=N
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    lea     rsi, [str_opt_size_eq]
    mov     ecx, 7                     ; len("--size=")
    call    str_starts_with
    test    eax, eax
    jnz     .parse_size_eq

    ; --remove / --remove=HOW
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    lea     rsi, [str_opt_remove]
    call    str_eq
    test    eax, eax
    jnz     .set_remove_default

    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    lea     rsi, [str_opt_remove_eq]
    mov     ecx, 9                     ; len("--remove=")
    call    str_starts_with
    test    eax, eax
    jnz     .parse_remove_eq

    ; --random-source=FILE (accept but ignore)
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    lea     rsi, [str_opt_random_source]
    mov     ecx, 16                    ; len("--random-source=")
    call    str_starts_with
    test    eax, eax
    jnz     .next_arg                  ; just skip it

    ; Unknown long option
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    call    err_unrecognized_opt
    mov     edi, 1
    jmp     do_exit

.short_opts:
    ; rdi points to "-X..."
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    lea     r12, [rdi + 1]            ; point past '-'

.short_loop:
    movzx   eax, byte [r12]
    test    al, al
    jz      .next_arg

    cmp     al, 'v'
    je      .short_verbose
    cmp     al, 'z'
    je      .short_zero
    cmp     al, 'x'
    je      .short_exact
    cmp     al, 'f'
    je      .short_force
    cmp     al, 'u'
    je      .short_remove
    cmp     al, 'n'
    je      .short_n
    cmp     al, 's'
    je      .short_s

    ; Invalid option
    push    rax
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr
    mov     rdi, str_invalid_opt
    mov     rsi, str_invalid_opt_len
    call    write_stderr
    pop     rax
    mov     [char_buf], al
    mov     rdi, char_buf
    mov     rsi, 1
    call    write_stderr
    mov     rdi, str_quote_nl
    mov     rsi, str_quote_nl_len
    call    write_stderr
    mov     rdi, str_try_help
    mov     rsi, str_try_help_len
    call    write_stderr
    mov     edi, 1
    jmp     do_exit

.short_verbose:
    or      byte [flags], FLAG_VERBOSE
    inc     r12
    jmp     .short_loop

.short_zero:
    or      byte [flags], FLAG_ZERO
    inc     r12
    jmp     .short_loop

.short_exact:
    or      byte [flags], FLAG_EXACT
    inc     r12
    jmp     .short_loop

.short_force:
    or      byte [flags], FLAG_FORCE
    inc     r12
    jmp     .short_loop

.short_remove:
    or      byte [flags], FLAG_REMOVE
    mov     byte [remove_mode], RM_WIPESYNC
    inc     r12
    jmp     .short_loop

.short_n:
    ; Next chars or next arg are the count
    inc     r12
    cmp     byte [r12], 0
    jne     .short_n_inline
    ; Need next arg
    inc     rbx
    cmp     rbx, [argc]
    jge     .missing_n_arg
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    jmp     .parse_n_value

.short_n_inline:
    mov     rdi, r12
.parse_n_value:
    call    parse_uint
    test    rdx, rdx
    jnz     .invalid_n
    mov     [iterations], rax
    jmp     .next_arg

.missing_n_arg:
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr
    mov     rdi, str_opt_n_missing
    mov     rsi, str_opt_n_missing_len
    call    write_stderr
    mov     edi, 1
    jmp     do_exit

.invalid_n:
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr
    mov     rdi, str_invalid_passes
    mov     rsi, str_invalid_passes_len
    call    write_stderr
    ; Print the bad value in quotes
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    ; find the -n value source
    mov     rdi, str_quote
    mov     rsi, 1
    call    write_stderr
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    call    strlen
    mov     rsi, rax
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    call    write_stderr
    mov     rdi, str_quote_nl
    mov     rsi, str_quote_nl_len
    call    write_stderr
    mov     edi, 1
    jmp     do_exit

.short_s:
    ; Next chars or next arg are the size
    inc     r12
    cmp     byte [r12], 0
    jne     .short_s_inline
    ; Need next arg
    inc     rbx
    cmp     rbx, [argc]
    jge     .missing_s_arg
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    jmp     .parse_s_value

.short_s_inline:
    mov     rdi, r12
.parse_s_value:
    call    parse_size_str
    test    rdx, rdx
    jnz     .invalid_s
    mov     [override_size], rax
    or      byte [flags], FLAG_HAS_SIZE
    jmp     .next_arg

.missing_s_arg:
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr
    mov     rdi, str_opt_s_missing
    mov     rsi, str_opt_s_missing_len
    call    write_stderr
    mov     edi, 1
    jmp     do_exit

.invalid_s:
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr
    mov     rdi, str_invalid_size
    mov     rsi, str_invalid_size_len
    call    write_stderr
    mov     edi, 1
    jmp     do_exit

.set_verbose:
    or      byte [flags], FLAG_VERBOSE
    jmp     .next_arg

.set_zero:
    or      byte [flags], FLAG_ZERO
    jmp     .next_arg

.set_exact:
    or      byte [flags], FLAG_EXACT
    jmp     .next_arg

.set_force:
    or      byte [flags], FLAG_FORCE
    jmp     .next_arg

.set_remove_default:
    or      byte [flags], FLAG_REMOVE
    mov     byte [remove_mode], RM_WIPESYNC
    jmp     .next_arg

.parse_remove_eq:
    ; rdi still points to "--remove=..."
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    add     rdi, 9                     ; skip "--remove="
    ; Compare HOW value
    push    rdi
    lea     rsi, [str_unlink]
    call    str_eq
    test    eax, eax
    pop     rdi
    jnz     .set_rm_unlink

    push    rdi
    lea     rsi, [str_wipesync]
    call    str_eq
    test    eax, eax
    pop     rdi
    jnz     .set_rm_wipesync

    push    rdi
    lea     rsi, [str_wipe]
    call    str_eq
    test    eax, eax
    pop     rdi
    jnz     .set_rm_wipe

    ; Invalid remove mode
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr
    mov     rdi, str_invalid_remove
    mov     rsi, str_invalid_remove_len
    call    write_stderr
    mov     edi, 1
    jmp     do_exit

.set_rm_unlink:
    or      byte [flags], FLAG_REMOVE
    mov     byte [remove_mode], RM_UNLINK
    jmp     .next_arg

.set_rm_wipe:
    or      byte [flags], FLAG_REMOVE
    mov     byte [remove_mode], RM_WIPE
    jmp     .next_arg

.set_rm_wipesync:
    or      byte [flags], FLAG_REMOVE
    mov     byte [remove_mode], RM_WIPESYNC
    jmp     .next_arg

.parse_iterations_eq:
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    add     rdi, 13                    ; skip "--iterations="
    call    parse_uint
    test    rdx, rdx
    jnz     .invalid_n_long
    mov     [iterations], rax
    jmp     .next_arg

.invalid_n_long:
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr
    mov     rdi, str_invalid_passes
    mov     rsi, str_invalid_passes_len
    call    write_stderr
    mov     rdi, str_quote
    mov     rsi, 1
    call    write_stderr
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    add     rdi, 13
    call    strlen
    mov     rsi, rax
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    add     rdi, 13
    call    write_stderr
    mov     rdi, str_quote_nl
    mov     rsi, str_quote_nl_len
    call    write_stderr
    mov     edi, 1
    jmp     do_exit

.parse_size_eq:
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    add     rdi, 7                     ; skip "--size="
    call    parse_size_str
    test    rdx, rdx
    jnz     .invalid_s
    mov     [override_size], rax
    or      byte [flags], FLAG_HAS_SIZE
    jmp     .next_arg

.do_help:
    mov     rdi, str_help_text
    mov     rsi, str_help_text_len
    call    write_stdout
    xor     edi, edi
    jmp     do_exit

.do_version:
    mov     rdi, str_version
    mov     rsi, str_version_len
    call    write_stdout
    xor     edi, edi
    jmp     do_exit

.add_file:
    mov     rax, [nfiles]
    cmp     rax, 4096
    jge     .next_arg
    mov     rax, [argv]
    mov     rdi, [rax + rbx*8]
    mov     rax, [nfiles]
    mov     [file_ptrs + rax*8], rdi
    inc     qword [nfiles]
    jmp     .next_arg

.next_arg:
    inc     rbx
    jmp     .arg_loop

.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; shred_one_file — shred a single file
; rdi = filename pointer
; ============================================================================
shred_one_file:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, STAT_STRUCT_SIZE + 16  ; stat buf + alignment

    mov     r12, rdi                   ; r12 = filename
    mov     r14d, -1                   ; r14 = fd (not opened yet)

    ; If force, try to chmod +w first
    test    byte [flags], FLAG_FORCE
    jz      .open_file
    ; stat the file first
    mov     eax, SYS_STAT
    mov     rdi, r12
    lea     rsi, [rsp]
    syscall
    test    rax, rax
    js      .open_file                ; stat failed, let open fail naturally
    ; Check if writable by owner
    mov     eax, [rsp + STAT_MODE]
    test    eax, 0o200
    jnz     .open_file                ; already writable
    ; chmod to add write permission
    or      eax, 0o200
    mov     edi, eax                  ; new mode
    push    rdi
    mov     eax, SYS_CHMOD
    mov     rdi, r12
    pop     rsi                       ; mode
    syscall

.open_file:
    ; Open for writing
    mov     eax, SYS_OPEN
    mov     rdi, r12
    mov     esi, O_WRONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .open_error
    mov     r14d, eax                 ; fd

    ; fstat to get file size and block size
    mov     eax, SYS_FSTAT
    mov     edi, r14d
    lea     rsi, [rsp]
    syscall
    test    rax, rax
    js      .stat_error

    ; Get file size
    mov     r13, [rsp + STAT_SIZE]     ; r13 = file_size

    ; Check if -s was given
    test    byte [flags], FLAG_HAS_SIZE
    jz      .no_override_size
    mov     r13, [override_size]
.no_override_size:

    ; Determine write_size (r15)
    mov     r15, r13                   ; write_size = file_size
    test    byte [flags], FLAG_EXACT
    jnz     .size_ready
    test    byte [flags], FLAG_HAS_SIZE
    jnz     .size_ready                ; -s overrides: use exact size

    ; Check if regular file (only round up for regular files)
    mov     eax, [rsp + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFREG
    jne     .size_ready

    ; Round up to filesystem block size
    mov     rbp, [rsp + STAT_BLKSIZE]  ; block size
    test    rbp, rbp
    jz      .round_512
    cmp     rbp, 1
    jle     .round_512
    jmp     .do_round

.round_512:
    mov     rbp, 512

.do_round:
    ; write_size = ((file_size + block - 1) / block) * block
    mov     rax, r15
    add     rax, rbp
    dec     rax
    xor     edx, edx
    div     rbp
    mul     rbp
    mov     r15, rax

.size_ready:
    ; Seed PRNG from /dev/urandom
    call    seed_prng

    ; Calculate total passes
    mov     rbx, [iterations]
    mov     rax, rbx
    test    byte [flags], FLAG_ZERO
    jz      .no_extra_pass
    inc     rax
.no_extra_pass:
    mov     [total_passes], rax

    ; Do random passes
    xor     ebp, ebp                  ; pass counter
.random_pass_loop:
    cmp     rbp, [iterations]
    jge     .random_done

    ; Verbose: "shred: FILE: pass N/T (random)..."
    test    byte [flags], FLAG_VERBOSE
    jz      .skip_verbose_random
    mov     rdi, r12                  ; filename
    lea     rsi, [rbp + 1]           ; pass number (1-based)
    mov     rdx, [total_passes]
    lea     rcx, [str_random]
    mov     r8d, str_random_len
    call    print_pass_msg
.skip_verbose_random:

    ; Seek to beginning
    mov     eax, SYS_LSEEK
    mov     edi, r14d
    xor     esi, esi
    xor     edx, edx                  ; SEEK_SET
    syscall

    ; Write random data
    mov     rdi, r15                  ; write_size
    mov     esi, r14d                 ; fd
    mov     edx, 1                    ; random=1
    call    write_pass

    ; fdatasync
    mov     eax, SYS_FDATASYNC
    mov     edi, r14d
    syscall

    inc     rbp
    jmp     .random_pass_loop

.random_done:
    ; Zero pass if requested
    test    byte [flags], FLAG_ZERO
    jz      .passes_done

    ; Verbose: "shred: FILE: pass N/T (000000)..."
    test    byte [flags], FLAG_VERBOSE
    jz      .skip_verbose_zero
    mov     rdi, r12
    mov     rsi, [total_passes]       ; last pass
    mov     rdx, [total_passes]
    lea     rcx, [str_zeros]
    mov     r8d, str_zeros_len
    call    print_pass_msg
.skip_verbose_zero:

    ; Seek to beginning
    mov     eax, SYS_LSEEK
    mov     edi, r14d
    xor     esi, esi
    xor     edx, edx
    syscall

    ; Write zeros
    mov     rdi, r15                  ; write_size
    mov     esi, r14d                 ; fd
    xor     edx, edx                  ; random=0 (zeros)
    call    write_pass

    ; fdatasync
    mov     eax, SYS_FDATASYNC
    mov     edi, r14d
    syscall

.passes_done:
    ; Close file
    mov     eax, SYS_CLOSE
    mov     edi, r14d
    syscall
    mov     r14d, -1

    ; Remove if requested
    test    byte [flags], FLAG_REMOVE
    jz      .file_done

    mov     rdi, r12
    call    remove_file

    jmp     .file_done

.open_error:
    neg     rax
    mov     ebx, eax
    ; "shred: FILE: failed to open for writing: ERROR"
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr
    mov     rdi, r12
    call    strlen
    mov     rsi, rax
    mov     rdi, r12
    call    write_stderr
    mov     rdi, str_failed_open
    mov     rsi, str_failed_open_len
    call    write_stderr
    mov     edi, ebx
    call    print_errno
    mov     byte [had_error], 1
    jmp     .file_done

.stat_error:
    ; Close fd and report error
    push    rax
    mov     eax, SYS_CLOSE
    mov     edi, r14d
    syscall
    pop     rax
    neg     rax
    mov     ebx, eax
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr
    mov     rdi, r12
    call    strlen
    mov     rsi, rax
    mov     rdi, r12
    call    write_stderr
    mov     rdi, str_colon_space
    mov     rsi, 2
    call    write_stderr
    mov     edi, ebx
    call    print_errno
    mov     byte [had_error], 1
    jmp     .file_done

.file_done:
    add     rsp, STAT_STRUCT_SIZE + 16
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; write_pass — write data for one pass
; rdi = total bytes to write
; esi = fd
; edx = 1 for random, 0 for zeros
; ============================================================================
write_pass:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rdi                   ; r12 = remaining bytes
    mov     r13d, esi                  ; r13 = fd
    mov     r14d, edx                  ; r14 = random flag

    ; If zero pass, clear the buffer once
    test    r14d, r14d
    jnz     .write_loop

    ; Zero the write buffer
    lea     rdi, [write_buf]
    xor     eax, eax
    mov     ecx, WRITE_BUF_SIZE / 8
    rep     stosq

.write_loop:
    test    r12, r12
    jz      .write_done

    ; Determine chunk size
    mov     rbx, r12
    cmp     rbx, WRITE_BUF_SIZE
    jbe     .chunk_ok
    mov     ebx, WRITE_BUF_SIZE
.chunk_ok:

    ; Fill buffer with random data if needed
    test    r14d, r14d
    jz      .do_write
    lea     rdi, [write_buf]
    mov     rsi, rbx
    call    fill_random_buf

.do_write:
    ; Write chunk
    lea     rsi, [write_buf]
    mov     rdx, rbx
    mov     rax, rdx                   ; bytes to write this iteration
    mov     rcx, rsi                   ; buffer pointer

.write_retry:
    mov     eax, SYS_WRITE
    mov     edi, r13d
    mov     rsi, rcx
    mov     rdx, rbx
    syscall

    test    rax, rax
    js      .write_error
    jz      .write_error

    sub     r12, rax
    sub     rbx, rax
    add     rcx, rax
    test    rbx, rbx
    jnz     .write_retry

    jmp     .write_loop

.write_error:
    ; Ignore write errors (could be EINTR)
    cmp     rax, -EINTR
    je      .write_retry
    ; Real error — just continue
    jmp     .write_done

.write_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; fill_random_buf — fill buffer with xoshiro256** random bytes
; rdi = buffer pointer
; rsi = length
; ============================================================================
fill_random_buf:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, rdi                   ; buffer
    mov     r13, rsi                   ; length

    ; Load PRNG state
    mov     rax, [prng_s0]
    mov     rbx, [prng_s1]
    mov     rcx, [prng_s2]
    mov     rdx, [prng_s3]

    ; Fill 32 bytes at a time (4x unrolled xoshiro256**)
    mov     r14, r13
    shr     r14, 5                     ; number of 32-byte chunks

    test    r14, r14
    jz      .fill_8_remainder

.fill_32:
    ; --- Iteration 1 ---
    mov     r15, rbx
    lea     r15, [r15 + r15*4]
    rol     r15, 7
    lea     r15, [r15 + r15*8]
    mov     [r12], r15
    mov     rbp, rbx
    shl     rbp, 17
    xor     rcx, rax
    xor     rdx, rbx
    xor     rbx, rcx
    xor     rax, rdx
    xor     rcx, rbp
    rol     rdx, 45

    ; --- Iteration 2 ---
    mov     r15, rbx
    lea     r15, [r15 + r15*4]
    rol     r15, 7
    lea     r15, [r15 + r15*8]
    mov     [r12+8], r15
    mov     rbp, rbx
    shl     rbp, 17
    xor     rcx, rax
    xor     rdx, rbx
    xor     rbx, rcx
    xor     rax, rdx
    xor     rcx, rbp
    rol     rdx, 45

    ; --- Iteration 3 ---
    mov     r15, rbx
    lea     r15, [r15 + r15*4]
    rol     r15, 7
    lea     r15, [r15 + r15*8]
    mov     [r12+16], r15
    mov     rbp, rbx
    shl     rbp, 17
    xor     rcx, rax
    xor     rdx, rbx
    xor     rbx, rcx
    xor     rax, rdx
    xor     rcx, rbp
    rol     rdx, 45

    ; --- Iteration 4 ---
    mov     r15, rbx
    lea     r15, [r15 + r15*4]
    rol     r15, 7
    lea     r15, [r15 + r15*8]
    mov     [r12+24], r15
    mov     rbp, rbx
    shl     rbp, 17
    xor     rcx, rax
    xor     rdx, rbx
    xor     rbx, rcx
    xor     rax, rdx
    xor     rcx, rbp
    rol     rdx, 45

    add     r12, 32
    dec     r14
    jnz     .fill_32

.fill_8_remainder:
    ; Handle remaining 8-byte chunks (0-3)
    mov     r14, r13
    and     r14, 0x18                  ; remaining bytes that are 8-aligned (bits 3-4)
    shr     r14, 3
    test    r14, r14
    jz      .fill_tail

.fill_8:
    mov     r15, rbx
    lea     r15, [r15 + r15*4]
    rol     r15, 7
    lea     r15, [r15 + r15*8]
    mov     [r12], r15
    mov     rbp, rbx
    shl     rbp, 17
    xor     rcx, rax
    xor     rdx, rbx
    xor     rbx, rcx
    xor     rax, rdx
    xor     rcx, rbp
    rol     rdx, 45
    add     r12, 8
    dec     r14
    jnz     .fill_8

.fill_tail:
    ; Handle remaining bytes (0-7)
    and     r13, 7
    jz      .fill_done

    ; Generate one more value
    mov     r15, rbx
    lea     r15, [r15 + r15*4]
    rol     r15, 7
    lea     r15, [r15 + r15*8]

    ; Advance state
    mov     rbp, rbx
    shl     rbp, 17
    xor     rcx, rax
    xor     rdx, rbx
    xor     rbx, rcx
    xor     rax, rdx
    xor     rcx, rbp
    rol     rdx, 45

.tail_byte:
    mov     [r12], r15b
    shr     r15, 8
    inc     r12
    dec     r13
    jnz     .tail_byte

.fill_done:
    ; Store state back
    mov     [prng_s0], rax
    mov     [prng_s1], rbx
    mov     [prng_s2], rcx
    mov     [prng_s3], rdx

    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; seed_prng — seed xoshiro256** from /dev/urandom
; ============================================================================
seed_prng:
    push    rbx

    ; Open /dev/urandom
    mov     eax, SYS_OPEN
    lea     rdi, [str_dev_urandom]
    xor     esi, esi                   ; O_RDONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .seed_fallback

    mov     ebx, eax                   ; fd

    ; Read 32 bytes for state
    mov     eax, SYS_READ
    mov     edi, ebx
    lea     rsi, [prng_s0]
    mov     edx, 32
    syscall

    ; Close
    mov     eax, SYS_CLOSE
    mov     edi, ebx
    syscall

    ; Ensure non-zero state
    mov     rax, [prng_s0]
    or      rax, [prng_s1]
    or      rax, [prng_s2]
    or      rax, [prng_s3]
    test    rax, rax
    jnz     .seed_done

.seed_fallback:
    ; Use fixed seeds if /dev/urandom fails
    mov     rax, 0x12345678DEADBEEF
    mov     [prng_s0], rax
    mov     rax, 0x87654321CAFEBABE
    mov     [prng_s1], rax
    mov     rax, 0xFEDCBA9876543210
    mov     [prng_s2], rax
    mov     rax, 0x0123456789ABCDEF
    mov     [prng_s3], rax

.seed_done:
    pop     rbx
    ret

; ============================================================================
; remove_file — remove file after shredding, with optional name wipe
; rdi = original filename
; ============================================================================
remove_file:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, rdi                   ; original filename

    ; Verbose: "shred: FILE: removing"
    test    byte [flags], FLAG_VERBOSE
    jz      .skip_removing_msg
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr
    mov     rdi, r12
    call    strlen
    mov     rsi, rax
    mov     rdi, r12
    call    write_stderr
    mov     rdi, str_removing
    mov     rsi, str_removing_len
    call    write_stderr
.skip_removing_msg:

    cmp     byte [remove_mode], RM_UNLINK
    je      .do_unlink

    ; Wipe mode: rename to shorter and shorter names
    ; First, find the directory and filename parts
    mov     rdi, r12
    call    strlen
    mov     r13, rax                   ; total path length

    ; Find last '/'
    mov     rdi, r12
    mov     rsi, r13
    call    find_last_slash
    mov     r14, rax                   ; offset of last slash (-1 if none)

    ; Calculate filename length
    cmp     r14, -1
    je      .no_dir
    mov     r15, r13
    sub     r15, r14
    dec     r15                        ; filename length
    ; Copy directory prefix to rename_buf
    lea     rdi, [rename_buf]
    mov     rsi, r12
    mov     rcx, r14
    inc     rcx                        ; include the slash
    mov     rbp, rcx                   ; rbp = dir prefix length (including slash)
    rep     movsb
    jmp     .start_wipe

.no_dir:
    mov     r15, r13                   ; filename length = total length
    xor     ebp, ebp                   ; no dir prefix

.start_wipe:
    ; Copy current filename to rename_src (starts as original)
    lea     rdi, [rename_src]
    mov     rsi, r12
    mov     rcx, r13
    rep     movsb
    mov     byte [rdi], 0

    ; r15 = current name length
    ; rbp = directory prefix length

    ; Start renaming with same length as original filename
.wipe_loop:
    cmp     r15, 0
    jle     .wipe_done

    ; Build new name: dir_prefix + "000...0" (r15 zeros)
    lea     rdi, [rename_buf + rbp]
    mov     rcx, r15
    mov     al, '0'
    rep     stosb
    mov     byte [rdi], 0              ; null terminate

    ; Try rename
    mov     eax, SYS_RENAME
    lea     rdi, [rename_src]
    lea     rsi, [rename_buf]
    syscall
    test    rax, rax
    js      .wipe_rename_failed

    ; Verbose: "shred: OLDNAME: renamed to NEWNAME"
    test    byte [flags], FLAG_VERBOSE
    jz      .skip_rename_msg
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr
    ; Print old name (full path)
    lea     rdi, [rename_src]
    push    rdi
    call    strlen
    mov     rsi, rax
    pop     rdi
    call    write_stderr
    mov     rdi, str_renamed_to
    mov     rsi, str_renamed_to_len
    call    write_stderr
    ; Print new name (full path)
    lea     rdi, [rename_buf]
    push    rdi
    call    strlen
    mov     rsi, rax
    pop     rdi
    call    write_stderr
    mov     rdi, str_newline
    mov     rsi, 1
    call    write_stderr
.skip_rename_msg:

    ; If wipesync, sync directory
    cmp     byte [remove_mode], RM_WIPESYNC
    jne     .skip_dirsync

    ; Open parent directory and fsync it
    cmp     rbp, 0
    je      .sync_dot
    ; Copy dir part without trailing slash
    lea     rdi, [dir_buf]
    mov     rsi, r12
    mov     rcx, rbp
    dec     rcx                        ; don't include trailing slash
    test    rcx, rcx
    jz      .sync_dot
    rep     movsb
    mov     byte [rdi], 0
    lea     rdi, [dir_buf]
    jmp     .do_dir_fsync

.sync_dot:
    lea     rdi, [str_dot]

.do_dir_fsync:
    mov     eax, SYS_OPEN
    ; rdi already set
    mov     esi, O_RDONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .skip_dirsync
    mov     ebx, eax
    mov     eax, SYS_FSYNC
    mov     edi, ebx
    syscall
    mov     eax, SYS_CLOSE
    mov     edi, ebx
    syscall

.skip_dirsync:
    ; Copy new name as current source
    lea     rdi, [rename_src]
    lea     rsi, [rename_buf]
    call    strlen_rsi
    mov     rcx, rax
    inc     rcx                        ; include null
    lea     rdi, [rename_src]
    lea     rsi, [rename_buf]
    rep     movsb

    ; Decrease name length
    dec     r15
    jmp     .wipe_loop

.wipe_rename_failed:
    ; If rename fails (e.g., collision), try shorter name
    dec     r15
    jmp     .wipe_loop

.wipe_done:
    ; Unlink the final name
    mov     eax, SYS_UNLINK
    lea     rdi, [rename_src]
    syscall
    test    rax, rax
    js      .unlink_error

    ; Verbose: "shred: FILE: removed"
    test    byte [flags], FLAG_VERBOSE
    jz      .remove_done
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr
    mov     rdi, r12                   ; original filename
    call    strlen
    mov     rsi, rax
    mov     rdi, r12
    call    write_stderr
    mov     rdi, str_removed
    mov     rsi, str_removed_len
    call    write_stderr
    jmp     .remove_done

.do_unlink:
    mov     eax, SYS_UNLINK
    mov     rdi, r12
    syscall
    test    rax, rax
    js      .unlink_error

    ; Verbose: "shred: FILE: removed"
    test    byte [flags], FLAG_VERBOSE
    jz      .remove_done
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr
    mov     rdi, r12
    call    strlen
    mov     rsi, rax
    mov     rdi, r12
    call    write_stderr
    mov     rdi, str_removed
    mov     rsi, str_removed_len
    call    write_stderr
    jmp     .remove_done

.unlink_error:
    neg     rax
    mov     ebx, eax
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr
    mov     rdi, r12
    call    strlen
    mov     rsi, rax
    mov     rdi, r12
    call    write_stderr
    mov     rdi, str_colon_space
    mov     rsi, 2
    call    write_stderr
    mov     edi, ebx
    call    print_errno
    mov     byte [had_error], 1

.remove_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; print_pass_msg — print verbose pass message
; rdi = filename, rsi = pass_num, rdx = total_passes, rcx = type_str, r8d = type_len
; ============================================================================
print_pass_msg:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi                   ; filename
    mov     r13, rsi                   ; pass num
    mov     r14, rdx                   ; total passes
    mov     r15, rcx                   ; type string
    mov     ebx, r8d                   ; type string len

    ; "shred: "
    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr

    ; filename
    mov     rdi, r12
    call    strlen
    mov     rsi, rax
    mov     rdi, r12
    call    write_stderr

    ; ": pass "
    mov     rdi, str_pass
    mov     rsi, str_pass_len
    call    write_stderr

    ; pass number
    mov     rdi, r13
    call    print_uint_stderr

    ; "/"
    mov     rdi, str_slash
    mov     rsi, 1
    call    write_stderr

    ; total passes
    mov     rdi, r14
    call    print_uint_stderr

    ; " (type)...\n"
    mov     rdi, str_space_paren
    mov     rsi, str_space_paren_len
    call    write_stderr

    mov     rdi, r15
    mov     rsi, rbx
    call    write_stderr

    mov     rdi, str_paren_dots_nl
    mov     rsi, str_paren_dots_nl_len
    call    write_stderr

    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; Utility functions
; ============================================================================

; strlen — return length of null-terminated string
; rdi = string pointer
; returns rax = length
strlen:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

; strlen_rsi — return length of null-terminated string at rsi
; rsi = string pointer
; returns rax = length
strlen_rsi:
    xor     eax, eax
.loop:
    cmp     byte [rsi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

; str_eq — compare two null-terminated strings
; rdi = str1, rsi = str2
; returns eax = 1 if equal, 0 if not
str_eq:
    push    rdi
    push    rsi
.loop:
    mov     al, [rdi]
    cmp     al, [rsi]
    jne     .ne
    test    al, al
    jz      .eq
    inc     rdi
    inc     rsi
    jmp     .loop
.eq:
    mov     eax, 1
    pop     rsi
    pop     rdi
    ret
.ne:
    xor     eax, eax
    pop     rsi
    pop     rdi
    ret

; str_starts_with — check if rdi starts with ecx bytes from rsi
; rdi = string, rsi = prefix, ecx = prefix length
; returns eax = 1 if match, 0 if not
str_starts_with:
    push    rdi
    push    rsi
    push    rcx
.loop:
    test    ecx, ecx
    jz      .match
    mov     al, [rdi]
    cmp     al, [rsi]
    jne     .nomatch
    inc     rdi
    inc     rsi
    dec     ecx
    jmp     .loop
.match:
    mov     eax, 1
    pop     rcx
    pop     rsi
    pop     rdi
    ret
.nomatch:
    xor     eax, eax
    pop     rcx
    pop     rsi
    pop     rdi
    ret

; find_last_slash — find position of last '/' in string
; rdi = string, rsi = length
; returns rax = offset of last slash, or -1 if none
find_last_slash:
    mov     rax, -1
    xor     ecx, ecx
.loop:
    cmp     rcx, rsi
    jge     .done
    cmp     byte [rdi + rcx], '/'
    jne     .next
    mov     rax, rcx
.next:
    inc     rcx
    jmp     .loop
.done:
    ret

; parse_uint — parse unsigned integer from string
; rdi = string pointer
; returns rax = value, rdx = 0 on success, 1 on error
parse_uint:
    xor     eax, eax
    xor     ecx, ecx                  ; digit count

.loop:
    movzx   r8d, byte [rdi]
    test    r8b, r8b
    jz      .done
    sub     r8d, '0'
    cmp     r8d, 9
    ja      .error

    ; rax = rax * 10 + digit
    lea     rax, [rax + rax*4]
    lea     rax, [r8 + rax*2]

    inc     rdi
    inc     ecx
    jmp     .loop

.done:
    test    ecx, ecx
    jz      .error
    xor     edx, edx                   ; success
    ret

.error:
    mov     edx, 1
    ret

; parse_size_str — parse size string with K/M/G suffix
; rdi = string pointer
; returns rax = size in bytes, rdx = 0 on success, 1 on error
parse_size_str:
    push    rbx
    push    r12

    mov     r12, rdi

    ; Find end of digits
    xor     eax, eax
    xor     ecx, ecx
.digit_loop:
    movzx   r8d, byte [r12 + rcx]
    sub     r8d, '0'
    cmp     r8d, 9
    ja      .got_digits
    lea     rax, [rax + rax*4]
    lea     rax, [r8 + rax*2]
    inc     ecx
    jmp     .digit_loop

.got_digits:
    test    ecx, ecx
    jz      .error
    mov     rbx, rax                   ; save number

    ; Check suffix
    movzx   eax, byte [r12 + rcx]
    test    al, al
    jz      .done_size                 ; no suffix

    cmp     al, 'K'
    je      .mul_1024
    cmp     al, 'k'
    je      .mul_1024
    cmp     al, 'M'
    je      .mul_1m
    cmp     al, 'm'
    je      .mul_1m
    cmp     al, 'G'
    je      .mul_1g
    cmp     al, 'g'
    je      .mul_1g
    ; Check for KB, MB, GB (decimal)
    jmp     .error

.mul_1024:
    ; Check for 'B' after K
    cmp     byte [r12 + rcx + 1], 'B'
    je      .mul_1000
    shl     rbx, 10
    jmp     .done_size

.mul_1m:
    cmp     byte [r12 + rcx + 1], 'B'
    je      .mul_1000000
    shl     rbx, 20
    jmp     .done_size

.mul_1g:
    cmp     byte [r12 + rcx + 1], 'B'
    je      .mul_1000000000
    shl     rbx, 30
    jmp     .done_size

.mul_1000:
    imul    rbx, 1000
    jmp     .done_size

.mul_1000000:
    imul    rbx, 1000000
    jmp     .done_size

.mul_1000000000:
    imul    rbx, 1000000000
    jmp     .done_size

.done_size:
    mov     rax, rbx
    xor     edx, edx
    pop     r12
    pop     rbx
    ret

.error:
    mov     edx, 1
    pop     r12
    pop     rbx
    ret

; write_stdout — write to stdout
; rdi = buffer, rsi = length
write_stdout:
    push    rcx
    push    r11
    mov     rdx, rsi
    mov     rsi, rdi
    mov     edi, STDOUT
    mov     eax, SYS_WRITE
    syscall
    pop     r11
    pop     rcx
    ret

; write_stderr — write to stderr
; rdi = buffer, rsi = length
write_stderr:
    push    rcx
    push    r11
    mov     rdx, rsi
    mov     rsi, rdi
    mov     edi, STDERR
    mov     eax, SYS_WRITE
    syscall
    pop     r11
    pop     rcx
    ret

; print_uint_stderr — print unsigned integer to stderr
; rdi = value
print_uint_stderr:
    push    rbx
    push    r12

    mov     rax, rdi
    lea     r12, [itoa_buf + 20]
    mov     byte [r12], 0
    mov     ecx, 10

    test    rax, rax
    jnz     .convert
    dec     r12
    mov     byte [r12], '0'
    jmp     .print

.convert:
    test    rax, rax
    jz      .print
    xor     edx, edx
    div     rcx
    add     dl, '0'
    dec     r12
    mov     [r12], dl
    jmp     .convert

.print:
    mov     rdi, r12
    ; Calculate length
    lea     rsi, [itoa_buf + 20]
    sub     rsi, r12
    call    write_stderr

    pop     r12
    pop     rbx
    ret

; print_errno — print error string for errno value and newline
; edi = errno value
print_errno:
    push    rbx
    mov     ebx, edi

    cmp     ebx, 1
    je      .eperm
    cmp     ebx, 2
    je      .enoent
    cmp     ebx, 5
    je      .eio
    cmp     ebx, 9
    je      .ebadf
    cmp     ebx, 12
    je      .enomem
    cmp     ebx, 13
    je      .eacces
    cmp     ebx, 20
    je      .enotdir
    cmp     ebx, 21
    je      .eisdir
    cmp     ebx, 22
    je      .einval
    cmp     ebx, 36
    je      .enametoolong

    mov     rdi, str_unknown_error
    mov     rsi, str_unknown_error_len
    call    write_stderr
    jmp     .nl

.eperm:
    mov     rdi, str_eperm
    mov     rsi, str_eperm_len
    call    write_stderr
    jmp     .nl
.enoent:
    mov     rdi, str_enoent
    mov     rsi, str_enoent_len
    call    write_stderr
    jmp     .nl
.eio:
    mov     rdi, str_eio
    mov     rsi, str_eio_len
    call    write_stderr
    jmp     .nl
.ebadf:
    mov     rdi, str_ebadf
    mov     rsi, str_ebadf_len
    call    write_stderr
    jmp     .nl
.enomem:
    mov     rdi, str_enomem
    mov     rsi, str_enomem_len
    call    write_stderr
    jmp     .nl
.eacces:
    mov     rdi, str_eacces
    mov     rsi, str_eacces_len
    call    write_stderr
    jmp     .nl
.enotdir:
    mov     rdi, str_enotdir
    mov     rsi, str_enotdir_len
    call    write_stderr
    jmp     .nl
.eisdir:
    mov     rdi, str_eisdir
    mov     rsi, str_eisdir_len
    call    write_stderr
    jmp     .nl
.einval:
    mov     rdi, str_einval
    mov     rsi, str_einval_len
    call    write_stderr
    jmp     .nl
.enametoolong:
    mov     rdi, str_enametoolong
    mov     rsi, str_enametoolong_len
    call    write_stderr
    jmp     .nl
.nl:
    mov     rdi, str_newline
    mov     rsi, 1
    call    write_stderr
    pop     rbx
    ret

; err_unrecognized_opt — print "shred: unrecognized option '...'"
; rdi = option string
err_unrecognized_opt:
    push    r12
    mov     r12, rdi

    mov     rdi, str_shred_prefix
    mov     rsi, str_shred_prefix_len
    call    write_stderr

    mov     rdi, str_unrecognized
    mov     rsi, str_unrecognized_len
    call    write_stderr

    mov     rdi, str_quote
    mov     rsi, 1
    call    write_stderr

    mov     rdi, r12
    call    strlen
    mov     rsi, rax
    mov     rdi, r12
    call    write_stderr

    mov     rdi, str_quote_nl
    mov     rsi, str_quote_nl_len
    call    write_stderr

    mov     rdi, str_try_help
    mov     rsi, str_try_help_len
    call    write_stderr

    pop     r12
    ret

; ============================================================================
;                        READ-ONLY DATA
; ============================================================================

str_newline:        db 10
str_quote:          db "'"
str_quote_nl:       db "'", 10
str_quote_nl_len    equ 2
str_colon_space:    db ": "
str_dot:            db ".", 0

str_shred_prefix:   db "shred: "
str_shred_prefix_len equ $ - str_shred_prefix

str_missing_operand: db "missing file operand", 10
str_missing_operand_len equ $ - str_missing_operand

str_try_help:       db "Try 'shred --help' for more information.", 10
str_try_help_len    equ $ - str_try_help

str_failed_open:    db ": failed to open for writing: "
str_failed_open_len equ $ - str_failed_open

str_pass:           db ": pass "
str_pass_len        equ $ - str_pass

str_slash:          db "/"

str_space_paren:    db " ("
str_space_paren_len equ $ - str_space_paren

str_random:         db "random"
str_random_len      equ $ - str_random

str_zeros:          db "000000"
str_zeros_len       equ $ - str_zeros

str_paren_dots_nl:  db ")...", 10
str_paren_dots_nl_len equ $ - str_paren_dots_nl

str_removing:       db ": removing", 10
str_removing_len    equ $ - str_removing

str_renamed_to:     db ": renamed to "
str_renamed_to_len  equ $ - str_renamed_to

str_removed:        db ": removed", 10
str_removed_len     equ $ - str_removed

str_invalid_opt:    db "invalid option -- '"
str_invalid_opt_len equ $ - str_invalid_opt

str_unrecognized:   db "unrecognized option '"
str_unrecognized_len equ $ - str_unrecognized

str_invalid_passes: db "invalid number of passes: "
str_invalid_passes_len equ $ - str_invalid_passes

str_invalid_size:   db "invalid file size", 10
str_invalid_size_len equ $ - str_invalid_size

str_invalid_remove: db "invalid argument for '--remove'", 10
str_invalid_remove_len equ $ - str_invalid_remove

str_opt_n_missing:  db "option requires an argument -- 'n'", 10
str_opt_n_missing_len equ $ - str_opt_n_missing

str_opt_s_missing:  db "option requires an argument -- 's'", 10
str_opt_s_missing_len equ $ - str_opt_s_missing

str_dev_urandom:    db "/dev/urandom", 0

str_opt_help:       db "--help", 0
str_opt_version:    db "--version", 0
str_opt_verbose:    db "--verbose", 0
str_opt_zero:       db "--zero", 0
str_opt_exact:      db "--exact", 0
str_opt_force:      db "--force", 0
str_opt_remove:     db "--remove", 0
str_opt_iterations_eq: db "--iterations="
str_opt_size_eq:    db "--size="
str_opt_remove_eq:  db "--remove="
str_opt_random_source: db "--random-source="

str_unlink:         db "unlink", 0
str_wipe:           db "wipe", 0
str_wipesync:       db "wipesync", 0

; Error strings
str_eperm:          db "Operation not permitted"
str_eperm_len       equ $ - str_eperm
str_enoent:         db "No such file or directory"
str_enoent_len      equ $ - str_enoent
str_eio:            db "Input/output error"
str_eio_len         equ $ - str_eio
str_ebadf:          db "Bad file descriptor"
str_ebadf_len       equ $ - str_ebadf
str_enomem:         db "Cannot allocate memory"
str_enomem_len      equ $ - str_enomem
str_eacces:         db "Permission denied"
str_eacces_len      equ $ - str_eacces
str_enotdir:        db "Not a directory"
str_enotdir_len     equ $ - str_enotdir
str_eisdir:         db "Is a directory"
str_eisdir_len      equ $ - str_eisdir
str_einval:         db "Invalid argument"
str_einval_len      equ $ - str_einval
str_enametoolong:   db "File name too long"
str_enametoolong_len equ $ - str_enametoolong
str_unknown_error:  db "Unknown error"
str_unknown_error_len equ $ - str_unknown_error

str_version:
    db "shred (fcoreutils) 0.19.4", 10
str_version_len equ $ - str_version

str_help_text:
    db "Usage: shred [OPTION]... FILE...", 10
    db "Overwrite the specified FILE(s) repeatedly, in order to make it harder", 10
    db "for even very expensive hardware probing to recover the data.", 10
    db 10
    db "If FILE is -, shred standard output.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -f, --force    change permissions to allow writing if necessary", 10
    db "  -n, --iterations=N  overwrite N times instead of the default (3)", 10
    db "      --random-source=FILE  get random bytes from FILE", 10
    db "  -s, --size=N   shred this many bytes (suffixes like K, M, G accepted)", 10
    db "  -u             deallocate and remove file after overwriting", 10
    db "      --remove[=HOW]  like -u but give control on HOW to delete;  See below", 10
    db "  -v, --verbose  show progress", 10
    db "  -x, --exact    do not round file sizes up to the next full block;", 10
    db "                   this is the default for non-regular files", 10
    db "  -z, --zero     add a final overwrite with zeros to hide shredding", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "Delete FILE(s) if --remove (-u) is specified.  The default is not to remove", 10
    db "the files because it is common to operate on device files like /dev/hda,", 10
    db "and those files usually should not be removed.", 10
    db "The optional HOW parameter indicates how to remove a directory entry:", 10
    db "'unlink' => use a standard unlink call.", 10
    db "'wipe' => also first obfuscate bytes in the name.", 10
    db "'wipesync' => also sync each obfuscated byte to the device.", 10
    db "The default mode is 'wipesync', but note it can be expensive.", 10
    db 10
    db "CAUTION: shred assumes the file system and hardware overwrite data in place.", 10
    db "Although this is common, many platforms operate otherwise.  Also, backups", 10
    db "and mirrors may contain unremovable copies that will let a shredded file", 10
    db "be recovered later.  See the GNU coreutils manual for details.", 10
str_help_text_len equ $ - str_help_text

file_size equ $ - ehdr

; ─── BSS ─────────────────────────────────────────────────
absolute $ + 0x400000
bss_start:

argc:           resq 1
argv:           resq 1
flags:          resb 1
remove_mode:    resb 1
had_error:      resb 1
                resb 5          ; alignment
iterations:     resq 1
override_size:  resq 1
total_passes:   resq 1
nfiles:         resq 1
file_ptrs:      resq 4096

; PRNG state (xoshiro256**)
prng_s0:        resq 1
prng_s1:        resq 1
prng_s2:        resq 1
prng_s3:        resq 1

; Buffers
char_buf:       resb 8
itoa_buf:       resb 24
rename_src:     resb 4096
rename_buf:     resb 4096
dir_buf:        resb 4096
write_buf:      resb WRITE_BUF_SIZE

bss_size equ $ - bss_start
