; ============================================================
; fmktemp_unified.asm — GNU-compatible 'mktemp' command
; Builds with: nasm -f bin fmktemp_unified.asm -o fmktemp
;
; mktemp: Create temporary file or directory, print name.
;
; Usage: mktemp [OPTION]... [TEMPLATE]
;   -d, --directory   create directory instead of file
;   -u, --dry-run     do not create anything, just print name (unsafe)
;   -q, --quiet       suppress error messages
;   -p DIR, --tmpdir[=DIR]  use DIR (default $TMPDIR or /tmp)
;   --suffix=SUFF     append SUFF to template
;   -t               interpret TEMPLATE relative to TMPDIR
;
; Default template: tmp.XXXXXXXXXX
; X's replaced with random chars from [a-zA-Z0-9]
; Uses getrandom(2) syscall for randomness.
; For files: open(O_CREAT|O_EXCL|O_RDWR) with retry on EEXIST.
; For dirs: mkdir with retry on EEXIST.
;
; Register allocation:
;   r14d = argc, r15 = argv
;   ebx  = flags (bit0=dir, bit1=dry-run, bit2=quiet, bit3=-t flag)
;   ebp  = exit code
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_MKDIR       83
%define SYS_EXIT        60
%define SYS_RT_SIGPROCMASK 14
%define SYS_GETRANDOM   318

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE         13

; open flags
%define O_RDWR          2
%define O_CREAT         0o100
%define O_EXCL          0o200

; errno
%define EEXIST          17
%define EINVAL          22

; Max retries for EEXIST
%define MAX_RETRIES     1000

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

    ; Allocate stack buffer for path: 4096 + 256 suffix + 16 random + alignment
    sub     rsp, 4608
    ; rsp+0..4095: path buffer
    ; rsp+4096..4351: suffix buffer (256)
    ; rsp+4352..4367: random bytes buffer (16)

    ; Initialize
    xor     ebx, ebx            ; flags
    xor     ebp, ebp            ; exit code
    mov     ecx, 1              ; arg index

    ; Pointers for -p DIR and --suffix=SUFF and template
    xor     r12, r12            ; -p DIR pointer (0 = use TMPDIR/tmp)
    xor     r13, r13            ; template pointer (0 = use default)

    ; suffix pointer: store 0 as "no suffix"
    mov     qword [rsp + 4096], 0

    ; Parse options
.parse_opts:
    cmp     ecx, r14d
    jge     .done_opts           ; no more args -> use defaults
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
    cmp     al, 'u'
    je      .set_dry
    cmp     al, 'q'
    je      .set_quiet
    cmp     al, 't'
    je      .set_t_flag
    cmp     al, 'p'
    je      .set_p_short
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
    mov     edi, 1
    jmp     .do_exit

.set_dir:
    or      bl, 1
    inc     rdi
    jmp     .short_loop
.set_dry:
    or      bl, 2
    inc     rdi
    jmp     .short_loop
.set_quiet:
    or      bl, 4
    inc     rdi
    jmp     .short_loop
.set_t_flag:
    or      bl, 8
    inc     rdi
    jmp     .short_loop
.set_p_short:
    ; -p DIR: next char or next arg
    inc     rdi
    cmp     byte [rdi], 0
    jne     .set_p_val
    inc     ecx
    cmp     ecx, r14d
    jge     .err_missing_p
    mov     rdi, [r15 + rcx*8]
.set_p_val:
    mov     r12, rdi
    jmp     .next_opt

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    push    rcx
    mov     r13, rdi
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
    mov     rsi, str_directory_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_dir
    mov     rdi, r13
    mov     rsi, str_dry_run_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_dry
    mov     rdi, r13
    mov     rsi, str_quiet_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_quiet
    ; --tmpdir=DIR
    mov     rdi, r13
    mov     rsi, str_tmpdir_eq_flag
    call    str_starts_with
    test    eax, eax
    jnz     .pop_set_tmpdir_eq
    ; --tmpdir (no =)
    mov     rdi, r13
    mov     rsi, str_tmpdir_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_tmpdir
    ; --suffix=SUFF
    mov     rdi, r13
    mov     rsi, str_suffix_eq_flag
    call    str_starts_with
    test    eax, eax
    jnz     .pop_set_suffix
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
    jmp     .do_exit

