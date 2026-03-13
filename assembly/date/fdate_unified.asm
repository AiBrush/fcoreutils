; ============================================================
; fdate_unified.asm — GNU-compatible 'date' command
; Single nasm -f bin file with hand-crafted ELF header.
;
; date: display the system date and time
; - date             — print current date/time in default format
; - date -u          — use UTC
; - date +FORMAT     — custom format string
; - date -R          — RFC 5322 date format
; - date -I[FMT]     — ISO 8601 format
; - date --help / --version
;
; Uses clock_gettime(228) syscall, always UTC.
;
; BUILD:
;   nasm -f bin fdate_unified.asm -o fdate && chmod +x fdate
; ============================================================

BITS 64
ORG 0x400000

; --- Syscall numbers ---
%define SYS_WRITE       1
%define SYS_EXIT       60
%define SYS_CLOCK_GETTIME 228

%define STDOUT          1
%define STDERR          2

; --- ELF Header (64 bytes) ---
ehdr:
    db 0x7f, 'E','L','F'
    db 2, 1, 1, 0
    dq 0
    dw 2
    dw 0x3e
    dd 1
    dq _start
    dq phdr - $$
    dq 0
    dd 0
    dw ehdr_size
    dw phdr_size
    dw 2
    dw 64
    dw 0
    dw 0
ehdr_size equ $ - ehdr

; --- Program Header 1: PT_LOAD ---
phdr:
    dd 1                        ; PT_LOAD
    dd 7                        ; PF_R | PF_W | PF_X
    dq 0
    dq $$
    dq $$
    dq file_size
    dq mem_size
    dq 0x200000
phdr_size equ $ - phdr

; --- Program Header 2: PT_GNU_STACK (NX) ---
    dd 0x6474e551               ; PT_GNU_STACK
    dd 6                        ; PF_R | PF_W
    dq 0, 0, 0, 0, 0
    dq 16

; ===============================================================
; Writable data (initialized, in-file)
; ===============================================================
day_names:
    db "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"
mon_names:
    db "Jan", "Feb", "Mar", "Apr", "May", "Jun"
    db "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
days_per_month:
    db 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
rfc_day_names:
    db "Sun, ", "Mon, ", "Tue, ", "Wed, ", "Thu, ", "Fri, ", "Sat, "

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
            db 0                ; padding
dt_fmt_ptr: dq 0

; ===============================================================
; Code
; ===============================================================

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

format_4digit:
    push    rbx
    push    rcx
    movzx   eax, ax
    xor     edx, edx
    mov     ebx, 1000
    div     ebx
    add     al, '0'
    mov     [num_tmp], al
    mov     eax, edx
    xor     edx, edx
    mov     ebx, 100
    div     ebx
    add     al, '0'
    mov     [num_tmp + 1], al
    mov     eax, edx
    xor     edx, edx
    mov     ebx, 10
    div     ebx
    add     al, '0'
    add     dl, '0'
    mov     [num_tmp + 2], al
    mov     [num_tmp + 3], dl
    movzx   eax, byte [num_tmp]
    movzx   edx, byte [num_tmp + 1]
    shl     edx, 8
    or      eax, edx
    movzx   edx, byte [num_tmp + 2]
    shl     edx, 16
    or      eax, edx
    movzx   edx, byte [num_tmp + 3]
    shl     edx, 24
    or      eax, edx
    pop     rcx
    pop     rbx
    ret

format_day_sp:
    movzx   eax, al
    cmp     eax, 10
    jge     .two
    mov     byte [num_tmp + 10], ' '
    add     al, '0'
    mov     [num_tmp + 11], al
    lea     rsi, [num_tmp + 10]
    ret
.two:
    push    rbx
    xor     edx, edx
    mov     ebx, 10
    div     ebx
    add     al, '0'
    add     dl, '0'
    mov     [num_tmp + 10], al
    mov     [num_tmp + 11], dl
    lea     rsi, [num_tmp + 10]
    pop     rbx
    ret

