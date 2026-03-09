; fexpand.asm — GNU-compatible "expand" in x86-64 Linux assembly
;
; Converts tabs to spaces. Handles:
;   -i/--initial, -t/--tabs=N, -t/--tabs=LIST, --help, --version, --
;   Multiple files, - for stdin, SIGPIPE, EINTR, partial writes
;
; Tab stop list supports:
;   Single number: uniform tab stops (e.g., -t 4)
;   Comma-separated: explicit positions (e.g., -t 3,7,11)
;   /N prefix on last item: repeating interval after explicit stops
;   +N prefix on last item: relative repeating from last explicit stop
;
; Performance optimizations:
;   - mmap() for file input (zero-copy, kernel prefetch, no read syscalls)
;   - SSE2 SIMD scanning for tab/newline/backspace (16 bytes at a time)
;   - 512KB output buffer with 256KB flush threshold
;   - Inline space fill with unrolled stores for 1-8 spaces
;   - Power-of-2 tab width uses AND instead of DIV
;   - Falls back to read() for stdin (pipes can't be mmap'd)
;
; Register conventions (global):
;   r12 = out_buf_pos (bytes in output buffer)
;   r13 = processed_any flag
;   ebp = had_error flag (0=ok, 1=error)
;
; Build (modular):
;   nasm -f elf64 -I include/ tools/fexpand.asm -o build/tools/fexpand.o
;   nasm -f elf64 -I include/ lib/io.asm -o build/lib/io.o
;   ld --gc-sections -n build/tools/fexpand.o build/lib/io.o -o fexpand

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close

; ─── Constants ───────────────────────────────────────────
%define MAX_TAB_STOPS   256
%define MAX_FILES        256

; mmap constants
%define PROT_READ        1
%define MAP_PRIVATE      2
%define MAP_POPULATE     0x08000
%define MADV_SEQUENTIAL  2
%define MADV_HUGEPAGE    14
%define SYS_MADVISE      28

; struct stat offsets (x86-64 Linux)
%define STAT_SIZE        144      ; sizeof(struct stat)
%define ST_SIZE_OFF      48       ; offset of st_size in struct stat

; Large output buffer
%define OUT_BUF_SIZE_BIG   1048576
%define FLUSH_THRESHOLD_BIG 786432

global _start

section .text

; ─── Entry Point ─────────────────────────────────────────
_start:
    BLOCK_SIGPIPE

    ; Parse argc/argv from stack
    mov     r14, [rsp]              ; argc
    lea     r15, [rsp + 8]          ; argv[0]

    ; Skip argv[0]
    dec     r14
    add     r15, 8                  ; &argv[1]

    ; Initialize global state
    xor     ebp, ebp                ; had_error = 0
    xor     r12d, r12d              ; out_buf_pos = 0
    xor     r13d, r13d              ; processed_any = 0

    ; Initialize tab config
    mov     dword [rel tab_mode], 0         ; 0=uniform, 1=list
    mov     qword [rel uniform_tab], 8      ; default tab stop = 8
    mov     dword [rel num_tab_stops], 0
    mov     byte [rel initial_only], 0
    mov     dword [rel num_files], 0
    mov     byte [rel seen_dashdash], 0
    mov     qword [rel repeat_interval], 0  ; 0 = no repeating
    mov     byte [rel repeat_relative], 0   ; 0 = /N absolute, 1 = +N relative

    ; If no args, skip parse → done_args will read stdin
    test    r14, r14
    jz      .done_args

    ; Parse arguments
    xor     ebx, ebx                ; arg index = 0

.parse_loop:
    cmp     rbx, r14
    jge     .done_args

    mov     rsi, [r15 + rbx*8]      ; argv[i]

    ; If we've seen --, treat as file
    cmp     byte [rel seen_dashdash], 1
    je      .is_file

    ; Check for '-' prefix
    cmp     byte [rsi], '-'
    jne     .is_file

    ; Check for "--" or "--..."
    cmp     byte [rsi+1], '-'
    jne     .check_short

    ; Starts with "--"
    cmp     byte [rsi+2], 0
    je      .set_dashdash           ; exactly "--"

    ; Check --help
    push    rbx
    lea     rdi, [rel str_help_opt]
    call    strcmp
    pop     rbx
    test    eax, eax
    jz      .do_help

    ; Check --version
    mov     rsi, [r15 + rbx*8]
    push    rbx
    lea     rdi, [rel str_version_opt]
    call    strcmp
    pop     rbx
    test    eax, eax
    jz      .do_version

    ; Check --initial
    mov     rsi, [r15 + rbx*8]
    push    rbx
    lea     rdi, [rel str_initial_opt]
    call    strcmp
    pop     rbx
    test    eax, eax
    jz      .set_initial

    ; Check --tabs=
    mov     rsi, [r15 + rbx*8]
    push    rbx
    lea     rdi, [rel str_tabs_eq]
    mov     ecx, 7                  ; strlen("--tabs=")
    call    strncmp
    pop     rbx
    test    eax, eax
    jz      .parse_tabs_eq

    ; Unknown --option
    mov     rsi, [r15 + rbx*8]
    call    err_unrecognized_option
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.set_initial:
    mov     byte [rel initial_only], 1
    jmp     .parse_next

.parse_tabs_eq:
    ; rsi still points to argv[i], skip "--tabs="
    mov     rsi, [r15 + rbx*8]
    add     rsi, 7
    push    rbx
    call    parse_tab_spec
    pop     rbx
    test    eax, eax
    jnz     .tab_parse_error
    jmp     .parse_next

.check_short:
    ; Single '-' means stdin
    cmp     byte [rsi+1], 0
    je      .is_stdin

    ; Parse short options: -i, -t, -tN, -it4, etc.
    inc     rsi                     ; skip the '-'
    call    parse_short_opts
    test    eax, eax
    jnz     .short_opt_error
    jmp     .parse_next

.short_opt_error:
    ; eax < 0 means we need the next argv for -t value
    cmp     eax, -1
    jne     .tab_parse_error
    ; Need next arg for -t value
    inc     rbx
    cmp     rbx, r14
    jge     .missing_tab_arg
    mov     rsi, [r15 + rbx*8]
    push    rbx
    call    parse_tab_spec
    pop     rbx
    test    eax, eax
    jnz     .tab_parse_error
    jmp     .parse_next

.missing_tab_arg:
    lea     rsi, [rel str_missing_tab]
    call    err_msg
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.tab_parse_error:
    ; Error already printed by parse_tab_spec
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.set_dashdash:
    mov     byte [rel seen_dashdash], 1
    jmp     .parse_next

.is_stdin:
    push    rbx
    mov     r13d, 1
    mov     edi, STDIN
    call    try_mmap_or_read
    pop     rbx
    jmp     .parse_next

.is_file:
    push    rbx
    mov     r13d, 1
    mov     rsi, [r15 + rbx*8]
    call    open_and_process
    pop     rbx
    jmp     .parse_next

.parse_next:
    inc     rbx
    jmp     .parse_loop

.done_args:
    ; Validate tab config
    cmp     dword [rel tab_mode], 1
    jne     .skip_tab_validate
    cmp     dword [rel num_tab_stops], 0
    je      .skip_tab_validate
    ; Tab list is already validated during parsing
.skip_tab_validate:

    ; If no files processed, read stdin
    test    r13, r13
    jnz     .final_flush
    mov     edi, STDIN
    call    try_mmap_or_read

.final_flush:
    call    flush_output
    test    eax, eax
    jnz     .write_error_exit

    movzx   rdi, bpl
    mov     rax, SYS_EXIT
    syscall

.write_error_exit:
    lea     rdi, [rel str_write_error]
    call    print_error_simple
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

