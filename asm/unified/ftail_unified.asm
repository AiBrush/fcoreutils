; ftail_unified_opt.asm — Size-optimized GNU-compatible "tail"
; Build: nasm -f bin ftail_unified_opt.asm -o ftail_tiny && chmod +x ftail_tiny
BITS 64
org 0x400000

%define SYS_READ    0
%define SYS_WRITE   1
%define SYS_OPEN    2
%define SYS_CLOSE   3
%define SYS_FSTAT   5
%define SYS_LSEEK   8
%define SYS_MMAP    9
%define SYS_MUNMAP  11
%define SYS_SIGPROCMASK 14
%define SYS_EXIT    60

%define STDIN   0
%define STDOUT  1
%define STDERR  2
%define SEEK_SET 0
%define S_IFMT  0xF000
%define S_IFREG 0x8000
%define EINTR   -4
%define RDBUF_SZ 65536
%define STDIN_ALLOC (256*1024*1024)
%define MAX_FILES 1024
%define STAT_SIZE 144

; BSS follows file_end in memory (single PT_LOAD, memsz > filesz)
%define V_MODE      (file_end)
%define V_COUNT     (file_end+8)
%define V_DELIM     (file_end+16)
%define V_QUIET     (file_end+17)
%define V_VERBOSE   (file_end+18)
%define V_HADERROR  (file_end+19)
%define V_FIRSTFILE (file_end+20)
%define V_SHOWHDR   (file_end+21)
%define V_SKIPTRAIL (file_end+22)
%define V_FILECOUNT (file_end+24)
%define V_ARGC      (file_end+32)
%define V_ARGVBASE  (file_end+40)
%define FILE_PTRS   (file_end+48)
%define RDBUF       (file_end+48+MAX_FILES*8)
%define BSS_SIZE    (48+MAX_FILES*8+RDBUF_SZ)

; ======================== ELF Header ========================================
ehdr:
    db 0x7F,"ELF",2,1,1,0     ; magic, 64-bit, LE, v1, SysV
    dq 0                       ; padding
    dw 2                       ; ET_EXEC
    dw 0x3E                    ; x86-64
    dd 1                       ; version
    dq _start                  ; entry
    dq phdr - ehdr             ; phoff
    dq 0                       ; shoff
    dd 0                       ; flags
    dw ehdr_end - ehdr         ; ehsize
    dw phdr_size               ; phentsize
    dw 2                       ; phnum (code+BSS merged, GNU_STACK)
    dw 0,0,0                   ; section header unused
ehdr_end:

phdr:
    dd 1                       ; PT_LOAD
    dd 7                       ; PF_R|PF_W|PF_X
    dq 0                       ; offset
    dq 0x400000                ; vaddr
    dq 0x400000                ; paddr
    dq file_end - ehdr         ; filesz
    dq file_end - ehdr + BSS_SIZE ; memsz
    dq 0x1000                  ; align
phdr_size equ $ - phdr

    dd 0x6474E551              ; PT_GNU_STACK
    dd 6                       ; PF_R|PF_W (NX)
    dq 0,0,0,0,0
    dq 0x10                    ; align

; ======================== CODE ==============================================
_start:
    pop rcx
    mov [V_ARGC], rcx
    mov r14, rsp
    mov [V_ARGVBASE], r14

    ; Block SIGPIPE
    push rcx
    sub rsp, 16
    mov qword [rsp], 0x1000
    xor edi, edi
    mov rsi, rsp
    xor edx, edx
    mov r10d, 8
    mov eax, SYS_SIGPROCMASK
    syscall
    add rsp, 16
    pop rcx

    ; Init non-zero defaults (BSS is zero from kernel)
    mov qword [V_COUNT], 10
    mov byte [V_DELIM], 10

    call parse_args

    ; Determine show_headers
    cmp byte [V_QUIET], 0
    jne .no_hdr
    cmp byte [V_VERBOSE], 0
    jne .yes_hdr
    cmp qword [V_FILECOUNT], 1
    jle .no_hdr
.yes_hdr:
    mov byte [V_SHOWHDR], 1
.no_hdr:

    ; Default to stdin
    cmp qword [V_FILECOUNT], 0
    jne .have_files
    mov rax, str_dash
    mov [FILE_PTRS], rax
    mov qword [V_FILECOUNT], 1
.have_files:

    xor r12d, r12d
    mov byte [V_FIRSTFILE], 1
.file_loop:
    cmp r12, [V_FILECOUNT]
    jge .done
    mov rdi, [FILE_PTRS + r12*8]
    call process_file
    inc r12
    jmp .file_loop
