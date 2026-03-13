; ============================================================
; fuptime_unified.asm — unified flat ELF64 binary
; uptime (procps-ng compatible) — x86_64 Linux
; Build: nasm -f bin unified/fuptime_unified.asm -o fuptime
; ============================================================
BITS 64
ORG 0x400000

; ── Syscall numbers ──────────────────────────────────────────
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_SYSINFO         99
%define SYS_EXIT            60
%define SYS_CLOCK_GETTIME   228
%define SYS_RT_SIGACTION    13
%define SYS_GETDENTS64      217
%define O_RDONLY             0
%define O_DIRECTORY          0x10000
%define O_NONBLOCK           0x800
%define O_CLOEXEC            0x80000
%define DT_REG               8

; ── Constants ────────────────────────────────────────────────
%define STDOUT              1
%define STDERR              2
%define CLOCK_REALTIME      0
%define SIGPIPE             13
%define SIG_IGN             1
%define SI_LOAD_SHIFT       16          ; loads scaled by 1 << 16 = 65536

; utmp entry: 384 bytes on x86_64
; ut_type at offset 0 (short = 2 bytes)
; USER_PROCESS = 7
%define UTMP_ENTRY_SIZE     384
%define UT_TYPE_OFFSET      0
%define USER_PROCESS        7

; ── ELF Header (64 bytes) ───────────────────────────────────
ehdr:
    db 0x7F, 'E', 'L', 'F'     ; magic
    db 2                         ; 64-bit
    db 1                         ; little endian
    db 1                         ; ELF version
    db 0                         ; OS/ABI: System V
    dq 0                         ; padding
    dw 2                         ; ET_EXEC
    dw 0x3E                      ; x86_64
    dd 1                         ; ELF version
    dq _start                    ; entry point
    dq phdr - $$                 ; program header offset
    dq 0                         ; section header offset (none)
    dd 0                         ; flags
    dw ehdr_size                 ; ELF header size
    dw phdr_size                 ; program header entry size
    dw 2                         ; 2 program headers
    dw 64                        ; section header entry size
    dw 0                         ; section header count
    dw 0                         ; section name index
ehdr_size equ $ - ehdr

; ── Program Headers ─────────────────────────────────────────
phdr:
    dd 1                         ; PT_LOAD
    dd 7                         ; PF_R | PF_W | PF_X
    dq 0                         ; offset
    dq $$                        ; virtual address
    dq $$                        ; physical address
    dq file_size                 ; file size
    dq mem_size                  ; memory size
    dq 0x200000                  ; alignment
phdr_size equ $ - phdr

    dd 0x6474E551                ; PT_GNU_STACK
    dd 6                         ; PF_R | PF_W (non-executable)
    dq 0, 0, 0, 0, 0
    dq 16

; ── Data Section ────────────────────────────────────────────

str_help:
    db 10
    db "Usage:", 10
    db " uptime [options]", 10
    db 10
    db "Options:", 10
    db " -p, --pretty   show uptime in pretty format", 10
    db " -h, --help     display this help and exit", 10
    db " -s, --since    system up since", 10
    db " -V, --version  output version information and exit", 10
    db 10
    db "For more details see uptime(1).", 10
str_help_len equ $ - str_help

str_version:
    db "uptime from procps-ng 4.0.4", 10
str_version_len equ $ - str_version

str_err_prefix:     db "uptime: invalid option -- '"
str_err_prefix_len  equ $ - str_err_prefix
str_err_suffix:     db "'", 10
str_err_suffix_len  equ $ - str_err_suffix
str_err_unrec:      db "uptime: unrecognized option '"
str_err_unrec_len   equ $ - str_err_unrec

str_try:
    db 10
    db "Usage:", 10
    db " uptime [options]", 10
    db 10
    db "Options:", 10
    db " -p, --pretty   show uptime in pretty format", 10
    db " -h, --help     display this help and exit", 10
    db " -s, --since    system up since", 10
    db " -V, --version  output version information and exit", 10
    db 10
    db "For more details see uptime(1).", 10
str_try_len equ $ - str_try

str_up:             db " up "
str_up_len          equ 4
str_days_comma:     db " days, "
str_days_comma_len  equ 7
str_day_comma:      db " day, "
str_day_comma_len   equ 6
str_min:            db " min,"
str_min_len         equ 5
str_comma_sp:       db ",  "
str_comma_sp_len    equ 3
str_users:          db " users,  "
str_users_len       equ 9
str_user:           db " user,  "
str_user_len        equ 8
str_load_avg:       db "load average: "
str_load_avg_len    equ 14
str_newline:        db 10

; pretty mode strings
str_pretty_up:      db "up "
str_pretty_up_len   equ 3
str_pretty_days:    db " days, "
str_pretty_days_len equ 7
str_pretty_day:     db " day, "
str_pretty_day_len  equ 6
str_pretty_hours:   db " hours, "
str_pretty_hours_len equ 8
str_pretty_hour:    db " hour, "
str_pretty_hour_len equ 7
str_pretty_minutes: db " minutes"
str_pretty_minutes_len equ 8
str_pretty_minute:  db " minute"
str_pretty_minute_len equ 7

str_proc_uptime:    db "/proc/uptime", 0
str_proc_loadavg:   db "/proc/loadavg", 0
str_var_run_utmp:   db "/var/run/utmp", 0
str_run_utmp:       db "/run/utmp", 0
str_etc_localtime:  db "/etc/localtime", 0
str_sd_sessions:    db "/run/systemd/sessions/", 0
str_sd_sessions_len equ 22
str_type_tty:       db "TYPE=tty", 10
str_type_tty_len    equ 9

str_opt_help:       db "--help", 0
str_opt_pretty:     db "--pretty", 0
str_opt_since:      db "--since", 0
str_opt_version:    db "--version", 0

days_per_month:     db 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

; ── Writable data (in flat binary) ──────────────────────────
mode:       db 0        ; 0=normal, 1=pretty, 2=since
utc_offset: dq 0        ; UTC offset in seconds (signed)

; ── Code Section ────────────────────────────────────────────

; ── asm_write: write with EINTR retry and partial write handling ──
; rdi=fd, rsi=buf, rdx=len
asm_write:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.aw_retry:
    mov     rax, SYS_WRITE
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    syscall
    cmp     rax, -4
    je      .aw_retry
    test    rax, rax
    js      .aw_done
    add     r12, rax
    sub     r13, rax
    jnz     .aw_retry
    xor     eax, eax
.aw_done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── format_2digit: al = number (0-99), returns al=tens+'0', ah=ones+'0' ──
format_2digit:
    movzx   eax, al
    push    rbx
    xor     edx, edx
    mov     ebx, 10
    div     ebx
    add     al, '0'
    add     dl, '0'
    mov     ah, dl
    pop     rbx
    ret

; ── format_number: convert unsigned integer in rax to decimal string ──
; rdi = output buffer pointer, returns length in rax
format_number:
    push    rbx
    push    rcx
    push    rdx
    push    rdi
    mov     rcx, rdi
    lea     rbx, [num_tmp + 20]
    mov     byte [rbx], 0
    test    rax, rax
    jnz     .fn_loop
    dec     rbx
    mov     byte [rbx], '0'
    jmp     .fn_copy
.fn_loop:
    xor     edx, edx
    push    rax
    mov     rax, rax
    pop     rax
    push    r8
    mov     r8, 10
    xor     edx, edx
    div     r8
    pop     r8
    add     dl, '0'
    dec     rbx
    mov     [rbx], dl
    test    rax, rax
    jnz     .fn_loop
.fn_copy:
    xor     rax, rax
.fn_copy_loop:
    mov     dl, [rbx]
    test    dl, dl
    jz      .fn_done
    mov     [rcx + rax], dl
    inc     rax
    inc     rbx
    jmp     .fn_copy_loop
.fn_done:
    pop     rdi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; ── parse_uint: parse unsigned integer from string ──
; rsi = string pointer, returns value in rax, advances rsi past digits
parse_uint:
    xor     rax, rax
    xor     rcx, rcx
.pu_loop:
    movzx   ecx, byte [rsi]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .pu_done
    imul    rax, 10
    add     rax, rcx
    inc     rsi
    jmp     .pu_loop
.pu_done:
    ret

; ── is_leap: rdi = year, returns edx = 1 if leap, 0 if not ──
is_leap:
    push    rbx
    mov     rax, rdi
    xor     edx, edx
    mov     rbx, 4
    div     rbx
    test    edx, edx
    jnz     .no
    mov     rax, rdi
    xor     edx, edx
    mov     rbx, 100
    div     rbx
    test    edx, edx
    jnz     .yes
    mov     rax, rdi
    xor     edx, edx
    mov     rbx, 400
    div     rbx
    test    edx, edx
    jnz     .no
.yes:
    mov     edx, 1
    pop     rbx
    ret
.no:
    xor     edx, edx
    pop     rbx
    ret

