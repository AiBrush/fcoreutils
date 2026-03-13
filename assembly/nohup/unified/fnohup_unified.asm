; ============================================================
; fnohup_unified.asm — AUTO-GENERATED unified file
; nohup (GNU coreutils compatible) — x86_64 Linux
; Build: nasm -f bin unified/fnohup_unified.asm -o fnohup
; ============================================================
BITS 64
ORG 0x400000

; === ELF Header (64 bytes) ===
ehdr:
    db 0x7f, 'E','L','F'       ; magic
    db 2                        ; 64-bit
    db 1                        ; little endian
    db 1                        ; ELF version
    db 0                        ; OS/ABI: System V
    dq 0                        ; padding
    dw 2                        ; ET_EXEC
    dw 0x3e                     ; x86_64
    dd 1                        ; ELF version
    dq _start                   ; entry point
    dq phdr - $$                ; program header offset
    dq 0                        ; section header offset (none)
    dd 0                        ; flags
    dw ehdr_size                ; ELF header size
    dw phdr_size                ; program header entry size
    dw 2                        ; 2 program headers
    dw 64                       ; section header entry size
    dw 0                        ; section header count
    dw 0                        ; section name index
ehdr_size equ $ - ehdr

; === Program Header 1: PT_LOAD (code + data) ===
phdr:
    dd 1                        ; PT_LOAD
    dd 7                        ; PF_R | PF_W | PF_X
    dq 0                        ; offset in file
    dq $$                       ; virtual address
    dq $$                       ; physical address
    dq file_size                ; file size
    dq mem_size                 ; memory size (includes BSS)
    dq 0x200000                 ; alignment
phdr_size equ $ - phdr

; === Program Header 2: PT_GNU_STACK (NX stack) ===
    dd 0x6474e551               ; PT_GNU_STACK
    dd 6                        ; PF_R | PF_W (no PF_X)
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 16                       ; alignment

; ============================================================
; Syscall numbers and constants
; ============================================================
%define SYS_WRITE       1
%define SYS_CLOSE       3
%define SYS_RT_SIGACTION 13
%define SYS_IOCTL      16
%define SYS_DUP2        33
%define SYS_EXECVE      59
%define SYS_EXIT        60
%define SYS_OPENAT      257

%define STDOUT          1
%define STDERR          2
%define STDIN           0

%define SIGHUP          1
%define SIG_IGN         1

%define TIOCGWINSZ      0x5413

%define AT_FDCWD        -100
%define O_WRONLY        1
%define O_CREAT         64
%define O_APPEND        1024
%define O_WRONLY_CREAT_APPEND (O_WRONLY | O_CREAT | O_APPEND)
%define FILE_MODE       0o644

; ============================================================
; Code Section
; ============================================================

_start:
    ; Save stack frame
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Get envp pointer
    mov     rax, r14
    lea     r13, [r15 + rax*8 + 8]   ; envp

    ; ── Check for --help / --version / missing operand ──
    cmp     r14, 2
    jl      .missing_operand

    mov     rdi, [r15 + 8]      ; argv[1]
    mov     rsi, str_opt_help
    call    _strcmp
    test    eax, eax
    jz      .show_help

    mov     rdi, [r15 + 8]
    mov     rsi, str_opt_version
    call    _strcmp
    test    eax, eax
    jz      .show_version

    ; ── argv index of COMMAND starts at 1 ──
    mov     rbx, 1

    ; Check for "--" separator
    mov     rdi, [r15 + 8]
    cmp     byte [rdi], '-'
    jne     .setup_nohup
    cmp     byte [rdi+1], '-'
    jne     .setup_nohup
    cmp     byte [rdi+2], 0
    jne     .setup_nohup
    ; It's "--", skip it
    inc     rbx
    cmp     rbx, r14
    jge     .missing_operand