.done:
    movzx edi, byte [V_HADERROR]
    jmp exit_code

; ---- Shared helpers ----
; die_err: write [rsi, edx] to stderr, exit(1)
die_err:
    mov edi, STDERR
    call write_all
    mov edi, 1
exit_code:
    mov eax, SYS_EXIT
    syscall

; die_err_try: write [rsi, edx] to stderr, then "Try..." suffix, exit(1)
die_err_try:
    mov edi, STDERR
    call write_all
    mov esi, err_try_help
    mov edx, err_try_help_len
    jmp die_err

; ======================== ARGUMENT PARSING ==================================
parse_args:
    push rbx
    push r12
    push r13
    push r15
    mov rcx, [V_ARGC]
    cmp rcx, 2
    jl .pa_done
    lea rbx, [r14+8]
    xor r15d, r15d

.pa_loop:
    mov rsi, [rbx]
    test rsi, rsi
    jz .pa_done
    test r15d, r15d
    jnz .pa_add_file
    cmp byte [rsi], '-'
    jne .pa_add_file
    cmp byte [rsi+1], 0
    je .pa_add_file
    cmp byte [rsi+1], '-'
    je .pa_long_opt
    inc rsi

.pa_short_loop:
    movzx eax, byte [rsi]
    test al, al
    jz .pa_next
    cmp al, 'n'
    je .pa_n
    cmp al, 'c'
    je .pa_c
    cmp al, 'q'
    je .pa_q
    cmp al, 'v'
    je .pa_v
    cmp al, 'z'
    je .pa_z
    cmp al, 'f'
    je .pa_ign
    cmp al, 'F'
    je .pa_ign
    cmp al, 's'
    je .pa_s_skip
    cmp al, '+'
    je .pa_legacy
    cmp al, '0'
    jb .pa_inval
    cmp al, '9'
    jbe .pa_legacy

.pa_inval:
    movzx r12d, byte [rsi]
    mov esi, err_inval_pre
    mov edx, err_inval_pre_len
    mov edi, STDERR
    call write_all
    push r12
    mov edi, STDERR
    mov rsi, rsp
    mov edx, 1
    call write_all
    pop r12
    mov esi, err_try_suffix
    mov edx, err_try_suffix_len
    jmp die_err

.pa_n:
    inc rsi
    cmp byte [rsi], 0
    jne .pa_nval
    add rbx, 8
    mov rsi, [rbx]
    test rsi, rsi
    jnz .pa_nval
    mov esi, err_n_req
    mov edx, err_n_req_len
    jmp die_err_try
.pa_nval:
    mov r13, rsi             ; save original value for error messages
    cmp byte [rsi], '+'
    je .pa_nfrom
    cmp byte [rsi], '-'
    jne .pa_nlast
    inc rsi
.pa_nlast:
    call parse_number
    test edx, edx
    jnz .pa_bad_lines
    mov qword [V_MODE], 0    ; MODE_LINES
    mov [V_COUNT], rax
    jmp .pa_next
.pa_nfrom:
    inc rsi
    call parse_number
    test edx, edx
    jnz .pa_bad_lines
    mov qword [V_MODE], 1    ; MODE_LINES_FROM
    mov [V_COUNT], rax
    jmp .pa_next
.pa_bad_lines:
    mov esi, err_bad_lines_pre
    mov edx, err_bad_lines_pre_len
    mov edi, STDERR
    call write_all
    mov rdi, r13
    call strlen_fn
    mov edx, eax
    mov edi, STDERR
    mov rsi, r13
    call write_all
    mov esi, err_bad_val_suf
    mov edx, err_bad_val_suf_len
    jmp die_err

.pa_c:
    inc rsi
    cmp byte [rsi], 0
    jne .pa_cval
    add rbx, 8
    mov rsi, [rbx]
    test rsi, rsi
    jnz .pa_cval
    mov esi, err_c_req
    mov edx, err_c_req_len
    jmp die_err_try
.pa_cval:
    mov r13, rsi             ; save original value for error messages
    cmp byte [rsi], '+'
    je .pa_cfrom
    cmp byte [rsi], '-'
    jne .pa_clast
    inc rsi
.pa_clast:
    call parse_number
    test edx, edx
    jnz .pa_bad_bytes
    mov qword [V_MODE], 2    ; MODE_BYTES
    mov [V_COUNT], rax
    jmp .pa_next