.pop_show_help:
    pop     rcx
    jmp     .show_help
.pop_show_version:
    pop     rcx
    jmp     .show_version
.pop_set_dir:
    pop     rcx
    or      bl, 1
    jmp     .next_opt
.pop_set_dry:
    pop     rcx
    or      bl, 2
    jmp     .next_opt
.pop_set_quiet:
    pop     rcx
    or      bl, 4
    jmp     .next_opt
.pop_set_tmpdir_eq:
    ; --tmpdir=DIR
    pop     rcx
    lea     r12, [r13 + 9]      ; skip "--tmpdir="
    or      bl, 8               ; act like -t
    jmp     .next_opt
.pop_set_tmpdir:
    ; --tmpdir (use $TMPDIR or /tmp)
    pop     rcx
    or      bl, 8
    ; r12 stays 0 -> will use $TMPDIR or /tmp
    jmp     .next_opt
.pop_set_suffix:
    ; --suffix=SUFF
    pop     rcx
    lea     rdi, [r13 + 9]      ; skip "--suffix="
    ; Copy suffix to suffix buffer at rsp+4096
    lea     r8, [rsp + 4096]
    xor     r9d, r9d
.copy_suffix:
    movzx   eax, byte [rdi + r9]
    mov     byte [r8 + r9], al
    test    al, al
    jz      .suffix_done
    inc     r9d
    cmp     r9d, 255
    jb      .copy_suffix
    mov     byte [r8 + r9], 0
.suffix_done:
    jmp     .next_opt

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.done_opts:
    ; Check for template arg
    xor     r13, r13            ; default: no template
    cmp     ecx, r14d
    jge     .no_template
    mov     r13, [r15 + rcx*8] ; template
    inc     ecx
    ; Check for extra operand
    cmp     ecx, r14d
    jl      .err_extra
.no_template:

    ; Build the full path in buffer at rsp
    ; Components: [DIR/] + TEMPLATE + [SUFFIX]

    lea     r8, [rsp]           ; path buffer

    ; Determine base directory
    ; If -p DIR or --tmpdir=DIR was given with a value:
    test    r12, r12
    jnz     .use_given_dir

    ; If -t flag (--tmpdir without value): use TMPDIR env or /tmp
    test    bl, 8
    jnz     .use_tmpdir_env

    ; If template is given and has no '/', use TMPDIR env or /tmp
    ; If no template, use TMPDIR env or /tmp
    test    r13, r13
    jz      .use_tmpdir_env     ; no template -> use tmpdir

    ; Template given: check if it contains '/'
    mov     rdi, r13
    call    has_slash
    test    eax, eax
    jnz     .use_template_as_is ; has '/' -> use as-is (absolute/relative path)
    ; No slash -> use tmpdir
    jmp     .use_tmpdir_env

.use_given_dir:
    ; Copy DIR to buffer
    lea     r8, [rsp]           ; path buffer base
    mov     rdi, r12
    call    str_len
    mov     r9d, eax            ; dir length
    ; Copy dir
    xor     r10d, r10d
.copy_dir:
    cmp     r10d, r9d
    jge     .dir_copied
    movzx   eax, byte [r12 + r10]
    mov     byte [r8 + r10], al
    inc     r10d
    jmp     .copy_dir
.dir_copied:
    ; Add '/' if not already there
    cmp     r10d, 0
    je      .add_slash
    movzx   eax, byte [r8 + r10 - 1]
    cmp     al, '/'
    je      .dir_slash_done
.add_slash:
    mov     byte [r8 + r10], '/'
    inc     r10d
.dir_slash_done:
    jmp     .append_template

