; ============================================================================
;  ftsort_unified.asm — Unified flat-binary build of ftsort
;  Self-contained: includes ELF headers, all code, and BSS definitions.
;  Build: nasm -f bin ftsort_unified.asm -o ftsort_release && chmod +x ftsort_release
; ============================================================================

BITS 64
org 0x400000

; ── Syscall numbers ──
%define SYS_READ         0
%define SYS_WRITE        1
%define SYS_OPEN         2
%define SYS_CLOSE        3
%define SYS_FSTAT        5
%define SYS_MMAP         9
%define SYS_MUNMAP      11
%define SYS_RT_SIGACTION 13
%define SYS_MREMAP      25
%define SYS_EXIT        60

%define STDIN            0
%define STDOUT           1
%define STDERR           2
%define O_RDONLY         0
%define EINTR            4
%define SIGPIPE         13

%define PROT_READ        1
%define PROT_WRITE       2
%define MAP_PRIVATE      2
%define MAP_ANONYMOUS   0x20
%define MREMAP_MAYMOVE   1

%define STAT_SIZE       48
%define STAT_STRUCT_SIZE 144

; ── Application constants ──
%define INITIAL_HASH_CAP    1024
%define INITIAL_NODE_CAP    256
%define INITIAL_ADJ_CAP     1024
%define OUT_BUF_SIZE        262144
%define READ_BUF_SIZE       131072
%define FLUSH_THRESHOLD     196608

; ── ELF Header ──
ehdr:
    db      0x7f, "ELF"
    db      2, 1, 1, 0
    dq      0
    dw      2
    dw      0x3E
    dd      1
    dq      _start
    dq      phdr - ehdr
    dq      0
    dd      0
    dw      ehdr_end - ehdr
    dw      phdr_size
    dw      3
    dw      0, 0, 0
ehdr_end:

; ── Program Headers ──
phdr:
    ; Code + Data (R+X)
    dd      1
    dd      5
    dq      0
    dq      0x400000
    dq      0x400000
    dq      file_end - ehdr
    dq      file_end - ehdr
    dq      0x1000
phdr_size equ $ - phdr

    ; BSS (R+W)
    dd      1
    dd      6
    dq      0
    dq      bss_start
    dq      bss_start
    dq      0
    dq      bss_size
    dq      0x1000

    ; GNU_STACK (NX)
    dd      0x6474E551
    dd      6
    dq      0, 0, 0, 0, 0
    dq      0x10

; ============================================================================
;                           ENTRY POINT
; ============================================================================
_start:
    ; Set SIGPIPE to SIG_DFL (terminate on broken pipe)
    mov     rax, SYS_RT_SIGACTION
    mov     rdi, SIGPIPE
    lea     rsi, [sigact_buf]
    xor     rdx, rdx
    mov     r10, 8
    syscall

    ; Parse argc/argv
    mov     r14, [rsp]              ; argc
    lea     r15, [rsp + 8]          ; argv[0]

    ; Default: no file, read stdin
    mov     qword [input_ptr], 0
    mov     qword [input_len], 0
    lea     rax, [str_dash]
    mov     [source_name], rax
    mov     byte [exit_code], 0

    ; Parse command line arguments
    cmp     r14, 1
    jle     .no_args

    ; Check argv[1]
    mov     rsi, [r15 + 8]

    ; Check for --help
    lea     rdi, [str_help_flag]
    call    str_equal
    test    eax, eax
    jnz     .do_help

    mov     rsi, [r15 + 8]

    ; Check for --version
    lea     rdi, [str_version_flag]
    call    str_equal
    test    eax, eax
    jnz     .do_version

    mov     rsi, [r15 + 8]

    ; Check for --
    lea     rdi, [str_dashdash]
    call    str_equal
    test    eax, eax
    jnz     .check_after_dashdash

    mov     rsi, [r15 + 8]

    ; Check for - (stdin)
    cmp     byte [rsi], '-'
    jne     .is_file_arg
    cmp     byte [rsi + 1], 0
    je      .check_extra_operand

    ; Starts with '-' — check if long or short option
    cmp     byte [rsi + 1], '-'
    je      .unknown_long_option
    jmp     .unknown_short_option

.unknown_long_option:
    lea     rdi, [str_tool_name]
    call    write_stderr_str
    lea     rdi, [str_unrec_opt]
    call    write_stderr_str
    mov     rdi, [r15 + 8]
    call    write_stderr_str
    lea     rdi, [str_squote_nl]
    call    write_stderr_str
    lea     rdi, [str_try_help]
    call    write_stderr_str
    mov     rdi, 1
    jmp     exit_now

.unknown_short_option:
    lea     rdi, [str_tool_name]
    call    write_stderr_str
    lea     rdi, [str_inv_opt]
    call    write_stderr_str
    mov     rax, [r15 + 8]
    movzx   eax, byte [rax + 1]
    mov     [small_buf], al
    mov     rdi, STDERR
    lea     rsi, [small_buf]
    mov     rdx, 1
    call    asm_write_all
    lea     rdi, [str_squote_nl]
    call    write_stderr_str
    lea     rdi, [str_try_help]
    call    write_stderr_str
    mov     rdi, 1
    jmp     exit_now

.check_after_dashdash:
    cmp     r14, 3
    jl      .no_args
    cmp     r14, 4
    jge     .extra_op_argv3
    mov     rsi, [r15 + 16]
    jmp     .is_file_arg

.extra_op_argv3:
    mov     rsi, [r15 + 24]
    jmp     .extra_operand_err

.check_extra_operand:
    cmp     r14, 3
    jge     .extra_op_argv2
    jmp     .no_args

.extra_op_argv2:
    mov     rsi, [r15 + 16]
    jmp     .extra_operand_err

.extra_operand_err:
    push    rsi
    lea     rdi, [str_tool_name]
    call    write_stderr_str
    lea     rdi, [str_extra_op]
    call    write_stderr_str
    pop     rdi
    call    write_stderr_str
    lea     rdi, [str_squote_nl]
    call    write_stderr_str
    lea     rdi, [str_try_help]
    call    write_stderr_str
    mov     rdi, 1
    jmp     exit_now

.is_file_arg:
    cmp     r14, 3
    jge     .extra_op_check2
    jmp     .open_file

.extra_op_check2:
    mov     rsi, [r15 + 16]
    jmp     .extra_operand_err

.open_file:
    mov     rsi, [r15 + 8]
    mov     [source_name], rsi

    mov     rdi, rsi
    xor     esi, esi
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .open_error
    mov     [file_fd], eax

    ; fstat to get size
    mov     edi, eax
    lea     rsi, [stat_buf]
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .read_file_fallback

    mov     rax, [stat_buf + STAT_SIZE]
    test    rax, rax
    jz      .empty_file
    mov     [input_len], rax

    ; mmap the file
    xor     edi, edi
    mov     rsi, rax
    mov     edx, PROT_READ
    mov     r10d, MAP_PRIVATE
    mov     r8d, [file_fd]
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .read_file_fallback
    mov     [input_ptr], rax
    mov     byte [input_mmapped], 1

    mov     edi, [file_fd]
    call    asm_close
    jmp     .have_input

.empty_file:
    mov     edi, [file_fd]
    call    asm_close
    xor     edi, edi
    jmp     exit_now

.read_file_fallback:
    call    read_fd_to_buf
    jmp     .have_input

.open_error:
    lea     rdi, [str_tool_name]
    call    write_stderr_str
    mov     rdi, [source_name]
    call    write_stderr_str
    lea     rdi, [str_colon_sp]
    call    write_stderr_str
    lea     rdi, [str_no_such_file]
    call    write_stderr_str
    mov     rdi, 1
    jmp     exit_now

.no_args:
    mov     dword [file_fd], STDIN
    call    read_fd_to_buf

.have_input:
    mov     rax, [input_len]
    test    rax, rax
    jz      .done_empty

    call    init_structures
    call    parse_and_build

    test    byte [token_parity], 1
    jnz     .odd_tokens

    call    kahn_sort
    call    flush_outbuf

    movzx   edi, byte [exit_code]
    jmp     exit_now

.odd_tokens:
    call    flush_outbuf
    lea     rdi, [str_tool_name]
    call    write_stderr_str
    mov     rdi, [source_name]
    call    write_stderr_str
    lea     rdi, [str_odd_tokens]
    call    write_stderr_str
    mov     rdi, 1
    jmp     exit_now

.done_empty:
    xor     edi, edi
    jmp     exit_now

.do_help:
    lea     rsi, [help_text]
    mov     rdx, help_text_len
    mov     rdi, STDOUT
    call    asm_write_all
    xor     edi, edi
    jmp     exit_now

.do_version:
    lea     rsi, [version_text]
    mov     rdx, version_text_len
    mov     rdi, STDOUT
    call    asm_write_all
    xor     edi, edi
    jmp     exit_now

; ── Exit ──
exit_now:
    mov     rax, SYS_EXIT
    syscall

; ============================================================================
;  I/O Library (inlined from lib/io.asm)
; ============================================================================

; asm_write_all(rdi=fd, rsi=buf, rdx=len) -> rax=0 on success, -1 on error
asm_write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.wa_loop:
    test    r13, r13
    jle     .wa_success
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -EINTR
    je      .wa_loop
    test    rax, rax
    js      .wa_error
    add     r12, rax
    sub     r13, rax
    jmp     .wa_loop
.wa_success:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.wa_error:
    mov     rax, -1
    pop     r13
    pop     r12
    pop     rbx
    ret

; asm_read(rdi=fd, rsi=buf, rdx=len) -> rax=bytes_read
asm_read:
.ar_retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, -EINTR
    je      .ar_retry
    ret

; asm_open(rdi=path, rsi=flags, rdx=mode) -> rax=fd
asm_open:
    mov     rax, SYS_OPEN
    syscall
    ret

; asm_close(rdi=fd) -> rax=0 or error
asm_close:
    mov     rax, SYS_CLOSE
    syscall
    ret

; ============================================================================
;  read_fd_to_buf — Read from file_fd into dynamically allocated buffer
; ============================================================================
read_fd_to_buf:
    push    rbx
    push    r12
    push    r13

    mov     r12, READ_BUF_SIZE
    xor     edi, edi
    mov     rsi, r12
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8d, -1
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .rfb_fail
    mov     rbx, rax
    xor     r13d, r13d

.rfb_loop:
    mov     edi, [file_fd]
    lea     rsi, [rbx + r13]
    mov     rdx, r12
    sub     rdx, r13
    cmp     rdx, READ_BUF_SIZE
    jbe     .rfb_read_ok
    mov     rdx, READ_BUF_SIZE
.rfb_read_ok:
    test    rdx, rdx
    jz      .rfb_grow
    call    asm_read
    test    rax, rax
    jle     .rfb_done
    add     r13, rax

    mov     rax, r12
    sub     rax, r13
    cmp     rax, 4096
    jge     .rfb_loop

.rfb_grow:
    mov     rdi, rbx
    mov     rsi, r12
    lea     rdx, [r12 * 2]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .rfb_fail
    mov     rbx, rax
    shl     r12, 1
    jmp     .rfb_loop

.rfb_done:
    mov     [input_ptr], rbx
    mov     [input_len], r13
    mov     byte [input_mmapped], 0

    cmp     dword [file_fd], STDIN
    je      .rfb_ret
    mov     edi, [file_fd]
    call    asm_close

.rfb_ret:
    pop     r13
    pop     r12
    pop     rbx
    ret

.rfb_fail:
    mov     rdi, 1
    jmp     exit_now

; ============================================================================
;  init_structures — Allocate hash table, node arrays, adjacency pool
; ============================================================================
init_structures:
    push    rbx

    mov     rsi, INITIAL_HASH_CAP * 8
    call    alloc_zeroed
    mov     [ht_keys], rax

    mov     rsi, INITIAL_HASH_CAP * 4
    call    alloc_zeroed
    mov     [ht_lens], rax

    mov     rsi, INITIAL_HASH_CAP * 4
    call    alloc_zeroed
    mov     [ht_ids], rax

    mov     dword [ht_cap], INITIAL_HASH_CAP
    mov     dword [ht_count], 0

    mov     rsi, INITIAL_NODE_CAP * 8
    call    alloc_zeroed
    mov     [node_ptrs], rax

    mov     rsi, INITIAL_NODE_CAP * 4
    call    alloc_zeroed
    mov     [node_lens], rax

    mov     rsi, INITIAL_NODE_CAP * 4
    call    alloc_zeroed
    mov     [in_deg], rax

    mov     rsi, INITIAL_NODE_CAP * 4
    call    alloc_zeroed
    mov     [adj_off], rax

    mov     rsi, INITIAL_NODE_CAP * 4
    call    alloc_zeroed
    mov     [adj_cnt], rax

    mov     rsi, INITIAL_NODE_CAP * 4
    call    alloc_zeroed
    mov     [adj_cap_arr], rax

    mov     dword [node_cap], INITIAL_NODE_CAP
    mov     dword [node_count], 0

    mov     rsi, INITIAL_ADJ_CAP * 4
    call    alloc_zeroed
    mov     [adj_pool], rax
    mov     dword [adj_pool_cap], INITIAL_ADJ_CAP
    mov     dword [adj_pool_used], 0

    mov     rsi, OUT_BUF_SIZE
    call    alloc_zeroed
    mov     [out_buf], rax
    mov     dword [out_buf_used], 0

    mov     byte [token_parity], 0

    pop     rbx
    ret

; ============================================================================
;  alloc_zeroed — Allocate rsi bytes of zeroed memory via mmap
; ============================================================================
alloc_zeroed:
    push    rsi
    xor     edi, edi
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8d, -1
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    pop     rsi
    cmp     rax, -4096
    ja      .alloc_fail
    ret
.alloc_fail:
    mov     rdi, 1
    jmp     exit_now

; ============================================================================
;  parse_and_build — Parse all tokens and build graph
; ============================================================================
parse_and_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, [input_ptr]
    mov     r13, [input_len]
    xor     r14d, r14d
    xor     ebp, ebp

.parse_loop:
.skip_ws:
    cmp     r14, r13
    jge     .parse_done
    movzx   eax, byte [r12 + r14]
    cmp     al, ' '
    je      .do_skip
    cmp     al, 10
    je      .do_skip
    cmp     al, 13
    je      .do_skip
    cmp     al, 9
    je      .do_skip
    jmp     .found_token_start
.do_skip:
    inc     r14
    jmp     .skip_ws

.found_token_start:
    mov     r15, r14

.scan_token:
    inc     r14
    cmp     r14, r13
    jge     .token_end
    movzx   eax, byte [r12 + r14]
    cmp     al, ' '
    je      .token_end
    cmp     al, 10
    je      .token_end
    cmp     al, 13
    je      .token_end
    cmp     al, 9
    je      .token_end
    jmp     .scan_token

.token_end:
    lea     rdi, [r12 + r15]
    mov     rsi, r14
    sub     rsi, r15

    call    intern_token

    test    byte [token_parity], 1
    jnz     .is_second_token

    mov     ebp, eax
    xor     byte [token_parity], 1
    jmp     .parse_loop

.is_second_token:
    xor     byte [token_parity], 1
    mov     edi, ebp
    mov     esi, eax
    cmp     edi, esi
    je      .parse_loop
    call    add_edge
    jmp     .parse_loop

.parse_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  intern_token — Look up or create a node for the given token
;  Input: rdi = token ptr, rsi = token len
;  Output: eax = node ID
; ============================================================================
intern_token:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi
    mov     r13, rsi

    ; Compute FNV-1a hash
    mov     rax, 0xcbf29ce484222325
    mov     r8, 0x100000001b3
    xor     ecx, ecx
.hash_loop:
    cmp     rcx, r13
    jge     .hash_done
    movzx   edx, byte [r12 + rcx]
    xor     al, dl
    mul     r8
    inc     rcx
    jmp     .hash_loop
.hash_done:
    mov     r14, rax

    mov     r15d, [ht_cap]
    dec     r15d
    mov     ebx, r14d
    and     ebx, r15d

.probe_loop:
    mov     rax, [ht_keys]
    mov     rdi, [rax + rbx * 8]
    test    rdi, rdi
    jz      .slot_empty

    mov     rax, [ht_lens]
    mov     ecx, [rax + rbx * 4]
    cmp     rcx, r13
    jne     .probe_next

    mov     rsi, r12
    xor     edx, edx
.cmp_loop:
    cmp     rdx, rcx
    jge     .found_existing
    movzx   eax, byte [rdi + rdx]
    cmp     al, [rsi + rdx]
    jne     .probe_next
    inc     rdx
    jmp     .cmp_loop

.found_existing:
    mov     rax, [ht_ids]
    mov     eax, [rax + rbx * 4]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.probe_next:
    inc     ebx
    and     ebx, r15d
    jmp     .probe_loop

.slot_empty:
    ; Check load factor BEFORE insert
    mov     eax, [ht_count]
    inc     eax
    shl     eax, 2
    mov     ecx, [ht_cap]
    lea     ecx, [ecx + ecx * 2]
    cmp     eax, ecx
    jle     .no_pre_rehash

    call    rehash

    mov     r15d, [ht_cap]
    dec     r15d
    mov     ebx, r14d
    and     ebx, r15d

.reprobe_loop:
    mov     rax, [ht_keys]
    mov     rdi, [rax + rbx * 8]
    test    rdi, rdi
    jz      .no_pre_rehash
    inc     ebx
    and     ebx, r15d
    jmp     .reprobe_loop

.no_pre_rehash:
    mov     r8d, [node_count]

    cmp     r8d, [node_cap]
    jl      .node_space_ok
    call    grow_nodes
.node_space_ok:

    mov     rax, [node_ptrs]
    mov     [rax + r8 * 8], r12

    mov     rax, [node_lens]
    mov     [rax + r8 * 4], r13d

    inc     dword [node_count]

    mov     rax, [ht_keys]
    mov     [rax + rbx * 8], r12

    mov     rax, [ht_lens]
    mov     [rax + rbx * 4], r13d

    mov     rax, [ht_ids]
    mov     [rax + rbx * 4], r8d

    inc     dword [ht_count]

    mov     eax, r8d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  grow_nodes — Double the capacity of all node arrays
; ============================================================================
grow_nodes:
    push    rbx
    push    r12
    push    r13

    mov     ebx, [node_cap]
    lea     r12d, [ebx * 2]
    mov     r13, rbx

    mov     rdi, [node_ptrs]
    lea     rsi, [r13 * 8]
    lea     rdx, [r12 * 8]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .grow_fail
    mov     [node_ptrs], rax

    mov     rdi, [node_lens]
    lea     rsi, [r13 * 4]
    lea     rdx, [r12 * 4]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .grow_fail
    mov     [node_lens], rax

    mov     rdi, [in_deg]
    lea     rsi, [r13 * 4]
    lea     rdx, [r12 * 4]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .grow_fail
    mov     [in_deg], rax

    mov     rdi, [adj_off]
    lea     rsi, [r13 * 4]
    lea     rdx, [r12 * 4]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .grow_fail
    mov     [adj_off], rax

    mov     rdi, [adj_cnt]
    lea     rsi, [r13 * 4]
    lea     rdx, [r12 * 4]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .grow_fail
    mov     [adj_cnt], rax

    mov     rdi, [adj_cap_arr]
    lea     rsi, [r13 * 4]
    lea     rdx, [r12 * 4]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .grow_fail
    mov     [adj_cap_arr], rax

    mov     [node_cap], r12d

    pop     r13
    pop     r12
    pop     rbx
    ret

.grow_fail:
    mov     rdi, 1
    jmp     exit_now

; ============================================================================
;  rehash — Double hash table capacity and reinsert all entries
; ============================================================================
rehash:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     ebx, [ht_cap]
    lea     r12d, [ebx * 2]

    mov     r13, [ht_keys]
    mov     r14, [ht_lens]
    mov     r15, [ht_ids]

    lea     rsi, [r12 * 8]
    call    alloc_zeroed
    mov     [ht_keys], rax

    lea     rsi, [r12 * 4]
    call    alloc_zeroed
    mov     [ht_lens], rax

    lea     rsi, [r12 * 4]
    call    alloc_zeroed
    mov     [ht_ids], rax

    mov     [ht_cap], r12d

    xor     ebp, ebp
.rehash_loop:
    cmp     ebp, ebx
    jge     .rehash_done

    mov     rdi, [r13 + rbp * 8]
    test    rdi, rdi
    jz      .rehash_next

    mov     ecx, [r14 + rbp * 4]
    mov     r8d, [r15 + rbp * 4]

    push    rbp
    push    r8
    push    rcx
    push    rdi

    mov     rax, 0xcbf29ce484222325
    mov     r9, 0x100000001b3
    xor     esi, esi
.rh_hash_loop:
    cmp     esi, ecx
    jge     .rh_hash_done
    movzx   edx, byte [rdi + rsi]
    xor     al, dl
    mul     r9
    inc     esi
    jmp     .rh_hash_loop
.rh_hash_done:

    mov     ecx, r12d
    dec     ecx
    mov     esi, eax
    and     esi, ecx

    mov     r9, [ht_keys]
.rh_probe:
    cmp     qword [r9 + rsi * 8], 0
    je      .rh_insert
    inc     esi
    and     esi, ecx
    jmp     .rh_probe

.rh_insert:
    pop     rdi
    pop     rcx
    pop     r8

    mov     rax, [ht_keys]
    mov     [rax + rsi * 8], rdi
    mov     rax, [ht_lens]
    mov     [rax + rsi * 4], ecx
    mov     rax, [ht_ids]
    mov     [rax + rsi * 4], r8d

    pop     rbp

.rehash_next:
    inc     ebp
    jmp     .rehash_loop

.rehash_done:
    mov     rdi, r13
    mov     rsi, rbx
    shl     rsi, 3
    mov     rax, SYS_MUNMAP
    syscall

    mov     rdi, r14
    mov     rsi, rbx
    shl     rsi, 2
    mov     rax, SYS_MUNMAP
    syscall

    mov     rdi, r15
    mov     rsi, rbx
    shl     rsi, 2
    mov     rax, SYS_MUNMAP
    syscall

    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  add_edge — Add directed edge from -> to (with dedup)
;  Input: edi = from_id, esi = to_id
; ============================================================================
add_edge:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     ebx, edi
    mov     r12d, esi

    mov     rax, [adj_cnt]
    mov     ecx, [rax + rbx * 4]
    test    ecx, ecx
    jz      .ae_no_existing

    mov     rax, [adj_off]
    mov     r13d, [rax + rbx * 4]
    mov     rdi, [adj_pool]
    xor     edx, edx
.ae_dedup:
    cmp     edx, ecx
    jge     .ae_no_dup
    mov     eax, r13d
    add     eax, edx
    cmp     dword [rdi + rax * 4], r12d
    je      .ae_found_dup
    inc     edx
    jmp     .ae_dedup

.ae_found_dup:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.ae_no_existing:
.ae_no_dup:
    mov     rax, [adj_cap_arr]
    mov     r14d, [rax + rbx * 4]
    mov     rax, [adj_cnt]
    mov     r15d, [rax + rbx * 4]

    cmp     r15d, r14d
    jl      .ae_have_space

    test    r14d, r14d
    jz      .ae_new_list

    lea     ecx, [r14d * 2]
    jmp     .ae_realloc

.ae_new_list:
    mov     ecx, 4

.ae_realloc:
    mov     eax, [adj_pool_used]
    lea     edx, [eax + ecx]

    cmp     edx, [adj_pool_cap]
    jle     .ae_pool_ok

    push    rax
    push    rcx
    push    rdx

    mov     eax, [adj_pool_cap]
    mov     edi, eax
    shl     edi, 1
    cmp     edi, edx
    jge     .ae_pool_size_ok
    lea     edi, [edx * 2]
.ae_pool_size_ok:
    push    rdi

    mov     rdi, [adj_pool]
    lea     rsi, [rax * 4]
    pop     rax
    push    rax
    lea     rdx, [rax * 4]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .ae_fail
    mov     [adj_pool], rax

    pop     rax
    mov     [adj_pool_cap], eax
    pop     rdx
    pop     rcx
    pop     rax
    jmp     .ae_pool_ok

.ae_pool_ok:
    test    r15d, r15d
    jz      .ae_no_copy

    mov     rdi, [adj_pool]
    mov     r8, [adj_off]
    mov     r8d, [r8 + rbx * 4]
    xor     edx, edx
.ae_copy:
    cmp     edx, r15d
    jge     .ae_copy_done
    mov     r9d, r8d
    add     r9d, edx
    mov     r9d, [rdi + r9 * 4]
    mov     r10d, eax
    add     r10d, edx
    mov     [rdi + r10 * 4], r9d
    inc     edx
    jmp     .ae_copy
.ae_copy_done:

.ae_no_copy:
    mov     rdi, [adj_off]
    mov     [rdi + rbx * 4], eax

    mov     rdi, [adj_cap_arr]
    mov     [rdi + rbx * 4], ecx

    add     eax, ecx
    mov     [adj_pool_used], eax

.ae_have_space:
    mov     rax, [adj_off]
    mov     ecx, [rax + rbx * 4]
    add     ecx, r15d

    mov     rdi, [adj_pool]
    mov     [rdi + rcx * 4], r12d

    mov     rax, [adj_cnt]
    inc     dword [rax + rbx * 4]

    mov     rax, [in_deg]
    inc     dword [rax + r12 * 4]

    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.ae_fail:
    mov     rdi, 1
    jmp     exit_now

; ============================================================================
;  kahn_sort — Topological sort using Kahn's algorithm
; ============================================================================
kahn_sort:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12d, [node_count]
    test    r12d, r12d
    jz      .kahn_ret

    lea     rsi, [r12 * 4 + 16]
    call    alloc_zeroed
    mov     [queue_buf], rax

    lea     rsi, [r12 + 16]
    call    alloc_zeroed
    mov     [removed_buf], rax

    xor     ebx, ebx
    xor     r13d, r13d
    xor     r14d, r14d

    mov     rax, [in_deg]
    xor     ecx, ecx
.kahn_seed:
    cmp     ecx, r12d
    jge     .kahn_seed_sort
    cmp     dword [rax + rcx * 4], 0
    jne     .kahn_seed_next
    mov     rdi, [queue_buf]
    mov     [rdi + r13 * 4], ecx
    inc     r13d
.kahn_seed_next:
    inc     ecx
    jmp     .kahn_seed

.kahn_seed_sort:
    cmp     r13d, 2
    jl      .kahn_seed_done

    mov     ebp, 1
.ks_outer:
    cmp     ebp, r13d
    jge     .kahn_seed_done

    mov     rdi, [queue_buf]
    mov     r8d, [rdi + rbp * 4]
    mov     r15d, ebp
    dec     r15d

.ks_inner:
    cmp     r15d, 0
    jl      .ks_insert

    mov     rdi, [queue_buf]
    mov     r9d, [rdi + r15 * 4]

    push    r8
    push    r15

    mov     edi, r9d
    mov     esi, r8d
    call    compare_node_names

    pop     r15
    pop     r8

    test    eax, eax
    jle     .ks_insert

    mov     rdi, [queue_buf]
    mov     r9d, [rdi + r15 * 4]
    lea     eax, [r15d + 1]
    mov     [rdi + rax * 4], r9d
    dec     r15d
    jmp     .ks_inner

.ks_insert:
    lea     eax, [r15d + 1]
    mov     rdi, [queue_buf]
    mov     [rdi + rax * 4], r8d
    inc     ebp
    jmp     .ks_outer

.kahn_seed_done:

.kahn_main_loop:
.kahn_process:
    cmp     ebx, r13d
    jge     .kahn_queue_empty

    mov     rdi, [queue_buf]
    mov     ebp, [rdi + rbx * 4]
    inc     ebx

    mov     rdi, [removed_buf]
    mov     byte [rdi + rbp], 1
    inc     r14d

    mov     rax, [node_ptrs]
    mov     rsi, [rax + rbp * 8]
    mov     rax, [node_lens]
    mov     edx, [rax + rbp * 4]
    call    outbuf_write

    mov     byte [small_buf], 10
    lea     rsi, [small_buf]
    mov     edx, 1
    call    outbuf_write

    mov     rax, [adj_cnt]
    mov     ecx, [rax + rbp * 4]
    test    ecx, ecx
    jz      .kahn_process

    mov     rax, [adj_off]
    mov     r8d, [rax + rbp * 4]
    mov     r9, [adj_pool]
    mov     r10, [removed_buf]
    mov     r11, [in_deg]

    mov     r15d, r13d

    xor     edx, edx
.kahn_edge_loop:
    cmp     edx, ecx
    jge     .kahn_edges_done

    mov     eax, r8d
    add     eax, edx
    mov     eax, [r9 + rax * 4]

    cmp     byte [r10 + rax], 0
    jne     .kahn_edge_next

    dec     dword [r11 + rax * 4]
    jnz     .kahn_edge_next

    mov     rdi, [queue_buf]
    mov     [rdi + r13 * 4], eax
    inc     r13d

.kahn_edge_next:
    inc     edx
    jmp     .kahn_edge_loop

.kahn_edges_done:
    mov     eax, r15d
    mov     edx, r13d
    dec     edx
    mov     rdi, [queue_buf]
.kne_rev:
    cmp     eax, edx
    jge     .kahn_edges_sorted
    mov     ecx, [rdi + rax * 4]
    mov     r8d, [rdi + rdx * 4]
    mov     [rdi + rax * 4], r8d
    mov     [rdi + rdx * 4], ecx
    inc     eax
    dec     edx
    jmp     .kne_rev

.kahn_edges_sorted:
    jmp     .kahn_process

.kahn_queue_empty:
    cmp     r14d, r12d
    jge     .kahn_ret

    mov     byte [exit_code], 1

    call    flush_outbuf

    mov     rdi, [removed_buf]
    xor     ecx, ecx
.kahn_find_start:
    cmp     ecx, r12d
    jge     .kahn_ret
    cmp     byte [rdi + rcx], 0
    je      .kahn_found_start
    inc     ecx
    jmp     .kahn_find_start

.kahn_found_start:
    push    rcx
    mov     edi, ecx
    call    find_and_report_cycle
    pop     rcx

    mov     rax, [in_deg]
    mov     dword [rax + rcx * 4], 0
    mov     rdi, [queue_buf]
    mov     [rdi + r13 * 4], ecx
    inc     r13d

    jmp     .kahn_main_loop

.kahn_ret:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  find_and_report_cycle — DFS to find and report cycle
;  Input: edi = start node ID
; ============================================================================
find_and_report_cycle:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     ebx, edi
    mov     r12d, [node_count]

    lea     rsi, [r12 * 4 + 16]
    call    alloc_zeroed
    mov     r13, rax

    mov     rdi, rax
    mov     ecx, r12d
.fc_init:
    test    ecx, ecx
    jz      .fc_init_done
    mov     dword [rdi], 0xFFFFFFFF
    add     rdi, 4
    dec     ecx
    jmp     .fc_init

.fc_init_done:
    lea     rsi, [r12 * 4 + 16]
    call    alloc_zeroed
    mov     r14, rax

    xor     r15d, r15d
    mov     ebp, ebx

.fc_walk:
    mov     eax, [r13 + rbp * 4]
    cmp     eax, 0xFFFFFFFF
    jne     .fc_found_cycle

    mov     [r13 + rbp * 4], r15d
    mov     [r14 + r15 * 4], ebp
    inc     r15d

    mov     rax, [adj_cnt]
    mov     ecx, [rax + rbp * 4]
    test    ecx, ecx
    jz      .fc_no_next

    mov     rax, [adj_off]
    mov     r8d, [rax + rbp * 4]
    mov     r9, [adj_pool]
    mov     r10, [removed_buf]
    xor     edx, edx
.fc_next:
    cmp     edx, ecx
    jge     .fc_no_next
    mov     eax, r8d
    add     eax, edx
    mov     eax, [r9 + rax * 4]
    cmp     byte [r10 + rax], 0
    je      .fc_got_next
    inc     edx
    jmp     .fc_next

.fc_got_next:
    mov     ebp, eax
    jmp     .fc_walk

.fc_no_next:
    jmp     .fc_report_single

.fc_found_cycle:
    mov     ebp, eax

    lea     rdi, [str_tool_name]
    call    write_stderr_str
    mov     rdi, [source_name]
    call    write_stderr_str
    lea     rdi, [str_loop_msg]
    call    write_stderr_str

.fc_print:
    cmp     ebp, r15d
    jge     .fc_cleanup

    lea     rdi, [str_tool_prefix]
    call    write_stderr_str

    mov     eax, [r14 + rbp * 4]
    call    write_stderr_node

    inc     ebp
    jmp     .fc_print

.fc_report_single:
    lea     rdi, [str_tool_name]
    call    write_stderr_str
    mov     rdi, [source_name]
    call    write_stderr_str
    lea     rdi, [str_loop_msg]
    call    write_stderr_str

    lea     rdi, [str_tool_prefix]
    call    write_stderr_str
    mov     eax, ebx
    call    write_stderr_node

.fc_cleanup:
    mov     rdi, r13
    lea     rsi, [r12 * 4 + 16]
    mov     rax, SYS_MUNMAP
    syscall

    mov     rdi, r14
    lea     rsi, [r12 * 4 + 16]
    mov     rax, SYS_MUNMAP
    syscall

    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  write_stderr_node — Write node name + newline to stderr
;  Input: eax = node ID
; ============================================================================
write_stderr_node:
    push    rbx
    mov     ebx, eax

    mov     rax, [node_ptrs]
    mov     rsi, [rax + rbx * 8]
    mov     rax, [node_lens]
    mov     edx, [rax + rbx * 4]

    mov     rdi, STDERR
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [newline_char]
    mov     edx, 1
    call    asm_write_all

    pop     rbx
    ret

; ============================================================================
;  write_stderr_str — Write null-terminated string to stderr
;  Input: rdi = string ptr
; ============================================================================
write_stderr_str:
    push    rbx
    mov     rbx, rdi

    xor     ecx, ecx
.wss_len:
    cmp     byte [rbx + rcx], 0
    je      .wss_write
    inc     ecx
    jmp     .wss_len
.wss_write:
    test    ecx, ecx
    jz      .wss_done
    mov     rdi, STDERR
    mov     rsi, rbx
    mov     edx, ecx
    call    asm_write_all
.wss_done:
    pop     rbx
    ret

; ============================================================================
;  outbuf_write — Append bytes to output buffer, flush if needed
;  Input: rsi = ptr, edx = len
; ============================================================================
outbuf_write:
    push    rbx
    push    r12

    mov     rbx, rsi
    mov     r12d, edx

    mov     eax, [out_buf_used]
    lea     ecx, [eax + r12d]
    cmp     ecx, OUT_BUF_SIZE
    jl      .ow_copy
    call    flush_outbuf

.ow_copy:
    mov     rdi, [out_buf]
    mov     eax, [out_buf_used]
    add     rdi, rax

    mov     rsi, rbx
    mov     ecx, r12d
    rep     movsb

    add     [out_buf_used], r12d

    mov     eax, [out_buf_used]
    cmp     eax, FLUSH_THRESHOLD
    jl      .ow_done
    call    flush_outbuf
.ow_done:
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  flush_outbuf — Write output buffer to stdout
; ============================================================================
flush_outbuf:
    mov     edx, [out_buf_used]
    test    edx, edx
    jz      .fl_done
    mov     rdi, STDOUT
    mov     rsi, [out_buf]
    call    asm_write_all
    test    rax, rax
    js      .fl_epipe
    mov     dword [out_buf_used], 0
.fl_done:
    ret
.fl_epipe:
    movzx   edi, byte [exit_code]
    jmp     exit_now

; ============================================================================
;  str_equal — Compare null-terminated strings rdi and rsi
;  Returns eax=1 if equal, 0 if not
; ============================================================================
str_equal:
    xor     ecx, ecx
.se_loop:
    movzx   eax, byte [rdi + rcx]
    movzx   edx, byte [rsi + rcx]
    cmp     al, dl
    jne     .se_ne
    test    al, al
    jz      .se_eq
    inc     ecx
    jmp     .se_loop
.se_eq:
    mov     eax, 1
    ret
.se_ne:
    xor     eax, eax
    ret

; ============================================================================
;  compare_node_names — Lexicographic compare of two node names
;  Input: edi = node_id_a, esi = node_id_b
;  Output: eax < 0 if a < b, 0 if equal, > 0 if a > b
; ============================================================================
compare_node_names:
    push    rbx
    push    r12

    mov     rax, [node_ptrs]
    mov     rbx, [rax + rdi * 8]
    mov     r12, [rax + rsi * 8]

    mov     rax, [node_lens]
    mov     ecx, [rax + rdi * 4]
    mov     edx, [rax + rsi * 4]

    cmp     ecx, edx
    jle     .cn_use_a
    mov     eax, edx
    jmp     .cn_cmp
.cn_use_a:
    mov     eax, ecx
.cn_cmp:
    xor     esi, esi
.cn_loop:
    cmp     esi, eax
    jge     .cn_len_compare
    movzx   r8d, byte [rbx + rsi]
    movzx   r9d, byte [r12 + rsi]
    cmp     r8d, r9d
    jl      .cn_less
    jg      .cn_greater
    inc     esi
    jmp     .cn_loop

.cn_len_compare:
    sub     ecx, edx
    mov     eax, ecx
    pop     r12
    pop     rbx
    ret

.cn_less:
    mov     eax, -1
    pop     r12
    pop     rbx
    ret

.cn_greater:
    mov     eax, 1
    pop     r12
    pop     rbx
    ret

; ============================================================================
;                           DATA
; ============================================================================

str_help_flag:      db '--help', 0
str_version_flag:   db '--version', 0
str_dashdash:       db '--', 0
str_dash:           db '-', 0
str_tool_name:      db 'tsort: ', 0
str_tool_prefix:    db 'tsort: ', 0
str_colon_sp:       db ': ', 0
str_squote_nl:      db 0x27, 10, 0
str_unrec_opt:      db 'unrecognized option ', 0x27, 0
str_inv_opt:        db 'invalid option -- ', 0x27, 0
str_extra_op:       db 'extra operand ', 0x27, 0
str_try_help:       db "Try 'tsort --help' for more information.", 10, 0
str_no_such_file:   db 'No such file or directory', 10, 0
str_loop_msg:       db ': input contains a loop:', 10, 0
str_odd_tokens:     db ': input contains an odd number of tokens', 10, 0
newline_char:       db 10

help_text:
    db 'Usage: tsort [OPTION] [FILE]', 10
    db 'Write totally ordered list consistent with the partial ordering in FILE.', 10
    db 10
    db 'With no FILE, or when FILE is -, read standard input.', 10
    db 10
    db '      --help        display this help and exit', 10
    db '      --version     output version information and exit', 10
help_text_end:
help_text_len equ help_text_end - help_text

version_text:
    db 'tsort (fcoreutils) 0.1.0', 10
version_text_end:
version_text_len equ version_text_end - version_text

file_end:

; ============================================================================
;                           BSS — computed addresses
; ============================================================================
bss_start     equ (file_end - ehdr + 0x400000 + 0xFFF) & ~0xFFF

; SIGPIPE
sigact_buf    equ bss_start + 0           ; 32 bytes

; Input
input_ptr     equ bss_start + 32          ; 8 bytes
input_len     equ bss_start + 40          ; 8 bytes
input_mmapped equ bss_start + 48          ; 1 byte
source_name   equ bss_start + 56          ; 8 bytes (aligned)
file_fd       equ bss_start + 64          ; 4 bytes

; stat buffer
stat_buf      equ bss_start + 72          ; 144 bytes (aligned to 8)

; Hash table
ht_keys       equ bss_start + 216         ; 8 bytes
ht_lens       equ bss_start + 224         ; 8 bytes
ht_ids        equ bss_start + 232         ; 8 bytes
ht_cap        equ bss_start + 240         ; 4 bytes
ht_count      equ bss_start + 244         ; 4 bytes

; Node arrays
node_ptrs     equ bss_start + 248         ; 8 bytes
node_lens     equ bss_start + 256         ; 8 bytes
in_deg        equ bss_start + 264         ; 8 bytes
adj_off       equ bss_start + 272         ; 8 bytes
adj_cnt       equ bss_start + 280         ; 8 bytes
adj_cap_arr   equ bss_start + 288         ; 8 bytes
node_cap      equ bss_start + 296         ; 4 bytes
node_count    equ bss_start + 300         ; 4 bytes

; Adjacency pool
adj_pool      equ bss_start + 304         ; 8 bytes
adj_pool_cap  equ bss_start + 312         ; 4 bytes
adj_pool_used equ bss_start + 316         ; 4 bytes

; Queue
queue_buf     equ bss_start + 320         ; 8 bytes

; Removed bitmap
removed_buf   equ bss_start + 328         ; 8 bytes

; Output buffer
out_buf       equ bss_start + 336         ; 8 bytes
out_buf_used  equ bss_start + 344         ; 4 bytes

; State
token_parity  equ bss_start + 348         ; 1 byte
exit_code     equ bss_start + 349         ; 1 byte

; Scratch
small_buf     equ bss_start + 352         ; 16 bytes

bss_size      equ (352 + 16)             ; Total BSS size
