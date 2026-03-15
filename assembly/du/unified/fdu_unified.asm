; ============================================================================
;  fdu_unified.asm — Unified single-file build of fdu
;  GNU-compatible "du" in x86_64 Linux assembly
;  Build: nasm -f bin unified/fdu_unified.asm -o fdu && chmod +x fdu
; ============================================================================

BITS 64
org 0x400000

; ── Linux syscall numbers and constants ──
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_STAT            4
%define SYS_FSTAT           5
%define SYS_LSTAT           6
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT           60
%define SYS_GETDENTS64    217

%define STDIN               0
%define STDOUT              1
%define STDERR              2

%define O_RDONLY            0
%define O_DIRECTORY     0x10000

%define EINTR               4
%define EPIPE              32
%define ENOENT              2
%define EACCES             13
%define ENOTDIR            20

; struct stat offsets (x86-64 Linux)
%define STAT_DEV            0
%define STAT_INO            8
%define STAT_NLINK         16
%define STAT_MODE          24
%define STAT_UID           28
%define STAT_GID           32
%define STAT_RDEV          40
%define STAT_SIZE          48
%define STAT_BLKSIZE       56
%define STAT_BLOCKS        64
%define STAT_ATIME         72
%define STAT_MTIME         88
%define STAT_CTIME        104
%define STAT_STRUCT_SIZE  144

; File type masks
%define S_IFMT          0o170000
%define S_IFDIR         0o040000
%define S_IFREG         0o100000
%define S_IFLNK         0o120000

; struct linux_dirent64
%define DIRENT_INO          0
%define DIRENT_OFF          8
%define DIRENT_RECLEN      16
%define DIRENT_TYPE        18
%define DIRENT_NAME        19

%define DT_DIR              4
%define DT_REG              8
%define DT_LNK             10

; Buffer sizes
%define OUT_BUF_SIZE    262144
%define FLUSH_THRESHOLD 131072
%define GETDENTS_SIZE    32768
%define PATH_MAX          4096

; Flag bits
%define FLAG_S          0x01    ; -s summary only
%define FLAG_H          0x02    ; -h human-readable
%define FLAG_A          0x04    ; -a all files
%define FLAG_C          0x08    ; -c grand total
%define FLAG_B          0x10    ; -b apparent size (bytes)
%define FLAG_K          0x20    ; -k kilobytes (default)
%define FLAG_M          0x40    ; -m megabytes
%define FLAG_SEP        0x80    ; -S separate dirs

%define MAX_FILES       4096

; ── BSS layout at fixed address ──
%define BSS_BASE        0x500000
%define b_argc          BSS_BASE
%define b_argv          (b_argc + 8)
%define b_flags         (b_argv + 8)
%define b_had_error     (b_flags + 1)
%define b_nfiles        (b_had_error + 8)       ; align to 8
%define b_file_ptrs     (b_nfiles + 8)
%define b_max_depth     (b_file_ptrs + MAX_FILES * 8)
%define b_grand_total   (b_max_depth + 8)       ; align to 8
%define b_stat_buf      (b_grand_total + 8)
%define b_du_path_buf   (b_stat_buf + STAT_STRUCT_SIZE)
%define b_itoa_buf      (b_du_path_buf + PATH_MAX)
%define b_getdents_buf  (b_itoa_buf + 32)
%define b_char_buf      (b_getdents_buf + GETDENTS_SIZE)
%define b_out_buf       (b_char_buf + 8)
%define BSS_END         (b_out_buf + OUT_BUF_SIZE)
%define BSS_SIZE        (BSS_END - BSS_BASE)

; ── Macros ──
%macro EXIT 1
    mov     rax, SYS_EXIT
    mov     rdi, %1
    syscall
%endmacro

; ── ELF Header ──
ehdr:
    db      0x7f, "ELF"
    db      2, 1, 1, 0
    dq      0
    dw      2
    dw      0x3E
    dd      1
    dq      _start
    dq      phdr - ehdr
    dq      0
    dd      0
    dw      ehdr_end - ehdr
    dw      phdr_size
    dw      3
    dw      0, 0, 0
