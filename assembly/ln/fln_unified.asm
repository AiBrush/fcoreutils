; ============================================================
; fln_unified.asm — GNU-compatible 'ln' command
; Builds with: nasm -f bin fln_unified.asm -o fln
;
; ln: Make links between files.
;
; Register allocation:
;   r14d = argc, r15 = argv
;   ebx  = flags (bit0=-s, bit1=-f, bit2=-v, bit3=-n, bit4=-r)
;   r13d = first non-option arg index
;   ebp  = exit code
;
; Flags in ebx:
;   bit 0 = -s (symbolic)
;   bit 1 = -f (force)
;   bit 2 = -v (verbose)
;   bit 3 = -n (no-dereference)
;   bit 4 = -r (relative — only with -s)
;   bit 5 = -T (no-target-directory)
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
%define SYS_ACCESS      21
%define SYS_EXIT        60
%define SYS_UNLINK      87
%define SYS_LINK        86
%define SYS_SYMLINK     88
%define SYS_READLINK    89

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13

%define O_RDONLY        0

; stat structure offsets
%define STAT_MODE       24
%define STAT_SIZE       144

; S_IFMT and S_IFDIR
%define S_IFMT      0xF000
%define S_IFDIR     0x4000
%define S_IFLNK     0xA000

; errno values
%define EPERM           1
%define ENOENT          2
%define EIO             5
%define EACCES         13
%define EEXIST         17
%define EXDEV          18
%define ENOTDIR        20
%define EISDIR         21
%define EINVAL         22
%define ENAMETOOLONG   36
%define ENOSPC         28
%define EROFS          30
%define EMLINK         31
%define ELOOP          40
%define ENOMEM         12
%define EFAULT         14
%define ENOTEMPTY      39

; Stack buffer size
%define PATH_MAX       4096
%define STAT_BUF_SIZE  144+8

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
    dd 1, 5
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

    ; Save argc/argv
    mov     r14d, [rsp]         ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Initialize flags and exit code
    xor     ebx, ebx            ; flags
    xor     ebp, ebp            ; exit code = 0
    mov     ecx, 1              ; arg index

    ; Parse options
.parse_opts:
    cmp     ecx, r14d
    jge     .err_missing_operand
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .done_opts
    cmp     byte [rdi + 1], 0
    je      .done_opts           ; bare "-" is not an option
    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options: -s, -f, -v, -n, -r, -T (can be combined)
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 's'
    je      .set_symbolic
    cmp     al, 'f'
    je      .set_force
    cmp     al, 'v'
    je      .set_verbose
    cmp     al, 'n'
    je      .set_noderef
    cmp     al, 'r'
    je      .set_relative
    cmp     al, 'T'
    je      .set_no_target_dir
    ; Invalid short option
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

.set_symbolic:
    or      bl, 1
    inc     rdi
    jmp     .short_loop
.set_force:
    or      bl, 2
    inc     rdi
    jmp     .short_loop
.set_verbose:
    or      bl, 4
    inc     rdi
    jmp     .short_loop
.set_noderef:
    or      bl, 8
    inc     rdi
    jmp     .short_loop
.set_relative:
    or      bl, 16
    inc     rdi
    jmp     .short_loop
.set_no_target_dir:
    or      bl, 32
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
    ; Check --symbolic
    mov     rdi, r13
    mov     rsi, str_symbolic_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_symbolic
    ; Check --force
    mov     rdi, r13
    mov     rsi, str_force_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_force
    ; Check --verbose
    mov     rdi, r13
    mov     rsi, str_verbose_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_verbose
    ; Check --no-dereference
    mov     rdi, r13
    mov     rsi, str_noderef_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_noderef
    ; Check --relative
    mov     rdi, r13
    mov     rsi, str_relative_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_relative
    ; Check --no-target-directory
    mov     rdi, r13
    mov     rsi, str_no_target_dir_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_no_target_dir
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
.pop_set_symbolic:
    pop     rcx
    or      bl, 1
    jmp     .next_opt
.pop_set_force:
    pop     rcx
    or      bl, 2
    jmp     .next_opt
