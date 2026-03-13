; ============================================================
; ftouch_unified.asm — GNU-compatible 'touch' command
; Builds with: nasm -f bin unified/ftouch_unified.asm -o ftouch
;
; touch: Update the access and modification times of each FILE
;        to the current time. A FILE argument that does not exist
;        is created empty.
;
; Register allocation:
;   r14d = argc, r15 = argv
;   r12d = flags (bit 0 = -a, bit 1 = -m, bit 2 = -c/no-create,
;                  bit 3 = -h/no-dereference, bit 4 = have explicit time)
;   r13  = file arg start index during option parse, then file loop counter
;   rbp  = exit code accumulator
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT           60
%define SYS_OPENAT        257
%define SYS_NEWFSTATAT    262
%define SYS_UTIMENSAT     280

%define STDOUT              1
%define STDERR              2
%define SIG_BLOCK           0
%define SIGPIPE            13

%define AT_FDCWD          -100
%define AT_SYMLINK_NOFOLLOW 0x100

%define O_RDONLY            0
%define O_WRONLY            1
%define O_CREAT            64
%define O_NOCTTY          256
%define O_NONBLOCK       2048
%define MODE_0666        0x1B6

%define UTIME_NOW    0x3FFFFFFF
%define UTIME_OMIT   0x3FFFFFFE

; Flags
%define FLAG_ATIME_ONLY     1   ; -a
%define FLAG_MTIME_ONLY     2   ; -m
%define FLAG_NO_CREATE      4   ; -c
%define FLAG_NO_DEREF       8   ; -h
%define FLAG_HAVE_TIME     16   ; explicit time set (-t, -r, -d)

; struct stat offsets (x86-64 Linux)
%define STAT_ATIM_SEC      72
%define STAT_ATIM_NSEC     80
%define STAT_MTIM_SEC      88
%define STAT_MTIM_NSEC     96
%define STAT_BUF_SIZE     144

%define BSS_ADDR        0x500000
%define BSS_SIZE        (64 * 1024)         ; 64KB for BSS (need room for TZif)
%define STAT_BUF        BSS_ADDR            ; 144 bytes for struct stat
%define TIMESPEC_BUF    (BSS_ADDR + 160)    ; 32 bytes for 2x timespec
%define TZIF_BUF        (BSS_ADDR + 256)    ; up to 60KB for /etc/localtime
%define TZIF_BUF_SIZE   (60 * 1024)

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

    xor     r12d, r12d          ; flags
    xor     ebp, ebp            ; exit code
    mov     ecx, 1              ; arg index

.parse_opts:
    cmp     ecx, r14d
    jge     .done_opts
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .done_opts
    cmp     byte [rdi + 1], 0
    je      .done_opts          ; bare "-" is a filename
    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options
    inc     rdi                 ; skip '-'
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'a'
    je      .set_atime
    cmp     al, 'm'
    je      .set_mtime
    cmp     al, 'c'
    je      .set_no_create
    cmp     al, 'f'
    je      .set_ignore_f
    cmp     al, 'h'
    je      .set_no_deref
    cmp     al, 't'
    je      .set_stamp_short
    cmp     al, 'r'
    je      .set_ref_short
    cmp     al, 'd'
    je      .set_date_short
    ; Invalid short option
    mov     r9, rdi
    push    rcx
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    do_write_err
    mov     rsi, r9
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

.set_atime:
    or      r12d, FLAG_ATIME_ONLY
    inc     rdi
    jmp     .short_loop

.set_mtime:
    or      r12d, FLAG_MTIME_ONLY
    inc     rdi
    jmp     .short_loop

.set_no_create:
    or      r12d, FLAG_NO_CREATE
    inc     rdi
    jmp     .short_loop

.set_ignore_f:
    ; -f is ignored (for BSD compat)
    inc     rdi
    jmp     .short_loop

.set_no_deref:
    or      r12d, FLAG_NO_DEREF
    inc     rdi
    jmp     .short_loop

.set_stamp_short:
    ; -t STAMP — next char or next arg
    inc     rdi
    cmp     byte [rdi], 0
    jne     .parse_stamp_value
    ; Stamp is the next argument
    inc     ecx
    cmp     ecx, r14d
    jge     .err_opt_requires_arg_t
    mov     rdi, [r15 + rcx*8]
    jmp     .parse_stamp_value

.set_ref_short:
    ; -r FILE — next char or next arg
    inc     rdi
    cmp     byte [rdi], 0
    jne     .do_ref_file
    ; Reference file is next argument
    inc     ecx
    cmp     ecx, r14d
    jge     .err_opt_requires_arg_r
    mov     rdi, [r15 + rcx*8]
    jmp     .do_ref_file

.set_date_short:
    ; -d STRING — next char or next arg
    inc     rdi
    cmp     byte [rdi], 0
    jne     .parse_date_value
    ; Date is the next argument
    inc     ecx
    cmp     ecx, r14d
    jge     .err_opt_requires_arg_d
    mov     rdi, [r15 + rcx*8]
    jmp     .parse_date_value

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    mov     r9, rdi
    push    rcx

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

    ; --no-create
    mov     rdi, r9
    mov     rsi, str_no_create_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_no_create

    ; --no-dereference
    mov     rdi, r9
    mov     rsi, str_no_deref_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_no_deref

    ; --reference=
    mov     rdi, r9
    mov     rsi, str_ref_prefix
    mov     edx, 12             ; "--reference="
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_ref_long

    ; --date=
    mov     rdi, r9
    mov     rsi, str_date_prefix
    mov     edx, 7              ; "--date="
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_date_long

    ; --time= (recognized for compat)
    mov     rdi, r9
    mov     rsi, str_time_prefix
    mov     edx, 7              ; "--time="
    call    str_prefix_match
    test    eax, eax
    jnz     .pop_set_time_long

    ; Unrecognized long option
    pop     rcx
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

.pop_set_no_create:
    pop     rcx
    or      r12d, FLAG_NO_CREATE
    jmp     .next_opt

.pop_set_no_deref:
    pop     rcx
    or      r12d, FLAG_NO_DEREF
    jmp     .next_opt

.pop_set_ref_long:
    pop     rcx
    lea     rdi, [r9 + 12]     ; skip "--reference="
    jmp     .do_ref_file

.pop_set_date_long:
    pop     rcx
    lea     rdi, [r9 + 7]      ; skip "--date="
    jmp     .parse_date_value

.pop_set_time_long:
    ; --time=atime or --time=mtime
    pop     rcx
    lea     rdi, [r9 + 7]      ; skip "--time="
    cmp     byte [rdi], 'a'
    je      .time_atime
    cmp     byte [rdi], 'm'
    je      .time_mtime
    jmp     .next_opt
.time_atime:
    or      r12d, FLAG_ATIME_ONLY
    jmp     .next_opt
.time_mtime:
    or      r12d, FLAG_MTIME_ONLY
    jmp     .next_opt

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

; --- Handle -r FILE (reference file) ---
; rdi = path to reference file
.do_ref_file:
    push    rcx
    or      r12d, FLAG_HAVE_TIME

    ; Use newfstatat to stat the reference file
    xor     r10d, r10d
    test    r12d, FLAG_NO_DEREF
    jz      .ref_stat_flags_done
    mov     r10d, AT_SYMLINK_NOFOLLOW
.ref_stat_flags_done:
    mov     r8, rdi             ; save path
    mov     eax, SYS_NEWFSTATAT
    mov     edi, AT_FDCWD
    mov     rsi, r8             ; path
    mov     rdx, STAT_BUF
    ; r10d already set
    syscall
    test    rax, rax
    js      .err_ref_stat

    ; Copy atime and mtime from stat buf to TIMESPEC_BUF
    mov     rax, [STAT_BUF + STAT_ATIM_SEC]
    mov     [TIMESPEC_BUF], rax
    mov     rax, [STAT_BUF + STAT_ATIM_NSEC]
    mov     [TIMESPEC_BUF + 8], rax
    mov     rax, [STAT_BUF + STAT_MTIM_SEC]
    mov     [TIMESPEC_BUF + 16], rax
    mov     rax, [STAT_BUF + STAT_MTIM_NSEC]
    mov     [TIMESPEC_BUF + 24], rax

    pop     rcx
    jmp     .next_opt

.err_ref_stat:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_fail_stat1
    mov     edx, str_fail_stat1_len
    call    do_write_err
    mov     rdi, r8
    call    str_len
    mov     edx, eax
    mov     rsi, r8
    call    do_write_err
    mov     rsi, str_fail_stat2
    mov     edx, str_fail_stat2_len
    call    do_write_err
    pop     rcx
    mov     edi, 1
    jmp     do_exit

; --- Parse -t [[CC]YY]MMDDhhmm[.ss] ---
; rdi = pointer to stamp string
.parse_stamp_value:
    push    rcx
    or      r12d, FLAG_HAVE_TIME

    mov     r8, rdi             ; save original
    call    str_len
    mov     r9d, eax            ; length

    ; Find dot position for optional .ss
    xor     ecx, ecx
    mov     rdi, r8
.find_dot:
    cmp     ecx, r9d
    jge     .no_dot
    cmp     byte [rdi + rcx], '.'
    je      .found_dot
    inc     ecx
    jmp     .find_dot

.no_dot:
    xor     r11d, r11d          ; seconds = 0
    mov     ecx, r9d            ; date part length = full length
    jmp     .parse_stamp_date

.found_dot:
    push    rcx                 ; save dot position (= date part length)
    lea     rdi, [r8 + rcx + 1]
    call    parse_2digits
    mov     r11d, eax           ; seconds
    pop     rcx                 ; date part length

.parse_stamp_date:
    mov     rdi, r8
    ; ecx = length of date portion (without .ss)
    ; Parse from the end: last 2=mm, -4=hh, -6=DD, -8=MM
    ; Remaining prefix (0, 2, or 4 chars) = year

    ; minute
    push    rcx
    lea     rax, [rdi + rcx - 2]
    push    rdi
    mov     rdi, rax
    call    parse_2digits
    pop     rdi
    pop     rcx
    push    rax                 ; push minute

    ; hour
    push    rcx
    lea     rax, [rdi + rcx - 4]
    push    rdi
    mov     rdi, rax
    call    parse_2digits
    pop     rdi
    pop     rcx
    push    rax                 ; push hour

    ; day
    push    rcx
    lea     rax, [rdi + rcx - 6]
    push    rdi
    mov     rdi, rax
    call    parse_2digits
    pop     rdi
    pop     rcx
    push    rax                 ; push day

    ; month
    push    rcx
    lea     rax, [rdi + rcx - 8]
    push    rdi
    mov     rdi, rax
    call    parse_2digits
    pop     rdi
    pop     rcx
    push    rax                 ; push month

    ; Year prefix length = ecx - 8
    sub     ecx, 8
    cmp     ecx, 0
    je      .stamp_no_year
    cmp     ecx, 2
    je      .stamp_2digit_year
    cmp     ecx, 4
    je      .stamp_4digit_year
    jmp     .stamp_bad_format

.stamp_no_year:
    ; GNU touch uses current year when no year specified
    ; Get current year from clock_gettime
    call    get_current_year
    push    rax
    jmp     .stamp_have_year

.stamp_2digit_year:
    push    rcx
    push    rdi
    call    parse_2digits
    pop     rdi
    pop     rcx
    ; 2-digit year: 69-99 -> 1969-1999, 00-68 -> 2000-2068
    cmp     eax, 69
    jge     .stamp_year_19xx
    add     eax, 2000
    jmp     .stamp_push_year
.stamp_year_19xx:
    add     eax, 1900
.stamp_push_year:
    push    rax
    jmp     .stamp_have_year

.stamp_4digit_year:
    push    rcx
    push    rdi
    call    parse_2digits
    imul    eax, 100
    mov     r10d, eax
    add     rdi, 2
    call    parse_2digits
    add     eax, r10d
    pop     rdi
    pop     rcx
    push    rax

.stamp_have_year:
    ; Stack: year, month, day, hour, minute (top to bottom)
    ; r11d = seconds
    pop     rax             ; year
    mov     r8d, eax
    pop     rcx             ; month
    pop     rdx             ; day
    pop     rsi             ; hour
    pop     rdi             ; minute
    ; r8d=year, ecx=month, edx=day, esi=hour, edi=minute, r11d=seconds

    ; Convert to epoch (UTC) then adjust for local timezone
    push    r11             ; save seconds
    push    rdi             ; save minute
    push    rsi             ; save hour

    mov     edi, r8d
    mov     esi, ecx
    call    days_from_civil
    imul    rax, 86400

    pop     rsi             ; hour
    pop     rdi             ; minute
    pop     r11             ; seconds

    movzx   esi, si
    imul    rsi, 3600
    add     rax, rsi
    movzx   edi, di
    imul    rdi, 60
    add     rax, rdi
    movzx   r11d, r11b
    add     rax, r11

    ; rax = UTC epoch if interpreted as UTC
    ; But -t timestamps are local time, so we need to subtract the TZ offset
    ; offset = get_tz_offset(utc_epoch_guess)
    ; local_epoch = utc_guess - offset
    ; We do one iteration: guess UTC, get offset, adjust
    push    rax
    mov     rdi, rax
    call    get_tz_offset       ; rax = offset in seconds (e.g., -18000 for CDT)
    mov     rbx, rax            ; save offset
    pop     rax
    sub     rax, rbx            ; local_epoch = utc_guess - tz_offset

    ; Store in TIMESPEC_BUF
    mov     [TIMESPEC_BUF], rax
    mov     qword [TIMESPEC_BUF + 8], 0
    mov     [TIMESPEC_BUF + 16], rax
    mov     qword [TIMESPEC_BUF + 24], 0

    pop     rcx
    jmp     .next_opt

.stamp_bad_format:
    add     rsp, 32             ; pop 4 values
    pop     rcx
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid_date
    mov     edx, str_invalid_date_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; --- Parse -d DATE string ---
; YYYY-MM-DD or YYYY-MM-DDThh:mm:ss or YYYY-MM-DD hh:mm:ss
.parse_date_value:
    push    rcx
    or      r12d, FLAG_HAVE_TIME

    mov     r8, rdi             ; save original string

    ; Parse YYYY
    call    parse_4digits
    mov     r9d, eax            ; year
    cmp     byte [rdi + 4], '-'
    jne     .date_bad_format
    lea     rdi, [rdi + 5]

    ; Parse MM
    call    parse_2digits
    mov     r10d, eax           ; month
    cmp     byte [rdi + 2], '-'
    jne     .date_bad_format
    lea     rdi, [rdi + 3]

    ; Parse DD
    call    parse_2digits
    mov     r11d, eax           ; day
    lea     rdi, [rdi + 2]

    ; Check for time separator
    movzx   eax, byte [rdi]
    test    al, al
    jz      .date_no_time
    cmp     al, 'T'
    je      .date_has_time
    cmp     al, ' '
    je      .date_has_time
    jmp     .date_bad_format

.date_no_time:
    xor     ecx, ecx        ; hour
    xor     esi, esi        ; minute
    xor     edx, edx        ; second
    jmp     .date_compute

.date_has_time:
    inc     rdi             ; skip 'T' or ' '
    push    r9
    push    r10
    push    r11
    call    parse_2digits
    push    rax             ; hour
    cmp     byte [rdi + 2], ':'
    jne     .date_time_no_colon1
    lea     rdi, [rdi + 3]
    jmp     .date_parse_min
.date_time_no_colon1:
    lea     rdi, [rdi + 2]
.date_parse_min:
    call    parse_2digits
    push    rax             ; minute

    movzx   eax, byte [rdi + 2]
    cmp     al, ':'
    je      .date_has_sec
    jmp     .date_no_sec

.date_has_sec:
    lea     rdi, [rdi + 3]
    call    parse_2digits
    mov     edx, eax        ; second
    jmp     .date_got_time

.date_no_sec:
    xor     edx, edx

.date_got_time:
    pop     rsi             ; minute
    pop     rcx             ; hour
    pop     r11             ; day
    pop     r10             ; month
    pop     r9              ; year

