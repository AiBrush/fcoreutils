; ============================================================
; freadlink_unified.asm — GNU-compatible 'readlink' command
; Builds with: nasm -f bin freadlink_unified.asm -o freadlink
;
; readlink: Print the target of a symbolic link or canonical path.
;
; Register allocation:
;   r14d = argc, r15 = argv, ebx = flags, ecx = arg index
;   r12 = first file arg index, r13 = current file index
;
; Flags (ebx):
;   bit 0 = -f (canonicalize)
;   bit 1 = -e (canonicalize-existing)
;   bit 2 = -m (canonicalize-missing)
;   bit 3 = -n (no-newline)
;   bit 4 = -z (zero/NUL delimiter)
;   bit 5 = -v (verbose)
;   bit 6 = -q/-s (quiet/silent) — suppress errors
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE           1
%define SYS_LSTAT            6
%define SYS_EXIT            60
%define SYS_RT_SIGPROCMASK  14
%define SYS_READLINKAT     267
%define SYS_GETCWD          79
%define SYS_STAT             4

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13
%define AT_FDCWD       -100

%define PATH_MAX       4096

; BSS layout: 0x500000
%define BSS_ADDR       0x500000
%define BSS_SIZE       16384
%define BUF_READLINK   BSS_ADDR                    ; 4096 bytes - readlinkat buffer
%define BUF_PATH       (BSS_ADDR + 4096)           ; 4096 bytes - path construction buffer
%define BUF_WORK       (BSS_ADDR + 8192)           ; 4096 bytes - work/resolve buffer
%define BUF_CWD        (BSS_ADDR + 12288)          ; 4096 bytes - getcwd buffer

; stat struct offsets (struct stat on x86-64)
; st_mode is at offset 24
%define STAT_SIZE      144
%define ST_MODE_OFF    24

; S_IFMT and types
%define S_IFMT         0xF000
%define S_IFLNK        0xA000
%define S_IFDIR        0x4000

; --- ELF Header (64 bytes) ---
ehdr:
    db 0x7f, 'E','L','F'
    db 2, 1, 1, 0
    dq 0
    dw 2, 0x3e
    dd 1
    dq _start
    dq phdr - $$
    dq 0
    dd 0
    dw 64, 56, 3, 64, 0, 0

; --- Program Headers ---
phdr:
    ; PT_LOAD: code + data (R+X)
    dd 1, 5
    dq 0, $$, $$, file_size, file_size, 0x200000

    ; PT_LOAD: BSS (R+W)
    dd 1, 6
    dq 0, BSS_ADDR, BSS_ADDR, 0, BSS_SIZE, 0x200000

    ; PT_GNU_STACK (NX)
    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 0x10

; ============================================================
; Code
; ============================================================
_start:
    ; Block SIGPIPE
    sub     rsp, 16
    mov     qword [rsp], 0
    bts     qword [rsp], SIGPIPE
    mov     eax, SYS_RT_SIGPROCMASK
    mov     edi, SIG_BLOCK
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    ; Save argc/argv
    mov     r14d, [rsp]         ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Initialize flags
    xor     ebx, ebx            ; flags
    mov     ecx, 1              ; arg index

; Parse options
.parse_opts:
    cmp     ecx, r14d
    jge     .err_missing_operand
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .done_opts
    cmp     byte [rdi + 1], 0
    je      .done_opts           ; bare "-" is a filename
    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options: -f, -e, -m, -n, -z, -q, -s, -v
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'f'
    je      .set_canon
    cmp     al, 'e'
    je      .set_canon_exist
    cmp     al, 'm'
    je      .set_canon_miss
    cmp     al, 'n'
    je      .set_no_newline
    cmp     al, 'z'
    je      .set_zero
    cmp     al, 'q'
    je      .set_quiet
    cmp     al, 's'
    je      .set_quiet
    cmp     al, 'v'
    je      .set_verbose
    ; Invalid short option
    mov     r13, rdi
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    do_write_err
    mov     rsi, r13
    mov     edx, 1
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.set_canon:
    ; -f clears bits 1,2 and sets bit 0
    and     bl, ~0x07
    or      bl, 1
    inc     rdi
    jmp     .short_loop

.set_canon_exist:
    and     bl, ~0x07
    or      bl, 2
    inc     rdi
    jmp     .short_loop

.set_canon_miss:
    and     bl, ~0x07
    or      bl, 4
    inc     rdi
    jmp     .short_loop

.set_no_newline:
    or      bl, 8
    inc     rdi
    jmp     .short_loop

.set_zero:
    or      bl, 16
    inc     rdi
    jmp     .short_loop

.set_quiet:
    or      bl, 64
    and     bl, ~0x20           ; quiet clears verbose
    inc     rdi
    jmp     .short_loop

.set_verbose:
    or      bl, 32
    and     bl, ~0x40           ; verbose clears quiet
    inc     rdi
    jmp     .short_loop

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    mov     r13, rdi
    push    rcx
    ; --help
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_help
    ; --version
    mov     rdi, r13
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_version
    ; --canonicalize
    mov     rdi, r13
    mov     rsi, str_canonicalize_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_canon
    ; --canonicalize-existing
    mov     rdi, r13
    mov     rsi, str_canon_exist_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_canon_exist
    ; --canonicalize-missing
    mov     rdi, r13
    mov     rsi, str_canon_miss_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_canon_miss
    ; --no-newline
    mov     rdi, r13
    mov     rsi, str_no_newline_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_no_newline
    ; --zero
    mov     rdi, r13
    mov     rsi, str_zero_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_zero
    ; --quiet
    mov     rdi, r13
    mov     rsi, str_quiet_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_quiet
    ; --silent
    mov     rdi, r13
    mov     rsi, str_silent_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_quiet
    ; --verbose
    mov     rdi, r13
    mov     rsi, str_verbose_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_verbose
    ; Unrecognized long option
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_unrecog
    mov     edx, str_unrecog_len
    call    do_write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    pop     rcx
    mov     edi, 1
    jmp     do_exit

.pop_show_help:
    pop     rcx
    jmp     .show_help
.pop_show_version:
    pop     rcx
    jmp     .show_version
.pop_set_canon:
    pop     rcx
    and     bl, ~0x07
    or      bl, 1
    jmp     .next_opt
.pop_set_canon_exist:
    pop     rcx
    and     bl, ~0x07
    or      bl, 2
    jmp     .next_opt
.pop_set_canon_miss:
    pop     rcx
    and     bl, ~0x07
    or      bl, 4
    jmp     .next_opt
.pop_set_no_newline:
    pop     rcx
    or      bl, 8
    jmp     .next_opt
.pop_set_zero:
    pop     rcx
    or      bl, 16
    jmp     .next_opt
.pop_set_quiet:
    pop     rcx
    or      bl, 64
    and     bl, ~0x20
    jmp     .next_opt
.pop_set_verbose:
    pop     rcx
    or      bl, 32
    and     bl, ~0x40
    jmp     .next_opt

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.done_opts:
    ; ecx = index of first file arg
    cmp     ecx, r14d
    jge     .err_missing_operand

    ; Process files
    mov     r12d, ecx           ; first file index
    mov     r13d, ecx           ; current file index
    xor     ebp, ebp            ; exit code (0 = success)

.file_loop:
    cmp     r13d, r14d
    jge     .exit_with_code
    mov     rdi, [r15 + r13*8]

    ; Check if canonical mode
    test    bl, 0x07
    jnz     .do_canonical
    ; Simple readlink mode
    call    do_readlink_simple
    jmp     .file_next

.do_canonical:
    call    do_realpath
    jmp     .file_next

.file_next:
    inc     r13d
    jmp     .file_loop

.exit_with_code:
    mov     edi, ebp
    jmp     do_exit

.show_help:
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.show_version:
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.err_missing_operand:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing
    mov     edx, str_missing_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; ============================================================
; do_readlink_simple: read symlink target and print it
; Input: rdi = path, ebx = flags, ebp = exit code accumulator
; Updates ebp on failure
; ============================================================
do_readlink_simple:
    push    rbp
    push    r12
    push    r13
    mov     r12, rdi            ; save path

    ; readlinkat(AT_FDCWD, path, buf, PATH_MAX-1)
    mov     eax, SYS_READLINKAT
    mov     edi, AT_FDCWD
    mov     rsi, r12
    mov     rdx, BUF_READLINK
    mov     r10d, PATH_MAX - 1
    syscall

    test    rax, rax
    js      .rls_fail

    ; rax = number of bytes read
    mov     r13, rax
    ; NUL-terminate
    mov     byte [BUF_READLINK + r13], 0

    ; Write the result
    mov     edi, STDOUT
    mov     rsi, BUF_READLINK
    mov     edx, r13d
    call    do_write

    ; Write terminator
    call    write_terminator

    pop     r13
    pop     r12
    pop     rbp
    ret

.rls_fail:
    ; rax has negative errno from readlinkat
    ; r12 still has the path pointer (hasn't been popped yet)
    neg     rax                 ; convert to positive errno
    mov     r13, rax            ; save errno

    ; If verbose, print error before restoring registers
    test    bl, 32
    jz      .rls_fail_quiet

    ; Print error: "readlink: <path>: <error>"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    do_write_err
    ; Choose error message based on errno
    cmp     r13d, 22            ; EINVAL
    je      .rls_err_einval
    cmp     r13d, 2             ; ENOENT
    je      .rls_err_enoent
    cmp     r13d, 13            ; EACCES
    je      .rls_err_eacces
    ; Default: use "No such file or directory"
    jmp     .rls_err_enoent

.rls_err_einval:
    mov     rsi, str_not_symlink
    mov     edx, str_not_symlink_len
    call    do_write_err
    jmp     .rls_fail_quiet

.rls_err_enoent:
    mov     rsi, str_no_such_file
    mov     edx, str_no_such_file_len
    call    do_write_err
    jmp     .rls_fail_quiet

.rls_err_eacces:
    mov     rsi, str_perm_denied
    mov     edx, str_perm_denied_len
    call    do_write_err

.rls_fail_quiet:
    pop     r13
    pop     r12
    pop     rbp
    mov     ebp, 1
    ret

; ============================================================
; do_realpath: resolve canonical path
; Input: rdi = path, ebx = flags, ebp = exit code accumulator
; Mode depends on flags bits 0-2:
;   bit 0 (-f): all but last component must exist
;   bit 1 (-e): all components must exist
;   bit 2 (-m): no components need to exist
;
; Internal register usage:
;   r12 = pointer into remaining source path to process
;   r13d = current length of resolved path in BUF_PATH
;   r14 = start of current component
;   r15d = length of current component
;   [rsp+STAT_SIZE] = saved original arg pointer (for errors)
; ============================================================
do_realpath:
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, STAT_SIZE + 8  ; stat buffer + saved original path ptr
    mov     [rsp + STAT_SIZE], rdi  ; save original path for error messages

    ; Copy input path to BUF_READLINK so we can use it as source
    ; (since the original pointer may be in argv and we need a mutable copy)
    mov     rsi, rdi
    mov     rdi, BUF_READLINK
    call    str_copy
    mov     r12, BUF_READLINK   ; r12 = source path pointer

    ; Start building result path in BUF_PATH
    ; Check if path is absolute
    cmp     byte [r12], '/'
    je      .rp_abs

    ; Relative path: start with getcwd
    mov     eax, SYS_GETCWD
    mov     rdi, BUF_PATH
    mov     esi, PATH_MAX
    syscall
    test    rax, rax
    js      .rp_fail
    ; Find end of cwd string
    mov     rdi, BUF_PATH
    call    str_len
    mov     r13d, eax           ; r13d = current length in BUF_PATH
    jmp     .rp_process_components

.rp_abs:
    ; Absolute path: start with "/"
    mov     byte [BUF_PATH], '/'
    mov     byte [BUF_PATH + 1], 0
    mov     r13d, 1
    ; Skip leading slashes in source
    inc     r12
.rp_skip_leading:
    cmp     byte [r12], '/'
    jne     .rp_process_components
    inc     r12
    jmp     .rp_skip_leading

.rp_process_components:
    ; r12 points to remaining path to process
    ; r13d = current length of BUF_PATH
    ; Process each component separated by '/'

.rp_next_component:
    ; Skip slashes
    cmp     byte [r12], '/'
    jne     .rp_check_end
    inc     r12
    jmp     .rp_next_component

.rp_check_end:
    cmp     byte [r12], 0
    je      .rp_done

    ; Find end of component (next '/' or NUL)
    mov     r14, r12            ; start of component
    xor     r15d, r15d          ; component length
.rp_find_comp_end:
    movzx   eax, byte [r12 + r15]
    test    al, al
    jz      .rp_got_component
    cmp     al, '/'
    je      .rp_got_component
    inc     r15d
    jmp     .rp_find_comp_end

.rp_got_component:
    ; r14 = component start, r15d = component length
    ; Check for "."
    cmp     r15d, 1
    jne     .rp_check_dotdot
    cmp     byte [r14], '.'
    jne     .rp_check_dotdot
    ; "." - skip it
    jmp     .rp_skip_component

.rp_check_dotdot:
    ; Check for ".."
    cmp     r15d, 2
    jne     .rp_append_component
    cmp     byte [r14], '.'
    jne     .rp_append_component
    cmp     byte [r14 + 1], '.'
    jne     .rp_append_component

    ; ".." - go up one level
    ; Remove last component from BUF_PATH (but keep root "/")
    cmp     r13d, 1
    jle     .rp_skip_component
    dec     r13d
.rp_backup:
    cmp     r13d, 1
    jle     .rp_backup_done
    cmp     byte [BUF_PATH + r13 - 1], '/'
    je      .rp_backup_done
    dec     r13d
    jmp     .rp_backup
.rp_backup_done:
    ; r13d now points just after the last '/' (or is 1 for root)
    mov     byte [BUF_PATH + r13], 0
    jmp     .rp_skip_component

.rp_skip_component:
    ; Advance r12 past the current component
    lea     r12, [r14 + r15]
    jmp     .rp_next_component

.rp_append_component:
    ; Append "/" if not already ending with one
    cmp     r13d, 0
    je      .rp_add_slash
    cmp     byte [BUF_PATH + r13 - 1], '/'
    je      .rp_copy_comp
.rp_add_slash:
    mov     byte [BUF_PATH + r13], '/'
    inc     r13d

.rp_copy_comp:
    ; Copy component to BUF_PATH
    xor     ecx, ecx
.rp_copy_loop:
    cmp     ecx, r15d
    jge     .rp_copy_done
    movzx   eax, byte [r14 + rcx]
    mov     byte [BUF_PATH + r13 + rcx], al
    inc     ecx
    jmp     .rp_copy_loop
.rp_copy_done:
    add     r13d, r15d
    mov     byte [BUF_PATH + r13], 0

    ; Determine if this is the last component
    ; Peek past the component to see if more non-slash chars follow
    lea     rdi, [r14 + r15]
.rp_peek_more:
    cmp     byte [rdi], '/'
    jne     .rp_peek_done
    inc     rdi
    jmp     .rp_peek_more
.rp_peek_done:
    cmp     byte [rdi], 0
    je      .rp_is_last_component

    ; ---- Not last component ----
    ; lstat to check if symlink or directory
    mov     eax, SYS_LSTAT
    mov     rdi, BUF_PATH
    lea     rsi, [rsp]          ; stat buffer on stack
    syscall
    test    rax, rax
    js      .rp_comp_not_found

    ; Check if symlink
    movzx   eax, word [rsp + ST_MODE_OFF]
    and     eax, S_IFMT
    cmp     eax, S_IFLNK
    je      .rp_resolve_symlink

    ; Not a symlink - check if directory (required for non-last component)
    movzx   eax, word [rsp + ST_MODE_OFF]
    and     eax, S_IFMT
    cmp     eax, S_IFDIR
    je      .rp_skip_component

    ; Non-last component is not a directory and not a symlink - error
    ; For -m mode, just keep going
    test    bl, 4
    jnz     .rp_skip_component
    jmp     .rp_fail

.rp_comp_not_found:
    ; Component doesn't exist
    ; For -m mode, just keep going
    test    bl, 4
    jnz     .rp_skip_component
    ; For -f and -e, non-last component must exist
    jmp     .rp_fail

    ; ---- Last component ----
.rp_is_last_component:
    ; lstat it
    mov     eax, SYS_LSTAT
    mov     rdi, BUF_PATH
    lea     rsi, [rsp]
    syscall
    test    rax, rax
    js      .rp_last_not_found

    ; Check if symlink
    movzx   eax, word [rsp + ST_MODE_OFF]
    and     eax, S_IFMT
    cmp     eax, S_IFLNK
    je      .rp_resolve_symlink

    ; Exists and not a symlink - we're done
    jmp     .rp_skip_component

.rp_last_not_found:
    ; Last component doesn't exist
    ; -e mode: must exist -> fail
    test    bl, 2
    jnz     .rp_fail
    ; -f and -m: ok, keep path as-is
    jmp     .rp_skip_component

.rp_resolve_symlink:
    ; Read the symlink target into BUF_WORK
    mov     eax, SYS_READLINKAT
    mov     edi, AT_FDCWD
    mov     rsi, BUF_PATH
    mov     rdx, BUF_WORK
    mov     r10d, PATH_MAX - 1
    syscall
    test    rax, rax
    js      .rp_fail

    ; NUL-terminate the target
    mov     byte [BUF_WORK + rax], 0

    ; Remove last component from BUF_PATH (the symlink name itself)
    ; to get the directory containing the symlink
    cmp     r13d, 1
    jle     .rp_sym_at_root
    dec     r13d
.rp_sym_backup:
    cmp     r13d, 1
    jle     .rp_sym_backup_done
    cmp     byte [BUF_PATH + r13 - 1], '/'
    je      .rp_sym_backup_done
    dec     r13d
    jmp     .rp_sym_backup
.rp_sym_backup_done:
    mov     byte [BUF_PATH + r13], 0
    jmp     .rp_sym_build_new_source

.rp_sym_at_root:
    mov     r13d, 1
    mov     byte [BUF_PATH + 1], 0

.rp_sym_build_new_source:
    ; Build new source in BUF_CWD: symlink_target + "/" + remaining_source
    ; Copy symlink target to BUF_CWD
    mov     rdi, BUF_CWD
    mov     rsi, BUF_WORK
    call    str_copy            ; returns length in eax
    mov     ecx, eax

    ; Compute remaining source path (after current component)
    lea     rdi, [r14 + r15]    ; pointer past current component
    cmp     byte [rdi], 0
    je      .rp_sym_no_remaining

    ; Add "/" separator if target doesn't end with one
    cmp     ecx, 0
    je      .rp_sym_add_sep
    cmp     byte [BUF_CWD + rcx - 1], '/'
    je      .rp_sym_copy_remaining
.rp_sym_add_sep:
    mov     byte [BUF_CWD + rcx], '/'
    inc     ecx

.rp_sym_copy_remaining:
    ; Copy remaining source
    mov     rsi, rdi
    lea     rdi, [BUF_CWD + rcx]
    push    rcx
    call    str_copy_from
    pop     rcx
    add     ecx, eax

.rp_sym_no_remaining:
    mov     byte [BUF_CWD + rcx], 0

    ; Now check: if symlink target is absolute, reset BUF_PATH
    cmp     byte [BUF_CWD], '/'
    jne     .rp_sym_relative

    ; Absolute symlink target: reset resolved path to "/"
    mov     byte [BUF_PATH], '/'
    mov     byte [BUF_PATH + 1], 0
    mov     r13d, 1

.rp_sym_relative:
    ; Set r12 to new source and continue processing
    mov     r12, BUF_CWD
    jmp     .rp_process_components

.rp_done:
    ; Remove trailing slash if path is not just "/"
    cmp     r13d, 1
    jle     .rp_output
    cmp     byte [BUF_PATH + r13 - 1], '/'
    jne     .rp_output
    dec     r13d
    mov     byte [BUF_PATH + r13], 0

.rp_output:
    ; Write result
    mov     edi, STDOUT
    mov     rsi, BUF_PATH
    mov     edx, r13d
    call    do_write
    call    write_terminator

    add     rsp, STAT_SIZE + 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret

.rp_fail:
    ; Only print error if verbose (-v) flag is set
    test    bl, 32
    jz      .rp_fail_done
    ; Print error using saved original path
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rdi, [rsp + STAT_SIZE]  ; original path pointer
    call    str_len
    mov     edx, eax
    mov     rsi, [rsp + STAT_SIZE]
    call    do_write_err
    mov     rsi, str_no_such_file
    mov     edx, str_no_such_file_len
    call    do_write_err

.rp_fail_done:
    add     rsp, STAT_SIZE + 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    mov     ebp, 1              ; set exit code AFTER restoring rbp
    ret

; ============================================================
; write_terminator: write newline/NUL based on flags
; Input: ebx = flags (bit 3 = -n, bit 4 = -z)
; For multiple files, -n only suppresses on last file
; ============================================================
write_terminator:
    ; Check -z flag first
    test    bl, 16
    jnz     .wt_nul

    ; Check -n flag: suppress newline only for single file or last file
    test    bl, 8
    jnz     .wt_check_last

    ; Normal newline
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write
    ret

.wt_check_last:
    ; -n: no trailing newline
    ret

.wt_nul:
    mov     edi, STDOUT
    mov     rsi, str_nul
    mov     edx, 1
    call    do_write
    ret

; ============================================================
; Utility functions
; ============================================================
do_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      do_write
    ret

do_write_err:
    mov     edi, STDERR
    jmp     do_write

do_exit:
    mov     eax, SYS_EXIT
    syscall

str_len:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     eax
    jmp     .sl_loop
.sl_done:
    ret

; str_copy: copy NUL-terminated string from rsi to rdi
; Returns length in eax (not counting NUL)
str_copy:
    xor     eax, eax
.sc_loop:
    movzx   ecx, byte [rsi + rax]
    mov     byte [rdi + rax], cl
    test    cl, cl
    jz      .sc_done
    inc     eax
    jmp     .sc_loop
.sc_done:
    ret

; str_copy_from: copy NUL-terminated string from rsi to rdi
; Returns length in eax
str_copy_from:
    xor     eax, eax
.scf_loop:
    movzx   ecx, byte [rsi + rax]
    mov     byte [rdi + rax], cl
    test    cl, cl
    jz      .scf_done
    inc     eax
    jmp     .scf_loop
.scf_done:
    ret

; str_eq: compare two NUL-terminated strings
; rdi = s1, rsi = s2; returns eax: 1=equal, 0=not equal
str_eq:
    xor     r8d, r8d
.se_loop:
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    cmp     al, dl
    jne     .se_ne
    test    al, al
    jz      .se_eq
    inc     r8d
    jmp     .se_loop
.se_eq:
    mov     eax, 1
    ret
.se_ne:
    xor     eax, eax
    ret

str_prefix_match:
    xor     r8d, r8d
.sp_loop:
    cmp     r8d, edx
    jge     .sp_match
    movzx   eax, byte [rdi + r8]
    cmp     al, byte [rsi + r8]
    jne     .sp_nomatch
    inc     r8d
    jmp     .sp_loop
.sp_match:
    mov     eax, 1
    ret
.sp_nomatch:
    xor     eax, eax
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: readlink [OPTION]... FILE...", 10
    db "Print value of a symbolic link or canonical file name", 10, 10
    db "  -f, --canonicalize            canonicalize by following every symlink in", 10
    db "                                every component of the given name recursively;", 10
    db "                                all but the last component must exist", 10
    db "  -e, --canonicalize-existing   canonicalize by following every symlink in", 10
    db "                                every component of the given name recursively,", 10
    db "                                all components must exist", 10
    db "  -m, --canonicalize-missing    canonicalize by following every symlink in", 10
    db "                                every component of the given name recursively,", 10
    db "                                without requirements on components existence", 10
    db "  -n, --no-newline              do not output the trailing delimiter", 10
    db "  -q, --quiet", 10
    db "  -s, --silent                  suppress most error messages (on by default)", 10
    db "  -v, --verbose                 report error messages", 10
    db "  -z, --zero                    end each output line with NUL, not newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/readlink>", 10
    db "or available locally via: info '(coreutils) readlink invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "readlink (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Dmitry V. Levin.", 10
str_version_len equ $ - str_version

str_prefix:      db "readlink: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_missing:     db "missing operand", 10
str_missing_len  equ $ - str_missing
str_sq_nl:       db "'", 10
str_try:         db "Try 'readlink --help' for more information.", 10
str_try_len      equ $ - str_try
str_not_symlink: db ": Invalid argument", 10
str_not_symlink_len equ $ - str_not_symlink
str_no_such_file: db ": No such file or directory", 10
str_no_such_file_len equ $ - str_no_such_file
str_perm_denied: db ": Permission denied", 10
str_perm_denied_len equ $ - str_perm_denied
; @@DATA_END@@

str_newline:     db 10
str_nul:         db 0
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_canonicalize_flag: db "--canonicalize", 0
str_canon_exist_flag: db "--canonicalize-existing", 0
str_canon_miss_flag: db "--canonicalize-missing", 0
str_no_newline_flag: db "--no-newline", 0
str_zero_flag:   db "--zero", 0
str_quiet_flag:  db "--quiet", 0
str_silent_flag: db "--silent", 0
str_verbose_flag: db "--verbose", 0

file_size equ $ - $$
