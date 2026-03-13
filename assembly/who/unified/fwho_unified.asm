; ============================================================
; fwho_unified.asm — GNU-compatible 'who' command
; Builds with: nasm -f bin unified/fwho_unified.asm -o fwho
;
; who: show who is logged on
;
; Usage: who [OPTION]... [ FILE | ARG1 ARG2 ]
;   -b, --boot     time of last system boot
;   -H, --heading  print line of column headings
;   -q, --count    all login names and number of users logged on
;   -s, --short    print only name, line, and time (default)
;   who am i       print only the entry for current terminal
;
; Reads /var/run/utmp and displays formatted user information.
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ             0
%define SYS_WRITE            1
%define SYS_OPEN             2
%define SYS_CLOSE            3
%define SYS_IOCTL           16
%define SYS_EXIT            60
%define SYS_READLINK        89
%define SYS_RT_SIGPROCMASK  14

%define O_RDONLY             0
%define STDOUT               1
%define STDERR               2
%define SIG_BLOCK            0
%define SIGPIPE             13

; ioctl for tty name
%define TIOCGPGRP       0x540F

; utmp record size and field offsets (Linux x86-64)
%define UTMP_SIZE       384
%define UT_LINESIZE      32
%define UT_NAMESIZE      32
%define UT_HOSTSIZE     256

; Offsets in struct utmp
%define UT_TYPE           0     ; short (2 bytes, 2 padding)
%define UT_PID            4     ; pid_t (4 bytes)
%define UT_LINE           8     ; char[32]
%define UT_ID            40     ; char[4]
%define UT_USER          44     ; char[32]
%define UT_HOST          76     ; char[256]
%define UT_EXIT         332     ; struct exit_status (4 bytes)
%define UT_SESSION      336     ; int32_t
%define UT_TV_SEC       340     ; int32_t (tv_sec)
%define UT_TV_USEC      344     ; int32_t (tv_usec)

; ut_type values
%define USER_PROCESS      7
%define BOOT_TIME          2

; === ELF Header ===
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
    dw ehdr_size
    dw phdr_size
    dw 2
    dw 64, 0, 0
ehdr_size equ $ - ehdr

phdr:
    dd 1, 7
    dq 0, $$, $$
    dq file_size, mem_size
    dq 0x200000
phdr_size equ $ - phdr

    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 16

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

    ; argc, argv
    mov     r14d, [rsp]         ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Defaults: flags in r12d
    ; bit 0: -b (boot)
    ; bit 1: -H (heading)
    ; bit 2: -q (count)
    ; bit 3: -s (short, default — implicit)
    ; bit 4: "am i" mode
    xor     r12d, r12d

    ; Parse args
    mov     ecx, 1              ; current arg index

    cmp     r14d, 2
    jl      .no_more_opts

    ; Check for "who am i" / "who am I" (argc >= 3, argv[1]="am", argv[2]="i"/"I")
    cmp     r14d, 3
    jl      .not_am_i
    mov     rdi, [r15 + 8]
    mov     rsi, str_am
    call    str_eq
    test    eax, eax
    jz      .not_am_i
    mov     rdi, [r15 + 16]
    mov     rsi, str_i_lower
    call    str_eq
    test    eax, eax
    jnz     .set_am_i
    mov     rdi, [r15 + 16]
    mov     rsi, str_i_upper
    call    str_eq
    test    eax, eax
    jnz     .set_am_i
    jmp     .not_am_i
.set_am_i:
    or      r12d, 16            ; am i mode
    jmp     .no_more_opts
.not_am_i:

    ; Check --help / --version first
    mov     rdi, [r15 + 8]
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .show_help
    mov     rdi, [r15 + 8]
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .show_version

    ; Check long options
    mov     rdi, [r15 + 8]
    mov     rsi, str_boot_long
    call    str_eq
    test    eax, eax
    jnz     .set_boot_and_continue
    mov     rdi, [r15 + 8]
    mov     rsi, str_heading_long
    call    str_eq
    test    eax, eax
    jnz     .set_heading_and_continue
    mov     rdi, [r15 + 8]
    mov     rsi, str_count_long
    call    str_eq
    test    eax, eax
    jnz     .set_count_and_continue
    mov     rdi, [r15 + 8]
    mov     rsi, str_short_long
    call    str_eq
    test    eax, eax
    jnz     .set_short_and_continue

.parse_opts:
    cmp     ecx, r14d
    jge     .no_more_opts
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .no_more_opts
    cmp     byte [rdi + 1], '-'
    je      .check_long_in_loop
    cmp     byte [rdi + 1], 0
    je      .no_more_opts
    ; Parse short flags
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'b'
    je      .set_boot
    cmp     al, 'H'
    je      .set_heading
    cmp     al, 'q'
    je      .set_count
    cmp     al, 's'
    je      .set_short
    ; Invalid option
    jmp     .invalid_short
.set_boot:
    or      r12d, 1
    inc     rdi
    jmp     .short_loop
.set_heading:
    or      r12d, 2
    inc     rdi
    jmp     .short_loop
.set_count:
    or      r12d, 4
    inc     rdi
    jmp     .short_loop
.set_short:
    ; -s is default, just accept it
    inc     rdi
    jmp     .short_loop
.next_opt:
    inc     ecx
    jmp     .parse_opts

.check_long_in_loop:
    ; rdi points to arg starting with "--"
    push    rcx
    mov     rsi, str_boot_long
    call    str_eq
    test    eax, eax
    jnz     .long_boot
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_heading_long
    call    str_eq
    test    eax, eax
    jnz     .long_heading
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_count_long
    call    str_eq
    test    eax, eax
    jnz     .long_count
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_short_long
    call    str_eq
    test    eax, eax
    jnz     .long_short
    pop     rcx
    ; Unknown long option
    mov     rdi, [r15 + rcx*8]
    jmp     .invalid_long
.long_boot:
    pop     rcx
    or      r12d, 1
    inc     ecx
    jmp     .parse_opts
.long_heading:
    pop     rcx
    or      r12d, 2
    inc     ecx
    jmp     .parse_opts
.long_count:
    pop     rcx
    or      r12d, 4
    inc     ecx
    jmp     .parse_opts
.long_short:
    pop     rcx
    inc     ecx
    jmp     .parse_opts

.set_boot_and_continue:
    or      r12d, 1
    mov     ecx, 2
    jmp     .parse_opts
.set_heading_and_continue:
    or      r12d, 2
    mov     ecx, 2
    jmp     .parse_opts
.set_count_and_continue:
    or      r12d, 4
    mov     ecx, 2
    jmp     .parse_opts
.set_short_and_continue:
    mov     ecx, 2
    jmp     .parse_opts

.no_more_opts:
    ; If "am i" mode, get current tty name
    test    r12d, 16
    jz      .skip_tty_lookup

    ; Read /proc/self/fd/0 symlink to get tty path
    mov     eax, SYS_READLINK
    mov     rdi, str_proc_fd0
    lea     rsi, [tty_path_buf]
    mov     edx, 256
    syscall
    cmp     rax, 0
    jle     .ami_no_tty
    ; NUL-terminate
    lea     rdi, [tty_path_buf]
    mov     byte [rdi + rax], 0
    ; Strip /dev/ prefix if present (we need just the line part, e.g. "pts/0")
    mov     rsi, str_dev_prefix
    call    starts_with
    test    eax, eax
    jz      .ami_use_full
    lea     rdi, [tty_path_buf + 5]  ; skip "/dev/"
    mov     [ami_tty_line], rdi
    jmp     .skip_tty_lookup
.ami_use_full:
    lea     rdi, [tty_path_buf]
    mov     [ami_tty_line], rdi
    jmp     .skip_tty_lookup
.ami_no_tty:
    ; No tty, clear am-i mode — will produce no output
    and     r12d, ~16

.skip_tty_lookup:
    ; If -q (count) mode, handle separately
    test    r12d, 4
    jnz     .count_mode

    ; Print heading if -H
    test    r12d, 2
    jz      .skip_heading
    mov     edi, STDOUT
    mov     rsi, str_heading
    mov     edx, str_heading_len
    call    do_write
.skip_heading:

    ; Open /var/run/utmp
    mov     eax, SYS_OPEN
    mov     rdi, str_utmp_path
    xor     esi, esi            ; O_RDONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .try_run_utmp
    jmp     .utmp_opened
.try_run_utmp:
    mov     eax, SYS_OPEN
    mov     rdi, str_run_utmp_path
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    js      .no_utmp
.utmp_opened:
    mov     r13, rax            ; utmp fd

    ; Initialize user count for -q mode (reuse for count in normal modes)
    xor     ebp, ebp            ; user count

.read_loop:
    mov     eax, SYS_READ
    mov     edi, r13d
    lea     rsi, [utmp_buf]
    mov     edx, UTMP_SIZE
    syscall
    cmp     rax, UTMP_SIZE
    jl      .close_utmp

    ; Check what type of entry we want
    movzx   eax, word [utmp_buf + UT_TYPE]

    ; If -b mode, look for BOOT_TIME entries
    test    r12d, 1
    jz      .check_user_process
    cmp     eax, BOOT_TIME
    je      .print_boot_entry
    jmp     .check_user_process_after_boot

.check_user_process:
    cmp     eax, USER_PROCESS
    jne     .read_loop
    jmp     .filter_and_print

.check_user_process_after_boot:
    ; In -b mode, also show user processes unless only -b is set
    ; Actually GNU who -b only shows boot, not users. Match GNU.
    jmp     .read_loop

.filter_and_print:
    ; If "am i" mode, filter by current tty
    test    r12d, 16
    jz      .print_user_entry

    ; Compare ut_line with our tty line
    lea     rdi, [utmp_buf + UT_LINE]
    mov     rsi, [ami_tty_line]
    call    str_eq_n32
    test    eax, eax
    jz      .read_loop

.print_user_entry:
    ; Format: USERNAME   LINE       YYYY-MM-DD HH:MM (HOST)
    ; Columns: name@0 (pad to 8+1=col9), line@9 (pad to col22), time@22, host

    ; Print username (pad to 8 chars min, then space to col 9)
    lea     rdi, [utmp_buf + UT_USER]
    call    str_len_n32
    mov     r8d, eax            ; username length
    lea     rsi, [utmp_buf + UT_USER]
    mov     edx, eax
    mov     edi, STDOUT
    call    do_write

    ; Pad from current pos to column 9 (at least 1 space)
    mov     eax, 9
    sub     eax, r8d
    cmp     eax, 1
    jge     .pad_to_line
    mov     eax, 1
.pad_to_line:
    mov     r9d, eax
    call    write_spaces

    ; Print line (tty), pad to column 22 (line col is 13 chars wide)
    lea     rdi, [utmp_buf + UT_LINE]
    call    str_len_n32
    mov     r8d, eax            ; line length
    lea     rsi, [utmp_buf + UT_LINE]
    mov     edx, eax
    mov     edi, STDOUT
    call    do_write

    ; Pad from line end to column 22 (13 - line_len spaces, min 1)
    mov     eax, 13
    sub     eax, r8d
    cmp     eax, 1
    jge     .pad_to_time
    mov     eax, 1
.pad_to_time:
    mov     r9d, eax
    call    write_spaces

    ; Format and print timestamp: YYYY-MM-DD HH:MM
    mov     eax, [utmp_buf + UT_TV_SEC]
    ; eax = unix timestamp (signed 32-bit)
    movsxd  rdi, eax
    call    format_timestamp

    ; Print host if non-empty: " (HOST)"
    lea     rdi, [utmp_buf + UT_HOST]
    cmp     byte [rdi], 0
    je      .no_host
    ; Print " ("
    mov     edi, STDOUT
    mov     rsi, str_host_open
    mov     edx, 2
    call    do_write
    ; Print host
    lea     rdi, [utmp_buf + UT_HOST]
    call    str_len_n256
    mov     edx, eax
    lea     rsi, [utmp_buf + UT_HOST]
    mov     edi, STDOUT
    call    do_write
    ; Print ")"
    mov     edi, STDOUT
    mov     rsi, str_host_close
    mov     edx, 1
    call    do_write
.no_host:

    ; Newline
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write

    inc     ebp                 ; count users
    jmp     .read_loop

.print_boot_entry:
    ; Format: "         system boot  YYYY-MM-DD HH:MM"
    ; 9 spaces, then "system boot", then pad to col 22, then timestamp
    mov     edi, STDOUT
    mov     rsi, str_boot_prefix
    mov     edx, str_boot_prefix_len
    call    do_write

    ; Format and print timestamp
    mov     eax, [utmp_buf + UT_TV_SEC]
    movsxd  rdi, eax
    call    format_timestamp

    ; Newline
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write

    jmp     .read_loop

.close_utmp:
    mov     eax, SYS_CLOSE
    mov     edi, r13d
    syscall

.no_utmp:
    xor     edi, edi
    jmp     do_exit

; ── Count mode (-q) ──
.count_mode:
    xor     ebp, ebp            ; init user count to 0
    ; Open utmp
    mov     eax, SYS_OPEN
    mov     rdi, str_utmp_path
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    js      .count_try_run
    jmp     .count_opened
.count_try_run:
    mov     eax, SYS_OPEN
    mov     rdi, str_run_utmp_path
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    js      .count_print_total  ; no utmp, just print count=0
.count_opened:
    mov     r13, rax
    xor     ebp, ebp            ; user count
    mov     byte [count_first], 1

.count_read:
    mov     eax, SYS_READ
    mov     edi, r13d
    lea     rsi, [utmp_buf]
    mov     edx, UTMP_SIZE
    syscall
    cmp     rax, UTMP_SIZE
    jl      .count_done

    movzx   eax, word [utmp_buf + UT_TYPE]
    cmp     eax, USER_PROCESS
    jne     .count_read

    ; Print space separator (not before first)
    cmp     byte [count_first], 1
    je      .count_no_sep
    mov     edi, STDOUT
    mov     rsi, str_space
    mov     edx, 1
    call    do_write
.count_no_sep:
    mov     byte [count_first], 0

    ; Print username
    lea     rdi, [utmp_buf + UT_USER]
    call    str_len_n32
    mov     edx, eax
    lea     rsi, [utmp_buf + UT_USER]
    mov     edi, STDOUT
    call    do_write

    inc     ebp
    jmp     .count_read

.count_done:
    mov     eax, SYS_CLOSE
    mov     edi, r13d
    syscall

.count_print_total:
    ; Print newline after usernames
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write

    ; Print "# users=N"
    mov     edi, STDOUT
    mov     rsi, str_count_prefix
    mov     edx, str_count_prefix_len
    call    do_write

    ; Print count as decimal
    mov     eax, ebp
    call    print_uint

    ; Print newline
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write

    xor     edi, edi
    jmp     do_exit

; ── Error handling ──
.invalid_short:
    mov     r8b, [rdi]
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    write_err
    mov     [char_buf], r8b
    mov     rsi, char_buf
    mov     edx, 1
    call    write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    write_err
    mov     edi, 1
    jmp     do_exit

.invalid_long:
    ; rdi = the arg string
    push    rdi
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_unrecognized
    mov     edx, str_unrecognized_len
    call    write_err
    pop     rdi
    push    rdi
    call    str_len
    mov     edx, eax
    pop     rsi
    call    write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    write_err
    mov     edi, 1
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
; Utility functions
; ============================================================

do_write:
    ; edi = fd, rsi = buf, edx = len
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4             ; EINTR
    je      do_write
    ret

write_err:
    mov     edi, STDERR
    jmp     do_write

do_exit:
    mov     eax, SYS_EXIT
    syscall

; write_spaces: write r9d spaces
write_spaces:
    test    r9d, r9d
    jle     .done
.loop:
    push    r9
    mov     edi, STDOUT
    mov     rsi, str_space
    mov     edx, 1
    call    do_write
    pop     r9
    dec     r9d
    jnz     .loop
.done:
    ret

; str_len: length of NUL-terminated string at rdi
str_len:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     eax
    jmp     .loop
.done:
    ret

; str_len_n32: length of string at rdi, max 32 bytes
str_len_n32:
    xor     eax, eax
.loop:
    cmp     eax, 32
    jge     .done
    cmp     byte [rdi + rax], 0
    je      .done
    inc     eax
    jmp     .loop
.done:
    ret

; str_len_n256: length of string at rdi, max 256 bytes
str_len_n256:
    xor     eax, eax
.loop:
    cmp     eax, 256
    jge     .done
    cmp     byte [rdi + rax], 0
    je      .done
    inc     eax
    jmp     .loop
.done:
    ret

; str_eq: compare NUL-terminated strings at rdi, rsi. Returns 1 if equal.
str_eq:
    xor     r8d, r8d
.loop:
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    cmp     al, dl
    jne     .ne
    test    al, al
    jz      .eq
    inc     r8d
    jmp     .loop
.eq:
    mov     eax, 1
    ret
.ne:
    xor     eax, eax
    ret

; str_eq_n32: compare utmp field (rdi, max 32) with NUL-terminated (rsi)
str_eq_n32:
    xor     r8d, r8d
.loop:
    cmp     r8d, 32
    jge     .check_end
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    test    al, al
    jz      .check_end
    test    dl, dl
    jz      .check_utmp_end
    cmp     al, dl
    jne     .ne
    inc     r8d
    jmp     .loop
.check_end:
    cmp     byte [rsi + r8], 0
    je      .eq
    jmp     .ne
.check_utmp_end:
    cmp     byte [rdi + r8], 0
    je      .eq
.ne:
    xor     eax, eax
    ret
.eq:
    mov     eax, 1
    ret

; starts_with: check if string rdi starts with prefix rsi
starts_with:
    xor     r8d, r8d
.loop:
    movzx   eax, byte [rsi + r8]
    test    al, al
    jz      .match
    cmp     al, byte [rdi + r8]
    jne     .no
    inc     r8d
    jmp     .loop
.match:
    mov     eax, 1
    ret
.no:
    xor     eax, eax
    ret

; print_uint: print unsigned 32-bit integer in eax to stdout
print_uint:
    lea     rdi, [num_buf + 20]
    mov     byte [rdi], 0
    mov     ecx, 10
    test    eax, eax
    jnz     .convert
    ; Zero case
    dec     rdi
    mov     byte [rdi], '0'
    jmp     .print
