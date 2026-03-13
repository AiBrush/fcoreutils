; ============================================================
; frealpath_unified.asm — GNU-compatible 'realpath' command
; Builds with: nasm -f bin frealpath_unified.asm -o frealpath
;
; realpath: Print the resolved absolute file name.
;
; Register allocation:
;   r14d = argc, r15 = argv, ebx = flags
;   r12  = first file arg index, r13 = current file index
;
; Flags (ebx):
;   bit 0 = -e (canonicalize-existing, all must exist)
;   bit 1 = -m (canonicalize-missing, no need to exist)
;   bit 2 = -s (no-symlinks, don't resolve symlinks)
;   bit 3 = -z (zero/NUL delimiter)
;   bit 4 = -q (quiet, suppress errors)
;   bit 5 = --relative-to set (ptr in RELTO_PTR)
;   bit 6 = --relative-base set (ptr in RELBASE_PTR)
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE           1
%define SYS_STAT             4
%define SYS_LSTAT            6
%define SYS_EXIT            60
%define SYS_RT_SIGPROCMASK  14
%define SYS_READLINKAT     267
%define SYS_GETCWD          79

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13
%define AT_FDCWD       -100

%define PATH_MAX       4096

; BSS layout: 0x500000
%define BSS_ADDR       0x500000
%define BSS_SIZE       32768
%define STAT_AREA      BSS_ADDR                    ; 144 bytes
%define BUF_READLINK   (BSS_ADDR + 256)            ; 4096 bytes
%define BUF_PATH       (BSS_ADDR + 4352)           ; 4096 bytes - resolved path
%define BUF_WORK       (BSS_ADDR + 8448)           ; 4096 bytes - work buffer
%define BUF_CWD        (BSS_ADDR + 12544)          ; 4096 bytes - getcwd
%define BUF_RELTO      (BSS_ADDR + 16640)          ; 4096 bytes - resolved --relative-to
%define BUF_RELBASE    (BSS_ADDR + 20736)          ; 4096 bytes - resolved --relative-base
%define RELTO_PTR      (BSS_ADDR + 24832)          ; 8 bytes
%define RELBASE_PTR    (BSS_ADDR + 24840)          ; 8 bytes

; struct stat offsets
%define ST_MODE_OFF    24
%define S_IFMT         0xF000
%define S_IFLNK        0xA000
%define S_IFDIR        0x4000
%define STAT_SIZE      144

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
    mov     r14d, [rsp]
    lea     r15, [rsp + 8]

    ; Initialize flags
    xor     ebx, ebx
    mov     ecx, 1

; Parse options
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

    ; Short options
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'e'
    je      .set_exist
    cmp     al, 'm'
    je      .set_miss
    cmp     al, 's'
    je      .set_nosym
    cmp     al, 'z'
    je      .set_zero
    cmp     al, 'q'
    je      .set_quiet
    ; Invalid
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

.set_exist:
    and     bl, ~0x07           ; clear mode bits
    or      bl, 1
    inc     rdi
    jmp     .short_loop

.set_miss:
    and     bl, ~0x07
    or      bl, 2
    inc     rdi
    jmp     .short_loop

.set_nosym:
    or      bl, 4
    inc     rdi
    jmp     .short_loop

.set_zero:
    or      bl, 8
    inc     rdi
    jmp     .short_loop

.set_quiet:
    or      bl, 16
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
    ; --canonicalize-existing
    mov     rdi, r13
    mov     rsi, str_canon_exist_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_exist
    ; --canonicalize-missing
    mov     rdi, r13
    mov     rsi, str_canon_miss_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_miss
    ; --no-symlinks
    mov     rdi, r13
    mov     rsi, str_nosym_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_nosym
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
    ; --strip (alias for -s)
    mov     rdi, r13
    mov     rsi, str_strip_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_nosym
    ; --relative-to=
    mov     rdi, r13
    mov     rsi, str_relto_eq
    mov     edx, 14
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_relto
    ; --relative-base=
    mov     rdi, r13
    mov     rsi, str_relbase_eq
    mov     edx, 16
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_relbase
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

.pop_set_exist:
    pop     rcx
    and     bl, ~0x07
    or      bl, 1
    inc     ecx
    jmp     .parse_opts

.pop_set_miss:
    pop     rcx
    and     bl, ~0x07
    or      bl, 2
    inc     ecx
    jmp     .parse_opts

.pop_set_nosym:
    pop     rcx
    or      bl, 4
    inc     ecx
    jmp     .parse_opts

.pop_set_zero:
    pop     rcx
    or      bl, 8
    inc     ecx
    jmp     .parse_opts

.pop_set_quiet:
    pop     rcx
    or      bl, 16
    inc     ecx
    jmp     .parse_opts

.pop_set_relto:
    pop     rcx
    or      bl, 32
    lea     rax, [r13 + 14]     ; skip "--relative-to="
    mov     [RELTO_PTR], rax
    inc     ecx
    jmp     .parse_opts

.pop_set_relbase:
    pop     rcx
    or      bl, 64
    lea     rax, [r13 + 16]     ; skip "--relative-base="
    mov     [RELBASE_PTR], rax
    inc     ecx
    jmp     .parse_opts

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.done_opts:
    cmp     ecx, r14d
    jge     .err_missing_operand

    ; Process files
    mov     r12d, ecx
    mov     r13d, ecx
    xor     ebp, ebp            ; exit code

.file_loop:
    cmp     r13d, r14d
    jge     .exit_done
    mov     rdi, [r15 + r13*8]
    call    do_realpath_main
    inc     r13d
    jmp     .file_loop

.exit_done:
    mov     edi, ebp
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
; do_realpath_main: resolve canonical path and print it
; Input: rdi = path, ebx = flags, ebp = exit code accum
; ============================================================
do_realpath_main:
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, STAT_SIZE + 8
    mov     [rsp + STAT_SIZE], rdi  ; save original path

    ; Check -s (no-symlinks) mode
    test    bl, 4
    jnz     .rpm_nosym

    ; Copy input path to BUF_READLINK
    mov     rsi, rdi
    mov     rdi, BUF_READLINK
    call    str_copy
    mov     r12, BUF_READLINK

    ; Start building result in BUF_PATH
    cmp     byte [r12], '/'
    je      .rpm_abs

    ; Relative: start with cwd
    mov     eax, SYS_GETCWD
    mov     rdi, BUF_PATH
    mov     esi, PATH_MAX
    syscall
    test    rax, rax
    js      .rpm_fail
    mov     rdi, BUF_PATH
    call    str_len
    mov     r13d, eax
    jmp     .rpm_process

.rpm_abs:
    mov     byte [BUF_PATH], '/'
    mov     byte [BUF_PATH + 1], 0
    mov     r13d, 1
    inc     r12
.rpm_skip_lead:
    cmp     byte [r12], '/'
    jne     .rpm_process
    inc     r12
    jmp     .rpm_skip_lead

.rpm_process:
    ; Process components
.rpm_next:
    cmp     byte [r12], '/'
    jne     .rpm_check_end
    inc     r12
    jmp     .rpm_next

.rpm_check_end:
    cmp     byte [r12], 0
    je      .rpm_done

    ; Find end of component
    mov     r14, r12
    xor     r15d, r15d
.rpm_find_end:
    movzx   eax, byte [r12 + r15]
    test    al, al
    jz      .rpm_got_comp
    cmp     al, '/'
    je      .rpm_got_comp
    inc     r15d
    jmp     .rpm_find_end

.rpm_got_comp:
    ; Check "."
    cmp     r15d, 1
    jne     .rpm_check_dotdot
    cmp     byte [r14], '.'
    je      .rpm_skip_comp

.rpm_check_dotdot:
    cmp     r15d, 2
    jne     .rpm_append
    cmp     word [r14], 0x2E2E  ; ".."
    jne     .rpm_append
    ; Go up
    cmp     r13d, 1
    jle     .rpm_skip_comp
    dec     r13d
.rpm_backup:
    cmp     r13d, 1
    jle     .rpm_backup_done
    cmp     byte [BUF_PATH + r13 - 1], '/'
    je      .rpm_backup_done
    dec     r13d
    jmp     .rpm_backup
.rpm_backup_done:
    mov     byte [BUF_PATH + r13], 0
    jmp     .rpm_skip_comp

.rpm_skip_comp:
    lea     r12, [r14 + r15]
    jmp     .rpm_next

.rpm_append:
    ; Add slash if needed
    cmp     r13d, 0
    je      .rpm_add_slash
    cmp     byte [BUF_PATH + r13 - 1], '/'
    je      .rpm_copy_comp
.rpm_add_slash:
    mov     byte [BUF_PATH + r13], '/'
    inc     r13d
.rpm_copy_comp:
    xor     ecx, ecx
.rpm_cloop:
    cmp     ecx, r15d
    jge     .rpm_cdone
    movzx   eax, byte [r14 + rcx]
    mov     byte [BUF_PATH + r13 + rcx], al
    inc     ecx
    jmp     .rpm_cloop
.rpm_cdone:
    add     r13d, r15d
    mov     byte [BUF_PATH + r13], 0

    ; Check if more components follow
    lea     rdi, [r14 + r15]
.rpm_peek:
    cmp     byte [rdi], '/'
    jne     .rpm_peek_done
    inc     rdi
    jmp     .rpm_peek
.rpm_peek_done:
    cmp     byte [rdi], 0
    je      .rpm_is_last

    ; Not last: lstat to check
    mov     eax, SYS_LSTAT
    mov     rdi, BUF_PATH
    lea     rsi, [rsp]
    syscall
    test    rax, rax
    js      .rpm_comp_missing

    movzx   eax, word [rsp + ST_MODE_OFF]
    and     eax, S_IFMT
    cmp     eax, S_IFLNK
    je      .rpm_resolve_sym
    cmp     eax, S_IFDIR
    je      .rpm_skip_comp
    ; Not dir, not symlink
    test    bl, 2
    jnz     .rpm_skip_comp
    jmp     .rpm_fail

.rpm_comp_missing:
    test    bl, 2
    jnz     .rpm_skip_comp
    jmp     .rpm_fail

.rpm_is_last:
    mov     eax, SYS_LSTAT
    mov     rdi, BUF_PATH
    lea     rsi, [rsp]
    syscall
    test    rax, rax
    js      .rpm_last_missing

    movzx   eax, word [rsp + ST_MODE_OFF]
    and     eax, S_IFMT
    cmp     eax, S_IFLNK
    je      .rpm_resolve_sym
    jmp     .rpm_skip_comp

.rpm_last_missing:
    test    bl, 1               ; -e: must exist
    jnz     .rpm_fail
    jmp     .rpm_skip_comp

.rpm_resolve_sym:
    mov     eax, SYS_READLINKAT
    mov     edi, AT_FDCWD
    mov     rsi, BUF_PATH
    mov     rdx, BUF_WORK
    mov     r10d, PATH_MAX - 1
    syscall
    test    rax, rax
    js      .rpm_fail
    mov     byte [BUF_WORK + rax], 0

    ; Remove last component from BUF_PATH
    cmp     r13d, 1
    jle     .rpm_sym_root
    dec     r13d
.rpm_sym_backup:
    cmp     r13d, 1
    jle     .rpm_sym_backup_d
    cmp     byte [BUF_PATH + r13 - 1], '/'
    je      .rpm_sym_backup_d
    dec     r13d
    jmp     .rpm_sym_backup
.rpm_sym_backup_d:
    mov     byte [BUF_PATH + r13], 0
    jmp     .rpm_sym_build

.rpm_sym_root:
    mov     r13d, 1
    mov     byte [BUF_PATH + 1], 0

.rpm_sym_build:
    ; Build new source: symlink_target + remaining
    mov     rdi, BUF_CWD
    mov     rsi, BUF_WORK
    call    str_copy
    mov     ecx, eax

    lea     rdi, [r14 + r15]
    cmp     byte [rdi], 0
    je      .rpm_sym_no_rem

    cmp     ecx, 0
    je      .rpm_sym_add_sep
    cmp     byte [BUF_CWD + rcx - 1], '/'
    je      .rpm_sym_copy_rem
.rpm_sym_add_sep:
    mov     byte [BUF_CWD + rcx], '/'
    inc     ecx
.rpm_sym_copy_rem:
    mov     rsi, rdi
    lea     rdi, [BUF_CWD + rcx]
    push    rcx
    call    str_copy
    pop     rcx
    add     ecx, eax

.rpm_sym_no_rem:
    mov     byte [BUF_CWD + rcx], 0

    cmp     byte [BUF_CWD], '/'
    jne     .rpm_sym_rel
    mov     byte [BUF_PATH], '/'
    mov     byte [BUF_PATH + 1], 0
    mov     r13d, 1
.rpm_sym_rel:
    mov     r12, BUF_CWD
    jmp     .rpm_process

.rpm_done:
    ; Remove trailing slash if not root
    cmp     r13d, 1
    jle     .rpm_output
    cmp     byte [BUF_PATH + r13 - 1], '/'
    jne     .rpm_output
    dec     r13d
    mov     byte [BUF_PATH + r13], 0

.rpm_output:
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

.rpm_nosym:
    ; -s mode: don't resolve symlinks, just canonicalize path
    mov     rsi, rdi
    mov     rdi, BUF_READLINK
    call    str_copy
    mov     r12, BUF_READLINK

    cmp     byte [r12], '/'
    je      .rpm_ns_abs

    ; Relative: prepend cwd
    mov     eax, SYS_GETCWD
    mov     rdi, BUF_PATH
    mov     esi, PATH_MAX
    syscall
    test    rax, rax
    js      .rpm_fail
    mov     rdi, BUF_PATH
    call    str_len
    mov     r13d, eax
    jmp     .rpm_ns_process

.rpm_ns_abs:
    mov     byte [BUF_PATH], '/'
    mov     byte [BUF_PATH + 1], 0
    mov     r13d, 1
    inc     r12
.rpm_ns_skip:
    cmp     byte [r12], '/'
    jne     .rpm_ns_process
    inc     r12
    jmp     .rpm_ns_skip

.rpm_ns_process:
.rpm_ns_next:
    cmp     byte [r12], '/'
    jne     .rpm_ns_check_end
    inc     r12
    jmp     .rpm_ns_next

.rpm_ns_check_end:
    cmp     byte [r12], 0
    je      .rpm_done

    mov     r14, r12
    xor     r15d, r15d
.rpm_ns_find_end:
    movzx   eax, byte [r12 + r15]
    test    al, al
    jz      .rpm_ns_got
    cmp     al, '/'
    je      .rpm_ns_got
    inc     r15d
    jmp     .rpm_ns_find_end

.rpm_ns_got:
    cmp     r15d, 1
    jne     .rpm_ns_check_dd
    cmp     byte [r14], '.'
    je      .rpm_ns_skip_comp

.rpm_ns_check_dd:
    cmp     r15d, 2
    jne     .rpm_ns_append
    cmp     word [r14], 0x2E2E
    jne     .rpm_ns_append
    cmp     r13d, 1
    jle     .rpm_ns_skip_comp
    dec     r13d
.rpm_ns_backup:
    cmp     r13d, 1
    jle     .rpm_ns_bkdone
    cmp     byte [BUF_PATH + r13 - 1], '/'
    je      .rpm_ns_bkdone
    dec     r13d
    jmp     .rpm_ns_backup
.rpm_ns_bkdone:
    mov     byte [BUF_PATH + r13], 0
    jmp     .rpm_ns_skip_comp

.rpm_ns_skip_comp:
    lea     r12, [r14 + r15]
    jmp     .rpm_ns_next

.rpm_ns_append:
    cmp     r13d, 0
    je      .rpm_ns_add_slash
    cmp     byte [BUF_PATH + r13 - 1], '/'
    je      .rpm_ns_copy
.rpm_ns_add_slash:
    mov     byte [BUF_PATH + r13], '/'
    inc     r13d
.rpm_ns_copy:
    xor     ecx, ecx
.rpm_ns_cloop:
    cmp     ecx, r15d
    jge     .rpm_ns_cdone
    movzx   eax, byte [r14 + rcx]
    mov     byte [BUF_PATH + r13 + rcx], al
    inc     ecx
    jmp     .rpm_ns_cloop
.rpm_ns_cdone:
    add     r13d, r15d
    mov     byte [BUF_PATH + r13], 0
    lea     r12, [r14 + r15]
    jmp     .rpm_ns_next

.rpm_fail:
    test    bl, 16              ; quiet?
    jnz     .rpm_fail_done
    ; Print error
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rdi, [rsp + STAT_SIZE]
    call    str_len
    mov     edx, eax
    mov     rsi, [rsp + STAT_SIZE]
    call    do_write_err
    mov     rsi, str_no_such_file
    mov     edx, str_no_such_file_len
    call    do_write_err

.rpm_fail_done:
    add     rsp, STAT_SIZE + 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    mov     ebp, 1
    ret

; ============================================================
; write_terminator
; ============================================================
write_terminator:
    test    bl, 8               ; -z
    jnz     .wt_nul
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write
    ret
.wt_nul:
    mov     edi, STDOUT
    mov     rsi, str_nul_char
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
    db "Usage: realpath [OPTION]... FILE...", 10
    db "Print the resolved absolute file name;", 10
    db "all but the last component must exist", 10, 10
    db "  -e, --canonicalize-existing  all components of the path must exist", 10
    db "  -m, --canonicalize-missing   no path components need exist or be a directory", 10
    db "  -q, --quiet                  suppress most error messages", 10
    db "  -s, --strip, --no-symlinks   don't expand symlinks", 10
    db "  -z, --zero                   end each output line with NUL, not newline", 10
    db "      --relative-to=DIR        print the resolved path relative to DIR", 10
    db "      --relative-base=DIR      print absolute paths unless paths below DIR", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/realpath>", 10
    db "or available locally via: info '(coreutils) realpath invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "realpath (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Padraig Brady.", 10
str_version_len equ $ - str_version

str_prefix:      db "realpath: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_missing:     db "missing operand", 10
str_missing_len  equ $ - str_missing
str_sq_nl:       db "'", 10
str_try:         db "Try 'realpath --help' for more information.", 10
str_try_len      equ $ - str_try
str_no_such_file: db ": No such file or directory", 10
str_no_such_file_len equ $ - str_no_such_file
; @@DATA_END@@

str_newline:     db 10
str_nul_char:    db 0
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_canon_exist_flag: db "--canonicalize-existing", 0
str_canon_miss_flag: db "--canonicalize-missing", 0
str_nosym_flag:  db "--no-symlinks", 0
str_strip_flag:  db "--strip", 0
str_zero_flag:   db "--zero", 0
str_quiet_flag:  db "--quiet", 0
str_relto_eq:    db "--relative-to=", 0
str_relbase_eq:  db "--relative-base=", 0

file_size equ $ - $$