is_leap:
    mov     rax, rdi
    xor     edx, edx
    push    rbx
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

epoch_to_datetime:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     [dt_epoch], rdi
    mov     rax, rdi
    xor     edx, edx
    mov     rbx, 86400
    div     rbx
    mov     r8, rax
    mov     r9, rdx
    mov     rax, r9
    xor     edx, edx
    mov     rbx, 3600
    div     rbx
    mov     [dt_hour], al
    mov     rax, rdx
    xor     edx, edx
    mov     rbx, 60
    div     rbx
    mov     [dt_min], al
    mov     [dt_sec], dl
    mov     rax, r8
    add     rax, 4
    xor     edx, edx
    mov     rbx, 7
    div     rbx
    mov     [dt_wday], dl
    mov     rax, r8
    mov     r10, 1970
.yl:
    mov     rbx, 365
    push    rax
    mov     rdi, r10
    call    is_leap
    pop     rax
    add     rbx, rdx
    cmp     rax, rbx
    jl      .yf
    sub     rax, rbx
    inc     r10
    jmp     .yl
.yf:
    mov     [dt_year], r10w
    inc     rax
    mov     [dt_yday], ax
    dec     rax
    push    rax
    mov     rdi, r10
    call    is_leap
    pop     rax
    mov     r11, rdx
    lea     rsi, [days_per_month]
    xor     ecx, ecx
.ml:
    movzx   ebx, byte [rsi + rcx]
    cmp     ecx, 1
    jne     .nf
    add     ebx, r11d
.nf:
    cmp     eax, ebx
    jl      .mf
    sub     eax, ebx
    inc     ecx
    cmp     ecx, 11
    jle     .ml
.mf:
    inc     ecx
    mov     [dt_month], cl
    inc     eax
    mov     [dt_day], al
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

emit_year:
    movzx   eax, word [dt_year]
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

emit_hms:
    movzx   eax, byte [dt_hour]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    mov     byte [rdi + rcx], ':'
    inc     rcx
    movzx   eax, byte [dt_min]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    mov     byte [rdi + rcx], ':'
    inc     rcx
    movzx   eax, byte [dt_sec]
    call    format_2digit
    mov     [rdi + rcx], al
    inc     rcx
    mov     [rdi + rcx], ah
    inc     rcx
    ret

_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      _write
    ret

_strlen:
    xor     eax, eax
.l:
    cmp     byte [rdi + rax], 0
    je      .d
    inc     rax
    jmp     .l
.d:
    ret

_strcmp:
.l:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .df
    test    al, al
    jz      .eq
    inc     rdi
    inc     rsi
    jmp     .l
.eq:
    xor     eax, eax
    ret
.df:
    sub     eax, ecx
    ret

_start:
    mov     r14, [rsp]
    lea     r15, [rsp + 8]
    xor     r12d, r12d
    xor     r13d, r13d
    mov     rbx, 1
.pa:
    cmp     rbx, r14
    jge     .ad
    mov     rdi, [r15 + rbx*8]
    push    rbx
    mov     rsi, str_opt_help
    call    _strcmp
    pop     rbx
    test    eax, eax
    jz      .sh
    mov     rdi, [r15 + rbx*8]
    push    rbx
    mov     rsi, str_opt_version
    call    _strcmp
    pop     rbx
    test    eax, eax
    jz      .sv
    mov     rdi, [r15 + rbx*8]
    cmp     byte [rdi], '+'
    jne     .cd
    lea     r13, [rdi + 1]
    mov     r12d, 1
    inc     rbx
    jmp     .pa
.cd:
    cmp     byte [rdi], '-'
    jne     .ua
    movzx   eax, byte [rdi + 1]
    cmp     al, 'u'
    je      .ou
    cmp     al, 'R'
    je      .oR
    cmp     al, 'I'
    je      .oI
    cmp     al, 'd'
    je      .od
    cmp     al, '-'
    je      .cl
    jmp     .ua