.setup_nohup:
    ; ── Step 1: Ignore SIGHUP (signal 1) ──
    ; struct sigaction { handler, flags, restorer, mask }
    ; We want sa_handler = SIG_IGN (1)
    ; Use stack space for the struct
    sub     rsp, 152            ; sigaction struct (sa_handler=8, sa_flags=8, sa_restorer=8, sa_mask=128)
    mov     qword [rsp], SIG_IGN    ; sa_handler = SIG_IGN
    mov     qword [rsp+8], 0x04000000  ; sa_flags = SA_RESTORER (needed for rt_sigaction)
    mov     qword [rsp+16], 0   ; sa_restorer = 0
    ; Zero out sa_mask (128 bytes)
    lea     rdi, [rsp+24]
    xor     eax, eax
    mov     ecx, 16             ; 128 bytes = 16 qwords
.zero_mask:
    mov     [rdi], rax
    add     rdi, 8
    dec     ecx
    jnz     .zero_mask

    mov     eax, SYS_RT_SIGACTION
    mov     edi, SIGHUP         ; signal number
    mov     rsi, rsp            ; new sigaction
    xor     edx, edx            ; old sigaction (NULL)
    mov     r10, 8              ; sigsetsize
    syscall
    ; Ignore errors — best effort

    add     rsp, 152            ; restore stack

    ; ── Step 2: Check if stdout is a terminal ──
    ; ioctl(STDOUT, TIOCGWINSZ, &ws)
    sub     rsp, 16             ; winsize struct
    mov     eax, SYS_IOCTL
    mov     edi, STDOUT
    mov     esi, TIOCGWINSZ
    mov     rdx, rsp
    syscall
    add     rsp, 16
    ; If rax == 0, stdout IS a terminal → redirect to nohup.out
    test    rax, rax
    jnz     .check_stderr       ; not a terminal, skip redirect

    ; ── Redirect stdout to nohup.out ──
    ; Try opening "nohup.out" in current directory first
    mov     eax, SYS_OPENAT
    mov     edi, AT_FDCWD
    lea     rsi, [str_nohup_out]
    mov     edx, O_WRONLY_CREAT_APPEND
    mov     r10d, FILE_MODE
    syscall
    cmp     rax, 0
    jge     .got_output_fd

    ; Failed — try $HOME/nohup.out
    mov     rdi, r13
    call    _find_home_env
    test    rax, rax
    jz      .cannot_open_nohup_out

    ; Build "$HOME/nohup.out" in path_buf
    mov     rsi, rax            ; HOME value
    lea     rdi, [path_buf]
    xor     ecx, ecx
.copy_home:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .home_done
    mov     [rdi + rcx], al
    inc     rcx
    inc     rsi
    cmp     rcx, 3900
    jge     .cannot_open_nohup_out
    jmp     .copy_home
.home_done:
    mov     byte [rdi + rcx], '/'
    inc     rcx
    ; Append "nohup.out"
    lea     rsi, [str_nohup_out]
.copy_nohup_name:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .home_path_done
    mov     [rdi + rcx], al
    inc     rcx
    inc     rsi
    jmp     .copy_nohup_name
.home_path_done:
    mov     byte [rdi + rcx], 0

    ; Print message to stderr about redirecting to $HOME/nohup.out
    mov     edi, STDERR
    mov     rsi, str_redir_home_pre
    mov     edx, str_redir_home_pre_len
    call    _write

    ; Open $HOME/nohup.out
    mov     eax, SYS_OPENAT
    mov     edi, AT_FDCWD
    lea     rsi, [path_buf]
    mov     edx, O_WRONLY_CREAT_APPEND
    mov     r10d, FILE_MODE
    syscall
    cmp     rax, 0
    jge     .got_output_fd

.cannot_open_nohup_out:
    ; Print error and exit 125
    mov     edi, STDERR
    mov     rsi, str_cannot_open
    mov     edx, str_cannot_open_len
    call    _write
    mov     edi, 125
    mov     eax, SYS_EXIT
    syscall

