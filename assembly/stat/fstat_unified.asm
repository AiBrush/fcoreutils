; ============================================================
; fstat_unified.asm — GNU-compatible 'stat' command
; Builds with: nasm -f bin fstat_unified.asm -o fstat
;
; stat: Display file or file system status.
;
; Register allocation:
;   r14d = argc, r15 = argv
;   ebx  = flags (bit 0 = -L/deref, bit 1 = -f/filesystem, bit 2 = -t/terse,
;                  bit 3 = -c/format given)
;   r12  = current file arg index
;   r13  = format string pointer (if -c/--format)
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE           1
%define SYS_STAT             4
%define SYS_LSTAT            6
%define SYS_EXIT            60
%define SYS_RT_SIGPROCMASK  14
%define SYS_READLINKAT     267
%define SYS_STATFS         137

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13
%define AT_FDCWD       -100

; BSS layout at 0x500000
%define BSS_ADDR       0x500000
%define BSS_SIZE       16384
%define STAT_BUF       BSS_ADDR             ; 144 bytes - struct stat
%define STATFS_BUF     (BSS_ADDR + 256)     ; 120 bytes - struct statfs
%define NUM_BUF        (BSS_ADDR + 512)     ; 64 bytes - number formatting
%define OUT_BUF        (BSS_ADDR + 576)     ; 8192 bytes - output buffer
%define LINK_BUF       (BSS_ADDR + 8768)    ; 4096 bytes - readlink buffer
%define MODE_BUF       (BSS_ADDR + 12864)   ; 16 bytes - mode string
%define OUT_POS        (BSS_ADDR + 12880)   ; 8 bytes - output buffer position
%define STATX_BUF      (BSS_ADDR + 12896)   ; 256 bytes - struct statx

; statx() syscall
%define SYS_STATX      332
%define AT_SYMLINK_NOFOLLOW     0x100
%define AT_EMPTY_PATH           0x1000
%define STATX_BASIC_STATS       0x7FF
%define STATX_BTIME             0x800

; struct statx offsets
%define STATX_MASK              0
%define STATX_BTIME_SEC         80    ; __s64 stx_btime.tv_sec
%define STATX_BTIME_NSEC        88    ; __u32 stx_btime.tv_nsec

; struct stat offsets (x86-64 Linux)
%define ST_DEV          0
%define ST_INO          8
%define ST_NLINK       16
%define ST_MODE        24
%define ST_UID         28
%define ST_GID         32
%define ST_PAD0        36
%define ST_RDEV        40
%define ST_SIZE        48
%define ST_BLKSIZE     56
%define ST_BLOCKS      64
%define ST_ATIME       72
%define ST_ATIME_NSEC  80
%define ST_MTIME       88
%define ST_MTIME_NSEC  96
%define ST_CTIME      104
%define ST_CTIME_NSEC 112

; struct statfs offsets (x86-64)
%define SF_TYPE         0
%define SF_BSIZE        8
%define SF_BLOCKS      16
%define SF_BFREE       24
%define SF_BAVAIL      32
%define SF_FILES       40
%define SF_FFREE       48
%define SF_FSID        56
%define SF_NAMELEN     64

; File type masks
%define S_IFMT   0xF000
%define S_IFSOCK 0xC000
%define S_IFLNK  0xA000
%define S_IFREG  0x8000
%define S_IFBLK  0x6000
%define S_IFDIR  0x4000
%define S_IFCHR  0x2000
%define S_IFIFO  0x1000

; Flag bits
%define FLAG_DEREF   0
%define FLAG_FS      1
%define FLAG_TERSE   2
%define FLAG_FORMAT  3

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

    ; Initialize
    xor     ebx, ebx            ; flags
    xor     r13d, r13d          ; format ptr
    mov     ecx, 1              ; arg index

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
    cmp     al, 'L'
    je      .set_deref
    cmp     al, 'f'
    je      .set_fs
    cmp     al, 't'
    je      .set_terse
    cmp     al, 'c'
    je      .set_format
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

.set_deref:
    or      bl, (1 << FLAG_DEREF)
    inc     rdi
    jmp     .short_loop

.set_fs:
    or      bl, (1 << FLAG_FS)
    inc     rdi
    jmp     .short_loop

.set_terse:
    or      bl, (1 << FLAG_TERSE)
    inc     rdi
    jmp     .short_loop

.set_format:
    or      bl, (1 << FLAG_FORMAT)
    inc     rdi
    ; Check if rest of short opt string is the format
    cmp     byte [rdi], 0
    jne     .format_inline
    ; Next arg is the format string
    inc     ecx
    cmp     ecx, r14d
    jge     .err_missing_format
    mov     r13, [r15 + rcx*8]
    inc     ecx
    jmp     .parse_opts

.format_inline:
    mov     r13, rdi
    jmp     .next_opt

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    push    rcx
    mov     r9, rdi
    ; --help
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_help
    ; --version
    mov     rdi, r9
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_version
    ; --dereference
    mov     rdi, r9
    mov     rsi, str_deref_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_deref
    ; --file-system
    mov     rdi, r9
    mov     rsi, str_filesys_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_fs
    ; --terse
    mov     rdi, r9
    mov     rsi, str_terse_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_terse
    ; --format=... or --printf=...
    mov     rdi, r9
    mov     rsi, str_format_eq
    mov     edx, 9
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_format_long
    mov     rdi, r9
    mov     rsi, str_printf_eq
    mov     edx, 9
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_printf_long
    ; Unrecognized
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_unrecog
    mov     edx, str_unrecog_len
    call    do_write_err
    mov     rdi, r9
    call    str_len
    mov     edx, eax
    mov     rsi, r9
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

.pop_set_deref:
    pop     rcx
    or      bl, (1 << FLAG_DEREF)
    inc     ecx
    jmp     .parse_opts

.pop_set_fs:
    pop     rcx
    or      bl, (1 << FLAG_FS)
    inc     ecx
    jmp     .parse_opts

.pop_set_terse:
    pop     rcx
    or      bl, (1 << FLAG_TERSE)
    inc     ecx
    jmp     .parse_opts

.pop_set_format_long:
    pop     rcx
    or      bl, (1 << FLAG_FORMAT)
    lea     r13, [r9 + 9]      ; skip "--format="
    inc     ecx
    jmp     .parse_opts

.pop_set_printf_long:
    pop     rcx
    or      bl, (1 << FLAG_FORMAT)
    lea     r13, [r9 + 9]      ; skip "--printf="
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
    xor     ebp, ebp            ; exit code

.file_loop:
    cmp     r12d, r14d
    jge     .exit_done
    mov     rdi, [r15 + r12*8]

    ; Reset output buffer
    mov     qword [OUT_POS], 0

    test    bl, (1 << FLAG_FS)
    jnz     .do_statfs

    ; stat or lstat the file
    test    bl, (1 << FLAG_DEREF)
    jnz     .do_stat_deref

    ; lstat (default: don't follow symlinks)
    mov     eax, SYS_LSTAT
    mov     rsi, STAT_BUF
    syscall
    test    rax, rax
    js      .stat_failed
    ; rdi still has filename (preserved across syscall)
    ; Call statx with AT_SYMLINK_NOFOLLOW to get birth time
    mov     rsi, rdi                ; rsi = pathname
    mov     eax, SYS_STATX
    mov     edi, AT_FDCWD           ; dirfd
    mov     edx, AT_SYMLINK_NOFOLLOW ; flags
    mov     r10d, STATX_BASIC_STATS | STATX_BTIME  ; mask
    mov     r8, STATX_BUF           ; statxbuf
    syscall
    ; If statx fails, zero out birth time
    test    rax, rax
    jns     .stat_ok
    mov     qword [STATX_BUF + STATX_BTIME_SEC], 0
    mov     dword [STATX_BUF + STATX_BTIME_NSEC], 0
    jmp     .stat_ok

.do_stat_deref:
    mov     eax, SYS_STAT
    mov     rsi, STAT_BUF
    syscall
    test    rax, rax
    js      .stat_failed
    ; rdi still has filename (preserved across syscall)
    ; Call statx without AT_SYMLINK_NOFOLLOW (follow symlinks) to get birth time
    mov     rsi, rdi                ; rsi = pathname
    mov     eax, SYS_STATX
    mov     edi, AT_FDCWD           ; dirfd
    xor     edx, edx               ; flags = 0 (follow symlinks)
    mov     r10d, STATX_BASIC_STATS | STATX_BTIME  ; mask
    mov     r8, STATX_BUF           ; statxbuf
    syscall
    ; If statx fails, zero out birth time
    test    rax, rax
    jns     .stat_ok
    mov     qword [STATX_BUF + STATX_BTIME_SEC], 0
    mov     dword [STATX_BUF + STATX_BTIME_NSEC], 0
    jmp     .stat_ok

.do_statfs:
    mov     eax, SYS_STATFS
    mov     rsi, STATFS_BUF
    syscall
    test    rax, rax
    js      .stat_failed

    ; Output filesystem info
    test    bl, (1 << FLAG_FORMAT)
    jnz     .format_fs_custom
    test    bl, (1 << FLAG_TERSE)
    jnz     .terse_fs_output
    jmp     .default_fs_output

.stat_ok:
    test    bl, (1 << FLAG_FORMAT)
    jnz     .format_custom
    test    bl, (1 << FLAG_TERSE)
    jnz     .terse_output
    jmp     .default_output

.stat_failed:
    ; Print error: "stat: cannot stat 'file': No such file or directory"
    neg     rax
    mov     r9, rax             ; save errno
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_stat
    mov     edx, str_cannot_stat_len
    call    do_write_err
    ; Print the filename in quotes
    mov     rsi, str_sq
    mov     edx, 1
    call    do_write_err
    mov     rdi, [r15 + r12*8]
    call    str_len
    mov     edx, eax
    mov     rsi, rdi
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    ; Pick error message
    cmp     r9d, 2              ; ENOENT
    je      .stat_err_noent
    cmp     r9d, 13             ; EACCES
    je      .stat_err_acces
    cmp     r9d, 20             ; ENOTDIR
    je      .stat_err_notdir
    ; Default: No such file or directory
.stat_err_noent:
    ; already printed above with sq_nl
    jmp     .stat_err_done
.stat_err_acces:
.stat_err_notdir:
.stat_err_done:
    mov     ebp, 1
    inc     r12d
    jmp     .file_loop

; ============================================================
; Default output format (like GNU stat)
; ============================================================
.default_output:
    push    r12
    mov     r12, [r15 + r12*8]  ; filename ptr

    ; "  File: " + filename (+ link target for symlinks)
    mov     rsi, str_file_label
    mov     edx, str_file_label_len
    call    buf_write
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    buf_write

    ; Check if symlink, append " -> target"
    movzx   eax, word [STAT_BUF + ST_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFLNK
    jne     .def_after_link

    mov     rsi, str_arrow
    mov     edx, str_arrow_len
    call    buf_write
    ; readlinkat to get target
    mov     eax, SYS_READLINKAT
    mov     edi, AT_FDCWD
    mov     rsi, r12
    mov     rdx, LINK_BUF
    mov     r10d, 4095
    syscall
    test    rax, rax
    js      .def_after_link
    mov     byte [LINK_BUF + rax], 0
    mov     edx, eax
    mov     rsi, LINK_BUF
    call    buf_write

.def_after_link:
    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write

    ; "  Size: N  Blocks: N  IO Block: N  type"
    mov     rsi, str_size_label
    mov     edx, str_size_label_len
    call    buf_write
    mov     rdi, [STAT_BUF + ST_SIZE]
    call    format_u64
    call    buf_write

    mov     rsi, str_blocks_label
    mov     edx, str_blocks_label_len
    call    buf_write
    mov     rdi, [STAT_BUF + ST_BLOCKS]
    call    format_u64
    call    buf_write

    mov     rsi, str_ioblock_label
    mov     edx, str_ioblock_label_len
    call    buf_write
    mov     rdi, [STAT_BUF + ST_BLKSIZE]
    call    format_u64
    call    buf_write

    ; File type
    mov     rsi, str_type_sep
    mov     edx, str_type_sep_len
    call    buf_write
    movzx   edi, word [STAT_BUF + ST_MODE]
    call    get_file_type_str
    call    buf_write

    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write

    ; "Device: Xh/Yd  Inode: N  Links: N"
    mov     rsi, str_device_label
    mov     edx, str_device_label_len
    call    buf_write
    mov     rdi, [STAT_BUF + ST_DEV]
    call    format_dev_hex
    call    buf_write

    mov     rsi, str_inode_label
    mov     edx, str_inode_label_len
    call    buf_write
    mov     rdi, [STAT_BUF + ST_INO]
    call    format_u64
    call    buf_write

    mov     rsi, str_links_label
    mov     edx, str_links_label_len
    call    buf_write
    mov     rdi, [STAT_BUF + ST_NLINK]
    call    format_u64
    call    buf_write

    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write

    ; "Access: (OCTAL/PERMS)  Uid: ( N/ name)  Gid: ( N/ name)"
    mov     rsi, str_access_label
    mov     edx, str_access_label_len
    call    buf_write
    mov     rsi, str_lparen
    mov     edx, 1
    call    buf_write
    movzx   edi, word [STAT_BUF + ST_MODE]
    call    format_octal_mode
    call    buf_write
    mov     rsi, str_slash
    mov     edx, 1
    call    buf_write
    movzx   edi, word [STAT_BUF + ST_MODE]
    call    format_rwx_mode
    call    buf_write
    mov     rsi, str_rparen
    mov     edx, 1
    call    buf_write

    mov     rsi, str_uid_label
    mov     edx, str_uid_label_len
    call    buf_write
    mov     edi, dword [STAT_BUF + ST_UID]
    call    format_u64_rdi
    call    buf_write
    mov     rsi, str_uid_sep
    mov     edx, str_uid_sep_len
    call    buf_write

    mov     rsi, str_gid_label
    mov     edx, str_gid_label_len
    call    buf_write
    mov     edi, dword [STAT_BUF + ST_GID]
    call    format_u64_rdi
    call    buf_write
    mov     rsi, str_gid_sep
    mov     edx, str_gid_sep_len
    call    buf_write

    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write

    ; "Access: timestamp"
    mov     rsi, str_access_ts
    mov     edx, str_access_ts_len
    call    buf_write
    mov     rdi, [STAT_BUF + ST_ATIME]
    mov     rsi, [STAT_BUF + ST_ATIME_NSEC]
    call    format_timestamp
    call    buf_write
    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write

    ; "Modify: timestamp"
    mov     rsi, str_modify_ts
    mov     edx, str_modify_ts_len
    call    buf_write
    mov     rdi, [STAT_BUF + ST_MTIME]
    mov     rsi, [STAT_BUF + ST_MTIME_NSEC]
    call    format_timestamp
    call    buf_write
    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write

    ; "Change: timestamp"
    mov     rsi, str_change_ts
    mov     edx, str_change_ts_len
    call    buf_write
    mov     rdi, [STAT_BUF + ST_CTIME]
    mov     rsi, [STAT_BUF + ST_CTIME_NSEC]
    call    format_timestamp
    call    buf_write
    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write

    ; " Birth: <timestamp>" or " Birth: -"
    mov     rdi, [STATX_BUF + STATX_BTIME_SEC]
    test    rdi, rdi
    jz      .def_birth_unknown
    ; Have birth time - show " Birth: <timestamp>"
    mov     rsi, str_birth_label
    mov     edx, str_birth_label_len
    call    buf_write
    mov     rdi, [STATX_BUF + STATX_BTIME_SEC]
    mov     esi, dword [STATX_BUF + STATX_BTIME_NSEC]
    call    format_timestamp
    call    buf_write
    jmp     .def_birth_done
.def_birth_unknown:
    mov     rsi, str_birth_ts
    mov     edx, str_birth_ts_len
    call    buf_write
.def_birth_done:
    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write

    ; Flush output buffer
    call    buf_flush

    pop     r12
    inc     r12d
    jmp     .file_loop

; ============================================================
; Terse output: %n %s %b %f %u %g %D %i %h %t %T %X %Y %Z %W %o
; ============================================================
.terse_output:
    push    r12
    mov     r12, [r15 + r12*8]

    ; name
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; size
    mov     rdi, [STAT_BUF + ST_SIZE]
    call    format_u64
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; blocks
    mov     rdi, [STAT_BUF + ST_BLOCKS]
    call    format_u64
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; raw mode hex
    movzx   edi, word [STAT_BUF + ST_MODE]
    call    format_hex_lower
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; uid
    mov     edi, dword [STAT_BUF + ST_UID]
    call    format_u64_rdi
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; gid
    mov     edi, dword [STAT_BUF + ST_GID]
    call    format_u64_rdi
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; device hex
    mov     rdi, [STAT_BUF + ST_DEV]
    call    format_hex_lower_full
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; inode
    mov     rdi, [STAT_BUF + ST_INO]
    call    format_u64
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; links
    mov     rdi, [STAT_BUF + ST_NLINK]
    call    format_u64
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; major hex
    mov     rdi, [STAT_BUF + ST_RDEV]
    shr     rdi, 8
    and     edi, 0xFFF
    call    format_hex_lower
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; minor hex
    mov     rdi, [STAT_BUF + ST_RDEV]
    mov     rax, rdi
    and     edi, 0xFF
    shr     rax, 12
    and     eax, 0xFFF00
    or      edi, eax
    call    format_hex_lower
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; atime epoch
    mov     rdi, [STAT_BUF + ST_ATIME]
    call    format_u64
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; mtime epoch
    mov     rdi, [STAT_BUF + ST_MTIME]
    call    format_u64
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; ctime epoch
    mov     rdi, [STAT_BUF + ST_CTIME]
    call    format_u64
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; birth epoch (from statx, 0 if unavailable)
    mov     rdi, [STATX_BUF + STATX_BTIME_SEC]
    call    format_u64
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; IO block size
    mov     rdi, [STAT_BUF + ST_BLKSIZE]
    call    format_u64
    call    buf_write

    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write
    call    buf_flush

    pop     r12
    inc     r12d
    jmp     .file_loop

; ============================================================
; Custom format output (-c FORMAT)
; Process format specifiers: %a %A %b %B %d %D %f %F %g %G
;   %h %i %m %n %N %o %s %t %T %u %U %w %W %x %X %y %Y %z %Z
; ============================================================
.format_custom:
    push    r12
    mov     r12, [r15 + r12*8]  ; filename
    mov     rdi, r13            ; format string

.fc_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .fc_done
    cmp     al, '%'
    je      .fc_percent
    cmp     al, '\'
    je      .fc_escape
    ; Regular char
    mov     byte [NUM_BUF], al
    push    rdi
    mov     rsi, NUM_BUF
    mov     edx, 1
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_escape:
    inc     rdi
    movzx   eax, byte [rdi]
    test    al, al
    jz      .fc_done
    cmp     al, 'n'
    je      .fc_esc_nl
    cmp     al, 't'
    je      .fc_esc_tab
    cmp     al, '\'
    je      .fc_esc_bslash
    ; Unknown escape - output literally
    mov     byte [NUM_BUF], '\'
    push    rdi
    mov     rsi, NUM_BUF
    mov     edx, 1
    call    buf_write
    pop     rdi
    jmp     .fc_loop

.fc_esc_nl:
    push    rdi
    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_esc_tab:
    push    rdi
    mov     byte [NUM_BUF], 9
    mov     rsi, NUM_BUF
    mov     edx, 1
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_esc_bslash:
    push    rdi
    mov     byte [NUM_BUF], '\'
    mov     rsi, NUM_BUF
    mov     edx, 1
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_percent:
    inc     rdi
    movzx   eax, byte [rdi]
    cmp     al, '%'
    je      .fc_pct_literal
    cmp     al, 'a'
    je      .fc_pct_a
    cmp     al, 'A'
    je      .fc_pct_A
    cmp     al, 'b'
    je      .fc_pct_b
    cmp     al, 'B'
    je      .fc_pct_B
    cmp     al, 'd'
    je      .fc_pct_d
    cmp     al, 'D'
    je      .fc_pct_D
    cmp     al, 'f'
    je      .fc_pct_f
    cmp     al, 'F'
    je      .fc_pct_F
    cmp     al, 'g'
    je      .fc_pct_g
    cmp     al, 'G'
    je      .fc_pct_G
    cmp     al, 'h'
    je      .fc_pct_h
    cmp     al, 'i'
    je      .fc_pct_i
    cmp     al, 'n'
    je      .fc_pct_n
    cmp     al, 'N'
    je      .fc_pct_N
    cmp     al, 'o'
    je      .fc_pct_o
    cmp     al, 's'
    je      .fc_pct_s
    cmp     al, 't'
    je      .fc_pct_t
    cmp     al, 'T'
    je      .fc_pct_T
    cmp     al, 'u'
    je      .fc_pct_u
    cmp     al, 'U'
    je      .fc_pct_U
    cmp     al, 'w'
    je      .fc_pct_w
    cmp     al, 'W'
    je      .fc_pct_W
    cmp     al, 'x'
    je      .fc_pct_x
    cmp     al, 'X'
    je      .fc_pct_X
    cmp     al, 'y'
    je      .fc_pct_y
    cmp     al, 'Y'
    je      .fc_pct_Y
    cmp     al, 'z'
    je      .fc_pct_z
    cmp     al, 'Z'
    je      .fc_pct_Z
    ; Unknown %spec - output %X literally
    mov     byte [NUM_BUF], '%'
    mov     byte [NUM_BUF + 1], al
    push    rdi
    mov     rsi, NUM_BUF
    mov     edx, 2
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_literal:
    push    rdi
    mov     byte [NUM_BUF], '%'
    mov     rsi, NUM_BUF
    mov     edx, 1
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_a:  ; octal mode
    push    rdi
    movzx   edi, word [STAT_BUF + ST_MODE]
    call    format_octal_mode
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_A:  ; rwx mode
    push    rdi
    movzx   edi, word [STAT_BUF + ST_MODE]
    call    format_rwx_mode
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_b:  ; blocks
    push    rdi
    mov     rdi, [STAT_BUF + ST_BLOCKS]
    call    format_u64
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_B:  ; block size (512)
    push    rdi
    mov     rsi, str_512
    mov     edx, 3
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_d:  ; device decimal
    push    rdi
    mov     rdi, [STAT_BUF + ST_DEV]
    call    format_u64
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_D:  ; device hex
    push    rdi
    mov     rdi, [STAT_BUF + ST_DEV]
    call    format_hex_lower_full
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_f:  ; raw mode hex
    push    rdi
    movzx   edi, word [STAT_BUF + ST_MODE]
    call    format_hex_lower
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_F:  ; file type
    push    rdi
    movzx   edi, word [STAT_BUF + ST_MODE]
    call    get_file_type_str
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_g:  ; gid
    push    rdi
    mov     edi, dword [STAT_BUF + ST_GID]
    call    format_u64_rdi
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_G:  ; group name (just numeric for assembly)
    push    rdi
    mov     edi, dword [STAT_BUF + ST_GID]
    call    format_u64_rdi
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_h:  ; nlinks
    push    rdi
    mov     rdi, [STAT_BUF + ST_NLINK]
    call    format_u64
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_i:  ; inode
    push    rdi
    mov     rdi, [STAT_BUF + ST_INO]
    call    format_u64
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_n:  ; name
    push    rdi
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_N:  ; quoted name (with link target for symlinks)
    push    rdi
    ; Print quoted name
    mov     rsi, str_sq
    mov     edx, 1
    call    buf_write
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    buf_write
    mov     rsi, str_sq
    mov     edx, 1
    call    buf_write
    ; Check if symlink
    movzx   eax, word [STAT_BUF + ST_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFLNK
    jne     .fc_pct_N_done
    mov     rsi, str_arrow
    mov     edx, str_arrow_len
    call    buf_write
    mov     rsi, str_sq
    mov     edx, 1
    call    buf_write
    ; readlinkat
    mov     eax, SYS_READLINKAT
    mov     edi, AT_FDCWD
    mov     rsi, r12
    mov     rdx, LINK_BUF
    mov     r10d, 4095
    syscall
    test    rax, rax
    js      .fc_pct_N_done
    mov     byte [LINK_BUF + rax], 0
    mov     edx, eax
    mov     rsi, LINK_BUF
    call    buf_write
    mov     rsi, str_sq
    mov     edx, 1
    call    buf_write
.fc_pct_N_done:
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_o:  ; IO block
    push    rdi
    mov     rdi, [STAT_BUF + ST_BLKSIZE]
    call    format_u64
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_s:  ; size
    push    rdi
    mov     rdi, [STAT_BUF + ST_SIZE]
    call    format_u64
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_t:  ; major hex
    push    rdi
    mov     rdi, [STAT_BUF + ST_RDEV]
    shr     rdi, 8
    and     edi, 0xFFF
    call    format_hex_lower
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_T:  ; minor hex
    push    rdi
    mov     rdi, [STAT_BUF + ST_RDEV]
    mov     rax, rdi
    and     edi, 0xFF
    shr     rax, 12
    and     eax, 0xFFF00
    or      edi, eax
    call    format_hex_lower
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_u:  ; uid
    push    rdi
    mov     edi, dword [STAT_BUF + ST_UID]
    call    format_u64_rdi
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_U:  ; user name (just numeric)
    push    rdi
    mov     edi, dword [STAT_BUF + ST_UID]
    call    format_u64_rdi
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_w:  ; birth time (formatted timestamp or "-")
    push    rdi
    mov     rdi, [STATX_BUF + STATX_BTIME_SEC]
    test    rdi, rdi
    jz      .fc_pct_w_unknown
    mov     esi, dword [STATX_BUF + STATX_BTIME_NSEC]
    call    format_timestamp
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop
.fc_pct_w_unknown:
    mov     rsi, str_dash
    mov     edx, 1
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_W:  ; birth epoch (seconds or 0)
    push    rdi
    mov     rdi, [STATX_BUF + STATX_BTIME_SEC]
    call    format_u64
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_x:  ; access time
    push    rdi
    mov     rdi, [STAT_BUF + ST_ATIME]
    mov     rsi, [STAT_BUF + ST_ATIME_NSEC]
    call    format_timestamp
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_X:  ; access epoch
    push    rdi
    mov     rdi, [STAT_BUF + ST_ATIME]
    call    format_u64
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_y:  ; modify time
    push    rdi
    mov     rdi, [STAT_BUF + ST_MTIME]
    mov     rsi, [STAT_BUF + ST_MTIME_NSEC]
    call    format_timestamp
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_Y:  ; modify epoch
    push    rdi
    mov     rdi, [STAT_BUF + ST_MTIME]
    call    format_u64
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_z:  ; change time
    push    rdi
    mov     rdi, [STAT_BUF + ST_CTIME]
    mov     rsi, [STAT_BUF + ST_CTIME_NSEC]
    call    format_timestamp
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_pct_Z:  ; change epoch
    push    rdi
    mov     rdi, [STAT_BUF + ST_CTIME]
    call    format_u64
    call    buf_write
    pop     rdi
    inc     rdi
    jmp     .fc_loop

.fc_done:
    ; Flush and add newline for -c (not --printf)
    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write
    call    buf_flush
    pop     r12
    inc     r12d
    jmp     .file_loop

; ============================================================
; Default filesystem output
; ============================================================
.default_fs_output:
    push    r12
    mov     r12, [r15 + r12*8]

    mov     rsi, str_fs_file_label
    mov     edx, str_fs_file_label_len
    call    buf_write
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    buf_write
    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write

    ; ID / Namelen / Block size / Fundamental block size
    mov     rsi, str_fs_id_label
    mov     edx, str_fs_id_label_len
    call    buf_write
    mov     rdi, [STATFS_BUF + SF_FSID]
    call    format_hex_lower_full
    call    buf_write
    mov     rsi, str_fs_namelen_label
    mov     edx, str_fs_namelen_label_len
    call    buf_write
    mov     rdi, [STATFS_BUF + SF_NAMELEN]
    call    format_u64
    call    buf_write
    mov     rsi, str_fs_type_label
    mov     edx, str_fs_type_label_len
    call    buf_write
    mov     rdi, [STATFS_BUF + SF_TYPE]
    call    format_hex_lower
    call    buf_write
    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write

    ; Block size / Blocks / Free / Available
    mov     rsi, str_fs_bsize_label
    mov     edx, str_fs_bsize_label_len
    call    buf_write
    mov     rdi, [STATFS_BUF + SF_BSIZE]
    call    format_u64
    call    buf_write
    mov     rsi, str_fs_blocks_label
    mov     edx, str_fs_blocks_label_len
    call    buf_write
    mov     rdi, [STATFS_BUF + SF_BLOCKS]
    call    format_u64
    call    buf_write
    mov     rsi, str_fs_bfree_label
    mov     edx, str_fs_bfree_label_len
    call    buf_write
    mov     rdi, [STATFS_BUF + SF_BFREE]
    call    format_u64
    call    buf_write
    mov     rsi, str_fs_bavail_label
    mov     edx, str_fs_bavail_label_len
    call    buf_write
    mov     rdi, [STATFS_BUF + SF_BAVAIL]
    call    format_u64
    call    buf_write
    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write

    ; Inodes / Free inodes
    mov     rsi, str_fs_files_label
    mov     edx, str_fs_files_label_len
    call    buf_write
    mov     rdi, [STATFS_BUF + SF_FILES]
    call    format_u64
    call    buf_write
    mov     rsi, str_fs_ffree_label
    mov     edx, str_fs_ffree_label_len
    call    buf_write
    mov     rdi, [STATFS_BUF + SF_FFREE]
    call    format_u64
    call    buf_write
    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write

    call    buf_flush
    pop     r12
    inc     r12d
    jmp     .file_loop

; ============================================================
; Terse filesystem output
; ============================================================
.terse_fs_output:
    push    r12
    mov     r12, [r15 + r12*8]

    ; name
    mov     rdi, r12
    call    str_len
    mov     edx, eax
    mov     rsi, r12
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; fs id hex
    mov     rdi, [STATFS_BUF + SF_FSID]
    call    format_hex_lower_full
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; namelen
    mov     rdi, [STATFS_BUF + SF_NAMELEN]
    call    format_u64
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; type hex
    mov     rdi, [STATFS_BUF + SF_TYPE]
    call    format_hex_lower
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; bsize
    mov     rdi, [STATFS_BUF + SF_BSIZE]
    call    format_u64
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; blocks
    mov     rdi, [STATFS_BUF + SF_BLOCKS]
    call    format_u64
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; bfree
    mov     rdi, [STATFS_BUF + SF_BFREE]
    call    format_u64
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; bavail
    mov     rdi, [STATFS_BUF + SF_BAVAIL]
    call    format_u64
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; files
    mov     rdi, [STATFS_BUF + SF_FILES]
    call    format_u64
    call    buf_write
    mov     rsi, str_space
    mov     edx, 1
    call    buf_write

    ; ffree
    mov     rdi, [STATFS_BUF + SF_FFREE]
    call    format_u64
    call    buf_write

    mov     rsi, str_newline
    mov     edx, 1
    call    buf_write
    call    buf_flush

    pop     r12
    inc     r12d
    jmp     .file_loop

; Filesystem custom format stub (just prints like terse for now)
.format_fs_custom:
    jmp     .terse_fs_output

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

.err_missing_format:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing_fmt
    mov     edx, str_missing_fmt_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; ============================================================
; Output buffer routines
; ============================================================
buf_write:
    ; rsi = data, edx = length
    push    rdi
    push    rcx
    mov     rcx, [OUT_POS]
    ; Copy to OUT_BUF + rcx
    xor     eax, eax
.bw_loop:
    cmp     eax, edx
    jge     .bw_done
    movzx   r8d, byte [rsi + rax]
    mov     byte [OUT_BUF + rcx], r8b
    inc     rcx
    inc     eax
    ; Flush if buffer near full
    cmp     ecx, 8000
    jl      .bw_loop
    mov     [OUT_POS], rcx
    push    rsi
    push    rdx
    push    rax
    call    buf_flush
    pop     rax
    pop     rdx
    pop     rsi
    xor     ecx, ecx
    jmp     .bw_loop
.bw_done:
    mov     [OUT_POS], rcx
    pop     rcx
    pop     rdi
    ret

buf_flush:
    mov     rcx, [OUT_POS]
    test    rcx, rcx
    jz      .bf_done
    mov     edi, STDOUT
    mov     rsi, OUT_BUF
    mov     edx, ecx
    call    do_write
    mov     qword [OUT_POS], 0
.bf_done:
    ret

; ============================================================
; Number formatting
; ============================================================

; format_u64: format rdi as unsigned decimal
; Returns: rsi = start, edx = length
format_u64:
    mov     rax, rdi
    lea     rcx, [NUM_BUF + 63]
    mov     byte [rcx], 0
    mov     r8d, 10
.fu_loop:
    xor     edx, edx
    div     r8
    add     dl, '0'
    dec     rcx
    mov     byte [rcx], dl
    test    rax, rax
    jnz     .fu_loop
    mov     rsi, rcx
    lea     edx, [NUM_BUF + 63]
    sub     edx, ecx
    ret

; format_u64_rdi: same but for 32-bit values zero-extended
format_u64_rdi:
    mov     edi, edi            ; zero-extend edi to rdi
    jmp     format_u64

; format_hex_lower: format edi as lowercase hex (no leading zeros, no 0x prefix)
format_hex_lower:
    mov     eax, edi
    lea     rcx, [NUM_BUF + 63]
    mov     byte [rcx], 0
    test    eax, eax
    jnz     .fhl_loop
    dec     rcx
    mov     byte [rcx], '0'
    jmp     .fhl_done
.fhl_loop:
    test    eax, eax
    jz      .fhl_done
    mov     edx, eax
    and     edx, 0xF
    cmp     edx, 10
    jl      .fhl_digit
    add     dl, ('a' - 10)
    jmp     .fhl_store
.fhl_digit:
    add     dl, '0'
.fhl_store:
    dec     rcx
    mov     byte [rcx], dl
    shr     eax, 4
    jmp     .fhl_loop
.fhl_done:
    mov     rsi, rcx
    lea     edx, [NUM_BUF + 63]
    sub     edx, ecx
    ret

; format_hex_lower_full: format rdi as lowercase hex (no leading zeros)
format_hex_lower_full:
    mov     rax, rdi
    lea     rcx, [NUM_BUF + 63]
    mov     byte [rcx], 0
    test    rax, rax
    jnz     .fhlf_loop
    dec     rcx
    mov     byte [rcx], '0'
    jmp     .fhlf_done
.fhlf_loop:
    test    rax, rax
    jz      .fhlf_done
    mov     edx, eax
    and     edx, 0xF
    cmp     edx, 10
    jl      .fhlf_digit
    add     dl, ('a' - 10)
    jmp     .fhlf_store
.fhlf_digit:
    add     dl, '0'
.fhlf_store:
    dec     rcx
    mov     byte [rcx], dl
    shr     rax, 4
    jmp     .fhlf_loop
.fhlf_done:
    mov     rsi, rcx
    lea     edx, [NUM_BUF + 63]
    sub     edx, ecx
    ret

; format_octal_mode: format lower 12 bits of edi as octal (no leading zeros)
; Returns: rsi = start, edx = length
format_octal_mode:
    and     edi, 0xFFF
    mov     eax, edi
    lea     rcx, [NUM_BUF + 10]
    mov     byte [rcx], 0
    ; Handle zero specially
    test    eax, eax
    jnz     .fom_loop
    dec     rcx
    mov     byte [rcx], '0'
    jmp     .fom_done
.fom_loop:
    test    eax, eax
    jz      .fom_done
    mov     edx, eax
    and     edx, 7
    add     dl, '0'
    dec     rcx
    mov     byte [rcx], dl
    shr     eax, 3
    jmp     .fom_loop
.fom_done:
    mov     rsi, rcx
    lea     edx, [NUM_BUF + 10]
    sub     edx, ecx
    ret

; format_rwx_mode: format mode as drwxrwxrwx string (10 chars)
; Input: edi = mode, Returns: rsi = MODE_BUF, edx = 10
format_rwx_mode:
    push    rdi
    ; First char: file type
    mov     eax, edi
    and     eax, S_IFMT
    cmp     eax, S_IFDIR
    je      .frm_dir
    cmp     eax, S_IFLNK
    je      .frm_lnk
    cmp     eax, S_IFCHR
    je      .frm_chr
    cmp     eax, S_IFBLK
    je      .frm_blk
    cmp     eax, S_IFIFO
    je      .frm_fifo
    cmp     eax, S_IFSOCK
    je      .frm_sock
    mov     byte [MODE_BUF], '-'
    jmp     .frm_perms
.frm_dir:
    mov     byte [MODE_BUF], 'd'
    jmp     .frm_perms
.frm_lnk:
    mov     byte [MODE_BUF], 'l'
    jmp     .frm_perms
.frm_chr:
    mov     byte [MODE_BUF], 'c'
    jmp     .frm_perms
.frm_blk:
    mov     byte [MODE_BUF], 'b'
    jmp     .frm_perms
.frm_fifo:
    mov     byte [MODE_BUF], 'p'
    jmp     .frm_perms
.frm_sock:
    mov     byte [MODE_BUF], 's'
    jmp     .frm_perms

.frm_perms:
    pop     rdi
    ; Owner rwx
    mov     byte [MODE_BUF + 1], '-'
    test    edi, 0x100
    jz      .frm_p2
    mov     byte [MODE_BUF + 1], 'r'
.frm_p2:
    mov     byte [MODE_BUF + 2], '-'
    test    edi, 0x80
    jz      .frm_p3
    mov     byte [MODE_BUF + 2], 'w'
.frm_p3:
    mov     byte [MODE_BUF + 3], '-'
    test    edi, 0x40
    jz      .frm_p3s
    mov     byte [MODE_BUF + 3], 'x'
.frm_p3s:
    test    edi, 0x800           ; setuid
    jz      .frm_p4
    test    edi, 0x40
    jz      .frm_p3S
    mov     byte [MODE_BUF + 3], 's'
    jmp     .frm_p4
.frm_p3S:
    mov     byte [MODE_BUF + 3], 'S'

.frm_p4:
    ; Group rwx
    mov     byte [MODE_BUF + 4], '-'
    test    edi, 0x20
    jz      .frm_p5
    mov     byte [MODE_BUF + 4], 'r'
.frm_p5:
    mov     byte [MODE_BUF + 5], '-'
    test    edi, 0x10
    jz      .frm_p6
    mov     byte [MODE_BUF + 5], 'w'
.frm_p6:
    mov     byte [MODE_BUF + 6], '-'
    test    edi, 0x8
    jz      .frm_p6s
    mov     byte [MODE_BUF + 6], 'x'
.frm_p6s:
    test    edi, 0x400           ; setgid
    jz      .frm_p7
    test    edi, 0x8
    jz      .frm_p6S
    mov     byte [MODE_BUF + 6], 's'
    jmp     .frm_p7
.frm_p6S:
    mov     byte [MODE_BUF + 6], 'S'

.frm_p7:
    ; Other rwx
    mov     byte [MODE_BUF + 7], '-'
    test    edi, 0x4
    jz      .frm_p8
    mov     byte [MODE_BUF + 7], 'r'
.frm_p8:
    mov     byte [MODE_BUF + 8], '-'
    test    edi, 0x2
    jz      .frm_p9
    mov     byte [MODE_BUF + 8], 'w'
.frm_p9:
    mov     byte [MODE_BUF + 9], '-'
    test    edi, 0x1
    jz      .frm_p9t
    mov     byte [MODE_BUF + 9], 'x'
.frm_p9t:
    test    edi, 0x200           ; sticky
    jz      .frm_done
    test    edi, 0x1
    jz      .frm_p9T
    mov     byte [MODE_BUF + 9], 't'
    jmp     .frm_done
.frm_p9T:
    mov     byte [MODE_BUF + 9], 'T'

.frm_done:
    mov     rsi, MODE_BUF
    mov     edx, 10
    ret

; get_file_type_str: return file type string
; Input: edi = mode, Returns: rsi = string, edx = length
get_file_type_str:
    and     edi, S_IFMT
    cmp     edi, S_IFREG
    je      .gft_reg
    cmp     edi, S_IFDIR
    je      .gft_dir
    cmp     edi, S_IFLNK
    je      .gft_lnk
    cmp     edi, S_IFCHR
    je      .gft_chr
    cmp     edi, S_IFBLK
    je      .gft_blk
    cmp     edi, S_IFIFO
    je      .gft_fifo
    cmp     edi, S_IFSOCK
    je      .gft_sock
    mov     rsi, str_type_unknown
    mov     edx, str_type_unknown_len
    ret
.gft_reg:
    ; Check if file size is 0 -> "regular empty file"
    cmp     qword [STAT_BUF + ST_SIZE], 0
    jne     .gft_reg_nonempty
    mov     rsi, str_type_reg_empty
    mov     edx, str_type_reg_empty_len
    ret
.gft_reg_nonempty:
    mov     rsi, str_type_reg
    mov     edx, str_type_reg_len
    ret
.gft_dir:
    mov     rsi, str_type_dir
    mov     edx, str_type_dir_len
    ret
.gft_lnk:
    mov     rsi, str_type_lnk
    mov     edx, str_type_lnk_len
    ret
.gft_chr:
    mov     rsi, str_type_chr
    mov     edx, str_type_chr_len
    ret
.gft_blk:
    mov     rsi, str_type_blk
    mov     edx, str_type_blk_len
    ret
.gft_fifo:
    mov     rsi, str_type_fifo
    mov     edx, str_type_fifo_len
    ret
.gft_sock:
    mov     rsi, str_type_sock
    mov     edx, str_type_sock_len
    ret

; format_dev_hex: format device number as "Xh/Yd" (major*256+minor in hex / decimal)
; Input: rdi = st_dev, Returns: rsi, edx
format_dev_hex:
    push    rdi
    call    format_hex_lower_full
    push    rsi
    push    rdx
    ; Write hex part to NUM_BUF+20 area
    lea     rdi, [NUM_BUF + 20]
    pop     rcx                 ; hex len
    pop     rsi                 ; hex ptr
    xor     eax, eax
.fdh_copy:
    cmp     eax, ecx
    jge     .fdh_hex_done
    movzx   r8d, byte [rsi + rax]
    mov     byte [rdi + rax], r8b
    inc     eax
    jmp     .fdh_copy
.fdh_hex_done:
    mov     byte [rdi + rax], 'h'
    inc     eax
    mov     rsi, rdi
    mov     edx, eax
    pop     rdi
    ret

; format_timestamp: format epoch time as "YYYY-MM-DD HH:MM:SS.NNNNNNNNN +0000"
; Input: rdi = epoch seconds, rsi = nanoseconds
; Returns: rsi = start, edx = length
; Uses a simplified UTC-only formatter
format_timestamp:
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12, rdi            ; epoch
    mov     r13, rsi            ; nsec

    ; Compute date from epoch (days since 1970-01-01)
    ; seconds -> days
    mov     rax, r12
    xor     edx, edx
    mov     rcx, 86400
    div     rcx
    mov     rbx, rax            ; days since epoch
    mov     r14, rdx            ; remaining seconds

    ; Civil date from days (algorithm from Howard Hinnant)
    add     rax, 719468         ; days from 0000-03-01 to 1970-01-01
    mov     rbp, rax

    ; era = floor(days / 146097)
    xor     edx, edx
    mov     rcx, 146097
    cmp     rbp, 0
    jge     .ts_pos_era
    ; For negative: subtract 146096 first
    sub     rbp, 146096
.ts_pos_era:
    mov     rax, rbp
    xor     edx, edx
    div     rcx
    mov     r8, rax             ; era
    ; doe = days - era * 146097
    imul    rax, rcx
    mov     r9, rbp
    sub     r9, rax             ; doe (day of era, 0..146096)

    ; yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
    mov     rax, r9
    xor     edx, edx
    mov     rcx, 1460
    div     rcx
    mov     r10, rax            ; doe/1460

    mov     rax, r9
    xor     edx, edx
    mov     rcx, 36524
    div     rcx
    mov     r11, rax            ; doe/36524

    mov     rax, r9
    xor     edx, edx
    mov     rcx, 146096
    div     rcx                 ; doe/146096

    mov     rcx, r9
    sub     rcx, r10
    add     rcx, r11
    sub     rcx, rax
    mov     rax, rcx
    xor     edx, edx
    mov     rcx, 365
    div     rcx
    mov     r10, rax            ; yoe (year of era)

    ; year = yoe + era * 400
    imul    r8, 400
    add     r10, r8             ; year (March-based)

    ; doy = doe - (365*yoe + yoe/4 - yoe/100)
    mov     rax, r10
    sub     rax, r8             ; back to yoe
    push    rax
    imul    rax, 365
    mov     r11, rax
    pop     rax
    push    rax
    xor     edx, edx
    mov     rcx, 4
    div     rcx
    add     r11, rax
    pop     rax
    xor     edx, edx
    mov     rcx, 100
    div     rcx
    sub     r11, rax
    mov     rax, r9
    sub     rax, r11            ; doy

    ; mp = (5*doy + 2) / 153
    imul    rcx, rax, 5
    add     rcx, 2
    push    rax
    mov     rax, rcx
    xor     edx, edx
    mov     rcx, 153
    div     rcx
    mov     r8, rax             ; mp
    pop     rax

    ; day = doy - (153*mp+2)/5 + 1
    imul    rcx, r8, 153
    add     rcx, 2
    push    rax
    mov     rax, rcx
    xor     edx, edx
    mov     rcx, 5
    div     rcx
    mov     r9, rax             ; (153*mp+2)/5
    pop     rax
    sub     eax, r9d
    inc     eax
    mov     r9d, eax            ; day (1-31)

    ; month = mp + (mp < 10 ? 3 : -9)
    cmp     r8d, 10
    jl      .ts_m_lt10
    sub     r8d, 9
    jmp     .ts_m_done
.ts_m_lt10:
    add     r8d, 3
.ts_m_done:
    ; If month <= 2, year++
    cmp     r8d, 2
    jg      .ts_y_done
    inc     r10
.ts_y_done:

    ; Now format: YYYY-MM-DD HH:MM:SS.NNNNNNNNN +0000
    lea     rdi, [NUM_BUF]
    ; Year (4 digits)
    mov     eax, r10d
    mov     ecx, 1000
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     byte [rdi], al
    mov     eax, edx
    mov     ecx, 100
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     byte [rdi+1], al
    mov     eax, edx
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     byte [rdi+2], al
    add     dl, '0'
    mov     byte [rdi+3], dl
    mov     byte [rdi+4], '-'
    ; Month (2 digits)
    mov     eax, r8d
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     byte [rdi+5], al
    add     dl, '0'
    mov     byte [rdi+6], dl
    mov     byte [rdi+7], '-'
    ; Day (2 digits)
    mov     eax, r9d
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     byte [rdi+8], al
    add     dl, '0'
    mov     byte [rdi+9], dl
    mov     byte [rdi+10], ' '

    ; Time from remaining seconds
    mov     rax, r14
    xor     edx, edx
    mov     ecx, 3600
    div     ecx
    ; al = hour
    push    rdx
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     byte [rdi+11], al
    add     dl, '0'
    mov     byte [rdi+12], dl
    mov     byte [rdi+13], ':'
    pop     rax
    xor     edx, edx
    mov     ecx, 60
    div     ecx
    ; al = minute
    push    rdx
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     byte [rdi+14], al
    add     dl, '0'
    mov     byte [rdi+15], dl
    mov     byte [rdi+16], ':'
    pop     rax
    ; al = second
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     byte [rdi+17], al
    add     dl, '0'
    mov     byte [rdi+18], dl
    mov     byte [rdi+19], '.'

    ; Nanoseconds (9 digits)
    mov     rax, r13
    mov     ecx, 9
    lea     r8, [rdi + 28]      ; end position
.ts_ns_loop:
    xor     edx, edx
    push    rcx
    mov     rcx, 10
    div     rcx
    pop     rcx
    add     dl, '0'
    dec     r8
    mov     byte [r8], dl
    dec     ecx
    jnz     .ts_ns_loop

    ; " +0000"
    mov     byte [rdi+29], ' '
    mov     byte [rdi+30], '+'
    mov     byte [rdi+31], '0'
    mov     byte [rdi+32], '0'
    mov     byte [rdi+33], '0'
    mov     byte [rdi+34], '0'
    mov     byte [rdi+35], 0

    mov     rsi, rdi
    mov     edx, 35

    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
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
; @@DATA_START@@
str_help:
    db "Usage: stat [OPTION]... FILE...", 10
    db "Display file or file system status.", 10, 10
    db "  -L, --dereference     follow links", 10
    db "  -f, --file-system     display file system status instead of file status", 10
    db "  -c  --format=FORMAT   use the specified FORMAT instead of the default;", 10
    db "                          output a newline after each use of FORMAT", 10
    db "      --printf=FORMAT   like --format, but interpret backslash escapes,", 10
    db "                          and do not output a mandatory trailing newline;", 10
    db "                          if you want a newline, include \n in FORMAT", 10
    db "  -t, --terse           print the information in terse form", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/stat>", 10
    db "or available locally via: info '(coreutils) stat invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "stat (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Michael Meskes.", 10
str_version_len equ $ - str_version

str_prefix:      db "stat: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_missing:     db "missing operand", 10
str_missing_len  equ $ - str_missing
str_missing_fmt: db "option requires an argument -- 'c'", 10
str_missing_fmt_len equ $ - str_missing_fmt
str_sq_nl:       db "'", 10
str_sq:          db "'"
str_try:         db "Try 'stat --help' for more information.", 10
str_try_len      equ $ - str_try
str_cannot_stat: db "cannot stat '"
str_cannot_stat_len equ $ - str_cannot_stat
; @@DATA_END@@

str_newline:     db 10
str_space:       db ' '
str_slash:       db '/'
str_lparen:      db '('
str_rparen:      db ')'
str_dash:        db '-'
str_zero:        db '0'
str_512:         db "512"

str_help_flag:    db "--help", 0
str_version_flag: db "--version", 0
str_deref_flag:   db "--dereference", 0
str_filesys_flag: db "--file-system", 0
str_terse_flag:   db "--terse", 0
str_format_eq:    db "--format=", 0
str_printf_eq:    db "--printf=", 0

; Default output labels
str_file_label:    db "  File: "
str_file_label_len equ $ - str_file_label
str_arrow:         db " -> "
str_arrow_len      equ $ - str_arrow
str_size_label:    db "  Size: "
str_size_label_len equ $ - str_size_label
str_blocks_label:  db 9, "Blocks: "
str_blocks_label_len equ $ - str_blocks_label
str_ioblock_label: db "  IO Block: "
str_ioblock_label_len equ $ - str_ioblock_label
str_type_sep:      db "  "
str_type_sep_len   equ $ - str_type_sep
str_device_label:  db "Device: "
str_device_label_len equ $ - str_device_label
str_inode_label:   db 9, "Inode: "
str_inode_label_len equ $ - str_inode_label
str_links_label:   db "  Links: "
str_links_label_len equ $ - str_links_label
str_access_label:  db "Access: "
str_access_label_len equ $ - str_access_label
str_uid_label:     db "  Uid: ( "
str_uid_label_len  equ $ - str_uid_label
str_uid_sep:       db "/    ?)"
str_uid_sep_len    equ $ - str_uid_sep
str_gid_label:     db "   Gid: ( "
str_gid_label_len  equ $ - str_gid_label
str_gid_sep:       db "/    ?)"
str_gid_sep_len    equ $ - str_gid_sep
str_access_ts:     db "Access: "
str_access_ts_len  equ $ - str_access_ts
str_modify_ts:     db "Modify: "
str_modify_ts_len  equ $ - str_modify_ts
str_change_ts:     db "Change: "
str_change_ts_len  equ $ - str_change_ts
str_birth_ts:      db " Birth: -"
str_birth_ts_len   equ $ - str_birth_ts
str_birth_label:   db " Birth: "
str_birth_label_len equ $ - str_birth_label

; File type strings
str_type_reg:      db "regular file"
str_type_reg_len   equ $ - str_type_reg
str_type_reg_empty: db "regular empty file"
str_type_reg_empty_len equ $ - str_type_reg_empty
str_type_dir:      db "directory"
str_type_dir_len   equ $ - str_type_dir
str_type_lnk:      db "symbolic link"
str_type_lnk_len   equ $ - str_type_lnk
str_type_chr:      db "character special file"
str_type_chr_len   equ $ - str_type_chr
str_type_blk:      db "block special file"
str_type_blk_len   equ $ - str_type_blk
str_type_fifo:     db "fifo"
str_type_fifo_len  equ $ - str_type_fifo
str_type_sock:     db "socket"
str_type_sock_len  equ $ - str_type_sock
str_type_unknown:  db "weird file"
str_type_unknown_len equ $ - str_type_unknown

; Filesystem labels
str_fs_file_label:    db "  File: "
str_fs_file_label_len equ $ - str_fs_file_label
str_fs_id_label:      db "    ID: "
str_fs_id_label_len   equ $ - str_fs_id_label
str_fs_namelen_label: db " Namelen: "
str_fs_namelen_label_len equ $ - str_fs_namelen_label
str_fs_type_label:    db " Type: "
str_fs_type_label_len equ $ - str_fs_type_label
str_fs_bsize_label:   db "Block size: "
str_fs_bsize_label_len equ $ - str_fs_bsize_label
str_fs_blocks_label:  db "   Blocks: Total: "
str_fs_blocks_label_len equ $ - str_fs_blocks_label
str_fs_bfree_label:   db "      Free: "
str_fs_bfree_label_len equ $ - str_fs_bfree_label
str_fs_bavail_label:  db "      Available: "
str_fs_bavail_label_len equ $ - str_fs_bavail_label
str_fs_files_label:   db "Inodes: Total: "
str_fs_files_label_len equ $ - str_fs_files_label
str_fs_ffree_label:   db "      Free: "
str_fs_ffree_label_len equ $ - str_fs_ffree_label

file_size equ $ - $$
