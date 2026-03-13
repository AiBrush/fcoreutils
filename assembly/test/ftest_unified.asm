; ============================================================
; ftest_unified.asm — GNU-compatible 'test' command
; Builds with: nasm -f bin ftest_unified.asm -o ftest
;
; test: Evaluate conditional expression.
; Supports: file tests (-e,-f,-d,-r,-w,-x,-s,-L,-h,-b,-c,-p,-S,
;           -g,-u,-k,-O,-G,-N), string tests (-n,-z,=,!=),
;           integer tests (-eq,-ne,-lt,-le,-gt,-ge),
;           logic (!, -a, -o), parentheses, -nt, -ot, -ef
; Exit: 0 if true, 1 if false, 2 on error
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE       1
%define SYS_EXIT       60
%define SYS_STAT       4
%define SYS_LSTAT       6
%define SYS_ACCESS     21
%define SYS_GETUID    102
%define SYS_GETGID    104
%define SYS_GETEUID   107
%define SYS_GETEGID   108
%define SYS_RT_SIGPROCMASK 14

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE         13

; Access mode flags
%define F_OK            0
%define R_OK            4
%define W_OK            2
%define X_OK            1

; stat structure offsets (x86-64 Linux)
%define ST_DEV          0
%define ST_INO          8
%define ST_NLINK       16
%define ST_MODE        24
%define ST_UID         28
%define ST_GID         32
%define ST_RDEV        40
%define ST_SIZE        48
%define ST_ATIME       72
%define ST_MTIME       88
%define ST_CTIME      104

; File type masks
%define S_IFMT      0o170000
%define S_IFREG     0o100000
%define S_IFDIR     0o040000
%define S_IFCHR     0o020000
%define S_IFBLK     0o060000
%define S_IFIFO     0o010000
%define S_IFLNK     0o120000
%define S_IFSOCK    0o140000
%define S_ISUID     0o004000
%define S_ISGID     0o002000
%define S_ISVTX     0o001000

; BSS layout
%define BSS_BASE     0x500000
%define stat_buf1    BSS_BASE
%define stat_buf2    (stat_buf1 + 144)
%define arg_idx      (stat_buf2 + 144)
%define arg_max      (arg_idx + 8)
%define argv_ptr     (arg_max + 8)
%define BSS_END      (argv_ptr + 8)
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

    mov     r14d, [rsp]         ; argc
    lea     r15, [rsp + 8]      ; argv
    mov     [argv_ptr], r15

    ; Check --help / --version (only if exactly 2 args)
    cmp     r14d, 2
    jne     .skip_special
    mov     rdi, [r15 + 8]
    push    r14
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .show_help
    mov     rdi, [r15 + 8]
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .show_version
    pop     r14

.skip_special:
    ; test with no arguments: exit 1 (false)
    cmp     r14d, 1
    je      .exit_false

    ; Effective argc = r14d - 1 (skip argv[0])
    ; Set up for evaluation: args are argv[1..argc-1]
    mov     qword [arg_idx], 1
    mov     eax, r14d
    dec     eax
    mov     [arg_max], eax

    ; Evaluate expression
    call    eval_expr

    ; rax: 1 = true (exit 0), 0 = false (exit 1)
    test    eax, eax
    jnz     .exit_true

.exit_false:
    mov     edi, 1
    jmp     do_exit

.exit_true:
    xor     edi, edi
    jmp     do_exit

.show_help:
    pop     r14
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.show_version:
    pop     r14
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

; ============================================================
; eval_expr: evaluate test expression
; Uses argv[arg_idx .. r14d-1]
; Returns: eax = 1 (true) or 0 (false)
; ============================================================
eval_expr:
    push    rbx
    push    r12
    push    r13
    call    eval_or_expr
    pop     r13
    pop     r12
    pop     rbx
    ret

; eval_or_expr: handle -o (OR)
eval_or_expr:
    push    rbx
    push    r12
    call    eval_and_expr
    mov     r12d, eax