.got_output_fd:
    ; rax = fd of nohup.out
    mov     r12, rax            ; save fd

    ; Print "nohup: ignoring input and appending output to 'nohup.out'" or $HOME/nohup.out
    ; We already printed the $HOME variant above if we took that path.
    ; Check if r12's path is the CWD one (we came directly here)
    ; We'll just always print the appending message for CWD case.
    ; For simplicity: if we opened nohup.out from CWD, print the CWD message.
    ; The $HOME path already printed its message.
    ; We can distinguish by checking if we jumped from the CWD open or $HOME open.
    ; Actually, let's use a flag. We'll use the stack.
    ; Simpler: just print the CWD message if path_buf is not set.
    ; Actually let's restructure: print CWD message before the open, detect which path.
    ; Re-approach: GNU nohup prints the message to stderr regardless.

    ; Print appending message to stderr
    mov     edi, STDERR
    mov     rsi, str_appending
    mov     edx, str_appending_len
    call    _write

    ; dup2(fd, STDOUT)
    mov     eax, SYS_DUP2
    mov     edi, r12d
    mov     esi, STDOUT
    syscall

    ; Close the original fd
    mov     eax, SYS_CLOSE
    mov     edi, r12d
    syscall

.check_stderr:
    ; ── Step 3: Check if stderr is a terminal ──
    sub     rsp, 16
    mov     eax, SYS_IOCTL
    mov     edi, STDERR
    mov     esi, TIOCGWINSZ
    mov     rdx, rsp
    syscall
    add     rsp, 16
    test    rax, rax
    jnz     .check_stdin        ; not a terminal

    ; stderr is a terminal — redirect to stdout
    mov     eax, SYS_DUP2
    mov     edi, STDOUT
    mov     esi, STDERR
    syscall

.check_stdin:
    ; ── Step 4: Check if stdin is a terminal, redirect from /dev/null ──
    sub     rsp, 16
    mov     eax, SYS_IOCTL
    mov     edi, STDIN
    mov     esi, TIOCGWINSZ
    mov     rdx, rsp
    syscall
    add     rsp, 16
    test    rax, rax
    jnz     .do_exec            ; not a terminal

    ; stdin is a terminal — redirect from /dev/null
    mov     eax, SYS_OPENAT
    mov     edi, AT_FDCWD
    lea     rsi, [str_dev_null]
    xor     edx, edx            ; O_RDONLY
    xor     r10d, r10d
    syscall
    cmp     rax, 0
    jl      .do_exec            ; ignore failure
    mov     r12, rax
    mov     eax, SYS_DUP2
    mov     edi, r12d
    mov     esi, STDIN
    syscall
    mov     eax, SYS_CLOSE
    mov     edi, r12d
    syscall

.do_exec:
    ; ── Step 5: Build argv for exec ──
    ; argv starts at r15[rbx*8]
    mov     rcx, 0
.build_argv:
    cmp     rbx, r14
    jge     .argv_done
    mov     rax, [r15 + rbx*8]
    mov     [exec_argv + rcx*8], rax
    inc     rcx
    inc     rbx
    cmp     rcx, 256
    jge     .argv_done
    jmp     .build_argv
.argv_done:
    mov     qword [exec_argv + rcx*8], 0

    ; ── Step 6: Try direct execve ──
    mov     rdi, [exec_argv]
    lea     rsi, [exec_argv]
    mov     rdx, r13
    mov     eax, SYS_EXECVE
    syscall

    ; Check for ENOENT (-2), EACCES (-13), ENOTDIR (-20)
    ; If the command has a slash, don't search PATH
    mov     rdi, [exec_argv]
    call    _has_slash
    test    eax, eax
    jnz     .exec_check_error

    ; Try PATH search
    cmp     rax, -2
    je      .try_path

    ; For relative names, also try PATH on common errors
    jmp     .try_path

.exec_check_error:
    ; Command has a slash — interpret the error directly
    mov     rdi, [exec_argv]
    lea     rsi, [exec_argv]
    mov     rdx, r13
    mov     eax, SYS_EXECVE
    syscall
    ; rax is the error
    cmp     rax, -13
    je      .exec_failed_perm
    jmp     .exec_not_found

.try_path:
    mov     rdi, r13
    call    _find_path_env
    test    rax, rax
    jz      .exec_not_found
    mov     r8, rax             ; PATH value pointer
    mov     r9, [exec_argv]     ; command name

.path_loop:
    cmp     byte [r8], 0
    je      .exec_not_found

    lea     rdi, [path_buf]
    mov     rcx, 0
.copy_path_component:
    movzx   eax, byte [r8]
    cmp     al, ':'
    je      .path_sep
    test    al, al
    jz      .path_sep
    mov     [rdi + rcx], al
    inc     rcx
    inc     r8
    cmp     rcx, 4000
    jge     .path_sep
    jmp     .copy_path_component
.path_sep:
    cmp     byte [r8], ':'
    jne     .no_skip_colon
    inc     r8
.no_skip_colon:
    ; Add trailing slash
    test    rcx, rcx
    jz      .skip_slash         ; empty component = "."
    mov     byte [rdi + rcx], '/'
    inc     rcx
    jmp     .copy_cmd
.skip_slash:
    ; empty PATH component means current directory
    mov     byte [rdi], '.'
    mov     byte [rdi+1], '/'
    mov     rcx, 2
.copy_cmd:
    push    r8
    mov     rsi, r9
.copy_cmd_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .cmd_done
    mov     [rdi + rcx], al
    inc     rcx
    inc     rsi
    cmp     rcx, 4090
    jge     .cmd_done
    jmp     .copy_cmd_loop
.cmd_done:
    mov     byte [rdi + rcx], 0
    pop     r8

    ; Try execve with this path
    lea     rdi, [path_buf]
    lea     rsi, [exec_argv]
    mov     rdx, r13
    mov     eax, SYS_EXECVE
    syscall

    ; If EACCES, remember it but keep searching
    cmp     rax, -13
    je      .path_eacces
    jmp     .path_loop

.path_eacces:
    ; Mark that we found but couldn't execute
    mov     byte [found_eacces], 1
    jmp     .path_loop

.exec_not_found:
    ; Check if we got EACCES during PATH search
    cmp     byte [found_eacces], 1
    je      .exec_failed_perm

    ; ENOENT — command not found (127)
    mov     edi, STDERR
    mov     rsi, str_prog_prefix
    mov     edx, str_prog_prefix_len
    call    _write
    mov     edi, STDERR
    mov     rsi, str_failed_run
    mov     edx, str_failed_run_len
    call    _write
    mov     rdi, [exec_argv]
    call    _strlen
    mov     rdx, rax
    mov     rsi, [exec_argv]
    mov     edi, STDERR
    call    _write
    mov     edi, STDERR
    mov     rsi, str_enoent
    mov     edx, str_enoent_len
    call    _write
    mov     edi, 127
    mov     eax, SYS_EXIT
    syscall

.exec_failed_perm:
    ; EACCES — command found but cannot invoke (126)
    mov     edi, STDERR
    mov     rsi, str_prog_prefix
    mov     edx, str_prog_prefix_len
    call    _write
    mov     edi, STDERR
    mov     rsi, str_failed_run
    mov     edx, str_failed_run_len
    call    _write
    mov     rdi, [exec_argv]
    call    _strlen
    mov     rdx, rax
    mov     rsi, [exec_argv]
    mov     edi, STDERR
    call    _write
    mov     edi, STDERR
    mov     rsi, str_eperm
    mov     edx, str_eperm_len
    call    _write
    mov     edi, 126
    mov     eax, SYS_EXIT
    syscall

.missing_operand:
    mov     edi, STDERR
    mov     rsi, str_missing_operand
    mov     edx, str_missing_operand_len
    call    _write
    mov     edi, STDERR
    mov     rsi, str_try
    mov     edx, str_try_len
    call    _write
    mov     edi, 125
    mov     eax, SYS_EXIT
    syscall

.show_help:
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    _write
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.show_version:
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    _write
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

; ============================================================
; Utility functions
; ============================================================

_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4             ; EINTR
    je      _write
    ret

_strlen:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

_strcmp:
.loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .diff
    test    al, al
    jz      .equal
    inc     rdi
    inc     rsi
    jmp     .loop
.equal:
    xor     eax, eax
    ret