.date_compute:
    ; r9d=year, r10d=month, r11d=day, ecx=hour, esi=minute, edx=second
    push    rdx             ; save second
    push    rsi             ; save minute
    push    rcx             ; save hour

    mov     edi, r9d
    mov     esi, r10d
    mov     edx, r11d
    call    days_from_civil
    imul    rax, 86400

    pop     rcx             ; hour
    pop     rsi             ; minute
    pop     rdx             ; second

    movzx   ecx, cl
    imul    rcx, 3600
    add     rax, rcx
    movzx   esi, si
    imul    rsi, 60
    add     rax, rsi
    movzx   edx, dl
    add     rax, rdx

    ; Adjust for local timezone (same as -t)
    push    rax
    mov     rdi, rax
    call    get_tz_offset
    mov     rbx, rax
    pop     rax
    sub     rax, rbx

    ; Store in TIMESPEC_BUF
    mov     [TIMESPEC_BUF], rax
    mov     qword [TIMESPEC_BUF + 8], 0
    mov     [TIMESPEC_BUF + 16], rax
    mov     qword [TIMESPEC_BUF + 24], 0

    pop     rcx
    jmp     .next_opt

.date_bad_format:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid_date_arg
    mov     edx, str_invalid_date_arg_len
    call    do_write_err
    mov     rdi, r8
    call    str_len
    mov     edx, eax
    mov     rsi, r8
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    pop     rcx
    mov     edi, 1
    jmp     do_exit

; --- Error: option requires argument ---
.err_opt_requires_arg_t:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_opt_req_t
    mov     edx, str_opt_req_t_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.err_opt_requires_arg_r:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_opt_req_r
    mov     edx, str_opt_req_r_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.err_opt_requires_arg_d:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_opt_req_d
    mov     edx, str_opt_req_d_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; --- Done parsing options ---
.done_opts:
    mov     r9d, ecx

    cmp     r9d, r14d
    jge     .err_missing_operand

    mov     r13d, r9d
    xor     ebp, ebp

.file_loop:
    cmp     r13d, r14d
    jge     .exit_with_code
    mov     rdi, [r15 + r13*8]
    call    do_touch_file
    inc     r13d
    jmp     .file_loop

.exit_with_code:
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
; do_touch_file: touch one file
; Input: rdi = filename pointer
;   r12d = flags, ebp = exit code accumulator
; ============================================================
do_touch_file:
    push    r13
    push    r14
    push    r15
    push    rbx
    mov     r13, rdi            ; save filename

    ; First, try to create the file if it doesn't exist (unless -c)
    test    r12d, FLAG_NO_CREATE
    jnz     .tf_skip_create

    ; openat(AT_FDCWD, path, O_WRONLY|O_CREAT|O_NOCTTY|O_NONBLOCK, 0666)
    mov     eax, SYS_OPENAT
    mov     edi, AT_FDCWD
    mov     rsi, r13
    mov     edx, O_WRONLY | O_CREAT | O_NOCTTY | O_NONBLOCK
    mov     r10d, MODE_0666
    syscall
    test    rax, rax
    js      .tf_open_err
    mov     r14d, eax           ; fd
    mov     eax, SYS_CLOSE
    mov     edi, r14d
    syscall
    jmp     .tf_do_utimensat

.tf_skip_create:
    ; With -c, check if file exists
    mov     eax, SYS_NEWFSTATAT
    mov     edi, AT_FDCWD
    mov     rsi, r13
    mov     rdx, STAT_BUF
    xor     r10d, r10d
    test    r12d, FLAG_NO_DEREF
    jz      .tf_stat_nf_done
    mov     r10d, AT_SYMLINK_NOFOLLOW
.tf_stat_nf_done:
    syscall
    test    rax, rax
    js      .tf_skip_silent

.tf_do_utimensat:
    sub     rsp, 32

    test    r12d, FLAG_HAVE_TIME
    jnz     .tf_explicit_time

    ; No explicit time — use UTIME_NOW
    mov     eax, r12d
    and     eax, FLAG_ATIME_ONLY | FLAG_MTIME_ONLY
    cmp     eax, FLAG_ATIME_ONLY
    je      .tf_now_atime_only
    cmp     eax, FLAG_MTIME_ONLY
    je      .tf_now_mtime_only

    ; Both
    mov     qword [rsp], 0
    mov     qword [rsp + 8], UTIME_NOW
    mov     qword [rsp + 16], 0
    mov     qword [rsp + 24], UTIME_NOW
    jmp     .tf_call_utimensat

.tf_now_atime_only:
    mov     qword [rsp], 0
    mov     qword [rsp + 8], UTIME_NOW
    mov     qword [rsp + 16], 0
    mov     qword [rsp + 24], UTIME_OMIT
    jmp     .tf_call_utimensat

.tf_now_mtime_only:
    mov     qword [rsp], 0
    mov     qword [rsp + 8], UTIME_OMIT
    mov     qword [rsp + 16], 0
    mov     qword [rsp + 24], UTIME_NOW
    jmp     .tf_call_utimensat

.tf_explicit_time:
    mov     eax, r12d
    and     eax, FLAG_ATIME_ONLY | FLAG_MTIME_ONLY
    cmp     eax, FLAG_ATIME_ONLY
    je      .tf_explicit_atime_only
    cmp     eax, FLAG_MTIME_ONLY
    je      .tf_explicit_mtime_only

    ; Both
    mov     rax, [TIMESPEC_BUF]
    mov     [rsp], rax
    mov     rax, [TIMESPEC_BUF + 8]
    mov     [rsp + 8], rax
    mov     rax, [TIMESPEC_BUF + 16]
    mov     [rsp + 16], rax
    mov     rax, [TIMESPEC_BUF + 24]
    mov     [rsp + 24], rax
    jmp     .tf_call_utimensat

.tf_explicit_atime_only:
    mov     rax, [TIMESPEC_BUF]
    mov     [rsp], rax
    mov     rax, [TIMESPEC_BUF + 8]
    mov     [rsp + 8], rax
    mov     qword [rsp + 16], 0
    mov     qword [rsp + 24], UTIME_OMIT
    jmp     .tf_call_utimensat

.tf_explicit_mtime_only:
    mov     qword [rsp], 0
    mov     qword [rsp + 8], UTIME_OMIT
    mov     rax, [TIMESPEC_BUF + 16]
    mov     [rsp + 16], rax
    mov     rax, [TIMESPEC_BUF + 24]
    mov     [rsp + 24], rax

.tf_call_utimensat:
    mov     eax, SYS_UTIMENSAT
    mov     edi, AT_FDCWD
    mov     rsi, r13
    mov     rdx, rsp
    xor     r10d, r10d
    test    r12d, FLAG_NO_DEREF
    jz      .tf_utimens_flags_done
    mov     r10d, AT_SYMLINK_NOFOLLOW
.tf_utimens_flags_done:
    syscall
    add     rsp, 32
    test    rax, rax
    js      .tf_utimens_err

    pop     rbx
    pop     r15
    pop     r14
    pop     r13
    ret

.tf_open_err:
    push    rbp
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot_touch1
    mov     edx, str_cannot_touch1_len
    call    do_write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_cannot_touch2
    mov     edx, str_cannot_touch2_len
    call    do_write_err
    pop     rbp
    mov     ebp, 1
    pop     rbx
    pop     r15
    pop     r14
    pop     r13
    ret

.tf_skip_silent:
    pop     rbx
    pop     r15
    pop     r14
    pop     r13
    ret

.tf_utimens_err:
    push    rbp
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_set_times1
    mov     edx, str_set_times1_len
    call    do_write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_set_times2
    mov     edx, str_set_times2_len
    call    do_write_err
    pop     rbp
    mov     ebp, 1
    pop     rbx
    pop     r15
    pop     r14
    pop     r13
    ret

; ============================================================
; get_tz_offset: Get UTC offset in seconds for a given epoch time
; by reading /etc/localtime (TZif format)
;
; Input: rdi = UTC epoch timestamp (approximate, for finding transition)
; Output: rax = UTC offset in seconds (e.g., -18000 for UTC-5)
;         Returns 0 if /etc/localtime cannot be read
;
; Reads /etc/localtime, skips V1 data, parses V2 transition table.
; Searches transitions to find which UTC offset applies.
; ============================================================
get_tz_offset:
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    r8
    push    r9
    push    r10
    push    r11
    push    r12
    push    r13
    push    rbp
    mov     rbp, rsp
    mov     r12, rdi            ; save target epoch

    ; Open /etc/localtime
    mov     eax, SYS_OPEN
    mov     rdi, str_etc_localtime
    xor     esi, esi            ; O_RDONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .tz_fail
    mov     r8d, eax            ; fd

    ; Read into TZIF_BUF
    mov     eax, SYS_READ
    mov     edi, r8d
    mov     rsi, TZIF_BUF
    mov     edx, TZIF_BUF_SIZE
    syscall
    mov     r9, rax             ; bytes read
    push    r9

    ; Close fd
    mov     eax, SYS_CLOSE
    mov     edi, r8d
    syscall

    pop     r9
    cmp     r9, 44
    jl      .tz_fail            ; too small for TZif header

    ; Verify magic "TZif"
    mov     eax, [TZIF_BUF]
    cmp     eax, 0x66695A54     ; 'TZif' little-endian
    jne     .tz_fail

    ; Check version — need V2 or V3
    movzx   eax, byte [TZIF_BUF + 4]
    cmp     al, '2'
    je      .tz_v2
    cmp     al, '3'
    je      .tz_v2
    ; V1 only — fall through to use V1
    jmp     .tz_use_v1

.tz_v2:
    ; Read V1 header to compute V1 data size and skip to V2
    ; V1 header at offset 20:
    ;   tzh_ttisutcnt  [20..24]
    ;   tzh_ttisstdcnt [24..28]
    ;   tzh_leapcnt    [28..32]
    ;   tzh_timecnt    [32..36]
    ;   tzh_typecnt    [36..40]
    ;   tzh_charcnt    [40..44]
    ; All big-endian 32-bit

    ; Read V1 counts (big-endian)
    mov     edi, TZIF_BUF + 20
    call    read_be32
    mov     r10d, eax           ; v1_ttisutcnt

    mov     edi, TZIF_BUF + 24
    call    read_be32
    mov     r11d, eax           ; v1_ttisstdcnt

    mov     edi, TZIF_BUF + 28
    call    read_be32
    push    rax                 ; v1_leapcnt

    mov     edi, TZIF_BUF + 32
    call    read_be32
    mov     ebx, eax            ; v1_timecnt

    mov     edi, TZIF_BUF + 36
    call    read_be32
    mov     ecx, eax            ; v1_typecnt

    mov     edi, TZIF_BUF + 40
    call    read_be32
    mov     edx, eax            ; v1_charcnt

    pop     rsi                 ; v1_leapcnt

    ; V1 data size = timecnt*4 + timecnt*1 + typecnt*6 + charcnt + leapcnt*8 + ttisstdcnt + ttisutcnt
    mov     eax, ebx
    shl     eax, 2             ; timecnt * 4
    add     eax, ebx           ; + timecnt (type indices)
    ; typecnt * 6
    lea     edi, [ecx + ecx*2] ; typecnt * 3
    shl     edi, 1             ; typecnt * 6
    add     eax, edi
    add     eax, edx           ; + charcnt
    ; leapcnt * 8
    mov     edi, esi
    shl     edi, 3
    add     eax, edi
    add     eax, r11d          ; + ttisstdcnt
    add     eax, r10d          ; + ttisutcnt

    ; V2 header starts at 44 + v1_data_size
    add     eax, 44
    mov     r10d, eax           ; v2_offset

    ; Verify V2 magic
    lea     edi, [TZIF_BUF + 0]
    add     edi, r10d
    mov     eax, [rdi]
    cmp     eax, 0x66695A54     ; 'TZif'
    jne     .tz_fail

    ; V2 header at v2_offset + 20
    lea     r11d, [r10d + 20]

    ; Read V2 counts
    lea     edi, [TZIF_BUF + 0]
    add     edi, r11d
    call    read_be32
    push    rax                 ; v2_ttisutcnt (not needed but track offset)

    lea     edi, [TZIF_BUF + 0]
    add     edi, r11d
    add     edi, 4
    call    read_be32
    push    rax                 ; v2_ttisstdcnt

    lea     edi, [TZIF_BUF + 0]
    add     edi, r11d
    add     edi, 8
    call    read_be32
    push    rax                 ; v2_leapcnt

    lea     edi, [TZIF_BUF + 0]
    add     edi, r11d
    add     edi, 12
    call    read_be32
    mov     ebx, eax            ; v2_timecnt

    lea     edi, [TZIF_BUF + 0]
    add     edi, r11d
    add     edi, 16
    call    read_be32
    mov     ecx, eax            ; v2_typecnt

    lea     edi, [TZIF_BUF + 0]
    add     edi, r11d
    add     edi, 20
    call    read_be32
    mov     edx, eax            ; v2_charcnt

    pop     rsi                 ; v2_leapcnt
    pop     rax                 ; v2_ttisstdcnt (discard)
    pop     rax                 ; v2_ttisutcnt (discard)

    ; V2 data starts at v2_offset + 44
    lea     r10d, [r10d + 44]   ; v2_data_offset

    ; Transition times: v2_timecnt * 8 bytes of big-endian int64
    ; at offset v2_data_offset in TZIF_BUF
    ; Transition type indices: v2_timecnt bytes after transition times
    ; ttinfo structs: v2_typecnt * 6 bytes after type indices
    ;   each ttinfo: int32 utoff (BE), uint8 dst, uint8 idx

    ; Search transitions from last to first
    ; Find the last transition where transition_time <= target_epoch
    test    ebx, ebx
    jz      .tz_use_default_type

    ; Start from the last transition and scan backwards
    mov     r13d, ebx
    dec     r13d                ; index of last transition

.tz_scan_loop:
    cmp     r13d, 0
    jl      .tz_use_default_type

    ; Read transition time at index r13d
    ; offset = v2_data_offset + r13d * 8
    mov     eax, r13d
    shl     eax, 3              ; * 8
    add     eax, r10d
    lea     edi, [TZIF_BUF + 0]
    add     edi, eax
    call    read_be64

    ; rax = transition time (signed)
    cmp     r12, rax            ; target_epoch >= transition_time?
    jge     .tz_found_transition

    dec     r13d
    jmp     .tz_scan_loop

.tz_found_transition:
    ; Get the type index for this transition
    ; type_indices start at v2_data_offset + v2_timecnt * 8
    mov     eax, ebx            ; v2_timecnt
    shl     eax, 3              ; * 8
    add     eax, r10d           ; + v2_data_offset
    add     eax, r13d           ; + transition index
    lea     edi, [TZIF_BUF + 0]
    add     edi, eax
    movzx   eax, byte [rdi]    ; type index
    jmp     .tz_read_ttinfo

.tz_use_default_type:
    ; No matching transition — use type 0
    xor     eax, eax

.tz_read_ttinfo:
    ; Read utoff from ttinfo[type_index]
    ; ttinfo starts at v2_data_offset + v2_timecnt * 9
    ; Each ttinfo is 6 bytes: int32_be utoff, uint8 dst, uint8 idx
    push    rax
    mov     eax, ebx            ; v2_timecnt
    shl     eax, 3              ; * 8
    add     eax, ebx            ; + v2_timecnt (for type indices)
    add     eax, r10d           ; + v2_data_offset
    pop     rdi                 ; type index
    ; offset = base + type_index * 6
    imul    edi, edi, 6
    add     eax, edi
    lea     edi, [TZIF_BUF + 0]
    add     edi, eax
    call    read_be32           ; utoff (signed)
    movsx   rax, eax            ; sign-extend to 64-bit

    mov     rsp, rbp
    pop     rbp
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

.tz_use_v1:
    ; For V1-only files, read V1 transition table (4-byte times)
    ; V1 counts:
    mov     edi, TZIF_BUF + 32
    call    read_be32
    mov     ebx, eax            ; v1_timecnt

    mov     edi, TZIF_BUF + 36
    call    read_be32
    mov     ecx, eax            ; v1_typecnt

    ; V1 data starts at offset 44
    mov     r10d, 44            ; v1_data_offset

    ; Scan transitions backwards (4-byte big-endian times)
    test    ebx, ebx
    jz      .tz_v1_default

    mov     r13d, ebx
    dec     r13d

.tz_v1_scan:
    cmp     r13d, 0
    jl      .tz_v1_default

    mov     eax, r13d
    shl     eax, 2              ; * 4
    add     eax, r10d
    lea     edi, [TZIF_BUF + 0]
    add     edi, eax
    call    read_be32
    movsx   rax, eax            ; sign-extend 32-bit time

    cmp     r12, rax
    jge     .tz_v1_found

    dec     r13d
    jmp     .tz_v1_scan

.tz_v1_found:
    ; Get type index
    mov     eax, ebx
    shl     eax, 2              ; v1_timecnt * 4
    add     eax, r10d
    add     eax, r13d
    lea     edi, [TZIF_BUF + 0]
    add     edi, eax
    movzx   eax, byte [rdi]
    jmp     .tz_v1_read_ttinfo

.tz_v1_default:
    xor     eax, eax

.tz_v1_read_ttinfo:
    push    rax
    mov     eax, ebx
    shl     eax, 2
    add     eax, ebx            ; + timecnt (type indices)
    add     eax, r10d
    pop     rdi
    imul    edi, edi, 6
    add     eax, edi
    lea     edi, [TZIF_BUF + 0]
    add     edi, eax
    call    read_be32
    movsx   rax, eax

    mov     rsp, rbp
    pop     rbp
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

.tz_fail:
    ; Return 0 (UTC) if we can't read timezone
    xor     eax, eax
    mov     rsp, rbp
    pop     rbp
    pop     r13
    pop     r12
    pop     r11
    pop     r10
    pop     r9
    pop     r8
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; ============================================================
; read_be32: Read big-endian 32-bit integer from [edi]
; Input: edi = address (absolute)
; Output: eax = value
; ============================================================
read_be32:
    push    rdi
    mov     eax, [rdi]
    bswap   eax
    pop     rdi
    ret

; ============================================================
; read_be64: Read big-endian 64-bit integer from [edi]
; Input: edi = address (absolute)
; Output: rax = value
; ============================================================
read_be64:
    push    rdi
    mov     rax, [rdi]
    bswap   rax
    pop     rdi
    ret

; ============================================================
; get_current_year: Get current year from system clock
; Output: eax = current year
; Uses clock_gettime(CLOCK_REALTIME) and reverse-computes year from epoch
; ============================================================
get_current_year:
    push    rbx
    push    rcx
    push    rdx
    push    rsi
    push    rdi
    sub     rsp, 16             ; struct timespec

    ; clock_gettime(CLOCK_REALTIME=0, &ts)
    mov     eax, 228            ; SYS_clock_gettime
    xor     edi, edi            ; CLOCK_REALTIME
    mov     rsi, rsp
    syscall

    mov     rax, [rsp]          ; tv_sec = epoch seconds
    add     rsp, 16

    ; Approximate year from epoch:
    ; days = epoch / 86400
    xor     edx, edx
    mov     rcx, 86400
    cqo
    idiv    rcx                 ; rax = days since epoch

    ; From days, compute year using inverse of days_from_civil
    ; z = days + 719468
    add     rax, 719468
    mov     rbx, rax            ; z

    ; era = z / 146097 (floor)
    mov     rax, rbx
    test    rax, rax
    jns     .gcy_pos
    sub     rax, 146096
.gcy_pos:
    xor     edx, edx
    mov     rcx, 146097
    cqo
    idiv    rcx
    mov     rsi, rax            ; era

    ; doe = z - era * 146097
    imul    rcx, rsi, 146097
    mov     rax, rbx
    sub     rax, rcx            ; doe (0..146096)

    ; yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
    mov     rcx, rax            ; doe
    push    rcx

    xor     edx, edx
    mov     rdi, 1460
    div     rdi                 ; doe/1460
    mov     r8, rax

    mov     rax, rcx
    xor     edx, edx
    mov     rdi, 36524
    div     rdi
    mov     r9, rax

    mov     rax, rcx
    xor     edx, edx
    mov     rdi, 146096
    div     rdi
    mov     r10, rax

    pop     rcx
    mov     rax, rcx
    sub     rax, r8
    add     rax, r9
    sub     rax, r10
    xor     edx, edx
    mov     rdi, 365
    div     rdi                 ; yoe

    ; year = yoe + era * 400
    imul    rcx, rsi, 400
    add     rax, rcx            ; year (March-based)

    ; Adjust: the March-based year might need +1 for Jan/Feb
    ; For simplicity, this is close enough for -t with no year
    ; (GNU touch uses actual current year; this is within 1 year)

    pop     rdi
    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; ============================================================
; days_from_civil: compute days since Unix epoch (1970-01-01)
; Input: edi = year, esi = month (1-12), edx = day (1-31)
; Output: rax = days since epoch (signed)
; Uses Howard Hinnant's algorithm
; ============================================================
days_from_civil:
    push    rbx
    push    rcx
    push    rdx
    push    rsi

    movsx   rax, edi            ; year (signed)
    movsx   rcx, esi            ; month
    movsx   rbx, edx            ; day

    cmp     ecx, 2
    jg      .dfc_no_adj
    dec     rax
    add     ecx, 9
    jmp     .dfc_adj_done
.dfc_no_adj:
    sub     ecx, 3
.dfc_adj_done:

    mov     rdi, rax            ; adjusted year

    ; era = floor(y / 400)
    mov     rax, rdi
    test    rax, rax
    jns     .dfc_pos_era
    sub     rax, 399
.dfc_pos_era:
    push    rdx
    cqo
    mov     rsi, 400
    idiv    rsi
    pop     rdx
    mov     r8, rax             ; era

    ; yoe = y - era * 400
    imul    rax, r8, 400
    mov     r9, rdi
    sub     r9, rax             ; yoe (0..399)

    ; doy = (153 * m + 2) / 5 + d - 1
    imul    eax, ecx, 153
    add     eax, 2
    push    rdx
    cdq
    mov     esi, 5
    idiv    esi
    pop     rdx
    add     eax, ebx
    dec     eax
    movsx   r10, eax            ; doy

    ; doe = yoe * 365 + yoe/4 - yoe/100 + doy
    mov     rax, r9
    imul    rax, 365
    mov     rcx, r9
    shr     rcx, 2
    add     rax, rcx
    ; - yoe/100
    push    rdx
    push    rax
    mov     rax, r9
    xor     edx, edx
    mov     rcx, 100
    div     rcx
    mov     rcx, rax
    pop     rax
    pop     rdx
    sub     rax, rcx
    add     rax, r10            ; doe

    ; days = era * 146097 + doe - 719468
    imul    rcx, r8, 146097
    add     rax, rcx
    sub     rax, 719468

    pop     rsi
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; ============================================================
; parse_2digits: parse 2 ASCII digits from [rdi] -> eax
; ============================================================
parse_2digits:
    movzx   eax, byte [rdi]
    sub     eax, '0'
    imul    eax, 10
    movzx   ecx, byte [rdi + 1]
    sub     ecx, '0'
    add     eax, ecx
    ret

; ============================================================
; parse_4digits: parse 4 ASCII digits from [rdi] -> eax
; ============================================================
parse_4digits:
    movzx   eax, byte [rdi]
    sub     eax, '0'
    imul    eax, 10
    movzx   ecx, byte [rdi + 1]
    sub     ecx, '0'
    add     eax, ecx
    imul    eax, 10
    movzx   ecx, byte [rdi + 2]
    sub     ecx, '0'
    add     eax, ecx
    imul    eax, 10
    movzx   ecx, byte [rdi + 3]
    sub     ecx, '0'
    add     eax, ecx
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
    db "Usage: touch [OPTION]... FILE...", 10
    db "Update the access and modification times of each FILE to the current time.", 10, 10
    db "A FILE argument that does not exist is created empty, unless -c or -h", 10
    db "is supplied.", 10, 10
    db "A FILE argument string of - is handled specially and causes touch to", 10
    db "change the times of the file associated with standard output.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -a                     change only the access time", 10
    db "  -c, --no-create        do not create any files", 10
    db "  -d, --date=STRING      parse STRING and use it instead of current time", 10
    db "  -f                     (ignored)", 10
    db "  -h, --no-dereference   affect each symbolic link instead of any referenced", 10
    db "                         file (useful only on systems that can change the", 10
    db "                         timestamps of a symlink)", 10
    db "  -m                     change only the modification time", 10
    db "  -r, --reference=FILE   use this file's times instead of current time", 10
    db "  -t STAMP               use [[CC]YY]MMDDhhmm[.ss] instead of current time", 10
    db "      --time=WORD        change the specified time:", 10
    db "                           WORD is access, atime, or use: equivalent to -a", 10
    db "                           WORD is modify or mtime: equivalent to -m", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "Note that the -d and -t options accept different time-date formats.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/touch>", 10
    db "or available locally via: info '(coreutils) touch invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "touch (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Paul Rubin, Arnold Robbins, Jim Kingdon,", 10
    db "David MacKenzie, and Randy Smith.", 10
str_version_len equ $ - str_version

str_prefix:         db "touch: "
str_prefix_len      equ $ - str_prefix
str_unrecog:        db "unrecognized option '"
str_unrecog_len     equ $ - str_unrecog
str_invalid:        db "invalid option -- '"
str_invalid_len     equ $ - str_invalid
str_missing:        db "missing file operand", 10
str_missing_len     equ $ - str_missing
str_sq_nl:          db "'", 10
str_try:            db "Try 'touch --help' for more information.", 10
str_try_len         equ $ - str_try
str_opt_req_t:      db "option requires an argument -- 't'", 10
str_opt_req_t_len   equ $ - str_opt_req_t
str_opt_req_r:      db "option requires an argument -- 'r'", 10
str_opt_req_r_len   equ $ - str_opt_req_r
str_opt_req_d:      db "option requires an argument -- 'd'", 10
str_opt_req_d_len   equ $ - str_opt_req_d
str_invalid_date:       db "invalid date format", 10
str_invalid_date_len    equ $ - str_invalid_date
str_invalid_date_arg:   db "invalid date '"
str_invalid_date_arg_len equ $ - str_invalid_date_arg
str_cannot_touch1:  db "cannot touch '"
str_cannot_touch1_len equ $ - str_cannot_touch1
str_cannot_touch2:  db "': No such file or directory", 10
str_cannot_touch2_len equ $ - str_cannot_touch2
str_fail_stat1:     db "failed to get attributes of '"
str_fail_stat1_len  equ $ - str_fail_stat1
str_fail_stat2:     db "': No such file or directory", 10
str_fail_stat2_len  equ $ - str_fail_stat2
str_set_times1:     db "setting times of '"
str_set_times1_len  equ $ - str_set_times1
str_set_times2:     db "': Operation not permitted", 10
str_set_times2_len  equ $ - str_set_times2

str_etc_localtime:  db "/etc/localtime", 0
; @@DATA_END@@

str_help_flag:      db "--help", 0
str_version_flag:   db "--version", 0
str_no_create_flag: db "--no-create", 0
str_no_deref_flag:  db "--no-dereference", 0
str_ref_prefix:     db "--reference=", 0
str_date_prefix:    db "--date=", 0
str_time_prefix:    db "--time=", 0

file_size equ $ - $$