.use_tmpdir_env:
    ; Find TMPDIR in environment
    ; r15 = argv (pointer to argv[0])
    ; r14d = argc
    ; envp starts at r15 + (r14+1)*8 (after argv null terminator)
    mov     eax, r14d
    inc     eax                 ; argc + 1
    lea     rdi, [r15 + rax*8]  ; rdi = &envp[0]

    ; Search for "TMPDIR="
.search_tmpdir:
    mov     rax, [rdi]
    test    rax, rax
    jz      .tmpdir_not_found
    ; Check if starts with "TMPDIR="
    push    rdi
    mov     rdi, rax
    mov     rsi, str_tmpdir_env
    call    str_starts_with
    pop     rdi
    test    eax, eax
    jnz     .tmpdir_found
    add     rdi, 8
    jmp     .search_tmpdir

.tmpdir_found:
    mov     rax, [rdi]
    lea     r12, [rax + 7]      ; skip "TMPDIR="
    ; Check if it's non-empty
    cmp     byte [r12], 0
    je      .tmpdir_not_found
    jmp     .use_given_dir

.tmpdir_not_found:
    ; Use /tmp
    mov     r12, str_tmp_path
    jmp     .use_given_dir

.use_template_as_is:
    ; Template has '/' - use as-is, no DIR prefix
    xor     r10d, r10d
    jmp     .append_template

.append_template:
    ; r10d = current offset in buffer
    ; Append template
    test    r13, r13
    jnz     .has_template
    ; No template -> use "tmp.XXXXXXXXXX"
    mov     r13, str_default_template
.has_template:
    mov     rdi, r13
    call    str_len
    mov     r9d, eax            ; template length
    xor     ecx, ecx
.copy_template:
    cmp     ecx, r9d
    jge     .template_copied
    movzx   eax, byte [r13 + rcx]
    mov     byte [r8 + r10], al
    inc     r10d
    inc     ecx
    jmp     .copy_template
.template_copied:

    ; Append suffix if any
    lea     rdi, [rsp + 4096]   ; suffix buffer
    cmp     byte [rdi], 0
    je      .no_suffix
    call    str_len
    mov     r9d, eax
    xor     ecx, ecx
.copy_suf:
    cmp     ecx, r9d
    jge     .no_suffix
    movzx   eax, byte [rdi + rcx]
    mov     byte [r8 + r10], al
    inc     r10d
    inc     ecx
    jmp     .copy_suf
.no_suffix:
    mov     byte [r8 + r10], 0  ; NUL terminate
    mov     r9d, r10d           ; total path length

    ; Now find the X's to replace
    ; Count trailing X's (before suffix)
    ; Find start of X sequence: scan backwards from end of template portion
    ; Template portion ends at (r9d - suffix_len)
    lea     rdi, [rsp + 4096]
    cmp     byte [rdi], 0
    je      .no_suf_for_x
    push    r9
    call    str_len
    mov     ecx, eax            ; suffix length
    pop     r9
    jmp     .count_xs
.no_suf_for_x:
    xor     ecx, ecx            ; no suffix
.count_xs:
    ; ecx = suffix length
    ; r9d = total path length
    ; X's end at position (r9d - ecx - 1) and go backwards
    mov     r10d, r9d
    sub     r10d, ecx           ; position after last X
    xor     r11d, r11d          ; X count
.count_x_loop:
    cmp     r10d, 0
    jle     .xs_counted
    dec     r10d
    cmp     byte [r8 + r10], 'X'
    jne     .xs_counted_inc
    inc     r11d
    jmp     .count_x_loop
.xs_counted_inc:
    inc     r10d                ; went one too far
.xs_counted:
    ; r10d = start position of X's in path
    ; r11d = number of X's
    ; Validate: need at least 3 X's
    cmp     r11d, 3
    jl      .err_too_few_xs

    ; Now create the temp file/dir
    ; r8 = path buffer
    ; r10d = X start offset
    ; r11d = X count
    ; ebx = flags

    mov     r9d, 0              ; retry counter
