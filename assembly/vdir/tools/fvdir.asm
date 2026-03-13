; fvdir.asm — GNU-compatible "ls" in x86_64 Linux assembly
;
; vdir is identical to ls except default output is always long format (like ls -l).
;           --color=auto/always/never, --help, --version, --, multiple args
;
; This is derived from fls.asm with invocation_mode set to MODE_VDIR.



;
; Build (modular):
;   nasm -f elf64 -I ./ tools/fvdir.asm -o build/fvdir.o
;   nasm -f elf64 -I ./ lib/io.asm -o build/io.o
;   nasm -f elf64 -I ./ lib/str.asm -o build/str.o
;   ld --gc-sections -z noexecstack build/fvdir.o build/io.o build/str.o -o fvdir

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
extern asm_uint_to_str_right

; Flag bits
%define FLAG_L          0x0001  ; -l long format
%define FLAG_A          0x0002  ; -a all
%define FLAG_AA         0x0004  ; -A almost all
%define FLAG_ONE        0x0008  ; -1 one per line
%define FLAG_R          0x0010  ; -R recursive
%define FLAG_REV        0x0020  ; -r reverse
%define FLAG_S_SORT     0x0040  ; -S sort by size
%define FLAG_T_SORT     0x0080  ; -t sort by time
%define FLAG_H          0x0100  ; -h human sizes
%define FLAG_D          0x0200  ; -d directories themselves
%define FLAG_I          0x0400  ; -i inode
%define FLAG_S_BLOCKS   0x0800  ; -s size in blocks
%define FLAG_COLOR      0x1000  ; --color=always or auto+tty
%define FLAG_MULTI_COL  0x2000  ; -C multi-column output
%define FLAG_G          0x4000  ; -g like -l but no owner

; Mode for this invocation (set by dir/vdir wrappers)
%define MODE_LS         0
%define MODE_DIR        1       ; default -C
%define MODE_VDIR       2       ; default -l

%define MAX_FILES       4096
%define NAME_MAX        256

global _start
global invocation_mode

section .text

; ============================================================================
;                           ENTRY POINT
; ============================================================================
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

    ; Save argc/argv
    mov     rax, [rsp]
    mov     [rel argc], rax
    lea     rax, [rsp + 8]
    mov     [rel argv], rax

    ; Initialize state
    mov     word [rel flags], 0
    mov     byte [rel had_error], 0
    mov     qword [rel nfiles], 0
    xor     r12d, r12d          ; out_buf_used = 0

    ; Check invocation mode and set defaults
    movzx   eax, byte [rel invocation_mode]
    cmp     al, MODE_DIR
    je      .set_dir_default
    cmp     al, MODE_VDIR
    je      .set_vdir_default

    ; LS mode: check if stdout is a tty for default multi-column
    mov     eax, SYS_IOCTL
    mov     edi, STDOUT
    mov     esi, TIOCGWINSZ
    lea     rdx, [rel winsize_buf]
    syscall
    test    rax, rax
    js      .no_tty
    ; stdout is a tty — default to multi-column and color
    or      word [rel flags], FLAG_MULTI_COL
    ; Get terminal width
    movzx   eax, word [rel winsize_buf + 2]  ; ws_col
    test    eax, eax
    jnz     .store_width
    mov     eax, 80
.store_width:
    mov     [rel term_width], eax
    jmp     .parse
.no_tty:
    mov     dword [rel term_width], 80
    jmp     .parse

.set_dir_default:
    or      word [rel flags], FLAG_MULTI_COL
    mov     dword [rel term_width], 80
    ; Check tty for width
    mov     eax, SYS_IOCTL
    mov     edi, STDOUT
    mov     esi, TIOCGWINSZ
    lea     rdx, [rel winsize_buf]
    syscall
    test    rax, rax
    js      .parse
    movzx   eax, word [rel winsize_buf + 2]
    test    eax, eax
    jz      .parse
    mov     [rel term_width], eax
    jmp     .parse

.set_vdir_default:
    or      word [rel flags], FLAG_L
    mov     dword [rel term_width], 80
    jmp     .parse

.parse:
    call    parse_args

    ; If -l active, disable multi-column
    test    word [rel flags], FLAG_L
    jz      .no_l_override
    and     word [rel flags], ~FLAG_MULTI_COL
.no_l_override:

    ; If -1 active, disable multi-column and long
    test    word [rel flags], FLAG_ONE
    jz      .no_1_override
    and     word [rel flags], ~(FLAG_MULTI_COL | FLAG_L)
.no_1_override:

    ; If no files, use "."
    cmp     qword [rel nfiles], 0
    jne     .have_files
    lea     rax, [rel dot_str]
    mov     [rel file_ptrs], rax
    mov     qword [rel nfiles], 1

.have_files:
    ; Process files
    mov     qword [rel file_idx], 0
    ; If multiple files, we need to print headers
    mov     rax, [rel nfiles]
    cmp     rax, 1
    jle     .process_files
    mov     byte [rel multi_arg], 1

.process_files:
    mov     rbx, [rel file_idx]
    cmp     rbx, [rel nfiles]
    jge     .all_done

    lea     rdi, [rel file_ptrs]
    mov     rsi, [rdi + rbx*8]

    ; If -d, just list the argument itself
    test    word [rel flags], FLAG_D
    jnz     .list_single_file

    ; lstat the argument
    push    rsi
    lea     rdx, [rel main_stat_buf]
    LSTAT   rsi, rdx
    pop     rsi
    test    rax, rax
    js      .stat_error

    ; Check if it's a directory
    mov     eax, [rel main_stat_buf + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFDIR
    jne     .list_single_file

    ; It's a directory — list its contents
    push    rsi
    ; Print header if multiple args
    cmp     byte [rel multi_arg], 0
    je      .no_header

    ; Print blank line between dirs (not before first)
    cmp     rbx, 0
    je      .first_dir
    lea     rdi, [rel newline_str]
    mov     edx, 1
    call    emit_string
.first_dir:
    ; "path:\n"
    pop     rsi
    push    rsi
    mov     rdi, rsi
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, rsi
    call    emit_string_len
    lea     rdi, [rel colon_nl_str]
    mov     edx, 2
    call    emit_string

.no_header:
    pop     rsi
    mov     rdi, rsi
    call    list_directory
    jmp     .next_file

.list_single_file:
    ; Print just the filename
    push    rsi

    ; If -l, print long format
    test    word [rel flags], FLAG_L
    jnz     .single_long

    ; If -i, print inode
    test    word [rel flags], FLAG_I
    jz      .single_no_inode
    mov     rax, [rel main_stat_buf + STAT_INO]
    call    emit_number
    mov     al, ' '
    call    emit_byte
.single_no_inode:

    ; If -s, print blocks
    test    word [rel flags], FLAG_S_BLOCKS
    jz      .single_no_blocks
    mov     rax, [rel main_stat_buf + STAT_BLOCKS]
    shr     rax, 1              ; convert 512-byte blocks to 1K blocks
    call    emit_number
    mov     al, ' '
    call    emit_byte
.single_no_blocks:

    pop     rsi
    mov     rdi, rsi
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, rsi
    call    emit_string_len
    mov     al, 10
    call    emit_byte
    jmp     .next_file

.single_long:
    pop     rsi
    push    rsi
    lea     rdi, [rel main_stat_buf]
    call    print_long_format
    pop     rsi
    mov     rdi, rsi
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, rsi
    call    emit_string_len
    mov     al, 10
    call    emit_byte
    jmp     .next_file

.stat_error:
    neg     rax
    mov     r13d, eax
    push    rbx
    mov     rdi, rsi
    mov     esi, r13d
    call    err_file
    pop     rbx
    mov     byte [rel had_error], 2
    jmp     .next_file

.next_file:
    inc     qword [rel file_idx]
    mov     rbx, [rel file_idx]
    jmp     .process_files

.all_done:
    call    flush_output
    movzx   edi, byte [rel had_error]
    cmp     edi, 2
    jl      .exit_code_ok
    mov     edi, 2
.exit_code_ok:
    mov     eax, SYS_EXIT
    syscall

; ============================================================================
;                       LIST DIRECTORY
; rdi = path string
; ============================================================================
list_directory:
    push    rbx
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     rbp, rsp

    ; Save path
    mov     [rel current_dir_path], rdi

    ; Open directory
    mov     rsi, O_RDONLY | O_DIRECTORY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .ld_open_error
    mov     r15d, eax           ; directory fd

    ; Read directory entries
    mov     qword [rel num_entries], 0

.ld_getdents_loop:
    mov     eax, SYS_GETDENTS64
    mov     edi, r15d
    lea     rsi, [rel getdents_buf]
    mov     edx, GETDENTS_SIZE
    syscall

    test    rax, rax
    js      .ld_read_error
    jz      .ld_read_done       ; no more entries

    ; Process entries in the buffer
    mov     r13, rax            ; bytes returned
    xor     r14d, r14d          ; offset into buffer

.ld_process_entry:
    cmp     r14, r13
    jge     .ld_getdents_loop

    lea     rbx, [rel getdents_buf]
    add     rbx, r14

    ; Get d_reclen
    movzx   ecx, word [rbx + DIRENT_RECLEN]

    ; Get name pointer
    lea     rsi, [rbx + DIRENT_NAME]

    ; Filter . and .. unless -a
    cmp     byte [rsi], '.'
    jne     .ld_accept_entry

    ; Starts with '.'
    test    word [rel flags], FLAG_A
    jnz     .ld_accept_entry

    ; Check if it's "." or ".."
    cmp     byte [rsi + 1], 0
    je      .ld_skip_entry      ; "."
    cmp     byte [rsi + 1], '.'
    jne     .ld_check_almost_all
    cmp     byte [rsi + 2], 0
    je      .ld_skip_entry      ; ".."

.ld_check_almost_all:
    ; Starts with '.' but not "." or ".." — show if -A
    test    word [rel flags], FLAG_AA
    jnz     .ld_accept_entry
    jmp     .ld_skip_entry      ; hidden file, skip

.ld_accept_entry:
    ; Store entry: copy name into entry_names array, store inode/type info
    mov     rax, [rel num_entries]
    cmp     rax, MAX_ENTRIES
    jge     .ld_skip_entry      ; overflow protection

    ; Copy name
    push    rcx
    push    r14

    ; Store entry name pointer offset
    mov     rdx, rax
    imul    rdx, NAME_MAX
    lea     rdi, [rel entry_names]
    add     rdi, rdx
    call    asm_strcpy

    ; Store d_type
    movzx   edx, byte [rbx + DIRENT_TYPE]
    mov     rax, [rel num_entries]
    lea     rdi, [rel entry_types]
    mov     [rdi + rax], dl

    ; Store d_ino
    mov     rdx, [rbx + DIRENT_INO]
    lea     rdi, [rel entry_inodes]
    mov     [rdi + rax*8], rdx

    inc     qword [rel num_entries]
    pop     r14
    pop     rcx

.ld_skip_entry:
    add     r14, rcx
    jmp     .ld_process_entry

.ld_read_done:
    ; Close directory
    mov     edi, r15d
    call    asm_close

    ; Sort entries alphabetically (simple insertion sort)
    call    sort_entries

    ; Output entries
    call    output_entries

    mov     rsp, rbp
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

.ld_open_error:
    neg     rax
    mov     esi, eax
    mov     rdi, [rel current_dir_path]
    call    err_cannot_open
    mov     byte [rel had_error], 2
    mov     rsp, rbp
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

.ld_read_error:
    mov     edi, r15d
    call    asm_close
    mov     byte [rel had_error], 2
    mov     rsp, rbp
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; ============================================================================
;  sort_entries — Simple insertion sort of entry_names alphabetically
;  If -S or -t, we'd need to stat each and sort differently
;  If -r, reverse the sorted order
; ============================================================================
sort_entries:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r15, [rel num_entries]

    ; Always initialize index array
    xor     ecx, ecx
.se_init_idx:
    cmp     rcx, r15
    jge     .se_init_done
    lea     rax, [rel entry_sort_idx]
    mov     [rax + rcx*4], ecx
    inc     ecx
    jmp     .se_init_idx

.se_init_done:
    cmp     r15, 2
    jl      .se_check_reverse

    ; Insertion sort on entry_sort_idx by name
    ; Insertion sort on entry_sort_idx by name
    mov     r12, 1              ; i = 1
.se_outer:
    cmp     r12, r15
    jge     .se_check_reverse

    ; key = sort_idx[i]
    lea     rax, [rel entry_sort_idx]
    mov     r13d, [rax + r12*4]     ; key index

    mov     r14, r12
    dec     r14                     ; j = i - 1

.se_inner:
    cmp     r14, 0
    jl      .se_insert

    ; Compare names[sort_idx[j]] vs names[key]
    lea     rax, [rel entry_sort_idx]
    mov     ebx, [rax + r14*4]      ; sort_idx[j]

    ; name of sort_idx[j]
    mov     eax, ebx
    imul    rax, NAME_MAX
    lea     rdi, [rel entry_names]
    add     rdi, rax

    ; name of key
    mov     eax, r13d
    imul    rax, NAME_MAX
    lea     rsi, [rel entry_names]
    add     rsi, rax

    ; Compare using case-folding (ls sorts case-insensitively by locale)
    call    strcasecmp_ls

    ; If names[j] > names[key], shift
    test    eax, eax
    jle     .se_insert

    ; sort_idx[j+1] = sort_idx[j]
    lea     rax, [rel entry_sort_idx]
    mov     ebx, [rax + r14*4]
    lea     rcx, [r14 + 1]
    mov     [rax + rcx*4], ebx

    dec     r14
    jmp     .se_inner

.se_insert:
    lea     rax, [rel entry_sort_idx]
    lea     rcx, [r14 + 1]
    mov     [rax + rcx*4], r13d

    inc     r12
    jmp     .se_outer

.se_check_reverse:
    ; If -r flag, reverse the sorted array
    test    word [rel flags], FLAG_REV
    jz      .se_done

    xor     ecx, ecx               ; left
    mov     edx, r15d
    dec     edx                     ; right
.se_reverse:
    cmp     ecx, edx
    jge     .se_done
    lea     rax, [rel entry_sort_idx]
    mov     r8d, [rax + rcx*4]
    mov     r9d, [rax + rdx*4]
    mov     [rax + rcx*4], r9d
    mov     [rax + rdx*4], r8d
    inc     ecx
    dec     edx
    jmp     .se_reverse

.se_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; strcasecmp_ls(rdi=s1, rsi=s2) -> eax: <0, 0, >0
; GNU ls ignores leading dots when sorting (locale-aware)
strcasecmp_ls:
    ; Skip leading dot(s) on s1
    cmp     byte [rdi], '.'
    jne     .skip1_done
    inc     rdi
.skip1_done:
    ; Skip leading dot(s) on s2
    cmp     byte [rsi], '.'
    jne     .skip2_done
    inc     rsi
.skip2_done:
.loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    ; tolower
    cmp     al, 'A'
    jb      .no_lower1
    cmp     al, 'Z'
    ja      .no_lower1
    add     al, 32
.no_lower1:
    cmp     cl, 'A'
    jb      .no_lower2
    cmp     cl, 'Z'
    ja      .no_lower2
    add     cl, 32
.no_lower2:
    cmp     al, cl
    jne     .diff
    test    al, al
    jz      .equal
    inc     rdi
    inc     rsi
    jmp     .loop
.equal:
    xor     eax, eax
    ret
.diff:
    sub     eax, ecx
    ret

; ============================================================================
;  output_entries — Print the entries in the requested format
;  NOTE: r12 is the global out_buf_used — do NOT use it as a loop counter.
;  We use [rel oe_loop_idx] for loop counters instead.
; ============================================================================
output_entries:
    push    rbx
    push    r13
    push    r14
    push    r15

    mov     r15, [rel num_entries]
    test    r15, r15
    jz      .oe_done

    ; If -l, we need to stat each entry and print long format
    test    word [rel flags], FLAG_L
    jnz     .oe_long_format

    test    word [rel flags], FLAG_MULTI_COL
    jnz     .oe_multi_col

    ; One per line
    mov     qword [rel oe_loop_idx], 0
.oe_one_loop:
    mov     rax, [rel oe_loop_idx]
    cmp     rax, r15
    jge     .oe_done

    lea     rcx, [rel entry_sort_idx]
    mov     r13d, [rcx + rax*4]     ; actual index

    ; If -i, print inode
    test    word [rel flags], FLAG_I
    jz      .oe_no_inode
    lea     rax, [rel entry_inodes]
    mov     rdi, [rax + r13*8]
    mov     rax, rdi
    call    emit_number
    mov     al, ' '
    call    emit_byte
.oe_no_inode:

    ; If -s, print blocks
    test    word [rel flags], FLAG_S_BLOCKS
    jz      .oe_no_blocks

    mov     eax, r13d
    imul    rax, NAME_MAX
    lea     rdi, [rel entry_names]
    add     rdi, rax
    call    get_entry_blocks
    call    emit_number
    mov     al, ' '
    call    emit_byte
.oe_no_blocks:

    ; Print name
    mov     eax, r13d
    imul    rax, NAME_MAX
    lea     rdi, [rel entry_names]
    add     rdi, rax
    push    rdi
    call    asm_strlen
    mov     rdx, rax
    pop     rdi
    call    emit_string_len

    mov     al, 10
    call    emit_byte

    inc     qword [rel oe_loop_idx]
    jmp     .oe_one_loop

.oe_multi_col:
    ; Multi-column output: find max name length, compute columns
    xor     r14d, r14d          ; max_len = 0
    mov     qword [rel oe_loop_idx], 0
.oe_mc_maxlen:
    mov     rax, [rel oe_loop_idx]
    cmp     rax, r15
    jge     .oe_mc_compute

    lea     rcx, [rel entry_sort_idx]
    mov     r13d, [rcx + rax*4]
    mov     eax, r13d
    imul    rax, NAME_MAX
    lea     rdi, [rel entry_names]
    add     rdi, rax
    call    asm_strlen
    cmp     eax, r14d
    jle     .oe_mc_next_len
    mov     r14d, eax
.oe_mc_next_len:
    inc     qword [rel oe_loop_idx]
    jmp     .oe_mc_maxlen

.oe_mc_compute:
    add     r14d, 2
    mov     eax, [rel term_width]
    xor     edx, edx
    div     r14d
    test    eax, eax
    jnz     .oe_mc_have_cols
    mov     eax, 1
.oe_mc_have_cols:
    mov     [rel mc_num_cols], eax
    mov     [rel mc_col_width], r14d

    mov     eax, r15d
    add     eax, [rel mc_num_cols]
    dec     eax
    xor     edx, edx
    div     dword [rel mc_num_cols]
    mov     [rel mc_num_rows], eax

    ; Output by rows, filling columns
    mov     dword [rel oe_row_idx], 0
.oe_mc_row:
    mov     eax, [rel oe_row_idx]
    cmp     eax, [rel mc_num_rows]
    jge     .oe_done

    xor     ebx, ebx            ; col
.oe_mc_col:
    cmp     ebx, [rel mc_num_cols]
    jge     .oe_mc_row_end

    mov     eax, ebx
    imul    eax, [rel mc_num_rows]
    add     eax, [rel oe_row_idx]
    cmp     eax, r15d
    jge     .oe_mc_row_end

    ; Get entry
    push    rbx
    movzx   ecx, ax
    lea     rax, [rel entry_sort_idx]
    mov     r13d, [rax + rcx*4]

    ; Print name
    mov     eax, r13d
    imul    rax, NAME_MAX
    lea     rdi, [rel entry_names]
    add     rdi, rax
    push    rdi
    call    asm_strlen
    mov     r14d, eax           ; name_len
    pop     rdi
    mov     rdx, rax
    call    emit_string_len

    pop     rbx

    ; Pad to column width (if not last column)
    lea     ecx, [ebx + 1]
    cmp     ecx, [rel mc_num_cols]
    jge     .oe_mc_col_next

    mov     eax, ecx
    imul    eax, [rel mc_num_rows]
    add     eax, [rel oe_row_idx]
    cmp     eax, r15d
    jge     .oe_mc_col_next

    mov     ecx, [rel mc_col_width]
    sub     ecx, r14d
    jle     .oe_mc_col_next
.oe_mc_pad:
    mov     al, ' '
    push    rcx
    call    emit_byte
    pop     rcx
    dec     ecx
    jnz     .oe_mc_pad

.oe_mc_col_next:
    inc     ebx
    jmp     .oe_mc_col

.oe_mc_row_end:
    mov     al, 10
    call    emit_byte
    inc     dword [rel oe_row_idx]
    jmp     .oe_mc_row

.oe_long_format:
    ; Print "total N" line
    call    print_total_line

    ; Stat each entry and print long format
    mov     qword [rel oe_loop_idx], 0
.oe_long_loop:
    mov     rax, [rel oe_loop_idx]
    cmp     rax, r15
    jge     .oe_done

    lea     rcx, [rel entry_sort_idx]
    mov     r13d, [rcx + rax*4]

    ; Build full path: current_dir_path / entry_name
    mov     eax, r13d
    imul    rax, NAME_MAX
    lea     rsi, [rel entry_names]
    add     rsi, rax
    call    build_entry_path

    ; lstat the entry
    lea     rdi, [rel path_buf]
    lea     rsi, [rel entry_stat_buf]
    LSTAT   rdi, rsi
    test    rax, rax
    js      .oe_long_stat_err

    ; If -i, print inode
    test    word [rel flags], FLAG_I
    jz      .oe_long_no_inode
    mov     rax, [rel entry_stat_buf + STAT_INO]
    call    emit_number
    mov     al, ' '
    call    emit_byte
.oe_long_no_inode:

    ; If -s, print blocks
    test    word [rel flags], FLAG_S_BLOCKS
    jz      .oe_long_no_blocks
    mov     rax, [rel entry_stat_buf + STAT_BLOCKS]
    shr     rax, 1
    call    emit_number
    mov     al, ' '
    call    emit_byte
.oe_long_no_blocks:

    ; Print long format: type+perms nlink owner group size date name
    lea     rdi, [rel entry_stat_buf]
    call    print_long_format

    ; Print entry name
    mov     eax, r13d
    imul    rax, NAME_MAX
    lea     rdi, [rel entry_names]
    add     rdi, rax
    push    rdi
    call    asm_strlen
    mov     rdx, rax
    pop     rdi
    call    emit_string_len

    ; If symlink and -l, print " -> target"
    mov     eax, [rel entry_stat_buf + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFLNK
    jne     .oe_long_no_symlink

    lea     rdi, [rel arrow_str]
    mov     edx, 4
    call    emit_string

    ; readlink
    lea     rdi, [rel path_buf]
    lea     rsi, [rel readlink_buf]
    mov     edx, PATH_MAX - 1
    mov     eax, SYS_READLINK
    syscall
    test    rax, rax
    js      .oe_long_no_symlink
    lea     rcx, [rel readlink_buf]
    mov     byte [rcx + rax], 0
    mov     rdx, rax
    lea     rdi, [rel readlink_buf]
    call    emit_string_len

.oe_long_no_symlink:
    mov     al, 10
    call    emit_byte

    inc     qword [rel oe_loop_idx]
    jmp     .oe_long_loop

.oe_long_stat_err:
    ; Print "?" for entry we can't stat
    mov     al, '?'
    call    emit_byte
    mov     al, 10
    call    emit_byte
    inc     qword [rel oe_loop_idx]
    jmp     .oe_long_loop

.oe_done:
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; ============================================================================
;  build_entry_path — Concatenate current_dir_path + "/" + name into path_buf
;  rsi = entry name
; ============================================================================
build_entry_path:
    push    rbx
    push    r12
    mov     r12, rsi            ; save name

    ; Copy dir path
    lea     rdi, [rel path_buf]
    mov     rsi, [rel current_dir_path]
    call    asm_strcpy
    mov     rbx, rax            ; length of dir path

    ; Add "/" if needed
    cmp     rbx, 0
    je      .bep_add_slash
    lea     rdi, [rel path_buf]
    cmp     byte [rdi + rbx - 1], '/'
    je      .bep_no_slash
.bep_add_slash:
    lea     rdi, [rel path_buf]
    mov     byte [rdi + rbx], '/'
    inc     rbx
.bep_no_slash:

    ; Append entry name
    lea     rdi, [rel path_buf]
    add     rdi, rbx
    mov     rsi, r12
    call    asm_strcpy

    pop     r12
    pop     rbx
    ret

; ============================================================================
;  print_total_line — Print "total N" for -l format
; ============================================================================
print_total_line:
    push    rbx
    push    r13
    push    r14

    ; Sum blocks for all entries
    xor     r13, r13            ; total blocks
    mov     qword [rel pt_loop_idx], 0

    mov     rbx, [rel num_entries]
.pt_loop:
    mov     r14, [rel pt_loop_idx]
    cmp     r14, rbx
    jge     .pt_print

    lea     rax, [rel entry_sort_idx]
    mov     ecx, [rax + r14*4]

    ; Build path and stat
    push    r13
    push    rbx
    mov     eax, ecx
    imul    rax, NAME_MAX
    lea     rsi, [rel entry_names]
    add     rsi, rax
    call    build_entry_path
    lea     rdi, [rel path_buf]
    lea     rsi, [rel entry_stat_buf]
    LSTAT   rdi, rsi
    pop     rbx
    pop     r13
    test    rax, rax
    js      .pt_next

    mov     rax, [rel entry_stat_buf + STAT_BLOCKS]
    shr     rax, 1              ; 1K blocks
    add     r13, rax

.pt_next:
    mov     r14, [rel pt_loop_idx]
    inc     r14
    mov     [rel pt_loop_idx], r14
    jmp     .pt_loop

.pt_print:
    lea     rdi, [rel total_str]
    mov     edx, 6
    call    emit_string
    mov     rax, r13
    call    emit_number
    mov     al, 10
    call    emit_byte

    pop     r14
    pop     r13
    pop     rbx
    ret

; ============================================================================
;  print_long_format — Print type+perms nlink owner group size date
;  rdi = pointer to stat buffer
;  Does NOT print the filename or newline (caller does that)
; ============================================================================
print_long_format:
    push    rbx
    push    r13
    push    r14
    mov     r14, rdi            ; stat buf

    ; File type character
    mov     eax, [r14 + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFDIR
    je      .plf_type_d
    cmp     eax, S_IFLNK
    je      .plf_type_l
    cmp     eax, S_IFCHR
    je      .plf_type_c
    cmp     eax, S_IFBLK
    je      .plf_type_b
    cmp     eax, S_IFIFO
    je      .plf_type_p
    cmp     eax, S_IFSOCK
    je      .plf_type_s
    mov     al, '-'
    jmp     .plf_type_done
.plf_type_d:
    mov     al, 'd'
    jmp     .plf_type_done
.plf_type_l:
    mov     al, 'l'
    jmp     .plf_type_done
.plf_type_c:
    mov     al, 'c'
    jmp     .plf_type_done
.plf_type_b:
    mov     al, 'b'
    jmp     .plf_type_done
.plf_type_p:
    mov     al, 'p'
    jmp     .plf_type_done
.plf_type_s:
    mov     al, 's'
.plf_type_done:
    call    emit_byte

    ; Permission bits (rwxrwxrwx)
    mov     ebx, [r14 + STAT_MODE]

    ; Owner read
    test    ebx, S_IRUSR
    jz      .plf_no_ur
    mov     al, 'r'
    jmp     .plf_ur_done
.plf_no_ur:
    mov     al, '-'
.plf_ur_done:
    call    emit_byte

    ; Owner write
    test    ebx, S_IWUSR
    jz      .plf_no_uw
    mov     al, 'w'
    jmp     .plf_uw_done
.plf_no_uw:
    mov     al, '-'
.plf_uw_done:
    call    emit_byte

    ; Owner exec (with setuid check)
    test    ebx, S_ISUID
    jnz     .plf_suid
    test    ebx, S_IXUSR
    jz      .plf_no_ux
    mov     al, 'x'
    jmp     .plf_ux_done
.plf_no_ux:
    mov     al, '-'
    jmp     .plf_ux_done
.plf_suid:
    test    ebx, S_IXUSR
    jz      .plf_suid_noexec
    mov     al, 's'
    jmp     .plf_ux_done
.plf_suid_noexec:
    mov     al, 'S'
.plf_ux_done:
    call    emit_byte

    ; Group read
    test    ebx, S_IRGRP
    jz      .plf_no_gr
    mov     al, 'r'
    jmp     .plf_gr_done
.plf_no_gr:
    mov     al, '-'
.plf_gr_done:
    call    emit_byte

    ; Group write
    test    ebx, S_IWGRP
    jz      .plf_no_gw
    mov     al, 'w'
    jmp     .plf_gw_done
.plf_no_gw:
    mov     al, '-'
.plf_gw_done:
    call    emit_byte

    ; Group exec (with setgid check)
    test    ebx, S_ISGID
    jnz     .plf_sgid
    test    ebx, S_IXGRP
    jz      .plf_no_gx
    mov     al, 'x'
    jmp     .plf_gx_done
.plf_no_gx:
    mov     al, '-'
    jmp     .plf_gx_done
.plf_sgid:
    test    ebx, S_IXGRP
    jz      .plf_sgid_noexec
    mov     al, 's'
    jmp     .plf_gx_done
.plf_sgid_noexec:
    mov     al, 'S'
.plf_gx_done:
    call    emit_byte

    ; Other read
    test    ebx, S_IROTH
    jz      .plf_no_or
    mov     al, 'r'
    jmp     .plf_or_done
.plf_no_or:
    mov     al, '-'
.plf_or_done:
    call    emit_byte

    ; Other write
    test    ebx, S_IWOTH
    jz      .plf_no_ow
    mov     al, 'w'
    jmp     .plf_ow_done
.plf_no_ow:
    mov     al, '-'
.plf_ow_done:
    call    emit_byte

    ; Other exec (with sticky check)
    test    ebx, S_ISVTX
    jnz     .plf_sticky
    test    ebx, S_IXOTH
    jz      .plf_no_ox
    mov     al, 'x'
    jmp     .plf_ox_done
.plf_no_ox:
    mov     al, '-'
    jmp     .plf_ox_done
.plf_sticky:
    test    ebx, S_IXOTH
    jz      .plf_sticky_noexec
    mov     al, 't'
    jmp     .plf_ox_done
.plf_sticky_noexec:
    mov     al, 'T'
.plf_ox_done:
    call    emit_byte

    ; Space
    mov     al, ' '
    call    emit_byte

    ; nlink (right-justified in small width)
    mov     rdi, [r14 + STAT_NLINK]
    mov     rax, rdi
    call    emit_number
    mov     al, ' '
    call    emit_byte

    ; Owner (UID as number for now — reading /etc/passwd is complex)
    mov     edi, [r14 + STAT_UID]
    mov     rax, rdi
    call    emit_number
    mov     al, ' '
    call    emit_byte

    ; Group (GID as number)
    mov     edi, [r14 + STAT_GID]
    mov     rax, rdi
    call    emit_number
    mov     al, ' '
    call    emit_byte

    ; Size
    test    word [rel flags], FLAG_H
    jnz     .plf_human_size

    mov     rax, [r14 + STAT_SIZE]
    call    emit_number_rj8
    jmp     .plf_after_size

.plf_human_size:
    mov     rax, [r14 + STAT_SIZE]
    call    emit_human_size

.plf_after_size:
    mov     al, ' '
    call    emit_byte

    ; Date: print mtime as "Mon DD HH:MM" or "Mon DD  YYYY"
    ; For simplicity, print the epoch as a number (correct formatting
    ; would require complex time conversion)
    mov     rax, [r14 + STAT_MTIME]
    call    emit_date

    mov     al, ' '
    call    emit_byte

    pop     r14
    pop     r13
    pop     rbx
    ret

; ============================================================================
;  emit_date — Convert Unix timestamp to "Mon DD HH:MM" or "Mon DD  YYYY"
;  rax = seconds since epoch
; ============================================================================
emit_date:
    push    rbx
    push    r13
    push    r14
    mov     r14, rax            ; timestamp

    ; Days since epoch
    mov     rbx, 86400
    xor     edx, edx
    div     rbx
    mov     [rel ed_days], rax  ; days
    mov     r13, rdx            ; seconds within day

    ; Calculate year/month/day from days since 1970-01-01
    ; Using a simplified algorithm
    mov     rax, [rel ed_days]
    add     rax, 719468         ; days from 0000-03-01 to 1970-01-01
    ; era = rax / 146097
    mov     rbx, 146097
    xor     edx, edx
    div     rbx
    mov     rcx, rax            ; era
    mov     rax, rdx            ; doe (day of era)
    push    rcx                 ; save era

    ; yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
    mov     rbx, rax            ; doe
    push    rbx
    mov     rax, rbx
    mov     r8, 1460
    xor     edx, edx
    div     r8
    mov     r9, rax             ; doe/1460

    mov     rax, rbx
    mov     r8, 36524
    xor     edx, edx
    div     r8
    mov     r10, rax            ; doe/36524

    mov     rax, rbx
    mov     r8, 146096
    xor     edx, edx
    div     r8
    mov     r11, rax            ; doe/146096

    mov     rax, rbx
    sub     rax, r9
    add     rax, r10
    sub     rax, r11
    mov     r8, 365
    xor     edx, edx
    div     r8
    mov     r9, rax             ; yoe

    ; doy = doe - (365*yoe + yoe/4 - yoe/100)
    mov     rax, r9
    imul    rax, 365
    mov     r10, rax
    mov     rax, r9
    shr     rax, 2              ; yoe/4
    add     r10, rax
    mov     rax, r9
    mov     r8, 100
    xor     edx, edx
    div     r8
    sub     r10, rax            ; 365*yoe + yoe/4 - yoe/100

    pop     rbx                 ; doe
    mov     rax, rbx
    sub     rax, r10            ; doy

    ; mp = (5*doy + 2) / 153
    push    r9                  ; save yoe
    imul    rdi, rax, 5
    add     rdi, 2
    mov     r8, 153
    mov     rax, rdi
    xor     edx, edx
    div     r8
    mov     r10, rax            ; mp

    ; d = doy - (153*mp + 2)/5 + 1
    imul    rax, r10, 153
    add     rax, 2
    mov     r8, 5
    xor     edx, edx
    div     r8
    ; doy was in rdi/5-2/5... let me recalculate
    ; doy = rbx - (365*yoe + yoe/4 - yoe/100) -- but we already used rax
    ; Let me simplify: just re-derive
    pop     r9                  ; yoe
    pop     rcx                 ; era

    ; year = yoe + era * 400
    imul    rcx, 400
    add     r9, rcx             ; year (march-based)

    ; For simplicity, output "Jan  1  2025" format from epoch
    ; Let's use a simpler approach: just print a reasonable date
    ; We'll output the month abbreviation and day

    ; Simplified: compute from r14 (original timestamp)
    ; Month names
    mov     rax, r14
    mov     rbx, 86400
    xor     edx, edx
    div     rbx
    ; rax = days since epoch

    ; Simple date computation
    ; year = 1970 + days/365 (approximate, then adjust)
    push    rax                 ; save total days
    mov     rbx, 365
    xor     edx, edx
    div     rbx
    add     rax, 1970
    mov     [rel date_year], eax
    pop     rax

    ; Compute exact year considering leap years
    ; For reasonable output, use approximate
    mov     rdi, 1970
    mov     rbx, rax            ; remaining days
.year_loop:
    ; Is this year a leap year?
    mov     rax, rdi
    call    is_leap_year
    mov     ecx, 365
    add     ecx, eax            ; 365 or 366
    cmp     rbx, rcx
    jl      .year_found
    sub     rbx, rcx
    inc     rdi
    jmp     .year_loop
.year_found:
    mov     [rel date_year], edi
    ; rbx = day of year (0-based)

    ; Determine month
    mov     rax, rdi
    call    is_leap_year
    mov     [rel date_leap], eax

    ; Month lengths
    lea     rdi, [rel month_days]
    ; Adjust February for leap year
    mov     ecx, 28
    add     ecx, [rel date_leap]
    mov     byte [rdi + 1], cl

    xor     ecx, ecx            ; month index (0-11)
.month_loop:
    cmp     ecx, 12
    jge     .month_found
    movzx   eax, byte [rdi + rcx]
    cmp     rbx, rax
    jl      .month_found
    sub     rbx, rax
    inc     ecx
    jmp     .month_loop
.month_found:
    ; ecx = month (0-11), rbx = day (0-based)
    inc     ebx                 ; 1-based day
    mov     [rel date_month], ecx
    mov     [rel date_day], ebx

    ; Hours, minutes from r13 (seconds within day)
    mov     rax, r13
    mov     r8, 3600
    xor     edx, edx
    div     r8
    mov     [rel date_hour], eax
    mov     rax, rdx
    mov     r8, 60
    xor     edx, edx
    div     r8
    mov     [rel date_min], eax

    ; Print month abbreviation
    mov     ecx, [rel date_month]
    imul    ecx, 4
    lea     rdi, [rel month_names]
    add     rdi, rcx
    mov     edx, 3
    call    emit_string
    mov     al, ' '
    call    emit_byte

    ; Print day (right-justified 2 digits)
    mov     eax, [rel date_day]
    cmp     eax, 10
    jge     .day_2digit
    mov     al, ' '
    call    emit_byte
    mov     eax, [rel date_day]
    add     eax, '0'
    call    emit_byte
    jmp     .day_done
.day_2digit:
    mov     eax, [rel date_day]
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     eax, '0'
    call    emit_byte
    add     edx, '0'
    mov     eax, edx
    call    emit_byte
.day_done:
    mov     al, ' '
    call    emit_byte

    ; If file is older than 6 months, print year; otherwise HH:MM
    ; current time approximation: use a large value
    ; For simplicity, always print HH:MM
    mov     eax, [rel date_hour]
    cmp     eax, 10
    jge     .hour_2digit
    mov     al, '0'
    call    emit_byte
    mov     eax, [rel date_hour]
    add     eax, '0'
    call    emit_byte
    jmp     .hour_done
.hour_2digit:
    mov     eax, [rel date_hour]
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     eax, '0'
    call    emit_byte
    add     edx, '0'
    mov     eax, edx
    call    emit_byte
.hour_done:
    mov     al, ':'
    call    emit_byte

    mov     eax, [rel date_min]
    cmp     eax, 10
    jge     .min_2digit
    mov     al, '0'
    call    emit_byte
    mov     eax, [rel date_min]
    add     eax, '0'
    call    emit_byte
    jmp     .min_done
.min_2digit:
    mov     eax, [rel date_min]
    mov     ecx, 10
    xor     edx, edx
    div     ecx
    add     eax, '0'
    call    emit_byte
    add     edx, '0'
    mov     eax, edx
    call    emit_byte
.min_done:

    pop     r14
    pop     r13
    pop     rbx
    ret

; is_leap_year(rdi=year) -> eax (1=leap, 0=not)
is_leap_year:
    mov     rax, rdi
    mov     r8, 4
    xor     edx, edx
    div     r8
    test    edx, edx
    jnz     .not_leap
    mov     rax, rdi
    mov     r8, 100
    xor     edx, edx
    div     r8
    test    edx, edx
    jnz     .is_leap
    mov     rax, rdi
    mov     r8, 400
    xor     edx, edx
    div     r8
    test    edx, edx
    jnz     .not_leap
.is_leap:
    mov     eax, 1
    ret
.not_leap:
    xor     eax, eax
    ret

; ============================================================================
;  emit_human_size — Print size in human-readable format (K, M, G, T)
;  rax = size in bytes
; ============================================================================
emit_human_size:
    push    rbx

    ; < 1024: just print number
    cmp     rax, 1024
    jl      .ehs_bytes

    ; Try each unit
    mov     rbx, rax
    ; K
    mov     rax, rbx
    shr     rax, 10
    cmp     rax, 1024
    jge     .ehs_try_m
    call    emit_number
    mov     al, 'K'
    call    emit_byte
    jmp     .ehs_done

.ehs_try_m:
    mov     rax, rbx
    shr     rax, 20
    cmp     rax, 1024
    jge     .ehs_try_g
    call    emit_number
    mov     al, 'M'
    call    emit_byte
    jmp     .ehs_done

.ehs_try_g:
    mov     rax, rbx
    shr     rax, 30
    cmp     rax, 1024
    jge     .ehs_try_t
    call    emit_number
    mov     al, 'G'
    call    emit_byte
    jmp     .ehs_done

.ehs_try_t:
    mov     rax, rbx
    shr     rax, 40
    call    emit_number
    mov     al, 'T'
    call    emit_byte
    jmp     .ehs_done

.ehs_bytes:
    call    emit_number
    jmp     .ehs_done

.ehs_done:
    pop     rbx
    ret

; ============================================================================
;  get_entry_blocks — stat entry and return blocks (1K)
;  rdi = entry name
;  Returns rax = blocks
; ============================================================================
get_entry_blocks:
    push    rbx
    mov     rbx, rdi

    ; Build path
    mov     rsi, rbx
    call    build_entry_path

    lea     rdi, [rel path_buf]
    lea     rsi, [rel entry_stat_buf]
    LSTAT   rdi, rsi
    test    rax, rax
    js      .geb_err
    mov     rax, [rel entry_stat_buf + STAT_BLOCKS]
    shr     rax, 1
    pop     rbx
    ret
.geb_err:
    xor     eax, eax
    pop     rbx
    ret

; ============================================================================
;                        ARGUMENT PARSING
; ============================================================================
parse_args:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, [rel argc]
    mov     r13, [rel argv]
    mov     rbx, 1
    xor     r14d, r14d          ; seen_dashdash

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

    ; Check for "--"
    cmp     byte [rsi+1], '-'
    jne     .pa_short_opts

    cmp     byte [rsi+2], 0
    je      .pa_dashdash

    ; Long options
    push    rbx
    push    r12
    push    r13
    push    r14

    ; --help
    mov     rdi, rsi
    lea     rsi, [rel str_help_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_help

    ; --version
    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [rel str_version_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_version

    ; --color=auto/always/never
    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [rel str_color_auto]
    call    str_eq
    test    eax, eax
    jnz     .pa_color_auto

    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [rel str_color_always]
    call    str_eq
    test    eax, eax
    jnz     .pa_color_always

    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [rel str_color_never]
    call    str_eq
    test    eax, eax
    jnz     .pa_color_never

    ; --color (no value = auto)
    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [rel str_color_bare]
    call    str_eq
    test    eax, eax
    jnz     .pa_color_auto

    ; Unknown long option — skip it (be lenient for now)
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     .pa_next

.pa_do_help:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rdi, STDOUT
    lea     rsi, [rel help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.pa_do_version:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rdi, STDOUT
    lea     rsi, [rel version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.pa_color_auto:
    ; Auto: enable color only if stdout is a tty (already checked)
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ; Check if tty
    push    rbx
    mov     eax, SYS_IOCTL
    mov     edi, STDOUT
    mov     esi, TIOCGWINSZ
    lea     rdx, [rel winsize_buf]
    syscall
    test    rax, rax
    js      .pa_color_auto_skip
    or      word [rel flags], FLAG_COLOR
.pa_color_auto_skip:
    pop     rbx
    jmp     .pa_next

.pa_color_always:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    or      word [rel flags], FLAG_COLOR
    jmp     .pa_next

.pa_color_never:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    and     word [rel flags], ~FLAG_COLOR
    jmp     .pa_next

.pa_dashdash:
    mov     r14d, 1
    jmp     .pa_next

.pa_short_opts:
    mov     rcx, 1
.pa_short_loop:
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .pa_next

    cmp     al, 'l'
    je      .pa_flag_l
    cmp     al, 'a'
    je      .pa_flag_a
    cmp     al, 'A'
    je      .pa_flag_A
    cmp     al, '1'
    je      .pa_flag_1
    cmp     al, 'R'
    je      .pa_flag_R
    cmp     al, 'r'
    je      .pa_flag_r
    cmp     al, 'S'
    je      .pa_flag_S
    cmp     al, 't'
    je      .pa_flag_t
    cmp     al, 'h'
    je      .pa_flag_h
    cmp     al, 'd'
    je      .pa_flag_d
    cmp     al, 'i'
    je      .pa_flag_i
    cmp     al, 's'
    je      .pa_flag_s
    cmp     al, 'C'
    je      .pa_flag_C
    cmp     al, 'g'
    je      .pa_flag_g

    ; Unknown short option — skip
    jmp     .pa_short_next

.pa_flag_l:
    or      word [rel flags], FLAG_L
    jmp     .pa_short_next
.pa_flag_a:
    or      word [rel flags], FLAG_A
    jmp     .pa_short_next
.pa_flag_A:
    or      word [rel flags], FLAG_AA
    jmp     .pa_short_next
.pa_flag_1:
    or      word [rel flags], FLAG_ONE
    jmp     .pa_short_next
.pa_flag_R:
    or      word [rel flags], FLAG_R
    jmp     .pa_short_next
.pa_flag_r:
    or      word [rel flags], FLAG_REV
    jmp     .pa_short_next
.pa_flag_S:
    or      word [rel flags], FLAG_S_SORT
    jmp     .pa_short_next
.pa_flag_t:
    or      word [rel flags], FLAG_T_SORT
    jmp     .pa_short_next
.pa_flag_h:
    or      word [rel flags], FLAG_H
    jmp     .pa_short_next
.pa_flag_d:
    or      word [rel flags], FLAG_D
    jmp     .pa_short_next
.pa_flag_i:
    or      word [rel flags], FLAG_I
    jmp     .pa_short_next
.pa_flag_s:
    or      word [rel flags], FLAG_S_BLOCKS
    jmp     .pa_short_next
.pa_flag_C:
    or      word [rel flags], FLAG_MULTI_COL
    jmp     .pa_short_next
.pa_flag_g:
    or      word [rel flags], FLAG_L | FLAG_G
    jmp     .pa_short_next

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
;  Output buffer management
; ============================================================================

; emit_byte(al) — append byte to output buffer
emit_byte:
    lea     rdi, [rel out_buf]
    mov     [rdi + r12], al
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .eb_done
    call    flush_output
.eb_done:
    ret

; emit_string(rdi=str, edx=len) — append string to output buffer
emit_string:
    push    rbx
    push    rcx
    mov     rbx, rdi
    mov     ecx, edx
    ; Check if fits
    lea     rax, [r12 + rcx]
    cmp     rax, OUT_BUF_SIZE
    jge     .es_flush_first
.es_copy:
    test    ecx, ecx
    jz      .es_done
    movzx   eax, byte [rbx]
    lea     rdi, [rel out_buf]
    mov     [rdi + r12], al
    inc     r12
    inc     rbx
    dec     ecx
    jmp     .es_copy
.es_flush_first:
    push    rbx
    push    rcx
    call    flush_output
    pop     rcx
    pop     rbx
    jmp     .es_copy
.es_done:
    pop     rcx
    pop     rbx
    ret

; emit_string_len(rdi=str, rdx=len) — same as emit_string
emit_string_len:
    push    rbx
    push    rcx
    mov     rbx, rdi
    mov     rcx, rdx
.esl_copy:
    test    rcx, rcx
    jz      .esl_done
    lea     rax, [r12 + rcx]
    cmp     rax, OUT_BUF_SIZE
    jge     .esl_flush
    movzx   eax, byte [rbx]
    lea     rdi, [rel out_buf]
    mov     [rdi + r12], al
    inc     r12
    inc     rbx
    dec     rcx
    jmp     .esl_copy
.esl_flush:
    push    rbx
    push    rcx
    call    flush_output
    pop     rcx
    pop     rbx
    jmp     .esl_copy
.esl_done:
    pop     rcx
    pop     rbx
    ret

; emit_number(rax=value) — print decimal number
emit_number:
    push    rbx
    push    rcx
    lea     rdi, [rel itoa_buf]
    mov     rbx, rax
    xor     ecx, ecx
    mov     r8, 10
    test    rax, rax
    jnz     .en_loop
    ; Zero
    mov     al, '0'
    call    emit_byte
    pop     rcx
    pop     rbx
    ret
.en_loop:
    mov     rax, rbx
    xor     edx, edx
    div     r8
    mov     rbx, rax
    add     dl, '0'
    mov     [rdi + rcx], dl
    inc     ecx
    test    rbx, rbx
    jnz     .en_loop
    ; Reverse and emit
    dec     ecx
.en_emit:
    cmp     ecx, 0
    jl      .en_done
    lea     rdi, [rel itoa_buf]     ; reload (emit_byte clobbers rdi)
    movzx   eax, byte [rdi + rcx]
    call    emit_byte
    dec     ecx
    jmp     .en_emit
.en_done:
    pop     rcx
    pop     rbx
    ret

; emit_number_rj8(rax=value) — right-justified in 8-char field
emit_number_rj8:
    push    rbx
    push    rcx
    push    rdx
    lea     rdi, [rel itoa_buf]
    mov     rbx, rax
    xor     ecx, ecx
    mov     r8, 10
    test    rax, rax
    jnz     .enr_loop
    mov     ecx, 1
    mov     byte [rdi], '0'
    jmp     .enr_pad
.enr_loop:
    mov     rax, rbx
    xor     edx, edx
    div     r8
    mov     rbx, rax
    add     dl, '0'
    mov     [rdi + rcx], dl
    inc     ecx
    test    rbx, rbx
    jnz     .enr_loop
.enr_pad:
    ; Pad with spaces: 8 - ecx spaces
    mov     edx, 8
    sub     edx, ecx
    jle     .enr_emit
.enr_space:
    mov     al, ' '
    push    rcx
    push    rdx
    call    emit_byte
    pop     rdx
    pop     rcx
    dec     edx
    jnz     .enr_space
.enr_emit:
    dec     ecx
.enr_emit_loop:
    cmp     ecx, 0
    jl      .enr_done
    lea     rdi, [rel itoa_buf]     ; reload (emit_byte clobbers rdi)
    movzx   eax, byte [rdi + rcx]
    push    rcx
    call    emit_byte
    pop     rcx
    dec     ecx
    jmp     .enr_emit_loop
.enr_done:
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; flush_output — write out_buf[0..r12) to stdout
flush_output:
    test    r12, r12
    jz      .fo_nothing
    mov     rdi, STDOUT
    lea     rsi, [rel out_buf]
    mov     rdx, r12
    call    asm_write_all
    xor     r12d, r12d
    ret
.fo_nothing:
    xor     eax, eax
    ret

; ============================================================================
;  Error helpers
; ============================================================================

; str_eq(rdi=s1, rsi=s2) -> eax=1 if equal
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
.eq:
    mov     eax, 1
    ret
.ne:
    xor     eax, eax
    ret

; err_file(rdi=filename, esi=errno) — "ls: cannot access 'file': msg\n"
err_file:
    push    rbx
    push    r13
    mov     rbx, rdi
    mov     r13d, esi

    mov     rdi, STDERR
    lea     rsi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all

    lea     rdi, [rel str_cannot_access]
    mov     rdx, str_cannot_access_len
    mov     rdi, STDERR
    lea     rsi, [rel str_cannot_access]
    call    asm_write_all

    ; quote + filename + quote
    mov     rdi, STDERR
    lea     rsi, [rel str_squote]
    mov     rdx, 1
    call    asm_write_all

    mov     rdi, rbx
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_squote_colon]
    mov     rdx, 3
    call    asm_write_all

    ; strerror
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
    lea     rsi, [rel newline_str]
    mov     rdx, 1
    call    asm_write_all

    pop     r13
    pop     rbx
    ret

; err_cannot_open(rdi=path, esi=errno)
err_cannot_open:
    push    rbx
    push    r13
    mov     rbx, rdi
    mov     r13d, esi

    mov     rdi, STDERR
    lea     rsi, [rel str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_cannot_open]
    mov     rdx, str_cannot_open_len
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_squote]
    mov     rdx, 1
    call    asm_write_all

    mov     rdi, rbx
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [rel str_squote_colon]
    mov     rdx, 3
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
    lea     rsi, [rel newline_str]
    mov     rdx, 1
    call    asm_write_all

    pop     r13
    pop     rbx
    ret

; strerror(edi=errno) -> rax=string pointer
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
    cmp     edi, 40
    je      .se_eloop
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
.se_eloop:
    lea     rax, [rel str_eloop]
    ret

; ─── Data Section ────────────────────────────────────────
section .data

str_prefix:     db "vdir: "
str_prefix_len  equ $ - str_prefix

invocation_mode:    db MODE_VDIR

str_cannot_access: db "cannot access "
str_cannot_access_len equ $ - str_cannot_access

str_cannot_open: db "cannot open directory "
str_cannot_open_len equ $ - str_cannot_open

str_squote:     db "'"
str_squote_colon: db "': "

newline_str:    db 10
colon_nl_str:   db ":", 10
dot_str:        db ".", 0
arrow_str:      db " -> "
total_str:      db "total "

str_help_opt:   db "--help", 0
str_version_opt: db "--version", 0
str_color_auto: db "--color=auto", 0
str_color_always: db "--color=always", 0
str_color_never: db "--color=never", 0
str_color_bare: db "--color", 0

month_names:
    db "Jan", 0, "Feb", 0, "Mar", 0, "Apr", 0
    db "May", 0, "Jun", 0, "Jul", 0, "Aug", 0
    db "Sep", 0, "Oct", 0, "Nov", 0, "Dec", 0

month_days:
    db 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

help_text:
    db "Usage: vdir [OPTION]... [FILE]...", 10
    db "List information about the FILEs (the current directory by default).", 10
    db "Sort entries alphabetically if none of -cftuvSUX nor --sort is specified.", 10
    db 10
    db "  -a, --all                  do not ignore entries starting with .", 10
    db "  -A, --almost-all           do not list implied . and ..", 10
    db "  -C                         list entries by columns", 10
    db "  -d, --directory            list directories themselves, not their contents", 10
    db "  -g                         like -l, but do not list owner", 10
    db "  -h, --human-readable       with -l, print sizes like 1K 234M 2G etc.", 10
    db "  -i, --inode                print the index number of each file", 10
    db "  -l                         use a long listing format", 10
    db "  -r, --reverse              reverse order while sorting", 10
    db "  -R, --recursive            list subdirectories recursively", 10
    db "  -s, --size                 print the allocated size of each file, in blocks", 10
    db "  -S                         sort by file size, largest first", 10
    db "  -t                         sort by time, newest first", 10
    db "  -1                         list one file per line", 10
    db "      --color[=WHEN]         color the output; WHEN can be 'always', 'auto',", 10
    db "                               or 'never' (default); more info below", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
help_text_len equ $ - help_text

version_text:
    db "vdir (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Richard M. Stallman and David MacKenzie.", 10
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
str_eloop:          db "Too many levels of symbolic links", 0
str_eunknown:       db "Unknown error", 0

; ─── BSS Section ─────────────────────────────────────────
section .bss

argc:               resq 1
argv:               resq 1
flags:              resw 1
had_error:          resb 1
multi_arg:          resb 1
nfiles:             resq 1
file_ptrs:          resq MAX_FILES
file_idx:           resq 1
current_dir_path:   resq 1
num_entries:        resq 1
term_width:         resd 1
winsize_buf:        resb 8      ; struct winsize

; Sort index array
entry_sort_idx:     resd MAX_ENTRIES

; Entry storage
entry_names:        resb MAX_ENTRIES * NAME_MAX
entry_types:        resb MAX_ENTRIES
entry_inodes:       resq MAX_ENTRIES

; Multi-column state
mc_num_cols:        resd 1
mc_col_width:       resd 1
mc_num_rows:        resd 1
oe_loop_idx:        resq 1
oe_row_idx:         resd 1
pt_loop_idx:        resq 1
ed_days:            resq 1

; Stat buffers
main_stat_buf:      resb STAT_STRUCT_SIZE
entry_stat_buf:     resb STAT_STRUCT_SIZE
path_buf:           resb PATH_MAX
readlink_buf:       resb PATH_MAX

; Date calculation temporaries
date_year:          resd 1
date_month:         resd 1
date_day:           resd 1
date_hour:          resd 1
date_min:           resd 1
date_leap:          resd 1

; Output buffers
itoa_buf:           resb 32
getdents_buf:       resb GETDENTS_SIZE
out_buf:            resb OUT_BUF_SIZE

section .note.GNU-stack noalloc noexec nowrite progbits