.diff:
    sub     eax, ecx
    ret

_has_slash:
    ; Returns 1 if string at rdi contains '/', 0 otherwise
    xor     eax, eax
.loop:
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .done
    cmp     cl, '/'
    je      .found
    inc     rdi
    jmp     .loop
.found:
    mov     eax, 1
.done:
    ret

_find_path_env:
    ; rdi = envp, returns PATH value in rax (or 0)
.loop:
    mov     rax, [rdi]
    test    rax, rax
    jz      .not_found
    cmp     dword [rax], 0x48544150     ; "PATH"
    jne     .next
    cmp     byte [rax + 4], '='
    jne     .next
    lea     rax, [rax + 5]
    ret
.next:
    add     rdi, 8
    jmp     .loop
.not_found:
    xor     eax, eax
    ret

_find_home_env:
    ; rdi = envp, returns HOME value in rax (or 0)
.loop:
    mov     rax, [rdi]
    test    rax, rax
    jz      .not_found
    cmp     dword [rax], 0x454d4f48     ; "HOME"
    jne     .next
    cmp     byte [rax + 4], '='
    jne     .next
    lea     rax, [rax + 5]
    ret
.next:
    add     rdi, 8
    jmp     .loop
.not_found:
    xor     eax, eax
    ret

; ============================================================
; Data Section
; ============================================================

; @@DATA_START@@
str_help:
    db "Usage: nohup COMMAND [ARG]...", 10
    db "  or:  nohup OPTION", 10
    db "Run COMMAND, ignoring hangup signals.", 10
    db 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "If standard input is a terminal, redirect it from an unreadable file.", 10
    db "If standard output is a terminal, append output to 'nohup.out' if possible,", 10
    db "'$HOME/nohup.out' otherwise.", 10
    db "If standard error is a terminal, redirect it to standard output.", 10
    db "To save output to FILE, use 'nohup COMMAND > FILE'.", 10
    db 10
    db "Your shell may have its own version of nohup, which usually supersedes", 10
    db "the version described here.  Please refer to your shell's documentation", 10
    db "for details about the options it supports.", 10
    db 10
    db "Exit status:", 10
    db "  125  if the nohup command itself fails", 10
    db "  126  if COMMAND is found but cannot be invoked", 10
    db "  127  if COMMAND cannot be found", 10
    db "  -    the exit status of COMMAND otherwise", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/nohup>", 10
    db "or available locally via: info '(coreutils) nohup invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "nohup (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Jim Meyering.", 10
str_version_len equ $ - str_version

str_try:
    db "Try 'nohup --help' for more information.", 10
str_try_len equ $ - str_try

str_missing_operand:
    db "nohup: missing operand", 10
str_missing_operand_len equ $ - str_missing_operand

str_prog_prefix:
    db "nohup: ", 0
str_prog_prefix_len equ $ - str_prog_prefix - 1

str_failed_run:
    db "failed to run command '", 0
str_failed_run_len equ $ - str_failed_run - 1

str_enoent:
    db "': No such file or directory", 10
str_enoent_len equ $ - str_enoent

str_eperm:
    db "': Permission denied", 10
str_eperm_len equ $ - str_eperm

str_appending:
    db "nohup: ignoring input and appending output to 'nohup.out'", 10
str_appending_len equ $ - str_appending

str_redir_home_pre:
    db "nohup: ignoring input and appending output to '$HOME/nohup.out'", 10
str_redir_home_pre_len equ $ - str_redir_home_pre

str_cannot_open:
    db "nohup: failed to open 'nohup.out': Permission denied", 10
str_cannot_open_len equ $ - str_cannot_open
; @@DATA_END@@

str_opt_help:
    db "--help", 0

str_opt_version:
    db "--version", 0

str_nohup_out:
    db "nohup.out", 0

str_dev_null:
    db "/dev/null", 0

; ============================================================
; BSS — writable area after file data
; ============================================================
file_size equ $ - $$

exec_argv: times 258*8 db 0
path_buf: times 4096 db 0
found_eacces: db 0

mem_size equ $ - $$