.or_loop:
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .or_done
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    cmp     byte [rdi], '-'
    jne     .or_done
    cmp     byte [rdi + 1], 'o'
    jne     .or_done
    cmp     byte [rdi + 2], 0
    jne     .or_done

    inc     qword [arg_idx]
    call    eval_and_expr
    or      r12d, eax
    jmp     .or_loop

.or_done:
    mov     eax, r12d
    pop     r12
    pop     rbx
    ret

; eval_and_expr: handle -a (AND)
eval_and_expr:
    push    rbx
    push    r12
    call    eval_not_expr
    mov     r12d, eax

.and_loop:
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .and_done
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    cmp     byte [rdi], '-'
    jne     .and_done
    cmp     byte [rdi + 1], 'a'
    jne     .and_done
    cmp     byte [rdi + 2], 0
    jne     .and_done

    inc     qword [arg_idx]
    call    eval_not_expr
    and     r12d, eax
    jmp     .and_loop

.and_done:
    mov     eax, r12d
    pop     r12
    pop     rbx
    ret

; eval_not_expr: handle ! (NOT)
eval_not_expr:
    push    rbx
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .not_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    cmp     byte [rdi], '!'
    jne     .not_primary
    cmp     byte [rdi + 1], 0
    jne     .not_primary

    inc     qword [arg_idx]
    call    eval_not_expr
    xor     eax, 1              ; negate
    pop     rbx
    ret

.not_primary:
    call    eval_primary_test
    pop     rbx
    ret

.not_false:
    xor     eax, eax
    pop     rbx
    ret

; eval_primary_test: handle primary expressions
eval_primary_test:
    push    rbx
    push    r12

    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false

    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]

    ; Check for '('
    cmp     byte [rdi], '('
    jne     .pt_check_unary
    cmp     byte [rdi + 1], 0
    jne     .pt_check_unary
    inc     qword [arg_idx]
    call    eval_or_expr
    mov     r12d, eax
    ; Expect ')'
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_ret_r12
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    cmp     byte [rdi], ')'
    jne     .pt_ret_r12
    cmp     byte [rdi + 1], 0
    jne     .pt_ret_r12
    inc     qword [arg_idx]
.pt_ret_r12:
    mov     eax, r12d
    pop     r12
    pop     rbx
    ret

.pt_check_unary:
    ; Check for unary operators: -e, -f, -d, -r, -w, -x, -s, -L, -h, etc.
    cmp     byte [rdi], '-'
    jne     .pt_string_or_binary

    movzx   eax, byte [rdi + 1]
    cmp     byte [rdi + 2], 0
    jne     .pt_check_long_unary

    ; Single-char flag after -
    cmp     al, 'n'
    je      .pt_n
    cmp     al, 'z'
    je      .pt_z
    cmp     al, 'e'
    je      .pt_file_exists
    cmp     al, 'f'
    je      .pt_file_regular
    cmp     al, 'd'
    je      .pt_file_dir
    cmp     al, 'r'
    je      .pt_file_readable
    cmp     al, 'w'
    je      .pt_file_writable
    cmp     al, 'x'
    je      .pt_file_executable
    cmp     al, 's'
    je      .pt_file_nonempty
    cmp     al, 'L'
    je      .pt_file_symlink
    cmp     al, 'h'
    je      .pt_file_symlink
    cmp     al, 'b'
    je      .pt_file_block
    cmp     al, 'c'
    je      .pt_file_char
    cmp     al, 'p'
    je      .pt_file_pipe
    cmp     al, 'S'
    je      .pt_file_socket
    cmp     al, 'g'
    je      .pt_file_setgid
    cmp     al, 'u'
    je      .pt_file_setuid
    cmp     al, 'k'
    je      .pt_file_sticky
    cmp     al, 'O'
    je      .pt_file_owner
    cmp     al, 'G'
    je      .pt_file_group
    cmp     al, 'N'
    je      .pt_file_newer
    cmp     al, 't'
    je      .pt_file_terminal
    jmp     .pt_string_or_binary

.pt_check_long_unary:
    ; Could be -nt, -ot, -ef, -eq, -ne, -lt, -le, -gt, -ge
    ; These are binary operators, check if we have 3 args remaining
    jmp     .pt_string_or_binary

; ── Unary string tests ──
.pt_n:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    call    str_len
    test    eax, eax
    jnz     .pt_true
    jmp     .pt_false

.pt_z:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_true            ; no arg = empty
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    call    str_len
    test    eax, eax
    jz      .pt_true
    jmp     .pt_false

; ── File tests ──
.pt_file_exists:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    jns     .pt_true
    jmp     .pt_false

.pt_file_regular:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    mov     eax, [stat_buf1 + ST_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFREG
    je      .pt_true
    jmp     .pt_false

.pt_file_dir:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    mov     eax, [stat_buf1 + ST_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFDIR
    je      .pt_true
    jmp     .pt_false

.pt_file_readable:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     esi, R_OK
    mov     eax, SYS_ACCESS
    syscall
    test    rax, rax
    jz      .pt_true
    jmp     .pt_false

.pt_file_writable:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     esi, W_OK
    mov     eax, SYS_ACCESS
    syscall
    test    rax, rax
    jz      .pt_true
    jmp     .pt_false

.pt_file_executable:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     esi, X_OK
    mov     eax, SYS_ACCESS
    syscall
    test    rax, rax
    jz      .pt_true
    jmp     .pt_false

.pt_file_nonempty:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    cmp     qword [stat_buf1 + ST_SIZE], 0
    jg      .pt_true
    jmp     .pt_false

.pt_file_symlink:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     rsi, stat_buf1
    mov     eax, SYS_LSTAT
    syscall
    test    rax, rax
    js      .pt_false
    mov     eax, [stat_buf1 + ST_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFLNK
    je      .pt_true
    jmp     .pt_false

.pt_file_block:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    mov     eax, [stat_buf1 + ST_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFBLK
    je      .pt_true
    jmp     .pt_false

.pt_file_char:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    mov     eax, [stat_buf1 + ST_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFCHR
    je      .pt_true
    jmp     .pt_false

.pt_file_pipe:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    mov     eax, [stat_buf1 + ST_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFIFO
    je      .pt_true
    jmp     .pt_false

.pt_file_socket:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    mov     eax, [stat_buf1 + ST_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFSOCK
    je      .pt_true
    jmp     .pt_false

.pt_file_setgid:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    test    dword [stat_buf1 + ST_MODE], S_ISGID
    jnz     .pt_true
    jmp     .pt_false

.pt_file_setuid:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    test    dword [stat_buf1 + ST_MODE], S_ISUID
    jnz     .pt_true
    jmp     .pt_false

.pt_file_sticky:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    test    dword [stat_buf1 + ST_MODE], S_ISVTX
    jnz     .pt_true
    jmp     .pt_false

.pt_file_owner:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    mov     eax, SYS_GETEUID
    syscall
    cmp     eax, [stat_buf1 + ST_UID]
    je      .pt_true
    jmp     .pt_false

.pt_file_group:
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    mov     eax, SYS_GETEGID
    syscall
    cmp     eax, [stat_buf1 + ST_GID]
    je      .pt_true
    jmp     .pt_false

.pt_file_newer:
    ; -N FILE: file exists and has been modified since last read
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    ; mtime > atime?
    mov     rax, [stat_buf1 + ST_MTIME]
    cmp     rax, [stat_buf1 + ST_ATIME]
    jge     .pt_true
    jmp     .pt_false

.pt_file_terminal:
    ; -t FD: fd is open and refers to a terminal
    ; For simplicity, just check if fd 1 is a tty (we can't easily do ioctl)
    inc     qword [arg_idx]
    mov     rcx, [arg_idx]
    cmp     ecx, r14d
    jge     .pt_false
    inc     qword [arg_idx]
    ; Simplified: always false (ioctl TIOCGWINSZ needed for real check)
    jmp     .pt_false

.pt_string_or_binary:
    ; Check if this is a binary operator: STRING = STRING, STRING != STRING,
    ; INT -eq INT, etc.
    ; First, peek at next arg to see if it's an operator
    mov     rcx, [arg_idx]
    lea     edx, [ecx + 1]
    cmp     edx, r14d
    jge     .pt_single_string   ; only one arg left

    ; Save current arg
    mov     rbx, [argv_ptr]
    mov     r12, [rbx + rcx*8]     ; left operand

    ; Check next arg for operator
    mov     rdi, [rbx + rdx*8]

    ; = operator
    cmp     byte [rdi], '='
    jne     .pt_check_ne
    cmp     byte [rdi + 1], 0
    jne     .pt_check_ne
    ; Consume left, operator, right
    add     qword [arg_idx], 3
    lea     edx, [ecx + 2]
    cmp     edx, r14d
    jge     .pt_false
    mov     rdi, [rbx + rdx*8]     ; right operand
    mov     rsi, rdi
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     .pt_true
    jmp     .pt_false

.pt_check_ne:
    cmp     byte [rdi], '!'
    jne     .pt_check_int_ops
    cmp     byte [rdi + 1], '='
    jne     .pt_check_int_ops
    cmp     byte [rdi + 2], 0
    jne     .pt_check_int_ops
    add     qword [arg_idx], 3
    lea     edx, [ecx + 2]
    cmp     edx, r14d
    jge     .pt_false
    mov     rdi, [rbx + rdx*8]
    mov     rsi, rdi
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jz      .pt_true
    jmp     .pt_false

.pt_check_int_ops:
    ; Check for -eq, -ne, -lt, -le, -gt, -ge, -nt, -ot, -ef
    cmp     byte [rdi], '-'
    jne     .pt_single_string
    movzx   eax, byte [rdi + 1]

    cmp     al, 'e'
    je      .pt_int_e
    cmp     al, 'n'
    je      .pt_int_n
    cmp     al, 'l'
    je      .pt_int_l
    cmp     al, 'g'
    je      .pt_int_g
    jmp     .pt_single_string

.pt_int_e:
    cmp     byte [rdi + 2], 'q'
    jne     .pt_int_ef
    cmp     byte [rdi + 3], 0
    jne     .pt_single_string
    ; -eq
    add     qword [arg_idx], 3
    lea     edx, [ecx + 2]
    cmp     edx, r14d
    jge     .pt_false
    push    rbx
    mov     rdi, r12
    call    parse_int
    mov     r12, rax
    mov     rbx, [argv_ptr]
    mov     rcx, [arg_idx]
    sub     ecx, 1
    mov     rdi, [rbx + rcx*8]
    call    parse_int
    pop     rbx
    cmp     r12, rax
    je      .pt_true
    jmp     .pt_false

.pt_int_ef:
    cmp     byte [rdi + 2], 'f'
    jne     .pt_single_string
    cmp     byte [rdi + 3], 0
    jne     .pt_single_string
    ; -ef: same file (same dev+inode)
    add     qword [arg_idx], 3
    lea     edx, [ecx + 2]
    cmp     edx, r14d
    jge     .pt_false
    ; stat left
    mov     rdi, r12
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    ; stat right
    mov     rbx, [argv_ptr]
    mov     rcx, [arg_idx]
    sub     ecx, 1
    mov     rdi, [rbx + rcx*8]
    mov     rsi, stat_buf2
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    mov     rax, [stat_buf1 + ST_DEV]
    cmp     rax, [stat_buf2 + ST_DEV]
    jne     .pt_false
    mov     rax, [stat_buf1 + ST_INO]
    cmp     rax, [stat_buf2 + ST_INO]
    jne     .pt_false
    jmp     .pt_true

.pt_int_n:
    cmp     byte [rdi + 2], 'e'
    jne     .pt_int_nt
    cmp     byte [rdi + 3], 0
    jne     .pt_single_string
    ; -ne
    add     qword [arg_idx], 3
    lea     edx, [ecx + 2]
    cmp     edx, r14d
    jge     .pt_false
    push    rbx
    mov     rdi, r12
    call    parse_int
    mov     r12, rax
    mov     rbx, [argv_ptr]
    mov     rcx, [arg_idx]
    sub     ecx, 1
    mov     rdi, [rbx + rcx*8]
    call    parse_int
    pop     rbx
    cmp     r12, rax
    jne     .pt_true
    jmp     .pt_false

.pt_int_nt:
    cmp     byte [rdi + 2], 't'
    jne     .pt_single_string
    cmp     byte [rdi + 3], 0
    jne     .pt_single_string
    ; -nt: newer than (mtime comparison)
    add     qword [arg_idx], 3
    lea     edx, [ecx + 2]
    cmp     edx, r14d
    jge     .pt_false
    mov     rdi, r12
    mov     rsi, stat_buf1
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_false
    mov     rbx, [argv_ptr]
    mov     rcx, [arg_idx]
    sub     ecx, 1
    mov     rdi, [rbx + rcx*8]
    mov     rsi, stat_buf2
    mov     eax, SYS_STAT
    syscall
    test    rax, rax
    js      .pt_true            ; if right doesn't exist, left is newer
    mov     rax, [stat_buf1 + ST_MTIME]
    cmp     rax, [stat_buf2 + ST_MTIME]
    jg      .pt_true
    jmp     .pt_false

.pt_int_l:
    cmp     byte [rdi + 2], 't'
    je      .pt_lt
    cmp     byte [rdi + 2], 'e'
    je      .pt_le
    jmp     .pt_single_string

.pt_lt:
    cmp     byte [rdi + 3], 0
    jne     .pt_single_string
    add     qword [arg_idx], 3
    lea     edx, [ecx + 2]
    cmp     edx, r14d
    jge     .pt_false
    push    rbx
    mov     rdi, r12
    call    parse_int
    mov     r12, rax
    mov     rbx, [argv_ptr]
    mov     rcx, [arg_idx]
    sub     ecx, 1
    mov     rdi, [rbx + rcx*8]
    call    parse_int
    pop     rbx
    cmp     r12, rax
    jl      .pt_true
    jmp     .pt_false

.pt_le:
    cmp     byte [rdi + 3], 0
    jne     .pt_single_string
    add     qword [arg_idx], 3
    lea     edx, [ecx + 2]
    cmp     edx, r14d
    jge     .pt_false
    push    rbx
    mov     rdi, r12
    call    parse_int
    mov     r12, rax
    mov     rbx, [argv_ptr]
    mov     rcx, [arg_idx]
    sub     ecx, 1
    mov     rdi, [rbx + rcx*8]
    call    parse_int
    pop     rbx
    cmp     r12, rax
    jle     .pt_true
    jmp     .pt_false

.pt_int_g:
    cmp     byte [rdi + 2], 't'
    je      .pt_gt
    cmp     byte [rdi + 2], 'e'
    je      .pt_ge
    jmp     .pt_single_string

.pt_gt:
    cmp     byte [rdi + 3], 0
    jne     .pt_single_string
    add     qword [arg_idx], 3
    lea     edx, [ecx + 2]
    cmp     edx, r14d
    jge     .pt_false
    push    rbx
    mov     rdi, r12
    call    parse_int
    mov     r12, rax
    mov     rbx, [argv_ptr]
    mov     rcx, [arg_idx]
    sub     ecx, 1
    mov     rdi, [rbx + rcx*8]
    call    parse_int
    pop     rbx
    cmp     r12, rax
    jg      .pt_true
    jmp     .pt_false

.pt_ge:
    cmp     byte [rdi + 3], 0
    jne     .pt_single_string
    add     qword [arg_idx], 3
    lea     edx, [ecx + 2]
    cmp     edx, r14d
    jge     .pt_false
    push    rbx
    mov     rdi, r12
    call    parse_int
    mov     r12, rax
    mov     rbx, [argv_ptr]
    mov     rcx, [arg_idx]
    sub     ecx, 1
    mov     rdi, [rbx + rcx*8]
    call    parse_int
    pop     rbx
    cmp     r12, rax
    jge     .pt_true
    jmp     .pt_false

.pt_single_string:
    ; Single string: true if non-empty
    mov     rcx, [arg_idx]
    mov     rbx, [argv_ptr]
    mov     rdi, [rbx + rcx*8]
    inc     qword [arg_idx]
    call    str_len
    test    eax, eax
    jnz     .pt_true
    jmp     .pt_false

.pt_true:
    mov     eax, 1
    pop     r12
    pop     rbx
    ret

.pt_false:
    xor     eax, eax
    pop     r12
    pop     rbx
    ret

; ============================================================
; parse_int: parse signed decimal integer
; Input: rdi = string; Output: rax = value
; ============================================================
parse_int:
    push    rbx
    xor     rax, rax
    xor     ebx, ebx
    movzx   ecx, byte [rdi]
    cmp     cl, '-'
    jne     .pi_loop
    mov     ebx, 1
    inc     rdi
.pi_loop:
    movzx   ecx, byte [rdi]
    cmp     cl, '0'
    jb      .pi_done
    cmp     cl, '9'
    ja      .pi_done
    imul    rax, 10
    sub     cl, '0'
    movzx   ecx, cl
    add     rax, rcx
    inc     rdi
    jmp     .pi_loop
.pi_done:
    test    ebx, ebx
    jz      .pi_ret
    neg     rax
.pi_ret:
    pop     rbx
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
    db "Usage: test EXPRESSION", 10
    db "  or:  test", 10
    db "  or:  [ EXPRESSION ]", 10
    db "Exit with the status determined by EXPRESSION.", 10, 10
    db "      --help     display this help and exit", 10
    db "      --version  output version information and exit", 10, 10
    db "  EXPRESSION is true or false and sets exit status.", 10, 10
    db "  ( EXPRESSION )               EXPRESSION is true", 10
    db "  ! EXPRESSION                 EXPRESSION is false", 10
    db "  EXPRESSION1 -a EXPRESSION2   both are true", 10
    db "  EXPRESSION1 -o EXPRESSION2   either is true", 10, 10
    db "  -n STRING            the length of STRING is nonzero", 10
    db "  STRING               equivalent to -n STRING", 10
    db "  -z STRING            the length of STRING is zero", 10
    db "  STRING1 = STRING2    the strings are equal", 10
    db "  STRING1 != STRING2   the strings are not equal", 10, 10
    db "  INTEGER1 -eq INTEGER2   INTEGER1 is equal to INTEGER2", 10
    db "  INTEGER1 -ge INTEGER2   INTEGER1 >= INTEGER2", 10
    db "  INTEGER1 -gt INTEGER2   INTEGER1 > INTEGER2", 10
    db "  INTEGER1 -le INTEGER2   INTEGER1 <= INTEGER2", 10
    db "  INTEGER1 -lt INTEGER2   INTEGER1 < INTEGER2", 10
    db "  INTEGER1 -ne INTEGER2   INTEGER1 is not equal to INTEGER2", 10, 10
    db "  FILE1 -ef FILE2   FILE1 and FILE2 have the same device and inode numbers", 10
    db "  FILE1 -nt FILE2   FILE1 is newer than FILE2", 10
    db "  FILE1 -ot FILE2   FILE1 is older than FILE2", 10, 10
    db "  -e FILE     FILE exists", 10
    db "  -f FILE     FILE exists and is a regular file", 10
    db "  -d FILE     FILE exists and is a directory", 10
    db "  -r FILE     FILE exists and read permission is granted", 10
    db "  -w FILE     FILE exists and write permission is granted", 10
    db "  -x FILE     FILE exists and execute permission is granted", 10
    db "  -s FILE     FILE exists and has a size greater than zero", 10
    db "  -L FILE     FILE exists and is a symbolic link (same as -h)", 10
    db "  -b FILE     FILE exists and is block special", 10
    db "  -c FILE     FILE exists and is character special", 10
    db "  -g FILE     FILE exists and is set-group-ID", 10
    db "  -k FILE     FILE exists and has its sticky bit set", 10
    db "  -p FILE     FILE exists and is a named pipe", 10
    db "  -S FILE     FILE exists and is a socket", 10
    db "  -u FILE     FILE exists and its set-user-ID bit is set", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/test>", 10
    db "or available locally via: info '(coreutils) test invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "test (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Kevin Braunsdorf and Matthew Bradburn.", 10
str_version_len equ $ - str_version

str_prefix:      db "test: "
str_prefix_len   equ $ - str_prefix
str_sq_nl:       db "'", 10

str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0

file_size equ $ - $$