.retry_loop:
    cmp     r9d, MAX_RETRIES
    jge     .err_too_many_retries

    ; Generate random bytes
    push    r9
    push    r10
    push    r11
    lea     rdi, [rsp + 4352 + 24]  ; random buffer (adjusted for 3 pushes)
    mov     esi, r11d           ; need r11d random bytes
    xor     edx, edx            ; flags = 0
    mov     eax, SYS_GETRANDOM
    syscall
    pop     r11
    pop     r10
    pop     r9

    test    rax, rax
    js      .err_getrandom

    ; Map random bytes to [a-zA-Z0-9]
    xor     ecx, ecx
.map_random:
    cmp     ecx, r11d
    jge     .random_mapped
    ; Load random byte using r8 as temp base
    lea     r8, [rsp + 4352]
    movzx   eax, byte [r8 + rcx]
    ; byte % 62 -> maps to [a-zA-Z0-9]
    xor     edx, edx
    push    rcx
    mov     ecx, 62
    div     ecx                 ; eax = quot, edx = remainder (0..61)
    pop     rcx
    ; Map edx to char
    cmp     edx, 26
    jb      .map_lower
    cmp     edx, 52
    jb      .map_upper
    ; 52-61 -> '0'-'9'
    sub     edx, 52
    add     edx, '0'
    jmp     .map_store
.map_lower:
    add     edx, 'a'
    jmp     .map_store
.map_upper:
    sub     edx, 26
    add     edx, 'A'
.map_store:
    lea     r8, [rsp]
    ; Store at path[r10 + ecx]
    movzx   eax, dl             ; save char
    push    rdx
    mov     edx, r10d
    add     edx, ecx
    mov     byte [r8 + rdx], al
    pop     rdx
    inc     ecx
    jmp     .map_random
.random_mapped:

    lea     r8, [rsp]           ; path buffer

    ; Dry run? Just succeed
    test    bl, 2
    jnz     .success

    ; Create directory or file
    test    bl, 1
    jnz     .create_dir

    ; Create file: open(path, O_RDWR|O_CREAT|O_EXCL, 0600)
    mov     eax, SYS_OPEN
    lea     rdi, [rsp]
    mov     esi, O_RDWR | O_CREAT | O_EXCL
    mov     edx, 0o600
    syscall

    test    rax, rax
    js      .open_failed

    ; Close the fd
    mov     edi, eax
    mov     eax, SYS_CLOSE
    syscall
    jmp     .success

.open_failed:
    neg     rax
    cmp     eax, EEXIST
    je      .retry_next
    ; Real error
    jmp     .creation_error

.create_dir:
    mov     eax, SYS_MKDIR
    lea     rdi, [rsp]
    mov     esi, 0o700
    syscall

    test    rax, rax
    jz      .success
    neg     rax
    cmp     eax, EEXIST
    je      .retry_next
    jmp     .creation_error

.retry_next:
    inc     r9d
    jmp     .retry_loop

.success:
    ; Print the path to stdout
    lea     r8, [rsp]
    mov     rdi, r8
    call    str_len
    mov     edx, eax
    mov     rsi, r8
    mov     edi, STDOUT
    call    do_write
    ; Print newline
    mov     rsi, str_newline
    mov     edx, 1
    mov     edi, STDOUT
    call    do_write
    xor     edi, edi
    jmp     .do_exit

.creation_error:
    ; eax = errno
    test    bl, 4               ; quiet?
    jnz     .quiet_exit
    push    rax
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_failed
    mov     edx, str_failed_len
    call    do_write_err
    lea     rdi, [rsp + 8]      ; path buffer (adjusted for push)
    call    str_len
    mov     edx, eax
    lea     rsi, [rsp + 8]
    call    do_write_err
    mov     rsi, str_colon_sep
    mov     edx, str_colon_sep_len
    call    do_write_err
    pop     rax
    call    print_errno
.quiet_exit:
    mov     edi, 1
    jmp     .do_exit

.err_too_many_retries:
    test    bl, 4
    jnz     .quiet_exit
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_too_many
    mov     edx, str_too_many_len
    call    do_write_err
    mov     edi, 1
    jmp     .do_exit

.err_getrandom:
    test    bl, 4
    jnz     .quiet_exit
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_getrandom_err
    mov     edx, str_getrandom_err_len
    call    do_write_err
    mov     edi, 1
    jmp     .do_exit

.err_too_few_xs:
    test    bl, 4
    jnz     .quiet_exit
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_too_few_xs
    mov     edx, str_too_few_xs_len
    call    do_write_err
    mov     edi, 1
    jmp     .do_exit

.err_extra:
    mov     r13, [r15 + rcx*8]
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_extra
    mov     edx, str_extra_len
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
    mov     edi, 1
    jmp     .do_exit

.err_missing_p:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing_p
    mov     edx, str_missing_p_len
    call    do_write_err
    mov     edi, 1
    jmp     .do_exit

.show_help:
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     .do_exit

.show_version:
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     .do_exit

.do_exit:
    add     rsp, 4608
    jmp     do_exit

; ============================================================
; has_slash: check if string contains '/'
; Input: rdi = string
; Output: eax = 1 if has '/', 0 otherwise
; ============================================================
has_slash:
    xor     r8d, r8d
.hs_loop:
    movzx   eax, byte [rdi + r8]
    test    al, al
    jz      .hs_no
    cmp     al, '/'
    je      .hs_yes
    inc     r8d
    jmp     .hs_loop
.hs_yes:
    mov     eax, 1
    ret
.hs_no:
    xor     eax, eax
    ret

; ============================================================
; print_errno
; ============================================================
print_errno:
    cmp     eax, 2              ; ENOENT
    je      .pe_noent
    cmp     eax, 13             ; EACCES
    je      .pe_acces
    cmp     eax, 17             ; EEXIST
    je      .pe_exist
    cmp     eax, 20             ; ENOTDIR
    je      .pe_notdir
    cmp     eax, 28             ; ENOSPC
    je      .pe_nospc
    cmp     eax, 30             ; EROFS
    je      .pe_rofs
    cmp     eax, 22             ; EINVAL
    je      .pe_inval
    cmp     eax, 1              ; EPERM
    je      .pe_perm
    mov     rsi, str_err_unknown
    mov     edx, str_err_unknown_len
    jmp     do_write_err
.pe_noent:
    mov     rsi, str_err_noent
    mov     edx, str_err_noent_len
    jmp     do_write_err
.pe_acces:
    mov     rsi, str_err_acces
    mov     edx, str_err_acces_len
    jmp     do_write_err
.pe_exist:
    mov     rsi, str_err_exist
    mov     edx, str_err_exist_len
    jmp     do_write_err
.pe_notdir:
    mov     rsi, str_err_notdir
    mov     edx, str_err_notdir_len
    jmp     do_write_err
.pe_nospc:
    mov     rsi, str_err_nospc
    mov     edx, str_err_nospc_len
    jmp     do_write_err
.pe_rofs:
    mov     rsi, str_err_rofs
    mov     edx, str_err_rofs_len
    jmp     do_write_err
.pe_inval:
    mov     rsi, str_err_inval
    mov     edx, str_err_inval_len
    jmp     do_write_err
.pe_perm:
    mov     rsi, str_err_perm
    mov     edx, str_err_perm_len
    jmp     do_write_err

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

str_starts_with:
    xor     r8d, r8d
.ssw_loop:
    movzx   eax, byte [rsi + r8]
    test    al, al
    jz      .ssw_yes
    movzx   edx, byte [rdi + r8]
    cmp     al, dl
    jne     .ssw_no
    inc     r8d
    jmp     .ssw_loop
.ssw_yes:
    mov     eax, 1
    ret
.ssw_no:
    xor     eax, eax
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: mktemp [OPTION]... [TEMPLATE]", 10
    db "Create a temporary file or directory, safely, and print its name.", 10
    db "TEMPLATE must contain at least 3 consecutive 'X's in last component.", 10
    db "If TEMPLATE is not specified, use tmp.XXXXXXXXXX, and --tmpdir is implied.", 10
    db "Files are created u+rw, and directories u+rwx, minus umask restrictions.", 10, 10
    db "  -d, --directory     create a directory, not a file", 10
    db "  -u, --dry-run       do not create anything; merely print a name (unsafe)", 10
    db "  -q, --quiet         suppress diagnostics about file/dir-creation failure", 10
    db "  -p DIR, --tmpdir[=DIR]  interpret TEMPLATE relative to DIR; if DIR is not", 10
    db "                        specified, use $TMPDIR if set, else /tmp.  With", 10
    db "                        this option, TEMPLATE must not be an absolute name;", 10
    db "                        unlike with -t, TEMPLATE may contain slashes, but", 10
    db "                        mktemp creates only the final component", 10
    db "  -t                  interpret TEMPLATE as a single file name component,", 10
    db "                        relative to a directory: $TMPDIR, if set; else the", 10
    db "                        directory specified via -p; else /tmp [deprecated]", 10
    db "      --suffix=SUFF  append SUFF to TEMPLATE; SUFF must not contain a slash.", 10
    db "                        This option is implied if TEMPLATE does not end in X", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/mktemp>", 10
    db "or available locally via: info '(coreutils) mktemp invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "mktemp (GNU coreutils) 9.4", 10
    db "Copyright (C) 2023 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Jim Meyering and Eric Blake.", 10
str_version_len equ $ - str_version

str_prefix:      db "mktemp: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_sq_nl:       db "'", 10
str_try:         db "Try 'mktemp --help' for more information.", 10
str_try_len      equ $ - str_try
str_failed:      db "failed to create "
str_failed_len   equ $ - str_failed
str_colon_sep:   db "': "
str_colon_sep_len equ $ - str_colon_sep
str_too_many:    db "too many retries, giving up", 10
str_too_many_len equ $ - str_too_many
str_getrandom_err: db "failed to get random data", 10
str_getrandom_err_len equ $ - str_getrandom_err
str_too_few_xs:  db "too few X's in template", 10
str_too_few_xs_len equ $ - str_too_few_xs
str_extra:       db "extra operand '"
str_extra_len    equ $ - str_extra
str_missing_p:   db "option requires an argument -- 'p'", 10
str_missing_p_len equ $ - str_missing_p
; @@DATA_END@@

str_err_noent:     db "No such file or directory", 10
str_err_noent_len  equ $ - str_err_noent
str_err_acces:     db "Permission denied", 10
str_err_acces_len  equ $ - str_err_acces
str_err_exist:     db "File exists", 10
str_err_exist_len  equ $ - str_err_exist
str_err_notdir:    db "Not a directory", 10
str_err_notdir_len equ $ - str_err_notdir
str_err_nospc:     db "No space left on device", 10
str_err_nospc_len  equ $ - str_err_nospc
str_err_rofs:      db "Read-only file system", 10
str_err_rofs_len   equ $ - str_err_rofs
str_err_inval:     db "Invalid argument", 10
str_err_inval_len  equ $ - str_err_inval
str_err_perm:      db "Operation not permitted", 10
str_err_perm_len   equ $ - str_err_perm
str_err_unknown:   db "Unknown error", 10
str_err_unknown_len equ $ - str_err_unknown

str_newline:     db 10
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_directory_flag: db "--directory", 0
str_dry_run_flag: db "--dry-run", 0
str_quiet_flag:  db "--quiet", 0
str_tmpdir_flag: db "--tmpdir", 0
str_tmpdir_eq_flag: db "--tmpdir=", 0
str_suffix_eq_flag: db "--suffix=", 0
str_default_template: db "tmp.XXXXXXXXXX", 0
str_tmp_path:    db "/tmp", 0
str_tmpdir_env:  db "TMPDIR=", 0

file_size equ $ - $$
