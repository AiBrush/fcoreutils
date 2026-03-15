; fbasenc_unified.asm — GNU-compatible basenc encode/decode in x86-64 Linux assembly
; Build: nasm -f bin fbasenc_unified.asm -o fbasenc && chmod +x fbasenc

BITS 64
org 0x400000

%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_OPEN   2
%define SYS_CLOSE  3
%define SYS_SIGPROCMASK 14
%define SYS_EXIT  60
%define STDOUT     1
%define STDERR     2

%define INBUF_SIZE   65536
%define OUTBUF_SIZE  589824
%define WRAP_DEFAULT 76

%define ENC_NONE 255

%define BSS_BASE      0x800000
%define inbuf         BSS_BASE
%define outbuf        (BSS_BASE + INBUF_SIZE)
%define filename_ptr  (BSS_BASE + INBUF_SIZE + OUTBUF_SIZE)
%define BSS_SIZE      (INBUF_SIZE + OUTBUF_SIZE + 16)

; ======================== ELF Header ========================================
ehdr:
    db 0x7f,"ELF",2,1,1,0
    dq 0
    dw 2,0x3E
    dd 1
    dq _start, phdr-ehdr, 0
    dd 0
    dw ehdr_end-ehdr, phdr_size, 3, 0, 0, 0
ehdr_end:
phdr:
    dd 1,5
    dq 0, 0x400000, 0x400000, file_end-ehdr, file_end-ehdr, 0x1000
phdr_size equ $-phdr
    dd 1,6
    dq 0, BSS_BASE, BSS_BASE, 0, BSS_SIZE, 0x1000
    dd 0x6474E551, 6
    dq 0,0,0,0,0,0x10

; ============================================================================
_start:
    mov r15, rsp
    sub rsp, 16
    mov qword [rsp], 0x1000
    mov eax, SYS_SIGPROCMASK
    xor edi, edi
    mov rsi, rsp
    xor edx, edx
    mov r10d, 8
    syscall
    add rsp, 16

    xor r12d, r12d          ; flags: bit0=decode, bit1=ignore-garbage
    mov r13d, WRAP_DEFAULT   ; wrap column
    xor r14d, r14d          ; filename ptr
    sub rsp, 32
    mov byte [rsp], ENC_NONE ; encoding mode at [rsp]

    mov ecx, [r15]
    cmp ecx, 1
    jle args_done
    lea rbx, [r15+16]
    xor ebp, ebp

arg_loop:
    mov rsi, [rbx]
    test rsi, rsi
    jz args_done
    test ebp, ebp
    jnz arg_pos
    cmp byte [rsi], '-'
    jne arg_pos
    cmp byte [rsi+1], 0
    je arg_pos
    cmp byte [rsi+1], '-'
    jne arg_short
    cmp byte [rsi+2], 0
    jne .chk
    mov ebp, 1
    jmp arg_next
.chk:
    lea rdi, [rsi+2]
    ; Check each long option using str_eq
    lea r11, [str_help]
    call str_eq
    test al, al
    jnz do_help
    lea rdi, [rsi+2]
    lea r11, [str_version]
    call str_eq
    test al, al
    jnz do_version
    lea rdi, [rsi+2]
    lea r11, [str_decode]
    call str_eq
    test al, al
    jnz .set_dec
    lea rdi, [rsi+2]
    lea r11, [str_ignore_garbage]
    call str_eq
    test al, al
    jnz .set_ign
    ; --wrap=N
    lea rdi, [rsi+2]
    lea r11, [str_wrap_eq]
    call str_prefix
    test al, al
    jnz .wrap_eq
    ; --wrap N
    lea rdi, [rsi+2]
    lea r11, [str_wrap]
    call str_eq
    test al, al
    jnz .wrap_sp
    ; encoding options (check longer first)
    lea rdi, [rsi+2]
    lea r11, [str_base64url]
    call str_eq
    test al, al
    jnz .enc_b64u
    lea rdi, [rsi+2]
    lea r11, [str_base64]
    call str_eq
    test al, al
    jnz .enc_b64
    lea rdi, [rsi+2]
    lea r11, [str_base32hex]
    call str_eq
    test al, al
    jnz .enc_b32h
    lea rdi, [rsi+2]
    lea r11, [str_base32]
    call str_eq
    test al, al
    jnz .enc_b32
    lea rdi, [rsi+2]
    lea r11, [str_base16]
    call str_eq
    test al, al
    jnz .enc_b16
    lea rdi, [rsi+2]
    lea r11, [str_base2msbf]
    call str_eq
    test al, al
    jnz .enc_b2m
    lea rdi, [rsi+2]
    lea r11, [str_base2lsbf]
    call str_eq
    test al, al
    jnz .enc_b2l
    lea rdi, [rsi+2]
    lea r11, [str_z85]
    call str_eq
    test al, al
    jnz .enc_z85
    jmp err_unrec
.set_dec:
    or r12d, 1
    jmp arg_next
.set_ign:
    or r12d, 2
    jmp arg_next
.wrap_eq:
    lea rdi, [rsi+7]
    call parse_uint
    test eax, eax
    js err_inv_wrap
    mov r13d, eax
    jmp arg_next
.wrap_sp:
    add rbx, 8
    mov rdi, [rbx]
    test rdi, rdi
    jz err_wrap_long
    call parse_uint
    test eax, eax
    js err_inv_wrap
    mov r13d, eax
    jmp arg_next
.enc_b64u:
    mov byte [rsp], 1
    jmp arg_next
.enc_b64:
    mov byte [rsp], 0
    jmp arg_next
.enc_b32h:
    mov byte [rsp], 3
    jmp arg_next
.enc_b32:
    mov byte [rsp], 2
    jmp arg_next
.enc_b16:
    mov byte [rsp], 4
    jmp arg_next
.enc_b2m:
    mov byte [rsp], 5
    jmp arg_next
.enc_b2l:
    mov byte [rsp], 6
    jmp arg_next
.enc_z85:
    mov byte [rsp], 7
    jmp arg_next

do_help:
    mov rdi, STDOUT
    mov rsi, help_text
    mov rdx, help_text_len
    call asm_write_all
    xor edi, edi
    call asm_exit
do_version:
    mov rdi, STDOUT
    mov rsi, version_text
    mov rdx, version_text_len
    call asm_write_all
    xor edi, edi
    call asm_exit

arg_short:
    lea rsi, [rsi+1]
.lp:
    movzx eax, byte [rsi]
    test al, al
    jz arg_next
    cmp al, 'd'
    je .d
    cmp al, 'i'
    je .i
    cmp al, 'w'
    je .w
    ; invalid
    push rax
    mov rdi, STDERR
    mov rsi, err_inv_opt
    mov rdx, err_inv_opt_len
    call asm_write_all
    lea rsi, [rsp]
    mov rdi, STDERR
    mov rdx, 1
    call asm_write_all
    pop rax
    mov rdi, STDERR
    mov rsi, err_suf
    mov rdx, err_suf_len
    call asm_write_all
    mov edi, 1
    call asm_exit
.d: or r12d, 1
    inc rsi
    jmp .lp
.i: or r12d, 2
    inc rsi
    jmp .lp
.w: inc rsi
    cmp byte [rsi], 0
    je .wn
    mov rdi, rsi
    call parse_uint
    test eax, eax
    js err_inv_wrap
    mov r13d, eax
    jmp arg_next
.wn:
    add rbx, 8
    mov rdi, [rbx]
    test rdi, rdi
    jz err_w_arg
    call parse_uint
    test eax, eax
    js err_inv_wrap
    mov r13d, eax
    jmp arg_next

arg_pos:
    test r14, r14
    jnz err_extra
    mov r14, rsi
arg_next:
    add rbx, 8
    jmp arg_loop

args_done:
    movzx eax, byte [rsp]
    cmp al, ENC_NONE
    je err_miss_enc

    test r14, r14
    jz .stdin
    cmp byte [r14], '-'
    jne .openf
    cmp byte [r14+1], 0
    je .stdin
.openf:
    mov [filename_ptr], r14
    mov rdi, r14
    xor esi, esi
    xor edx, edx
    call asm_open
    test eax, eax
    js err_open
    mov ebp, eax
    jmp .disp
.stdin:
    xor ebp, ebp
.disp:
    movzx eax, byte [rsp]
    test r12d, 1
    jnz .ddec
    ; encode dispatch
    cmp al, 0
    je enc_b64
    cmp al, 1
    je enc_b64u
    cmp al, 2
    je enc_b32
    cmp al, 3
    je enc_b32h
    cmp al, 4
    je enc_b16
    cmp al, 5
    je enc_b2m
    cmp al, 6
    je enc_b2l
    cmp al, 7
    je enc_z85
    jmp err_miss_enc
.ddec:
    cmp al, 0
    je dec_b64
    cmp al, 1
    je dec_b64u
    cmp al, 2
    je dec_b32
    cmp al, 3
    je dec_b32h
    cmp al, 4
    je dec_b16
    cmp al, 5
    je dec_b2m
    cmp al, 6
    je dec_b2l
    cmp al, 7
    je dec_z85
    jmp err_miss_enc

; ═══════════════════════════════════════════════════════════════════════════
; BASE64 / BASE64URL ENCODE
; ═══════════════════════════════════════════════════════════════════════════
enc_b64:
    lea r10, [b64_enc]
    jmp enc_b64_common
enc_b64u:
    lea r10, [b64u_enc]
enc_b64_common:
    xor r8d, r8d       ; column
    xor r9d, r9d       ; leftover count
.rd:
    mov edi, ebp
    mov rsi, inbuf
    mov edx, INBUF_SIZE
    call asm_read
    test rax, rax
    js err_rd
    jz .final
    mov rcx, rax
    mov rsi, inbuf
    mov rdi, outbuf
    test r9d, r9d
    jz .ml
    cmp r9d, 1
    je .l1
    ; leftover==2, need 1 more
    test rcx, rcx
    jz .rd
    movzx eax, byte [rsp+4]
    shl eax, 16
    movzx edx, byte [rsp+5]
    shl edx, 8
    or eax, edx
    movzx edx, byte [rsi]
    or eax, edx
    inc rsi
    dec rcx
    call b64_triplet
    xor r9d, r9d
    jmp .ml
.l1:
    cmp rcx, 2
    jl .l1s
    movzx eax, byte [rsp+4]
    shl eax, 16
    movzx edx, byte [rsi]
    shl edx, 8
    or eax, edx
    movzx edx, byte [rsi+1]
    or eax, edx
    add rsi, 2
    sub rcx, 2
    call b64_triplet
    xor r9d, r9d
    jmp .ml
.l1s:
    test rcx, rcx
    jz .rd
    movzx eax, byte [rsi]
    mov [rsp+5], al
    mov r9d, 2
    jmp .rd
.ml:
    cmp rcx, 3
    jl .sv
    ; === FAST PATH: check if wrap=0 or wrap divisible by 4 ===
    test r13d, r13d
    jz .fast_triplet
    mov eax, r13d
    and eax, 3
    jnz .slow_triplet
.fast_triplet:
    ; Encode 3 bytes -> 4 base64 chars fully inline, no function calls
    movzx eax, byte [rsi]
    shl eax, 16
    movzx edx, byte [rsi+1]
    shl edx, 8
    or eax, edx
    movzx edx, byte [rsi+2]
    or eax, edx
    add rsi, 3
    sub rcx, 3
    mov edx, eax
    shr edx, 18
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    mov edx, eax
    shr edx, 12
    and edx, 0x3F
    movzx edx, byte [r10+rdx]
    mov [rdi+1], dl
    mov edx, eax
    shr edx, 6
    and edx, 0x3F
    movzx edx, byte [r10+rdx]
    mov [rdi+2], dl
    and eax, 0x3F
    movzx eax, byte [r10+rax]
    mov [rdi+3], al
    add rdi, 4
    ; Batch wrap check: add 4 to column, insert newline if needed
    test r13d, r13d
    jz .fast_nowrap
    add r8d, 4
    cmp r8d, r13d
    jl .fast_nowrap
    mov byte [rdi], 10
    inc rdi
    sub r8d, r13d
.fast_nowrap:
    mov rax, rdi
    sub rax, outbuf
    cmp rax, OUTBUF_SIZE-1024
    jl .ml
    push rcx
    push rsi
    mov rdx, rdi
    sub rdx, outbuf
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    test eax, eax
    js werr2
    pop rsi
    pop rcx
    mov rdi, outbuf
    jmp .ml
.slow_triplet:
    ; Slow path for non-4-aligned wrap: per-char wrap check
    movzx eax, byte [rsi]
    shl eax, 16
    movzx edx, byte [rsi+1]
    shl edx, 8
    or eax, edx
    movzx edx, byte [rsi+2]
    or eax, edx
    add rsi, 3
    sub rcx, 3
    push rcx
    push rsi
    mov rbx, rax
    mov edx, eax
    shr edx, 18
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    inc rdi
    call wchk
    mov eax, ebx
    shr eax, 12
    and eax, 0x3F
    movzx eax, byte [r10+rax]
    mov [rdi], al
    inc rdi
    call wchk
    mov eax, ebx
    shr eax, 6
    and eax, 0x3F
    movzx eax, byte [r10+rax]
    mov [rdi], al
    inc rdi
    call wchk
    and ebx, 0x3F
    movzx eax, byte [r10+rbx]
    mov [rdi], al
    inc rdi
    call wchk
    pop rsi
    pop rcx
    mov rax, rdi
    sub rax, outbuf
    cmp rax, OUTBUF_SIZE-1024
    jl .ml
    push rcx
    push rsi
    mov rdx, rdi
    sub rdx, outbuf
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    test eax, eax
    js werr2
    pop rsi
    pop rcx
    mov rdi, outbuf
    jmp .ml
.sv:
    mov r9d, ecx
    test ecx, ecx
    jz .fl
    mov al, [rsi]
    mov [rsp+4], al
    cmp ecx, 2
    jl .fl
    mov al, [rsi+1]
    mov [rsp+5], al
.fl:
    mov rdx, rdi
    sub rdx, outbuf
    test rdx, rdx
    jz .rd
    push r9
    push r9
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    pop r9
    pop r9
    test eax, eax
    js werr
    jmp .rd
.final:
    mov rdi, outbuf
    cmp r9d, 1
    je .p1
    cmp r9d, 2
    je .p2
    jmp .fnl
.p1:
    movzx eax, byte [rsp+4]
    shl eax, 16
    mov edx, eax
    shr edx, 18
    and edx, 0x3F
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    inc rdi
    call wchk
    mov edx, eax
    shr edx, 12
    and edx, 0x3F
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    inc rdi
    call wchk
    mov byte [rdi], '='
    inc rdi
    call wchk
    mov byte [rdi], '='
    inc rdi
    call wchk
    jmp .fnl
.p2:
    movzx eax, byte [rsp+4]
    shl eax, 16
    movzx edx, byte [rsp+5]
    shl edx, 8
    or eax, edx
    push rax
    mov edx, eax
    shr edx, 18
    and edx, 0x3F
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    inc rdi
    call wchk
    pop rax
    push rax
    mov edx, eax
    shr edx, 12
    and edx, 0x3F
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    inc rdi
    call wchk
    pop rax
    mov edx, eax
    shr edx, 6
    and edx, 0x3F
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    inc rdi
    call wchk
    mov byte [rdi], '='
    inc rdi
    call wchk
.fnl:
    test r13d, r13d
    jz .ffl
    test r8d, r8d
    jz .ffl
    mov byte [rdi], 10
    inc rdi
.ffl:
    mov rsi, outbuf
    mov rdx, rdi
    sub rdx, rsi
    test rdx, rdx
    jz done_ok
    mov rdi, STDOUT
    call asm_write_all
    jmp done_ok

; b64_triplet: encode 24-bit value in eax -> 4 chars at rdi with wrap (slow path only)
b64_triplet:
    push rax
    mov edx, eax
    shr edx, 18
    and edx, 0x3F
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    inc rdi
    call wchk
    pop rax
    push rax
    mov edx, eax
    shr edx, 12
    and edx, 0x3F
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    inc rdi
    call wchk
    pop rax
    push rax
    mov edx, eax
    shr edx, 6
    and edx, 0x3F
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    inc rdi
    call wchk
    pop rax
    and eax, 0x3F
    movzx eax, byte [r10+rax]
    mov [rdi], al
    inc rdi
    call wchk
    ret

; ═══════════════════════════════════════════════════════════════════════════
; BASE64 / BASE64URL DECODE
; ═══════════════════════════════════════════════════════════════════════════
dec_b64:
    lea r10, [b64_dec]
    jmp dec_b64_common
dec_b64u:
    lea r10, [b64u_dec]
dec_b64_common:
    xor r8d, r8d
    xor r9d, r9d
    mov r14, outbuf
.rd:
    mov edi, ebp
    mov rsi, inbuf
    mov edx, INBUF_SIZE
    call asm_read
    test rax, rax
    js err_rd
    jz .eof
    mov rcx, rax
    mov rsi, inbuf
.bl:
    test rcx, rcx
    jz .fr
    movzx eax, byte [rsi]
    inc rsi
    dec rcx
    cmp al, '='
    je .pad
    movzx edx, byte [r10+rax]
    cmp dl, 0xFE
    je .bl
    cmp dl, 0xFF
    je .garb
    shl r9d, 6
    or r9d, edx
    inc r8d
    cmp r8d, 4
    jl .bl
    mov eax, r9d
    shr eax, 16
    mov [r14], al
    mov eax, r9d
    shr eax, 8
    mov [r14+1], al
    mov [r14+2], r9b
    add r14, 3
    xor r8d, r8d
    xor r9d, r9d
    mov rax, r14
    sub rax, outbuf
    cmp rax, OUTBUF_SIZE-1024
    jl .bl
    push rcx
    push rsi
    mov rdx, r14
    sub rdx, outbuf
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    test eax, eax
    js werr2
    pop rsi
    pop rcx
    mov r14, outbuf
    jmp .bl
.garb:
    test r12d, 2
    jnz .bl
    jmp err_inv
.pad:
    inc r8d
    cmp r8d, 3
    je .ps
    cmp r8d, 4
    je .pd
    jmp err_inv
.ps: ; scan for second '='
    test rcx, rcx
    jz .psr
    movzx eax, byte [rsi]
    inc rsi
    dec rcx
    cmp al, '='
    je .pd
    movzx edx, byte [r10+rax]
    cmp dl, 0xFE
    je .ps
    test r12d, 2
    jnz .ps
    jmp err_inv
.psr:
    push r8
    push r9
    mov edi, ebp
    mov rsi, inbuf
    mov edx, INBUF_SIZE
    call asm_read
    pop r9
    pop r8
    test rax, rax
    jz err_inv
    js err_rd
    mov rcx, rax
    mov rsi, inbuf
    jmp .ps
.pd: ; padding done
    cmp r8d, 3
    je .o1
    ; 3 data + 1 pad -> 2 bytes
    shl r9d, 6
    mov eax, r9d
    shr eax, 16
    mov [r14], al
    mov eax, r9d
    shr eax, 8
    mov [r14+1], al
    add r14, 2
    xor r8d, r8d
    xor r9d, r9d
    jmp .bl
.o1: ; 2 data + 2 pad -> 1 byte
    shl r9d, 12
    mov eax, r9d
    shr eax, 16
    mov [r14], al
    inc r14
    xor r8d, r8d
    xor r9d, r9d
    jmp .bl
.fr:
    mov rdx, r14
    sub rdx, outbuf
    test rdx, rdx
    jz .rd
    push r8
    push r9
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    pop r9
    pop r8
    test eax, eax
    js werr
    mov r14, outbuf
    jmp .rd
.eof:
    test r8d, r8d
    jnz .eoi
    mov rsi, outbuf
    mov rdx, r14
    sub rdx, rsi
    test rdx, rdx
    jz done_ok
    mov rdi, STDOUT
    call asm_write_all
    jmp done_ok
.eoi: ; incomplete
    cmp r8d, 2
    jl .eoe
    je .eo1
    shl r9d, 6
    mov eax, r9d
    shr eax, 16
    mov [r14], al
    mov eax, r9d
    shr eax, 8
    mov [r14+1], al
    add r14, 2
    jmp .eoe
.eo1:
    shl r9d, 12
    mov eax, r9d
    shr eax, 16
    mov [r14], al
    inc r14
.eoe:
    mov rsi, outbuf
    mov rdx, r14
    sub rdx, rsi
    test rdx, rdx
    jz err_inv_msg
    mov rdi, STDOUT
    call asm_write_all
    jmp err_inv_msg

; ═══════════════════════════════════════════════════════════════════════════
; BASE32 / BASE32HEX ENCODE
; ═══════════════════════════════════════════════════════════════════════════
enc_b32:
    lea r10, [b32_enc]
    jmp enc_b32_common
enc_b32h:
    lea r10, [b32h_enc]
enc_b32_common:
    xor r8d, r8d
    xor r9d, r9d
.rd:
    mov edi, ebp
    mov rsi, inbuf
    mov edx, INBUF_SIZE
    call asm_read
    test rax, rax
    js err_rd
    jz .final
    mov rcx, rax
    mov rsi, inbuf
    mov rdi, outbuf
    test r9d, r9d
    jz .ml
.fl: ; fill leftover
    cmp r9d, 5
    jge .elg
    test rcx, rcx
    jz .frd
    movzx eax, byte [rsi]
    lea r11, [rsp+4]
    add r11, r9
    mov [r11], al
    inc rsi
    dec rcx
    inc r9d
    jmp .fl
.elg:
    mov rbx, rcx
    call b32_group
    mov rcx, rbx
    xor r9d, r9d
.ml:
    cmp rcx, 5
    jl .sv
    ; === FAST PATH: check if wrap=0 or wrap >= 8 ===
    test r13d, r13d
    jz .fast_5bytes
    cmp r13d, 8
    jge .fast_5bytes
    jmp .slow_5bytes
.fast_5bytes:
    ; Build 40-bit value in rax directly from input (no stack copy)
    movzx eax, byte [rsi]
    shl rax, 8
    movzx edx, byte [rsi+1]
    or eax, edx
    shl rax, 8
    movzx edx, byte [rsi+2]
    or eax, edx
    shl rax, 8
    movzx edx, byte [rsi+3]
    or eax, edx
    shl rax, 8
    movzx edx, byte [rsi+4]
    or rax, rdx
    add rsi, 5
    sub rcx, 5
    ; Extract 8 x 5-bit groups directly to output (fully inline)
    mov rdx, rax
    shr rdx, 35
    and edx, 0x1F
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    mov rdx, rax
    shr rdx, 30
    and edx, 0x1F
    movzx edx, byte [r10+rdx]
    mov [rdi+1], dl
    mov rdx, rax
    shr rdx, 25
    and edx, 0x1F
    movzx edx, byte [r10+rdx]
    mov [rdi+2], dl
    mov rdx, rax
    shr rdx, 20
    and edx, 0x1F
    movzx edx, byte [r10+rdx]
    mov [rdi+3], dl
    mov rdx, rax
    shr rdx, 15
    and edx, 0x1F
    movzx edx, byte [r10+rdx]
    mov [rdi+4], dl
    mov rdx, rax
    shr rdx, 10
    and edx, 0x1F
    movzx edx, byte [r10+rdx]
    mov [rdi+5], dl
    mov rdx, rax
    shr rdx, 5
    and edx, 0x1F
    movzx edx, byte [r10+rdx]
    mov [rdi+6], dl
    and eax, 0x1F
    movzx eax, byte [r10+rax]
    mov [rdi+7], al
    add rdi, 8
    ; Batch wrap check: add 8 to column
    test r13d, r13d
    jz .fast_b32_nowrap
    add r8d, 8
    cmp r8d, r13d
    jl .fast_b32_nowrap
    je .fast_b32_exact
    ; column > wrap: need to insert newline within the 8-char block
    mov eax, r8d
    sub eax, r13d      ; overflow count (1..7)
    mov r11d, eax       ; save overflow
    lea rbx, [rdi - 1]  ; last char position
.fast_b32_shift:
    test eax, eax
    jz .fast_b32_shifted
    movzx edx, byte [rbx]
    mov [rbx+1], dl
    dec rbx
    dec eax
    jmp .fast_b32_shift
.fast_b32_shifted:
    mov byte [rbx+1], 10
    inc rdi
    mov r8d, r11d
    jmp .fast_b32_nowrap
.fast_b32_exact:
    mov byte [rdi], 10
    inc rdi
    xor r8d, r8d
.fast_b32_nowrap:
    mov rax, rdi
    sub rax, outbuf
    cmp rax, OUTBUF_SIZE-1024
    jl .ml
    push rcx
    push rsi
    mov rdx, rdi
    sub rdx, outbuf
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    test eax, eax
    js werr2
    pop rsi
    pop rcx
    mov rdi, outbuf
    jmp .ml
.slow_5bytes:
    ; Slow path for wrap < 8: copy to stack, use per-char b32_group
    mov al, [rsi]
    mov [rsp+4], al
    mov al, [rsi+1]
    mov [rsp+5], al
    mov al, [rsi+2]
    mov [rsp+6], al
    mov al, [rsi+3]
    mov [rsp+7], al
    mov al, [rsi+4]
    mov [rsp+8], al
    add rsi, 5
    sub rcx, 5
    mov rbx, rcx
    call b32_group
    mov rcx, rbx
    mov rax, rdi
    sub rax, outbuf
    cmp rax, OUTBUF_SIZE-1024
    jl .ml
    push rcx
    push rsi
    mov rdx, rdi
    sub rdx, outbuf
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    test eax, eax
    js werr2
    pop rsi
    pop rcx
    mov rdi, outbuf
    jmp .ml
.sv:
    mov r9d, ecx
    xor r11d, r11d
.svl:
    cmp r11d, ecx
    jge .frd
    movzx eax, byte [rsi+r11]
    mov byte [rsp+r11+4], al
    inc r11d
    jmp .svl
.frd:
    mov rdx, rdi
    sub rdx, outbuf
    test rdx, rdx
    jz .rd
    push r9
    push r9
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    pop r9
    pop r9
    test eax, eax
    js werr
    jmp .rd
.final:
    mov rdi, outbuf
    test r9d, r9d
    jz .fnl
    ; Pad remaining bytes with zeros
    mov r11d, r9d
.pz:
    cmp r11d, 5
    jge .ef
    mov byte [rsp+r11+4], 0
    inc r11d
    jmp .pz
.ef:
    ; For leftover count r9d: valid_chars / pad_chars:
    ;   1 -> 2 valid, 6 pad
    ;   2 -> 4 valid, 4 pad
    ;   3 -> 5 valid, 3 pad
    ;   4 -> 7 valid, 1 pad
    ; Load bytes for encoding
    movzx eax, byte [rsp+4]   ; b0
    movzx edx, byte [rsp+5]   ; b1
    ; c0: b0>>3 (always valid for leftover >= 1)
    mov ecx, eax
    shr ecx, 3
    movzx ecx, byte [r10+rcx]
    mov [rdi], cl
    inc rdi
    call wchk
    ; c1: (b0&7)<<2 | b1>>6 (always valid for leftover >= 1)
    movzx eax, byte [rsp+4]
    movzx edx, byte [rsp+5]
    mov ecx, eax
    and ecx, 7
    shl ecx, 2
    mov eax, edx
    shr eax, 6
    or ecx, eax
    movzx ecx, byte [r10+rcx]
    mov [rdi], cl
    inc rdi
    call wchk
    cmp r9d, 1
    je .pad6
    ; c2: (b1>>1)&0x1F (valid for leftover >= 2)
    movzx edx, byte [rsp+5]
    mov ecx, edx
    shr ecx, 1
    and ecx, 0x1F
    movzx ecx, byte [r10+rcx]
    mov [rdi], cl
    inc rdi
    call wchk
    ; c3: (b1&1)<<4 | b2>>4 (valid for leftover >= 2)
    movzx edx, byte [rsp+5]
    and edx, 1
    shl edx, 4
    movzx eax, byte [rsp+6]
    mov ecx, eax
    shr ecx, 4
    or edx, ecx
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    inc rdi
    call wchk
    cmp r9d, 2
    je .pad4
    ; c4: (b2&0xF)<<1 | b3>>7 (valid for leftover >= 3)
    movzx eax, byte [rsp+6]
    and eax, 0xF
    shl eax, 1
    movzx edx, byte [rsp+7]
    mov ecx, edx
    shr ecx, 7
    or eax, ecx
    movzx eax, byte [r10+rax]
    mov [rdi], al
    inc rdi
    call wchk
    cmp r9d, 3
    je .pad3
    ; c5: (b3>>2)&0x1F (valid for leftover >= 4)
    movzx edx, byte [rsp+7]
    mov ecx, edx
    shr ecx, 2
    and ecx, 0x1F
    movzx ecx, byte [r10+rcx]
    mov [rdi], cl
    inc rdi
    call wchk
    ; c6: (b3&3)<<3 (valid for leftover >= 4, b4=0)
    movzx edx, byte [rsp+7]
    and edx, 3
    shl edx, 3
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    inc rdi
    call wchk
    ; 1 pad char
    mov ecx, 1
    jmp .dpl
.pad6: mov ecx, 6
    jmp .dpl
.pad4: mov ecx, 4
    jmp .dpl
.pad3: mov ecx, 3
.dpl:
    test ecx, ecx
    jz .fnl
    mov byte [rdi], '='
    inc rdi
    push rcx
    call wchk
    pop rcx
    dec ecx
    jmp .dpl
.fnl:
    test r13d, r13d
    jz .ffl
    test r8d, r8d
    jz .ffl
    mov byte [rdi], 10
    inc rdi
.ffl:
    mov rsi, outbuf
    mov rdx, rdi
    sub rdx, rsi
    test rdx, rdx
    jz done_ok
    mov rdi, STDOUT
    call asm_write_all
    jmp done_ok

; b32_group: encode 5 bytes from caller's [rsp+4..8] -> 8 chars at rdi
; Note: call pushes 8-byte return addr, so caller's [rsp+N] = our [rsp+N+8]
b32_group:
    movzx eax, byte [rsp+12]
    movzx edx, byte [rsp+13]
    ; c0: b0>>3
    mov ecx, eax
    shr ecx, 3
    movzx ecx, byte [r10+rcx]
    mov [rdi], cl
    inc rdi
    call wchk
    ; c1: (b0&7)<<2 | b1>>6
    mov ecx, eax
    and ecx, 7
    shl ecx, 2
    mov eax, edx
    shr eax, 6
    or ecx, eax
    movzx ecx, byte [r10+rcx]
    mov [rdi], cl
    inc rdi
    call wchk
    ; c2: (b1>>1)&0x1F
    mov ecx, edx
    shr ecx, 1
    and ecx, 0x1F
    movzx ecx, byte [r10+rcx]
    mov [rdi], cl
    inc rdi
    call wchk
    ; c3: (b1&1)<<4 | b2>>4
    and edx, 1
    shl edx, 4
    movzx eax, byte [rsp+14]
    mov ecx, eax
    shr ecx, 4
    or edx, ecx
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    inc rdi
    call wchk
    ; c4: (b2&0xF)<<1 | b3>>7
    and eax, 0xF
    shl eax, 1
    movzx edx, byte [rsp+15]
    mov ecx, edx
    shr ecx, 7
    or eax, ecx
    movzx eax, byte [r10+rax]
    mov [rdi], al
    inc rdi
    call wchk
    ; c5: (b3>>2)&0x1F
    mov ecx, edx
    shr ecx, 2
    and ecx, 0x1F
    movzx ecx, byte [r10+rcx]
    mov [rdi], cl
    inc rdi
    call wchk
    ; c6: (b3&3)<<3 | b4>>5
    and edx, 3
    shl edx, 3
    movzx eax, byte [rsp+16]
    mov ecx, eax
    shr ecx, 5
    or edx, ecx
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    inc rdi
    call wchk
    ; c7: b4&0x1F
    and eax, 0x1F
    movzx eax, byte [r10+rax]
    mov [rdi], al
    inc rdi
    call wchk
    ret

; ═══════════════════════════════════════════════════════════════════════════
; BASE32 / BASE32HEX DECODE
; ═══════════════════════════════════════════════════════════════════════════
dec_b32:
    lea r10, [b32_dec]
    jmp dec_b32_common
dec_b32h:
    lea r10, [b32h_dec]
dec_b32_common:
    xor r8d, r8d
    mov byte [rsp+20], 0xFF  ; sentinel: no pad seen yet
    mov r14, outbuf
.rd:
    mov edi, ebp
    mov rsi, inbuf
    mov edx, INBUF_SIZE
    call asm_read
    test rax, rax
    js err_rd
    jz .eof
    mov rcx, rax
    mov rsi, inbuf
.bl:
    test rcx, rcx
    jz .fr
    movzx eax, byte [rsi]
    inc rsi
    dec rcx
    cmp al, '='
    je .pad
    movzx edx, byte [r10+rax]
    cmp dl, 0xFE
    je .bl
    cmp dl, 0xFF
    je .garb
    mov byte [rsp+r8+4], dl
    inc r8d
    cmp r8d, 8
    jl .bl
    mov rbx, rcx
    call b32_dec_grp
    mov rcx, rbx
    add r14, 5
    xor r8d, r8d
    mov byte [rsp+20], 0xFF  ; reset pad sentinel
    mov rax, r14
    sub rax, outbuf
    cmp rax, OUTBUF_SIZE-1024
    jl .bl
    push rcx
    push rsi
    mov rdx, r14
    sub rdx, outbuf
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    test eax, eax
    js werr2
    pop rsi
    pop rcx
    mov r14, outbuf
    jmp .bl
.garb:
    test r12d, 2
    jnz .bl
    jmp err_inv
.pad:
    ; [rsp+20] = count of data chars before first pad (set once)
    cmp byte [rsp+20], 0xFF
    jne .pad2
    mov [rsp+20], r8b
.pad2:
    mov byte [rsp+r8+4], 0
    inc r8d
    cmp r8d, 8
    jl .bl
    ; skip remaining '=' and whitespace
.sp:
    test rcx, rcx
    jz .po
    movzx eax, byte [rsi]
    cmp al, '='
    jne .spw
    inc rsi
    dec rcx
    jmp .sp
.spw:
    movzx edx, byte [r10+rax]
    cmp dl, 0xFE
    jne .po
    inc rsi
    dec rcx
    jmp .sp
.po: ; decode
    mov rbx, rcx
    call b32_dec_grp
    mov rcx, rbx
    movzx r11d, byte [rsp+20]
    cmp r11d, 2
    je .a1
    cmp r11d, 4
    je .a2
    cmp r11d, 5
    je .a3
    cmp r11d, 7
    je .a4
    jmp err_inv
.a1: inc r14
    jmp .ad
.a2: add r14, 2
    jmp .ad
.a3: add r14, 3
    jmp .ad
.a4: add r14, 4
.ad: xor r8d, r8d
    mov byte [rsp+20], 0xFF  ; reset pad sentinel
    jmp .bl
.fr:
    mov rdx, r14
    sub rdx, outbuf
    test rdx, rdx
    jz .rd
    push r8
    push rax
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    pop rax
    pop r8
    test eax, eax
    js werr
    mov r14, outbuf
    jmp .rd
.eof:
    test r8d, r8d
    jnz err_inv
    mov rsi, outbuf
    mov rdx, r14
    sub rdx, rsi
    test rdx, rdx
    jz done_ok
    mov rdi, STDOUT
    call asm_write_all
    jmp done_ok

; b32_dec_grp: decode 8x5bit values from caller's [rsp+4..11] -> 5 bytes at r14
; Note: call pushes 8-byte return addr, so caller's [rsp+N] = our [rsp+N+8]
b32_dec_grp:
    movzx eax, byte [rsp+12]
    movzx edx, byte [rsp+13]
    mov ecx, eax
    shl ecx, 3
    mov eax, edx
    shr eax, 2
    or ecx, eax
    mov [r14], cl
    and edx, 3
    shl edx, 6
    movzx eax, byte [rsp+14]
    mov ecx, eax
    shl ecx, 1
    or edx, ecx
    movzx ecx, byte [rsp+15]
    mov eax, ecx
    shr eax, 4
    or edx, eax
    mov [r14+1], dl
    and ecx, 0xF
    shl ecx, 4
    movzx edx, byte [rsp+16]
    mov eax, edx
    shr eax, 1
    or ecx, eax
    mov [r14+2], cl
    and edx, 1
    shl edx, 7
    movzx ecx, byte [rsp+17]
    shl ecx, 2
    or edx, ecx
    movzx ecx, byte [rsp+18]
    mov eax, ecx
    shr eax, 3
    or edx, eax
    mov [r14+3], dl
    and ecx, 7
    shl ecx, 5
    movzx edx, byte [rsp+19]
    or ecx, edx
    mov [r14+4], cl
    ret

; ═══════════════════════════════════════════════════════════════════════════
; BASE16 ENCODE
; ═══════════════════════════════════════════════════════════════════════════
enc_b16:
    lea r10, [hex_ch]
    xor r8d, r8d
.rd:
    mov edi, ebp
    mov rsi, inbuf
    mov edx, INBUF_SIZE
    call asm_read
    test rax, rax
    js err_rd
    jz .fin
    mov rcx, rax
    mov rsi, inbuf
    mov rdi, outbuf
.bl:
    test rcx, rcx
    jz .fr
    ; Write both hex chars inline, single batch wrap check
    movzx eax, byte [rsi]
    inc rsi
    dec rcx
    mov edx, eax
    shr edx, 4
    movzx edx, byte [r10+rdx]
    mov [rdi], dl
    and eax, 0xF
    movzx eax, byte [r10+rax]
    mov [rdi+1], al
    add rdi, 2
    ; Batch wrap check: column += 2
    test r13d, r13d
    jz .hex_nowrap
    add r8d, 2
    cmp r8d, r13d
    jl .hex_nowrap
    je .hex_exact_wrap
    ; column > wrap (odd wrap): split the 2-char pair with a newline
    movzx edx, byte [rdi-1]
    mov [rdi], dl
    mov byte [rdi-1], 10
    inc rdi
    mov r8d, 1
    jmp .hex_nowrap
.hex_exact_wrap:
    mov byte [rdi], 10
    inc rdi
    xor r8d, r8d
.hex_nowrap:
    mov rax, rdi
    sub rax, outbuf
    cmp rax, OUTBUF_SIZE-1024
    jl .bl
    push rcx
    push rsi
    mov rdx, rdi
    sub rdx, outbuf
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    test eax, eax
    js werr2
    pop rsi
    pop rcx
    mov rdi, outbuf
    jmp .bl
.fr:
    mov rdx, rdi
    sub rdx, outbuf
    test rdx, rdx
    jz .rd
    push rax
    push rax
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    pop rax
    pop rax
    test eax, eax
    js werr
    jmp .rd
.fin:
    test r13d, r13d
    jz done_ok
    test r8d, r8d
    jz done_ok
    mov rdi, STDOUT
    mov rsi, nl_ch
    mov rdx, 1
    call asm_write_all
    jmp done_ok

; ═══════════════════════════════════════════════════════════════════════════
; BASE16 DECODE
; ═══════════════════════════════════════════════════════════════════════════
dec_b16:
    xor r8d, r8d
    xor r9d, r9d
    mov r14, outbuf
.rd:
    mov edi, ebp
    mov rsi, inbuf
    mov edx, INBUF_SIZE
    call asm_read
    test rax, rax
    js err_rd
    jz .eof
    mov rcx, rax
    mov rsi, inbuf
.bl:
    test rcx, rcx
    jz .fr
    movzx eax, byte [rsi]
    inc rsi
    dec rcx
    cmp al, 10
    je .bl
    cmp al, 13
    je .bl
    cmp al, 9
    je .bl
    cmp al, 32
    je .bl
    cmp al, '0'
    jl .garb
    cmp al, '9'
    jle .dig
    cmp al, 'A'
    jl .cl
    cmp al, 'F'
    jle .up
.cl:
    cmp al, 'a'
    jl .garb
    cmp al, 'f'
    jg .garb
    sub al, 'a'-10
    jmp .hn
.dig:
    sub al, '0'
    jmp .hn
.up:
    sub al, 'A'-10
.hn:
    test r8d, r8d
    jnz .s2
    movzx r9d, al
    shl r9d, 4
    mov r8d, 1
    jmp .bl
.s2:
    or r9d, eax
    mov [r14], r9b
    inc r14
    xor r8d, r8d
    mov rax, r14
    sub rax, outbuf
    cmp rax, OUTBUF_SIZE-1024
    jl .bl
    push rcx
    push rsi
    mov rdx, r14
    sub rdx, outbuf
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    test eax, eax
    js werr2
    pop rsi
    pop rcx
    mov r14, outbuf
    jmp .bl
.garb:
    test r12d, 2
    jnz .bl
    jmp err_inv
.fr:
    mov rdx, r14
    sub rdx, outbuf
    test rdx, rdx
    jz .rd
    push r8
    push r9
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    pop r9
    pop r8
    test eax, eax
    js werr
    mov r14, outbuf
    jmp .rd
.eof:
    test r8d, r8d
    jnz err_inv
    mov rsi, outbuf
    mov rdx, r14
    sub rdx, rsi
    test rdx, rdx
    jz done_ok
    mov rdi, STDOUT
    call asm_write_all
    jmp done_ok

; ═══════════════════════════════════════════════════════════════════════════
; BASE2 ENCODE (MSBF and LSBF)
; ═══════════════════════════════════════════════════════════════════════════
enc_b2m:
    xor r8d, r8d
    mov r9d, 1             ; direction flag: 1=MSB first
    jmp enc_b2_common
enc_b2l:
    xor r8d, r8d
    xor r9d, r9d           ; 0=LSB first
enc_b2_common:
.rd:
    mov edi, ebp
    mov rsi, inbuf
    mov edx, INBUF_SIZE
    call asm_read
    test rax, rax
    js err_rd
    jz .fin
    mov rcx, rax
    mov rsi, inbuf
    mov rdi, outbuf
.bl:
    test rcx, rcx
    jz .fr
    ; === FAST PATH: wrap=0 or wrap >= 8 ===
    test r13d, r13d
    jz .fast_b2
    cmp r13d, 8
    jge .fast_b2
    jmp .slow_b2
.fast_b2:
    movzx eax, byte [rsi]
    inc rsi
    dec rcx
    ; Write all 8 bits at once using branchless arithmetic: (bit & 1) + '0'
    test r9d, r9d
    jnz .fast_msb
    ; LSB first: bit 0 first
    mov edx, eax
    and edx, 1
    add edx, '0'
    mov [rdi], dl
    mov edx, eax
    shr edx, 1
    and edx, 1
    add edx, '0'
    mov [rdi+1], dl
    mov edx, eax
    shr edx, 2
    and edx, 1
    add edx, '0'
    mov [rdi+2], dl
    mov edx, eax
    shr edx, 3
    and edx, 1
    add edx, '0'
    mov [rdi+3], dl
    mov edx, eax
    shr edx, 4
    and edx, 1
    add edx, '0'
    mov [rdi+4], dl
    mov edx, eax
    shr edx, 5
    and edx, 1
    add edx, '0'
    mov [rdi+5], dl
    mov edx, eax
    shr edx, 6
    and edx, 1
    add edx, '0'
    mov [rdi+6], dl
    shr eax, 7
    add eax, '0'
    mov [rdi+7], al
    jmp .fast_b2_done
.fast_msb:
    ; MSB first: bit 7 first
    mov edx, eax
    shr edx, 7
    add edx, '0'
    mov [rdi], dl
    mov edx, eax
    shr edx, 6
    and edx, 1
    add edx, '0'
    mov [rdi+1], dl
    mov edx, eax
    shr edx, 5
    and edx, 1
    add edx, '0'
    mov [rdi+2], dl
    mov edx, eax
    shr edx, 4
    and edx, 1
    add edx, '0'
    mov [rdi+3], dl
    mov edx, eax
    shr edx, 3
    and edx, 1
    add edx, '0'
    mov [rdi+4], dl
    mov edx, eax
    shr edx, 2
    and edx, 1
    add edx, '0'
    mov [rdi+5], dl
    mov edx, eax
    shr edx, 1
    and edx, 1
    add edx, '0'
    mov [rdi+6], dl
    and eax, 1
    add eax, '0'
    mov [rdi+7], al
.fast_b2_done:
    add rdi, 8
    ; Batch wrap check
    test r13d, r13d
    jz .fast_b2_nowrap
    add r8d, 8
    cmp r8d, r13d
    jl .fast_b2_nowrap
    je .fast_b2_exact
    ; column > wrap: insert newline within the 8-char block
    mov eax, r8d
    sub eax, r13d       ; overflow count (1..7)
    mov r11d, eax        ; save overflow
    lea rbx, [rdi - 1]   ; last char position
.fast_b2_shift:
    test eax, eax
    jz .fast_b2_shifted
    movzx edx, byte [rbx]
    mov [rbx+1], dl
    dec rbx
    dec eax
    jmp .fast_b2_shift
.fast_b2_shifted:
    mov byte [rbx+1], 10
    inc rdi
    mov r8d, r11d
    jmp .fast_b2_nowrap
.fast_b2_exact:
    mov byte [rdi], 10
    inc rdi
    xor r8d, r8d
.fast_b2_nowrap:
    mov rax, rdi
    sub rax, outbuf
    cmp rax, OUTBUF_SIZE-1024
    jl .bl
    push rcx
    push rsi
    mov rdx, rdi
    sub rdx, outbuf
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    test eax, eax
    js werr2
    pop rsi
    pop rcx
    mov rdi, outbuf
    jmp .bl
.slow_b2:
    ; Slow path for non-8-aligned wrap
    movzx eax, byte [rsi]
    inc rsi
    dec rcx
    test r9d, r9d
    jnz .msb
    ; LSB first
    xor r11d, r11d
.lbit:
    bt eax, r11d
    jc .l1
    mov byte [rdi], '0'
    jmp .ln
.l1: mov byte [rdi], '1'
.ln: inc rdi
    push rax
    call wchk
    pop rax
    inc r11d
    cmp r11d, 8
    jl .lbit
    jmp .bc
.msb:
    mov r11d, 7
.mbit:
    bt eax, r11d
    jc .m1
    mov byte [rdi], '0'
    jmp .mn
.m1: mov byte [rdi], '1'
.mn: inc rdi
    push rax
    call wchk
    pop rax
    dec r11d
    jns .mbit
.bc:
    mov rax, rdi
    sub rax, outbuf
    cmp rax, OUTBUF_SIZE-1024
    jl .bl
    push rcx
    push rsi
    mov rdx, rdi
    sub rdx, outbuf
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    test eax, eax
    js werr2
    pop rsi
    pop rcx
    mov rdi, outbuf
    jmp .bl
.fr:
    mov rdx, rdi
    sub rdx, outbuf
    test rdx, rdx
    jz .rd
    push rax
    push rax
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    pop rax
    pop rax
    test eax, eax
    js werr
    jmp .rd
.fin:
    test r13d, r13d
    jz done_ok
    test r8d, r8d
    jz done_ok
    mov rdi, STDOUT
    mov rsi, nl_ch
    mov rdx, 1
    call asm_write_all
    jmp done_ok

; ═══════════════════════════════════════════════════════════════════════════
; BASE2 DECODE (MSBF and LSBF)
; ═══════════════════════════════════════════════════════════════════════════
dec_b2m:
    mov dword [rsp+16], 1   ; direction=MSB
    jmp dec_b2_common
dec_b2l:
    mov dword [rsp+16], 0   ; direction=LSB
dec_b2_common:
    xor r8d, r8d
    xor r9d, r9d
    mov r14, outbuf
.rd:
    mov edi, ebp
    mov rsi, inbuf
    mov edx, INBUF_SIZE
    call asm_read
    test rax, rax
    js err_rd
    jz .eof
    mov rcx, rax
    mov rsi, inbuf
.bl:
    test rcx, rcx
    jz .fr
    movzx eax, byte [rsi]
    inc rsi
    dec rcx
    cmp al, 10
    je .bl
    cmp al, 13
    je .bl
    cmp al, 9
    je .bl
    cmp al, 32
    je .bl
    cmp al, '0'
    je .z
    cmp al, '1'
    je .o
    test r12d, 2
    jnz .bl
    jmp err_inv
.z: cmp dword [rsp+16], 0
    je .zl
    shl r9d, 1
    jmp .ck
.zl: jmp .ck
.o: cmp dword [rsp+16], 0
    je .ol
    shl r9d, 1
    or r9d, 1
    jmp .ck
.ol:
    bts r9d, r8d
.ck:
    inc r8d
    cmp r8d, 8
    jl .bl
    mov [r14], r9b
    inc r14
    xor r8d, r8d
    xor r9d, r9d
    mov rax, r14
    sub rax, outbuf
    cmp rax, OUTBUF_SIZE-1024
    jl .bl
    push rcx
    push rsi
    mov rdx, r14
    sub rdx, outbuf
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    test eax, eax
    js werr2
    pop rsi
    pop rcx
    mov r14, outbuf
    jmp .bl
.fr:
    mov rdx, r14
    sub rdx, outbuf
    test rdx, rdx
    jz .rd
    push r8
    push r9
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    pop r9
    pop r8
    test eax, eax
    js werr
    mov r14, outbuf
    jmp .rd
.eof:
    test r8d, r8d
    jnz err_inv
    mov rsi, outbuf
    mov rdx, r14
    sub rdx, rsi
    test rdx, rdx
    jz done_ok
    mov rdi, STDOUT
    call asm_write_all
    jmp done_ok

; ═══════════════════════════════════════════════════════════════════════════
; Z85 ENCODE
; ═══════════════════════════════════════════════════════════════════════════
enc_z85:
    lea r10, [z85_enc]
    xor r8d, r8d
    xor r9d, r9d
.rd:
    mov edi, ebp
    mov rsi, inbuf
    mov edx, INBUF_SIZE
    call asm_read
    test rax, rax
    js err_rd
    jz .fin
    mov rcx, rax
    mov rsi, inbuf
    mov rdi, outbuf
    test r9d, r9d
    jz .ml
.fl:
    cmp r9d, 4
    jge .elg
    test rcx, rcx
    jz .frd
    movzx eax, byte [rsi]
    lea r11, [rsp+4]
    add r11, r9
    mov [r11], al
    inc rsi
    dec rcx
    inc r9d
    jmp .fl
.elg:
    mov rbx, rcx
    call z85_grp
    mov rcx, rbx
    xor r9d, r9d
.ml:
    cmp rcx, 4
    jl .sv
    mov al, [rsi]
    mov [rsp+4], al
    mov al, [rsi+1]
    mov [rsp+5], al
    mov al, [rsi+2]
    mov [rsp+6], al
    mov al, [rsi+3]
    mov [rsp+7], al
    add rsi, 4
    sub rcx, 4
    mov rbx, rcx
    call z85_grp
    mov rcx, rbx
    mov rax, rdi
    sub rax, outbuf
    cmp rax, OUTBUF_SIZE-1024
    jl .ml
    push rcx
    push rsi
    mov rdx, rdi
    sub rdx, outbuf
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    test eax, eax
    js werr2
    pop rsi
    pop rcx
    mov rdi, outbuf
    jmp .ml
.sv:
    mov r9d, ecx
    xor r11d, r11d
.svl:
    cmp r11d, ecx
    jge .frd
    movzx eax, byte [rsi+r11]
    mov byte [rsp+r11+4], al
    inc r11d
    jmp .svl
.frd:
    mov rdx, rdi
    sub rdx, outbuf
    test rdx, rdx
    jz .rd
    push r9
    push r9
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    pop r9
    pop r9
    test eax, eax
    js werr
    jmp .rd
.fin:
    test r9d, r9d
    jnz .lerr
    mov rdi, outbuf
    test r13d, r13d
    jz .ffl
    test r8d, r8d
    jz .ffl
    mov byte [rdi], 10
    inc rdi
.ffl:
    mov rsi, outbuf
    mov rdx, rdi
    sub rdx, rsi
    test rdx, rdx
    jz done_ok
    mov rdi, STDOUT
    call asm_write_all
    jmp done_ok
.lerr:
    mov rdi, STDERR
    mov rsi, err_z85m4
    mov rdx, err_z85m4_len
    call asm_write_all
    mov edi, 1
    call asm_exit

; z85_grp: encode 4 bytes from caller's [rsp+4..7] -> 5 chars at rdi
; Note: call pushes 8-byte return addr, so caller's [rsp+N] = our [rsp+N+8]
z85_grp:
    movzx eax, byte [rsp+12]
    shl eax, 24
    movzx edx, byte [rsp+13]
    shl edx, 16
    or eax, edx
    movzx edx, byte [rsp+14]
    shl edx, 8
    or eax, edx
    movzx edx, byte [rsp+15]
    or eax, edx
    xor edx, edx
    mov ecx, 52200625
    div ecx
    movzx r11d, byte [r10+rax]
    mov [rdi], r11b
    inc rdi
    call wchk
    mov eax, edx
    xor edx, edx
    mov ecx, 614125
    div ecx
    movzx r11d, byte [r10+rax]
    mov [rdi], r11b
    inc rdi
    call wchk
    mov eax, edx
    xor edx, edx
    mov ecx, 7225
    div ecx
    movzx r11d, byte [r10+rax]
    mov [rdi], r11b
    inc rdi
    call wchk
    mov eax, edx
    xor edx, edx
    mov ecx, 85
    div ecx
    movzx r11d, byte [r10+rax]
    mov [rdi], r11b
    inc rdi
    call wchk
    movzx r11d, byte [r10+rdx]
    mov [rdi], r11b
    inc rdi
    call wchk
    ret

; ═══════════════════════════════════════════════════════════════════════════
; Z85 DECODE
; ═══════════════════════════════════════════════════════════════════════════
dec_z85:
    lea r10, [z85_dec]
    xor r8d, r8d
    xor r9, r9
    mov r14, outbuf
.rd:
    mov edi, ebp
    mov rsi, inbuf
    mov edx, INBUF_SIZE
    call asm_read
    test rax, rax
    js err_rd
    jz .eof
    mov rcx, rax
    mov rsi, inbuf
.bl:
    test rcx, rcx
    jz .fr
    movzx eax, byte [rsi]
    inc rsi
    dec rcx
    cmp al, 10
    je .bl
    cmp al, 13
    je .bl
    cmp al, 9
    je .bl
    cmp al, 32
    je .bl
    movzx edx, byte [r10+rax]
    cmp dl, 0xFF
    je .garb
    cmp dl, 0xFE
    je .bl
    imul r9, 85
    movzx edx, dl
    add r9, rdx
    inc r8d
    cmp r8d, 5
    jl .bl
    mov eax, r9d
    shr eax, 24
    mov [r14], al
    mov eax, r9d
    shr eax, 16
    mov [r14+1], al
    mov eax, r9d
    shr eax, 8
    mov [r14+2], al
    mov [r14+3], r9b
    add r14, 4
    xor r8d, r8d
    xor r9, r9
    mov rax, r14
    sub rax, outbuf
    cmp rax, OUTBUF_SIZE-1024
    jl .bl
    push rcx
    push rsi
    mov rdx, r14
    sub rdx, outbuf
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    test eax, eax
    js werr2
    pop rsi
    pop rcx
    mov r14, outbuf
    jmp .bl
.garb:
    test r12d, 2
    jnz .bl
    jmp err_inv
.fr:
    mov rdx, r14
    sub rdx, outbuf
    test rdx, rdx
    jz .rd
    push r8
    push r9
    mov rsi, outbuf
    mov rdi, STDOUT
    call asm_write_all
    pop r9
    pop r8
    test eax, eax
    js werr
    mov r14, outbuf
    jmp .rd
.eof:
    test r8d, r8d
    jnz err_inv
    mov rsi, outbuf
    mov rdx, r14
    sub rdx, rsi
    test rdx, rdx
    jz done_ok
    mov rdi, STDOUT
    call asm_write_all
    jmp done_ok

; ═══════════════════════════════════════════════════════════════════════════
; SHARED
; ═══════════════════════════════════════════════════════════════════════════
wchk:
    test r13d, r13d
    jz .s
    inc r8d
    cmp r8d, r13d
    jl .s
    mov byte [rdi], 10
    inc rdi
    xor r8d, r8d
.s: ret

done_ok:
    test ebp, ebp
    jz .x
    push rbx
    mov edi, ebp
    call asm_close
    pop rbx
.x: xor edi, edi
    call asm_exit

werr:
    xor edi, edi
    call asm_exit
werr2:
    pop rsi
    pop rcx
    jmp werr

; ── Error handlers ──
err_miss_enc:
    mov rdi, STDERR
    mov rsi, e_miss
    mov rdx, e_miss_len
    call asm_write_all
    mov edi, 1
    call asm_exit
err_extra:
    push rsi
    mov rdi, STDERR
    mov rsi, e_extra
    mov rdx, e_extra_len
    call asm_write_all
    pop rsi
    push rsi
    mov rdi, rsi
    call slen
    pop rsi
    mov rdx, rax
    mov rdi, STDERR
    call asm_write_all
    mov rdi, STDERR
    mov rsi, err_suf
    mov rdx, err_suf_len
    call asm_write_all
    mov edi, 1
    call asm_exit
err_unrec:
    push rsi
    mov rdi, STDERR
    mov rsi, e_unrec
    mov rdx, e_unrec_len
    call asm_write_all
    pop rsi
    push rsi
    mov rdi, rsi
    call slen
    pop rsi
    mov rdx, rax
    mov rdi, STDERR
    call asm_write_all
    mov rdi, STDERR
    mov rsi, err_suf
    mov rdx, err_suf_len
    call asm_write_all
    mov edi, 1
    call asm_exit
err_inv_wrap:
    push rdi
    mov rdi, STDERR
    mov rsi, e_iwrap
    mov rdx, e_iwrap_len
    call asm_write_all
    pop rsi
    push rsi
    mov rdi, rsi
    call slen
    pop rsi
    mov rdx, rax
    mov rdi, STDERR
    call asm_write_all
    mov rdi, STDERR
    mov rsi, e_wsuf
    mov rdx, e_wsuf_len
    call asm_write_all
    mov edi, 1
    call asm_exit
err_w_arg:
    mov rdi, STDERR
    mov rsi, e_warg
    mov rdx, e_warg_len
    call asm_write_all
    mov edi, 1
    call asm_exit
err_wrap_long:
    mov rdi, STDERR
    mov rsi, e_wlong
    mov rdx, e_wlong_len
    call asm_write_all
    mov edi, 1
    call asm_exit
err_open:
    neg eax
    mov r12d, eax
    mov rdi, STDERR
    mov rsi, e_pfx
    mov rdx, e_pfx_len
    call asm_write_all
    mov rsi, [filename_ptr]
    mov rdi, rsi
    call slen
    mov rdx, rax
    mov rsi, [filename_ptr]
    mov rdi, STDERR
    call asm_write_all
    cmp r12d, 2
    je .noent
    cmp r12d, 13
    je .perm
    cmp r12d, 21
    je .isdir
    mov rdi, STDERR
    mov rsi, e_rderr
    mov rdx, e_rderr_len
    call asm_write_all
    mov edi, 1
    call asm_exit
.noent:
    mov rdi, STDERR
    mov rsi, e_noent
    mov rdx, e_noent_len
    call asm_write_all
    mov edi, 1
    call asm_exit
.perm:
    mov rdi, STDERR
    mov rsi, e_perm
    mov rdx, e_perm_len
    call asm_write_all
    mov edi, 1
    call asm_exit
.isdir:
    mov rdi, STDERR
    mov rsi, e_isdir
    mov rdx, e_isdir_len
    call asm_write_all
    mov edi, 1
    call asm_exit
err_inv:
    mov rsi, outbuf
    mov rdx, r14
    sub rdx, rsi
    test rdx, rdx
    jz err_inv_msg
    mov rdi, STDOUT
    call asm_write_all
err_inv_msg:
    mov rdi, STDERR
    mov rsi, e_inv
    mov rdx, e_inv_len
    call asm_write_all
    mov edi, 1
    call asm_exit
err_rd:
    mov rdi, STDERR
    mov rsi, e_pfx
    mov rdx, e_pfx_len
    call asm_write_all
    mov rsi, [filename_ptr]
    test rsi, rsi
    jz .g
    mov rdi, rsi
    call slen
    mov rdx, rax
    mov rsi, [filename_ptr]
    mov rdi, STDERR
    call asm_write_all
.g: mov rdi, STDERR
    mov rsi, e_rderr
    mov rdx, e_rderr_len
    call asm_write_all
    mov edi, 1
    call asm_exit

; ── String utilities ──
str_eq:
    push rdi
    push r11
.l: movzx eax, byte [rdi]
    movzx edx, byte [r11]
    cmp al, dl
    jne .n
    test al, al
    jz .y
    inc rdi
    inc r11
    jmp .l
.y: mov al, 1
    pop r11
    pop rdi
    ret
.n: xor al, al
    pop r11
    pop rdi
    ret

str_prefix:
    push rdi
    push r11
.l: movzx edx, byte [r11]
    test dl, dl
    jz .y
    movzx eax, byte [rdi]
    cmp al, dl
    jne .n
    inc rdi
    inc r11
    jmp .l
.y: mov al, 1
    pop r11
    pop rdi
    ret
.n: xor al, al
    pop r11
    pop rdi
    ret

slen:
    xor eax, eax
.l: cmp byte [rdi+rax], 0
    je .d
    inc eax
    jmp .l
.d: ret

parse_uint:
    push rdi
    xor eax, eax
    movzx ecx, byte [rdi]
    test cl, cl
    jz .e
.l: movzx ecx, byte [rdi]
    test cl, cl
    jz .d
    sub cl, '0'
    cmp cl, 9
    ja .e
    imul eax, 10
    jo .e
    movzx ecx, cl
    add eax, ecx
    jo .e
    inc rdi
    jmp .l
.d: pop rdi
    ret
.e: pop rdi
    mov eax, -1
    ret

asm_write_all:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
.l: test r13, r13
    jle .ok
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rax, SYS_WRITE
    syscall
    cmp rax, -4
    je .l
    test rax, rax
    js .er
    add r12, rax
    sub r13, rax
    jmp .l
.ok:xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret
.er:mov rax, -1
    pop r13
    pop r12
    pop rbx
    ret

asm_read:
.r: mov rax, SYS_READ
    syscall
    cmp rax, -4
    je .r
    ret

asm_open:
    mov rax, SYS_OPEN
    syscall
    ret

asm_close:
    mov rax, SYS_CLOSE
    syscall
    ret

asm_exit:
    mov rax, SYS_EXIT
    syscall

; ############################################################################
; DATA
; ############################################################################
str_help: db "help",0
str_version: db "version",0
str_decode: db "decode",0
str_ignore_garbage: db "ignore-garbage",0
str_wrap_eq: db "wrap=",0
str_wrap: db "wrap",0
str_base64: db "base64",0
str_base64url: db "base64url",0
str_base32: db "base32",0
str_base32hex: db "base32hex",0
str_base16: db "base16",0
str_base2msbf: db "base2msbf",0
str_base2lsbf: db "base2lsbf",0
str_z85: db "z85",0

nl_ch: db 10

b64_enc: db "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
b64u_enc: db "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

b64_dec:
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFE,0xFE,0xFE,0xFE,0xFE,0xFF,0xFF
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFE,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,62,0xFF,0xFF,0xFF,63
    db 52,53,54,55,56,57,58,59,60,61,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFF,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14
    db 15,16,17,18,19,20,21,22,23,24,25,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFF,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40
    db 41,42,43,44,45,46,47,48,49,50,51,0xFF,0xFF,0xFF,0xFF,0xFF
    times 128 db 0xFF

b64u_dec:
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFE,0xFE,0xFE,0xFE,0xFE,0xFF,0xFF
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFE,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,62,0xFF,0xFF
    db 52,53,54,55,56,57,58,59,60,61,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFF,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14
    db 15,16,17,18,19,20,21,22,23,24,25,0xFF,0xFF,0xFF,0xFF,63
    db 0xFF,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40
    db 41,42,43,44,45,46,47,48,49,50,51,0xFF,0xFF,0xFF,0xFF,0xFF
    times 128 db 0xFF

b32_enc: db "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
b32h_enc: db "0123456789ABCDEFGHIJKLMNOPQRSTUV"

b32_dec:
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFE,0xFE,0xFE,0xFE,0xFE,0xFF,0xFF
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFE,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFF,0xFF,26,27,28,29,30,31,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFF,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14
    db 15,16,17,18,19,20,21,22,23,24,25,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    times 128 db 0xFF

b32h_dec:
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFE,0xFE,0xFE,0xFE,0xFE,0xFF,0xFF
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFE,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0,1,2,3,4,5,6,7,8,9,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFF,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24
    db 25,26,27,28,29,30,31,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    times 128 db 0xFF

hex_ch: db "0123456789ABCDEF"

z85_enc: db "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#"

z85_dec:
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
    db 0xFE,68,0xFF,84,83,82,72,0xFF,75,76,70,65,0xFF,63,62,69
    db 0,1,2,3,4,5,6,7,8,9,64,0xFF,73,66,74,71
    db 81,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50
    db 51,52,53,54,55,56,57,58,59,60,61,77,0xFF,78,67,0xFF
    db 0xFF,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24
    db 25,26,27,28,29,30,31,32,33,34,35,79,0xFF,80,0xFF,0xFF
    times 128 db 0xFF

help_text:
    db "Usage: basenc [OPTION]... [FILE]",10
    db "basenc encode or decode FILE, or standard input, to standard output.",10,10
    db "With no FILE, or when FILE is -, read standard input.",10,10
    db "Mandatory arguments to long options are mandatory for short options too.",10
    db "      --base64          same as 'base64' program (RFC4648 section 4)",10
    db "      --base64url       file- and url-safe base64 (RFC4648 section 5)",10
    db "      --base32          same as 'base32' program (RFC4648 section 6)",10
    db "      --base32hex       extended hex alphabet base32 (RFC4648 section 7)",10
    db "      --base16          hex encoding (RFC4648 section 8)",10
    db "      --base2msbf       bit string with most significant bit (msb) first",10
    db "      --base2lsbf       bit string with least significant bit (lsb) first",10
    db "  -d, --decode          decode data",10
    db "  -i, --ignore-garbage  when decoding, ignore non-alphabet characters",10
    db "  -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).",10
    db "                          Use 0 to disable line wrapping",10
    db "      --z85             ascii85-like encoding (ZeroMQ spec:32/Z85);",10
    db "                        when encoding, input length must be a multiple of 4;",10
    db "                        when decoding, input length must be a multiple of 5",10
    db "      --help        display this help and exit",10
    db "      --version     output version information and exit",10,10
    db "When decoding, the input may contain newlines in addition to the bytes of",10
    db "the formal alphabet.  Use --ignore-garbage to attempt to recover",10
    db "from any other non-alphabet bytes in the encoded stream.",10,10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>",10
    db "Full documentation <https://www.gnu.org/software/coreutils/basenc>",10
    db "or available locally via: info '(coreutils) basenc invocation'",10
help_text_len equ $-help_text

version_text:
    db "basenc (GNU coreutils) 9.7",10
    db "Packaged by Debian (9.7-3)",10
    db "Copyright (C) 2025 Free Software Foundation, Inc.",10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.",10
    db "This is free software: you are free to change and redistribute it.",10
    db "There is NO WARRANTY, to the extent permitted by law.",10,10
    db "Written by Simon Josefsson and Assaf Gordon.",10
version_text_len equ $-version_text

e_pfx: db "basenc: "
e_pfx_len equ $-e_pfx
err_inv_opt: db "basenc: invalid option -- '"
err_inv_opt_len equ $-err_inv_opt
e_unrec: db "basenc: unrecognized option '"
e_unrec_len equ $-e_unrec
err_suf: db "'",10,"Try 'basenc --help' for more information.",10
err_suf_len equ $-err_suf
e_iwrap: db "basenc: invalid wrap size: '"
e_iwrap_len equ $-e_iwrap
e_wsuf: db "'",10
e_wsuf_len equ $-e_wsuf
e_warg:
    db "basenc: option requires an argument -- 'w'",10
    db "Try 'basenc --help' for more information.",10
e_warg_len equ $-e_warg
e_wlong:
    db "basenc: option '--wrap' requires an argument",10
    db "Try 'basenc --help' for more information.",10
e_wlong_len equ $-e_wlong
e_inv: db "basenc: invalid input",10
e_inv_len equ $-e_inv
e_miss:
    db "basenc: missing encoding type",10
    db "Try 'basenc --help' for more information.",10
e_miss_len equ $-e_miss
err_z85m4: db "basenc: invalid input (length must be multiple of 4 characters)",10
err_z85m4_len equ $-err_z85m4
e_noent: db ": No such file or directory",10
e_noent_len equ $-e_noent
e_perm: db ": Permission denied",10
e_perm_len equ $-e_perm
e_isdir: db ": Is a directory",10
e_isdir_len equ $-e_isdir
e_rderr: db ": read error",10
e_rderr_len equ $-e_rderr
e_extra: db "basenc: extra operand ",0xE2,0x80,0x98
e_extra_len equ $-e_extra

file_end:
