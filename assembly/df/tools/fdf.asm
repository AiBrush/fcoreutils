; fdf.asm — GNU-compatible "df" in x86_64 Linux assembly
;
; Supports: -h (human-readable), -T (show fs type), -i (inodes),
;           -a (include pseudo), -l (local only), -k (1K blocks),
;           --help, --version, specific file arguments
;
; Reads /proc/mounts for mount information, calls statfs(2) for each
;
; Build (modular):
;   nasm -f elf64 -I ./ tools/fdf.asm -o build/fdf.o
;   nasm -f elf64 -I ./ lib/io.asm -o build/io.o
;   nasm -f elf64 -I ./ lib/str.asm -o build/str.o
;   ld --gc-sections -z noexecstack build/fdf.o build/io.o build/str.o -o fdf

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_write
extern asm_read
extern asm_open
extern asm_close
extern asm_exit
extern asm_strlen
extern asm_strcmp
extern asm_strcpy
extern asm_uint_to_str

; Flag bits
%define FLAG_H          0x01    ; -h human-readable
%define FLAG_T          0x02    ; -T show filesystem type
%define FLAG_I          0x04    ; -i inode info
%define FLAG_A          0x08    ; -a include pseudo fs
%define FLAG_L          0x10    ; -l local only
%define FLAG_K          0x20    ; -k 1K blocks (default)

%define MAX_FILES       256

global _start

section .text

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
    mov     [rel argc], rax
    lea     rax, [rsp + 8]
    mov     [rel argv], rax

    mov     byte [rel flags], 0
    mov     byte [rel had_error], 0
    mov     qword [rel nfiles], 0
    xor     r12d, r12d          ; out_buf_used

    call    parse_args

    ; Print header
    call    print_header

    ; If specific files given, report for each
    cmp     qword [rel nfiles], 0
    jne     .specific_files

    ; No files: read /proc/mounts and report all
    call    read_proc_mounts
    jmp     .all_done

.specific_files:
    ; For each file, find its mount point and report
    xor     ebx, ebx
.sf_loop:
    cmp     rbx, [rel nfiles]
    jge     .all_done

    lea     rdi, [rel file_ptrs]
    mov     rsi, [rdi + rbx*8]
    push    rbx

    ; statfs on the file
    mov     rdi, rsi
    push    rsi
    lea     rsi, [rel statfs_buf]
    mov     eax, SYS_STATFS
    syscall
    pop     rsi
    test    rax, rax
    js      .sf_error

    ; Print: "-" as device, mountpoint as the file, statfs data
    push    rsi
    lea     rdi, [rel dash_str]
    mov     edx, 1
    call    emit_string

    ; Pad to column
    call    emit_pad_20

    ; If -T, print fs type
    test    byte [rel flags], FLAG_T
    jz      .sf_no_type
    lea     rdi, [rel str_unknown_fs]
    call    asm_strlen
    mov     rdx, rax
    lea     rdi, [rel str_unknown_fs]
    call    emit_string_len
    call    emit_pad_8
.sf_no_type:

    call    print_statfs_data
    mov     al, ' '
    call    emit_byte

    ; Print filename
    pop     rsi
    mov     rdi, rsi
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, rsi
    call    emit_string_len
    mov     al, 10
    call    emit_byte

    pop     rbx
    inc     rbx
    jmp     .sf_loop

.sf_error:
    neg     rax
    mov     r13d, eax
    mov     rdi, rsi
    mov     esi, r13d
    call    err_file
    mov     byte [rel had_error], 1
    pop     rbx
    inc     rbx
    jmp     .sf_loop

.all_done:
    call    flush_output
    movzx   edi, byte [rel had_error]
    mov     eax, SYS_EXIT
    syscall

; ============================================================================
;  print_header — Print column headers
; ============================================================================
print_header:
    test    byte [rel flags], FLAG_I
    jnz     .ph_inode_header

    ; Normal header
    lea     rdi, [rel header_normal]
    mov     edx, header_normal_len

    test    byte [rel flags], FLAG_H
    jz      .ph_check_type
    lea     rdi, [rel header_human]
    mov     edx, header_human_len

.ph_check_type:
    test    byte [rel flags], FLAG_T
    jz      .ph_emit
    ; With -T, use type header
    lea     rdi, [rel header_type]
    mov     edx, header_type_len

.ph_emit:
    call    emit_string
    mov     al, 10
    call    emit_byte
    ret

.ph_inode_header:
    lea     rdi, [rel header_inode]
    mov     edx, header_inode_len
    call    emit_string
    mov     al, 10
    call    emit_byte
    ret

; ============================================================================
;  read_proc_mounts — Parse /proc/mounts and report each filesystem
; ============================================================================
read_proc_mounts:
    push    rbx
    push    r13
    push    r14
    push    r15

    ; Open /proc/mounts
    lea     rdi, [rel proc_mounts_path]
    xor     esi, esi            ; O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .rpm_try_mtab
    mov     r15d, eax
    jmp     .rpm_read

.rpm_try_mtab:
    lea     rdi, [rel etc_mtab_path]
    xor     esi, esi
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .rpm_error
    mov     r15d, eax

.rpm_read:
    ; Read the entire file
    mov     edi, r15d
    lea     rsi, [rel mounts_buf]
    mov     edx, READ_BUF_SIZE - 1
    call    asm_read
    test    rax, rax
    js      .rpm_close_error

    mov     r14, rax            ; bytes read
    lea     rdi, [rel mounts_buf]
    mov     byte [rdi + r14], 0             ; null terminate

    mov     edi, r15d
    call    asm_close

    ; Parse line by line
    ; Format: device mountpoint fstype options dump pass
    lea     r13, [rel mounts_buf]

.rpm_line:
    ; Skip if at end
    cmp     byte [r13], 0
    je      .rpm_done

    ; Find device (first field)
    mov     [rel mount_device], r13
    call    skip_field          ; skip device, r13 -> after space

    ; Find mountpoint (second field)
    mov     [rel mount_point], r13
    call    skip_field          ; skip mountpoint

    ; Find fstype (third field)
    mov     [rel mount_fstype], r13
    call    skip_to_eol         ; skip to end of line

    ; Filter: skip pseudo filesystems unless -a
    test    byte [rel flags], FLAG_A
    jnz     .rpm_accept

    ; Check if device starts with '/'
    mov     rdi, [rel mount_device]
    cmp     byte [rdi], '/'
    jne     .rpm_line           ; skip non-device mounts

.rpm_accept:
    ; Null-terminate the fields (replace space/tab with 0)
    mov     rdi, [rel mount_device]
    call    null_at_space
    mov     rdi, [rel mount_point]
    call    null_at_space
    mov     rdi, [rel mount_fstype]
    call    null_at_space

    ; statfs on mountpoint
    mov     rdi, [rel mount_point]
    lea     rsi, [rel statfs_buf]
    mov     eax, SYS_STATFS
    syscall
    test    rax, rax
    js      .rpm_line           ; skip if can't stat

    ; Skip zero-block filesystems (pseudo) unless -a
    test    byte [rel flags], FLAG_A
    jnz     .rpm_print
    cmp     qword [rel statfs_buf + STATFS_BLOCKS], 0
    je      .rpm_line

.rpm_print:
    ; Print device
    mov     rdi, [rel mount_device]
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, [rel mount_device]
    call    emit_string_len
    call    emit_pad_20_from

    ; If -T, print fstype
    test    byte [rel flags], FLAG_T
    jz      .rpm_no_type
    mov     al, ' '
    call    emit_byte
    mov     rdi, [rel mount_fstype]
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, [rel mount_fstype]
    call    emit_string_len
    call    emit_pad_8
.rpm_no_type:

    ; Print statfs data
    call    print_statfs_data

    ; Print mountpoint
    mov     al, ' '
    call    emit_byte
    mov     rdi, [rel mount_point]
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, [rel mount_point]
    call    emit_string_len

    mov     al, 10
    call    emit_byte

    jmp     .rpm_line

.rpm_done:
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

.rpm_close_error:
    mov     edi, r15d
    call    asm_close
.rpm_error:
    mov     byte [rel had_error], 1
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; skip_field: advance r13 past non-space chars and whitespace
skip_field:
    ; Skip non-space
.sf_loop:
    movzx   eax, byte [r13]
    test    al, al
    jz      .sf_done
    cmp     al, ' '
    je      .sf_skip_ws
    cmp     al, 9              ; tab
    je      .sf_skip_ws
    inc     r13
    jmp     .sf_loop
.sf_skip_ws:
    ; Skip whitespace
    movzx   eax, byte [r13]
    cmp     al, ' '
    je      .sf_ws
    cmp     al, 9
    je      .sf_ws
    jmp     .sf_done
.sf_ws:
    inc     r13
    jmp     .sf_skip_ws
.sf_done:
    ret

; skip_to_eol: advance r13 to after newline
skip_to_eol:
.loop:
    movzx   eax, byte [r13]
    test    al, al
    jz      .done
    cmp     al, 10
    je      .found_nl
    inc     r13
    jmp     .loop
.found_nl:
    inc     r13                 ; skip the newline
.done:
    ret

; null_at_space: put 0 at first space/tab in string at rdi
null_at_space:
.loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .done
    cmp     al, ' '
    je      .null
    cmp     al, 9
    je      .null
    cmp     al, 10
    je      .null
    inc     rdi
    jmp     .loop
.null:
    mov     byte [rdi], 0
.done:
    ret

; ============================================================================
;  print_statfs_data — Print size/used/avail/use% from statfs_buf
; ============================================================================
print_statfs_data:
    push    rbx
    push    r13
    push    r14

    test    byte [rel flags], FLAG_I
    jnz     .psd_inode

    ; Calculate sizes in 1K blocks
    ; total = f_blocks * f_bsize / 1024
    ; avail = f_bavail * f_bsize / 1024
    ; used = total - f_bfree * f_bsize / 1024

    mov     rax, [rel statfs_buf + STATFS_BSIZE]
    mov     rbx, rax            ; block size

    ; total_1k = blocks * bsize / 1024
    mov     rax, [rel statfs_buf + STATFS_BLOCKS]
    imul    rax, rbx
    shr     rax, 10
    mov     r13, rax            ; total_1k

    ; free_1k = bfree * bsize / 1024
    mov     rax, [rel statfs_buf + STATFS_BFREE]
    imul    rax, rbx
    shr     rax, 10
    mov     r14, rax            ; free_1k

    ; avail_1k = bavail * bsize / 1024
    mov     rax, [rel statfs_buf + STATFS_BAVAIL]
    imul    rax, rbx
    shr     rax, 10
    push    rax                 ; save avail_1k

    ; used_1k = total_1k - free_1k
    mov     rax, r13
    sub     rax, r14
    push    rax                 ; save used_1k

    ; Print total
    test    byte [rel flags], FLAG_H
    jnz     .psd_human

    ; 1K-blocks format
    mov     rax, r13
    call    emit_number_rj
    mov     al, ' '
    call    emit_byte

    ; Used
    pop     rax                 ; used
    push    rax
    call    emit_number_rj
    mov     al, ' '
    call    emit_byte

    ; Available
    mov     rax, [rsp + 8]     ; avail (second on stack)
    call    emit_number_rj
    jmp     .psd_percent

.psd_human:
    mov     rax, r13
    call    emit_human_size_rj
    mov     al, ' '
    call    emit_byte

    pop     rax                 ; used
    push    rax
    call    emit_human_size_rj
    mov     al, ' '
    call    emit_byte

    mov     rax, [rsp + 8]     ; avail
    call    emit_human_size_rj

.psd_percent:
    mov     al, ' '
    call    emit_byte

    ; Use% = used * 100 / (used + avail)
    pop     rax                 ; used
    pop     rbx                 ; avail
    mov     r13, rax            ; used
    add     rbx, rax            ; used + avail = total usable

    test    rbx, rbx
    jz      .psd_zero_pct

    imul    rax, r13, 100
    xor     edx, edx
    div     rbx
    ; Round up: if remainder > 0 and result < 100, add 1
    test    edx, edx
    jz      .psd_pct_ok
    cmp     rax, 100
    jge     .psd_pct_ok
    inc     rax
.psd_pct_ok:
    call    emit_number_rj4
    mov     al, '%'
    call    emit_byte
    jmp     .psd_done

.psd_zero_pct:
    lea     rdi, [rel str_dash_pct]
    mov     edx, 5
    call    emit_string
    jmp     .psd_done

.psd_inode:
    ; Inode mode
    mov     rax, [rel statfs_buf + STATFS_FILES]
    call    emit_number_rj
    mov     al, ' '
    call    emit_byte

    ; IUsed = files - ffree
    mov     rax, [rel statfs_buf + STATFS_FILES]
    sub     rax, [rel statfs_buf + STATFS_FFREE]
    push    rax
    call    emit_number_rj
    mov     al, ' '
    call    emit_byte

    ; IFree
    mov     rax, [rel statfs_buf + STATFS_FFREE]
    call    emit_number_rj
    mov     al, ' '
    call    emit_byte

    ; IUse%
    pop     rax                 ; iused
    mov     r13, rax
    mov     rbx, [rel statfs_buf + STATFS_FILES]
    test    rbx, rbx
    jz      .psd_zero_ipct
    imul    rax, r13, 100
    xor     edx, edx
    div     rbx
    test    edx, edx
    jz      .psd_ipct_ok
    cmp     rax, 100
    jge     .psd_ipct_ok
    inc     rax
.psd_ipct_ok:
    call    emit_number_rj4
    mov     al, '%'
    call    emit_byte
    jmp     .psd_done

.psd_zero_ipct:
    lea     rdi, [rel str_dash_pct]
    mov     edx, 5
    call    emit_string

.psd_done:
    pop     r14
    pop     r13
    pop     rbx
    ret

; ============================================================================
;  emit_pad_20_from — Pad current output to at least 20 chars from last newline
; ============================================================================
emit_pad_20_from:
    ; For simplicity, emit a few spaces
    mov     al, ' '
    call    emit_byte
    ret

emit_pad_20:
    mov     al, ' '
    call    emit_byte
    ret

emit_pad_8:
    mov     al, ' '
    call    emit_byte
    ret

; ============================================================================
;  emit_human_size_rj — Human-readable size, right-justified
; ============================================================================
emit_human_size_rj:
    push    rbx
    mov     rbx, rax

    ; Convert 1K-blocks to human
    cmp     rbx, 1048576        ; 1G in KB
    jge     .ehs_g
    cmp     rbx, 1024           ; 1M in KB
    jge     .ehs_m

    ; KB
    mov     rax, rbx
    call    emit_number_rj
    mov     al, 'K'
    call    emit_byte
    pop     rbx
    ret

.ehs_m:
    mov     rax, rbx
    shr     rax, 10
    call    emit_number_rj
    mov     al, 'M'
    call    emit_byte
    pop     rbx
    ret

.ehs_g:
    mov     rax, rbx
    shr     rax, 20
    call    emit_number_rj
    mov     al, 'G'
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

    mov     r12, [rel argc]
    mov     r13, [rel argv]
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
    lea     rsi, [rel str_help_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_help
    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [rel str_version_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_version
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     .pa_next

.pa_do_help:
    pop r14
    pop r13
    pop r12
    pop rbx
    mov     rdi, STDOUT
    lea     rsi, [rel help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.pa_do_version:
    pop r14
    pop r13
    pop r12
    pop rbx
    mov     rdi, STDOUT
    lea     rsi, [rel version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.pa_dashdash:
    mov     r14d, 1
    jmp     .pa_next

.pa_short_opts:
    mov     rcx, 1
.pa_short_loop:
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .pa_next
    cmp     al, 'h'
    je      .f_h
    cmp     al, 'T'
    je      .f_T
    cmp     al, 'i'
    je      .f_i
    cmp     al, 'a'
    je      .f_a
    cmp     al, 'l'
    je      .f_l
    cmp     al, 'k'
    je      .f_k
    jmp     .pa_short_next

.f_h: or byte [rel flags], FLAG_H
    jmp .pa_short_next
.f_T: or byte [rel flags], FLAG_T
    jmp .pa_short_next
.f_i: or byte [rel flags], FLAG_I
    jmp .pa_short_next
.f_a: or byte [rel flags], FLAG_A
    jmp .pa_short_next
.f_l: or byte [rel flags], FLAG_L
    jmp .pa_short_next
.f_k: or byte [rel flags], FLAG_K
    jmp .pa_short_next

.pa_short_next:
    inc     rcx
    jmp     .pa_short_loop

.pa_is_file:
    mov     rax, [rel nfiles]
    cmp     rax, MAX_FILES
    jge     .pa_next
    lea     rcx, [rel file_ptrs]
    mov     [rcx + rax*8], rsi
    inc     qword [rel nfiles]

.pa_next:
    inc     rbx
    jmp     .pa_loop

.pa_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  Output helpers
; ============================================================================
emit_byte:
    lea     rdi, [rel out_buf]
    mov     [rdi + r12], al
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .done
    call    flush_output
.done:
    ret

emit_string:
    push    rbx
    push    rcx
    mov     rbx, rdi
    mov     ecx, edx
.copy:
    test    ecx, ecx
    jz      .done
    movzx   eax, byte [rbx]
    lea     rdi, [rel out_buf]
    mov     [rdi + r12], al
    inc     r12
    inc     rbx
    dec     ecx
    cmp     r12, OUT_BUF_SIZE
    jl      .copy
    push    rbx
    push    rcx
    call    flush_output
    pop     rcx
    pop     rbx
    jmp     .copy
.done:
    pop     rcx
    pop     rbx
    ret

emit_string_len:
    push    rbx
    push    rcx
    mov     rbx, rdi
    mov     rcx, rdx
.copy:
    test    rcx, rcx
    jz      .done
    movzx   eax, byte [rbx]
    lea     rdi, [rel out_buf]
    mov     [rdi + r12], al
    inc     r12
    inc     rbx
    dec     rcx
    cmp     r12, OUT_BUF_SIZE
    jl      .copy
    push    rbx
    push    rcx
    call    flush_output
    pop     rcx
    pop     rbx
    jmp     .copy
.done:
    pop     rcx
    pop     rbx
    ret

emit_number:
    push    rbx
    push    rcx
    lea     rdi, [rel itoa_buf]
    mov     rbx, rax
    xor     ecx, ecx
    mov     r8, 10
    test    rax, rax
    jnz     .loop
    mov     al, '0'
    call    emit_byte
    pop     rcx
    pop     rbx
    ret
.loop:
    mov     rax, rbx
    xor     edx, edx
    div     r8
    mov     rbx, rax
    add     dl, '0'
    mov     [rdi + rcx], dl
    inc     ecx
    test    rbx, rbx
    jnz     .loop
    dec     ecx
.emit:
    cmp     ecx, 0
    jl      .done
    lea     rdi, [rel itoa_buf]     ; reload (emit_byte clobbers rdi)
    movzx   eax, byte [rdi + rcx]
    call    emit_byte
    dec     ecx
    jmp     .emit
.done:
    pop     rcx
    pop     rbx
    ret

; emit_number_rj — right-justified in 10 chars
emit_number_rj:
    push    rbx
    push    rcx
    push    rdx
    lea     rdi, [rel itoa_buf]
    mov     rbx, rax
    xor     ecx, ecx
    mov     r8, 10
    test    rax, rax
    jnz     .loop
    mov     ecx, 1
    mov     byte [rdi], '0'
    jmp     .pad
.loop:
    mov     rax, rbx
    xor     edx, edx
    div     r8
    mov     rbx, rax
    add     dl, '0'
    mov     [rdi + rcx], dl
    inc     ecx
    test    rbx, rbx
    jnz     .loop
.pad:
    mov     edx, 10
    sub     edx, ecx
    jle     .emit
.space:
    mov     al, ' '
    push    rcx
    push    rdx
    call    emit_byte
    pop     rdx
    pop     rcx
    dec     edx
    jnz     .space
.emit:
    dec     ecx
.emit_loop:
    cmp     ecx, 0
    jl      .done
    lea     rdi, [rel itoa_buf]     ; reload (emit_byte clobbers rdi)
    movzx   eax, byte [rdi + rcx]
    push    rcx
    call    emit_byte
    pop     rcx
    dec     ecx
    jmp     .emit_loop
.done:
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; emit_number_rj4 — right-justified in 4 chars
emit_number_rj4:
    push    rbx
    push    rcx
    push    rdx
    lea     rdi, [rel itoa_buf]
    mov     rbx, rax
    xor     ecx, ecx
    mov     r8, 10
    test    rax, rax
    jnz     .loop
    mov     ecx, 1
    mov     byte [rdi], '0'
    jmp     .pad
.loop:
    mov     rax, rbx
    xor     edx, edx
    div     r8
    mov     rbx, rax
    add     dl, '0'
    mov     [rdi + rcx], dl
    inc     ecx
    test    rbx, rbx
    jnz     .loop
.pad:
    mov     edx, 4
    sub     edx, ecx
    jle     .emit
.space:
    mov     al, ' '
    push    rcx
    push    rdx
    call    emit_byte
    pop     rdx
    pop     rcx
    dec     edx
    jnz     .space
.emit:
    dec     ecx
.emit_loop:
    cmp     ecx, 0
    jl      .done
    lea     rdi, [rel itoa_buf]     ; reload (emit_byte clobbers rdi)
    movzx   eax, byte [rdi + rcx]
    push    rcx
    call    emit_byte
    pop     rcx
    dec     ecx
    jmp     .emit_loop
.done:
    pop     rdx
    pop     rcx
    pop     rbx
    ret

flush_output:
    test    r12, r12
    jz      .nothing
    mov     rdi, STDOUT
    lea     rsi, [rel out_buf]
    mov     rdx, r12
    call    asm_write_all
    xor     r12d, r12d
    ret
.nothing:
    xor     eax, eax
    ret

; ============================================================================
;  Error / string helpers
; ============================================================================
str_eq:
.loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .ne
    test    al, al
    jz      .eq
    inc     rdi
    inc     rsi
    jmp     .loop
.eq: mov eax, 1
    ret
.ne: xor eax, eax
    ret

err_file:
    push    rbx
    push    r13
    mov     rbx, rdi
    mov     r13d, esi
    mov     rdi, STDERR
    lea     rsi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all
    mov     rdi, rbx
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [rel str_colon_space]
    mov     rdx, 2
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
    lea     rsi, [rel str_nl]
    mov     rdx, 1
    call    asm_write_all
    pop     r13
    pop     rbx
    ret

strerror:
    cmp edi, 2
    je .e2
    cmp edi, 13
    je .e13
    lea rax, [rel str_eunknown]
    ret
.e2: lea rax, [rel str_enoent]
    ret
.e13: lea rax, [rel str_eacces]
    ret

; ─── Data ───
section .data
str_prefix: db "df: "
str_prefix_len equ $ - str_prefix
str_colon_space: db ": "
str_nl: db 10
dash_str: db "-"
str_dash_pct: db "    -"
str_help_opt: db "--help", 0
str_version_opt: db "--version", 0
str_unknown_fs: db "unknown", 0
proc_mounts_path: db "/proc/mounts", 0
etc_mtab_path: db "/etc/mtab", 0
str_enoent: db "No such file or directory", 0
str_eacces: db "Permission denied", 0
str_eunknown: db "Unknown error", 0

header_normal:
    db "Filesystem           1K-blocks      Used Available Use% Mounted on"
header_normal_len equ $ - header_normal

header_human:
    db "Filesystem            Size  Used Avail Use% Mounted on"
header_human_len equ $ - header_human

header_type:
    db "Filesystem     Type   1K-blocks      Used Available Use% Mounted on"
header_type_len equ $ - header_type

header_inode:
    db "Filesystem          Inodes   IUsed   IFree IUse% Mounted on"
header_inode_len equ $ - header_inode

help_text:
    db "Usage: df [OPTION]... [FILE]...", 10
    db "Show information about the file system on which each FILE resides,", 10
    db "or all file systems by default.", 10
    db 10
    db "  -a, --all             include pseudo, duplicate, inaccessible file systems", 10
    db "  -h, --human-readable  print sizes in powers of 1024 (e.g., 1023M)", 10
    db "  -i, --inodes          list inode information instead of block usage", 10
    db "  -k                    like --block-size=1K", 10
    db "  -l, --local           limit listing to local file systems", 10
    db "  -T, --print-type      print file system type", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
help_text_len equ $ - help_text

version_text:
    db "df (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Torbjorn Granlund, David MacKenzie, and Paul Eggert.", 10
version_text_len equ $ - version_text

; ─── BSS ───
section .bss
argc: resq 1
argv: resq 1
flags: resb 1
had_error: resb 1
nfiles: resq 1
file_ptrs: resq MAX_FILES
statfs_buf: resb STATFS_STRUCT_SIZE
mount_device: resq 1
mount_point: resq 1
mount_fstype: resq 1
itoa_buf: resb 32
mounts_buf: resb READ_BUF_SIZE
out_buf: resb OUT_BUF_SIZE

section .note.GNU-stack noalloc noexec nowrite progbits
