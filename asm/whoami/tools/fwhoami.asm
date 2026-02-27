; fwhoami — print effective user name
; GNU-compatible whoami implementation in x86_64 assembly
;
; Uses geteuid syscall + /etc/passwd parsing (no libc needed)

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write
extern asm_write_err
extern asm_exit
extern asm_read
extern asm_open
extern asm_close
extern asm_strlen
extern asm_strcmp
extern asm_uint_to_str

global _start

section .data
    str_help:       db "Usage: whoami [OPTION]...", 10
                    db "Print the user name associated with the current effective user ID.", 10
                    db "Same as id -un.", 10
                    db 10
                    db "      --help        display this help and exit", 10
                    db "      --version     output version information and exit", 10
                    db 10
                    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
                    db "Full documentation <https://www.gnu.org/software/coreutils/whoami>", 10
                    db "or available locally via: info '(coreutils) whoami invocation'", 10
    str_help_len    equ $ - str_help

    str_version:    db "whoami (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
                    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
                    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
                    db "This is free software: you are free to change and redistribute it.", 10
                    db "There is NO WARRANTY, to the extent permitted by law.", 10
                    db 10
                    db "Written by Richard Mlynarik.", 10
    str_ver_len     equ $ - str_version

    str_flag_help:      db "--help", 0
    str_flag_version:   db "--version", 0

    str_passwd_path:    db "/etc/passwd", 0

    str_err_prefix:     db "whoami: ", 0
    str_err_no_name:    db "cannot find name for user ID ", 0
    str_err_operand1:   db "whoami: extra operand '", 0
    str_err_operand2:   db "'", 10, "Try 'whoami --help' for more information.", 10, 0
    str_err_unrec1:     db "whoami: unrecognized option '", 0
    str_err_unrec2:     db "'", 10, "Try 'whoami --help' for more information.", 10, 0
    str_err_invalid1:   db "whoami: invalid option -- '", 0
    str_err_invalid2:   db "'", 10, "Try 'whoami --help' for more information.", 10, 0

    newline:            db 10
    quote_char:         db "'"

section .bss
    passwd_buf:     resb BUF_SIZE       ; buffer for /etc/passwd contents
    uid_str_buf:    resb 32             ; buffer for UID string conversion
    name_buf:       resb 256            ; buffer for extracted username

section .text

_start:
    ; Get argc and argv from the stack
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

    ; If argc >= 2, check for flags
    cmp     r14, 2
    jl      .run_main

    ; Get argv[1]
    mov     rsi, [r15 + 8]      ; argv[1]

    ; Check if argv[1] starts with '-'
    cmp     byte [rsi], '-'
    jne     .extra_operand_argv1

    ; argv[1] starts with '-'
    cmp     byte [rsi + 1], 0
    je      .extra_operand_argv1 ; "-" alone is an extra operand

    cmp     byte [rsi + 1], '-'
    jne     .invalid_short_option ; "-x" is an invalid short option

    ; argv[1] starts with '--'
    cmp     byte [rsi + 2], 0
    je      .end_of_options     ; "--" alone is end-of-options marker

    ; Check --help
    mov     rdi, rsi
    mov     rsi, str_flag_help
    call    asm_strcmp
    test    eax, eax
    jz      .show_help

    ; Check --version
    mov     rdi, [r15 + 8]
    mov     rsi, str_flag_version
    call    asm_strcmp
    test    eax, eax
    jz      .show_version

    ; Unrecognized option starting with --
    jmp     .unrecognized_option

.end_of_options:
    ; "--" means end of options
    ; If argc == 2, no more args after "--" -> run main
    cmp     r14, 2
    je      .run_main
    ; If argc > 2, argv[2] is an extra operand
    mov     rbx, [r15 + 16]     ; argv[2]
    jmp     .report_extra_operand

.invalid_short_option:
    ; "-x" -> "whoami: invalid option -- 'x'"
    ; Report the first char after '-'
    mov     rdi, STDERR
    mov     rsi, str_err_invalid1
    call    asm_strlen_and_write

    ; Write the single option character (argv[1][1])
    mov     rsi, [r15 + 8]
    add     rsi, 1              ; point to char after '-'
    mov     rdi, STDERR
    mov     rdx, 1
    call    asm_write

    ; Write closing quote + try message
    mov     rdi, STDERR
    mov     rsi, str_err_invalid2
    call    asm_strlen_and_write

    mov     rdi, 1
    call    asm_exit

.extra_operand_argv1:
    mov     rbx, [r15 + 8]      ; argv[1]

.report_extra_operand:
    ; whoami: extra operand 'ARG'
    ; rbx = pointer to the operand string
    mov     rdi, STDERR
    mov     rsi, str_err_operand1
    call    asm_strlen_and_write

    ; Write the argument
    mov     rdi, rbx
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, rbx
    mov     rdi, STDERR
    call    asm_write

    ; Write closing quote + rest of message
    mov     rdi, STDERR
    mov     rsi, str_err_operand2
    call    asm_strlen_and_write

    mov     rdi, 1
    call    asm_exit

.unrecognized_option:
    ; whoami: unrecognized option 'ARG'
    mov     rdi, STDERR
    mov     rsi, str_err_unrec1
    call    asm_strlen_and_write

    ; Write the argument
    mov     rdi, [r15 + 8]      ; argv[1]
    push    rdi
    call    asm_strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDERR
    call    asm_write

    ; Write closing quote + try message
    mov     rdi, STDERR
    mov     rsi, str_err_unrec2
    call    asm_strlen_and_write

    mov     rdi, 1
    call    asm_exit

.show_help:
    mov     rdi, STDOUT
    mov     rsi, str_help
    mov     rdx, str_help_len
    call    asm_write
    xor     rdi, rdi
    call    asm_exit

.show_version:
    mov     rdi, STDOUT
    mov     rsi, str_version
    mov     rdx, str_ver_len
    call    asm_write
    xor     rdi, rdi
    call    asm_exit

.run_main:
    ; geteuid() syscall
    mov     rax, SYS_GETEUID
    syscall
    mov     r12, rax            ; r12 = euid

    ; Open /etc/passwd
    mov     rdi, str_passwd_path
    xor     esi, esi            ; O_RDONLY
    xor     edx, edx            ; mode = 0
    call    asm_open
    test    rax, rax
    js      .err_no_name        ; open failed
    mov     r13, rax            ; r13 = fd

    ; Read the file into buffer
    ; We'll read in chunks and parse
    xor     ebx, ebx            ; total bytes read into passwd_buf
.read_loop:
    mov     rdi, r13            ; fd
    lea     rsi, [passwd_buf + rbx]
    mov     rdx, BUF_SIZE
    sub     rdx, rbx            ; remaining buffer space
    jle     .close_and_parse    ; buffer full
    call    asm_read
    test    rax, rax
    jle     .close_and_parse    ; EOF or error
    add     rbx, rax
    jmp     .read_loop

.close_and_parse:
    ; Close the file
    push    rbx                 ; save total bytes
    mov     rdi, r13
    call    asm_close
    pop     rbx                 ; rbx = total bytes in buffer

    ; Parse /etc/passwd to find our UID
    ; Format: username:password:uid:gid:gecos:home:shell
    ; We need to find the line where field 3 (uid) matches r12
    xor     ecx, ecx            ; current position in buffer
.parse_line:
    cmp     ecx, ebx
    jge     .err_no_name        ; reached end without finding

    ; Save start of line (start of username)
    mov     r8d, ecx            ; r8 = start of username

    ; Skip to first colon (end of username)
.find_colon1:
    cmp     ecx, ebx
    jge     .err_no_name
    cmp     byte [passwd_buf + ecx], ':'
    je      .found_colon1
    cmp     byte [passwd_buf + ecx], 10
    je      .next_line_from_field1
    inc     ecx
    jmp     .find_colon1
.next_line_from_field1:
    inc     ecx
    jmp     .parse_line
.found_colon1:
    mov     r9d, ecx            ; r9 = position of first colon (end of username)
    inc     ecx                 ; skip past colon

    ; Skip password field (to second colon)
.find_colon2:
    cmp     ecx, ebx
    jge     .err_no_name
    cmp     byte [passwd_buf + ecx], ':'
    je      .found_colon2
    cmp     byte [passwd_buf + ecx], 10
    je      .next_line_from_field2
    inc     ecx
    jmp     .find_colon2
.next_line_from_field2:
    inc     ecx
    jmp     .parse_line
.found_colon2:
    inc     ecx                 ; skip past colon

    ; Now at UID field — parse the number
    xor     eax, eax            ; accumulated UID value
    mov     r10d, 10            ; multiplier
.parse_uid:
    cmp     ecx, ebx
    jge     .err_no_name
    movzx   edx, byte [passwd_buf + ecx]
    cmp     dl, ':'
    je      .uid_done
    cmp     dl, 10
    je      .next_line_from_uid
    sub     dl, '0'
    cmp     dl, 9
    ja      .next_line_from_uid ; not a digit
    imul    eax, r10d
    movzx   edx, dl
    add     eax, edx
    inc     ecx
    jmp     .parse_uid
.next_line_from_uid:
    ; Skip to next newline
.skip_to_nl:
    cmp     ecx, ebx
    jge     .err_no_name
    cmp     byte [passwd_buf + ecx], 10
    je      .at_nl
    inc     ecx
    jmp     .skip_to_nl
.at_nl:
    inc     ecx
    jmp     .parse_line

.uid_done:
    ; eax = parsed UID, r12 = target UID
    cmp     eax, r12d
    jne     .skip_to_nl_and_continue

    ; Found matching UID! Extract username (r8..r9)
    mov     eax, r9d
    sub     eax, r8d            ; length of username
    cmp     eax, 255            ; bounds check for name_buf
    jg      .err_no_name

    ; Copy username to name_buf
    xor     edx, edx
.copy_name:
    cmp     edx, eax
    jge     .name_copied
    movzx   ecx, byte [passwd_buf + r8d]
    mov     byte [name_buf + edx], cl
    inc     r8d
    inc     edx
    jmp     .copy_name
.name_copied:
    ; Add newline
    mov     byte [name_buf + edx], 10
    inc     edx

    ; Write the username
    mov     rdi, STDOUT
    mov     rsi, name_buf
    ; rdx already has the length including newline
    call    asm_write

    ; Exit success
    xor     rdi, rdi
    call    asm_exit

.skip_to_nl_and_continue:
    ; UID didn't match, skip to next line
    jmp     .skip_to_nl

.err_no_name:
    ; "whoami: cannot find name for user ID <uid>\n"
    mov     rdi, STDERR
    mov     rsi, str_err_prefix
    call    asm_strlen_and_write

    mov     rdi, STDERR
    mov     rsi, str_err_no_name
    call    asm_strlen_and_write

    ; Convert UID to string
    mov     rdi, r12            ; uid value
    mov     rsi, uid_str_buf
    mov     rdx, 32
    call    asm_uint_to_str
    ; rax = length of uid string

    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, uid_str_buf
    call    asm_write

    ; Write newline
    mov     rdi, STDERR
    mov     rsi, newline
    mov     rdx, 1
    call    asm_write

    mov     rdi, 1
    call    asm_exit

; Helper: compute strlen of null-terminated string at rsi, then write to fd in rdi
; Preserves rdi
asm_strlen_and_write:
    push    rdi                 ; save fd
    mov     rdi, rsi            ; string pointer for strlen
    push    rsi                 ; save string pointer
    call    asm_strlen
    mov     rdx, rax            ; length
    pop     rsi                 ; restore string pointer
    pop     rdi                 ; restore fd
    call    asm_write
    ret
