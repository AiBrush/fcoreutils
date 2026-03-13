; ============================================================
; fchown_unified.asm -- GNU-compatible 'chown' command
; Builds with: nasm -f bin fchown_unified.asm -o fchown
;
; Usage: chown [OPTION]... [OWNER][:[GROUP]] FILE...
;        chown [OPTION]... --reference=RFILE FILE...
;
; Global register allocation (main):
;   r14d = argc, r15 = argv, ebx = flags, ebp = exit code
;   r13d = file arg index
;   Target uid/gid stored in g_target_uid / g_target_gid (writable globals)
;
; Flags in ebx:
;   bit 0 = -v (verbose)
;   bit 1 = -c (changes only)
;   bit 2 = -R (recursive)
;   bit 4 = -h (--no-dereference)
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
%define SYS_EXIT        60
%define SYS_CHOWN       92
%define SYS_LCHOWN      94
%define SYS_GETDENTS64 217
%define SYS_OPENAT     257

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13

%define O_RDONLY        0
%define O_DIRECTORY     0x10000
%define AT_FDCWD       -100

%define STAT_MODE       24
%define STAT_UID        28
%define STAT_GID        32
%define STAT_BUF_SIZE   144

%define S_IFMT      0xF000
%define S_IFDIR     0x4000

%define EPERM           1
%define ENOENT          2
%define EACCES         13
%define ENOTDIR        20
%define EINVAL         22
%define ENAMETOOLONG   36
%define ELOOP          40
%define EROFS          30

%define PATH_MAX       4096
%define DIRBUF_SIZE    8192
%define FILE_BUF_SIZE  8192

; --- ELF Header ---
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

phdr:
    dd 1, 7
    dq 0, $$, $$, file_size, file_size, 0x200000

    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 0x10

; ============================================================
_start:
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
    mov     dword [g_target_uid], -1
    mov     dword [g_target_gid], -1
    mov     ecx, 1

    sub     rsp, 8
    mov     qword [rsp], 0      ; ref_path

.parse_opts:
    cmp     ecx, r14d
    jge     .err_missing_operand
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
    cmp     al, 'v'
    je      .sv
    cmp     al, 'c'
    je      .sc
    cmp     al, 'R'
    je      .sr
    cmp     al, 'h'
    je      .sh
    cmp     al, 'f'
    je      .sf
    push    rcx
    push    rdi
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    do_write_err
    pop     rdi
    push    rdi
    mov     rsi, rdi
    mov     edx, 1
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    pop     rdi
    pop     rcx
    jmp     .exit1

.sv: or bl, 1
    inc     rdi
    jmp     .short_loop
.sc: or bl, 2
    inc     rdi
    jmp     .short_loop
.sr: or bl, 4
    inc     rdi
    jmp     .short_loop
.sh: or bl, 16
    inc     rdi
    jmp     .short_loop
.sf: inc rdi
    jmp     .short_loop

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    push    rcx
    mov     r13, rdi

    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .Lhelp
    mov     rdi, r13
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .Lversion
    mov     rdi, r13
    mov     rsi, str_verbose_flag
    call    str_eq
    test    eax, eax
    jnz     .Lverbose
    mov     rdi, r13
    mov     rsi, str_changes_flag
    call    str_eq
    test    eax, eax
    jnz     .Lchanges
    mov     rdi, r13
    mov     rsi, str_recursive_flag
    call    str_eq
    test    eax, eax
    jnz     .Lrecursive
    mov     rdi, r13
    mov     rsi, str_noderef_flag
    call    str_eq
    test    eax, eax
    jnz     .Lnoderef
    mov     rdi, r13
    mov     rsi, str_deref_flag
    call    str_eq
    test    eax, eax
    jnz     .Lderef
    mov     rdi, r13
    mov     rsi, str_no_preserve_root
    call    str_eq
    test    eax, eax
    jnz     .Lnopreserve
    mov     rdi, r13
    mov     rsi, str_preserve_root
    call    str_eq
    test    eax, eax
    jnz     .Laccept
    mov     rdi, r13
    mov     rsi, str_from_prefix
    call    str_starts_with
    test    eax, eax
    jnz     .Laccept
    mov     rdi, r13
    mov     rsi, str_reference_prefix
    call    str_starts_with
    test    eax, eax
    jnz     .Lreference

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
    jmp     .exit1

.Lhelp:
    pop     rcx
    jmp     .show_help
.Lversion:
    pop     rcx
    jmp     .show_version
.Lverbose:
    pop     rcx
    or      bl, 1
    jmp     .next_opt
.Lchanges:
    pop     rcx
    or      bl, 2
    jmp     .next_opt
.Lrecursive:
    pop     rcx
    or      bl, 4
    jmp     .next_opt
.Lnoderef:
    pop     rcx
    or      bl, 16
    jmp     .next_opt
.Lderef:
    pop     rcx
    and     bl, 0xEF
    jmp     .next_opt
.Lnopreserve:
    pop     rcx
    or      bl, 32
    jmp     .next_opt
.Laccept:
    pop     rcx
    jmp     .next_opt
.Lreference:
    pop     rcx
    lea     rax, [r13 + 12]
    mov     [rsp], rax
    or      bl, 8
    jmp     .next_opt

.double_dash:
    inc     ecx
    jmp     .done_opts
.next_opt:
    inc     ecx
    jmp     .parse_opts

; ── Done parsing ─────────────────────────────
.done_opts:
    test    bl, 8
    jnz     .ref_mode

    cmp     ecx, r14d
    jge     .err_missing_operand
    mov     r13d, ecx

    mov     rdi, [r15 + rcx*8]
    call    parse_owner_group
    ; eax = uid (-1 unchanged, -2 error), edx = gid (-1 unchanged)
    cmp     eax, -2
    je      .err_invalid_user

    mov     [g_target_uid], eax
    mov     [g_target_gid], edx

    lea     ecx, [r13d + 1]
    cmp     ecx, r14d
    jge     .err_missing_file
    mov     r13d, ecx
    add     rsp, 8
    jmp     .process_files

.ref_mode:
    mov     rdi, [rsp]
    sub     rsp, STAT_BUF_SIZE
    mov     rsi, rsp
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .ref_stat_err
    mov     eax, [rsp + STAT_UID]
    mov     [g_target_uid], eax
    mov     eax, [rsp + STAT_GID]
    mov     [g_target_gid], eax
    add     rsp, STAT_BUF_SIZE
    cmp     ecx, r14d
    jge     .err_missing_file_ref
    mov     r13d, ecx
    add     rsp, 8
    jmp     .process_files

.ref_stat_err:
    neg     rax
    mov     r8d, eax
    add     rsp, STAT_BUF_SIZE
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_failed_ref
    mov     edx, str_failed_ref_len
    call    do_write_err
    mov     rdi, [rsp]
    call    str_len
    mov     edx, eax
    mov     rsi, [rsp]
    call    do_write_err
    mov     rsi, str_colon_sep
    mov     edx, str_colon_sep_len
    call    do_write_err
    mov     eax, r8d
    call    print_errno
    jmp     .exit1

.err_invalid_user:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid_user
    mov     edx, str_invalid_user_len
    call    do_write_err
    mov     rdi, [r15 + r13*8]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + r13*8]
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    jmp     .exit1

.process_files:
.file_loop:
    cmp     r13d, r14d
    jge     .exit_done
    mov     rdi, [r15 + r13*8]
    call    do_chown_file
    inc     r13d
    jmp     .file_loop

.exit_done:
    mov     edi, ebp
    jmp     do_exit
.exit1:
    mov     edi, 1
    jmp     do_exit

.show_help:
    add     rsp, 8
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.show_version:
    add     rsp, 8
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.err_missing_operand:
    add     rsp, 8
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing
    mov     edx, str_missing_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    jmp     .exit1

.err_missing_file:
    add     rsp, 8
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing_after
    mov     edx, str_missing_after_len
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
    jmp     .exit1

.err_missing_file_ref:
    add     rsp, STAT_BUF_SIZE + 8
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing_file
    mov     edx, str_missing_file_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    jmp     .exit1

; ============================================================
; do_chown_file
; ============================================================
do_chown_file:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, STAT_BUF_SIZE + 16

    mov     r15, rdi
    mov     r13d, ebx

    mov     rdi, r15
    mov     rsi, rsp
    test    r13d, 16
    jnz     .cf_lstat
    mov     eax, SYS_STAT
    jmp     .cf_stat
.cf_lstat:
    mov     eax, SYS_LSTAT
.cf_stat:
    syscall
    test    rax, rax
    js      .cf_stat_err

    mov     r12d, [rsp + STAT_UID]
    mov     r14d, [rsp + STAT_GID]

    mov     esi, [g_target_uid]
    mov     edx, [g_target_gid]

    mov     rdi, r15
    test    r13d, 16
    jnz     .cf_lchown
    mov     eax, SYS_CHOWN
    syscall
    jmp     .cf_result
.cf_lchown:
    mov     eax, SYS_LCHOWN
    syscall

.cf_result:
    test    rax, rax
    js      .cf_chown_err

    test    r13d, 3
    jz      .cf_recurse

    ; Compute actual new uid/gid
    mov     eax, [g_target_uid]
    cmp     eax, -1
    jne     .cf_u1
    mov     eax, r12d
.cf_u1:
    mov     [rsp + STAT_BUF_SIZE + 8], eax  ; new uid

    mov     eax, [g_target_gid]
    cmp     eax, -1
    jne     .cf_g1
    mov     eax, r14d
.cf_g1:
    mov     [rsp + STAT_BUF_SIZE + 12], eax ; new gid

    ; -c: only if changed
    test    r13d, 2
    jz      .cf_verbose
    mov     eax, [rsp + STAT_BUF_SIZE + 8]
    cmp     r12d, eax
    jne     .cf_verbose
    mov     eax, [rsp + STAT_BUF_SIZE + 12]
    cmp     r14d, eax
    jne     .cf_verbose
    jmp     .cf_recurse

.cf_verbose:
    mov     eax, [rsp + STAT_BUF_SIZE + 8]
    cmp     r12d, eax
    jne     .cf_changed
    mov     eax, [rsp + STAT_BUF_SIZE + 12]
    cmp     r14d, eax
    jne     .cf_changed

    ; Retained
    mov     rsi, str_owner_of
    mov     edx, str_owner_of_len
    call    do_write_stdout
    mov     rdi, r15
    call    str_len
    mov     edx, eax
    mov     rsi, r15
    call    do_write_stdout
    mov     rsi, str_retained
    mov     edx, str_retained_len
    call    do_write_stdout
    mov     edi, r12d
    call    print_uint
    mov     rsi, str_colon_char
    mov     edx, 1
    call    do_write_stdout
    mov     edi, r14d
    call    print_uint
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write_stdout
    jmp     .cf_recurse

.cf_changed:
    mov     rsi, str_changed_own
    mov     edx, str_changed_own_len
    call    do_write_stdout
    mov     rdi, r15
    call    str_len
    mov     edx, eax
    mov     rsi, r15
    call    do_write_stdout
    mov     rsi, str_sq_from
    mov     edx, str_sq_from_len
    call    do_write_stdout
    mov     edi, r12d
    call    print_uint
    mov     rsi, str_colon_char
    mov     edx, 1
    call    do_write_stdout
    mov     edi, r14d
    call    print_uint
    mov     rsi, str_to
    mov     edx, str_to_len
    call    do_write_stdout
    mov     edi, [rsp + STAT_BUF_SIZE + 8]
    call    print_uint
    mov     rsi, str_colon_char
    mov     edx, 1
    call    do_write_stdout
    mov     edi, [rsp + STAT_BUF_SIZE + 12]
    call    print_uint
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write_stdout

.cf_recurse:
    test    r13d, 4
    jz      .cf_done
    movzx   eax, word [rsp + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFDIR
    jne     .cf_done
    mov     rdi, r15
    call    do_chown_recurse
    jmp     .cf_done

.cf_stat_err:
    neg     rax
    mov     r8d, eax
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_access
    mov     edx, str_cannot_access_len
    call    do_write_err
    mov     rdi, r15
    call    str_len
    mov     edx, eax
    mov     rsi, r15
    call    do_write_err
    mov     rsi, str_colon_sep
    mov     edx, str_colon_sep_len
    call    do_write_err
    mov     eax, r8d
    call    print_errno
    mov     ebp, 1
    jmp     .cf_done

.cf_chown_err:
    neg     rax
    mov     r8d, eax
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_changing_own
    mov     edx, str_changing_own_len
    call    do_write_err
    mov     rdi, r15
    call    str_len
    mov     edx, eax
    mov     rsi, r15
    call    do_write_err
    mov     rsi, str_colon_sep
    mov     edx, str_colon_sep_len
    call    do_write_err
    mov     eax, r8d
    call    print_errno
    mov     ebp, 1

.cf_done:
    add     rsp, STAT_BUF_SIZE + 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; do_chown_recurse
; ============================================================
do_chown_recurse:
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15, rdi

    mov     eax, SYS_OPENAT
    mov     edi, AT_FDCWD
    mov     rsi, r15
    mov     edx, O_RDONLY | O_DIRECTORY
    xor     r10d, r10d
    syscall
    test    rax, rax
    js      .cr_err
    mov     r14d, eax

    sub     rsp, DIRBUF_SIZE + PATH_MAX + 8

.cr_read:
    mov     eax, SYS_GETDENTS64
    mov     edi, r14d
    lea     rsi, [rsp]
    mov     edx, DIRBUF_SIZE
    syscall
    test    rax, rax
    jz      .cr_close
    js      .cr_close
    mov     r13, rax
    xor     r12d, r12d

.cr_entry:
    cmp     r12d, r13d
    jge     .cr_read
    movzx   ecx, word [rsp + r12 + 16]
    lea     rdi, [rsp + r12 + 19]

    cmp     byte [rdi], '.'
    jne     .cr_proc
    cmp     byte [rdi + 1], 0
    je      .cr_skip
    cmp     byte [rdi + 1], '.'
    jne     .cr_proc
    cmp     byte [rdi + 2], 0
    je      .cr_skip

.cr_proc:
    push    rcx
    lea     r8, [rsp + DIRBUF_SIZE + 8]
    mov     rdi, r15
    push    r8
    call    str_len
    pop     r8
    mov     ecx, eax
    mov     rdi, r8
    mov     rsi, r15
    rep movsb
    mov     byte [rdi], '/'
    inc     rdi
    pop     rcx
    push    rcx
    lea     rsi, [rsp + r12 + 19 + 8]
    push    rdi
    mov     rdi, rsi
    call    str_len
    pop     rdi
    mov     ecx, eax
    lea     rsi, [rsp + r12 + 19 + 8]
    rep movsb
    mov     byte [rdi], 0

    lea     rdi, [rsp + DIRBUF_SIZE + 8]
    push    r12
    push    r13
    push    r14
    call    do_chown_file
    pop     r14
    pop     r13
    pop     r12
    pop     rcx

.cr_skip:
    add     r12d, ecx
    jmp     .cr_entry

.cr_close:
    mov     eax, SYS_CLOSE
    mov     edi, r14d
    syscall
    add     rsp, DIRBUF_SIZE + PATH_MAX + 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

.cr_err:
    neg     rax
    mov     r8d, eax
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_access
    mov     edx, str_cannot_access_len
    call    do_write_err
    mov     rdi, r15
    call    str_len
    mov     edx, eax
    mov     rsi, r15
    call    do_write_err
    mov     rsi, str_colon_sep
    mov     edx, str_colon_sep_len
    call    do_write_err
    mov     eax, r8d
    call    print_errno
    mov     ebp, 1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

; ============================================================
; parse_owner_group: rdi = "OWNER[:GROUP]"
; Returns: eax = uid (-1 unchanged, -2 error), edx = gid (-1 unchanged)
; ============================================================
parse_owner_group:
    push    rbx
    push    r12
    push    r13
    push    r15
    sub     rsp, 264

    mov     r15, rdi
    mov     r12d, -1            ; uid
    mov     r13d, -1            ; gid

    ; Find ':'
    xor     ecx, ecx
.pog_scan:
    movzx   eax, byte [rdi + rcx]
    test    al, al
    jz      .pog_nosep
    cmp     al, ':'
    je      .pog_sep
    inc     ecx
    jmp     .pog_scan

.pog_nosep:
    ; Entire string = OWNER
    mov     rdi, r15
    call    parse_number
    cmp     eax, -1
    jne     .pog_u
    mov     rdi, r15
    call    lookup_user
    test    eax, eax
    jz      .pog_err
    dec     eax                 ; uid+1 -> uid
.pog_u:
    mov     r12d, eax
    jmp     .pog_done

.pog_sep:
    ; ecx = index of ':'
    test    ecx, ecx
    jz      .pog_grp            ; starts with ':', no owner

    ; Copy owner part to buffer
    lea     rdi, [rsp]
    mov     rsi, r15
    mov     r8d, ecx
    push    rcx
    mov     ecx, r8d
    rep movsb
    mov     byte [rdi], 0
    pop     rcx

    push    rcx
    lea     rdi, [rsp + 8]     ; buffer (pushed rcx offsets by 8)
    call    parse_number
    cmp     eax, -1
    jne     .pog_u2
    lea     rdi, [rsp + 8]
    call    lookup_user
    test    eax, eax
    jz      .pog_err2
    dec     eax
.pog_u2:
    mov     r12d, eax
    pop     rcx

.pog_grp:
    ; Group part starts after ':'
    lea     rdi, [r15 + rcx + 1]
    cmp     byte [rdi], 0
    je      .pog_done           ; empty group

    push    rcx
    call    parse_number
    cmp     eax, -1
    jne     .pog_g
    pop     rcx
    push    rcx
    lea     rdi, [r15 + rcx + 1]
    call    lookup_group
    test    eax, eax
    jz      .pog_err3
    dec     eax
.pog_g:
    mov     r13d, eax
    pop     rcx
    jmp     .pog_done

.pog_err3:
    pop     rcx
    jmp     .pog_err
.pog_err2:
    pop     rcx
.pog_err:
    mov     r12d, -2
.pog_done:
    mov     eax, r12d
    mov     edx, r13d
    add     rsp, 264
    pop     r15
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; lookup_user: rdi=name, returns eax=uid+1 (0=not found)
; ============================================================
lookup_user:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15, rdi

    mov     eax, SYS_OPEN
    lea     rdi, [str_etc_passwd]
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    js      .lu_fail
    mov     r14d, eax

    sub     rsp, FILE_BUF_SIZE
    xor     r13d, r13d
    xor     r12d, r12d

.lu_rd:
    mov     eax, SYS_READ
    mov     edi, r14d
    lea     rsi, [rsp + r12]
    mov     edx, FILE_BUF_SIZE
    sub     edx, r12d
    jle     .lu_cfail
    syscall
    test    rax, rax
    jz      .lu_cfail
    js      .lu_cfail
    lea     r13d, [r12d + eax]
    xor     r12d, r12d

.lu_lines:
    mov     ecx, r12d
.lu_nl:
    cmp     ecx, r13d
    jge     .lu_more
    cmp     byte [rsp + rcx], 10
    je      .lu_line
    inc     ecx
    jmp     .lu_nl

.lu_line:
    push    rcx
    lea     rdi, [rsp + r12 + 8]
    mov     rsi, r15
    call    match_passwd
    test    eax, eax
    jnz     .lu_ok
    pop     rcx
    lea     r12d, [ecx + 1]
    jmp     .lu_lines

.lu_more:
    cmp     r12d, 0
    je      .lu_cfail
    mov     ecx, r13d
    sub     ecx, r12d
    push    rsi
    push    rdi
    lea     rsi, [rsp + r12 + 16]
    lea     rdi, [rsp + 16]
    push    rcx
    rep movsb
    pop     rcx
    pop     rdi
    pop     rsi
    mov     r13d, ecx
    xor     r12d, r12d
    jmp     .lu_rd

.lu_ok:
    pop     rcx
    add     rsp, FILE_BUF_SIZE
    push    rax
    mov     eax, SYS_CLOSE
    mov     edi, r14d
    syscall
    pop     rax              ; eax = uid+1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.lu_cfail:
    add     rsp, FILE_BUF_SIZE
    mov     eax, SYS_CLOSE
    mov     edi, r14d
    syscall
.lu_fail:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; lookup_group: rdi=name, returns eax=gid+1 (0=not found)
; ============================================================
lookup_group:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15, rdi

    mov     eax, SYS_OPEN
    lea     rdi, [str_etc_group]
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    js      .lg_fail
    mov     r14d, eax

    sub     rsp, FILE_BUF_SIZE
    xor     r13d, r13d
    xor     r12d, r12d

.lg_rd:
    mov     eax, SYS_READ
    mov     edi, r14d
    lea     rsi, [rsp + r12]
    mov     edx, FILE_BUF_SIZE
    sub     edx, r12d
    jle     .lg_cfail
    syscall
    test    rax, rax
    jz      .lg_cfail
    js      .lg_cfail
    lea     r13d, [r12d + eax]
    xor     r12d, r12d

.lg_lines:
    mov     ecx, r12d
.lg_nl:
    cmp     ecx, r13d
    jge     .lg_more
    cmp     byte [rsp + rcx], 10
    je      .lg_line
    inc     ecx
    jmp     .lg_nl

.lg_line:
    push    rcx
    lea     rdi, [rsp + r12 + 8]
    mov     rsi, r15
    call    match_group
    test    eax, eax
    jnz     .lg_ok
    pop     rcx
    lea     r12d, [ecx + 1]
    jmp     .lg_lines

.lg_more:
    cmp     r12d, 0
    je      .lg_cfail
    mov     ecx, r13d
    sub     ecx, r12d
    push    rsi
    push    rdi
    lea     rsi, [rsp + r12 + 16]
    lea     rdi, [rsp + 16]
    push    rcx
    rep movsb
    pop     rcx
    pop     rdi
    pop     rsi
    mov     r13d, ecx
    xor     r12d, r12d
    jmp     .lg_rd

.lg_ok:
    pop     rcx
    add     rsp, FILE_BUF_SIZE
    push    rax
    mov     eax, SYS_CLOSE
    mov     edi, r14d
    syscall
    pop     rax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.lg_cfail:
    add     rsp, FILE_BUF_SIZE
    mov     eax, SYS_CLOSE
    mov     edi, r14d
    syscall
.lg_fail:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; match_passwd: rdi=line, rsi=name. Returns eax=uid+1 or 0
; ============================================================
match_passwd:
    push    rbx
    xor     ecx, ecx
.mp_cmp:
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .mp_colon
    movzx   edx, byte [rdi + rcx]
    cmp     al, dl
    jne     .mp_no
    inc     ecx
    jmp     .mp_cmp
.mp_colon:
    cmp     byte [rdi + rcx], ':'
    jne     .mp_no
    inc     ecx
.mp_skip:
    cmp     byte [rdi + rcx], ':'
    je      .mp_uid
    cmp     byte [rdi + rcx], 0
    je      .mp_no
    cmp     byte [rdi + rcx], 10
    je      .mp_no
    inc     ecx
    jmp     .mp_skip
.mp_uid:
    inc     ecx
    xor     eax, eax
.mp_parse:
    movzx   edx, byte [rdi + rcx]
    cmp     dl, ':'
    je      .mp_ok
    cmp     dl, 10
    je      .mp_ok
    cmp     dl, 0
    je      .mp_ok
    sub     dl, '0'
    cmp     dl, 9
    ja      .mp_no
    imul    eax, eax, 10
    movzx   edx, dl
    add     eax, edx
    inc     ecx
    jmp     .mp_parse
.mp_ok:
    inc     eax
    pop     rbx
    ret
.mp_no:
    xor     eax, eax
    pop     rbx
    ret

; ============================================================
; match_group: rdi=line, rsi=name. Returns eax=gid+1 or 0
; ============================================================
match_group:
    push    rbx
    xor     ecx, ecx
.mg_cmp:
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .mg_colon
    movzx   edx, byte [rdi + rcx]
    cmp     al, dl
    jne     .mg_no
    inc     ecx
    jmp     .mg_cmp
.mg_colon:
    cmp     byte [rdi + rcx], ':'
    jne     .mg_no
    inc     ecx
.mg_skip:
    cmp     byte [rdi + rcx], ':'
    je      .mg_gid
    cmp     byte [rdi + rcx], 0
    je      .mg_no
    cmp     byte [rdi + rcx], 10
    je      .mg_no
    inc     ecx
    jmp     .mg_skip
.mg_gid:
    inc     ecx
    xor     eax, eax
.mg_parse:
    movzx   edx, byte [rdi + rcx]
    cmp     dl, ':'
    je      .mg_ok
    cmp     dl, 10
    je      .mg_ok
    cmp     dl, 0
    je      .mg_ok
    sub     dl, '0'
    cmp     dl, 9
    ja      .mg_no
    imul    eax, eax, 10
    movzx   edx, dl
    add     eax, edx
    inc     ecx
    jmp     .mg_parse
.mg_ok:
    inc     eax
    pop     rbx
    ret
.mg_no:
    xor     eax, eax
    pop     rbx
    ret

; ============================================================
parse_number:
    xor     eax, eax
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .pn_fail
    cmp     cl, '0'
    jb      .pn_fail
    cmp     cl, '9'
    ja      .pn_fail
.pn_loop:
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .pn_done
    cmp     cl, '0'
    jb      .pn_fail
    cmp     cl, '9'
    ja      .pn_fail
    sub     cl, '0'
    imul    eax, eax, 10
    movzx   ecx, cl
    add     eax, ecx
    inc     rdi
    jmp     .pn_loop
.pn_done: ret
.pn_fail: mov eax, -1
    ret

print_uint:
    sub     rsp, 24
    lea     rcx, [rsp + 20]
    mov     byte [rcx], 0
    mov     eax, edi
    test    eax, eax
    jnz     .pu_lp
    dec     rcx
    mov     byte [rcx], '0'
    jmp     .pu_pr
.pu_lp:
    test    eax, eax
    jz      .pu_pr
    xor     edx, edx
    mov     r8d, 10
    div     r8d
    add     dl, '0'
    dec     rcx
    mov     [rcx], dl
    jmp     .pu_lp
.pu_pr:
    mov     rsi, rcx
    lea     edx, [rsp + 20]
    sub     edx, ecx
    call    do_write_stdout
    add     rsp, 24
    ret

do_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      do_write
    ret
do_write_stdout:
    mov     edi, STDOUT
    jmp     do_write
do_write_err:
    mov     edi, STDERR
    jmp     do_write
do_exit:
    mov     eax, SYS_EXIT
    syscall

str_len:
    xor     eax, eax
.sl: cmp byte [rdi + rax], 0
    je      .sd
    inc     eax
    jmp     .sl
.sd: ret

str_eq:
    xor     r8d, r8d
.se: movzx eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    cmp     al, dl
    jne     .sn
    test    al, al
    jz      .sy
    inc     r8d
    jmp     .se
.sy: mov eax, 1
    ret
.sn: xor eax, eax
    ret

str_starts_with:
    xor     r8d, r8d
.sw: movzx edx, byte [rsi + r8]
    test    dl, dl
    jz      .sm
    movzx   eax, byte [rdi + r8]
    cmp     al, dl
    jne     .sf2
    inc     r8d
    jmp     .sw
.sm: mov eax, 1
    ret
.sf2: xor eax, eax
    ret

print_errno:
    cmp     eax, ENOENT
    je      .pe1
    cmp     eax, EACCES
    je      .pe2
    cmp     eax, EPERM
    je      .pe3
    cmp     eax, ENOTDIR
    je      .pe4
    cmp     eax, EINVAL
    je      .pe5
    cmp     eax, EROFS
    je      .pe6
    cmp     eax, ELOOP
    je      .pe7
    cmp     eax, ENAMETOOLONG
    je      .pe8
    mov     rsi, str_err_unknown
    mov     edx, str_err_unknown_len
    jmp     do_write_err
.pe1: mov rsi, str_err_noent
    mov     edx, str_err_noent_len
    jmp     do_write_err
.pe2: mov rsi, str_err_acces
    mov     edx, str_err_acces_len
    jmp     do_write_err
.pe3: mov rsi, str_err_perm
    mov     edx, str_err_perm_len
    jmp     do_write_err
.pe4: mov rsi, str_err_notdir
    mov     edx, str_err_notdir_len
    jmp     do_write_err
.pe5: mov rsi, str_err_inval
    mov     edx, str_err_inval_len
    jmp     do_write_err
.pe6: mov rsi, str_err_rofs
    mov     edx, str_err_rofs_len
    jmp     do_write_err
.pe7: mov rsi, str_err_loop
    mov     edx, str_err_loop_len
    jmp     do_write_err
.pe8: mov rsi, str_err_nametoolong
    mov     edx, str_err_nametoolong_len
    jmp     do_write_err

; ============================================================
; Data
; ============================================================
g_target_uid: dd 0xFFFFFFFF
g_target_gid: dd 0xFFFFFFFF

str_help:
    db "Usage: chown [OPTION]... [OWNER][:[GROUP]] FILE...", 10
    db "  or:  chown [OPTION]... --reference=RFILE FILE...", 10
    db "Change the owner and/or group of each FILE to OWNER and/or GROUP.", 10
    db "With --reference, change the owner and group of each FILE to those of RFILE.", 10, 10
    db "  -c, --changes          like verbose but report only when a change is made", 10
    db "  -f, --silent, --quiet  suppress most error messages", 10
    db "  -v, --verbose          output a diagnostic for every file processed", 10
    db "      --dereference      affect the referent of each symbolic link (this is", 10
    db "                         the default), rather than the symbolic link itself", 10
    db "  -h, --no-dereference   affect symbolic links instead of any referenced file", 10
    db "                         (useful only on systems that can change the", 10
    db "                         ownership of a symlink)", 10
    db "      --from=CURRENT_OWNER:CURRENT_GROUP", 10
    db "                         change the owner and/or group of each file only if", 10
    db "                         its current owner and/or group match those specified", 10
    db "                         here.", 10
    db "      --no-preserve-root  do not treat '/' specially (the default)", 10
    db "      --preserve-root    fail to operate recursively on '/'", 10
    db "      --reference=RFILE  use RFILE's owner and group rather than specifying", 10
    db "                         OWNER:GROUP values.  RFILE is always dereferenced.", 10
    db "  -R, --recursive        operate on files and directories recursively", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "Owner is unchanged if missing.  Group is unchanged if missing, but changed", 10
    db "to login group if implied by a ':' following a symbolic OWNER.", 10, 10
    db "OWNER and GROUP may be numeric as well as symbolic.", 10, 10
    db "Examples:", 10
    db '  chown root /u        Change the owner of /u to "root".', 10
    db '  chown root:staff /u  Change the owner of /u to "root" and the', 10
    db "                       group to ", '"', "staff", '"', ".", 10
    db "  chown -hR root /u    Change the owner of /u and subfiles to ", '"', "root", '"', ".", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/chown>", 10
    db "or available locally via: info '(coreutils) chown invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "chown (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by David MacKenzie and Jim Meyering.", 10
str_version_len equ $ - str_version

str_prefix:         db "chown: "
str_prefix_len      equ $ - str_prefix
str_unrecog:        db "unrecognized option '"
str_unrecog_len     equ $ - str_unrecog
str_invalid:        db "invalid option -- '"
str_invalid_len     equ $ - str_invalid
str_missing:        db "missing operand", 10
str_missing_len     equ $ - str_missing
str_missing_after:  db "missing operand after '"
str_missing_after_len equ $ - str_missing_after
str_missing_file:   db "missing operand", 10
str_missing_file_len equ $ - str_missing_file
str_sq_nl:          db "'", 10
str_try:            db "Try 'chown --help' for more information.", 10
str_try_len         equ $ - str_try
str_colon_sep:      db "': "
str_colon_sep_len   equ $ - str_colon_sep
str_colon_char:     db ":"
str_cannot_access:  db "cannot access '"
str_cannot_access_len equ $ - str_cannot_access
str_changing_own:   db "changing ownership of '"
str_changing_own_len equ $ - str_changing_own
str_failed_ref:     db "failed to get attributes of '"
str_failed_ref_len  equ $ - str_failed_ref
str_invalid_user:   db "invalid user: '"
str_invalid_user_len equ $ - str_invalid_user
str_changed_own:    db "changed ownership of '"
str_changed_own_len equ $ - str_changed_own
str_owner_of:       db "ownership of '"
str_owner_of_len    equ $ - str_owner_of
str_sq_from:        db "' from "
str_sq_from_len     equ $ - str_sq_from
str_retained:       db "' retained as "
str_retained_len    equ $ - str_retained
str_to:             db " to "
str_to_len          equ $ - str_to
str_newline:        db 10

str_etc_passwd:     db "/etc/passwd", 0
str_etc_group:      db "/etc/group", 0

str_help_flag:      db "--help", 0
str_version_flag:   db "--version", 0
str_verbose_flag:   db "--verbose", 0
str_changes_flag:   db "--changes", 0
str_recursive_flag: db "--recursive", 0
str_noderef_flag:   db "--no-dereference", 0
str_deref_flag:     db "--dereference", 0
str_silent_flag:    db "--silent", 0
str_quiet_flag:     db "--quiet", 0
str_no_preserve_root: db "--no-preserve-root", 0
str_preserve_root:  db "--preserve-root", 0
str_reference_prefix: db "--reference=", 0
str_from_prefix:    db "--from=", 0

str_err_noent:      db "No such file or directory", 10
str_err_noent_len   equ $ - str_err_noent
str_err_acces:      db "Permission denied", 10
str_err_acces_len   equ $ - str_err_acces
str_err_perm:       db "Operation not permitted", 10
str_err_perm_len    equ $ - str_err_perm
str_err_notdir:     db "Not a directory", 10
str_err_notdir_len  equ $ - str_err_notdir
str_err_inval:      db "Invalid argument", 10
str_err_inval_len   equ $ - str_err_inval
str_err_rofs:       db "Read-only file system", 10
str_err_rofs_len    equ $ - str_err_rofs
str_err_loop:       db "Too many levels of symbolic links", 10
str_err_loop_len    equ $ - str_err_loop
str_err_nametoolong: db "File name too long", 10
str_err_nametoolong_len equ $ - str_err_nametoolong
str_err_unknown:    db "Unknown error", 10
str_err_unknown_len equ $ - str_err_unknown

file_size equ $ - $$