; ── epoch_to_local: convert epoch seconds (rdi) to YYYY-MM-DD HH:MM:SS ──
; Output written to out_buf at position [out_pos]
; This converts UTC epoch + utc_offset to local time components
; Returns: year in r8w, month in r9b, day in r10b, hour in r11b, min in r12b, sec in r13b
epoch_to_local:
    push    rbx
    push    rbp
    push    r14
    push    r15

    ; Apply UTC offset
    add     rdi, [utc_offset]

    ; Split into days and time-of-day
    mov     rax, rdi
    xor     edx, edx
    mov     rbx, 86400
    ; Handle negative times (shouldn't happen for realistic uptimes, but be safe)
    cqo
    idiv    rbx
    ; rax = days since epoch, rdx = seconds within day
    test    rdx, rdx
    jns     .etl_pos_secs
    add     rdx, 86400
    dec     rax
.etl_pos_secs:
    mov     r14, rax            ; days since epoch
    mov     r15, rdx            ; seconds within day

    ; Extract hour, minute, second
    mov     rax, r15
    xor     edx, edx
    mov     rbx, 3600
    div     rbx
    mov     r11, rax            ; hour
    mov     rax, rdx
    xor     edx, edx
    mov     rbx, 60
    div     rbx
    mov     r12, rax            ; minute
    mov     r13, rdx            ; second

    ; Convert days since epoch to year/month/day
    ; Days since 1970-01-01
    mov     rax, r14
    mov     r8, 1970            ; year counter
.etl_year_loop:
    mov     rbx, 365
    push    rax
    mov     rdi, r8
    call    is_leap
    pop     rax
    add     rbx, rdx            ; 365 or 366
    cmp     rax, rbx
    jl      .etl_year_found
    sub     rax, rbx
    inc     r8
    jmp     .etl_year_loop
.etl_year_found:
    ; rax = day of year (0-based), r8 = year
    push    rax
    mov     rdi, r8
    call    is_leap
    pop     rax
    mov     rbp, rdx            ; leap flag

    ; Find month
    lea     rsi, [days_per_month]
    xor     r9d, r9d            ; month (0-based)
.etl_month_loop:
    movzx   ebx, byte [rsi + r9]
    cmp     r9d, 1
    jne     .etl_not_feb
    add     ebx, ebp
.etl_not_feb:
    cmp     eax, ebx
    jl      .etl_month_found
    sub     eax, ebx
    inc     r9d
    cmp     r9d, 11
    jle     .etl_month_loop
.etl_month_found:
    inc     r9d                 ; month is 1-based
    inc     eax                 ; day is 1-based
    mov     r10d, eax

    pop     r14
    pop     r15
    pop     rbp
    pop     rbx
    ret

; ── get_utc_offset: parse /etc/localtime TZif to get current UTC offset ──
; Uses current epoch time from [epoch_time]
; Sets [utc_offset]
get_utc_offset:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    ; Open /etc/localtime
    mov     rax, SYS_OPEN
    lea     rdi, [str_etc_localtime]
    xor     esi, esi            ; O_RDONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .guo_done_zero      ; can't open, assume UTC
    mov     r12, rax            ; fd

    ; Read into tz_buf
    lea     rsi, [tz_buf]
    mov     rdx, 4096
.guo_read_retry:
    mov     rax, SYS_READ
    mov     rdi, r12
    syscall
    cmp     rax, -4
    je      .guo_read_retry
    mov     r13, rax            ; bytes read

    ; Close
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall

    cmp     r13, 44
    jl      .guo_done_zero      ; too small

    ; Check TZif magic
    lea     rbx, [tz_buf]
    cmp     dword [rbx], 'TZif'
    jne     .guo_done_zero

    ; Check version byte for TZif2/TZif3
    mov     al, [rbx + 4]
    cmp     al, '2'
    je      .guo_has_v2
    cmp     al, '3'
    je      .guo_has_v2
    ; V1 only - parse v1
    jmp     .guo_parse_v1

.guo_has_v2:
    ; Skip v1 section to find v2
    ; Parse v1 header counts at offset 20
    ; Counts: isutcnt(4), isstdcnt(4), leapcnt(4), timecnt(4), typecnt(4), charcnt(4)
    mov     eax, [rbx + 32]     ; timecnt (big-endian)
    bswap   eax
    mov     r14d, eax           ; v1 timecnt

    mov     eax, [rbx + 36]     ; typecnt (big-endian)
    bswap   eax
    mov     r15d, eax           ; v1 typecnt

    mov     eax, [rbx + 40]     ; charcnt (big-endian)
    bswap   eax
    mov     ebp, eax            ; v1 charcnt

    mov     eax, [rbx + 28]     ; leapcnt (big-endian)
    bswap   eax
    mov     ecx, eax            ; v1 leapcnt

    mov     eax, [rbx + 24]     ; isstdcnt
    bswap   eax
    mov     edx, eax

    mov     eax, [rbx + 20]     ; isutcnt
    bswap   eax

    ; v1 data size = timecnt*4 + timecnt*1 + typecnt*6 + charcnt + leapcnt*8 + isstdcnt + isutcnt
    ; Start of v1 data = offset 44
    push    rax                 ; save isutcnt
    push    rdx                 ; save isstdcnt

    mov     eax, r14d
    imul    eax, 5              ; timecnt * (4 + 1)
    mov     r12d, eax

    mov     eax, r15d
    imul    eax, 6              ; typecnt * 6
    add     r12d, eax

    add     r12d, ebp           ; + charcnt

    imul    ecx, 8              ; leapcnt * 8
    add     r12d, ecx

    pop     rdx                 ; isstdcnt
    add     r12d, edx

    pop     rax                 ; isutcnt
    add     r12d, eax

    add     r12d, 44            ; + header size

    ; v2 header starts at offset r12d in tz_buf
    lea     rbx, [tz_buf + r12]

    ; Verify v2 TZif magic
    cmp     dword [rbx], 'TZif'
    jne     .guo_done_zero

    ; Parse v2 counts
    mov     eax, [rbx + 32]     ; timecnt
    bswap   eax
    mov     r14d, eax           ; v2 timecnt

    mov     eax, [rbx + 36]     ; typecnt
    bswap   eax
    mov     r15d, eax           ; v2 typecnt

    ; v2 data starts at rbx + 44
    lea     rbx, [rbx + 44]     ; now points to v2 transition times

    ; Search for the last transition time <= current epoch
    mov     rax, [epoch_time]
    xor     ecx, ecx            ; index
    xor     edx, edx            ; last matching type index

    ; Default: use first ttinfo if no transition applies
    test    r14d, r14d
    jz      .guo_use_type

.guo_search_loop:
    cmp     ecx, r14d
    jge     .guo_use_type
    ; Read transition time (big-endian int64) at rbx + ecx*8
    push    rax
    mov     rax, [rbx + rcx*8]
    bswap   rax                 ; convert big-endian to little-endian
    mov     r12, rax            ; transition time
    pop     rax
    cmp     rax, r12
    jl      .guo_use_type       ; current time < this transition
    ; Get type index
    ; Type indices are at rbx + timecnt*8 + ecx
    push    rax
    lea     rax, [rbx + r14*8]
    movzx   edx, byte [rax + rcx]
    pop     rax
    inc     ecx
    jmp     .guo_search_loop

.guo_use_type:
    ; edx = type index
    ; ttinfo array at rbx + timecnt*8 + timecnt
    lea     rax, [rbx + r14*8]
    add     rax, r14            ; skip type indices
    ; Each ttinfo: int32 utoff (big-endian), uint8 dst, uint8 abbr_idx
    imul    edx, 6
    add     rax, rdx
    mov     eax, [rax]          ; utoff (big-endian)
    bswap   eax
    movsx   rax, eax            ; sign-extend to 64-bit
    mov     [utc_offset], rax
    jmp     .guo_done

.guo_parse_v1:
    ; Parse v1 directly
    mov     eax, [rbx + 32]     ; timecnt
    bswap   eax
    mov     r14d, eax

    lea     rbx, [tz_buf + 44]  ; v1 transition times (4 bytes each)
    mov     rax, [epoch_time]
    xor     ecx, ecx
    xor     edx, edx

    test    r14d, r14d
    jz      .guo_v1_use_type

.guo_v1_search:
    cmp     ecx, r14d
    jge     .guo_v1_use_type
    mov     r12d, [rbx + rcx*4]
    bswap   r12d
    movsx   r12, r12d
    cmp     rax, r12
    jl      .guo_v1_use_type
    push    rax
    lea     rax, [rbx + r14*4]
    movzx   edx, byte [rax + rcx]
    pop     rax
    inc     ecx
    jmp     .guo_v1_search

.guo_v1_use_type:
    lea     rax, [rbx + r14*4]
    add     rax, r14
    imul    edx, 6
    add     rax, rdx
    mov     eax, [rax]
    bswap   eax
    movsx   rax, eax
    mov     [utc_offset], rax
    jmp     .guo_done

.guo_done_zero:
    mov     qword [utc_offset], 0
.guo_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── count_utmp_users: count USER_PROCESS entries in utmp file ──
; Falls back to counting systemd sessions with TYPE=tty
; Returns user count in rax
count_utmp_users:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    ; Try /var/run/utmp first
    mov     rax, SYS_OPEN
    lea     rdi, [str_var_run_utmp]
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    jns     .cu_opened

    ; Try /run/utmp
    mov     rax, SYS_OPEN
    lea     rdi, [str_run_utmp]
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    jns     .cu_opened

    ; No utmp — fall back to systemd sessions
    jmp     .cu_systemd

.cu_opened:
    mov     r12, rax            ; fd
    xor     r13d, r13d          ; user count

.cu_read_loop:
    lea     rsi, [utmp_buf]
    mov     rdx, UTMP_ENTRY_SIZE
.cu_read_retry:
    mov     rax, SYS_READ
    mov     rdi, r12
    syscall
    cmp     rax, -4
    je      .cu_read_retry
    cmp     rax, UTMP_ENTRY_SIZE
    jne     .cu_read_done       ; EOF or error

    ; Check ut_type == USER_PROCESS (7)
    movzx   eax, word [utmp_buf + UT_TYPE_OFFSET]
    cmp     eax, USER_PROCESS
    jne     .cu_read_loop
    inc     r13d
    jmp     .cu_read_loop

.cu_read_done:
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall

    ; If we found utmp entries, use that count
    ; If utmp existed but had 0 users, still use 0 (file may be stale)
    mov     rax, r13
    jmp     .cu_return

.cu_systemd:
    ; Count sessions in /run/systemd/sessions/ with TYPE=tty
    ; Open directory
    mov     rax, SYS_OPEN
    lea     rdi, [str_sd_sessions]
    mov     esi, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC
    xor     edx, edx
    syscall
    test    rax, rax
    js      .cu_zero
    mov     r12, rax            ; dir fd
    xor     r13d, r13d          ; user count

.cu_getdents:
    ; Read directory entries into dirent_buf
    mov     rax, SYS_GETDENTS64
    mov     rdi, r12
    lea     rsi, [dirent_buf]
    mov     edx, 2048
    syscall
    test    rax, rax
    jle     .cu_sd_done         ; 0 = end of dir, < 0 = error
    mov     r14, rax            ; bytes returned
    xor     r15d, r15d          ; offset into buffer

.cu_dent_loop:
    cmp     r15, r14
    jge     .cu_getdents        ; read more entries

    ; struct linux_dirent64:
    ; offset 0: d_ino (8 bytes)
    ; offset 8: d_off (8 bytes)
    ; offset 16: d_reclen (2 bytes)
    ; offset 18: d_type (1 byte)
    ; offset 19: d_name (variable)
    lea     rbx, [dirent_buf + r15]
    movzx   ebp, word [rbx + 16]       ; d_reclen
    movzx   eax, byte [rbx + 18]       ; d_type

    ; Skip non-regular files (we want regular files, d_type=8)
    ; But session files might show as DT_UNKNOWN (0) on some filesystems
    ; Just check the name: skip "." and ".." and "*.ref"
    lea     rdi, [rbx + 19]            ; d_name

    ; Skip "."
    cmp     byte [rdi], '.'
    je      .cu_dent_skip

    ; Session files are pure numeric names (e.g., "13", "14")
    ; Skip any file containing non-digit characters (like "14.ref")
    ; First check: first char must be a digit
    movzx   eax, byte [rdi]
    sub     eax, '0'
    cmp     eax, 9
    ja      .cu_dent_skip              ; not a digit, skip

    ; Verify ALL chars are digits (skip names like "14.ref")
    push    rdi
    mov     rcx, rdi
.cu_check_digits:
    movzx   eax, byte [rcx]
    test    al, al
    jz      .cu_digits_ok
    sub     eax, '0'
    cmp     eax, 9
    ja      .cu_not_pure_digits
    inc     rcx
    jmp     .cu_check_digits
.cu_not_pure_digits:
    pop     rdi
    jmp     .cu_dent_skip
.cu_digits_ok:
    pop     rdi

    ; This is a numeric session file — read it and check for TYPE=tty
    ; Build path: /run/systemd/sessions/<name>
    lea     rsi, [str_sd_sessions]
    lea     rcx, [path_buf]
    xor     edx, edx
.cu_copy_base:
    mov     al, [rsi + rdx]
    test    al, al
    jz      .cu_copy_name
    mov     [rcx + rdx], al
    inc     edx
    jmp     .cu_copy_base
.cu_copy_name:
    ; Copy d_name
    lea     rsi, [rbx + 19]
    xor     eax, eax
.cu_copy_name_loop:
    mov     al, [rsi]
    mov     [rcx + rdx], al
    test    al, al
    jz      .cu_open_session
    inc     rsi
    inc     edx
    jmp     .cu_copy_name_loop

.cu_open_session:
    ; Open session file
    push    r14
    push    r15
    push    rbp
    mov     rax, SYS_OPEN
    lea     rdi, [path_buf]
    xor     esi, esi            ; O_RDONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .cu_session_done
    mov     r14, rax            ; session fd

    ; Read session file into session_buf
    lea     rsi, [session_buf]
    mov     edx, 1023
.cu_sess_read_retry:
    mov     rax, SYS_READ
    mov     rdi, r14
    syscall
    cmp     rax, -4
    je      .cu_sess_read_retry
    mov     r15, rax            ; bytes read

    ; Close session fd
    mov     rax, SYS_CLOSE
    mov     rdi, r14
    syscall

    cmp     r15, 0
    jle     .cu_session_done

    ; Null terminate
    lea     rax, [session_buf]
    mov     byte [rax + r15], 0

    ; Search for "TYPE=tty\n" in session_buf
    lea     rsi, [session_buf]
    lea     rdi, [str_type_tty]
    mov     ecx, str_type_tty_len
    call    .cu_strstr
    test    eax, eax
    jnz     .cu_found_tty

    ; Not a tty session — doesn't count
    jmp     .cu_session_done

.cu_found_tty:
    inc     r13d

.cu_session_done:
    pop     rbp
    pop     r15
    pop     r14

.cu_dent_skip:
    add     r15, rbp            ; advance by d_reclen
    jmp     .cu_dent_loop

.cu_sd_done:
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall

    mov     rax, r13
    jmp     .cu_return

.cu_zero:
    xor     eax, eax

.cu_return:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── Helper: search for needle (rdi, len ecx) in haystack (rsi, null-terminated) ──
; Returns eax=1 if found, 0 if not
.cu_strstr:
    push    rbx
    push    r8
.cu_ss_outer:
    cmp     byte [rsi], 0
    je      .cu_ss_not_found
    ; Try matching at current position
    xor     ebx, ebx
.cu_ss_inner:
    cmp     ebx, ecx
    jge     .cu_ss_found        ; matched all chars
    mov     al, [rsi + rbx]
    cmp     al, 0
    je      .cu_ss_not_found
    cmp     al, [rdi + rbx]
    jne     .cu_ss_next
    inc     ebx
    jmp     .cu_ss_inner
.cu_ss_next:
    inc     rsi
    jmp     .cu_ss_outer
.cu_ss_found:
    mov     eax, 1
    pop     r8
    pop     rbx
    ret
.cu_ss_not_found:
    xor     eax, eax
    pop     r8
    pop     rbx
    ret

; ── Entry Point ─────────────────────────────────────────────
_start:
    ; Block SIGPIPE (SIG_IGN)
    sub     rsp, 152            ; struct sigaction (sa_handler + sa_flags + sa_mask)
    mov     qword [rsp], SIG_IGN
    mov     qword [rsp + 8], 0x04000000  ; SA_RESTORER flag (needed on some kernels)
    xor     eax, eax
    lea     rdi, [rsp + 16]
    mov     ecx, 128
.clear_mask:
    mov     byte [rdi], 0
    inc     rdi
    dec     ecx
    jnz     .clear_mask
    mov     rax, SYS_RT_SIGACTION
    mov     edi, SIGPIPE
    mov     rsi, rsp
    xor     edx, edx            ; old sigaction = NULL
    mov     r10, 8              ; sigsetsize
    syscall
    add     rsp, 152

    ; Parse argc/argv
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

    mov     byte [mode], 0      ; default mode

    mov     rbx, 1              ; arg index
.parse_args:
    cmp     rbx, r14
    jge     .args_done

    mov     rdi, [r15 + rbx*8]

    ; Check for '-' prefix
    cmp     byte [rdi], '-'
    jne     .err_unrec_option

    cmp     byte [rdi + 1], '-'
    je      .long_opt

    ; Short options: -p, -s, -h, -V
    cmp     byte [rdi + 2], 0   ; must be exactly 2 chars
    jne     .err_invalid_short

    movzx   eax, byte [rdi + 1]
    cmp     al, 'p'
    je      .set_pretty
    cmp     al, 's'
    je      .set_since
    cmp     al, 'h'
    je      .do_help
    cmp     al, 'V'
    je      .do_version
    jmp     .err_invalid_short

.set_pretty:
    mov     byte [mode], 1
    inc     rbx
    jmp     .parse_args

.set_since:
    mov     byte [mode], 2
    inc     rbx
    jmp     .parse_args

.long_opt:
    ; --pretty
    push    rbx
    lea     rsi, [str_opt_pretty]
    call    str_eq
    pop     rbx
    test    eax, eax
    jnz     .set_pretty

    mov     rdi, [r15 + rbx*8]
    push    rbx
    lea     rsi, [str_opt_since]
    call    str_eq
    pop     rbx
    test    eax, eax
    jnz     .set_since

    mov     rdi, [r15 + rbx*8]
    push    rbx
    lea     rsi, [str_opt_help]
    call    str_eq
    pop     rbx
    test    eax, eax
    jnz     .do_help

    mov     rdi, [r15 + rbx*8]
    push    rbx
    lea     rsi, [str_opt_version]
    call    str_eq
    pop     rbx
    test    eax, eax
    jnz     .do_version

    ; Unrecognized long option
    mov     rdi, [r15 + rbx*8]
    jmp     .err_unrec_option

.err_invalid_short:
    ; Print: uptime: invalid option -- 'X'
    mov     rdi, STDERR
    lea     rsi, [str_err_prefix]
    mov     edx, str_err_prefix_len
    call    asm_write

    mov     rdi, [r15 + rbx*8]
    movzx   eax, byte [rdi + 1]
    mov     [char_tmp], al
    mov     rdi, STDERR
    lea     rsi, [char_tmp]
    mov     edx, 1
    call    asm_write

    mov     rdi, STDERR
    lea     rsi, [str_err_suffix]
    mov     edx, str_err_suffix_len
    call    asm_write

    mov     rdi, STDERR
    lea     rsi, [str_try]
    mov     edx, str_try_len
    call    asm_write

    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.err_unrec_option:
    ; Print: uptime: unrecognized option 'xxx'\n
    push    rdi                 ; save arg pointer
    mov     rdi, STDERR
    lea     rsi, [str_err_unrec]
    mov     edx, str_err_unrec_len
    call    asm_write

    pop     rdi
    push    rdi
    call    str_len
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDERR
    call    asm_write

    mov     rdi, STDERR
    lea     rsi, [str_err_suffix]
    mov     edx, str_err_suffix_len
    call    asm_write

    mov     rdi, STDERR
    lea     rsi, [str_try]
    mov     edx, str_try_len
    call    asm_write

    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.do_help:
    mov     rdi, STDOUT
    lea     rsi, [str_help]
    mov     edx, str_help_len
    call    asm_write
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.do_version:
    mov     rdi, STDOUT
    lea     rsi, [str_version]
    mov     edx, str_version_len
    call    asm_write
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.args_done:
    ; Get current epoch time
    sub     rsp, 16
    mov     eax, SYS_CLOCK_GETTIME
    xor     edi, edi            ; CLOCK_REALTIME
    mov     rsi, rsp
    syscall
    mov     rax, [rsp]
    mov     [epoch_time], rax
    add     rsp, 16

    ; Get UTC offset from /etc/localtime
    call    get_utc_offset

    ; Read /proc/uptime to get uptime seconds
    mov     rax, SYS_OPEN
    lea     rdi, [str_proc_uptime]
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    js      .uptime_sysinfo     ; fallback to sysinfo
    mov     r12, rax            ; fd

    lea     rsi, [proc_buf]
    mov     edx, 127
.read_uptime_retry:
    mov     rax, SYS_READ
    mov     rdi, r12
    syscall
    cmp     rax, -4
    je      .read_uptime_retry
    mov     r13, rax            ; bytes read

    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall

    ; Parse uptime seconds from proc_buf (first number before '.' or ' ')
    lea     rsi, [proc_buf]
    call    parse_uint
    mov     [uptime_secs], rax
    jmp     .have_uptime

.uptime_sysinfo:
    ; Fallback: use sysinfo syscall
    lea     rdi, [sysinfo_buf]
    mov     eax, SYS_SYSINFO
    syscall
    mov     rax, [sysinfo_buf]  ; uptime at offset 0
    mov     [uptime_secs], rax

.have_uptime:
    ; Branch on mode
    cmp     byte [mode], 2
    je      .mode_since
    cmp     byte [mode], 1
    je      .mode_pretty

    ; ── Normal mode ─────────────────────────────────────────
    ; Format: " HH:MM:SS up N days, HH:MM,  N user(s),  load average: X.XX, X.XX, X.XX"
    lea     rdi, [out_buf]
    xor     ecx, ecx            ; position in out_buf

    ; Leading space
    mov     byte [rdi + rcx], ' '
    inc     ecx

    ; Current local time HH:MM:SS
    push    rcx
    push    rdi
    mov     rdi, [epoch_time]
    call    epoch_to_local
    pop     rdi
    pop     rcx
    ; r11b=hour, r12b=min, r13b=sec

    mov     al, r11b
    push    rcx
    call    format_2digit
    pop     rcx
    mov     [rdi + rcx], al
    inc     ecx
    mov     [rdi + rcx], ah
    inc     ecx
    mov     byte [rdi + rcx], ':'
    inc     ecx

    mov     al, r12b
    push    rcx
    call    format_2digit
    pop     rcx
    mov     [rdi + rcx], al
    inc     ecx
    mov     [rdi + rcx], ah
    inc     ecx
    mov     byte [rdi + rcx], ':'
    inc     ecx

    mov     al, r13b
    push    rcx
    call    format_2digit
    pop     rcx
    mov     [rdi + rcx], al
    inc     ecx
    mov     [rdi + rcx], ah
    inc     ecx

    ; " up "
    mov     byte [rdi + rcx], ' '
    inc     ecx
    mov     byte [rdi + rcx], 'u'
    inc     ecx
    mov     byte [rdi + rcx], 'p'
    inc     ecx

    ; Format uptime
    mov     rax, [uptime_secs]

    ; Calculate days, hours, minutes
    xor     edx, edx
    mov     rbx, 86400
    div     rbx
    mov     r8, rax             ; days
    mov     rax, rdx
    xor     edx, edx
    mov     rbx, 3600
    div     rbx
    mov     r9, rax             ; hours
    mov     rax, rdx
    xor     edx, edx
    mov     rbx, 60
    div     rbx
    mov     r10, rax            ; minutes

    ; If days > 0: " N day(s), HH:MM,"
    ; If days == 0 and hours > 0: "  HH:MM,"
    ; If days == 0 and hours == 0: "  N min,"
    test    r8, r8
    jz      .normal_no_days

    ; " N day(s), "
    mov     byte [rdi + rcx], ' '
    inc     ecx

    push    rcx
    push    rdi
    mov     rax, r8
    lea     rdi, [rdi + rcx]
    call    format_number
    pop     rdi
    pop     rcx
    add     ecx, eax

    cmp     r8, 1
    je      .normal_one_day
    ; " days, "
    push    rsi
    lea     rsi, [str_days_comma]
    mov     edx, str_days_comma_len
    call    .copy_str
    pop     rsi
    jmp     .normal_after_days

.normal_one_day:
    push    rsi
    lea     rsi, [str_day_comma]
    mov     edx, str_day_comma_len
    call    .copy_str
    pop     rsi

.normal_after_days:
    ; HH:MM, (no leading space - "days, " already has trailing space)
    mov     al, r9b
    push    rcx
    call    format_2digit
    pop     rcx
    mov     [rdi + rcx], al
    inc     ecx
    mov     [rdi + rcx], ah
    inc     ecx
    mov     byte [rdi + rcx], ':'
    inc     ecx
    mov     al, r10b
    push    rcx
    call    format_2digit
    pop     rcx
    mov     [rdi + rcx], al
    inc     ecx
    mov     [rdi + rcx], ah
    inc     ecx
    mov     byte [rdi + rcx], ','
    inc     ecx

    jmp     .normal_users

.normal_no_days:
    ; No days
    test    r9, r9
    jz      .normal_just_minutes
    jnz     .normal_hours_mins

.normal_hours_mins:
    ; "  HH:MM,"
    mov     byte [rdi + rcx], ' '
    inc     ecx
    mov     byte [rdi + rcx], ' '
    inc     ecx
    mov     al, r9b
    push    rcx
    call    format_2digit
    pop     rcx
    mov     [rdi + rcx], al
    inc     ecx
    mov     [rdi + rcx], ah
    inc     ecx
    mov     byte [rdi + rcx], ':'
    inc     ecx
    mov     al, r10b
    push    rcx
    call    format_2digit
    pop     rcx
    mov     [rdi + rcx], al
    inc     ecx
    mov     [rdi + rcx], ah
    inc     ecx
    mov     byte [rdi + rcx], ','
    inc     ecx

    jmp     .normal_users

.normal_just_minutes:
    ; "  N min,"
    mov     byte [rdi + rcx], ' '
    inc     ecx
    mov     byte [rdi + rcx], ' '
    inc     ecx

    push    rcx
    push    rdi
    mov     rax, r10
    lea     rdi, [rdi + rcx]
    call    format_number
    pop     rdi
    pop     rcx
    add     ecx, eax

    push    rsi
    lea     rsi, [str_min]
    mov     edx, str_min_len
    call    .copy_str
    pop     rsi

.normal_users:
    ; "  N user(s),  "
    mov     byte [rdi + rcx], ' '
    inc     ecx
    mov     byte [rdi + rcx], ' '
    inc     ecx

    ; Count users
    push    rcx
    push    rdi
    call    count_utmp_users
    pop     rdi
    pop     rcx
    mov     r8, rax             ; user count

    push    rcx
    push    rdi
    mov     rax, r8
    lea     rdi, [rdi + rcx]
    call    format_number
    pop     rdi
    pop     rcx
    add     ecx, eax

    cmp     r8, 1
    je      .normal_one_user
    push    rsi
    lea     rsi, [str_users]
    mov     edx, str_users_len
    call    .copy_str
    pop     rsi
    jmp     .normal_load

.normal_one_user:
    push    rsi
    lea     rsi, [str_user]
    mov     edx, str_user_len
    call    .copy_str
    pop     rsi

.normal_load:
    ; "load average: "
    push    rsi
    lea     rsi, [str_load_avg]
    mov     edx, str_load_avg_len
    call    .copy_str
    pop     rsi

    ; Read /proc/loadavg
    push    rcx
    push    rdi
    call    .read_loadavg
    pop     rdi
    pop     rcx

    ; Parse and format 3 load averages from proc_buf
    ; Format: "X.XX X.XX X.XX ..."
    lea     rsi, [proc_buf]

    ; First load average
    call    .copy_loadavg_field
    mov     byte [rdi + rcx], ','
    inc     ecx
    mov     byte [rdi + rcx], ' '
    inc     ecx

    ; Skip space in proc_buf
    cmp     byte [rsi], ' '
    jne     .la2
    inc     rsi
.la2:
    ; Second load average
    call    .copy_loadavg_field
    mov     byte [rdi + rcx], ','
    inc     ecx
    mov     byte [rdi + rcx], ' '
    inc     ecx

    cmp     byte [rsi], ' '
    jne     .la3
    inc     rsi
.la3:
    ; Third load average
    call    .copy_loadavg_field

    ; Newline
    mov     byte [rdi + rcx], 10
    inc     ecx

    ; Write output
    mov     rdx, rcx
    lea     rsi, [out_buf]
    mov     edi, STDOUT
    call    asm_write

    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

; ── Helper: copy string from rsi, length edx, to rdi+ecx, advance ecx ──
.copy_str:
    push    rbx
    xor     ebx, ebx
.cs_loop:
    cmp     ebx, edx
    jge     .cs_done
    mov     al, [rsi + rbx]
    mov     [rdi + rcx], al
    inc     ecx
    inc     ebx
    jmp     .cs_loop
.cs_done:
    pop     rbx
    ret

; ── Helper: copy one loadavg field (X.XX) from [rsi] to [rdi+ecx] ──
; Advances rsi past the field, advances ecx
.copy_loadavg_field:
.clf_loop:
    mov     al, [rsi]
    cmp     al, ' '
    je      .clf_done
    cmp     al, 10
    je      .clf_done
    cmp     al, 0
    je      .clf_done
    mov     [rdi + rcx], al
    inc     ecx
    inc     rsi
    jmp     .clf_loop
.clf_done:
    ret

; ── Helper: read /proc/loadavg into proc_buf ──
.read_loadavg:
    mov     rax, SYS_OPEN
    lea     rdi, [str_proc_loadavg]
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    js      .rl_zero
    mov     r12, rax

    lea     rsi, [proc_buf]
    mov     edx, 127
.rl_retry:
    mov     rax, SYS_READ
    mov     rdi, r12
    syscall
    cmp     rax, -4
    je      .rl_retry
    mov     r13, rax

    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall

    ; Null-terminate
    lea     rax, [proc_buf]
    mov     byte [rax + r13], 0
    ret

.rl_zero:
    ; Zero out loadavg buffer
    lea     rdi, [proc_buf]
    mov     byte [rdi], '0'
    mov     byte [rdi + 1], '.'
    mov     byte [rdi + 2], '0'
    mov     byte [rdi + 3], '0'
    mov     byte [rdi + 4], ' '
    mov     byte [rdi + 5], '0'
    mov     byte [rdi + 6], '.'
    mov     byte [rdi + 7], '0'
    mov     byte [rdi + 8], '0'
    mov     byte [rdi + 9], ' '
    mov     byte [rdi + 10], '0'
    mov     byte [rdi + 11], '.'
    mov     byte [rdi + 12], '0'
    mov     byte [rdi + 13], '0'
    mov     byte [rdi + 14], 0
    ret

; ── Pretty mode ─────────────────────────────────────────────
; Format: "up N day(s), N hour(s), N minute(s)"
.mode_pretty:
    lea     rdi, [out_buf]
    xor     ecx, ecx

    ; "up "
    mov     byte [rdi + rcx], 'u'
    inc     ecx
    mov     byte [rdi + rcx], 'p'
    inc     ecx
    mov     byte [rdi + rcx], ' '
    inc     ecx

    ; Calculate days, hours, minutes
    mov     rax, [uptime_secs]
    xor     edx, edx
    mov     rbx, 86400
    div     rbx
    mov     r8, rax             ; days
    mov     rax, rdx
    xor     edx, edx
    mov     rbx, 3600
    div     rbx
    mov     r9, rax             ; hours
    mov     rax, rdx
    xor     edx, edx
    mov     rbx, 60
    div     rbx
    mov     r10, rax            ; minutes

    ; Days
    test    r8, r8
    jz      .pretty_no_days

    push    rcx
    push    rdi
    mov     rax, r8
    lea     rdi, [rdi + rcx]
    call    format_number
    pop     rdi
    pop     rcx
    add     ecx, eax

    cmp     r8, 1
    je      .pretty_one_day
    push    rsi
    lea     rsi, [str_pretty_days]
    mov     edx, str_pretty_days_len
    call    .copy_str
    pop     rsi
    jmp     .pretty_check_hours
.pretty_one_day:
    push    rsi
    lea     rsi, [str_pretty_day]
    mov     edx, str_pretty_day_len
    call    .copy_str
    pop     rsi

.pretty_check_hours:
    ; Hours
    test    r9, r9
    jz      .pretty_no_hours_after_days

    push    rcx
    push    rdi
    mov     rax, r9
    lea     rdi, [rdi + rcx]
    call    format_number
    pop     rdi
    pop     rcx
    add     ecx, eax

    cmp     r9, 1
    je      .pretty_one_hour
    push    rsi
    lea     rsi, [str_pretty_hours]
    mov     edx, str_pretty_hours_len
    call    .copy_str
    pop     rsi
    jmp     .pretty_check_mins
.pretty_one_hour:
    push    rsi
    lea     rsi, [str_pretty_hour]
    mov     edx, str_pretty_hour_len
    call    .copy_str
    pop     rsi

.pretty_check_mins:
    ; Minutes
    push    rcx
    push    rdi
    mov     rax, r10
    lea     rdi, [rdi + rcx]
    call    format_number
    pop     rdi
    pop     rcx
    add     ecx, eax

    cmp     r10, 1
    je      .pretty_one_minute
    push    rsi
    lea     rsi, [str_pretty_minutes]
    mov     edx, str_pretty_minutes_len
    call    .copy_str
    pop     rsi
    jmp     .pretty_done

.pretty_one_minute:
    push    rsi
    lea     rsi, [str_pretty_minute]
    mov     edx, str_pretty_minute_len
    call    .copy_str
    pop     rsi
    jmp     .pretty_done

.pretty_no_hours_after_days:
    ; Days but no hours - still show minutes
    push    rcx
    push    rdi
    mov     rax, r10
    lea     rdi, [rdi + rcx]
    call    format_number
    pop     rdi
    pop     rcx
    add     ecx, eax

    cmp     r10, 1
    je      .pretty_one_minute2
    push    rsi
    lea     rsi, [str_pretty_minutes]
    mov     edx, str_pretty_minutes_len
    call    .copy_str
    pop     rsi
    jmp     .pretty_done
.pretty_one_minute2:
    push    rsi
    lea     rsi, [str_pretty_minute]
    mov     edx, str_pretty_minute_len
    call    .copy_str
    pop     rsi
    jmp     .pretty_done

.pretty_no_days:
    ; No days - check hours
    test    r9, r9
    jz      .pretty_only_minutes

    push    rcx
    push    rdi
    mov     rax, r9
    lea     rdi, [rdi + rcx]
    call    format_number
    pop     rdi
    pop     rcx
    add     ecx, eax

    cmp     r9, 1
    je      .pretty_one_hour2
    push    rsi
    lea     rsi, [str_pretty_hours]
    mov     edx, str_pretty_hours_len
    call    .copy_str
    pop     rsi
    jmp     .pretty_check_mins
.pretty_one_hour2:
    push    rsi
    lea     rsi, [str_pretty_hour]
    mov     edx, str_pretty_hour_len
    call    .copy_str
    pop     rsi
    jmp     .pretty_check_mins

.pretty_only_minutes:
    push    rcx
    push    rdi
    mov     rax, r10
    lea     rdi, [rdi + rcx]
    call    format_number
    pop     rdi
    pop     rcx
    add     ecx, eax

    cmp     r10, 1
    je      .pretty_one_minute3
    push    rsi
    lea     rsi, [str_pretty_minutes]
    mov     edx, str_pretty_minutes_len
    call    .copy_str
    pop     rsi
    jmp     .pretty_done
.pretty_one_minute3:
    push    rsi
    lea     rsi, [str_pretty_minute]
    mov     edx, str_pretty_minute_len
    call    .copy_str
    pop     rsi

.pretty_done:
    mov     byte [rdi + rcx], 10
    inc     ecx

    mov     rdx, rcx
    lea     rsi, [out_buf]
    mov     edi, STDOUT
    call    asm_write

    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

; ── Since mode ──────────────────────────────────────────────
; Format: "YYYY-MM-DD HH:MM:SS"
.mode_since:
    ; Calculate boot time = epoch - uptime
    mov     rax, [epoch_time]
    sub     rax, [uptime_secs]
    mov     rdi, rax
    call    epoch_to_local
    ; r8w=year, r9b=month, r10b=day, r11b=hour, r12b=min, r13b=sec

    lea     rdi, [out_buf]
    xor     ecx, ecx

    ; Year (4 digits)
    movzx   eax, r8w
    call    .format_4digit_to_buf

    mov     byte [rdi + rcx], '-'
    inc     ecx

    ; Month
    mov     al, r9b
    push    rcx
    call    format_2digit
    pop     rcx
    mov     [rdi + rcx], al
    inc     ecx
    mov     [rdi + rcx], ah
    inc     ecx

    mov     byte [rdi + rcx], '-'
    inc     ecx

    ; Day
    mov     al, r10b
    push    rcx
    call    format_2digit
    pop     rcx
    mov     [rdi + rcx], al
    inc     ecx
    mov     [rdi + rcx], ah
    inc     ecx

    mov     byte [rdi + rcx], ' '
    inc     ecx

    ; Hour
    mov     al, r11b
    push    rcx
    call    format_2digit
    pop     rcx
    mov     [rdi + rcx], al
    inc     ecx
    mov     [rdi + rcx], ah
    inc     ecx

    mov     byte [rdi + rcx], ':'
    inc     ecx

    ; Minute
    mov     al, r12b
    push    rcx
    call    format_2digit
    pop     rcx
    mov     [rdi + rcx], al
    inc     ecx
    mov     [rdi + rcx], ah
    inc     ecx

    mov     byte [rdi + rcx], ':'
    inc     ecx

    ; Second
    mov     al, r13b
    push    rcx
    call    format_2digit
    pop     rcx
    mov     [rdi + rcx], al
    inc     ecx
    mov     [rdi + rcx], ah
    inc     ecx

    mov     byte [rdi + rcx], 10
    inc     ecx

    mov     rdx, rcx
    lea     rsi, [out_buf]
    mov     edi, STDOUT
    call    asm_write

    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

; ── format_4digit_to_buf: format eax (0-9999) as 4 digits at rdi+ecx ──
.format_4digit_to_buf:
    push    rbx
    push    rdx

    xor     edx, edx
    mov     ebx, 1000
    div     ebx
    add     al, '0'
    mov     [rdi + rcx], al
    inc     ecx

    mov     eax, edx
    xor     edx, edx
    mov     ebx, 100
    div     ebx
    add     al, '0'
    mov     [rdi + rcx], al
    inc     ecx

    mov     eax, edx
    xor     edx, edx
    mov     ebx, 10
    div     ebx
    add     al, '0'
    mov     [rdi + rcx], al
    inc     ecx

    add     dl, '0'
    mov     [rdi + rcx], dl
    inc     ecx

    pop     rdx
    pop     rbx
    ret

; ── str_eq: compare null-terminated strings rdi and rsi ──
; Returns eax=1 if equal, 0 if not
str_eq:
    xor     ecx, ecx
.se_loop:
    mov     al, [rdi + rcx]
    mov     dl, [rsi + rcx]
    cmp     al, dl
    jne     .se_ne
    test    al, al
    jz      .se_eq
    inc     ecx
    jmp     .se_loop
.se_eq:
    mov     eax, 1
    ret
.se_ne:
    xor     eax, eax
    ret

; ── str_len: get length of null-terminated string at rdi ──
str_len:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; ── File size marker ────────────────────────────────────────
file_size equ $ - $$

; ── Writable buffers (in-file, part of mem_size) ────────────
epoch_time:     dq 0
uptime_secs:    dq 0
out_buf:        times 512 db 0
num_tmp:        times 32  db 0
proc_buf:       times 128 db 0
sysinfo_buf:    times 128 db 0
utmp_buf:       times 384  db 0
tz_buf:         times 4096 db 0
dirent_buf:     times 2048 db 0
path_buf:       times 256  db 0
session_buf:    times 1024 db 0
char_tmp:       db 0, 0

mem_size equ $ - $$
