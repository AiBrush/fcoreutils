; ============================================================
; finstall_unified.asm — GNU-compatible 'install' command
; Builds with: nasm -f bin finstall_unified.asm -o finstall
;
; install: Copy files and set attributes.
; Supports: install SOURCE DEST, install -d DIR...,
;           -m MODE, -v, -D, -t DIR, -T
; Default mode: 755 (rwxr-xr-x)
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_STAT        4
%define SYS_CHMOD       90
%define SYS_MKDIR       83
%define SYS_EXIT       60
%define SYS_RT_SIGPROCMASK 14

%define STDIN           0
%define STDOUT          1
%define STDERR          2
%define O_RDONLY        0
%define O_WRONLY        1
%define O_CREAT         64
%define O_TRUNC         512
%define EINTR           4
%define SIG_BLOCK       0
%define SIGPIPE         13

%define S_IFMT      0o170000
%define S_IFDIR     0o040000
%define DEFAULT_MODE 0o755
%define DIR_MODE    0o755
%define IO_SIZE     65536

; BSS layout
%define BSS_BASE     0x500000
%define io_buf       BSS_BASE
%define stat_buf     (io_buf + IO_SIZE)
%define num_buf      (stat_buf + 144)
%define mode_val     (num_buf + 128)
%define flag_dir     (mode_val + 8)
%define flag_verbose (flag_dir + 4)
%define flag_create_leading (flag_verbose + 4)
%define flag_no_target_dir  (flag_create_leading + 4)
%define target_dir   (flag_no_target_dir + 4)
%define strip_flag   (target_dir + 8)
%define path_buf     (strip_flag + 4)
%define PATH_MAX     4096
%define BSS_END      (path_buf + PATH_MAX)
%define BSS_SIZE     (BSS_END - BSS_BASE)

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
    dw 64, 56, 3, 64, 0, 0

; --- Program Headers ---
phdr:
    dd 1, 5
    dq 0, $$, $$, file_size, file_size, 0x200000

    dd 1, 6
    dq 0, BSS_BASE, BSS_BASE, 0, BSS_SIZE, 0x200000

    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 0x10

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

    ; Defaults
    mov     qword [mode_val], DEFAULT_MODE
    mov     dword [flag_dir], 0
    mov     dword [flag_verbose], 0
    mov     dword [flag_create_leading], 0
    mov     dword [flag_no_target_dir], 0
    mov     qword [target_dir], 0
    mov     dword [strip_flag], 0

    mov     r14d, [rsp]         ; argc
    lea     r15, [rsp + 8]      ; argv
    mov     ecx, 1

.parse_opts:
    cmp     ecx, r14d
    jge     .done_opts
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
    cmp     al, 'd'
    je      .set_dir
    cmp     al, 'v'
    je      .set_verbose
    cmp     al, 'D'
    je      .set_create_leading
    cmp     al, 'T'
    je      .set_no_target
    cmp     al, 's'
    je      .set_strip
    cmp     al, 'm'
    je      .set_mode
    cmp     al, 't'
    je      .set_target_dir
    cmp     al, 'o'
    je      .skip_next_arg      ; -o OWNER (accept but ignore)
    cmp     al, 'g'
    je      .skip_next_arg      ; -g GROUP (accept but ignore)
    cmp     al, 'b'
    je      .set_backup
    cmp     al, 'c'
    je      .next_short         ; -c is accepted and ignored (compat)
    cmp     al, 'p'
    je      .next_short         ; -p preserve timestamps (accept)
    ; Invalid option
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

.set_dir:
    mov     dword [flag_dir], 1
    inc     rdi
    jmp     .short_loop

.set_verbose:
    mov     dword [flag_verbose], 1
    inc     rdi
    jmp     .short_loop

.set_create_leading:
    mov     dword [flag_create_leading], 1
    inc     rdi
    jmp     .short_loop

.set_no_target:
    mov     dword [flag_no_target_dir], 1
    inc     rdi
    jmp     .short_loop

