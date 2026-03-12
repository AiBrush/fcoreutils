; ============================================================
; fid_unified.asm — GNU-compatible 'id' command
; Builds with: nasm -f bin fid_unified.asm -o fid
;
; id: Print real and effective user and group IDs.
;
; Options:
;   -u  print effective user ID
;   -g  print effective group ID
;   -G  print all group IDs
;   -n  print name instead of number (with -u/-g/-G)
;   -r  print real ID instead of effective (with -u/-g)
;   --help, --version
;
; Register allocation:
;   r14d = argc, r15 = argv
;   ebx  = flags (bit 0=-u, bit 1=-g, bit 2=-G, bit 3=-n, bit 4=-r)
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXIT       60
%define SYS_GETUID     102
%define SYS_GETGID     104
%define SYS_GETEUID    107
%define SYS_GETEGID    108
%define SYS_GETGROUPS  115

%define STDOUT          1
%define STDERR          2

%define BUF_SIZE    65536
%define MAX_GROUPS    256

%define FLAG_U  1
%define FLAG_G  2
%define FLAG_GG 4
%define FLAG_N  8
%define FLAG_R  16

; --- ELF Header (64 bytes) ---
ehdr:
    db 0x7F, 'E','L','F'
    db 2, 1, 1, 0
    dq 0
    dw 2, 0x3E
    dd 1
    dq _start
    dq phdr - $$
    dq 0
    dd 0
    dw ehdr_size, phdr_size, 2, 64, 0, 0
ehdr_size equ $ - ehdr

; --- Program Headers ---
phdr:
    ; PT_LOAD
    dd 1, 7
    dq 0, $$, $$, file_size, file_size + bss_size, 0x200000
phdr_size equ $ - phdr

    ; PT_GNU_STACK (NX)
    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 0x10

; ============================================================
; Code
; ============================================================
_start:
    mov     r14d, [rsp]         ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Initialize
    xor     ebx, ebx            ; flags
    mov     dword [has_user_arg], 0
    mov     r13d, 1             ; arg index

    ; Parse options
.parse_opts:
    cmp     r13d, r14d
    jge     .done_opts
    mov     rdi, [r15 + r13*8]
    cmp     byte [rdi], '-'
    jne     .is_user_arg
    cmp     byte [rdi + 1], 0
    je      .is_user_arg

    cmp     byte [rdi + 1], '-'
    jne     .short_opts

    ; Long option
    cmp     byte [rdi + 2], 0
    je      .double_dash

    ; Check --help
    mov     rsi, str_help_flag
    call    _strcmp
    test    eax, eax
    jz      .show_help

    mov     rdi, [r15 + r13*8]
    mov     rsi, str_version_flag
    call    _strcmp
    test    eax, eax
    jz      .show_version

    ; Unrecognized long option
    mov     rdi, STDERR
    mov     rsi, str_err_unrec1
    call    _strlen_and_write
    mov     rdi, [r15 + r13*8]
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDERR
    call    _write
    mov     rdi, STDERR
    mov     rsi, str_err_unrec2
    call    _strlen_and_write
    mov     rdi, 1
    jmp     _exit

.short_opts:
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'u'
    je      .set_u
    cmp     al, 'g'
    je      .set_g
    cmp     al, 'G'
    je      .set_GG
    cmp     al, 'n'
    je      .set_n
    cmp     al, 'r'
    je      .set_r
    cmp     al, 'z'
    je      .set_z
    ; Invalid option
    push    rdi
    mov     rdi, STDERR
    mov     rsi, str_err_invalid1
    call    _strlen_and_write
    pop     rdi
    mov     rsi, rdi
    mov     rdi, STDERR
    mov     rdx, 1
    call    _write
    mov     rdi, STDERR
    mov     rsi, str_err_invalid2
    call    _strlen_and_write
    mov     rdi, 1
    jmp     _exit

.set_u:
    or      bl, FLAG_U
    inc     rdi
    jmp     .short_loop
.set_g:
    or      bl, FLAG_G
    inc     rdi
    jmp     .short_loop
.set_GG:
    or      bl, FLAG_GG
    inc     rdi
    jmp     .short_loop
.set_n:
    or      bl, FLAG_N
    inc     rdi
    jmp     .short_loop
.set_r:
    or      bl, FLAG_R
    inc     rdi
    jmp     .short_loop
.set_z:
    or      bl, 32              ; bit 5 = -z (NUL separator for -G)
    inc     rdi
    jmp     .short_loop

.double_dash:
    inc     r13d
    jmp     .check_user_after_opts

.next_opt:
    inc     r13d
    jmp     .parse_opts

.is_user_arg:
    ; This is a username argument
    mov     rdi, [r15 + r13*8]
    mov     [user_arg_ptr], rdi
    mov     dword [has_user_arg], 1
    inc     r13d
    jmp     .parse_opts

.check_user_after_opts:
    cmp     r13d, r14d
    jge     .done_opts
    mov     rdi, [r15 + r13*8]
    mov     [user_arg_ptr], rdi
    mov     dword [has_user_arg], 1

.done_opts:
    ; Check for conflicting options: -n or -r without -u/-g/-G
    mov     eax, ebx
    and     eax, FLAG_N | FLAG_R
    test    eax, eax
    jz      .no_conflict
    mov     eax, ebx
    and     eax, FLAG_U | FLAG_G | FLAG_GG
    test    eax, eax
    jnz     .no_conflict
    ; -n or -r specified without -u, -g, or -G
    mov     rdi, STDERR
    mov     rsi, str_err_prefix
    call    _strlen_and_write
    mov     rdi, STDERR
    mov     rsi, str_err_no_default
    call    _strlen_and_write
    mov     rdi, 1
    jmp     _exit

.no_conflict:
    ; Read /etc/passwd and /etc/group files
    call    _read_passwd_file
    call    _read_group_file

    ; Get IDs (either from current process or from username)
    cmp     dword [has_user_arg], 0
    je      .get_process_ids

    ; Lookup user
    call    _lookup_user
    test    eax, eax
    js      .user_not_found
    jmp     .have_ids

.get_process_ids:
    ; Get real IDs
    mov     eax, SYS_GETUID
    syscall
    mov     [real_uid], eax
    mov     eax, SYS_GETGID
    syscall
    mov     [real_gid], eax
    ; Get effective IDs
    mov     eax, SYS_GETEUID
    syscall
    mov     [eff_uid], eax
    mov     eax, SYS_GETEGID
    syscall
    mov     [eff_gid], eax
    ; Get supplementary groups
    mov     rdi, MAX_GROUPS
    mov     rsi, group_list
    mov     eax, SYS_GETGROUPS
    syscall
    cmp     rax, 0
    jl      .no_supp_groups
    mov     [group_count], eax
    jmp     .have_ids
.no_supp_groups:
    mov     dword [group_count], 0

.have_ids:
    ; Now dispatch based on flags
    mov     eax, ebx
    and     eax, FLAG_U | FLAG_G | FLAG_GG
    test    eax, eax
    jz      .print_full_id

    test    bl, FLAG_U
    jnz     .print_uid_only
    test    bl, FLAG_G
    jnz     .print_gid_only
    test    bl, FLAG_GG
    jnz     .print_groups_only
    jmp     .print_full_id

; ── Print single UID ──
.print_uid_only:
    ; Choose real or effective
    test    bl, FLAG_R
    jnz     .uid_real
    mov     edi, [eff_uid]
    jmp     .uid_chosen
.uid_real:
    mov     edi, [real_uid]
.uid_chosen:
    test    bl, FLAG_N
    jnz     .uid_name

    ; Print as number
    mov     rsi, num_buf
    mov     rdx, 32
    call    _uint_to_str
    mov     rdx, rax
    mov     rsi, num_buf
    mov     rdi, STDOUT
    call    _write
    jmp     .print_trailing_nl

.uid_name:
    ; Look up name
    call    _find_user_name
    test    rax, rax
    jz      .uid_no_name
    mov     rdi, rax
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDOUT
    call    _write
    jmp     .print_trailing_nl

.uid_no_name:
    ; Print number if no name found
    test    bl, FLAG_R
    jnz     .uid_no_name_r
    mov     edi, [eff_uid]
    jmp     .uid_no_name_print
.uid_no_name_r:
    mov     edi, [real_uid]
.uid_no_name_print:
    mov     rsi, num_buf
    mov     rdx, 32
    call    _uint_to_str
    mov     rdx, rax
    mov     rsi, num_buf
    mov     rdi, STDOUT
    call    _write
    jmp     .print_trailing_nl

; ── Print single GID ──
.print_gid_only:
    test    bl, FLAG_R
    jnz     .gid_real
    mov     edi, [eff_gid]
    jmp     .gid_chosen
.gid_real:
    mov     edi, [real_gid]
.gid_chosen:
    test    bl, FLAG_N
    jnz     .gid_name

    mov     rsi, num_buf
    mov     rdx, 32
    call    _uint_to_str
    mov     rdx, rax
    mov     rsi, num_buf
    mov     rdi, STDOUT
    call    _write
    jmp     .print_trailing_nl

.gid_name:
    call    _find_group_name
    test    rax, rax
    jz      .gid_no_name
    mov     rdi, rax
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDOUT
    call    _write
    jmp     .print_trailing_nl

.gid_no_name:
    test    bl, FLAG_R
    jnz     .gid_no_name_r
    mov     edi, [eff_gid]
    jmp     .gid_no_name_print
.gid_no_name_r:
    mov     edi, [real_gid]
.gid_no_name_print:
    mov     rsi, num_buf
    mov     rdx, 32
    call    _uint_to_str
    mov     rdx, rax
    mov     rsi, num_buf
    mov     rdi, STDOUT
    call    _write
    jmp     .print_trailing_nl

; ── Print all group IDs ──
.print_groups_only:
    ; Ensure effective gid is in the list
    mov     eax, [eff_gid]
    mov     [primary_gid_for_G], eax

    ; Print primary first
    test    bl, FLAG_N
    jnz     .groups_name_mode

    ; Number mode
    mov     edi, [primary_gid_for_G]
    mov     rsi, num_buf
    mov     rdx, 32
    call    _uint_to_str
    mov     rdx, rax
    mov     rsi, num_buf
    mov     rdi, STDOUT
    call    _write

    ; Print each supplementary group
    xor     r13d, r13d
.groups_num_loop:
    cmp     r13d, [group_count]
    jge     .print_trailing_nl

    mov     eax, [group_list + r13*4]
    cmp     eax, [primary_gid_for_G]
    je      .groups_num_skip    ; skip if same as primary

    ; Print space
    mov     rdi, STDOUT
    mov     rsi, str_space
    mov     rdx, 1
    call    _write

    mov     edi, [group_list + r13*4]
    mov     rsi, num_buf
    mov     rdx, 32
    call    _uint_to_str
    mov     rdx, rax
    mov     rsi, num_buf
    mov     rdi, STDOUT
    call    _write

.groups_num_skip:
    inc     r13d
    jmp     .groups_num_loop

.groups_name_mode:
    ; Name mode for -Gn
    mov     edi, [primary_gid_for_G]
    call    _find_group_name
    test    rax, rax
    jz      .groups_name_primary_num
    mov     rdi, rax
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDOUT
    call    _write
    jmp     .groups_name_rest

.groups_name_primary_num:
    mov     edi, [primary_gid_for_G]
    mov     rsi, num_buf
    mov     rdx, 32
    call    _uint_to_str
    mov     rdx, rax
    mov     rsi, num_buf
    mov     rdi, STDOUT
    call    _write

.groups_name_rest:
    xor     r13d, r13d
.groups_name_loop:
    cmp     r13d, [group_count]
    jge     .print_trailing_nl

    mov     eax, [group_list + r13*4]
    cmp     eax, [primary_gid_for_G]
    je      .groups_name_skip

    mov     rdi, STDOUT
    mov     rsi, str_space
    mov     rdx, 1
    call    _write

    mov     edi, [group_list + r13*4]
    call    _find_group_name
    test    rax, rax
    jz      .groups_name_fallback_num

    mov     rdi, rax
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDOUT
    call    _write
    jmp     .groups_name_skip

.groups_name_fallback_num:
    mov     edi, [group_list + r13*4]
    mov     rsi, num_buf
    mov     rdx, 32
    call    _uint_to_str
    mov     rdx, rax
    mov     rsi, num_buf
    mov     rdi, STDOUT
    call    _write

.groups_name_skip:
    inc     r13d
    jmp     .groups_name_loop

; ── Print full id output ──
.print_full_id:
    ; Format: uid=N(name) gid=N(name) groups=N(name),N(name),...

    ; "uid="
    mov     rdi, STDOUT
    mov     rsi, str_uid_eq
    mov     rdx, 4
    call    _write

    ; UID number
    mov     edi, [eff_uid]
    mov     rsi, num_buf
    mov     rdx, 32
    call    _uint_to_str
    mov     rdx, rax
    mov     rsi, num_buf
    mov     rdi, STDOUT
    call    _write

    ; (username)
    mov     edi, [eff_uid]
    call    _find_user_name
    test    rax, rax
    jz      .no_uid_name
    push    rax                 ; save name pointer
    mov     rdi, STDOUT
    mov     rsi, str_lparen
    mov     rdx, 1
    call    _write
    pop     rdi                 ; restore name pointer
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDOUT
    call    _write
    mov     rdi, STDOUT
    mov     rsi, str_rparen
    mov     rdx, 1
    call    _write
.no_uid_name:

    ; " gid="
    mov     rdi, STDOUT
    mov     rsi, str_gid_eq
    mov     rdx, 5
    call    _write

    ; GID number
    mov     edi, [eff_gid]
    mov     rsi, num_buf
    mov     rdx, 32
    call    _uint_to_str
    mov     rdx, rax
    mov     rsi, num_buf
    mov     rdi, STDOUT
    call    _write

    ; (groupname)
    mov     edi, [eff_gid]
    call    _find_group_name
    test    rax, rax
    jz      .no_gid_name
    push    rax                 ; save name pointer
    mov     rdi, STDOUT
    mov     rsi, str_lparen
    mov     rdx, 1
    call    _write
    pop     rdi                 ; restore name pointer
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDOUT
    call    _write
    mov     rdi, STDOUT
    mov     rsi, str_rparen
    mov     rdx, 1
    call    _write
.no_gid_name:

    ; " groups="
    mov     rdi, STDOUT
    mov     rsi, str_groups_eq
    mov     rdx, 8
    call    _write

    ; Print effective GID first in groups list
    mov     edi, [eff_gid]
    mov     rsi, num_buf
    mov     rdx, 32
    call    _uint_to_str
    mov     rdx, rax
    mov     rsi, num_buf
    mov     rdi, STDOUT
    call    _write

    mov     edi, [eff_gid]
    call    _find_group_name
    test    rax, rax
    jz      .no_primary_grp_name
    push    rax
    mov     rdi, STDOUT
    mov     rsi, str_lparen
    mov     rdx, 1
    call    _write
    pop     rdi
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDOUT
    call    _write
    mov     rdi, STDOUT
    mov     rsi, str_rparen
    mov     rdx, 1
    call    _write
.no_primary_grp_name:

    ; Print remaining groups
    xor     r13d, r13d
.full_groups_loop:
    cmp     r13d, [group_count]
    jge     .print_trailing_nl

    mov     eax, [group_list + r13*4]
    cmp     eax, [eff_gid]
    je      .full_groups_skip

    ; Print comma
    mov     rdi, STDOUT
    mov     rsi, str_comma
    mov     rdx, 1
    call    _write

    ; Print GID number
    mov     edi, [group_list + r13*4]
    mov     rsi, num_buf
    mov     rdx, 32
    call    _uint_to_str
    mov     rdx, rax
    mov     rsi, num_buf
    mov     rdi, STDOUT
    call    _write

    ; Print (name)
    mov     edi, [group_list + r13*4]
    call    _find_group_name
    test    rax, rax
    jz      .full_groups_skip
    push    rax
    mov     rdi, STDOUT
    mov     rsi, str_lparen
    mov     rdx, 1
    call    _write
    pop     rdi
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDOUT
    call    _write
    mov     rdi, STDOUT
    mov     rsi, str_rparen
    mov     rdx, 1
    call    _write

.full_groups_skip:
    inc     r13d
    jmp     .full_groups_loop

.print_trailing_nl:
    mov     rdi, STDOUT
    mov     rsi, str_newline
    mov     rdx, 1
    call    _write
    xor     edi, edi
    jmp     _exit

.user_not_found:
    mov     rdi, STDERR
    mov     rsi, str_err_prefix
    call    _strlen_and_write
    mov     rdi, STDERR
    mov     rsi, str_sq_open
    mov     rdx, 3
    call    _write
    mov     rdi, [user_arg_ptr]
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDERR
    call    _write
    mov     rdi, STDERR
    mov     rsi, str_no_such_user
    call    _strlen_and_write
    mov     rdi, 1
    jmp     _exit

.show_help:
    mov     rdi, STDOUT
    mov     rsi, str_help
    mov     rdx, str_help_len
    call    _write
    xor     edi, edi
    jmp     _exit

.show_version:
    mov     rdi, STDOUT
    mov     rsi, str_version
    mov     rdx, str_version_len
    call    _write
    xor     edi, edi
    jmp     _exit

; ============================================================
; _read_passwd_file: Read /etc/passwd into passwd_buf
; ============================================================
_read_passwd_file:
    push    rbx
    mov     rdi, str_passwd_path
    xor     esi, esi
    xor     edx, edx
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .rpf_done
    mov     r12, rax

    xor     ebx, ebx
.rpf_read:
    mov     rdi, r12
    lea     rsi, [passwd_buf + rbx]
    mov     rdx, BUF_SIZE
    sub     rdx, rbx
    jle     .rpf_close
    mov     eax, SYS_READ
    syscall
    cmp     rax, -4
    je      .rpf_read
    test    rax, rax
    jle     .rpf_close
    add     rbx, rax
    jmp     .rpf_read
.rpf_close:
    push    rbx
    mov     rdi, r12
    mov     eax, SYS_CLOSE
    syscall
    pop     rbx
    mov     [passwd_buf_len], ebx
.rpf_done:
    pop     rbx
    ret

; ============================================================
; _read_group_file: Read /etc/group into group_buf
; ============================================================
_read_group_file:
    push    rbx
    mov     rdi, str_group_path
    xor     esi, esi
    xor     edx, edx
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .rgf_done
    mov     r12, rax

    xor     ebx, ebx
.rgf_read:
    mov     rdi, r12
    lea     rsi, [group_file_buf + rbx]
    mov     rdx, BUF_SIZE
    sub     rdx, rbx
    jle     .rgf_close
    mov     eax, SYS_READ
    syscall
    cmp     rax, -4
    je      .rgf_read
    test    rax, rax
    jle     .rgf_close
    add     rbx, rax
    jmp     .rgf_read
.rgf_close:
    push    rbx
    mov     rdi, r12
    mov     eax, SYS_CLOSE
    syscall
    pop     rbx
    mov     [group_file_len], ebx
.rgf_done:
    pop     rbx
    ret

; ============================================================
; _lookup_user: Find UID/GID for username in [user_arg_ptr]
; Sets real_uid, eff_uid, real_gid, eff_gid, group_list, group_count
; Returns: eax = 0 success, -1 failure
; ============================================================
_lookup_user:
    push    rbx
    push    r13

    mov     r13, [user_arg_ptr]
    mov     ebx, [passwd_buf_len]
    xor     ecx, ecx

.lu_line:
    cmp     ecx, ebx
    jge     .lu_fail
    mov     r8d, ecx

    ; Compare username
    xor     edx, edx
.lu_cmp:
    movzx   eax, byte [r13 + rdx]
    test    al, al
    jz      .lu_check_colon
    cmp     ecx, ebx
    jge     .lu_fail
    movzx   r9d, byte [passwd_buf + ecx]
    cmp     al, r9b
    jne     .lu_skip_line
    inc     ecx
    inc     edx
    jmp     .lu_cmp

.lu_check_colon:
    cmp     ecx, ebx
    jge     .lu_fail
    cmp     byte [passwd_buf + ecx], ':'
    jne     .lu_skip_line
    inc     ecx

    ; Skip password
.lu_skip_pw:
    cmp     ecx, ebx
    jge     .lu_fail
    cmp     byte [passwd_buf + ecx], ':'
    je      .lu_pw_done
    cmp     byte [passwd_buf + ecx], 10
    je      .lu_next_line
    inc     ecx
    jmp     .lu_skip_pw
.lu_pw_done:
    inc     ecx

    ; Parse UID
    xor     eax, eax
.lu_uid:
    cmp     ecx, ebx
    jge     .lu_fail
    movzx   edx, byte [passwd_buf + ecx]
    cmp     dl, ':'
    je      .lu_uid_done
    sub     dl, '0'
    cmp     dl, 9
    ja      .lu_skip_line
    imul    eax, 10
    movzx   edx, dl
    add     eax, edx
    inc     ecx
    jmp     .lu_uid
.lu_uid_done:
    mov     [real_uid], eax
    mov     [eff_uid], eax
    inc     ecx

    ; Parse GID
    xor     eax, eax
.lu_gid:
    cmp     ecx, ebx
    jge     .lu_fail
    movzx   edx, byte [passwd_buf + ecx]
    cmp     dl, ':'
    je      .lu_gid_done
    cmp     dl, 10
    je      .lu_gid_done
    sub     dl, '0'
    cmp     dl, 9
    ja      .lu_skip_line
    imul    eax, 10
    movzx   edx, dl
    add     eax, edx
    inc     ecx
    jmp     .lu_gid
.lu_gid_done:
    mov     [real_gid], eax
    mov     [eff_gid], eax

    ; Find supplementary groups from /etc/group
    call    _find_supplementary_groups

    xor     eax, eax
    pop     r13
    pop     rbx
    ret

.lu_skip_line:
    cmp     ecx, ebx
    jge     .lu_fail
    cmp     byte [passwd_buf + ecx], 10
    je      .lu_next_line
    inc     ecx
    jmp     .lu_skip_line
.lu_next_line:
    inc     ecx
    jmp     .lu_line

.lu_fail:
    mov     eax, -1
    pop     r13
    pop     rbx
    ret

; ============================================================
; _find_supplementary_groups: scan /etc/group for groups
; containing [user_arg_ptr] as a member
; Populates group_list and group_count
; ============================================================
_find_supplementary_groups:
    push    rbx
    push    r12
    push    r13
    push    rbp

    mov     dword [group_count], 0
    mov     ebx, [group_file_len]
    mov     r13, [user_arg_ptr]
    xor     ecx, ecx

.fsg_line:
    cmp     ecx, ebx
    jge     .fsg_done

    ; Skip group name
.fsg_c1:
    cmp     ecx, ebx
    jge     .fsg_done
    cmp     byte [group_file_buf + ecx], ':'
    je      .fsg_c1_done
    cmp     byte [group_file_buf + ecx], 10
    je      .fsg_next_line
    inc     ecx
    jmp     .fsg_c1
.fsg_c1_done:
    inc     ecx

    ; Skip password
.fsg_c2:
    cmp     ecx, ebx
    jge     .fsg_done
    cmp     byte [group_file_buf + ecx], ':'
    je      .fsg_c2_done
    cmp     byte [group_file_buf + ecx], 10
    je      .fsg_next_line
    inc     ecx
    jmp     .fsg_c2
.fsg_c2_done:
    inc     ecx

    ; Parse GID
    xor     eax, eax
.fsg_gid:
    cmp     ecx, ebx
    jge     .fsg_done
    movzx   edx, byte [group_file_buf + ecx]
    cmp     dl, ':'
    je      .fsg_gid_done
    cmp     dl, 10
    je      .fsg_next_line
    sub     dl, '0'
    cmp     dl, 9
    ja      .fsg_next_line
    imul    eax, 10
    movzx   edx, dl
    add     eax, edx
    inc     ecx
    jmp     .fsg_gid
.fsg_gid_done:
    mov     r12d, eax           ; GID of this group
    inc     ecx

    ; Scan member list for username
.fsg_members:
    cmp     ecx, ebx
    jge     .fsg_done
    cmp     byte [group_file_buf + ecx], 10
    je      .fsg_next_line

    ; Try to match username
    mov     ebp, ecx            ; save start
    xor     edx, edx
.fsg_cmp:
    movzx   eax, byte [r13 + rdx]
    test    al, al
    jz      .fsg_cmp_end
    cmp     ecx, ebx
    jge     .fsg_done
    movzx   r9d, byte [group_file_buf + ecx]
    cmp     al, r9b
    jne     .fsg_skip_member
    inc     ecx
    inc     edx
    jmp     .fsg_cmp

.fsg_cmp_end:
    ; Check delimiter
    cmp     ecx, ebx
    jge     .fsg_match
    movzx   eax, byte [group_file_buf + ecx]
    cmp     al, ','
    je      .fsg_match
    cmp     al, 10
    je      .fsg_match
    cmp     al, 0
    je      .fsg_match
    jmp     .fsg_skip_member

.fsg_match:
    ; Add GID to group_list
    mov     eax, [group_count]
    cmp     eax, MAX_GROUPS
    jge     .fsg_skip_rest
    mov     [group_list + rax*4], r12d
    inc     eax
    mov     [group_count], eax
    jmp     .fsg_skip_rest

.fsg_skip_member:
    mov     ecx, ebp            ; restore
.fsg_to_comma:
    cmp     ecx, ebx
    jge     .fsg_done
    cmp     byte [group_file_buf + ecx], ','
    je      .fsg_next_member
    cmp     byte [group_file_buf + ecx], 10
    je      .fsg_next_line
    inc     ecx
    jmp     .fsg_to_comma
.fsg_next_member:
    inc     ecx
    jmp     .fsg_members

.fsg_skip_rest:
.fsg_skip_to_nl:
    cmp     ecx, ebx
    jge     .fsg_done
    cmp     byte [group_file_buf + ecx], 10
    je      .fsg_next_line
    inc     ecx
    jmp     .fsg_skip_to_nl

.fsg_next_line:
    inc     ecx
    jmp     .fsg_line

.fsg_done:
    pop     rbp
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; _find_user_name: Find username for UID
; Input: edi = UID
; Returns: rax = pointer to username (NUL-terminated in passwd_buf) or 0
; ============================================================
_find_user_name:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     ebx, [passwd_buf_len]
    xor     ecx, ecx

.fun_line:
    cmp     ecx, ebx
    jge     .fun_not_found
    mov     r8d, ecx            ; start of username

    ; Skip to first colon
.fun_c1:
    cmp     ecx, ebx
    jge     .fun_not_found
    cmp     byte [passwd_buf + ecx], ':'
    je      .fun_c1_done
    cmp     byte [passwd_buf + ecx], 10
    je      .fun_next_line
    inc     ecx
    jmp     .fun_c1
.fun_c1_done:
    mov     r9d, ecx
    mov     byte [passwd_buf + ecx], 0  ; NUL-terminate username
    inc     ecx

    ; Skip password
.fun_c2:
    cmp     ecx, ebx
    jge     .fun_restore_fail
    cmp     byte [passwd_buf + ecx], ':'
    je      .fun_c2_done
    cmp     byte [passwd_buf + ecx], 10
    je      .fun_restore_next
    inc     ecx
    jmp     .fun_c2
.fun_c2_done:
    inc     ecx

    ; Parse UID
    xor     eax, eax
.fun_uid:
    cmp     ecx, ebx
    jge     .fun_restore_fail
    movzx   edx, byte [passwd_buf + ecx]
    cmp     dl, ':'
    je      .fun_uid_done
    cmp     dl, 10
    je      .fun_restore_next
    sub     dl, '0'
    cmp     dl, 9
    ja      .fun_restore_next
    imul    eax, 10
    movzx   edx, dl
    add     eax, edx
    inc     ecx
    jmp     .fun_uid
.fun_uid_done:
    cmp     eax, r12d
    je      .fun_found
    mov     byte [passwd_buf + r9d], ':'  ; restore colon
.fun_skip:
    cmp     ecx, ebx
    jge     .fun_not_found
    cmp     byte [passwd_buf + ecx], 10
    je      .fun_next_line
    inc     ecx
    jmp     .fun_skip
.fun_next_line:
    inc     ecx
    jmp     .fun_line

.fun_found:
    ; Copy username to user_name_buf and restore colon
    mov     eax, r9d
    sub     eax, r8d            ; name length
    cmp     eax, 255
    jg      .fun_restore_fail
    xor     edx, edx
.fun_copy:
    cmp     edx, eax
    jge     .fun_copy_done
    movzx   r13d, byte [passwd_buf + r8d]
    mov     byte [user_name_buf + edx], r13b
    inc     r8d
    inc     edx
    jmp     .fun_copy
.fun_copy_done:
    mov     byte [user_name_buf + edx], 0
    mov     byte [passwd_buf + r9d], ':'  ; restore colon
    lea     rax, [user_name_buf]
    pop     r13
    pop     r12
    pop     rbx
    ret

.fun_restore_next:
    mov     byte [passwd_buf + r9d], ':'
    jmp     .fun_skip

.fun_restore_fail:
    mov     byte [passwd_buf + r9d], ':'
.fun_not_found:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; _find_group_name: Find group name for GID
; Input: edi = GID
; Returns: rax = pointer to group name (NUL-terminated) or 0
; ============================================================
_find_group_name:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     ebx, [group_file_len]
    xor     ecx, ecx

.fgn_line:
    cmp     ecx, ebx
    jge     .fgn_not_found
    mov     r8d, ecx

.fgn_c1:
    cmp     ecx, ebx
    jge     .fgn_not_found
    cmp     byte [group_file_buf + ecx], ':'
    je      .fgn_c1_done
    cmp     byte [group_file_buf + ecx], 10
    je      .fgn_next_line
    inc     ecx
    jmp     .fgn_c1
.fgn_c1_done:
    mov     r9d, ecx
    mov     byte [group_file_buf + ecx], 0
    inc     ecx

.fgn_c2:
    cmp     ecx, ebx
    jge     .fgn_restore_fail
    cmp     byte [group_file_buf + ecx], ':'
    je      .fgn_c2_done
    cmp     byte [group_file_buf + ecx], 10
    je      .fgn_restore_next
    inc     ecx
    jmp     .fgn_c2
.fgn_c2_done:
    inc     ecx

    xor     eax, eax
.fgn_gid:
    cmp     ecx, ebx
    jge     .fgn_restore_fail
    movzx   edx, byte [group_file_buf + ecx]
    cmp     dl, ':'
    je      .fgn_gid_done
    cmp     dl, 10
    je      .fgn_gid_done
    sub     dl, '0'
    cmp     dl, 9
    ja      .fgn_restore_next
    imul    eax, 10
    movzx   edx, dl
    add     eax, edx
    inc     ecx
    jmp     .fgn_gid
.fgn_gid_done:
    cmp     eax, r12d
    je      .fgn_found
    mov     byte [group_file_buf + r9d], ':'
.fgn_skip:
    cmp     ecx, ebx
    jge     .fgn_not_found
    cmp     byte [group_file_buf + ecx], 10
    je      .fgn_next_line
    inc     ecx
    jmp     .fgn_skip
.fgn_next_line:
    inc     ecx
    jmp     .fgn_line

.fgn_found:
    ; Copy group name to grp_name_buf and restore colon
    mov     eax, r9d
    sub     eax, r8d            ; name length
    cmp     eax, 255
    jg      .fgn_restore_fail
    xor     edx, edx
.fgn_copy:
    cmp     edx, eax
    jge     .fgn_copy_done
    movzx   r13d, byte [group_file_buf + r8d]
    mov     byte [grp_name_buf + edx], r13b
    inc     r8d
    inc     edx
    jmp     .fgn_copy
.fgn_copy_done:
    mov     byte [grp_name_buf + edx], 0
    mov     byte [group_file_buf + r9d], ':'  ; restore colon
    lea     rax, [grp_name_buf]
    pop     r13
    pop     r12
    pop     rbx
    ret

.fgn_restore_next:
    mov     byte [group_file_buf + r9d], ':'
    jmp     .fgn_skip

.fgn_restore_fail:
    mov     byte [group_file_buf + r9d], ':'
.fgn_not_found:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; Utility functions
; ============================================================
_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      _write
    ret

_exit:
    mov     eax, SYS_EXIT
    syscall

_strlen:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     eax
    jmp     .sl_loop
.sl_done:
    ret

_strcmp:
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
    xor     eax, eax
    ret
.se_ne:
    sub     eax, edx
    ret

_strlen_and_write:
    push    rdi
    mov     rdi, rsi
    push    rsi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    pop     rdi
    call    _write
    ret

_uint_to_str:
    push    rbx
    push    r12
    mov     r12, rsi
    mov     rbx, rdx
    xor     ecx, ecx
    mov     rax, rdi
    mov     r8, 10
.dloop:
    xor     edx, edx
    div     r8
    add     dl, '0'
    push    rdx
    inc     ecx
    test    rax, rax
    jnz     .dloop
    xor     eax, eax
.sloop:
    cmp     eax, ebx
    jge     .sdone
    pop     rdx
    mov     byte [r12 + rax], dl
    inc     eax
    dec     ecx
    jnz     .sloop
.sdone:
    pop     r12
    pop     rbx
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: id [OPTION]... [USER]", 10
    db "Print user and group information for each specified USER,", 10
    db "or (when USER omitted) for the current process.", 10, 10
    db "  -a             ignore, for compatibility with other versions", 10
    db "  -Z, --context  print only the security context of the process", 10
    db "  -g, --group    print only the effective group ID", 10
    db "  -G, --groups   print all group IDs", 10
    db "  -n, --name     print a name instead of a number, for -ugG", 10
    db "  -r, --real     print the real ID instead of the effective ID, for -ugG", 10
    db "  -u, --user     print only the effective user ID", 10
    db "  -z, --zero     delimit entries with NUL characters, not whitespace;", 10
    db "                   not permitted in default format", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "Without any OPTION, print some useful set of identified information.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/id>", 10
    db "or available locally via: info '(coreutils) id invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "id (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Arnold Robbins and David MacKenzie.", 10
str_version_len equ $ - str_version

str_err_prefix:     db "id: ", 0
str_err_unrec1:     db "id: unrecognized option '", 0
str_err_unrec2:     db "'", 10, "Try 'id --help' for more information.", 10, 0
str_err_invalid1:   db "id: invalid option -- '", 0
str_err_invalid2:   db "'", 10, "Try 'id --help' for more information.", 10, 0
str_err_no_default: db "cannot print only names or real IDs in default format", 10, "Try 'id --help' for more information.", 10, 0
str_sq_open:        db 0xE2, 0x80, 0x98
str_no_such_user:   db 0xE2, 0x80, 0x99, ": no such user", 10, 0
str_passwd_path:    db "/etc/passwd", 0
str_group_path:     db "/etc/group", 0
; @@DATA_END@@

str_newline:        db 10
str_space:          db ' '
str_comma:          db ','
str_lparen:         db '('
str_rparen:         db ')'
str_uid_eq:         db "uid="
str_gid_eq:         db " gid="
str_groups_eq:      db " groups="
str_help_flag:      db "--help", 0
str_version_flag:   db "--version", 0

file_size equ $ - $$

; BSS section
passwd_buf          equ $$ + file_size
passwd_buf_len      equ passwd_buf + BUF_SIZE
group_file_buf      equ passwd_buf_len + 4
group_file_len      equ group_file_buf + BUF_SIZE
group_list          equ group_file_len + 4          ; MAX_GROUPS * 4 bytes
group_count         equ group_list + MAX_GROUPS * 4
real_uid            equ group_count + 4
eff_uid             equ real_uid + 4
real_gid            equ eff_uid + 4
eff_gid             equ real_gid + 4
primary_gid_for_G   equ eff_gid + 4
has_user_arg        equ primary_gid_for_G + 4
user_arg_ptr        equ has_user_arg + 4 + 4        ; 8-byte aligned pointer
num_buf             equ user_arg_ptr + 8             ; 32 bytes
user_name_buf       equ num_buf + 32                 ; 256 bytes
grp_name_buf        equ user_name_buf + 256          ; 256 bytes
bss_size            equ BUF_SIZE + 4 + BUF_SIZE + 4 + MAX_GROUPS * 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 8 + 32 + 256 + 256