; ─── Help ────────────────────────────────────────────────
.do_help:
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [rel help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

; ─── Version ─────────────────────────────────────────────
.do_version:
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [rel version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

; ─── parse_short_opts(rsi=ptr past '-') ──────────────────
; Returns: 0 = ok, -1 = need next argv for -t value, >0 = error
parse_short_opts:
    push    rbx
    push    r14
    mov     rbx, rsi                ; ptr into option chars

.pso_loop:
    movzx   eax, byte [rbx]
    test    al, al
    jz      .pso_ok

    cmp     al, 'i'
    je      .pso_initial

    cmp     al, 't'
    je      .pso_tab

    ; Unknown short option
    push    rbx
    ; Build "-X" string on stack for error
    sub     rsp, 4
    mov     byte [rsp], '-'
    mov     [rsp+1], al
    mov     byte [rsp+2], 0
    mov     rsi, rsp
    call    err_invalid_option
    add     rsp, 4
    pop     rbx
    pop     r14
    pop     rbx
    mov     rdi, 1
    mov     rax, SYS_EXIT
    syscall

.pso_initial:
    mov     byte [rel initial_only], 1
    inc     rbx
    jmp     .pso_loop

.pso_tab:
    ; Check if value follows immediately: -t4 or -t 4,8
    inc     rbx
    cmp     byte [rbx], 0
    je      .pso_need_next_arg

    ; Value follows immediately
    mov     rsi, rbx
    push    rbx
    call    parse_tab_spec
    pop     rbx
    ; After parse_tab_spec, remaining chars in rbx are consumed
    pop     r14
    pop     rbx
    ret                             ; return parse_tab_spec result in eax

.pso_need_next_arg:
    ; -t was last char, need next argv
    mov     eax, -1
    pop     r14
    pop     rbx
    ret

.pso_ok:
    xor     eax, eax
    pop     r14
    pop     rbx
    ret

; ─── parse_tab_spec(rsi=string) ──────────────────────────
; Parses: "N" (uniform), "N1,N2,..." (list), with optional /N or +N last
; Returns: 0=ok, 1=error (message printed)
parse_tab_spec:
    push    rbx
    push    r13
    push    r14
    push    r15
    mov     rbx, rsi                ; save string start

    ; Check if string contains comma or space → list mode
    mov     rdi, rbx
    call    has_separator
    test    eax, eax
    jnz     .pts_list_mode

    ; Single value — check for / or + prefix
    movzx   eax, byte [rbx]
    cmp     al, '/'
    je      .pts_uniform_repeat
    cmp     al, '+'
    je      .pts_uniform_repeat

    ; Plain number → uniform tab stops
    mov     rsi, rbx
    call    parse_number
    test    rax, rax
    js      .pts_invalid_char
    test    rax, rax
    jz      .pts_zero_error
    mov     [rel uniform_tab], rax
    mov     dword [rel tab_mode], 0
    jmp     .pts_ok

.pts_uniform_repeat:
    ; /N or +N as sole argument → uniform repeating from 0
    mov     r14b, [rbx]             ; save prefix char
    inc     rbx
    mov     rsi, rbx
    call    parse_number
    test    rax, rax
    js      .pts_invalid_char
    test    rax, rax
    jz      .pts_zero_error
    mov     [rel uniform_tab], rax
    mov     dword [rel tab_mode], 0
    jmp     .pts_ok

.pts_list_mode:
    ; Parse comma/space-separated list
    mov     dword [rel tab_mode], 1
    mov     dword [rel num_tab_stops], 0
    mov     qword [rel repeat_interval], 0
    mov     byte [rel repeat_relative], 0
    mov     r14, rbx                ; current parse position

.pts_list_next:
    ; Skip separators (comma, space)
    movzx   eax, byte [r14]
    test    al, al
    jz      .pts_list_done
    cmp     al, ','
    je      .pts_skip_sep
    cmp     al, ' '
    je      .pts_skip_sep
    jmp     .pts_list_parse_num

.pts_skip_sep:
    inc     r14
    jmp     .pts_list_next

.pts_list_parse_num:
    ; Check for /N or +N prefix (only valid as last item)
    movzx   eax, byte [r14]
    cmp     al, '/'
    je      .pts_list_repeat
    cmp     al, '+'
    je      .pts_list_repeat_relative

    ; Parse number
    mov     rsi, r14
    call    parse_number
    test    rax, rax
    js      .pts_invalid_char
    test    rax, rax
    jz      .pts_zero_error

    ; Store in tab_stops array
    mov     ecx, [rel num_tab_stops]
    cmp     ecx, MAX_TAB_STOPS
    jge     .pts_too_many

    ; Validate ascending order
    test    ecx, ecx
    jz      .pts_list_store
    lea     rdi, [rel tab_stops]
    mov     rdx, [rdi + (rcx-1)*8]
    cmp     rax, rdx
    jle     .pts_not_ascending

.pts_list_store:
    lea     rdi, [rel tab_stops]
    mov     [rdi + rcx*8], rax
    inc     ecx
    mov     [rel num_tab_stops], ecx

    ; Advance past the number
    mov     rsi, r14
    call    skip_number
    mov     r14, rax
    jmp     .pts_list_next

.pts_list_repeat:
    ; /N — repeating interval (absolute)
    inc     r14
    mov     rsi, r14
    call    parse_number
    test    rax, rax
    js      .pts_invalid_char
    test    rax, rax
    jz      .pts_zero_error
    mov     [rel repeat_interval], rax
    mov     byte [rel repeat_relative], 0
    ; Advance past number and check nothing follows
    mov     rsi, r14
    call    skip_number
    mov     r14, rax
    jmp     .pts_list_done

.pts_list_repeat_relative:
    ; +N — relative repeating from last stop
    inc     r14
    mov     rsi, r14
    call    parse_number
    test    rax, rax
    js      .pts_invalid_char
    test    rax, rax
    jz      .pts_zero_error
    mov     [rel repeat_interval], rax
    mov     byte [rel repeat_relative], 1
    mov     rsi, r14
    call    skip_number
    mov     r14, rax
    jmp     .pts_list_done

.pts_list_done:
    ; Ensure we got at least one stop
    cmp     dword [rel num_tab_stops], 0
    je      .pts_ok                 ; /N alone handled above as uniform
    jmp     .pts_ok

.pts_not_ascending:
    lea     rsi, [rel str_not_ascending]
    call    err_msg
    jmp     .pts_error

.pts_zero_error:
    lea     rsi, [rel str_zero_tab]
    call    err_msg
    jmp     .pts_error

.pts_invalid_char:
    ; Print error about invalid character
    mov     rsi, r14
    test    rsi, rsi
    jnz     .pts_inv1
    mov     rsi, rbx
.pts_inv1:
    call    err_invalid_tab
    jmp     .pts_error

.pts_too_many:
    lea     rsi, [rel str_too_many_tabs]
    call    err_msg
    jmp     .pts_error

.pts_error:
    mov     eax, 1
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

.pts_ok:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; ─── has_separator(rdi=str) → eax=1 if comma or space found ──
has_separator:
    xor     eax, eax
.hs_loop:
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .hs_done
    cmp     cl, ','
    je      .hs_found
    cmp     cl, ' '
    je      .hs_found
    inc     rdi
    jmp     .hs_loop
.hs_found:
    mov     eax, 1
.hs_done:
    ret

; ─── parse_number(rsi=str) → rax=value, -1 if invalid ───
; Stops at comma, space, or NUL
parse_number:
    xor     rax, rax
    movzx   ecx, byte [rsi]
    ; Must start with digit
    sub     cl, '0'
    cmp     cl, 9
    ja      .pn_invalid
.pn_loop:
    movzx   ecx, byte [rsi]
    sub     cl, '0'
    cmp     cl, 9
    ja      .pn_done
    imul    rax, 10
    movzx   ecx, byte [rsi]
    sub     cl, '0'
    add     rax, rcx
    inc     rsi
    jmp     .pn_loop
.pn_done:
    ; Verify stopped at separator or end
    movzx   ecx, byte [rsi]
    test    cl, cl
    jz      .pn_ok
    cmp     cl, ','
    je      .pn_ok
    cmp     cl, ' '
    je      .pn_ok
    ; Not a valid stop character
.pn_invalid:
    mov     rax, -1
.pn_ok:
    ret

; ─── skip_number(rsi=str) → rax=ptr past digits ─────────
skip_number:
    mov     rax, rsi
.sn_loop:
    movzx   ecx, byte [rax]
    sub     cl, '0'
    cmp     cl, 9
    ja      .sn_done
    inc     rax
    jmp     .sn_loop
.sn_done:
    ret

; ─── try_mmap_or_read(edi=fd) ──────────────────────────────
; Try to mmap the fd (works for regular files, even stdin redirected from file).
; Falls back to read() for pipes/sockets.
try_mmap_or_read:
    push    r14
    push    r15
    mov     r14d, edi               ; save fd

    ; fstat to get file size
    sub     rsp, STAT_SIZE
    mov     edi, r14d
    mov     rsi, rsp
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .tmor_fstat_fail        ; fstat failed

    mov     r15, [rsp + ST_SIZE_OFF]
    add     rsp, STAT_SIZE

    test    r15, r15
    jle     .tmor_read              ; size 0 or negative, use read

    ; Try mmap
    xor     edi, edi
    mov     rsi, r15
    mov     edx, PROT_READ
    mov     r10d, MAP_PRIVATE | MAP_POPULATE
    mov     r8d, r14d
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .tmor_read              ; mmap failed, use read

    push    rax
    push    r15

    ; madvise SEQUENTIAL
    mov     rdi, rax
    mov     rsi, r15
    mov     edx, MADV_SEQUENTIAL
    mov     rax, SYS_MADVISE
    syscall

    ; madvise HUGEPAGE
    pop     r15
    pop     rax
    push    rax
    push    r15
    mov     rdi, rax
    mov     rsi, r15
    mov     edx, MADV_HUGEPAGE
    mov     rax, SYS_MADVISE
    syscall

    ; Process mmap'd data
    pop     r15
    pop     rax
    push    rax
    push    r15

    mov     r8, rax
    lea     r9, [rax + r15]
    call    process_mmap_region

    ; munmap
    pop     rsi
    pop     rdi
    mov     rax, SYS_MUNMAP
    syscall

    pop     r15
    pop     r14
    ret

.tmor_fstat_fail:
    add     rsp, STAT_SIZE          ; clean up stat struct from stack
.tmor_read:
    mov     edi, r14d
    call    process_fd
    pop     r15
    pop     r14
    ret

; ─── open_and_process(rsi=filename) ──────────────────────
; Opens a file, tries mmap first, falls back to read() for empty/special files
open_and_process:
    push    rbx
    push    r14
    push    r15
    mov     rbx, rsi                ; save filename

    ; Open file
    mov     rdi, rsi
    xor     esi, esi                ; O_RDONLY
    xor     edx, edx
    mov     rax, SYS_OPEN
    syscall
    test    rax, rax
    js      .oap_error

    mov     r14d, eax               ; fd

    ; fstat to get file size
    sub     rsp, STAT_SIZE
    mov     edi, r14d
    mov     rsi, rsp
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .oap_stat_failed

    mov     r15, [rsp + ST_SIZE_OFF]  ; file size
    add     rsp, STAT_SIZE

    ; If size is 0, fall back to read-based processing (could be special file)
    test    r15, r15
    jz      .oap_use_read

    ; mmap the file: mmap(NULL, size, PROT_READ, MAP_PRIVATE|MAP_POPULATE, fd, 0)
    xor     edi, edi                ; addr = NULL
    mov     rsi, r15                ; length = file size
    mov     edx, PROT_READ          ; prot
    mov     r10d, MAP_PRIVATE | MAP_POPULATE ; flags
    mov     r8d, r14d               ; fd
    xor     r9d, r9d                ; offset = 0
    mov     rax, SYS_MMAP
    syscall
    test    rax, rax
    js      .oap_mmap_failed

    push    rax                     ; save mmap address
    push    r15                     ; save mmap size

    ; madvise(addr, len, MADV_SEQUENTIAL) — hint for sequential access
    mov     rdi, rax
    mov     rsi, r15
    mov     edx, MADV_SEQUENTIAL
    mov     rax, SYS_MADVISE
    syscall

    ; madvise(addr, len, MADV_HUGEPAGE) — use transparent huge pages
    pop     r15                     ; mmap size
    pop     rax                     ; mmap address
    push    rax
    push    r15
    mov     rdi, rax
    mov     rsi, r15
    mov     edx, MADV_HUGEPAGE
    mov     rax, SYS_MADVISE
    syscall
    ; ignore madvise errors

    ; Process mmap'd data: r8=start, r9=end
    pop     r15                     ; mmap size
    pop     rax                     ; mmap address
    push    rax                     ; save for munmap
    push    r15

    ; Set up input pointers and process
    mov     r8, rax                 ; input start
    lea     r9, [rax + r15]         ; input end
    call    process_mmap_region

    ; munmap
    pop     rsi                     ; size
    pop     rdi                     ; addr
    mov     rax, SYS_MUNMAP
    syscall

    ; Close fd
    mov     edi, r14d
    mov     rax, SYS_CLOSE
    syscall

    pop     r15
    pop     r14
    pop     rbx
    ret

.oap_use_read:
    ; Fall back to read-based processing for stdin/empty/special files
    mov     edi, r14d
    call    process_fd

    ; Close fd
    mov     edi, r14d
    mov     rax, SYS_CLOSE
    syscall

    pop     r15
    pop     r14
    pop     rbx
    ret

.oap_stat_failed:
    add     rsp, STAT_SIZE
    ; Close fd and fall back to read
    jmp     .oap_use_read

.oap_mmap_failed:
    ; mmap failed, fall back to read
    jmp     .oap_use_read

.oap_error:
    neg     rax
    mov     rdi, rbx
    mov     esi, eax
    call    err_file
    mov     ebp, 1
    pop     r15
    pop     r14
    pop     rbx
    ret

; ─── process_mmap_region ─────────────────────────────────
; Processes mmap'd input data directly.
; Input: r8=start pointer, r9=end pointer (set by caller)
; Uses same processing logic as process_fd but without read loop.
;
; Register usage:
;   r13 = tab_width (callee-saved)
;   r14 = current column (callee-saved)
;   r15 = tab_mask for power-of-2, or 0 for div (callee-saved)
;   r8  = input pointer
;   r9  = input end pointer
;   r10 = output pointer
;   r12 = out_buf_pos (global)
;   ebp = had_error (global)

; Macro to save caller-saved registers to BSS before function calls
%macro SAVE_PTRS 0
    mov     [rel save_r8], r8
    mov     [rel save_r9], r9
    mov     [rel save_r10], r10
%endmacro

; Macro to restore caller-saved registers after function calls
%macro RESTORE_PTRS 0
    mov     r8, [rel save_r8]
    mov     r9, [rel save_r9]
    mov     r10, [rel save_r10]
%endmacro

process_mmap_region:
    push    rbx
    push    r13
    push    r14
    push    r15
    ; Save r8, r9 across setup (they are inputs)
    push    r8
    push    r9

    xor     r14d, r14d              ; column = 0

    ; Pre-compute tab parameters
    mov     r13, [rel uniform_tab]  ; tab width
    mov     rax, r13
    dec     rax
    test    rax, r13
    jnz     .pmr_not_pow2
    mov     r15, rax                ; r15 = mask for power-of-2
    jmp     .pmr_setup_done
.pmr_not_pow2:
    xor     r15d, r15d              ; r15 = 0 means "use div"
.pmr_setup_done:
    mov     byte [rel init_done_flag], 0

    pop     r9                      ; restore input end
    pop     r8                      ; restore input start
    lea     r10, [rel out_buf]
    add     r10, r12                ; output pointer

    ; Check which processing mode to use
    cmp     byte [rel initial_only], 1
    je      .pmr_initial_mode

    cmp     dword [rel tab_mode], 1
    je      .pmr_list_mode

    ; ━━━ FAST PATH: uniform tabs, no -i ━━━━━━━━━━━━━━━━━━━
    ; Pre-load SIMD constant into register to avoid memory loads in hot loop
    movdqa  xmm6, [rel special_threshold]
    pxor    xmm7, xmm7                 ; permanent zero for pcmpeqb
    jmp     .pf_fast_simd

    ; ━━━ LIST MODE ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
.pmr_list_mode:
    jmp     .pf_list_simd

    ; ━━━ INITIAL MODE ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
.pmr_initial_mode:
    jmp     .pf_initial_mode

; ─── FAST PATH: uniform tabs ────────────────────────────
; Streamlined approach: SIMD scan → find first special → bulk copy before it
; → handle special → repeat. No window loop — simpler and fewer branches.
.pf_fast_simd:
    ; Ensure output buffer has room
    lea     rax, [rel out_buf + FLUSH_THRESHOLD_BIG]
    cmp     r10, rax
    jl      .pf_fast_simd_scan
    ; Need to flush
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    SAVE_PTRS
    call    flush_output
    RESTORE_PTRS
    lea     r10, [rel out_buf]

.pf_fast_simd_scan:
    mov     rax, r9
    sub     rax, r8
    cmp     rax, 64
    jl      .pf_fast_32_check

    ; 64-byte path: check 4x16 in parallel
    movdqu  xmm0, [r8]
    movdqu  xmm1, [r8 + 16]
    movdqu  xmm2, [r8 + 32]
    movdqu  xmm3, [r8 + 48]
    movdqa  xmm4, xmm0
    psubusb xmm4, xmm6
    pcmpeqb xmm4, xmm7
    movdqa  xmm5, xmm1
    psubusb xmm5, xmm6
    pcmpeqb xmm5, xmm7
    por     xmm4, xmm5
    movdqa  xmm5, xmm2
    psubusb xmm5, xmm6
    pcmpeqb xmm5, xmm7
    por     xmm4, xmm5
    movdqa  xmm5, xmm3
    psubusb xmm5, xmm6
    pcmpeqb xmm5, xmm7
    por     xmm4, xmm5
    pmovmskb eax, xmm4
    test    eax, eax
    jnz     .pf_fast_64_special

    ; No specials in 64 bytes — bulk copy all 4 chunks
    movdqu  [r10], xmm0
    movdqu  [r10 + 16], xmm1
    movdqu  [r10 + 32], xmm2
    movdqu  [r10 + 48], xmm3
    add     r8, 64
    add     r10, 64
    add     r14, 64
    jmp     .pf_fast_simd

.pf_fast_64_special:
    ; Fall through to 16-byte processing (data in cache)

.pf_fast_32_check:
    cmp     rax, 16
    jl      .pf_fast_scalar_loop

    ; 16-byte scan: find first special
    movdqu  xmm0, [r8]
    movdqa  xmm4, xmm0
    psubusb xmm4, xmm6
    pcmpeqb xmm4, xmm7
    pmovmskb eax, xmm4
    test    eax, eax
    jnz     .pf_fast_has_special

    ; No specials — bulk copy 16 bytes
    movdqu  [r10], xmm0
    add     r8, 16
    add     r10, 16
    add     r14, 16
    jmp     .pf_fast_simd

.pf_fast_has_special:
    ; eax = bitmask, find position of first special
    bsf     ecx, eax                    ; ecx = offset to first special

    ; Copy normal bytes before the special (0 to 15 bytes)
    test    ecx, ecx
    jz      .pf_fast_at_special         ; first byte is special

    ; Bulk copy ecx bytes using SIMD partial store
    ; xmm0 already has the data; use overlapping write for < 16 bytes
    add     r14, rcx
    cmp     ecx, 8
    jl      .pf_fast_copy_small
    ; 8-15 bytes: two overlapping 8-byte stores
    movq    [r10], xmm0
    lea     rsi, [r8 + rcx - 8]
    mov     rax, [rsi]
    mov     [r10 + rcx - 8], rax
    jmp     .pf_fast_copy_done
.pf_fast_copy_small:
    cmp     ecx, 4
    jl      .pf_fast_copy_tiny
    mov     eax, [r8]
    mov     [r10], eax
    mov     eax, [r8 + rcx - 4]
    mov     [r10 + rcx - 4], eax
    jmp     .pf_fast_copy_done
.pf_fast_copy_tiny:
    ; 1-3 bytes
    movzx   eax, byte [r8]
    mov     [r10], al
    cmp     ecx, 1
    je      .pf_fast_copy_done
    movzx   eax, byte [r8 + 1]
    mov     [r10 + 1], al
    cmp     ecx, 2
    je      .pf_fast_copy_done
    movzx   eax, byte [r8 + 2]
    mov     [r10 + 2], al
.pf_fast_copy_done:
    add     r10, rcx
    add     r8, rcx

.pf_fast_at_special:
    ; r8 points to the special char, handle it
    movzx   eax, byte [r8]
    inc     r8

    cmp     al, 9
    je      .pf_fast_tab
    cmp     al, 10
    je      .pf_fast_newline
    cmp     al, 8
    je      .pf_fast_backspace
    ; Other control char: copy verbatim
    mov     [r10], al
    inc     r10
    inc     r14
    jmp     .pf_fast_simd

.pf_fast_tab:
    test    r15, r15
    jz      .pf_fast_tab_div
    mov     eax, r14d
    and     eax, r15d                   ; col & mask
    mov     ecx, r13d                   ; tab_width
    sub     ecx, eax                    ; spaces = tab_width - (col & mask)
    jmp     .pf_fast_fill_spaces

.pf_fast_tab_div:
    mov     rax, r14
    xor     edx, edx
    div     r13
    mov     ecx, r13d
    sub     ecx, edx

.pf_fast_fill_spaces:
    add     r14, rcx

    cmp     ecx, 8
    ja      .pf_fast_fill_large
    ; 1-8 spaces: single 8-byte store (always safe, output buffer has headroom)
    mov     rax, 0x2020202020202020
    mov     [r10], rax
    add     r10, rcx
    jmp     .pf_fast_simd

.pf_fast_fill_large:
    ; 9+ spaces (rare: tab_width > 8)
    mov     rax, 0x2020202020202020
.pf_fast_fill_loop:
    cmp     ecx, 8
    jl      .pf_fast_fill_tail
    mov     [r10], rax
    add     r10, 8
    sub     ecx, 8
    jmp     .pf_fast_fill_loop
.pf_fast_fill_tail:
    test    ecx, ecx
    jz      .pf_fast_simd
    mov     [r10], rax
    add     r10, rcx
    jmp     .pf_fast_simd

.pf_fast_newline:
    mov     byte [r10], 10
    inc     r10
    xor     r14d, r14d
    jmp     .pf_fast_simd

.pf_fast_backspace:
    mov     byte [r10], 8
    inc     r10
    test    r14, r14
    jz      .pf_fast_simd
    dec     r14
    jmp     .pf_fast_simd

.pf_fast_scalar_loop:
    cmp     r8, r9
    jge     .pf_fast_done

    movzx   eax, byte [r8]

    cmp     al, 9
    je      .pf_fast_scalar_tab
    cmp     al, 10
    je      .pf_fast_scalar_nl
    cmp     al, 8
    je      .pf_fast_scalar_bs

    mov     [r10], al
    inc     r10
    inc     r14
    inc     r8
    jmp     .pf_fast_scalar_loop

.pf_fast_scalar_nl:
    inc     r8
    jmp     .pf_fast_newline

.pf_fast_scalar_bs:
    inc     r8
    jmp     .pf_fast_backspace

.pf_fast_scalar_tab:
    inc     r8
    test    r15, r15
    jz      .pf_fast_tab_div
    mov     eax, r14d
    and     eax, r15d
    mov     ecx, r13d
    sub     ecx, eax
    jmp     .pf_fast_fill_spaces

.pf_fast_done:
    ; Update r12 from r10
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    ; Flush if above threshold
    cmp     r12, FLUSH_THRESHOLD_BIG
    jl      .pmr_done
    call    flush_output
    jmp     .pmr_done

    ; ━━━ LIST MODE ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
.pf_list_simd:
    lea     rax, [rel out_buf + FLUSH_THRESHOLD_BIG]
    cmp     r10, rax
    jl      .pf_list_simd_scan
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    SAVE_PTRS
    call    flush_output
    RESTORE_PTRS
    lea     r10, [rel out_buf]

.pf_list_simd_scan:
    mov     rax, r9
    sub     rax, r8
    cmp     rax, 16
    jl      .pf_list_scalar

    movdqu  xmm0, [r8]
    movdqa  xmm4, xmm0
    pcmpeqb xmm4, [rel tab_pattern]
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, [rel newline_pattern]
    por     xmm4, xmm5
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, [rel backspace_pattern]
    por     xmm4, xmm5
    pmovmskb eax, xmm4
    test    eax, eax
    jnz     .pf_list_simd_special

    movdqu  [r10], xmm0
    add     r8, 16
    add     r10, 16
    add     r14, 16
    jmp     .pf_list_simd

.pf_list_simd_special:
    bsf     ecx, eax
    test    ecx, ecx
    jz      .pf_list_scalar

    movzx   edx, cl
    add     r14, rdx

    ; Small copy for list mode
    cmp     edx, 8
    jl      .pf_list_copy_small
    mov     rcx, [r8]
    mov     [r10], rcx
    mov     rcx, [r8 + rdx - 8]
    mov     [r10 + rdx - 8], rcx
    jmp     .pf_list_copy_done
.pf_list_copy_small:
    cmp     edx, 4
    jl      .pf_list_copy_tiny
    mov     ecx, [r8]
    mov     [r10], ecx
    mov     ecx, [r8 + rdx - 4]
    mov     [r10 + rdx - 4], ecx
    jmp     .pf_list_copy_done
.pf_list_copy_tiny:
    xor     ecx, ecx
.pf_list_copy_byte:
    cmp     ecx, edx
    jge     .pf_list_copy_done
    mov     al, [r8 + rcx]
    mov     [r10 + rcx], al
    inc     ecx
    jmp     .pf_list_copy_byte
.pf_list_copy_done:
    add     r8, rdx
    add     r10, rdx

.pf_list_scalar:
    cmp     r8, r9
    jge     .pf_list_done

    movzx   eax, byte [r8]
    cmp     al, 9
    je      .pf_list_tab
    cmp     al, 10
    je      .pf_list_newline
    cmp     al, 8
    je      .pf_list_backspace

    mov     [r10], al
    inc     r10
    inc     r14
    inc     r8
    jmp     .pf_list_simd

.pf_list_tab:
    ; Update r12, save ptrs, call calc_tab_spaces
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    SAVE_PTRS
    call    calc_tab_spaces
    RESTORE_PTRS
    lea     r10, [rel out_buf]
    add     r10, r12

    mov     ecx, eax
    test    ecx, ecx
    jz      .pf_list_tab_done
    add     r14, rcx
    ; Inline space fill
    mov     rax, 0x2020202020202020
.pf_list_fill_loop:
    cmp     ecx, 8
    jl      .pf_list_fill_tail
    mov     [r10], rax
    add     r10, 8
    sub     ecx, 8
    jmp     .pf_list_fill_loop
.pf_list_fill_tail:
    test    ecx, ecx
    jz      .pf_list_tab_done
    mov     [r10], rax
    add     r10, rcx
.pf_list_tab_done:
    inc     r8
    jmp     .pf_list_simd

.pf_list_newline:
    mov     byte [r10], 10
    inc     r10
    inc     r8
    xor     r14d, r14d
    jmp     .pf_list_simd

.pf_list_backspace:
    mov     byte [r10], 8
    inc     r10
    inc     r8
    test    r14, r14
    jz      .pf_list_simd
    dec     r14
    jmp     .pf_list_simd

.pf_list_done:
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    cmp     r12, FLUSH_THRESHOLD_BIG
    jl      .pmr_done
    call    flush_output
    jmp     .pmr_done

    ; ━━━ INITIAL MODE (-i flag) ━━━━━━━━━━━━━━━━━━━━━━━━━━
.pf_initial_mode:

.pf_init_simd:
    lea     rax, [rel out_buf + FLUSH_THRESHOLD_BIG]
    cmp     r10, rax
    jl      .pf_init_simd_scan
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    SAVE_PTRS
    call    flush_output
    RESTORE_PTRS
    lea     r10, [rel out_buf]

.pf_init_simd_scan:
    mov     rax, r9
    sub     rax, r8
    cmp     rax, 16
    jl      .pf_init_scalar

    ; If initial_done, use passthrough mode
    cmp     byte [rel init_done_flag], 1
    je      .pf_init_passthrough_simd

    ; In initial region: check for special chars
    movdqu  xmm0, [r8]
    movdqa  xmm4, xmm0
    pcmpeqb xmm4, [rel tab_pattern]
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, [rel newline_pattern]
    por     xmm4, xmm5
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, [rel backspace_pattern]
    por     xmm4, xmm5
    pmovmskb eax, xmm4
    test    eax, eax
    jnz     .pf_init_simd_special

    ; No special chars — copy 16 bytes, check for non-space
    movdqu  [r10], xmm0
    ; Check if all 16 bytes are spaces
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, [rel space_pattern]
    pmovmskb ecx, xmm5
    cmp     ecx, 0xFFFF
    je      .pf_init_all_spaces
    mov     byte [rel init_done_flag], 1
.pf_init_all_spaces:
    add     r8, 16
    add     r10, 16
    add     r14, 16
    jmp     .pf_init_simd

.pf_init_simd_special:
    bsf     ecx, eax
    test    ecx, ecx
    jz      .pf_init_scalar

    movzx   edx, cl
    add     r14, rdx
    ; Check for non-space in bytes before special
    push    rdx
    xor     ecx, ecx
.pf_init_pre_check:
    cmp     ecx, edx
    jge     .pf_init_pre_done
    cmp     byte [r8 + rcx], ' '
    jne     .pf_init_pre_nonblank
    inc     ecx
    jmp     .pf_init_pre_check
.pf_init_pre_nonblank:
    mov     byte [rel init_done_flag], 1
.pf_init_pre_done:
    pop     rdx
    ; Copy edx bytes
    cmp     edx, 8
    jl      .pf_init_copy_small
    mov     rcx, [r8]
    mov     [r10], rcx
    mov     rcx, [r8 + rdx - 8]
    mov     [r10 + rdx - 8], rcx
    jmp     .pf_init_copy_done
.pf_init_copy_small:
    cmp     edx, 4
    jl      .pf_init_copy_tiny
    mov     ecx, [r8]
    mov     [r10], ecx
    mov     ecx, [r8 + rdx - 4]
    mov     [r10 + rdx - 4], ecx
    jmp     .pf_init_copy_done
.pf_init_copy_tiny:
    xor     ecx, ecx
.pf_init_copy_byte:
    cmp     ecx, edx
    jge     .pf_init_copy_done
    mov     al, [r8 + rcx]
    mov     [r10 + rcx], al
    inc     ecx
    jmp     .pf_init_copy_byte
.pf_init_copy_done:
    add     r8, rdx
    add     r10, rdx

.pf_init_scalar:
    cmp     r8, r9
    jge     .pf_init_done

    movzx   eax, byte [r8]
    cmp     al, 9
    je      .pf_init_tab
    cmp     al, 10
    je      .pf_init_newline
    cmp     al, 8
    je      .pf_init_backspace

    ; Regular char
    mov     [r10], al
    inc     r10
    inc     r14
    inc     r8
    cmp     al, ' '
    je      .pf_init_simd
    mov     byte [rel init_done_flag], 1
    jmp     .pf_init_simd

.pf_init_tab:
    cmp     byte [rel init_done_flag], 1
    je      .pf_init_tab_pass

    ; Expand tab (same logic as fast path)
    cmp     dword [rel tab_mode], 1
    je      .pf_init_tab_list

    test    r15, r15
    jz      .pf_init_tab_div
    mov     eax, r14d
    and     eax, r15d
    mov     ecx, r13d
    sub     ecx, eax
    jmp     .pf_init_tab_fill

.pf_init_tab_div:
    mov     rax, r14
    xor     edx, edx
    div     r13
    mov     ecx, r13d
    sub     ecx, edx
    jmp     .pf_init_tab_fill

.pf_init_tab_list:
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    SAVE_PTRS
    call    calc_tab_spaces
    RESTORE_PTRS
    lea     r10, [rel out_buf]
    add     r10, r12
    mov     ecx, eax

.pf_init_tab_fill:
    test    ecx, ecx
    jz      .pf_init_tab_done
    add     r14, rcx
    ; Inline space fill
    cmp     ecx, 8
    ja      .pf_init_fill_large
    mov     rax, 0x2020202020202020
    mov     [r10], rax
    add     r10, rcx
    jmp     .pf_init_tab_done
.pf_init_fill_large:
    mov     rax, 0x2020202020202020
.pf_init_fill_loop:
    cmp     ecx, 8
    jl      .pf_init_fill_tail
    mov     [r10], rax
    add     r10, 8
    sub     ecx, 8
    jmp     .pf_init_fill_loop
.pf_init_fill_tail:
    test    ecx, ecx
    jz      .pf_init_tab_done
    mov     [r10], rax
    add     r10, rcx
.pf_init_tab_done:
    inc     r8
    jmp     .pf_init_simd

.pf_init_tab_pass:
    mov     byte [r10], 9
    inc     r10
    inc     r14
    inc     r8
    jmp     .pf_init_simd

.pf_init_newline:
    mov     byte [r10], 10
    inc     r10
    inc     r8
    xor     r14d, r14d
    mov     byte [rel init_done_flag], 0
    jmp     .pf_init_simd

.pf_init_backspace:
    mov     byte [r10], 8
    inc     r10
    inc     r8
    test    r14, r14
    jz      .pf_init_simd
    dec     r14
    jmp     .pf_init_simd

.pf_init_passthrough_simd:
    movdqu  xmm0, [r8]
    movdqa  xmm4, xmm0
    pcmpeqb xmm4, [rel newline_pattern]
    pmovmskb eax, xmm4
    test    eax, eax
    jnz     .pf_init_pt_has_nl

    movdqu  [r10], xmm0
    add     r8, 16
    add     r10, 16
    add     r14, 16
    jmp     .pf_init_simd

.pf_init_pt_has_nl:
    bsf     ecx, eax
    test    ecx, ecx
    jz      .pf_init_pt_nl_emit

    movzx   edx, cl
    ; Copy edx bytes before the newline
    cmp     edx, 8
    jl      .pf_init_pt_copy_small
    mov     rcx, [r8]
    mov     [r10], rcx
    mov     rcx, [r8 + rdx - 8]
    mov     [r10 + rdx - 8], rcx
    jmp     .pf_init_pt_copy_done
.pf_init_pt_copy_small:
    cmp     edx, 4
    jl      .pf_init_pt_copy_tiny
    mov     ecx, [r8]
    mov     [r10], ecx
    mov     ecx, [r8 + rdx - 4]
    mov     [r10 + rdx - 4], ecx
    jmp     .pf_init_pt_copy_done
.pf_init_pt_copy_tiny:
    xor     ecx, ecx
.pf_init_pt_copy_byte:
    cmp     ecx, edx
    jge     .pf_init_pt_copy_done
    mov     al, [r8 + rcx]
    mov     [r10 + rcx], al
    inc     ecx
    jmp     .pf_init_pt_copy_byte
.pf_init_pt_copy_done:
    add     r8, rdx
    add     r10, rdx
    add     r14, rdx

.pf_init_pt_nl_emit:
    mov     byte [r10], 10
    inc     r10
    inc     r8
    xor     r14d, r14d
    mov     byte [rel init_done_flag], 0
    jmp     .pf_init_simd

.pf_init_done:
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    cmp     r12, FLUSH_THRESHOLD_BIG
    jl      .pmr_done
    call    flush_output
    jmp     .pmr_done

.pmr_done:
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; ─── process_fd(edi=fd) ─────────────────────────────────
; Read-based processing for stdin and fallback.
; Uses a read loop with the same SIMD processing logic.
process_fd:
    push    rbx
    push    r13
    push    r14
    push    r15

    mov     ebx, edi
    xor     r14d, r14d              ; column = 0

    ; Pre-compute tab parameters in callee-saved registers
    mov     r13, [rel uniform_tab]  ; tab width
    mov     rax, r13
    dec     rax
    test    rax, r13
    jnz     .fd_not_pow2
    mov     r15, rax                ; r15 = mask for power-of-2
    jmp     .fd_setup_done
.fd_not_pow2:
    xor     r15d, r15d              ; r15 = 0 means "use div"
.fd_setup_done:
    mov     byte [rel init_done_flag], 0

.fd_read_loop:
    mov     edi, ebx
    lea     rsi, [rel read_buf]
    mov     edx, READ_BUF_SIZE
    call    asm_read

    test    rax, rax
    js      .fd_read_error
    jz      .fd_done

    ; Set up pointers for this chunk
    lea     r8, [rel read_buf]
    lea     r9, [r8 + rax]
    lea     r10, [rel out_buf]
    add     r10, r12

    ; Check which processing mode to use
    cmp     byte [rel initial_only], 1
    je      .fd_initial_mode

    cmp     dword [rel tab_mode], 1
    je      .fd_list_mode

    ; Fast path: uniform tabs
    jmp     .fd_fast_simd

.fd_fast_simd:
    lea     rax, [rel out_buf + FLUSH_THRESHOLD_BIG]
    cmp     r10, rax
    jl      .fd_fast_simd_scan
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    SAVE_PTRS
    call    flush_output
    RESTORE_PTRS
    lea     r10, [rel out_buf]

.fd_fast_simd_scan:
    mov     rax, r9
    sub     rax, r8
    cmp     rax, 16
    jl      .fd_fast_scalar

    movdqu  xmm0, [r8]
    movdqa  xmm4, xmm0
    pcmpeqb xmm4, [rel tab_pattern]
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, [rel newline_pattern]
    por     xmm4, xmm5
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, [rel backspace_pattern]
    por     xmm4, xmm5
    pmovmskb eax, xmm4
    test    eax, eax
    jnz     .fd_fast_simd_special

    movdqu  [r10], xmm0
    add     r8, 16
    add     r10, 16
    add     r14, 16
    jmp     .fd_fast_simd

.fd_fast_simd_special:
    bsf     ecx, eax
    test    ecx, ecx
    jz      .fd_fast_scalar

    movzx   edx, cl
    add     r14, rdx
    cmp     edx, 8
    jl      .fd_fast_copy_small
    mov     rcx, [r8]
    mov     [r10], rcx
    mov     rcx, [r8 + rdx - 8]
    mov     [r10 + rdx - 8], rcx
    jmp     .fd_fast_copy_done
.fd_fast_copy_small:
    cmp     edx, 4
    jl      .fd_fast_copy_tiny
    mov     ecx, [r8]
    mov     [r10], ecx
    mov     ecx, [r8 + rdx - 4]
    mov     [r10 + rdx - 4], ecx
    jmp     .fd_fast_copy_done
.fd_fast_copy_tiny:
    mov     cl, [r8]
    mov     [r10], cl
    cmp     edx, 1
    je      .fd_fast_copy_done
    mov     cl, [r8+1]
    mov     [r10+1], cl
    cmp     edx, 2
    je      .fd_fast_copy_done
    mov     cl, [r8+2]
    mov     [r10+2], cl
.fd_fast_copy_done:
    add     r8, rdx
    add     r10, rdx

.fd_fast_scalar:
    cmp     r8, r9
    jge     .fd_fast_done

    movzx   eax, byte [r8]
    cmp     al, 9
    je      .fd_fast_tab
    cmp     al, 10
    je      .fd_fast_newline
    cmp     al, 8
    je      .fd_fast_backspace

    mov     [r10], al
    inc     r10
    inc     r14
    inc     r8
    jmp     .fd_fast_simd

.fd_fast_tab:
    test    r15, r15
    jz      .fd_fast_tab_div
    mov     eax, r14d
    and     eax, r15d
    mov     ecx, r13d
    sub     ecx, eax
    jmp     .fd_fast_fill
.fd_fast_tab_div:
    mov     rax, r14
    xor     edx, edx
    div     r13
    mov     ecx, r13d
    sub     ecx, edx
.fd_fast_fill:
    add     r14, rcx
    inc     r8
    cmp     ecx, 8
    ja      .fd_fast_fill_large
    mov     rax, 0x2020202020202020
    mov     [r10], rax
    add     r10, rcx
    jmp     .fd_fast_simd
.fd_fast_fill_large:
    mov     rax, 0x2020202020202020
.fd_fast_fill_loop:
    cmp     ecx, 8
    jl      .fd_fast_fill_tail
    mov     [r10], rax
    add     r10, 8
    sub     ecx, 8
    jmp     .fd_fast_fill_loop
.fd_fast_fill_tail:
    test    ecx, ecx
    jz      .fd_fast_simd
    mov     [r10], rax
    add     r10, rcx
    jmp     .fd_fast_simd

.fd_fast_newline:
    mov     byte [r10], 10
    inc     r10
    inc     r8
    xor     r14d, r14d
    jmp     .fd_fast_simd

.fd_fast_backspace:
    mov     byte [r10], 8
    inc     r10
    inc     r8
    test    r14, r14
    jz      .fd_fast_simd
    dec     r14
    jmp     .fd_fast_simd

.fd_fast_done:
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    cmp     r12, FLUSH_THRESHOLD_BIG
    jl      .fd_read_loop
    call    flush_output
    jmp     .fd_read_loop

    ; ━━━ LIST MODE (fd) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
.fd_list_mode:

.fd_list_simd:
    lea     rax, [rel out_buf + FLUSH_THRESHOLD_BIG]
    cmp     r10, rax
    jl      .fd_list_simd_scan
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    SAVE_PTRS
    call    flush_output
    RESTORE_PTRS
    lea     r10, [rel out_buf]

.fd_list_simd_scan:
    mov     rax, r9
    sub     rax, r8
    cmp     rax, 16
    jl      .fd_list_scalar

    movdqu  xmm0, [r8]
    movdqa  xmm4, xmm0
    pcmpeqb xmm4, [rel tab_pattern]
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, [rel newline_pattern]
    por     xmm4, xmm5
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, [rel backspace_pattern]
    por     xmm4, xmm5
    pmovmskb eax, xmm4
    test    eax, eax
    jnz     .fd_list_simd_special

    movdqu  [r10], xmm0
    add     r8, 16
    add     r10, 16
    add     r14, 16
    jmp     .fd_list_simd

.fd_list_simd_special:
    bsf     ecx, eax
    test    ecx, ecx
    jz      .fd_list_scalar
    movzx   edx, cl
    add     r14, rdx
    cmp     edx, 8
    jl      .fd_list_copy_small2
    mov     rcx, [r8]
    mov     [r10], rcx
    mov     rcx, [r8 + rdx - 8]
    mov     [r10 + rdx - 8], rcx
    jmp     .fd_list_copy_done2
.fd_list_copy_small2:
    cmp     edx, 4
    jl      .fd_list_copy_tiny2
    mov     ecx, [r8]
    mov     [r10], ecx
    mov     ecx, [r8 + rdx - 4]
    mov     [r10 + rdx - 4], ecx
    jmp     .fd_list_copy_done2
.fd_list_copy_tiny2:
    xor     ecx, ecx
.fd_list_copy_byte2:
    cmp     ecx, edx
    jge     .fd_list_copy_done2
    mov     al, [r8 + rcx]
    mov     [r10 + rcx], al
    inc     ecx
    jmp     .fd_list_copy_byte2
.fd_list_copy_done2:
    add     r8, rdx
    add     r10, rdx

.fd_list_scalar:
    cmp     r8, r9
    jge     .fd_list_done
    movzx   eax, byte [r8]
    cmp     al, 9
    je      .fd_list_tab
    cmp     al, 10
    je      .fd_list_newline
    cmp     al, 8
    je      .fd_list_backspace
    mov     [r10], al
    inc     r10
    inc     r14
    inc     r8
    jmp     .fd_list_simd

.fd_list_tab:
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    SAVE_PTRS
    call    calc_tab_spaces
    RESTORE_PTRS
    lea     r10, [rel out_buf]
    add     r10, r12
    mov     ecx, eax
    test    ecx, ecx
    jz      .fd_list_tab_done
    add     r14, rcx
    mov     rax, 0x2020202020202020
.fd_list_fill_loop:
    cmp     ecx, 8
    jl      .fd_list_fill_tail
    mov     [r10], rax
    add     r10, 8
    sub     ecx, 8
    jmp     .fd_list_fill_loop
.fd_list_fill_tail:
    test    ecx, ecx
    jz      .fd_list_tab_done
    mov     [r10], rax
    add     r10, rcx
.fd_list_tab_done:
    inc     r8
    jmp     .fd_list_simd

.fd_list_newline:
    mov     byte [r10], 10
    inc     r10
    inc     r8
    xor     r14d, r14d
    jmp     .fd_list_simd

.fd_list_backspace:
    mov     byte [r10], 8
    inc     r10
    inc     r8
    test    r14, r14
    jz      .fd_list_simd
    dec     r14
    jmp     .fd_list_simd

.fd_list_done:
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    cmp     r12, FLUSH_THRESHOLD_BIG
    jl      .fd_read_loop
    call    flush_output
    jmp     .fd_read_loop

    ; ━━━ INITIAL MODE (fd) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
.fd_initial_mode:

.fd_init_simd:
    lea     rax, [rel out_buf + FLUSH_THRESHOLD_BIG]
    cmp     r10, rax
    jl      .fd_init_simd_scan
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    SAVE_PTRS
    call    flush_output
    RESTORE_PTRS
    lea     r10, [rel out_buf]

.fd_init_simd_scan:
    mov     rax, r9
    sub     rax, r8
    cmp     rax, 16
    jl      .fd_init_scalar

    cmp     byte [rel init_done_flag], 1
    je      .fd_init_passthrough_simd

    movdqu  xmm0, [r8]
    movdqa  xmm4, xmm0
    pcmpeqb xmm4, [rel tab_pattern]
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, [rel newline_pattern]
    por     xmm4, xmm5
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, [rel backspace_pattern]
    por     xmm4, xmm5
    pmovmskb eax, xmm4
    test    eax, eax
    jnz     .fd_init_simd_special

    movdqu  [r10], xmm0
    movdqa  xmm5, xmm0
    pcmpeqb xmm5, [rel space_pattern]
    pmovmskb ecx, xmm5
    cmp     ecx, 0xFFFF
    je      .fd_init_all_spaces
    mov     byte [rel init_done_flag], 1
.fd_init_all_spaces:
    add     r8, 16
    add     r10, 16
    add     r14, 16
    jmp     .fd_init_simd

.fd_init_simd_special:
    bsf     ecx, eax
    test    ecx, ecx
    jz      .fd_init_scalar
    movzx   edx, cl
    add     r14, rdx
    push    rdx
    xor     ecx, ecx
.fd_init_pre_check:
    cmp     ecx, edx
    jge     .fd_init_pre_done
    cmp     byte [r8 + rcx], ' '
    jne     .fd_init_pre_nonblank
    inc     ecx
    jmp     .fd_init_pre_check
.fd_init_pre_nonblank:
    mov     byte [rel init_done_flag], 1
.fd_init_pre_done:
    pop     rdx
    cmp     edx, 8
    jl      .fd_init_copy_small
    mov     rcx, [r8]
    mov     [r10], rcx
    mov     rcx, [r8 + rdx - 8]
    mov     [r10 + rdx - 8], rcx
    jmp     .fd_init_copy_done
.fd_init_copy_small:
    cmp     edx, 4
    jl      .fd_init_copy_tiny
    mov     ecx, [r8]
    mov     [r10], ecx
    mov     ecx, [r8 + rdx - 4]
    mov     [r10 + rdx - 4], ecx
    jmp     .fd_init_copy_done
.fd_init_copy_tiny:
    xor     ecx, ecx
.fd_init_copy_byte:
    cmp     ecx, edx
    jge     .fd_init_copy_done
    mov     al, [r8 + rcx]
    mov     [r10 + rcx], al
    inc     ecx
    jmp     .fd_init_copy_byte
.fd_init_copy_done:
    add     r8, rdx
    add     r10, rdx

.fd_init_scalar:
    cmp     r8, r9
    jge     .fd_init_done
    movzx   eax, byte [r8]
    cmp     al, 9
    je      .fd_init_tab
    cmp     al, 10
    je      .fd_init_newline
    cmp     al, 8
    je      .fd_init_backspace

    mov     [r10], al
    inc     r10
    inc     r14
    inc     r8
    cmp     al, ' '
    je      .fd_init_simd
    mov     byte [rel init_done_flag], 1
    jmp     .fd_init_simd

.fd_init_tab:
    cmp     byte [rel init_done_flag], 1
    je      .fd_init_tab_pass
    cmp     dword [rel tab_mode], 1
    je      .fd_init_tab_list
    test    r15, r15
    jz      .fd_init_tab_div
    mov     eax, r14d
    and     eax, r15d
    mov     ecx, r13d
    sub     ecx, eax
    jmp     .fd_init_tab_fill
.fd_init_tab_div:
    mov     rax, r14
    xor     edx, edx
    div     r13
    mov     ecx, r13d
    sub     ecx, edx
    jmp     .fd_init_tab_fill
.fd_init_tab_list:
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    SAVE_PTRS
    call    calc_tab_spaces
    RESTORE_PTRS
    lea     r10, [rel out_buf]
    add     r10, r12
    mov     ecx, eax
.fd_init_tab_fill:
    test    ecx, ecx
    jz      .fd_init_tab_done
    add     r14, rcx
    cmp     ecx, 8
    ja      .fd_init_fill_large
    mov     rax, 0x2020202020202020
    mov     [r10], rax
    add     r10, rcx
    jmp     .fd_init_tab_done
.fd_init_fill_large:
    mov     rax, 0x2020202020202020
.fd_init_fill_loop:
    cmp     ecx, 8
    jl      .fd_init_fill_tail
    mov     [r10], rax
    add     r10, 8
    sub     ecx, 8
    jmp     .fd_init_fill_loop
.fd_init_fill_tail:
    test    ecx, ecx
    jz      .fd_init_tab_done
    mov     [r10], rax
    add     r10, rcx
.fd_init_tab_done:
    inc     r8
    jmp     .fd_init_simd

.fd_init_tab_pass:
    mov     byte [r10], 9
    inc     r10
    inc     r14
    inc     r8
    jmp     .fd_init_simd

.fd_init_newline:
    mov     byte [r10], 10
    inc     r10
    inc     r8
    xor     r14d, r14d
    mov     byte [rel init_done_flag], 0
    jmp     .fd_init_simd

.fd_init_backspace:
    mov     byte [r10], 8
    inc     r10
    inc     r8
    test    r14, r14
    jz      .fd_init_simd
    dec     r14
    jmp     .fd_init_simd

.fd_init_passthrough_simd:
    movdqu  xmm0, [r8]
    movdqa  xmm4, xmm0
    pcmpeqb xmm4, [rel newline_pattern]
    pmovmskb eax, xmm4
    test    eax, eax
    jnz     .fd_init_pt_has_nl
    movdqu  [r10], xmm0
    add     r8, 16
    add     r10, 16
    add     r14, 16
    jmp     .fd_init_simd

.fd_init_pt_has_nl:
    bsf     ecx, eax
    test    ecx, ecx
    jz      .fd_init_pt_nl_emit
    movzx   edx, cl
    cmp     edx, 8
    jl      .fd_init_pt_copy_small
    mov     rcx, [r8]
    mov     [r10], rcx
    mov     rcx, [r8 + rdx - 8]
    mov     [r10 + rdx - 8], rcx
    jmp     .fd_init_pt_copy_done
.fd_init_pt_copy_small:
    cmp     edx, 4
    jl      .fd_init_pt_copy_tiny
    mov     ecx, [r8]
    mov     [r10], ecx
    mov     ecx, [r8 + rdx - 4]
    mov     [r10 + rdx - 4], ecx
    jmp     .fd_init_pt_copy_done
.fd_init_pt_copy_tiny:
    xor     ecx, ecx
.fd_init_pt_copy_byte:
    cmp     ecx, edx
    jge     .fd_init_pt_copy_done
    mov     al, [r8 + rcx]
    mov     [r10 + rcx], al
    inc     ecx
    jmp     .fd_init_pt_copy_byte
.fd_init_pt_copy_done:
    add     r8, rdx
    add     r10, rdx
    add     r14, rdx

.fd_init_pt_nl_emit:
    mov     byte [r10], 10
    inc     r10
    inc     r8
    xor     r14d, r14d
    mov     byte [rel init_done_flag], 0
    jmp     .fd_init_simd

.fd_init_done:
    lea     rax, [rel out_buf]
    sub     r10, rax
    mov     r12, r10
    cmp     r12, FLUSH_THRESHOLD_BIG
    jl      .fd_read_loop
    call    flush_output
    jmp     .fd_read_loop

.fd_done:
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

.fd_read_error:
    mov     ebp, 1
    jmp     .fd_done

; ─── calc_tab_spaces(r14=column) → eax=num_spaces ───────
; Uses tab_mode, uniform_tab, tab_stops[], num_tab_stops, repeat_interval
; Tab stop values are 0-based column positions (matching GNU expand behavior)
calc_tab_spaces:
    cmp     dword [rel tab_mode], 1
    je      .cts_list

    ; Uniform mode: spaces = tab_width - (column % tab_width)
    mov     rax, r14                ; column
    xor     edx, edx
    mov     rcx, [rel uniform_tab]
    div     rcx                     ; rdx = column % tab_width
    mov     rax, rcx
    sub     rax, rdx                ; tab_width - remainder
    ret

.cts_list:
    ; List mode: find next tab stop > current column
    mov     ecx, [rel num_tab_stops]
    test    ecx, ecx
    jz      .cts_list_single_space

    lea     rdi, [rel tab_stops]
    xor     edx, edx                ; index

.cts_list_search:
    cmp     edx, ecx
    jge     .cts_list_past_end

    mov     rax, [rdi + rdx*8]      ; tab_stops[i] (0-based column)
    cmp     rax, r14
    ja      .cts_list_found         ; stop > column

    inc     edx
    jmp     .cts_list_search

.cts_list_found:
    ; rax = tab stop column, r14 = current column
    sub     rax, r14                ; spaces = stop - column
    ret

.cts_list_past_end:
    ; Past all explicit stops — check for repeat interval
    mov     rax, [rel repeat_interval]
    test    rax, rax
    jz      .cts_list_single_space

    ; Get last explicit stop
    mov     rdx, [rdi + (rcx-1)*8]  ; last tab stop (0-based)

    cmp     byte [rel repeat_relative], 1
    je      .cts_list_repeat_relative

    ; /N — repeating interval from column 0
    ; next = ((column / interval) + 1) * interval
    mov     rcx, rax                ; interval
    mov     rax, r14                ; column
    xor     edx, edx
    div     rcx                     ; column / interval
    inc     rax                     ; +1
    imul    rax, rcx                ; next stop column
    sub     rax, r14                ; spaces = next_stop - column
    ret

.cts_list_repeat_relative:
    ; +N — repeating relative to last explicit stop
    ; distance = column - last_stop
    ; next_offset = ((distance / interval) + 1) * interval
    ; next_stop = last_stop + next_offset
    ; spaces = next_stop - column
    mov     rcx, rax                ; interval
    push    rdx                     ; save last_stop
    mov     rax, r14
    sub     rax, rdx                ; distance from last stop
    xor     edx, edx
    div     rcx                     ; distance / interval
    inc     rax
    imul    rax, rcx                ; next_offset
    pop     rdx                     ; restore last_stop
    add     rax, rdx                ; next_stop column
    sub     rax, r14                ; spaces
    ret

.cts_list_single_space:
    mov     eax, 1
    ret

; ─── emit_byte(al=byte) ─────────────────────────────────
; Appends one byte to out_buf, flushing if needed
emit_byte:
    cmp     r12, OUT_BUF_SIZE_BIG - 1
    jl      .eb_ok
    push    rax
    call    flush_output
    pop     rax
    test    eax, eax
    ; ignore flush error for now (ebp will be set by flush_output indirectly)
.eb_ok:
    lea     rdi, [rel out_buf]
    mov     [rdi + r12], al
    inc     r12

    cmp     r12, FLUSH_THRESHOLD_BIG
    jl      .eb_done
    call    flush_output
.eb_done:
    ret

; ─── emit_newline() ──────────────────────────────────────
emit_newline:
    mov     al, 10
    jmp     emit_byte

; ─── ensure_out_space_16 ─────────────────────────────────
; Ensures at least 16 bytes of space in out_buf
ensure_out_space_16:
    lea     rax, [r12 + 16]
    cmp     rax, OUT_BUF_SIZE_BIG
    jl      .eos16_ok
    call    flush_output
.eos16_ok:
    ret

; ─── ensure_out_space_n(edx=n) ───────────────────────────
; Ensures at least n bytes of space in out_buf
ensure_out_space_n:
    movzx   eax, dl
    add     rax, r12
    cmp     rax, OUT_BUF_SIZE_BIG
    jl      .eosn_ok
    push    rdx
    call    flush_output
    pop     rdx
.eosn_ok:
    ret

; ─── flush_output() ──────────────────────────────────────
flush_output:
    test    r12, r12
    jz      .fo_nothing

    mov     rdi, STDOUT
    lea     rsi, [rel out_buf]
    mov     rdx, r12
    call    asm_write_all
    test    eax, eax
    jnz     .fo_error
    xor     r12d, r12d
    xor     eax, eax
    ret

.fo_error:
    mov     ebp, 1
    xor     r12d, r12d
    mov     eax, -1
    ret

.fo_nothing:
    xor     eax, eax
    ret

; ─── strcmp(rdi=str1, rsi=str2) → eax=0 if equal ────────
strcmp:
.sc_loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .sc_ne
    test    al, al
    jz      .sc_eq
    inc     rdi
    inc     rsi
    jmp     .sc_loop
.sc_eq:
    xor     eax, eax
    ret
.sc_ne:
    mov     eax, 1
    ret

; ─── strncmp(rdi=str1, rsi=str2, ecx=n) → eax=0 if equal ──
strncmp:
    test    ecx, ecx
    jz      .snc_eq
.snc_loop:
    movzx   eax, byte [rdi]
    movzx   edx, byte [rsi]
    cmp     al, dl
    jne     .snc_ne
    test    al, al
    jz      .snc_eq
    inc     rdi
    inc     rsi
    dec     ecx
    jnz     .snc_loop
.snc_eq:
    xor     eax, eax
    ret
.snc_ne:
    mov     eax, 1
    ret

; ─── strlen(rdi=str) → rax=length ───────────────────────
strlen:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; ─── Error helpers ───────────────────────────────────────

; print_error_simple(rdi=message) — "expand: {message}\n" to stderr
print_error_simple:
    push    rbx
    mov     rbx, rdi

    mov     rdi, STDERR
    lea     rsi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all

    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_newline]
    mov     rdx, 1
    call    asm_write_all

    pop     rbx
    ret

; err_msg(rsi=message) — "expand: {message}\n"
err_msg:
    push    rbx
    mov     rbx, rsi

    mov     rdi, STDERR
    lea     rsi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all

    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_newline]
    mov     rdx, 1
    call    asm_write_all

    pop     rbx
    ret

; err_file(rdi=filename, esi=errno) — "expand: {filename}: {strerror}\n"
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
    call    strlen
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
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_newline]
    mov     rdx, 1
    call    asm_write_all

    pop     r13
    pop     rbx
    ret

; err_unrecognized_option(rsi=option_string)
err_unrecognized_option:
    push    rbx
    mov     rbx, rsi

    mov     rdi, STDERR
    lea     rsi, [rel str_unrecognized]
    mov     rdx, str_unrecognized_len
    call    asm_write_all

    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_quote_nl]
    mov     rdx, 2
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all

    pop     rbx
    ret

; err_invalid_option(rsi=option_string) — "expand: invalid option -- 'X'\nTry..."
err_invalid_option:
    push    rbx
    mov     rbx, rsi

    mov     rdi, STDERR
    lea     rsi, [rel str_invalid_opt]
    mov     rdx, str_invalid_opt_len
    call    asm_write_all

    ; The option character (byte at rbx+1)
    mov     rdi, STDERR
    lea     rsi, [rbx + 1]
    mov     rdx, 1
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_quote_nl]
    mov     rdx, 2
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all

    pop     rbx
    ret

; err_invalid_tab(rsi=spec_string) — "expand: tab size contains invalid character(s): 'SPEC'\n"
err_invalid_tab:
    push    rbx
    mov     rbx, rsi

    mov     rdi, STDERR
    lea     rsi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_invalid_tab_msg]
    mov     rdx, str_invalid_tab_msg_len
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_squote]
    mov     rdx, 1
    call    asm_write_all

    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_quote_nl]
    mov     rdx, 2
    call    asm_write_all

    pop     rbx
    ret

; strerror(edi=errno) → rax=string pointer
strerror:
    cmp     edi, 1
    je      .se_eperm
    cmp     edi, 2
    je      .se_enoent
    cmp     edi, 5
    je      .se_eio
    cmp     edi, 9
    je      .se_ebadf
    cmp     edi, 12
    je      .se_enomem
    cmp     edi, 13
    je      .se_eacces
    cmp     edi, 20
    je      .se_enotdir
    cmp     edi, 21
    je      .se_eisdir
    cmp     edi, 22
    je      .se_einval
    cmp     edi, 24
    je      .se_emfile
    cmp     edi, 36
    je      .se_enametoolong
    lea     rax, [rel str_eunknown]
    ret
.se_eperm:
    lea     rax, [rel str_eperm]
    ret
.se_enoent:
    lea     rax, [rel str_enoent]
    ret
.se_eio:
    lea     rax, [rel str_eio]
    ret
.se_ebadf:
    lea     rax, [rel str_ebadf]
    ret
.se_enomem:
    lea     rax, [rel str_enomem]
    ret
.se_eacces:
    lea     rax, [rel str_eacces]
    ret
.se_enotdir:
    lea     rax, [rel str_enotdir]
    ret
.se_eisdir:
    lea     rax, [rel str_eisdir]
    ret
.se_einval:
    lea     rax, [rel str_einval]
    ret
.se_emfile:
    lea     rax, [rel str_emfile]
    ret
.se_enametoolong:
    lea     rax, [rel str_enametoolong]
    ret

; ─── Data Section ────────────────────────────────────────
section .data

align 16
tab_pattern:
    times 16 db 9

align 16
newline_pattern:
    times 16 db 10

align 16
backspace_pattern:
    times 16 db 8

align 16
special_threshold:
    times 16 db 10              ; for psubusb: bytes <= 10 become 0

align 16
space_pattern:
    times 16 db 32

str_prefix:     db "expand: "
str_prefix_len equ $ - str_prefix

str_newline:    db 10
str_colon_space: db ": "

str_help_opt:       db "--help", 0
str_version_opt:    db "--version", 0
str_initial_opt:    db "--initial", 0
str_tabs_eq:        db "--tabs=", 0

str_unrecognized: db "expand: unrecognized option '"
str_unrecognized_len equ $ - str_unrecognized

str_quote_nl:   db "'", 10
str_squote:     db "'"

str_write_error: db "write error", 0

str_try_help: db "Try 'expand --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_invalid_opt: db "expand: invalid option -- '"
str_invalid_opt_len equ $ - str_invalid_opt

str_missing_tab: db "option requires an argument -- 't'", 0

str_zero_tab:    db "tab size cannot be 0", 0
str_not_ascending: db "tab sizes must be ascending", 0
str_too_many_tabs: db "too many tab stops specified", 0

str_invalid_tab_msg: db "tab size contains invalid character(s): "
str_invalid_tab_msg_len equ $ - str_invalid_tab_msg

help_text:
    db "Usage: expand [OPTION]... [FILE]...", 10
    db "Convert tabs in each FILE to spaces, writing to standard output.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -i, --initial    do not convert tabs after non blanks", 10
    db "  -t, --tabs=N     have tabs N characters apart, not 8", 10
    db "  -t, --tabs=LIST  use comma separated list of tab positions.", 10
    db "                     The last specified position can be prefixed with '/'", 10
    db "                     to specify a tab size to use after the last", 10
    db "                     explicitly specified tab stop.  Also a prefix of '+'", 10
    db "                     can be used to align remaining tab stops relative to", 10
    db "                     the last specified tab stop instead of the first column", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
help_text_len equ $ - help_text

version_text:
    db "expand (fcoreutils) 0.1.0", 10
version_text_len equ $ - version_text

str_eperm:          db "Operation not permitted", 0
str_enoent:         db "No such file or directory", 0
str_eio:            db "Input/output error", 0
str_ebadf:          db "Bad file descriptor", 0
str_enomem:         db "Cannot allocate memory", 0
str_eacces:         db "Permission denied", 0
str_enotdir:        db "Not a directory", 0
str_eisdir:         db "Is a directory", 0
str_einval:         db "Invalid argument", 0
str_emfile:         db "Too many open files", 0
str_enametoolong:   db "File name too long", 0
str_eunknown:       db "Unknown error", 0

; ─── BSS Section ─────────────────────────────────────────
section .bss

; Tab configuration
tab_mode:           resd 1          ; 0=uniform, 1=list
uniform_tab:        resq 1          ; uniform tab width (default 8)
num_tab_stops:      resd 1          ; number of explicit tab stops
tab_stops:          resq MAX_TAB_STOPS  ; tab stop positions (1-based)
repeat_interval:    resq 1          ; repeating interval after last stop
repeat_relative:    resb 1          ; 0=/N absolute, 1=+N relative
initial_only:       resb 1          ; -i flag
seen_dashdash:      resb 1
num_files:          resd 1
files:              resq MAX_FILES

; Saved registers for function calls (r8, r9, r10 are caller-saved)
save_r8:            resq 1
save_r9:            resq 1
save_r10:           resq 1
init_done_flag:     resb 1          ; initial_done for -i mode

read_buf:           resb READ_BUF_SIZE
out_buf:            resb OUT_BUF_SIZE_BIG

section .note.GNU-stack noalloc noexec nowrite progbits