.pop_set_verbose:
    pop     rcx
    or      bl, 4
    jmp     .next_opt
.pop_set_noderef:
    pop     rcx
    or      bl, 8
    jmp     .next_opt
.pop_set_relative:
    pop     rcx
    or      bl, 16
    jmp     .next_opt
.pop_set_no_target_dir:
    pop     rcx
    or      bl, 32
    jmp     .next_opt

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.done_opts:
    ; ecx = first non-option arg index
    mov     r13d, ecx
    ; Count remaining args
    mov     eax, r14d
    sub     eax, r13d

    ; Need at least 1 arg
    cmp     eax, 0
    jle     .err_missing_operand

    ; If exactly 1 arg: ln TARGET → create link in current dir with same basename
    cmp     eax, 1
    je      .single_arg

    ; If exactly 2 args: ln TARGET LINK_NAME (or ln TARGET DIR)
    cmp     eax, 2
    je      .two_args

    ; More than 2 args: ln TARGET... DIR (last arg must be directory)
    jmp     .multi_args

.single_arg:
    ; ln TARGET → create link with basename of TARGET in current dir
    ; Get target
    mov     rdi, [r15 + r13*8]   ; target

    ; If -s flag, check that we're making a symbolic link
    ; Get basename of target
    push    rdi
    call    basename
    ; rax = pointer to basename part
    mov     r12, rax             ; save basename

    ; Build link name = "." + "/" + basename
    pop     rdi                  ; target

    ; Create the link: target=argv[r13], link_name=basename
    mov     rsi, r12             ; link name = basename
    call    do_link
    jmp     .exit_done

.two_args:
    ; Two args: ln TARGET LINK_NAME
    mov     rdi, [r15 + r13*8]       ; target
    lea     eax, [r13d + 1]
    mov     rsi, [r15 + rax*8]       ; link_name

    ; Check if -T flag is set — if so, treat DEST as normal file
    test    bl, 32
    jnz     .two_args_direct

    ; Check if dest is a directory (stat it)
    ; Use lstat if -n flag, otherwise stat
    push    rdi                  ; save target
    push    rsi                  ; save link_name
    sub     rsp, 152             ; stat buffer
    mov     rdi, rsi             ; path = link_name
    test    bl, 8                ; -n flag?
    jnz     .two_lstat
    mov     eax, SYS_STAT
    mov     rsi, rsp
    syscall
    jmp     .two_check_stat
.two_lstat:
    mov     eax, SYS_LSTAT
    mov     rsi, rsp
    syscall
.two_check_stat:
    test    rax, rax
    js      .two_not_dir         ; stat failed, not a directory
    ; Check mode
    mov     eax, [rsp + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFDIR
    je      .two_is_dir
.two_not_dir:
    add     rsp, 152
    pop     rsi                  ; link_name
    pop     rdi                  ; target
    jmp     .two_args_direct

.two_is_dir:
    ; Dest is a directory: create link inside it
    add     rsp, 152
    ; Stack: [link_name/dir] [target]
    pop     r12                  ; r12 = dir path
    pop     rdi                  ; rdi = target

    ; Get basename of target
    push    rdi                  ; save target
    push    r12                  ; save dir
    call    basename             ; rax = basename of target
    mov     r8, rax              ; r8 = basename ptr

    ; Build path buffer on stack: dir + "/" + basename
    sub     rsp, PATH_MAX
    mov     rdi, rsp             ; dest = buffer start

    ; Copy dir to buffer
    mov     rsi, [rsp + PATH_MAX] ; dir (saved on stack)
.copy_dir:
    lodsb
    test    al, al
    jz      .dir_copied
    stosb
    jmp     .copy_dir
.dir_copied:
    mov     byte [rdi], '/'
    inc     rdi
    ; Copy basename to buffer
    mov     rsi, r8
.copy_bname:
    lodsb
    stosb
    test    al, al
    jnz     .copy_bname

    ; Now call do_link(target, buffer)
    mov     rsi, rsp             ; link_name = constructed path
    mov     rdi, [rsp + PATH_MAX + 8] ; target (saved on stack)
    call    do_link

    add     rsp, PATH_MAX
    pop     r12                  ; dir
    pop     rdi                  ; target (discard)
    jmp     .exit_done

.two_args_direct:
    ; Direct: ln TARGET LINK_NAME
    call    do_link
    jmp     .exit_done

.multi_args:
    ; ln TARGET... DIR — last arg must be directory
    mov     eax, r14d
    dec     eax
    mov     r12, [r15 + rax*8]  ; r12 = last arg = DIR

    ; Stat it to confirm it's a directory
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

    ; It's a directory — iterate targets
    mov     r8d, r13d            ; start index

.multi_loop:
    lea     eax, [r14d - 1]
    cmp     r8d, eax
    jge     .exit_done
    mov     rdi, [r15 + r8*8]   ; target

    ; Get basename of target
    push    r8
    call    basename             ; rax = basename of target
    mov     r9, rax              ; r9 = basename ptr

    ; Build path on stack: dir + "/" + basename
    sub     rsp, PATH_MAX
    mov     rdi, rsp
    mov     rsi, r12             ; dir
.mcopy_dir:
    lodsb
    test    al, al
    jz      .mdir_done
    stosb
    jmp     .mcopy_dir
.mdir_done:
    mov     byte [rdi], '/'
    inc     rdi
    mov     rsi, r9              ; basename
.mcopy_bname:
    lodsb
    stosb
    test    al, al
    jnz     .mcopy_bname

    ; do_link(target, constructed_path)
    mov     r8, [rsp + PATH_MAX] ; restore r8 from stack
    mov     rdi, [r15 + r8*8]   ; target
    mov     rsi, rsp             ; link_name = constructed path
    call    do_link

    add     rsp, PATH_MAX
    pop     r8                   ; index
    inc     r8d
    jmp     .multi_loop

.multi_not_dir:
    add     rsp, 152

    ; Print error: "target 'DIR' is not a directory"
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

; ============================================================
; do_link: create a link (hard or symbolic)
; Input: rdi = target, rsi = link_name
; Uses: ebx = flags, ebp = exit code
; ============================================================
do_link:
    push    r12
    push    r13
    push    r14
    mov     r12, rdi            ; target
    mov     r13, rsi            ; link_name
    mov     r14d, ebx           ; flags

    ; If -f flag, unlink destination first
    test    r14d, 2
    jz      .dl_no_force
    mov     rdi, r13
    mov     eax, SYS_UNLINK
    syscall
    ; Ignore errors (ENOENT is fine)

.dl_no_force:
    ; Create the link
    test    r14d, 1             ; -s flag?
    jnz     .dl_symlink

    ; Hard link: link(target, link_name)
    mov     rdi, r12
    mov     rsi, r13
    mov     eax, SYS_LINK
    syscall
    jmp     .dl_check

.dl_symlink:
    ; Symbolic link: symlink(target, link_name)
    mov     rdi, r12
    mov     rsi, r13
    mov     eax, SYS_SYMLINK
    syscall

.dl_check:
    test    rax, rax
    js      .dl_error

    ; Success — verbose output if -v
    test    r14d, 4
    jz      .dl_done

    ; Print "'LINK_NAME' -> 'TARGET'\n"
    mov     rsi, str_sq
    mov     edx, 1
    mov     edi, STDOUT
    call    do_write
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    mov     edi, STDOUT
    call    do_write
    mov     rsi, str_arrow
    mov     edx, str_arrow_len
    mov     edi, STDOUT
    call    do_write
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    mov     edi, STDOUT
    call    do_write
    mov     rsi, str_sq_nl
    mov     edx, 2
    mov     edi, STDOUT
    call    do_write
    jmp     .dl_done

.dl_error:
    neg     rax
    push    rax                 ; save errno
    mov     ebp, 1              ; set exit code

    ; Print error: "ln: failed to create TYPE link 'LINK' -> 'TARGET': ERROR\n"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err

    mov     rsi, str_failed_create
    mov     edx, str_failed_create_len
    call    do_write_err

    ; Print link type
    test    r14d, 1
    jz      .dl_hard_type
    mov     rsi, str_symbolic_str
    mov     edx, str_symbolic_str_len
    jmp     .dl_type_done
.dl_hard_type:
    mov     rsi, str_hard_str
    mov     edx, str_hard_str_len
.dl_type_done:
    call    do_write_err

    mov     rsi, str_link_sq
    mov     edx, str_link_sq_len
    call    do_write_err

    ; Print link_name
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err

    ; Print "' -> '"  or "': " depending on if symbolic
    test    r14d, 1
    jz      .dl_no_arrow_err
    mov     rsi, str_arrow
    mov     edx, str_arrow_len
    call    do_write_err
    ; Print target
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    do_write_err
.dl_no_arrow_err:
    mov     rsi, str_colon_space
    mov     edx, str_colon_space_len
    call    do_write_err

    pop     rdi                 ; errno
    call    errno_to_msg
    call    do_write_err

    mov     rsi, str_newline
    mov     edx, 1
    call    do_write_err

.dl_done:
    pop     r14
    pop     r13
    pop     r12
    ret

; ============================================================
; basename: get basename of a path
; Input: rdi = path string
; Output: rax = pointer to basename part
; ============================================================
basename:
    push    rdi
    call    str_len
    mov     ecx, eax
    pop     rdi
    ; Start from end, find last '/'
    test    ecx, ecx
    jz      .bn_done_start
    ; Strip trailing slashes
    dec     ecx
.bn_strip_trailing:
    cmp     ecx, 0
    jl      .bn_done_start
    cmp     byte [rdi + rcx], '/'
    jne     .bn_find_slash
    dec     ecx
    jmp     .bn_strip_trailing
.bn_find_slash:
    mov     eax, ecx
.bn_scan:
    cmp     eax, 0
    jl      .bn_done_start
    cmp     byte [rdi + rax], '/'
    je      .bn_found
    dec     eax
    jmp     .bn_scan
.bn_found:
    inc     eax
    lea     rax, [rdi + rax]
    ret
.bn_done_start:
    mov     rax, rdi
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
    cmp     edi, EEXIST
    je      .e_eexist
    cmp     edi, EXDEV
    je      .e_exdev
    cmp     edi, ENOTDIR
    je      .e_enotdir
    cmp     edi, EISDIR
    je      .e_eisdir
    cmp     edi, ENOMEM
    je      .e_enomem
    cmp     edi, EROFS
    je      .e_erofs
    cmp     edi, EMLINK
    je      .e_emlink
    cmp     edi, ENOSPC
    je      .e_enospc
    cmp     edi, ELOOP
    je      .e_eloop
    cmp     edi, ENAMETOOLONG
    je      .e_enametoolong
    cmp     edi, EINVAL
    je      .e_einval
    ; default
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
.e_exdev:
    mov     rsi, str_err_exdev
    mov     edx, str_err_exdev_len
    ret
.e_enotdir:
    mov     rsi, str_err_enotdir
    mov     edx, str_err_enotdir_len
    ret
.e_eisdir:
    mov     rsi, str_err_eisdir
    mov     edx, str_err_eisdir_len
    ret
.e_enomem:
    mov     rsi, str_err_enomem
    mov     edx, str_err_enomem_len
    ret
.e_erofs:
    mov     rsi, str_err_erofs
    mov     edx, str_err_erofs_len
    ret
.e_emlink:
    mov     rsi, str_err_emlink
    mov     edx, str_err_emlink_len
    ret
.e_enospc:
    mov     rsi, str_err_enospc
    mov     edx, str_err_enospc_len
    ret
.e_eloop:
    mov     rsi, str_err_eloop
    mov     edx, str_err_eloop_len
    ret
.e_enametoolong:
    mov     rsi, str_err_enametoolong
    mov     edx, str_err_enametoolong_len
    ret
.e_einval:
    mov     rsi, str_err_einval
    mov     edx, str_err_einval_len
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
    db "Usage: ln [OPTION]... [-T] TARGET LINK_NAME", 10
    db "  or:  ln [OPTION]... TARGET", 10
    db "  or:  ln [OPTION]... TARGET... DIRECTORY", 10
    db "  or:  ln [OPTION]... -t DIRECTORY TARGET...", 10
    db "In the 1st form, create a link to TARGET with the name LINK_NAME.", 10
    db "In the 2nd form, create a link to TARGET in the current directory.", 10
    db "In the 3rd and 4th forms, create links to each TARGET in DIRECTORY.", 10
    db "Create hard links by default, symbolic links with --symbolic.", 10
    db "By default, each destination (name of new link) should not already exist.", 10
    db "When creating hard links, each TARGET must exist.  Symbolic links", 10
    db "can hold arbitrary text; if later resolved, a relative link is", 10
    db "interpreted in relation to its parent directory.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -f, --force                  remove existing destination files", 10
    db "  -n, --no-dereference         treat LINK_NAME as a normal file if", 10
    db "                                 it is a symbolic link to a directory", 10
    db "  -r, --relative               create symbolic links relative to", 10
    db "                                 link location", 10
    db "  -s, --symbolic               make symbolic links instead of hard links", 10
    db "  -T, --no-target-directory    treat LINK_NAME as a normal file always", 10
    db "  -v, --verbose                print name of each linked file", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/ln>", 10
    db "or available locally via: info '(coreutils) ln invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "ln (GNU coreutils) 9.4", 10
    db "Copyright (C) 2023 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Mike Parker and David MacKenzie.", 10
str_version_len equ $ - str_version

str_prefix:      db "ln: "
str_prefix_len   equ $ - str_prefix
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_missing:     db "missing file operand", 10
str_missing_len  equ $ - str_missing
str_sq:          db "'"
str_sq_nl:       db "'", 10
str_try:         db "Try 'ln --help' for more information.", 10
str_try_len      equ $ - str_try
str_failed_create: db "failed to create "
str_failed_create_len equ $ - str_failed_create
str_symbolic_str: db "symbolic "
str_symbolic_str_len equ $ - str_symbolic_str
str_hard_str:     db "hard "
str_hard_str_len  equ $ - str_hard_str
str_link_sq:      db "link '"
str_link_sq_len   equ $ - str_link_sq
str_arrow:        db "' -> '"
str_arrow_len     equ $ - str_arrow
str_colon_space:  db "': "
str_colon_space_len equ $ - str_colon_space
str_target_str:   db "target '"
str_target_str_len equ $ - str_target_str
str_not_a_dir:    db "' is not a directory", 10
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
str_err_exdev:       db "Invalid cross-device link"
str_err_exdev_len    equ $ - str_err_exdev
str_err_enotdir:     db "Not a directory"
str_err_enotdir_len  equ $ - str_err_enotdir
str_err_eisdir:      db "Is a directory"
str_err_eisdir_len   equ $ - str_err_eisdir
str_err_enomem:      db "Cannot allocate memory"
str_err_enomem_len   equ $ - str_err_enomem
str_err_erofs:       db "Read-only file system"
str_err_erofs_len    equ $ - str_err_erofs
str_err_emlink:      db "Too many links"
str_err_emlink_len   equ $ - str_err_emlink
str_err_enospc:      db "No space left on device"
str_err_enospc_len   equ $ - str_err_enospc
str_err_eloop:       db "Too many levels of symbolic links"
str_err_eloop_len    equ $ - str_err_eloop
str_err_enametoolong: db "File name too long"
str_err_enametoolong_len equ $ - str_err_enametoolong
str_err_einval:      db "Invalid argument"
str_err_einval_len   equ $ - str_err_einval
str_err_unknown:     db "Unknown error"
str_err_unknown_len  equ $ - str_err_unknown

str_newline:     db 10
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_symbolic_flag: db "--symbolic", 0
str_force_flag:  db "--force", 0
str_verbose_flag: db "--verbose", 0
str_noderef_flag: db "--no-dereference", 0
str_relative_flag: db "--relative", 0
str_no_target_dir_flag: db "--no-target-directory", 0

file_size equ $ - $$