.pa_cfrom:
    inc rsi
    call parse_number
    test edx, edx
    jnz .pa_bad_bytes
    mov qword [V_MODE], 3    ; MODE_BYTES_FROM
    mov [V_COUNT], rax
    jmp .pa_next
.pa_bad_bytes:
    mov esi, err_bad_bytes_pre
    mov edx, err_bad_bytes_pre_len
    mov edi, STDERR
    call write_all
    mov rdi, r13
    call strlen_fn
    mov edx, eax
    mov edi, STDERR
    mov rsi, r13
    call write_all
    mov esi, err_bad_val_suf
    mov edx, err_bad_val_suf_len
    jmp die_err

.pa_q:
    mov byte [V_QUIET], 1
    inc rsi
    jmp .pa_short_loop
.pa_v:
    mov byte [V_VERBOSE], 1
    inc rsi
    jmp .pa_short_loop
.pa_z:
    mov byte [V_DELIM], 0
    inc rsi
    jmp .pa_short_loop
.pa_ign:
    inc rsi
    jmp .pa_short_loop
.pa_s_skip:
    inc rsi
    cmp byte [rsi], 0
    jne .pa_next
    add rbx, 8
    jmp .pa_next

.pa_legacy:
    cmp byte [rsi], '+'
    je .pa_leg_from
    call parse_number
    test edx, edx
    jnz .pa_next
    mov qword [V_MODE], 0
    mov [V_COUNT], rax
    jmp .pa_next
.pa_leg_from:
    inc rsi
    call parse_number
    test edx, edx
    jnz .pa_next
    mov qword [V_MODE], 1
    mov [V_COUNT], rax
    jmp .pa_next

; ---- Long options ----
.pa_long_opt:
    cmp byte [rsi+2], 0
    je .pa_set_past

    mov rdi, str_help_opt
    call str_eq
    je .pa_help
    mov rdi, str_version_opt
    call str_eq
    je .pa_version

    lea rdi, [str_lines_opt]
    mov r13, rsi
    call str_startswith
    je .pa_ll

    mov rsi, r13
    lea rdi, [str_bytes_opt]
    call str_startswith
    je .pa_lb

    mov rsi, r13
    mov rdi, str_quiet_opt
    call str_eq
    je .pa_q_long
    mov rsi, r13
    mov rdi, str_silent_opt
    call str_eq
    je .pa_q_long
    mov rsi, r13
    mov rdi, str_verbose_opt
    call str_eq
    je .pa_v_long
    mov rsi, r13
    mov rdi, str_zero_opt
    call str_eq
    je .pa_z_long

    ; Accept follow/retry/pid/sleep/max-unchanged-stats silently
    mov rsi, r13
    mov rdi, str_follow_opt
    call str_startswith
    je .pa_next
    mov rsi, r13
    mov rdi, str_follow_opt
    call str_eq
    je .pa_next
    mov rsi, r13
    mov rdi, str_retry_opt
    call str_eq
    je .pa_next
    mov rsi, r13
    mov rdi, str_pid_opt
    call str_startswith
    je .pa_next
    mov rsi, r13
    mov rdi, str_pid_opt
    call str_eq
    je .pa_skip_next
    mov rsi, r13
    mov rdi, str_sleep_opt
    call str_startswith
    je .pa_next
    mov rsi, r13
    mov rdi, str_sleep_opt
    call str_eq
    je .pa_skip_next
    mov rsi, r13
    mov rdi, str_maxu_opt
    call str_startswith
    je .pa_next
    mov rsi, r13
    mov rdi, str_maxu_opt
    call str_eq
    je .pa_skip_next

    ; Unrecognized long option
    mov rsi, r13
    mov esi, err_unrec_pre
    mov edx, err_unrec_pre_len
    mov edi, STDERR
    call write_all
    mov rdi, r13
    call strlen_fn
    mov edx, eax
    mov edi, STDERR
    mov rsi, r13
    call write_all
    mov esi, err_try_suffix
    mov edx, err_try_suffix_len
    jmp die_err

.pa_ll:
    cmp byte [rsi], 0
    jne .pa_nval
    add rbx, 8
    mov rsi, [rbx]
    test rsi, rsi
    jnz .pa_nval
    mov esi, err_lines_req
    mov edx, err_lines_req_len
    jmp die_err_try

.pa_lb:
    cmp byte [rsi], 0
    jne .pa_cval
    add rbx, 8
    mov rsi, [rbx]
    test rsi, rsi
    jnz .pa_cval
    mov esi, err_bytes_req
    mov edx, err_bytes_req_len
    jmp die_err_try

.pa_q_long:
    mov byte [V_QUIET], 1
    jmp .pa_next
.pa_v_long:
    mov byte [V_VERBOSE], 1
    jmp .pa_next
.pa_z_long:
    mov byte [V_DELIM], 0
    jmp .pa_next

.pa_help:
    mov edi, STDOUT
    mov esi, help_text
    mov edx, help_text_len
    call write_all
    xor edi, edi
    jmp exit_code

.pa_version:
    mov edi, STDOUT
    mov esi, version_text
    mov edx, version_text_len
    call write_all
    xor edi, edi
    jmp exit_code

.pa_set_past:
    mov r15d, 1
    jmp .pa_next
.pa_skip_next:
    add rbx, 8
.pa_next:
    add rbx, 8
    jmp .pa_loop

.pa_add_file:
    mov rcx, [V_FILECOUNT]
    cmp rcx, MAX_FILES
    jge .pa_next
    mov [FILE_PTRS + rcx*8], rsi
    inc qword [V_FILECOUNT]
    jmp .pa_next

.pa_done:
    pop r15
    pop r13
    pop r12
    pop rbx
    ret

; ======================== STRING HELPERS ====================================
; str_eq: compare rsi vs rdi (null-terminated), ZF=equal
str_eq:
    push rsi
    push rdi
.loop:
    movzx eax, byte [rdi]
    cmp al, [rsi]
    jne .ne
    test al, al
    jz .eq
    inc rdi
    inc rsi
    jmp .loop
.eq:
    pop rdi
    pop rsi
    xor eax, eax
    ret
.ne:
    pop rdi
    pop rsi
    or eax, 1
    ret

; str_startswith: rsi starts with rdi prefix, then '=' or '\0'
; On match: ZF set, rsi past prefix (past '=' if present)
str_startswith:
    push r8
    mov r8, rsi
.sw_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .sw_end
    cmp al, [rsi]
    jne .sw_no
    inc rdi
    inc rsi
    jmp .sw_loop
.sw_end:
    cmp byte [rsi], '='
    je .sw_eq
    cmp byte [rsi], 0
    je .sw_yes
.sw_no:
    mov rsi, r8
    pop r8
    or eax, 1
    ret
.sw_eq:
    inc rsi
.sw_yes:
    pop r8
    xor eax, eax
    ret

; ======================== NUMBER PARSING ====================================
; parse_number: rsi → rax=number, edx=0 ok / 1 error
parse_number:
    push rbx
    push rcx
    xor eax, eax
    xor ecx, ecx
.digit:
    movzx edx, byte [rsi]
    sub dl, '0'
    cmp dl, 9
    ja .suffix
    imul rax, 10
    jo .overflow
    movzx edx, byte [rsi]
    sub dl, '0'
    add rax, rdx
    inc rsi
    inc ecx
    jmp .digit

.suffix:
    test ecx, ecx
    jz .error
    movzx edx, byte [rsi]
    test dl, dl
    jz .ok

    mov rbx, rax   ; save number
    cmp dl, 'b'
    jne .not_b
    inc rsi
    mov rcx, 512
    jmp .mul
.not_b:
    cmp dl, 'k'
    jne .not_k
    inc rsi
    cmp byte [rsi], 'B'
    jne .error
    inc rsi
    mov rcx, 1000
    jmp .mul
.not_k:
    ; Table lookup for K/M/G/T/P/E
    lea r8, [suffix_tab]
.scan:
    movzx ecx, byte [r8]
    test cl, cl
    jz .error
    cmp dl, cl
    je .found
    add r8, 17
    jmp .scan
.found:
    inc rsi
    movzx edx, byte [rsi]
    cmp dl, 'B'
    je .decimal
    cmp dl, 'i'
    jne .binary
    inc rsi
    cmp byte [rsi], 'B'
    jne .error
    inc rsi
.binary:
    mov rcx, [r8+1]
    jmp .mul
.decimal:
    inc rsi
    mov rcx, [r8+9]
    jmp .mul

.mul:
    mov rax, rbx
    imul rax, rcx
    jo .overflow
    cmp byte [rsi], 0
    jne .error
.ok:
    xor edx, edx
    pop rcx
    pop rbx
    ret
.overflow:
    mov rax, -1
    xor edx, edx
    pop rcx
    pop rbx
    ret
.error:
    xor eax, eax
    mov edx, 1
    pop rcx
    pop rbx
    ret