ehdr_end:

; ── Program Headers ──
phdr:
    ; Code + Data (R+X)
    dd      1
    dd      5
    dq      0
    dq      0x400000
    dq      0x400000
    dq      file_end - ehdr
    dq      file_end - ehdr
    dq      0x1000
phdr_size equ $ - phdr

    ; BSS (R+W)
    dd      1
    dd      6
    dq      0
    dq      BSS_BASE
    dq      BSS_BASE
    dq      0
    dq      BSS_SIZE
    dq      0x1000

    ; GNU_STACK (NX)
    dd      0x6474E551
    dd      6
    dq      0, 0, 0, 0, 0
    dq      0x10

; ============================================================================
;                           CODE SECTION
; ============================================================================

_start:
    ; Block SIGPIPE
    sub     rsp, 16
    mov     qword [rsp], 0x1000
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    mov     rax, [rsp]
    mov     [b_argc], rax
    lea     rax, [rsp + 8]
    mov     [b_argv], rax

    mov     byte [b_flags], 0
    mov     byte [b_had_error], 0
    mov     qword [b_nfiles], 0
    mov     dword [b_max_depth], -1     ; unlimited
    mov     qword [b_grand_total], 0
    xor     r12d, r12d                  ; out_buf_used

    call    parse_args

    ; If no files, use "."
    cmp     qword [b_nfiles], 0
    jne     .have_files
    lea     rax, [dot_str]
    mov     [b_file_ptrs], rax
    mov     qword [b_nfiles], 1

.have_files:
    xor     ebx, ebx
.file_loop:
    cmp     rbx, [b_nfiles]
    jge     .check_total

    lea     rdi, [b_file_ptrs]
    mov     rsi, [rdi + rbx*8]
    push    rbx

    ; lstat the argument
    push    rsi
    lea     rdx, [b_stat_buf]
    mov     rax, SYS_LSTAT
    mov     rdi, rsi
    mov     rsi, rdx
    syscall
    pop     rsi
    test    rax, rax
    js      .file_stat_error

    ; Check if directory
    mov     eax, [b_stat_buf + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFDIR
    jne     .file_not_dir

    ; It's a directory — recursively sum
    mov     rdi, rsi
    xor     esi, esi            ; depth = 0
    call    du_directory
    jmp     .file_next

.file_not_dir:
    ; Single file — report its size
    call    get_file_size
    push    rax

    ; Print size + filename
    call    emit_size_value
    mov     al, 9               ; tab
    call    emit_byte
    ; filename
    pop     rax
    push    rax
    ; Get file index and filename
    mov     rbx, [rsp + 8]     ; saved rbx (file index)
    lea     rdi, [b_file_ptrs]
    mov     rsi, [rdi + rbx*8]
    push    rsi                 ; save filename

    mov     rdi, rsi
    call    asm_strlen
    mov     rdx, rax
    pop     rsi                 ; filename
    push    rsi
    mov     rdi, rsi
    call    emit_string_len
    mov     al, 10
    call    emit_byte

    pop     rsi                 ; discard
    pop     rax                 ; size
    add     [b_grand_total], rax
    jmp     .file_next

.file_stat_error:
    neg     rax
    mov     r13d, eax
    mov     rdi, rsi
    mov     esi, r13d
    call    err_file
    mov     byte [b_had_error], 1

.file_next:
    pop     rbx
    inc     rbx
    jmp     .file_loop

.check_total:
    ; If -c, print grand total
    test    byte [b_flags], FLAG_C
    jz      .all_done

    mov     rax, [b_grand_total]
    call    emit_size_value
    mov     al, 9
    call    emit_byte
    lea     rdi, [total_label]
    mov     edx, 5
    call    emit_string
    mov     al, 10
    call    emit_byte

.all_done:
    call    flush_output
    movzx   edi, byte [b_had_error]
    mov     eax, SYS_EXIT
    syscall

; ============================================================================
;  du_directory(rdi=path, esi=depth) -> rax=total_size
;  Recursively computes disk usage
; ============================================================================
du_directory:
    push    rbx
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     rbp, rsp
    sub     rsp, 16             ; local: [rbp-8]=total, [rbp-16]=depth

    mov     [rbp-16], rsi       ; depth (as qword, sign-extended)
    mov     qword [rbp-8], 0    ; total = 0

    ; Save path
    mov     r15, rdi            ; path string

    ; Open directory
    mov     rsi, O_RDONLY | O_DIRECTORY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .dd_open_error
    mov     r14d, eax           ; dir fd

    ; Read directory entries with getdents64
.dd_getdents:
    mov     eax, SYS_GETDENTS64
    mov     edi, r14d
    lea     rsi, [b_getdents_buf]
    mov     edx, GETDENTS_SIZE
    syscall
    test    rax, rax
    js      .dd_read_error
    jz      .dd_read_done

    mov     r13, rax            ; bytes returned
    xor     ebx, ebx            ; offset

.dd_entry:
    cmp     rbx, r13
    jge     .dd_getdents

    lea     rcx, [b_getdents_buf]
    add     rcx, rbx
    movzx   eax, word [rcx + DIRENT_RECLEN]
    push    rax                 ; save reclen

    ; Get name
    lea     rsi, [rcx + DIRENT_NAME]

    ; Skip "." and ".."
    cmp     byte [rsi], '.'
    jne     .dd_process
    cmp     byte [rsi + 1], 0
    je      .dd_skip
    cmp     byte [rsi + 1], '.'
    jne     .dd_process
    cmp     byte [rsi + 2], 0
    je      .dd_skip

.dd_process:
    ; Build full path: path/name
    push    rbx
    push    r13

    ; Copy dir path to path_buf
    lea     rdi, [b_du_path_buf]
    mov     rsi, r15
    call    asm_strcpy
    mov     rbx, rax            ; path len

    ; Add /
    lea     rdi, [b_du_path_buf]
    cmp     rbx, 0
    je      .dd_add_slash
    cmp     byte [rdi + rbx - 1], '/'
    je      .dd_no_slash
.dd_add_slash:
    mov     byte [rdi + rbx], '/'
    inc     rbx
.dd_no_slash:

    ; Append entry name
    lea     rdi, [b_du_path_buf]
    add     rdi, rbx
    ; Recalculate: rcx = getdents_buf + original_rbx + DIRENT_NAME
    mov     rax, [rsp + 8]     ; saved rbx (original offset)
    lea     rcx, [b_getdents_buf]
    add     rcx, rax
    lea     rsi, [rcx + DIRENT_NAME]
    call    asm_strcpy

    ; lstat the full path
    lea     rdi, [b_du_path_buf]
    lea     rsi, [b_stat_buf]
    mov     rax, SYS_LSTAT
    syscall
    test    rax, rax
    js      .dd_stat_err

    ; Check file type
    mov     eax, [b_stat_buf + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFDIR
    je      .dd_is_subdir

    ; Regular file (or other): add its size
    call    get_file_size
    add     [rbp-8], rax

    ; If -a flag, print this file
    test    byte [b_flags], FLAG_A
    jz      .dd_entry_done

    ; Check depth vs max_depth
    mov     ecx, [b_max_depth]
    cmp     ecx, -1
    je      .dd_print_file
    mov     rax, [rbp-16]      ; current depth
    inc     rax                 ; file is at depth+1
    cmp     rax, rcx
    jg      .dd_entry_done

.dd_print_file:
    call    get_file_size
    push    rax
    call    emit_size_value
    mov     al, 9
    call    emit_byte
    lea     rdi, [b_du_path_buf]
    call    asm_strlen
    mov     rdx, rax
    lea     rdi, [b_du_path_buf]
    call    emit_string_len
    mov     al, 10
    call    emit_byte
    pop     rax
    jmp     .dd_entry_done

.dd_is_subdir:
    ; Recurse into subdirectory
    ; We need to save the path because recursion will overwrite du_path_buf
    ; Use a stack-allocated copy
    sub     rsp, PATH_MAX
    mov     rdi, rsp
    lea     rsi, [b_du_path_buf]
    call    asm_strcpy

    mov     rdi, rsp
    mov     rsi, [rbp-16]
    inc     rsi                 ; depth + 1
    call    du_directory
    add     rsp, PATH_MAX

    ; Add subdirectory total to our total
    add     [rbp-8], rax
    jmp     .dd_entry_done

.dd_stat_err:
    ; Couldn't stat entry — report error
    push    rbx
    push    r13
    lea     rdi, [b_du_path_buf]
    mov     esi, 2              ; ENOENT as default
    call    err_file
    mov     byte [b_had_error], 1
    pop     r13
    pop     rbx

.dd_entry_done:
    pop     r13
    pop     rbx

.dd_skip:
    pop     rax                 ; reclen
    add     rbx, rax
    jmp     .dd_entry

.dd_read_done:
    ; Close directory
    mov     edi, r14d
    call    asm_close

    ; Add the directory's own blocks
    mov     rdi, r15
    lea     rsi, [b_stat_buf]
    mov     rax, SYS_LSTAT
    syscall
    test    rax, rax
    js      .dd_no_self
    call    get_file_size
    add     [rbp-8], rax
.dd_no_self:

    ; Print this directory's total (unless -s and depth > 0)
    test    byte [b_flags], FLAG_S
    jz      .dd_check_depth

    ; -s: only print at depth 0
    cmp     qword [rbp-16], 0
    jne     .dd_return

.dd_check_depth:
    ; Check max_depth
    mov     ecx, [b_max_depth]
    cmp     ecx, -1
    je      .dd_print_dir
    mov     rax, [rbp-16]
    cmp     rax, rcx
    jg      .dd_return

.dd_print_dir:
    mov     rax, [rbp-8]
    push    rax
    call    emit_size_value
    mov     al, 9
    call    emit_byte

    ; Print directory path
    mov     rdi, r15
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, r15
    call    emit_string_len
    mov     al, 10
    call    emit_byte

    pop     rax

.dd_return:
    mov     rax, [rbp-8]
    add     [b_grand_total], rax

    mov     rsp, rbp
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

.dd_open_error:
    neg     rax
    mov     esi, eax
    mov     rdi, r15
    call    err_cannot_read
    mov     byte [b_had_error], 1
    xor     eax, eax
    mov     rsp, rbp
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

.dd_read_error:
    mov     edi, r14d
    call    asm_close
    mov     byte [b_had_error], 1
    xor     eax, eax
    mov     rsp, rbp
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; ============================================================================
;  get_file_size — Returns size from stat_buf based on flags
;  Returns rax = size
; ============================================================================
get_file_size:
    test    byte [b_flags], FLAG_B
    jnz     .gfs_bytes

    ; Default: 1K blocks (st_blocks is in 512-byte units)
    mov     rax, [b_stat_buf + STAT_BLOCKS]
    shr     rax, 1              ; convert to 1K blocks

    test    byte [b_flags], FLAG_M
    jnz     .gfs_megabytes

    ret

.gfs_bytes:
    mov     rax, [b_stat_buf + STAT_SIZE]
    ret

.gfs_megabytes:
    ; Already in 1K, convert to MB
    mov     rax, [b_stat_buf + STAT_BLOCKS]
    shr     rax, 11             ; 512-byte blocks to MB
    ret

; ============================================================================
;  emit_size_value — Print size based on flags (-h for human, else raw number)
; ============================================================================
emit_size_value:
    test    byte [b_flags], FLAG_H
    jnz     .esv_human
    call    emit_number
    ret

.esv_human:
    ; Human-readable: pick appropriate unit
    push    rbx
    mov     rbx, rax

    test    byte [b_flags], FLAG_B
    jnz     .esv_human_bytes

    ; Size is in 1K blocks
    cmp     rbx, 1024
    jl      .esv_human_k
    mov     rax, rbx
    shr     rax, 10
    cmp     rax, 1024
    jl      .esv_human_m
    shr     rax, 10
    cmp     rax, 1024
    jl      .esv_human_g
    shr     rax, 10
    call    emit_number
    mov     al, 'T'
    call    emit_byte
    pop     rbx
    ret

.esv_human_k:
    mov     rax, rbx
    call    emit_number
    mov     al, 'K'
    call    emit_byte
    pop     rbx
    ret

.esv_human_m:
    call    emit_number
    mov     al, 'M'
    call    emit_byte
    pop     rbx
    ret

.esv_human_g:
    call    emit_number
    mov     al, 'G'
    call    emit_byte
    pop     rbx
    ret

.esv_human_bytes:
    ; Size is in bytes
    cmp     rbx, 1024
    jl      .esv_hb_bytes
    mov     rax, rbx
    shr     rax, 10
    cmp     rax, 1024
    jl      .esv_hb_k
    shr     rax, 10
    cmp     rax, 1024
    jl      .esv_hb_m
    shr     rax, 10
    call    emit_number
    mov     al, 'G'
    call    emit_byte
    pop     rbx
    ret

.esv_hb_bytes:
    mov     rax, rbx
    call    emit_number
    pop     rbx
    ret

.esv_hb_k:
    call    emit_number
    mov     al, 'K'
    call    emit_byte
    pop     rbx
    ret

.esv_hb_m:
    call    emit_number
    mov     al, 'M'
    call    emit_byte
    pop     rbx
    ret

; ============================================================================
;                       ARGUMENT PARSING
; ============================================================================
parse_args:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, [b_argc]
    mov     r13, [b_argv]
    mov     rbx, 1
    xor     r14d, r14d

.pa_loop:
    cmp     rbx, r12
    jge     .pa_done
    mov     rsi, [r13 + rbx*8]
    test    r14d, r14d
    jnz     .pa_is_file
    cmp     byte [rsi], '-'
    jne     .pa_is_file
    cmp     byte [rsi+1], 0
    je      .pa_is_file

    cmp     byte [rsi+1], '-'
    jne     .pa_short_opts
    cmp     byte [rsi+2], 0
    je      .pa_dashdash

    ; Long options
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rdi, rsi
    lea     rsi, [str_help_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_help
    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [str_version_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_version

    ; --max-depth=N
    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [str_max_depth]
    call    str_starts_with
    test    eax, eax
    jnz     .pa_max_depth

    ; Unknown long option: error and exit
    mov     rsi, [r13 + rbx*8]
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rdi, rsi
    call    err_unrecognized_option
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.pa_do_help:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ; Flush any buffered output first
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.pa_do_version:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.pa_max_depth:
    ; Parse number after "--max-depth="
    mov     rsi, [r13 + rbx*8]
    add     rsi, 12             ; skip "--max-depth="
    call    parse_uint
    mov     [b_max_depth], eax
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     .pa_next

.pa_dashdash:
    mov     r14d, 1
    jmp     .pa_next

.pa_short_opts:
    mov     rcx, 1
.pa_short_loop:
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .pa_next
    cmp     al, 's'
    je      .f_s
    cmp     al, 'h'
    je      .f_h
    cmp     al, 'a'
    je      .f_a
    cmp     al, 'c'
    je      .f_c
    cmp     al, 'b'
    je      .f_b
    cmp     al, 'k'
    je      .f_k
    cmp     al, 'm'
    je      .f_m
    cmp     al, 'S'
    je      .f_S
    cmp     al, 'd'
    je      .f_d
    ; Unknown short option: error and exit
    push    rsi
    push    rcx
    movzx   esi, al
    call    err_invalid_option
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.f_s: or byte [b_flags], FLAG_S
    jmp .pa_short_next
.f_h: or byte [b_flags], FLAG_H
    jmp .pa_short_next
.f_a: or byte [b_flags], FLAG_A
    jmp .pa_short_next
.f_c: or byte [b_flags], FLAG_C
    jmp .pa_short_next
.f_b: or byte [b_flags], FLAG_B
    jmp .pa_short_next
.f_k: or byte [b_flags], FLAG_K
    jmp .pa_short_next
.f_m: or byte [b_flags], FLAG_M
    jmp .pa_short_next
.f_S: or byte [b_flags], FLAG_SEP
    jmp .pa_short_next
.f_d:
    ; -d N: next char or next arg is the depth
    inc     rcx
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .f_d_next_arg
    ; Digit follows in same string
    lea     rdi, [rsi + rcx]
    push    rsi
    push    rcx
    mov     rsi, rdi
    call    parse_uint
    mov     [b_max_depth], eax
    pop     rcx
    pop     rsi
    ; Skip rest of this arg
    jmp     .pa_next

.f_d_next_arg:
    ; Next argument is the depth
    inc     rbx
    cmp     rbx, r12
    jge     .pa_next
    mov     rdi, [r13 + rbx*8]
    mov     rsi, rdi
    call    parse_uint
    mov     [b_max_depth], eax
    jmp     .pa_next

.pa_short_next:
    inc     rcx
    jmp     .pa_short_loop

.pa_is_file:
    mov     rax, [b_nfiles]
    cmp     rax, MAX_FILES
    jge     .pa_next
    lea     rcx, [b_file_ptrs]
    mov     [rcx + rax*8], rsi
    inc     qword [b_nfiles]

.pa_next:
    inc     rbx
    jmp     .pa_loop

.pa_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; parse_uint(rsi=string) -> eax=value
parse_uint:
    xor     eax, eax
    mov     ecx, 10
.pu_loop:
    movzx   edx, byte [rsi]
    sub     edx, '0'
    cmp     edx, 9
    ja      .pu_done
    imul    eax, ecx
    add     eax, edx
    inc     rsi
    jmp     .pu_loop
.pu_done:
    ret

; str_starts_with(rdi=str, rsi=prefix) -> eax=1 if match
str_starts_with:
.ssw_loop:
    movzx   ecx, byte [rsi]
    test    cl, cl
    jz      .ssw_match
    movzx   eax, byte [rdi]
    cmp     al, cl
    jne     .ssw_no
    inc     rdi
    inc     rsi
    jmp     .ssw_loop
.ssw_match:
    mov     eax, 1
    ret
.ssw_no:
    xor     eax, eax
    ret

; ============================================================================
;  Output helpers
; ============================================================================
emit_byte:
    lea     rdi, [b_out_buf]
    mov     [rdi + r12], al
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .eb_done
    call    flush_output
.eb_done:
    ret

emit_string:
    push    rbx
    push    rcx
    mov     rbx, rdi
    mov     ecx, edx
.es_copy:
    test    ecx, ecx
    jz      .es_done
    movzx   eax, byte [rbx]
    lea     rdi, [b_out_buf]
    mov     [rdi + r12], al
    inc     r12
    inc     rbx
    dec     ecx
    cmp     r12, OUT_BUF_SIZE
    jl      .es_copy
    push    rbx
    push    rcx
    call    flush_output
    pop     rcx
    pop     rbx
    jmp     .es_copy
.es_done:
    pop     rcx
    pop     rbx
    ret

emit_string_len:
    push    rbx
    push    rcx
    mov     rbx, rdi
    mov     rcx, rdx
.esl_copy:
    test    rcx, rcx
    jz      .esl_done
    movzx   eax, byte [rbx]
    lea     rdi, [b_out_buf]
    mov     [rdi + r12], al
    inc     r12
    inc     rbx
    dec     rcx
    cmp     r12, OUT_BUF_SIZE
    jl      .esl_copy
    push    rbx
    push    rcx
    call    flush_output
    pop     rcx
    pop     rbx
    jmp     .esl_copy
.esl_done:
    pop     rcx
    pop     rbx
    ret

emit_number:
    push    rbx
    push    rcx
    lea     rdi, [b_itoa_buf]
    mov     rbx, rax
    xor     ecx, ecx
    mov     r8, 10
    test    rax, rax
    jnz     .en_loop
    mov     al, '0'
    call    emit_byte
    pop     rcx
    pop     rbx
    ret
.en_loop:
    mov     rax, rbx
    xor     edx, edx
    div     r8
    mov     rbx, rax
    add     dl, '0'
    mov     [rdi + rcx], dl
    inc     ecx
    test    rbx, rbx
    jnz     .en_loop
    dec     ecx
.en_emit:
    cmp     ecx, 0
    jl      .en_done
    lea     rdi, [b_itoa_buf]     ; reload (emit_byte clobbers rdi)
    movzx   eax, byte [rdi + rcx]
    call    emit_byte
    dec     ecx
    jmp     .en_emit
.en_done:
    pop     rcx
    pop     rbx
    ret

flush_output:
    test    r12, r12
    jz      .fo_nothing
    mov     rdi, STDOUT
    lea     rsi, [b_out_buf]
    mov     rdx, r12
    call    asm_write_all
    xor     r12d, r12d
    ret
.fo_nothing:
    xor     eax, eax
    ret

; ============================================================================
;  Error helpers
; ============================================================================
str_eq:
.se_loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .se_ne
    test    al, al
    jz      .se_eq
    inc     rdi
    inc     rsi
    jmp     .se_loop
.se_eq: mov eax, 1
    ret
.se_ne: xor eax, eax
    ret

err_file:
    push    rbx
    push    r13
    mov     rbx, rdi
    mov     r13d, esi
    ; flush stdout first
    call    flush_output
    mov     rdi, STDERR
    lea     rsi, [str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_cannot_access]
    mov     rdx, str_cannot_access_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_squote]
    mov     rdx, 1
    call    asm_write_all
    mov     rdi, rbx
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_squote_colon]
    mov     rdx, 3
    call    asm_write_all
    mov     edi, r13d
    call    strerror
    mov     rbx, rax
    mov     rdi, rax
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_nl]
    mov     rdx, 1
    call    asm_write_all
    pop     r13
    pop     rbx
    ret

err_cannot_read:
    push    rbx
    push    r13
    mov     rbx, rdi
    mov     r13d, esi
    call    flush_output
    mov     rdi, STDERR
    lea     rsi, [str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_cannot_read]
    mov     rdx, str_cannot_read_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_squote]
    mov     rdx, 1
    call    asm_write_all
    mov     rdi, rbx
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_squote_colon]
    mov     rdx, 3
    call    asm_write_all
    mov     edi, r13d
    call    strerror
    mov     rbx, rax
    mov     rdi, rax
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_nl]
    mov     rdx, 1
    call    asm_write_all
    pop     r13
    pop     rbx
    ret

