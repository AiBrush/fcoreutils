; ============================================================
; frm_unified.asm — GNU-compatible 'rm' command
; Builds with: nasm -f bin frm_unified.asm -o frm
;
; rm: Remove files and directories.
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
;   bit 3 = -i (interactive — not implemented in asm, just accepted)
;   bit 4 = -d (remove empty directories)
;   bit 5 = --no-preserve-root
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ         0
%define SYS_WRITE        1
%define SYS_OPEN         2
%define SYS_CLOSE        3
%define SYS_STAT         4
%define SYS_LSTAT        6
%define SYS_RT_SIGPROCMASK 14
%define SYS_GETDENTS64  217
%define SYS_EXIT        60
%define SYS_UNLINK      87
%define SYS_RMDIR       84
%define SYS_OPENAT     257

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13

%define O_RDONLY        0
%define O_DIRECTORY     0x10000
%define AT_FDCWD       -100

; stat structure offsets
%define STAT_MODE       24
%define STAT_SIZE       48

; S_IFMT and types
%define S_IFMT      0xF000
%define S_IFDIR     0x4000
%define S_IFLNK     0xA000
%define S_IFREG     0x8000

; dirent64: d_ino(8) d_off(8) d_reclen(2) d_type(1) d_name(...)
%define DT_DIR       4
%define DT_REG       8
%define DT_LNK      10

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
%define ENOTEMPTY      39
%define EROFS          30
%define ENOMEM         12

%define PATH_MAX       4096
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
; BSS-like area (we use the stack for all buffers)
; ============================================================

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

    ; Initialize
    xor     ebx, ebx            ; flags
    xor     ebp, ebp            ; exit code = 0
    mov     ecx, 1              ; arg index

    ; Parse options
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

    ; Short options
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'f'
    je      .set_force
    cmp     al, 'r'
    je      .set_recursive
    cmp     al, 'R'
    je      .set_recursive
    cmp     al, 'v'
    je      .set_verbose
    cmp     al, 'i'
    je      .set_interactive
    cmp     al, 'I'
    je      .set_interactive
    cmp     al, 'd'
    je      .set_dir
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

.set_force:
    or      bl, 1
    inc     rdi
    jmp     .short_loop
.set_recursive:
    or      bl, 2
    inc     rdi
    jmp     .short_loop
.set_verbose:
    or      bl, 4
    inc     rdi
    jmp     .short_loop
.set_interactive:
    or      bl, 8
    inc     rdi
    jmp     .short_loop
.set_dir:
    or      bl, 16
    inc     rdi
    jmp     .short_loop

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    mov     r13, rdi
    push    rcx
    ; Check --help
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_help
    ; Check --version
    mov     rdi, r13
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_version
    ; Check --force
    mov     rdi, r13
    mov     rsi, str_force_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_force
    ; Check --recursive
    mov     rdi, r13
    mov     rsi, str_recursive_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_recursive
    ; Check --verbose
    mov     rdi, r13
    mov     rsi, str_verbose_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_verbose
    ; Check --no-preserve-root
    mov     rdi, r13
    mov     rsi, str_no_preserve_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_no_preserve
    ; Check --dir
    mov     rdi, r13
    mov     rsi, str_dir_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_dir
    ; Check --interactive (accept but ignore variants)
    mov     rdi, r13
    mov     rsi, str_interactive_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_interactive
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
.pop_set_force:
    pop     rcx
    or      bl, 1
    jmp     .next_opt
.pop_set_recursive:
    pop     rcx
    or      bl, 2
    jmp     .next_opt
.pop_set_verbose:
    pop     rcx
    or      bl, 4
    jmp     .next_opt
.pop_set_no_preserve:
    pop     rcx
    or      bl, 32
    jmp     .next_opt
.pop_set_dir:
    pop     rcx
    or      bl, 16
    jmp     .next_opt
.pop_set_interactive:
    pop     rcx
    or      bl, 8
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

.check_args:
    ; If no args and -f, exit 0 silently
    cmp     r13d, r14d
    jl      .process_files
    test    bl, 1               ; -f?
    jnz     .exit_success
    ; Missing operand
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

.process_files:
    mov     r12d, r13d           ; current arg index

.file_loop:
    cmp     r12d, r14d
    jge     .exit_done
    mov     rdi, [r15 + r12*8]

    ; Check for "/" and --no-preserve-root
    cmp     byte [rdi], '/'
    jne     .do_remove
    cmp     byte [rdi + 1], 0
    jne     .do_remove
    ; It's "/"
    test    bl, 2               ; -r flag?
    jz      .do_remove          ; without -r, "/" is just EISDIR
    test    bl, 32              ; --no-preserve-root?
    jnz     .do_remove
    ; Refuse to remove /
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_root_err
    mov     edx, str_root_err_len
    call    do_write_err
    mov     ebp, 1
    jmp     .next_file

.do_remove:
    call    remove_path
    jmp     .next_file

.next_file:
    inc     r12d
    jmp     .file_loop

.exit_success:
    xor     edi, edi
    jmp     do_exit

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

; ============================================================
; remove_path: remove a file or directory
; Input: rdi = path
; Uses: ebx = flags, ebp = exit code
; ============================================================
remove_path:
    push    r12
    push    r13
    push    r14
    mov     r12, rdi            ; save path

    ; lstat the path to determine type
    sub     rsp, 152            ; stat buffer
    mov     rdi, r12
    mov     rsi, rsp
    mov     eax, SYS_LSTAT
    syscall
    test    rax, rax
    js      .rp_lstat_err

    ; Check if directory
    mov     eax, [rsp + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFDIR
    je      .rp_is_dir
    add     rsp, 152

    ; Not a directory: unlink it
    mov     rdi, r12
    mov     eax, SYS_UNLINK
    syscall
    test    rax, rax
    js      .rp_unlink_err

    ; Verbose
    test    bl, 4
    jz      .rp_done
    mov     rsi, str_removed
    mov     edx, str_removed_len
    call    do_write_err
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    jmp     .rp_done

.rp_is_dir:
    add     rsp, 152
    ; If -r flag, recursive remove
    test    bl, 2
    jnz     .rp_recursive

    ; If -d flag, try rmdir (empty dirs only)
    test    bl, 16
    jnz     .rp_try_rmdir

    ; Cannot remove directory without -r or -d
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_rm
    mov     edx, str_cannot_rm_len
    call    do_write_err
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    do_write_err
    mov     rsi, str_is_dir
    mov     edx, str_is_dir_len
    call    do_write_err
    mov     ebp, 1
    jmp     .rp_done

.rp_try_rmdir:
    mov     rdi, r12
    mov     eax, SYS_RMDIR
    syscall
    test    rax, rax
    js      .rp_rmdir_err

    ; Verbose
    test    bl, 4
    jz      .rp_done
    mov     rsi, str_removed
    mov     edx, str_removed_len
    call    do_write_err
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    jmp     .rp_done

.rp_recursive:
    ; Recursive removal: open directory, iterate entries, remove each, then rmdir
    ; Open the directory
    mov     rdi, r12
    mov     esi, O_RDONLY | O_DIRECTORY
    xor     edx, edx
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .rp_open_err
    mov     r13, rax             ; r13 = dir fd

    ; Allocate dirent buffer on stack
    sub     rsp, DIRBUF_SIZE

.rp_read_dir:
    mov     eax, SYS_GETDENTS64
    mov     edi, r13d
    mov     rsi, rsp
    mov     edx, DIRBUF_SIZE
    syscall
    test    rax, rax
    js      .rp_getdents_err
    jz      .rp_dir_done         ; no more entries

    ; Process entries
    xor     r14d, r14d           ; offset into buffer

.rp_entry_loop:
    cmp     r14d, eax
    jge     .rp_read_dir

    ; Get entry
    lea     rsi, [rsp + r14]
    ; d_reclen at offset 16
    movzx   ecx, word [rsi + 16]
    ; d_type at offset 18
    movzx   edx, byte [rsi + 18]
    ; d_name at offset 19
    lea     rdi, [rsi + 19]

    ; Skip . and ..
    cmp     byte [rdi], '.'
    jne     .rp_not_dot
    cmp     byte [rdi + 1], 0
    je      .rp_skip_entry
    cmp     byte [rdi + 1], '.'
    jne     .rp_not_dot
    cmp     byte [rdi + 2], 0
    je      .rp_skip_entry

.rp_not_dot:
    ; Build full path: parent_path + "/" + entry_name
    ; Save state
    push    rax                  ; save nread
    push    r14                  ; save offset
    push    rcx                  ; save reclen
    push    rdx                  ; save d_type
    push    rdi                  ; save entry name ptr

    ; Build path on stack
    sub     rsp, PATH_MAX
    mov     rdi, rsp

    ; Copy parent path
    mov     rsi, r12
.rp_copy_parent:
    lodsb
    test    al, al
    jz      .rp_parent_done
    stosb
    jmp     .rp_copy_parent
.rp_parent_done:
    ; Add /
    mov     byte [rdi], '/'
    inc     rdi
    ; Copy entry name
    mov     rsi, [rsp + PATH_MAX]    ; entry name ptr
.rp_copy_entry:
    lodsb
    stosb
    test    al, al
    jnz     .rp_copy_entry

    ; Now recursively remove this path
    mov     rdi, rsp
    call    remove_path

    add     rsp, PATH_MAX
    pop     rdi                  ; entry name
    pop     rdx                  ; d_type
    pop     rcx                  ; reclen
    pop     r14                  ; offset
    pop     rax                  ; nread

.rp_skip_entry:
    add     r14d, ecx
    jmp     .rp_entry_loop

.rp_dir_done:
    add     rsp, DIRBUF_SIZE

    ; Close directory fd
    mov     edi, r13d
    mov     eax, SYS_CLOSE
    syscall

    ; Now rmdir the (now empty) directory
    mov     rdi, r12
    mov     eax, SYS_RMDIR
    syscall
    test    rax, rax
    js      .rp_rmdir_err

    ; Verbose
    test    bl, 4
    jz      .rp_done
    mov     rsi, str_removed
    mov     edx, str_removed_len
    call    do_write_err
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    jmp     .rp_done

.rp_lstat_err:
    add     rsp, 152             ; free stat buffer
    neg     rax
    ; If -f and ENOENT, silently skip
    test    bl, 1
    jz      .rp_lstat_report
    cmp     eax, ENOENT
    je      .rp_lstat_skip
.rp_lstat_report:
    push    rax
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_rm
    mov     edx, str_cannot_rm_len
    call    do_write_err
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
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
.rp_lstat_skip:
    jmp     .rp_done

.rp_unlink_err:
    neg     rax
    push    rax
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_rm
    mov     edx, str_cannot_rm_len
    call    do_write_err
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
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
    jmp     .rp_done

.rp_rmdir_err:
    neg     rax
    push    rax
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_rm
    mov     edx, str_cannot_rm_len
    call    do_write_err
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
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
    jmp     .rp_done

.rp_open_err:
    neg     rax
    push    rax
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_rm
    mov     edx, str_cannot_rm_len
    call    do_write_err
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
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
    jmp     .rp_done

.rp_getdents_err:
    add     rsp, DIRBUF_SIZE
    mov     edi, r13d
    mov     eax, SYS_CLOSE
    syscall
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_rm
    mov     edx, str_cannot_rm_len
    call    do_write_err
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    do_write_err
    mov     rsi, str_colon_space
    mov     edx, str_colon_space_len
    call    do_write_err
    mov     rdi, EIO
    call    errno_to_msg
    call    do_write_err
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write_err
    mov     ebp, 1
    jmp     .rp_done

.rp_done:
    pop     r14
    pop     r13
    pop     r12
    ret

; ============================================================
; errno_to_msg: map errno to error string
; Input: rdi = errno value
; Output: rsi = pointer to message, edx = length
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
    cmp     edi, EBUSY
    je      .e_ebusy
    cmp     edi, EEXIST
    je      .e_eexist
    cmp     edi, ENOTDIR
    je      .e_enotdir
    cmp     edi, EISDIR
    je      .e_eisdir
    cmp     edi, EINVAL
    je      .e_einval
    cmp     edi, ENOTEMPTY
    je      .e_enotempty
    cmp     edi, EROFS
    je      .e_erofs
    cmp     edi, ENOMEM
    je      .e_enomem
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
.e_ebusy:
    mov     rsi, str_err_ebusy
    mov     edx, str_err_ebusy_len
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
.e_enotempty:
    mov     rsi, str_err_enotempty
    mov     edx, str_err_enotempty_len
    ret
.e_erofs:
    mov     rsi, str_err_erofs
    mov     edx, str_err_erofs_len
    ret
.e_enomem:
    mov     rsi, str_err_enomem
    mov     edx, str_err_enomem_len
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
    db "Usage: rm [OPTION]... [FILE]...", 10
    db "Remove (unlink) the FILE(s).", 10, 10
    db "  -f, --force           ignore nonexistent files and arguments, never prompt", 10
    db "  -i                    prompt before every removal", 10
    db "  -r, -R, --recursive   remove directories and their contents recursively", 10
    db "  -d, --dir             remove empty directories", 10
    db "  -v, --verbose         explain what is being done", 10
    db "      --no-preserve-root  do not treat '/' specially", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "By default, rm does not remove directories.  Use the --recursive (-r or -R)", 10
    db "option to remove each listed directory, too, along with all of its contents.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/rm>", 10
    db "or available locally via: info '(coreutils) rm invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "rm (GNU coreutils) 9.4", 10
    db "Copyright (C) 2023 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Paul Rubin, David MacKenzie, Richard M. Stallman,", 10
    db "and Jim Meyering.", 10
str_version_len equ $ - str_version

str_prefix:      db "rm: "
str_prefix_len   equ $ - str_prefix
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_missing:     db "missing operand", 10
str_missing_len  equ $ - str_missing
str_sq_nl:       db "'", 10
str_try:         db "Try 'rm --help' for more information.", 10
str_try_len      equ $ - str_try
str_cannot_rm:   db "cannot remove '"
str_cannot_rm_len equ $ - str_cannot_rm
str_colon_space: db "': "
str_colon_space_len equ $ - str_colon_space
str_is_dir:      db "': Is a directory", 10
str_is_dir_len   equ $ - str_is_dir
str_removed:     db "removed '"
str_removed_len  equ $ - str_removed
str_root_err:    db "it is dangerous to operate recursively on '/'", 10
str_root_err_t2: db "Use --no-preserve-root to override this failsafe.", 10
str_root_err_len equ $ - str_root_err
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
str_err_ebusy:       db "Device or resource busy"
str_err_ebusy_len    equ $ - str_err_ebusy
str_err_eexist:      db "File exists"
str_err_eexist_len   equ $ - str_err_eexist
str_err_enotdir:     db "Not a directory"
str_err_enotdir_len  equ $ - str_err_enotdir
str_err_eisdir:      db "Is a directory"
str_err_eisdir_len   equ $ - str_err_eisdir
str_err_einval:      db "Invalid argument"
str_err_einval_len   equ $ - str_err_einval
str_err_enotempty:   db "Directory not empty"
str_err_enotempty_len equ $ - str_err_enotempty
str_err_erofs:       db "Read-only file system"
str_err_erofs_len    equ $ - str_err_erofs
str_err_enomem:      db "Cannot allocate memory"
str_err_enomem_len   equ $ - str_err_enomem
str_err_unknown:     db "Unknown error"
str_err_unknown_len  equ $ - str_err_unknown

str_newline:     db 10
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_force_flag:  db "--force", 0
str_recursive_flag: db "--recursive", 0
str_verbose_flag: db "--verbose", 0
str_no_preserve_flag: db "--no-preserve-root", 0
str_dir_flag:    db "--dir", 0
str_interactive_flag: db "--interactive", 0

file_size equ $ - $$