; Suffix table: char(1) + binary_mult(8) + decimal_mult(8) = 17 bytes each
suffix_tab:
    db 'K'
    dq 1024, 1000
    db 'M'
    dq 1048576, 1000000
    db 'G'
    dq 1073741824, 1000000000
    db 'T'
    dq 1099511627776, 1000000000000
    db 'P'
    dq 1125899906842624, 1000000000000000
    db 'E'
    dq 1152921504606846976, 1000000000000000000
    db 0     ; terminator

; ======================== FILE PROCESSING ===================================
process_file:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, STAT_SIZE
    mov r12, rdi

    ; Check stdin marker
    mov rdi, r12
    mov rsi, str_dash
    call str_eq
    je .pf_stdin

    mov rdi, r12
    xor esi, esi
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .pf_open_err
    mov r14, rax
    jmp .pf_opened

.pf_stdin:
    xor r14d, r14d
.pf_opened:
    ; Print header
    cmp byte [V_SHOWHDR], 0
    je .pf_no_hdr
    cmp byte [V_FIRSTFILE], 1
    je .pf_first
    mov edi, STDOUT
    mov esi, str_nl
    mov edx, 1
    call write_all
.pf_first:
    mov edi, STDOUT
    mov esi, str_hdr_pre
    mov edx, 4
    call write_all
    ; Display name
    mov rdi, r12
    mov rsi, str_dash
    push r14
    call str_eq
    pop r14
    je .pf_hdr_stdin
    mov r13, r12
    jmp .pf_hdr_name
.pf_hdr_stdin:
    mov r13, str_stdin_name
.pf_hdr_name:
    mov rdi, r13
    call strlen_fn
    mov edx, eax
    mov edi, STDOUT
    mov rsi, r13
    call write_all
    mov edi, STDOUT
    mov esi, str_hdr_suf
    mov edx, 5
    call write_all
.pf_no_hdr:
    mov byte [V_FIRSTFILE], 0

    ; fstat
    mov eax, SYS_FSTAT
    mov rdi, r14
    mov rsi, rsp
    syscall
    test rax, rax
    js .pf_nosek
    mov eax, [rsp+24]
    and eax, S_IFMT
    cmp eax, S_IFREG
    jne .pf_nosek
    mov r15, [rsp+48]

    ; Dispatch seekable
    mov rdi, r14
    mov rsi, r15
    mov rdx, [V_COUNT]
    movzx ecx, byte [V_DELIM]
    cmp qword [V_MODE], 0
    je .pf_sk_lines
    cmp qword [V_MODE], 1
    je .pf_sk_lfrom
    cmp qword [V_MODE], 2
    je .pf_sk_bytes
    jmp .pf_sk_bfrom

.pf_sk_lines:
    call tail_seekable_lines
    jmp .pf_close
.pf_sk_lfrom:
    call tail_seekable_lines_from
    jmp .pf_close
.pf_sk_bytes:
    call tail_seekable_bytes
    jmp .pf_close
.pf_sk_bfrom:
    call tail_seekable_bytes_from
    jmp .pf_close

.pf_nosek:
    mov rdi, r14
    call read_all_input
    test rax, rax
    jz .pf_close
    mov r13, rax
    mov r15, rdx

    cmp qword [V_MODE], 0
    je .pb_lines
    cmp qword [V_MODE], 1
    je .pb_lfrom
    cmp qword [V_MODE], 2
    je .pb_bytes
    jmp .pb_bfrom

.pb_lines:
    mov rdi, r13
    mov rsi, r15
    mov rdx, [V_COUNT]
    movzx ecx, byte [V_DELIM]
    call backward_scan
    lea rsi, [r13+rax]
    mov rdx, r15
    sub rdx, rax
    jmp .pb_write

.pb_lfrom:
    mov rdi, r13
    mov rsi, r15
    mov rdx, [V_COUNT]
    movzx ecx, byte [V_DELIM]
    call forward_skip_lines
    lea rsi, [r13+rax]
    mov rdx, r15
    sub rdx, rax
    jmp .pb_write

.pb_bytes:
    mov rax, [V_COUNT]
    cmp rax, r15
    jae .pb_ball
    mov rdx, rax
    lea rsi, [r13+r15]
    sub rsi, rdx
    jmp .pb_write
.pb_ball:
    mov rsi, r13
    mov rdx, r15
    jmp .pb_write

.pb_bfrom:
    mov rax, [V_COUNT]
    test rax, rax
    jz .pb_bfall
    dec rax
    cmp rax, r15
    jae .pb_done
    lea rsi, [r13+rax]
    mov rdx, r15
    sub rdx, rax
    jmp .pb_write
.pb_bfall:
    mov rsi, r13
    mov rdx, r15

.pb_write:
    test rdx, rdx
    jz .pb_done
    mov edi, STDOUT
    call write_all
.pb_done:
    mov eax, SYS_MUNMAP
    mov rdi, r13
    mov esi, STDIN_ALLOC
    syscall
    jmp .pf_close

.pf_open_err:
    mov byte [V_HADERROR], 1
    mov edi, STDERR
    mov esi, err_open_pre
    mov edx, err_open_pre_len
    call write_all
    mov rdi, r12
    call strlen_fn
    mov edx, eax
    mov edi, STDERR
    mov rsi, r12
    call write_all
    mov edi, STDERR
    mov esi, err_open_suf
    mov edx, err_open_suf_len
    call write_all
    jmp .pf_ret

.pf_close:
    test r14, r14
    jz .pf_ret
    mov rdi, r14
    mov eax, SYS_CLOSE
    syscall
.pf_ret:
    add rsp, STAT_SIZE
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ======================== SEEKABLE TAIL =====================================
tail_seekable_lines:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx

    test r13, r13
    jz .tsl_done
    test r12, r12
    jz .tsl_done

    mov r15, r12
    xor ebp, ebp
    mov byte [V_SKIPTRAIL], 1

.tsl_chunk:
    mov rax, r15
    sub rax, RDBUF_SZ
    jns .tsl_ok
    xor eax, eax
.tsl_ok:
    mov rcx, r15
    sub rcx, rax
    test rcx, rcx
    jz .tsl_all
    push rax
    push rcx
    mov rdi, rbx
    mov rsi, rax
    xor edx, edx
    mov eax, SYS_LSEEK
    syscall
    pop rdx
    push rdx
    mov rdi, rbx
    mov esi, RDBUF
    mov eax, SYS_READ
    syscall
    pop rcx
    pop r8

    mov edi, RDBUF
    mov rsi, rcx

    cmp byte [V_SKIPTRAIL], 0
    je .tsl_scan
    mov byte [V_SKIPTRAIL], 0
    dec rsi
    test rsi, rsi
    jz .tsl_scan_end
    movzx eax, byte [rdi+rsi]
    cmp al, r14b
    jne .tsl_scan

.tsl_scan:
    test rsi, rsi
    jz .tsl_scan_end
    dec rsi
    movzx eax, byte [rdi+rsi]
    cmp al, r14b
    jne .tsl_scan
    inc ebp
    cmp rbp, r13
    jge .tsl_found
    jmp .tsl_scan

.tsl_scan_end:
    mov r15, r8
    test r15, r15
    jnz .tsl_chunk

.tsl_all:
    xor r8d, r8d
    jmp .tsl_out
.tsl_found:
    lea r8, [r8+rsi+1]
.tsl_out:
    mov rdi, rbx
    mov rsi, r8
    xor edx, edx
    mov eax, SYS_LSEEK
    syscall
    mov rdi, rbx
    call copy_fd_to_stdout

.tsl_done:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

tail_seekable_bytes:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    test rdx, rdx
    jz .tsb_done
    mov rax, r12
    sub rax, rdx
    jns .tsb_sk
    xor eax, eax
.tsb_sk:
    mov rdi, rbx
    mov rsi, rax
    xor edx, edx
    mov eax, SYS_LSEEK
    syscall
    mov rdi, rbx
    call copy_fd_to_stdout
.tsb_done:
    pop r12
    pop rbx
    ret

tail_seekable_lines_from:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    cmp r13, 1
    jbe .tslf_all
    dec r13
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    mov eax, SYS_LSEEK
    syscall
    xor r15d, r15d
.tslf_rd:
    mov rdi, rbx
    mov esi, RDBUF
    mov edx, RDBUF_SZ
    call asm_read
    test rax, rax
    jle .tslf_done
    mov edi, RDBUF
    xor ecx, ecx
.tslf_sc:
    cmp rcx, rax
    jge .tslf_rd
    movzx edx, byte [rdi+rcx]
    inc rcx
    cmp dl, r14b
    jne .tslf_sc
    inc r15
    cmp r15, r13
    jge .tslf_fnd
    jmp .tslf_sc
.tslf_fnd:
    mov rdx, rax
    sub rdx, rcx
    test rdx, rdx
    jz .tslf_rest
    lea esi, [RDBUF]
    add rsi, rcx
    mov edi, STDOUT
    call write_all
.tslf_rest:
    mov rdi, rbx
    call copy_fd_to_stdout
    jmp .tslf_done
.tslf_all:
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    mov eax, SYS_LSEEK
    syscall
    mov rdi, rbx
    call copy_fd_to_stdout
.tslf_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

tail_seekable_bytes_from:
    push rbx
    mov rbx, rdi
    mov rax, rdx
    test rax, rax
    jz .tsbf_z
    dec rax
    cmp rax, rsi
    jbe .tsbf_sk
    pop rbx
    ret
.tsbf_z:
    xor eax, eax
.tsbf_sk:
    mov rdi, rbx
    mov rsi, rax
    xor edx, edx
    mov eax, SYS_LSEEK
    syscall
    mov rdi, rbx
    call copy_fd_to_stdout
    pop rbx
    ret

; ======================== NON-SEEKABLE INPUT ================================
read_all_input:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov eax, SYS_MMAP
    xor edi, edi
    mov esi, STDIN_ALLOC
    mov edx, 3
    mov r10d, 0x22
    mov r8d, -1
    xor r9d, r9d
    syscall
    cmp rax, -1
    je .rai_err
    mov r12, rax
    xor r13d, r13d
.rai_loop:
    mov rax, STDIN_ALLOC
    sub rax, r13
    cmp rax, RDBUF_SZ
    jl .rai_sm
    mov edx, RDBUF_SZ
    jmp .rai_do
.rai_sm:
    test rax, rax
    jz .rai_eof
    mov rdx, rax
.rai_do:
    mov rdi, rbx
    lea rsi, [r12+r13]
    call asm_read
    test rax, rax
    jle .rai_eof
    add r13, rax
    jmp .rai_loop
.rai_eof:
    mov rax, r12
    mov rdx, r13
    pop r13
    pop r12
    pop rbx
    ret
.rai_err:
    xor eax, eax
    xor edx, edx
    pop r13
    pop r12
    pop rbx
    ret

; ======================== BUFFER SCANNING (scalar only) =====================
backward_scan:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx

    test r13, r13
    jz .bs_end
    test r12, r12
    jz .bs_start

    mov rsi, r12
    xor edx, edx

    ; Skip trailing delimiter
    dec rsi
    movzx eax, byte [rbx+rsi]
    cmp al, cl
    jne .bs_sc

.bs_sc:
    test rsi, rsi
    jz .bs_start
    dec rsi
    movzx eax, byte [rbx+rsi]
    cmp al, cl
    jne .bs_sc
    inc edx
    cmp edx, r13d
    jge .bs_found
    jmp .bs_sc

.bs_found:
    lea rax, [rsi+1]
    jmp .bs_ret
.bs_start:
    xor eax, eax
    jmp .bs_ret
.bs_end:
    mov rax, r12
.bs_ret:
    pop r13
    pop r12
    pop rbx
    ret

forward_skip_lines:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    cmp rdx, 1
    jbe .fsl_zero
    dec rdx
    xor eax, eax
.fsl_sc:
    cmp rax, r12
    jge .fsl_past
    movzx r8d, byte [rbx+rax]
    inc rax
    cmp r8b, cl
    jne .fsl_sc
    dec rdx
    jz .fsl_ret
    jmp .fsl_sc
.fsl_past:
    mov rax, r12
    jmp .fsl_ret
.fsl_zero:
    xor eax, eax
.fsl_ret:
    pop r12
    pop rbx
    ret

; ======================== I/O FUNCTIONS =====================================
write_all:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
.wa_lp:
    test r13d, r13d
    jle .wa_ok
    mov edi, ebx
    mov rsi, r12
    mov edx, r13d
    mov eax, SYS_WRITE
    syscall
    cmp rax, EINTR
    je .wa_lp
    test rax, rax
    js .wa_err
    add r12, rax
    sub r13, rax
    jmp .wa_lp
.wa_ok:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret
.wa_err:
    mov rax, -1
    pop r13
    pop r12
    pop rbx
    ret

asm_read:
.retry:
    mov eax, SYS_READ
    syscall
    cmp rax, EINTR
    je .retry
    ret

copy_fd_to_stdout:
    push rbx
    mov rbx, rdi
.lp:
    mov rdi, rbx
    mov esi, RDBUF
    mov edx, RDBUF_SZ
    call asm_read
    test rax, rax
    jle .dn
    mov edx, eax
    mov edi, STDOUT
    mov esi, RDBUF
    call write_all
    cmp rax, -1
    je .dn
    jmp .lp
.dn:
    pop rbx
    ret

strlen_fn:
    xor eax, eax
.lp:
    cmp byte [rdi+rax], 0
    je .dn
    inc eax
    jmp .lp
.dn:
    ret

; ======================== DATA ==============================================
str_dash:       db "-", 0
str_stdin_name: db "standard input", 0
str_nl:         db 10
str_hdr_pre:    db "==> "
str_hdr_suf:    db " <==", 10

help_text:
    db "Usage: tail [OPTION]... [FILE]...", 10
    db "Print the last 10 lines of each FILE to standard output.", 10
    db "With more than one FILE, precede each with a header giving the file name.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -c, --bytes=[+]NUM       output the last NUM bytes; or use -c +NUM to", 10
    db "                             output starting with byte NUM of each file", 10
    db "  -f, --follow[={name|descriptor}]", 10
    db "                           output appended data as the file grows;", 10
    db "                             an absent option argument means 'descriptor'", 10
    db "  -F                       same as --follow=name --retry", 10
    db "  -n, --lines=[+]NUM       output the last NUM lines, instead of the last 10;", 10
    db "                             or use -n +NUM to output starting with line NUM", 10
    db "      --max-unchanged-stats=N", 10
    db "                           with --follow=name, reopen a FILE which has not", 10
    db "                             changed size after N (default 5) iterations", 10
    db "      --pid=PID            with -f, terminate after process ID, PID dies", 10
    db "  -q, --quiet, --silent    never output headers giving file names", 10
    db "      --retry              keep trying to open a file if it is inaccessible", 10
    db "  -s, --sleep-interval=N   with -f, sleep for approximately N seconds", 10
    db "                             (default 1.0) between iterations", 10
    db "  -v, --verbose            always output headers giving file names", 10
    db "  -z, --zero-terminated    line delimiter is NUL, not newline", 10
    db "      --help               display this help and exit", 10
    db "      --version            output version information and exit", 10
    db 10
    db "NUM may have a multiplier suffix:", 10
    db "b 512, kB 1000, K 1024, MB 1000*1000, M 1024*1024,", 10
    db "GB 1000*1000*1000, G 1024*1024*1024, and so on for T, P, E, Z, Y.", 10
    db "Binary prefixes can be used, too: KiB=K, MiB=M, and so on.", 10
help_text_len equ $ - help_text

version_text:
    db "tail (fcoreutils) 0.1.0", 10
version_text_len equ $ - version_text

; Option strings (reuse for both str_eq and str_startswith)
str_help_opt:    db "--help", 0
str_version_opt: db "--version", 0
str_lines_opt:   db "--lines", 0
str_bytes_opt:   db "--bytes", 0
str_quiet_opt:   db "--quiet", 0
str_silent_opt:  db "--silent", 0
str_verbose_opt: db "--verbose", 0
str_zero_opt:    db "--zero-terminated", 0
str_follow_opt:  db "--follow", 0
str_retry_opt:   db "--retry", 0
str_pid_opt:     db "--pid", 0
str_sleep_opt:   db "--sleep-interval", 0
str_maxu_opt:    db "--max-unchanged-stats", 0

; Error messages (shared suffix for "Try 'tail --help'...")
err_try_suffix:     db "'", 10, "Try 'tail --help' for more information.", 10
err_try_suffix_len equ $ - err_try_suffix
err_inval_pre:      db "tail: invalid option -- '"
err_inval_pre_len equ $ - err_inval_pre
err_unrec_pre:      db "tail: unrecognized option '"
err_unrec_pre_len equ $ - err_unrec_pre
err_n_req:          db "tail: option requires an argument -- 'n'", 10
err_n_req_len equ $ - err_n_req
err_c_req:          db "tail: option requires an argument -- 'c'", 10
err_c_req_len equ $ - err_c_req
err_lines_req:      db "tail: option '--lines' requires an argument", 10
err_lines_req_len equ $ - err_lines_req
err_bytes_req:      db "tail: option '--bytes' requires an argument", 10
err_bytes_req_len equ $ - err_bytes_req
err_try_help:       db "Try 'tail --help' for more information.", 10
err_try_help_len equ $ - err_try_help
err_bad_lines_pre:  db "tail: invalid number of lines: '"
err_bad_lines_pre_len equ $ - err_bad_lines_pre
err_bad_bytes_pre:  db "tail: invalid number of bytes: '"
err_bad_bytes_pre_len equ $ - err_bad_bytes_pre
err_bad_val_suf:    db "'", 10
err_bad_val_suf_len equ $ - err_bad_val_suf
err_open_pre:       db "tail: cannot open '"
err_open_pre_len equ $ - err_open_pre
err_open_suf:       db "' for reading: No such file or directory", 10
err_open_suf_len equ $ - err_open_suf

file_end:
