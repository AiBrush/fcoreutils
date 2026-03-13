; fdate.asm — GNU-compatible 'date' command
;
; date: display or set the system date and time
; - date             — print current date/time in default format
; - date -u          — use UTC
; - date +FORMAT     — custom format string
; - date -R          — RFC 5322 date format
; - date -I[FMT]     — ISO 8601 format
; - date --help / --version
;
; Default output: "Thu Mar 12 20:00:00 UTC 2026"
; Uses clock_gettime(228) syscall, always UTC (no TZ file parsing).

%include "include/linux.inc"

extern asm_write
extern asm_exit
extern asm_strlen
extern asm_strcmp

global _start

section .bss
    out_buf: resb 256           ; output buffer
    num_tmp: resb 32            ; temp for number formatting

section .data

; Day names (3-char abbreviations)
day_names:
    db "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"

; Month names (3-char abbreviations)
mon_names:
    db "Jan", "Feb", "Mar", "Apr", "May", "Jun"
    db "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"

; Days per month (non-leap)
days_per_month:
    db 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

; RFC 5322 day names
rfc_day_names:
    db "Sun, ", "Mon, ", "Tue, ", "Wed, ", "Thu, ", "Fri, ", "Sat, "

; Datetime storage
dt_epoch:  dq 0
dt_year:   dw 0
dt_month:  db 0
dt_day:    db 0
dt_hour:   db 0
dt_min:    db 0
dt_sec:    db 0
dt_wday:   db 0
dt_yday:   dw 0
dt_format: db 0
dt_fmt_ptr: dq 0

section .text

; ============================================================
; format_2digit(eax=value 0-99) -> al=tens+'0', ah=ones+'0'
; ============================================================
format_2digit:
    push    rbx
    movzx   eax, al
    xor     edx, edx
    mov     ebx, 10
    div     ebx
    add     al, '0'
    add     dl, '0'
    mov     ah, dl
    pop     rbx
    ret

; ============================================================
; format_4digit(eax=year) -> stores in num_tmp, returns packed eax
; al=thousands, ah=hundreds, bits[16..23]=tens, bits[24..31]=ones
; ============================================================
format_4digit:
    push    rbx
    push    rcx
    movzx   eax, ax
    xor     edx, edx
    mov     ebx, 1000
    div     ebx
    add     al, '0'
    mov     [rel num_tmp], al
    mov     eax, edx
    xor     edx, edx
    mov     ebx, 100
    div     ebx
    add     al, '0'
    mov     [rel num_tmp + 1], al
    mov     eax, edx
    xor     edx, edx
    mov     ebx, 10
    div     ebx
    add     al, '0'
    add     dl, '0'
    mov     [rel num_tmp + 2], al
    mov     [rel num_tmp + 3], dl
    ; Return as packed dword
    movzx   eax, byte [rel num_tmp]
    movzx   edx, byte [rel num_tmp + 1]
    shl     edx, 8
    or      eax, edx
    movzx   edx, byte [rel num_tmp + 2]
    shl     edx, 16
    or      eax, edx
    movzx   edx, byte [rel num_tmp + 3]
    shl     edx, 24
    or      eax, edx
    pop     rcx
    pop     rbx
    ret

; ============================================================
; format_day_sp(eax=day 1-31) -> rsi points to 2-char (space-padded)
; ============================================================
format_day_sp:
    movzx   eax, al
    cmp     eax, 10
    jge     .two_digits
    mov     byte [rel num_tmp + 10], ' '
    add     al, '0'
    mov     [rel num_tmp + 11], al
    lea     rsi, [rel num_tmp + 10]
    ret
.two_digits:
    push    rbx
    xor     edx, edx
    mov     ebx, 10
    div     ebx
    add     al, '0'
    add     dl, '0'
    mov     [rel num_tmp + 10], al
    mov     [rel num_tmp + 11], dl
    lea     rsi, [rel num_tmp + 10]
    pop     rbx
    ret

; ============================================================
; is_leap(rdi=year) -> edx: 1 if leap, 0 if not
; ============================================================
is_leap:
    mov     rax, rdi
    xor     edx, edx
    push    rbx
    mov     rbx, 4
    div     rbx
    test    edx, edx
    jnz     .not_leap
    mov     rax, rdi
    xor     edx, edx
    mov     rbx, 100
    div     rbx
    test    edx, edx
    jnz     .yes_leap
    mov     rax, rdi
    xor     edx, edx
    mov     rbx, 400
    div     rbx
    test    edx, edx
    jnz     .not_leap
.yes_leap:
    mov     edx, 1
    pop     rbx
    ret
.not_leap:
    xor     edx, edx
    pop     rbx
    ret

; ============================================================
; epoch_to_datetime — convert Unix epoch (rdi) to datetime components
; Stores results in dt_* globals
; ============================================================
epoch_to_datetime:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15

    mov     [rel dt_epoch], rdi
    mov     rax, rdi            ; epoch seconds

    ; Compute seconds within day
    xor     edx, edx
    mov     rbx, 86400
    div     rbx                 ; rax = days since epoch, rdx = seconds in day
    mov     r8, rax             ; r8 = total days
    mov     r9, rdx             ; r9 = seconds in day

    ; Hour/Min/Sec from seconds in day
    mov     rax, r9
    xor     edx, edx
    mov     rbx, 3600
    div     rbx
    mov     [rel dt_hour], al
    mov     rax, rdx
    xor     edx, edx
    mov     rbx, 60
    div     rbx
    mov     [rel dt_min], al
    mov     [rel dt_sec], dl

    ; Day of week: (days + 4) % 7  (Jan 1 1970 = Thursday = 4)
    mov     rax, r8
    add     rax, 4
    xor     edx, edx
    mov     rbx, 7
    div     rbx
    mov     [rel dt_wday], dl

    ; Convert days to year/month/day
    mov     rax, r8             ; remaining days
    mov     r10, 1970           ; current year

.year_loop:
    mov     rbx, 365
    push    rax
    mov     rdi, r10
    call    is_leap
    pop     rax
    add     rbx, rdx            ; 365 or 366

    cmp     rax, rbx
    jl      .year_found
    sub     rax, rbx
    inc     r10
    jmp     .year_loop

.year_found:
    mov     [rel dt_year], r10w
    inc     rax                 ; 1-based yday
    mov     [rel dt_yday], ax
    dec     rax                 ; back to 0-based for month calc

    push    rax
    mov     rdi, r10
    call    is_leap
    pop     rax
    mov     r11, rdx            ; leap flag

    lea     rsi, [rel days_per_month]
    xor     ecx, ecx
.month_loop:
    movzx   ebx, byte [rsi + rcx]
    cmp     ecx, 1
    jne     .no_feb_adj
    add     ebx, r11d
.no_feb_adj:
    cmp     eax, ebx
    jl      .month_found
    sub     eax, ebx
    inc     ecx
    cmp     ecx, 11
    jle     .month_loop

.month_found:
    inc     ecx                 ; 1-based month
    mov     [rel dt_month], cl
    inc     eax                 ; 1-based day
    mov     [rel dt_day], al

    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; ============================================================
; emit_4digit_year: writes 4 chars at [rdi+rcx], advances rcx by 4
; ============================================================
emit_year:
    movzx   eax, word [rel dt_year]
    call    format_4digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    shr     eax, 16
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    ret

; ============================================================
; emit_2digit: writes 2 chars for byte in al at [rdi+rcx]
; ============================================================
emit_hms:
    ; Emit HH:MM:SS at [rdi+rcx]
    movzx   eax, byte [rel dt_hour]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    mov     byte [rdi + rcx], ':'
    inc     rcx
    movzx   eax, byte [rel dt_min]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    mov     byte [rdi + rcx], ':'
    inc     rcx
    movzx   eax, byte [rel dt_sec]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    ret

; ============================================================
; _start — entry point
; ============================================================
_start:
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Flags
    xor     r12d, r12d          ; format: 0=default, 1=custom, 2=RFC, 3=ISO
    xor     r13d, r13d          ; format string pointer

    mov     rbx, 1
.parse_args:
    cmp     rbx, r14
    jge     .args_done

    mov     rdi, [r15 + rbx*8]

    ; --help
    push    rbx
    mov     rsi, str_opt_help
    call    asm_strcmp
    pop     rbx
    test    eax, eax
    jz      .show_help

    mov     rdi, [r15 + rbx*8]
    push    rbx
    mov     rsi, str_opt_version
    call    asm_strcmp
    pop     rbx
    test    eax, eax
    jz      .show_version

    mov     rdi, [r15 + rbx*8]

    ; +FORMAT
    cmp     byte [rdi], '+'
    jne     .check_dash
    lea     r13, [rdi + 1]
    mov     r12d, 1
    inc     rbx
    jmp     .parse_args

.check_dash:
    cmp     byte [rdi], '-'
    jne     .unknown_arg

    movzx   eax, byte [rdi + 1]
    cmp     al, 'u'
    je      .opt_u
    cmp     al, 'R'
    je      .opt_R
    cmp     al, 'I'
    je      .opt_I
    cmp     al, 'd'
    je      .opt_d
    cmp     al, '-'
    je      .check_long
    jmp     .unknown_arg

.opt_u:
    cmp     byte [rdi + 2], 0
    jne     .check_long
    inc     rbx
    jmp     .parse_args

.opt_R:
    cmp     byte [rdi + 2], 0
    jne     .unknown_arg
    mov     r12d, 2
    inc     rbx
    jmp     .parse_args

.opt_I:
    mov     r12d, 3
    inc     rbx
    jmp     .parse_args

.opt_d:
    cmp     byte [rdi + 2], 0
    jne     .unknown_arg
    ; Skip the -d and its argument
    add     rbx, 2
    jmp     .parse_args

.check_long:
    ; --utc, --universal
    mov     rdi, [r15 + rbx*8]
    push    rbx
    mov     rsi, str_opt_utc
    call    asm_strcmp
    pop     rbx
    test    eax, eax
    jz      .opt_u_long

    mov     rdi, [r15 + rbx*8]
    push    rbx
    mov     rsi, str_opt_universal
    call    asm_strcmp
    pop     rbx
    test    eax, eax
    jz      .opt_u_long

    mov     rdi, [r15 + rbx*8]
    push    rbx
    mov     rsi, str_opt_rfc_email
    call    asm_strcmp
    pop     rbx
    test    eax, eax
    jz      .opt_R_long

    jmp     .unknown_arg

.opt_u_long:
    inc     rbx
    jmp     .parse_args

.opt_R_long:
    mov     r12d, 2
    inc     rbx
    jmp     .parse_args

.unknown_arg:
    mov     edi, STDERR
    mov     rsi, str_err_prefix
    mov     edx, str_err_prefix_len
    call    asm_write
    mov     rdi, [r15 + rbx*8]
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, [r15 + rbx*8]
    mov     edi, STDERR
    call    asm_write
    mov     edi, STDERR
    mov     rsi, str_err_post
    mov     edx, str_err_post_len
    call    asm_write
    mov     edi, STDERR
    mov     rsi, str_try
    mov     edx, str_try_len
    call    asm_write
    mov     edi, 1
    call    asm_exit

.args_done:
    ; Save format info
    mov     [rel dt_format], r12b
    mov     [rel dt_fmt_ptr], r13

    ; Get current time
    sub     rsp, 16
    mov     eax, SYS_CLOCK_GETTIME
    xor     edi, edi            ; CLOCK_REALTIME
    mov     rsi, rsp
    syscall
    test    rax, rax
    jnz     .clock_failed

    mov     rdi, [rsp]          ; epoch seconds
    add     rsp, 16

    ; Convert to broken-down time
    call    epoch_to_datetime

    ; Format based on mode
    movzx   eax, byte [rel dt_format]
    cmp     al, 2
    je      .format_rfc5322
    cmp     al, 3
    je      .format_iso8601
    cmp     al, 1
    je      .format_custom

    ; ── Default format: "Thu Mar 12 20:00:00 UTC 2026\n" ──
    lea     rdi, [rel out_buf]
    xor     ecx, ecx

    ; Day name
    movzx   eax, byte [rel dt_wday]
    imul    eax, 3
    lea     rsi, [rel day_names]
    add     rsi, rax
    mov     al, [rsi]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 1]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 2]
    mov     [rdi + rcx], al
    inc     rcx
    mov     byte [rdi + rcx], ' '
    inc     rcx

    ; Month name
    movzx   eax, byte [rel dt_month]
    dec     eax
    imul    eax, 3
    lea     rsi, [rel mon_names]
    add     rsi, rax
    mov     al, [rsi]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 1]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 2]
    mov     [rdi + rcx], al
    inc     rcx
    mov     byte [rdi + rcx], ' '
    inc     rcx

    ; Day (space-padded)
    push    rcx
    push    rdi
    movzx   eax, byte [rel dt_day]
    call    format_day_sp
    pop     rdi
    pop     rcx
    mov     al, [rsi]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 1]
    mov     [rdi + rcx], al
    inc     rcx
    mov     byte [rdi + rcx], ' '
    inc     rcx

    ; HH:MM:SS
    call    emit_hms
    mov     byte [rdi + rcx], ' '
    inc     rcx

    ; "UTC "
    mov     byte [rdi + rcx], 'U'
    inc     rcx
    mov     byte [rdi + rcx], 'T'
    inc     rcx
    mov     byte [rdi + rcx], 'C'
    inc     rcx
    mov     byte [rdi + rcx], ' '
    inc     rcx

    ; Year
    call    emit_year

    ; Newline
    mov     byte [rdi + rcx], 10
    inc     rcx

    mov     rdx, rcx
    lea     rsi, [rel out_buf]
    mov     edi, STDOUT
    call    asm_write
    xor     edi, edi
    call    asm_exit

.format_rfc5322:
    ; "Thu, 12 Mar 2026 20:00:00 +0000\n"
    lea     rdi, [rel out_buf]
    xor     ecx, ecx

    ; Day name + ", "
    movzx   eax, byte [rel dt_wday]
    imul    eax, 5
    lea     rsi, [rel rfc_day_names]
    add     rsi, rax
    ; Copy 5 bytes "Thu, "
    mov     al, [rsi]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 1]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 2]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 3]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 4]
    mov     [rdi + rcx], al
    inc     rcx

    ; Day (zero-padded)
    movzx   eax, byte [rel dt_day]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    mov     byte [rdi + rcx], ' '
    inc     rcx

    ; Month name
    movzx   eax, byte [rel dt_month]
    dec     eax
    imul    eax, 3
    lea     rsi, [rel mon_names]
    add     rsi, rax
    mov     al, [rsi]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 1]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 2]
    mov     [rdi + rcx], al
    inc     rcx
    mov     byte [rdi + rcx], ' '
    inc     rcx

    ; Year
    call    emit_year
    mov     byte [rdi + rcx], ' '
    inc     rcx

    ; HH:MM:SS
    call    emit_hms
    mov     byte [rdi + rcx], ' '
    inc     rcx

    ; "+0000\n"
    mov     byte [rdi + rcx], '+'
    inc     rcx
    mov     byte [rdi + rcx], '0'
    inc     rcx
    mov     byte [rdi + rcx], '0'
    inc     rcx
    mov     byte [rdi + rcx], '0'
    inc     rcx
    mov     byte [rdi + rcx], '0'
    inc     rcx
    mov     byte [rdi + rcx], 10
    inc     rcx

    mov     rdx, rcx
    lea     rsi, [rel out_buf]
    mov     edi, STDOUT
    call    asm_write
    xor     edi, edi
    call    asm_exit

.format_iso8601:
    ; "2026-03-12\n"
    lea     rdi, [rel out_buf]
    xor     ecx, ecx

    call    emit_year
    mov     byte [rdi + rcx], '-'
    inc     rcx
    movzx   eax, byte [rel dt_month]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    mov     byte [rdi + rcx], '-'
    inc     rcx
    movzx   eax, byte [rel dt_day]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    mov     byte [rdi + rcx], 10
    inc     rcx

    mov     rdx, rcx
    lea     rsi, [rel out_buf]
    mov     edi, STDOUT
    call    asm_write
    xor     edi, edi
    call    asm_exit

.format_custom:
    lea     rdi, [rel out_buf]
    xor     ecx, ecx
    mov     rbp, [rel dt_fmt_ptr]   ; format string

.fmt_loop:
    movzx   eax, byte [rbp]
    test    al, al
    jz      .fmt_done

    cmp     al, '%'
    jne     .fmt_literal
    inc     rbp
    movzx   eax, byte [rbp]
    test    al, al
    jz      .fmt_done

    cmp     al, 'Y'
    je      .fmt_Y
    cmp     al, 'm'
    je      .fmt_m
    cmp     al, 'd'
    je      .fmt_d
    cmp     al, 'H'
    je      .fmt_H
    cmp     al, 'M'
    je      .fmt_M
    cmp     al, 'S'
    je      .fmt_S
    cmp     al, 'a'
    je      .fmt_a
    cmp     al, 'A'
    je      .fmt_a
    cmp     al, 'b'
    je      .fmt_b
    cmp     al, 'B'
    je      .fmt_b
    cmp     al, 'e'
    je      .fmt_e
    cmp     al, 'Z'
    je      .fmt_Z
    cmp     al, 'n'
    je      .fmt_n
    cmp     al, 't'
    je      .fmt_t
    cmp     al, '%'
    je      .fmt_percent
    cmp     al, 'F'
    je      .fmt_F
    cmp     al, 'T'
    je      .fmt_T
    cmp     al, 'R'
    je      .fmt_R_spec
    cmp     al, 'u'
    je      .fmt_u
    cmp     al, 'w'
    je      .fmt_w
    cmp     al, 'j'
    je      .fmt_j
    cmp     al, 'p'
    je      .fmt_p
    cmp     al, 'I'
    je      .fmt_I
    cmp     al, 'z'
    je      .fmt_z
    cmp     al, 's'
    je      .fmt_s

    ; Unknown — output %X literally
    mov     byte [rdi + rcx], '%'
    inc     rcx
    mov     [rdi + rcx], al
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_literal:
    mov     [rdi + rcx], al
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_Y:
    call    emit_year
    inc     rbp
    jmp     .fmt_loop

.fmt_m:
    movzx   eax, byte [rel dt_month]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_d:
    movzx   eax, byte [rel dt_day]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_H:
    movzx   eax, byte [rel dt_hour]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_M:
    movzx   eax, byte [rel dt_min]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_S:
    movzx   eax, byte [rel dt_sec]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_a:
    movzx   eax, byte [rel dt_wday]
    imul    eax, 3
    lea     rsi, [rel day_names]
    add     rsi, rax
    mov     al, [rsi]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 1]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 2]
    mov     [rdi + rcx], al
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_b:
    movzx   eax, byte [rel dt_month]
    dec     eax
    imul    eax, 3
    lea     rsi, [rel mon_names]
    add     rsi, rax
    mov     al, [rsi]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 1]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 2]
    mov     [rdi + rcx], al
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_e:
    push    rcx
    push    rdi
    movzx   eax, byte [rel dt_day]
    call    format_day_sp
    pop     rdi
    pop     rcx
    mov     al, [rsi]
    mov     [rdi + rcx], al
    inc     rcx
    mov     al, [rsi + 1]
    mov     [rdi + rcx], al
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_Z:
    mov     byte [rdi + rcx], 'U'
    inc     rcx
    mov     byte [rdi + rcx], 'T'
    inc     rcx
    mov     byte [rdi + rcx], 'C'
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_n:
    mov     byte [rdi + rcx], 10
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_t:
    mov     byte [rdi + rcx], 9
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_percent:
    mov     byte [rdi + rcx], '%'
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_F:
    call    emit_year
    mov     byte [rdi + rcx], '-'
    inc     rcx
    movzx   eax, byte [rel dt_month]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    mov     byte [rdi + rcx], '-'
    inc     rcx
    movzx   eax, byte [rel dt_day]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_T:
    call    emit_hms
    inc     rbp
    jmp     .fmt_loop

.fmt_R_spec:
    movzx   eax, byte [rel dt_hour]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    mov     byte [rdi + rcx], ':'
    inc     rcx
    movzx   eax, byte [rel dt_min]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_u:
    movzx   eax, byte [rel dt_wday]
    test    eax, eax
    jnz     .fmt_u_ok
    mov     eax, 7
.fmt_u_ok:
    add     al, '0'
    mov     [rdi + rcx], al
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_w:
    movzx   eax, byte [rel dt_wday]
    add     al, '0'
    mov     [rdi + rcx], al
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_j:
    movzx   eax, word [rel dt_yday]
    ; 3-digit zero-padded
    push    rbx
    xor     edx, edx
    mov     ebx, 100
    div     ebx
    add     al, '0'
    mov     [rdi + rcx], al
    inc     rcx
    mov     eax, edx
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    pop     rbx
    inc     rbp
    jmp     .fmt_loop

.fmt_p:
    movzx   eax, byte [rel dt_hour]
    cmp     eax, 12
    jge     .fmt_pm
    mov     byte [rdi + rcx], 'A'
    inc     rcx
    mov     byte [rdi + rcx], 'M'
    inc     rcx
    inc     rbp
    jmp     .fmt_loop
.fmt_pm:
    mov     byte [rdi + rcx], 'P'
    inc     rcx
    mov     byte [rdi + rcx], 'M'
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_I:
    movzx   eax, byte [rel dt_hour]
    test    eax, eax
    jnz     .fmt_I_nz
    mov     eax, 12
    jmp     .fmt_I_out
.fmt_I_nz:
    cmp     eax, 12
    jle     .fmt_I_out
    sub     eax, 12
.fmt_I_out:
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_z:
    mov     byte [rdi + rcx], '+'
    inc     rcx
    mov     byte [rdi + rcx], '0'
    inc     rcx
    mov     byte [rdi + rcx], '0'
    inc     rcx
    mov     byte [rdi + rcx], '0'
    inc     rcx
    mov     byte [rdi + rcx], '0'
    inc     rcx
    inc     rbp
    jmp     .fmt_loop

.fmt_s:
    mov     rax, [rel dt_epoch]
    lea     rsi, [rel num_tmp + 20]
    mov     byte [rsi], 0
    push    rbx
    mov     rbx, 10
.fmt_s_loop:
    xor     edx, edx
    div     rbx
    add     dl, '0'
    dec     rsi
    mov     [rsi], dl
    test    rax, rax
    jnz     .fmt_s_loop
    pop     rbx
.fmt_s_copy:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .fmt_s_done
    mov     [rdi + rcx], al
    inc     rcx
    inc     rsi
    jmp     .fmt_s_copy
.fmt_s_done:
    inc     rbp
    jmp     .fmt_loop

.fmt_done:
    mov     byte [rdi + rcx], 10
    inc     rcx
    mov     rdx, rcx
    lea     rsi, [rel out_buf]
    mov     edi, STDOUT
    call    asm_write
    xor     edi, edi
    call    asm_exit

.clock_failed:
    mov     edi, STDERR
    mov     rsi, str_clock_err
    mov     edx, str_clock_err_len
    call    asm_write
    mov     edi, 1
    call    asm_exit

.show_help:
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    asm_write
    xor     edi, edi
    call    asm_exit

.show_version:
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    asm_write
    xor     edi, edi
    call    asm_exit


section .rodata

str_opt_help:
    db "--help", 0

str_opt_version:
    db "--version", 0

str_opt_utc:
    db "--utc", 0

str_opt_universal:
    db "--universal", 0

str_opt_rfc_email:
    db "--rfc-email", 0

str_help:
    db "Usage: date [OPTION]... [+FORMAT]", 10
    db "  or:  date [-u|--utc|--universal] [MMDDhhmm[[CC]YY][.ss]]", 10
    db "Display date and time in the given FORMAT.", 10
    db 10
    db "  -d, --date=STRING          display time described by STRING", 10
    db "  -I[FMT], --iso-8601[=FMT]  output date/time in ISO 8601 format.", 10
    db "  -R, --rfc-email            output date and time in RFC 5322 format.", 10
    db "  -u, --utc, --universal     print Coordinated Universal Time (UTC)", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/date>", 10
    db "or available locally via: info '(coreutils) date invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "date (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by David MacKenzie.", 10
str_version_len equ $ - str_version

str_try:
    db "Try 'date --help' for more information.", 10
str_try_len equ $ - str_try

str_err_prefix:
    db "date: unrecognized option '", 0
str_err_prefix_len equ $ - str_err_prefix - 1

str_err_post:
    db "'", 10, 0
str_err_post_len equ $ - str_err_post - 1

str_clock_err:
    db "date: cannot get time", 10
str_clock_err_len equ $ - str_clock_err

; Non-executable stack
section .note.GNU-stack noalloc noexec nowrite progbits