.ou:
    cmp     byte [rdi + 2], 0
    jne     .cl
    inc     rbx
    jmp     .pa
.oR:
    cmp     byte [rdi + 2], 0
    jne     .ua
    mov     r12d, 2
    inc     rbx
    jmp     .pa
.oI:
    mov     r12d, 3
    inc     rbx
    jmp     .pa
.od:
    cmp     byte [rdi + 2], 0
    jne     .ua
    add     rbx, 2
    jmp     .pa
.cl:
    mov     rdi, [r15 + rbx*8]
    push    rbx
    mov     rsi, str_opt_utc
    call    _strcmp
    pop     rbx
    test    eax, eax
    jz      .oul
    mov     rdi, [r15 + rbx*8]
    push    rbx
    mov     rsi, str_opt_universal
    call    _strcmp
    pop     rbx
    test    eax, eax
    jz      .oul
    mov     rdi, [r15 + rbx*8]
    push    rbx
    mov     rsi, str_opt_rfc_email
    call    _strcmp
    pop     rbx
    test    eax, eax
    jz      .oRl
    jmp     .ua
.oul:
    inc     rbx
    jmp     .pa
.oRl:
    mov     r12d, 2
    inc     rbx
    jmp     .pa
.ua:
    mov     edi, STDERR
    mov     rsi, str_err_prefix
    mov     edx, str_err_prefix_len
    call    _write
    mov     rdi, [r15 + rbx*8]
    call    _strlen
    mov     rdx, rax
    mov     rsi, [r15 + rbx*8]
    mov     edi, STDERR
    call    _write
    mov     edi, STDERR
    mov     rsi, str_err_post
    mov     edx, str_err_post_len
    call    _write
    mov     edi, STDERR
    mov     rsi, str_try
    mov     edx, str_try_len
    call    _write
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall
.ad:
    mov     [dt_format], r12b
    mov     [dt_fmt_ptr], r13
    sub     rsp, 16
    mov     eax, SYS_CLOCK_GETTIME
    xor     edi, edi
    mov     rsi, rsp
    syscall
    test    rax, rax
    jnz     .cf
    mov     rdi, [rsp]
    add     rsp, 16
    call    epoch_to_datetime
    movzx   eax, byte [dt_format]
    cmp     al, 2
    je      .frfc
    cmp     al, 3
    je      .fiso
    cmp     al, 1
    je      .fcustom

    ; Default format
    lea     rdi, [out_buf]
    xor     ecx, ecx
    movzx   eax, byte [dt_wday]
    imul    eax, 3
    lea     rsi, [day_names]
    add     rsi, rax
    mov     al, [rsi]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+1]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+2]
    mov     [rdi+rcx], al
    inc     rcx
    mov     byte [rdi+rcx], ' '
    inc     rcx
    movzx   eax, byte [dt_month]
    dec     eax
    imul    eax, 3
    lea     rsi, [mon_names]
    add     rsi, rax
    mov     al, [rsi]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+1]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+2]
    mov     [rdi+rcx], al
    inc     rcx
    mov     byte [rdi+rcx], ' '
    inc     rcx
    push    rcx
    push    rdi
    movzx   eax, byte [dt_day]
    call    format_day_sp
    pop     rdi
    pop     rcx
    mov     al, [rsi]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+1]
    mov     [rdi+rcx], al
    inc     rcx
    mov     byte [rdi+rcx], ' '
    inc     rcx
    call    emit_hms
    mov     byte [rdi+rcx], ' '
    inc     rcx
    mov     byte [rdi+rcx], 'U'
    inc     rcx
    mov     byte [rdi+rcx], 'T'
    inc     rcx
    mov     byte [rdi+rcx], 'C'
    inc     rcx
    mov     byte [rdi+rcx], ' '
    inc     rcx
    call    emit_year
    mov     byte [rdi+rcx], 10
    inc     rcx
    jmp     .out

.frfc:
    lea     rdi, [out_buf]
    xor     ecx, ecx
    movzx   eax, byte [dt_wday]
    imul    eax, 5
    lea     rsi, [rfc_day_names]
    add     rsi, rax
    mov     al, [rsi]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+1]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+2]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+3]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+4]
    mov     [rdi+rcx], al
    inc     rcx
    movzx   eax, byte [dt_day]
    call    format_2digit
    mov     [rdi+rcx], al
    inc     rcx
    mov     [rdi+rcx], ah
    inc     rcx
    mov     byte [rdi+rcx], ' '
    inc     rcx
    movzx   eax, byte [dt_month]
    dec     eax
    imul    eax, 3
    lea     rsi, [mon_names]
    add     rsi, rax
    mov     al, [rsi]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+1]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+2]
    mov     [rdi+rcx], al
    inc     rcx
    mov     byte [rdi+rcx], ' '
    inc     rcx
    call    emit_year
    mov     byte [rdi+rcx], ' '
    inc     rcx
    call    emit_hms
    mov     byte [rdi+rcx], ' '
    inc     rcx
    mov     byte [rdi+rcx], '+'
    inc     rcx
    mov     byte [rdi+rcx], '0'
    inc     rcx
    mov     byte [rdi+rcx], '0'
    inc     rcx
    mov     byte [rdi+rcx], '0'
    inc     rcx
    mov     byte [rdi+rcx], '0'
    inc     rcx
    mov     byte [rdi+rcx], 10
    inc     rcx
    jmp     .out

.fiso:
    lea     rdi, [out_buf]
    xor     ecx, ecx
    call    emit_year
    mov     byte [rdi+rcx], '-'
    inc     rcx
    movzx   eax, byte [dt_month]
    call    format_2digit
    mov     [rdi+rcx], al
    inc     rcx
    mov     [rdi+rcx], ah
    inc     rcx
    mov     byte [rdi+rcx], '-'
    inc     rcx
    movzx   eax, byte [dt_day]
    call    format_2digit
    mov     [rdi+rcx], al
    inc     rcx
    mov     [rdi+rcx], ah
    inc     rcx
    mov     byte [rdi+rcx], 10
    inc     rcx
    jmp     .out

.fcustom:
    lea     rdi, [out_buf]
    xor     ecx, ecx
    mov     rbp, [dt_fmt_ptr]
.fl:
    movzx   eax, byte [rbp]
    test    al, al
    jz      .fd
    cmp     al, '%'
    jne     .flit
    inc     rbp
    movzx   eax, byte [rbp]
    test    al, al
    jz      .fd
    cmp     al, 'Y'
    je      .fY
    cmp     al, 'm'
    je      .fm
    cmp     al, 'd'
    je      .fdd
    cmp     al, 'H'
    je      .fH
    cmp     al, 'M'
    je      .fM
    cmp     al, 'S'
    je      .fS
    cmp     al, 'a'
    je      .fa
    cmp     al, 'A'
    je      .fa
    cmp     al, 'b'
    je      .fb
    cmp     al, 'B'
    je      .fb
    cmp     al, 'e'
    je      .fe
    cmp     al, 'Z'
    je      .fZ
    cmp     al, 'n'
    je      .fn
    cmp     al, 't'
    je      .ft
    cmp     al, '%'
    je      .fpc
    cmp     al, 'F'
    je      .fF
    cmp     al, 'T'
    je      .fT
    cmp     al, 'R'
    je      .fRs
    cmp     al, 'u'
    je      .fu
    cmp     al, 'w'
    je      .fw
    cmp     al, 'j'
    je      .fj
    cmp     al, 'p'
    je      .fp
    cmp     al, 'I'
    je      .fI
    cmp     al, 'z'
    je      .fz
    cmp     al, 's'
    je      .fs
    mov     byte [rdi+rcx], '%'
    inc     rcx
    mov     [rdi+rcx], al
    inc     rcx
    inc     rbp
    jmp     .fl
.flit:
    mov     [rdi+rcx], al
    inc     rcx
    inc     rbp
    jmp     .fl
.fY:
    call    emit_year
    inc     rbp
    jmp     .fl
.fm:
    movzx   eax, byte [dt_month]
    call    format_2digit
    mov     [rdi+rcx], al
    inc     rcx
    mov     [rdi+rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fl
.fdd:
    movzx   eax, byte [dt_day]
    call    format_2digit
    mov     [rdi+rcx], al
    inc     rcx
    mov     [rdi+rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fl
.fH:
    movzx   eax, byte [dt_hour]
    call    format_2digit
    mov     [rdi+rcx], al
    inc     rcx
    mov     [rdi+rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fl
.fM:
    movzx   eax, byte [dt_min]
    call    format_2digit
    mov     [rdi+rcx], al
    inc     rcx
    mov     [rdi+rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fl
.fS:
    movzx   eax, byte [dt_sec]
    call    format_2digit
    mov     [rdi+rcx], al
    inc     rcx
    mov     [rdi+rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fl
.fa:
    movzx   eax, byte [dt_wday]
    imul    eax, 3
    lea     rsi, [day_names]
    add     rsi, rax
    mov     al, [rsi]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+1]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+2]
    mov     [rdi+rcx], al
    inc     rcx
    inc     rbp
    jmp     .fl
.fb:
    movzx   eax, byte [dt_month]
    dec     eax
    imul    eax, 3
    lea     rsi, [mon_names]
    add     rsi, rax
    mov     al, [rsi]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+1]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+2]
    mov     [rdi+rcx], al
    inc     rcx
    inc     rbp
    jmp     .fl
.fe:
    push    rcx
    push    rdi
    movzx   eax, byte [dt_day]
    call    format_day_sp
    pop     rdi
    pop     rcx
    mov     al, [rsi]
    mov     [rdi+rcx], al
    inc     rcx
    mov     al, [rsi+1]
    mov     [rdi+rcx], al
    inc     rcx
    inc     rbp
    jmp     .fl
.fZ:
    mov     byte [rdi+rcx], 'U'
    inc     rcx
    mov     byte [rdi+rcx], 'T'
    inc     rcx
    mov     byte [rdi+rcx], 'C'
    inc     rcx
    inc     rbp
    jmp     .fl
.fn:
    mov     byte [rdi+rcx], 10
    inc     rcx
    inc     rbp
    jmp     .fl
.ft:
    mov     byte [rdi+rcx], 9
    inc     rcx
    inc     rbp
    jmp     .fl
.fpc:
    mov     byte [rdi+rcx], '%'
    inc     rcx
    inc     rbp
    jmp     .fl
.fF:
    call    emit_year
    mov     byte [rdi+rcx], '-'
    inc     rcx
    movzx   eax, byte [dt_month]
    call    format_2digit
    mov     [rdi+rcx], al
    inc     rcx
    mov     [rdi+rcx], ah
    inc     rcx
    mov     byte [rdi+rcx], '-'
    inc     rcx
    movzx   eax, byte [dt_day]
    call    format_2digit
    mov     [rdi+rcx], al
    inc     rcx
    mov     [rdi+rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fl
.fT:
    call    emit_hms
    inc     rbp
    jmp     .fl
.fRs:
    movzx   eax, byte [dt_hour]
    call    format_2digit
    mov     [rdi+rcx], al
    inc     rcx
    mov     [rdi+rcx], ah
    inc     rcx
    mov     byte [rdi+rcx], ':'
    inc     rcx
    movzx   eax, byte [dt_min]
    call    format_2digit
    mov     [rdi+rcx], al
    inc     rcx
    mov     [rdi+rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fl
.fu:
    movzx   eax, byte [dt_wday]
    test    eax, eax
    jnz     .fu_ok
    mov     eax, 7
.fu_ok:
    add     al, '0'
    mov     [rdi+rcx], al
    inc     rcx
    inc     rbp
    jmp     .fl
.fw:
    movzx   eax, byte [dt_wday]
    add     al, '0'
    mov     [rdi+rcx], al
    inc     rcx
    inc     rbp
    jmp     .fl
.fj:
    movzx   eax, word [dt_yday]
    push    rbx
    xor     edx, edx
    mov     ebx, 100
    div     ebx
    add     al, '0'
    mov     [rdi+rcx], al
    inc     rcx
    mov     eax, edx
    call    format_2digit
    mov     [rdi+rcx], al
    inc     rcx
    mov     [rdi+rcx], ah
    inc     rcx
    pop     rbx
    inc     rbp
    jmp     .fl
.fp:
    movzx   eax, byte [dt_hour]
    cmp     eax, 12
    jge     .fpm
    mov     byte [rdi+rcx], 'A'
    inc     rcx
    mov     byte [rdi+rcx], 'M'
    inc     rcx
    inc     rbp
    jmp     .fl
.fpm:
    mov     byte [rdi+rcx], 'P'
    inc     rcx
    mov     byte [rdi+rcx], 'M'
    inc     rcx
    inc     rbp
    jmp     .fl
.fI:
    movzx   eax, byte [dt_hour]
    test    eax, eax
    jnz     .fI_nz
    mov     eax, 12
    jmp     .fI_o
.fI_nz:
    cmp     eax, 12
    jle     .fI_o
    sub     eax, 12
.fI_o:
    call    format_2digit
    mov     [rdi+rcx], al
    inc     rcx
    mov     [rdi+rcx], ah
    inc     rcx
    inc     rbp
    jmp     .fl
.fz:
    mov     byte [rdi+rcx], '+'
    inc     rcx
    mov     byte [rdi+rcx], '0'
    inc     rcx
    mov     byte [rdi+rcx], '0'
    inc     rcx
    mov     byte [rdi+rcx], '0'
    inc     rcx
    mov     byte [rdi+rcx], '0'
    inc     rcx
    inc     rbp
    jmp     .fl
.fs:
    mov     rax, [dt_epoch]
    lea     rsi, [num_tmp + 20]
    mov     byte [rsi], 0
    push    rbx
    mov     rbx, 10
.fsl:
    xor     edx, edx
    div     rbx
    add     dl, '0'
    dec     rsi
    mov     [rsi], dl
    test    rax, rax
    jnz     .fsl
    pop     rbx
.fsc:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .fsd
    mov     [rdi+rcx], al
    inc     rcx
    inc     rsi
    jmp     .fsc
.fsd:
    inc     rbp
    jmp     .fl
.fd:
    mov     byte [rdi+rcx], 10
    inc     rcx
    jmp     .out

.out:
    mov     rdx, rcx
    lea     rsi, [out_buf]
    mov     edi, STDOUT
    call    _write
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.cf:
    mov     edi, STDERR
    mov     rsi, str_clock_err
    mov     edx, str_clock_err_len
    call    _write
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.sh:
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    _write
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.sv:
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    _write
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

; ===============================================================
; RODATA
; ===============================================================

str_help:
    db "Usage: date [OPTION]... [+FORMAT]", 10
    db "  or:  date [-u|--utc|--universal] [MMDDhhmm[[CC]YY][.ss]]", 10
    db "Display date and time in the given FORMAT.", 10, 10
    db "  -d, --date=STRING          display time described by STRING", 10
    db "  -I[FMT], --iso-8601[=FMT]  output date/time in ISO 8601 format.", 10
    db "  -R, --rfc-email            output date and time in RFC 5322 format.", 10
    db "  -u, --utc, --universal     print Coordinated Universal Time (UTC)", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
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
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
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

; ===============================================================
; BSS (uninitialized data — zero-filled by ELF loader)
; ===============================================================
file_size equ $ - $$

bss_base    equ $$ + file_size

out_buf     equ bss_base + 0            ; 256 bytes
num_tmp     equ bss_base + 256          ; 32 bytes

bss_end     equ bss_base + 288
mem_size    equ bss_end - $$
