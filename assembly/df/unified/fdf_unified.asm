; fdf_unified.asm — GNU-compatible "df" in x86_64 Linux assembly
; Flat binary (nasm -f bin) with hand-crafted ELF headers.
;
; Build: nasm -f bin unified/fdf_unified.asm -o fdf && chmod +x fdf
; Test:  bash tests/run_tests.sh ./fdf
;
; Supports: -h (human-readable), -T (show fs type), -i (inodes),
;           -a (include pseudo), -l (local only), -k (1K blocks),
;           --help, --version, specific file arguments
;
; Reads /proc/mounts for mount information, calls statfs(2) for each.
;
; Register convention: r12 = out_buf_used (global across calls)

BITS 64
ORG 0x400000

; ── Syscall numbers ──
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_STATFS        137
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT           60

; ── File descriptors ──
%define STDIN               0
%define STDOUT              1
%define STDERR              2

; ── Error numbers ──
%define EINTR               4
%define EPIPE              32

; ── struct statfs offsets (x86-64 Linux) ──
%define STATFS_TYPE         0
%define STATFS_BSIZE        8
%define STATFS_BLOCKS      16
%define STATFS_BFREE       24
%define STATFS_BAVAIL      32
%define STATFS_FILES       40
%define STATFS_FFREE       48
%define STATFS_STRUCT_SIZE 120

; ── Buffer sizes ──
%define OUT_BUF_SIZE    262144
%define FLUSH_THRESHOLD 131072
%define READ_BUF_SIZE    65536
%define MAX_FILES       256

; ── Flag bits ──
%define FLAG_H          0x01    ; -h human-readable
%define FLAG_T          0x02    ; -T show filesystem type
%define FLAG_I          0x04    ; -i inode info
%define FLAG_A          0x08    ; -a include pseudo fs
%define FLAG_L          0x10    ; -l local only
%define FLAG_K          0x20    ; -k 1K blocks (default)

; ── BSS layout ──
%define BSS_ADDR        0x800000
%define BSS_SIZE        0x60000     ; ~393216 bytes

%define B_ARGC          (BSS_ADDR + 0)
%define B_ARGV          (BSS_ADDR + 8)
%define B_FLAGS         (BSS_ADDR + 16)
%define B_HAD_ERROR     (BSS_ADDR + 17)
%define B_NFILES        (BSS_ADDR + 24)
%define B_FILE_PTRS     (BSS_ADDR + 32)         ; 256 * 8 = 2048
%define B_STATFS_BUF    (BSS_ADDR + 2080)       ; 120 bytes
%define B_MOUNT_DEVICE  (BSS_ADDR + 2200)
%define B_MOUNT_POINT   (BSS_ADDR + 2208)
%define B_MOUNT_FSTYPE  (BSS_ADDR + 2216)
%define B_ITOA_BUF      (BSS_ADDR + 2224)       ; 32 bytes
%define B_MOUNTS_BUF    (BSS_ADDR + 2304)       ; 65536 bytes
%define B_OUT_BUF       (BSS_ADDR + 67840)      ; 262144 bytes

; ── ELF Header (64 bytes) ──
ehdr:
    db 0x7f, 'E','L','F'       ; magic
    db 2, 1, 1, 0              ; 64-bit, little-endian, ELF v1, SYSV
    dq 0                       ; padding
    dw 2, 0x3e                 ; ET_EXEC, x86-64
    dd 1                       ; ELF version
    dq _start                  ; entry point
    dq phdr - $$               ; program header offset
    dq 0                       ; section header offset
    dd 0                       ; flags
    dw 64, 56, 3, 64, 0, 0    ; ehsize, phentsize, phnum=3, shentsize, shnum, shstrndx

; ── Program Headers ──
phdr:
    ; PT_LOAD: code + rodata (R+X)
    dd 1, 5                    ; PT_LOAD, PF_R|PF_X
    dq 0, $$, $$, file_size, file_size, 0x200000

    ; PT_LOAD: BSS (R+W)
    dd 1, 6                    ; PT_LOAD, PF_R|PF_W
    dq 0, BSS_ADDR, BSS_ADDR, 0, BSS_SIZE, 0x200000

    ; PT_GNU_STACK (NX)
    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 0x10

