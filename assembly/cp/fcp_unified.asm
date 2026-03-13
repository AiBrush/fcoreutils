; ============================================================
; fcp_unified.asm — GNU-compatible 'cp' command
; Builds with: nasm -f bin fcp_unified.asm -o fcp
;
; cp: Copy files and directories.
;
; Register allocation:
;   r14d = argc, r15 = argv
;   ebx  = flags
;   r13d = first non-option arg index
;   ebp  = exit code
;
; Flags in ebx:
;   bit 0 = -f (force)
;   bit 1 = -r/-R (recursive)
;   bit 2 = -v (verbose)
;   bit 3 = -n (no-clobber)
;   bit 4 = -a (archive = -dpR)
;   bit 5 = -p (preserve)
;   bit 6 = -l (hard link)
;   bit 7 = -s (symlink)
;   bit 8 = -T (no-target-directory)
;   bit 9 = -i (interactive)
;   bit 10 = -d (no-dereference, preserve links)
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ         0
%define SYS_WRITE        1
%define SYS_OPEN         2
%define SYS_CLOSE        3
%define SYS_STAT         4
%define SYS_FSTAT        5
%define SYS_LSTAT        6
%define SYS_RT_SIGPROCMASK 14
%define SYS_READLINK    89
%define SYS_EXIT        60
%define SYS_UNLINK      87
%define SYS_LINK        86
%define SYS_SYMLINK     88
%define SYS_MKDIR       83
%define SYS_RMDIR       84
%define SYS_GETDENTS64 217
%define SYS_CHMOD       90
%define SYS_UTIMENSAT  280
%define SYS_COPY_FILE_RANGE 326

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13

%define O_RDONLY        0
%define O_WRONLY        1
%define O_CREAT         64
%define O_TRUNC        512
%define O_DIRECTORY     0x10000

; stat structure offsets (x86-64 Linux)
%define STAT_MODE       24
%define STAT_SIZE       48

%define S_IFMT      0xF000
%define S_IFDIR     0x4000
%define S_IFLNK     0xA000
%define S_IFREG     0x8000

; errno values
%define EPERM           1
%define ENOENT          2
%define EIO             5
%define EACCES         13
%define EBUSY          16
%define EEXIST         17
%define ENOTDIR        20
%define EISDIR         21
%define EINVAL         22
%define ENOSPC         28
%define EROFS          30
%define ENOMEM         12
%define ENOTEMPTY      39

%define PATH_MAX       4096
%define COPY_BUF_SIZE  65536
%define DIRBUF_SIZE    8192

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
    dw 64, 56, 2, 64, 0, 0

; --- Program Header: PT_LOAD ---
phdr:
    dd 1, 7
    dq 0, $$, $$, file_size, file_size, 0x200000

; --- Program Header: PT_GNU_STACK (NX) ---
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

    mov     r14d, [rsp]
    lea     r15, [rsp + 8]

    xor     ebx, ebx
    xor     ebp, ebp
    mov     ecx, 1

.parse_opts:
    cmp     ecx, r14d
    jge     .opts_exhausted
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .done_opts
    cmp     byte [rdi + 1], 0
    je      .done_opts
    cmp     byte [rdi + 1], '-'
    je      .check_long

    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'f'
    je      .s_force
    cmp     al, 'r'
    je      .s_recursive
    cmp     al, 'R'
    je      .s_recursive
    cmp     al, 'v'
    je      .s_verbose
    cmp     al, 'n'
    je      .s_noclobber
    cmp     al, 'a'
    je      .s_archive
    cmp     al, 'p'
    je      .s_preserve
    cmp     al, 'l'
    je      .s_link
    cmp     al, 's'
    je      .s_symlink
    cmp     al, 'T'
    je      .s_notargetdir
    cmp     al, 'i'
    je      .s_interactive
    cmp     al, 'd'
    je      .s_noderef
    ; Invalid option
    push    rcx
    push    rdi
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    do_write_err
    pop     rdi
    mov     rsi, rdi
    mov     edx, 1
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

.s_force:
    or      bl, 1
    inc     rdi
    jmp     .short_loop
.s_recursive:
    or      bl, 2
    inc     rdi
    jmp     .short_loop
.s_verbose:
    or      bl, 4
    inc     rdi
    jmp     .short_loop
.s_noclobber:
    or      bl, 8
    inc     rdi
    jmp     .short_loop
.s_archive:
    ; -a = -dpR
    or      bx, 2 | 32 | 1024   ; recursive + preserve + no-deref
    inc     rdi
    jmp     .short_loop
.s_preserve:
    or      bx, 32
    inc     rdi
    jmp     .short_loop
.s_link:
    or      bl, 64
    inc     rdi
    jmp     .short_loop
.s_symlink:
    or      bl, 128
    inc     rdi
    jmp     .short_loop
.s_notargetdir:
    or      bx, 256
    inc     rdi
    jmp     .short_loop
.s_interactive:
    or      bx, 512
    inc     rdi
    jmp     .short_loop
.s_noderef:
    or      bx, 1024
    inc     rdi
    jmp     .short_loop

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    mov     r13, rdi
    push    rcx
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_help
    mov     rdi, r13
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_version
    mov     rdi, r13
    mov     rsi, str_force_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_s_force
    mov     rdi, r13
    mov     rsi, str_recursive_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_s_recursive
    mov     rdi, r13
    mov     rsi, str_verbose_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_s_verbose
    mov     rdi, r13
    mov     rsi, str_noclobber_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_s_noclobber
    mov     rdi, r13
    mov     rsi, str_archive_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_s_archive
    mov     rdi, r13
    mov     rsi, str_no_target_dir_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_s_notargetdir
    ; Unrecognized
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
.pop_s_force:
    pop     rcx
    or      bl, 1
    jmp     .next_opt
.pop_s_recursive:
    pop     rcx
    or      bl, 2
    jmp     .next_opt
.pop_s_verbose:
    pop     rcx
    or      bl, 4
    jmp     .next_opt
.pop_s_noclobber:
    pop     rcx
    or      bl, 8
    jmp     .next_opt
.pop_s_archive:
    pop     rcx
    or      bx, 2 | 32 | 1024
    jmp     .next_opt
.pop_s_notargetdir:
    pop     rcx
    or      bx, 256
    jmp     .next_opt

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.opts_exhausted:
.done_opts:
    mov     r13d, ecx

    mov     eax, r14d
    sub     eax, r13d
    cmp     eax, 0
    jle     .err_missing_operand
    cmp     eax, 1
    je      .err_missing_dest
    cmp     eax, 2
    je      .two_args
    jmp     .multi_args

.two_args:
    mov     rdi, [r15 + r13*8]
    lea     eax, [r13d + 1]
    mov     rsi, [r15 + rax*8]

    ; Check -T flag
    test    bx, 256
    jnz     .two_direct

    ; Check if dest is directory
    push    rdi
    push    rsi
    sub     rsp, 152
    mov     rdi, rsi
    mov     rsi, rsp
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .two_not_dir
    mov     eax, [rsp + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFDIR
    je      .two_is_dir
.two_not_dir:
    add     rsp, 152
    pop     rsi
    pop     rdi
    jmp     .two_direct

.two_is_dir:
    add     rsp, 152
    pop     r12                  ; dest dir
    pop     rdi                  ; source

    push    rdi
    push    r12
    call    basename
    mov     r8, rax

    sub     rsp, PATH_MAX
    mov     rdi, rsp
    mov     rsi, [rsp + PATH_MAX]
.td_dir:
    lodsb
    test    al, al
    jz      .td_dir_done
    stosb
    jmp     .td_dir
.td_dir_done:
    mov     byte [rdi], '/'
    inc     rdi
    mov     rsi, r8
.td_bname:
    lodsb
    stosb
    test    al, al
    jnz     .td_bname

    mov     rsi, rsp
    mov     rdi, [rsp + PATH_MAX + 8]
    call    do_copy

    add     rsp, PATH_MAX
    pop     r12
    pop     rdi
    jmp     .exit_done

.two_direct:
    call    do_copy
    jmp     .exit_done

.multi_args:
    mov     eax, r14d
    dec     eax
    mov     r12, [r15 + rax*8]

    sub     rsp, 152
    mov     rdi, r12
    mov     rsi, rsp
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .multi_not_dir
    mov     eax, [rsp + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFDIR
    jne     .multi_not_dir
    add     rsp, 152

    mov     r8d, r13d

.multi_loop:
    lea     eax, [r14d - 1]
    cmp     r8d, eax
    jge     .exit_done
    mov     rdi, [r15 + r8*8]

    push    r8
    call    basename
    mov     r9, rax

    sub     rsp, PATH_MAX
    mov     rdi, rsp
    mov     rsi, r12
.mc_dir:
    lodsb
    test    al, al
    jz      .mc_done
    stosb
    jmp     .mc_dir
.mc_done:
    mov     byte [rdi], '/'
    inc     rdi
    mov     rsi, r9
.mc_bname:
    lodsb
    stosb
    test    al, al
    jnz     .mc_bname

    mov     r8, [rsp + PATH_MAX]
    mov     rdi, [r15 + r8*8]
    mov     rsi, rsp
    call    do_copy

    add     rsp, PATH_MAX
    pop     r8
    inc     r8d
    jmp     .multi_loop

.multi_not_dir:
    add     rsp, 152
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_target_str
    mov     edx, str_target_str_len
    call    do_write_err
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    do_write_err
    mov     rsi, str_not_a_dir
    mov     edx, str_not_a_dir_len
    call    do_write_err
    mov     ebp, 1
    jmp     .exit_done

.exit_done:
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

.err_missing_dest:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing_dest
    mov     edx, str_missing_dest_len
    call    do_write_err
    mov     rdi, [r15 + r13*8]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + r13*8]
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; ============================================================
; do_copy: copy source to dest
; Input: rdi = source, rsi = dest
; Uses: ebx = flags, ebp = exit code
; ============================================================
do_copy:
    push    r12
    push    r13
    push    r14
    mov     r12, rdi            ; source
    mov     r13, rsi            ; dest
    mov     r14d, ebx

    ; If -n: check if dest exists
    test    r14d, 8
    jz      .cp_no_noclobber
    sub     rsp, 152
    mov     rdi, r13
    mov     rsi, rsp
    mov     eax, SYS_LSTAT
    syscall
    add     rsp, 152
    test    rax, rax
    jns     .cp_done             ; dest exists, skip

.cp_no_noclobber:
    ; lstat source to determine type
    sub     rsp, 152
    mov     rdi, r12
    mov     rsi, rsp
    mov     eax, SYS_LSTAT
    syscall
    test    rax, rax
    js      .cp_src_err

    mov     eax, [rsp + STAT_MODE]
    mov     r8d, eax             ; save full mode
    and     eax, S_IFMT

    cmp     eax, S_IFDIR
    je      .cp_is_dir
    cmp     eax, S_IFLNK
    je      .cp_is_symlink

    ; Regular file: copy it
    add     rsp, 152

    ; If -l flag: hard link
    test    r14d, 64
    jnz     .cp_hardlink
    ; If -s flag: symlink
    test    r14b, 128
    jnz     .cp_symlink

    ; Open source
    mov     rdi, r12
    mov     esi, O_RDONLY
    xor     edx, edx
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .cp_open_src_err
    push    rax                  ; src fd

    ; fstat to get mode
    sub     rsp, 152
    mov     edi, eax
    mov     rsi, rsp
    mov     eax, SYS_FSTAT
    syscall
    mov     r8d, [rsp + STAT_MODE]
    add     rsp, 152

    ; If -f: unlink dest first (ignore errors)
    test    r14d, 1
    jz      .cp_no_force_unlink
    mov     rdi, r13
    mov     eax, SYS_UNLINK
    syscall
.cp_no_force_unlink:

    ; Create dest
    mov     rdi, r13
    mov     esi, O_WRONLY | O_CREAT | O_TRUNC
    mov     edx, r8d
    and     edx, 0o7777
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .cp_open_dst_err
    push    rax                  ; dst fd

    ; Copy with read/write loop
    sub     rsp, COPY_BUF_SIZE

.cp_copy_loop:
    mov     eax, SYS_READ
    mov     edi, [rsp + COPY_BUF_SIZE + 8]  ; src fd
    mov     rsi, rsp
    mov     edx, COPY_BUF_SIZE
    syscall
    test    rax, rax
    jle     .cp_copy_done

    mov     rdx, rax
    mov     eax, SYS_WRITE
    mov     edi, [rsp + COPY_BUF_SIZE]  ; dst fd
    mov     rsi, rsp
    syscall
    jmp     .cp_copy_loop

.cp_copy_done:
    add     rsp, COPY_BUF_SIZE

    ; Close dst
    pop     rdi
    mov     edi, edi
    mov     eax, SYS_CLOSE
    syscall

    ; Close src
    pop     rdi
    mov     edi, edi
    mov     eax, SYS_CLOSE
    syscall

    ; Verbose
    test    r14d, 4
    jz      .cp_done
    call    print_verbose
    jmp     .cp_done

.cp_hardlink:
    ; If -f: unlink dest first
    test    r14d, 1
    jz      .cp_hl_no_force
    mov     rdi, r13
    mov     eax, SYS_UNLINK
    syscall
.cp_hl_no_force:
    mov     rdi, r12
    mov     rsi, r13
    mov     eax, SYS_LINK
    syscall
    test    rax, rax
    js      .cp_link_err
    test    r14d, 4
    jz      .cp_done
    call    print_verbose
    jmp     .cp_done

.cp_symlink:
    ; If -f: unlink dest first
    test    r14d, 1
    jz      .cp_sl_no_force
    mov     rdi, r13
    mov     eax, SYS_UNLINK
    syscall
.cp_sl_no_force:
    mov     rdi, r12
    mov     rsi, r13
    mov     eax, SYS_SYMLINK
    syscall
    test    rax, rax
    js      .cp_link_err
    test    r14d, 4
    jz      .cp_done
    call    print_verbose
    jmp     .cp_done

.cp_is_symlink:
    ; Read the symlink target, recreate it at dest
    add     rsp, 152
    sub     rsp, PATH_MAX
    mov     rdi, r12
    mov     rsi, rsp
    mov     edx, PATH_MAX - 1
    mov     eax, SYS_READLINK
    syscall
    test    rax, rax
    js      .cp_readlink_err
    ; NUL-terminate
    mov     byte [rsp + rax], 0
    ; Create symlink at dest
    mov     rdi, rsp             ; target
    mov     rsi, r13             ; link_name
    mov     eax, SYS_SYMLINK
    syscall
    add     rsp, PATH_MAX
    test    rax, rax
    js      .cp_link_err
    test    r14d, 4
    jz      .cp_done
    call    print_verbose
    jmp     .cp_done

.cp_readlink_err:
    add     rsp, PATH_MAX
    jmp     .cp_generic_err

.cp_is_dir:
    add     rsp, 152
    ; Need -r flag for directories
    test    r14d, 2
    jnz     .cp_recursive

    ; Error: omitting directory
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_omitting
    mov     edx, str_omitting_len
    call    do_write_err
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     ebp, 1
    jmp     .cp_done

.cp_recursive:
    ; Create dest directory
    ; First, stat the source for mode
    sub     rsp, 152
    mov     rdi, r12
    mov     rsi, rsp
    mov     eax, SYS_STAT
    syscall
    mov     r8d, [rsp + STAT_MODE]
    add     rsp, 152
    and     r8d, 0o7777

    mov     rdi, r13
    mov     esi, r8d
    or      esi, 0o700          ; ensure we can write to it
    mov     eax, SYS_MKDIR
    syscall
    ; Ignore EEXIST
    cmp     rax, -EEXIST
    je      .cp_mkdir_ok
    test    rax, rax
    js      .cp_mkdir_err
.cp_mkdir_ok:

    ; Open source directory
    mov     rdi, r12
    mov     esi, O_RDONLY | O_DIRECTORY
    xor     edx, edx
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .cp_open_dir_err
    push    rax                  ; dir fd

    sub     rsp, DIRBUF_SIZE

.cp_readdir:
    mov     eax, SYS_GETDENTS64
    mov     edi, [rsp + DIRBUF_SIZE]  ; dir fd
    mov     rsi, rsp
    mov     edx, DIRBUF_SIZE
    syscall
    test    rax, rax
    jle     .cp_readdir_done

    xor     r8d, r8d             ; offset

.cp_entry_loop:
    cmp     r8d, eax
    jge     .cp_readdir

    lea     rsi, [rsp + r8]
    movzx   ecx, word [rsi + 16]  ; d_reclen
    lea     rdi, [rsi + 19]       ; d_name

    ; Skip . and ..
    cmp     byte [rdi], '.'
    jne     .cp_not_dot
    cmp     byte [rdi + 1], 0
    je      .cp_skip_entry
    cmp     byte [rdi + 1], '.'
    jne     .cp_not_dot
    cmp     byte [rdi + 2], 0
    je      .cp_skip_entry

.cp_not_dot:
    push    rax
    push    r8
    push    rcx

    ; Build src_path = source + "/" + name
    sub     rsp, PATH_MAX * 2    ; src_path and dst_path

    ; Build src path at rsp
    mov     rdi, rsp
    mov     rsi, r12
.cp_csrc:
    lodsb
    test    al, al
    jz      .cp_csrc_done
    stosb
    jmp     .cp_csrc
.cp_csrc_done:
    mov     byte [rdi], '/'
    inc     rdi
    ; entry name is at [rsp + PATH_MAX*2 + 24]  — need to reload
    lea     rsi, [rsp + PATH_MAX*2 + 16]   ; points to saved r8
    mov     r8, [rsi]                        ; restore r8
    lea     rsi, [rsp + PATH_MAX*2 + 24 + DIRBUF_SIZE]
    ; Hmm, stack offsets are getting complex. Let me use a different approach.
    ; Save entry name before building paths.
    ; Actually, let's save name ptr before sub rsp
    ; I need to rethink this. The entry name is in the dirbuf on stack.
    ; After sub rsp, PATH_MAX*2, the dirbuf is at rsp + PATH_MAX*2 + 24 (3 pushes = 24 bytes)
    ; The entry was at old_rsp + r8 + 19
    ; So entry name is at rsp + PATH_MAX*2 + 24 + r8_saved + 19
    ; r8_saved is at [rsp + PATH_MAX*2 + 8]
    mov     r8, [rsp + PATH_MAX*2 + 8]     ; saved r8
    lea     rsi, [rsp + PATH_MAX*2 + 24]   ; start of dirbuf
    add     rsi, r8
    add     rsi, 19                          ; d_name offset
.cp_csrc_name:
    lodsb
    stosb
    test    al, al
    jnz     .cp_csrc_name

    ; Build dst path at rsp + PATH_MAX
    lea     rdi, [rsp + PATH_MAX]
    mov     rsi, r13
.cp_cdst:
    lodsb
    test    al, al
    jz      .cp_cdst_done
    stosb
    jmp     .cp_cdst
.cp_cdst_done:
    mov     byte [rdi], '/'
    inc     rdi
    ; Copy entry name again
    mov     r8, [rsp + PATH_MAX*2 + 8]
    lea     rsi, [rsp + PATH_MAX*2 + 24]
    add     rsi, r8
    add     rsi, 19
.cp_cdst_name:
    lodsb
    stosb
    test    al, al
    jnz     .cp_cdst_name

    ; Recursively copy
    mov     rdi, rsp                    ; src_path
    lea     rsi, [rsp + PATH_MAX]       ; dst_path
    call    do_copy

    add     rsp, PATH_MAX * 2
    pop     rcx                  ; reclen
    pop     r8
    pop     rax

.cp_skip_entry:
    add     r8d, ecx
    jmp     .cp_entry_loop

.cp_readdir_done:
    add     rsp, DIRBUF_SIZE
    pop     rdi                  ; dir fd
    mov     edi, edi
    mov     eax, SYS_CLOSE
    syscall

    ; Verbose
    test    r14d, 4
    jz      .cp_done
    call    print_verbose
    jmp     .cp_done

.cp_src_err:
    add     rsp, 152
.cp_generic_err:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_stat
    mov     edx, str_cannot_stat_len
    call    do_write_err
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    do_write_err
    mov     rsi, str_colon_space
    mov     edx, str_colon_space_len
    call    do_write_err
    mov     rdi, ENOENT
    call    errno_to_msg
    call    do_write_err
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write_err
    mov     ebp, 1
    jmp     .cp_done

.cp_open_src_err:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_open
    mov     edx, str_cannot_open_len
    call    do_write_err
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    do_write_err
    mov     rsi, str_colon_space
    mov     edx, str_colon_space_len
    call    do_write_err
    mov     rdi, ENOENT
    call    errno_to_msg
    call    do_write_err
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write_err
    mov     ebp, 1
    jmp     .cp_done

.cp_open_dst_err:
    neg     rax
    push    rax
    ; Close src
    pop     rdi
    push    rdi
    mov     edi, [rsp + 8]
    mov     eax, SYS_CLOSE
    syscall
    pop     rax
    pop     rdi                  ; discard src fd
    push    rax
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_create
    mov     edx, str_cannot_create_len
    call    do_write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_colon_space
    mov     edx, str_colon_space_len
    call    do_write_err
    pop     rdi
    call    errno_to_msg
    call    do_write_err
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write_err
    mov     ebp, 1
    jmp     .cp_done

.cp_link_err:
    neg     rax
    push    rax
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_create
    mov     edx, str_cannot_create_len
    call    do_write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_colon_space
    mov     edx, str_colon_space_len
    call    do_write_err
    pop     rdi
    call    errno_to_msg
    call    do_write_err
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write_err
    mov     ebp, 1
    jmp     .cp_done

.cp_mkdir_err:
    neg     rax
    push    rax
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_create
    mov     edx, str_cannot_create_len
    call    do_write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_colon_space
    mov     edx, str_colon_space_len
    call    do_write_err
    pop     rdi
    call    errno_to_msg
    call    do_write_err
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write_err
    mov     ebp, 1
    jmp     .cp_done

.cp_open_dir_err:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_open
    mov     edx, str_cannot_open_len
    call    do_write_err
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    do_write_err
    mov     rsi, str_colon_space
    mov     edx, str_colon_space_len
    call    do_write_err
    mov     rdi, EACCES
    call    errno_to_msg
    call    do_write_err
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write_err
    mov     ebp, 1
    jmp     .cp_done

.cp_done:
    pop     r14
    pop     r13
    pop     r12
    ret

; print_verbose: "'src' -> 'dst'\n"
print_verbose:
    push    r12
    push    r13
    mov     rsi, str_sq
    mov     edx, 1
    mov     edi, STDOUT
    call    do_write
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    mov     edi, STDOUT
    call    do_write
    mov     rsi, str_arrow
    mov     edx, str_arrow_len
    mov     edi, STDOUT
    call    do_write
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    mov     edi, STDOUT
    call    do_write
    mov     rsi, str_sq_nl
    mov     edx, 2
    mov     edi, STDOUT
    call    do_write
    pop     r13
    pop     r12
    ret

; ============================================================
; basename
; ============================================================
basename:
    push    rdi
    call    str_len
    mov     ecx, eax
    pop     rdi
    test    ecx, ecx
    jz      .bn_start
    dec     ecx
.bn_strip:
    cmp     ecx, 0
    jl      .bn_start
    cmp     byte [rdi + rcx], '/'
    jne     .bn_scan
    dec     ecx
    jmp     .bn_strip
.bn_scan:
    mov     eax, ecx
.bn_find:
    cmp     eax, 0
    jl      .bn_start
    cmp     byte [rdi + rax], '/'
    je      .bn_found
    dec     eax
    jmp     .bn_find
.bn_found:
    inc     eax
    lea     rax, [rdi + rax]
    ret
.bn_start:
    mov     rax, rdi
    ret

; ============================================================
; errno_to_msg
; ============================================================
errno_to_msg:
    cmp     edi, EPERM
    je      .e_eperm
    cmp     edi, ENOENT
    je      .e_enoent
    cmp     edi, EIO
    je      .e_eio
    cmp     edi, EACCES
    je      .e_eacces
    cmp     edi, EEXIST
    je      .e_eexist
    cmp     edi, ENOTDIR
    je      .e_enotdir
    cmp     edi, EISDIR
    je      .e_eisdir
    cmp     edi, EINVAL
    je      .e_einval
    cmp     edi, ENOSPC
    je      .e_enospc
    cmp     edi, EROFS
    je      .e_erofs
    cmp     edi, ENOTEMPTY
    je      .e_enotempty
    mov     rsi, str_err_unknown
    mov     edx, str_err_unknown_len
    ret
.e_eperm:
    mov     rsi, str_err_eperm
    mov     edx, str_err_eperm_len
    ret
.e_enoent:
    mov     rsi, str_err_enoent
    mov     edx, str_err_enoent_len
    ret
.e_eio:
    mov     rsi, str_err_eio
    mov     edx, str_err_eio_len
    ret
.e_eacces:
    mov     rsi, str_err_eacces
    mov     edx, str_err_eacces_len
    ret
.e_eexist:
    mov     rsi, str_err_eexist
    mov     edx, str_err_eexist_len
    ret
.e_enotdir:
    mov     rsi, str_err_enotdir
    mov     edx, str_err_enotdir_len
    ret
.e_eisdir:
    mov     rsi, str_err_eisdir
    mov     edx, str_err_eisdir_len
    ret
.e_einval:
    mov     rsi, str_err_einval
    mov     edx, str_err_einval_len
    ret
.e_enospc:
    mov     rsi, str_err_enospc
    mov     edx, str_err_enospc_len
    ret
.e_erofs:
    mov     rsi, str_err_erofs
    mov     edx, str_err_erofs_len
    ret
.e_enotempty:
    mov     rsi, str_err_enotempty
    mov     edx, str_err_enotempty_len
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

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: cp [OPTION]... [-T] SOURCE DEST", 10
    db "  or:  cp [OPTION]... SOURCE... DIRECTORY", 10
    db "  or:  cp [OPTION]... -t DIRECTORY SOURCE...", 10
    db "Copy SOURCE to DEST, or multiple SOURCE(s) to DIRECTORY.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -a, --archive                same as -dR --preserve=all", 10
    db "  -f, --force                  if an existing destination file cannot be", 10
    db "                                 opened, remove it and try again", 10
    db "  -i, --interactive            prompt before overwrite", 10
    db "  -l, --link                   hard link files instead of copying", 10
    db "  -n, --no-clobber             do not overwrite an existing file", 10
    db "  -p                           same as --preserve=mode,ownership,timestamps", 10
    db "  -r, -R, --recursive          copy directories recursively", 10
    db "  -s, --symbolic-link          make symbolic links instead of copying", 10
    db "  -T, --no-target-directory    treat DEST as a normal file", 10
    db "  -v, --verbose                explain what is being done", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/cp>", 10
    db "or available locally via: info '(coreutils) cp invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "cp (GNU coreutils) 9.4", 10
    db "Copyright (C) 2023 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Torbjorn Granlund, David MacKenzie, and Jim Meyering.", 10
str_version_len equ $ - str_version

str_prefix:      db "cp: "
str_prefix_len   equ $ - str_prefix
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_missing:     db "missing file operand", 10
str_missing_len  equ $ - str_missing
str_missing_dest: db "missing destination file operand after '"
str_missing_dest_len equ $ - str_missing_dest
str_sq:          db "'"
str_sq_nl:       db "'", 10
str_try:         db "Try 'cp --help' for more information.", 10
str_try_len      equ $ - str_try
str_cannot_stat: db "cannot stat '"
str_cannot_stat_len equ $ - str_cannot_stat
str_cannot_open: db "cannot open '"
str_cannot_open_len equ $ - str_cannot_open
str_cannot_create: db "cannot create regular file '"
str_cannot_create_len equ $ - str_cannot_create
str_colon_space: db "': "
str_colon_space_len equ $ - str_colon_space
str_arrow:       db "' -> '"
str_arrow_len    equ $ - str_arrow
str_omitting:    db "-r not specified; omitting directory '"
str_omitting_len equ $ - str_omitting
str_target_str:  db "target '"
str_target_str_len equ $ - str_target_str
str_not_a_dir:   db "' is not a directory", 10
str_not_a_dir_len equ $ - str_not_a_dir
; @@DATA_END@@

; Error messages
str_err_eperm:       db "Operation not permitted"
str_err_eperm_len    equ $ - str_err_eperm
str_err_enoent:      db "No such file or directory"
str_err_enoent_len   equ $ - str_err_enoent
str_err_eio:         db "Input/output error"
str_err_eio_len      equ $ - str_err_eio
str_err_eacces:      db "Permission denied"
str_err_eacces_len   equ $ - str_err_eacces
str_err_eexist:      db "File exists"
str_err_eexist_len   equ $ - str_err_eexist
str_err_enotdir:     db "Not a directory"
str_err_enotdir_len  equ $ - str_err_enotdir
str_err_eisdir:      db "Is a directory"
str_err_eisdir_len   equ $ - str_err_eisdir
str_err_einval:      db "Invalid argument"
str_err_einval_len   equ $ - str_err_einval
str_err_enospc:      db "No space left on device"
str_err_enospc_len   equ $ - str_err_enospc
str_err_erofs:       db "Read-only file system"
str_err_erofs_len    equ $ - str_err_erofs
str_err_enotempty:   db "Directory not empty"
str_err_enotempty_len equ $ - str_err_enotempty
str_err_unknown:     db "Unknown error"
str_err_unknown_len  equ $ - str_err_unknown

str_newline:     db 10
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_force_flag:  db "--force", 0
str_recursive_flag: db "--recursive", 0
str_verbose_flag: db "--verbose", 0
str_noclobber_flag: db "--no-clobber", 0
str_archive_flag: db "--archive", 0
str_no_target_dir_flag: db "--no-target-directory", 0

file_size equ $ - $$