; err_unrecognized_option(rdi=option_string) — print "du: unrecognized option '...'"
err_unrecognized_option:
    push    rbx
    mov     rbx, rdi
    xor     r12d, r12d              ; reset out_buf_used (clobbered by parse_args)
    call    flush_output
    mov     rdi, STDERR
    lea     rsi, [str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_unrecognized]
    mov     rdx, str_unrecognized_len
    call    asm_write_all
    mov     rdi, rbx
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_quote_nl]
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all
    pop     rbx
    ret

; err_invalid_option(esi=char) — print "du: invalid option -- 'X'"
err_invalid_option:
    push    rbx
    mov     ebx, esi
    xor     r12d, r12d              ; reset out_buf_used (clobbered by parse_args)
    call    flush_output
    mov     rdi, STDERR
    lea     rsi, [str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_invalid_opt]
    mov     rdx, str_invalid_opt_len
    call    asm_write_all
    mov     byte [b_char_buf], bl
    mov     rdi, STDERR
    lea     rsi, [b_char_buf]
    mov     rdx, 1
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_quote_nl]
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all
    pop     rbx
    ret

strerror:
    cmp     edi, 2
    je      .st_e2
    cmp     edi, 13
    je      .st_e13
    cmp     edi, 20
    je      .st_e20
    lea     rax, [str_eunknown]
    ret
.st_e2: lea rax, [str_enoent]
    ret
.st_e13: lea rax, [str_eacces]
    ret
.st_e20: lea rax, [str_enotdir]
    ret

; ============================================================================
;  I/O library (inlined from io.asm)
; ============================================================================

; asm_write(rdi=fd, rsi=buf, rdx=len) -> rax=bytes_written
asm_write:
.aw_retry:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -EINTR
    je      .aw_retry
    ret

; asm_write_all(rdi=fd, rsi=buf, rdx=len) -> rax=0 on success, negative on error
asm_write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.awa_loop:
    test    r13, r13
    jle     .awa_success
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -EINTR
    je      .awa_loop
    test    rax, rax
    js      .awa_error
    add     r12, rax
    sub     r13, rax
    jmp     .awa_loop
.awa_success:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.awa_error:
    pop     r13
    pop     r12
    pop     rbx
    ret

; asm_read(rdi=fd, rsi=buf, rdx=len) -> rax=bytes_read
asm_read:
.ar_retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, -EINTR
    je      .ar_retry
    ret

; asm_open(rdi=path, rsi=flags, rdx=mode) -> rax=fd
asm_open:
    mov     rax, SYS_OPEN
    syscall
    ret

; asm_close(rdi=fd) -> rax=0 or error
asm_close:
    mov     rax, SYS_CLOSE
    syscall
    ret

; ============================================================================
;  String library (inlined from str.asm)
; ============================================================================

; asm_strlen(rdi=str) -> rax=length
asm_strlen:
    xor     rax, rax
.asl_loop:
    cmp     byte [rdi + rax], 0
    je      .asl_done
    inc     rax
    jmp     .asl_loop
.asl_done:
    ret

; asm_strcmp(rdi=s1, rsi=s2) -> rax: 0 if equal, <0 or >0 otherwise
asm_strcmp:
.asc_loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .asc_diff
    test    al, al
    jz      .asc_equal
    inc     rdi
    inc     rsi
    jmp     .asc_loop
.asc_equal:
    xor     eax, eax
    ret
.asc_diff:
    sub     eax, ecx
    ret

; asm_strcpy(rdi=dest, rsi=src) -> rax=length copied
asm_strcpy:
    xor     rax, rax
.ascp_loop:
    movzx   ecx, byte [rsi + rax]
    mov     [rdi + rax], cl
    test    cl, cl
    jz      .ascp_done
    inc     rax
    jmp     .ascp_loop
.ascp_done:
    ret

; ============================================================================
;  Read-only Data
; ============================================================================

str_prefix: db "du: "
str_prefix_len equ $ - str_prefix
str_cannot_access: db "cannot access "
str_cannot_access_len equ $ - str_cannot_access
str_cannot_read: db "cannot read directory "
str_cannot_read_len equ $ - str_cannot_read
str_squote: db "'"
str_squote_colon: db "': "
str_nl: db 10
dot_str: db ".", 0
total_label: db "total"
str_help_opt: db "--help", 0
str_version_opt: db "--version", 0
str_max_depth: db "--max-depth=", 0
str_enoent: db "No such file or directory", 0
str_eacces: db "Permission denied", 0
str_enotdir: db "Not a directory", 0
str_eunknown: db "Unknown error", 0
str_unrecognized: db "unrecognized option '"
str_unrecognized_len equ $ - str_unrecognized
str_invalid_opt: db "invalid option -- '"
str_invalid_opt_len equ $ - str_invalid_opt
str_quote_nl: db "'", 10
str_try_help: db "Try 'du --help' for more information.", 10
str_try_help_len equ $ - str_try_help

help_text:
    db "Usage: du [OPTION]... [FILE]...", 10
    db "  or:  du [OPTION]... --files0-from=F", 10
    db "Summarize device usage of the set of FILEs, recursively for directories.", 10
    db 10
    db "  -a, --all             write counts for all files, not just directories", 10
    db "  -b, --bytes           equivalent to '--apparent-size --block-size=1'", 10
    db "  -c, --total           produce a grand total", 10
    db "  -d, --max-depth=N     print the total for a directory only if it is N or", 10
    db "                          fewer levels below the command line argument", 10
    db "  -h, --human-readable  print sizes in human readable format (e.g., 1K 234M 2G)", 10
    db "  -k                    like --block-size=1K", 10
    db "  -m                    like --block-size=1M", 10
    db "  -s, --summarize       display only a total for each argument", 10
    db "  -S, --separate-dirs   for directories do not include size of subdirectories", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
help_text_len equ $ - help_text

version_text:
    db "du (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Torbjorn Granlund, David MacKenzie, Paul Eggert,", 10
    db "and Jim Meyering.", 10
version_text_len equ $ - version_text

file_end:
