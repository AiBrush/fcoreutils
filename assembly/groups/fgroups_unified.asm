; ============================================================
; fgroups_unified.asm — GNU-compatible 'groups' command
; Builds with: nasm -f bin fgroups_unified.asm -o fgroups
;
; groups: Print group memberships for each USERNAME or,
;         if no USERNAME is specified, for the current process.
;
; Register allocation:
;   r14d = argc, r15 = argv
;   r12  = buffer for /etc/group file
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
%define O_RDONLY        0

%define BUF_SIZE    65536
%define MAX_GROUPS    256
%define NAME_BUF_SZ   256

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

    ; Parse options
    cmp     r14d, 1
    jle     .no_args

    ; Check argv[1]
    mov     rdi, [r15 + 8]
    cmp     byte [rdi], '-'
    jne     .has_user_arg

    cmp     byte [rdi + 1], '-'
    jne     .invalid_short

    cmp     byte [rdi + 2], 0
    je      .double_dash

    ; Check --help
    mov     rsi, str_help_flag
    call    _strcmp
    test    eax, eax
    jz      .show_help

    ; Check --version
    mov     rdi, [r15 + 8]
    mov     rsi, str_version_flag
    call    _strcmp
    test    eax, eax
    jz      .show_version

    ; Unrecognized long option
    mov     rdi, STDERR
    mov     rsi, str_err_unrec1
    call    _strlen_and_write
    mov     rdi, [r15 + 8]
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

.invalid_short:
    mov     rdi, STDERR
    mov     rsi, str_err_invalid1
    call    _strlen_and_write
    mov     rsi, [r15 + 8]
    add     rsi, 1
    mov     rdi, STDERR
    mov     rdx, 1
    call    _write
    mov     rdi, STDERR
    mov     rsi, str_err_invalid2
    call    _strlen_and_write
    mov     rdi, 1
    jmp     _exit

.double_dash:
    ; -- : if argc > 2, treat argv[2] as username
    cmp     r14d, 3
    jge     .has_user_arg_at2
    jmp     .no_args

.has_user_arg_at2:
    mov     rdi, [r15 + 16]     ; argv[2]
    jmp     .lookup_user

.has_user_arg:
    mov     rdi, [r15 + 8]      ; argv[1] = username

.lookup_user:
    ; We need to find the user's UID/GID first from /etc/passwd
    mov     [username_ptr], rdi
    call    _read_passwd_file
    test    eax, eax
    js      .user_not_found

    ; Print "username : " prefix
    mov     rdi, [username_ptr]
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDOUT
    call    _write

    mov     rdi, STDOUT
    mov     rsi, str_colon_space
    mov     rdx, 3
    call    _write

    ; Now get groups for this user from /etc/group
    call    _read_group_file
    call    _print_user_groups
    jmp     .print_newline_and_exit

.no_args:
    ; Get effective GID
    mov     eax, SYS_GETEGID
    syscall
    mov     [primary_gid], eax

    ; Get supplementary groups
    mov     rdi, MAX_GROUPS
    mov     rsi, group_list
    mov     eax, SYS_GETGROUPS
    syscall
    cmp     rax, 0
    jl      .getgroups_failed
    mov     [group_count], eax

    ; Check if primary GID is already in the list
    xor     ecx, ecx
    mov     edx, [primary_gid]
.check_primary:
    cmp     ecx, [group_count]
    jge     .add_primary
    cmp     [group_list + rcx*4], edx
    je      .primary_in_list
    inc     ecx
    jmp     .check_primary

.add_primary:
    ; Primary not in list — insert at position 0, shift others
    mov     ecx, [group_count]
.shift_loop:
    cmp     ecx, 0
    jle     .shift_done
    mov     eax, [group_list + rcx*4 - 4]
    mov     [group_list + rcx*4], eax
    dec     ecx
    jmp     .shift_loop
.shift_done:
    mov     eax, [primary_gid]
    mov     [group_list], eax
    inc     dword [group_count]
    jmp     .have_groups

.primary_in_list:
    ; Primary already in list — remove it from current position and
    ; insert at front to match GNU groups ordering
    cmp     ecx, 0
    je      .have_groups         ; already at front
    ; Shift elements [0..ecx-1] right by 1
    mov     r8d, ecx
.move_right:
    cmp     r8d, 0
    jle     .insert_primary
    mov     eax, [group_list + r8d*4 - 4]
    mov     [group_list + r8d*4], eax
    dec     r8d
    jmp     .move_right
.insert_primary:
    mov     eax, [primary_gid]
    mov     [group_list], eax

.have_groups:
    ; Read /etc/group to resolve GID -> name
    call    _read_group_file

    ; Print each group name separated by spaces
    xor     r13d, r13d          ; group index
.print_groups_loop:
    cmp     r13d, [group_count]
    jge     .print_newline_and_exit

    ; Look up group name for group_list[r13d]
    mov     edi, [group_list + r13*4]
    call    _find_group_name

    ; Print space between groups (not before first)
    cmp     r13d, 0
    je      .no_space
    push    rax
    mov     rdi, STDOUT
    mov     rsi, str_space
    mov     rdx, 1
    call    _write
    pop     rax
.no_space:
    ; If we found a name (rax != 0), print it; otherwise print GID number
    test    rax, rax
    jz      .print_gid_number

    ; Print group name
    mov     rdi, rax
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDOUT
    call    _write
    jmp     .next_group

.print_gid_number:
    ; Convert GID to string and print
    mov     edi, [group_list + r13*4]
    mov     rsi, num_buf
    mov     rdx, 32
    call    _uint_to_str
    mov     rdx, rax
    mov     rsi, num_buf
    mov     rdi, STDOUT
    call    _write

.next_group:
    inc     r13d
    jmp     .print_groups_loop

.getgroups_failed:
    ; Fallback: just print primary group
    mov     dword [group_count], 1
    mov     eax, [primary_gid]
    mov     [group_list], eax
    jmp     .have_groups

.print_newline_and_exit:
    mov     rdi, STDOUT
    mov     rsi, str_newline
    mov     rdx, 1
    call    _write
    xor     edi, edi
    jmp     _exit

.user_not_found:
    ; "groups: 'USER': no such user"
    mov     rdi, STDERR
    mov     rsi, str_prefix
    call    _strlen_and_write
    mov     rdi, STDERR
    mov     rsi, str_sq_open
    mov     rdx, 3
    call    _write
    mov     rdi, [username_ptr]
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
; _read_passwd_file: Read /etc/passwd, find username, set
;   primary_gid and user_uid
; Input: [username_ptr] = username string
; Returns: eax = 0 on success, -1 on failure
; ============================================================
_read_passwd_file:
    push    rbx
    push    r12
    push    r13

    ; Open /etc/passwd
    mov     rdi, str_passwd_path
    xor     esi, esi
    xor     edx, edx
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .rpf_fail
    mov     r12, rax            ; fd

    ; Read into passwd_buf
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

    ; Parse: find line matching username
    ; Format: username:password:uid:gid:...
    mov     r13, [username_ptr]
    xor     ecx, ecx
.rpf_parse:
    cmp     ecx, ebx
    jge     .rpf_fail
    mov     r8d, ecx            ; start of username

    ; Compare username
    xor     edx, edx
.rpf_cmp_name:
    movzx   eax, byte [r13 + rdx]
    test    al, al
    jz      .rpf_check_colon
    cmp     ecx, ebx
    jge     .rpf_fail
    movzx   r9d, byte [passwd_buf + ecx]
    cmp     al, r9b
    jne     .rpf_skip_line
    inc     ecx
    inc     edx
    jmp     .rpf_cmp_name

.rpf_check_colon:
    cmp     ecx, ebx
    jge     .rpf_fail
    cmp     byte [passwd_buf + ecx], ':'
    jne     .rpf_skip_line
    inc     ecx

    ; Skip password field
.rpf_skip_pw:
    cmp     ecx, ebx
    jge     .rpf_fail
    cmp     byte [passwd_buf + ecx], ':'
    je      .rpf_pw_done
    cmp     byte [passwd_buf + ecx], 10
    je      .rpf_next_line
    inc     ecx
    jmp     .rpf_skip_pw
.rpf_pw_done:
    inc     ecx

    ; Parse UID
    xor     eax, eax
.rpf_parse_uid:
    cmp     ecx, ebx
    jge     .rpf_fail
    movzx   edx, byte [passwd_buf + ecx]
    cmp     dl, ':'
    je      .rpf_uid_done
    sub     dl, '0'
    cmp     dl, 9
    ja      .rpf_skip_line
    imul    eax, 10
    movzx   edx, dl
    add     eax, edx
    inc     ecx
    jmp     .rpf_parse_uid
.rpf_uid_done:
    mov     [user_uid], eax
    inc     ecx

    ; Parse GID
    xor     eax, eax
.rpf_parse_gid:
    cmp     ecx, ebx
    jge     .rpf_fail
    movzx   edx, byte [passwd_buf + ecx]
    cmp     dl, ':'
    je      .rpf_gid_done
    cmp     dl, 10
    je      .rpf_gid_done
    sub     dl, '0'
    cmp     dl, 9
    ja      .rpf_skip_line
    imul    eax, 10
    movzx   edx, dl
    add     eax, edx
    inc     ecx
    jmp     .rpf_parse_gid
.rpf_gid_done:
    mov     [primary_gid], eax

    ; Read /etc/group to find all groups this user belongs to
    ; We'll do that separately
    xor     eax, eax            ; success
    pop     r13
    pop     r12
    pop     rbx
    ret

.rpf_skip_line:
    cmp     ecx, ebx
    jge     .rpf_fail
    cmp     byte [passwd_buf + ecx], 10
    je      .rpf_next_line
    inc     ecx
    jmp     .rpf_skip_line
.rpf_next_line:
    inc     ecx
    jmp     .rpf_parse

.rpf_fail:
    mov     eax, -1
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; _read_group_file: Read /etc/group into group_buf
; Sets group_buf_len
; ============================================================
_read_group_file:
    push    rbx

    mov     rdi, str_group_path
    xor     esi, esi
    xor     edx, edx
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .rgf_fail
    mov     r12, rax

    xor     ebx, ebx
.rgf_read:
    mov     rdi, r12
    lea     rsi, [group_buf + rbx]
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
    mov     [group_buf_len], ebx

.rgf_fail:
    pop     rbx
    ret

; ============================================================
; _find_group_name: Find group name for a GID
; Input: edi = GID
; Returns: rax = pointer to group name (in group_buf, colon-terminated)
;          or 0 if not found
; ============================================================
_find_group_name:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi           ; target GID
    mov     ebx, [group_buf_len]

    ; Parse /etc/group: name:password:gid:members
    xor     ecx, ecx
.fgn_line:
    cmp     ecx, ebx
    jge     .fgn_not_found
    mov     r8d, ecx            ; start of group name

    ; Skip to first colon
.fgn_c1:
    cmp     ecx, ebx
    jge     .fgn_not_found
    cmp     byte [group_buf + ecx], ':'
    je      .fgn_c1_done
    cmp     byte [group_buf + ecx], 10
    je      .fgn_next_line
    inc     ecx
    jmp     .fgn_c1
.fgn_c1_done:
    mov     r9d, ecx            ; end of group name
    ; NUL-terminate group name temporarily
    mov     byte [group_buf + ecx], 0
    inc     ecx

    ; Skip password field
.fgn_c2:
    cmp     ecx, ebx
    jge     .fgn_restore_and_fail
    cmp     byte [group_buf + ecx], ':'
    je      .fgn_c2_done
    cmp     byte [group_buf + ecx], 10
    je      .fgn_restore_next
    inc     ecx
    jmp     .fgn_c2
.fgn_c2_done:
    inc     ecx

    ; Parse GID
    xor     eax, eax
.fgn_parse_gid:
    cmp     ecx, ebx
    jge     .fgn_restore_and_fail
    movzx   edx, byte [group_buf + ecx]
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
    jmp     .fgn_parse_gid

.fgn_gid_done:
    cmp     eax, r12d
    je      .fgn_found
    ; Restore colon and skip to next line
    mov     byte [group_buf + r9d], ':'
.fgn_skip_line:
    cmp     ecx, ebx
    jge     .fgn_not_found
    cmp     byte [group_buf + ecx], 10
    je      .fgn_next_line
    inc     ecx
    jmp     .fgn_skip_line
.fgn_next_line:
    inc     ecx
    jmp     .fgn_line

.fgn_found:
    ; Copy group name to name_buf and restore colon in group_buf
    mov     eax, r9d
    sub     eax, r8d            ; name length
    cmp     eax, NAME_BUF_SZ - 1
    jg      .fgn_restore_and_fail
    xor     edx, edx
.fgn_copy:
    cmp     edx, eax
    jge     .fgn_copy_done
    movzx   r13d, byte [group_buf + r8d]
    mov     byte [name_buf + edx], r13b
    inc     r8d
    inc     edx
    jmp     .fgn_copy
.fgn_copy_done:
    mov     byte [name_buf + edx], 0    ; NUL-terminate
    ; Restore colon in group_buf
    mov     byte [group_buf + r9d], ':'
    lea     rax, [name_buf]
    pop     r13
    pop     r12
    pop     rbx
    ret

.fgn_restore_next:
    mov     byte [group_buf + r9d], ':'
    jmp     .fgn_skip_line

.fgn_restore_and_fail:
    mov     byte [group_buf + r9d], ':'
.fgn_not_found:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; _print_user_groups: Print groups for a named user
; Uses [username_ptr], [primary_gid], group_buf
; ============================================================
_print_user_groups:
    push    rbx
    push    r12
    push    r13
    push    rbp
    xor     ebp, ebp            ; count of groups printed

    ; First print primary group
    mov     edi, [primary_gid]
    call    _find_group_name
    test    rax, rax
    jz      .pug_primary_num

    ; Print primary group name
    mov     rdi, rax
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDOUT
    call    _write
    inc     ebp
    jmp     .pug_scan_groups

.pug_primary_num:
    mov     edi, [primary_gid]
    mov     rsi, num_buf
    mov     rdx, 32
    call    _uint_to_str
    mov     rdx, rax
    mov     rsi, num_buf
    mov     rdi, STDOUT
    call    _write
    inc     ebp

.pug_scan_groups:
    ; Now scan /etc/group for groups that have this user in their member list
    mov     ebx, [group_buf_len]
    xor     ecx, ecx

.pug_line:
    cmp     ecx, ebx
    jge     .pug_done
    mov     r8d, ecx            ; start of group name

    ; Find first colon (end of group name)
.pug_c1:
    cmp     ecx, ebx
    jge     .pug_done
    cmp     byte [group_buf + ecx], ':'
    je      .pug_c1_done
    cmp     byte [group_buf + ecx], 10
    je      .pug_next
    inc     ecx
    jmp     .pug_c1
.pug_c1_done:
    mov     r9d, ecx            ; position of first colon
    inc     ecx

    ; Skip password field
.pug_c2:
    cmp     ecx, ebx
    jge     .pug_done
    cmp     byte [group_buf + ecx], ':'
    je      .pug_c2_done
    cmp     byte [group_buf + ecx], 10
    je      .pug_next
    inc     ecx
    jmp     .pug_c2
.pug_c2_done:
    inc     ecx

    ; Parse GID of this group
    xor     eax, eax
.pug_gid:
    cmp     ecx, ebx
    jge     .pug_done
    movzx   edx, byte [group_buf + ecx]
    cmp     dl, ':'
    je      .pug_gid_done
    cmp     dl, 10
    je      .pug_next
    sub     dl, '0'
    cmp     dl, 9
    ja      .pug_next
    imul    eax, 10
    movzx   edx, dl
    add     eax, edx
    inc     ecx
    jmp     .pug_gid
.pug_gid_done:
    mov     r12d, eax           ; GID of this group
    inc     ecx                 ; skip ':'

    ; Now at member list. Check if username appears in comma-separated list
    ; Also check if this is the primary group (GID match) — skip if already printed
    cmp     r12d, [primary_gid]
    je      .pug_skip           ; already printed primary

.pug_check_members:
    cmp     ecx, ebx
    jge     .pug_done
    cmp     byte [group_buf + ecx], 10
    je      .pug_next
    ; Try to match username at current position
    mov     r13, [username_ptr]
    mov     r10d, ecx
    xor     edx, edx
.pug_cmp:
    movzx   eax, byte [r13 + rdx]
    test    al, al
    jz      .pug_cmp_end
    cmp     ecx, ebx
    jge     .pug_done
    movzx   r11d, byte [group_buf + ecx]
    cmp     al, r11b
    jne     .pug_skip_member
    inc     ecx
    inc     edx
    jmp     .pug_cmp

.pug_cmp_end:
    ; Username matched. Check that next char is ',' or newline or end
    cmp     ecx, ebx
    jge     .pug_member_match
    movzx   eax, byte [group_buf + ecx]
    cmp     al, ','
    je      .pug_member_match
    cmp     al, 10
    je      .pug_member_match
    cmp     al, 0
    je      .pug_member_match
    ; Not a full match, skip this member
    jmp     .pug_skip_member

.pug_member_match:
    ; Save ecx (scan position) — syscalls clobber rcx
    push    rcx

    ; This group contains our user — print space + group name
    mov     rdi, STDOUT
    mov     rsi, str_space
    mov     rdx, 1
    call    _write

    ; Print group name using length r9d - r8d (no NUL-termination needed)
    mov     edx, r9d
    sub     edx, r8d            ; name length
    lea     rsi, [group_buf + r8d]
    mov     rdi, STDOUT
    call    _write

    inc     ebp
    pop     rcx                 ; restore scan position
    jmp     .pug_skip

.pug_skip_member:
    ; Skip to next comma or end of line
    mov     ecx, r10d           ; restore to start of this member attempt
.pug_skip_to_comma:
    cmp     ecx, ebx
    jge     .pug_done
    cmp     byte [group_buf + ecx], ','
    je      .pug_next_member
    cmp     byte [group_buf + ecx], 10
    je      .pug_next
    inc     ecx
    jmp     .pug_skip_to_comma
.pug_next_member:
    inc     ecx                 ; skip comma
    jmp     .pug_check_members

.pug_skip:
    ; Skip to end of line
    cmp     ecx, ebx
    jge     .pug_done
    cmp     byte [group_buf + ecx], 10
    je      .pug_next
    inc     ecx
    jmp     .pug_skip
.pug_next:
    inc     ecx
    jmp     .pug_line

.pug_done:
    pop     rbp
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
    db "Usage: groups [OPTION]... [USERNAME]...", 10
    db "Print group memberships for each USERNAME or, if no USERNAME is specified,", 10
    db "for the current process (which may differ if the groups database has changed).", 10, 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/groups>", 10
    db "or available locally via: info '(coreutils) groups invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "groups (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by David MacKenzie and James Youngman.", 10
str_version_len equ $ - str_version

str_prefix:         db "groups: ", 0
str_err_unrec1:     db "groups: unrecognized option '", 0
str_err_unrec2:     db "'", 10, "Try 'groups --help' for more information.", 10, 0
str_err_invalid1:   db "groups: invalid option -- '", 0
str_err_invalid2:   db "'", 10, "Try 'groups --help' for more information.", 10, 0
str_sq_open:        db 0xE2, 0x80, 0x98
str_no_such_user:   db 0xE2, 0x80, 0x99, ": no such user", 10, 0
str_passwd_path:    db "/etc/passwd", 0
str_group_path:     db "/etc/group", 0
; @@DATA_END@@

str_newline:        db 10
str_space:          db ' '
str_colon_space:    db " : "
str_help_flag:      db "--help", 0
str_version_flag:   db "--version", 0

file_size equ $ - $$

; BSS section
passwd_buf      equ $$ + file_size
group_buf       equ passwd_buf + BUF_SIZE
group_buf_len   equ group_buf + BUF_SIZE
group_list      equ group_buf_len + 4       ; MAX_GROUPS * 4 bytes (int32 GIDs)
group_count     equ group_list + MAX_GROUPS * 4
primary_gid     equ group_count + 4
user_uid        equ primary_gid + 4
username_ptr    equ user_uid + 4 + 4        ; 8 bytes for pointer
num_buf         equ username_ptr + 8        ; 32 bytes
name_buf        equ num_buf + 32            ; NAME_BUF_SZ bytes for group name copy
bss_size        equ BUF_SIZE + BUF_SIZE + 4 + MAX_GROUPS * 4 + 4 + 4 + 4 + 4 + 8 + 32 + NAME_BUF_SZ
