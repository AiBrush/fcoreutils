; ============================================================================
;  ftsort.asm — GNU-compatible "tsort" in x86_64 Linux assembly
;
;  Topological sort. Reads pairs of strings from stdin or file,
;  builds a directed graph, outputs a valid topological ordering.
;  Detects and reports cycles to stderr (still outputs partial ordering).
;
;  Features:
;    - FNV-1a hash for string interning
;    - Open-addressing hash table (linear probing)
;    - Dynamic memory via mmap/mremap
;    - Kahn's algorithm for topological sort
;    - DFS-based cycle detection
;    - mmap for file input (zero-copy)
;    - SIGPIPE handling (SIG_DFL)
;    - NX stack
;    --help / --version
;
;  Build (modular):
;    nasm -f elf64 -I ./ tools/ftsort.asm -o build/ftsort.o
;    nasm -f elf64 -I ./ lib/io.asm -o build/io.o
;    ld --gc-sections build/ftsort.o build/io.o -o ftsort
; ============================================================================

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close

; ═══════════════════════════════════════════════════════════════════
; Constants
; ═══════════════════════════════════════════════════════════════════

%define INITIAL_HASH_CAP    1024        ; Initial hash table capacity (power of 2)
%define INITIAL_NODE_CAP    256         ; Initial node array capacity
%define INITIAL_ADJ_CAP     1024        ; Initial adjacency pool capacity
%define OUT_BUF_SIZE        262144      ; 256KB output buffer
%define READ_BUF_SIZE       131072      ; 128KB read buffer for stdin
%define FLUSH_THRESHOLD     196608      ; Flush at 192KB

; FNV-1a constants (64-bit)
%define FNV_OFFSET_HI       0xcbf29ce4
%define FNV_OFFSET_LO       0x84222325
%define FNV_PRIME_HI        0x00000100
%define FNV_PRIME_LO        0x000001b3

global _start

section .text

; ─── Entry Point ─────────────────────────────────────────
_start:
    ; Set SIGPIPE to SIG_DFL (terminate on broken pipe)
    mov     rax, SYS_RT_SIGACTION
    mov     rdi, SIGPIPE
    lea     rsi, [rel sigact_buf]
    xor     rdx, rdx
    mov     r10, 8
    syscall

    ; Parse argc/argv
    mov     r14, [rsp]              ; argc
    lea     r15, [rsp + 8]          ; argv[0]

    ; Default: no file, read stdin
    mov     qword [rel input_ptr], 0
    mov     qword [rel input_len], 0
    lea     rax, [rel str_dash]
    mov     [rel source_name], rax
    mov     byte [rel exit_code], 0

    ; Parse command line arguments
    cmp     r14, 1
    jle     .no_args

    ; Check argv[1]
    mov     rsi, [r15 + 8]         ; argv[1]

    ; Check for --help
    lea     rdi, [rel str_help_flag]
    call    str_equal
    test    eax, eax
    jnz     .do_help

    ; Restore rsi (str_equal may clobber it)
    mov     rsi, [r15 + 8]

    ; Check for --version
    lea     rdi, [rel str_version_flag]
    call    str_equal
    test    eax, eax
    jnz     .do_version

    mov     rsi, [r15 + 8]

    ; Check for --
    lea     rdi, [rel str_dashdash]
    call    str_equal
    test    eax, eax
    jnz     .check_after_dashdash

    mov     rsi, [r15 + 8]

    ; Check for - (stdin)
    cmp     byte [rsi], '-'
    jne     .is_file_arg
    cmp     byte [rsi + 1], 0
    je      .check_extra_operand    ; just "-" = stdin

    ; Starts with '-' — check if long or short option
    cmp     byte [rsi + 1], '-'
    je      .unknown_long_option
    jmp     .unknown_short_option

.unknown_long_option:
    ; "tsort: unrecognized option 'ARG'"
    lea     rdi, [rel str_tool_name]
    call    write_stderr_str
    lea     rdi, [rel str_unrec_opt]
    call    write_stderr_str
    mov     rdi, [r15 + 8]
    call    write_stderr_str
    lea     rdi, [rel str_squote_nl]
    call    write_stderr_str
    lea     rdi, [rel str_try_help]
    call    write_stderr_str
    mov     rdi, 1
    jmp     exit_now

.unknown_short_option:
    ; "tsort: invalid option -- 'x'"
    lea     rdi, [rel str_tool_name]
    call    write_stderr_str
    lea     rdi, [rel str_inv_opt]
    call    write_stderr_str
    ; Write the option char
    mov     rax, [r15 + 8]
    movzx   eax, byte [rax + 1]
    mov     [rel small_buf], al
    mov     rdi, STDERR
    lea     rsi, [rel small_buf]
    mov     rdx, 1
    call    asm_write_all
    lea     rdi, [rel str_squote_nl]
    call    write_stderr_str
    lea     rdi, [rel str_try_help]
    call    write_stderr_str
    mov     rdi, 1
    jmp     exit_now

.check_after_dashdash:
    ; After --, check if there's a file argument
    cmp     r14, 3
    jl      .no_args               ; no file after --
    cmp     r14, 4
    jge     .extra_op_argv3        ; too many args
    ; Have file after --
    mov     rsi, [r15 + 16]        ; argv[2]
    jmp     .is_file_arg

.extra_op_argv3:
    mov     rsi, [r15 + 24]        ; argv[3]
    jmp     .extra_operand_err

.check_extra_operand:
    ; "-" means stdin; check for extra operand
    cmp     r14, 3
    jge     .extra_op_argv2
    jmp     .no_args

.extra_op_argv2:
    mov     rsi, [r15 + 16]
    jmp     .extra_operand_err

.extra_operand_err:
    ; "tsort: extra operand 'FILE'"
    push    rsi
    lea     rdi, [rel str_tool_name]
    call    write_stderr_str
    lea     rdi, [rel str_extra_op]
    call    write_stderr_str
    pop     rdi
    call    write_stderr_str
    lea     rdi, [rel str_squote_nl]
    call    write_stderr_str
    lea     rdi, [rel str_try_help]
    call    write_stderr_str
    mov     rdi, 1
    jmp     exit_now

.is_file_arg:
    ; Check for extra operand
    cmp     r14, 3
    jge     .extra_op_check2
    jmp     .open_file

.extra_op_check2:
    ; argv[1] is file, check if argv[2] exists (extra operand)
    ; But if we came from --, argv[2] IS the file and argv[3] is extra
    ; Let's handle this simpler: if not from --, argv[1]=file, argv[2]=extra
    mov     rsi, [r15 + 16]
    jmp     .extra_operand_err

.open_file:
    mov     rsi, [r15 + 8]        ; argv[1] = filename
    mov     [rel source_name], rsi

    ; Open the file
    mov     rdi, rsi
    xor     esi, esi               ; O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .open_error
    mov     [rel file_fd], eax

    ; fstat to get size
    mov     edi, eax
    lea     rsi, [rel stat_buf]
    FSTAT   rdi, rsi
    test    rax, rax
    js      .read_file_fallback

    mov     rax, [rel stat_buf + STAT_SIZE]
    test    rax, rax
    jz      .empty_file
    mov     [rel input_len], rax

    ; mmap the file
    xor     edi, edi               ; addr = NULL
    mov     rsi, rax               ; length
    mov     edx, PROT_READ         ; prot
    mov     r10d, MAP_PRIVATE      ; flags
    mov     r8d, [rel file_fd]     ; fd
    xor     r9d, r9d               ; offset = 0
    mov     rax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .read_file_fallback
    mov     [rel input_ptr], rax
    mov     byte [rel input_mmapped], 1

    ; Close file
    mov     edi, [rel file_fd]
    call    asm_close
    jmp     .have_input

.empty_file:
    mov     edi, [rel file_fd]
    call    asm_close
    xor     edi, edi
    jmp     exit_now

.read_file_fallback:
    call    read_fd_to_buf
    jmp     .have_input

.open_error:
    ; "tsort: FILE: No such file or directory"
    lea     rdi, [rel str_tool_name]
    call    write_stderr_str
    mov     rdi, [rel source_name]
    call    write_stderr_str
    lea     rdi, [rel str_colon_sp]
    call    write_stderr_str
    lea     rdi, [rel str_no_such_file]
    call    write_stderr_str
    mov     rdi, 1
    jmp     exit_now

.no_args:
    ; Read from stdin
    mov     dword [rel file_fd], STDIN
    call    read_fd_to_buf

.have_input:
    ; Now input_ptr and input_len are set
    mov     rax, [rel input_len]
    test    rax, rax
    jz      .done_empty

    ; Initialize data structures
    call    init_structures

    ; Parse input and build graph
    call    parse_and_build

    ; Check for odd token count
    test    byte [rel token_parity], 1
    jnz     .odd_tokens

    ; Run Kahn's algorithm
    call    kahn_sort

    ; Flush output buffer
    call    flush_outbuf

    ; Exit
    movzx   edi, byte [rel exit_code]
    jmp     exit_now

.odd_tokens:
    ; Flush any pending output first
    call    flush_outbuf
    ; "tsort: SOURCE: input contains an odd number of tokens"
    lea     rdi, [rel str_tool_name]
    call    write_stderr_str
    mov     rdi, [rel source_name]
    call    write_stderr_str
    lea     rdi, [rel str_odd_tokens]
    call    write_stderr_str
    mov     rdi, 1
    jmp     exit_now

.done_empty:
    xor     edi, edi
    jmp     exit_now

.do_help:
    lea     rsi, [rel help_text]
    mov     rdx, help_text_len
    mov     rdi, STDOUT
    call    asm_write_all
    xor     edi, edi
    jmp     exit_now

.do_version:
    lea     rsi, [rel version_text]
    mov     rdx, version_text_len
    mov     rdi, STDOUT
    call    asm_write_all
    xor     edi, edi
    jmp     exit_now

; ─── Exit ───────────────────────────────────────────────
exit_now:
    mov     rax, SYS_EXIT
    syscall

; ═══════════════════════════════════════════════════════════════════
; read_fd_to_buf — Read from file_fd into dynamically allocated buffer
; Sets input_ptr and input_len
; ═══════════════════════════════════════════════════════════════════
read_fd_to_buf:
    push    rbx
    push    r12
    push    r13

    ; Allocate initial buffer via mmap
    mov     r12, READ_BUF_SIZE     ; current capacity
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
    mov     rbx, rax               ; buffer ptr
    xor     r13d, r13d             ; total bytes read

.rfb_loop:
    ; Read chunk
    mov     edi, [rel file_fd]
    lea     rsi, [rbx + r13]
    mov     rdx, r12
    sub     rdx, r13
    cmp     rdx, READ_BUF_SIZE
    jbe     .rfb_read_ok
    mov     rdx, READ_BUF_SIZE
.rfb_read_ok:
    test    rdx, rdx
    jz      .rfb_grow              ; no space left, grow first
    call    asm_read
    test    rax, rax
    jle     .rfb_done              ; EOF or error
    add     r13, rax

    ; Check if buffer needs growing
    mov     rax, r12
    sub     rax, r13
    cmp     rax, 4096
    jge     .rfb_loop

.rfb_grow:
    ; Grow buffer via mremap
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
    mov     [rel input_ptr], rbx
    mov     [rel input_len], r13
    mov     byte [rel input_mmapped], 0

    ; Close fd if not stdin
    cmp     dword [rel file_fd], STDIN
    je      .rfb_ret
    mov     edi, [rel file_fd]
    call    asm_close

.rfb_ret:
    pop     r13
    pop     r12
    pop     rbx
    ret

.rfb_fail:
    mov     rdi, 1
    jmp     exit_now

; ═══════════════════════════════════════════════════════════════════
; init_structures — Allocate hash table, node arrays, adjacency pool
; ═══════════════════════════════════════════════════════════════════
init_structures:
    push    rbx

    ; Hash table keys (pointers)
    mov     rsi, INITIAL_HASH_CAP * 8
    call    alloc_zeroed
    mov     [rel ht_keys], rax

    ; Hash table lens (u32)
    mov     rsi, INITIAL_HASH_CAP * 4
    call    alloc_zeroed
    mov     [rel ht_lens], rax

    ; Hash table IDs (u32)
    mov     rsi, INITIAL_HASH_CAP * 4
    call    alloc_zeroed
    mov     [rel ht_ids], rax

    mov     dword [rel ht_cap], INITIAL_HASH_CAP
    mov     dword [rel ht_count], 0

    ; Node arrays
    mov     rsi, INITIAL_NODE_CAP * 8
    call    alloc_zeroed
    mov     [rel node_ptrs], rax

    mov     rsi, INITIAL_NODE_CAP * 4
    call    alloc_zeroed
    mov     [rel node_lens], rax

    mov     rsi, INITIAL_NODE_CAP * 4
    call    alloc_zeroed
    mov     [rel in_deg], rax

    mov     rsi, INITIAL_NODE_CAP * 4
    call    alloc_zeroed
    mov     [rel adj_off], rax

    mov     rsi, INITIAL_NODE_CAP * 4
    call    alloc_zeroed
    mov     [rel adj_cnt], rax

    mov     rsi, INITIAL_NODE_CAP * 4
    call    alloc_zeroed
    mov     [rel adj_cap_arr], rax

    mov     dword [rel node_cap], INITIAL_NODE_CAP
    mov     dword [rel node_count], 0

    ; Adjacency pool
    mov     rsi, INITIAL_ADJ_CAP * 4
    call    alloc_zeroed
    mov     [rel adj_pool], rax
    mov     dword [rel adj_pool_cap], INITIAL_ADJ_CAP
    mov     dword [rel adj_pool_used], 0

    ; Output buffer
    mov     rsi, OUT_BUF_SIZE
    call    alloc_zeroed
    mov     [rel out_buf], rax
    mov     dword [rel out_buf_used], 0

    mov     byte [rel token_parity], 0

    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════════════
; alloc_zeroed — Allocate rsi bytes of zeroed memory via mmap
; Returns rax = pointer (mmap of MAP_ANONYMOUS is already zeroed)
; ═══════════════════════════════════════════════════════════════════
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

; ═══════════════════════════════════════════════════════════════════
; parse_and_build — Parse all tokens and build graph
; ═══════════════════════════════════════════════════════════════════
parse_and_build:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12, [rel input_ptr]   ; input data pointer
    mov     r13, [rel input_len]   ; input length
    xor     r14d, r14d             ; current position
    xor     ebp, ebp               ; pair_first_id

.parse_loop:
    ; Skip whitespace
.skip_ws:
    cmp     r14, r13
    jge     .parse_done
    movzx   eax, byte [r12 + r14]
    cmp     al, ' '
    je      .do_skip
    cmp     al, 10                 ; \n
    je      .do_skip
    cmp     al, 13                 ; \r
    je      .do_skip
    cmp     al, 9                  ; \t
    je      .do_skip
    jmp     .found_token_start
.do_skip:
    inc     r14
    jmp     .skip_ws

.found_token_start:
    mov     r15, r14               ; save start

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
    ; Token is input[r15..r14], length = r14 - r15
    lea     rdi, [r12 + r15]       ; token ptr
    mov     rsi, r14
    sub     rsi, r15               ; token len

    ; Intern the token
    call    intern_token           ; returns eax = node_id

    ; Check parity
    test    byte [rel token_parity], 1
    jnz     .is_second_token

    ; First token of pair
    mov     ebp, eax
    xor     byte [rel token_parity], 1
    jmp     .parse_loop

.is_second_token:
    xor     byte [rel token_parity], 1
    ; Add edge: pair_first -> eax (if different)
    mov     edi, ebp               ; from
    mov     esi, eax               ; to
    cmp     edi, esi
    je      .parse_loop            ; self-loop, skip edge
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

; ═══════════════════════════════════════════════════════════════════
; intern_token — Look up or create a node for the given token
; Input: rdi = token ptr, rsi = token len
; Output: eax = node ID
; Clobbers: rcx, rdx, r8, r9, r10, r11
; Preserves: r12-r15, rbp, rbx (via push/pop)
; ═══════════════════════════════════════════════════════════════════
intern_token:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi               ; token ptr
    mov     r13, rsi               ; token len (as 64-bit)

    ; Compute FNV-1a hash
    mov     rax, 0xcbf29ce484222325
    mov     r8, 0x100000001b3
    xor     ecx, ecx
.hash_loop:
    cmp     rcx, r13
    jge     .hash_done
    movzx   edx, byte [r12 + rcx]
    xor     al, dl
    mul     r8                     ; rax = rax * FNV_PRIME (only low 64 bits matter)
    inc     rcx
    jmp     .hash_loop
.hash_done:
    mov     r14, rax               ; hash value

    ; Probe hash table
    mov     r15d, [rel ht_cap]
    dec     r15d                   ; mask = cap - 1
    mov     ebx, r14d
    and     ebx, r15d              ; slot = hash & mask

.probe_loop:
    ; Load key pointer
    mov     rax, [rel ht_keys]
    mov     rdi, [rax + rbx * 8]
    test    rdi, rdi
    jz      .slot_empty

    ; Compare lengths
    mov     rax, [rel ht_lens]
    mov     ecx, [rax + rbx * 4]
    cmp     rcx, r13
    jne     .probe_next

    ; Compare strings byte-by-byte
    mov     rsi, r12               ; our token
    ; rdi = existing key, rsi = our token, rcx = len
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
    mov     rax, [rel ht_ids]
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
    ; Check load factor BEFORE insert: (count+1) * 4 > cap * 3 => rehash first
    mov     eax, [rel ht_count]
    inc     eax                    ; count + 1
    shl     eax, 2                 ; (count+1) * 4
    mov     ecx, [rel ht_cap]
    lea     ecx, [ecx + ecx * 2]  ; cap * 3
    cmp     eax, ecx
    jle     .no_pre_rehash

    ; Rehash first, then re-probe to find the empty slot
    call    rehash

    ; Re-probe with new table
    mov     r15d, [rel ht_cap]
    dec     r15d                   ; new mask
    mov     ebx, r14d
    and     ebx, r15d              ; re-compute slot with new mask

.reprobe_loop:
    mov     rax, [rel ht_keys]
    mov     rdi, [rax + rbx * 8]
    test    rdi, rdi
    jz      .no_pre_rehash         ; found empty slot
    inc     ebx
    and     ebx, r15d
    jmp     .reprobe_loop

.no_pre_rehash:
    ; Create new node
    mov     r8d, [rel node_count]  ; new node ID

    ; Check if we need to grow node arrays
    cmp     r8d, [rel node_cap]
    jl      .node_space_ok
    call    grow_nodes
.node_space_ok:

    ; Store node data
    mov     rax, [rel node_ptrs]
    mov     [rax + r8 * 8], r12    ; node_ptrs[id] = token ptr

    mov     rax, [rel node_lens]
    mov     [rax + r8 * 4], r13d   ; node_lens[id] = token len

    ; in_deg[id] = 0, adj_off/cnt/cap already 0 from zeroed alloc

    inc     dword [rel node_count]

    ; Store in hash table
    mov     rax, [rel ht_keys]
    mov     [rax + rbx * 8], r12

    mov     rax, [rel ht_lens]
    mov     [rax + rbx * 4], r13d

    mov     rax, [rel ht_ids]
    mov     [rax + rbx * 4], r8d

    inc     dword [rel ht_count]

    mov     eax, r8d
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════════════
; grow_nodes — Double the capacity of all node arrays
; ═══════════════════════════════════════════════════════════════════
grow_nodes:
    push    rbx
    push    r12
    push    r13

    mov     ebx, [rel node_cap]
    lea     r12d, [ebx * 2]       ; new capacity
    ; Use r13 for zero-extended versions
    mov     r13, rbx               ; old cap as 64-bit

    ; Grow node_ptrs (8 bytes each)
    mov     rdi, [rel node_ptrs]
    lea     rsi, [r13 * 8]
    lea     rdx, [r12 * 8]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .grow_fail
    mov     [rel node_ptrs], rax

    ; Grow node_lens (4 bytes each)
    mov     rdi, [rel node_lens]
    lea     rsi, [r13 * 4]
    lea     rdx, [r12 * 4]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .grow_fail
    mov     [rel node_lens], rax

    ; Grow in_deg
    mov     rdi, [rel in_deg]
    lea     rsi, [r13 * 4]
    lea     rdx, [r12 * 4]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .grow_fail
    mov     [rel in_deg], rax

    ; Grow adj_off
    mov     rdi, [rel adj_off]
    lea     rsi, [r13 * 4]
    lea     rdx, [r12 * 4]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .grow_fail
    mov     [rel adj_off], rax

    ; Grow adj_cnt
    mov     rdi, [rel adj_cnt]
    lea     rsi, [r13 * 4]
    lea     rdx, [r12 * 4]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .grow_fail
    mov     [rel adj_cnt], rax

    ; Grow adj_cap_arr
    mov     rdi, [rel adj_cap_arr]
    lea     rsi, [r13 * 4]
    lea     rdx, [r12 * 4]
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .grow_fail
    mov     [rel adj_cap_arr], rax

    mov     [rel node_cap], r12d

    pop     r13
    pop     r12
    pop     rbx
    ret

.grow_fail:
    mov     rdi, 1
    jmp     exit_now

; ═══════════════════════════════════════════════════════════════════
; rehash — Double hash table capacity and reinsert all entries
; ═══════════════════════════════════════════════════════════════════
rehash:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     ebx, [rel ht_cap]     ; old cap
    lea     r12d, [ebx * 2]       ; new cap

    ; Save old tables
    mov     r13, [rel ht_keys]
    mov     r14, [rel ht_lens]
    mov     r15, [rel ht_ids]

    ; Allocate new tables
    lea     rsi, [r12 * 8]
    call    alloc_zeroed
    mov     [rel ht_keys], rax

    lea     rsi, [r12 * 4]
    call    alloc_zeroed
    mov     [rel ht_lens], rax

    lea     rsi, [r12 * 4]
    call    alloc_zeroed
    mov     [rel ht_ids], rax

    mov     [rel ht_cap], r12d

    ; Reinsert all entries
    xor     ebp, ebp               ; index
.rehash_loop:
    cmp     ebp, ebx
    jge     .rehash_done

    mov     rdi, [r13 + rbp * 8]  ; old key ptr
    test    rdi, rdi
    jz      .rehash_next

    mov     ecx, [r14 + rbp * 4]  ; old key len
    mov     r8d, [r15 + rbp * 4]  ; old node ID

    ; Compute FNV-1a hash
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

    ; Find empty slot
    mov     ecx, r12d
    dec     ecx                    ; mask
    mov     esi, eax
    and     esi, ecx

    mov     r9, [rel ht_keys]
.rh_probe:
    cmp     qword [r9 + rsi * 8], 0
    je      .rh_insert
    inc     esi
    and     esi, ecx
    jmp     .rh_probe

.rh_insert:
    pop     rdi                    ; key ptr
    pop     rcx                    ; key len (ecx)
    pop     r8                     ; node ID (r8d)

    mov     rax, [rel ht_keys]
    mov     [rax + rsi * 8], rdi
    mov     rax, [rel ht_lens]
    mov     [rax + rsi * 4], ecx
    mov     rax, [rel ht_ids]
    mov     [rax + rsi * 4], r8d

    pop     rbp

.rehash_next:
    inc     ebp
    jmp     .rehash_loop

.rehash_done:
    ; Free old tables
    mov     rdi, r13
    mov     rsi, rbx
    shl     rsi, 3                 ; old_cap * 8
    mov     rax, SYS_MUNMAP
    syscall

    mov     rdi, r14
    mov     rsi, rbx
    shl     rsi, 2                 ; old_cap * 4
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

; ═══════════════════════════════════════════════════════════════════
; add_edge — Add directed edge from -> to (with dedup)
; Input: edi = from_id, esi = to_id
; ═══════════════════════════════════════════════════════════════════
add_edge:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     ebx, edi               ; from
    mov     r12d, esi              ; to

    ; Get current edge count for 'from' node
    mov     rax, [rel adj_cnt]     ; rax = pointer to adj_cnt array
    mov     ecx, [rax + rbx * 4]  ; ecx = count of edges from 'from'
    test    ecx, ecx
    jz      .ae_no_existing

    ; Check if edge already exists (linear scan)
    mov     rax, [rel adj_off]
    mov     r13d, [rax + rbx * 4] ; r13d = offset into pool
    mov     rdi, [rel adj_pool]
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
    ; Check if node has capacity for more edges
    mov     rax, [rel adj_cap_arr]
    mov     r14d, [rax + rbx * 4] ; r14d = capacity
    mov     rax, [rel adj_cnt]
    mov     r15d, [rax + rbx * 4] ; r15d = current count

    cmp     r15d, r14d
    jl      .ae_have_space

    ; Need to allocate/grow edge list
    test    r14d, r14d
    jz      .ae_new_list

    ; Grow: double capacity
    lea     ecx, [r14d * 2]        ; new cap
    jmp     .ae_realloc

.ae_new_list:
    mov     ecx, 4                 ; initial cap = 4

.ae_realloc:
    ; ecx = new capacity for this node's edge list
    ; Allocate ecx slots from adj_pool
    mov     eax, [rel adj_pool_used]
    lea     edx, [eax + ecx]      ; new pool_used

    ; Check if pool needs growing
    cmp     edx, [rel adj_pool_cap]
    jle     .ae_pool_ok

    ; Grow pool
    push    rax                    ; save old pool_used
    push    rcx                    ; save new cap
    push    rdx                    ; save new pool_used

    mov     eax, [rel adj_pool_cap]
    mov     edi, eax
    shl     edi, 1                 ; try doubling
    cmp     edi, edx
    jge     .ae_pool_size_ok
    lea     edi, [edx * 2]        ; need more than double
.ae_pool_size_ok:
    push    rdi                    ; save new pool cap

    mov     rdi, [rel adj_pool]
    lea     rsi, [rax * 4]        ; old size in bytes
    pop     rax                    ; new pool cap
    push    rax
    lea     rdx, [rax * 4]        ; new size in bytes
    mov     r10d, MREMAP_MAYMOVE
    mov     rax, SYS_MREMAP
    syscall
    cmp     rax, -4096
    ja      .ae_fail
    mov     [rel adj_pool], rax

    pop     rax                    ; new pool cap
    mov     [rel adj_pool_cap], eax
    pop     rdx                    ; restore new pool_used
    pop     rcx                    ; restore new cap
    pop     rax                    ; restore old pool_used
    jmp     .ae_pool_ok

.ae_pool_ok:
    ; eax = offset in pool for new edge list, ecx = new cap
    ; Copy old edges to new location
    test    r15d, r15d
    jz      .ae_no_copy

    mov     rdi, [rel adj_pool]
    mov     r8, [rel adj_off]
    mov     r8d, [r8 + rbx * 4]   ; old offset
    xor     edx, edx
.ae_copy:
    cmp     edx, r15d
    jge     .ae_copy_done
    mov     r9d, r8d
    add     r9d, edx
    mov     r9d, [rdi + r9 * 4]   ; load old edge
    mov     r10d, eax
    add     r10d, edx
    mov     [rdi + r10 * 4], r9d  ; store at new location
    inc     edx
    jmp     .ae_copy
.ae_copy_done:

.ae_no_copy:
    ; Update adj_off and adj_cap_arr
    mov     rdi, [rel adj_off]
    mov     [rdi + rbx * 4], eax

    mov     rdi, [rel adj_cap_arr]
    mov     [rdi + rbx * 4], ecx

    ; Update pool used
    add     eax, ecx
    mov     [rel adj_pool_used], eax

    ; r15d still has the count

.ae_have_space:
    ; Store the new edge
    mov     rax, [rel adj_off]
    mov     ecx, [rax + rbx * 4]  ; offset
    add     ecx, r15d              ; offset + count = insert position

    mov     rdi, [rel adj_pool]
    mov     [rdi + rcx * 4], r12d  ; store target node ID

    ; Increment edge count
    mov     rax, [rel adj_cnt]
    inc     dword [rax + rbx * 4]

    ; Increment in-degree of target
    mov     rax, [rel in_deg]
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

; ═══════════════════════════════════════════════════════════════════
; kahn_sort — Topological sort using Kahn's algorithm
; ═══════════════════════════════════════════════════════════════════
kahn_sort:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r12d, [rel node_count]
    test    r12d, r12d
    jz      .kahn_ret

    ; Allocate queue buffer
    lea     rsi, [r12 * 4 + 16]
    call    alloc_zeroed
    mov     [rel queue_buf], rax

    ; Allocate removed array (1 byte per node)
    lea     rsi, [r12 + 16]
    call    alloc_zeroed
    mov     [rel removed_buf], rax

    xor     ebx, ebx               ; queue_head
    xor     r13d, r13d             ; queue_tail
    xor     r14d, r14d             ; processed count

    ; Seed queue with zero-indegree nodes (sorted alphabetically for GNU compat)
    mov     rax, [rel in_deg]
    xor     ecx, ecx
.kahn_seed:
    cmp     ecx, r12d
    jge     .kahn_seed_sort
    cmp     dword [rax + rcx * 4], 0
    jne     .kahn_seed_next
    mov     rdi, [rel queue_buf]
    mov     [rdi + r13 * 4], ecx
    inc     r13d
.kahn_seed_next:
    inc     ecx
    jmp     .kahn_seed

.kahn_seed_sort:
    ; Sort queue_buf[0..r13d) by node name (insertion sort)
    ; Uses rbp as temp (will be overwritten in main loop anyway)
    cmp     r13d, 2
    jl      .kahn_seed_done

    mov     ebp, 1                 ; i = 1 (use rbp, callee-saved)
.ks_outer:
    cmp     ebp, r13d
    jge     .kahn_seed_done

    mov     rdi, [rel queue_buf]
    mov     r8d, [rdi + rbp * 4]  ; key = queue[i]
    mov     r15d, ebp
    dec     r15d                   ; j = i - 1

.ks_inner:
    cmp     r15d, 0
    jl      .ks_insert

    mov     rdi, [rel queue_buf]
    mov     r9d, [rdi + r15 * 4]  ; queue[j]

    ; Compare: save caller-save regs we need
    push    r8                     ; key node ID
    push    r15                    ; j

    mov     edi, r9d               ; node a = queue[j]
    mov     esi, r8d               ; node b = key
    call    compare_node_names

    pop     r15
    pop     r8

    test    eax, eax
    jle     .ks_insert             ; queue[j] <= key, stop

    ; Shift: queue[j+1] = queue[j]
    mov     rdi, [rel queue_buf]
    mov     r9d, [rdi + r15 * 4]
    lea     eax, [r15d + 1]
    mov     [rdi + rax * 4], r9d
    dec     r15d
    jmp     .ks_inner

.ks_insert:
    lea     eax, [r15d + 1]
    mov     rdi, [rel queue_buf]
    mov     [rdi + rax * 4], r8d
    inc     ebp
    jmp     .ks_outer

.kahn_seed_done:

.kahn_main_loop:
    ; Process queue entries
.kahn_process:
    cmp     ebx, r13d
    jge     .kahn_queue_empty

    ; Dequeue
    mov     rdi, [rel queue_buf]
    mov     ebp, [rdi + rbx * 4]  ; current node
    inc     ebx

    ; Mark removed
    mov     rdi, [rel removed_buf]
    mov     byte [rdi + rbp], 1
    inc     r14d

    ; Output node name
    mov     rax, [rel node_ptrs]
    mov     rsi, [rax + rbp * 8]  ; name ptr
    mov     rax, [rel node_lens]
    mov     edx, [rax + rbp * 4]  ; name len
    call    outbuf_write

    ; Write newline
    mov     byte [rel small_buf], 10
    lea     rsi, [rel small_buf]
    mov     edx, 1
    call    outbuf_write

    ; Process outgoing edges — collect new zero-indegree nodes
    mov     rax, [rel adj_cnt]
    mov     ecx, [rax + rbp * 4]  ; edge count
    test    ecx, ecx
    jz      .kahn_process          ; no edges

    mov     rax, [rel adj_off]
    mov     r8d, [rax + rbp * 4]  ; edge offset
    mov     r9, [rel adj_pool]
    mov     r10, [rel removed_buf]
    mov     r11, [rel in_deg]

    ; First pass: decrement in-degrees and collect new zeros
    ; We use the area after queue_tail in queue_buf as temp storage
    ; Save queue_tail as start of new-zeros collection
    mov     r15d, r13d             ; save old tail = start of new zeros

    xor     edx, edx               ; edge index
.kahn_edge_loop:
    cmp     edx, ecx
    jge     .kahn_edges_done

    mov     eax, r8d
    add     eax, edx
    mov     eax, [r9 + rax * 4]   ; neighbor ID

    ; Skip if removed
    cmp     byte [r10 + rax], 0
    jne     .kahn_edge_next

    ; Decrement in-degree
    dec     dword [r11 + rax * 4]
    jnz     .kahn_edge_next

    ; New zero-indegree: collect (forward order)
    mov     rdi, [rel queue_buf]
    mov     [rdi + r13 * 4], eax
    inc     r13d

.kahn_edge_next:
    inc     edx
    jmp     .kahn_edge_loop

.kahn_edges_done:
    ; Reverse newly added zeros in queue_buf[r15d..r13d)
    ; GNU tsort uses LIFO for newly freed nodes: last freed = first output
    ; Since we iterate edges forward, the last freed is at r13d-1
    ; Reversing makes it come first in the queue
    mov     eax, r15d              ; left
    mov     edx, r13d
    dec     edx                    ; right
    mov     rdi, [rel queue_buf]
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

    ; Cycle detected
    mov     byte [rel exit_code], 1

    ; Flush output buffer before stderr
    call    flush_outbuf

    ; Find first non-removed node
    mov     rdi, [rel removed_buf]
    xor     ecx, ecx
.kahn_find_start:
    cmp     ecx, r12d
    jge     .kahn_ret
    cmp     byte [rdi + rcx], 0
    je      .kahn_found_start
    inc     ecx
    jmp     .kahn_find_start

.kahn_found_start:
    ; ecx = cycle start node
    push    rcx
    mov     edi, ecx
    call    find_and_report_cycle
    pop     rcx

    ; Break cycle: set in_deg[start] = 0, enqueue
    mov     rax, [rel in_deg]
    mov     dword [rax + rcx * 4], 0
    mov     rdi, [rel queue_buf]
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

; ═══════════════════════════════════════════════════════════════════
; find_and_report_cycle — DFS to find and report cycle
; Input: edi = start node ID
; ═══════════════════════════════════════════════════════════════════
find_and_report_cycle:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     ebx, edi               ; start node
    mov     r12d, [rel node_count]

    ; Allocate visited[] (u32 per node, 0xFFFFFFFF = unvisited)
    lea     rsi, [r12 * 4 + 16]
    call    alloc_zeroed
    mov     r13, rax               ; visited[]

    ; Set all to 0xFFFFFFFF
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
    ; Allocate path[] (u32 node IDs)
    lea     rsi, [r12 * 4 + 16]
    call    alloc_zeroed
    mov     r14, rax               ; path[]

    xor     r15d, r15d             ; path_len = 0
    mov     ebp, ebx               ; current = start

.fc_walk:
    ; Check if already visited
    mov     eax, [r13 + rbp * 4]
    cmp     eax, 0xFFFFFFFF
    jne     .fc_found_cycle

    ; visited[current] = path_len
    mov     [r13 + rbp * 4], r15d
    ; path[path_len] = current
    mov     [r14 + r15 * 4], ebp
    inc     r15d

    ; Find first non-removed neighbor
    mov     rax, [rel adj_cnt]
    mov     ecx, [rax + rbp * 4]
    test    ecx, ecx
    jz      .fc_no_next

    mov     rax, [rel adj_off]
    mov     r8d, [rax + rbp * 4]
    mov     r9, [rel adj_pool]
    mov     r10, [rel removed_buf]
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
    ; Dead end — report just the start node
    jmp     .fc_report_single

.fc_found_cycle:
    ; eax = path index where cycle begins
    ; Save cycle_start_idx in ebp (callee-saved, we pushed it)
    mov     ebp, eax

    ; Print header
    lea     rdi, [rel str_tool_name]
    call    write_stderr_str
    mov     rdi, [rel source_name]
    call    write_stderr_str
    lea     rdi, [rel str_loop_msg]
    call    write_stderr_str

    ; Print cycle nodes: path[ebp..r15d)
.fc_print:
    cmp     ebp, r15d
    jge     .fc_cleanup

    lea     rdi, [rel str_tool_prefix]
    call    write_stderr_str

    mov     eax, [r14 + rbp * 4]
    call    write_stderr_node

    inc     ebp
    jmp     .fc_print

.fc_report_single:
    lea     rdi, [rel str_tool_name]
    call    write_stderr_str
    mov     rdi, [rel source_name]
    call    write_stderr_str
    lea     rdi, [rel str_loop_msg]
    call    write_stderr_str

    lea     rdi, [rel str_tool_prefix]
    call    write_stderr_str
    mov     eax, ebx
    call    write_stderr_node

.fc_cleanup:
    ; Free arrays
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

; ═══════════════════════════════════════════════════════════════════
; write_stderr_node — Write node name + newline to stderr
; Input: eax = node ID
; ═══════════════════════════════════════════════════════════════════
write_stderr_node:
    push    rbx
    mov     ebx, eax

    mov     rax, [rel node_ptrs]
    mov     rsi, [rax + rbx * 8]
    mov     rax, [rel node_lens]
    mov     edx, [rax + rbx * 4]

    mov     rdi, STDERR
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel newline_char]
    mov     edx, 1
    call    asm_write_all

    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════════════
; write_stderr_str — Write null-terminated string to stderr
; Input: rdi = string ptr
; ═══════════════════════════════════════════════════════════════════
write_stderr_str:
    push    rbx
    mov     rbx, rdi

    ; Find length
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

; ═══════════════════════════════════════════════════════════════════
; outbuf_write — Append bytes to output buffer, flush if needed
; Input: rsi = ptr, edx = len
; ═══════════════════════════════════════════════════════════════════
outbuf_write:
    push    rbx
    push    r12

    mov     rbx, rsi               ; ptr
    mov     r12d, edx              ; len

    ; Check if we need to flush first
    mov     eax, [rel out_buf_used]
    lea     ecx, [eax + r12d]
    cmp     ecx, OUT_BUF_SIZE
    jl      .ow_copy
    call    flush_outbuf

.ow_copy:
    mov     rdi, [rel out_buf]
    mov     eax, [rel out_buf_used]
    add     rdi, rax

    mov     rsi, rbx
    mov     ecx, r12d
    rep     movsb

    add     [rel out_buf_used], r12d

    ; Flush if past threshold
    mov     eax, [rel out_buf_used]
    cmp     eax, FLUSH_THRESHOLD
    jl      .ow_done
    call    flush_outbuf
.ow_done:
    pop     r12
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════════════
; flush_outbuf — Write output buffer to stdout
; ═══════════════════════════════════════════════════════════════════
flush_outbuf:
    mov     edx, [rel out_buf_used]
    test    edx, edx
    jz      .fl_done
    mov     rdi, STDOUT
    mov     rsi, [rel out_buf]
    call    asm_write_all
    test    rax, rax
    js      .fl_epipe
    mov     dword [rel out_buf_used], 0
.fl_done:
    ret
.fl_epipe:
    movzx   edi, byte [rel exit_code]
    jmp     exit_now

; ═══════════════════════════════════════════════════════════════════
; str_equal — Compare null-terminated strings rdi and rsi
; Returns eax=1 if equal, 0 if not
; ═══════════════════════════════════════════════════════════════════
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

; ═══════════════════════════════════════════════════════════════════
; compare_node_names — Lexicographic compare of two node names
; Input: edi = node_id_a, esi = node_id_b
; Output: eax < 0 if a < b, 0 if equal, > 0 if a > b
; ═══════════════════════════════════════════════════════════════════
compare_node_names:
    push    rbx
    push    r12

    ; Get pointers and lengths
    mov     rax, [rel node_ptrs]
    mov     rbx, [rax + rdi * 8]  ; ptr_a
    mov     r12, [rax + rsi * 8]  ; ptr_b

    mov     rax, [rel node_lens]
    mov     ecx, [rax + rdi * 4]  ; len_a
    mov     edx, [rax + rsi * 4]  ; len_b

    ; min_len = min(len_a, len_b)
    cmp     ecx, edx
    jle     .cn_use_a
    mov     eax, edx
    jmp     .cn_cmp
.cn_use_a:
    mov     eax, ecx
.cn_cmp:
    ; Compare min_len bytes
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
    ; All compared bytes equal; shorter string is "less"
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

; ═══════════════════════════════════════════════════════════════════
; Data Sections
; ═══════════════════════════════════════════════════════════════════
section .rodata

str_help_flag:      db '--help', 0
str_version_flag:   db '--version', 0
str_dashdash:       db '--', 0
str_dash:           db '-', 0
str_tool_name:      db 'tsort: ', 0
str_tool_prefix:    db 'tsort: ', 0
str_colon_sp:       db ': ', 0
str_squote_nl:      db 0x27, 10, 0         ; '\n
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

; ═══════════════════════════════════════════════════════════════════
; BSS Section
; ═══════════════════════════════════════════════════════════════════
section .bss

; SIGPIPE
sigact_buf:     resb 32

; Input
input_ptr:      resq 1
input_len:      resq 1
input_mmapped:  resb 1
source_name:    resq 1
file_fd:        resd 1

; stat buffer
stat_buf:       resb STAT_STRUCT_SIZE

; Hash table
ht_keys:        resq 1
ht_lens:        resq 1
ht_ids:         resq 1
ht_cap:         resd 1
ht_count:       resd 1

; Node arrays
node_ptrs:      resq 1
node_lens:      resq 1
in_deg:         resq 1
adj_off:        resq 1
adj_cnt:        resq 1
adj_cap_arr:    resq 1
node_cap:       resd 1
node_count:     resd 1

; Adjacency pool
adj_pool:       resq 1
adj_pool_cap:   resd 1
adj_pool_used:  resd 1

; Queue
queue_buf:      resq 1

; Removed bitmap
removed_buf:    resq 1

; Output buffer
out_buf:        resq 1
out_buf_used:   resd 1

; State
token_parity:   resb 1
exit_code:      resb 1

; Scratch
small_buf:      resb 16

section .note.GNU-stack noalloc noexec nowrite progbits