; ============================================================================
;  _start
; ============================================================================
_start:
    ; Block SIGPIPE
    sub     rsp, 16
    mov     qword [rsp], 0
    bts     qword [rsp], 13     ; SIGPIPE = 13
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi            ; SIG_BLOCK
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    ; Save argc/argv
    mov     rax, [rsp]
    mov     [B_ARGC], rax
    lea     rax, [rsp + 8]
    mov     [B_ARGV], rax

    ; Initialize state
    mov     byte [B_FLAGS], 0
    mov     byte [B_HAD_ERROR], 0
    mov     qword [B_NFILES], 0
    xor     r12d, r12d          ; out_buf_used = 0

    call    parse_args

    ; Print header
    call    print_header

    ; If specific files given, report for each
    cmp     qword [B_NFILES], 0
    jne     .specific_files

    ; No files: read /proc/mounts and report all
    call    read_proc_mounts
    jmp     .all_done

.specific_files:
    xor     ebx, ebx
.sf_loop:
    cmp     rbx, [B_NFILES]
    jge     .all_done

    mov     rsi, [B_FILE_PTRS + rbx*8]
    push    rbx

    ; statfs on the file
    mov     rdi, rsi
    push    rsi
    lea     rsi, [B_STATFS_BUF]
    mov     eax, SYS_STATFS
    syscall
    pop     rsi
    test    rax, rax
    js      .sf_error

    ; Print: "-" as device
    push    rsi
    mov     rdi, dash_str
    mov     edx, 1
    call    emit_string

    ; Pad
    call    emit_pad_20

    ; If -T, print fs type
    test    byte [B_FLAGS], FLAG_T
    jz      .sf_no_type
    mov     rdi, str_unknown_fs
    call    str_len
    mov     rdx, rax
    mov     rdi, str_unknown_fs
    call    emit_string_len
    call    emit_pad_8
.sf_no_type:

    call    print_statfs_data
    mov     al, ' '
    call    emit_byte

    ; Print filename
    pop     rsi
    mov     rdi, rsi
    call    str_len
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
    ; rsi still has the filename pointer
    mov     rdi, rsi
    mov     esi, r13d
    call    err_file
    mov     byte [B_HAD_ERROR], 1
    pop     rbx
    inc     rbx
    jmp     .sf_loop

.all_done:
    call    flush_output
    movzx   edi, byte [B_HAD_ERROR]
    mov     eax, SYS_EXIT
    syscall

; ============================================================================
;  print_header — Print column headers
; ============================================================================
print_header:
    test    byte [B_FLAGS], FLAG_I
    jnz     .ph_inode_header

    ; Normal header
    mov     rdi, header_normal
    mov     edx, header_normal_len

    test    byte [B_FLAGS], FLAG_H
    jz      .ph_check_type
    mov     rdi, header_human
    mov     edx, header_human_len

.ph_check_type:
    test    byte [B_FLAGS], FLAG_T
    jz      .ph_emit
    mov     rdi, header_type
    mov     edx, header_type_len

.ph_emit:
    call    emit_string
    mov     al, 10
    call    emit_byte
    ret

.ph_inode_header:
    mov     rdi, header_inode
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
    mov     rdi, proc_mounts_path
    xor     esi, esi            ; O_RDONLY
    xor     edx, edx
    call    do_open
    test    rax, rax
    js      .rpm_try_mtab
    mov     r15d, eax
    jmp     .rpm_read

.rpm_try_mtab:
    mov     rdi, etc_mtab_path
    xor     esi, esi
    xor     edx, edx
    call    do_open
    test    rax, rax
    js      .rpm_error
    mov     r15d, eax

.rpm_read:
    ; Read the entire file
    mov     edi, r15d
    mov     rsi, B_MOUNTS_BUF
    mov     edx, READ_BUF_SIZE - 1
    call    do_read
    test    rax, rax
    js      .rpm_close_error

    mov     r14, rax            ; bytes read
    mov     byte [B_MOUNTS_BUF + r14], 0  ; null terminate

    mov     edi, r15d
    call    do_close

    ; Parse line by line
    ; Format: device mountpoint fstype options dump pass
    mov     r13, B_MOUNTS_BUF

.rpm_line:
    cmp     byte [r13], 0
    je      .rpm_done

    ; Find device (first field)
    mov     [B_MOUNT_DEVICE], r13
    call    skip_field

    ; Find mountpoint (second field)
    mov     [B_MOUNT_POINT], r13
    call    skip_field

    ; Find fstype (third field)
    mov     [B_MOUNT_FSTYPE], r13
    call    skip_to_eol

    ; Filter: skip pseudo filesystems unless -a
    test    byte [B_FLAGS], FLAG_A
    jnz     .rpm_accept

    ; Check if device starts with '/'
    mov     rdi, [B_MOUNT_DEVICE]
    cmp     byte [rdi], '/'
    jne     .rpm_line

.rpm_accept:
    ; Null-terminate the fields
    mov     rdi, [B_MOUNT_DEVICE]
    call    null_at_space
    mov     rdi, [B_MOUNT_POINT]
    call    null_at_space
    mov     rdi, [B_MOUNT_FSTYPE]
    call    null_at_space

    ; statfs on mountpoint
    mov     rdi, [B_MOUNT_POINT]
    lea     rsi, [B_STATFS_BUF]
    mov     eax, SYS_STATFS
    syscall
    test    rax, rax
    js      .rpm_line

    ; Skip zero-block filesystems (pseudo) unless -a
    test    byte [B_FLAGS], FLAG_A
    jnz     .rpm_print
    cmp     qword [B_STATFS_BUF + STATFS_BLOCKS], 0
    je      .rpm_line

.rpm_print:
    ; Print device
    mov     rdi, [B_MOUNT_DEVICE]
    call    str_len
    mov     rdx, rax
    mov     rdi, [B_MOUNT_DEVICE]
    call    emit_string_len
    call    emit_pad_20_from

    ; If -T, print fstype
    test    byte [B_FLAGS], FLAG_T
    jz      .rpm_no_type
    mov     al, ' '
    call    emit_byte
    mov     rdi, [B_MOUNT_FSTYPE]
    call    str_len
    mov     rdx, rax
    mov     rdi, [B_MOUNT_FSTYPE]
    call    emit_string_len
    call    emit_pad_8
.rpm_no_type:

    ; Print statfs data
    call    print_statfs_data

    ; Print mountpoint
    mov     al, ' '
    call    emit_byte
    mov     rdi, [B_MOUNT_POINT]
    call    str_len
    mov     rdx, rax
    mov     rdi, [B_MOUNT_POINT]
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
    call    do_close
.rpm_error:
    mov     byte [B_HAD_ERROR], 1
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; skip_field: advance r13 past non-space chars and whitespace
skip_field:
.sf_loop:
    movzx   eax, byte [r13]
    test    al, al
    jz      .sf_done
    cmp     al, ' '
    je      .sf_skip_ws
    cmp     al, 9
    je      .sf_skip_ws
    inc     r13
    jmp     .sf_loop
.sf_skip_ws:
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
    inc     r13
.done:
    ret

; null_at_space: put 0 at first space/tab/newline in string at rdi
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
;  print_statfs_data — Print size/used/avail/use% from B_STATFS_BUF
; ============================================================================
print_statfs_data:
    push    rbx
    push    r13
    push    r14

    test    byte [B_FLAGS], FLAG_I
    jnz     .psd_inode

    ; Calculate sizes in 1K blocks
    mov     rax, [B_STATFS_BUF + STATFS_BSIZE]
    mov     rbx, rax            ; block size

    ; total_1k = blocks * bsize / 1024
    mov     rax, [B_STATFS_BUF + STATFS_BLOCKS]
    imul    rax, rbx
    shr     rax, 10
    mov     r13, rax            ; total_1k

    ; free_1k = bfree * bsize / 1024
    mov     rax, [B_STATFS_BUF + STATFS_BFREE]
    imul    rax, rbx
    shr     rax, 10
    mov     r14, rax            ; free_1k

    ; avail_1k = bavail * bsize / 1024
    mov     rax, [B_STATFS_BUF + STATFS_BAVAIL]
    imul    rax, rbx
    shr     rax, 10
    push    rax                 ; save avail_1k

    ; used_1k = total_1k - free_1k
    mov     rax, r13
    sub     rax, r14
    push    rax                 ; save used_1k

    ; Print total
    test    byte [B_FLAGS], FLAG_H
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
    mov     rax, [rsp + 8]     ; avail
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
    mov     r13, rax
    add     rbx, rax            ; used + avail

    test    rbx, rbx
    jz      .psd_zero_pct

    imul    rax, r13, 100
    xor     edx, edx
    div     rbx
    ; Round up
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
    mov     rdi, str_dash_pct
    mov     edx, 5
    call    emit_string
    jmp     .psd_done

.psd_inode:
    mov     rax, [B_STATFS_BUF + STATFS_FILES]
    call    emit_number_rj
    mov     al, ' '
    call    emit_byte

    ; IUsed = files - ffree
    mov     rax, [B_STATFS_BUF + STATFS_FILES]
    sub     rax, [B_STATFS_BUF + STATFS_FFREE]
    push    rax
    call    emit_number_rj
    mov     al, ' '
    call    emit_byte

    ; IFree
    mov     rax, [B_STATFS_BUF + STATFS_FFREE]
    call    emit_number_rj
    mov     al, ' '
    call    emit_byte

    ; IUse%
    pop     rax                 ; iused
    mov     r13, rax
    mov     rbx, [B_STATFS_BUF + STATFS_FILES]
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
    mov     rdi, str_dash_pct
    mov     edx, 5
    call    emit_string

.psd_done:
    pop     r14
    pop     r13
    pop     rbx
    ret

; ============================================================================
;  Padding helpers
; ============================================================================
emit_pad_20_from:
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
;  Argument parsing
; ============================================================================
parse_args:
    push    rbx
    push    r13
    push    r14
    push    r15

    mov     r13, [B_ARGC]
    mov     r14, [B_ARGV]
    mov     rbx, 1
    xor     r15d, r15d          ; dashdash flag

.pa_loop:
    cmp     rbx, r13
    jge     .pa_done
    mov     rsi, [r14 + rbx*8]
    test    r15d, r15d
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
    mov     rdi, rsi
    push    rbx
    push    r13
    push    r14
    push    r15
    mov     rsi, str_help_opt
    call    str_eq
    test    eax, eax
    jnz     .pa_do_help
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    mov     rsi, [r14 + rbx*8]
    mov     rdi, rsi
    push    rbx
    push    r13
    push    r14
    push    r15
    mov     rsi, str_version_opt
    call    str_eq
    test    eax, eax
    jnz     .pa_do_version
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    jmp     .pa_next

.pa_do_help:
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ; flush any buffered output first
    call    flush_output
    mov     edi, STDOUT
    mov     rsi, help_text
    mov     edx, help_text_len
    call    do_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.pa_do_version:
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    call    flush_output
    mov     edi, STDOUT
    mov     rsi, version_text
    mov     edx, version_text_len
    call    do_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.pa_dashdash:
    mov     r15d, 1
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

.f_h: or byte [B_FLAGS], FLAG_H
    jmp .pa_short_next
.f_T: or byte [B_FLAGS], FLAG_T
    jmp .pa_short_next
.f_i: or byte [B_FLAGS], FLAG_I
    jmp .pa_short_next
.f_a: or byte [B_FLAGS], FLAG_A
    jmp .pa_short_next
.f_l: or byte [B_FLAGS], FLAG_L
    jmp .pa_short_next
.f_k: or byte [B_FLAGS], FLAG_K
    jmp .pa_short_next

.pa_short_next:
    inc     rcx
    jmp     .pa_short_loop

.pa_is_file:
    mov     rax, [B_NFILES]
    cmp     rax, MAX_FILES
    jge     .pa_next
    mov     [B_FILE_PTRS + rax*8], rsi
    inc     qword [B_NFILES]

.pa_next:
    inc     rbx
    jmp     .pa_loop

.pa_done:
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; ============================================================================
;  Output helpers
; ============================================================================
emit_byte:
    mov     [B_OUT_BUF + r12], al
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .done
    call    flush_output
.done:
    ret

emit_string:
    ; rdi = string pointer, edx = length
    push    rbx
    push    rcx
    mov     rbx, rdi
    mov     ecx, edx
.copy:
    test    ecx, ecx
    jz      .done
    movzx   eax, byte [rbx]
    mov     [B_OUT_BUF + r12], al
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
    ; rdi = string pointer, rdx = length
    push    rbx
    push    rcx
    mov     rbx, rdi
    mov     rcx, rdx
.copy:
    test    rcx, rcx
    jz      .done
    movzx   eax, byte [rbx]
    mov     [B_OUT_BUF + r12], al
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
    mov     [B_ITOA_BUF + rcx], dl
    inc     ecx
    test    rbx, rbx
    jnz     .loop
    dec     ecx
.emit:
    cmp     ecx, 0
    jl      .done
    movzx   eax, byte [B_ITOA_BUF + rcx]
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
    mov     rbx, rax
    xor     ecx, ecx
    mov     r8, 10
    test    rax, rax
    jnz     .loop
    mov     ecx, 1
    mov     byte [B_ITOA_BUF], '0'
    jmp     .pad
.loop:
    mov     rax, rbx
    xor     edx, edx
    div     r8
    mov     rbx, rax
    add     dl, '0'
    mov     [B_ITOA_BUF + rcx], dl
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
    movzx   eax, byte [B_ITOA_BUF + rcx]
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
    mov     rbx, rax
    xor     ecx, ecx
    mov     r8, 10
    test    rax, rax
    jnz     .loop
    mov     ecx, 1
    mov     byte [B_ITOA_BUF], '0'
    jmp     .pad
.loop:
    mov     rax, rbx
    xor     edx, edx
    div     r8
    mov     rbx, rax
    add     dl, '0'
    mov     [B_ITOA_BUF + rcx], dl
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
    movzx   eax, byte [B_ITOA_BUF + rcx]
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
    mov     edi, STDOUT
    mov     rsi, B_OUT_BUF
    mov     rdx, r12
    call    do_write_all
    xor     r12d, r12d
    ret
.nothing:
    xor     eax, eax
    ret

; ============================================================================
;  Error / string helpers
; ============================================================================
str_eq:
    ; rdi = s1, rsi = s2; returns eax = 1 if equal, 0 if not
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

str_len:
    ; rdi = string; returns rax = length
    xor     rax, rax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

err_file:
    ; rdi = filename, esi = errno
    push    rbx
    push    r13
    mov     rbx, rdi
    mov     r13d, esi
    mov     edi, STDERR
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_all
    mov     rdi, rbx
    call    str_len
    mov     rdx, rax
    mov     edi, STDERR
    mov     rsi, rbx
    call    do_write_all
    mov     edi, STDERR
    mov     rsi, str_colon_space
    mov     edx, 2
    call    do_write_all
    mov     edi, r13d
    call    strerror
    mov     rbx, rax
    mov     rdi, rax
    call    str_len
    mov     rdx, rax
    mov     edi, STDERR
    mov     rsi, rbx
    call    do_write_all
    mov     edi, STDERR
    mov     rsi, str_nl
    mov     edx, 1
    call    do_write_all
    pop     r13
    pop     rbx
    ret

strerror:
    ; edi = errno; returns rax = pointer to string
    cmp     edi, 2
    je      .e2
    cmp     edi, 13
    je      .e13
    lea     rax, [str_eunknown]
    ret
.e2: lea rax, [str_enoent]
    ret
.e13: lea rax, [str_eacces]
    ret

; ============================================================================
;  I/O primitives (inlined from lib/io.asm)
; ============================================================================
do_write:
    ; edi = fd, rsi = buf, edx = len
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -EINTR
    je      do_write
    ret

do_write_all:
    ; edi = fd, rsi = buf, rdx = len
    push    rbx
    push    r13
    push    r14
    mov     ebx, edi
    mov     r13, rsi
    mov     r14, rdx
.loop:
    test    r14, r14
    jle     .success
    mov     edi, ebx
    mov     rsi, r13
    mov     rdx, r14
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -EINTR
    je      .loop
    test    rax, rax
    js      .error
    add     r13, rax
    sub     r14, rax
    jmp     .loop
.success:
    xor     eax, eax
    pop     r14
    pop     r13
    pop     rbx
    ret
.error:
    pop     r14
    pop     r13
    pop     rbx
    ret

do_read:
    ; edi = fd, rsi = buf, edx = len
.retry:
    mov     eax, SYS_READ
    syscall
    cmp     rax, -EINTR
    je      .retry
    ret

do_open:
    ; rdi = path, esi = flags, edx = mode
    mov     eax, SYS_OPEN
    syscall
    ret

do_close:
    ; edi = fd
    mov     eax, SYS_CLOSE
    syscall
    ret

; ============================================================================
;  Read-only data
; ============================================================================
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

file_size equ $ - $$