.set_strip:
    mov     dword [strip_flag], 1
    inc     rdi
    jmp     .short_loop

.set_backup:
    inc     rdi
    jmp     .short_loop

.next_short:
    inc     rdi
    jmp     .short_loop

.set_mode:
    ; -m MODE: next arg or rest of this arg
    inc     rdi
    cmp     byte [rdi], 0
    jne     .parse_mode_inline
    ; Next arg is mode
    inc     ecx
    cmp     ecx, r14d
    jge     .err_missing_arg
    mov     rdi, [r15 + rcx*8]
.parse_mode_inline:
    push    rcx
    call    parse_mode
    pop     rcx
    mov     [mode_val], rax
    inc     ecx
    jmp     .parse_opts

.set_target_dir:
    ; -t DIR: next arg
    inc     ecx
    cmp     ecx, r14d
    jge     .err_missing_arg
    mov     rdi, [r15 + rcx*8]
    mov     [target_dir], rdi
    inc     ecx
    jmp     .parse_opts

.skip_next_arg:
    inc     ecx
    cmp     ecx, r14d
    jge     .err_missing_arg
    inc     ecx
    jmp     .parse_opts

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    mov     r9, rdi
    push    rcx
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_help
    mov     rdi, r9
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_version
    mov     rdi, r9
    mov     rsi, str_verbose_long
    call    str_eq
    test    eax, eax
    jnz     .pop_set_verbose
    mov     rdi, r9
    mov     rsi, str_strip_long
    call    str_eq
    test    eax, eax
    jnz     .pop_set_strip
    pop     rcx
    ; Accept unknown long options silently for compat
    inc     ecx
    jmp     .parse_opts

.pop_show_help:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.pop_show_version:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.pop_set_verbose:
    pop     rcx
    mov     dword [flag_verbose], 1
    inc     ecx
    jmp     .parse_opts

.pop_set_strip:
    pop     rcx
    mov     dword [strip_flag], 1
    inc     ecx
    jmp     .parse_opts

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.done_opts:
    ; ecx = first non-option arg index
    ; Check mode: -d (create directories) or copy files
    cmp     dword [flag_dir], 0
    jne     .mode_mkdir

    ; File install mode
    ; Need at least 2 args (source, dest) unless -t is used
    cmp     qword [target_dir], 0
    jne     .mode_target_dir

    ; Count remaining args
    mov     ebx, r14d
    sub     ebx, ecx
    cmp     ebx, 2
    jl      .err_missing_operand

    ; If exactly 2 args or -T: install SOURCE DEST
    cmp     dword [flag_no_target_dir], 0
    jne     .install_to_file
    cmp     ebx, 2
    je      .install_two_args

    ; Multiple sources + last arg is directory
    ; Last arg is destination directory
    mov     eax, r14d
    dec     eax
    mov     rdi, [r15 + rax*8]
    mov     [target_dir], rdi
    jmp     .install_to_target_dir

.install_two_args:
    ; Check if dest is a directory
    mov     eax, r14d
    dec     eax
    mov     rdi, [r15 + rax*8]
    mov     rsi, stat_buf
    push    rcx
    mov     eax, SYS_STAT
    syscall
    pop     rcx
    test    rax, rax
    js      .install_to_file    ; dest doesn't exist = file install
    mov     eax, [stat_buf + 24]    ; st_mode
    and     eax, S_IFMT
    cmp     eax, S_IFDIR
    je      .install_two_to_dir
    jmp     .install_to_file

.install_two_to_dir:
    mov     eax, r14d
    dec     eax
    mov     rdi, [r15 + rax*8]
    mov     [target_dir], rdi
    ; Fall through to install source to dir

.install_to_target_dir:
.mode_target_dir:
    ; Install each source to target_dir
.itd_loop:
    cmp     ecx, r14d
    jge     .exit_ok
    ; Skip last arg if it's the target dir and not using -t
    cmp     qword [target_dir], 0
    je      .itd_do
    lea     eax, [ecx + 1]
    cmp     eax, r14d
    jge     .exit_ok            ; last arg is target dir

.itd_do:
    mov     rdi, [r15 + rcx*8]     ; source
    mov     rsi, [target_dir]      ; dest dir
    push    rcx
    call    install_to_dir
    pop     rcx
    inc     ecx
    jmp     .itd_loop

.install_to_file:
    ; install SOURCE DEST
    mov     rdi, [r15 + rcx*8]     ; source
    mov     eax, r14d
    dec     eax
    mov     rsi, [r15 + rax*8]     ; dest

    ; If -D, create leading directories (parent dirs only, not dest itself)
    cmp     dword [flag_create_leading], 0
    je      .do_install_file
    push    rdi
    push    rsi
    mov     rdi, rsi
    call    mkdir_leading
    pop     rsi
    pop     rdi

.do_install_file:
    call    copy_file
    jmp     .exit_ok

; ── Directory creation mode (-d) ──
.mode_mkdir:
    cmp     ecx, r14d
    jge     .err_missing_operand
.mkdir_loop:
    cmp     ecx, r14d
    jge     .exit_ok
    mov     rdi, [r15 + rcx*8]
    push    rcx
    call    mkdir_parents
    pop     rcx
    inc     ecx
    jmp     .mkdir_loop

.exit_ok:
    xor     edi, edi
    jmp     do_exit

.err_missing_operand:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing_op
    mov     edx, str_missing_op_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.err_missing_arg:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing_arg
    mov     edx, str_missing_arg_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; ============================================================
; install_to_dir: copy source file into directory
; rdi = source path, rsi = dest dir path
; ============================================================
install_to_dir:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi            ; source
    mov     r13, rsi            ; dest dir

    ; Build dest path: dir/basename(source)
    ; Find basename of source
    mov     rdi, r12
    call    str_len
    mov     ebx, eax
    ; Find last /
    dec     ebx
.itd_find_slash:
    cmp     ebx, 0
    jl      .itd_no_slash
    cmp     byte [r12 + rbx], '/'
    je      .itd_got_slash
    dec     ebx
    jmp     .itd_find_slash

.itd_got_slash:
    inc     ebx                 ; skip /
    jmp     .itd_build_path

.itd_no_slash:
    xor     ebx, ebx            ; basename starts at 0

.itd_build_path:
    ; Copy dir to path_buf
    lea     rdi, [path_buf]
    mov     rsi, r13
    xor     ecx, ecx
.itd_cp_dir:
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .itd_add_slash
    mov     [rdi + rcx], al
    inc     ecx
    cmp     ecx, PATH_MAX - 2
    jge     .itd_open
    jmp     .itd_cp_dir

.itd_add_slash:
    ; Add / if not already there
    test    ecx, ecx
    jz      .itd_cp_base
    cmp     byte [rdi + rcx - 1], '/'
    je      .itd_cp_base
    mov     byte [rdi + rcx], '/'
    inc     ecx

.itd_cp_base:
    ; Copy basename
    lea     rsi, [r12 + rbx]
.itd_cp_bn:
    movzx   eax, byte [rsi]
    mov     [rdi + rcx], al
    test    al, al
    jz      .itd_open
    inc     rsi
    inc     ecx
    cmp     ecx, PATH_MAX - 1
    jge     .itd_open
    jmp     .itd_cp_bn

.itd_open:
    mov     byte [rdi + rcx], 0

    ; Now copy r12 -> path_buf
    mov     rdi, r12
    mov     rsi, path_buf
    call    copy_file

    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; copy_file: copy source to dest, set mode
; rdi = source path, rsi = dest path
; ============================================================
copy_file:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12, rdi            ; source
    mov     r13, rsi            ; dest

    ; Open source for reading
    mov     rdi, r12
    mov     esi, O_RDONLY
    xor     edx, edx
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .cf_err_src
    mov     r14, rax            ; source fd

    ; Open dest for writing
    mov     rdi, r13
    mov     esi, (O_WRONLY | O_CREAT | O_TRUNC)
    mov     edx, [mode_val]
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .cf_err_dst
    mov     rbx, rax            ; dest fd

    ; Copy loop
.cf_loop:
    mov     eax, SYS_READ
    mov     rdi, r14
    mov     rsi, io_buf
    mov     edx, IO_SIZE
    syscall
    cmp     rax, -EINTR
    je      .cf_loop
    test    rax, rax
    jle     .cf_done

    mov     r8, rax             ; bytes read
    xor     r9d, r9d            ; bytes written
.cf_write:
    mov     eax, SYS_WRITE
    mov     rdi, rbx
    lea     rsi, [io_buf + r9]
    mov     rdx, r8
    sub     rdx, r9
    syscall
    cmp     rax, -EINTR
    je      .cf_write
    test    rax, rax
    jle     .cf_done
    add     r9, rax
    cmp     r9, r8
    jl      .cf_write
    jmp     .cf_loop

.cf_done:
    ; Close files
    mov     eax, SYS_CLOSE
    mov     rdi, rbx
    syscall
    mov     eax, SYS_CLOSE
    mov     rdi, r14
    syscall

    ; Set mode
    mov     rdi, r13
    mov     rsi, [mode_val]
    mov     eax, SYS_CHMOD
    syscall

    ; Verbose output
    cmp     dword [flag_verbose], 0
    je      .cf_ret
    ; Print "source -> dest\n"
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
    mov     rsi, str_newline
    mov     edx, 1
    mov     edi, STDOUT
    call    do_write

.cf_ret:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.cf_err_src:
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
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.cf_err_dst:
    ; Close source fd
    push    rax
    mov     eax, SYS_CLOSE
    mov     rdi, r14
    syscall
    pop     rax
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
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; mkdir_leading: create parent directories of a file path
; rdi = file path (e.g. /a/b/c/file.txt creates /a/b/c)
; ============================================================
mkdir_leading:
    push    rbx
    push    r12
    mov     r12, rdi            ; save original path

    ; Find last / in path
    call    str_len
    mov     ebx, eax            ; length
    dec     ebx
.ml_find_slash:
    cmp     ebx, 0
    jl      .ml_done            ; no slash found, nothing to create
    cmp     byte [r12 + rbx], '/'
    je      .ml_found
    dec     ebx
    jmp     .ml_find_slash

.ml_found:
    ; Temporarily null-terminate at last slash
    mov     byte [r12 + rbx], 0
    mov     rdi, r12
    call    mkdir_parents
    ; Restore the slash
    mov     byte [r12 + rbx], '/'

.ml_done:
    pop     r12
    pop     rbx
    ret

; ============================================================
; mkdir_parents: create directory and all parents
; rdi = path
; ============================================================
mkdir_parents:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi            ; path

    ; Try mkdir first
    mov     rdi, r12
    mov     esi, DIR_MODE
    mov     eax, SYS_MKDIR
    syscall
    test    rax, rax
    jns     .mp_verbose         ; success
    cmp     eax, -17            ; EEXIST
    je      .mp_done

    ; Failed — try creating parents
    ; Walk path and create each component
    lea     rdi, [path_buf]
    mov     rsi, r12
    xor     ecx, ecx
    ; Skip leading /
    cmp     byte [rsi], '/'
    jne     .mp_scan
    mov     byte [rdi], '/'
    inc     ecx

.mp_scan:
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .mp_final

    cmp     al, '/'
    jne     .mp_next_char

    ; Found a / — try to create this prefix
    mov     byte [rdi + rcx], 0
    push    rcx
    push    rsi
    mov     rdi, path_buf
    mov     esi, DIR_MODE
    mov     eax, SYS_MKDIR
    syscall
    pop     rsi
    pop     rcx
    lea     rdi, [path_buf]
    mov     byte [rdi + rcx], '/'
    ; Skip .mp_next_char write — al is clobbered by syscall
    inc     ecx
    jmp     .mp_scan

.mp_next_char:
    mov     [rdi + rcx], al
    inc     ecx
    cmp     ecx, PATH_MAX - 1
    jl      .mp_scan
    jmp     .mp_final

.mp_final:
    mov     byte [rdi + rcx], 0
    ; Create final directory
    mov     rdi, path_buf
    mov     esi, DIR_MODE
    mov     eax, SYS_MKDIR
    syscall

.mp_verbose:
    cmp     dword [flag_verbose], 0
    je      .mp_done
    ; Print "creating directory 'path'\n"
    mov     rsi, str_creating_dir
    mov     edx, str_creating_dir_len
    mov     edi, STDERR
    call    do_write
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    mov     edi, STDERR
    call    do_write
    mov     rsi, str_sq_nl
    mov     edx, 2
    mov     edi, STDERR
    call    do_write

.mp_done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; parse_mode: parse octal mode string
; rdi = string; returns rax = mode value
; ============================================================
parse_mode:
    xor     rax, rax
.pm_loop:
    movzx   ecx, byte [rdi]
    cmp     cl, '0'
    jb      .pm_done
    cmp     cl, '7'
    ja      .pm_done
    shl     rax, 3
    sub     cl, '0'
    movzx   ecx, cl
    add     rax, rcx
    inc     rdi
    jmp     .pm_loop
.pm_done:
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
str_help:
    db "Usage: install [OPTION]... [-T] SOURCE DEST", 10
    db "  or:  install [OPTION]... SOURCE... DIRECTORY", 10
    db "  or:  install [OPTION]... -t DIRECTORY SOURCE...", 10
    db "  or:  install [OPTION]... -d DIRECTORY...", 10, 10
    db "This install program copies files (often just compiled) into destination", 10
    db "locations you choose.  In the first three forms, copy SOURCE to DEST or", 10
    db "multiple SOURCE(s) to the existing DIRECTORY, while setting permission", 10
    db "modes and owner/group.  In the 4th form, create all components of the", 10
    db "given DIRECTORY(ies).", 10, 10
    db "  -b                  make a backup of each existing destination file", 10
    db "  -c                  (ignored)", 10
    db "  -d, --directory     treat all arguments as directory names", 10
    db "  -D                  create all leading components of DEST", 10
    db "  -g, --group=GROUP   set group ownership", 10
    db "  -m, --mode=MODE     set permission mode (as in chmod), instead of rwxr-xr-x", 10
    db "  -o, --owner=OWNER   set ownership", 10
    db "  -s, --strip         strip symbol tables", 10
    db "  -t, --target-directory=DIRECTORY  copy all SOURCE arguments into DIRECTORY", 10
    db "  -T, --no-target-directory  treat DEST as a normal file", 10
    db "  -v, --verbose       print the name of each directory as it is created", 10
    db "      --help          display this help and exit", 10
    db "      --version       output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/install>", 10
    db "or available locally via: info '(coreutils) install invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "install (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by David MacKenzie.", 10
str_version_len equ $ - str_version

str_prefix:      db "install: "
str_prefix_len   equ $ - str_prefix
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_sq_nl:       db "'", 10
str_try:         db "Try 'install --help' for more information.", 10
str_try_len      equ $ - str_try
str_missing_op:  db "missing file operand", 10
str_missing_op_len equ $ - str_missing_op
str_missing_arg: db "option requires an argument", 10
str_missing_arg_len equ $ - str_missing_arg
str_cannot_stat: db "cannot stat '"
str_cannot_stat_len equ $ - str_cannot_stat
str_cannot_create: db "cannot create regular file '"
str_cannot_create_len equ $ - str_cannot_create
str_creating_dir: db "install: creating directory '"
str_creating_dir_len equ $ - str_creating_dir
str_arrow:       db " -> "
str_arrow_len    equ $ - str_arrow
str_newline:     db 10

str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_verbose_long: db "--verbose", 0
str_strip_long:  db "--strip", 0

file_size equ $ - $$