.convert:
    test    eax, eax
    jz      .print
    xor     edx, edx
    div     ecx
    add     dl, '0'
    dec     rdi
    mov     [rdi], dl
    jmp     .convert
.print:
    ; rdi = start of string
    mov     rsi, rdi
    lea     rdi, [num_buf + 20]
    sub     rdi, rsi
    mov     edx, edi            ; length
    mov     edi, STDOUT
    call    do_write
    ret

; ============================================================
; format_timestamp: convert unix timestamp to "YYYY-MM-DD HH:MM"
; Input: rdi = unix timestamp (int64)
; Output: writes 16 chars to stdout
; ============================================================
format_timestamp:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    ; Apply timezone offset to convert UTC -> local time
    call    get_tz_offset       ; rdi = UTC timestamp, returns rax = offset
    add     rdi, rax
    mov     rbx, rdi            ; save local timestamp

    ; Handle negative timestamps (before epoch)
    cmp     rbx, 0
    jge     .ts_positive
    xor     ebx, ebx
.ts_positive:
    ; rax = total seconds
    ; days = rax / 86400
    ; remainder = seconds within day
    mov     rax, rbx
    xor     rdx, rdx
    mov     rcx, 86400
    div     rcx
    ; rax = total days since epoch, rdx = seconds in day
    mov     r13, rax            ; total days
    mov     r14, rdx            ; seconds in day

    ; hours = seconds_in_day / 3600
    mov     rax, r14
    xor     edx, edx
    mov     ecx, 3600
    div     ecx
    mov     r15d, eax           ; hours (0-23)
    ; remaining seconds
    mov     rax, rdx
    xor     edx, edx
    mov     ecx, 60
    div     ecx
    mov     ebp, eax            ; minutes (0-59)

    ; Now compute year/month/day from total days since epoch (Jan 1 1970)
    ; Algorithm: count days
    mov     rax, r13            ; total_days
    ; Start from 1970
    mov     ecx, 1970           ; year
    ; r12 will hold month, r13 will hold day
.year_loop:
    ; days_in_year: 365 or 366 if leap
    push    rax
    push    rcx
    mov     edi, ecx
    call    is_leap_year
    mov     r9d, eax            ; save leap flag (0 or 1)
    pop     rcx
    pop     rax                 ; restore remaining days
    mov     edx, 365
    add     edx, r9d            ; 365 + leap
    cmp     rax, rdx
    jl      .year_found
    sub     rax, rdx
    inc     ecx
    jmp     .year_loop
.year_found:
    ; ecx = year, rax = day_of_year (0-based)
    mov     r12d, ecx           ; year
    ; Now find month
    push    rax
    mov     edi, ecx
    call    is_leap_year
    mov     r8d, eax            ; leap flag
    pop     rax
    ; month lengths: 31, 28/29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
    mov     ecx, 1              ; month (1-based)
    lea     rsi, [month_days]
.month_loop:
    movzx   edx, byte [rsi]
    ; February special case
    cmp     ecx, 2
    jne     .not_feb
    add     edx, r8d            ; add 1 if leap year
.not_feb:
    cmp     eax, edx
    jl      .month_found
    sub     eax, edx
    inc     ecx
    inc     rsi
    cmp     ecx, 13
    jl      .month_loop
    ; Shouldn't happen, but safety
    mov     ecx, 12
    jmp     .month_found
.month_found:
    ; ecx = month (1-12), eax = day (0-based)
    inc     eax                 ; day is 1-based
    mov     r13d, ecx           ; month
    mov     r14d, eax           ; day

    ; Now format: "YYYY-MM-DD HH:MM"
    ; Build in ts_buf
    lea     rdi, [ts_buf]

    ; Year (4 digits)
    mov     eax, r12d
    mov     ecx, 1000
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     [rdi], al
    mov     eax, edx
    mov     ecx, 100
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     [rdi + 1], al
    mov     eax, edx
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     [rdi + 2], al
    add     dl, '0'
    mov     [rdi + 3], dl

    mov     byte [rdi + 4], '-'

    ; Month (2 digits)
    mov     eax, r13d
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     [rdi + 5], al
    add     dl, '0'
    mov     [rdi + 6], dl

    mov     byte [rdi + 7], '-'

    ; Day (2 digits)
    mov     eax, r14d
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     [rdi + 8], al
    add     dl, '0'
    mov     [rdi + 9], dl

    mov     byte [rdi + 10], ' '

    ; Hours (2 digits)
    mov     eax, r15d
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     [rdi + 11], al
    add     dl, '0'
    mov     [rdi + 12], dl

    mov     byte [rdi + 13], ':'

    ; Minutes (2 digits)
    mov     eax, ebp
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     al, '0'
    mov     [rdi + 14], al
    add     dl, '0'
    mov     [rdi + 15], dl

    ; Write timestamp to stdout
    mov     edi, STDOUT
    lea     rsi, [ts_buf]
    mov     edx, 16
    call    do_write

    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; is_leap_year: edi = year, returns eax = 1 if leap, 0 if not
is_leap_year:
    mov     eax, edi
    ; divisible by 4?
    test    eax, 3
    jnz     .not_leap
    ; divisible by 100?
    push    rax
    xor     edx, edx
    mov     ecx, 100
    div     ecx
    test    edx, edx
    pop     rax
    jnz     .leap
    ; divisible by 400?
    xor     edx, edx
    mov     ecx, 400
    div     ecx
    test    edx, edx
    jnz     .not_leap
.leap:
    mov     eax, 1
    ret
.not_leap:
    xor     eax, eax
    ret

; ============================================================
; get_tz_offset: find UTC offset for a given timestamp
; Input: rdi = UTC timestamp (int64)
; Output: rax = offset in seconds (signed)
; Preserves: rdi
; Uses cached TZif data loaded by load_tzinfo
; ============================================================
get_tz_offset:
    push    rdi
    ; Check if tzinfo loaded
    cmp     dword [tz_loaded], 0
    jne     .tz_ready
    ; Load TZif data
    call    load_tzinfo
.tz_ready:
    pop     rdi
    ; If no timezone data, return 0
    cmp     dword [tz_loaded], 1
    jne     .tz_zero

    ; Search transitions: find the last transition <= rdi
    ; tz_trans_count = number of transitions
    ; tz_trans_times = array of int64 transition times
    ; tz_trans_types = array of byte type indices
    ; tz_ttinfos = array of (int32 utoff, byte dst, byte abbr_idx) = 6 bytes each

    mov     ecx, [tz_trans_count]
    test    ecx, ecx
    jz      .use_default_type

    ; Linear scan from end (most entries are recent)
    lea     rsi, [tz_trans_times]
    lea     rdx, [tz_trans_type_idx]
    dec     ecx
.tz_search:
    cmp     ecx, 0
    jl      .use_default_type
    mov     rax, [rsi + rcx*8]
    cmp     rdi, rax
    jge     .tz_found
    dec     ecx
    jmp     .tz_search

.tz_found:
    ; ecx = index of matching transition
    movzx   eax, byte [rdx + rcx]  ; type index
    jmp     .tz_get_offset

.use_default_type:
    ; Use first ttinfo (type 0)
    xor     eax, eax

.tz_get_offset:
    ; eax = type index, each ttinfo is 6 bytes: int32 utoff, byte dst, byte abbr
    lea     rsi, [tz_ttinfos]
    imul    eax, eax, 6
    movsxd  rax, dword [rsi + rax]  ; utoff (signed 32-bit -> 64-bit)
    ret

.tz_zero:
    xor     eax, eax
    ret

; ============================================================
; load_tzinfo: read and parse /etc/localtime (TZif2 format)
; Stores transition data in global buffers
; ============================================================
load_tzinfo:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     dword [tz_loaded], 2  ; mark as attempted (2 = failed)
    mov     dword [tz_trans_count], 0

    ; Open /etc/localtime
    mov     eax, SYS_OPEN
    mov     rdi, str_localtime
    xor     esi, esi            ; O_RDONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .tz_load_done
    mov     r12, rax            ; fd

    ; Read entire file into tz_file_buf (max 4096 bytes)
    mov     eax, SYS_READ
    mov     edi, r12d
    lea     rsi, [tz_file_buf]
    mov     edx, 4096
    syscall
    mov     r13, rax            ; bytes read

    ; Close file
    push    r13
    mov     eax, SYS_CLOSE
    mov     edi, r12d
    syscall
    pop     r13

    cmp     r13, 44
    jl      .tz_load_done       ; too small

    ; Verify TZif magic
    lea     rsi, [tz_file_buf]
    cmp     dword [rsi], 0x66695a54  ; 'TZif' little-endian
    jne     .tz_load_done

    ; Find the second TZif header (TZif2/3)
    ; Search for 'TZif' starting from offset 1
    lea     rdi, [tz_file_buf + 1]
    lea     rcx, [tz_file_buf]
    add     rcx, r13
    sub     rcx, 44             ; need at least 44 bytes for header
.tz_find_header2:
    cmp     rdi, rcx
    jge     .tz_parse_v1        ; no v2 header found, try v1
    cmp     dword [rdi], 0x66695a54
    je      .tz_found_v2
    inc     rdi
    jmp     .tz_find_header2

.tz_found_v2:
    ; rdi = start of v2 header
    mov     rsi, rdi
    ; Parse v2 header:
    ; offset 20: tzh_ttisutcnt (4 bytes, big-endian)
    ; offset 24: tzh_ttisstdcnt
    ; offset 28: tzh_leapcnt
    ; offset 32: tzh_timecnt
    ; offset 36: tzh_typecnt
    ; offset 40: tzh_charcnt

    ; Read counts (big-endian)
    mov     eax, [rsi + 32]
    bswap   eax
    mov     r14d, eax           ; timecnt
    mov     eax, [rsi + 36]
    bswap   eax
    mov     r15d, eax           ; typecnt
    mov     eax, [rsi + 28]
    bswap   eax
    mov     ebx, eax            ; leapcnt

    ; Limit transition count to our buffer size (max 256)
    cmp     r14d, 256
    jle     .tz_count_ok
    mov     r14d, 256
.tz_count_ok:
    mov     [tz_trans_count], r14d

    ; Data starts at offset 44 from v2 header
    lea     rdi, [rsi + 44]     ; pointer to transition times (8 bytes each, big-endian)

    ; Copy transition times (convert from big-endian)
    xor     ecx, ecx
    lea     rdx, [tz_trans_times]
.tz_copy_times:
    cmp     ecx, r14d
    jge     .tz_copy_types
    mov     rax, [rdi + rcx*8]
    bswap   rax
    mov     [rdx + rcx*8], rax
    inc     ecx
    jmp     .tz_copy_times

.tz_copy_types:
    ; Type indices start after transition times
    lea     rsi, [rdi + r14*8]  ; rsi = type indices (1 byte each)
    xor     ecx, ecx
    lea     rdx, [tz_trans_type_idx]
.tz_copy_type_loop:
    cmp     ecx, r14d
    jge     .tz_copy_ttinfos
    movzx   eax, byte [rsi + rcx]
    mov     [rdx + rcx], al
    inc     ecx
    jmp     .tz_copy_type_loop

.tz_copy_ttinfos:
    ; ttinfos start after type indices
    lea     rsi, [rsi + r14]    ; rsi = ttinfos (6 bytes each)
    ; Limit typecnt
    cmp     r15d, 16
    jle     .tz_typecnt_ok
    mov     r15d, 16
.tz_typecnt_ok:
    xor     ecx, ecx
    lea     rdx, [tz_ttinfos]
.tz_copy_ttinfo_loop:
    cmp     ecx, r15d
    jge     .tz_load_success
    ; Each ttinfo: int32 utoff (big-endian), byte dst, byte abbr_idx
    mov     eax, [rsi]
    bswap   eax
    mov     [rdx], eax          ; utoff
    movzx   eax, byte [rsi + 4]
    mov     [rdx + 4], al       ; dst
    movzx   eax, byte [rsi + 5]
    mov     [rdx + 5], al       ; abbr_idx
    add     rsi, 6
    add     rdx, 6
    inc     ecx
    jmp     .tz_copy_ttinfo_loop

.tz_parse_v1:
    ; Parse v1 TZif (4-byte transition times)
    lea     rsi, [tz_file_buf]
    mov     eax, [rsi + 32]
    bswap   eax
    mov     r14d, eax           ; timecnt
    mov     eax, [rsi + 36]
    bswap   eax
    mov     r15d, eax           ; typecnt
    mov     eax, [rsi + 28]
    bswap   eax
    mov     ebx, eax            ; leapcnt

    cmp     r14d, 256
    jle     .tz_v1_count_ok
    mov     r14d, 256
.tz_v1_count_ok:
    mov     [tz_trans_count], r14d

    lea     rdi, [rsi + 44]     ; transition times (4 bytes each)
    xor     ecx, ecx
    lea     rdx, [tz_trans_times]
.tz_v1_copy_times:
    cmp     ecx, r14d
    jge     .tz_v1_copy_types
    mov     eax, [rdi + rcx*4]
    bswap   eax
    movsxd  rax, eax            ; sign-extend 32->64
    mov     [rdx + rcx*8], rax
    inc     ecx
    jmp     .tz_v1_copy_times

.tz_v1_copy_types:
    lea     rsi, [rdi + r14*4]  ; type indices
    xor     ecx, ecx
    lea     rdx, [tz_trans_type_idx]
.tz_v1_type_loop:
    cmp     ecx, r14d
    jge     .tz_v1_ttinfos
    movzx   eax, byte [rsi + rcx]
    mov     [rdx + rcx], al
    inc     ecx
    jmp     .tz_v1_type_loop

.tz_v1_ttinfos:
    lea     rsi, [rsi + r14]
    cmp     r15d, 16
    jle     .tz_v1_typecnt_ok
    mov     r15d, 16
.tz_v1_typecnt_ok:
    xor     ecx, ecx
    lea     rdx, [tz_ttinfos]
.tz_v1_ttinfo_loop:
    cmp     ecx, r15d
    jge     .tz_load_success
    mov     eax, [rsi]
    bswap   eax
    mov     [rdx], eax
    movzx   eax, byte [rsi + 4]
    mov     [rdx + 4], al
    movzx   eax, byte [rsi + 5]
    mov     [rdx + 5], al
    add     rsi, 6
    add     rdx, 6
    inc     ecx
    jmp     .tz_v1_ttinfo_loop

.tz_load_success:
    mov     dword [tz_loaded], 1

.tz_load_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: who [OPTION]... [ FILE | ARG1 ARG2 ]", 10
    db "Print information about users who are currently logged in.", 10, 10
    db "  -a, --all         same as -b -d --login -p -r -t -T -u", 10
    db "  -b, --boot        time of last system boot", 10
    db "  -d, --dead        print dead processes", 10
    db "  -H, --heading     print line of column headings", 10
    db "  -l, --login       print system login processes", 10
    db "      --lookup      attempt to canonicalize hostnames via DNS", 10
    db "  -m                only hostname and user associated with stdin", 10
    db "  -p, --process     print active processes spawned by init", 10
    db "  -q, --count       all login names and number of users logged on", 10
    db "  -r, --runlevel    print current runlevel", 10
    db "  -s, --short       print only name, line, and time (default)", 10
    db "  -t, --time        print last system clock change", 10
    db "  -T, -w, --mesg    add user's message status as +, - or ?", 10
    db "  -u, --users       list users logged in", 10
    db "      --message     same as -T", 10
    db "      --writable    same as -T", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "If FILE is not specified, use /var/run/utmp.  /var/log/wtmp as FILE is common.", 10
    db "If ARG1 ARG2 given, -m presumed: 'am i' or 'mom likes' are usual.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/who>", 10
    db "or available locally via: info '(coreutils) who invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "who (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Joseph Arceneaux, David MacKenzie, and Michael Stone.", 10
str_version_len equ $ - str_version
; @@DATA_END@@

str_prefix:         db "who: "
str_prefix_len      equ $ - str_prefix
str_try:            db "Try 'who --help' for more information.", 10
str_try_len         equ $ - str_try
str_invalid:        db "invalid option -- '"
str_invalid_len     equ $ - str_invalid
str_unrecognized:   db "unrecognized option '"
str_unrecognized_len equ $ - str_unrecognized
str_sq_nl:          db "'", 10

str_heading:        db "NAME     LINE         TIME             COMMENT", 10
str_heading_len     equ $ - str_heading

str_boot_prefix:    db "         system boot  "
str_boot_prefix_len equ $ - str_boot_prefix

str_host_open:      db " ("
str_host_close:     db ")"

str_count_prefix:   db "# users="
str_count_prefix_len equ $ - str_count_prefix

str_help_flag:      db "--help", 0
str_version_flag:   db "--version", 0
str_boot_long:      db "--boot", 0
str_heading_long:   db "--heading", 0
str_count_long:     db "--count", 0
str_short_long:     db "--short", 0
str_utmp_path:      db "/var/run/utmp", 0
str_run_utmp_path:  db "/run/utmp", 0
str_proc_fd0:       db "/proc/self/fd/0", 0
str_dev_prefix:     db "/dev/", 0
str_am:             db "am", 0
str_i_lower:        db "i", 0
str_i_upper:        db "I", 0
str_newline:        db 10
str_space:          db " "
str_localtime:      db "/etc/localtime", 0

; Month day counts (non-leap): Jan=31, Feb=28, Mar=31, ...
month_days:     db 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

file_size equ $ - $$

; ── BSS (uninitialized, but in memory) ──
utmp_buf:       times UTMP_SIZE db 0
ts_buf:         times 20 db 0
num_buf:        times 24 db 0
char_buf:       db 0, 0
count_first:    db 0
tty_path_buf:   times 260 db 0
ami_tty_line:   dq 0

; Timezone data
tz_loaded:          dd 0        ; 0=not loaded, 1=loaded OK, 2=failed
tz_trans_count:     dd 0        ; number of transitions
tz_trans_times:     times 256 dq 0   ; transition timestamps (int64)
tz_trans_type_idx:  times 256 db 0   ; type index for each transition
tz_ttinfos:         times 96 db 0    ; up to 16 ttinfos, 6 bytes each
tz_file_buf:        times 4096 db 0  ; raw TZif file data

mem_size equ $ - $$
